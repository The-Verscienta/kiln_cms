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
end
