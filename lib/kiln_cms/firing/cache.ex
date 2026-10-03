defmodule KilnCMS.Firing.Cache do
  @moduledoc """
  Two-tier read cache for fired artifacts (Kiln v2 — decision D9/D1).

  Tier 1 is in-BEAM ETS via Cachex (always on, started in the supervision tree).
  Tier 2 is an optional shared cache (Redis/Dragonfly) behind a config seam —
  **off by default** to honor the project's minimal-ops goal (D2). When a tier-2
  adapter is configured it would back-fill tier 1 on miss; none ships today.

  Keyed by `{org_id, document_type, document_id, surface}` — the tenant (epic
  #336) is part of the key so eviction and any tier-2 (Redis) sharing stay
  correct per site even though `document_id` (a UUID) is globally unique.

  Each body is also kept **already encoded as JSON**, under a companion key
  (`get_json/4`), for readers that hand a body to a client without looking
  inside it: a sync API page embeds up to 500 artifacts, and encoding them
  again on every request was most of its cost (#1713). `put/5` writes both
  entries in one ETS insert and `evict/3` drops both, so the JSON is always
  the encoding of the body beside it. Nothing writes the JSON on its own: a
  reader that encoded lazily and cached the result could put back the
  encoding of a body that a concurrent fire had already replaced.
  """
  import Cachex.Spec, only: [hook: 1]

  @cache :kiln_cms_firing_cache
  @surfaces KilnCMS.Firing.Surfaces.all()
  @ttl :timer.minutes(60)

  # Hard cap on cached artifacts. Without it, fired bodies (documents × 3
  # surfaces) accumulate in BEAM memory forever. An evented LRW policy reclaims
  # ~10% once the cap is hit, mirroring `KilnCMS.Cache`. Two entries per
  # artifact (the body and its JSON), so this still holds 10,000 artifacts.
  @max_entries 20_000

  @doc "Cachex instance name (supervised in the application tree)."
  def cache_name, do: @cache

  @doc """
  Supervisor child spec for the firing cache, bounded to `#{@max_entries}`
  entries by an evented least-recently-written eviction policy. Used in place of
  a bare `{Cachex, ...}` child so fired artifacts can't grow memory without bound.
  """
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

  @spec get(Ash.UUID.t(), atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :miss
  def get(org_id, document_type, document_id, surface) do
    case Cachex.get(@cache, key(org_id, document_type, document_id, surface)) do
      {:ok, nil} -> :miss
      {:ok, body} -> {:ok, body}
      _ -> :miss
    end
  end

  @doc """
  The cached body already encoded as JSON, for a response that embeds it
  verbatim (`Jason.Fragment`). `:miss` when the body is not cached or could
  not be encoded; the caller then reads the body and encodes it itself.
  """
  @spec get_json(Ash.UUID.t(), atom(), Ash.UUID.t(), atom()) :: {:ok, binary()} | :miss
  def get_json(org_id, document_type, document_id, surface) do
    case Cachex.get(@cache, json_key(org_id, document_type, document_id, surface)) do
      {:ok, json} when is_binary(json) -> {:ok, json}
      _ -> :miss
    end
  end

  @spec put(Ash.UUID.t(), atom(), Ash.UUID.t(), atom(), map()) :: :ok
  def put(org_id, document_type, document_id, surface, body) do
    # A body that cannot be encoded stores `nil` beside it, which `get_json/4`
    # reads as a miss, so an older encoding is overwritten, never left behind.
    json =
      case Jason.encode(body) do
        {:ok, json} -> json
        {:error, _} -> nil
      end

    # One insert for both, so no reader finds a body beside another body's
    # JSON. Cachex honors `:expire`, not `:ttl` — the latter is silently
    # ignored, so entries would otherwise never expire (see KilnCMS.Cache).
    Cachex.put_many(
      @cache,
      [
        {key(org_id, document_type, document_id, surface), body},
        {json_key(org_id, document_type, document_id, surface), json}
      ],
      expire: @ttl
    )

    :ok
  end

  @doc """
  Drop every cached artifact body. The blunt operator-facing primitive behind
  `KilnCMS.Cache.flush_delivery/0` and `mix kiln.cache.flush` (#483) — nothing on
  a write path should reach for it, since writes evict precisely.

  Returns the number of entries dropped, or `0` when the cache is disabled.
  """
  @spec clear() :: non_neg_integer()
  def clear do
    case Cachex.clear(@cache) do
      {:ok, count} when is_integer(count) -> count
      _ -> 0
    end
  end

  @doc "Evict every surface for a document (on unpublish or re-fire)."
  @spec evict(Ash.UUID.t(), atom(), Ash.UUID.t()) :: :ok
  def evict(org_id, document_type, document_id) do
    Enum.each(@surfaces, fn surface ->
      Cachex.del(@cache, key(org_id, document_type, document_id, surface))
      Cachex.del(@cache, json_key(org_id, document_type, document_id, surface))
    end)

    :ok
  end

  defp key(org_id, document_type, document_id, surface),
    do: {org_id, document_type, document_id, surface}

  defp json_key(org_id, document_type, document_id, surface),
    do: {:json, org_id, document_type, document_id, surface}
end
