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
end
