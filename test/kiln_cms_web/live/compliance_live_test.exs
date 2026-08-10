defmodule KilnCMSWeb.ComplianceLiveTest do
  @moduledoc """
  Per-site claim checking (`/editor/compliance`, #857): the admin auth matrix, a
  real save, and the cross-org write boundary.

  Two things here carry the issue rather than the page. The first is that the
  page **exists at all**: claim checking ships off and the editor suppresses the
  whole panel while it is off, so before this there was nothing anywhere in the
  admin UI saying the feature was there. The second is that a save writes for
  the site the admin is on and no other — a hard publish gate is exactly the
  setting a tenant must not be able to impose on its neighbours.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings

  @password "password1234!"

  setup do
    original = Application.get_env(:kiln_cms, Compliance, [])
    Application.put_env(:kiln_cms, Compliance, [])

    org = org("compliancelive")

    on_exit(fn ->
      Application.put_env(:kiln_cms, Compliance, original)
      KilnCMS.Cache.bust_compliance(org.id)
      KilnCMS.Cache.bust_compliance(Accounts.default_org_id())
    end)

    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/compliance")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/compliance")

      assert flash["error"] =~ "admin access"
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, _lv, html} =
        conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/compliance")

      assert html =~ "Claim checking"
    end
  end

  # The discoverability half of the issue. A feature that ships off, renders no
  # panel while it is off, and has no page is one nobody chose not to use.
  describe "when the feature is off" do
    test "explains what it is and offers to turn it on", %{conn: conn, org: org} do
      {:ok, _lv, html} = admin_live(conn, org)

      assert html =~ "Claim checking is off for this site"
      assert html =~ "Turn on claim checking"
      # No settings form to fill in before there is anything to configure.
      refute html =~ ~s(id="compliance-settings-form")
    end

    test "the button turns it on for this site", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      html = render_click(lv, "enable")

      assert html =~ "Compliance panel now appears"
      assert Settings.for_org(org).enabled?
      refute Settings.for_org(Accounts.default_org()).enabled?
    end

    # Every column on the row has a default, and a default is applied on the
    # create side of an upsert — so a one-click "turn it on" that sent
    # `%{enabled: true}` alone would clear the phrase list of a site that had
    # configured one and then switched off.
    test "turning it back on keeps the vocabulary the site already had", %{conn: conn, org: org} do
      CMS.save_site_compliance!(
        %{enabled: false, phrases: ["banishes toxins"], phrase_severity: :error},
        authorize?: false,
        tenant: org
      )

      {:ok, lv, _html} = admin_live(conn, org)
      render_click(lv, "enable")

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: org, authorize?: false)
      assert row.phrases == ["banishes toxins"]
      assert row.phrase_severity == :error
    end
  end

  describe "the page reflects what the site actually does" do
    test "says so when the site is still on the deployment defaults", %{conn: conn, org: org} do
      Application.put_env(:kiln_cms, Compliance, enabled: true)

      {:ok, _lv, html} = admin_live(conn, org)

      assert html =~ "using the deployment defaults"
    end

    test "seeds the form from the resolved settings, not from an empty row", %{
      conn: conn,
      org: org
    } do
      Application.put_env(:kiln_cms, Compliance,
        enabled: true,
        require_at_publish: true,
        disclaimer: "Not medical advice."
      )

      {:ok, _lv, html} = admin_live(conn, org)

      assert checked?(html, "compliance[require_at_publish]")
      assert value_of(html, "compliance[disclaimer]") == "Not medical advice."
    end

    test "lists the rules a document here is actually checked against", %{conn: conn, org: org} do
      CMS.save_site_compliance!(%{enabled: true, phrases: ["banishes toxins"]},
        authorize?: false,
        tenant: org
      )

      {:ok, _lv, html} = admin_live(conn, org)

      assert html =~ "Rules in effect"
      assert html =~ "regulatory claim"
      assert html =~ "banishes toxins"
    end

    # A site with no rules reports every document as unchecked rather than
    # clean, which is the one outcome an admin must not mistake for a pass.
    test "warns when the site has ended up with no rules at all", %{conn: conn, org: org} do
      CMS.save_site_compliance!(%{enabled: true, use_shared_rules: false, phrases: []},
        authorize?: false,
        tenant: org
      )

      {:ok, _lv, html} = admin_live(conn, org)

      assert html =~ "No rules apply"
    end
  end

  describe "saving" do
    test "writes the site's own switches, vocabulary and disclaimer", %{conn: conn, org: org} do
      Application.put_env(:kiln_cms, Compliance, enabled: true)

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#compliance-settings-form",
        compliance: %{
          enabled: "true",
          require_at_publish: "true",
          use_shared_rules: "false",
          phrases: "banishes toxins\n\n  detoxes you  \nbanishes toxins",
          phrase_severity: "error",
          disclaimer: "Not medical advice."
        }
      )
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: org, authorize?: false)
      assert row.enabled
      assert row.require_at_publish
      refute row.use_shared_rules
      # One per line, trimmed, blank lines dropped, deduped.
      assert row.phrases == ["banishes toxins", "detoxes you"]
      assert row.phrase_severity == :error
      assert row.disclaimer == "Not medical advice."

      settings = Settings.for_org(org)
      assert settings.require_at_publish?
      assert [%{code: :site_claim, severity: :error}] = settings.rules
    end

    test "a site can decline a publish gate the operator turned on", %{conn: conn, org: org} do
      Application.put_env(:kiln_cms, Compliance, enabled: true, require_at_publish: true)

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#compliance-settings-form",
        compliance: %{
          enabled: "true",
          require_at_publish: "false",
          use_shared_rules: "true",
          phrases: "",
          phrase_severity: "warning",
          disclaimer: ""
        }
      )
      |> render_submit()

      refute Settings.for_org(org).require_at_publish?
      # And a site that said nothing still follows the operator.
      assert Settings.for_org(Accounts.default_org()).require_at_publish?
    end

    test "a severity the form never offered is not turned into an atom", %{conn: conn, org: org} do
      Application.put_env(:kiln_cms, Compliance, enabled: true)

      {:ok, lv, _html} = admin_live(conn, org)

      render_submit(lv, "save", %{
        "compliance" => %{"enabled" => "true", "phrase_severity" => "catastrophic"}
      })

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: org, authorize?: false)
      assert row.phrase_severity == :warning
    end

    test "a payload that is not the shape the form sends is ignored, not fatal", %{
      conn: conn,
      org: org
    } do
      # `phx-submit` params are decoded from a client-controlled string, so
      # `compliance` need not be a map at all. Reading a field off a bare binary
      # would crash the LiveView into a reconnect loop.
      Application.put_env(:kiln_cms, Compliance, enabled: true)

      {:ok, lv, _html} = admin_live(conn, org)

      assert render_submit(lv, "save", %{"compliance" => "not-a-map"}) =~ "settings saved"

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: org, authorize?: false)
      refute row.enabled
    end

    test "resetting twice does not crash the page", %{conn: conn, org: org} do
      # `@row` is assigned at mount, so a second click (or a second tab) would
      # destroy an already-deleted record. A bang call there raises out of the
      # handler and takes the LiveView with it.
      Application.put_env(:kiln_cms, Compliance, enabled: true)

      CMS.save_site_compliance!(%{enabled: true, phrases: ["x"]}, authorize?: false, tenant: org)

      {:ok, lv, _html} = admin_live(conn, org)

      render_click(lv, "reset")
      html = render_click(lv, "reset")

      assert html =~ "using the deployment defaults"
      assert {:ok, []} = CMS.list_site_compliance(tenant: org, authorize?: false)
    end

    test "writes for the current site only", %{conn: conn, org: org} do
      other = org("compliancelive")
      on_exit(fn -> KilnCMS.Cache.bust_compliance(other.id) end)

      Application.put_env(:kiln_cms, Compliance, enabled: true)

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#compliance-settings-form",
        compliance: %{
          enabled: "true",
          require_at_publish: "true",
          use_shared_rules: "true",
          phrases: "banishes toxins",
          phrase_severity: "error",
          disclaimer: ""
        }
      )
      |> render_submit()

      assert {:ok, []} = CMS.list_site_compliance(tenant: other, authorize?: false)
      refute Settings.for_org(other).require_at_publish?
      assert Settings.for_org(other).rules == Compliance.default_rules()
    end
  end

  describe "cross-org write boundary" do
    test "an admin of one site cannot write another site's claim checking", %{org: org} do
      other = org("compliancelive")
      on_exit(fn -> KilnCMS.Cache.bust_compliance(other.id) end)

      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_compliance(%{enabled: true}, actor: user, tenant: other)
    end

    test "a DEFAULT-org admin cannot write another site's claim checking" do
      other = org("compliancelive")
      on_exit(fn -> KilnCMS.Cache.bust_compliance(other.id) end)

      user = authed_user(:editor)
      grant_tier(user, Accounts.default_org(), :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_compliance(%{enabled: true}, actor: user, tenant: other)
    end

    # Editors read it — the editor panel resolves it as the signed-in author —
    # but deciding what this site may not say is an admin act.
    test "an org editor may read the settings but not write them", %{org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:ok, _rows} = CMS.list_site_compliance(actor: user, tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_compliance(%{enabled: true}, actor: user, tenant: org)
    end
  end

  defp checked?(html, name) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(input[name="#{name}"][type="checkbox"][checked]))
    |> Enum.any?()
  end

  defp value_of(html, name) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(input[name="#{name}"]))
    |> Floki.attribute("value")
    |> List.first()
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/compliance")
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "compliancelive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
