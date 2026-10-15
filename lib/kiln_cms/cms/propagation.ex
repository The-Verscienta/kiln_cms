defmodule KilnCMS.CMS.Propagation do
  @moduledoc """
  One **propagation record** per publish or withdrawal of a document (#1927):
  when the transition happened, what became of the CDN purge it enqueued, and
  how long its webhook endpoints took to hear about it.

  The record is opened by the webhook fan-out (`KilnCMS.Webhooks.dispatch/4`)
  with the number of endpoints the transition was sent to, and every delivery
  of it (`KilnCMS.CMS.WebhookDelivery.propagation_id`) points back here. It is
  settled by `KilnCMS.Propagation` once every one of those deliveries is
  terminal (delivered or given up on) and the CDN purge, if one was enqueued,
  has been acknowledged or has failed. Settling stamps the latencies and emits
  `[:kiln_cms, :propagation, :complete]`. See `KilnCMS.Propagation` for what
  counts as a transition and how the latencies are measured.

  Written by system code only (the webhook pipeline and the CDN purge worker);
  admin-only to read. Pruned after `retention_days/0` by a nightly trigger:
  the record is a measurement, and the number it feeds is a rolling window.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  @retention_days Application.compile_env(:kiln_cms, [:propagation, :retention_days], 90)

  @doc "Days a propagation record is kept before the nightly prune."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  admin do
    resource_group :system
    table_columns [:kind, :event, :transitioned_at, :endpoint_latency_ms, :completed_at]
  end

  postgres do
    table "propagations"
    repo KilnCMS.Repo

    custom_indexes do
      # `KilnCMS.Propagation.percentiles/2`: completed records of one kind in a
      # window, per site.
      index [:org_id, :kind, :completed_at]
    end
  end

  oban do
    use_tenant_from_record? true

    triggers do
      trigger :prune_propagations do
        action :destroy
        queue :default
        scheduler_cron "35 3 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds

        where expr(transitioned_at <= ago(^@retention_days, :day))

        worker_read_action :read
        worker_module_name KilnCMS.CMS.Propagation.Workers.PrunePropagations
        scheduler_module_name KilnCMS.CMS.Propagation.Schedulers.PrunePropagations
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    # Opened by the webhook fan-out, as the transition is dispatched.
    create :open do
      primary? true

      accept [
        :kind,
        :event,
        :document_type,
        :document_id,
        :transitioned_at,
        :endpoints_expected,
        :cdn_status,
        :cdn_enqueued_at
      ]
    end

    # The CDN purge covering this record answered (or gave up).
    update :settle_cdn do
      accept [:cdn_status, :cdn_settled_at]
    end

    # Every delivery is terminal and the purge is not pending. Once only: the
    # filter makes a second settle (two deliveries finishing together) a no-op
    # rather than a second stamp and a second telemetry event.
    update :complete do
      accept [:completed_at, :endpoint_latency_ms, :cdn_latency_ms, :endpoints_failed]
      change filter(expr(is_nil(completed_at)))
    end

    # Completed records of `kind` settled since `since`: the window
    # `KilnCMS.Propagation.percentiles/2` measures.
    read :completed_since do
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:publish, :withdraw]]
      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               kind == ^arg(:kind) and not is_nil(completed_at) and
                 completed_at >= ^arg(:since)
             )
    end

    # Records of `kind` opened since `since` and not yet settled.
    read :open_since do
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:publish, :withdraw]]
      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               kind == ^arg(:kind) and is_nil(completed_at) and
                 transitioned_at >= ^arg(:since)
             )
    end
  end

  policies do
    # The prune trigger runs as a system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Admin-only to read. The webhook pipeline opens a record and settles it;
    # the CDN purge worker records the purge half, and settling stays with the
    # pipeline (it counts the record's deliveries, which only `:webhooks` may
    # read). Neither may destroy one:
    # the nightly trigger above prunes.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin

      forbid_unless action([:read, :completed_since, :open_since, :open, :settle_cdn, :complete])

      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :webhooks,
                    action: [:read, :completed_since, :open_since, :open, :settle_cdn, :complete]}

      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :cdn, action: [:read, :settle_cdn]}
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

    # `:publish` (the document went on the delivery path) or `:withdraw` (it
    # came off it: unpublished, or trashed while live).
    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:publish, :withdraw]
    end

    # The event as dispatched (`page.unpublished`).
    attribute :event, :string do
      allow_nil? false
      public? true
      constraints max_length: KilnCMS.Limits.identifier()
    end

    attribute :document_type, :string do
      allow_nil? false
      public? true
      constraints max_length: KilnCMS.Limits.identifier()
    end

    attribute :document_id, :uuid, allow_nil?: false, public?: true

    # When the transition was dispatched: just after its write committed.
    attribute :transitioned_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # How many webhook endpoints the transition was sent to.
    attribute :endpoints_expected, :integer, allow_nil?: false, default: 0, public?: true

    # The CDN purge: `:not_configured` (no purge URL, or nothing to purge),
    # `:pending`, then `:acknowledged` (a 2xx) or `:failed` (gave up).
    attribute :cdn_status, :atom do
      allow_nil? false
      default :not_configured
      public? true
      constraints one_of: [:not_configured, :pending, :acknowledged, :failed]
    end

    attribute :cdn_enqueued_at, :utc_datetime_usec, public?: true
    attribute :cdn_settled_at, :utc_datetime_usec, public?: true

    # Stamped once, when the record settles.
    attribute :completed_at, :utc_datetime_usec, public?: true

    # Transition to the last endpoint's 2xx. Nil when there were no endpoints
    # or any of them was given up on: then there is no "last endpoint
    # delivered" to measure, and `endpoints_failed` says why.
    attribute :endpoint_latency_ms, :integer, public?: true

    # Transition to the CDN's acknowledgement. Nil unless acknowledged.
    attribute :cdn_latency_ms, :integer, public?: true

    attribute :endpoints_failed, :integer, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :deliveries, KilnCMS.CMS.WebhookDelivery do
      destination_attribute :propagation_id
      public? true
    end
  end

  aggregates do
    count :deliveries_succeeded, :deliveries do
      filter expr(status == :succeeded)
      public? true
    end

    count :deliveries_failed, :deliveries do
      filter expr(status == :failed)
      public? true
    end

    max :last_delivered_at, :deliveries, :delivered_at do
      public? true
    end
  end
end
