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

    # The long tail #894 left open: handlers that *match* a wrong-shaped payload
    # and then raise in the body. The catch-all can't help those — only a head
    # guard can, and these are the sites that got one.
    #
    # `Phoenix.LiveViewTest` does NOT stringify a view-targeted payload
    # (`client_proxy.ex` stringifies with `& &1`, the identity fun), so the
    # integers, `nil`s and booleans below reach `handle_event/3` unconverted.
    # That is what makes these genuine rather than a test of `to_string/1`.
    @malformed [
      # #894 spot-checked these four as still raising. `mint` reached
      # `String.trim/1`, `send_test` the same, `delete` an Ash primary key, and
      # `new` a `create!/4` bang.
      {"/editor/api-keys", "mint", %{"user_id" => 1, "name" => "x", "days" => "30"}},
      {"/editor/api-keys", "mint", %{"user_id" => "u", "name" => nil, "days" => true}},
      {"/editor/mail", "send_test", %{"test" => %{"to" => ["a@b.test"]}}},
      {"/editor/mail", "send_test", %{"test" => %{"to" => nil}}},
      {"/editor/taxonomy", "delete", %{"type" => 1, "id" => nil}},
      {"/editor/taxonomy", "delete", %{"type" => "tag", "id" => ["x"]}},
      {"/editor", "new", %{"kind" => true}},
      {"/editor", "new", %{"kind" => ["post"]}},

      # A spread over the rest of the sweep, one per shape the client can pick.
      {"/editor/api-keys", "revoke", %{"id" => 1}},
      {"/editor/mail", "save_server_ip", %{"settings" => %{"server_ip" => 25}}},
      {"/editor/taxonomy", "edit", %{"type" => true, "id" => %{"a" => "1"}}},
      {"/editor", "filter", %{"status" => 1}},
      {"/editor", "duplicate", %{"kind" => "post", "id" => 7}},
      {"/editor/team", "add_member", %{"member" => %{"email" => 1}}},
      {"/editor/team", "edit_role", %{"id" => nil}},
      {"/editor/settings", "confirm_totp", %{"code" => 123_456}},
      {"/editor/webhooks", "ping", %{"id" => 1}},
      {"/editor/redirects", "create", %{"redirect" => ["x"]}},
      {"/editor/menus", "reorder_items", %{"parent_id" => nil, "order" => "not-a-list"}},

      # A form-params key the client sent as something other than a map. The
      # `is_map` half of the sweep: `AshPhoenix.Form.validate/2` and the
      # hand-rolled `to_form(params, as: :x)` readers both assume a map.
      {"/editor/settings", "save_password", %{"user" => "not-a-map"}},
      {"/editor/webhooks", "validate", %{"webhook" => ["a"]}},
      {"/editor/team", "create_role", %{"role" => 1}}
    ]

    test "a wrong-shaped payload at a guarded site is ignored, not raised", %{conn: conn} do
      for {path, event, payload} <- @malformed do
        {:ok, view, _html} = live(conn, path)

        render_hook(view, event, payload)

        assert render(view) =~ "<",
               "#{path} died on #{event} with #{inspect(payload)}"
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

    # The same worry, aimed at the guards rather than at the catch-all — and
    # this is the one the sweep needs, because an over-strict guard fails
    # exactly the way the bug did: silently, through the catch-all. `mint`
    # guards three variables at once, so it is the sharpest control.
    #
    # This is not hypothetical. Writing the sweep, `is_binary(value)` on
    # `InContextEditLive`'s `"update_block"` was wrong — the rich-text region
    # pushes a TipTap *document*, a map — and the only signal was one existing
    # test going red. Without a positive assertion a guarded handler that never
    # fires looks exactly like a guarded handler that works.
    test "a well-formed mint still mints", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor/api-keys")

      user = authed_user(:editor)

      html =
        render_hook(view, "mint", %{
          "user_id" => user.id,
          "name" => "a real key",
          "days" => "30"
        })

      assert html =~ "copy it now"
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

  describe "every payload-binding handler states its shape" do
    # The acceptance criterion #764 asked for: a mechanism, so the *next*
    # handler inherits this rather than joining a list someone has to re-derive.
    #
    # The behavioural tests above can only cover the handlers they name — there
    # are ~200 payload-binding clauses across 32 views, most of them needing
    # seeded records and a specific role to reach. This reads the source
    # instead and asserts the structural property those tests sample: a clause
    # that binds a value out of a client payload says what shape it expects.
    #
    # A guard is what turns "matches, then raises in the body" into "does not
    # match" — which is the only thing the catch-all can then absorb.

    # Clauses that bind a payload value and deliberately carry no guard,
    # because the value's every consumer is already total. Keyed by event name
    # and file, with the reason, so removing the reason fails the test.
    @unguarded %{
      {"preview_live.ex", "cursor"} => "clamp/1 is total: is_number or 0.0",
      {"token_preview_live.ex", "cursor"} => "clamp/1 is total: is_number or 0.0"
    }

    test "no handler binds a client value without saying what shape it expects" do
      offenders =
        "lib/kiln_cms_web/live/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(&unguarded_clauses/1)
        |> Enum.reject(fn {file, _line, event, _missing} ->
          Map.has_key?(@unguarded, {Path.basename(file), event})
        end)

      assert offenders == [],
             """
             These handle_event/3 clauses bind a value out of a client-chosen
             payload without a guard on the head (#764). A wrong shape reaches
             the body, where String./Integer.parse/Ash and friends raise — the
             catch-all cannot help, because the clause matched.

             Add `when is_binary(x)` (or is_map / is_list / is_number — whichever
             the body actually needs), or, if every consumer of the value is
             already total, add an entry to @unguarded with the reason.

             #{Enum.map_join(offenders, "\n", fn {f, l, e, missing} -> "  #{f}:#{l} #{e} — unguarded: #{Enum.join(missing, ", ")}" end)}
             """
    end
  end

  # {file, line, event, [unguarded var]} for each handle_event/3 clause that
  # binds a payload value the head's guard never mentions.
  defp unguarded_clauses(file) do
    {_ast, found} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:def, meta, [head, _body]} = node, acc ->
          case offender(file, meta[:line], head) do
            nil -> {node, acc}
            found -> {node, [found | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp offender(file, line, head) do
    with {event, binds, guarded} <- clause_shape(head),
         [_ | _] = missing <- Enum.reject(binds, &(&1 in guarded)) do
      {file, line, event, missing}
    else
      _not_an_offender -> nil
    end
  end

  # {event_name, bound_vars, guarded_vars} or nil if this isn't a
  # handle_event/3 clause that binds anything out of the payload.
  defp clause_shape({:when, _meta, [inner, guard]}) do
    case clause_shape(inner) do
      nil -> nil
      {event, binds, _} -> {event, binds, guard_vars(guard)}
    end
  end

  defp clause_shape({:handle_event, _meta, [event, payload, _socket]}) do
    case payload_binds(payload) do
      [] -> nil
      binds -> {event_name(event), binds, []}
    end
  end

  defp clause_shape(_other), do: nil

  defp event_name(name) when is_binary(name), do: name
  defp event_name(other), do: Macro.to_string(other)

  # Variables bound to a key of the payload map, at any nesting depth.
  # `_`-prefixed bindings are discards and constrain nothing, so they need no
  # guard.
  defp payload_binds({:%{}, _meta, pairs}) do
    Enum.flat_map(pairs, fn
      {_key, {var, _m, ctx}} when is_atom(var) and is_atom(ctx) ->
        if String.starts_with?(to_string(var), "_"), do: [], else: [var]

      {_key, nested} ->
        payload_binds(nested)

      _other ->
        []
    end)
  end

  defp payload_binds({:=, _meta, [left, right]}),
    do: payload_binds(left) ++ payload_binds(right)

  defp payload_binds(_other), do: []

  defp guard_vars(guard) do
    {_ast, vars} =
      Macro.prewalk(guard, [], fn
        {var, _m, ctx} = node, acc when is_atom(var) and is_atom(ctx) -> {node, [var | acc]}
        node, acc -> {node, acc}
      end)

    vars
  end
end
