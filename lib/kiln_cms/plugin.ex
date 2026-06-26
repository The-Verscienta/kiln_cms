defmodule KilnCMS.Plugin do
  @moduledoc """
  Behaviour for a KilnCMS plugin (issue #63).

  A plugin is an external package (its own OTP application) that extends KilnCMS
  — today by contributing typed block types (`Kiln.Block` modules), with room to
  grow (resources, LiveView hooks, API extensions). In-app blocks are
  auto-discovered from the `:kiln_cms` application; plugins are how blocks
  defined in *another* package get into the registry.

  Define a plugin with `use KilnCMS.Plugin`, overriding what you provide:

      defmodule KilnPluginCallout do
        use KilnCMS.Plugin

        @impl true
        def name, do: "Callout"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def blocks, do: [KilnPluginCallout.Blocks.Callout]
      end

  Then enable it in the host app's config:

      config :kiln_cms, plugins: [KilnPluginCallout]

  Its blocks then appear in the block registry, the editor inserter, and the
  render/search-text dispatch. See `KilnCMS.Plugins` and `docs/plugins.md`.
  """

  @doc "Human-readable plugin name."
  @callback name() :: String.t()

  @doc "Plugin version string (e.g. \"1.0.0\")."
  @callback version() :: String.t()

  @doc "Block modules (`use Kiln.Block`) this plugin contributes."
  @callback blocks() :: [module()]

  defmacro __using__(_opts) do
    quote do
      @behaviour KilnCMS.Plugin

      @impl true
      def name, do: __MODULE__ |> Module.split() |> List.last()

      @impl true
      def version, do: "0.0.0"

      @impl true
      def blocks, do: []

      defoverridable name: 0, version: 0, blocks: 0
    end
  end
end
