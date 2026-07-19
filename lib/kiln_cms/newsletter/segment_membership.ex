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
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a membership belongs to the same site as its
  # segment and subscriber. `global?: true` keeps the tenant optional.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on create, else
    # the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

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
