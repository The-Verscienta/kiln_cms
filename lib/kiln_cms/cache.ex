defmodule KilnCMS.Cache do
  @moduledoc """
  In-BEAM cache (Cachex) for the public content-delivery hot path.

  Published content fetched by slug is cached per `{type, slug}` so repeated
  requests for the same page skip the database. Entries carry a safety-net TTL
  and are invalidated precisely on any write that affects published content (see
  `KilnCMS.CMS.Changes.BustContentCache`).

  In keeping with the project's minimal-ops goal this is in-process only (no
  Redis/Dragonfly); a shared multi-node cache is deferred until measured (D2).

  Set `config :kiln_cms, KilnCMS.Cache, enabled: false` to bypass the cache
  (every read hits the source) without removing the supervised process.
  """
  @cache :kiln_cms_content_cache

  # Safety net only — invalidation is normally driven by content writes.
  @ttl :timer.minutes(60)

  @doc "The Cachex instance name (started in the application supervision tree)."
  def cache_name, do: @cache

  @doc """
  Return the cached published record for `{type, slug, locale}`, or compute it
  with `fun`, caching a non-nil result. Keyed by locale so each locale variant
  (and the default-locale fallback served for a missing one) caches separately.
  A `nil` (not found) is never cached, so newly published content appears
  immediately. Falls back to `fun` if the cache is disabled or the backend errors.
  """
  @spec fetch_published(String.t(), String.t(), String.t(), (-> any())) :: any()
  def fetch_published(type, slug, locale, fun) when is_function(fun, 0) do
    if enabled?() do
      key = key(type, slug, locale)

      case Cachex.get(@cache, key) do
        {:ok, nil} -> compute_and_cache(key, fun)
        {:ok, value} -> value
        _ -> fun.()
      end
    else
      fun.()
    end
  end

  @doc "Drop all cached published content (called after a content write)."
  @spec bust_published() :: :ok
  def bust_published do
    if enabled?(), do: Cachex.clear(@cache)
    :ok
  end

  defp compute_and_cache(key, fun) do
    value = fun.()
    if not is_nil(value), do: Cachex.put(@cache, key, value, expire: @ttl)
    value
  end

  defp key(type, slug, locale), do: "published:#{type}:#{locale}:#{slug}"

  defp enabled? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end
end
