defmodule KilnCMS.MultitenancyGuardLiftTest do
  @moduledoc """
  The epic #336 close-out: with the tenant threaded through every reachable read,
  the `multitenancy_enabled` guard is lifted (a real second org can be created)
  and the cross-org reads the pre-lift audit surfaced are now tenant-scoped.

  This suite exercises a genuinely provisioned second org (via the create action,
  not `Ash.Seed`) and the governance reads that previously spanned all orgs.

  Not async: reads span the tables and the app-env guard is process-global.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Governance

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mtgl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "the guard is lifted (a real second org can be provisioned)" do
    test "create_organization succeeds for a second org" do
      # The seeded default org already exists; this is a genuine 2nd org through
      # the create action (previously refused by the guard).
      assert {:ok, org} =
               Accounts.create_organization(%{name: "Site Two", slug: uniq("site-two")},
                 authorize?: false
               )

      refute org.id == Accounts.default_org_id()
    end
  end

  describe "governance reads are scoped to the request org" do
    setup do
      a = Accounts.create_organization!(%{name: "A", slug: uniq("a")}, authorize?: false)
      b = Accounts.create_organization!(%{name: "B", slug: uniq("b")}, authorize?: false)
      actor = admin()

      pa =
        CMS.create_page!(%{title: "A page", slug: uniq("a"), blocks: []},
          actor: actor,
          tenant: a
        )

      pb =
        CMS.create_page!(%{title: "B page", slug: uniq("b"), blocks: []},
          actor: actor,
          tenant: b
        )

      %{a: a, b: b, pa: pa, pb: pb}
    end

    test "content_index lists only the request org's content", ctx do
      a_ids = Governance.content_index(ctx.a.id) |> Enum.map(& &1.id)
      assert ctx.pa.id in a_ids
      refute ctx.pb.id in a_ids
    end

    test "trail refuses to pull another org's record by id", ctx do
      # B's page id, requested under A's org → no trail (id-scoped to the org).
      assert Governance.trail("page", ctx.pb.id, ctx.a.id) == nil
      # …but resolves under B's own org.
      assert %{item: %{id: id}} = Governance.trail("page", ctx.pb.id, ctx.b.id)
      assert id == ctx.pb.id
    end
  end
end
