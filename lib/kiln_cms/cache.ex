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

  # The two cached shapes of a published `{type, slug, locale}`. Both delivery
  # paths resolve the same coordinates but cache *different* values — the bare
  # record (headless/artifact delivery, `Firing.Delivery.published/4`) vs the
  # media-enriched HTML payload map (`ContentController`). They must never share
  # a key: whichever path seeded first would hand the other a shape it can't
  # render (a FunctionClauseError 500), so each shape gets its own namespace and
  # `bust/3` drops both.
  #
  # The `payload` namespace is the ANONYMOUS, `:public`-only shape (#337 Phase 2).
  # Member and paywall-teaser renders bypass this cache entirely — never add an
  # audience axis to this key. Correctness would then depend on canonically
  # serialising a SET into a string, and any slip would serve gated blocks to
  # anonymous readers. See `docs/memberships.md`.
  @shapes ["record", "payload"]

  @doc """
  Return the cached **bare published record** for `{type, slug, locale}`, or
  compute it with `fun`, caching a non-nil result. Keyed by locale so each
  locale variant (and the default-locale fallback served for a missing one)
  caches separately. A `nil` (not found) is never cached, so newly published
  content appears immediately. Falls back to `fun` if the cache is disabled or
  the backend errors.

  This is the headless-delivery shape (`KilnCMS.Firing.Delivery.published/4`);
  the HTML controller's enriched payload lives under its own namespace via
  `fetch_published_payload/5`.
  """
  @spec fetch_published(Ash.UUID.t(), String.t(), String.t(), String.t(), (-> any())) :: any()
  def fetch_published(org_id, type, slug, locale, fun) when is_function(fun, 0) do
    fetch_shaped("record", org_id, type, slug, locale, fun)
  end

  @doc """
  Like `fetch_published/5`, but for the HTML delivery **payload** shape
  (`%{record, blocks, translations}`, see `KilnCMSWeb.ContentController`).
  Cached under a separate key namespace so it can never collide with the bare
  record cached by `fetch_published/5` for the same `{type, slug, locale}`.
  """
  @spec fetch_published_payload(Ash.UUID.t(), String.t(), String.t(), String.t(), (-> any())) ::
          any()
  def fetch_published_payload(org_id, type, slug, locale, fun) when is_function(fun, 0) do
    fetch_shaped("payload", org_id, type, slug, locale, fun)
  end

  defp fetch_shaped(shape, org_id, type, slug, locale, fun) do
    if enabled?(),
      do: fetch_published_cached(shape, org_id, type, slug, locale, fun),
      else: fun.()
  end

  # `Cachex.fetch` deduplicates concurrent fallback executions per key
  # (Courier), so a burst of requests for a hot page right after an
  # invalidation computes the value once instead of stampeding the DB.
  defp fetch_published_cached(shape, org_id, type, slug, locale, fun) do
    case Cachex.fetch(@cache, key(shape, org_id, type, slug, locale), fn _key ->
           commit(fun.(), @ttl)
         end) do
      {:ok, value} -> emit(:hit, value)
      {:commit, value} -> emit(:miss, value)
      {:ignore, value} -> emit(:miss, value)
      _ -> emit(:miss, fun.())
    end
  end

  # Emit a content-cache hit/miss event (for cache-hit-rate dashboards, #206) and
  # return `value` unchanged.
  defp emit(result, value) do
    :telemetry.execute([:kiln_cms, :cache, :content], %{count: 1}, %{result: result})
    value
  end

  @doc """
  Generic cache-aside helper: return the value cached under `key`, or compute it
  with `fun` and cache it for `ttl` milliseconds (a non-`nil` result; a `nil` is
  recomputed each call, as in `fetch_published/4`). Cleared by `bust_published/0`
  along with everything else, so it stays fresh on writes.
  """
  @spec fetch(term(), pos_integer(), (-> any())) :: any()
  def fetch(key, ttl, fun) when is_function(fun, 0) do
    if enabled?(), do: fetch_cached(key, ttl, fun), else: fun.()
  end

  # Stampede-safe like `fetch_published/4` — one concurrent rebuild per key
  # (this also guards the sitemap, whose rebuild is expensive).
  defp fetch_cached(key, ttl, fun) do
    case Cachex.fetch(@cache, key, fn _key -> commit(fun.(), ttl) end) do
      {:ok, value} -> value
      {:commit, value} -> value
      {:ignore, value} -> value
      _ -> fun.()
    end
  end

  @doc """
  Invalidate every locale variant of a single published record (`{type, slug}`).

  The precise alternative to `bust_published/0`: a publish or edit drops only the
  keys for the affected record instead of clearing the whole cache. All locales
  are busted because a request for a missing locale caches the default-locale
  fallback under the *requested* locale's key (same slug), so a single slug can
  live under several locale keys. Both cached shapes (bare record + HTML
  payload) are dropped.
  """
  @spec bust(Ash.UUID.t(), String.t(), String.t()) :: :ok
  def bust(org_id, type, slug) when is_binary(type) and is_binary(slug) do
    if enabled?() do
      for locale <- KilnCMS.I18n.locales(), shape <- @shapes do
        Cachex.del(@cache, key(shape, org_id, type, slug, locale))
      end
    end

    :ok
  end

  @doc """
  Cache key for a site's dynamic content-type registry (D17) descriptors.
  Per-org (epic #336): a `TypeDefinition` belongs to one site, so each org caches
  its own registry and one site's dynamic types never leak into another's.
  """
  def type_registry_key(org_id), do: "content_types:dynamic:#{org_id}"

  @doc """
  Drop a site's cached dynamic-type registry so a `TypeDefinition` write is
  visible on the next request instead of waiting out the TTL. Like the sitemap
  key, this aggregate isn't touched by per-record `bust/3`, so
  `Changes.BustTypeRegistry` calls it explicitly with the writing record's org.
  """
  @spec bust_type_registry(Ash.UUID.t()) :: :ok
  def bust_type_registry(org_id) do
    if enabled?(), do: Cachex.del(@cache, type_registry_key(org_id))
    :ok
  end

  @doc """
  Cache key for a site's resolved white-label branding tokens (#48). Per-org:
  each site caches its own `%KilnCMS.Branding{}`.
  """
  def branding_key(org_id), do: "branding:#{org_id}"

  @doc """
  Drop a site's cached branding so a settings save is visible on the next
  request instead of waiting out the TTL. Per-record `bust/3` doesn't touch this
  aggregate key, so `Changes.BustBranding` calls it explicitly.
  """
  @spec bust_branding(Ash.UUID.t()) :: :ok
  def bust_branding(org_id) do
    if enabled?(), do: Cachex.del(@cache, branding_key(org_id))
    :ok
  end

  @doc """
  Cache key for a site's generated sitemap XML (shared with the sitemap
  controller). Per-org (epic #336): each organization serves its own sitemap of
  its own published URLs.
  """
  def sitemap_key(org_id), do: "sitemap:#{org_id}:xml"

  @doc """
  Drop a site's cached sitemap XML so a new publish/unpublish is reflected on the
  next request rather than waiting out the sitemap's TTL. Per-record `bust/3`
  doesn't touch this key, so publish hooks call it explicitly.
  """
  @spec bust_sitemap(Ash.UUID.t()) :: :ok
  def bust_sitemap(org_id) do
    if enabled?(), do: Cachex.del(@cache, sitemap_key(org_id))
    :ok
  end

  @doc "Cache key for a site's generated `llms.txt` (shared with the llms controller)."
  def llms_key(org_id), do: "llms:#{org_id}:txt"

  @doc """
  Drop a site's cached `llms.txt` so a publish/unpublish is reflected on the next
  request rather than waiting out its TTL. Like the sitemap, this aggregate key
  isn't touched by per-record `bust/3`, so publish hooks call it explicitly.
  """
  @spec bust_llms(Ash.UUID.t()) :: :ok
  def bust_llms(org_id) do
    if enabled?(), do: Cachex.del(@cache, llms_key(org_id))
    :ok
  end

  @doc """
  Cache key for a generated feed (#486).

  `type` is the content-type name for a per-type feed (`/blog/feed.xml`) or
  `nil` for the site-wide one; `format` is `:atom` or `:json`. Per-org, like
  every other aggregate key here.
  """
  @spec feed_key(Ash.UUID.t(), String.t() | nil, :atom | :json) :: String.t()
  def feed_key(org_id, type, format), do: "feed:#{org_id}:#{type || "all"}:#{format}"

  @doc """
  Drop the feeds a write to `type` affects: that type's own, and the site-wide
  ones it appears in.

  Takes the type rather than enumerating every syndicated type, for the reason
  `bust/3` does: the caller knows which record changed, and a dynamic type's
  name is not derivable from an org id. A type that was *removed* from
  syndication leaves its own stale key behind, which the TTL reclaims — the
  site-wide feeds, which are the ones anyone is actually subscribed to, drop
  immediately.
  """
  @spec bust_feeds(Ash.UUID.t(), String.t() | atom() | nil) :: :ok
  def bust_feeds(org_id, type) do
    if enabled?() do
      for name <- Enum.uniq([nil, type && to_string(type)]),
          format <- [:atom, :json] do
        Cachex.del(@cache, feed_key(org_id, name, format))
      end
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

  @doc """
  Drop **every** delivery cache: this instance and the fired-artifact cache
  (`KilnCMS.Firing.Cache`). The operator-facing purge behind `mix
  kiln.cache.flush` and the admin button (#483).

  Both instances feed delivery, so clearing one and not the other leaves the
  site serving half-stale — the published-record lookups repopulate from the
  database while the fired bodies keep whatever they had. Nothing on a write
  path should call this: writes invalidate precisely, and a full flush means
  every subsequent request re-reads the database until the caches warm again.

  It exists for the states precise invalidation cannot reach — a config change,
  a template deploy, an external data source feeding a custom block — where the
  alternative was an IEx shell on production.

  Returns the number of entries dropped from each, for the operator to see that
  something happened. A disabled cache reports `0` rather than failing.
  """
  @spec flush_delivery() :: %{published: non_neg_integer(), artifacts: non_neg_integer()}
  def flush_delivery do
    %{published: clear_published(), artifacts: KilnCMS.Firing.Cache.clear()}
  end

  defp clear_published do
    with true <- enabled?(),
         {:ok, count} when is_integer(count) <- Cachex.clear(@cache) do
      count
    else
      _ -> 0
    end
  end

  # Fallback result for `Cachex.fetch`: cache non-nil values with a TTL; a nil
  # (not found) is ignored, never cached, so newly published content appears
  # immediately.
  defp commit(nil, _ttl), do: {:ignore, nil}
  defp commit(value, ttl), do: {:commit, value, expire: ttl}

  defp key(shape, org_id, type, slug, locale) when shape in @shapes,
    do: "published:#{shape}:#{org_id}:#{type}:#{locale}:#{slug}"

  defp enabled? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end
end
