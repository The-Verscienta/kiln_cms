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

  `:claim` accepts `:received` and `:failed`, and also a `:processing` row whose
  `updated_at` (which the claim bumped) is older than `reclaim_after_ms/0`: a
  worker that died mid-run (node kill, an exception that escaped) must not strand
  the event. The age test is part of the claim's single filtered `UPDATE`, so two
  workers can never both win a reclaim. The threshold is deliberately longer than
  the worker's 3-minute run timeout, so a live run is never reclaimed.

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

  Payloads carry customer emails and amounts, so processed rows are purged on a
  retention schedule; failed rows are kept until an operator resolves them.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @statuses [:received, :processing, :processed, :failed, :ignored]

  # How long a `:processing` claim may sit before another worker may take it over.
  # Must stay strictly above `WebhookWorker.timeout/1` (a test pins it).
  @reclaim_after :timer.minutes(10)
  @statuses_sql Enum.map_join(@statuses, ", ", &"'#{&1}'")

  postgres do
    table "billing_webhook_events"
    repo KilnCMS.Repo

    check_constraints do
      check_constraint :status, "billing_webhook_events_status_must_be_known",
        check: "status IN (#{@statuses_sql})"

      check_constraint :provider, "billing_webhook_events_provider_must_be_known",
        check: "provider IN ('stripe')"
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
    # not `:receive` an event or `:destroy` one.
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

    # The verified event, kept for diagnosis. Contains customer PII, hence the
    # retention sweep.
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

    timestamps()
  end

  identities do
    identity :unique_provider_event, [:provider, :provider_event_id]
  end

  @doc "Every valid status."
  def statuses, do: @statuses

  @doc "Milliseconds after which a `:processing` claim may be taken over."
  @spec reclaim_after_ms() :: pos_integer()
  def reclaim_after_ms, do: @reclaim_after

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
