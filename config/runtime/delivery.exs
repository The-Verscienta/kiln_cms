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
# KILN_CONSOLE_HOST=console.example.com serves the editor console ONLY on that
# host and never serves tenant content there, so any script that runs on a
# tenant's public site is cross-origin to the console (its cookies are not
# attached, its DOM is not reachable). Unset (the default), console and site
# share an origin as before. Add the console host to CHECK_ORIGINS. Org
# resolution is still host-derived, so the console host is the DEFAULT org's
# console — right for a single-org deployment; see docs/multi-tenancy.md.
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
