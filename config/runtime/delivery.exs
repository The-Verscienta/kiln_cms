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
