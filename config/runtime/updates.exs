import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Presentation console (#355) — where the external front end serves content
#
# The Kiln-hosted side-by-side editing console iframes the external front end.
# Kiln doesn't render that front end, so point it here — a URL template with
# `{path}`/`{type}`/`{slug}`/`{locale}` placeholders (a bare base URL gets
# `{path}` appended). Unset ⇒ the console shows a setup hint. The origin is
# derived from this for `postMessage` validation. See `KilnCMSWeb.Presentation`.
if preview_url = System.get_env("PRESENTATION_PREVIEW_URL") do
  config :kiln_cms, :presentation_preview_url, preview_url
end

# ## Upstream update check
#
# The admin update page asks GitHub whether a newer Kiln release exists. The
# request carries a bare `KilnCMS` user-agent with no version and no instance
# identifier, so it discloses nothing about this deployment beyond its IP. It
# is made only when an admin opens the page, and results are cached (24h for a
# comparison, 15 minutes for a failure), so an outage cannot turn page loads
# into a request stream.
#
# This is the only outbound integration that is on by default — the others all
# need a credential, so leaving it unset implicitly disables them. Set
# KILN_UPDATE_CHECK=false for an instance that must make no third-party
# requests at all; the page then reports the running version and the update
# command without the comparison. See `Kiln.Updates`.
#
# Accepted spellings are the shared ones (see the header): an operator who set
# this because they need *no* egress must not be defeated by `Off` or `FALSE`.
#
# An explicit on-spelling now writes `enabled: true` as well, where this used to
# write only on the off path. That is deliberate — it lets an operator re-enable
# the check against a build whose compiled config turned it off (`config/e2e.exs`
# does exactly that) without a rebuild.
with {:ok, enabled?} <- Env.fetch("KILN_UPDATE_CHECK") do
  config :kiln_cms, Kiln.Updates, enabled: enabled?
end

# Where this project keeps its pinned Kiln checkout, relative to the project
# repo root — `kiln/upstream`, `upstream`, whatever the layout uses. Purely
# cosmetic: the admin page prefixes the update command with a matching `cd`.
#
# Unset by default rather than guessed. The pin is a submodule *or* a fetched
# ref at a path the project chooses (see projects/README.md), so a default
# would be a wrong, copy-pasteable `cd` baked into the image for everyone on a
# different layout. Left unset, the page just says to run it from the Kiln
# checkout.
pin_path = "KILN_PIN_PATH" |> System.get_env("") |> String.trim()

if pin_path != "" do
  config :kiln_cms, Kiln.Updates, pin_path: pin_path
end

# Which repo this build compares itself against. `The-Verscienta/kiln_cms` is
# the default because an unmodified install genuinely is that repo — but a fork
# that keeps the default is told about someone else's releases, and the failure
# is silent in the dangerous direction: a fork *ahead* of upstream compares as
# newer, so the page reports "Up to date" forever and the fork's own security
# releases never surface.
#
# KILN_UPDATE_RELEASES_URL additionally repoints the API endpoint, for GitHub
# Enterprise or an internal mirror — installs that can't reach api.github.com
# at all and would otherwise be stuck in a permanent error state. It overrides
# the endpoint only, so set KILN_UPDATE_REPO alongside it. See `Kiln.Updates`.
update_repo = "KILN_UPDATE_REPO" |> System.get_env("") |> String.trim()

if update_repo != "" do
  config :kiln_cms, Kiln.Updates, repo: update_repo
end

releases_url = "KILN_UPDATE_RELEASES_URL" |> System.get_env("") |> String.trim()

if releases_url != "" do
  config :kiln_cms, Kiln.Updates, releases_url: releases_url
end
