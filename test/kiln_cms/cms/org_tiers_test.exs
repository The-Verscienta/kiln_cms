defmodule KilnCMS.CMS.OrgTiersTest do
  @moduledoc "Per-org capability tiers (#419): the membership tier governs its org."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "tiers-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp org do
    Ash.Seed.seed!(Organization, %{
      name: "Tiers #{System.unique_integer([:positive])}",
      slug: "tiers-#{System.unique_integer([:positive])}"
    })
  end

  defp membership(user, org, tier) do
    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp slug, do: "tiers-#{System.unique_integer([:positive])}"

  test "an org-granted editor authors on that org despite a global viewer role" do
    site = org()
    promoted = user(:viewer)
    membership(promoted, site, :editor)

    assert Scoping.effective_tier(promoted, site.id) == :editor
    assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: promoted, tenant: site)
  end

  test "an org-demoted global editor loses authoring on that org only" do
    site = org()
    home = org()
    demoted = user(:editor)
    membership(demoted, site, :viewer)
    membership(demoted, home, :editor)

    assert Scoping.effective_tier(demoted, site.id) == :viewer

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.create_post(%{title: "P", slug: slug()}, actor: demoted, tenant: site)

    assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: demoted, tenant: home)
  end

  test "a membership admin gets admin verbs (publish) on their org" do
    site = org()
    site_admin = user(:viewer)
    membership(site_admin, site, :admin)

    post = CMS.create_post!(%{title: "P", slug: slug()}, actor: site_admin, tenant: site)
    assert {:ok, _} = CMS.publish_post(post, actor: site_admin, tenant: site)
  end

  test "a platform admin keeps break-glass access everywhere" do
    site = org()
    platform = user(:admin)

    assert Scoping.effective_tier(platform, site.id) == :admin
    assert {:ok, _} = CMS.create_page(%{title: "Pg", slug: slug()}, actor: platform, tenant: site)
  end

  test "affiliated users have no tier on foreign orgs; legacy accounts keep User.role" do
    site = org()
    foreign = org()

    member = user(:editor)
    membership(member, site, :editor)
    assert Scoping.effective_tier(member, foreign.id) == :none

    legacy = user(:editor)
    assert Scoping.effective_tier(legacy, foreign.id) == :editor
  end

  test "the scope axes bind the effective editor (org-promoted viewer under a grant)" do
    site = org()
    promoted = user(:viewer)

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: promoted.id,
      organization_id: site.id,
      role: :editor,
      editable_types: ["post"]
    })

    assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: promoted, tenant: site)

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.create_page(%{title: "Pg", slug: slug()}, actor: promoted, tenant: site)
  end
end
