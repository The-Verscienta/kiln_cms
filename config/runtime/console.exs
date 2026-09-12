import Config

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# Extra origins allowed in the browser CSP's `img-src` (space-separated), for
# media libraries whose files serve from an external CDN — e.g.
# CSP_IMG_SRC="https://imagedelivery.net" for Cloudflare Images. Overrides any
# `:csp_img_src` default from a project overlay.
if csp_img_src = System.get_env("CSP_IMG_SRC") do
  config :kiln_cms, :csp_img_src, String.split(csp_img_src)
end

# Unsplash media-library integration — the Unsplash tab appears in the media
# library whenever an access key is configured.
if unsplash_key = System.get_env("UNSPLASH_ACCESS_KEY") do
  config :kiln_cms, :unsplash, access_key: unsplash_key
end

# Environment indicator (#469) — a strip across the top of the console naming
# this deployment. Read in EVERY environment, not just prod: a scrubbed staging
# clone is a byte-for-byte copy of production's content and branding, so the two
# consoles are visually identical, and a developer running against a copy of
# prod data wants the same warning.
#
# Absent means no strip, so **production stays clean by default** — it is the
# environment you recognise by the absence of a label, and the one where nothing
# has to be configured for that to be true. KILN_ENV_COLOR names a design-kit
# tone (see `KilnCMS.Environment`), never a hex.
#
# Guarded on the label being present, like CSP_IMG_SRC above: `Config`
# deep-merges keyword lists, so an unconditional `label: nil` would overwrite a
# project overlay's own `config :kiln_cms, :environment` — silently, and only in
# the deployment that had bothered to set one.
#
# Skipped in `:test` for the reason EMBED_ORIGINS is: this one injects markup
# into every rendered console page, so a developer with KILN_ENV_LABEL exported
# would get different HTML from CI on identical code.
if config_env() != :test do
  if env_label = System.get_env("KILN_ENV_LABEL") do
    config :kiln_cms, :environment,
      label: env_label,
      tone: System.get_env("KILN_ENV_COLOR")
  end
end
