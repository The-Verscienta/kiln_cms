defmodule KilnCMS.Billing.MembershipTier do
  @moduledoc """
  A paid membership tier: the product an org sells, and the audience it grants.

  "Supporter — $5/mo → audience `:member`". The tier is the product; the
  `audience` is the entitlement. Several tiers may grant the same audience (a
  monthly and an annual plan), which the entitlement recompute handles as a set.

  ## Per-site, unlike credentials

  Tiers are **org-scoped**, so writes gate on `KilnCMS.CMS.Checks.OrgAdmin` —
  correct here precisely *because* this resource has a `multitenancy` block. The
  sibling `KilnCMS.Billing.Settings` is the opposite: an instance-wide singleton
  gating on the global `User.role`. Getting that pair backwards is the hazard
  documented on `KilnCMS.CMS.SiteBranding`.

  ## Money lives in the provider

  We store only `provider_price_id` — a pointer. Amounts, currency, intervals,
  trials and tax are configured in the provider's dashboard, so there is one
  source of truth for money. `price_config` is display copy for the join page and
  is **never** used to charge.

  ## `audience` is immutable after create

  It is accepted on `:create` and not on `:update`, deliberately. The entitlement
  recompute derives "which audiences billing owns" from this table; changing a
  tier's audience would stop the old one being owned while live grants for it
  remained, stranding an entitlement that nothing would ever revoke. Retire a
  tier (`active: false`) and create a new one instead — which also keeps the
  audit trail honest.

  ## Audiences are compile-time

  `KilnCMS.CMS.Audiences` reads `config :kiln_cms, :audiences` via
  `Application.compile_env/3`, so introducing a *new* paid audience needs a
  config change, a recompile, and `mix ash.codegen` + `mix ash.migrate` to move
  the CHECK constraint below. Removing an audience while tiers reference it makes
  those rows unreadable (the atom cast fails), so the console guards reads with
  `KilnCMS.CMS.Audiences.valid?/1` and warns rather than crashing.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.CMS.Audiences

  # Built at compile time from the configured audience list, so the DB constraint
  # and the Ash `one_of` can never disagree.
  @gated_sql Enum.map_join(Audiences.gated(), ", ", &"'#{&1}'")

  postgres do
    table "billing_membership_tiers"
    repo KilnCMS.Repo

    # Same reasoning as `KilnCMS.Mail.Settings`: Ash casts this column to an atom
    # on read, so an out-of-band bad write would crash every read — and here that
    # means the public join page and the paywall, i.e. the revenue path.
    check_constraints do
      check_constraint :audience, "billing_membership_tiers_audience_must_be_gated",
        check: "audience IN (#{@gated_sql})"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :name,
        :slug,
        :description,
        :audience,
        :provider_price_id,
        :price_config,
        :active,
        :position
      ]
    end

    # `:audience` is deliberately absent — see the moduledoc.
    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :slug,
        :description,
        :provider_price_id,
        :price_config,
        :active,
        :position
      ]
    end

    # The tiers the join page offers.
    read :active do
      filter expr(active == true)
      prepare build(sort: [position: :asc, name: :asc])
    end

    # Webhook → tier resolution: an event carries a price id, not our tier id.
    read :by_price do
      get? true
      argument :provider_price_id, :string, allow_nil?: false
      filter expr(provider_price_id == ^arg(:provider_price_id))
    end

    # Every tier on the instance, for `KilnCMS.Billing.Entitlements` to work out
    # which audiences billing owns.
    #
    # `multitenancy :bypass` because `User.audiences` is a single global column, so
    # "is this audience billing-owned?" is an instance-wide question. **Inactive
    # tiers are included on purpose**: if a retired tier's audience stopped
    # counting as billing-owned, the recompute would reclassify it as admin-owned
    # and freeze every existing grant of it permanently, with nothing left to
    # revoke it.
    read :all_for_entitlements do
      multitenancy :bypass
      prepare build(select: [:id, :org_id, :audience])
    end
  end

  policies do
    # Tier names, descriptions and display prices render on the PUBLIC join page
    # and the paywall CTA, so they are public information — the same rationale as
    # `KilnCMS.CMS.SiteBranding` and `KilnCMS.CMS.Redirect`. The read is
    # tenant-scoped, so this exposes only the requesting site's own tiers.
    policy action_type(:read) do
      authorize_if always()
    end

    # Writes are an org-admin act, resolved against the REQUEST's org. No
    # platform-admin bypass is needed: `Scoping.effective_tier/2`'s first clause
    # already returns `:admin` for a platform admin on every org.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    # Every tier gets its auto-maintained newsletter segment (#337 Phase 2), so
    # the segment always exists before a membership on it activates — no admin
    # step to forget. Best-effort: a newsletter bookkeeping failure must not stop
    # an operator creating a tier.
    change after_action(fn _changeset, tier, _context ->
             KilnCMS.Newsletter.TierSync.ensure_segment(tier)
             {:ok, tier}
           end),
           on: [:create, :update]
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336) — same contract as every per-site
    # resource: set from the tenant, never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :slug, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    attribute :description, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # The entitlement this tier grants. The first live call site of
    # `Audiences.gated/0` — `:public` is not a purchasable entitlement.
    attribute :audience, :atom do
      allow_nil? false
      constraints one_of: Audiences.gated()
      public? true
    end

    # The provider's price identifier (e.g. Stripe `price_…`).
    attribute :provider_price_id, :string, allow_nil?: false, public?: true

    # Display copy for the join page ("$5", "per month"). Never used to charge.
    attribute :price_config, :map, allow_nil?: false, default: %{}, public?: true

    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_slug_per_org, [:org_id, :slug]

    # One tier per provider price, so webhook → tier resolution is never
    # ambiguous.
    identity :unique_price_per_org, [:org_id, :provider_price_id]
  end
end
