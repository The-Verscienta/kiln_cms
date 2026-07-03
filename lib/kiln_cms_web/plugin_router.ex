defmodule KilnCMSWeb.PluginRouter do
  @moduledoc """
  Router macro expanding plugin-contributed **admin routes** (D18) inside the
  admin-gated live session — the only routing surface plugins get in v1
  (their content types are already served by the generic public delivery).

  Expansion happens at compile time from `Kiln.Plugins.admin_routes/0`, so
  plugin panels are ordinary compiled routes: verified paths, LiveView
  auth `on_mount` hooks, the works.
  """

  defmacro plugin_admin_routes do
    routes =
      for {path, live_view, action} <- Kiln.Plugins.admin_routes() do
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
