import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# The secret key base is used to sign/encrypt cookies and other secrets.
# A default value is used in config/dev.exs and config/test.exs but you
# want to use a different value for prod and you most likely don't want
# to check this value into version control, so we use an environment
# variable instead.
secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

# PHX_HOST is meant to be a bare host (e.g. "cms.example.com"), but is
# easy to misconfigure as a full URL. Strip any scheme/trailing slash so a
# `https://host` value doesn't get baked into the Endpoint's `url: [host:
# ...]` — Phoenix uses that host as-is (not re-parsed) both for generating
# absolute URLs and for validating the LiveView/channel socket's Origin
# header (check_origin), so a raw scheme prefix silently breaks both.
#
# Shared with `runtime/prod/mailer.exs` (the SMTP HELO name falls back to it),
# and a local variable does not cross a fragment boundary — hence a
# module rather than the same four lines in two files. See KilnCMS.Config.Host.
host = KilnCMS.Config.Host.canonical()

# CHECK_ORIGINS: comma-separated allowlist of extra origins permitted to
# open LiveView/channel sockets, for when the app is reachable on more than
# one hostname (e.g. mid domain migration). Entries may be full origins
# ("https://cms.example.com"), scheme-less ("//cms.example.com" — any
# scheme/port), or bare hosts (normalized to "//host"). The PHX_HOST origin
# is always kept, so this can only widen the allowlist. Unset ⇒ Phoenix's
# default: sockets are only accepted from the PHX_HOST origin.
extra_origins =
  "CHECK_ORIGINS"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(fn origin ->
    origin = String.trim_trailing(origin, "/")

    if String.starts_with?(origin, ["https://", "http://", "//"]) do
      origin
    else
      "//" <> origin
    end
  end)

# Accept sockets from the canonical host AND any of its subdomains — multi-tenant
# sites are served at `<org>.<host>` (epic #336), so a per-org LiveView/channel
# would otherwise fail the Origin check. `//*.host` matches any scheme/port. The
# explicit list (not `true`) is required for the wildcard; `CHECK_ORIGINS` still
# widens it (e.g. a custom domain mid-migration).
#
# The wildcard covers every subdomain of the base host, registered as an org or
# not, so passing it says nothing about WHICH org a socket may act as. That is
# each socket's own tenant resolution (#654) — every one of the four resolves
# from the host it connected on, whatever origin admitted it.
check_origin = ["https://" <> host, "//*." <> host | extra_origins]

config :kiln_cms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

# Trusted reverse-proxy CIDRs. When set (comma-separated, e.g.
# "10.0.0.0/8,172.16.0.0/12"), KilnCMSWeb.Plugs.ClientIp rewrites remote_ip from
# X-Forwarded-For so rate limiting keys on the real client. Leave unset when the
# app is internet-facing directly (X-Forwarded-For would be spoofable).
# Entries are trimmed, matching CHECK_ORIGINS above: `split(trim: true)` drops
# empty segments but not whitespace, so `10.0.0.0/8, 172.16.0.0/12` (a space
# after the comma) or a trailing newline from a mounted secret file would reach
# `RemoteIp.init/1` as a malformed CIDR — which raises.
config :kiln_cms,
       :trusted_proxies,
       "TRUSTED_PROXIES"
       |> System.get_env("")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == ""))

# The base host multi-tenant subdomains are carved from (epic #336): a request
# to `<org>.<TENANT_BASE_HOST>` resolves to that org. Defaults to PHX_HOST — set
# it explicitly only if tenant subdomains live under a different apex than the
# canonical URL host.
config :kiln_cms, :tenant_base_host, System.get_env("TENANT_BASE_HOST") || host

# Reject requests whose Host matches no organization instead of serving them
# the default org (#563). Recommended for any multi-tenant deployment; leave
# off for a single-host install, where the bare host / an IP / the load
# balancer's health-check Host all legitimately arrive unmatched and would
# start 404ing.
#
# `fetch/1`, not `flag/2`: this must only OVERRIDE config when the operator
# actually set the variable. `flag/2` writes unconditionally, so an unset
# variable would rewrite a project overlay's `config :kiln_cms,
# :tenant_strict_host, true` back to false — silently, in production, on the
# multi-org deployment most likely to have set it. See `KilnCMS.Config.Env`.
with {:ok, strict_host?} <- KilnCMS.Config.Env.fetch("TENANT_STRICT_HOST") do
  config :kiln_cms, :tenant_strict_host, strict_host?
