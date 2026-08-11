defmodule KilnCMSWeb.LiveTenantPinTest do
  @moduledoc """
  A connected LiveView mount resolves its tenant from the host it connected on,
  not from the one the client names (#654).

  `socket.host_uri` on a connected mount is rebuilt from the client's join
  payload — only its *path* is matched against the router, the host is copied
  verbatim — and `check_origin` admits every subdomain of the base host,
  registered as an org or not. So before this, a client served `orga`'s page
  could join naming `orgb` and `:assign_current_org` would hand it org B.

  `/live` now carries `connect_info: [:uri]` like the three raw sockets, and the
  hook resolves from that, refusing a claim that names a different org.

  `async: false` — several tests flip `:tenant_strict_host`, which is
  application env and therefore visible to every concurrently running test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  setup do
    # Host resolution is Cachex-backed and is NOT sandboxed, so an entry written
    # by one test outlives the transaction that created the org. Clear it either
    # side rather than relying on the unique slugs to hide the overlap.
    KilnCMS.Cache.Hosts.clear()
    on_exit(&KilnCMS.Cache.Hosts.clear/0)
    :ok
  end

  defp host_for(org), do: "#{org.slug}.#{Tenant.base_host()}"

  defp strict!(value) do
    previous = Application.get_env(:kiln_cms, :tenant_strict_host)
    Application.put_env(:kiln_cms, :tenant_strict_host, value)
    on_exit(fn -> Application.put_env(:kiln_cms, :tenant_strict_host, previous) end)
  end

  # The socket state `Phoenix.LiveView.Channel` builds for a CONNECTED mount:
  # `host_uri` from the client's join payload, `connect_info` from the transport,
  # `transport_pid` set. A bare `%Socket{}` (no transport) is the disconnected
  # mount, which is a real HTTP request whose host the endpoint validated.
  defp connected_socket(connected_host, claimed_host) do
    %Phoenix.LiveView.Socket{
      host_uri: claim(claimed_host),
      transport_pid: self(),
      private: %{connect_info: %{uri: URI.parse("https://#{connected_host}/membership")}}
    }
  end

  defp claim(nil), do: :not_mounted_at_router
  defp claim(host), do: URI.parse("https://#{host}/membership")

  defp mount(socket),
    do: KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)

  describe "a connected mount" do
    setup do
      %{a: org("pin-a"), b: org("pin-b")}
    end

    test "resolves the org of the host it connected on", %{a: a} do
      assert {:cont, socket} = mount(connected_socket(host_for(a), host_for(a)))
      assert socket.assigns.current_org.id == a.id
    end

    test "refuses a claim naming another org's host", %{a: a, b: b} do
      # The attack from #654: connected on org A, joins claiming org B.
      error =
        assert_raise Tenant.HostMismatchError, fn ->
          mount(connected_socket(host_for(a), host_for(b)))
        end

      assert error.claimed == host_for(b)
      assert error.connected == host_for(a)

      # 4xx is what `Phoenix.LiveView.Channel` turns into a client reload rather
      # than a crash report, so the status is load-bearing, not decoration.
      assert Plug.Exception.status(error) == 404
    end

    test "ignores the claim rather than trusting it, so a claim it cannot resolve is refused",
         %{a: a} do
      strict!(true)

      assert_raise Tenant.HostMismatchError, fn ->
        mount(connected_socket(host_for(a), "no-such-org.#{Tenant.base_host()}"))
      end
    end

    test "accepts a claim that spells the same org's host differently", %{a: a} do
      # Case-folded and rooted forms name the same host, and a `Host`-rewriting
      # proxy makes the two sides differ textually while naming one org. The
      # comparison is by resolved org precisely so neither is a refusal.
      assert {:cont, socket} =
               mount(connected_socket(host_for(a), String.upcase(host_for(a)) <> "."))

      assert socket.assigns.current_org.id == a.id
    end

    test "accepts a custom domain and its subdomain as the same org" do
      org =
        org("pin-custom", custom_domain: "pin-custom-#{System.unique_integer([:positive])}.test")

      assert {:cont, socket} = mount(connected_socket(org.custom_domain, host_for(org)))
      assert socket.assigns.current_org.id == org.id
    end

    test "has nothing to contradict when the client claims no host at all", %{a: a} do
      # A join carrying no URL leaves `host_uri` at `:not_mounted_at_router`.
      # That is "no claim", not "a claim that disagreed" — and the org still
      # comes from the connected host, so it is not a way to reach another org.
      assert {:cont, socket} = mount(connected_socket(host_for(a), nil))
      assert socket.assigns.current_org.id == a.id
    end

    test "is refused when the transport supplied no request URI", %{a: a} do
      # Only reachable if the endpoint's `connect_info: [:uri]` goes missing —
      # which is exactly when falling back to the client's claim would be worst.
      socket = %Phoenix.LiveView.Socket{
        host_uri: claim(host_for(a)),
        transport_pid: self(),
        private: %{connect_info: %{}}
      }

      assert_raise Tenant.UnknownHostError, fn -> mount(socket) end
    end

    test "is refused when the connected host resolves to no org under strict matching" do
      strict!(true)
      unknown = "no-such-org-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"

      assert_raise Tenant.UnknownHostError, fn -> mount(connected_socket(unknown, unknown)) end
    end
  end

  describe "a disconnected mount" do
    test "resolves from host_uri, which the endpoint built from a validated Host header" do
      a = org("pin-disconnected")
      socket = %Phoenix.LiveView.Socket{host_uri: claim(host_for(a))}

      assert {:cont, socket} = mount(socket)
      assert socket.assigns.current_org.id == a.id
    end

    test "is not host-scoped when there is no host, so it is not refused" do
      strict!(true)
      socket = %Phoenix.LiveView.Socket{host_uri: :not_mounted_at_router}

      assert {:cont, socket} = mount(socket)
      assert socket.assigns.current_org.id == Accounts.default_org_id()
    end
  end

  describe "the endpoint" do
    test "declares :uri on both of /live's transports" do
      # The hook refuses a connected mount without it, so this declaration is
      # the whole mechanism — and it is a line in another file that nothing else
      # would fail on if it were dropped.
      {_path, _handler, opts} =
        Enum.find(KilnCMSWeb.Endpoint.__sockets__(), &match?({"/live", _, _}, &1))

      for transport <- [:websocket, :longpoll] do
        assert :uri in Keyword.fetch!(opts, transport)[:connect_info],
               "/live's #{transport} transport must carry :uri in connect_info (#654)"
      end
    end
  end

  describe "end to end through the router" do
    setup do
      %{a: org("pin-e2e-a"), b: org("pin-e2e-b")}
    end

    test "a join whose url names a different org's host is refused", %{a: a, b: b} do
      # `Phoenix.LiveViewTest` derives both the join `url:` and `connect_info`
      # from the conn, so the split #654 describes is staged by serving the page
      # on org A's host and overriding `connect_info` to keep it there while the
      # conn's host — and therefore the claim — moves to org B.
      served =
        Phoenix.ConnTest.build_conn() |> Map.put(:host, host_for(a)) |> get(~p"/membership")

      attack =
        %{served | host: host_for(b)}
        |> Plug.Conn.put_private(:live_view_connect_info, %{
          uri: URI.parse("https://#{host_for(a)}/membership")
        })

      # The refusal reaches the client as `plug_status: 404` — a reload
      # instruction, which is what LiveView's channel makes of a 4xx raised
      # during mount. The socket never gets org B, and it costs no crash report.
      assert {%{reason: "reload", status: 404}, _call} = catch_exit(live(attack))
    end

    test "a join whose url names the host that served it connects as that org", %{a: a} do
      served =
        Phoenix.ConnTest.build_conn() |> Map.put(:host, host_for(a)) |> get(~p"/membership")

      assert {:ok, view, _html} = live(served)

      # Not just "it mounted": a silent fall-through to the default org is the
      # cross-tenant write this exists to prevent, and it would still be `:ok`.
      assert :sys.get_state(view.pid).socket.assigns.current_org.id == a.id
    end
  end
end
