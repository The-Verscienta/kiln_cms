# Deploying KilnCMS on Coolify

A step-by-step guide to running the KilnCMS backend (with the Verscienta catalog)
on [Coolify](https://coolify.io). KilnCMS ships as a self-contained Elixir/OTP
release built from the repo `Dockerfile`; the only hard dependency is
**PostgreSQL with the `pgvector` extension**.

## Architecture

What you deploy on Coolify:

```
                     ┌──────────────────────────────┐
   Internet  ──TLS── │ Coolify proxy (Traefik)      │
   :443             └──────────────┬───────────────┘
                                    │ http :4000 (PORT)
                          ┌─────────▼──────────┐
                          │ kiln_cms app       │   OTP release (bin/server)
                          │ Phoenix + Ash +    │   • web + admin (/admin, /editor)
                          │ Oban (in-process)  │   • GraphQL /gql, JSON:API /api/json
                          └─────────┬──────────┘   • background jobs (no broker)
                                    │ ecto (private network)
                          ┌─────────▼──────────┐
                          │ PostgreSQL 17 +    │
                          │ pgvector           │
                          └────────────────────┘
   Optional: S3/R2 (media) · Meilisearch (search) · Sentry · OTEL collector
```

Notes that shape the setup:

- **No message broker / Redis required.** Oban uses Postgres; PubSub is native
  BEAM. One app container + one database is the whole stack.
- **TLS is terminated at Coolify's proxy.** The app listens on plain HTTP on
  `PORT` (default 4000); its public URL is fixed to `https://$PHX_HOST:443`, and
  `force_ssl` (with HSTS) is compiled in — so it **must** sit behind a proxy that
  sets `X-Forwarded-Proto: https` (Coolify's Traefik does this).
- **`pgvector` is mandatory** — a migration runs `CREATE EXTENSION vector` for
  semantic-search columns, even though semantic search itself is off by default.
- This deploys the **backend only**. The public delivery frontend (still on
  Directus today) is a separate concern.

---

## Prerequisites

- A Coolify instance (v4+) with a server/destination configured.
- A domain (e.g. `cms.verscienta.com`) with DNS pointing at the Coolify server.
- Coolify connected to the `kiln_cms` Git repo (GitHub App or deploy key).
- Two generated secrets:
  ```bash
  openssl rand -base64 64   # SECRET_KEY_BASE
  openssl rand -base64 64   # TOKEN_SIGNING_SECRET
  ```

---

## Step 1 — PostgreSQL with pgvector

In your Coolify Project → Environment → **+ New** → **Database** → **PostgreSQL**.

1. **Use a pgvector-capable image.** In the database settings set the Docker
   image to **`pgvector/pgvector:pg17`** (the stock `postgres:*` image does *not*
   include the `vector` extension and the migration will fail). PG 17 matches the
   image used in local dev.
2. Set a strong password; note the database name and username.
3. Start the database. Coolify shows two connection strings — use the
   **internal** one (private Docker network) for the app:
   ```
   postgresql://USER:PASSWORD@<internal-host>:5432/DBNAME
   ```
   Keep it for `DATABASE_URL` below.

> The default Coolify Postgres superuser may create extensions, so the
> `CREATE EXTENSION vector` migration just works. If you later run the app as a
> non-superuser role, pre-create it once: `CREATE EXTENSION IF NOT EXISTS vector;`

---

## Step 2 — Create the application

Project → Environment → **+ New** → **Application** → **Public/Private Repository**.

1. Select the `kiln_cms` repo and the branch to deploy.
2. **Build Pack: `Dockerfile`** (Coolify auto-detects the repo `Dockerfile`,
   which produces the OTP release). No build args are required.
3. **Ports exposed:** `4000`. Coolify routes the domain to this container port.
4. Leave the start command as the image default (`/app/bin/server`).

---

## Step 3 — Environment variables

Add these under the application's **Environment Variables** (runtime). None are
needed at build time.

### Required

| Variable | Value |
|----------|-------|
| `DATABASE_URL` | The **internal** Postgres URL from Step 1, e.g. `ecto://user:pass@host:5432/kiln_cms`. (`ecto://`, `postgres://`, `postgresql://` all parse.) |
| `SECRET_KEY_BASE` | First generated secret. |
| `TOKEN_SIGNING_SECRET` | Second generated secret. |
| `PHX_HOST` | Your public hostname, e.g. `cms.verscienta.com` (used for URL/cookie/origin generation — set it correctly or links and LiveView origin checks break). |
| `DATABASE_SSL` | **`false`** when using Coolify's managed Postgres over the private network (it doesn't terminate TLS; leaving the default `true` causes a handshake failure). Use `true` for a managed provider that requires TLS. |

> `PHX_SERVER` is set automatically by `bin/server` — you don't need to add it.

### Recommended

| Variable | Value | Why |
|----------|-------|-----|
| `POOL_SIZE` | `20` | Oban runs ~29 workers across queues plus web requests; bump the pool above the default 10. See `docs/performance.md`. |
| `PUBLIC_BASE_URL` | `https://cms.verscienta.com` | Used for sitemap/robots/JSON-LD canonical URLs. *(Currently a compile-time default; if you need it changed, set it in `config/prod.exs` — see note below.)* |

### Optional (enable a feature only when set)

| Group | Variables |
|-------|-----------|
| **Object storage (S3/R2)** | `S3_BUCKET`, `S3_PUBLIC_BASE_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `S3_ENDPOINT_HOST`, `S3_ENDPOINT_SCHEME`, `S3_ENDPOINT_PORT`, `S3_ACL` — see **Media storage** below. |
| **Search (Meilisearch)** | `MEILI_URL`, `MEILI_MASTER_KEY`, `MEILI_INDEX` — Postgres full-text is the default; only set these to add Meilisearch. |
| **Error tracking** | `SENTRY_DSN`, `SENTRY_ENV` |
| **Tracing** | `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_HEADERS` |
| **DB TLS verification** | `DATABASE_SSL_CACERTFILE` (path to provider CA bundle for `verify_peer`) |
| **Behind extra proxies** | `TRUSTED_PROXIES` (comma-separated CIDRs) for correct client IPs in rate limiting |

The canonical, line-referenced list lives in
[`docs/environment-variables.md`](environment-variables.md).

---

## Step 4 — Domain, port & health check

1. **Domains:** set the FQDN (e.g. `https://cms.verscienta.com`). Coolify
   provisions a Let's Encrypt certificate and routes 443 → container `:4000`.
2. **Health check:** configure Coolify's HTTP health check to
   **`GET /up`** on port `4000`. That endpoint returns `200` only when the
   database is reachable (`503` otherwise) — a real readiness probe. (The image
   also defines a container `HEALTHCHECK`, but `/up` is the meaningful one.)

---

## Step 5 — Run migrations on every deploy

The release bundles a migration entrypoint at `/app/bin/migrate` (runs
`KilnCMS.Release.migrate`, i.e. `Ecto.Migrator` over all repos).

In the application's settings set the **Pre-deployment Command** to:

```
/app/bin/migrate
```

Coolify runs this in a container of the freshly built image **before** swapping
traffic, so a failed migration aborts the deploy instead of bricking the live
version. This creates the `vector` extension and all KilnCMS + Verscienta tables.

---

## Step 6 — Deploy

Click **Deploy**. First build takes a few minutes (it compiles the release and
bundles assets). When it finishes:

- `https://cms.verscienta.com/up` → `OK`
- `https://cms.verscienta.com/admin` → the Ash admin
- `https://cms.verscienta.com/editor` → the content editor

---

## Step 7 — Create the first admin user

`mix` is not present in a release, so seed the admin with a release `rpc` against
the running node. Open the app's **Terminal** in Coolify (or
`Execute Command`) and run:

