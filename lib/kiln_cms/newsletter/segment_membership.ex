defmodule KilnCMS.Newsletter.SegmentMembership do
  @moduledoc """
  Join resource linking `KilnCMS.Newsletter.Subscriber` to
  `KilnCMS.Newsletter.Segment` (many-to-many). Admin-managed; deleting either
  side removes the membership.
  """
  use Ash.Resource,
    domain: KilnCMS.Newsletter,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "newsletter_segment_memberships"
    repo KilnCMS.Repo

    references do
      reference :segment, on_delete: :delete
      reference :subscriber, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:segment_id, :subscriber_id]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :segment, KilnCMS.Newsletter.Segment do
      allow_nil? false
      public? true
    end

    belongs_to :subscriber, KilnCMS.Newsletter.Subscriber do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_membership, [:segment_id, :subscriber_id]
  end
end
