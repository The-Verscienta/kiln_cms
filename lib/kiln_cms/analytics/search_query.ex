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
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "search_queries"
    repo KilnCMS.Repo
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
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Reading analytics is editor/admin only.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Recorded only by the system (`authorize?: false`); never by an external
    # caller.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :query, :string, allow_nil?: false, public?: true
    attribute :locale, :string, allow_nil?: false, default: "en", public?: true
    attribute :count, :integer, default: 1, allow_nil?: false, public?: true
    attribute :result_count, :integer, public?: true
    attribute :last_searched_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_query, [:query, :locale]
  end
end
