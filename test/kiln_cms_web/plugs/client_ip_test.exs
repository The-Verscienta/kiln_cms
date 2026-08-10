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

  `async: false`: both `:trusted_proxies` and the warning latch are global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias KilnCMSWeb.Plugs.ClientIp

  setup do
    previous = Application.get_env(:kiln_cms, :trusted_proxies)
    ClientIp.reset_forwarding_warning()

    on_exit(fn ->
      ClientIp.reset_forwarding_warning()

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
      # The default, and the one that protects production.
      assert ClientIp.resolve(@x_headers, @proxy) == @proxy
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

    # The invariant the docstring states out loud: two copies of "when do we
    # believe X-Forwarded-For" that drift would give the socket a different
    # client identity than the HTTP request that preceded it. Asserted as
    # equality between the two doors, so a change to either alone goes red.
    test "agrees with call/2 on the same request, trusted and not" do
      for proxies <- [[], ["10.0.0.0/8"], ["192.168.0.0/16"], ["not-a-cidr"]] do
        trust(proxies)
        ClientIp.reset_forwarding_warning()

        plug_answer =
          capture_log(fn ->
            send(
              self(),
              {:ip, "203.0.113.7" |> forwarded() |> ClientIp.call([]) |> Map.fetch!(:remote_ip)}
            )
          end)
          |> then(fn _log -> receive do: ({:ip, ip} -> ip) end)

        assert ClientIp.resolve(@x_headers, @proxy) == plug_answer,
               "socket and plug disagreed with trusted_proxies=#{inspect(proxies)}"
      end
    end
  end
end
