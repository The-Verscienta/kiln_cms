defmodule KilnCMSWeb.LiveJoinWithoutUrlTest do
  @moduledoc """
  A `/live` join carrying a valid session token but no `"url"` is refused (#688).

  `Phoenix.LiveView`'s channel has a catch-all for a join payload with neither
  `"url"` nor `"redirect"`: it matches no route, and the channel attaches a
  `live_session`'s `on_mount` list only when a route matched. So such a join runs
  none of the router's gates — not `:current_user`, not `:assign_current_org`,
  not `:live_editor_required` / `:live_admin_required`.

  These tests drive the channel directly rather than through
  `Phoenix.LiveViewTest`, which always sends a URL — sending one is the whole
  thing being tested, so it cannot be the test's own client.

  The credential is the signed `data-phx-session` blob from any page the caller
  was served legitimately, which is why "they had to be let in once" is not a
  defence: the token outlives the visit, and outlives a demotion.

  `async: false` — `KilnCMS.DataCase.setup_sandbox` only shares the sandbox
  connection for non-async cases, and the channel processes `subscribe_and_join`
  spawns are not sandbox-allowed owners otherwise.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  import Phoenix.LiveViewTest, only: [live: 2]

  @moduletag :capture_log

  @endpoint KilnCMSWeb.Endpoint
  @password "password123456"

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.LiveRouteGuard

  # AshAuthentication ships these, so they cannot carry `use KilnCMSWeb,
  # :live_view` and are outside the guard. Listed rather than filtered by
  # namespace so that a *new* third-party LiveView in the router fails this test
  # and gets looked at.
  #
  # `AshAuthentication.Phoenix.SignInLive` is *not* on this list: `/sign-in`,
  # `/register` and `/reset` are routed to `KilnCMSWeb.SignInLive`, which wraps
  # it in order to attach the client address (#715) and picks up the guard on
  # the way past.
  @unguarded_views [
    AshAuthentication.Phoenix.ConfirmLive,
    AshAuthentication.Phoenix.MagicSignInLive,
    AshAuthentication.Phoenix.ResetLive,
    AshAuthentication.Phoenix.SignOutLive
  ]

  defp authed_user(role) do
    email = "join-#{System.unique_integer([:positive])}@example.com"

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Exactly what a browser holds after being served the page: the main
  # container's DOM id (which is the channel topic) and its signed session blob.
  defp phx_main(html) do
    with [_, id] <- Regex.run(~r/id="(phx-[^"]+)"[^>]*data-phx-main/, html),
         [_, session] <- Regex.run(~r/id="#{id}"[^>]*data-phx-session="([^"]+)"/, html) do
      {id, session}
    else
      _ ->
        flunk("""
        No phx-main container found. These regexes ride the attribute order
        `Phoenix.LiveView.Static` emits (id, then data-phx-main, then
        data-phx-session) — if LiveView reordered them, fix the regexes rather
        than KilnCMSWeb.LiveRouteGuard.
        """)
    end
  end

  defp scrape_token(conn, path) do
    conn
    |> get(path)
    |> html_response(200)
    |> phx_main()
  end

  defp live_socket(path) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(Phoenix.LiveView.Socket, %{},
        connect_info: %{uri: URI.parse("http://localhost#{path}"), session: %{}}
      )

    socket
  end

  defp join_without_url(socket, id, session),
    do: subscribe_and_join(socket, "lv:" <> id, %{"session" => session})

  describe "an admin-gated LiveView" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "does not render when joined without a url", %{conn: conn} do
      {id, session} = scrape_token(conn, "/editor/team")

      assert {:error, reply} = join_without_url(live_socket("/editor/team"), id, session)

      # A clean, deliberate refusal — not the `KeyError` on the assign the
      # skipped hook was supposed to set, which is how this failed before #688.
      # `reason: "reload"` is what the channel returns for a 4xx raised during
      # mount; it stops the channel without a crash report, and a real client
      # reloads through the router, where the gates run.
      assert reply.reason == "reload"
      assert reply.status == 404
    end

    test "still renders for an ordinary connected mount, which does carry a url", %{conn: conn} do
      # The guard's negative control. `live/2` performs the connected join a
      # browser performs, url and all — and the rest of the suite is the same
      # control at scale, since a guard that fired on a routed join would take
      # every LiveView test with it.
      assert {:ok, _view, html} = live(conn, "/editor/team")

      # Something only TeamLive emits, not the console shell, which links
      # `/editor/team` from every editor page.
      assert html =~ "Add member"
    end
  end

  describe "the whole authoring surface" do
    # Behavioural sweep of every parameterless authoring route. Complements the
    # structural check below: this one proves the runtime effect, that one
    # proves the coverage. Neither alone is enough — a hand-listed sweep cannot
    # notice a route it does not list, and introspection cannot prove a mount
    # actually refuses.
    @routes ~w(
      /account /media /editor /editor/overview /editor/calendar /editor/translations
      /editor/search /editor/taxonomy /editor/analytics /editor/settings
      /editor/trash /editor/webhooks /editor/redirects /editor/slugs /editor/team
      /editor/automation /editor/fields /editor/types /editor/branding /editor/mail
      /editor/newsletter /editor/billing /editor/governance /editor/forms
      /editor/api-keys /editor/system
    )

    test "refuses a url-less join the same way everywhere", %{conn: conn} do
      user = authed_user(:admin)

      refusals =
        Map.new(@routes, fn path ->
          {id, session} = scrape_token(log_in(conn, user), path)

          outcome =
            case join_without_url(live_socket(path), id, session) do
              {:error, %{reason: "reload", status: 404}} -> :refused
              other -> other
            end

          {path, outcome}
        end)

      assert refusals == Map.new(@routes, &{&1, :refused})
    end
  end

  describe "coverage" do
    test "every live route in the router carries the guard" do
      # The invariant the sweep above can only sample: the guard rides
      # `use KilnCMSWeb, :live_view`, so a LiveView written with plain
      # `use Phoenix.LiveView` — including one contributed by a plugin through
      # `KilnCMSWeb.PluginRouter`, which compiles third-party modules straight
      # into the admin-gated live_session — would silently have no guard. This
      # reaches the parameterised routes (`ContentEditorLive`, `GovernanceLive`
      # `:show`, `FormBuilderLive`) that a path sweep cannot reach without
      # seeding a record for each.
      views =
        KilnCMSWeb.Router.__routes__()
        |> Enum.flat_map(fn
          %{metadata: %{phoenix_live_view: {view, _action, _opts, _live_session}}} -> [view]
          _not_a_live_route -> []
        end)
        |> Enum.uniq()

      # Guard the enumeration itself: a filter that silently matched nothing
      # would make the assertion below vacuously true.
      assert length(views) > 20

      unguarded =
        Enum.reject(views, fn view ->
          view in @unguarded_views or
            Enum.any?(view.__live__().lifecycle.mount, &(&1.id == {LiveRouteGuard, :default}))
        end)

      assert unguarded == []
    end
  end

  describe "the guard's condition" do
    # `Phoenix.LiveView.Static.sign_nested_session/5` signs a **sticky** child
    # with `parent_pid: nil` and the parent's `router` — that is what lets it
    # outlive the parent — so it is a "main" session by the framework's own
    # definition, and the JS client deliberately sends it no URL. It is
    # therefore indistinguishable from the attack on every field except the one
    # the guard reads: `live_session_name`, which `sign_root_session/5` always
    # includes and `sign_nested_session/5` never does.
    #
    # Kiln has no `live_render` today, so this is the only cover for that shape.
    # Without it, the first sticky child anyone adds 404s on join, and the
    # client turns a 404 into a page reload — which re-renders the child, which
    # 404s again.
    defp socket_shaped_like(private) do
      %Phoenix.LiveView.Socket{
        view: KilnCMSWeb.TeamLive,
        router: KilnCMSWeb.Router,
        transport_pid: self(),
        host_uri: :not_mounted_at_router,
        private: Map.merge(%{connect_info: %{}, lifecycle: nil}, private)
      }
    end

    test "refuses a url-less join whose session named a live_session" do
      socket = socket_shaped_like(%{live_session_name: :admin_routes})

      assert_raise LiveRouteGuard.UnroutedJoinError, fn ->
        LiveRouteGuard.on_mount(:default, %{}, %{}, socket)
      end
    end

    test "admits a sticky or nested child, whose session names none" do
      socket = socket_shaped_like(%{})

      assert {:cont, ^socket} = LiveRouteGuard.on_mount(:default, %{}, %{}, socket)
    end

    test "admits a disconnected mount, which went through the router already" do
      socket = %{socket_shaped_like(%{live_session_name: :admin_routes}) | transport_pid: nil}

      assert {:cont, ^socket} = LiveRouteGuard.on_mount(:default, %{}, %{}, socket)
    end

    test "admits a routed connected join, which is every real one" do
      socket = %{
        socket_shaped_like(%{live_session_name: :admin_routes})
        | host_uri: URI.parse("http://localhost/editor/team")
      }

      assert {:cont, ^socket} = LiveRouteGuard.on_mount(:default, %{}, %{}, socket)
    end
  end
end
