defmodule KilnCMSWeb.LiveJoinWithoutSessionTest do
  @moduledoc """
  A `/live` join whose transport resolved **no session** is refused cleanly
  (#689).

  `Phoenix.Socket.Transport.connect_session/4` answers `nil` — not `%{}` — when
  the session cookie is missing *or* when `_csrf_token` fails to validate. The
  common case is not an attacker: signing out in tab B rotates the token, tab A's
  socket reconnects with the stale one from its page's meta tag, and ordinary
  "I have two tabs open" behaviour hits it.

  #689 read `Phoenix.LiveView.Channel` and concluded that `nil` reaches
  `Map.merge(socket_session, verified_user_session)` in `verified_mount/8`, which
  would raise `BadMapError` outside the `try` that turns a 4xx into a client
  reload — an unhandled crash and a Sentry event for a non-adversarial
  condition.

  **It does not, on the version this project pins.** `mount/3` matches
  `%{session: nil}` on `connect_info` *before* calling `authorize_session/3`,
  logs a debug line naming the likely misconfiguration, and replies
  `{:error, %{reason: "stale"}}` — the same orderly refusal a genuinely expired
  token gets, with no crash report. The lines #689 cites are real but
  unreachable for this input.

  This test is the evidence, and the guard: it drives the real transport, so a
  LiveView upgrade that removed that clause would fail here rather than start
  paging on two-tab sign-outs. A hand-built socket would be assuming the answer,
  since what the transport puts in `connect_info` is the whole question.

  `async: false` for the reason `live_join_without_url_test.exs` gives: the
  sandbox connection is only shared for non-async cases, and the channel
  processes `subscribe_and_join` spawns are not otherwise allowed owners.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @moduletag :capture_log

  @endpoint KilnCMSWeb.Endpoint
  @password "password123456"

  alias KilnCMS.Accounts.User

  defp authed_user(role) do
    email = "nosess-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  # What a browser holds after being served the page: the main container's DOM
  # id (the channel topic) and its signed session blob. A real credential, so
  # the join gets past token verification and reaches the clause under test.
  defp scrape_token(conn, path) do
    html =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(authed_user(:editor))
      |> get(path)
      |> html_response(200)

    with [_, id] <- Regex.run(~r/id="(phx-[^"]+)"[^>]*data-phx-main/, html),
         [_, session] <- Regex.run(~r/id="#{id}"[^>]*data-phx-session="([^"]+)"/, html) do
      {id, session}
    else
      _ -> flunk("no phx-main container in #{path}")
    end
  end

  defp join_live(conn, path, connect_info) do
    {id, session} = scrape_token(conn, path)

    {:ok, socket} =
      Phoenix.ChannelTest.connect(Phoenix.LiveView.Socket, %{},
        connect_info: Map.put(connect_info, :uri, URI.parse("http://localhost#{path}"))
      )

    subscribe_and_join(socket, "lv:" <> id, %{
      "session" => session,
      "url" => "http://localhost#{path}"
    })
  end

  test "a join whose transport resolved no session is refused, not crashed", %{conn: conn} do
    # `config/test.exs` pins the level at `:warning`, and the clause under test
    # logs at `:debug` — without this the assertion below sees nothing.
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # `session: nil` is what the transport hands the channel when the cookie
        # is absent or the CSRF token fails — not a value invented here.
        result = join_live(conn, "/editor", %{session: nil})

        # The orderly refusal, not `** (BadMapError) expected a map, got: nil`.
        # `reason: "stale"` is what a real client reloads on, so the user's tab
        # recovers through the router instead of the server filing a crash
        # report.
        assert result == {:error, %{reason: "stale"}}
      end)

    # And this is why the tuple above means anything. `{:error, %{reason:
    # "stale"}}` is what FOUR clauses return — `session: nil`, a token that fails
    # `verify_session`, an `authorize_session` failure, and a join carrying no
    # session param at all — so on its own it cannot tell "refused for the right
    # reason" from "the credential we scraped was never valid". An endpoint salt
    # change, a `static` token becoming required, or a layout tweak that made
    # `scrape_token`'s regex bind the wrong container would all leave the
    # assertion green while proving nothing, which is precisely the regression
    # this file exists to catch.
    #
    # The nil clause is the only one of the four that logs, and what it logs is
    # unmistakable.
    assert log =~ "LiveView session was misconfigured"
  end
end
