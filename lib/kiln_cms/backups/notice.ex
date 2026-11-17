defmodule KilnCMS.Backups.Notice do
  @moduledoc """
  A backup problem the operator has to hear about, kept until it is over
  (#2487, #2931): one row per `{kind, scope}`.

  The step chain and retention know things nobody sees: retention that was
  skipped or stopped part-way (a deployment then fills its disk while every
  backup still reads **Succeeded**), or a backup a schedule keeps that was
  deleted outside the app. A run's log line is the wrong home for them: a
  clean prune writes none, so the strip would flicker with every run, and
  most hold syncs run with no run at all. So each is a row here, which
  `KilnCMS.Backups.status/0` reads for the Backups page and Home.

  Two kinds:

    * `:retention` is a **state**, per place retention runs: a skip
      (`outcome: :skipped`) or a part-way stop (`:stopped`, with how many files
      it removed first) upserts the row, and a clean pass over the same place
      deletes it (`clear`). `stamp` is the backup whose prune it was. A local
      one clears only on the next in-app backup whose retention runs cleanly
      in that directory (which clears `"local"` too, see
      `KilnCMS.Backups.Notices`).
    * `:held_deleted` is an **event**: each detection upserts the row with its
      `at`, and the panels show it for eight days. A second detection in the
      same scope merges into the row (`KilnCMS.Backups.Notices.held_deleted/2`).

  `scope` names the place: `"local:<dir id>"` for a backup directory with a
  `.kiln-dir-id` (`dir_id` set too), `"local"` for one without (every such
  directory shares the one row: a cluster whose directories have no id has
  nothing else to tell them apart by), and `"dest:<id>"` for a stored
  off-site destination (`label` is its name as the run recorded it).

  `reason` is the English account `KilnCMS.Backups.Retention.describe/1`
  gives, redacted and capped like a run's log line; `units` lists at most ten
  `"<kind>:<stamp>"` entries, `total` how many there were.

  System-only, like `KilnCMS.Backups.NodeBeat`: only `KilnCMS.Backups.system/0`
  reads, reports or clears a notice. People see them through
  `KilnCMS.Backups.status/0`, which reads as the system actor for pages that
  already checked the viewer is a platform admin.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [:retention, :held_deleted]
  @outcomes [:skipped, :stopped]

  postgres do
    table "backup_notices"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # One row per `{kind, scope}`: a later report replaces every field of an
    # earlier one.
    create :report do
      accept [
        :kind,
        :scope,
        :dir_id,
        :outcome,
        :deleted,
        :stamp,
        :units,
        :total,
        :at
      ]

      # Arguments, not accepted attributes, so `Changes.Normalize` cuts them
      # before the columns' `max_length` sees them: a long reason never
      # refuses the write that records it.
      argument :label, :string
      argument :reason, :string

      upsert? true
      upsert_identity :unique_scope

      upsert_fields [
        :dir_id,
        :label,
        :outcome,
        :reason,
        :deleted,
        :stamp,
        :units,
        :total,
        :at,
        :updated_at
      ]

      change KilnCMS.Backups.Notice.Changes.Normalize
    end

    # The place is fine again: its notice of `kind` goes.
    destroy :clear do
      argument :kind, KilnCMS.Types.KnownAtom do
        allow_nil? false
        constraints one_of: @kinds
      end

      argument :scope, :string, allow_nil?: false

      change filter(expr(kind == ^arg(:kind) and scope == ^arg(:scope)))
    end
  end

  policies do
    policy always() do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, KilnCMS.Types.KnownAtom do
      allow_nil? false
      constraints one_of: @kinds
      public? true
    end

    attribute :scope, :string do
      allow_nil? false
      constraints max_length: 200
      public? true
    end

    # The backup directory's `.kiln-dir-id`, for a local scope that has one.
    attribute :dir_id, :uuid, public?: true

    # A destination's name, as the run recorded it. `Changes.Normalize` cuts
    # it to 200 characters; the ceiling is the backstop.
    attribute :label, :string do
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    # `:retention` only.
    attribute :outcome, KilnCMS.Types.KnownAtom do
      constraints one_of: @outcomes
      public? true
    end

    # Redacted and cut to 500 characters by `Changes.Normalize`; the ceiling
    # is the backstop.
    attribute :reason, :string do
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    # Files removed before a `:stopped` pass broke off.
    attribute :deleted, :integer do
      constraints min: 0
      public? true
    end

    # The backup whose prune it was (`:retention`).
    attribute :stamp, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # `:held_deleted`: up to ten `"<kind>:<stamp>"`, and how many in all.
    attribute :units, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :total, :integer do
      constraints min: 0
      public? true
    end

    attribute :at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_scope, [:kind, :scope]
  end

  @doc "Every kind of notice."
  def kinds, do: @kinds
end
