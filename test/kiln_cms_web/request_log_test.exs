defmodule KilnCMSWeb.RequestLogTest do
  @moduledoc """
  The request line never carries a credential from the path (#2449): every
  token route, through the real endpoint, logs its start line with the token as
  `[FILTERED]`, and Phoenix's own stop line as usual.
  """
  # async: false — each test raises the global Logger level to `:info` (the
  # production level, config/prod.exs) so the request line is emitted at all;
  # the fail-closed tests also `Application.put_env` the router and reset the
  # `:persistent_term` pattern cache.
  use KilnCMSWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.RequestLog
  alias KilnCMSWeb.RequestRedaction

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    RequestRedaction.reset()

    on_exit(fn ->
      Logger.configure(level: previous_level)
      RequestRedaction.reset()
    end)
  end

  defp token, do: "T#{System.unique_integer([:positive])}secret"

  # A `:browser`-pipeline POST without a form round trip.
  defp skip_csrf(conn), do: put_private(conn, :plug_skip_csrf_protection, true)

  defp request_lines(log), do: Regex.scan(~r/\b(?:GET|POST) \/\S*/, log)
  defp stop_lines(log), do: Regex.scan(~r/\b(?:Sent|Chunked) \d{3} in /, log)

  defp assert_redacted(log, line, token) do
    refute log =~ token
    assert [[^line]] = request_lines(log), "expected one request line #{line}, got:\n#{log}"
    assert [_] = stop_lines(log), "expected Phoenix's stop line, got:\n#{log}"
  end

  # {method, path with TOKEN, the logged start line, LiveView?}
  @routes [
    {:get, "/auth/invite/TOKEN", "GET /auth/invite/[FILTERED]", true},
    {:get, "/auth/unlock/TOKEN", "GET /auth/unlock/[FILTERED]", false},
    {:post, "/auth/unlock/TOKEN", "POST /auth/unlock/[FILTERED]", false},
    {:get, "/magic_link/TOKEN", "GET /magic_link/[FILTERED]", true},
    {:get, "/password-reset/TOKEN", "GET /password-reset/[FILTERED]", true},
    {:get, "/confirm_new_user/TOKEN", "GET /confirm_new_user/[FILTERED]", true},
    {:get, "/preview/TOKEN", "GET /preview/[FILTERED]", false},
    {:get, "/preview/release/TOKEN", "GET /preview/[FILTERED]/[FILTERED]", true},
    {:get, "/preview/TOKEN/live", "GET /preview/[FILTERED]/live", true},
    {:get, "/newsletter/unsubscribe/TOKEN", "GET /newsletter/unsubscribe/[FILTERED]", false},
    {:post, "/newsletter/unsubscribe/TOKEN", "POST /newsletter/unsubscribe/[FILTERED]", false},
    {:get, "/newsletter/confirm/TOKEN", "GET /newsletter/confirm/[FILTERED]", false},
    {:post, "/newsletter/confirm/TOKEN", "POST /newsletter/confirm/[FILTERED]", false},
    # Not routes of their own, but the same credential in the path: a locale
    # prefix and a mangled link that falls through to the 404 catch-all.
    {:get, "/fr/preview/release/TOKEN", "GET /fr/preview/[FILTERED]/[FILTERED]", false},
    {:get, "/magic_link/TOKEN/x", "GET /magic_link/[FILTERED]/x", false}
  ]

  describe "a token route" do
    for {method, path, line, _live?} <- @routes do
      @method method
      @path path
      @line line
      test "#{method |> to_string() |> String.upcase()} #{path} logs #{line}", %{conn: conn} do
        token = token()
        path = String.replace(@path, "TOKEN", token)

        log =
          capture_log(fn ->
            conn |> skip_csrf() |> dispatch(@endpoint, @method, path, %{})
          end)

        assert_redacted(log, @line, token)
      end
    end

    for {:get, path, line, true} <- @routes do
      @path path
      @line line
      test "live #{path} logs #{line}", %{conn: conn} do
        token = token()
        path = String.replace(@path, "TOKEN", token)

        log = capture_log(fn -> live(conn, path) end)

        assert_redacted(log, @line, token)
      end
    end
  end

  describe "an ordinary path" do
    test "logs its request line exactly as Phoenix does", %{conn: conn} do
      log = capture_log(fn -> get(conn, "/sitemap.xml") end)

      assert [["GET /sitemap.xml"]] = request_lines(log)
      assert [_] = stop_lines(log)
    end

    test "keeps a locale prefix and its path unredacted", %{conn: conn} do
      log = capture_log(fn -> get(conn, "/fr/blog") end)

      assert [["GET /fr/blog"]] = request_lines(log)
      refute log =~ "[FILTERED]"
    end
  end

  describe "level/1" do
    test "is :info for an ordinary request" do
      assert RequestLog.level(Plug.Test.conn(:get, "/blog")) == :info
    end

    test "is false for a token path's start, after logging the redacted line" do
      token = token()

      log =
        capture_log(fn ->
          assert RequestLog.level(Plug.Test.conn(:get, "/magic_link/#{token}")) == false
        end)

      assert log =~ "GET /magic_link/[FILTERED]"
      refute log =~ token
    end

    # The stop event asks the same callback; its line has no path, so Phoenix
    # writes it.
    test "is :info for a token path's stop, and logs nothing itself" do
      conn = %{Plug.Test.conn(:get, "/magic_link/#{token()}") | state: :set, status: 200}

      log = capture_log(fn -> assert RequestLog.level(conn) == :info end)

      assert log == ""
    end

    # `Plug.Test.conn/2` reads `//host/...` as an authority, so the empty
    # segment is built by hand, the way the server hands it over.
    test "drops an empty leading segment, as the router does" do
      token = token()

      conn = %{
        Plug.Test.conn(:get, "/")
        | request_path: "//magic_link/#{token}",
          path_info: ["magic_link", token]
      }

      log = capture_log(fn -> assert RequestLog.level(conn) == false end)

      assert log =~ "GET /magic_link/[FILTERED]"
      refute log =~ token
    end
  end

  describe "when the patterns cannot be built" do
    setup do
      previous = Application.get_env(:kiln_cms, RequestRedaction)
      Application.put_env(:kiln_cms, RequestRedaction, router: KilnCMSWeb.NoSuchRouter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, RequestRedaction, previous),
          else: Application.delete_env(:kiln_cms, RequestRedaction)
      end)
    end

    test "every path is written as /[FILTERED]", %{conn: conn} do
      log =
        capture_log(fn ->
          assert RequestRedaction.redact_path("/sitemap.xml") == "/[FILTERED]"
          assert RequestRedaction.secret?("/blog/a-post")
          get(conn, "/sitemap.xml")
        end)

      assert [["GET /[FILTERED]"]] = request_lines(log)
      refute log =~ "GET /sitemap.xml"
    end

    test "the failure is remembered rather than retried on every request" do
      log =
        capture_log(fn ->
          for _ <- 1..3, do: RequestRedaction.redact_path("/sitemap.xml")
        end)

      assert [_one] = Regex.scan(~r/could not read the router/, log)

      # A fixed router is picked up once the cache is reset.
      Application.delete_env(:kiln_cms, RequestRedaction)
      RequestRedaction.reset()
      assert RequestRedaction.redact_path("/sitemap.xml") == "/sitemap.xml"
    end
  end
end
