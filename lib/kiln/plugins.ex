defmodule Kiln.Plugins do
  @moduledoc """
  The registry over installed `Kiln.Plugin`s (decision D18).

  Reads `config :kiln_cms, :plugins` at **compile time** — the block union
  and the router expand plugin contributions during compilation, so the list
  must be static per build (which also keeps D4's compile-time-safety stance:
  no runtime module loading).
  """

  @plugins Application.compile_env(:kiln_cms, :plugins, [])

  @doc "The installed plugin modules, in registration order."
  @spec all() :: [module()]
  def all, do: @plugins

  @doc "Every plugin-contributed `Kiln.Block` module."
  @spec blocks() :: [module()]
  def blocks, do: Enum.flat_map(all(), & &1.blocks())

  @doc "Every plugin-contributed `Kiln.FieldType` module."
  @spec field_types() :: [module()]
  def field_types, do: Enum.flat_map(all(), & &1.field_types())

  @doc "Every plugin-declared admin nav item."
  @spec nav_items() :: [Kiln.Plugin.nav_item()]
  def nav_items, do: Enum.flat_map(all(), & &1.nav_items())

  @doc "Every plugin-declared admin route."
  @spec admin_routes() :: [Kiln.Plugin.admin_route()]
  def admin_routes, do: Enum.flat_map(all(), & &1.admin_routes())

  @doc "Every plugin-declared editor route."
  @spec editor_routes() :: [Kiln.Plugin.admin_route()]
  def editor_routes, do: Enum.flat_map(all(), & &1.editor_routes())

  @doc "Every plugin supervision child, appended to the app tree at boot."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children, do: Enum.flat_map(all(), & &1.children())

  @doc "Plugin Oban queues, merged into the core queue config at boot."
  @spec oban_queues() :: keyword(pos_integer())
  def oban_queues do
    Enum.reduce(all(), [], fn plugin, acc ->
      Keyword.merge(acc, plugin.oban_queues())
    end)
  end

  @typedoc """
  The plain-data catalog view of one installed plugin — its declared metadata
  plus its contribution surface. Rendered by `mix kiln.plugins.list` and the
  natural shape for a marketplace UI (see `docs/plugin-extensibility.md`).
  """
  @type manifest :: %{
          module: module(),
          name: String.t(),
          version: String.t() | nil,
          summary: String.t() | nil,
          homepage: String.t() | nil,
          domains: [module()],
          blocks: [module()],
          field_types: [module()],
          nav_items: non_neg_integer(),
          admin_routes: non_neg_integer(),
          editor_routes: non_neg_integer(),
          oban_queues: keyword(pos_integer()),
          children: non_neg_integer()
        }

  @doc """
  The catalog/registry view: one `t:manifest/0` per installed plugin, in
  registration order. Metadata (`version`/`summary`/`homepage`) is whatever the
  plugin declares (`nil` if it declares nothing); contributions are read from
  the same callbacks the seams use.
  """
  @spec manifests() :: [manifest()]
  def manifests, do: Enum.map(all(), &manifest/1)

  @spec manifest(module()) :: manifest()
  defp manifest(plugin) do
    %{
      module: plugin,
      name: plugin.name(),
      version: plugin.version(),
      summary: plugin.summary(),
      homepage: plugin.homepage(),
      domains: plugin.domains(),
      blocks: plugin.blocks(),
      field_types: plugin.field_types(),
      nav_items: length(plugin.nav_items()),
      admin_routes: length(plugin.admin_routes()),
      editor_routes: length(plugin.editor_routes()),
      oban_queues: plugin.oban_queues(),
      children: length(plugin.children())
    }
  end
end
