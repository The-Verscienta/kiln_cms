# Publish Kiln's security page to a running Kiln site: the disclosure policy
# at /security, and one entry of a dynamic "security_notice" content type per
# published GitHub security advisory (served at /security-notices/<ghsa-id>,
# and as a feed at /security-notices/feed.xml). kilncms.dev runs this from
# .github/workflows/publish-security.yml (#1873).
#
#     elixir scripts/publish_security.exs
#     elixir scripts/publish_security.exs --dry-run --out /tmp/security
#     elixir scripts/publish_security.exs --advisories advisories.json --dry-run
#
# Environment (not needed with --dry-run):
#
#     KILN_URL               site origin, e.g. https://kilncms.dev
#     KILN_SECURITY_API_KEY  a :read_write API key on an ADMIN account —
#                            publishing is admin-only (docs/json-api.md →
#                            "Writing"). The workflow passes the docs key.
#     KILN_SECURITY_TYPE     the type's machine name (default
#                            "security_notice"), looked up via
#                            /api/json/type-definitions/by-name/:name
#     GITHUB_TOKEN           optional: lifts the anonymous GitHub API rate
#                            limit. Published advisories need no token.
#
# `--advisories FILE` reads the advisories from a file holding what
# `GET /repos/:repo/security-advisories` returns, instead of asking GitHub.
#
# ## What is published
#
#   - The page `security` (/security): .github/SECURITY.md — the reporting
#     process, the supported versions, the scope — with its relative links
#     pointed at GitHub, followed by the list of notices and the feed's URL.
#     Its whole body is rebuilt on every run, so edit SECURITY.md, not the
#     page.
#   - One entry per published advisory, slug = its GHSA id in lowercase. The
#     body is the advisory's description; the custom fields are the
#     machine-readable part:
#       package            "kiln_cms" — a plugin's notice (#1447) uses the
#                          plugin's Hex name, so core and plugins share the
#                          type and the feed
#       affected_versions  GitHub's vulnerable range, as written
#       patched_versions   GitHub's patched versions, as written
#       severity           low | medium | high | critical | unknown
#       advisory_id        GHSA-xxxx-xxxx-xxxx
#       cve_id             CVE-YYYY-NNNNN, absent until one is assigned
#       published_on       YYYY-MM-DD
#       advisory_url       the GitHub advisory
#
# A withdrawn advisory is not published, and notices are never unpublished
# from here: withdraw one in the editor.
#
# ## The site's setup (one-time, by an admin)
#
# In /editor/types, create a type named `security_notice` with path segment
# `security-notices`, tick "Published feed", and give it these custom fields
# (machine name — field type):
#
#     package            — string
#     affected_versions  — string
#     patched_versions   — string
#     severity           — string
#     advisory_id        — string
#     cve_id             — string
#     published_on       — date
#     advisory_url       — url
#
# The script checks the type and every field before writing anything, and
# fails naming what is missing. Then, in /editor/security-txt, set the site's
# security.txt `Policy` to https://kilncms.dev/security.
#
# A standalone script rather than a mix task on purpose: CI publishes without
# compiling the application, so nothing here may reach a `KilnCMS.*` module.
# The server treats the HTML it sends as untrusted — the rich-text cast
# sanitizes it like any other API write. The logic is in
# scripts/publish/security.exs (loadable by the tests), the Markdown renderer
# and API client in scripts/publish/common.exs.

# The PARSER only, matching mix.exs. Not `earmark`: that package is retired on
# Hex and carries a stored-XSS advisory in its HTML renderer, so nothing in
# this repo may install it.
Mix.install([
  {:earmark_parser, "~> 1.4"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("publish/security.exs", __DIR__)

PublishSecurity.main(System.argv())
