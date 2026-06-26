defmodule KilnCMS.Analytics.ContentViewDaily do
  @moduledoc """
  Per-day view counter, the time-series companion to
  `KilnCMS.Analytics.ContentView` (which is totals-only). One row per
  `content_type` + `content_id` + `day`; each view upserts the row, atomically
  incrementing `views`. Still privacy-first — no per-visitor data, just a daily
  aggregate so the dashboard can show 7d/30d trends.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_views_daily"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # Record a single view in its day bucket. Upserts the per-day counter, so
    # the first view of the day inserts a row at 1 and the rest increment.
    create :record do
      upsert? true
      upsert_identity :unique_content_day
      upsert_fields [:views]
      accept [:content_type, :content_id, :day]
      change atomic_update(:views, expr(views + 1))
    end

    # Daily rows on or after `from`, oldest first — the dashboard trend source.
    read :since do
      argument :from, :date, allow_nil?: false
      filter expr(day >= ^arg(:from))
      prepare build(sort: [day: :asc])
    end
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Reading analytics is editor/admin only (mirrors ContentView).
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Recorded only by the system (via `authorize?: false`); never externally.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true
    attribute :day, :date, allow_nil?: false, public?: true

    # Defaults to 1: first view of the day inserts the row, later views hit the
    # upsert's atomic `views + 1`.
    attribute :views, :integer, default: 1, allow_nil?: false, public?: true

    timestamps()
  end

  identities do
    identity :unique_content_day, [:content_type, :content_id, :day]
  end
end
