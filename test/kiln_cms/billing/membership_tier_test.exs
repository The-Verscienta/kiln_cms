defmodule KilnCMS.Billing.MembershipTierTest do
  @moduledoc """
  Membership tiers: the gated-audience constraint, per-org isolation, and the
  deliberate immutability of `audience`.

  Contrast with `KilnCMS.Billing.SettingsTest`: tiers are per-site, so they gate
  on `Checks.OrgAdmin` — correct precisely *because* this resource carries a
  `multitenancy` block. Settings are instance-wide and gate on the global role.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp org(slug) do
    Ash.Seed.seed!(Organization, %{
      name: String.capitalize(slug),
      slug: "#{slug}-#{System.unique_integer([:positive])}"
    })
  end

  defp default_org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp tier_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Supporter",
        slug: "supporter-#{System.unique_integer([:positive])}",
        audience: @gated,
        provider_price_id: "price_#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp create(attrs, opts) do
    Billing.create_tier(tier_attrs(attrs), Keyword.put_new(opts, :tenant, default_org_id()))
  end

  describe "audience constraint" do
    test "accepts a gated audience" do
      assert {:ok, tier} = create(%{}, authorize?: false)
      assert tier.audience == @gated
    end

    test "refuses :public — it is not a purchasable entitlement" do
      # The first real call site of `Audiences.gated/0`, which had none before
      # this feature.
      assert {:error, error} = create(%{audience: :public}, authorize?: false)
      assert Exception.message(error) =~ "audience"
    end

    test "refuses an audience that is not configured at all" do
      assert {:error, error} = create(%{audience: :nonexistent_tier}, authorize?: false)
      assert Exception.message(error) =~ "audience"
    end
  end

  describe "audience immutability" do
    test "update rejects :audience outright" do
      # Changing a tier's audience would unmanage the old audience while live
      # grants for it remained, stranding an entitlement nothing would revoke.
      # Ash refuses the unknown input rather than silently dropping it, so a
      # caller that tries gets a loud error instead of a no-op.
      {:ok, tier} = create(%{}, authorize?: false)

      assert {:error,
              %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.NoSuchInput{input: :audience}]}} =
               Billing.update_tier(tier, %{name: "Renamed", audience: :public}, authorize?: false)
    end

    test "other fields still update" do
      {:ok, tier} = create(%{}, authorize?: false)

      assert {:ok, updated} = Billing.update_tier(tier, %{name: "Renamed"}, authorize?: false)
      assert updated.name == "Renamed"
      assert updated.audience == @gated
    end
  end

  describe "identities" do
    test "refuses a duplicate slug within one org" do
      {:ok, tier} = create(%{}, authorize?: false)

      # Ash reports a COMPOSITE identity violation against the identity's first
      # field (`org_id` here), not the field that actually collided — worth
      # remembering when matching these conflicts structurally.
      assert {:error, error} = create(%{slug: tier.slug}, authorize?: false)
      assert Exception.message(error) =~ "has already been taken"
    end

    test "refuses two tiers pointing at the same provider price in one org" do
      # Otherwise webhook price -> tier resolution would be ambiguous.
      {:ok, tier} = create(%{}, authorize?: false)

      assert {:error, error} =
               create(%{provider_price_id: tier.provider_price_id}, authorize?: false)

      assert Exception.message(error) =~ "has already been taken"
    end

    test "allows the same slug in two different orgs" do
      other = org("other")
      {:ok, tier} = create(%{}, authorize?: false)

      assert {:ok, twin} =
               Billing.create_tier(
                 tier_attrs(%{slug: tier.slug}),
                 authorize?: false,
                 tenant: other.id
               )

      assert twin.slug == tier.slug
      assert twin.org_id == other.id
    end
  end

  describe "reads" do
    test "the active read excludes inactive tiers and sorts by position" do
      {:ok, _inactive} = create(%{name: "Old", active: false}, authorize?: false)
      {:ok, _second} = create(%{name: "Second", position: 2}, authorize?: false)
      {:ok, _first} = create(%{name: "First", position: 1}, authorize?: false)

      names =
        Billing.list_active_tiers!(authorize?: false, tenant: default_org_id())
        |> Enum.map(& &1.name)

      assert names == ["First", "Second"]
    end

    test "by_price resolves a tier from a provider price id" do
      {:ok, tier} = create(%{}, authorize?: false)

      assert {:ok, found} =
               Billing.tier_by_price(tier.provider_price_id,
                 authorize?: false,
                 tenant: default_org_id()
               )

      assert found.id == tier.id
    end

    test "tiers are isolated per org" do
      other = org("other")
      {:ok, _mine} = create(%{}, authorize?: false)

      assert Billing.list_tiers!(authorize?: false, tenant: other.id) == []
    end
  end

  describe "policies" do
    test "anonymous callers may read — tiers render on the public join page" do
      {:ok, tier} = create(%{}, authorize?: false)

      assert [found] = Billing.list_tiers!(actor: nil, tenant: default_org_id())
      assert found.id == tier.id
    end

    test "an org admin may create" do
      admin = user(:admin)

      assert {:ok, _tier} = create(%{}, actor: admin)
    end

    test "a viewer may not create" do
      viewer = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} = create(%{}, actor: viewer)
    end

    test "an editor may not create" do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} = create(%{}, actor: editor)
    end

    test "an org admin of one org may not create a tier in another" do
      other = org("other")
      viewer = user(:viewer)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: default_org_id(),
        user_id: viewer.id,
        role: :admin
      })

      # Admin on the default org, but the request is scoped to `other`.
      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.create_tier(tier_attrs(), actor: viewer, tenant: other.id)

      # ...and allowed on their own org, proving the membership itself is good.
      assert {:ok, _tier} =
               Billing.create_tier(tier_attrs(), actor: viewer, tenant: default_org_id())
    end
  end
end
