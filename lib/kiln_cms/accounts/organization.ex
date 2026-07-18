defmodule KilnCMS.Accounts.Organization do
  @moduledoc """
  A tenant — one isolated site/space in a multi-tenant KilnCMS install
  (epic #336).

  Organizations are the **tenant registry**, so this resource is itself *not*
  multitenant: it is the list of tenants every other tenant-scoped resource is
  partitioned by (via an `org_id` attribute — Ash `:attribute` multitenancy).
  A `slug` is the future subdomain and a `custom_domain` the future vanity host;
  a request's tenant is resolved from one of them by the routing plug (a later
  stacked PR).

  ## The default org (non-breaking rollout)

  Multi-tenancy is introduced in non-strict mode (`global?: true` on the scoped
  resources), so existing single-tenant data and every tenant-less code path
  keep working. All pre-existing rows are backfilled to one well-known
  **default organization** whose id is the fixed sentinel `default_id/0`; that
  same id is the `org_id` attribute default stamped whenever a create runs
  without a tenant. Until the delivery path threads a real tenant (PR 2), this
  is the only org that should exist.

  Implements `Ash.ToTenant` so callers can pass an `%Organization{}` (or a bare
  id) as `tenant:`; for the `:attribute` strategy the tenant value is just the
  `org_id`.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The fixed id of the default org every existing/tenant-less row belongs to.
  # Seeded by the backfill migration and returned as the `org_id` default on
  # tenant-less creates — a constant (not a DB lookup) so it's free per write.
  @default_id "00000000-0000-0000-0000-000000000001"

  @doc "The sentinel id of the default organization (see the module doc)."
  @spec default_id() :: Ash.UUID.t()
  def default_id, do: @default_id

  postgres do
    table "organizations"
    repo KilnCMS.Repo

    # SQL for the partial `:unique_custom_domain` identity (only rows with a
    # vanity host are constrained), so the generated unique index is partial.
    identity_wheres_to_sql unique_custom_domain: "custom_domain IS NOT NULL"
  end

  actions do
    # No `:destroy` — organizations are deliberately NOT deletable in this PR.
    # Content org_id FKs are RESTRICT, but the paper-trail `*_versions` tables
    # carry `org_id` as an FK-less audit column (versions outlive their source by
    # design), so deleting an org whose content was purged would strand version
    # rows pointing at a nonexistent org. Org teardown (which must also reconcile
    # those audit rows) is a later feature; until then an org is permanent.
    defaults [:read]
    default_accept [:name, :slug, :custom_domain, :status]

    create :create do
      primary? true
      # Enforce the staged-rollout invariant: no second org until the delivery
      # path threads a tenant (epic #336). The seeded default org is created by
      # the backfill migration, which bypasses this action.
      validate KilnCMS.Accounts.Validations.MultitenancyEnabled
    end

    update :update, primary?: true

    # Tenant resolution: fetch an org by its subdomain slug (used by the routing
    # plug in a later PR). Present now so the registry is queryable by key.
    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
    end

    # Tenant resolution by vanity host.
    read :by_custom_domain do
      get? true
      argument :custom_domain, :string, allow_nil?: false
      filter expr(custom_domain == ^arg(:custom_domain))
    end
  end

  policies do
    # Provisioning and managing tenants is a platform-operator task — admins
    # only. (A per-org RBAC model, where an org admin manages their own org,
    # arrives with the admin-UI phase; for now `role` is the platform role.)
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # A signed-in user may read the orgs they belong to (backs the org switcher
    # in a later PR). Anonymous callers resolve the tenant by host, not by
    # reading this table, so no public read is exposed.
    policy action_type(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
    end

    # Provisioning/managing tenants is admin-only (covered by the bypass; explicit
    # deny here). Scoped to write actions ONLY — a bare `policy always()` would
    # also match `:read` and, since Ash AND-combines every applicable policy,
    # would nullify the member-read grant above (a hard forbid, not a filter).
    policy action_type([:create, :update]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    # The subdomain label (`acme` → `acme.example.com`) — the primary tenant
    # key. Unique across the install.
    attribute :slug, :string, allow_nil?: false, public?: true

    # Optional vanity host (`www.acme.com`). Unique when set; nil for orgs
    # served only on their subdomain.
    attribute :custom_domain, :string, public?: true

    attribute :status, :atom do
      constraints one_of: [:active, :suspended]
      default :active
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :memberships, KilnCMS.Accounts.OrgMembership do
      destination_attribute :organization_id
    end
  end

  identities do
    identity :unique_slug, [:slug]
    # Partial: only enforce uniqueness on rows that actually set a custom domain,
    # so multiple orgs may share the "no vanity host" (nil) state.
    identity :unique_custom_domain, [:custom_domain], where: expr(not is_nil(custom_domain))
  end
end

defimpl Ash.ToTenant, for: KilnCMS.Accounts.Organization do
  # Every tenant-scoped resource in KilnCMS uses the `:attribute` strategy, so
  # the tenant value is simply the org id.
  def to_tenant(%{id: id}, _resource), do: id
end
