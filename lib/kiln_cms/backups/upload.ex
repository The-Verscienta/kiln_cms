defmodule KilnCMS.Backups.Upload do
  @moduledoc """
  A resumable upload of one backup file to one stored destination (#2223):
  what lets a retried, reclaimed or resumed off-site step continue an upload
  where it stopped, and what lets this installation abort it later.

  One row per attempt to get `<subdir>/<name>` onto a destination, keyed by
  `destination_key`, the destination's `KilnCMS.Backups.Destination.target_key/2`
  (`"dest:<id>|<location fingerprint>"`), so a row never follows a
  destination that was pointed somewhere else. At most one row per file and
  destination is `:open` (the partial `:unique_open` identity).

  `checkpoint` is the adapter's own state (an upload id, the parts it has
  sent), opaque here, JSON of at most 8 KiB, never a secret
  (`Kiln.BackupDestination.Resume`). It is not public: nothing but the
  backup pipeline reads it.

  ## Who owns an open row

  `owner_job_id` and `owner_attempt` are the Oban job and attempt of the step
  that last claimed it. Oban job ids only grow, and a job's attempts too, so
  ownership is compared as integers and only ever moves forward:

    * `claim` takes a row only for a step at least as new as its owner
      (`job_id` greater, or the same job with an attempt no smaller);
    * `save_checkpoint`, `complete` and `note_error` write only for the
      owner, and only while the row is `:open`;
    * `abandon` and `mark_aborted` write only from the status (and owner)
      the caller read.

  A write that matches no row is a `StaleRecord`, which
  `KilnCMS.Backups.Uploads` turns into `{:error, :superseded}`: a step that
  lost its lease (a fence, a reclaim) can never overwrite the progress of the
  step that took over.

  ## Statuses

    * `:open` — in progress, resumable;
    * `:abandoned` — given up on (a permanent failure, a changed file, a
      file found already on the destination), its store upload not yet
      aborted: the next sweep aborts it;
    * `:completed` — the file arrived;
    * `:aborted` — its store upload was aborted.

  `purge` deletes closed rows (`:completed`, `:aborted`) and the rows of a
  deleted destination once they are older than the cutoff it is given.

  System-only, like `KilnCMS.Backups.Notice`: only `KilnCMS.Backups.system/0`
  reads or writes an upload. No API exposes it.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @statuses [:open, :abandoned, :completed, :aborted]

  postgres do
    table "backup_uploads"
    repo KilnCMS.Repo

    # SQL for the partial `:unique_open` identity: one open upload per file
    # and destination; closed rows don't count.
    identity_wheres_to_sql unique_open: "status = 'open'"

    custom_indexes do
      index [:destination_key, :status, :updated_at]
    end
  end

  actions do
    defaults [:read]

    # The first save of a fresh upload records it, owned by the step that
    # started it. A second open of the same file is refused by `:unique_open`.
    create :open do
      accept [
        :destination_key,
        :destination_id,
        :subdir,
        :name,
        :stamp,
        :bytes,
        :sha256,
        :checkpoint,
        :bytes_done,
        :owner_job_id,
        :owner_attempt
      ]

      change set_attribute(:status, :open)
      change set_attribute(:attempts, 1)
    end

    # The open upload of `<subdir>/<name>` on `destination_key`, if any.
    read :open_for do
      get? true

      argument :destination_key, :string, allow_nil?: false
      argument :subdir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      filter expr(
               destination_key == ^arg(:destination_key) and subdir == ^arg(:subdir) and
                 name == ^arg(:name) and status == :open
             )
    end

    # What the sweep may abort on one destination: abandoned uploads, and
    # open ones nobody has touched since `idle_before`. Oldest first, at most
    # `limit`.
    read :owed do
      argument :destination_key, :string, allow_nil?: false
      argument :idle_before, :utc_datetime_usec, allow_nil?: false

      argument :limit, :integer do
        allow_nil? false
        default 50
        constraints min: 1, max: 500
      end

      filter expr(
               destination_key == ^arg(:destination_key) and
                 (status == :abandoned or (status == :open and updated_at < ^arg(:idle_before)))
             )

      prepare build(sort: [updated_at: :asc, id: :asc])
      prepare fn query, _context -> Ash.Query.limit(query, query.arguments.limit) end
    end

    # Take over an open upload, for a step at least as new as its owner.
    update :claim do
      accept []

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]

      change filter(
               expr(
                 status == :open and
                   (owner_job_id < ^arg(:job_id) or
                      (owner_job_id == ^arg(:job_id) and owner_attempt <= ^arg(:attempt)))
               )
             )

      change set_attribute(:owner_job_id, arg(:job_id))
      change set_attribute(:owner_attempt, arg(:attempt))
      change atomic_update(:attempts, expr(attempts + 1))
    end

    # Progress, from the owner only.
    update :save_checkpoint do
      accept []

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]
      argument :checkpoint, :map, allow_nil?: false
      argument :bytes_done, :integer, allow_nil?: false, default: 0, constraints: [min: 0]

      change filter(
               expr(
                 status == :open and owner_job_id == ^arg(:job_id) and
                   owner_attempt == ^arg(:attempt)
               )
             )

      change set_attribute(:checkpoint, arg(:checkpoint))
      change set_attribute(:bytes_done, arg(:bytes_done))
    end

    # A transient failure: the row stays open, for the next attempt.
    update :note_error do
      accept []

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]
      argument :last_error, :string, constraints: [max_length: 500]

      change filter(
               expr(
                 status == :open and owner_job_id == ^arg(:job_id) and
                   owner_attempt == ^arg(:attempt)
               )
             )

      change set_attribute(:last_error, arg(:last_error))
    end

    # The file arrived.
    update :complete do
      accept []

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]

      change filter(
               expr(
                 status == :open and owner_job_id == ^arg(:job_id) and
                   owner_attempt == ^arg(:attempt)
               )
             )

      change set_attribute(:status, :completed)
      change set_attribute(:checkpoint, nil)
    end

    # Given up on; its store upload is still to be aborted.
    update :abandon do
      accept []

      argument :expected_status, KilnCMS.Types.KnownAtom do
        allow_nil? false
        constraints one_of: [:open, :abandoned]
      end

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]
      argument :last_error, :string, constraints: [max_length: 500]

      change filter(
               expr(
                 status == ^arg(:expected_status) and owner_job_id == ^arg(:job_id) and
                   owner_attempt == ^arg(:attempt)
               )
             )

      change set_attribute(:status, :abandoned)
      change set_attribute(:last_error, arg(:last_error))
    end

    # Its store upload was aborted (or was already gone).
    update :mark_aborted do
      accept []

      argument :expected_status, KilnCMS.Types.KnownAtom do
        allow_nil? false
        constraints one_of: [:open, :abandoned]
      end

      argument :job_id, :integer, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false, constraints: [min: 0]

      change filter(
               expr(
                 status == ^arg(:expected_status) and owner_job_id == ^arg(:job_id) and
                   owner_attempt == ^arg(:attempt)
               )
             )

      change set_attribute(:status, :aborted)
      change set_attribute(:checkpoint, nil)
    end

    # Closed rows, and every row of a destination that no longer exists, last
    # touched before `before`. One statement, whichever destination.
    destroy :purge do
      argument :before, :utc_datetime_usec, allow_nil?: false

      change filter(
               expr(
                 updated_at < ^arg(:before) and
                   (status in [:completed, :aborted] or
                      fragment(
                        "NOT EXISTS (SELECT 1 FROM backup_destinations d WHERE d.id = ?)",
                        destination_id
                      ))
               )
             )
    end
  end

  policies do
    policy always() do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    uuid_primary_key :id

    # `KilnCMS.Backups.Destination.target_key/2`: `"dest:<id>|<location fingerprint>"`.
    attribute :destination_key, :string do
      allow_nil? false
      constraints max_length: 200
      public? true
    end

    # The stored destination; no foreign key, so a deleted destination's rows
    # stay until `purge` takes them.
    attribute :destination_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :subdir, :string do
      allow_nil? false
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    # The backup the file belongs to.
    attribute :stamp, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # The file as it verified locally: a checkpoint is handed back only for
    # the same size and digest.
    attribute :bytes, :integer do
      allow_nil? false
      constraints min: 0
      public? true
    end

    attribute :sha256, :string do
      allow_nil? false
      constraints max_length: 64
      public? true
    end

    # The adapter's own state. Never a secret; never shown.
    attribute :checkpoint, :map, public?: false

    # How far the adapter says it got, when its checkpoint carries
    # `"bytes_done"`.
    attribute :bytes_done, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :status, KilnCMS.Types.KnownAtom do
      allow_nil? false
      default :open
      constraints one_of: @statuses
      public? true
    end

    attribute :owner_job_id, :integer do
      allow_nil? false
      public? true
    end

    # 0 for a step run by hand (tests), as `KilnCMS.Backups.Steps` tags it.
    attribute :owner_attempt, :integer do
      allow_nil? false
      constraints min: 0
      public? true
    end

    # How many steps have worked on it.
    attribute :attempts, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :last_error, :string do
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_open, [:destination_key, :subdir, :name] do
      where expr(status == :open)
    end
  end

  @doc "Every status an upload can have."
  def statuses, do: @statuses
end
