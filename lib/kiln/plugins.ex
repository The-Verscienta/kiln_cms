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

  @doc "Every plugin-declared admin nav item."
  @spec nav_items() :: [Kiln.Plugin.nav_item()]
  def nav_items, do: Enum.flat_map(all(), & &1.nav_items())

  @doc "Every plugin-declared admin route."
  @spec admin_routes() :: [Kiln.Plugin.admin_route()]
  def admin_routes, do: Enum.flat_map(all(), & &1.admin_routes())

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
end
