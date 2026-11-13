defmodule KilnCMS.Security.BlockedIpAlertTest do
  @moduledoc """
  The `blocked_ip` alert (#2245) from the request edges: a refused request is
  one sampled `ip_block_refused` event per client network per window, gated
  in memory first so a flood writes nothing per request; the alert goes to
  the blocking site's own admins, masked, once, then a summary. The event
  records no address and no user agent, only the rule and the surface.

  `async: false`: alerts are turned on and the window length is set
  (`Application.put_env`), the rule cache is one named Cachex instance, and
  the scanner guard reads its settings from application env.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.BlockedIpAlert
  alias KilnCMS.Security.IpBlocklist
  alias KilnCMS.Security.ScannerGuard
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMSWeb.Plugs.IpBlock

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()
    Application.put_env(:kiln_cms, :security_alert_window_ms, window())
    IpBlocklist.clear()

    on_exit(fn ->
      Application.delete_env(:kiln_cms, :security_alert_window_ms)
      IpBlocklist.clear()
    end)

    org = org("blocked-ip")
    other = org("blocked-ip-other")
    platform = user(:admin)

    %{
      org: org,
      other: other,
      platform: platform,
      admin: member!(user(:viewer), org.id, :admin),
      other_admin: member!(user(:viewer), other.id, :admin)
    }
  end

  defp window, do: KilnCMS.Test.BudgetWindow.fresh_window_ms()
  defp uniq, do: System.unique_integer([:positive])

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "blocked-ip-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp block!(ctx, cidr, org \\ nil) do
    CMS.create_ip_block_rule!(%{cidr: cidr},
      actor: ctx.platform,
      tenant: (org || ctx.org).id,
      context: %{client_ip: {192, 0, 2, 1}}
    )
  end

  defp text(ip), do: ip |> :inet.ntoa() |> to_string()

  # The plug alone, as the endpoint runs it after `SetTenant`.
  defp refuse(org, ip) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, ip)
      |> Plug.Conn.put_req_header("user-agent", "Flood/1.0")
      |> Plug.Conn.assign(:current_org, org)
      |> IpBlock.call([])

    assert conn.halted and conn.status == 403
    conn
  end

  defp refused_events(org_id) do
    # authorize?: false — reading the log back in a test.
    Security.list_events!(tenant: org_id, authorize?: false)
    |> Enum.filter(&(&1.type == :ip_block_refused))
  end

  defp alerts(org_id) do
    Enum.filter(
      SecurityAlerts.dispatches(),
      &(&1["kind"] == "blocked_ip" and &1["scope"] == org_id)
    )
  end

  defp sample_rows do
    %{rows: [[rows, total]]} =
      Repo.query!(
        "SELECT count(*), coalesce(sum(count), 0)::bigint FROM throttle_counters " <>
          "WHERE bucket = 'security_ip_block_refused'"
      )

    {rows, total}
  end

  defp bells, do: Notification |> Repo.all() |> Enum.filter(&(&1.event == :security_alert))

  defp deliveries do
    CMS.WebhookDelivery |> Repo.all() |> Enum.filter(&(&1.event == "security.blocked_ip"))
  end

  defp endpoint!(org_id, events, admin) do
    CMS.create_webhook_endpoint!(
      %{url: "https://hooks.example.com/#{uniq()}", events: events},
      actor: admin,
      tenant: org_id
    )
  end

  defp host_info(org, ip),
    do: %{
      uri: URI.parse("http://#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}/"),
      peer_data: %{address: ip, port: 111, ssl_cert: nil},
      x_headers: []
    }

  describe "one refused request" do
    test "is a bare 403, one event and one alert, to this site's admins only",
         %{conn: conn} = ctx do
      {conn, _key} = client_conn(conn)
      ip = conn.remote_ip
      rule = block!(ctx, text(ip))

      conn = conn |> org_conn(ctx.org) |> get("/sign-in")
      assert response(conn, 403) == ""

      assert [event] = refused_events(ctx.org.id)
      assert event.metadata == %{"rule" => rule.cidr, "surface" => "http"}
      # No address and no user agent: ADR 0026, nothing logs the address.
      assert event.ip == nil
      assert event.user_agent == nil
      assert refused_events(ctx.other.id) == []
      assert [_alert] = alerts(ctx.org.id)

      SecurityAlerts.deliver()

      assert [bell] = bells()
      assert bell.user_id == ctx.admin.id
      assert bell.org_id == ctx.org.id
      assert bell.excerpt =~ "A blocked address was refused (rule "
    end

    test "from an address the site does not block is nothing", %{conn: conn} = ctx do
      {conn, _key} = client_conn(conn)
      block!(ctx, "198.51.100.0/24")

      assert html_response(conn |> org_conn(ctx.org) |> get("/sign-in"), 200)
      assert refused_events(ctx.org.id) == []
    end

    test "another site's rule blocks there, and its admins hear of it, not these", ctx do
      ip = {198, 51, 100, 23}
      block!(ctx, text(ip), ctx.other)

      refuse(ctx.other, ip)
      SecurityAlerts.deliver()

      assert refused_events(ctx.org.id) == []
      assert [_event] = refused_events(ctx.other.id)
      assert Enum.map(bells(), & &1.user_id) == [ctx.other_admin.id]
    end

    test "/up answers a blocked address and records nothing", %{conn: conn} = ctx do
      {conn, _key} = client_conn(conn)
      block!(ctx, text(conn.remote_ip))

      assert get(org_conn(conn, ctx.org), "/up").status == 200
      assert refused_events(ctx.org.id) == []
    end

    test "loopback is never matched, so never recorded", ctx do
      block!(ctx, "10.0.0.0/8")

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_org, ctx.org)
        |> IpBlock.call([])

      refute conn.halted
      assert IpBlocklist.match(ctx.org, {127, 0, 0, 1}) == false
      assert refused_events(ctx.org.id) == []
    end
  end

  describe "a flood" do
    test "a thousand requests from one address: one event, one sample, one alert", ctx do
      ip = {203, 0, 113, 7}
      block!(ctx, "203.0.113.0/24")

      for _ <- 1..1_000, do: refuse(ctx.org, ip)

      assert [_event] = refused_events(ctx.org.id)
      # One sampled write in all: the in-memory gate let one request through.
      assert sample_rows() == {1, 1}
      assert [alert] = alerts(ctx.org.id)

      SecurityAlerts.deliver()
      SecurityAlerts.close_window(alert["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      # The window held only its alert: no summary.
      assert [_alert_bell] = bells()
    end

    test "five hundred addresses: the site's cap of events, one alert, one summary", ctx do
      block!(ctx, "10.0.0.0/8")
      cap = BlockedIpAlert.site_cap()

      for n <- 1..500, do: refuse(ctx.org, {10, 1, div(n, 256), rem(n, 256)})

      assert length(refused_events(ctx.org.id)) == cap
      assert sample_rows() == {cap, cap}
      assert [alert] = alerts(ctx.org.id)

      SecurityAlerts.deliver()
      SecurityAlerts.close_window(alert["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      excerpts = bells() |> Enum.map(& &1.excerpt) |> Enum.sort()

      assert excerpts == [
               "A blocked address was refused (rule 10.0.0.0/8)",
               "A blocked address was refused: #{cap} in this alert window"
             ]
    end

    test "IPv6 addresses in one /64 are one network", ctx do
      block!(ctx, "2001:db8:1::/48")

      for n <- 1..50, do: refuse(ctx.org, {0x2001, 0xDB8, 1, 2, 0, 0, 0, n})
      refuse(ctx.org, {0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})

      assert length(refused_events(ctx.org.id)) == 2
    end
  end

  describe "the site's settings" do
    test "with the kind turned off, the event is logged and nothing is sent", ctx do
      endpoint!(ctx.org.id, ["security.blocked_ip"], ctx.admin)

      CMS.save_site_security_alerts!(%{disabled_kinds: ["blocked_ip"]},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      Repo.query!("DELETE FROM security_alert_dispatches")
      block!(ctx, "203.0.113.7")

      refuse(ctx.org, {203, 0, 113, 7})
      assert [_event] = refused_events(ctx.org.id)
      assert [alert] = alerts(ctx.org.id)

      SecurityAlerts.deliver()

      assert [%{"alert_sent_at" => %{}}] =
               Enum.filter(SecurityAlerts.dispatches(), &(&1["id"] == alert["id"]))

      assert bells() == []
      assert deliveries() == []
    end

    test "the webhook carries the masked rule and no address", ctx do
      endpoint!(ctx.org.id, ["security.blocked_ip"], ctx.admin)
      endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)
      block!(ctx, "203.0.113.7/32")

      refuse(ctx.org, {203, 0, 113, 7})
      SecurityAlerts.deliver()

      assert [delivery] = deliveries()
      assert delivery.payload["event"]["ip"] == nil
      assert delivery.payload["event"]["metadata"]["rule"] == "203.0.113.0/24"
      assert delivery.payload["event"]["metadata"]["surface"] == "http"
      refute Jason.encode!(delivery.payload) =~ "203.0.113.7"
      refute Jason.encode!(delivery.payload) =~ "Flood/1.0"
    end

    test "with full addresses on, the webhook carries the full rule and still no address",
         ctx do
      CMS.save_site_security_alerts!(%{include_full_ip: true},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      endpoint!(ctx.org.id, ["security.blocked_ip"], ctx.admin)
      block!(ctx, "203.0.113.7/32")

      refuse(ctx.org, {203, 0, 113, 7})
      SecurityAlerts.deliver()

      assert [delivery] = deliveries()
      assert delivery.payload["event"]["ip"] == nil
      assert delivery.payload["event"]["metadata"]["rule"] == "203.0.113.7/32"
      refute Jason.encode!(delivery.payload) =~ "Flood/1.0"
    end

    test "an IPv6 rule is masked to the /48, and no address is sent", ctx do
      endpoint!(ctx.org.id, ["security.blocked_ip"], ctx.admin)
      block!(ctx, "2001:db8:1:2::/64")

      refuse(ctx.org, {0x2001, 0xDB8, 1, 2, 0, 0, 0, 9})
      SecurityAlerts.deliver()

      assert [delivery] = deliveries()
      assert delivery.payload["event"]["ip"] == nil
      refute Jason.encode!(delivery.payload) =~ "2001:db8:1:2::9"
      assert delivery.payload["event"]["metadata"]["rule"] == "2001:db8:1::/48"
    end
  end

  describe "each surface" do
    test "a socket connect records its own surface", ctx do
      for {surface, n} <- [gql: 1, collab: 2, bridge: 3] do
        ip = {198, 51, 100, n}
        block!(ctx, text(ip))
        assert :error = KilnCMSWeb.IpBlock.check_connect(surface, host_info(ctx.org, ip))
      end

      surfaces = ctx.org.id |> refused_events() |> Enum.map(& &1.metadata["surface"])
      assert Enum.sort(surfaces) == ["bridge", "collab", "gql"]
      assert Enum.all?(refused_events(ctx.org.id), &(is_nil(&1.ip) and is_nil(&1.user_agent)))
    end

    test "a /live root join records the live surface", %{conn: conn} = ctx do
      {conn, _key} = client_conn(conn)
      conn = org_conn(conn, ctx.org)

      conn = get(conn, "/sign-in")
      assert html_response(conn, 200)
      block!(ctx, text(conn.remote_ip))

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
      assert [event] = refused_events(ctx.org.id)
      assert event.metadata["surface"] == "live"
      assert event.ip == nil
      assert event.user_agent == nil
    end
  end

  describe "not a refusal" do
    test "asking whether an address is blocked records nothing", ctx do
      ip = {203, 0, 113, 9}
      block!(ctx, text(ip))

      assert IpBlocklist.blocked?(ctx.org.id, ip)
      assert refused_events(ctx.org.id) == []
    end

    test "the scanner guard counting a blocked address's 404s records nothing", ctx do
      Application.put_env(:kiln_cms, :scanner_blocking, enabled: true, threshold: 3)
      on_exit(fn -> Application.delete_env(:kiln_cms, :scanner_blocking) end)

      ip = {203, 0, 113, 9}
      block!(ctx, text(ip))

      for _ <- 1..5 do
        conn =
          Plug.Test.conn(:get, "/nope")
          |> Map.put(:remote_ip, ip)
          |> Plug.Conn.put_req_header("user-agent", "curl/8.4")
          |> Plug.Conn.assign(:current_org, ctx.org)

        assert :ok = ScannerGuard.record_miss(conn, "/nope")
      end

      assert refused_events(ctx.org.id) == []
    end
  end
end
