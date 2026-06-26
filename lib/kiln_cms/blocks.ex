defmodule KilnCMS.Blocks do
  @moduledoc """
  Registry and serializer dispatch for typed blocks (Kiln v2 — D10/D11).

  Block modules (`use Kiln.Block`) are discovered from the compiled application,
  keyed by their `_type` discriminator. `render/2` and `search_text/1` dispatch by
  struct type — multiple dispatch *is* the serializer registry (decision A4). The
  registry is what the Phase C `Ash.Type.Union` and the Phase D firing service
  build on.
  """

  @doc "All block modules using `Kiln.Block`."
  @spec modules() :: [module()]
  def modules do
    case :application.get_key(:kiln_cms, :modules) do
      {:ok, mods} -> Enum.filter(mods, &kiln_block?/1)
      _ -> []
    end
  end

  @doc "Map of `_type` discriminator → block module."
  @spec registry() :: %{atom() => module()}
  def registry, do: Map.new(modules(), &{Kiln.Block.Info.name(&1), &1})

  @doc "Look up a block module by its `_type`."
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(type) when is_atom(type), do: Map.fetch(registry(), type)

  @doc "Serialize a block struct to a surface (dispatches to the block module)."
  @spec render(struct(), Kiln.Block.Renderer.surface()) :: iodata() | map() | nil
  def render(%module{} = block, surface), do: module.render(block, surface)

  @doc "Plain-text projection of a block struct (dispatches to the block module)."
  @spec search_text(struct()) :: String.t()
  def search_text(%module{} = block), do: module.search_text(block)

  defp kiln_block?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :render, 2) and
      Kiln.Block.Renderer in behaviours(module)
  end

  # A module can declare several `@behaviour`s; module_info/1 returns one
  # `:behaviour` entry per declaration, so collect them all (not just the first).
  defp behaviours(module) do
    for {:behaviour, list} <- module.module_info(:attributes), behaviour <- list, do: behaviour
  end
end
