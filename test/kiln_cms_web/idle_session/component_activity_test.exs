defmodule KilnCMSWeb.IdleSession.ComponentActivityTest do
  @moduledoc """
  LiveComponent events as idle-timeout activity (#2491): what a component's
  wrapped `handle_event/3` reports, that it reports nothing in a LiveView the
  idle hooks are not attached to, and that every component in `lib/` gets the
  wrapper. The signed-in effect on `last_used_at` is in
  `KilnCMSWeb.IdleTimeoutTest`, beside the other activity tests.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMSWeb.IdleSession

  @tracked {IdleSession, :tracked}

  describe "component_event/1" do
    test "tells a tracked LiveView about the person's event" do
      Process.put(@tracked, true)

      assert IdleSession.component_event("mark-all-read") == :ok
      assert_received {:kiln_idle_component_activity}
    end

    test "says nothing for a reply a hook sends on its own" do
      Process.put(@tracked, true)

      IdleSession.component_event("push_state")
      refute_received {:kiln_idle_component_activity}
    end

    test "says nothing in a process the idle hooks are not attached to" do
      IdleSession.component_event("mark-all-read")
      refute_received {:kiln_idle_component_activity}
    end
  end

  describe "a component on an anonymous page" do
    test "sends its LiveView nothing, and the page keeps working", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign-in")
      :erlang.trace(lv.pid, true, [:receive])

      lv
      |> element("#user-password-sign-in-with-password")
      |> render_change(%{"user" => %{"email" => "someone@example.com"}})

      assert render(lv) =~ "user-password-sign-in-with-password"
      :erlang.trace(lv.pid, false, [:receive])

      refute_received {:trace, _pid, :receive, {:kiln_idle_component_activity}}
    end
  end

  # Components get the wrapper from `use KilnCMSWeb, :live_component`; one
  # that calls `use Phoenix.LiveComponent` itself would have its events
  # silently not count again.
  describe "every component in lib/" do
    test "goes through `use KilnCMSWeb, :live_component`" do
      users =
        Path.wildcard("lib/**/*.{ex,exs}")
        |> Enum.filter(&uses_live_component?/1)

      # The scan is not vacuous: the one place allowed to do it is found.
      assert "lib/kiln_cms_web.ex" in users

      assert users -- ["lib/kiln_cms_web.ex"] == [],
             "use `use KilnCMSWeb, :live_component` instead of `use Phoenix.LiveComponent` " <>
               "in #{inspect(users -- ["lib/kiln_cms_web.ex"])}, so the component's " <>
               "events count as idle-timeout activity (KilnCMSWeb.IdleSession.ComponentActivity)"
    end
  end

  defp uses_live_component?(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _meta, [{:__aliases__, _, [:Phoenix, :LiveComponent]} | _opts]} = node, _found ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found?
  end
end
