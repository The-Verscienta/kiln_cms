defmodule KilnCMS.Backups.Lock do
  @moduledoc """
  The cluster-wide backup lock (#2218): which step chain holds the backup
  pipeline, where it has got to, and the one request queued behind it.

  One row, `name: "backups"`. It is created on demand by `:ensure` inside every
  lock transaction rather than by a seed migration, so an empty table is a free
  lock. Every write happens inside that transaction, after
  `pg_advisory_xact_lock`, together with the `Oban.insert/2` or cancel it
  decides on (`KilnCMS.Backups.Chain`).

  ## Fencing

  `epoch` goes up on every `:hold`, `:move` and `:clear`. A step reads it when
  it begins and must present it to advance, so a step whose job was reclaimed
  or canceled meanwhile cannot move the chain on.

  `executing_boot_id`/`executing_job_id`/`executing_attempt` say which boot of
  which node last claimed the current step, with which job and which attempt of
  it (`:mark_executing`). `:hold` and `:move` clear all three: until the new
  step job claims the lock, none names it, so the stale-node rule cannot compare
  a fresh job against the previous job's boot. The attempt matters as much as
  the job: a retry of the same job may be fetched by another node (or by this
  one after a redeploy) before it claims the lock, and until it does the boot id
  is the previous attempt's.

  ## Which backup directory

  `dir_id` is written once per chain, when the `start` step hands over to
  `dump` (`:move`): only then are the chain's first files (`state.json`) in that
  directory, so a start that failed before that leaves it nil, and its retry,
  on whichever node, picks its own directory.

  ## The queued request

  `waiting_*` hold at most one request behind the holder. A further request
  folds into it (`:fold`: `waiting_folds` + 1); `:hold` clears the waiting
  fields because it is either a free lock (nothing waits) or the waiting request
  being promoted.

  ## What the queued request covers (#2219)

  `waiting_components` (nil: everything), `waiting_scheduled` and
  `waiting_schedule_ids` say what the queued request backs up. They count only
  while their **scope** is the current request's: `:queue_waiting` sets
  `waiting_scope_at` to the same instant as `waiting_requested_at` and
  `waiting_scope_folds` to 0, and `:fold` sets them to the request's
  `waiting_requested_at` and the new `waiting_folds`, each in the same
  statement. A node from before #2219 writes the queued request without them
  (its `:queue_waiting` and `:fold` don't know these columns, and its `:hold`
  doesn't clear them), so the two no longer agree and the queued request
  covers everything (`KilnCMS.Backups.Chain.waiting_scope/1`).

  The holder's own components are not on the row: an older node's `:hold` and
  `:clear` would leave them stale. They travel in the start job's args and the
  chain's `state.json`.

  ## Who writes

  No person. A platform admin reads the row (the Backups page's in-flight
  strip) and calls `:request`, whose implementation writes as
  `KilnCMS.Backups.system/0`. Every other action is the `:backups` system
  actor's alone.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:start, :dump, :plan, :archive, :checksum, :prune, :offsite, :finish]
  @components [:db, :media]
  @stamp ~r/\A\d{8}-\d{6}\z/

  postgres do
    table "backup_locks"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # The singleton, created if missing; an existing row is left as it is.
    create :ensure do
      accept []
      upsert? true
      upsert_fields []
      change set_attribute(:name, "backups")
    end

    # A free lock taken by a new chain, or the waiting request promoted.
    update :hold do
      accept [:chain_id, :trigger, :resume_stamp, :step, :part, :step_job_id]
      change atomic_update(:epoch, expr(epoch + 1))
      change atomic_update(:acquired_at, expr(now()))
      change set_attribute(:phase, :running)
      change set_attribute(:stamp, nil)
      change set_attribute(:dir_id, nil)
      change set_attribute(:executing_boot_id, nil)
      change set_attribute(:executing_job_id, nil)
      change set_attribute(:executing_attempt, nil)
      change set_attribute(:waiting_trigger, nil)
      change set_attribute(:waiting_resume_stamp, nil)
      change set_attribute(:waiting_requested_at, nil)
      change set_attribute(:waiting_requested_by, nil)
      change set_attribute(:waiting_folds, 0)
      change set_attribute(:last_folded_at, nil)
      change set_attribute(:waiting_components, nil)
      change set_attribute(:waiting_scheduled, nil)
      change set_attribute(:waiting_schedule_ids, nil)
      change set_attribute(:waiting_scope_at, nil)
      change set_attribute(:waiting_scope_folds, nil)
    end

    # The chain's next step (or a reclaimed step's replacement job).
    # `dir_id` only from the start step's hand-over (`Chain.advance/3`).
    update :move do
      accept [:step, :part, :step_job_id, :dir_id]
      change atomic_update(:epoch, expr(epoch + 1))
      change set_attribute(:phase, :running)
      change set_attribute(:executing_boot_id, nil)
      change set_attribute(:executing_job_id, nil)
      change set_attribute(:executing_attempt, nil)
    end

    # A step job's attempt began on this node's boot. The start step also
    # records the stamp it settled on, so a retry reuses it.
    update :mark_executing do
      accept [:executing_boot_id, :executing_job_id, :executing_attempt, :stamp]
    end

    # Past the point of no return: Cancel is refused from here.
    update :finishing do
      accept []
      change set_attribute(:phase, :finishing)
    end

    # Released. The waiting fields survive for the promotion that follows.
    update :clear do
      accept []
      change atomic_update(:epoch, expr(epoch + 1))

      change set_attribute(:chain_id, nil)
      change set_attribute(:stamp, nil)
      change set_attribute(:trigger, nil)
      change set_attribute(:resume_stamp, nil)
      change set_attribute(:dir_id, nil)
      change set_attribute(:step, nil)
      change set_attribute(:part, nil)
      change set_attribute(:step_job_id, nil)
      change set_attribute(:executing_boot_id, nil)
      change set_attribute(:executing_job_id, nil)
      change set_attribute(:executing_attempt, nil)
      change set_attribute(:phase, nil)
      change set_attribute(:acquired_at, nil)
    end

    # One timestamp for both columns: that is what makes the scope this
    # request's (see "What the queued request covers").
    update :queue_waiting do
      accept [
        :waiting_trigger,
        :waiting_resume_stamp,
        :waiting_requested_by,
        :waiting_components,
        :waiting_scheduled,
        :waiting_schedule_ids
      ]

      change KilnCMS.Backups.Lock.Changes.StampWaiting
      change set_attribute(:waiting_folds, 0)
      change set_attribute(:waiting_scope_folds, 0)
      change set_attribute(:last_folded_at, nil)
    end

    # The caller (`Chain`) works out what the queued request covers once this
    # one folds into it; the scope is re-stamped in the same statement.
    update :fold do
      accept [:waiting_components, :waiting_scheduled, :waiting_schedule_ids]
      change atomic_update(:waiting_folds, expr(waiting_folds + 1))
      change atomic_update(:waiting_scope_folds, expr(waiting_folds + 1))
      change atomic_update(:waiting_scope_at, expr(waiting_requested_at))
      change atomic_update(:last_folded_at, expr(now()))
    end

    # Every entry point that starts a backup: start it, queue it behind the
    # running chain, or fold it into the queued one.
    action :request, :map do
      argument :trigger, :string, allow_nil?: false, default: "manual"

      argument :resume, :string do
        constraints match: @stamp
      end

      # What to back up (#2219); nil is everything. Refused together with
      # `resume` (a resume backs up what the run did).
      argument :components, {:array, :atom} do
        constraints items: [one_of: @components], min_length: 1
      end

      # `KilnCMS.Backups.Chain` opens its own lock transaction, and must be able
      # to write the Run and log after it commits; an outer one would hold both.
      transaction? false
      run KilnCMS.Backups.Lock.Actions.Request
    end

    # The heartbeat's sweep: a holder whose node stopped beating loses the lock.
    action :reclaim_stale, :map do
      transaction? false
      run KilnCMS.Backups.Lock.Actions.ReclaimStale
    end
  end

  policies do
    # Instance-wide and tenant-less: the global role, never `OrgAdmin`.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # The Backups page's buttons, and the pipeline's own entry points. The
    # implementation writes the row as `Backups.system/0`, not as the caller.
    policy action(:request) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # The row itself: no person, platform admin included.
    policy action([
             :ensure,
             :hold,
             :move,
             :mark_executing,
             :finishing,
             :clear,
             :queue_waiting,
             :fold,
             :reclaim_stale
           ]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    attribute :name, :string do
      primary_key? true
      allow_nil? false
      default "backups"
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # The holding chain; nil when the lock is free.
    attribute :chain_id, :uuid, public?: true

    attribute :stamp, :string do
      constraints match: @stamp, max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # Capped at 64 by `Chain.request/1` before it gets here, as on the Run.
    attribute :trigger, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    attribute :resume_stamp, :string do
      constraints match: @stamp, max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # Which BACKUP_DIR (`<dir>/.kiln-dir-id`) the chain's files live in.
    attribute :dir_id, :uuid, public?: true

    attribute :step, :atom do
      constraints one_of: @steps
      public? true
    end

    attribute :part, :integer, public?: true

    # The Oban job id of the current step.
    attribute :step_job_id, :integer, public?: true

    attribute :executing_boot_id, :uuid, public?: true
    attribute :executing_job_id, :integer, public?: true
    attribute :executing_attempt, :integer, public?: true

    attribute :epoch, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :phase, :atom do
      constraints one_of: [:running, :finishing]
      public? true
    end

    attribute :acquired_at, :utc_datetime_usec, public?: true

    attribute :waiting_trigger, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    attribute :waiting_resume_stamp, :string do
      constraints match: @stamp, max_length: KilnCMS.Limits.identifier()
      public? true
    end

    attribute :waiting_requested_at, :utc_datetime_usec, public?: true

    # The user who asked, when a person did.
    attribute :waiting_requested_by, :uuid, public?: true

    attribute :waiting_folds, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_folded_at, :utc_datetime_usec, public?: true

    # What the queued request backs up (#2219); see "What the queued request
    # covers". Nil components: everything.
    attribute :waiting_components, {:array, :atom} do
      constraints items: [one_of: @components]
      public? true
    end

    # The components a schedule asked for, and which schedules (#2219).
    attribute :waiting_scheduled, {:array, :atom} do
      constraints items: [one_of: @components]
      public? true
    end

    attribute :waiting_schedule_ids, {:array, :uuid}, public?: true

    attribute :waiting_scope_at, :utc_datetime_usec, public?: true
    attribute :waiting_scope_folds, :integer, public?: true

    timestamps()
  end

  @doc "The steps of a chain, in order."
  def steps, do: @steps

  @doc "What a backup can cover (#2219), in the order a chain backs them up."
  def components, do: @components
end
