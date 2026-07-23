import Config

# Acupuncture project overlay activation for KilnCMS.
#
# The core's `config/config.exs` imports `config/project.exs` (when present)
# as its very last step — after `#{config_env()}.exs` — so everything here
# overrides both the core defaults and the per-env config. A clean core
# checkout has no `config/project.exs` (the path is git-ignored), which is
# exactly what keeps this catalog dormant in the reusable core's own builds
# and CI.
#
# To activate the acupuncture catalog, copy this file into place:
#
#     cp projects/acupuncture/project.exs config/project.exs   # dev
#     COPY projects/acupuncture/project.exs config/project.exs # Dockerfile
#
# NOTE: `ash_domains` fully REPLACES the core list (Elixir config lists are
# replaced, not appended). When bumping the core, diff this list against the
# one in `config/config.exs` and re-sync (ours must be *core list + the
# acupuncture additions*).
config :kiln_cms,
  ash_domains: [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex,
    KilnCMS.Mail,
    KilnCMS.Newsletter,
    KilnCMS.Automation,
    Acupuncture.Catalog
  ],
  # Scanned by `KilnCMS.CMS.ContentTypes` for content types, and (via
  # `Application.compile_env/3`) by the GraphQL schema and JSON:API router —
  # registering the catalog here exposes conditions/team-members/testimonials/
  # faqs on every delivery surface with no core edits.
  content_domains: [KilnCMS.CMS, Acupuncture.Catalog]

# The migrated media library serves from Cloudflare Images, so the admin,
# preview and delivery CSPs must allow its host in `img-src` or every
# thumbnail renders blank. `CSP_IMG_SRC` (runtime.exs) overrides this.
config :kiln_cms, :csp_img_src, ["https://imagedelivery.net"]

# Register the plugin (D18 seams: `mix kiln.plugins.doctor`, nav, blocks).
# In test, the core's test.exs registers KilnCMS.FixturePlugin — this file is
# imported after it and replaces the list, so restate the fixture plugin too.
if config_env() == :test do
  config :kiln_cms, :plugins, [KilnCMS.FixturePlugin, Acupuncture.Plugin]
else
  config :kiln_cms, :plugins, [Acupuncture.Plugin]
end
