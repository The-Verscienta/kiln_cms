defmodule KilnCMS.Search.MultitenancySearchTest do
  @moduledoc """
  Search tenant facet (epic #336, PR 3): `KilnCMS.Search` scopes content results
  to the request's org, so one site's search never surfaces another's content.

  Not async: search reads span the table and the shared sandbox is required.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mts-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp slug, do: "mts-#{System.unique_integer([:positive])}"

  # A published page in `org` whose title contains `term` (so the keyword leg matches).
  defp page(org, term) do
    CMS.create_page!(%{title: "#{term} guide", slug: slug(), blocks: []},
      actor: admin(),
      tenant: org
    )
    |> then(&CMS.publish_page!(&1, actor: admin(), tenant: org))
  end

  describe "KilnCMS.Search.global/2 tenant scoping" do
    setup do
      a = org("orga")
      b = org("orgb")
      # A distinctive shared term both orgs publish a page for.
      term = "zzq#{System.unique_integer([:positive])}"
      pa = page(a, term)
      pb = page(b, term)
      %{a: a, b: b, term: term, pa: pa, pb: pb}
    end

    test "a scoped search returns only that org's content", ctx do
      a_pages = ctx.term |> Search.global(tenant: ctx.a, authorize?: false) |> Map.fetch!(:pages)
      a_ids = Enum.map(a_pages, & &1.id)
      assert ctx.pa.id in a_ids
      refute ctx.pb.id in a_ids

      b_pages = ctx.term |> Search.global(tenant: ctx.b, authorize?: false) |> Map.fetch!(:pages)
      b_ids = Enum.map(b_pages, & &1.id)
      assert ctx.pb.id in b_ids
      refute ctx.pa.id in b_ids
    end

    test "the IDF-coverage corpus is the tenant's own published pages (#1936)", ctx do
      # In org A the query's second word is rare (one page of five carries
      # it); org B publishes it on ten pages. Counted across orgs, B's pages
      # would make it common and A's rare-word page's coverage collapse; scoped
      # to A, the page covers most of the query's IDF mass.
      rare = page(ctx.a, "zyxw")
      for _ <- 1..3, do: page(ctx.a, "common")
      for _ <- 1..10, do: page(ctx.b, "zyxw")

      coverage = fn tenant, ids ->
        KilnCMS.Search.IdfCoverage.coverages(KilnCMS.CMS.Page, "common zyxw", "en", ids,
          tenant: tenant,
          authorize?: false
        )
      end

      # N = 5 in A (the setup's page included): common df 3, zyxw df 1 —
      # ≈ 0.72. Across both orgs (N = 15, zyxw df 11) it would be ≈ 0.18.
      idf = fn n, df -> :math.log(1 + (n - df + 0.5) / (df + 0.5)) end
      expected = idf.(5, 1) / (idf.(5, 1) + idf.(5, 3))

      assert_in_delta coverage.(ctx.a, [rare.id])[rare.id], expected, 1.0e-9

      # Another org's row is not a hit A's search can be asked about.
      assert coverage.(ctx.a, [ctx.pb.id]) == %{}
    end

    test "a tenant-less search spans both orgs (global? true)", ctx do
      ids =
        ctx.term |> Search.global(authorize?: false) |> Map.fetch!(:pages) |> Enum.map(& &1.id)

      assert ctx.pa.id in ids
      assert ctx.pb.id in ids
    end
  end
end
