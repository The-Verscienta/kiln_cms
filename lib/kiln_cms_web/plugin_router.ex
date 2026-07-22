defmodule KilnCMSWeb.PluginRouter do
  @moduledoc """
  Router macros expanding plugin-contributed routes (D18) inside the gated
  live sessions: `plugin_admin_routes/0` in the admin-gated session and
  `plugin_editor_routes/0` in the editor-gated session (their content types
  are already served by the generic public delivery).

  Expansion happens at compile time from `Kiln.Plugins.admin_routes/0` /
  `Kiln.Plugins.editor_routes/0`, so plugin panels are ordinary compiled
  routes: verified paths, LiveView auth `on_mount` hooks, the works.
  """

  defmacro plugin_admin_routes do
    expand_routes(Kiln.Plugins.admin_routes())
  end

  defmacro plugin_editor_routes do
    expand_routes(Kiln.Plugins.editor_routes())
  end

  defp expand_routes(plugin_routes) do
    routes =
      for {path, live_view, action} <- plugin_routes do
        quote do
          live unquote(live_view_path(path)), unquote(live_view), unquote(action)
        end
      end

    # `alias: false` — plugin modules are fully qualified; the surrounding
    # `scope "/", KilnCMSWeb` must not prefix them.
    quote do
      scope "/", alias: false do
        (unquote_splicing(routes))
      end
    end
  end

  # Paths were validated by the doctor; normalize just in case.
  defp live_view_path("/" <> _ = path), do: path
  defp live_view_path(path), do: "/" <> path
end
