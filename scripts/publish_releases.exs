# Publish Kiln's release notes to a running Kiln site, as entries of a dynamic
# "release" content type (served at /releases/<slug>) plus a page that lists
# them (slug `release-notes`, served at /releases by its alias). kilncms.dev
# runs this from .github/workflows/publish-releases.yml when a GitHub release
# is published (#1870).
#
#     elixir scripts/publish_releases.exs --version v1.0.0
#     elixir scripts/publish_releases.exs --all                 # backfill
#     elixir scripts/publish_releases.exs --version v1.1.0-rc.1 --prerelease
#     elixir scripts/publish_releases.exs --all --dry-run --out /tmp/releases
#
# Environment (not needed with --dry-run):
#
#     KILN_URL               site origin, e.g. https://kilncms.dev
#     KILN_RELEASES_API_KEY  a :read_write API key on an ADMIN account —
#                            publishing is admin-only (docs/json-api.md →
#                            "Writing"). The workflow passes the docs key.
#     KILN_RELEASES_TYPE     the type's machine name (default "release"); its id,
#                            path segment and fields are looked up via
#                            /api/json/type-definitions/by-name/:name
#
# ## What one release becomes
#
# An entry with slug `v1-0-0` (a slug is lowercase letters, digits and single
# hyphens, so the tag's dots become hyphens; `v1.1.0-rc.1` → `v1-1-0-rc-1`):
#
#   - title          "KilnCMS 1.0.0"
#   - body           docs/changelog/v1.0.0.md, the long-form notes, as one
#                    rich_text block — its H1 and the stock "the long-form
#                    entries behind…" paragraph dropped, relative links pointed
#                    at GitHub at the release's own tag
#   - custom_fields  (the machine-readable part, read back by the #1877 feed)
#       version      "1.0.0"       semver, no leading `v`
#       released_on  "2026-10-02"  ISO-8601 date — the `## [1.0.0] - <date>`
#                                  heading in CHANGELOG.md, else the tag's
#                                  commit date, else --date
#       release_url  "https://github.com/The-Verscienta/kiln_cms/releases/tag/v1.0.0"
#       highlights   the bold lead of each CHANGELOG.md summary line under
#                    Upgrade notes, Breaking and Added — one per line, plain
#                    text, at most 4000 characters (whole lines)
#
# `--dry-run --out DIR` writes each entry's HTML and its attributes as JSON,
# so the shape can be checked without a site.
#
# ## The site's `release` type (one-time setup, by an admin)
#
# In /editor/types, create a type named `release` with path segment
# `releases` and these custom fields (machine name — field type):
#
#     version      — string
#     released_on  — date
#     release_url  — url
#     highlights   — text
#
# The script checks the type and every field before writing anything, and
# fails naming what is missing. Create no page with slug `releases`: the
# index is the page `release-notes`, whose `path_alias` is `/releases`.
#
# ## Pre-releases
#
# A release candidate is not published: `--version v1.1.0-rc.1` exits 0 and
# says so unless `--prerelease` is passed. A candidate has no notes file of
# its own, so it publishes docs/changelog/unreleased.md and CHANGELOG.md's
# [Unreleased] section. The index lists final releases only.
#
# A standalone script rather than a mix task on purpose: CI publishes without
# compiling the application, so nothing here may reach a `KilnCMS.*` module.
# The server treats the HTML it sends as untrusted — the rich-text cast
# sanitizes it like any other API write. The logic is in
# scripts/publish/releases.exs (loadable by the tests), the Markdown renderer
# and API client in scripts/publish/common.exs (shared with publish_docs.exs).
#
# Releases are never unpublished from here; do that in the editor.

# The PARSER only, matching mix.exs. Not `earmark`: that package is retired on
# Hex and carries a stored-XSS advisory in its HTML renderer, so nothing in
# this repo may install it.
Mix.install([
  {:earmark_parser, "~> 1.4"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("publish/releases.exs", __DIR__)

PublishReleases.main(System.argv())
