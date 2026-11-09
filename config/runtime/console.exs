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

# Breached-password check (#2240) — passwords are looked up against the Have I
# Been Pwned range API by k-anonymity (`KilnCMS.Accounts.BreachedPassword`).
#
# BREACHED_PASSWORD_CHECK=false is the air-gapped kill switch: no outbound call
# is ever made, whatever any site's setting says. Only an explicit "off" writes
# anything, so an unset or unreadable value leaves the check on, and — unlike
# `Env.flag/2` with a `true` default — the suite's own `enabled: false` is never
# overridden by an exported variable.
if KilnCMS.Config.Env.fetch("BREACHED_PASSWORD_CHECK") == {:ok, false} do
  config :kiln_cms, KilnCMS.Accounts.BreachedPassword, enabled: false
end

# BREACHED_PASSWORD_POLICY — the operator default (off | warn | block) that a
# site's own setting (/editor/password-policy) overrides. Skipped in :test so an
# exported value cannot change what the suite asserts.
if config_env() != :test do
  with {:ok, policy} <- KilnCMS.Config.Env.one_of("BREACHED_PASSWORD_POLICY", ~w(off warn block)) do
    config :kiln_cms, KilnCMS.Accounts.BreachedPassword,
      default_policy: %{"off" => :off, "warn" => :warn, "block" => :block}[policy]
  end
end

# Admin allowlist kill switch (#2248). KILN_ADMIN_ALLOWLIST_DISABLED=1 stops this
# node enforcing any site's admin allowlist (`KilnCMS.Security.AdminAllowlist`):
# the way back in for an operator who can set variables and restart but cannot
# run `bin/kiln_cms rpc 'KilnCMS.Release.admin_allowlist(clear: true)'`. The
# lists stay saved and the boot log says the switch is on. Only an explicit
# "on" writes anything. Skipped in :test so an exported value cannot change what
# the suite asserts.
if config_env() != :test do
  if KilnCMS.Config.Env.fetch("KILN_ADMIN_ALLOWLIST_DISABLED") == {:ok, true} do
    config :kiln_cms, :admin_allowlist, disabled: true
  end
end

# Human verification on password sign-in and registration (#2249) —
# `KilnCMS.Challenge`. Operator-only and deployment-wide: an account is global,
# so no site may turn its own sign-in challenges off.
#
#   CHALLENGE_PROVIDER           turnstile (recommended), recaptcha (v2
#                                checkbox) or an installed plugin's id
#   CHALLENGE_SITE_KEY           the widget's public site key
#   CHALLENGE_SECRET_KEY         the secret, or CHALLENGE_SECRET_KEY_FILE for a
#                                mounted file (resolved through KilnCMS.Keys)
#   CHALLENGE_SIGN_IN            off | adaptive (default adaptive)
#   CHALLENGE_REGISTRATION       off | adaptive | always (default adaptive)
#   CHALLENGE_HOSTNAMES          extra hostnames a token may have been solved on
#                                (space- or comma-separated), beyond the hosts
#                                the deployment serves itself
#   CHALLENGE_API_SIGN_IN        challenge POST /api/auth/sign_in too
#                                (default false: that contract is unchanged)
#   KILN_CHALLENGE_DISABLED      kill switch: nothing is required anywhere, no
#                                widget is drawn and the CSP is not widened
#
# Nothing is required until a provider, a site key and a secret are all set.
# Skipped in :test so an exported value cannot change what the suite asserts.
if config_env() != :test do
  # Only the id's shape here: a plugin's provider is not known yet. An id no
  # installed provider answers to leaves challenges off, with a boot warning.
  case KilnCMS.Challenge.parse_provider_id(System.get_env("CHALLENGE_PROVIDER")) do
    {:ok, provider} ->
      config :kiln_cms, KilnCMS.Challenge, provider: provider

    :unset ->
      :ok

    :invalid ->
      KilnCMS.Config.Env.record_unusable(
        "CHALLENGE_PROVIDER",
        System.get_env("CHALLENGE_PROVIDER"),
        "a provider id: turnstile, recaptcha or a plugin's (a-z, 0-9, _)"
      )
  end

  case System.get_env("CHALLENGE_SITE_KEY", "") |> String.trim() do
    "" -> :ok
    site_key -> config :kiln_cms, KilnCMS.Challenge, site_key: site_key
  end

  case System.get_env("CHALLENGE_SECRET_KEY_FILE", "") |> String.trim() do
    "" -> :ok
    path -> config :kiln_cms, KilnCMS.Challenge, secret_key: {:file, %{"path" => path}}
  end

  with {:ok, mode} <- KilnCMS.Config.Env.one_of("CHALLENGE_SIGN_IN", ~w(off adaptive)) do
    config :kiln_cms, KilnCMS.Challenge, sign_in: %{"off" => :off, "adaptive" => :adaptive}[mode]
  end

  with {:ok, mode} <-
         KilnCMS.Config.Env.one_of("CHALLENGE_REGISTRATION", ~w(off adaptive always)) do
    config :kiln_cms, KilnCMS.Challenge,
      registration: %{"off" => :off, "adaptive" => :adaptive, "always" => :always}[mode]
  end

  case System.get_env("CHALLENGE_HOSTNAMES", "") |> String.split([" ", ","], trim: true) do
    [] -> :ok
    hostnames -> config :kiln_cms, KilnCMS.Challenge, hostnames: hostnames
  end

  with {:ok, api?} <- KilnCMS.Config.Env.fetch("CHALLENGE_API_SIGN_IN") do
    config :kiln_cms, KilnCMS.Challenge, api_sign_in: api?
  end

  if KilnCMS.Config.Env.fetch("KILN_CHALLENGE_DISABLED") == {:ok, true} do
    config :kiln_cms, KilnCMS.Challenge, disabled: true
  end

  # CHALLENGE_FORMS (default true): whether a public form may ask for a check
  # at all. Each form opts in on its own (`Form.challenge`, off by default);
  # false turns every form off in effect without touching one.
  with {:ok, forms?} <- KilnCMS.Config.Env.fetch("CHALLENGE_FORMS") do
    config :kiln_cms, KilnCMS.Challenge, forms: forms?
  end
end
