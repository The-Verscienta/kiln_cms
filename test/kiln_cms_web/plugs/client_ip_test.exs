defmodule KilnCMSWeb.Plugs.ClientIpTest do
  @moduledoc """
  `KilnCMSWeb.Plugs.ClientIp` — proxy-aware `remote_ip`, and the warning that
  makes the unset-behind-a-proxy trap visible (#564).

  Rate limiting keys on `remote_ip`. Behind a reverse proxy with
  `TRUSTED_PROXIES` unset, every request carries the proxy's address and every
  bucket collapses to one counter for the whole internet — an availability
  problem and a security one, with nothing to show for it. The plug cannot fix
  that (trusting `X-Forwarded-For` unconditionally is strictly worse), so it says
  so instead.

  `async: false`: `:trusted_proxies`, `:client_ip_header` and the warning
  latches are global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias KilnCMSWeb.Plugs.ClientIp

  # What the test config says, restored after each test rather than a captured
  # value (memory of #1614: a captured `nil` faithfully re-applies a leak).
  @configured_header Application.compile_env(:kiln_cms, :client_ip_header)

  setup do
    previous = Application.get_env(:kiln_cms, :trusted_proxies)
    ClientIp.reset_forwarding_warning()
    ClientIp.reset_refused_header_warning()

    on_exit(fn ->
      ClientIp.reset_forwarding_warning()
      ClientIp.reset_refused_header_warning()

      case @configured_header do
        nil -> Application.delete_env(:kiln_cms, :client_ip_header)
        configured -> Application.put_env(:kiln_cms, :client_ip_header, configured)
      end

      case previous do
        nil -> Application.delete_env(:kiln_cms, :trusted_proxies)
        prev -> Application.put_env(:kiln_cms, :trusted_proxies, prev)
      end
    end)

    :ok
  end

  # The RemoteIp options cache is keyed on the proxy list itself, so switching
  # lists rebuilds rather than serving a previous test's compiled config.
  defp trust(proxies), do: Application.put_env(:kiln_cms, :trusted_proxies, proxies)

  defp forwarded(client_ip) do
    :get
    |> conn("/")
    |> Map.put(:remote_ip, {10, 0, 0, 1})
    |> put_req_header("x-forwarded-for", client_ip)
  end

  describe "with no trusted proxies (the default)" do
    setup do
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      :ok
    end

    test "leaves remote_ip as the direct peer, ignoring X-Forwarded-For" do
      # Captured only to keep the warning out of the suite's output; the
      # behaviour under test is the untouched remote_ip.
      {conn, _log} = with_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end)

      assert conn.remote_ip == {10, 0, 0, 1}
    end

    test "warns, naming the variable and what it costs" do
      log = capture_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end)

      assert log =~ "TRUSTED_PROXIES"
      assert log =~ "rate limiting"
    end

    # The plug runs before the rate limiter, so a line per request would let
    # anyone who can set a header amplify log volume.
    test "warns only once per node, however many forwarded requests arrive" do
      log =
        capture_log(fn ->
          for i <- 1..25, do: ClientIp.call(forwarded("203.0.113.#{rem(i, 250)}"), [])
        end)

      assert log |> String.split("TRUSTED_PROXIES is unset") |> length() == 2
    end

    # Paired with the warning tests: silence here is only meaningful because the
    # same setup DOES warn once a forwarding header is present.
    test "stays silent when no request is forwarded, then warns when one is" do
      assert capture_log(fn -> ClientIp.call(conn(:get, "/"), []) end) == ""

      assert capture_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end) =~
               "TRUSTED_PROXIES"
    end

    # The header is attacker-controlled and adds nothing: that it arrived at all
    # is the signal, so its contents must not reach the log.
    test "does not echo the header value into the log" do
      log = capture_log(fn -> ClientIp.call(forwarded("203.0.113.9, 198.51.100.4"), []) end)

      assert log =~ "TRUSTED_PROXIES"
      refute log =~ "203.0.113.9"
    end
  end

  describe "with a malformed proxy list" do
    setup do
      trust([" 172.16.0.0/12"])
      on_exit(fn -> :persistent_term.erase({ClientIp, :warned_bad_proxies?}) end)
      :persistent_term.erase({ClientIp, :warned_bad_proxies?})
      :ok
    end

    # `RemoteIp.init/1` raises on a bad CIDR, and this plug sits in the endpoint
    # ahead of the router — unrescued, that 500s every request including `/up`,
    # forever, because the opts cache is only written on success.
    test "degrades to trusting nothing instead of raising" do
      {conn, log} =
        with_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end)

      assert conn.remote_ip == {10, 0, 0, 1}
      assert log =~ "TRUSTED_PROXIES could not be parsed"
    end

    test "keeps serving on every subsequent request" do
      for _ <- 1..5 do
        conn = with_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end) |> elem(0)
        assert conn.remote_ip == {10, 0, 0, 1}
      end
    end
  end

  describe "with trusted proxies configured" do
    setup do
      trust(["10.0.0.0/8"])
      :ok
    end

    test "rewrites remote_ip to the forwarded client" do
      conn = ClientIp.call(forwarded("203.0.113.9"), [])

      assert conn.remote_ip == {203, 0, 113, 9}
    end

    test "does not warn — the header is being honoured" do
      {conn, log} = with_log(fn -> ClientIp.call(forwarded("203.0.113.9"), []) end)

      # The rewrite is what makes the silence meaningful: the plug ran and
      # honoured the header, rather than being silent because nothing happened.
      assert conn.remote_ip == {203, 0, 113, 9}
      refute log =~ "TRUSTED_PROXIES"
    end
  end

  describe "the forwarding-header set" do
    # The detection mirrors `RemoteIp`'s default headers. Asserted against the
    # library rather than a second literal, so a `remote_ip` bump that adds a
    # header cannot silently re-narrow the detection below what is honoured.
    test "matches what RemoteIp actually honours" do
      for header <- RemoteIp.Options.default(:headers) do
        ClientIp.reset_forwarding_warning()
        Application.put_env(:kiln_cms, :trusted_proxies, [])

        log =
          capture_log(fn ->
            :get |> conn("/") |> put_req_header(header, "203.0.113.9") |> ClientIp.call([])
          end)

        assert log =~ "TRUSTED_PROXIES", "expected #{header} to be detected"
      end
    end
  end

  # `resolve/2` is the socket half of the same rule (#715, #934). `call/2` is a
  # plug and cannot run on a `/live` handshake, so the endpoint hands the
  # transport's `:x_headers` and `:peer_data` here instead — and the whole point
  # of the socket sharing a bucket with the HTTP request that preceded it is
  # that the two answer identically.
  #
  # Nothing pinned it until now. Deleting the `proxies() == []` guard makes
  # `resolve/2` always believe `X-Forwarded-For`, so every socket sign-in bucket
  # keys on an attacker-supplied header — rotate the header, rotate the bucket,
  # unlimited `/sign-in` brute force — and the suite stayed fully green.
  describe "resolve/2 (the socket half)" do
    @proxy {10, 0, 0, 1}
    @client {203, 0, 113, 7}
    @x_headers [{"x-forwarded-for", "203.0.113.7"}]

    test "with no trusted proxies the header is ignored and the peer stands" do
      # The default, and the one that protects production. Captured only to keep
      # the forwarding warning out of the suite's output, as every sibling does.
      {answer, _log} = with_log(fn -> ClientIp.resolve(@x_headers, @proxy) end)

      assert answer == @proxy
    end

    test "with the peer inside a trusted proxy the forwarded client is used" do
      trust(["10.0.0.0/8"])

      assert ClientIp.resolve(@x_headers, @proxy) == @client
    end

    # Worth pinning because it is the opposite of what the name suggests, and I
    # asserted the wrong thing here first. `RemoteIp`'s `:proxies` names *which
    # hops to skip while walking the forwarded chain*, not *who is allowed to
    # forward* — no peer is consulted. So once the list is non-empty the header
    # is honoured whatever the peer's address, and `TRUSTED_PROXIES` must be set
    # only on a deployment that really is behind a proxy. Both doors do this, so
    # the socket is no weaker than the plug; the config is the boundary.
    test "any non-empty list honours the header, whatever the peer's address" do
      trust(["192.168.0.0/16"])

      assert ClientIp.resolve(@x_headers, @proxy) == @client
    end

    # The configured CIDRs have to actually be *used*, not merely be non-empty.
    # Every private range is in `RemoteIp`'s hardcoded reserved set and is
    # skipped whatever `:proxies` says, so a single-hop chain behind a private
    # peer answers the same for any valid list — a regression that passed the
    # wrong list through would not show. A public-IP load balancer is where the
    # list does the work: two hops, and only the configured CIDR distinguishes
    # the client from the proxy that forwarded it.
    test "the configured CIDRs decide which hop is the client" do
      chain = [{"x-forwarded-for", "203.0.113.7, 198.51.100.4"}]

      trust(["198.51.100.0/24"])
      assert ClientIp.resolve(chain, @proxy) == @client

      # The same chain with an unrelated list: the LB is no longer a known hop,
      # so it is taken for the client — one bucket for the whole internet, which
      # is #564's trap arriving through a *configured* deployment.
      trust(["10.0.0.0/8"])
      assert ClientIp.resolve(chain, @proxy) == {198, 51, 100, 4}
    end

    # A malformed CIDR degrades to "trust nothing", the same direction `call/2`
    # fails — a spoofable header is never honoured on the way down.
    test "a malformed proxy list falls back to the peer" do
      trust(["not-a-cidr"])

      assert ClientIp.resolve(@x_headers, @proxy) == @proxy
    end

    test "no header and no peer is nil, not a guess" do
      trust(["10.0.0.0/8"])

      assert ClientIp.resolve([], nil) == nil
    end

    # The docstring promises RFC 7239 `Forwarded:` cannot reach here, because
    # LiveView's `:x_headers` is exactly the `x-`-prefixed headers. That is an
    # upstream property, and `resolve/2` *would* honour the header if handed one
    # — so the guarantee lives in the transport, and this is what pins it.
    test "the transport hands over only x- headers, so Forwarded cannot arrive" do
      x_headers =
        :get
        |> conn("/")
        |> put_req_header("forwarded", "for=203.0.113.7")
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> Phoenix.Socket.Transport.connect_info(KilnCMSWeb.Endpoint, [:x_headers], [])
        |> Map.fetch!(:x_headers)

      assert Enum.all?(x_headers, fn {name, _value} -> String.starts_with?(name, "x-") end)
      refute Enum.any?(x_headers, fn {name, _value} -> name == "forwarded" end)
    end

    # The invariant the docstring states out loud: two copies of "when do we
    # believe X-Forwarded-For" that drift would give the socket a different
    # client identity than the HTTP request that preceded it. Asserted as
    # equality between the two doors, so a change to either alone goes red.
    test "agrees with call/2 on the same request, trusted and not" do
      for proxies <- [[], ["10.0.0.0/8"], ["192.168.0.0/16"], ["not-a-cidr"]] do
        trust(proxies)
        ClientIp.reset_forwarding_warning()

        {plug_answer, _log} =
          with_log(fn ->
            "203.0.113.7" |> forwarded() |> ClientIp.call([]) |> Map.fetch!(:remote_ip)
          end)

        assert ClientIp.resolve(@x_headers, @proxy) == plug_answer,
               "socket and plug disagreed with trusted_proxies=#{inspect(proxies)}"
      end
    end
  end

  # #1548. A platform header is a request header trusted with no peer check, so
  # the cases that matter most are the ones where it must NOT be believed.
  describe "CLIENT_IP_HEADER (a platform's own client-address header)" do
    @fly %{"FLY_APP_NAME" => "kiln", "FLY_MACHINE_ID" => "148e123a"}
    @railway %{"RAILWAY_SERVICE_ID" => "svc", "RAILWAY_ENVIRONMENT_ID" => "env"}
    @do_app %{"APP_ID" => "8a3f9c2e-1b4d-4e5f-9a6b-7c8d9e0f1a2b"}

    defp with_header(header, value) do
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header(header, value)
    end

    defp configure(env) do
      Application.put_env(:kiln_cms, :client_ip_header, ClientIp.header_setting(env))
    end

    test "unset (the default): the header is ignored and the peer stands" do
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      assert ClientIp.header_setting(%{}) == nil
      assert ClientIp.header_setting(Map.put(@fly, "CLIENT_IP_HEADER", "  ")) == nil

      configure(@fly)

      # `X-Real-IP` is also a forwarding header, so it trips the #564 warning.
      capture_log(fn ->
        for header <- ["fly-client-ip", "x-real-ip", "do-connecting-ip"] do
          conn = ClientIp.call(with_header(header, "203.0.113.9"), [])
          assert conn.remote_ip == {10, 0, 0, 1}, "#{header} believed without CLIENT_IP_HEADER"
        end
      end)
    end

    test "on the platform it names, the header is the client address" do
      for {header, markers} <- [
            {"fly-client-ip", @fly},
            {"x-real-ip", @railway},
            {"do-connecting-ip", @do_app}
          ] do
        # Case-insensitive, as HTTP header names are; Plug lowercases them.
        configure(Map.put(markers, "CLIENT_IP_HEADER", String.upcase(header)))

        assert ClientIp.header_setting(Map.put(markers, "CLIENT_IP_HEADER", header)) ==
                 {:header, header}

        assert ClientIp.call(with_header(header, "203.0.113.9"), []).remote_ip ==
                 {203, 0, 113, 9}

        assert ClientIp.call(with_header(header, " 2001:db8::7 "), []).remote_ip ==
                 {8193, 3512, 0, 0, 0, 0, 0, 7}
      end
    end

    test "it takes precedence over TRUSTED_PROXIES, and only that one header is believed" do
      trust(["10.0.0.0/8"])
      configure(Map.put(@fly, "CLIENT_IP_HEADER", "fly-client-ip"))

      conn =
        "198.51.100.4"
        |> forwarded()
        |> put_req_header("fly-client-ip", "203.0.113.9")
        |> put_req_header("x-real-ip", "192.0.2.1")
        |> ClientIp.call([])

      assert conn.remote_ip == {203, 0, 113, 9}
    end

    test "a request without the header falls through to the proxy path" do
      configure(Map.put(@fly, "CLIENT_IP_HEADER", "fly-client-ip"))

      trust(["10.0.0.0/8"])
      assert ClientIp.call(forwarded("198.51.100.4"), []).remote_ip == {198, 51, 100, 4}

      Application.put_env(:kiln_cms, :trusted_proxies, [])
      {conn, _log} = with_log(fn -> ClientIp.call(forwarded("198.51.100.4"), []) end)
      assert conn.remote_ip == {10, 0, 0, 1}
    end

    test "anything but exactly one address is not the proxy's and is ignored" do
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      configure(Map.put(@railway, "CLIENT_IP_HEADER", "x-real-ip"))

      capture_log(fn ->
        for value <- [
              "203.0.113.9, 198.51.100.4",
              "unknown",
              "",
              "203.0.113.9:443",
              "[2001:db8::7]"
            ] do
          assert ClientIp.call(with_header("x-real-ip", value), []).remote_ip == {10, 0, 0, 1},
                 "believed #{inspect(value)}"
        end
      end)
    end

    # The spoofing case: the variable copied onto a host where clients reach the
    # app directly. Any client could then send the header and pick its bucket.
    test "without the platform's markers it is refused, logged once, and ignored" do
      Application.put_env(:kiln_cms, :trusted_proxies, [])

      for {header, markers} <- [
            {"fly-client-ip", @fly},
            {"x-real-ip", @railway},
            {"do-connecting-ip", @do_app}
          ],
          missing <- Map.keys(markers) do
        env = markers |> Map.delete(missing) |> Map.put("CLIENT_IP_HEADER", header)
        assert {:refused, ^header, reason} = ClientIp.header_setting(env)
        assert reason =~ missing
      end

      # Another platform's markers are not this one's.
      assert {:refused, "fly-client-ip", _} =
               ClientIp.header_setting(Map.put(@railway, "CLIENT_IP_HEADER", "fly-client-ip"))

      # A placeholder is not an App Platform app id.
      assert {:refused, "do-connecting-ip", _} =
               ClientIp.header_setting(%{
                 "CLIENT_IP_HEADER" => "do-connecting-ip",
                 "APP_ID" => "${APP_ID}"
               })

      configure(%{"CLIENT_IP_HEADER" => "fly-client-ip"})
      ClientIp.reset_refused_header_warning()

      {conn, log} =
        with_log(fn -> ClientIp.call(with_header("fly-client-ip", "203.0.113.9"), []) end)

      assert conn.remote_ip == {10, 0, 0, 1}
      assert log =~ "CLIENT_IP_HEADER=fly-client-ip"
      assert log =~ "FLY_APP_NAME and FLY_MACHINE_ID are not set"
      refute log =~ "203.0.113.9"

      assert capture_log(fn ->
               ClientIp.call(with_header("fly-client-ip", "203.0.113.9"), [])
             end) == ""
    end

    test "a header no platform is known to set is refused" do
      for header <- ["x-forwarded-for", "true-client-ip", "cf-connecting-ip", "forwarded"] do
        env = Map.merge(@fly, Map.merge(@railway, @do_app))

        assert {:refused, ^header, reason} =
                 ClientIp.header_setting(Map.put(env, "CLIENT_IP_HEADER", header))

        assert reason =~ "Supported: do-connecting-ip, fly-client-ip, x-real-ip"
      end
    end

    test "the socket path agrees with the plug" do
      configure(Map.put(@railway, "CLIENT_IP_HEADER", "x-real-ip"))
      x_headers = [{"x-real-ip", "203.0.113.9"}, {"x-forwarded-for", "192.0.2.1"}]

      assert ClientIp.resolve(x_headers, {10, 0, 0, 1}) == {203, 0, 113, 9}

      assert ClientIp.call(with_header("x-real-ip", "203.0.113.9"), []).remote_ip ==
               {203, 0, 113, 9}

      # Unconfigured, the socket ignores it exactly as the plug does.
      Application.delete_env(:kiln_cms, :client_ip_header)
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      {answer, _log} = with_log(fn -> ClientIp.resolve(x_headers, {10, 0, 0, 1}) end)
      assert answer == {10, 0, 0, 1}
    end
  end
end
