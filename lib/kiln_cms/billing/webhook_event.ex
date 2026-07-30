defmodule KilnCMS.Billing.WebhookEvent do
  @moduledoc """
  One inbound provider webhook, recorded before it is processed.

  This row **is** the idempotency lock. The receiver inserts it first; the unique
  identity on `{provider, provider_event_id}` means a concurrent duplicate
  delivery loses the race, gets no Oban job, and is acked with a 200. The worker
  then claims the row atomically, so an Oban re-execution after a crash cannot
  process it twice either.

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

    create :receive do
      accept [:provider, :provider_event_id, :type, :payload]
    end

    # Atomic claim: a filtered update. Oban can execute a job more than once (a
    # crash between execution and ack), so the worker claims before doing anything;
    # zero rows updated means someone else already has it and the job cancels.
    #
    # `:failed` is claimable as well as `:received`, so an Oban RETRY after a
    # transient provider failure can pick the event back up. Without that, the
    # first transient error would strand the event permanently: the retry would
    # find a non-`:received` row and cancel.
    update :claim do
      accept []
      require_atomic? true
      validate attribute_in(:status, [:received, :failed])
      change set_attribute(:status, :processing)
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
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Written only by the receiver and worker, both `authorize?: false`.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
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
