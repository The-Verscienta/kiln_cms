defmodule KilnCMS.Accounts.OrgMembership do
  @moduledoc """
  A user's membership in an organization, carrying their **per-org** authoring
  role and read scope (epic #336).

  Users stay global (one account, usable across orgs); this join is where a
  user's effective role in a *given* org lives. The fields mirror the ones
  currently on `KilnCMS.Accounts.User` (`role`, `audiences`, `editable_types`)
  so a later PR can move the authorization source from the user onto the
  membership without another migration — for now they are populated (the
  backfill copies each user's `users.role` into their default-org membership)
  but the content policies still read the user's own `role` until that RBAC
  rewiring lands.

  The join itself is global (not tenant-scoped): it is queried by
  `organization_id`/`user_id` to build the org switcher and, later, to resolve a
  user's role for the request's tenant.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "org_memberships"
    repo KilnCMS.Repo

    references do
      # A membership is meaningless without its org/user — clean up on delete.
      reference :organization, on_delete: :delete
      reference :user, on_delete: :delete
    end

    # The unique identity is `(user_id, organization_id)` (user_id-leading), which
    # can't serve `organization_id`-only lookups — the `:for_org` read and the
    # org-delete cascade both probe by `organization_id` alone. Postgres doesn't
    # auto-index FK columns, so add one to avoid a sequential scan.
    custom_indexes do
      index [:organization_id]
    end
  end

  actions do
    defaults [:read, :create, :destroy]

    # Explicit (not a default) so the grant-shape validation — which inspects
    # the whole map and has no atomic expression — can run.
    update :update do
      primary? true
      require_atomic? false
    end

    default_accept [
      :organization_id,
      :user_id,
      :role,
      :audiences,
      :editable_types,
      :readable_types,
      :field_grants
    ]

    read :for_user do
      description "The orgs a user belongs to (backs the org switcher)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :for_org do
      description "The members of an org (backs per-org RBAC administration)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
    end
  end

  policies do
    # Managing memberships is a platform-operator task for now — admins only.
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # A user may read their own memberships (to populate their org switcher).
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Creating/changing/removing memberships is admin-only. Scoped to write
    # actions ONLY — a bare `policy always()` would also match `:read` and, since
    # Ash AND-combines every applicable policy, would nullify the self-read grant
    # above (a hard forbid, not a filter).
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  validations do
    # A malformed grant map must fail on the admin's write, not crash the
    # editor's next save (see the validation module).
    validate KilnCMS.Accounts.Validations.FieldGrantsShape, on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    # The per-org authoring role (mirrors `User.role`). Least-privileged default.
    attribute :role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      default :viewer
      allow_nil? false
      public? true
    end

    # The per-org read axis (mirrors `User.audiences` — see KilnCMS.CMS.Audiences).
    attribute :audiences, {:array, :atom} do
      constraints items: [one_of: KilnCMS.CMS.Audiences.all()]
      default []
      allow_nil? false
      public? false
    end

    # The per-org authoring scope (mirrors `User.editable_types`, #332). Empty
    # means no restriction.
    attribute :editable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # The per-org editorial read scope (mirrors `User.readable_types`, #332
    # phase 2). Empty means no restriction. A non-empty value here wins over
    # the user column for this org (see KilnCMS.Accounts.Scoping).
    attribute :readable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # The per-org per-field write grants (mirrors `User.field_grants`, #332
    # slice 3). Empty means no restriction; a non-empty map wins wholesale
    # over the user column for this org (see KilnCMS.Accounts.Scoping).
    attribute :field_grants, :map do
      default %{}
      allow_nil? false
      public? false
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    # One membership row per (user, org).
    identity :unique_membership, [:user_id, :organization_id]
  end
end
