# Environment variables

This is the canonical list of every environment variable KilnCMS reads, grouped
by whether it is **required** or **optional**, with a pointer to where each one is
consumed. Unless noted otherwise, variables are read at boot in
[`config/runtime.exs`](../config/runtime.exs), which executes for releases after
compilation and before the system starts.

> **Scope.** Most variables only take effect when `config_env() == :prod` (i.e. in
> a `mix release` / `MIX_ENV=prod` build). In dev and test, sensible defaults from
> `config/dev.exs` and `config/test.exs` are used instead, so you do not need to
> set these locally. The exceptions — read in *every* environment — are
> `PHX_SERVER`, `PORT`, `CORS_ORIGINS`, `EMBED_ORIGINS`, `SENTRY_DSN`, and the
> `OTEL_*` group.

## Required (production)

These must be set when running a production release. Missing `DATABASE_URL`,
`SECRET_KEY_BASE`, or `TOKEN_SIGNING_SECRET` will **raise on boot**.

| Variable | Purpose | Where it's read |
|----------|---------|-----------------|
| `PHX_SERVER` | Set to any truthy value to actually start the web server in a release. Without it the release boots but does not serve HTTP. The generated `bin/server` script sets this for you. | [`config/runtime.exs:19`](../config/runtime.exs#L19) |
| `DATABASE_URL` | Postgres connection string, e.g. `ecto://USER:PASS@HOST/DATABASE`. Raises if missing. | [`config/runtime.exs:75`](../config/runtime.exs#L75) |
| `SECRET_KEY_BASE` | Signs/encrypts session cookies and other secrets. Generate with `mix phx.gen.secret`. Raises if missing. | [`config/runtime.exs:120`](../config/runtime.exs#L120) |
| `TOKEN_SIGNING_SECRET` | Signs authentication tokens (AshAuthentication). Raises if missing. | [`config/runtime.exs:192`](../config/runtime.exs#L192) |
| `PHX_HOST` | Public hostname used to generate URLs and validate socket origins (defaults to `example.com`, so effectively required — wrong values break links, emails, **and LiveView socket connections**). Bare hostname; any `https://` prefix or trailing `/` is stripped. | [`config/runtime.exs:133`](../config/runtime.exs#L133) |

## Optional — server & networking

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `PORT` | `4000` | HTTP listen port the Bandit server binds to. | [`config/runtime.exs:24`](../config/runtime.exs#L24) |
| `CHECK_ORIGINS` | unset | Comma-separated **extra** origins allowed to open LiveView/channel sockets, for when the app is served from more than one hostname (e.g. mid domain migration). Entries may be full origins (`https://cms.example.com`), scheme-less (`//cms.example.com` — any scheme/port), or bare hosts (normalized to `//host`). The `PHX_HOST` origin is always allowed. Unset ⇒ only `PHX_HOST` may connect. | [`config/runtime.exs:145`](../config/runtime.exs#L145) |
| `CORS_ORIGINS` | unset | Comma-separated allowlist (or `*`) of origins allowed cross-origin **HTTP** reads of the headless API (`/api/*`, `/gql`). Read in every environment; without it prod stays same-origin-only. Does not affect sockets — that's `CHECK_ORIGINS`. See [`KilnCMSWeb.CORS`](../lib/kiln_cms_web/cors.ex). | [`config/runtime.exs:69`](../config/runtime.exs#L69) |
| `EMBED_ORIGINS` | `*` (any site) | Comma-separated allowlist of sites permitted to **iframe** an embeddable form (`/forms/:slug/embed`) — sets that page's CSP `frame-ancestors`. A blank value means same-origin only (embedding off). Safe to leave open: the embed page is an anonymous public form and a cross-site iframe never receives the `SameSite=Lax` session cookie. See [`KilnCMSWeb.Embed`](../lib/kiln_cms_web/embed.ex). | [`config/runtime.exs:79`](../config/runtime.exs#L79) |
| `VISUAL_EDITING_ENABLED` | `true` | Set to `false`/`0`/`no`/`off` to disable the visual-editing bridge (#355): the annotated preview route (`/api/visual-editing/:type/:slug`) 404s and the live-preview socket (`/ws/bridge`) refuses. Which origins may use the bridge (annotated read, write API, socket) is governed by **`CORS_ORIGINS`** — the bridge is cross-origin *to a different app*, so it uses that allowlist, not `CHECK_ORIGINS` (same-app extra hosts). See [visual-editing-bridge.md](visual-editing-bridge.md) and [`KilnCMS.VisualEditing`](../lib/kiln_cms/visual_editing.ex). | [`config/runtime.exs:86`](../config/runtime.exs#L86) |
| `PRESENTATION_PREVIEW_URL` | unset | The external front end's URL template for the Presentation console (`/editor/presentation/:type/:slug`, #355) — placeholders `{path}`/`{type}`/`{slug}`/`{locale}` (a bare base URL gets `{path}` appended). Unset ⇒ the console shows a setup hint. The front-end origin is derived from this for `postMessage` validation. See [visual-editing-bridge.md](visual-editing-bridge.md#the-presentation-console-side-by-side-editing) and [`KilnCMSWeb.Presentation`](../lib/kiln_cms_web/presentation.ex). | [`config/runtime.exs:98`](../config/runtime.exs#L98) |
| `POOL_SIZE` | `10` | Ecto database connection pool size. See the pool-sizing formula in [`docs/performance.md`](performance.md). | [`config/runtime.exs:107`](../config/runtime.exs#L107) |
| `ECTO_IPV6` | unset | Set to `true`/`1` to connect to Postgres over IPv6. | [`config/runtime.exs:81`](../config/runtime.exs#L81) |
| `TRUSTED_PROXIES` | unset | Comma-separated reverse-proxy CIDRs (e.g. `10.0.0.0/8,172.16.0.0/12`). When set, `KilnCMSWeb.Plugs.ClientIp` rewrites `remote_ip` from `X-Forwarded-For` for rate limiting. Leave unset when internet-facing directly. | [`config/runtime.exs:176`](../config/runtime.exs#L176) |
| `DNS_CLUSTER_QUERY` | unset | DNS query for libcluster-style node discovery. | [`config/runtime.exs:168`](../config/runtime.exs#L168) |

> **Note on ports.** The public URL is hardcoded to port `443`/`https`
> ([`config/runtime.exs:179`](../config/runtime.exs#L179)); the app itself listens
> on `PORT`. The expected topology is a TLS-terminating reverse proxy on 443
> forwarding to the app on `PORT`.

## Optional — database TLS

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `DATABASE_SSL` | `true` | Encrypt the Postgres connection. Set to `false` only for providers that cannot offer TLS. | [`config/runtime.exs:89`](../config/runtime.exs#L89) |
| `DATABASE_SSL_CACERTFILE` | unset | Path to the provider's CA bundle. When set, the server cert is verified (`verify_peer`); otherwise the connection is still encrypted but uses `verify_none`. | [`config/runtime.exs:92`](../config/runtime.exs#L92) |

## Optional — object storage (S3-compatible)

Opt into the S3 storage adapter by setting `S3_BUCKET`. When it is set,
`S3_PUBLIC_BASE_URL`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` become
required (the latter two raise via `System.fetch_env!`). See
[`KilnCMS.Storage.S3`](../lib/kiln_cms/storage/s3.ex) for per-provider hosts.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `S3_BUCKET` | unset | Enables the S3 adapter. Leave unset to use local storage. | [`config/runtime.exs:200`](../config/runtime.exs#L200) |
| `S3_PUBLIC_BASE_URL` | — | Public base URL for stored objects. **Required when `S3_BUCKET` is set** (raises otherwise). | [`config/runtime.exs:207`](../config/runtime.exs#L207) |
| `AWS_ACCESS_KEY_ID` | — | S3 access key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:222`](../config/runtime.exs#L222) |
| `AWS_SECRET_ACCESS_KEY` | — | S3 secret key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:223`](../config/runtime.exs#L223) |
| `AWS_REGION` | `us-east-1` | Region. Use `auto` for Cloudflare R2; a real region for B2/Wasabi/AWS. | [`config/runtime.exs:225`](../config/runtime.exs#L225) |
| `S3_ACL` | unset | Per-object canned ACL (e.g. `public_read`). Only needed if the bucket isn't public at the bucket level. | [`config/runtime.exs:214`](../config/runtime.exs#L214) |
| `S3_ENDPOINT_HOST` | unset | Custom endpoint host for non-AWS stores (R2/B2/Wasabi/MinIO). Leave unset for AWS S3. | [`config/runtime.exs:229`](../config/runtime.exs#L229) |
| `S3_ENDPOINT_SCHEME` | `https://` | Scheme for the custom endpoint. | [`config/runtime.exs:231`](../config/runtime.exs#L231) |
| `S3_ENDPOINT_PORT` | `443` | Port for the custom endpoint. | [`config/runtime.exs:233`](../config/runtime.exs#L233) |

## Optional — SSO (OpenID Connect, #331)

Only read when SSO was compiled in (`config :kiln_cms, :sso_oidc, enabled:
true` — see docs/sso.md). All four are then required for the flow to work.

| Variable | Purpose | Where it's read |
|----------|---------|-----------------|
| `OIDC_CLIENT_ID` | Client id registered at the IdP | `config/runtime.exs` |
| `OIDC_CLIENT_SECRET` | Client secret (`client_secret_basic`) | `config/runtime.exs` |
| `OIDC_ISSUER` | Provider base URL (OIDC discovery) | `config/runtime.exs` |
| `OIDC_REDIRECT_URI` | This site's callback base, e.g. `https://cms.example.com/auth` | `config/runtime.exs` |

## Optional — outbound email

With none of these set, production uses the dev-only in-memory adapter: the
app runs, but every delivery job fails in Oban and no email leaves. Opt into
real delivery with `MAIL_MODE` (or, for back-compat, just `SMTP_HOST`, which
implies `MAIL_MODE=smtp`). Direct mode is configured and verified from
`/editor/mail` — see the operator guide
[`docs/direct-email-delivery.md`](direct-email-delivery.md) for the DNS
requirements (SPF/DKIM/DMARC/PTR) and the big caveat: many cloud hosts block
outbound port 25.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MAIL_MODE` | unset | `smtp` = relay through an SMTP server; `direct` = deliver straight to each recipient domain's MX hosts (built-in MTA, no relay). Anything else raises at boot. | [`config/runtime.exs:307`](../config/runtime.exs#L307) |
| `MAIL_FROM_EMAIL` | unset | From address for all outbound mail. **Required when `MAIL_MODE=direct`** (raises otherwise) — its domain is the sending/DKIM domain. | [`config/runtime.exs:359`](../config/runtime.exs#L359) |
| `MAIL_FROM_NAME` | `KilnCMS` | Display name for the From address. | [`config/runtime.exs:360`](../config/runtime.exs#L360) |
| `SMTP_HOST` | unset | Relay host. **Required when `MAIL_MODE=smtp`**; setting it without `MAIL_MODE` also selects smtp mode. | [`config/runtime.exs:315`](../config/runtime.exs#L315) |
| `SMTP_PORT` | `587` | Relay port. | [`config/runtime.exs:321`](../config/runtime.exs#L321) |
| `SMTP_USERNAME` | unset | Relay username (`auth: :always`). | [`config/runtime.exs:322`](../config/runtime.exs#L322) |
| `SMTP_PASSWORD` | unset | Relay password. | [`config/runtime.exs:323`](../config/runtime.exs#L323) |
| `SMTP_TLS` | `true` | STARTTLS to the relay. Set to `false` only for a local dev/test relay. | [`config/runtime.exs:324`](../config/runtime.exs#L324) |
| `MAIL_HELO_HOST` | `PHX_HOST` | Direct mode only: HELO/EHLO hostname. Deliverability requires the sending IP's PTR record to resolve to this name. | [`config/runtime.exs:336`](../config/runtime.exs#L336) |

## Optional — search (Meilisearch)

Opt into the typo-tolerant search backend by setting `MEILI_URL`; otherwise
Postgres full-text search is the only backend. Run `mix kiln.meili.reindex` once
after enabling. See [`docs/meilisearch.md`](meilisearch.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MEILI_URL` | unset | Meilisearch server URL. Enables the backend when set. | [`config/runtime.exs:242`](../config/runtime.exs#L242) |
| `MEILI_MASTER_KEY` | unset | Meilisearch API master key. | [`config/runtime.exs:246`](../config/runtime.exs#L246), [`lib/kiln_cms/search/meilisearch.ex:14`](../lib/kiln_cms/search/meilisearch.ex#L14) |
| `MEILI_INDEX` | `kiln_content` | Index name. | [`config/runtime.exs:247`](../config/runtime.exs#L247) |

## Optional — error tracking (Sentry)

Enabled in any environment only when `SENTRY_DSN` is set; otherwise every Sentry
capture is a no-op. See [`docs/observability.md`](observability.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `SENTRY_DSN` | unset | Sentry DSN. Enables error reporting when set. | [`config/runtime.exs:32`](../config/runtime.exs#L32) |
| `SENTRY_ENV` | `config_env()` | Environment name tag for Sentry events. | [`config/runtime.exs:35`](../config/runtime.exs#L35) |
| `RELEASE_VSN` | unset | Release version tag (set automatically by the release runtime) to pin regressions to a deploy. | [`config/runtime.exs:38`](../config/runtime.exs#L38) |

## Optional — distributed tracing (OpenTelemetry)

Enabled only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, which flips the
`:otel_enabled` flag and points the OTLP exporter at the collector. See
[`docs/observability.md`](observability.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | OTLP collector endpoint. Enables tracing when set. | [`config/runtime.exs:48`](../config/runtime.exs#L48) |
| `OTEL_SERVICE_NAME` | `kiln_cms` | Service name attached to spans. | [`config/runtime.exs:54`](../config/runtime.exs#L54) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | OTLP protocol. | [`config/runtime.exs:58`](../config/runtime.exs#L58) |
| `OTEL_EXPORTER_OTLP_HEADERS` | unset | Standard OTLP headers (honored by the exporter library). | OpenTelemetry exporter (standard `OTEL_*`) |

## Test / CI only

These are read by `config/test.exs` and `config/e2e.exs` and are not relevant to
production.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MIX_TEST_PARTITION` | unset | Suffix appended to the test database name for partitioned test runs. | [`config/test.exs:46`](../config/test.exs#L46) |
| `POSTGRES_USER` | `postgres` | E2E database user. | [`config/e2e.exs:11`](../config/e2e.exs#L11) |
| `POSTGRES_PASSWORD` | `postgres` | E2E database password. | [`config/e2e.exs:12`](../config/e2e.exs#L12) |
| `POSTGRES_HOST` | `localhost` | E2E database host. | [`config/e2e.exs:13`](../config/e2e.exs#L13) |
| `POSTGRES_DB` | `kiln_cms_e2e` | E2E database name. | [`config/e2e.exs:14`](../config/e2e.exs#L14) |
