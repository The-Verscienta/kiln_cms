defmodule KilnCMS.Links.ExternalTest do
  @moduledoc """
  The external link checker (#474).

  Almost every test here is about something the checker *refuses* to call
  broken. That is the whole design: one false "broken" costs an author a hunt
  for a fault that does not exist, and a checker that does that twice is one
  they stop reading.

  `async: false` — several cases reconfigure `KilnCMS.Webhooks.SafeUrl`'s
  resolver to produce DNS outcomes that a stubbed transport cannot.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Links.External

  @url "https://example.test/page"

  defp stub(fun), do: Req.Test.stub(KilnCMS.Links.External, fun)

  defp respond(status), do: stub(fn conn -> Plug.Conn.send_resp(conn, status, "") end)

  # Reconfigure SafeUrl for one test, restoring whatever the suite had.
  defp with_safe_url(opts, fun) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, [])
    Application.put_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, Keyword.merge(previous, opts))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, previous) end)
    fun.()
  end

  describe "what counts as checkable" do
    test "absolute http(s) URLs, and nothing else" do
      assert External.checkable?("https://example.test/x")
      assert External.checkable?("http://example.test")

      # Every one of these is a link. None is a request, and a report row about
      # one is a row nobody can act on.
      refute External.checkable?("mailto:someone@example.test")
      refute External.checkable?("tel:+15551234")
      refute External.checkable?("javascript:alert(1)")
      refute External.checkable?("#section")
      refute External.checkable?("/blog/internal")
      refute External.checkable?("https://")
      refute External.checkable?(nil)
    end

    test "an unmakeable request is undetermined, never broken" do
      assert %{outcome: :undetermined} = External.check("mailto:x@example.test")
      assert %{outcome: :undetermined} = External.check("/blog/thing")
    end
  end

  describe "statuses" do
    test "2xx is ok" do
      respond(204)
      assert %{outcome: :ok, status: 204} = External.check(@url)
    end

    test "404 and 410 are the only statuses called broken" do
      respond(404)
      assert %{outcome: :broken, status: 404} = External.check(@url)

      respond(410)
      assert %{outcome: :broken, status: 410} = External.check(@url)
    end

    test "401, 403 and 429 are undetermined — a browser sails past all three" do
      for status <- [401, 403, 429] do
        respond(status)
        assert %{outcome: :undetermined, status: ^status} = External.check(@url)
      end
    end

    test "an unrecognised 4xx is undetermined rather than guessed" do
      respond(418)
      assert %{outcome: :undetermined, status: 418} = External.check(@url)
    end

    test "5xx is transient, so it is retried before anyone hears about it" do
      respond(503)
      assert %{outcome: :transient, status: 503} = External.check(@url)
    end
  end

  describe "HEAD is asked first and not believed when it refuses" do
    test "a 405 to HEAD is re-asked with GET" do
      stub(fn conn ->
        case conn.method do
          "HEAD" -> Plug.Conn.send_resp(conn, 405, "")
          "GET" -> Plug.Conn.send_resp(conn, 200, "hello")
        end
      end)

      assert %{outcome: :ok, status: 200} = External.check(@url)
    end

    test "even a 404 to HEAD is re-asked, because some servers only serve GET" do
      stub(fn conn ->
        case conn.method do
          "HEAD" -> Plug.Conn.send_resp(conn, 404, "")
          "GET" -> Plug.Conn.send_resp(conn, 200, "hello")
        end
      end)

      assert %{outcome: :ok} = External.check(@url)
    end

    test "a 200 to HEAD costs exactly one request" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:request, conn.method})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert %{outcome: :ok} = External.check(@url)
      assert_received {:request, "HEAD"}
      refute_received {:request, "GET"}
    end
  end

  describe "redirects" do
    test "are followed, and the destination is the answer" do
      stub(fn conn ->
        case conn.request_path do
          "/page" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/moved")
            |> Plug.Conn.send_resp(301, "")

          "/moved" ->
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert %{outcome: :ok, status: 200} = External.check(@url)
    end

    test "a loop is broken rather than followed forever" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/page")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert %{outcome: :broken, status: 302, reason: reason} = External.check(@url)
      assert reason =~ "redirect chain"
    end

    test "a redirect to a 404 is broken, at the status the chain ended on" do
      stub(fn conn ->
        case conn.request_path do
          "/page" ->
            conn |> Plug.Conn.put_resp_header("location", "/gone") |> Plug.Conn.send_resp(302, "")

          "/gone" ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert %{outcome: :broken, status: 404} = External.check(@url)
    end
  end

  describe "failures that never reach a status" do
    test "a name that does not resolve is transient, not broken" do
      # The most common genuinely-dead external link — and the one most worth
      # being patient about, since DNS fails for a minute far more often than
      # forever. The consecutive-failure counter is what tells them apart.
      with_safe_url([resolve_dns: true, resolver: fn _host -> {:error, :nxdomain} end], fn ->
        assert %{outcome: :transient, reason: reason} = External.check(@url)
        assert reason =~ "could not be resolved"
      end)
    end

    test "a resolution timeout is transient" do
      with_safe_url([resolve_dns: true, resolver: fn _host -> {:error, :timeout} end], fn ->
        assert %{outcome: :transient, reason: reason} = External.check(@url)
        assert reason =~ "timed out"
      end)
    end

    test "an address the SSRF guard refuses is undetermined and never escalates" do
      # A decision about this deployment, not about the author's link. Letting
      # it climb to `:broken` after three nights would report our own egress
      # policy as their mistake.
      assert %{outcome: :undetermined, reason: reason} = External.check("http://127.0.0.1/x")
      assert reason =~ "blocked URL"
    end

    test "a transport failure is transient" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert %{outcome: :transient, status: nil} = External.check(@url)
    end
  end

  describe "a body far larger than the cap" do
    test "is a working link, not a failed check" do
      # Without `truncate_body`, every long article on the web would come back
      # as "response exceeded N bytes" and read exactly like a dead link. The
      # HEAD is refused so the check falls through to the GET that actually
      # streams a body — a HEAD-answered 200 never exercises the cap.
      stub(fn conn ->
        case conn.method do
          "HEAD" -> Plug.Conn.send_resp(conn, 405, "")
          "GET" -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 200_000))
        end
      end)

      assert %{outcome: :ok, status: 200} = External.check(@url)
    end
  end

  describe "the user-agent" do
    test "identifies Kiln, carries a URL, and discloses no version" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:agent, Plug.Conn.get_req_header(conn, "user-agent")})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      External.check(@url)

      assert_received {:agent, [agent]}
      assert agent =~ "KilnCMS"
      assert agent =~ "http"
      # A link checker announces itself to every site an author has ever cited;
      # a build number there is a permanent broadcast of what to try.
      refute agent =~ ~r/\d+\.\d+\.\d+/
    end
  end
end
