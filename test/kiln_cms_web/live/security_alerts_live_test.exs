defmodule KilnCMSWeb.SecurityAlertsLiveTest do
  @moduledoc """
  The console screen behind `/editor/security-alerts` (#2245): admin-only,
  saving the whole settings row, a notice to the site's admins when alerts are
  turned down (and none when nothing changed), and the warning for a site with
  no member admins. Also the account's mute switch in `/editor/settings`, the
  bell's sentences and links, and the security log's label for a reused key.

  What the settings do to delivery is `KilnCMS.Security.DeliverAlertTest` and
  `KilnCMS.Security.NoticesTest`. Notices are written whether or not alerts are
  enabled for the suite, so this module needs no `Application.put_env`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMSWeb.NotificationText

  @moduletag :capture_log
  @password "security-alerts-live-123"

  setup do
    org = seed_org()
    admin = authed_user(:viewer)
    %{org: org, admin: admin, membership: grant_tier(admin, org, :admin)}
  end

  # Every field, as the browser submits the whole form.
  @all_on %{
    "new_admin" => "true",
    "role_elevation" => "true",
    "failed_sign_ins" => "false",
    "lockout" => "true",
    "two_factor_disabled" => "true",
    "sso_config_changed" => "true",
    "blocked_ip" => "true",
    "notify_admins" => "true",
    "include_full_ip" => "false"
  }

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/security-alerts")
    end

    for role <- [:editor, :viewer] do
      test "turns away a #{role} of this very site", %{conn: conn, org: org} do
        user = authed_user(:viewer)
        grant_tier(user, org, unquote(role))

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/security-alerts")
      end
    end

    test "turns away an admin of another site", %{conn: conn, org: org} do
      outsider = authed_user(:viewer)
      grant_tier(outsider, seed_org(), :admin)

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> org_conn(org) |> log_in(outsider) |> live(~p"/editor/security-alerts")
    end
  end

  describe "the page" do
    test "shows every site kind with the defaults: all on but failed sign-ins", ctx do
      {:ok, lv, html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      assert html =~ "10 failed sign-ins in 15 minutes"
      assert html =~ "sends every admin of this site a notice"
      assert has_element?(lv, "#security-alerts-platform-note", "new API keys")
      assert has_element?(lv, ~s(#security-alerts-webhooks-link[href="/editor/webhooks"]))

      for kind <-
            ~w(new_admin role_elevation lockout two_factor_disabled sso_config_changed blocked_ip) do
        assert has_element?(lv, ~s(#security-alert-kind-#{kind} input[type=checkbox][checked]))
      end

      refute has_element?(
               lv,
               "#security-alert-kind-failed_sign_ins input[type=checkbox][checked]"
             )

      assert has_element?(lv, "#alerts_notify_admins[checked]")
      refute has_element?(lv, "#alerts_include_full_ip[checked]")
      refute has_element?(lv, "#security-alerts-full-ip-warning")
      # The masking covers both families (#2642).
      assert html =~ "its /24 for IPv4, its /48 for IPv6"
    end

    test "warns when the site has no member admins", %{conn: conn} do
      # A platform admin with no membership: the only kind of admin the site has.
      org = seed_org()
      platform = authed_user(:admin)

      {:ok, lv, _html} =
        conn |> org_conn(org) |> log_in(platform) |> live(~p"/editor/security-alerts")

      assert has_element?(lv, "#security-alerts-no-admins", "go to the platform admins instead")
    end

    test "does not warn when the site has a member admin", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      refute has_element?(lv, "#security-alerts-no-admins")
    end

    test "ticking full addresses shows the warning before the save", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv
      |> form("#security-alerts-form", alerts: %{@all_on | "include_full_ip" => "true"})
      |> render_change()

      assert has_element?(lv, "#security-alerts-full-ip-warning")
    end
  end

  describe "saving" do
    test "turning a kind off saves the whole row and sends the admins a notice", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv
      |> form("#security-alerts-form", alerts: %{@all_on | "lockout" => "false"})
      |> render_submit()

      assert render(lv) =~ "Every admin of this site has been sent a notice."

      assert {:ok, [row]} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org)
      assert Enum.sort(row.disabled_kinds) == ["failed_sign_ins", "lockout"]
      assert row.notify_admins
      refute row.include_full_ip

      assert [%{"channel" => "notice", "notice" => notice, "org_id" => org_id}] =
               SecurityAlerts.dispatches()

      assert org_id == ctx.org.id
      assert notice["change"] == "kind_disabled"
      assert notice["kinds"] == ["lockout"]

      refute has_element?(lv, "#security-alert-kind-lockout input[type=checkbox][checked]")
    end

    test "turning blocked addresses off saves it and sends the admins a notice", ctx do
      {:ok, lv, html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")
      assert html =~ "Blocked addresses"
      assert html =~ "on this site&#39;s block list is refused. One alert every 15 minutes"

      lv
      |> form("#security-alerts-form", alerts: %{@all_on | "blocked_ip" => "false"})
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org)
      assert Enum.sort(row.disabled_kinds) == ["blocked_ip", "failed_sign_ins"]

      assert [%{"channel" => "notice", "notice" => notice}] = SecurityAlerts.dispatches()
      assert notice["change"] == "kind_disabled"
      assert notice["kinds"] == ["blocked_ip"]

      refute has_element?(lv, "#security-alert-kind-blocked_ip input[type=checkbox][checked]")
    end

    test "switching admin notifications off sends a notice", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv
      |> form("#security-alerts-form", alerts: %{@all_on | "notify_admins" => "false"})
      |> render_submit()

      assert [%{"notice" => %{"change" => "admin_notifications_off"}}] =
               SecurityAlerts.dispatches()
    end

    test "saving unchanged settings sends no notice", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv |> form("#security-alerts-form", alerts: @all_on) |> render_submit()

      html = render(lv)
      assert html =~ "Security alert settings saved."
      refute html =~ "has been sent a notice"
      assert SecurityAlerts.dispatches() == []
    end

    test "turning failed sign-ins on and full addresses on sends no notice", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv
      |> form("#security-alerts-form",
        alerts: %{@all_on | "failed_sign_ins" => "true", "include_full_ip" => "true"}
      )
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org)
      assert row.disabled_kinds == []
      assert row.include_full_ip
      assert SecurityAlerts.dispatches() == []
    end

    test "keeps a disabled kind this release does not show", ctx do
      # A row as a newer release might leave it, with a kind this page has no
      # checkbox for. Written below the policy and the kind validation.
      Ash.Seed.seed!(KilnCMS.CMS.SiteSecurityAlerts, %{
        org_id: ctx.org.id,
        disabled_kinds: ["failed_sign_ins", "ip_auto_blocked"]
      })

      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      lv |> form("#security-alerts-form", alerts: @all_on) |> render_submit()

      assert {:ok, [row]} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org)
      assert Enum.sort(row.disabled_kinds) == ["failed_sign_ins", "ip_auto_blocked"]
    end

    test "an admin demoted while the page is open cannot save", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      Ash.Seed.update!(ctx.membership, %{role: :editor})

      html =
        lv
        |> form("#security-alerts-form", alerts: %{@all_on | "lockout" => "false"})
        |> render_submit()

      assert html =~ "permission to change this site&#39;s security alerts"
      assert {:ok, []} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org)
      assert SecurityAlerts.dispatches() == []
    end
  end

  describe "the platform's alerts (#2245, D-A)" do
    test "a site admin sees the note, not the form, and cannot save it", ctx do
      {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-alerts")

      assert has_element?(
               lv,
               "#security-alerts-platform-note",
               "Only a platform admin can turn one off, and only API keys over a rate limit."
             )

      refute has_element?(lv, "#security-alerts-platform")
      refute has_element?(lv, "#platform-alerts-form")
      refute has_element?(lv, "#api-key-rate-limit-servers-help")

      # The event a crafted client could still send is refused.
      html =
        render_hook(lv, "save_platform", %{
          "platform_alerts" => %{"api_key_rate_limited" => "false"}
        })

      assert html =~ "Only platform administrators can change the platform&#39;s security alerts."

      assert {:ok, []} =
               KilnCMS.Security.list_platform_alert_settings(
                 actor: KilnCMS.Security.alerts_system()
               )
    end

    test "a platform admin turns rate-limit alerts off, and the page says it is logged",
         %{conn: conn, org: org} do
      platform = authed_user(:admin)

      {:ok, lv, _html} =
        conn |> org_conn(org) |> log_in(platform) |> live(~p"/editor/security-alerts")

      assert has_element?(
               lv,
               "#platform-alert-kind-api_key_rate_limited input[type=checkbox][checked]"
             )

      # The kind's `?` says a cluster raises fewer of these, and links the
      # section that explains why (#2896).
      assert has_element?(
               lv,
               "#platform-alert-kind-api_key_rate_limited #api-key-rate-limit-servers-help",
               "an alert is raised only by a server that recently verified the key"
             )

      assert has_element?(
               lv,
               ~s{#api-key-rate-limit-servers-help a[href$="/docs/security-alerts.md#running-more-than-one-server"]}
             )

      # The link's anchor is the heading's slug; a renamed heading breaks it.
      assert File.read!("docs/security-alerts.md") =~ ~r/^### Running more than one server$/m

      html =
        lv
        |> form("#platform-alerts-form", platform_alerts: %{"api_key_rate_limited" => "false"})
        |> render_submit()

      assert html =~ "recorded in the instance security log"

      refute has_element?(
               lv,
               "#platform-alert-kind-api_key_rate_limited input[type=checkbox][checked]"
             )

      assert {:ok, [row]} = KilnCMS.Security.list_platform_alert_settings(actor: platform)
      assert row.disabled_kinds == ["api_key_rate_limited"]
      # No site notice: the platform setting is not a site's.
      assert SecurityAlerts.dispatches() == []
    end
  end

  describe "the mute switch in your settings" do
    test "a member admin sees it and can turn the email off", %{conn: conn, org: org} do
      admin = authed_user(:viewer)
      grant_tier(admin, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(admin) |> live(~p"/editor/settings")

      assert has_element?(lv, "#notify-on-security-alert", "Platform alerts")

      lv
      |> form("#notification-prefs-form", user: %{"notify_on_security_alert" => "false"})
      |> render_submit()

      refute Accounts.get_user!(admin.id, authorize?: false).notify_on_security_alert
    end

    test "an editor and a platform admin do not see it", %{conn: conn, org: org} do
      editor = authed_user(:viewer)
      grant_tier(editor, org, :editor)
      platform = authed_user(:admin)

      for user <- [editor, platform] do
        {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/settings")
        refute has_element?(lv, "#notify-on-security-alert")
      end
    end
  end

  describe "the bell" do
    test "each security notification has its own sentence" do
      assert NotificationText.headline(%{event: :security_alert, actor_name: nil}) ==
               "Security alert"

      assert NotificationText.headline(%{event: :security_notice, actor_name: "Ada"}) ==
               "Security alerts were turned down"
    end

    test "an alert links to the security log, a notice to the alert settings" do
      alert = %{event: :security_alert, content_type: "security_alert_dispatch", content_id: "d1"}
      notice = %{alert | event: :security_notice}

      assert Link.editor_path(alert) == "/editor/security-log"
      assert Link.editor_url(alert) == KilnCMSWeb.Endpoint.url() <> "/editor/security-log"
      assert Link.editor_path(notice) == "/editor/security-alerts"
      assert Link.editor_url(notice) == KilnCMSWeb.Endpoint.url() <> "/editor/security-alerts"
    end
  end

  test "the security log names a refused blocked address and a key over a limit, as warnings",
       ctx do
    assert KilnCMSWeb.SecurityLog.type_label(:ip_block_refused) == "Blocked address refused"
    assert KilnCMSWeb.SecurityLog.type_label(:api_key_rate_limited) == "API key hit a rate limit"

    for type <- [:ip_block_refused, :api_key_rate_limited] do
      KilnCMS.Security.record!(%{type: type},
        actor: KilnCMS.Security.system(),
        tenant: ctx.org.id
      )
    end

    {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-log")

    for label <- ["Blocked address refused", "API key hit a rate limit"] do
      assert has_element?(lv, "#security-log-events span.bg-warning\\/20", label)
    end
  end

  test "the security log names a reused API key, as a warning", ctx do
    assert KilnCMSWeb.SecurityLog.type_label(:api_key_reuse_detected) ==
             "Rotated API key used again"

    KilnCMS.Security.record!(
      %{type: :api_key_reuse_detected, target_type: "api_key", metadata: %{"revoked" => 2}},
      actor: KilnCMS.Security.system(),
      tenant: ctx.org.id
    )

    {:ok, lv, _html} = admin_conn(ctx) |> live(~p"/editor/security-log")

    assert has_element?(
             lv,
             "#security-log-events span.bg-warning\\/20",
             "Rotated API key used again"
           )
  end

  describe "a security row in the inbox, in the reader's language (#2642)" do
    defp security_row(user, org, attrs \\ %{}) do
      Notifications.record_notification!(
        Map.merge(
          %{
            user_id: user.id,
            event: :security_alert,
            content_type: "security_alert_dispatch",
            content_id: Ecto.UUID.generate(),
            title: "Alerts Site",
            excerpt: "An account was locked out (from 203.0.113.0/24)",
            details: %{
              "phase" => "alert",
              "kind" => "lockout",
              "channel" => "site",
              "count" => 1,
              "ip" => "203.0.113.0/24",
              "event_type" => "sign_in_locked"
            }
          },
          attrs
        ),
        tenant: org.id
      )
    end

    defp inbox_in(ctx, locale) do
      {:ok, _lv, html} =
        admin_conn(ctx) |> Plug.Conn.put_session("locale", locale) |> live(~p"/editor/inbox")

      html
    end

    test "Spanish and French readers get the excerpt in their language", ctx do
      security_row(ctx.admin, ctx.org)

      es = inbox_in(ctx, "es")
      assert es =~ "Se bloqueó una cuenta (desde 203.0.113.0/24)"
      refute es =~ "An account was locked out"

      fr = inbox_in(ctx, "fr")
      assert fr =~ "Un compte a été verrouillé (depuis 203.0.113.0/24)"
      refute fr =~ "An account was locked out"
    end

    test "a summary and a notice are said from their details too", ctx do
      security_row(ctx.admin, ctx.org, %{
        excerpt: "An account was locked out: 3 in this alert window",
        details: %{"phase" => "summary", "kind" => "lockout", "count" => 3}
      })

      security_row(ctx.admin, ctx.org, %{
        event: :security_notice,
        excerpt: "Some security alerts were turned off",
        details: %{"phase" => "notice", "change" => "kind_disabled", "kinds" => ["lockout"]}
      })

      es = inbox_in(ctx, "es")
      assert es =~ "Se bloqueó una cuenta: 3 en este intervalo de alertas"
      assert es =~ "Se desactivaron algunas alertas de seguridad"
    end

    test "a row written before details existed shows its stored excerpt", ctx do
      security_row(ctx.admin, ctx.org, %{details: nil})

      assert inbox_in(ctx, "es") =~ "An account was locked out (from 203.0.113.0/24)"
    end
  end

  describe "platform alerts outside the default console (#2642)" do
    defp platform_row(user, attrs \\ %{}) do
      Notifications.record_notification!(
        Map.merge(
          %{
            user_id: user.id,
            event: :security_alert,
            content_type: Notifications.platform_alert_content_type(),
            content_id: Ecto.UUID.generate(),
            title: "Platform Row Title",
            excerpt: "A platform administrator lost the role (from 198.51.100.0/24)",
            details: %{"phase" => "alert", "kind" => "platform_role_changed"}
          },
          attrs
        ),
        tenant: Accounts.default_org_id()
      )
    end

    defp in_site(conn, org, user, path) do
      {:ok, lv, html} = conn |> org_conn(org) |> log_in(user) |> live(path)
      {lv, html}
    end

    defp platform_entry(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#inbox-platform-alerts, #notification-bell-platform-alerts")
    end

    test "a platform admin sees the count and a link to the default console", %{
      conn: conn,
      org: org
    } do
      platform = authed_user(:admin)
      platform_row(platform)
      platform_row(platform)

      {lv, html} = in_site(conn, org, platform, ~p"/editor/inbox")

      assert has_element?(lv, "#inbox-platform-alerts", "2 unread platform alerts")
      assert has_element?(lv, "#notification-bell-platform-alerts", "2 unread platform alerts")

      assert [href] =
               html
               |> Floki.parse_document!()
               |> Floki.attribute("#inbox-platform-alerts", "href")

      assert href == Link.platform_alerts_url()
      assert href =~ ~r{/editor/inbox\?filter=unread$}

      # Content-free: no title, no excerpt, no site.
      refute html =~ "Platform Row Title"
      refute html =~ "198.51.100.0/24"
      refute html =~ "lost the role"
    end

    test "read rows are not counted", %{conn: conn, org: org} do
      platform = authed_user(:admin)
      platform_row(platform)
      read = platform_row(platform)

      Notifications.mark_notification_read!(read,
        actor: platform,
        tenant: Accounts.default_org_id()
      )

      {lv, _html} = in_site(conn, org, platform, ~p"/editor/inbox")

      assert has_element?(lv, "#inbox-platform-alerts", "1 unread platform alert")

      Notifications.mark_all_read(platform, Accounts.default_org_id())
      {lv, html} = in_site(conn, org, platform, ~p"/editor/inbox")
      refute has_element?(lv, "#inbox-platform-alerts")
      assert platform_entry(html) == []
    end

    test "a site's own admin, not a platform admin, sees nothing", %{conn: conn, org: org} do
      member_admin = authed_user(:viewer)
      grant_tier(member_admin, org, :admin)
      # Even a row anchored as a platform alert is not counted for them.
      platform_row(member_admin)

      {_lv, html} = in_site(conn, org, member_admin, ~p"/editor/inbox")

      assert platform_entry(html) == []
      assert Notifications.unread_platform_alert_count(member_admin, org) == 0
    end

    test "a platform admin demoted mid-session stops seeing it", %{conn: conn, org: org} do
      platform = authed_user(:admin)
      grant_tier(platform, org, :editor)
      platform_row(platform)

      {lv, _html} = in_site(conn, org, platform, ~p"/editor/inbox")
      assert has_element?(lv, "#inbox-platform-alerts")

      Ash.Seed.update!(platform, %{role: :editor})

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        Notifications.topic(platform.id),
        :notifications_changed
      )

      _drained = render(lv)
      html = render(lv)

      refute has_element?(lv, "#inbox-platform-alerts")
      assert platform_entry(html) == []
    end

    test "the default console lists the rows themselves and shows no entry", %{conn: conn} do
      platform = authed_user(:admin)
      platform_row(platform)

      {:ok, lv, html} = conn |> log_in(platform) |> live(~p"/editor/inbox")

      assert html =~ "Platform Row Title"
      refute has_element?(lv, "#inbox-platform-alerts")
      refute has_element?(lv, "#notification-bell-platform-alerts")
    end
  end

  defp admin_conn(%{conn: conn, org: org} = ctx) do
    conn |> org_conn(org) |> log_in(ctx.admin)
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Alerts Site",
      slug: "secalerts-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    Ash.Seed.seed!(User, %{
      email: "secalerts-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp log_in(conn, user) do
    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
