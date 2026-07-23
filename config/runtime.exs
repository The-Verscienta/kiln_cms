import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kiln_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kiln_cms, KilnCMSWeb.Endpoint, server: true
end

config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

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

# ## Error tracking (Sentry)
#
# Enabled — in any environment — only when SENTRY_DSN is set. With no DSN every
# Sentry capture is a no-op, so dev/test/CI stay offline. The logger handler that
# turns crashes into Sentry events is attached in KilnCMS.Application only when a
# DSN is present.
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: System.get_env("SENTRY_ENV") || to_string(config_env()),
    # Tag events with the running release version when available (set by the
    # release runtime), so regressions can be pinned to a deploy.
    release: System.get_env("RELEASE_VSN")
end

# ## Distributed tracing (OpenTelemetry)
#
# Enabled only when an OTLP collector endpoint is configured. Flips the flag
# KilnCMS.Application reads to attach the Phoenix/Ecto/Bandit/Oban
# instrumentation, and points the OTLP exporter at the collector. Honors the
# standard OTEL_* env vars (OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_PROTOCOL,
# OTEL_EXPORTER_OTLP_HEADERS) for the rest.
if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :kiln_cms, :otel_enabled, true

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: %{service: %{name: System.get_env("OTEL_SERVICE_NAME") || "kiln_cms"}}

  config :opentelemetry_exporter,
    otlp_protocol:
      "OTEL_EXPORTER_OTLP_PROTOCOL" |> System.get_env("http_protobuf") |> String.to_atom(),
    otlp_endpoint: otlp_endpoint
end

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
# Defaults to `*` (any site), which is safe: the embed page is an anonymous
# public form and a cross-site iframe never receives the SameSite=Lax session
# cookie. Set EMBED_ORIGINS to an allowlist to lock it down, or to a blank value
# for same-origin only. See KilnCMSWeb.Embed.
if embed_origins = System.get_env("EMBED_ORIGINS") do
  config :kiln_cms, :embed_origins, KilnCMSWeb.Embed.parse_env(embed_origins)
end

# ## Visual-editing bridge (#355) — the annotated preview read + `/bridge.js`
#
# Enabled by default. Set VISUAL_EDITING_ENABLED=false to switch the whole
# surface off (the annotated `/api/visual-editing/...` route 404s). Which origins
# may fetch it cross-origin and round-trip writes is governed by CORS_ORIGINS
# (the annotated read and the write API both live under `/api`); draft visibility
# is governed by the caller's API key. See KilnCMS.VisualEditing.
if visual_editing = System.get_env("VISUAL_EDITING_ENABLED") do
  config :kiln_cms, :visual_editing_enabled, visual_editing not in ~w(false 0 no off)
