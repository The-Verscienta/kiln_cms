defmodule KilnCMS.CMS.PerOrgAudienceTest do
  @moduledoc """
  The audience read axis resolved **per organization** (#337 Phase 2).

  `KilnCMS.Billing.Membership` is org-scoped but `KilnCMS.Accounts.User.audiences`
  is a single global column, so reading the grant off that column meant paying on
  one site widened access on every other. These tests pin the fix, and the
  fail-closed behaviour that goes with it.

  `@moduletag :strict_tenancy` on the cross-org cases: they only mean anything on
  the fail-closed build, where a tenant is genuinely required.
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp default_org_id, do: Accounts.default_org_id()

  defp org(slug) do
    Ash.Seed.seed!(Organization, %{
      name: String.capitalize(slug),
      slug: "#{slug}-#{System.unique_integer([:positive])}"
    })
  end

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "poa-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp membership(user, org_id, audiences) do
    Ash.Seed.seed!(OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: :viewer,
      audiences: audiences
    })
  end

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "poa-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp gated_page(org_id) do
    actor = admin()

    {:ok, page} =
      CMS.create_page(
        %{
          title: "Gated",
          slug: "gated-#{System.unique_integer([:positive])}",
          audience: @gated
        },
        actor: actor,
        tenant: org_id
      )

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor, tenant: org_id)
    published
  end

  defp can_read?(actor, page, org_id) do
    CMS.Page
    |> Ash.Query.filter(id == ^page.id)
    |> Ash.read!(actor: actor, tenant: org_id)
    |> Enum.any?()
  end

  describe "per-org resolution" do
    @tag :strict_tenancy
    test "a membership audience grants on THAT org" do
      org_a = org("a")
      reader = user()
      membership(reader, org_a.id, [@gated])

      page = gated_page(org_a.id)

      assert can_read?(reader, page, org_a.id)
    end

    @tag :strict_tenancy
    test "it does NOT grant on another org — the leak this closes" do
      # Paying on site A must not unlock site B's gated content.
      org_a = org("a")
      org_b = org("b")

      reader = user()
      membership(reader, org_a.id, [@gated])
      membership(reader, org_b.id, [])

      page_b = gated_page(org_b.id)

      refute can_read?(reader, page_b, org_b.id)
    end

    @tag :strict_tenancy
    test "an org with no membership at all is fail-closed" do
      # The org resolves from a client-controlled host, so a foreign-org actor
      # must get nothing rather than falling back to the global column.
      org_a = org("a")
      org_b = org("b")

      reader = user(%{audiences: [@gated]})
      membership(reader, org_a.id, [@gated])

      page_b = gated_page(org_b.id)

      refute can_read?(reader, page_b, org_b.id)
    end

    @tag :strict_tenancy
    test "the global column does not override a narrower per-org value" do
      # A user whose global column still carries the audience, but whose
      # membership on this org does not, gets nothing here.
      org_a = org("a")

      reader = user(%{audiences: [@gated]})
      membership(reader, org_a.id, [])

      page = gated_page(org_a.id)

      refute can_read?(reader, page, org_a.id)
    end
  end

  describe "legacy compatibility" do
    test "a membership-less user keeps the global User.audiences column" do
      # Pre-#336 data that missed the backfill, and every single-org install:
      # behaviour must be exactly as before.
      reader = user(%{audiences: [@gated]})
      page = gated_page(default_org_id())

      assert can_read?(reader, page, default_org_id())
    end

    test "a membership-less user without the audience still can't read" do
      reader = user(%{audiences: []})
      page = gated_page(default_org_id())

      refute can_read?(reader, page, default_org_id())
    end

    test "anonymous callers are unaffected" do
      page = gated_page(default_org_id())

      refute can_read?(nil, page, default_org_id())
    end

    test "public content is still world-readable" do
      actor = admin()

      {:ok, page} =
        CMS.create_page(
          %{title: "Public", slug: "public-#{System.unique_integer([:positive])}"},
          actor: actor,
          tenant: default_org_id()
        )

      {:ok, published} = CMS.publish_page(page, %{}, actor: actor, tenant: default_org_id())

      assert can_read?(nil, published, default_org_id())
    end
  end

  describe "Scoping.audiences/2" do
    test "returns [] for an anonymous actor without a lookup" do
      assert Accounts.Scoping.audiences(nil, default_org_id()) == []
    end

    test "reads the per-org membership value" do
      org_a = org("a")
      reader = user(%{audiences: [:public]})
      membership(reader, org_a.id, [@gated])

      assert Accounts.Scoping.audiences(reader, org_a.id) == [@gated]
    end

    test "falls back to the user column when unaffiliated" do
      reader = user(%{audiences: [@gated]})

      assert Accounts.Scoping.audiences(reader, default_org_id()) == [@gated]
    end

    test "is fail-closed for a foreign org" do
      org_a = org("a")
      org_b = org("b")

      reader = user(%{audiences: [@gated]})
      membership(reader, org_a.id, [@gated])

      assert Accounts.Scoping.audiences(reader, org_b.id) == []
    end

    test "accepts an Organization struct as the subject" do
      org_a = org("a")
      reader = user()
      membership(reader, org_a.id, [@gated])

      assert Accounts.Scoping.audiences(reader, org_a) == [@gated]
    end
  end
end
