defmodule KilnCMS.Accounts.Role do
  @moduledoc """
  A named, admin-defined bundle of granular-RBAC grant axes (#332, slice 4) —
  the Directus-style "custom role".

  A role carries the three scope axes (`editable_types`, `readable_types`,
  `field_grants`) so an admin defines "Blog editor" once and assigns it to
  memberships instead of repeating per-user scope lists. Assignment is
  `OrgMembership.role_id`; resolution (in `KilnCMS.Accounts.Scoping`) is
  membership-attribute → role-attribute → user-column, so a membership can
  still override its role per axis.

  Deliberately **not** a replacement for the capability tier
  (`:admin`/`:editor`/`:viewer` — `User.role`): the tier stays the coarse
  authorization axis the policies check, and the built-ins therefore need no
  seeded rows — a membership without a custom role simply has no extra
  restriction bundle. Roles are org-owned config (like `OrgMembership`, the
  resource itself is not Ash-tenant-scoped; reads go through `:for_org`).
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :system
    table_columns [:name, :description]
  end

  postgres do
    table "roles"
    repo KilnCMS.Repo

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:name, :description, :editable_types, :readable_types, :field_grants]

    create :create do
      primary? true
      accept [:name, :description, :editable_types, :readable_types, :field_grants, :org_id]
    end

    update :update, primary?: true

    read :for_org do
      description "The custom roles defined by an org (backs /editor/team)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(org_id == ^arg(:organization_id))
    end
  end

  policies do
    # Role definition and assignment is org administration — admins only,
    # mirroring OrgMembership. Scoping resolution reads with `authorize?: false`.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    # The owning organization. Accepted on create (the team UI passes the
    # current org — `public?` so it is a valid action input, like
    # OrgMembership's writable organization_id) with the default-org default
    # for tenant-less bootstrap.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      public? true
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # The three grant axes, same shapes and semantics as their
    # User/OrgMembership counterparts (empty = no restriction on that axis).
    attribute :editable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    attribute :readable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    attribute :field_grants, :map do
      default %{}
      allow_nil? false
      public? false
    end

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

  identities do
    # Role names are unique per org.
    identity :unique_name_per_org, [:name, :org_id]
  end
end
