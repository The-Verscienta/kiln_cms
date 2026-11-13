import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Reading time (#492) — words per minute for `reading_time_minutes`
#
# 230 is the usual mid-range figure for adult silent reading of English prose.
# An unparseable or non-positive value keeps the default and warns rather than
# being interpreted — see KilnCMS.CMS.Calculations.ReadingTime. A release only
# evaluates this file, so without this block the documented config key would be
# unreachable on a Docker deployment.
with {:ok, wpm} <- Env.positive_integer("KILN_READING_TIME_WPM") do
  config :kiln_cms, :reading_time_wpm, wpm
end

# ## Visual-editing bridge (#355) — the annotated preview read + `/bridge.js`
#
# Enabled by default. Set VISUAL_EDITING_ENABLED=false to switch the whole
# surface off (the annotated `/api/visual-editing/...` route 404s). Which origins
# may fetch it cross-origin and round-trip writes is governed by CORS_ORIGINS
# (the annotated read and the write API both live under `/api`); draft visibility
# is governed by the caller's API key. See KilnCMS.VisualEditing.
#
# Only a recognized spelling writes config, so an unset var keeps the compiled
# default (or a project overlay's). See the header for the spellings.
with {:ok, enabled?} <- Env.fetch("VISUAL_EDITING_ENABLED") do
  config :kiln_cms, :visual_editing_enabled, enabled?
end

# ## The console/delivery origin split (#740)
#
# KILN_CONSOLE_HOST=console.example.com serves the editor console ONLY on
# console hosts and never serves tenant content there, so script on a tenant's
# public site is cross-origin to every console. The bare host is the DEFAULT
# org's console; <slug>.console.example.com is each other org's (#1688), so
# DNS and TLS need the host and its wildcard. Keep it under PHX_HOST, or
# passkeys cannot work there. Unset (the default), console and site share an
# origin as before. See docs/multi-tenancy.md and docs/decisions/0011-*.
if console_host = System.get_env("KILN_CONSOLE_HOST") do
  config :kiln_cms, :console_host, console_host
end

# ## Anonymous API caching (KilnCMSWeb.Plugs.PublicCache)
#
# Anonymous reads of JSON:API, GraphQL GET and /api/search go out as
# `public, max-age=60, stale-while-revalidate=60` with a body ETag. Set
# KILN_API_CACHE=false to keep them at Plug's `private` default; credentialed
# requests are `private, no-store` either way. Only a recognized spelling or a
# positive integer writes config, so an unset var keeps the compiled default.
with {:ok, api_cache?} <- Env.fetch("KILN_API_CACHE") do
  config :kiln_cms, KilnCMSWeb.Plugs.PublicCache, enabled: api_cache?
end

with {:ok, max_age} <- Env.positive_integer("KILN_API_CACHE_MAX_AGE") do
  config :kiln_cms, KilnCMSWeb.Plugs.PublicCache, max_age: max_age
end

with {:ok, swr} <- Env.positive_integer("KILN_API_CACHE_SWR") do
  config :kiln_cms, KilnCMSWeb.Plugs.PublicCache, stale_while_revalidate: swr
end

# ## CDN purge on publish (KilnCMS.CDN)
#
# Unset, cached API responses age out on their max-age. Set, every publish,
# unpublish or live edit POSTs the site's surrogate key to this URL (Cloudflare
# purge-by-tag body, Fastly `Surrogate-Key` header). The token stays a provider
# tuple so it resolves through `KilnCMS.Keys` at call time, like the governance
# witness token.
purge_url = "KILN_CDN_PURGE_URL" |> System.get_env("") |> String.trim()

if purge_url != "" do
  config :kiln_cms, KilnCMS.CDN,
    purge_url: purge_url,
    purge_token:
      if(System.get_env("KILN_CDN_PURGE_TOKEN"),
        do: {:env, %{"var" => "KILN_CDN_PURGE_TOKEN"}}
      ),
    purge_token_header: System.get_env("KILN_CDN_PURGE_TOKEN_HEADER", "authorization")
end

# ## Reject unverifiable bearer tokens (KilnCMSWeb.Plugs.ApiKeyAuth, #2161)
#
# On by default: a JWT that fails verification is answered 401 instead of being
# served anonymously. KILN_API_REJECT_INVALID_BEARER=false restores the anonymous
# fallback; that escape hatch is removed in the release after this one (ADR 0012).
# Unset writes no config, so the plug's default (on) applies.
with {:ok, reject?} <- Env.fetch("KILN_API_REJECT_INVALID_BEARER") do
  config :kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth, reject_invalid_bearer: reject?
end

# ## Smart 404 blocking (KilnCMS.Security.ScannerGuard, #2253)
#
# Off by default. KILN_SCANNER_BLOCKING=1 temporarily blocks an address that
# racks up delivery 404s (THRESHOLD per WINDOW_MINUTES) or probes bait paths
# (BAIT_THRESHOLD per window), for BLOCK_MINUTES. Only a recognized spelling or
# an in-range integer writes config, so an unset var keeps the default; a bad
# value warns and is ignored rather than being interpreted.
with {:ok, enabled?} <- Env.fetch("KILN_SCANNER_BLOCKING") do
  config :kiln_cms, :scanner_blocking, enabled: enabled?
end

with {:ok, threshold} <- Env.integer_in("KILN_SCANNER_BLOCKING_THRESHOLD", 5, 100_000) do
  config :kiln_cms, :scanner_blocking, threshold: threshold
end

with {:ok, threshold} <- Env.integer_in("KILN_SCANNER_BLOCKING_BAIT_THRESHOLD", 1, 1_000) do
  config :kiln_cms, :scanner_blocking, bait_threshold: threshold
end

with {:ok, minutes} <- Env.integer_in("KILN_SCANNER_BLOCKING_WINDOW_MINUTES", 1, 1_440) do
  config :kiln_cms, :scanner_blocking, window_ms: :timer.minutes(minutes)
end

with {:ok, minutes} <- Env.integer_in("KILN_SCANNER_BLOCKING_BLOCK_MINUTES", 1, 10_080) do
  config :kiln_cms, :scanner_blocking, block_ms: :timer.minutes(minutes)
end

# ## Per-class delivery ceilings by user agent (#2243, KilnCMS.BotBudgets)
#
# Each is a percentage of the `:delivery` limit (the browser ceiling), 1-1000,
# for search engines, AI crawlers, declared bots and clients with no user
# agent. Unset keeps the built-in default (200 for verified search engines,
# 100, 50, 20); a bad value keeps it too, and warns. A site may lower a class
# below these from /editor/bot-budgets, never raise it above. See
# docs/bot-budgets.md.
#
# Skipped under :test, like the gates in feature_gates.exs: the suite's limits
# are pinned by `KilnCMS.RateLimitHelpers.assert_test_limits!/0` against the
# compiled config, so a value exported in a developer's shell must not reach it.
if config_env() != :test do
  bot_budgets =
    for {class, var} <- [
          search_engine: "KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT",
          ai_crawler: "KILN_BOT_BUDGET_AI_CRAWLER_PERCENT",
          declared_bot: "KILN_BOT_BUDGET_DECLARED_BOT_PERCENT",
          empty: "KILN_BOT_BUDGET_EMPTY_UA_PERCENT"
        ],
        {:ok, percent} <- [Env.integer_in(var, 1, 1000)],
        into: %{},
        do: {class, percent}

  if bot_budgets != %{} do
    config :kiln_cms, KilnCMSWeb.RateLimit, delivery_classes: bot_budgets
  end

  # ## Verified search engines (#2254, KilnCMS.CrawlerVerification)
  #
  # A request whose user agent names a search engine keeps that class's
  # ceiling only until a reverse-DNS check proves the claim false. On by
  # default; `false` turns the check off (every claim is believed, the #2243
  # behavior) for a node that cannot reach a DNS resolver. Skipped under
  # :test like the rest of this block: config/test.exs pins it to a stub.
  with {:ok, enabled?} <- Env.fetch("KILN_CRAWLER_VERIFICATION") do
    config :kiln_cms, KilnCMS.CrawlerVerification, enabled: enabled?
  end

  # ## Published crawler IP ranges (#2586, KilnCMS.CrawlerVerification.Ranges)
  #
  # Google's, Bing's, Apple's and DuckDuckGo's own lists of their crawlers'
  # addresses, fetched every 6 hours by one node: an address inside a fresh
  # list is verified with no DNS lookup, and a DuckDuckBot claim from outside
  # DuckDuckGo's is proven false. On by default; this is an outbound HTTPS
  # request to each vendor, and `false` turns it off (no request is made and
  # claims fall back to DNS). Off by implication when
  # KILN_CRAWLER_VERIFICATION is false.
  with {:ok, enabled?} <- Env.fetch("KILN_CRAWLER_RANGES") do
    config :kiln_cms, KilnCMS.CrawlerVerification.Ranges, enabled: enabled?
  end
end
