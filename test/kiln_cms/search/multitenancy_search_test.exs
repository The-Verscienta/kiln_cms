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

    test "a tenant-less search spans both orgs (global? true)", ctx do
      ids =
        ctx.term |> Search.global(authorize?: false) |> Map.fetch!(:pages) |> Enum.map(& &1.id)

      assert ctx.pa.id in ids
      assert ctx.pb.id in ids
    end
  end
end
