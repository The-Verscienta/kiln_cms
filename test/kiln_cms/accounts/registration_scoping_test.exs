defmodule KilnCMS.Accounts.RegistrationScopingTest do
  @moduledoc """
  A registration awaiting approval grants nothing (#2251) — asserted against an
  **approved twin**: two accounts whose membership rows hold the same stored
  role, audiences and scopes, one `:pending` and one `:active`. Every
  difference below is the status, and nothing else.

  The rows are seeded with an editor role and gated audiences on purpose: a
  queued registration is always a bare viewer, but the point is that
  `KilnCMS.Accounts.Scoping` ignores whatever a non-active row holds.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.SiteAudiences
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Notifications

  defp uniq, do: System.unique_integer([:positive])

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "twin-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp row(user, org_id, status, role \\ :editor) do
    Ash.Seed.seed!(OrgMembership, %{
      user_id: user.id,
      organization_id: org_id,
      role: role,
      audiences: [:member],
      editable_types: ["post"],
      field_grants: %{"post" => ["title"]},
      status: status
    })
  end

  # One pending and one approved account on `org_id`, rows otherwise identical.
  defp twins(org_id, role \\ :editor) do
    pending = user()
    approved = user()

    {pending, row(pending, org_id, :pending, role), approved,
     row(approved, org_id, :active, role)}
  end

  defp page(org_id, audience, state) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Twin #{audience} #{state}",
      slug: "twin-#{uniq()}",
      locale: "en",
      state: state,
      audience: audience,
      org_id: org_id
    })
  end

  defp can_read?(page, actor, org_id),
    do: page.id in Enum.map(CMS.list_pages!(actor: actor, tenant: org_id), & &1.id)

  describe "on the site the registration is for" do
    setup do
      site = org("twin")
      {pending, pending_row, approved, approved_row} = twins(site.id)

      %{
        site: site,
        pending: pending,
        pending_row: pending_row,
        approved: approved,
        approved_row: approved_row
      }
    end

    test "tier: none against the twin's stored tier", ctx do
      assert Scoping.effective_tier(ctx.pending, ctx.site) == :none
      assert Scoping.effective_tier(ctx.approved, ctx.site) == :editor

      # The row is still named as the source, so a page can say why.
      assert {:none, :member, %{status: :pending}} = Scoping.tier_source(ctx.pending, ctx.site)
    end

    test "audiences: none, whatever the row stores", ctx do
      assert Scoping.audiences(ctx.pending, ctx.site.id) == []
      assert Scoping.audiences(ctx.approved, ctx.site.id) == [:member]

      assert SiteAudiences.for_site(ctx.pending, [ctx.pending_row], ctx.site.id) == {:pending, []}

      assert SiteAudiences.for_site(ctx.approved, [ctx.approved_row], ctx.site.id) ==
               {:membership, [:member]}
    end

    test "rejected rows answer the same, with their own source", ctx do
      rejected = user()
      rejected_row = row(rejected, ctx.site.id, :rejected)

      assert Scoping.effective_tier(rejected, ctx.site) == :none
      assert Scoping.audiences(rejected, ctx.site.id) == []
      assert SiteAudiences.for_site(rejected, [rejected_row], ctx.site.id) == {:rejected, []}
    end

    test "type scope and field grants: denied and empty", ctx do
      query = Ash.Query.new(KilnCMS.CMS.Page) |> Ash.Query.set_tenant(ctx.site.id)

      refute Scoping.permitted?(ctx.pending, query, :editable_types, "post")
      assert Scoping.permitted?(ctx.approved, query, :editable_types, "post")

      assert Scoping.field_grant(ctx.pending, ctx.site.id, "post") == []
      assert Scoping.field_grant(ctx.approved, ctx.site.id, "post") == ["title"]
      assert Scoping.field_read_grant(ctx.pending, ctx.site.id, "post") == []
    end

    test "content: public only, never gated or draft", ctx do
      public = page(ctx.site.id, :public, :published)
      gated = page(ctx.site.id, :member, :published)
      draft = page(ctx.site.id, :public, :draft)

      assert can_read?(public, ctx.pending, ctx.site.id)
      refute can_read?(gated, ctx.pending, ctx.site.id)
      refute can_read?(draft, ctx.pending, ctx.site.id)

      assert can_read?(gated, ctx.approved, ctx.site.id)
      assert can_read?(draft, ctx.approved, ctx.site.id)
    end

    test "comments: refused against the twin's allowed", ctx do
      params = %{
        content_type: "page",
        content_id: Ecto.UUID.generate(),
        block_id: "b1",
        body: "Hi"
      }

      refute CMS.can_add_comment?(ctx.pending, params, tenant: ctx.site.id)
      assert CMS.can_add_comment?(ctx.approved, params, tenant: ctx.site.id)
    end

    test "rosters: on no tier roster and no mention roster", ctx do
      admin_pending = user()
      row(admin_pending, ctx.site.id, :pending, :admin)
      admin_approved = user()
      row(admin_approved, ctx.site.id, :active, :admin)

      editors = ctx.site |> Scoping.users_with_tier([:editor]) |> Enum.map(& &1.id)
      assert ctx.approved.id in editors
      refute ctx.pending.id in editors

      admins = ctx.site |> Scoping.users_with_tier([:admin]) |> Enum.map(& &1.id)
      assert admin_approved.id in admins
      refute admin_pending.id in admins

      roster = ctx.site |> Notifications.mention_roster() |> Enum.map(& &1.id)
      assert ctx.approved.id in roster
      refute ctx.pending.id in roster
    end

    test "the account's own rows still list its pending one", ctx do
      assert [%{status: :pending}] =
               Accounts.list_memberships_for_user!(ctx.pending.id, actor: ctx.pending)
    end
  end

  describe "everywhere else" do
    test "a pending registration on site A is no access on site B or the default org" do
      site = org("twin-a")
      other = org("twin-b")
      pending = user()
      row(pending, site.id, :pending)

      assert Scoping.effective_tier(pending, other) == :none
      assert Scoping.effective_tier(pending, nil) == :none
      assert Scoping.audiences(pending, other.id) == []

      default_roster = nil |> Notifications.mention_roster() |> Enum.map(& &1.id)
      refute pending.id in default_roster
    end
  end
end
