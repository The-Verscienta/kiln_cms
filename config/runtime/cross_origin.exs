import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Cross-origin (CORS) for the headless API surfaces
#
# Set CORS_ORIGINS to allow browser clients from other origins to read
# `/api/*` and `/gql` (comma-separated allowlist, or `*` to echo any origin).
# Only overrides the per-env default when the var is present, so dev keeps its
# permissive default and prod stays same-origin-only (`[]`) unless configured.
# See KilnCMSWeb.CORS.
if cors_origins = System.get_env("CORS_ORIGINS") do
  config :kiln_cms, :cors_origins, KilnCMSWeb.CORS.parse_env(cors_origins)
end

# ## Embeddable forms — which parents may iframe `/forms/:slug/embed`
#
# Defaults to same-origin only (#562): cross-site embedding is OFF until you set
# EMBED_ORIGINS to your allowlist, e.g. `https://acme.com,https://blog.acme.com`.
# `*` re-opens it to any site — the old default, and a clickjacking surface,
# since form submission is deliberately CSRF-free. See KilnCMSWeb.Embed. Skipped
# in test so the suite never depends on what is exported in a developer's shell.
if config_env() != :test do
  if embed_origins = System.get_env("EMBED_ORIGINS") do
    config :kiln_cms, :embed_origins, KilnCMSWeb.Embed.parse_env(embed_origins)
  end

  # EMBED_ORIGINS_LOCKED=true makes EMBED_ORIGINS a *ceiling* as well as the
  # default (#1133): an org admin's per-form or per-site allowlist (#648, #1131)
  # may narrow it but not reach outside it — writes are refused and the served
  # frame-ancestors is clamped. Off by default, so nothing changes for a
  # deployment that never sets it. See KilnCMS.Forms.EmbedCeiling.
  config :kiln_cms, :embed_origins_locked, Env.flag("EMBED_ORIGINS_LOCKED", false)
end