end

# API documentation surface — the OpenAPI document and the Swagger explorer
# (#567). Off in a production build; an operator publishing a public API
# turns it back on here. `fetch/1` rather than `flag/2` for the reason above:
# an unset variable must not rewrite a project overlay's own setting.
with {:ok, api_docs?} <- Env.fetch("API_DOCS_ENABLED") do
  config :kiln_cms, :api_docs, api_docs?
end

# White-label branding (#48, see `KilnCMS.Branding`) — the instance-wide layer
# beneath each site's own editor-managed row. Unset vars fall through to the
# stock KilnCMS defaults. Off-origin BRAND_LOGO_URL hosts must also be in
# CSP_IMG_SRC or the browser will block the image.
#
# BRAND_PRIMARY_COLOR must be a hex colour (`#1d4ed8` or `#1d4`), and is
# checked HERE rather than only where it is used (#1089). `KilnCMS.Branding`
# still rejects a bad value — it is the same grammar wherever the colour comes
# from, and the editor-managed row goes through it too — but its rejection is
# a bare `Logger.warning`, which `Sentry.LoggerHandler`'s defaults
# (`level: :error`, `capture_log_messages: false`) drop. So on the env path
# that was container stdout and nowhere else, for a value that changes what
# every page looks like. Reading it through the collector puts it in the same
# boot-warning replay as every other misconfiguration in this file (#634).
brand_primary_color_raw = System.get_env("BRAND_PRIMARY_COLOR", "")

brand_primary_color =
  case KilnCMS.CMS.Validations.BrandTokens.normalize_color(brand_primary_color_raw) do
    nil ->
      # Blank — including whitespace-only — is "leave this alone", the same
      # rule a bare `FOO=` gets everywhere else in this file; warning about it
      # would be noise on every boot. `normalize_color/1` trims for itself, so
      # only the emptiness test needs to.
      #
      # The RAW value goes to the collector, untrimmed: the trimming is a
      # candidate explanation for the mismatch, so echoing the normalized form
      # hands the operator the one spelling that is not in their compose file.
      unless String.trim(brand_primary_color_raw) == "" do
        Env.record_unusable(
          "BRAND_PRIMARY_COLOR",
          brand_primary_color_raw,
          "a hex colour such as #1d4ed8 or #1d4"
        )
      end

      nil

    # Normalized (downcased, shorthand expanded) rather than raw: `Branding`
    # would do it on every read anyway, and writing the canonical form means
    # the value the tokens are built from is the one an operator sees.
    normalized ->
      normalized
  end

branding_config = []

branding_config =
  if site_name = System.get_env("SITE_NAME") do
    Keyword.put(branding_config, :site_name, site_name)
  else
    branding_config
  end

branding_config =
  if logo_url = System.get_env("BRAND_LOGO_URL") do
    Keyword.put(branding_config, :logo_url, logo_url)
  else
    branding_config
  end

branding_config =
  if favicon_url = System.get_env("BRAND_FAVICON_URL") do
    Keyword.put(branding_config, :favicon_url, favicon_url)
  else
    branding_config
  end

branding_config =
  if brand_primary_color do
    Keyword.put(branding_config, :primary_color, brand_primary_color)
  else
    branding_config
  end

if branding_config != [] do
  config :kiln_cms, :branding, branding_config
end

config :kiln_cms, KilnCMSWeb.Endpoint,
  url: [host: host, port: 443, scheme: "https"],
  check_origin: check_origin,
  http: [
    # Enable IPv6 and bind on all interfaces.
    # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
    # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
    # for details about using IPv6 vs IPv4 and loopback vs public addresses.
    ip: {0, 0, 0, 0, 0, 0, 0, 0}
  ],
  secret_key_base: secret_key_base

config :kiln_cms,
  token_signing_secret:
    System.get_env("TOKEN_SIGNING_SECRET") ||
      raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")
