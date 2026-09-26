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

  ## A gap refuses (#1642)

  The chain is followed step by step from the stored `_version`. When a
  stored version has no `migrate` step onward (or the step runs backwards or
  past the declared version), the upcast is **refused**: the stored map comes
  back exactly as it was, `_version` included. It used to be stamped with the
  head version anyway, which marked never-transformed data current so that no
  later run would migrate it. `Kiln.Block.MigrationChain` warns about such a
  chain when the block module compiles.

  Two entry points per shape:

    * `try_upcast/2` / `try_upcast_block_map/1` return `{:ok, map}` or
      `{:error, refusal}` — for callers that report, like an eager backfill.
    * `upcast/2` / `upcast_block_map/1` never fail — for read and delivery
      paths. A refused block is returned as stored and a warning is logged;
      the renderer reads whatever fields the stored shape has, which is the
      conservative choice next to crashing a page render.
  """
  require Logger

  alias KilnCMS.Blocks

  @typedoc """
  Why an upcast was refused. `kind` and `detail` are the fields a report
  prints; the rest say which block and where its chain breaks.
  """
  @type refusal :: %{
          kind: :missing_migration,
          detail: String.t(),
          module: module(),
          type: String.t() | nil,
          from: pos_integer(),
          to: pos_integer(),
          missing: pos_integer()
        }

  @doc "Current (head) schema version for a block module."
  @spec current_version(module()) :: pos_integer()
  def current_version(module), do: Kiln.Block.Info.version(module) || 1

  @doc """
  Upcast a stored block map to its module's current version.

  Never fails: a refused upcast (see `try_upcast/2`) logs a warning and returns
  the map exactly as stored.
  """
  @spec upcast(module(), map()) :: map()
  def upcast(module, map) when is_map(map) do
    case try_upcast(module, map) do
      {:ok, upcast} ->
        upcast

      {:error, refusal} ->
        Logger.warning(
          "Block upcast refused, block left as stored: #{refusal.detail} (#{inspect(module)})"
        )

        map
    end
  end

  @doc """
  Upcast a stored block map to its module's current version, or say why not.

  `{:error, refusal}` when the declared `migrate` chain cannot carry the stored
  `_version` to head; the stored map is untouched. A map at or past head is
  `{:ok, map}` unchanged.
  """
  @spec try_upcast(module(), map()) :: {:ok, map()} | {:error, refusal()}
  def try_upcast(module, map) when is_map(map) do
    from = stored_version(map)
    to = current_version(module)

    if from >= to do
      {:ok, map}
    else
      steps = module |> Kiln.Block.Info.migrations() |> Map.new(&{&1.from, &1})

      case walk(map, from, to, steps) do
        {:ok, upcast} -> {:ok, upcast}
        {:gap, at} -> {:error, refusal(module, map, from, to, at)}
      end
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

  @doc """
  `upcast_block_map/1`, reporting a refusal instead of logging it. A map whose
  `_type` names no block (or has none) is `{:ok, map}` unchanged.
  """
  @spec try_upcast_block_map(map()) :: {:ok, map()} | {:error, refusal()}
  def try_upcast_block_map(%{"_type" => type} = map) do
    case Blocks.fetch(safe_atom(type)) do
      {:ok, module} -> try_upcast(module, map)
      :error -> {:ok, map}
    end
  end

  def try_upcast_block_map(map), do: {:ok, map}

  @doc "Eager backfill over a list of stored block maps."
  @spec upcast_all([map()]) :: [map()]
  def upcast_all(maps) when is_list(maps), do: Enum.map(maps, &upcast_block_map/1)

  # Follow the declared steps. Each must move forward without passing head;
  # the first version with no such step is the gap, and nothing walked so far
  # is kept — the caller still holds the stored map.
  defp walk(map, to, to, _steps), do: {:ok, map}

  defp walk(map, at, to, steps) do
    case Map.get(steps, at) do
      %{to: next, fun: fun} when next > at and next <= to ->
        map |> fun.() |> Map.put("_version", next) |> walk(next, to, steps)

      _missing_or_unusable ->
        {:gap, at}
    end
  end

  defp refusal(module, map, from, to, at) do
    type = Map.get(map, "_type")

    %{
      kind: :missing_migration,
      detail:
        "#{type || inspect(module)} v#{from} → v#{to}: no usable `migrate` step from v#{at}",
      module: module,
      type: type,
      from: from,
      to: to,
      missing: at
    }
  end

  defp stored_version(map), do: Map.get(map, "_version") || Map.get(map, :_version) || 1

  defp safe_atom(type) when is_atom(type), do: type

  # This used to be a hand-written string→atom map, and it had silently fallen
  # five types behind: `faq`, `how_to`, `claim`, `form` and `divider` all
  # resolved to `:custom`, so `upcast_block_map/1` looked up the wrong module's
  # migration chain for them. Harmless only because no block has ever declared
  # `version > 1` — the first `migrate` step on any of those types would simply
  # not have run, on read, with nothing failing.
  #
  # `to_existing_atom` needs no list to keep current: every block type name
  # exists as an atom because a block module declared it, plugin blocks
  # included. A `_type` that names no block resolves to an atom `Blocks.fetch/1`
  # rejects (or raises here and is caught), and the caller returns the map
  # untouched — which is the right answer for a type this build knows nothing
  # about, and a better one than the old fallback of upcasting it as `:custom`.
  #
  # The atom table cannot be grown from a stored document: `to_existing_atom`
  # only ever returns atoms that already exist.
  defp safe_atom(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :__unknown_block_type__
  end
end
