defmodule KilnCMSWeb.TenantStrictHostTest do
  @moduledoc """
  Strict host→tenant matching (#563).

  Tenant resolution is by `Host`. A host that matches no org normally falls
  through to the **default** org, which on a multi-tenant deployment means any
  request with an unrecognised `Host` is served the default site's content,
  branding and analytics. `TENANT_STRICT_HOST=true` makes that a 404 instead.

  `async: false` — `:tenant_strict_host` is application env, so flipping it is
  visible to every concurrently running test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  # A host under the base host that no org claims. Unique per call so a previous
  # test's resolution can't be what's being observed (unknown hosts aren't
  # cached, but a stale positive would be).
  defp unknown_host,
    do: "no-such-org-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"

  # Drive the plug directly, so a test says something about `SetTenant` rather
  # than about whatever the router would have done next.
  defp plug_call(path, method \\ :get) do
    conn = %Plug.Conn{Phoenix.ConnTest.build_conn(method, path) | host: unknown_host()}
    KilnCMSWeb.Plugs.SetTenant.call(conn, [])
  end

  defp strict!(value) do
    previous = Application.get_env(:kiln_cms, :tenant_strict_host)
    Application.put_env(:kiln_cms, :tenant_strict_host, value)
    on_exit(fn -> Application.put_env(:kiln_cms, :tenant_strict_host, previous) end)
  end

  describe "fetch_org/1 with strict host matching off (the default)" do
    setup do: strict!(false)

    test "an unknown host resolves to the default org" do
      assert {:ok, org} = Tenant.fetch_org(unknown_host())
      assert org.id == Accounts.default_org_id()
    end

    test "a nil host resolves to the default org" do
      assert {:ok, org} = Tenant.fetch_org(nil)
      assert org.id == Accounts.default_org_id()
    end

    test "strict_host?/0 reports off" do
      refute Tenant.strict_host?()
    end
  end

  describe "fetch_org/1 with strict host matching on" do
    setup do: strict!(true)

    test "an unknown host is an error rather than the default org" do
      assert :error = Tenant.fetch_org(unknown_host())
    end

    test "a nil/blank host is an error" do
      assert :error = Tenant.fetch_org(nil)
      assert :error = Tenant.fetch_org("")
    end

    test "an IP literal and a bare hostname are errors" do
      assert :error = Tenant.fetch_org("203.0.113.9")
      assert :error = Tenant.fetch_org("localhost.localdomain")
    end

    test "the canonical base host still resolves to the default org" do
      assert {:ok, org} = Tenant.fetch_org(Tenant.base_host())
      assert org.id == Accounts.default_org_id()
    end

    test "an org subdomain still resolves to that org" do
      o = org("strictsub")
      assert {:ok, resolved} = Tenant.fetch_org("#{o.slug}.#{Tenant.base_host()}")
      assert resolved.id == o.id
    end

    test "an org custom domain still resolves to that org" do
      domain = "strict-vanity-#{System.unique_integer([:positive])}.example.com"
      o = org("strictdomain", custom_domain: domain)
      assert {:ok, resolved} = Tenant.fetch_org(domain)
      assert resolved.id == o.id
    end

    test "resolve_org/1 keeps its default-org fallback — only fetch_org/1 is strict" do
      # `resolve_org/1` exists for callers with no way to reject a request; the
      # strictness lives at the boundaries that can (the plug, the on_mount hook
      # and all three sockets), all of which go through `fetch_org/1`.
      assert Tenant.resolve_org(unknown_host()).id == Accounts.default_org_id()
    end
  end

  describe "SetTenant plug" do
    test "serves the default org for an unknown Host when strict matching is off", %{conn: conn} do
      strict!(false)

      conn = %{conn | host: unknown_host()} |> get(~p"/")

      assert conn.status == 200
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "404s an unknown Host when strict matching is on", %{conn: conn} do
      strict!(true)

      conn = %{conn | host: unknown_host()} |> get(~p"/")

      # Answered by the plug, not raised for the error renderer: the 404 template
      # brands itself from the default org, which is exactly what an unmatched
      # host must not be shown.
      assert conn.status == 404
      assert conn.halted
      refute Map.has_key?(conn.assigns, :current_org)
      assert conn.resp_body =~ "does not serve the requested host"
    end

    test "the rejection body is plain text, so it cannot carry the default site's chrome",
         %{conn: conn} do
      strict!(true)

      conn = %{conn | host: unknown_host()} |> get(~p"/")

      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
      refute conn.resp_body =~ "<html"
    end

    test "still serves the base host when strict matching is on", %{conn: conn} do
      strict!(true)

      conn = %{conn | host: Tenant.base_host()} |> get(~p"/")

      assert conn.status == 200
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "still serves an org subdomain when strict matching is on", %{conn: conn} do
      strict!(true)
      o = org("stricthosted")

      conn = %{conn | host: "#{o.slug}.#{Tenant.base_host()}"} |> get(~p"/")

      assert conn.status == 200
      assert conn.assigns.current_org.id == o.id
    end
  end

  describe "SetTenant plug: health probes are exempt from strict matching" do
    setup do: strict!(true)

    test "the liveness probe answers on an unknown Host", %{conn: conn} do
      # A load balancer sends whatever Host it likes — often the container IP.
      # 404ing it would mark a correctly configured deployment unhealthy.
      conn = %{conn | host: "10.0.1.7"} |> get(~p"/up")

      assert conn.status == 200
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "the readiness probe answers on an unknown Host", %{conn: conn} do
      conn = %{conn | host: unknown_host()} |> get(~p"/ready")

      # The DB is up in test, so this is the healthy answer — the point is that
      # it is the HealthController's answer and not the strict-host 404.
      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "ok"
    end

    test "a trailing slash still reaches the probe, because the router does the splitting" do
      # `request_path` is "/up/" here while the router matches `["up"]`. A raw
      # string comparison would miss it and 404 a health check configured with a
      # trailing slash — the one failure this exemption exists to prevent.
      assert plug_call("/up/").assigns.current_org.id == Accounts.default_org_id()
    end

    test "the billing webhook is exempt too — it is authorized by HMAC, not by host" do
      # `BillingWebhookController`'s own moduledoc says it must never read the
      # ambient tenant: the provider posts to whatever host the endpoint was
      # registered with. Rejecting it would silently diverge membership state.
      conn = plug_call("/billing/webhooks/stripe", :post)

      refute conn.halted
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "the exemption follows the router, so a lookalike path is still rejected" do
      # The exemption keys on the controller, not on a path list, so a path that
      # merely *starts* like a probe reaches the catch-all content route and
      # gets no relief.
      conn = plug_call("/upstream")

      assert conn.halted
      assert conn.status == 404
    end

    test "a path with no route at all is rejected rather than exempted" do
      conn = plug_call("/no/such/route/anywhere")

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "the LiveView mount hook" do
    test "refuses an unknown socket host with a 404-status exception" do
      strict!(true)
      socket = %Phoenix.LiveView.Socket{host_uri: URI.parse("https://#{unknown_host()}/")}

      error =
        assert_raise KilnCMSWeb.Tenant.UnknownHostError, fn ->
          KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)
        end

      # 4xx is what `Phoenix.LiveView.Channel` turns into a client reload rather
      # than a crash report, so the status is load-bearing, not decoration.
      assert Plug.Exception.status(error) == 404
    end

    test "serves the default org for an unknown socket host when strict matching is off" do
      strict!(false)
      socket = %Phoenix.LiveView.Socket{host_uri: URI.parse("https://#{unknown_host()}/")}

      assert {:cont, socket} =
               KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)

      assert socket.assigns.current_org.id == Accounts.default_org_id()
    end

    test "a socket that is not mounted at the router is not host-scoped, so it is not refused" do
      # `live_render/3` children and `live_isolated/3` tests carry
      # `:not_mounted_at_router`. That is "no host to judge", not "a host that
      # failed" — refusing them would be answering a question nobody asked.
      strict!(true)
      socket = %Phoenix.LiveView.Socket{host_uri: :not_mounted_at_router}

      assert {:cont, socket} =
               KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)

      assert socket.assigns.current_org.id == Accounts.default_org_id()
    end
  end

  describe "the raw sockets" do
    test "the GraphQL socket refuses a connect whose URI host resolves to no org" do
      strict!(true)
      info = %{uri: URI.parse("wss://#{unknown_host()}/ws/gql")}

      assert :error = KilnCMSWeb.GraphqlSocket.connect(%{}, %Phoenix.Socket{}, info)
    end

    test "the GraphQL socket refuses a connect with no URI at all under strict matching" do
      # A socket with no host cannot be scoped to a tenant, and scoping it to the
      # default org is the bug — so it is refused rather than defaulted.
      strict!(true)

      assert :error = KilnCMSWeb.GraphqlSocket.connect(%{}, %Phoenix.Socket{}, %{})
    end

    test "the GraphQL socket still scopes a known host to that org" do
      strict!(true)
      o = org("gqlstrict")
      info = %{uri: URI.parse("wss://#{o.slug}.#{Tenant.base_host()}/ws/gql")}

      assert {:ok, socket} = KilnCMSWeb.GraphqlSocket.connect(%{}, %Phoenix.Socket{}, info)
      assert socket.assigns.absinthe.opts[:context].tenant == o.id
    end

    test "the visual-editing bridge socket refuses an unknown host" do
      strict!(true)

      assert :error =
               KilnCMSWeb.BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => Ash.UUID.generate()},
                 connect_info: %{uri: URI.parse("wss://#{unknown_host()}/ws/bridge")}
               })
    end
  end

  describe "host normalization" do
    setup do: strict!(true)

    test "a rooted FQDN (trailing dot) resolves like its bare form" do
      o = org("rooted")

      assert {:ok, resolved} = Tenant.fetch_org("#{o.slug}.#{Tenant.base_host()}.")
      assert resolved.id == o.id
    end

    test "an uppercased host resolves like its lowercase form" do
      o = org("shouty")

      assert {:ok, resolved} =
               Tenant.fetch_org(String.upcase("#{o.slug}.#{Tenant.base_host()}"))

      assert resolved.id == o.id
    end

    test "base_host/0 is normalized, so a capitalized PHX_HOST cannot 404 the apex" do
      previous = Application.get_env(:kiln_cms, :tenant_base_host)
      Application.put_env(:kiln_cms, :tenant_base_host, "Example.COM.")
      on_exit(fn -> Application.put_env(:kiln_cms, :tenant_base_host, previous) end)

      assert Tenant.base_host() == "example.com"
      assert {:ok, org} = Tenant.fetch_org("example.com")
      assert org.id == Accounts.default_org_id()
    end
  end

  describe "UnknownHostError" do
    test "carries a 404 plug status and names the host" do
      err = KilnCMSWeb.Tenant.UnknownHostError.exception(host: "nope.example.com")

      assert Plug.Exception.status(err) == 404
      assert err.host == "nope.example.com"
      assert Exception.message(err) =~ "nope.example.com"
    end
  end
end
