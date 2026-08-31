defmodule KilnCMSWeb.TenantOutageTest do
  @moduledoc """
  Tenant resolution when the lookup cannot be *performed* — Postgres down (#341).

  A host that matches no org and a host nobody could ask about are different
  answers. `KilnCMSWeb.Tenant.fetch_org/1` used to give both the same `:error`,
  and `KilnCMSWeb.Plugs.SetTenant` turned it into "this server does not serve
  the requested host" — in the endpoint, above the router, so above the content
  cache that is supposed to keep answering without a database, and with
  `TENANT_STRICT_HOST` off, where nothing is ever meant to be refused.

  ## The outage is the absence of a checkout

  This module deliberately does **not** `use KilnCMS.DataCase` /
  `KilnCMSWeb.ConnCase`. Their setup checks a sandbox connection out for the
  test process; without one, every database read from this process fails exactly
  as it would against an unreachable Postgres — no spawning, no sandbox mode
  juggling, and no way for the outage to quietly stop being one.

  That last part matters here more than usual: with strict matching off, a test
  that *thinks* it is in an outage but is not would pass on the pre-fix code
  too, since the answer is the default org either way. `the harness really has
  no database` below is the guard that keeps the rest of this file honest — it
  asserts the failure directly, and every test that depends on the outage being
  real would be vacuous without it.

  `async: false`, and not only for the usual reason that `:tenant_strict_host`
  is application env: ExUnit runs sync modules after the async ones and one at a
  time, which is what guarantees no shared-mode sandbox owner is left standing
  to hand this process a connection.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  # Unique per call, so nothing this or another file resolved earlier can be
  # sitting in `KilnCMS.Cache.Hosts` and answer without a lookup. A failed read
  # is never cached (#1124), so these stay cold for the whole run.
  defp unknown_host, do: "outage-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"

  # Point the deployment's canonical name at a host nothing has resolved before,
  # for the same reason: the apex clause has to be reached through a real failed
  # lookup, not through a cached org left by another file.
  defp cold_base_host! do
    host = "outage-apex-#{System.unique_integer([:positive])}.example.com"
    previous = Application.get_env(:kiln_cms, :tenant_base_host)
    Application.put_env(:kiln_cms, :tenant_base_host, host)
    on_exit(fn -> Application.put_env(:kiln_cms, :tenant_base_host, previous) end)
    host
  end

  defp strict!(value) do
    previous = Application.get_env(:kiln_cms, :tenant_strict_host)
    Application.put_env(:kiln_cms, :tenant_strict_host, value)
    on_exit(fn -> Application.put_env(:kiln_cms, :tenant_strict_host, previous) end)
  end

  # Drive the plug directly, so these say something about `SetTenant` rather
  # than about whatever the router would have done next — which during an outage
  # is "raise", for reasons that have nothing to do with host resolution.
  defp plug_call(host, path \\ "/", method \\ :get) do
    conn = %Plug.Conn{Phoenix.ConnTest.build_conn(method, path) | host: host}
    KilnCMSWeb.Plugs.SetTenant.call(conn, [])
  end

  # Attach to the refusal-flood event (#678) and return the ref its handler
  # sends on. Two surfaces need this, and neither must fire.
  defp watch_refusal_alert! do
    KilnCMSWeb.TenantRefusalAlert.reset()

    ref = make_ref()
    handler_id = "tenant-outage-#{inspect(ref)}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:kiln_cms, :tenant, :refusal_flood],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  test "the harness really has no database" do
    # `Accounts.default_org/0` reports a failed read as `:error` (a miss is
    # `nil`), so this is the outage itself, asserted rather than assumed.
    assert :error = Accounts.default_org()
  end

  # #1335, the request-path twin of #1288: this module's no-checkout reads
  # RAISE, which Ash wraps into the `{:error, _}` that `lookup/2` judges — so
  # every `fetch_org/1` test below exercises only the raise half. A read into a
  # pool process that is not alive EXITS instead (seen on CI as
  # `DBConnection.Holder.checkout ... (EXIT) no process` out of this very
  # file), and an uncaught exit skips `fetch_org/1`'s `:error` branch entirely
  # to crash the caller. The guard is tested here directly, where the exit can
  # be forced deterministically — same approach as `Config.Report.probe/2`'s
  # tests (#1288).
  describe "read_degrading_exit/1" do
    test "passes a successful read's answer through untouched" do
      assert Tenant.read_degrading_exit(fn -> {:ok, :answer} end) == {:ok, :answer}
      assert Tenant.read_degrading_exit(fn -> nil end) == nil
    end

    test "degrades an exit to :error, fetch_org/1's could-not-ask answer" do
      assert Tenant.read_degrading_exit(fn -> exit(:noproc) end) == :error
    end

    test "an exit from a real dead-process call is caught, not just exit/1" do
      # `exit/1` above proves the clause; this proves the shape it exists for:
      # a `:gen_server.call` into a pid that has already stopped — what a pool
      # crashed or still restarting looks like from the calling process.
      {:ok, pid} = Agent.start(fn -> :ok end)
      :ok = Agent.stop(pid)

      assert Tenant.read_degrading_exit(fn -> GenServer.call(pid, :anything) end) == :error
    end

    test "a raise is not caught — Ash wraps those, and anything else is a bug" do
      assert_raise RuntimeError, fn ->
        Tenant.read_degrading_exit(fn -> raise "not an outage shape" end)
      end
    end
  end

  describe "fetch_org/1 with strict host matching off (the default)" do
    setup do: strict!(false)

    test "a failed lookup falls back to the default org, exactly as a miss does" do
      # The bug: this used to be `:error`, and `SetTenant` refused the request
      # with a 404 naming a control that is not even on.
      assert {:ok, org} = Tenant.fetch_org(unknown_host())
      assert org.id == Accounts.default_org_id()
    end

    test "so does a host that is a real tenant's, which nothing here can tell apart" do
      # Resolution cannot distinguish "org `acme` exists" from "could not ask"
      # while the database is down, and with the fallback in play it does not
      # have to: every unresolvable host lands on the default org, which on the
      # single-host install this fallback exists for is the only org there is.
      assert {:ok, org} = Tenant.fetch_org("acme.#{Tenant.base_host()}")
      assert org.id == Accounts.default_org_id()
    end

    test "the org is the id-only struct, which is all a cache-served request needs" do
      # `default_org/0`'s own read fails too during an outage. The synthetic
      # struct keeps `current_org_id/1` — and therefore every cache key the
      # delivery path builds — working.
      assert {:ok, %Accounts.Organization{id: id}} = Tenant.fetch_org(unknown_host())
      assert id == Accounts.default_org_id()
    end

    test "a socket connect info with no host resolves the same way" do
      assert {:ok, org} = Tenant.fetch_org_from_connect_info(%{})
      assert org.id == Accounts.default_org_id()
    end
  end

  describe "fetch_org/1 with strict host matching on" do
    setup do: strict!(true)

    test "a failed lookup is :unavailable — refused, but not as 'no such host'" do
      # Still refused: falling back would serve the default org's content on an
      # unrecognized host, which is the leak #563 exists to prevent. But it is
      # refused as a different thing, so the caller can say 503 rather than 404.
      assert :unavailable = Tenant.fetch_org(unknown_host())
    end

    test "the canonical base host is served, as its docstring has always promised" do
      base = cold_base_host!()

      assert {:ok, org} = Tenant.fetch_org(base)
      assert org.id == Accounts.default_org_id()
    end

    test "a rooted/uppercased spelling of the base host is served too" do
      base = cold_base_host!()

      assert {:ok, org} = Tenant.fetch_org(String.upcase(base) <> ".")
      assert org.id == Accounts.default_org_id()
    end
  end

  describe "SetTenant" do
    test "serves the default org during an outage when strict matching is off" do
      strict!(false)
      conn = plug_call(unknown_host())

      # The #341 promise: this plug halts above the router, so a refusal here is
      # a refusal *before* the content cache gets asked.
      refute conn.halted
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "answers a retryable 503 under strict matching, not a 404" do
      strict!(true)
      conn = plug_call(unknown_host())

      assert conn.status == 503
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["2"]
      refute Map.has_key?(conn.assigns, :current_org)
    end

    test "the 503 body does not claim the host is unknown" do
      strict!(true)
      conn = plug_call(unknown_host())

      # A 404 here is a lie about a host that may well exist, and it is the lie
      # a CDN caches and an uptime monitor pages the tenant about.
      refute conn.resp_body =~ "does not serve the requested host"
      assert conn.resp_body =~ "cannot be resolved"
    end

    test "the 503 is plain text, so it carries no default-site chrome either" do
      strict!(true)
      conn = plug_call(unknown_host())

      assert conn |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "text/plain"
      refute conn.resp_body =~ "<html"
    end

    test "a health probe still answers, so an outage cannot mark the deployment unhealthy" do
      strict!(true)
      conn = plug_call("10.0.1.7", "/up")

      # The host-agnostic exemption covers both refusals. `HealthController`
      # reports a database that is down; this plug replacing that answer with
      # its own opinion of the Host header is the one failure mode the
      # exemption exists to prevent.
      refute conn.halted
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "the billing webhook stays exempt during an outage as well" do
      strict!(true)
      conn = plug_call(unknown_host(), "/billing/webhooks/stripe", :post)

      refute conn.halted
      assert conn.assigns.current_org.id == Accounts.default_org_id()
    end

    test "the refusal alert does not fire — it would name TENANT_STRICT_HOST for a DB outage" do
      strict!(true)
      ref = watch_refusal_alert!()

      assert plug_call(unknown_host()).status == 503

      # #678 counts hosts this deployment does not serve, and every message it
      # emits names `TENANT_STRICT_HOST` as the cause. An unreachable database
      # is neither — and with strict matching off, the setting it named was not
      # even on.
      refute_receive {^ref, _measurements, _metadata}
    end
  end

  describe "the LiveView mount hook" do
    test "raises the 503 twin under strict matching" do
      strict!(true)
      socket = %Phoenix.LiveView.Socket{host_uri: URI.parse("https://#{unknown_host()}/")}

      error =
        assert_raise Tenant.UnavailableError, fn ->
          KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)
        end

      assert Plug.Exception.status(error) == 503
    end

    test "mounts on the default org during an outage when strict matching is off" do
      strict!(false)
      socket = %Phoenix.LiveView.Socket{host_uri: URI.parse("https://#{unknown_host()}/")}

      assert {:cont, socket} =
               KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)

      assert socket.assigns.current_org.id == Accounts.default_org_id()
    end
  end

  describe "the sockets" do
    test "the GraphQL socket refuses under strict matching without alerting" do
      strict!(true)
      ref = watch_refusal_alert!()

      info = %{uri: URI.parse("wss://#{unknown_host()}/ws/gql")}

      # A socket has no 503 to send, so the connect is refused either way — the
      # difference is that an outage does not feed the flood alert.
      assert :error = KilnCMSWeb.GraphqlSocket.connect(%{}, %Phoenix.Socket{}, info)
      refute_receive {^ref, _measurements, _metadata}
    end
  end
end
