defmodule KilnCMS.Backups.Schedule do
  @moduledoc """
  An in-app backup schedule (part of #2219): which components to back up,
  how often, at what local time in which time zone, and from which date.

  `KilnCMS.Backups.Scheduler` ticks every minute (one static Oban cron entry,
  `KILN_BACKUP_SCHEDULER_CRON`) and asks for a backup of every schedule whose
  latest **window** (`KilnCMS.Backups.Schedule.Window`) is due and not yet
  claimed (`KilnCMS.Backups.request_scheduled/3`).

  ## Windows and the claim

  A window is one occurrence of the schedule, identified by its UTC instant.
  `last_window_at` is the newest window this schedule has claimed (or
  refused). The claim (`:claim_window`) is a guarded update that matches zero
  rows when the window is already claimed, the schedule is paused, or it was
  rebaselined after the window; it runs inside the backup lock transaction
  together with the Lock write and the `Oban.insert/2` it decides on, so a
  window fires at most once however many nodes tick
  (`KilnCMS.Backups.Chain.request/1`).

  `baseline_at` is when the schedule's timing last changed (creation, an edit
  of its interval, time, zone, start date or components, a resume), taken from
  the node clock that also computes the windows. No window before it fires,
  so editing a schedule never fires a window it did not have before the edit.

  `last_outcome` is what the last window's request did: `:started`, `:queued`,
  `:folded`, `:deferred` (another kind of request was queued, #2540, or the
  node that ticked can't run backups; retried each minute and noted once per
  window in `last_deferred_window_at`) or `:refused` (`BACKUP_ENABLED=false`,
  or a media-only schedule with no media directory; the window is claimed so
  nothing retries it).

  ## Instance-wide, platform admins only

  The backup directory belongs to the instance, so there is no `multitenancy`
  block, and people are gated on the global role
  (`KilnCMS.Accounts.Checks.PlatformAdmin`), never `OrgAdmin`. A platform admin
  reads, creates, updates and destroys schedules (audited in the instance
  security log). The window writes are the `:backups` system actor's alone:
  no person can claim, refuse or defer a window, and `:create`/`:update`
  accept none of `baseline_at`, the `last_*` fields or the keep fields. Not
  exposed through JSON:API, GraphQL or MCP.

  ## Atoms

  `components`, `interval` and `last_outcome` are `KilnCMS.Types.KnownAtom`.
  For `interval` and `components` that is a deliberate exception to that
  type's rule (written only by code): a platform admin chooses them. A value a
  newer release wrote loads as `KilnCMS.Types.UnknownAtom`; the window
  computation treats such a schedule as invalid (skipped and reported), and an
  edit form must handle it.

  ## Intervals

  Every 2, 4, 8 or 12 hours, daily, weekly, fortnightly or monthly. Until keep
  N retention exists (#2219, part 3), sub-daily intervals are refused when a
  schedule is created or its interval changed: every run is a full set, and
  retention caps by age, not by count (beyond the recovery points and newest
  backups it keeps), so a two-hourly schedule would keep about
  `12 × BACKUP_KEEP_DAYS` sets of each component.

  ## Keep fields

  `keep_count` and `keep_days` are stored for #2219 part 3 and not used yet:
  no action accepts them, and retention is `BACKUP_KEEP_DAYS` for every
  backup.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Backups.Schedule.{Audit, Changes, Validations}

  @intervals [
    :every_2h,
    :every_4h,
    :every_8h,
    :every_12h,
    :daily,
    :weekly,
    :fortnightly,
    :monthly
  ]

  @sub_daily [:every_2h, :every_4h, :every_8h, :every_12h]

  @outcomes [:started, :queued, :folded, :deferred, :refused]

  @editable [:components, :interval, :time_of_day, :starts_on, :time_zone, :enabled]

  postgres do
    table "backup_schedules"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @editable

      change Changes.Normalize
      change Changes.SetBaseline
      validate Validations.KnownZone
      validate Validations.IntervalAvailable
      validate Validations.MediaAvailable

      change {KilnCMS.Security.Changes.Record,
              type: :backup_schedule_created,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.created/2}
    end

    # The timing fields compared by value: an edit that resubmits them
    # unchanged neither rebaselines nor records a `changed` event.
    update :update do
      primary? true
      accept @editable
      require_atomic? false

      change Changes.Normalize
      change Changes.Rebaseline
      validate Validations.KnownZone
      validate Validations.IntervalAvailable
      validate Validations.MediaAvailable

      change {KilnCMS.Security.Changes.Record,
              type: :backup_schedule_changed,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.changed/2,
              when: &Audit.changed?/2}
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {KilnCMS.Security.Changes.Record,
              type: :backup_schedule_deleted,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.deleted/2}
    end

    # The window claim, inside the backup lock transaction. Zero rows (the
    # window taken by another node, the schedule paused or rebaselined
    # meanwhile) is a `StaleRecord` error the caller turns into a rollback.
    update :claim_window do
      accept []
      require_atomic? true

      argument :window_at, :utc_datetime_usec, allow_nil?: false

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:started, :queued, :folded]
      end

      change filter(
               expr(
                 enabled == true and baseline_at <= ^arg(:window_at) and
                   (is_nil(last_window_at) or last_window_at < ^arg(:window_at))
               )
             )

      change atomic_update(:last_window_at, expr(^arg(:window_at)))
      change set_attribute(:last_outcome, arg(:outcome))
      change set_attribute(:last_error, nil)
      change set_attribute(:last_outcome_at, &DateTime.utc_now/0)
    end

    # A window that can't run here (backups disabled, no media directory):
    # claimed as refused, so no tick asks again until the next window.
    update :refuse_window do
      accept []
      require_atomic? true

      argument :window_at, :utc_datetime_usec, allow_nil?: false
      argument :reason, :string, allow_nil?: false

      change filter(
               expr(
                 enabled == true and baseline_at <= ^arg(:window_at) and
                   (is_nil(last_window_at) or last_window_at < ^arg(:window_at))
               )
             )

      change atomic_update(:last_window_at, expr(^arg(:window_at)))
      change set_attribute(:last_outcome, :refused)
      change set_attribute(:last_outcome_at, &DateTime.utc_now/0)
      change Changes.SetLastError
    end

    # A window whose request was refused for now (a queued Resume, #2540, or a
    # node without `pg_dump`, `pg_restore` or a database URL): it
    # stays due, and is asked for again on the next tick. Zero rows means it
    # was already noted for this window (or claimed meanwhile): the caller
    # logs only the first. Never touches `last_window_at`.
    update :note_deferred do
      accept []
      require_atomic? true

      argument :window_at, :utc_datetime_usec, allow_nil?: false
      argument :reason, :string, allow_nil?: false

      change filter(
               expr(
                 enabled == true and baseline_at <= ^arg(:window_at) and
                   (is_nil(last_window_at) or last_window_at < ^arg(:window_at)) and
                   (is_nil(last_deferred_window_at) or
                      last_deferred_window_at < ^arg(:window_at))
               )
             )

      change atomic_update(:last_deferred_window_at, expr(^arg(:window_at)))
      change set_attribute(:last_outcome, :deferred)
      change set_attribute(:last_outcome_at, &DateTime.utc_now/0)
      change Changes.SetLastError
    end
  end

  policies do
    # Instance-wide and tenant-less: the global role, never `OrgAdmin`. The
    # scheduler and the backup status read as the `:backups` system actor.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # A platform admin manages schedules; the pipeline never does.
    policy action([:create, :update, :destroy]) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # The window writes: the `:backups` system actor alone, so no person (a
    # platform admin included) can mark a window claimed, refused or waiting.
    policy action([:claim_window, :refuse_window, :note_deferred]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    uuid_primary_key :id

    # What each window backs up; de-duplicated and in
    # `KilnCMS.Backups.Lock.components/0` order (`Changes.Normalize`).
    attribute :components, {:array, KilnCMS.Types.KnownAtom} do
      allow_nil? false
      constraints items: [one_of: [:db, :media]], min_length: 1
      public? true
    end

    attribute :interval, KilnCMS.Types.KnownAtom do
      allow_nil? false
      constraints one_of: @intervals
      public? true
    end

    # Local wall time in `time_zone`, to the minute. A sub-daily interval's
    # slots are this time plus multiples of the interval, modulo a day.
    attribute :time_of_day, :time do
      allow_nil? false
      public? true
    end

    # A local date in `time_zone`. Nothing fires before it; weekly and
    # fortnightly take their weekday (and fortnightly its week parity) from
    # it, monthly its day of the month (clamped to the month's end).
    attribute :starts_on, :date do
      allow_nil? false
      public? true
    end

    attribute :time_zone, :string do
      allow_nil? false
      default "Etc/UTC"
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    # Stored for #2219 part 3 (keep N); no action accepts them yet.
    attribute :keep_count, :integer do
      constraints min: 1, max: 1000
      public? true
    end

    attribute :keep_days, :integer do
      constraints min: 1, max: 3650
      public? true
    end

    # Node clock (the clock windows are computed with), never SQL `now()`.
    attribute :baseline_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_window_at, :utc_datetime_usec, public?: true

    attribute :last_outcome, KilnCMS.Types.KnownAtom do
      constraints one_of: @outcomes
      public? true
    end

    attribute :last_outcome_at, :utc_datetime_usec, public?: true

    # Redacted and capped by `Changes.SetLastError` on every write.
    attribute :last_error, :string do
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    attribute :last_deferred_window_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  @doc "Every interval a schedule may have, shortest first."
  @spec intervals() :: [atom()]
  def intervals, do: @intervals

  @doc "The intervals refused until keep N retention exists (#2219, part 3)."
  @spec sub_daily_intervals() :: [atom()]
  def sub_daily_intervals, do: @sub_daily

  @doc "Every `last_outcome`."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes
end
