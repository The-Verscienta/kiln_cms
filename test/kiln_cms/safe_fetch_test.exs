defmodule KilnCMS.SafeFetchTest do
  @moduledoc """
  The redirect-following surface added for the link checker (#474).

  `SafeFetch` still has no general test suite (#753); these cover the part that
  is new and the part that is dangerous, which is the same part. Following a
  redirect means dialling an address the caller never chose, so every hop has to
  go back through `SafeUrl` — the moment it does not, an open redirect on a
  trusted host is a path to the metadata service.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.SafeFetch

  @url "https://example.test/start"

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp opts(extra \\ []), do: Keyword.merge([req_options: [plug: {Req.Test, __MODULE__}]], extra)

  defp redirect_to(conn, status, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(status, "")
  end

  describe "by default nothing is followed" do
    test "a 301 comes back as a 301" do
      stub(fn conn -> redirect_to(conn, 301, "/moved") end)

      assert {:ok, %{status: 301}} = SafeFetch.get(@url, opts())
    end
  end

  describe "with :max_redirects" do
    test "the chain is followed to its destination" do
      stub(fn conn ->
        case conn.request_path do
          "/start" -> redirect_to(conn, 302, "/second")
          "/second" -> redirect_to(conn, 302, "/third")
          "/third" -> Plug.Conn.send_resp(conn, 200, "arrived")
        end
      end)

      assert {:ok, %{status: 200, body: "arrived"}} =
               SafeFetch.get(@url, opts(max_redirects: 5))
    end

    test "a relative Location is merged against the URL that sent it" do
      stub(fn conn ->
        case conn.request_path do
          "/start" -> redirect_to(conn, 301, "elsewhere")
          "/elsewhere" -> Plug.Conn.send_resp(conn, 200, "ok")
        end
      end)

      assert {:ok, %{status: 200}} = SafeFetch.get(@url, opts(max_redirects: 2))
    end

    test "running out of hops returns the 3xx, not an error" do
      # The distinction a link checker needs: "the chain is too long" is a fact
      # about the link, while an error is a fact about us refusing to dial.
      stub(fn conn -> redirect_to(conn, 302, "/#{System.unique_integer([:positive])}") end)

      assert {:ok, %{status: 302}} = SafeFetch.get(@url, opts(max_redirects: 2))
    end

    test "every hop is re-validated, so a redirect into a private address is refused" do
      # The whole reason redirects are followed by hand. Handing the chain to the
      # HTTP client would resolve this hop inside the client, past every check.
      stub(fn conn ->
        case conn.request_path do
          "/start" -> redirect_to(conn, 302, "http://127.0.0.1/metadata")
          _other -> Plug.Conn.send_resp(conn, 200, "should never be reached")
        end
      end)

      assert {:error, message} = SafeFetch.get(@url, opts(max_redirects: 3))
      assert message =~ "blocked redirect from https://example.test/start"
      assert message =~ "private or link-local"
    end

    test "a POST redirected with 303 becomes a GET and loses its body" do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:hit, conn.method, conn.request_path, body})

        case conn.request_path do
          "/start" -> redirect_to(conn, 303, "/after")
          "/after" -> Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert {:ok, %{status: 200}} = SafeFetch.post(@url, "payload", opts(max_redirects: 2))

      assert_received {:hit, "POST", "/start", "payload"}
      # Replaying a body against a target the caller never chose is how a
      # redirect becomes a request forgery.
      assert_received {:hit, "GET", "/after", ""}
    end

    test "a HEAD stays a HEAD across a 303" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:hit, conn.method})

        case conn.request_path do
          "/start" -> redirect_to(conn, 303, "/after")
          "/after" -> Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert {:ok, %{status: 200}} = SafeFetch.head(@url, opts(max_redirects: 2))

      assert_received {:hit, "HEAD"}
      assert_received {:hit, "HEAD"}
    end

    test "credentials are dropped when the host changes, and kept when it does not" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:auth, conn.host, Plug.Conn.get_req_header(conn, "authorization")})

        case conn.request_path do
          "/start" -> redirect_to(conn, 302, "/same-host")
          "/same-host" -> redirect_to(conn, 302, "https://elsewhere.test/end")
          "/end" -> Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert {:ok, %{status: 200}} =
               SafeFetch.get(
                 @url,
                 opts(max_redirects: 3, headers: [{"authorization", "Bearer s"}])
               )

      assert_received {:auth, "example.test", ["Bearer s"]}
      assert_received {:auth, "example.test", ["Bearer s"]}
      # Whoever controls a `Location` must not be handed the caller's secret.
      assert_received {:auth, "elsewhere.test", []}
    end
  end

  describe ":truncate_body" do
    test "turns an over-length body into a truncated response instead of an error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 5_000)) end)

      assert {:error, message} = SafeFetch.get(@url, opts(max_bytes: 1_000))
      assert message =~ "exceeded 1000 bytes"

      assert {:ok, %{status: 200, body: body}} =
               SafeFetch.get(@url, opts(max_bytes: 1_000, truncate_body: true))

      assert byte_size(body) == 1_000
    end
  end

  # #753's acceptance list. These are the properties the module exists for, as
  # opposed to the redirect behaviour above, which is what it grew later.
  describe "the address check" do
    test "a private or link-local address is refused before anything is dialled" do
      # No stub is installed: if any of these reached `Req` the test would hang
      # or error on a real socket rather than returning a refusal.
      for url <- [
            "http://127.0.0.1/x",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/x",
            "http://10.0.0.1/x",
            "http://192.168.1.1/x"
          ] do
        assert {:error, message} = SafeFetch.get(url, opts()),
               "#{url} was not refused"

        assert message =~ "blocked URL:", "#{url}: #{message}"
      end
    end

    test "a URL with no host is refused rather than crashing" do
      assert {:error, message} = SafeFetch.get("not a url", opts())
      assert message =~ "blocked URL:"

      assert {:error, _} = SafeFetch.get(nil, opts())
    end
  end

  # `connect_target/3` and `host_header/2` are asserted as values, not through a
  # request: every one of these options fails *open* when wrong (SNI aimed at an
  # IP still connects, it just stops verifying the hostname), and `Req.Test`'s
  # plug adapter never opens a socket, so a round-trip test would pass on all of
  # them being absent.
  describe "the pinned connection keeps TLS pointed at the real hostname" do
    @pinned {93, 184, 216, 34}

    test "https carries SNI and hostname verification for the ORIGINAL host" do
      options = SafeFetch.connect_target("https://acme.test/webhooks", @pinned, 5_000)

      # Dialled by literal address — that is the whole point of the pin.
      assert options[:url] == "https://93.184.216.34/webhooks"

      transport = options[:connect_options][:transport_opts]

      assert transport[:verify] == :verify_peer
      assert is_list(transport[:cacerts]) and transport[:cacerts] != []
      # A charlist of the NAME. `~c"93.184.216.34"` here would still connect.
      assert transport[:server_name_indication] == ~c"acme.test"
      assert is_function(transport[:customize_hostname_check][:match_fun], 2)
    end

    # Regression: the host was bracketed by hand *and* by `URI.to_string/1`,
    # yielding `https://[[2606:2800::1]]/x`. Unparseable, so a webhook to any
    # endpoint whose DNS answer is IPv6 could never be delivered — and no test
    # touched the pinning path, so it had never been seen.
    test "an IPv6 pin is bracketed exactly once" do
      options =
        SafeFetch.connect_target("https://acme.test/x", {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}, 5_000)

      assert options[:url] == "https://[2606:2800::1]/x"
      # And it round-trips: an unparseable URL is what the bug produced.
      assert %URI{host: "2606:2800::1", scheme: "https", path: "/x"} = URI.parse(options[:url])

      assert options[:connect_options][:transport_opts][:server_name_indication] == ~c"acme.test"
    end

    test "an IPv6 literal URL keeps its brackets in the Host header" do
      pinned = {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}

      assert SafeFetch.host_header("https://[2606:2800::1]/x", pinned) ==
               [{"host", "[2606:2800::1]"}]

      # Without the brackets `2606:2800::1:8443` is neither a host nor a
      # host:port — RFC 3986 needs them before the `:port` can mean anything.
      assert SafeFetch.host_header("https://[2606:2800::1]:8443/x", pinned) ==
               [{"host", "[2606:2800::1]:8443"}]
    end

    test "http pins the address and adds no TLS options" do
      options = SafeFetch.connect_target("http://acme.test/x", @pinned, 5_000)

      assert options[:url] == "http://93.184.216.34/x"
      refute Keyword.has_key?(options[:connect_options], :transport_opts)
    end

    test "not pinning leaves the URL alone" do
      options = SafeFetch.connect_target("https://acme.test/x", nil, 5_000)

      assert options[:url] == "https://acme.test/x"
      refute Keyword.has_key?(options[:connect_options], :transport_opts)
    end

    test "the original Host is restored, including a non-default port" do
      assert SafeFetch.host_header("https://acme.test/x", @pinned) == [{"host", "acme.test"}]
      assert SafeFetch.host_header("http://acme.test/x", @pinned) == [{"host", "acme.test"}]

      assert SafeFetch.host_header("https://acme.test:8443/x", @pinned) ==
               [{"host", "acme.test:8443"}]

      assert SafeFetch.host_header("http://acme.test:8080/x", @pinned) ==
               [{"host", "acme.test:8080"}]

      # Default ports are elided rather than spelled out — `acme.test:443` is a
      # different `Host` to a vhost that matches on the literal string.
      assert SafeFetch.host_header("https://acme.test:443/x", @pinned) == [{"host", "acme.test"}]
      assert SafeFetch.host_header("http://acme.test:80/x", @pinned) == [{"host", "acme.test"}]

      # Nothing to restore when the URL was never rewritten.
      assert SafeFetch.host_header("https://acme.test/x", nil) == []
    end
  end

  describe "the byte cap" do
    test "an over-length body is an error, and the default cap applies unasked" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 300 * 1024)) end)

      assert {:error, message} = SafeFetch.get(@url, opts())
      assert message =~ "exceeded #{256 * 1024} bytes"
    end

    test "a body at exactly the cap is not an error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 1_000)) end)

      assert {:ok, %{body: body}} = SafeFetch.get(@url, opts(max_bytes: 1_000))
      assert byte_size(body) == 1_000
    end

    # The cap has to hold while the bytes are still arriving. A `content-length`
    # is written by the far end, so trusting it is trusting the attacker.
    test "a lying content-length does not raise the cap" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "10")
        |> Plug.Conn.send_resp(200, String.duplicate("x", 5_000))
      end)

      assert {:error, message} = SafeFetch.get(@url, opts(max_bytes: 1_000))
      assert message =~ "exceeded 1000 bytes"
    end
  end

  describe "the caller always gets bytes" do
    # `decode_body: false`. Req otherwise decodes by content-type, so `body`
    # would be a map on a JSON response and a binary on everything else — two
    # shapes for the caller to handle, and decoding happening *before* the size
    # cap rather than after it.
    test "a JSON response comes back as an undecoded binary" do
      stub(fn conn -> Req.Test.json(conn, %{ok: true, n: 1}) end)

      assert {:ok, %{body: body}} = SafeFetch.get(@url, opts())
      assert is_binary(body)
      assert body == ~s({"ok":true,"n":1}) or body == ~s({"n":1,"ok":true})
    end

    test "an empty body is an empty binary, not nil" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

      assert {:ok, %{status: 204, body: ""}} = SafeFetch.get(@url, opts())
    end
  end
end
