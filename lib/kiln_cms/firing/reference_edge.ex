defmodule KilnCMS.Firing.ReferenceEdge do
  @moduledoc """
  A firing dependency edge: document `from` embeds data owned by document `to`
  (Kiln v2 — decision D13). Rebuilt every time the *referrer* fires. When `to`
  changes, its referrers' fired artifacts are stale, so firing is a graph walk —
  these edges drive the re-fire wave (`KilnCMS.Firing.References`).
  """
  use Ash.Resource,
    domain: KilnCMS.Firing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "reference_edges"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :from_source do
      argument :from_type, :atom, allow_nil?: false
      argument :from_id, :uuid, allow_nil?: false
      filter expr(from_type == ^arg(:from_type) and from_id == ^arg(:from_id))
    end

    read :to_target do
      argument :to_type, :atom, allow_nil?: false
      argument :to_id, :uuid, allow_nil?: false
      filter expr(to_type == ^arg(:to_type) and to_id == ^arg(:to_id))
    end

    create :upsert do
      upsert? true
      upsert_identity :edge
      accept [:from_type, :from_id, :to_type, :to_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :from_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:page, :post]],
      public?: true

    attribute :from_id, :uuid, allow_nil?: false, public?: true

    attribute :to_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:page, :post]],
      public?: true

    attribute :to_id, :uuid, allow_nil?: false, public?: true
  end

  identities do
    identity :edge, [:from_type, :from_id, :to_type, :to_id]
  end
end