```sh
ADMIN_EMAIL=you@verscienta.com ADMIN_PASSWORD='a-strong-password' \
/app/bin/kiln_cms rpc '
  email = System.fetch_env!("ADMIN_EMAIL")
  pass  = System.fetch_env!("ADMIN_PASSWORD")
  case KilnCMS.Accounts.get_user_by_email(email, not_found_error?: false, authorize?: false) do
    {:ok, %{} = u} -> IO.puts("already exists: #{u.id}")
    _ ->
      u = Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(pass),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })
      IO.puts("created admin #{u.id}")
  end
'
```

(Role can't be set through self-registration — it always defaults to `:viewer` —
which is why this seeds the user directly, mirroring `priv/repo/seeds.exs`.)

---

## Step 8 — Run the Verscienta import

The importer is a Mix task locally (`mix verscienta.import`), but in a release
run it via `rpc` so it executes inside the fully-booted node. It reads
`DIRECTUS_URL` + `DIRECTUS_TOKEN` (a Directus **read** token).

**Dry run first** (fetch + transform + report counts, no writes):

```sh
DIRECTUS_URL=https://api.verscienta.com DIRECTUS_TOKEN=xxxxx \
/app/bin/kiln_cms rpc 'Verscienta.Importer.run(:directus, dry_run: true) |> IO.inspect()'
```

**Then the real import:**

```sh
DIRECTUS_URL=https://api.verscienta.com DIRECTUS_TOKEN=xxxxx \
/app/bin/kiln_cms rpc 'Verscienta.Importer.run(:directus, []) |> IO.inspect()'
```

