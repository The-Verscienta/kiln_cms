defmodule KilnCMSWeb.PluginPlugRoutesExpansionTest do
  @moduledoc """
  The `plugin_plug_routes/0` macro (#2272) built into small throwaway routers,
  since the real `KilnCMSWeb.Router` is compiled once from the configured
  plugins: the `:match` verb answers every method, and a malformed entry stops
  the build with a `CompileError` naming the plugin.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  defmodule Echo do
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, "method=" <> conn.method)
  end

  defmodule MatchPlugin do
    def plug_routes, do: [{:match, "/zz-match-hook", Echo, []}]
  end

  defmodule BadPlugin do
    def plug_routes, do: [{:get, "/:slug", Echo, []}]
  end

  defmodule NotATuplePlugin do
    def plug_routes, do: [:nope]
  end

  defp build_router(plugins) do
    name = Module.concat(__MODULE__, "Router#{System.unique_integer([:positive])}")
    routes = KilnCMSWeb.PluginRouter.plug_routes_ast(plugins)

    body =
      quote do
        use Phoenix.Router
        unquote(routes)
      end

    {:module, mod, _, _} = Module.create(name, body, Macro.Env.location(__ENV__))
    mod
  end

  test "a :match route answers every HTTP method" do
    router = build_router([MatchPlugin])

    for method <- ~w(GET POST PUT PATCH DELETE OPTIONS) do
      conn = router.call(conn(method, "/zz-match-hook"), router.init([]))

      assert conn.status == 200
      assert conn.resp_body == "method=" <> method
    end
  end

  test "a :match route answers only its own path" do
    router = build_router([MatchPlugin])

    assert_raise Phoenix.Router.NoRouteError, fn ->
      router.call(conn(:get, "/zz-other"), router.init([]))
    end
  end

  test "a malformed entry stops the build with a CompileError naming the plugin" do
    error =
      assert_raise CompileError, fn -> build_router([BadPlugin]) end

    assert error.description =~ inspect(BadPlugin)
    assert error.description =~ "invalid plug_routes/0 entry"
    assert error.description =~ "parameter or wildcard"
  end

  test "an entry that is not a route tuple is refused too" do
    error = assert_raise CompileError, fn -> build_router([NotATuplePlugin]) end

    assert error.description =~ inspect(NotATuplePlugin)
    assert error.description =~ "is not {verb, path, plug_module, plug_opts}"
  end

  test "a valid plugin beside a malformed one still fails the whole build" do
    assert_raise CompileError, ~r/#{inspect(BadPlugin)}/, fn ->
      build_router([MatchPlugin, BadPlugin])
    end
  end
end
