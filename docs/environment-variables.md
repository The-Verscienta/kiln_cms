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
> `PHX_SERVER`, `PORT`, `SENTRY_DSN`, and the `OTEL_*` group.

## Required (production)

These must be set when running a production release. Missing `DATABASE_URL`,
`SECRET_KEY_BASE`, or `TOKEN_SIGNING_SECRET` will **raise on boot**.

| Variable | Purpose | Where it's read |
|----------|---------|-----------------|
| `PHX_SERVER` | Set to any truthy value to actually start the web server in a release. Without it the release boots but does not serve HTTP. The generated `bin/server` script sets this for you. | [`config/runtime.exs:19`](../config/runtime.exs#L19) |
| `DATABASE_URL` | Postgres connection string, e.g. `ecto://USER:PASS@HOST/DATABASE`. Raises if missing. | [`config/runtime.exs:64`](../config/runtime.exs#L64) |
| `SECRET_KEY_BASE` | Signs/encrypts session cookies and other secrets. Generate with `mix phx.gen.secret`. Raises if missing. | [`config/runtime.exs:109`](../config/runtime.exs#L109) |
| `TOKEN_SIGNING_SECRET` | Signs authentication tokens (AshAuthentication). Raises if missing. | [`config/runtime.exs:140`](../config/runtime.exs#L140) |
| `PHX_HOST` | Public hostname used to generate URLs (defaults to `example.com`, so effectively required for correct links/emails). | [`config/runtime.exs:115`](../config/runtime.exs#L115) |

## Optional — server & networking

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `PORT` | `4000` | HTTP listen port the Bandit server binds to. | [`config/runtime.exs:24`](../config/runtime.exs#L24) |
| `POOL_SIZE` | `10` | Ecto database connection pool size. See the pool-sizing formula in [`docs/performance.md`](performance.md). | [`config/runtime.exs:96`](../config/runtime.exs#L96) |
| `ECTO_IPV6` | unset | Set to `true`/`1` to connect to Postgres over IPv6. | [`config/runtime.exs:70`](../config/runtime.exs#L70) |
| `TRUSTED_PROXIES` | unset | Comma-separated reverse-proxy CIDRs (e.g. `10.0.0.0/8,172.16.0.0/12`). When set, `KilnCMSWeb.Plugs.ClientIp` rewrites `remote_ip` from `X-Forwarded-For` for rate limiting. Leave unset when internet-facing directly. | [`config/runtime.exs:123`](../config/runtime.exs#L123) |
| `DNS_CLUSTER_QUERY` | unset | DNS query for libcluster-style node discovery. | [`config/runtime.exs:117`](../config/runtime.exs#L117) |

> **Note on ports.** The public URL is hardcoded to port `443`/`https`
> ([`config/runtime.exs:128`](../config/runtime.exs#L128)); the app itself listens
> on `PORT`. The expected topology is a TLS-terminating reverse proxy on 443
> forwarding to the app on `PORT`.

## Optional — database TLS

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `DATABASE_SSL` | `true` | Encrypt the Postgres connection. Set to `false` only for providers that cannot offer TLS. | [`config/runtime.exs:78`](../config/runtime.exs#L78) |
| `DATABASE_SSL_CACERTFILE` | unset | Path to the provider's CA bundle. When set, the server cert is verified (`verify_peer`); otherwise the connection is still encrypted but uses `verify_none`. | [`config/runtime.exs:81`](../config/runtime.exs#L81) |

## Optional — object storage (S3-compatible)

Opt into the S3 storage adapter by setting `S3_BUCKET`. When it is set,
`S3_PUBLIC_BASE_URL`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` become
required (the latter two raise via `System.fetch_env!`). See
[`KilnCMS.Storage.S3`](../lib/kiln_cms/storage/s3.ex) for per-provider hosts.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `S3_BUCKET` | unset | Enables the S3 adapter. Leave unset to use local storage. | [`config/runtime.exs:148`](../config/runtime.exs#L148) |
| `S3_PUBLIC_BASE_URL` | — | Public base URL for stored objects. **Required when `S3_BUCKET` is set** (raises otherwise). | [`config/runtime.exs:155`](../config/runtime.exs#L155) |
| `AWS_ACCESS_KEY_ID` | — | S3 access key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:170`](../config/runtime.exs#L170) |
| `AWS_SECRET_ACCESS_KEY` | — | S3 secret key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:171`](../config/runtime.exs#L171) |
| `AWS_REGION` | `us-east-1` | Region. Use `auto` for Cloudflare R2; a real region for B2/Wasabi/AWS. | [`config/runtime.exs:173`](../config/runtime.exs#L173) |
| `S3_ACL` | unset | Per-object canned ACL (e.g. `public_read`). Only needed if the bucket isn't public at the bucket level. | [`config/runtime.exs:162`](../config/runtime.exs#L162) |
| `S3_ENDPOINT_HOST` | unset | Custom endpoint host for non-AWS stores (R2/B2/Wasabi/MinIO). Leave unset for AWS S3. | [`config/runtime.exs:177`](../config/runtime.exs#L177) |
| `S3_ENDPOINT_SCHEME` | `https://` | Scheme for the custom endpoint. | [`config/runtime.exs:179`](../config/runtime.exs#L179) |
| `S3_ENDPOINT_PORT` | `443` | Port for the custom endpoint. | [`config/runtime.exs:181`](../config/runtime.exs#L181) |

## Optional — search (Meilisearch)

Opt into the typo-tolerant search backend by setting `MEILI_URL`; otherwise
Postgres full-text search is the only backend. Run `mix kiln.meili.reindex` once
after enabling. See [`docs/meilisearch.md`](meilisearch.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MEILI_URL` | unset | Meilisearch server URL. Enables the backend when set. | [`config/runtime.exs:190`](../config/runtime.exs#L190) |
| `MEILI_MASTER_KEY` | unset | Meilisearch API master key. | [`config/runtime.exs:194`](../config/runtime.exs#L194), [`lib/kiln_cms/search/meilisearch.ex:14`](../lib/kiln_cms/search/meilisearch.ex#L14) |
| `MEILI_INDEX` | `kiln_content` | Index name. | [`config/runtime.exs:195`](../config/runtime.exs#L195) |

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