It is idempotent (matches by slug / natural key), so it's safe to re-run.
Compare the reported counts against the Directus row counts to confirm a complete
migration. See [`projects/verscienta/README.md`](../projects/verscienta/README.md)
for the field-by-field mapping and the one M2M `fields`-selector caveat to verify
on the first live run.

> The offline JSON fixtures are dev/test only and aren't shipped in the release —
> in production always use the `:directus` source.

---

## Media storage

The default storage adapter writes to a directory **inside the container**
(`priv/uploads`), which is **ephemeral** — uploads vanish on redeploy. For
production choose one:

- **S3-compatible (recommended).** Set `S3_BUCKET` + `S3_PUBLIC_BASE_URL` +
  `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`. For **Cloudflare R2** (the
  natural successor to Verscienta's Cloudflare Images):
  ```
  S3_BUCKET=verscienta-media
  S3_PUBLIC_BASE_URL=https://media.verscienta.com
  S3_ENDPOINT_HOST=<account-id>.r2.cloudflarestorage.com
  AWS_REGION=auto
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
  ```
  (B2/Wasabi/MinIO work the same way via `S3_ENDPOINT_HOST`.)
- **Local with a volume.** If you must use local disk, add a Coolify **Persistent
  Storage** volume mounted at the release's `priv/uploads` path. This is brittle
  across release-version directories — prefer S3/R2.

Note: the Verscienta importer registers **existing** image URLs (the Cloudflare
URLs from Directus) as media items; it does not re-upload bytes, so the storage
adapter choice doesn't affect the import itself — only new uploads made in Kiln.

---

## Email (action required to actually send)

Out of the box the mailer uses a no-op/local adapter, so **auth emails
(confirmation, password reset) and workflow notifications are not delivered** in
production. To enable real delivery, add a Swoosh adapter at compile time in
`config/prod.exs`, e.g. Resend/Mailgun/SMTP:

```elixir
# config/prod.exs
config :kiln_cms, KilnCMS.Mailer,
  adapter: Swoosh.Adapters.Mailgun,
  api_key: System.get_env("MAILGUN_API_KEY"),
  domain: System.get_env("MAILGUN_DOMAIN")
```

(`config :swoosh, api_client: Swoosh.ApiClient.Req` is already set.) Rebuild/
redeploy after adding it, and set the adapter's secrets as env vars.

---

## Optional features

- **Meilisearch.** Optional; Postgres full-text search is the default. Add a
  Meilisearch service (Coolify has a one-click template), set `MEILI_URL` +
  `MEILI_MASTER_KEY`, and redeploy. The index must then be backfilled with
  `mix kiln.meili.reindex` (a Mix task — run it from a dev/CI checkout pointed at
  the same `MEILI_URL`, since `mix` isn't in the release). Note the current task
  indexes Page/Post only; see [`docs/meilisearch.md`](meilisearch.md).
- **Semantic search.** Off by default. Enabling it (`config :kiln_cms,
  KilnCMS.Search, semantic: true`) downloads a Bumblebee model and runs an
  embedding serving — heavyweight; only enable on a sufficiently large instance
  and run a one-time backfill. See [`docs/semantic-search-plan.md`](semantic-search-plan.md).
- **Sentry / OpenTelemetry.** Set the respective env vars (Step 3); both are
  no-ops until configured.

---

## Continuous deploys

- Enable **Auto Deploy** on the application so pushes to the chosen branch
  redeploy (Coolify registers a GitHub webhook). The pre-deployment migration
  runs each time.
- Or trigger from CI: copy the application's **Deploy Webhook** URL + API token
  from Coolify and `curl` it from a GitHub Action after tests pass.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Migration fails: `type "vector" does not exist` / `could not open extension control file` | Database isn't the `pgvector/pgvector` image. Recreate the DB with image `pgvector/pgvector:pg17` (Step 1). |
| App crashes on boot: `DATABASE_URL is missing` / `SECRET_KEY_BASE is missing` / `TOKEN_SIGNING_SECRET` | A required env var (Step 3) is unset. |
| DB connection hangs or TLS handshake error against managed Coolify Postgres | Set `DATABASE_SSL=false` (private-network Postgres doesn't offer TLS). |
| Redirect loop or "connection not secure" | The proxy isn't sending `X-Forwarded-Proto: https`. Ensure the domain is configured in Coolify so Traefik fronts the app (the app forces SSL). |
| LiveView won't connect / "origin not allowed" | `PHX_HOST` doesn't match the public domain. Set it exactly. |
| Health check failing | Point Coolify's check at `GET /up` on port `4000`; confirm the DB is up (it returns 503 when the DB is unreachable). |
| `mix verscienta.import` "command not found" | Releases have no `mix`. Use the `rpc` form in Step 8. |
| Uploaded media disappears after redeploy | Local storage is ephemeral — configure S3/R2 (see Media storage). |
| Emails never arrive | No mailer adapter configured — see Email section. |
