defmodule KilnCMS.Federation.Delivery do
  @moduledoc """
  One attempted delivery of one activity to one follower's inbox (#491).

  The same ledger shape `KilnCMS.CMS.WebhookDelivery` uses, and for the same
  reason: an outbound POST to somebody else's server either happened or it did
  not, and "did it go out?" is the first question anyone asks. The activity is
  stored alongside so a delivery can be inspected — and, later, replayed —
  without reconstructing what the document looked like at the time.

  Pruned on a schedule (`@retention_days`), staggered off
  the webhook ledger's 3:20 sweep so the two do not contend.
  """
  use Ash.Resource,
    domain: KilnCMS.Federation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # A literal, not `KilnCMS.Federation.retention_days()`: the trigger's `where`
  # is compiled into the DSL, so reading it from the domain module would be a
  # compile-time dependency on the very domain this resource belongs to.
  @retention_days 30

  postgres do
    table "federation_deliveries"
    repo KilnCMS.Repo
  end

  oban do
    use_tenant_from_record? true

    triggers do
      trigger :prune_deliveries do
        action :destroy
        queue :default
        scheduler_cron "40 3 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(inserted_at <= ago(^@retention_days, :day))
        worker_read_action :read
        worker_module_name KilnCMS.Federation.Delivery.Workers.PruneDeliveries
        scheduler_module_name KilnCMS.Federation.Delivery.Schedulers.PruneDeliveries
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:follower_id, :inbox_uri, :activity_type, :activity, :document_id]

    create :create do
      primary? true
    end

    update :settle do
      require_atomic? false
      accept [:state, :attempts, :last_status, :last_error]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :follower_id, :uuid, public?: true

    # Denormalized: the follower row may be dropped (a dead instance) while the
    # ledger row survives its retention window, and "delivered to whom" should
    # not become unanswerable because of that.
    attribute :inbox_uri, :string do
      constraints max_length: KilnCMS.Limits.url()
      allow_nil? false
      public? true
    end

    # `Accept` is in the set because a Follow is only honoured once accepted, and
    # that Accept goes out through this same signed, retried, ledgered path.
    attribute :activity_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:create, :update, :delete, :accept]
    end

    attribute :activity, :map do
      allow_nil? false
      public? true
    end

    # The Kiln document this activity is about, for grouping a publish's fan-out.
    attribute :document_id, :uuid, public?: true

    attribute :state, :atom do
      constraints one_of: [:pending, :delivered, :failed]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :attempts, :integer, default: 0, allow_nil?: false, public?: true
    attribute :last_status, :integer, public?: true
    attribute :last_error, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
