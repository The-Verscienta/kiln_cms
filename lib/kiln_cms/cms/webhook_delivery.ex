defmodule KilnCMS.CMS.WebhookDelivery do
  @moduledoc """
  The **delivery ledger** for outbound webhooks: one row per dispatched
  delivery, updated on every attempt, so admins can see exactly what was
  sent where, what came back, and replay failures (`/editor/webhooks`).

  Lifecycle: created `:pending` when a delivery is enqueued; every worker
  attempt records the attempt count and the last HTTP status / error;
  `:succeeded` on a 2xx, `:failed` once Oban's retries are exhausted (an
  exhausted delivery also counts against the endpoint's
  `consecutive_failures` — see `KilnCMS.Webhooks`). Rows are pruned after
  the retention window by a nightly AshOban trigger.

  Written exclusively by the delivery pipeline (system jobs); admin-only to
  read. Replays create a *new* delivery row, so history stays immutable.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  # Days a delivery row is kept before the nightly prune.
  @retention_days Application.compile_env(:kiln_cms, [:webhooks, :delivery_retention_days], 30)

  @doc "Days delivery history is retained."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  admin do
    resource_group :system
    table_columns [:event, :status, :attempts, :last_status, :inserted_at]
  end

  postgres do
    table "webhook_deliveries"
    repo KilnCMS.Repo

    references do
      # Deleting an endpoint takes its delivery history with it.
      reference :endpoint, on_delete: :delete
    end
  end

  oban do
    # The nightly prune scheduler scans globally (`global? true`), while the
    # prune worker runs under each row's own `org_id` tenant (epic #336) — one
    # site's retention sweep never touches another's ledger.
    use_tenant_from_record? true

    triggers do
      # Nightly ledger prune — delivery history is operational data, not an
      # archive.
      trigger :prune_deliveries do
        action :destroy
        queue :default
        scheduler_cron "20 3 * * *"
        # Strict-tenancy prep (#419): schedulers scan per org, not globally.
        list_tenants KilnCMS.Accounts.ListOrgIds

        where expr(inserted_at <= ago(^@retention_days, :day))

        worker_read_action :read
        worker_module_name KilnCMS.CMS.WebhookDelivery.Workers.PruneDeliveries
        scheduler_module_name KilnCMS.CMS.WebhookDelivery.Schedulers.PruneDeliveries
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:endpoint_id, :event, :payload]
    end

    # One worker attempt's outcome: bump the attempt counter, record what came
    # back, and (on success / exhaustion) settle the status.
    update :record_attempt do
      accept [:status, :attempts, :last_status, :last_error, :delivered_at]
    end

    # Recent history for the admin panel, newest first.
    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 25)
    end
  end

  policies do
    # The prune trigger runs as a system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Delivery history is admin-only; the pipeline writes with authorize?: false.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a delivery belongs to the same site as its
  # endpoint. `global?: true` keeps the tenant optional; the pipeline create
  # (`KilnCMS.Webhooks.enqueue`, `authorize?: false`) carries the endpoint's org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the endpoint's
    # org) on the pipeline create, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The event name as sent (`page.published`, `ping`, …).
    attribute :event, :string, allow_nil?: false, public?: true

    # The payload as dispatched (already serializer-shaped).
    attribute :payload, :map, allow_nil?: false, default: %{}, public?: true

    attribute :status, :atom do
      constraints one_of: [:pending, :succeeded, :failed]
      default :pending
      allow_nil? false
      public? true
    end

    # Attempts made so far (Oban's attempt counter at the last try).
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true

    # The last HTTP status received, if the endpoint responded at all.
    attribute :last_status, :integer, public?: true

    # The last failure, human-readable ("endpoint returned HTTP 500",
    # "delivery failed: timeout", "blocked webhook URL: …").
    attribute :last_error, :string, public?: true

    # When the delivery finally succeeded.
    attribute :delivered_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :endpoint, KilnCMS.CMS.WebhookEndpoint do
      allow_nil? false
      public? true
    end
  end
end
