defmodule KilnCMSWeb.SiteSsoLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-sso` (#1561): a site's own OIDC
  provider and the email domains it may vouch for.

  `KilnCMS.Accounts.SiteSsoTest` covers the rules. This covers what only the
  screen does:

    * **the auth matrix** — admins only: anonymous visitors, a site editor and
      an admin of *another* site are turned away, and the resources refuse a
      non-admin's write even past the page;
    * **the write-only secret** — never rendered, a blank save keeps it;
    * **SSRF at the form** — a private issuer is refused with the reason;
    * **domains** — added with their TXT record shown, verified only when the
      record is published, and one site never sees another's.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SiteSso.DomainCheck
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.SiteSsoFixtures, as: F

  @password "password1234!"

  @valid %{
    "enabled" => "true",
    "issuer" => "https://login.example.test",
    "client_id" => "kiln-site",
    "client_secret" => "sup3r-secret-value",
    "label" => "Acme staff"
  }

  setup do
    %{org: KilnCMS.OrgFixtures.org("ssolive")}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn, org: org} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               conn |> org_conn(org) |> live(~p"/editor/site-sso")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:viewer)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-sso")
    end

    test "turns away an admin of another site", %{conn: conn, org: org} do
      user = authed_user(:viewer)
      grant_tier(user, KilnCMS.OrgFixtures.org("ssolive-else"), :admin)

      assert {:error, {:redirect, _}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-sso")
    end

    test "the resources refuse a site editor's writes and reads, past the page", %{org: org} do
      editor = authed_user(:viewer)
      grant_tier(editor, org, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_sso_provider(
                 Map.new(@valid, fn {k, v} -> {String.to_atom(k), v} end),
                 actor: editor,
                 tenant: org
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.add_site_sso_domain("editor.example", actor: editor, tenant: org)

      F.domain!(org, F.unique_domain("hidden"))
      assert {:ok, []} = CMS.list_site_sso_domains(actor: editor, tenant: org)
    end
  end

  describe "the provider form" do
    test "saves, shows the callback URL, and never renders the secret",
         %{conn: conn, org: org} do
      {:ok, lv, html} = conn |> mount_as_admin(org)

      assert html =~ KilnCMSWeb.Tenant.base_url(org) <> "/auth/site-sso/callback"

      html = lv |> form("#site-sso-form", provider: @valid) |> render_submit()

      assert html =~ "Single sign-on saved."
      refute html =~ "sup3r-secret-value"
      assert html =~ "Saved. Leave blank to keep it."
      assert html =~ "verify at least one email domain"

      {:ok, [row]} = CMS.list_site_sso_provider(tenant: org, authorize?: false)
      encrypted = row.client_secret_encrypted

      lv
      |> form("#site-sso-form",
        provider: Map.merge(@valid, %{"client_secret" => "", "label" => "Staff"})
      )
      |> render_submit()

      {:ok, [row]} = CMS.list_site_sso_provider(tenant: org, authorize?: false)
      assert row.client_secret_encrypted == encrypted
      assert row.label == "Staff"
    end

    test "refuses a private issuer and says why", %{conn: conn, org: org} do
      {:ok, lv, _html} = mount_as_admin(conn, org)

      html =
        lv
        |> form("#site-sso-form", provider: Map.put(@valid, "issuer", "https://169.254.169.254"))
        |> render_submit()

      assert html =~ "private or link-local"
      assert {:ok, []} = CMS.list_site_sso_provider(tenant: org, authorize?: false)
    end
  end

  describe "domains" do
    test "added with its TXT record, verified only once published", %{conn: conn, org: org} do
      {:ok, lv, _html} = mount_as_admin(conn, org)
      domain = F.unique_domain("live")

      html = lv |> form("#site-sso-domain-form", domain: %{domain: domain}) |> render_submit()
      assert html =~ DomainCheck.record_name(domain)

      {:ok, [row]} = CMS.list_site_sso_domains(tenant: org, authorize?: false)
      assert html =~ DomainCheck.record_value(row.verification_token)
      assert html =~ "Not verified"

      html = lv |> element("#site-sso-domain-#{row.id} button", "Verify") |> render_click()
      assert html =~ "no TXT record at"

      assert {:ok, [%{verified_at: nil}]} =
               CMS.list_site_sso_domains(tenant: org, authorize?: false)

      F.publish!(row)
      html = lv |> element("#site-sso-domain-#{row.id} button", "Verify") |> render_click()
      assert html =~ "is verified."

      assert {:ok, [%{verified_at: %DateTime{}}]} =
               CMS.list_site_sso_domains(tenant: org, authorize?: false)
    end

    test "a site sees only its own domains, and cannot act on another's",
         %{conn: conn, org: org} do
      other = KilnCMS.OrgFixtures.org("ssolive-other")
      theirs = F.domain!(other, F.unique_domain("theirs"))

      {:ok, lv, html} = mount_as_admin(conn, org)
      refute html =~ theirs.domain

      render_click(lv, "remove_domain", %{"id" => theirs.id})
      assert {:ok, [_still_there]} = CMS.list_site_sso_domains(tenant: other, authorize?: false)
    end
  end

  defp mount_as_admin(conn, org) do
    user = authed_user(:viewer)
    grant_tier(user, org, :admin)
    conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-sso")
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "ssolive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
