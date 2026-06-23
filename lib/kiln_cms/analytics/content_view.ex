defmodule KilnCMS.Analytics.ContentView do
  @moduledoc """
  Aggregate view counter for one content item (keyed by `content_type` +
  `content_id`). One row per item; each view upserts the row, atomically
  incrementing `views` and stamping `last_viewed_at`. No per-visitor data is
  stored — see `KilnCMS.Analytics`.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_views"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # Record a single view. Upserts the per-content counter, so the first view
    # inserts a row at 1 and subsequent views increment atomically.
    create :record do
      upsert? true
      upsert_identity :unique_content
      upsert_fields [:views, :last_viewed_at]
      accept [:content_type, :content_id]
      change atomic_update(:views, expr(views + 1))
      change set_attribute(:last_viewed_at, &DateTime.utc_now/0)
    end

    # Most-viewed content first, for the dashboard.
    read :top do
      prepare build(sort: [views: :desc])
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

    # Views are recorded only by the system (the delivery controller, via
    # `authorize?: false`); never by an external caller.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # The content type's atom name as a string (e.g. "page", "post") + the
    # record id. Kept type-agnostic so any content type counts with no wiring.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # Defaults to 1: the first view inserts the row (default applies), and every
    # subsequent view hits the upsert's atomic `views + 1` increment.
    attribute :views, :integer, default: 1, allow_nil?: false, public?: true
    attribute :last_viewed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_content, [:content_type, :content_id]
  end
end
