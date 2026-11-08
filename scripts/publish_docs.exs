# Publish the user-facing guides in docs/ to a running Kiln site, as entries of
# a dynamic "Doc" content type (served at /docs/<slug>) plus a page that
# indexes them by section (slug `documentation`, served at /docs by its alias).
# kilncms.dev runs this from .github/workflows/publish-docs.yml on every push
# to main that touches docs.
#
#     elixir scripts/publish_docs.exs --all
#     elixir scripts/publish_docs.exs docs/deploy.md docs/seo.md
#     elixir scripts/publish_docs.exs --all --dry-run --out /tmp/docs-html
#
# Environment (not needed with --dry-run):
#
#     KILN_URL            site origin, e.g. https://kilncms.dev
#     KILN_DOCS_API_KEY   a :read_write API key on an ADMIN account — publishing
#                         is admin-only (docs/json-api.md → "Writing")
#     KILN_DOCS_TYPE      the Doc type's machine name (default "doc"); its id is
#                         looked up via /api/json/type-definitions/by-name/:name
#     KILN_DOCS_TYPE_ID   optional: that id, skipping the lookup
#
# Which files are published, their titles and their sections all come from
# `extras/0` and `groups_for_extras/0` in mix.exs — the curation ExDoc already
# uses. scripts/publish/docs.exs classifies every group as public
# (@public_groups, the index's sections), contributing (@contributing_group,
# published last on the index, after a rule) or internal (@internal_groups,
# never published). Adding a guide to a public or contributing group in mix.exs
# is what publishes it; a new group must be placed in one of the three, or the
# run raises before publishing anything. The role tracks at the top of /docs
# are inlined from docs/reading-paths.md.
#
# A standalone script rather than a mix task on purpose: CI publishes without
# compiling the application, so nothing here may reach a `KilnCMS.*` module.
# The server treats the HTML it sends as untrusted — the rich-text cast
# sanitizes it like any other API write.
#
# Renamed or deleted guides are not unpublished; do that in the editor.
#
# The logic is in scripts/publish/docs.exs (loadable by the tests), the
# Markdown renderer and the JSON:API client in scripts/publish/common.exs
# (shared with scripts/publish_releases.exs).

# The PARSER only, matching mix.exs. Not `earmark`: that package is retired on
# Hex and carries a stored-XSS advisory in its HTML renderer, so nothing in
# this repo may install it. Its `Earmark.Transform` is replaced by the renderer
# in scripts/publish/common.exs — a port of `KilnCMS.Markdown`'s, which this
# script cannot call for the reason above.
Mix.install([
  {:earmark_parser, "~> 1.4"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("publish/docs.exs", __DIR__)

PublishDocs.main(System.argv())
