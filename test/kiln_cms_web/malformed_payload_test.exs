defmodule KilnCMSWeb.MalformedPayloadTest do
  @moduledoc """
  A client-chosen payload *shape* does not crash an editor LiveView (#764).

  The sibling of `KilnCMSWeb.BracketedParamsTest`, which covers the public HTTP
  surface (#751). Everything here needs an authenticated editor session, so it
  is crash-your-own-session plus error-tracker noise rather than an anonymous
  denial of service — but a crafted link is enough for the `handle_params`
  half, and someone can be sent one.

  Two mechanisms are under test and they only work together:

    * a `when is_binary(…)` guard on the clause head, so a wrong-shaped payload
      does not match a handler that would raise inside its body;
    * the catch-all `KilnCMSWeb.MalformedEvent` appends after every LiveView's
      module body, so the unmatched event is a no-op rather than a
      `FunctionClauseError`.

  A guard without the catch-all just moves the crash from the body to the head.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  # The shapes Plug's decoder and a hand-written `pushEvent` can produce for
  # something the handler assumed was a string.
  @bad_shapes [[], ["x"], %{"a" => "1"}, 1, nil, true]

  defp authed_user(role) do
    email = "shape-#{System.unique_integer([:positive])}@example.com"

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

  defp admin_conn(%{conn: conn}), do: %{conn: log_in(conn, authed_user(:admin))}

  describe "reachable by a crafted link" do
    setup :admin_conn

    # These need only a bookmark, which is what makes them the sharp end: the
    # value arrives through `handle_params`, so nobody has to push anything.
    test "a bracketed ?q= does not crash the content list", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/editor?q[a]=1")
      assert {:ok, _view, _html} = live(conn, "/editor?q[]=1")
    end

    test "a bracketed ?q= does not crash the media library", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/media?q[a]=1")
      assert {:ok, _view, _html} = live(conn, "/media?q[]=1")
    end

    # The existing comment on `range_from/1` covered an unparseable *string*.
    # `?range[]=7` is a list, which `Integer.parse/1` had no clause for.
    test "a bracketed ?range= does not crash analytics, and falls back", %{conn: conn} do
      assert {:ok, _view, html} = live(conn, "/editor/analytics?range[]=7")

      # Asserted on the export link, which encodes the *window* — the 7d/30d
      # switcher renders both numbers at every range, so `html =~ "30"` would
      # have passed whatever `range_from/1` returned, covering only the crash.
      today = Date.utc_today()
      from_30 = today |> Date.add(-29) |> Date.to_iso8601()
      from_7 = today |> Date.add(-6) |> Date.to_iso8601()

      assert html =~ "from=#{from_30}", "did not fall back to the 30-day default"
      refute html =~ "from=#{from_7}"
    end
  end

  describe "reachable by a pushed event" do
    setup :admin_conn

    test "a wrong-shaped search payload is ignored, and the view survives", %{conn: conn} do
      for {path, event} <- [
            {"/editor", "search"},
            {"/media", "search"},
            {"/editor/search", "search"}
          ],
          shape <- @bad_shapes do
        {:ok, view, _html} = live(conn, path)

        # `render_click/3` raises if the view dies, so surviving *is* the
        # assertion. Rendering afterwards proves the process is still alive
        # rather than merely not having replied.
        render_click(view, event, %{"q" => shape})
        assert render(view) =~ "<"
      end
    end

    test "an event name nothing handles is ignored", %{conn: conn} do
      # `/editor/analytics` deliberately: `AnalyticsLive` defines NO
      # `handle_event/3` of its own. An earlier version of the mechanism skipped
      # those modules, on the theory that it preserved a Phoenix warning for
      # unhandled events — but no such warning exists. `Phoenix.LiveView.Channel`
      # calls `socket.view.handle_event/3` unconditionally (only `handle_info`
      # has the graceful path), so those six views raised
      # `UndefinedFunctionError` on any pushed event. Pointing this at `/editor`,
      # which has handlers, passed either way.
      for path <- ["/editor", "/editor/analytics", "/editor/calendar"] do
        {:ok, view, _html} = live(conn, path)

        render_click(view, "no_such_event_ever", %{"whatever" => ["x"]})
        assert render(view) =~ "<", "#{path} died on an unhandled event"
      end
    end
  end

  describe "the catch-all does not shadow real handlers" do
    setup :admin_conn

    # The risk of appending a catch-all: if it landed *before* the real
    # clauses, every handler would silently become a no-op and most of this
    # suite would still pass. So assert a real event still has its effect.
    test "a well-formed search still filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      render_click(view, "search", %{"q" => "somethingveryunlikely"})

      assert_patched(view, "/editor?q=somethingveryunlikely")
    end

    # The structural half of the same worry. `@before_compile` hooks fire in
    # REGISTRATION order, not "last wins" — so the catch-all lands after the
    # module body and after any hook registered earlier, but *before* one
    # registered later. `use KilnCMSWeb, :live_view` sits at the top of every
    # view, which is the losing position if a second `use` ever injects
    # `handle_event/3` from its own `__before_compile__`.
    #
    # No Kiln LiveView does today. This fails the day one does, rather than
    # every handler in that view quietly becoming a no-op.
    test "no Kiln LiveView registers a second before_compile hook" do
      views =
        KilnCMSWeb.Router.__routes__()
        |> Enum.flat_map(fn
          %{metadata: %{phoenix_live_view: {view, _a, _o, _ls}}} -> [view]
          _not_live -> []
        end)
        |> Enum.uniq()
        |> Enum.filter(&(to_string(&1) =~ ~r/^Elixir\.KilnCMSWeb\./))

      assert length(views) > 20

      offenders =
        Enum.reject(views, fn view ->
          hooks =
            view.module_info(:attributes)
            |> Keyword.get_values(:before_compile)
            |> List.flatten()

          hooks == [] or hooks == [KilnCMSWeb.MalformedEvent]
        end)

      assert offenders == [],
             "these views register another before_compile hook, which may now " <>
               "shadow or be shadowed by the malformed-event catch-all: " <>
               inspect(offenders)
    end
  end
end
