defmodule KilnCMS.MultitenancyTest do
  @moduledoc """
  Data-model foundation for multi-tenancy (epic #336, PR 1).

  Covers the tenant registry (`Organization`/`OrgMembership`), the non-breaking
  `global?: true` rollout (tenant-less code paths still work and land in the
  default org), and the headline capability: two orgs sharing a slug.

  Content ops run `authorize?: false` on purpose: the tenant axis is exactly
  what the anonymous delivery path relies on (it reads `authorize?: false`), so
  these assertions verify the `org_id` filter independently of the role policies.

  Not async: some assertions read across the whole table (tenant-less/global
  reads), so a shared sandbox is required.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS

  # Orgs are created via Ash.Seed to bypass the admin-only management policy —
  # this suite is about the tenant axis, not org RBAC.
  defp org(slug) do
    Ash.Seed.seed!(Organization, %{
      name: "Org #{slug}",
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uslug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp attrs(slug),
    do: %{title: "T", slug: slug, blocks: [%{type: :rich_text, content: "<p>x</p>", order: 0}]}

  # Content ops with authorization bypassed (the delivery-path scenario).
  defp create_page(attrs, opts),
    do: CMS.create_page(attrs, Keyword.put(opts, :authorize?, false))

  defp create_page!(attrs, opts \\ []),
    do: CMS.create_page!(attrs, Keyword.put(opts, :authorize?, false))

  defp list_pages!(opts \\ []),
    do: CMS.list_pages!(Keyword.put(opts, :authorize?, false))

  describe "the default organization" do
    test "is seeded by the backfill migration and exposed as a constant" do
      assert Accounts.default_org_id() == Organization.default_id()

      assert {:ok, default} =
               Accounts.get_organization(Accounts.default_org_id(), authorize?: false)

      assert default.slug == "default"
    end
  end

  describe "tenant-less writes (global?: true) land in the default org" do
    test "a page created with no tenant is stamped with the default org_id" do
      page = create_page!(attrs(uslug("mt-default")))
      assert page.org_id == Accounts.default_org_id()
    end

    test "Ash.Seed with no org_id also applies the default" do
      page = Ash.Seed.seed!(CMS.Page, %{title: "S", slug: uslug("mt-seed")})
      assert page.org_id == Accounts.default_org_id()
    end
  end

  describe "tenant-scoped writes" do
    test "a page created under a tenant is stamped with that org" do
      o = org("acme")
      page = create_page!(attrs(uslug("mt-scoped")), tenant: o)
      assert page.org_id == o.id
    end

    test "an %Organization{} struct and a bare id resolve to the same tenant" do
      o = org("bytenant")
      page = create_page!(attrs(uslug("mt-struct")), tenant: o)
      page2 = create_page!(attrs(uslug("mt-id")), tenant: o.id)
      assert page.org_id == o.id
      assert page2.org_id == o.id
    end
  end

  describe "the headline capability: two sites can share a slug" do
    test "the same slug+locale is allowed once per org" do
      a = org("a")
      b = org("b")
      assert {:ok, _} = create_page(attrs("about"), tenant: a)
      # Same slug in org B — must NOT collide (the whole point of #336).
      assert {:ok, _} = create_page(attrs("about"), tenant: b)
    end

    test "the slug is still unique WITHIN an org" do
      a = org("dup")
      assert {:ok, _} = create_page(attrs("about"), tenant: a)
      assert {:error, _} = create_page(attrs("about"), tenant: a)
    end
  end

  describe "tenant read isolation" do
    setup do
      a = org("read-a")
      b = org("read-b")
      sa = uslug("iso-a")
      sb = uslug("iso-b")
      create_page!(attrs(sa), tenant: a)
      create_page!(attrs(sb), tenant: b)
      %{a: a, sa: sa, sb: sb}
    end

    test "a tenant-scoped read returns only that org's rows", %{a: a, sa: sa, sb: sb} do
      slugs = a |> list_scoped() |> Enum.map(& &1.slug)
      assert sa in slugs
      refute sb in slugs
    end

    test "a tenant-less (global) read spans all orgs", %{sa: sa, sb: sb} do
      slugs = list_pages!() |> Enum.map(& &1.slug)
      # Superset assertion (shared sandbox) — both orgs' rows are visible.
      assert sa in slugs
      assert sb in slugs
    end

    defp list_scoped(org), do: list_pages!(tenant: org)
  end

  describe "PaperTrail versions carry the tenant" do
    test "a version created under a tenant is stamped with the org_id" do
      o = org("versioned")
      page = create_page!(attrs(uslug("mt-ver")), tenant: o)
      _ = CMS.update_page!(page, %{title: "Edited"}, tenant: o, authorize?: false)

      %{rows: rows} =
        KilnCMS.Repo.query!(
          "SELECT DISTINCT org_id FROM pages_versions WHERE version_source_id = $1",
          [Ecto.UUID.dump!(page.id)]
        )

      assert rows == [[Ecto.UUID.dump!(o.id)]]
    end
  end

  describe "Organization registry" do
    test "slug is unique across the install" do
      slug = uslug("unique")
      assert {:ok, _} = Accounts.create_organization(%{name: "X", slug: slug}, authorize?: false)

      assert {:error, _} =
               Accounts.create_organization(%{name: "Y", slug: slug}, authorize?: false)
    end

    test "custom_domain is unique only when set (partial identity)" do
      # Two orgs with no custom domain coexist (the partial index ignores nulls).
      assert {:ok, _} =
               Accounts.create_organization(%{name: "N1", slug: uslug("nd1")}, authorize?: false)

      assert {:ok, _} =
               Accounts.create_organization(%{name: "N2", slug: uslug("nd2")}, authorize?: false)

      domain = "vanity-#{System.unique_integer([:positive])}.example.com"

      assert {:ok, _} =
               Accounts.create_organization(
                 %{name: "D1", slug: uslug("d1"), custom_domain: domain},
                 authorize?: false
               )

      assert {:error, _} =
               Accounts.create_organization(
                 %{name: "D2", slug: uslug("d2"), custom_domain: domain},
                 authorize?: false
               )
    end
  end

  describe "OrgMembership" do
    test "is unique per (user, org) and mirrors the user's role fields" do
      o = org("mem")
      u = user()

      assert {:ok, m} =
               Accounts.create_org_membership(
                 %{organization_id: o.id, user_id: u.id, role: :editor},
                 authorize?: false
               )

      assert m.role == :editor

      assert {:error, _} =
               Accounts.create_org_membership(
                 %{organization_id: o.id, user_id: u.id, role: :viewer},
                 authorize?: false
               )
    end

    test "a user's memberships are queryable (backs the org switcher)" do
      u = user()

      {:ok, _} =
        Accounts.create_org_membership(
          %{organization_id: Accounts.default_org_id(), user_id: u.id, role: :admin},
          authorize?: false
        )

      memberships = Accounts.list_memberships_for_user!(u.id, authorize?: false)
      assert Enum.any?(memberships, &(&1.organization_id == Accounts.default_org_id()))
    end
  end
end
