defmodule KilnCMS.Analytics.SearchQuery do
  @moduledoc """
  Aggregate counter for a normalized search query (keyed by `query` + `locale`).

  Privacy-first: stores only the query text, its locale, how many times it was
  searched, and the most recent result count — no actor, IP, or other personal
  data. Powers "top queries" and "zero-result queries" (content-gap) reports.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # Retention window (days) before a query row is purged. Although rows carry no
  # actor/IP, the query text itself can contain names, emails, or confidential
  # titles — so it isn't kept indefinitely. Override via
  # `config :kiln_cms, :search_analytics, retention_days: N`.
  @retention_days Application.compile_env(:kiln_cms, [:search_analytics, :retention_days], 90)

  @doc "Configured retention window for recorded search queries, in days."
  def retention_days, do: @retention_days

  postgres do
    table "search_queries"
    repo KilnCMS.Repo
  end

  # Privacy retention (#213): purge query rows last searched longer ago than the
  # retention window. Runs nightly as a trusted system job. Surfaced to editors
  # via the search-palette disclosure (#220).
  oban do
    # The nightly purge scheduler scans globally (`global? true`), while the
    # worker destroys under each row's own `org_id` tenant (epic #336).
    use_tenant_from_record? true

    triggers do
      trigger :purge_expired do
        action :purge_expired
        read_action :expired
        worker_read_action :expired
        queue :default
        scheduler_cron "0 3 * * *"
        where expr(last_searched_at <= ago(@retention_days, :day))

        worker_module_name KilnCMS.Analytics.SearchQuery.AshOban.Worker.PurgeExpired
        scheduler_module_name KilnCMS.Analytics.SearchQuery.AshOban.Scheduler.PurgeExpired
      end
    end
  end

  actions do
    defaults [:read]

    # Record one search. Upserts the per-(query, locale) counter, so the first
    # search inserts a row at 1 and later searches increment atomically while
    # refreshing the latest result count.
    create :record do
      upsert? true
      upsert_identity :unique_query
      upsert_fields [:count, :result_count, :last_searched_at]
      accept [:query, :locale, :result_count]
      change atomic_update(:count, expr(count + 1))
      change set_attribute(:last_searched_at, &DateTime.utc_now/0)
    end

    # Most-searched queries first.
    read :top do
      prepare build(sort: [count: :desc])
    end

    # Queries that returned nothing — i.e. content gaps — most-searched first.
    read :zero_result do
      filter expr(^ref(:result_count) == 0)
      prepare build(sort: [count: :desc])
    end

    # Rows whose most-recent search predates the retention window. Keyset
    # pagination feeds the AshOban `:purge_expired` trigger.
    read :expired do
      description "Query rows last searched before the retention window."
      pagination keyset?: true, required?: false
      filter expr(last_searched_at <= ago(@retention_days, :day))
    end

    # Hard-delete expired rows. Invoked by the nightly `:purge_expired` trigger.
    destroy :purge_expired do
      description "Deletes search-query rows past the retention window."
      change filter(expr(last_searched_at <= ago(@retention_days, :day)))
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # The nightly `:purge_expired` retention trigger reads + destroys as a
    # trusted system job (no actor); let AshOban's scheduler/worker through.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Reading analytics is editor/admin only.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Recorded only by the system (`authorize?: false`); never by an external
    # caller.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): a recorded query belongs to the site it was
  # searched on. `global?: true` keeps the tenant optional; the record write
  # carries the request's org and the upsert identity gains `org_id`.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the request's
    # org) on record, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :query, :string, allow_nil?: false, public?: true
    attribute :locale, :string, allow_nil?: false, default: "en", public?: true
    attribute :count, :integer, default: 1, allow_nil?: false, public?: true
    attribute :result_count, :integer, public?: true
    attribute :last_searched_at, :utc_datetime_usec, public?: true

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
  end

  identities do
    identity :unique_query, [:query, :locale]
  end
end
