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
  """
  import Cachex.Spec, only: [hook: 1]

  @cache :kiln_cms_firing_cache
  @surfaces [:web, :json, :json_ld]
  @ttl :timer.minutes(60)

  # Hard cap on cached artifacts. Without it, fired bodies (documents × 3
  # surfaces) accumulate in BEAM memory forever. An evented LRW policy reclaims
  # ~10% once the cap is hit, mirroring `KilnCMS.Cache`.
  @max_entries 10_000

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

  @spec put(Ash.UUID.t(), atom(), Ash.UUID.t(), atom(), map()) :: :ok
  def put(org_id, document_type, document_id, surface, body) do
    # Cachex honors `:expire`, not `:ttl` — the latter is silently ignored, so
    # entries would otherwise never expire (see KilnCMS.Cache).
    Cachex.put(@cache, key(org_id, document_type, document_id, surface), body, expire: @ttl)
    :ok
  end

  @doc "Evict every surface for a document (on unpublish or re-fire)."
  @spec evict(Ash.UUID.t(), atom(), Ash.UUID.t()) :: :ok
  def evict(org_id, document_type, document_id) do
    Enum.each(@surfaces, &Cachex.del(@cache, key(org_id, document_type, document_id, &1)))
    :ok
  end

  defp key(org_id, document_type, document_id, surface),
    do: {org_id, document_type, document_id, surface}
end
