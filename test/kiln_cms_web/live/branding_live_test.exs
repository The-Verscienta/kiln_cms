defmodule KilnCMSWeb.BrandingLiveTest do
  @moduledoc """
  White-label branding settings (#48): the admin auth matrix, a real save, and
  the cross-org write boundary.

  The last of those is the important one. `Checks.OrgAdmin` resolves the actor's
  tier against the *request's* org, which is only safe because `SiteBranding` is
  tenant-scoped — a tenant-less resource would resolve every actor to the default
  org and let one site's admin rebrand every other site (the hazard documented on
  `KilnCMS.Mail.Settings`). These tests are the regression guard for that.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/branding")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/branding")

      assert flash["error"] =~ "admin access"
    end

    test "loads for a platform admin", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      assert html =~ "Branding"
      assert html =~ "Site name"
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_org_admin(user, org)

      {:ok, _lv, html} = org |> org_conn(conn) |> log_in(user) |> live(~p"/editor/branding")

      assert html =~ "Site name"
    end
  end

  describe "saving" do
    test "persists the tokens for the current site only", %{conn: conn, org: org} do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      {:ok, lv, _html} =
        org |> org_conn(conn) |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      lv
      |> form("#branding-form",
        branding: %{site_name: "Acme Docs", brand_color: "#0f62fe", logo_url: "/uploads/acme.png"}
      )
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_branding(tenant: org, authorize?: false)
      assert row.site_name == "Acme Docs"
      assert row.brand_color == "#0f62fe"

      # The other site is untouched.
      assert {:ok, []} = CMS.list_site_branding(tenant: other, authorize?: false)
      assert KilnCMS.Branding.for_org(other).site_name == "KilnCMS"
    end

    test "surfaces a validation error instead of writing", %{conn: conn, org: org} do
      {:ok, lv, _html} =
        org |> org_conn(conn) |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      html =
        lv
        |> form("#branding-form", branding: %{brand_color: "#fff} body{display:none}"})
        |> render_submit()

      assert html =~ "hex colour"
      assert {:ok, []} = CMS.list_site_branding(tenant: org, authorize?: false)
    end
  end

  describe "cross-org write boundary" do
    test "an admin of one site cannot write another site's branding", %{org: org} do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      user = authed_user(:editor)
      grant_org_admin(user, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Hijacked"}, actor: user, tenant: other)
    end

    test "a DEFAULT-org admin cannot write another site's branding" do
      # The specific shape of the Mail.Settings hazard: without the tenant
      # attribute, `OrgAdmin` would resolve this actor to the default org and
      # pass on every other org's row.
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      user = authed_user(:editor)
      grant_org_admin(user, Accounts.default_org())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Hijacked"}, actor: user, tenant: other)
    end

    test "an org editor is not an org admin", %{org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Nope"}, actor: user, tenant: org)
    end
  end

  defp org_conn(org, conn), do: %{conn | host: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"}

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Branding Site",
      slug: "brandlive-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_org_admin(user, org), do: grant_tier(user, org, :admin)

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "brandlive-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
