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
  import Cachex.Spec, only: [hook: 1]

  @cache :kiln_cms_content_cache

  # Safety net only — invalidation is normally driven by content writes.
  @ttl :timer.minutes(60)

  # Hard cap on cached entries. Without it an anonymous flood of distinct slugs
  # (one entry per `{type, slug, locale}`) could grow the cache without bound.
  # An evented LRW policy reclaims ~10% of entries once the cap is hit.
  @max_entries 10_000

  @doc "The Cachex instance name (started in the application supervision tree)."
  def cache_name, do: @cache

  @doc """
  Supervisor child spec for the content cache, bounded to `#{@max_entries}`
  entries by an evented least-recently-written eviction policy. Used in place of
  a bare `{Cachex, ...}` child so the public content hot path can't be turned
  into an unbounded-memory DoS.
  """
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

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

  @doc """
  Generic cache-aside helper: return the value cached under `key`, or compute it
  with `fun` and cache it for `ttl` milliseconds (a non-`nil` result; a `nil` is
  recomputed each call, as in `fetch_published/4`). Cleared by `bust_published/0`
  along with everything else, so it stays fresh on writes.
  """
  @spec fetch(term(), pos_integer(), (-> any())) :: any()
  def fetch(key, ttl, fun) when is_function(fun, 0) do
    if enabled?() do
      case Cachex.get(@cache, key) do
        {:ok, nil} ->
          value = fun.()
          Cachex.put(@cache, key, value, expire: ttl)
          value

        {:ok, value} ->
          value

        _ ->
          fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Invalidate every locale variant of a single published record (`{type, slug}`).

  The precise alternative to `bust_published/0`: a publish or edit drops only the
  keys for the affected record instead of clearing the whole cache. All locales
  are busted because a request for a missing locale caches the default-locale
  fallback under the *requested* locale's key (same slug), so a single slug can
  live under several locale keys.
  """
  @spec bust(String.t(), String.t()) :: :ok
  def bust(type, slug) when is_binary(type) and is_binary(slug) do
    if enabled?() do
      Enum.each(KilnCMS.I18n.locales(), fn locale ->
        Cachex.del(@cache, key(type, slug, locale))
      end)
    end

    :ok
  end

  @doc """
  Drop all cached published content. The blunt fallback for writes whose blast
  radius isn't a single `{type, slug}` (e.g. a media-item edit that may be
  referenced by any number of pages); prefer `bust/2` where the affected record
  is known.
  """
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
