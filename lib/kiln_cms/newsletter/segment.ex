defmodule KilnCMS.Newsletter.Segment do
  @moduledoc """
  A named group of newsletter subscribers — the "send this to audience X" axis.

  Distinct from `KilnCMS.CMS.Audiences` (a compile-time enum that gates
  signed-in *read* access to published content): a segment is a data-defined
  grouping of external subscribers. It may optionally *reference* an audience
  (`audience`) as a label, but membership lives in the join table, not the
  read-axis. Admin-managed.
  """
  use Ash.Resource,
    domain: KilnCMS.Newsletter,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :system
    table_columns [:name, :slug, :audience, :inserted_at]
  end

  postgres do
    table "newsletter_segments"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :description, :audience]
    end

    update :update do
      primary? true
      accept [:name, :slug, :description, :audience]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # Optional label linking this segment to a consumer-facing audience tier.
    # Not an access boundary — just metadata (and a Phase 2 seam for paid tiers).
    attribute :audience, :atom do
      constraints one_of: KilnCMS.CMS.Audiences.all()
      public? true
    end

    timestamps()
  end

  relationships do
    many_to_many :subscribers, KilnCMS.Newsletter.Subscriber do
      through KilnCMS.Newsletter.SegmentMembership
      source_attribute_on_join_resource :segment_id
      destination_attribute_on_join_resource :subscriber_id
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
