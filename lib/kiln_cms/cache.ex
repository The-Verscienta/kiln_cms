defmodule KilnCMS.Cache do
  @moduledoc """
  In-BEAM cache (Cachex) for the public content-delivery hot path.

  Published content fetched by slug is cached per `{type, slug}` so repeated
  requests for the same page skip the database. Entries carry a safety-net TTL
  and are invalidated precisely on any write that affects published content (see
  `KilnCMS.CMS.Changes.BustContentCache`).

  In keeping with the project's minimal-ops goal this is in-process only (no
  Redis/Dragonfly); a shared multi-node cache is deferred until measured (D2).
  Two keys are the exception to what that costs on a cluster —
  `bust_code_injection/1` and `bust_branding/1` invalidate on every node via
  `KilnCMS.Cache.ClusterBust`, because an operator deleting an executing script
  should not have to wait out a TTL on the nodes they did not happen to hit
  (#739).

  Set `config :kiln_cms, KilnCMS.Cache, enabled: false` to bypass the cache
  (every read hits the source) without removing the supervised process.
  """
  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.Cache.ClusterBust

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
    if enabled?() do
      Cachex.del(@cache, type_registry_key(org_id))
      Cachex.del(@cache, calendar_types_key(org_id))
      Cachex.del(@cache, delivery_schema_key(org_id))
    end

    :ok
  end

  @doc """
  Cache key for a site's exported delivery JSON Schema (#430).

  Busted from `bust_type_registry/1` rather than on its own, because the schema
  is derived from exactly what that function already invalidates: the dynamic
  type registry and the custom-field definitions. `Changes.BustTypeRegistry`
  fires on every `TypeDefinition` **and** `FieldDefinition` write, so the
  invalidation is exact and costs nothing extra.
  """
  @spec delivery_schema_key(Ash.UUID.t()) :: String.t()
  def delivery_schema_key(org_id), do: "delivery_schema:#{org_id}"

  @doc """
  Cache key for which of a site's content types are event-shaped (#480).

  Its own key rather than a slice of the type registry, because the answer
  depends on `FieldDefinition` rows and not on `TypeDefinition` ones — a
  `datetime_range` field being added is what changes it. Both writes bust it
  (`Changes.BustTypeRegistry` runs on each), so the TTL is a backstop rather
  than the mechanism.
  """
  @spec calendar_types_key(Ash.UUID.t()) :: String.t()
  def calendar_types_key(org_id), do: "content_types:calendar:#{org_id}"

  @doc """
  Cache key for a site's resolved white-label branding tokens (#48). Per-org:
  each site caches its own `%KilnCMS.Branding{}`.
  """
  def branding_key(org_id), do: "branding:#{org_id}"

  @doc """
  Drop a site's cached branding so a settings save is visible on the next
  request instead of waiting out the TTL. Per-record `bust/3` doesn't touch this
  aggregate key, so `Changes.BustBranding` calls it explicitly.

  Cluster-wide (#739), for the reason `bust_code_injection/1` gives: these two
  keys hold the same shape of thing, and there is no reason for one of them to
  reach every node and the other not to.
  """
  @spec bust_branding(Ash.UUID.t()) :: :ok
  def bust_branding(org_id) do
    if enabled?(), do: ClusterBust.broadcast([branding_key(org_id)])
    :ok
  end

  @doc """
  Cache key for a site's resolved code injection (#490) — the snippet **and**
  the CSP sources that let it run, which is why the two are one cached struct.
  """
  def code_injection_key(org_id), do: "code_injection:#{org_id}"

  @doc """
  Drop a site's cached code injection after a settings save.

  Staler than branding would be: the struct carries the CSP sources as well as
  the HTML, so a stale entry serves the NEW snippet under the OLD policy — a
  blocked script and a console error rather than a visibly out-of-date page.

  Cluster-wide (#739). The documented incident response for a bad snippet is
  "delete the row", and a node-local `Cachex.del` left every *other* node
  serving that script — under its widened CSP — until the TTL expired.
  """
  @spec bust_code_injection(Ash.UUID.t()) :: :ok
  def bust_code_injection(org_id) do
    if enabled?(), do: ClusterBust.broadcast([code_injection_key(org_id)])
    :ok
  end

  @doc """
  Cache key for a site's generated sitemap XML (shared with the sitemap
  controller). Per-org (epic #336): each organization serves its own sitemap of
  its own published URLs.
  """
  def sitemap_key(org_id), do: "sitemap:#{org_id}:xml"

  @doc """
  Cache key for a site's running content experiments (#499).

  On the delivery hot path for **every** page: a site with no experiments must
  not pay a query per request to find that out. Held as one entry per site
  rather than one per document, because the set is small by construction — an
  experiment costs its page the shared cache, so nobody runs many at once.
  """
  @spec experiments_key(Ash.UUID.t()) :: String.t()
  def experiments_key(org_id), do: "experiments:running:#{org_id}"

  @doc """
  Cache key for a site's funnel targets — each funnel's final step (#1010).

  Separate from `experiments_key/1` because the two are invalidated by different
  writes: a funnel edit must move a `:funnel_completion` goal without touching
  the experiment, which is the whole point of naming a funnel rather than a
  document.
  """
  @spec funnel_targets_key(Ash.UUID.t()) :: String.t()
  def funnel_targets_key(org_id), do: "experiments:funnel_targets:#{org_id}"

  @doc "Drop a site's cached funnel targets. Called from every funnel/step write."
  @spec bust_funnel_targets(Ash.UUID.t()) :: :ok
  def bust_funnel_targets(org_id) do
    if enabled?(), do: Cachex.del(@cache, funnel_targets_key(org_id))
    :ok
  end

  @doc "Cache key for a site's configured social accounts (#497)."
  @spec social_accounts_key(Ash.UUID.t()) :: String.t()
  def social_accounts_key(org_id), do: "social:accounts:#{org_id}"

  @doc """
  Drop a site's cached social-account set.

  Called from every account write, for the same reason experiments bust on
  every write: an admin who enables an account expects the next publish to
  announce, not the one after the TTL expires.
  """
  @spec bust_social_accounts(Ash.UUID.t()) :: :ok
  def bust_social_accounts(org_id) do
    if enabled?(), do: Cachex.del(@cache, social_accounts_key(org_id))
    :ok
  end

  @doc """
  Drop a site's cached running-experiment set.

  Called from every experiment and variant write. The TTL is a backstop, not the
  freshness signal — an editor who starts an experiment expects it live on the
  next request, not within five minutes.
  """
  @spec bust_experiments(Ash.UUID.t()) :: :ok
  def bust_experiments(org_id) do
    if enabled?(), do: Cachex.del(@cache, experiments_key(org_id))
    :ok
  end

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
  `nil` for the site-wide one; `format` is `:atom`, `:json` or `:ics`. Per-org,
  like every other aggregate key here.

  The calendar routes (#480) narrow `type` further — `"gigs/tag/jazz"` for a
  tag-scoped calendar — and the segment feeds (#720) do the same:
  `"post/category/news"`, `"post/tag/jazz"`, `"post/locale/fr"`.

  `bust_feeds/3` does not enumerate the **taxonomy** ones, and that is not an
  omission: computing which of them a record belongs to needs that record's tags
  and category, and the bust runs in an `after_action` — a relationship load
  there is a database read inside the publish transaction, which can abort it and
  lose the publish outright (#660). So it drops the keys anyone is actually
  subscribed to, immediately, and lets the five-minute TTL reclaim the segments.

  The **locale** is not in that bargain, and treating it as though it were was a
  bug: `record.locale` is a plain attribute already on the struct the bust
  receives, so it costs no read, no query and no transaction risk. Without it a
  French publish never invalidated `/fr/feed.xml` — leaving the one reader the
  locale feeds exist for as the only one whose feed went stale.
  """
  @spec feed_key(Ash.UUID.t(), String.t() | nil, :atom | :json | :ics) :: String.t()
  def feed_key(org_id, type, format), do: "feed:#{org_id}:#{type || "all"}:#{format}"

  @doc """
  Drop the feeds a write to `type` affects: that type's own, the site-wide ones
  it appears in, and — when `locale` is given — the same two for that locale.

  Takes the type rather than enumerating every syndicated type, for the reason
  `bust/3` does: the caller knows which record changed, and a dynamic type's
  name is not derivable from an org id. A type that was *removed* from
  syndication leaves its own stale key behind, which the TTL reclaims — the
  site-wide feeds, which are the ones anyone is actually subscribed to, drop
  immediately.

  `locale` is the written record's own, and defaults to `nil` for a caller that
  has no locale axis (the calendars). Passing the default locale is harmless: its
  feeds are keyed without a locale segment, so the two spellings collapse.
  """
  @spec bust_feeds(Ash.UUID.t(), String.t() | atom() | nil, String.t() | nil) :: :ok
  def bust_feeds(org_id, type, locale \\ nil) do
    if enabled?() do
      for name <- feed_names(type, locale),
          # `:ics` rides along (#480): a published event must appear in a
          # subscribed calendar on the same hook that refreshes the feeds.
          format <- [:atom, :json, :ics] do
        Cachex.del(@cache, feed_key(org_id, name, format))
      end
    end

    :ok
  end

  @doc """
  Drop **every** cached feed document for one org, across types, scopes and
  formats (#719).

  The blunt counterpart to `bust_feeds/3`, for a write that names no record and
  no type: a change to the org's syndication policy decides what is *in* every
  feed body at once. It walks the keyspace rather than enumerating types,
  because the set of types a stale key was written for is exactly what the
  policy change may have altered — and the taxonomy scopes `bust_feeds/3`
  deliberately leaves to the TTL are in here too, since this runs on a rare
  admin save rather than inside a publish transaction.
  """
  @spec bust_all_feeds(Ash.UUID.t()) :: :ok
  def bust_all_feeds(org_id) do
    prefix = "feed:#{org_id}:"

    with true <- enabled?(),
         {:ok, keys} <- Cachex.keys(@cache) do
      for key <- keys, is_binary(key), String.starts_with?(key, prefix) do
        Cachex.del(@cache, key)
      end
    end

    :ok
  end

  @doc """
  Cache key for a site's resolved feed syndication policy (#719) — which types
  syndicate and which carry their full body, with the operator-level
  `config :kiln_cms, :feeds` already folded in. Per-org: the whole point of the
  key is that two tenants on one deployment resolve it differently.
  """
  @spec feed_policy_key(Ash.UUID.t()) :: String.t()
  def feed_policy_key(org_id), do: "feed_policy:#{org_id}"

  @doc """
  Drop a site's cached syndication policy after a settings save. Called by
  `Changes.BustFeedSettings`, alongside `bust_all_feeds/1` — the policy decides
  the contents of the documents, so leaving those cached would hide the save for
  the whole TTL.
  """
  @spec bust_feed_policy(Ash.UUID.t()) :: :ok
  def bust_feed_policy(org_id) do
    if enabled?(), do: Cachex.del(@cache, feed_policy_key(org_id))
    :ok
  end

  # `nil` (site-wide) and the type, each in the default locale and — when the
  # record was written in another — that locale too. The segment mirrors
  # `KilnCMSWeb.FeedController.cache_scope/2` exactly; the two have to agree or
  # this drops keys nothing reads.
  defp feed_names(type, locale) do
    scopes = Enum.uniq([nil, type && to_string(type)])

    scopes ++ Enum.reject(Enum.map(scopes, &localized(&1, locale)), &is_nil/1)
  end

  # `nil` for the default locale, or for a caller with no locale axis at all —
  # those feeds are keyed without a locale segment, so the two spellings are one
  # key and the `Enum.uniq` above collapses them.
  defp localized(scope, locale) when is_binary(locale) do
    if locale == KilnCMS.I18n.default_locale() do
      nil
    else
      segment = "locale/" <> URI.encode(locale, &URI.char_unreserved?/1)
      if scope, do: "#{scope}/#{segment}", else: segment
    end
  end

  defp localized(_scope, _locale), do: nil

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
