defmodule KilnCMS.Backups.Run do
  @moduledoc """
  One backup attempt (#2217): what ran, what it produced, and how it ended.

  `manifest.json` answers "what was the last backup"; a `Run` answers "what
  happened every time". The in-app worker writes one per attempt, and the
  importer (a later step) turns cron-made backups into `origin: :imported` rows,
  so the history shows both.

  ## Instance-wide, and read-only to people

  The backup directory belongs to the instance, so there is no `multitenancy`
  block and the read gate is `KilnCMS.Accounts.Checks.PlatformAdmin` — never
  `OrgAdmin`, which would resolve a tenant-less subject to the default org (the
  hazard `KilnCMS.Mail.Settings` documents). **No person writes a Run**, with one
  exception: a platform admin may `:cancel` a running backup (#2218). The
  worker, the importer, retention and the stale-run sweep write as
  `KilnCMS.Backups.system/0` (subsystem `:backups`), through exactly the actions
  named in the write policy. There is no `destroy` yet; retention arrives with
  #2225.

  ## Idempotency

  `stamp` (`YYYYMMDD-HHMMSS`, the stamp in the artifacts' file names) is the
  identity: the importer upserts on it and a run it did not make is never
  modified.

  Artifacts and log entries are embedded (`KilnCMS.Backups.Artifact`,
  `KilnCMS.Backups.LogEntry`); see `KilnCMS.Backups.Log` for the log bound.

  `dir_id` (#2539) names the backup directory the run's files are in, so a
  resume's start runs on a node that has them (`KilnCMS.Backups.StepWorker`).
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Backups.Run.Changes.{Cancel, Normalize, OwnChain, Resume, ResumeRefused}

  # `:canceled` (#2218) comes last: a platform admin stopped the run. Widening
  # the check constraint is expand-safe; an older node READING a canceled row
  # cannot cast it (accepted, see the upgrade note).
  @statuses [:running, :succeeded, :failed, :skipped, :canceled]
  @statuses_sql Enum.map_join(@statuses, ", ", &"'#{&1}'")

  postgres do
    table "backup_runs"
    repo KilnCMS.Repo

    # Ash casts `status` to an atom on read, so an out-of-band write of any
    # other string would crash every read of the history page.
    check_constraints do
      check_constraint :status, "backup_runs_status_must_be_known",
        check: "status IN (#{@statuses_sql})"
    end

    custom_indexes do
      index [:started_at], name: "backup_runs_started_at_index"
    end
  end

  actions do
    defaults [:read]

    # The history page (platform admin): newest first, offset-paginated.
    read :history do
      pagination offset?: true,
                 countable: true,
                 required?: false,
                 default_limit: 25,
                 max_page_size: 100

      prepare build(sort: [started_at: :desc, id: :desc])
    end

    read :running do
      filter expr(status == :running)
    end

    read :by_stamp do
      get? true
      argument :stamp, :string, allow_nil?: false
      filter expr(stamp == ^arg(:stamp))
    end

    # The worker opens a run before any file lands.
    create :start do
      accept [
        :stamp,
        :trigger,
        :components,
        :scheduled_components,
        :schedule_ids,
        :started_at,
        :oban_job_id,
        :chain_id,
        :dir_id
      ]

      change set_attribute(:origin, :app)
      change set_attribute(:status, :running)
      change Normalize
    end

    # A refused attempt (no pg_dump, backups disabled): recorded, but the
    # manifest is NOT written, so cron's record of a good backup survives.
    create :skip do
      accept [
        :stamp,
        :trigger,
        :components,
        :scheduled_components,
        :schedule_ids,
        :started_at,
        :error
      ]

      change set_attribute(:origin, :app)
      change set_attribute(:status, :skipped)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
    end

    # The chain's writes (`record_progress`, `finish`, `fail`) only land on a
    # run that is still `running` (#2218) under the writer's own chain
    # (`OwnChain`, #2538): a step canceled or superseded meanwhile gets a
    # `StaleRecord` error (the recorder logs it) instead of overwriting
    # `canceled`, a newer outcome, or a resume's progress. `dir_id` (#2539):
    # a fresh start retried on another node records that node's directory.
    update :record_progress do
      accept [:components, :artifacts, :log, :dir_id]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change Normalize
    end

    update :finish do
      accept [:components, :artifacts, :log]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change set_attribute(:status, :succeeded)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
    end

    update :fail do
      accept [:components, :artifacts, :log, :error]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
    end

    # A failed, canceled or interrupted in-app run picks up where it stopped
    # (#2218): back to `running`, with the old outcome cleared. The guard is
    # the `Resume` change: it refuses anything but a failed or canceled run or
    # a stale `running` one, and re-checks the same in the UPDATE's WHERE, so
    # two callers holding one stale struct can't both flip it (#2421). The
    # stamp and `started_at` stay the original attempt's. `dir_id` (#2539) is
    # rebound to the directory the resume read `state.json` from.
    update :resume do
      accept [:chain_id, :dir_id]
      require_atomic? false
      change Resume
      change set_attribute(:status, :running)
      change set_attribute(:finished_at, nil)
      change set_attribute(:error, nil)
      change Normalize
    end

    # A resume that was requested but couldn't run says why on the row (#2539),
    # which keeps its status (a stale `running` one is failed). The guard and
    # the WHERE that keeps it off live, imported and re-opened runs are the
    # `ResumeRefused` change.
    update :note_resume_refused do
      accept []
      argument :reason, :string, allow_nil?: false
      require_atomic? false
      change ResumeRefused
      change Normalize
    end

    # Retention marking another run's deleted files `pruned`. Separate from
    # `record_progress` because that run has finished: no status filter.
    update :mark_pruned do
      accept [:artifacts]
      require_atomic? false
      change Normalize
    end

    # A platform admin stops a running in-app backup (#2218). The guard and the
    # job/lock side effects are the `Cancel` change; the status filter turns a
    # run that finished meanwhile into a `StaleRecord` error. Audited in the
    # same transaction. `manifest.json` and the work dir are left alone, so
    # the run can be resumed.
    update :cancel do
      accept []
      require_atomic? false
      change filter(expr(status == :running))
      change Cancel
      change set_attribute(:status, :canceled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize

      # The backup directory is the instance's, so the event goes to the
      # instance log, which only platform admins read (#2541) - never a
      # site's, whose admins need not be platform admins.
      change {KilnCMS.Security.Changes.Record,
              type: :backup_canceled,
              scope: :instance,
              mode: :in_transaction,
              target: fn record, _changeset -> {"backup_run", record.id} end,
              metadata: fn record, changeset ->
                %{"stamp" => record.stamp, "step" => changeset.context[:backup_step]}
              end}
    end

    # A cron-made backup becomes a row, once. `upsert_fields []` makes a
    # conflict on the stamp do nothing, so an existing run — the app's own,
    # still `running`, or a previous import — is never touched.
    create :import do
      accept [
        :stamp,
        :trigger,
        :status,
        :components,
        :started_at,
        :finished_at,
        :error,
        :log,
        :artifacts
      ]

      upsert? true
      upsert_identity :unique_stamp
      upsert_fields []
      change set_attribute(:origin, :imported)
      change Normalize
    end
  end

  policies do
    # Instance-wide, tenant-less: the global-role check, NOT `OrgAdmin`.
    #
    # Reads: a platform admin sees the history. The worker, importer and stale
    # sweep read as the `:backups` system actor, narrowed to the reads they
    # make — `:history` (the page) stays the platform admin's. Ash ANDs
    # policies, so the admission sits inside this policy rather than in a
    # second one that could not lift a refusal.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      forbid_unless action([:read, :running, :by_stamp])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # Writes: the pipeline's actions are closed to every person, platform admin
    # included, and open only to the `:backups` system actor. (No `destroy`
    # action exists; deletion comes with #2225.) `resume` (#2218) is the worker
    # re-opening a failed run; the platform admin's "Resume" button requests a
    # backup, it never writes the run itself. `note_resume_refused` (#2539) is
    # the worker saying on the row that a requested resume couldn't run.
    policy action([
             :start,
             :skip,
             :record_progress,
             :finish,
             :fail,
             :resume,
             :note_resume_refused,
             :import,
             :mark_pruned
           ]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # The one write a person makes (#2218): a platform admin cancels a running
    # backup. Not the system actor: nothing in the pipeline cancels a run.
    policy action(:cancel) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # Any write action not named above matches no policy and is forbidden.
  end

  attributes do
    uuid_primary_key :id

    # `YYYYMMDD-HHMMSS` of the start, as in `kiln-db-<stamp>.dump`.
    attribute :stamp, :string do
      allow_nil? false
      constraints match: ~r/\A\d{8}-\d{6}\z/
      public? true
    end

    # Operator-supplied (`BACKUP_TRIGGER`, a console label): capped, not enumerated.
    attribute :trigger, :string do
      allow_nil? false
      default "manual"
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :running
      constraints one_of: @statuses
      public? true
    end

    # `:app` — this application's worker; `:imported` — found on disk.
    attribute :origin, :atom do
      allow_nil? false
      default :app
      constraints one_of: [:app, :imported]
      public? true
    end

    attribute :components, {:array, :atom} do
      allow_nil? false
      default []
      constraints items: [one_of: [:db, :media]]
      public? true
    end

    # Of `components`, the ones a schedule asked for, and which schedules
    # (#2219). Empty for a manual, cron or imported run; a resume keeps the
    # run's own.
    attribute :scheduled_components, {:array, :atom} do
      allow_nil? false
      default []
      constraints items: [one_of: [:db, :media]]
      public? true
    end

    attribute :schedule_ids, {:array, :uuid} do
      allow_nil? false
      default []
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :finished_at, :utc_datetime_usec, public?: true

    # Redacted and capped to 4 000 characters by `Changes.Normalize`.
    attribute :error, :string, public?: true

    attribute :log, {:array, KilnCMS.Backups.LogEntry} do
      allow_nil? false
      default []
      public? true
    end

    attribute :artifacts, {:array, KilnCMS.Backups.Artifact} do
      allow_nil? false
      default []
      public? true
    end

    attribute :oban_job_id, :integer, public?: true

    # The step chain (#2218) writing this run; a resume or retry under a new
    # chain replaces it. Nil on imported runs and runs from before #2218.
    attribute :chain_id, :uuid, public?: true

    # The `.kiln-dir-id` of the directory holding the run's files (#2539): a
    # resume's start runs on a node with that directory. Nil for imported runs
    # and runs from before #2539.
    attribute :dir_id, :uuid, public?: true

    timestamps()
  end

  identities do
    identity :unique_stamp, [:stamp]
  end

  @doc "Every valid status."
  def statuses, do: @statuses
end
