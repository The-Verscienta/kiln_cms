defmodule KilnCMS.Backups.Run do
  @moduledoc """
  One backup attempt (#2217): what ran, what it produced, and how it ended.

  `manifest.json` answers "what was the last backup"; a `Run` answers "what
  happened every time". The in-app worker writes one per attempt, and the
  importer (`KilnCMS.Backups.Importer`) turns cron-made backups into
  `origin: :imported` rows, so the history shows both.

  ## Instance-wide, and read-only to people

  The backup directory belongs to the instance, so there is no `multitenancy`
  block and the read gate is `KilnCMS.Accounts.Checks.PlatformAdmin` — never
  `OrgAdmin`, which would resolve a tenant-less subject to the default org (the
  hazard `KilnCMS.Mail.Settings` documents). **No person writes a Run**, with three
  exceptions: a platform admin may `:cancel` a running backup (#2218),
  `:cancel_resume` a resume of it that has not started yet (#2816), or
  `:cancel_resend` a re-send of it to the destinations it missed (#2949). The
  worker, the importer, retention and the stale-run sweep write as
  `KilnCMS.Backups.system/0` (subsystem `:backups`), through exactly the actions
  named in the write policy. There is no `destroy`: retention (#2219) deletes
  files, not rows, and marks the deleted artifacts of a run `pruned`
  (`:mark_pruned`). Deleting a run is #2225.

  A platform admin may also download a run's local files (part of #2225):
  `:check_download` and `:download` are generic actions that write no Run;
  `:download` records `backup_downloaded` in the instance log before the file
  is handed over (`Actions.Download`). Nobody else may, the system actor
  included.

  ## Idempotency

  `stamp` (`YYYYMMDD-HHMMSS`, the stamp in the artifacts' file names) is the
  identity: the importer upserts on it and a run it did not make is never
  modified. The one exception is an imported row the importer recorded as
  "Interrupted" whose stamp later turned out complete (#2846): it is
  rewritten once, through `:reevaluate_interrupted`.

  ## Rewrites of a finished row are locked (#2846)

  `:mark_pruned` and `:reevaluate_interrupted` both change a row nothing else
  is writing any more, and both lock it first (`get_and_lock_for_update()`)
  and compute what they write from the row as locked (`Changes.MarkFiles`,
  `Changes.ReevaluateInterrupted`). So retention's mark can't be lost to a
  re-evaluation that read the row before it, and a re-evaluation refuses a
  row retention has marked since.

  Artifacts, log entries and the per-destination outcomes are embedded
  (`KilnCMS.Backups.Artifact`, `KilnCMS.Backups.LogEntry`,
  `KilnCMS.Backups.RunDestination`); see `KilnCMS.Backups.Log` for the log
  bound.

  `dir_id` (#2539) names the backup directory the run's files are in, so a
  resume's start runs on a node that has them (`KilnCMS.Backups.StepWorker`).

  ## Reports (#2229)

  Each write that gives a run its outcome (`:finish`, `:fail`, `:skip`,
  `:cancel`, `:cancel_resume`, `:note_resume_refused`, `:import`,
  `:reevaluate_interrupted`) enqueues the run's report in its own
  transaction (`Changes.AfterOutcome`, ADR 0094). A re-send's writes don't:
  a re-send is not a run.

  ## A re-send (#2949)

  A succeeded run that is partly off-site (or not off-site at all) may be
  re-sent to the destinations it missed (`KilnCMS.Backups.Resend`). Its
  writes never change `status`, `finished_at` or `error`:

    * `:begin_resend` moves the run to the re-send's chain (`chain_id`), so
      the re-send's own writes are fenced like a backup step's
      (`Changes.OwnChain`). Its UPDATE is pinned to the run as the re-send
      read it (`Changes.BeginResend`);
    * `:record_resend` writes what the re-send changed: the target
      destinations' entries, the per-file outcomes on the artifacts, the
      log, and the `offsite_status` they now add up to. Only on a run that
      is still `succeeded`, under the re-send's chain;
    * `:cancel_resend` is a platform admin's Cancel of a running re-send
      (`Changes.CancelResend`): its chain is cleared from the run, so a
      step that outlives the Cancel can't write.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Backups.Run.Changes.{
    AfterOutcome,
    BeginResend,
    Cancel,
    CancelResend,
    CancelResume,
    MarkFiles,
    Normalize,
    OwnChain,
    ReevaluateInterrupted,
    Resume,
    ResumeRefused
  }

  # `:canceled` (#2218) comes last: a platform admin stopped the run. Widening
  # the check constraint is expand-safe; an older node READING a canceled row
  # cannot cast it (accepted, see the upgrade note).
  @statuses [:running, :succeeded, :failed, :skipped, :canceled]
  @statuses_sql Enum.map_join(@statuses, ", ", &"'#{&1}'")

  @offsite_statuses [:none, :complete, :partial, :failed]

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

  # The error `KilnCMS.Backups.Importer` records on an import interrupted
  # mid-backup (#2846). Kept here, not in the importer, so this resource's
  # `:interrupted_imports` filter doesn't make Run depend on the importer at
  # compile time.
  @interrupted_import_error "Interrupted: the backup stopped before it finished and left .partial files behind"

  @doc "The error an import interrupted mid-backup records (`KilnCMS.Backups.Importer`)."
  @spec interrupted_import_error() :: String.t()
  def interrupted_import_error, do: @interrupted_import_error

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

    # The in-app runs that recorded reaching the destination `key` (`ok`),
    # with the backup directory each ran in: what the Destinations tab lists
    # as other backup directories' backups there. Newest first.
    read :sent_to_destination do
      argument :key, :string, allow_nil?: false

      filter expr(
               origin == :app and not is_nil(dir_id) and
                 fragment(
                   "EXISTS (SELECT 1 FROM unnest(?) AS d WHERE d->>'key' = ? AND d->>'status' = 'ok')",
                   destinations,
                   ^arg(:key)
                 )
             )

      prepare build(sort: [started_at: :desc, id: :desc])
    end

    # The prunes cron recorded after a page's oldest imported row (#3113):
    # the imported runs started after `after` that carry `keep_days`, oldest
    # first, with only what `KilnCMS.Backups.Presence` judges by. Read by the
    # history page, as the platform admin, once per disk read.
    read :prune_windows do
      argument :after, :utc_datetime_usec, allow_nil?: false

      filter expr(origin == :imported and started_at > ^arg(:after) and not is_nil(keep_days))

      prepare build(
                select: [:id, :started_at, :finished_at, :keep_days],
                sort: [started_at: :asc, id: :asc]
              )
    end

    # The newest imported run (#3113): a row older than it had a later cron
    # run, whether or not that run recorded `keep_days`.
    read :newest_import do
      get? true
      filter expr(origin == :imported)
      prepare build(select: [:id, :started_at], sort: [started_at: :desc, id: :desc], limit: 1)
    end

    read :by_stamp do
      get? true
      argument :stamp, :string, allow_nil?: false
      filter expr(stamp == ^arg(:stamp))
    end

    # The imported rows the importer recorded as killed runs (#2478), which
    # it looks at again each pass in case the stamp finished after all
    # (#2846). The system actor's alone.
    read :interrupted_imports do
      filter expr(
               origin == :imported and status == :failed and
                 error == ^@interrupted_import_error
             )
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
        :dir_id,
        :destinations,
        :offsite_status
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
      change AfterOutcome
    end

    # The chain's writes (`record_progress`, `finish`, `fail`) only land on a
    # run that is still `running` (#2218) under the writer's own chain
    # (`OwnChain`, #2538): a step canceled or superseded meanwhile gets a
    # `StaleRecord` error (the recorder logs it) instead of overwriting
    # `canceled`, a newer outcome, or a resume's progress. `dir_id` (#2539):
    # a fresh start retried on another node records that node's directory.
    update :record_progress do
      accept [:components, :artifacts, :log, :dir_id, :destinations, :offsite_status]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change Normalize
    end

    update :finish do
      accept [:components, :artifacts, :log, :destinations, :offsite_status]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change set_attribute(:status, :succeeded)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
      change AfterOutcome
    end

    update :fail do
      accept [:components, :artifacts, :log, :error, :destinations, :offsite_status]
      require_atomic? false
      change filter(expr(status == :running))
      change OwnChain
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Normalize
      change AfterOutcome
    end

    # A backup interrupted from outside its step (#3078) is failed from its
    # row at once (`fail`); the record that runs later, on the node with its
    # `state.json`, adds what a best-effort write missed: the accumulator's
    # components, artifacts, log and destinations. Only on a `failed` run of
    # the writer's own chain (`OwnChain`) that nothing has written since the
    # fail (`failed_at`, its `updated_at` then), so a later note (a refused
    # resume, a Cancel of one, retention's `pruned`) is never replaced; never
    # the status or the error.
    update :record_interrupted do
      accept [:components, :artifacts, :log, :destinations]
      argument :failed_at, :utc_datetime_usec, allow_nil?: false
      require_atomic? false
      change filter(expr(status == :failed and updated_at == ^arg(:failed_at)))
      change OwnChain
      change Normalize
    end

    # A failed, canceled or interrupted in-app run picks up where it stopped
    # (#2218): back to `running`, with the old outcome cleared. The guard is
    # the `Resume` change: it refuses anything but a failed or canceled run or
    # a stale `running` one, and re-checks the same in the UPDATE's WHERE, so
    # two callers holding one stale struct can't both flip it (#2421). The
    # stamp and `started_at` stay the original attempt's. `dir_id` (#2539) is
    # rebound to the directory the resume read `state.json` from. The
    # off-site outcome (#2220) is cleared too, unless the caller settles new
    # destinations with it: the resume's start sends to them again.
    update :resume do
      accept [:chain_id, :dir_id, :destinations, :offsite_status]
      require_atomic? false
      change Resume
      change set_attribute(:status, :running)
      change set_attribute(:finished_at, nil)
      change set_attribute(:error, nil)
      change set_new_attribute(:destinations, [])
      change set_new_attribute(:offsite_status, nil)
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
      change AfterOutcome
    end

    # Retention marking another run's deleted files `pruned`. Separate from
    # `record_progress` because that run has finished: no status filter. The
    # marks are computed from the row as locked (`MarkFiles`, after the
    # lock), never sent by the caller, so a write that commits between
    # retention's read and this one is kept (#2846).
    update :mark_pruned do
      accept []
      argument :names, {:array, :string}, allow_nil?: false
      argument :key, :string, allow_nil?: false
      argument :at, :string, allow_nil?: false
      require_atomic? false
      change get_and_lock_for_update()
      change {MarkFiles, mode: :pruned}
      change Normalize
    end

    # An "Interrupted" import whose stamp finished after all (#2846): the
    # importer's new outcome replaces the old one, once. Never the stamp, the
    # origin, `started_at` or `keep_days`. The guard (still that Interrupted
    # row, no file of it marked pruned) and the log line are
    # `ReevaluateInterrupted`, on the row as locked.
    update :reevaluate_interrupted do
      accept [:status, :error, :components, :finished_at, :artifacts]
      require_atomic? false
      change get_and_lock_for_update()
      change ReevaluateInterrupted
      change Normalize
      change AfterOutcome
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
      change AfterOutcome

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

    # A platform admin cancels a resume of this run that holds the backup
    # lock but has not re-opened the run yet (#2816): waiting for the server
    # with its files, or for a Cancel to settle. The guard, the job/lock side
    # effects and the WHERE are the `CancelResume` change; the run keeps its
    # status (a stale `running` one is failed) and gains a note. Audited in
    # the same transaction as the Cancel it is, with `"resume" => true`.
    update :cancel_resume do
      accept []
      require_atomic? false
      change CancelResume
      change Normalize
      change AfterOutcome

      change {KilnCMS.Security.Changes.Record,
              type: :backup_canceled,
              scope: :instance,
              mode: :in_transaction,
              target: fn record, _changeset -> {"backup_run", record.id} end,
              metadata: fn record, _changeset ->
                %{"stamp" => record.stamp, "step" => "start", "resume" => true}
              end}
    end

    # A re-send of this succeeded, partly off-site run begins (#2949): the
    # run moves to the re-send's chain. The guard, the log line and the
    # WHERE pinned to the run as the re-send read it are `BeginResend`.
    update :begin_resend do
      accept [:chain_id]
      require_atomic? false
      change BeginResend
      change Normalize
    end

    # What a re-send changed (#2949): only the target destinations' entries,
    # the per-file outcomes, the log and the off-site outcome they add up
    # to. Never the status: a run that is no longer `succeeded`, or no
    # longer the re-send's (`OwnChain`), gets a `StaleRecord` error.
    update :record_resend do
      accept [:artifacts, :log, :destinations, :offsite_status]
      require_atomic? false
      change filter(expr(status == :succeeded))
      change OwnChain
      change Normalize
    end

    # A platform admin stops a running re-send (#2949). The guard, the
    # job/lock side effects and the WHERE are the `CancelResend` change; the
    # run keeps its status and loses the re-send's chain. Audited in the same
    # transaction as the Cancel it is, with `"resend" => true`.
    update :cancel_resend do
      accept []
      require_atomic? false
      change CancelResend
      change Normalize

      change {KilnCMS.Security.Changes.Record,
              type: :backup_canceled,
              scope: :instance,
              mode: :in_transaction,
              target: fn record, _changeset -> {"backup_run", record.id} end,
              metadata: fn record, changeset ->
                %{
                  "stamp" => record.stamp,
                  "step" => changeset.context[:backup_step],
                  "resend" => true
                }
              end}
    end

    # Downloading one local file of a run (part of #2225): the checks, and
    # where the file is (`Actions.Download`). `:check_download` writes
    # nothing (the History page's click); `:download` records
    # `backup_downloaded` once every check passed and returns the path only
    # if it was written (the download request, before any byte is sent).
    # Not in a transaction: the event is written on its own, before the
    # file is streamed.
    action :check_download, :map do
      argument :run_id, :uuid, allow_nil?: false

      argument :file, :string do
        allow_nil? false
        # Compared byte for byte with the row's names: never trimmed.
        constraints max_length: 255, trim?: false
      end

      transaction? false
      run {KilnCMS.Backups.Run.Actions.Download, audit: false}
    end

    action :download, :map do
      argument :run_id, :uuid, allow_nil?: false

      argument :file, :string do
        allow_nil? false
        constraints max_length: 255, trim?: false
      end

      transaction? false
      run {KilnCMS.Backups.Run.Actions.Download, audit: true}
    end

    # A cron-made backup becomes a row, once. `keep_days` (#3113) is cron's
    # window as the run's own manifest recorded it; no other action takes it. `upsert_fields []` makes a
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
        :artifacts,
        :keep_days
      ]

      upsert? true
      upsert_identity :unique_stamp
      upsert_fields []
      change set_attribute(:origin, :imported)
      change Normalize
      change AfterOutcome
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
      forbid_unless action([:read, :running, :by_stamp, :interrupted_imports])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # The importer's second look at its Interrupted rows (#2846) is the
    # system actor's alone: ANDed with the read policy above, so a platform
    # admin, admitted there, is refused here. The history page has its own
    # read.
    policy action(:interrupted_imports) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # Writes: the pipeline's actions are closed to every person, platform admin
    # included, and open only to the `:backups` system actor. (No `destroy`
    # action exists; deletion comes with #2225. Downloads, its first part,
    # write no Run: their policy is below.) `resume` (#2218) is the worker
    # re-opening a failed run; the platform admin's "Resume" button requests a
    # backup, it never writes the run itself. `note_resume_refused` (#2539) is
    # the worker saying on the row that a requested resume couldn't run.
    # `reevaluate_interrupted` (#2846) is the importer correcting its own
    # Interrupted row.
    policy action([
             :start,
             :skip,
             :record_progress,
             :finish,
             :fail,
             :record_interrupted,
             :resume,
             :note_resume_refused,
             :begin_resend,
             :record_resend,
             :import,
             :mark_pruned,
             :reevaluate_interrupted
           ]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # The one write a person makes (#2218): a platform admin cancels a running
    # backup. Not the system actor: nothing in the pipeline cancels a run.
    policy action(:cancel) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # The same Cancel for a resume that has not started yet (#2816): the
    # platform admin's alone, as `:cancel`.
    policy action(:cancel_resume) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # The Cancel of a running re-send (#2949): the platform admin's alone, as
    # `:cancel`. Not the system actor: nothing in the pipeline cancels one.
    policy action(:cancel_resend) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # A download of a run's local file (part of #2225), checked or made: the
    # platform admin's alone. Not the system actor, not an org admin: nothing
    # in the pipeline downloads, and the dump holds every organization.
    policy action([:check_download, :download]) do
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

    # How each off-site destination fared (#2220), and what that adds up to:
    # `:none` (no destination), `:complete`, `:partial` (some reached, the run
    # still succeeded) or `:failed`. `KilnCMS.Backups.Recorder.offsite_outcome/1`
    # derives the second from the first. `[]` and nil on imported runs and on
    # runs from before #2220. `KnownAtom`, so a value a newer release adds
    # doesn't break this one's history page.
    attribute :destinations, {:array, KilnCMS.Backups.RunDestination} do
      allow_nil? false
      default []
      public? true
    end

    attribute :offsite_status, KilnCMS.Types.KnownAtom do
      constraints one_of: @offsite_statuses
      public? true
    end

    attribute :oban_job_id, :integer, public?: true

    # When this run last ended `failed` (#2229): that write's `finished_at`,
    # set by `Changes.AfterOutcome`, never accepted from input. A resume
    # keeps it, so a resumed run that then succeeds is reported as recovered
    # to the admins its failure was reported to. Nil on a run that never
    # failed, and on runs that failed before #2229.
    attribute :last_failed_at, :utc_datetime_usec, public?: true

    # The step chain (#2218) writing this run; a resume or retry under a new
    # chain replaces it. Nil on imported runs and runs from before #2218.
    attribute :chain_id, :uuid, public?: true

    # The `.kiln-dir-id` of the directory holding the run's files (#2539): a
    # resume's start runs on a node with that directory. Nil for imported runs
    # and runs from before #2539.
    attribute :dir_id, :uuid, public?: true

    # Cron's `BACKUP_KEEP_DAYS` when this run's prune ran (#3113), from the
    # `manifest.json` of an imported `backup.sh all` run that succeeded, if
    # the importer saw that manifest. Nil on every other run, and on runs
    # imported before #3113. Only `:import` sets it.
    attribute :keep_days, :integer do
      constraints min: 1
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_stamp, [:stamp]
  end

  @doc "Every valid status."
  def statuses, do: @statuses

  @doc "Every valid `offsite_status` (#2220)."
  def offsite_statuses, do: @offsite_statuses
end