end

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

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Encrypt the Postgres connection by default. Set DATABASE_SSL=false only for a
  # provider that genuinely cannot offer TLS (most managed Postgres — RDS,
  # Supabase, Neon, Fly — require or strongly prefer it). When DATABASE_SSL_CACERTFILE
  # points at the provider's CA bundle we verify the server certificate; otherwise
  # we still encrypt but skip peer verification (verify_none) so deployment isn't
  # blocked on cert plumbing.
  database_ssl? = System.get_env("DATABASE_SSL", "true") in ~w(true 1)

  database_ssl_opts =
    case System.get_env("DATABASE_SSL_CACERTFILE") do
      nil ->
        [verify: :verify_none]

      cacertfile ->
        [verify: :verify_peer, cacertfile: cacertfile, depth: 3]
    end

  config :kiln_cms,
         KilnCMS.Repo,
         [
           url: database_url,
           # Shared by web requests and Oban workers (~34 concurrent across the
           # split queues) — size up from 10 in production. See the pool-sizing
           # formula in docs/performance.md.
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           # For machines with several cores, consider starting multiple pools of `pool_size`
           # pool_count: 4,
           socket_options: maybe_ipv6,
           ssl: database_ssl?
         ] ++ if(database_ssl?, do: [ssl_opts: database_ssl_opts], else: [])

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

  # PHX_HOST is meant to be a bare host (e.g. "be.verscienta.com"), but is
  # easy to misconfigure as a full URL. Strip any scheme/trailing slash so a
  # `https://host` value doesn't get baked into the Endpoint's `url: [host:
  # ...]` — Phoenix uses that host as-is (not re-parsed) both for generating
  # absolute URLs and for validating the LiveView/channel socket's Origin
  # header (check_origin), so a raw scheme prefix silently breaks both.
  host =
    (System.get_env("PHX_HOST") || "example.com")
    |> String.replace_leading("https://", "")
    |> String.replace_leading("http://", "")
    |> String.trim_trailing("/")

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
  check_origin = ["https://" <> host, "//*." <> host | extra_origins]

  config :kiln_cms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Trusted reverse-proxy CIDRs. When set (comma-separated, e.g.
  # "10.0.0.0/8,172.16.0.0/12"), KilnCMSWeb.Plugs.ClientIp rewrites remote_ip from
  # X-Forwarded-For so rate limiting keys on the real client. Leave unset when the
  # app is internet-facing directly (X-Forwarded-For would be spoofable).
  config :kiln_cms,
         :trusted_proxies,
         "TRUSTED_PROXIES" |> System.get_env("") |> String.split(",", trim: true)

  # The base host multi-tenant subdomains are carved from (epic #336): a request
  # to `<org>.<TENANT_BASE_HOST>` resolves to that org. Defaults to PHX_HOST — set
  # it explicitly only if tenant subdomains live under a different apex than the
  # canonical URL host.
  config :kiln_cms, :tenant_base_host, System.get_env("TENANT_BASE_HOST") || host

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

  # OIDC SSO settings (#331) — only read when the strategy was compiled in
  # (`config :kiln_cms, :sso_oidc, enabled: true`). OIDC_ISSUER is the
  # provider's base URL (discovery at /.well-known/openid-configuration);
  # OIDC_REDIRECT_URI is this site's callback base, e.g.
  # "https://cms.example.com/auth".
  if Application.get_env(:kiln_cms, :sso_oidc, [])[:enabled] do
    config :kiln_cms, :sso_oidc,
      enabled: true,
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET"),
      base_url: System.get_env("OIDC_ISSUER"),
      redirect_uri: System.get_env("OIDC_REDIRECT_URI")
  end

  # ## Object storage (S3-compatible)
  #
  # Opt into the S3 adapter by setting S3_BUCKET. Works with AWS S3, Cloudflare
  # R2, Backblaze B2, Wasabi, MinIO, etc. For any non-AWS provider, also set
  # S3_ENDPOINT_HOST (see KilnCMS.Storage.S3 docs for per-provider hosts).
  if bucket = System.get_env("S3_BUCKET") do
    config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

    s3_opts =
      [
        bucket: bucket,
        public_base_url:
          System.get_env("S3_PUBLIC_BASE_URL") ||
            raise("S3_BUCKET is set but S3_PUBLIC_BASE_URL is missing")
      ]

    # Most buckets are made public at the bucket level; only send a per-object
    # canned ACL (e.g. "public_read") if the provider/bucket needs one.
    s3_opts =
      case System.get_env("S3_ACL") do
        nil -> s3_opts
        acl -> Keyword.put(s3_opts, :acl, String.to_atom(acl))
      end

    config :kiln_cms, KilnCMS.Storage.S3, s3_opts

    config :ex_aws,
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      # R2 uses "auto"; B2/Wasabi/AWS use a real region.
      region: System.get_env("AWS_REGION") || "us-east-1"

    # Custom endpoint for any non-AWS S3-compatible store (R2/B2/Wasabi/MinIO).
    # Leave unset for AWS S3 (ExAws derives the host from the region).
    if endpoint_host = System.get_env("S3_ENDPOINT_HOST") do
      config :ex_aws, :s3,
        scheme: System.get_env("S3_ENDPOINT_SCHEME") || "https://",
        host: endpoint_host,
        port: String.to_integer(System.get_env("S3_ENDPOINT_PORT") || "443")
    end
  end

  # ## Meilisearch (optional, Phase 6)
  #
  # Opt into the typo-tolerant search backend by setting MEILI_URL. Leave it
  # unset to keep Postgres full-text search as the only backend. Run
  # `mix kiln.meili.reindex` once after enabling to backfill the index.
  if meili_url = System.get_env("MEILI_URL") do
    config :kiln_cms, KilnCMS.Search.Meilisearch,
      enabled: true,
      url: meili_url,
      master_key: System.get_env("MEILI_MASTER_KEY"),
      index: System.get_env("MEILI_INDEX") || "kiln_content"
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # config/config.exs defaults to Swoosh.Adapters.Local — a dev-only in-memory
  # mailbox with no delivery, and no supervised storage process outside `mix
  # phx.server`. All outbound email is queued through KilnCMS.Mail onto the
  # Oban :mail queue, so with no real adapter configured in production the
  # triggering requests still succeed but every delivery job fails and retries
  # in Oban (visible in the oban_jobs table / logs) — no email actually leaves.
  #
  # Two real-delivery modes (docs/direct-email-delivery-plan.md):
  #
  #   * MAIL_MODE=smtp (or just setting SMTP_HOST, the pre-MAIL_MODE opt-in) —
  #     relay through any SMTP server (Postmark, SES, Gmail, ...). TLS is on
  #     by default (STARTTLS on 587); set SMTP_TLS=false for an unencrypted
  #     relay (e.g. a local dev/test relay).
  #   * MAIL_MODE=direct — no relay: deliver straight to each recipient
  #     domain's MX hosts on port 25, DKIM-signed once a key is configured.
  #     Requires MAIL_FROM_EMAIL (its domain is the sending domain) and
  #     correct DNS (SPF/DKIM/DMARC/PTR) — see /editor/mail once Phase 5
  #     lands, and mind that many cloud hosts block outbound port 25.
  # Treat a blank MAIL_MODE ("" — a common `MAIL_MODE=` .env/compose artifact)
  # as unset rather than an unknown mode: an empty string is truthy in Elixir,
  # so without this it would fall through to the `other -> raise` clause and
  # crash boot (and mask a set SMTP_HOST, since `||` wouldn't fall back).
  mail_mode =
    case System.get_env("MAIL_MODE") do
      blank when blank in [nil, ""] -> System.get_env("SMTP_HOST") && "smtp"
      mode -> mode
    end

  case mail_mode do
    "smtp" ->
      smtp_host =
        System.get_env("SMTP_HOST") ||
          raise "MAIL_MODE=smtp requires SMTP_HOST (the relay to send through)"

      # Explicit TLS options for STARTTLS: since OTP 26 the ssl app defaults to
      # `verify_peer` with no CA store configured, so gen_smtp's handshake to any
      # relay dies with :tls_failed unless we supply one. Verify against
      # CAStore's bundle (with SNI, required by multi-tenant relays) by default;
      # SMTP_TLS_VERIFY=false keeps the connection encrypted but skips peer
      # verification, for relays with self-signed or mismatched certificates.
      smtp_tls_options =
        if System.get_env("SMTP_TLS_VERIFY") == "false" do
          [verify: :verify_none]
        else
          [
            verify: :verify_peer,
            cacertfile: CAStore.file_path(),
            server_name_indication: String.to_charlist(smtp_host),
            depth: 3
          ]
        end

      config :kiln_cms, KilnCMS.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        tls: if(System.get_env("SMTP_TLS") == "false", do: :never, else: :always),
        tls_options: smtp_tls_options,
        auth: :always

    "direct" ->
      unless System.get_env("MAIL_FROM_EMAIL") do
        raise """
        MAIL_MODE=direct requires MAIL_FROM_EMAIL: its domain is the sending
        (and DKIM signing) domain, and async bounces are delivered to it.
        """
      end

      helo_host =
        case System.get_env("MAIL_HELO_HOST") do
          empty when empty in [nil, ""] -> host
          helo -> helo
        end

      config :kiln_cms, KilnCMS.Mailer,
        adapter: KilnCMS.Mailer.DirectMX,
        # HELO name; deliverability requires the sending IP's PTR record to
        # resolve to this host.
        hostname: helo_host

    nil ->
      :ok

    other ->
      raise "unknown MAIL_MODE #{inspect(other)} — expected \"smtp\" or \"direct\""
  end

  # Persist the resolved mode so the admin mail page reports it authoritatively
  # instead of reverse-inferring it from the adapter module (which mislabels a
  # downstream project's custom Swoosh adapter as "no real delivery").
  config :kiln_cms, :mail_mode, mail_mode

  if from_email = System.get_env("MAIL_FROM_EMAIL") do
    config :kiln_cms, email_from: {System.get_env("MAIL_FROM_NAME") || "KilnCMS", from_email}
  end
end
