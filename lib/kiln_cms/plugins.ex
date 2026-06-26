defmodule KilnCMS.Plugins do
  @moduledoc """
  Registry of installed plugins (issue #63).

  Plugins are listed in config and each implements `KilnCMS.Plugin`:

      config :kiln_cms, plugins: [KilnPluginCallout, MyApp.SomePlugin]

  This module reads that list, ignores anything that isn't a valid plugin, and
  exposes the aggregate extension points. Today that's block modules, which
  `KilnCMS.Blocks` merges into the block registry; the same pattern extends to
  future extension types.
  """

  @doc "Configured plugin modules that implement the `KilnCMS.Plugin` behaviour."
  @spec all() :: [module()]
  def all do
    :kiln_cms
    |> Application.get_env(:plugins, [])
    |> Enum.filter(&plugin?/1)
  end

  @doc "Every block module contributed by an installed plugin (deduped, valid blocks only)."
  @spec block_modules() :: [module()]
  def block_modules do
    all()
    |> Enum.flat_map(& &1.blocks())
    |> Enum.uniq()
    |> Enum.filter(&block?/1)
  end

  @doc """
  Metadata for each installed plugin — `%{module, name, version, blocks}` — for
  an admin "installed plugins" view or diagnostics.
  """
  @spec info() :: [%{module: module(), name: String.t(), version: String.t(), blocks: [module()]}]
  def info do
    Enum.map(all(), fn mod ->
      %{module: mod, name: mod.name(), version: mod.version(), blocks: mod.blocks()}
    end)
  end

  defp plugin?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :blocks, 0) and
      KilnCMS.Plugin in behaviours(module)
  end

  # A plugin-contributed block must be a real Kiln block (renderable embedded
  # resource), so a misconfigured plugin can't inject an arbitrary module.
  defp block?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :render, 2) and
      Kiln.Block.Renderer in behaviours(module)
  end

  defp behaviours(module) do
    for {:behaviour, list} <- module.module_info(:attributes), behaviour <- list, do: behaviour
  end
end
