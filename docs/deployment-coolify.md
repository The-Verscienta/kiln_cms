# Deploying KilnCMS to Coolify

**Status:** Phase 9 deployment recipe (issue #54). This is the canonical guide for
running KilnCMS as a Docker OTP release on [Coolify](https://coolify.io), including
a documented **staging** environment alongside production.

KilnCMS ships a self-contained, multi-stage [`Dockerfile`](../Dockerfile) that
builds a Phoenix/Elixir OTP release. Coolify builds that image straight from the
repo, injects configuration via environment variables, runs migrations on deploy,
and (optionally) auto-deploys on every push to `main`.

---

## Overview

The deployment model is **image-per-commit**:

1. Coolify clones the repo and builds the `Dockerfile` (no Nixpacks, no
   buildpack — point Coolify at the Dockerfile build pack).
2. The build stage compiles deps, bundles assets (`mix assets.deploy`), and runs
   `mix release`, producing the `kiln_cms` release under
   `_build/prod/rel/kiln_cms`.
3. The runtime stage is a slim Debian image with `libvips42` (for on-the-fly
   image processing) and the release copied in. It runs as the unprivileged
   `nobody` user.
4. The container's default command is `CMD ["/app/bin/server"]`, which sets
   `PHX_SERVER=true` and boots the endpoint. `MIX_ENV=prod` is baked into the
   image.
5. The app listens on `PORT` (default `4000`, see [`config/runtime.exs`](../config/runtime.exs)),
   binding all interfaces. Coolify's reverse proxy (Traefik) terminates TLS and
   forwards to that port.

Because all secrets and connection strings are read at boot from the
environment (`config/runtime.exs`), the **same image** is promoted across
environments — only the env vars differ between staging and production.

> TLS note: `config/prod.exs` sets `force_ssl: [rewrite_on: [:x_forwarded_proto], ...]`.
> Coolify/Traefik terminates HTTPS and forwards the `X-Forwarded-Proto` header, so
> HTTP requests are transparently redirected to HTTPS. `localhost`/`127.0.0.1` are
> excluded so the in-container healthcheck still works.

---

## Creating the service in Coolify

1. **New Resource → Application → Public/Private Git Repository.** Select the
   KilnCMS repo and the `main` branch.
2. **Build Pack: Dockerfile.** Coolify auto-detects the root `Dockerfile`. Leave
   the build context as the repo root.
3. **Ports:** set the *Ports Exposes* to `4000` (matches the default `PORT`). If
   you override `PORT`, keep the two in sync.
4. **Domain:** assign the production FQDN (e.g. `https://cms.example.com`). This
   must match `PHX_HOST` (below). Coolify provisions a Let's Encrypt cert.
5. Add the **environment variables** from the tables below.
6. Configure the **persistent volumes** (below).
7. **Deploy.**

---

## Environment variables

These are the **only** variables the app actually reads — enumerated from
[`config/runtime.exs`](../config/runtime.exs) (runtime, `:prod` only) and
[`config/prod.exs`](../config/prod.exs). Do not invent others.

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `DATABASE_URL` | Ecto connection URL for the Postgres database. Boot **fails** if missing. | `ecto://kiln:s3cret@postgres:5432/kiln_cms_prod` |
| `SECRET_KEY_BASE` | Signs/encrypts cookies and other secrets. Boot **fails** if missing. Generate with `mix phx.gen.secret`. | `64+ char random string` |
| `TOKEN_SIGNING_SECRET` | Signs Ash auth tokens (`config :kiln_cms, :token_signing_secret`). Boot **fails** if missing. Generate with `mix phx.gen.secret`. | `64+ char random string` |
| `PHX_HOST` | Public hostname used to build URLs (scheme `https`, port `443`). Must match the Coolify domain. Defaults to `example.com` if unset, which breaks generated links — always set it. | `cms.example.com` |

> `PHX_SERVER` is set to `true` automatically by `bin/server` (the container
> `CMD`), so you do **not** need to set it manually in Coolify. Only set it if you
> override the start command.

### Common / recommended

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PORT` | HTTP listen port inside the container. Keep in sync with the Coolify *Ports Exposes*. | `4000` | `4000` |
| `POOL_SIZE` | Ecto DB connection pool size. Size to your Postgres `max_connections` and replica count. | `10` | `10` |
| `ECTO_IPV6` | Set to `true` or `1` to connect to Postgres over IPv6 (adds the `:inet6` socket option). | unset (IPv4) | `true` |
| `DNS_CLUSTER_QUERY` | DNS query used by `dns_cluster` to discover BEAM nodes for clustering. Leave unset for a single node. | unset | `kiln-cms.internal` |

### Object storage (S3-compatible) — optional

Storage defaults to the **local filesystem**. Setting `S3_BUCKET` opts the app
into the S3 adapter (`KilnCMS.Storage.S3`). Works with AWS S3, Cloudflare R2,
Backblaze B2, Wasabi, MinIO, etc. When `S3_BUCKET` is set, the variables marked
**required (if S3)** must also be present or boot fails.

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `S3_BUCKET` | Enables the S3 storage adapter and names the bucket. | opt-in | `kiln-media-prod` |
| `S3_PUBLIC_BASE_URL` | Public base URL media is served from. | required (if S3) | `https://media.example.com` |
| `AWS_ACCESS_KEY_ID` | S3 access key. | required (if S3) | `AKIA…` |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key. | required (if S3) | `…` |
| `AWS_REGION` | Bucket region. R2 uses `auto`; AWS/B2/Wasabi use a real region. | optional (`us-east-1`) | `auto` |
| `S3_ACL` | Per-object canned ACL, only if the bucket needs one (most are public at the bucket level). | optional | `public_read` |
| `S3_ENDPOINT_HOST` | Custom endpoint host for any non-AWS S3 store. Leave unset for AWS. | optional | `<acct>.r2.cloudflarestorage.com` |
| `S3_ENDPOINT_SCHEME` | Scheme for the custom endpoint. | optional (`https://`) | `https://` |
| `S3_ENDPOINT_PORT` | Port for the custom endpoint. | optional (`443`) | `443` |

### Meilisearch (optional, Phase 6)

Search defaults to Postgres full-text. Setting `MEILI_URL` enables the
typo-tolerant Meilisearch backend (`KilnCMS.Search.Meilisearch`). After enabling,
run `mix kiln.meili.reindex` once to backfill. See [meilisearch.md](meilisearch.md).

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `MEILI_URL` | Meilisearch base URL. Enables the backend when set. | opt-in | `http://meilisearch:7700` |
| `MEILI_MASTER_KEY` | Meilisearch master/API key. | with `MEILI_URL` | `…` |
| `MEILI_INDEX` | Index name. | optional (`kiln_content`) | `kiln_content` |

> **Semantic search** (pgvector + local Bumblebee embeddings) is configured in
> application config, not via deployment env vars — it requires the `vector`
> Postgres extension (the `pgvector/pgvector` image provides it). See
> [semantic-search-plan.md](semantic-search-plan.md).

---

## Persistent volumes

KilnCMS itself is stateless; persistent state lives in Postgres and (when S3 is
not used) the local uploads directory.

### Postgres data — always

If you run Postgres as a Coolify resource (recommended), it persists its own
volume automatically. If you run it as a sidecar/standalone container, mount a
named volume at the data directory:

| Mount in container | Purpose |
|--------------------|---------|
| `/var/lib/postgresql/data` | Postgres database files. |

This mirrors the local `docker-compose.yml`, which uses the
`pgvector/pgvector:pg17` image (Postgres 17 + the `vector` extension required for
semantic search) on a `postgres_data` volume.

### Local uploads — only if S3 is **not** configured

When `S3_BUCKET` is unset, uploaded media is written to the local filesystem and
**must** survive redeploys (each deploy is a fresh container). Add a Coolify
**Persistent Storage** volume mounted into the app container:

| Mount in container | Purpose |
|--------------------|---------|
| `/app/priv/static/uploads` | Locally-stored media uploads. |

In Coolify: **Application → Storages → Add → Volume Mount**, set the *Destination
Path* to the mount above. Without this, all uploaded media is lost on every
deploy. If you configure S3, this volume is unnecessary.

---

## Healthcheck

Two complementary mechanisms:

### 1. Container HEALTHCHECK (built into the image)

The [`Dockerfile`](../Dockerfile) defines:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/app/bin/kiln_cms", "rpc", "1 + 1"]
```

This proves the BEAM node is alive and accepting RPCs. Coolify surfaces the
container health status from this directive — no extra config needed.

### 2. HTTP readiness probe — `GET /up`

For the reverse proxy / uptime monitoring, point Coolify's **Health Check** at
the HTTP endpoint exposed by
[`KilnCMSWeb.HealthController`](../lib/kiln_cms_web/controllers/health_controller.ex):

| Path | Behaviour |
|------|-----------|
| `GET /up` | Liveness **and** readiness. Runs `SELECT 1` against `KilnCMS.Repo`. Returns `200 OK` when the DB is reachable, `503 database unavailable` otherwise. |

Configure it in **Application → Health Checks**:

- **Path:** `/up`
- **Port:** `4000` (or your `PORT`)
- **Expected status:** `200`

`/up` is intentionally a combined liveness+readiness probe (it is not ready until
Postgres answers), so a separate `/ready` route is not required. `force_ssl` in
`config/prod.exs` excludes `localhost`/`127.0.0.1`, so the in-container probe is
not redirected to HTTPS.

---

## Database migrations on deploy

Migrations run via the release, not Mix (Mix is not present in the runtime
image). The release ships a `bin/migrate` wrapper:

```sh
# rel/overlays/bin/migrate
exec ./kiln_cms eval KilnCMS.Release.migrate
```

which calls [`KilnCMS.Release.migrate/0`](../lib/kiln_cms/release.ex), running all
pending migrations (`Ecto.Migrator.run(repo, :up, all: true)`) for every repo in
`:ecto_repos`.

**Run it as a Coolify pre/post-deploy command** so the schema is migrated before
new traffic is served:

```sh
/app/bin/migrate
# equivalently:
/app/bin/kiln_cms eval KilnCMS.Release.migrate
```

In Coolify, set this under **Application → Pre/Post Deployment Command** (run it
in the app container). For zero-downtime, prefer backward-compatible migrations.

Rollback of a single migration is also available:

```sh
/app/bin/kiln_cms eval 'KilnCMS.Release.rollback(KilnCMS.Repo, <version>)'
```

See [releases-and-migrations.md](releases-and-migrations.md) for the full
release/migration reference, including AshOban trigger considerations.

---

## Staging environment

Staging is a **separate Coolify application** built from the same repo and
`Dockerfile`, so the only differences are configuration and the Git branch it
tracks.

| Aspect | Production | Staging |
|--------|-----------|---------|
| Coolify app | `kiln-cms` | `kiln-cms-staging` (separate service) |
| Tracked branch | `main` | `staging` (or `main` with manual deploys) |
| Domain / `PHX_HOST` | `cms.example.com` | `staging.cms.example.com` |
| Database | production Postgres | **separate** staging Postgres + `DATABASE_URL` |
| Object storage | prod `S3_BUCKET` (or volume) | staging bucket, or local volume |
| Meilisearch | prod instance | staging instance (or disabled) |
| Secrets | unique `SECRET_KEY_BASE` / `TOKEN_SIGNING_SECRET` | **different** secrets |
| `POOL_SIZE` | sized for prod load | smaller (e.g. `5`) |

Key rules:

- **Never share the database.** Staging gets its own `DATABASE_URL` pointing at a
  separate Postgres so test data and migrations cannot touch production.
- **Distinct secrets.** Generate fresh `SECRET_KEY_BASE` and
  `TOKEN_SIGNING_SECRET` for staging; do not reuse prod values.
- **`PHX_HOST`** must be the staging domain so links and TLS resolve correctly.
- Run `/app/bin/migrate` on staging deploys exactly as in production — staging is
  where you validate migrations before they reach prod.

Create staging by duplicating the production resource (or **New Resource →
Application**), pointing it at the `staging` branch, and supplying the
staging-specific env vars and volumes.

---

## Auto-deploy, webhooks, and rollback

### Auto-deploy on push

Coolify can rebuild and redeploy on every push to the tracked branch:

1. **Application → enable Auto Deploy.**
2. Connect the repo via a **GitHub App** (preferred — Coolify manages the webhook
   for you), **or** add Coolify's **deploy webhook URL** to the repo's
   *Settings → Webhooks* with a `push` event and the Coolify secret token.
3. Production tracks `main`; staging tracks `staging`. A push triggers: build →
   (pre-deploy) `bin/migrate` → start new container → health check on `/up` →
   cut over.

For gated releases, leave Auto Deploy **off** on production and deploy manually
(or only auto-deploy staging), promoting the same commit to prod after staging
validation.

### Rollback

Coolify keeps previous images/deployments. To roll back:

- **Application → Deployments**, pick the last-known-good deployment and
  **Redeploy / Rollback** to it. Because the image is immutable per commit, this
  restores the exact prior build.
- **Database migrations do not auto-roll-back.** If a bad deploy ran a migration,
  reverting the image is not enough — roll the schema back explicitly with
  `KilnCMS.Release.rollback/2` (above) or a forward fix-up migration. Prefer
  backward-compatible migrations precisely so an image rollback alone is safe.

---

## Related docs

- [releases-and-migrations.md](releases-and-migrations.md) — release build &
  migration internals.
- [meilisearch.md](meilisearch.md) — optional search backend.
- [semantic-search-plan.md](semantic-search-plan.md) — pgvector/embeddings.
- [observability.md](observability.md) — telemetry & LiveDashboard in prod.
