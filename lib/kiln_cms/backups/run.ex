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
  hazard `KilnCMS.Mail.Settings` documents). **No person writes a Run**: the
  worker, the importer and the stale-run sweep write as `KilnCMS.Backups.system/0`
  (subsystem `:backups`), through exactly the actions named in the write policy.
  There is no `destroy` yet; retention arrives with #2225.

  ## Idempotency

  `stamp` (`YYYYMMDD-HHMMSS`, the stamp in the artifacts' file names) is the
  identity: the importer upserts on it and a run it did not make is never
  modified.

  Artifacts and log entries are embedded (`KilnCMS.Backups.Artifact`,
  `KilnCMS.Backups.LogEntry`); see `KilnCMS.Backups.Log` for the log bound.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Backups.Run.Changes.Normalize

  @statuses [:running, :succeeded, :failed, :skipped]
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
      accept [:stamp, :trigger, :components, :started_at, :oban_job_id]
      change set_attribute(:origin, :app)
      change set_attribute(:status, :running)
      change Normalize
    end

    # A refused attempt (no pg_dump, backups disabled): recorded, but the
    # manifest is NOT written, so cron's record of a good backup survives.
    create :skip do
      accept [:stamp, :trigger, :components, :started_at, :error]
      change set_attribute(:origin, :app)
      change set_attribute(:status, :skipped)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
    end

    update :record_progress do
      accept [:components, :artifacts, :log]
      require_atomic? false
      change Normalize
    end

    update :finish do
      accept [:components, :artifacts, :log]
      require_atomic? false
      change set_attribute(:status, :succeeded)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
    end

    update :fail do
      accept [:components, :artifacts, :log, :error]
      require_atomic? false
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
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

    # Writes: closed to every person, platform admin included — there is no
    # `authorize_if PlatformAdmin` ahead of the narrowing, which would admit
    # one to every action. Only the named actions, only the `:backups` system
    # actor. (No `destroy` action exists; deletion comes with #2225.)
    policy action_type([:create, :update, :destroy]) do
      forbid_unless action([:start, :skip, :record_progress, :finish, :fail, :import])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
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

    timestamps()
  end

  identities do
    identity :unique_stamp, [:stamp]
  end

  @doc "Every valid status."
  def statuses, do: @statuses
end
