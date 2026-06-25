defmodule KilnCMS.Firing.Cache do
  @moduledoc """
  Two-tier read cache for fired artifacts (Kiln v2 — decision D9/D1).

  Tier 1 is in-BEAM ETS via Cachex (always on, started in the supervision tree).
  Tier 2 is an optional shared cache (Redis/Dragonfly) behind a config seam —
  **off by default** to honor the project's minimal-ops goal (D2). When a tier-2
  adapter is configured it would back-fill tier 1 on miss; none ships today.

  Keyed by `{document_type, document_id, surface}`.
  """
  @cache :kiln_cms_firing_cache
  @surfaces [:web, :json, :json_ld]
  @ttl :timer.minutes(60)

  @doc "Cachex instance name (supervised in the application tree)."
  def cache_name, do: @cache

  @spec get(atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :miss
  def get(document_type, document_id, surface) do
    case Cachex.get(@cache, key(document_type, document_id, surface)) do
      {:ok, nil} -> :miss
      {:ok, body} -> {:ok, body}
      _ -> :miss
    end
  end

  @spec put(atom(), Ash.UUID.t(), atom(), map()) :: :ok
  def put(document_type, document_id, surface, body) do
    Cachex.put(@cache, key(document_type, document_id, surface), body, ttl: @ttl)
    :ok
  end

  @doc "Evict every surface for a document (on unpublish or re-fire)."
  @spec evict(atom(), Ash.UUID.t()) :: :ok
  def evict(document_type, document_id) do
    Enum.each(@surfaces, &Cachex.del(@cache, key(document_type, document_id, &1)))
    :ok
  end

  defp key(document_type, document_id, surface), do: {document_type, document_id, surface}
end
