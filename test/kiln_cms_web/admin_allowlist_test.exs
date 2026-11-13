defmodule KilnCMSWeb.AdminAllowlistTest do
  @moduledoc """
  A site's admin allowlist on every surface it gates (#2248): the console,
  `/setup`, every sign-in route and the headless sign-in over HTTP; `/live`
  joins of those pages, including on a platform whose sockets never see the
  client; pages already open when the list changes; and `/ws/collab`. Then
  what it must leave alone, whose list applies where, and how it fails.

  `async: false`: the telemetry handlers and `Application.put_env` (proxy
  settings, the operator's switch) are node-wide. Every test uses a site of its
  own, so a cached list cannot reach another test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMSWeb.AdminAllowlist, as: Gate
  alias KilnCMSWeb.CollabSocket

  @moduletag :capture_log

  @password "password1234!"

  setup do
    test_pid = self()
    handler = "aal-refused-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :admin_allowlist, :refused],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{site: org("aalw")}
  end

  # --- helpers -----------------------------------------------------------------

  defp on_site(conn, site), do: org_conn(conn, site)

  # A conn from an address of its own, on `site`'s host: `{conn, address}`.
  defp from_somewhere(conn, site) do
    {conn, _key} = client_conn(conn)
    {on_site(conn, site), conn.remote_ip}
  end

  defp from(conn, site, address) do
    %Plug.Conn{} =
      conn = Plug.Test.put_peer_data(conn, %{address: address, port: 1, ssl_cert: nil})

    on_site(%Plug.Conn{conn | remote_ip: address}, site)
  end

  defp cidr(address), do: KilnCMS.Security.Cidr.client_range(address)

  defp admin_of(site) do
    email = "aalw-#{System.unique_integer([:positive])}@example.com"

    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :admin
    })

    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(Accounts.User, :password),
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Save `cidrs` as an admin of `site` working from `saving_from`, with
  # "Also restrict sign-in" as given (on unless said otherwise, #2493).
  defp allow!(site, cidrs, saving_from, restrict_sign_in \\ true) do
    CMS.save_site_admin_allowlist!(%{cidrs: cidrs, restrict_sign_in: restrict_sign_in},
      actor: admin_of(site),
      tenant: site.id,
      context: %{client_ip: saving_from}
    )
  end

  @sign_in_routes [
    {:get, "/sign-in"},
    {:get, "/register"},
    {:get, "/reset"},
    {:get, "/password-reset/some-token"},
    {:get, "/confirm_new_user/some-token"},
    {:get, "/magic_link/some-token"},
    {:get, "/sign-in/verify"},
    {:post, "/sign-in/verify"},
    {:post, "/sign-in/verify/passkey/options"},
    {:post, "/sign-in/verify/passkey"},
    {:get, "/sign-in/unlock"},
    {:post, "/auth/passkey/options"},
    {:post, "/auth/passkey/verify"},
    {:get, "/auth/site-sso"},
    {:get, "/auth/site-sso/callback"},
    {:get, "/auth/invite/some-token"},
    {:post, "/auth/user/password/sign_in"},
    {:get, "/auth/user/password/sign_in_with_token"},
    {:post, "/auth/user/magic_link/request"}
  ]

  defp api_sign_in(conn, user) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", %{"email" => to_string(user.email), "password" => @password})
  end

  defp an_outside_address, do: {198, 51, 100, 200}

  defp gated?(conn) do
    conn.status in [403, 503] and
      (conn.resp_body =~ "admin-allowlist-refused" or conn.resp_body =~ "network_not_allowed" or
         conn.resp_body =~ "temporarily_unavailable")
  end

  defp refused_events(site) do
    Security.list_events!(actor: admin_of(site), tenant: site.id, page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :admin_access_refused))
  end

  defp restore_env(key) do
    previous = Application.get_env(:kiln_cms, key)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, key),
        else: Application.put_env(:kiln_cms, key, previous)
    end)
  end

  # --- HTTP: refused ------------------------------------------------------------

  describe "HTTP from outside the list" do
    setup %{conn: conn, site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      {conn, ip} = from_somewhere(conn, site)
      %{conn: conn, ip: ip}
    end

    test "the console answers 403 with the page, the visitor's own address and strict headers",
         %{conn: conn, ip: ip} do
      for path <- ["/editor", "/editor/ip-blocks", "/editor/admin-allowlist"] do
        conn = get(conn, path)

        assert html = html_response(conn, 403)
        assert html =~ "Not available from this network"
        assert html =~ "Your address appears as #{:inet.ntoa(ip)}."
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
        assert [csp] = get_resp_header(conn, "content-security-policy")
        assert csp =~ "default-src 'none'"
        assert csp =~ "form-action 'none'"
      end

      assert_received {:refused, %{count: 1}, %{surface: :http, reason: :not_listed}}
    end

    test "/setup and every sign-in route answer 403", %{conn: conn} do
      for {method, path} <- [{:get, "/setup"} | @sign_in_routes] do
        conn = dispatch(conn, @endpoint, method, path, %{})
        assert conn.status == 403, "#{method} #{path} answered #{conn.status}"
        assert gated?(conn), "#{method} #{path}"
      end
    end

    test "the console's downloads answer 403", %{conn: conn} do
      for path <- [
            "/editor/content/export.csv",
            "/editor/security-log/export.csv",
            "/editor/account/export.json",
            "/editor/pages/#{Ash.UUID.generate()}"
          ] do
        assert gated?(get(conn, path)), path
      end
    end

    test "a session carried outside is refused, and the refusal sets no cookie", %{
      conn: conn,
      site: site
    } do
      # Signed in from inside the list; the browser's cookie then goes outside.
      inside = from(conn, site, {203, 0, 113, 50})
      inside = inside |> log_in(admin_of(site)) |> get("/editor/sessions")
      assert html_response(inside, 200)

      conn = inside |> recycle() |> from(site, an_outside_address()) |> get("/editor/sessions")

      assert html_response(conn, 403)
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "the headless sign-in answers 403 network_not_allowed in JSON", %{conn: conn} do
      for path <- ["/api/auth/sign_in", "/api/auth/sign_in/verify"] do
        conn = post(conn, path, %{"email" => "a@example.com", "password" => "x"})

        assert %{"errors" => [%{"code" => "network_not_allowed", "status" => "403"}]} =
                 json_response(conn, 403)
      end

      assert_received {:refused, %{count: 1}, %{surface: :api, reason: :not_listed}}
    end

    test "a refusal is in the site's security log, with no actor", %{
      conn: conn,
      site: site,
      ip: ip
    } do
      get(conn, "/sign-in")

      assert [event] = refused_events(site)
      assert event.ip == to_string(:inet.ntoa(ip))
      assert is_nil(event.actor_id)
      assert event.metadata["surface"] == "http"
    end
  end

  describe "HTTP from inside the list" do
    test "the console and sign-in are served", %{conn: conn, site: site} do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)

      assert html_response(get(conn, "/sign-in"), 200)
      assert conn |> log_in(admin_of(site)) |> get("/editor/sessions") |> html_response(200)
      refute_received {:refused, _, _}
    end

    test "an IPv4 entry admits the same client arriving IPv4-mapped", %{conn: conn, site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      conn = from(conn, site, {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109})

      assert html_response(get(conn, "/sign-in"), 200)
    end
  end

  # --- "Also restrict sign-in" (#2493) ------------------------------------------

  describe "with \"Also restrict sign-in\" on (the default)" do
    test "a list saved without the setting restricts sign-in", %{conn: conn, site: site} do
      CMS.save_site_admin_allowlist!(%{cidrs: ["203.0.113.0/24"]},
        actor: admin_of(site),
        tenant: site.id,
        context: %{client_ip: {203, 0, 113, 7}}
      )

      user = admin_of(site)
      {conn, _ip} = from_somewhere(conn, site)

      assert gated?(get(conn, "/sign-in"))

      assert %{"errors" => [%{"code" => "network_not_allowed"}]} =
               conn |> api_sign_in(user) |> json_response(403)
    end
  end

  describe "with \"Also restrict sign-in\" off, from outside the list" do
    setup %{conn: conn, site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7}, false)
      {conn, ip} = from_somewhere(conn, site)
      %{conn: conn, ip: ip}
    end

    test "every sign-in route is served", %{conn: conn} do
      for {method, path} <- @sign_in_routes do
        conn = dispatch(conn, @endpoint, method, path, %{})
        refute gated?(conn), "#{method} #{path} answered #{conn.status}"
      end

      refute_received {:refused, _, _}
    end

    test "a member signs in through the API", %{conn: conn, site: site} do
      user = admin_of(site)

      assert %{"token" => token} = conn |> api_sign_in(user) |> json_response(201)
      assert is_binary(token)
    end

    test "the sign-in page joins", %{conn: conn} do
      assert {:ok, _lv, _html} = live(conn, "/sign-in")
    end

    test "the console, /setup and the security posture are still refused", %{
      conn: conn,
      site: site
    } do
      for path <- ["/editor", "/editor/admin-allowlist", "/setup"] do
        assert conn |> get(path) |> html_response(403), path
      end

      assert conn |> log_in(admin_of(site)) |> get("/editor/sessions") |> html_response(403)

      assert %{"errors" => [%{"code" => "network_not_allowed"}]} =
               conn |> get("/api/security/posture") |> json_response(403)
    end

    test "a console page's socket from outside is refused, though the page was served inside",
         %{conn: conn, site: site} do
      inside = from(conn, site, {203, 0, 113, 50})
      inside = inside |> log_in(admin_of(site)) |> get("/editor/sessions")
      assert html_response(inside, 200)

      %Plug.Conn{} =
        outside =
        Plug.Test.put_peer_data(inside, %{address: an_outside_address(), port: 1, ssl_cert: nil})

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(outside))
      assert_received {:refused, %{count: 1}, %{surface: :live, reason: :not_listed}}
    end

    test "an open console page still leaves when a save excludes it", %{site: site} do
      conn = from(build_conn(), site, {203, 0, 113, 50})
      {:ok, lv, _html} = conn |> log_in(admin_of(site)) |> live("/editor/sessions")

      allow!(site, ["198.18.0.0/16"], {198, 18, 0, 1}, false)

      assert_redirect(lv, "/editor")
    end

    test "an open sign-in page stays through a save that leaves sign-in open", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = live(conn, "/sign-in")

      allow!(site, ["198.18.0.0/16"], {198, 18, 0, 1}, false)

      assert is_binary(render(lv))
      refute_received {:refused, _, _}
    end

    test "an open sign-in page leaves when sign-in is restricted again", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = live(conn, "/sign-in")

      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7}, true)

      assert_redirect(lv, "/editor")
      assert gated?(get(conn, "/sign-in"))
    end
  end

  # --- what it leaves alone -------------------------------------------------------

  describe "what it does not gate, from outside a list" do
    setup %{conn: conn, site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      {conn, _ip} = from_somewhere(conn, site)
      %{conn: conn}
    end

    test "the public site, membership, health, previews, media and the info pages", %{conn: conn} do
      for path <- [
            "/",
            "/membership",
            "/up",
            "/ready",
            "/access-denied",
            "/developers",
            "/preview/not-a-token",
            "/media/#{Ash.UUID.generate()}/download",
            "/media/#{Ash.UUID.generate()}/stream",
            "/sign-out"
          ] do
        conn = get(conn, path)
        refute gated?(conn), "#{path} was gated (#{conn.status})"
      end

      refute_received {:refused, _, _}
    end

    test "the APIs with keys and tokens", %{conn: conn} do
      refute gated?(get(conn, "/api/json/pages"))
      refute gated?(post(conn, "/gql", %{"query" => "{ __typename }"}))
      refute gated?(post(conn, "/mcp", %{}))
      refute gated?(post(conn, "/api/keys/rotate", %{}))
      refute_received {:refused, _, _}
    end

    test "a signed-in reader's /account", %{conn: conn, site: site} do
      refute gated?(conn |> log_in(admin_of(site)) |> get("/account"))
    end

    test "the sign-out live page joins from outside", %{conn: conn} do
      assert {:ok, _lv, _html} = live(conn, "/sign-out")
    end

    test "a public LiveView joins from outside", %{conn: conn} do
      assert {:ok, _lv, _html} = live(conn, "/membership")
    end
  end

  describe "whose list" do
    test "a list on one site leaves another site open, both ways", %{conn: conn, site: a} do
      b = org("aalw-b")
      allow!(b, ["203.0.113.0/24"], {203, 0, 113, 7})
      {conn, _ip} = from_somewhere(conn, a)

      assert html_response(get(conn, "/sign-in"), 200)
      assert gated?(conn |> on_site(b) |> get("/sign-in"))

      allow!(a, ["192.0.2.0/24"], {192, 0, 2, 1})
      assert gated?(conn |> on_site(a) |> get("/sign-in"))
    end
  end

  describe "failing closed" do
    test "a list that cannot be read answers 503 on the gate, while the public site serves", %{
      conn: conn,
      site: site
    } do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)

      KilnCMS.OrgSettings.with_actor(nil, fn ->
        conn = get(conn, "/sign-in")
        assert html_response(conn, 503) =~ "temporarily unavailable"
        assert get_resp_header(conn, "retry-after") == ["30"]
        refute conn.resp_body =~ to_string(:inet.ntoa(ip))

        assert %{"errors" => [%{"code" => "temporarily_unavailable"}]} =
                 conn
                 |> recycle()
                 |> on_site(site)
                 |> post("/api/auth/sign_in", %{})
                 |> json_response(503)

        refute gated?(get(recycle(conn) |> on_site(site), "/"))
      end)

      assert_received {:refused, _, %{reason: :unavailable}}
    end
  end

  describe "the operator's switch" do
    # `put_env` is node-wide: this module is `async: false` for it.
    setup do
      restore_env(:admin_allowlist)
    end

    test "with KILN_ADMIN_ALLOWLIST_DISABLED the console is served from anywhere", %{
      conn: conn,
      site: site
    } do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      Application.put_env(:kiln_cms, :admin_allowlist, disabled: true)
      {conn, _ip} = from_somewhere(conn, site)

      assert html_response(get(conn, "/sign-in"), 200)
    end
  end

  describe "with the block list" do
    setup do
      KilnCMS.Security.IpBlocklist.clear()
      on_exit(&KilnCMS.Security.IpBlocklist.clear/0)
    end

    test "a blocked address is refused by the block list even when allowlisted", %{
      conn: conn,
      site: site
    } do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)

      CMS.create_ip_block_rule!(%{cidr: cidr(ip)},
        actor: admin_of(site),
        tenant: site.id,
        context: %{client_ip: {192, 0, 2, 1}}
      )

      conn = get(conn, "/sign-in")
      assert response(conn, 403) == ""
      refute_received {:refused, _, _}
    end
  end

  # --- the client address -------------------------------------------------------

  describe "behind a proxy" do
    setup do
      restore_env(:trusted_proxies)
      restore_env(:client_ip_header)
      :ok
    end

    test "a trusted proxy's X-Forwarded-For decides, both ways", %{conn: conn, site: site} do
      proxy = {10, 9, 9, 9}
      Application.put_env(:kiln_cms, :trusted_proxies, ["10.9.9.0/24"])
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      inside =
        conn |> from(site, proxy) |> put_req_header("x-forwarded-for", "203.0.113.50")

      outside =
        conn |> from(site, proxy) |> put_req_header("x-forwarded-for", "198.51.100.50")

      assert html_response(get(inside, "/sign-in"), 200)
      assert gated?(get(outside, "/sign-in"))
    end

    test "with no trusted proxy, a client's own X-Forwarded-For is ignored", %{
      conn: conn,
      site: site
    } do
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      spoofed =
        conn
        |> from(site, an_outside_address())
        |> put_req_header("x-forwarded-for", "203.0.113.50")

      assert gated?(get(spoofed, "/sign-in"))
    end

    test "a platform's own client-address header is honoured", %{conn: conn, site: site} do
      Application.put_env(:kiln_cms, :client_ip_header, {:header, "fly-client-ip"})
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      inside =
        conn |> from(site, {172, 16, 0, 9}) |> put_req_header("fly-client-ip", "203.0.113.50")

      outside =
        conn |> from(site, {172, 16, 0, 9}) |> put_req_header("fly-client-ip", "198.51.100.50")

      assert html_response(get(inside, "/sign-in"), 200)
      assert gated?(get(outside, "/sign-in"))
    end
  end

  # --- /live --------------------------------------------------------------------

  describe "/live" do
    test "a page rendered before the list existed cannot join once it excludes the page", %{
      conn: conn,
      site: site
    } do
      {conn, ip} = from_somewhere(conn, site)
      conn = get(conn, "/sign-in")
      assert html_response(conn, 200)

      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      refute ip == {203, 0, 113, 7}

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
      assert_received {:refused, %{count: 1}, %{surface: :live, reason: :not_listed}}
    end

    test "a page rendered inside the list joins", %{conn: conn, site: site} do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)

      assert {:ok, _lv, _html} = live(conn, "/sign-in")
      assert {:ok, _lv, _html} = conn |> log_in(admin_of(site)) |> live("/editor/sessions")
    end

    test "a socket arriving from outside is refused, though the page was served inside", %{
      conn: conn,
      site: site
    } do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)
      conn = get(conn, "/sign-in")
      assert html_response(conn, 200)

      # Same page, same stamp; the socket itself comes from another network.
      %Plug.Conn{} =
        conn =
        Plug.Test.put_peer_data(conn, %{address: an_outside_address(), port: 1, ssl_cert: nil})

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
    end

    test "a page rendered for another site admits nothing here", %{conn: conn, site: a} do
      b = org("aalw-blob")
      {conn, ip} = from_somewhere(conn, b)
      allow!(a, [cidr(ip)], ip)

      # Rendered on b (no list), so stamped for b; joined on a's host.
      conn = get(conn, "/sign-in")
      assert html_response(conn, 200)
      conn = %{conn | host: on_site(conn, a).host}

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
    end

    test "every LiveView module carries the hook, after the join budget" do
      for view <- [
            KilnCMSWeb.SignInLive,
            KilnCMSWeb.AdminAllowlistLive,
            KilnCMSWeb.MembershipLive
          ] do
        ids = Enum.map(view.__live__().lifecycle.mount, & &1.id)

        assert Enum.find_index(ids, &match?({KilnCMSWeb.LiveJoinBudget, _}, &1)) <
                 Enum.find_index(ids, &match?({Gate, _}, &1)),
               inspect(ids)
      end
    end

    test "the gated live sessions are exactly the console, /setup and the sign-in family" do
      assert Gate.gated_live_sessions() == [
               :admin_routes,
               :auth_confirm,
               :auth_magic_sign_in,
               :auth_reset,
               :auth_sign_in,
               :editor_routes,
               :first_run,
               :invitation
             ]
    end
  end

  describe "/live where the socket cannot see the client (Fly.io)" do
    setup %{site: site} do
      restore_env(:client_ip_header)
      Application.put_env(:kiln_cms, :client_ip_header, {:header, "fly-client-ip"})
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      :ok
    end

    # The socket's own peer is Fly's proxy, outside the list; only the address
    # the HTTP gate admitted, stamped into the page, can admit the join.
    defp via_fly(conn, site, client),
      do: conn |> from(site, {172, 16, 0, 9}) |> put_req_header("fly-client-ip", client)

    test "a client on the list joins on the stamped address", %{conn: conn, site: site} do
      assert {:ok, _lv, _html} = conn |> via_fly(site, "203.0.113.50") |> live("/sign-in")
    end

    test "a page stamped outside the list before it was turned on cannot join", %{
      conn: conn,
      site: site
    } do
      other = org("aalw-fly-before")
      conn = conn |> via_fly(other, "198.51.100.50") |> get("/sign-in")
      assert html_response(conn, 200)

      allow!(other, ["203.0.113.0/24"], {203, 0, 113, 7})
      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
      _ = site
    end

    test "a page stamped on another site cannot join here", %{conn: conn, site: site} do
      b = org("aalw-fly-b")
      conn = conn |> via_fly(b, "203.0.113.50") |> get("/sign-in")
      assert html_response(conn, 200)

      conn = %{conn | host: on_site(conn, site).host}
      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
    end
  end

  describe "how long a stamp vouches" do
    setup %{site: site} do
      restore_env(:client_ip_header)
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      :ok
    end

    # A connected root join of /sign-in on `site`, its socket from `peer`,
    # carrying a page stamped `age` seconds ago (`:none` for a stamp with no time).
    defp join(site, peer, age) do
      stamp = %{org_id: site.id, ip: {203, 0, 113, 50}}

      stamp =
        if age == :none,
          do: stamp,
          else: Map.put(stamp, :at, System.system_time(:second) - age)

      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        view: KilnCMSWeb.SignInLive,
        private: %{
          connect_info: %{
            uri: URI.parse("wss://#{on_site(build_conn(), site).host}/live"),
            x_headers: [],
            peer_data: %{address: peer, port: 1, ssl_cert: nil}
          },
          live_session_name: :auth_sign_in,
          lifecycle: %Phoenix.LiveView.Lifecycle{}
        }
      }

      Gate.on_mount(:default, %{}, %{"context" => %{kiln_admin_allowlist: stamp}}, socket)
    end

    test "where the socket cannot see the client, a stale stamp is refused and a fresh one admitted",
         %{site: site} do
      Application.put_env(:kiln_cms, :client_ip_header, {:header, "fly-client-ip"})
      proxy = {172, 16, 0, 9}
      limit = Gate.stamp_max_age_seconds()

      assert {:cont, _} = join(site, proxy, 5)
      assert {:cont, _} = join(site, proxy, limit - 5)
      assert_raise Gate.RefusedError, fn -> join(site, proxy, limit + 5) end
      assert_raise Gate.RefusedError, fn -> join(site, proxy, :none) end
    end

    test "where the socket sees a listed client, the stamp's age does not matter", %{site: site} do
      assert {:cont, _} = join(site, {203, 0, 113, 50}, Gate.stamp_max_age_seconds() * 100)
    end

    test "the HTTP gate stamps the time it admitted the page", %{conn: conn, site: site} do
      conn = conn |> from(site, {203, 0, 113, 50}) |> get("/sign-in")

      assert %{kiln_admin_allowlist: %{org_id: org_id, ip: {203, 0, 113, 50}, at: at}} =
               Ash.PlugHelpers.get_context(conn)

      assert org_id == site.id
      assert_in_delta at, System.system_time(:second), 5
    end
  end

  # --- pages already open ---------------------------------------------------------

  describe "an open page" do
    test "leaves for a full page load once a save excludes it", %{conn: conn, site: site} do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)
      {:ok, lv, _html} = conn |> log_in(admin_of(site)) |> live("/editor/sessions")

      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      assert_redirect(lv, "/editor")
      assert_received {:refused, _, %{surface: :live}}
    end

    test "stays when its address is still listed", %{conn: conn, site: site} do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)
      {:ok, lv, _html} = conn |> log_in(admin_of(site)) |> live("/editor/sessions")

      allow!(site, [cidr(ip), "203.0.113.0/24"], ip)

      assert render(lv) =~ "Sessions"
      refute_received {:refused, _, _}
    end

    test "is not touched by another site's change", %{conn: conn, site: site} do
      {conn, ip} = from_somewhere(conn, site)
      allow!(site, [cidr(ip)], ip)
      {:ok, lv, _html} = conn |> log_in(admin_of(site)) |> live("/editor/sessions")

      allow!(org("aalw-elsewhere"), ["203.0.113.0/24"], {203, 0, 113, 7})

      assert render(lv) =~ "Sessions"
    end

    test "a page opened while the list was off leaves when it is turned on without it", %{
      conn: conn,
      site: site
    } do
      {conn, _ip} = from_somewhere(conn, site)
      {:ok, lv, _html} = live(conn, "/sign-in")

      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      assert_redirect(lv, "/editor")
    end
  end

  # --- /ws/collab ---------------------------------------------------------------

  describe "/ws/collab" do
    defp collab_info(site, address),
      do: %{
        uri: URI.parse("wss://#{on_site(build_conn(), site).host}/ws/collab"),
        peer_data: %{address: address, port: 1, ssl_cert: nil},
        x_headers: []
      }

    test "a connect from outside is refused even with a valid token", %{site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      token = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", admin_of(site).id)

      assert :error =
               CollabSocket.connect(
                 %{"token" => token},
                 %Phoenix.Socket{},
                 collab_info(site, an_outside_address())
               )

      assert_received {:refused, %{count: 1}, %{surface: :collab, reason: :not_listed}}

      assert {:ok, socket} =
               CollabSocket.connect(
                 %{"token" => token},
                 %Phoenix.Socket{},
                 collab_info(site, {203, 0, 113, 50})
               )

      assert socket.assigns.client_ip == {203, 0, 113, 50}
    end

    test "a connect from outside is refused with sign-in open too (#2493)", %{site: site} do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7}, false)

      assert Gate.check_connect(:collab, collab_info(site, an_outside_address())) == :error
      assert {:ok, _ip} = Gate.check_connect(:collab, collab_info(site, {203, 0, 113, 50}))
    end

    test "where the socket cannot see the client, a connect is refused while a list is on", %{
      site: site
    } do
      restore_env(:client_ip_header)
      Application.put_env(:kiln_cms, :client_ip_header, {:header, "fly-client-ip"})
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      assert Gate.check_connect(:collab, collab_info(site, {203, 0, 113, 50})) == :error
    end
  end

  describe "a host whose site cannot be resolved" do
    # `put_env` is node-wide: this module is `async: false` for it.
    setup do
      restore_env(:tenant_strict_host)
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      :ok
    end

    test "refuses a collab connect" do
      info = %{uri: URI.parse("wss://no-such-site.example.invalid/ws/collab"), x_headers: []}

      assert Gate.check_connect(:collab, info) == :error
      assert_received {:refused, _, %{surface: :collab, reason: :unavailable}}
    end

    test "refuses a gated LiveView join, unlike the block list" do
      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        view: KilnCMSWeb.SignInLive,
        private: %{
          connect_info: %{uri: URI.parse("wss://no-such-site.example.invalid/live")},
          live_session_name: :auth_sign_in
        }
      }

      assert_raise Gate.RefusedError, fn -> Gate.on_mount(:default, %{}, %{}, socket) end

      # An ungated session is left to its own hooks.
      ungated = put_in(socket.private.live_session_name, :member_public_routes)
      assert {:cont, _} = Gate.on_mount(:default, %{}, %{}, ungated)
    end
  end

  # --- the audit sampling ---------------------------------------------------------

  describe "refusal events" do
    test "are sampled per address: a flood from one address records five", %{
      conn: conn,
      site: site
    } do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})
      {conn, _ip} = from_somewhere(conn, site)

      for _ <- 1..7, do: get(conn, "/sign-in")

      assert length(refused_events(site)) == 5
    end

    test "an IPv6 client is sampled per /64, however it rotates its address", %{
      conn: conn,
      site: site
    } do
      allow!(site, ["203.0.113.0/24"], {203, 0, 113, 7})

      for n <- 1..7 do
        conn |> from(site, {0x2001, 0xDB8, 7, 7, 0, 0, 0, n}) |> get("/sign-in")
      end

      assert length(refused_events(site)) == 5
    end
  end
end
