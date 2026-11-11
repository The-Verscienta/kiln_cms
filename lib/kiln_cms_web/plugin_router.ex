defmodule KilnCMSWeb.PluginRouter do
  @moduledoc """
  Router macros expanding plugin-contributed routes (D18) inside the gated
  live sessions: `plugin_admin_routes/0` in the admin-gated session and
  `plugin_editor_routes/0` in the editor-gated session (their content types
  are already served by the generic public delivery).

  Expansion happens at compile time from `Kiln.Plugins.admin_routes/0` /
  `Kiln.Plugins.editor_routes/0`, so plugin panels are ordinary compiled
  routes: verified paths, LiveView auth `on_mount` hooks, the works.
  `plugin_plug_routes/0` expands `Kiln.Plugins.plug_routes/0` the same way, for
  the plain-Plug endpoints (webhooks, JSON, feeds) in the router's
  `:plugin_endpoint` scope.
  """

  defmacro plugin_admin_routes do
    expand_routes(Kiln.Plugins.admin_routes())
  end

  defmacro plugin_editor_routes do
    expand_routes(Kiln.Plugins.editor_routes())
  end

  defmacro plugin_public_routes do
    expand_routes(Kiln.Plugins.public_routes())
  end

  @doc """
  Expands `Kiln.Plugins.plug_routes/0` (#2272) into `get`/`post`/…/`forward`
  calls. Invoked inside the router's `:plugin_endpoint` scope; a malformed
  route stops the build, naming the plugin that declared it.
  """
  defmacro plugin_plug_routes do
    plug_routes_ast(Kiln.Plugins.all())
  end

  @doc false
  # The expansion proper, taking the plugin list so a test can build a throwaway
  # router from test-only plugins without touching `config :kiln_cms, :plugins`.
  def plug_routes_ast(plugins) do
    routes =
      for plugin <- plugins,
          route <- Kiln.Plugins.PlugRoute.of(plugin) do
        case Kiln.Plugins.PlugRoute.validate(route) do
          :ok ->
            plug_route(route)

          {:error, reason} ->
            raise CompileError,
              description: "plugin #{inspect(plugin)}: invalid plug_routes/0 entry: #{reason}"
        end
      end

    quote do
      (unquote_splicing(routes))
    end
  end

  # `plug_opts` is escaped: it is a runtime term here, and `Macro.escape/1` is
  # what `PlugRoute.validate/1` already proved it survives.
  defp plug_route({:forward, path, plug, opts}) do
    quote do
      forward unquote(path), unquote(plug), unquote(Macro.escape(opts))
    end
  end

  defp plug_route({:match, path, plug, opts}) do
    quote do
      match :*, unquote(path), unquote(plug), unquote(Macro.escape(opts))
    end
  end

  defp plug_route({verb, path, plug, opts}) do
    quote do
      match unquote(verb), unquote(path), unquote(plug), unquote(Macro.escape(opts))
    end
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
