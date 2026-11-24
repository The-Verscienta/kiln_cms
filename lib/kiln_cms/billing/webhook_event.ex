defmodule KilnCMS.Billing.WebhookEvent do
  @moduledoc """
  One inbound provider webhook, recorded before it is processed.

  This row **is** the idempotency lock. The receiver inserts it first; the unique
  identity on `{provider, provider_event_id}` means a concurrent duplicate
  delivery loses the race and does not insert a second row. The worker then
  claims the row atomically, so an Oban re-execution after a crash cannot
  process it twice either.

  ## Recorded and enqueued atomically (#2748)

  `:receive` inserts the row **and** the `KilnCMS.Billing.WebhookWorker` job in
  one transaction. If the enqueue fails the row rolls back with it, the receiver
  answers 500 and the provider's redelivery starts from scratch. A row therefore
  never exists without a job having been created for it; `:received` means "a
  job was enqueued".

  ## Status lifecycle

  | Status | Meaning | Redelivery |
  |---|---|---|
  | `:received` | recorded, job enqueued | re-enqueues (unique job: no-op while one is pending) |
  | `:processing` | claimed by a worker | re-enqueues only once the claim is older than `reclaim_after_ms/0` |
  | `:failed` | last attempt errored | re-enqueues |
  | `:processed` / `:ignored` | settled | acked, nothing enqueued |

  `gave_up_at` is not a status: it marks an unsettled row (`:received` or
  `:failed`) the sweeper below stopped retrying. A claim clears it.

  `:claim` accepts `:received` and `:failed`, and also a `:processing` row whose
  `updated_at` (which the claim bumped) is older than `reclaim_after_ms/0`: a
  worker that died mid-run (node kill, an exception that escaped) must not strand
  the event. The age test is part of the claim's single filtered `UPDATE`, so two
  workers can never both win a reclaim. The threshold is deliberately longer than
  the worker's 3-minute run timeout, so a live run is never reclaimed.

  ## The sweeper (#3159)

  Three windows leave an unsettled row with no job, and the provider will not
  redeliver an event it saw acknowledged: a `:received` row recorded before
  enqueue became atomic (or whose job was lost), a `:failed` row whose job used
  its `max_attempts`, and a `:processing` row whose settle stamp did not save.
  Two AshOban triggers look every ten minutes (`stranded?`). They run on their
  own `:billing_sweeper` queue: a node of the previous release polls
  `:default` and has no worker module for their jobs.

    * `:redrive` re-enqueues the event and counts it in `redrive_count`. A
      `:received` row is left alone for `received_grace_minutes/0`, and any row
      with a job that will run is left alone (for `:processing`, a job that is
      only `executing` does not count: a dead node's job stays that way until
      `Oban.Lifeline` rescues it, 180 minutes later). A stale `:processing` row
      is released to `:failed` so the new job's claim succeeds.
    * `:give_up` stamps `gave_up_at`, logs at `error` and emits
      `[:kiln_cms, :billing, :webhook_event, :gave_up]`, once the event has
      been re-enqueued `max_redrives/0` times, is older than
      `redrive_window_days/0`, or has no `redrive_count`. An older event is
      not redriven: applied now it could undo later events, for instance
      re-granting a canceled member whose row has no event stamp for
      `KilnCMS.Billing.EventGuard` to order against. A row with no
      `redrive_count` was recorded before the sweeper existed (`:receive`
      sets it to 0; the column has no default), by an earlier release or by a
      node of the previous release during a rolling deploy. Unsettled, it is
      given up on, not replayed, for the same reason, however young.

  The window is not a hard cutoff on when an event is applied. A redrive just
  inside `redrive_window_days/0` enqueues a job with the worker's full
  `max_attempts` (8, about 15 hours of backoff), so a redriven event can still
  be applied about 3.6 days after it was received. And a job orphaned
  `executing` by a dead node is rescued by `Oban.Lifeline` (180 minutes)
  whatever the row's `gave_up_at`, so it can still claim and apply an event
  the sweeper has given up on.

  A given-up event waits for an operator to fix the cause and resend it from
  the provider's dashboard (`WHERE gave_up_at IS NOT NULL` lists them). The
  resend's claim clears `gave_up_at` but keeps `redrive_count`, so an event
  that fails again goes straight back to give-up.

  A reclaimed event is re-applied from the start. If the first run had already
  committed its membership transition before dying, the replay appends a second
  `MembershipEvent` for an unchanged status. Entitlements are recomputed from
  state, so access is not double-granted; ordering and replay guards are #2749's.

  ## Deliberately tenant-less

  There is **one provider account per instance** (see
  `KilnCMS.Billing.Settings`), so `provider_event_id` is a single global
  namespace. Were this resource org-scoped, the dedupe identity would gain
  `org_id` per the #336 convention — and a replayed event that resolved to a
  *different* org, which is exactly what a metadata bug produces, would insert a
  second row and process twice. Tenant-less keeps the identity global, which is
  the property idempotency actually needs. `org_id` is kept as a plain
  informational column for the console.

  Because it is tenant-less, reads gate on the **global** `User.role` rather than
  `Checks.OrgAdmin` — the same rule as `KilnCMS.Mail.Settings`.

  Payloads carry customer emails and amounts. `:purgeable` selects settled rows
  past a cutoff for a retention purge, but nothing calls it yet: rows are kept
  until one exists.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  @statuses [:received, :processing, :processed, :failed, :ignored]

  # How long a `:processing` claim may sit before another worker may take it over.
  # Must stay strictly above `WebhookWorker.timeout/1` (a test pins it).
  @reclaim_after :timer.minutes(10)
  @statuses_sql Enum.map_join(@statuses, ", ", &"'#{&1}'")

  # The sweeper (#3159). A `:received` row younger than this is left to the job
  # its `:receive` enqueued.
  @received_grace_minutes 10
  # Only events this recent are replayed: the provider's own retry window. An
  # older event applied now could undo what later events did (a stale
  # `subscription.updated active` re-granting a canceled member whose row has
  # no event stamp), so it is given up on instead.
  @redrive_window_days 3
  # Re-enqueues per event before the sweeper gives up and asks for an operator.
  @max_redrives 3

  postgres do
    table "billing_webhook_events"
    repo KilnCMS.Repo

    check_constraints do
      check_constraint :status, "billing_webhook_events_status_must_be_known",
        check: "status IN (#{@statuses_sql})"

      check_constraint :provider, "billing_webhook_events_provider_must_be_known",
        check: "provider IN ('stripe')"
    end

    custom_indexes do
      # The sweeper's scan (#3159): only unsettled rows, which stay few while
      # settled ones pile up. The predicate is the triggers' status set.
      index [:status, :inserted_at],
        where: "status IN ('received', 'processing', 'failed')",
        concurrently: true
    end
  end

  # The sweeper (#3159): every ten minutes, an unsettled event that nothing will
  # process is re-enqueued (`:redrive`) or, once it is too old or has been
  # re-enqueued `@max_redrives` times, given up on (`:give_up`). Both actions
  # are atomic, so AshOban's worker runs each as a bulk `UPDATE` over the
  # trigger's `where`: a row that settled or got a job between the scan and the
  # write matches nothing and the job completes having written nothing. Each
  # action also filters on that `where` (ADR 0074), so a direct call on a row
  # that does not match fails with a lone `StaleRecord`.
  oban do
    triggers do
      trigger :redrive do
        action :redrive
        queue :billing_sweeper
        scheduler_cron "*/10 * * * *"
        max_attempts 3
        worker_read_action :read

        where expr(redrive_due?)

        worker_module_name KilnCMS.Billing.WebhookEvent.AshOban.Worker.Redrive
        scheduler_module_name KilnCMS.Billing.WebhookEvent.AshOban.Scheduler.Redrive
      end

      trigger :give_up do
        action :give_up
        queue :billing_sweeper
        scheduler_cron "*/10 * * * *"
        max_attempts 3
        worker_read_action :read

        where expr(give_up_due?)

        worker_module_name KilnCMS.Billing.WebhookEvent.AshOban.Worker.GiveUp
        scheduler_module_name KilnCMS.Billing.WebhookEvent.AshOban.Scheduler.GiveUp
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    # Record and enqueue in ONE transaction (#2748): `Oban.insert` shares the
    # action's connection, so a failed enqueue rolls the row back and the
    # provider's retry starts clean. Recording first and enqueuing separately
    # left a `:received` row nothing would ever process.
    create :receive do
      accept [:provider, :provider_event_id, :type, :payload]

      # The sweeper replays only rows whose count is set (#3159). The column
      # has no default, so a row recorded before the sweeper, or by a node
      # still on the previous release, is null and given up on, never replayed.
      change set_attribute(:redrive_count, 0)

      change after_action(fn _changeset, record, _context ->
               case KilnCMS.Billing.WebhookWorker.enqueue(record) do
                 {:ok, _job} -> {:ok, record}
                 {:error, reason} -> {:error, reason}
               end
             end)
    end

    # Atomic claim: a filtered update. Oban can execute a job more than once (a
    # crash between execution and ack), so the worker claims before doing anything;
    # zero rows updated means someone else already has it (a `StaleRecord`) and
    # the job cancels.
    #
    # `:failed` is claimable as well as `:received`, so an Oban RETRY after a
    # transient provider failure can pick the event back up. A `:processing` row
    # is claimable too once it is older than `@reclaim_after`: its worker died
    # (#2748) and nobody else will ever settle it. The age test lives in the same
    # `UPDATE ... WHERE` as the status test, so concurrent reclaims have one winner.
    update :claim do
      accept []
      require_atomic? true

      change filter(
               expr(
                 status in [:received, :failed] or
                   (status == :processing and
                      updated_at < ago(^@reclaim_after, :millisecond))
               )
             )

      change set_attribute(:status, :processing)

      # A claim is the event being worked on again (a provider resend reaches
      # it), so a give-up no longer stands. `redrive_count` is kept: an event
      # that fails again goes straight back to give-up.
      change set_attribute(:gave_up_at, nil)

      # A reclaim writes `:processing` over `:processing`, which Ash does not count
      # as a change, so `updated_at` would not move and a second reclaimer would
      # win too. Stamp it explicitly: the claim time IS the staleness clock.
      change atomic_update(:updated_at, expr(now()))
    end

    update :mark_processed do
      accept [:org_id, :membership_id]
      require_atomic? false
      change set_attribute(:status, :processed)
      change set_attribute(:processed_at, &DateTime.utc_now/0)
    end

    update :mark_ignored do
      accept [:error]
      require_atomic? false
      change set_attribute(:status, :ignored)
      change set_attribute(:processed_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      accept [:error]
      require_atomic? false
      change set_attribute(:status, :failed)
    end

    # The sweeper's re-enqueue (#3159), run only by its trigger. The filter is
    # the trigger's `where` (ADR 0074). A stale `:processing` row is released
    # to `:failed`: this write bumps `updated_at`, which is `:claim`'s
    # staleness clock, so left `:processing` the new job's claim would miss
    # for another `@reclaim_after`. The job is inserted in this transaction,
    # as `:receive` does.
    update :redrive do
      accept []
      require_atomic? true

      change filter(expr(redrive_due?))
      change atomic_update(:redrive_count, expr(redrive_count + 1))
      change atomic_update(:status, expr(if status == :processing, do: :failed, else: status))
      change KilnCMS.Billing.Changes.RedriveWebhookEvent
    end

    # The sweeper's last word on an event (#3159): stamped, logged at `error`
    # and reported by telemetry, so an operator resends it from the provider's
    # dashboard. The filter is the trigger's `where`. A stale `:processing` row
    # is released to `:failed` so the console does not show it in flight.
    update :give_up do
      accept []
      require_atomic? true

      change filter(expr(give_up_due?))
      change atomic_update(:gave_up_at, expr(now()))
      change atomic_update(:status, expr(if status == :processing, do: :failed, else: status))
      change KilnCMS.Billing.Changes.ReportWebhookEventGivenUp
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    read :by_event_id do
      get? true
      argument :provider_event_id, :string, allow_nil?: false
      filter expr(provider_event_id == ^arg(:provider_event_id))
    end

    # Retention: processed/ignored rows older than the cutoff. Failed rows are
    # retained until an operator has looked at them.
    read :purgeable do
      argument :before, :utc_datetime_usec, allow_nil?: false
      filter expr(status in [:processed, :ignored] and inserted_at < ^arg(:before))
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Instance-wide resource with no `multitenancy` block, so the gate is the
    # global role — an `OrgAdmin` check would resolve a tenant-less subject to the
    # default org (the `KilnCMS.Mail.Settings` hazard).
    #
    # The webhook worker re-reads its event by id as the billing system actor
    # (#1659), narrowed to the plain `:read`: listing (`:recent`), dedupe
    # lookups (`:by_event_id`) and the retention read stay platform-admin.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      forbid_unless action(:read)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :billing}
    end

    # Closed to every person. The receiver records an event `authorize?: false`
    # (a webhook has no actor; the provider's HMAC is the grant). The worker's
    # claim and settle steps are the system actor's, by name (#1659); it may
    # not `:receive` an event or `:destroy` one. The sweeper's `:redrive` and
    # `:give_up` (#3159) are its triggers' alone, through the bypass above.
    policy action_type([:create, :update, :destroy]) do
      forbid_unless action([:claim, :mark_processed, :mark_ignored, :mark_failed])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :billing}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      default :stripe
      constraints one_of: [:stripe]
      public? true
    end

    attribute :provider_event_id, :string do
      allow_nil? false
      public? true
    end

    attribute :type, :string do
      allow_nil? false
      public? true
    end

    # The verified event, kept for diagnosis. Contains customer PII; no retention
    # purge runs yet (`:purgeable` has no caller).
    attribute :payload, :map, allow_nil?: false, default: %{}, public?: false

    attribute :status, :atom do
      allow_nil? false
      default :received
      constraints one_of: @statuses
      public? true
    end

    # Informational only — NOT a tenant attribute. Stamped once the event resolves
    # to an organization, so the console can show where it landed.
    attribute :org_id, :uuid, public?: false
    attribute :membership_id, :uuid, public?: false

    attribute :error, :string, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true

    # How many times the sweeper has re-enqueued this event (#3159). Never reset:
    # a resent event that keeps failing goes back to give-up, not round again.
    #
    # `:receive` sets it to 0. Null marks a row recorded before the sweeper: by
    # an earlier release, or by a node still on the previous release during a
    # rolling deploy. The column deliberately has no default, so those rows
    # stay null and an unsettled one is given up on, not replayed: nothing
    # tells it apart from an event the membership's ordering stamp predates.
    # A null row the previous release's own job settles is unaffected.
    attribute :redrive_count, :integer do
      allow_nil? true
      public? false
    end

    # Set when the sweeper gives up on the event: an operator has to look. A
    # claim (a provider resend) clears it.
    attribute :gave_up_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  # The sweeper's predicates (#3159). Each trigger's `where` and its action's
  # filter name the same calculation, so the two cannot drift (ADR 0074).
  calculations do
    # A job for this event that will run, or is running. Assumes Oban's table is
    # the unprefixed `oban_jobs`. `state::text` so the list does not depend on
    # which values this database's `oban_job_state` enum has.
    calculate :has_live_job?,
              :boolean,
              expr(
                fragment(
                  "EXISTS (SELECT 1 FROM oban_jobs AS j WHERE j.worker = 'KilnCMS.Billing.WebhookWorker' AND j.args @> jsonb_build_object('webhook_event_id', (?)::text) AND j.state::text IN ('available', 'scheduled', 'retryable', 'executing', 'suspended'))",
                  id
                )
              ),
              public?: false

    # The same, without `executing`: a node killed mid-run leaves its job
    # `executing` until `Oban.Lifeline` rescues it (180 minutes), so for a stale
    # `:processing` row an executing job is no sign anything will settle it.
    calculate :has_queued_job?,
              :boolean,
              expr(
                fragment(
                  "EXISTS (SELECT 1 FROM oban_jobs AS j WHERE j.worker = 'KilnCMS.Billing.WebhookWorker' AND j.args @> jsonb_build_object('webhook_event_id', (?)::text) AND j.state::text IN ('available', 'scheduled', 'retryable', 'suspended'))",
                  id
                )
              ),
              public?: false

    # Unsettled, not given up on, and nothing will process it:
    #
    #   * `:received` past the grace period with no job (one recorded before
    #     enqueue became atomic, or whose job was lost);
    #   * `:failed` with no job (its job used its `max_attempts`);
    #   * `:processing` past the takeover with no queued job (a settle stamp
    #     that did not save, or a worker that died).
    calculate :stranded?,
              :boolean,
              expr(
                is_nil(gave_up_at) and
                  ((status == :received and
                      inserted_at < ago(^@received_grace_minutes, :minute) and
                      not has_live_job?) or
                     (status == :failed and not has_live_job?) or
                     (status == :processing and
                        updated_at < ago(^@reclaim_after, :millisecond) and
                        not has_queued_job?))
              ),
              public?: false

    calculate :redrive_due?,
              :boolean,
              expr(
                stranded? and not is_nil(redrive_count) and
                  inserted_at > ago(^@redrive_window_days, :day) and
                  redrive_count < ^@max_redrives
              ),
              public?: false

    calculate :give_up_due?,
              :boolean,
              expr(
                stranded? and
                  (is_nil(redrive_count) or
                     inserted_at <= ago(^@redrive_window_days, :day) or
                     redrive_count >= ^@max_redrives)
              ),
              public?: false
  end

  identities do
    identity :unique_provider_event, [:provider, :provider_event_id]
  end

  @doc "Every valid status."
  def statuses, do: @statuses

  @doc "Milliseconds after which a `:processing` claim may be taken over."
  @spec reclaim_after_ms() :: pos_integer()
  def reclaim_after_ms, do: @reclaim_after

  @doc "Re-enqueues the sweeper makes per event before it gives up (#3159)."
  @spec max_redrives() :: pos_integer()
  def max_redrives, do: @max_redrives

  @doc "Days within which the sweeper replays an event; older ones are given up on."
  @spec redrive_window_days() :: pos_integer()
  def redrive_window_days, do: @redrive_window_days

  @doc "Minutes a `:received` event is left to its own job before the sweeper looks."
  @spec received_grace_minutes() :: pos_integer()
  def received_grace_minutes, do: @received_grace_minutes

  @doc """
  Whether a redelivery of this event should enqueue a job: it is not settled, and
  if a worker holds it, that claim is stale. Mirrors the `:claim` filter; the
  claim itself remains the guard against double processing.
  """
  @spec redeliverable?(%__MODULE__{}) :: boolean()
  def redeliverable?(%__MODULE__{status: status}) when status in [:received, :failed], do: true

  def redeliverable?(%__MODULE__{status: :processing, updated_at: updated_at}),
    do: DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) > @reclaim_after

  def redeliverable?(%__MODULE__{}), do: false

  @doc """
  Whether `errors` indicate a duplicate-event conflict on the dedupe identity.

  Matched **structurally**, never on message text — the same discipline the
  newsletter's automation dedupe uses. Note Ash reports a composite-identity
  violation against the identity's *first* field, so both fields are accepted.
  """
  @spec duplicate?(list()) :: boolean()
  def duplicate?(errors) when is_list(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: field} ->
        field in [:provider, :provider_event_id]

      %{constraint_name: "billing_webhook_events_unique_provider_event_index"} ->
        true

      _other ->
        false
    end)
  end
end
