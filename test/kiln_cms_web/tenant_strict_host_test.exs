defmodule KilnCMSWeb.TenantStrictHostTest do
  @moduledoc """
  Strict host → tenant resolution (#563).

  Tenant resolution is by HTTP host, and an unrecognised one — a bare hostname,
  an IP literal, `localhost`, or an attacker-supplied `Host` — used to fall
  through to the **default organization** rather than erroring. Right for a
  single-org install, wrong for a multi-org one: it serves the default org's
  content, branding and analytics to a request that named no org.

  `TENANT_STRICT_HOST` makes those requests 404. Both settings are covered here,
  through the real endpoint, because the plug runs in the endpoint rather than
  the router and a route-level test would not exercise it.

  `async: false`: `:tenant_strict_host` is global application config.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  defp set_strict(value) do
    previous = Application.get_env(:kiln_cms, :tenant_strict_host)
    Application.put_env(:kiln_cms, :tenant_strict_host, value)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:kiln_cms, :tenant_strict_host)
        prev -> Application.put_env(:kiln_cms, :tenant_strict_host, prev)
      end
    end)
  end

  # Unknown hosts are never cached (a `nil` is not committed), and every known
  # host here belongs to a freshly-seeded org, so no cache clearing is needed.
  defp with_host(conn, host), do: %{conn | host: host}

  describe "fetch_org/1 with strict host off (the default)" do
    setup do
      set_strict(false)
      :ok
    end

    test "an unknown host resolves to the default org" do
      assert {:ok, org} = Tenant.fetch_org("no-such-host.invalid")
      assert org.id == Accounts.default_org_id()
    end

    test "an IP literal and localhost resolve to the default org" do
      assert {:ok, %{id: id}} = Tenant.fetch_org("203.0.113.9")
      assert id == Accounts.default_org_id()
      assert {:ok, %{id: ^id}} = Tenant.fetch_org("localhost")
    end

    test "a missing or blank host resolves to the default org" do
      assert {:ok, %{id: id}} = Tenant.fetch_org(nil)
      assert id == Accounts.default_org_id()
      assert {:ok, %{id: ^id}} = Tenant.fetch_org("")
    end

    test "a real org's subdomain still resolves to that org" do
      o = org("strictoff")
      assert {:ok, resolved} = Tenant.fetch_org("#{o.slug}.#{Tenant.base_host()}")
      assert resolved.id == o.id
    end
  end

  describe "fetch_org/1 with strict host on" do
    setup do
      set_strict(true)
      :ok
    end

    test "an unknown host is refused rather than resolved" do
      assert Tenant.fetch_org("no-such-host.invalid") == :error
      assert Tenant.fetch_org("203.0.113.9") == :error
      assert Tenant.fetch_org(nil) == :error
      assert Tenant.fetch_org("") == :error
    end

    test "a real org's subdomain still resolves" do
      o = org("stricton")
      assert {:ok, resolved} = Tenant.fetch_org("#{o.slug}.#{Tenant.base_host()}")
      assert resolved.id == o.id
    end

    test "an org's custom domain still resolves" do
      o = org("strictdomain", custom_domain: "vanity.strict.test")
      assert {:ok, resolved} = Tenant.fetch_org("vanity.strict.test")
      assert resolved.id == o.id
    end

    test "the canonical base host still resolves to the default org" do
      assert {:ok, org} = Tenant.fetch_org(Tenant.base_host())
      assert org.id == Accounts.default_org_id()
    end

    # Hostnames are case-insensitive, and browsers send a rooted FQDN's trailing
    # dot verbatim. Both used to resolve to nothing and be papered over by the
    # default-org fallback; under strict mode each would 404 a hostname that is
    # DNS-identical to one that works.
    test "host matching is case-insensitive and tolerates a rooted FQDN" do
      o = org("strictnorm")
      host = "#{o.slug}.#{Tenant.base_host()}"

      assert {:ok, %{id: id}} = Tenant.fetch_org(String.upcase(host))
      assert id == o.id
      assert {:ok, %{id: ^id}} = Tenant.fetch_org(host <> ".")
      assert {:ok, %{id: ^id}} = Tenant.fetch_org(String.upcase(host) <> ".")
    end

    # The same normalisation on the base host itself: a `PHX_HOST` spelled with
    # capitals used to make EVERY host unresolvable, which lenient mode hid and
    # strict mode would turn into a total outage.
    test "a mixed-case configured base host still matches" do
      previous = Application.get_env(:kiln_cms, :tenant_base_host)
      Application.put_env(:kiln_cms, :tenant_base_host, "Acme.Test")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :tenant_base_host)
          prev -> Application.put_env(:kiln_cms, :tenant_base_host, prev)
        end
      end)

      assert {:ok, org} = Tenant.fetch_org("acme.test")
      assert org.id == Accounts.default_org_id()
    end

    # resolve_org/1 is for callers with no way to refuse (jobs, mailers), so it
    # keeps defaulting even here. If it started returning nil, every URL-builder
    # in the codebase would crash under strict mode.
    test "resolve_org/1 still defaults, since its callers cannot refuse" do
      assert Tenant.resolve_org("no-such-host.invalid").id == Accounts.default_org_id()
    end
  end

  describe "the request pipeline with strict host off" do
    setup do
      set_strict(false)
      :ok
    end

    # Deliberately NOT `/up`: that path is exempt in both modes, so a test using
    # it passes whether strict mode is off, on, or never read at all.
    test "an unknown host is served the default org's site", %{conn: conn} do
      conn = conn |> with_host("no-such-host.invalid") |> get("/sitemap.xml")

      assert conn.status == 200
      refute conn.halted
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end
  end

  describe "the request pipeline with strict host on" do
    setup do
      set_strict(true)
      :ok
    end

    test "an unknown host gets a 404 and no tenant assign", %{conn: conn} do
      conn = conn |> with_host("attacker.invalid") |> get("/")

      assert conn.status == 404
      assert conn.halted
      assert response_content_type(conn, :txt) =~ "text/plain"
      assert conn.resp_body =~ "No site is configured for this host"
      refute Map.has_key?(conn.assigns, :current_org)
    end

    # `conn.halted` is what makes this meaningful: `/api/content/page/anything`
    # would 404 from its own route regardless, so the status alone would pass
    # with the feature switched off. Halting proves the endpoint refused it
    # before the router ever ran.
    test "every routed path is refused, before routing", %{conn: conn} do
      for path <- ["/", "/sitemap.xml", "/api/content/page/anything", "/sign-in"] do
        conn = conn |> with_host("attacker.invalid") |> get(path)

        assert conn.status == 404, "expected #{path} to be refused"
        assert conn.halted, "expected #{path} to be halted by the plug, not routed"
        assert conn.resp_body =~ "No site is configured for this host"
      end
    end

    # Both `Plug.Static` mounts sit ABOVE this plug in the endpoint, so static
    # files are outside the refusal boundary. Deliberate — assets are
    # deployment-global and carry nothing org-specific — but pinned here so the
    # limit is recorded rather than assumed, and so a reordering that silently
    # changed it shows up as a failure. `/uploads` is the one to watch: it is
    # org media, keyed by unguessable UUID, and equally outside.
    test "static assets are served regardless of host", %{conn: conn} do
      conn = conn |> with_host("attacker.invalid") |> get("/embed.js")

      # `Plug.Static` halts too when it serves a file, so the 200 is the signal —
      # the refusal would have been a 404 with the plain-text body.
      assert conn.status == 200
      refute conn.resp_body =~ "No site is configured for this host"
    end

    # A load balancer health-checks by pod IP or an internal DNS name, neither of
    # which names an org. 404ing that reads as an unhealthy instance and pulls it
    # out of rotation — the fix would take the deployment down.
    test "the health probes stay exempt", %{conn: conn} do
      for path <- ["/up", "/ready"] do
        probe = conn |> with_host("10.0.1.7") |> get(path)

        assert probe.status == 200, "expected #{path} to stay reachable by IP"
        refute probe.halted
        assert probe.assigns.current_org.id == Accounts.default_org_id()
      end
    end

    # Again not `/up` — the point is that a LEGITIMATE tenant is not refused, and
    # an exempt path would prove that even if every host were being refused.
    test "a known host is served normally", %{conn: conn} do
      o = org("strictpipe")
      conn = conn |> with_host("#{o.slug}.#{Tenant.base_host()}") |> get("/sitemap.xml")

      assert conn.status == 200
      refute conn.halted
      assert conn.assigns.current_org.id == o.id
    end
  end

  describe "the refusal log" do
    setup do
      set_strict(true)
      KilnCMSWeb.Plugs.SetTenant.reset_log_throttle()
      on_exit(&KilnCMSWeb.Plugs.SetTenant.reset_log_throttle/0)
      :ok
    end

    test "names the refused host and the variable that caused it", %{conn: conn} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn |> with_host("attacker.invalid") |> get("/")
        end)

      assert log =~ "attacker.invalid"
      assert log =~ "TENANT_STRICT_HOST"
    end

    # The Host header is attacker-controlled and this line lands in whatever
    # aggregator the operator runs, so a value carrying newlines must not be
    # able to forge a second log line. `inspect/1` escapes them.
    test "escapes a host that would otherwise forge a log line", %{conn: conn} do
      forged = "evil\nlevel=error msg=\"root login succeeded\""

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn |> with_host(forged) |> get("/")
        end)

      assert log =~ ~S(evil\nlevel=error)
      refute log =~ "\nlevel=error msg=\"root login succeeded\""
    end

    # The refusal halts inside the endpoint, ahead of the router's rate limiter,
    # so an unthrottled line here would be a log-volume amplifier on a path
    # nothing else meters.
    test "is throttled, so a host flood cannot amplify into log volume", %{conn: conn} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for i <- 1..20, do: conn |> with_host("flood-#{i}.invalid") |> get("/")
        end)

      assert log |> String.split("Refused request for unknown host") |> length() == 2
    end
  end

  describe "the :assign_current_org on_mount hook" do
    # Sockets bypass the endpoint plug pipeline entirely, so this hook is the
    # only thing standing between a directly-opened WebSocket and the default
    # org. `LiveViewTest` derives its host from endpoint config rather than the
    # conn, so the branch is driven directly.
    defp mount_with_host(host) do
      KilnCMSWeb.LiveUserAuth.on_mount(
        :assign_current_org,
        %{},
        %{},
        %Phoenix.LiveView.Socket{host_uri: URI.parse("https://#{host}")}
      )
    end

    test "assigns the default org for an unknown host when strict mode is off" do
      set_strict(false)

      assert {:cont, socket} = mount_with_host("no-such-host.invalid")
      assert socket.assigns.current_org.id == Accounts.default_org_id()
    end

    test "halts the mount for an unknown host when strict mode is on" do
      set_strict(true)

      assert {:halt, socket} = mount_with_host("attacker.invalid")
      refute Map.has_key?(socket.assigns, :current_org)
    end

    test "still mounts a known host under strict mode" do
      set_strict(true)
      o = org("strictmount")

      assert {:cont, socket} = mount_with_host("#{o.slug}.#{Tenant.base_host()}")
      assert socket.assigns.current_org.id == o.id
    end
  end

  describe "strict_host?/0" do
    test "defaults to off, so an existing single-host install is unaffected" do
      previous = Application.get_env(:kiln_cms, :tenant_strict_host)
      Application.delete_env(:kiln_cms, :tenant_strict_host)

      # `case`, not `if previous` — an explicit `false` must be restored too.
      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :tenant_strict_host)
          prev -> Application.put_env(:kiln_cms, :tenant_strict_host, prev)
        end
      end)

      refute Tenant.strict_host?()
      assert {:ok, _} = Tenant.fetch_org("no-such-host.invalid")
    end

    test "the exempt path list defaults to both health probes" do
      assert Tenant.strict_host_exempt_paths() == ["/up", "/ready"]
    end
  end
end
