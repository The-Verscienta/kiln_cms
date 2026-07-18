defmodule KilnCMS.Blocks.Upcaster do
  @moduledoc """
  Block schema evolution / upcasting (Kiln v2 — decision D15).

  A stored block map carries `_version`; if it is behind the block module's
  current version, the declared `migrate` chain (`Kiln.Block.Info.migrations/1`)
  runs to bring it to head. Upcasting is **lazy on read** (`upcast/2`,
  `upcast_block_map/1`, applied wherever typed blocks are obtained) and the same
  function powers **eager backfill** (`upcast_all/1`, wrap in Oban once the stored
  column is union — Phase C flip). Idempotent: a head-version map is returned
  unchanged.

  For already-*fired* artifacts on a schema bump, the strategy is **re-fire the
  affected types** (decision H1) — re-firing reads the now-upcast blocks.
  """
  alias KilnCMS.Blocks

  @doc "Current (head) schema version for a block module."
  @spec current_version(module()) :: pos_integer()
  def current_version(module), do: Kiln.Block.Info.version(module) || 1

  @doc "Upcast a stored block map to its module's current version."
  @spec upcast(module(), map()) :: map()
  def upcast(module, map) when is_map(map) do
    from = stored_version(map)
    to = current_version(module)

    if from >= to do
      map
    else
      migrations = module |> Kiln.Block.Info.migrations() |> Map.new(&{&1.from, &1})
      Enum.reduce(from..(to - 1)//1, map, &apply_step(&2, &1, migrations))
    end
  end

  @doc "Resolve a stored map's module by its `_type` and upcast it (lazy-read path)."
  @spec upcast_block_map(map()) :: map()
  def upcast_block_map(%{"_type" => type} = map) do
    case Blocks.fetch(safe_atom(type)) do
      {:ok, module} -> upcast(module, map)
      :error -> map
    end
  end

  def upcast_block_map(map), do: map

  @doc "Eager backfill over a list of stored block maps."
  @spec upcast_all([map()]) :: [map()]
  def upcast_all(maps) when is_list(maps), do: Enum.map(maps, &upcast_block_map/1)

  defp apply_step(map, version, migrations) do
    case Map.get(migrations, version) do
      %{to: to, fun: fun} -> map |> fun.() |> Map.put("_version", to)
      nil -> Map.put(map, "_version", version + 1)
    end
  end

  defp stored_version(map), do: Map.get(map, "_version") || Map.get(map, :_version) || 1

  @types %{
    "heading" => :heading,
    "image" => :image,
    "rich_text" => :rich_text,
    "quote" => :quote,
    "embed" => :embed,
    "columns" => :columns,
    "custom" => :custom
  }
  defp safe_atom(type) when is_atom(type), do: type
  defp safe_atom(type) when is_binary(type), do: Map.get(@types, type, :custom)
end
