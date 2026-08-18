# Deploying Kiln

How to run Kiln in production, from nothing: the environment it needs, the
image, what happens at boot, which health endpoint to point what at, how to get
the first admin, and where backups and the optional infrastructure fit. This is
the standing guide; the checklists that used to be the only deploy material
are kept under *Audits & release checklists*: `deploy-p2.md` and
`deploy-p3.md` are rehearsal notes for specific feature batches (history), and
`deploy-staging.md` / `deploy-write-visual-editing.md` are still the operator
checklists for turning those two features on — all four assume you already
have a running Kiln, which is what this guide gets you to.

Kiln is **one OTP release plus Postgres**. It serves its own public site and
the editor console, runs background jobs on Oban (Postgres-backed — no broker),
and caches in-process — so a working deployment is a container and a database.
Everything else in this guide is optional.

**Where the other operations guides fit:**

| Question | Guide |
|----------|-------|
| What does every environment variable do? | [`environment-variables.md`](environment-variables.md) — the canonical, per-variable table. This guide names only the ones a deploy *needs*. |
| What must be backed up, and how do I restore? | [`backups.md`](backups.md) |
| How do I cut and stamp a release, and move a project to it? | [`releasing.md`](releasing.md) |
| Which health endpoint feeds which alert? | [`observability.md`](observability.md) |
| Pool sizing, Oban queues, load testing? | [`performance.md`](performance.md) |
| A throwaway copy of production for rehearsal? | [`staging-environments.md`](staging-environments.md) |
| Media on object storage with a CDN? | [`media-pipeline.md`](media-pipeline.md#production-storage--cdn) |
| Typo-tolerant search? | [`meilisearch.md`](meilisearch.md) |

## The short version

1. Build the image from the [`Dockerfile`](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile) (or pull one you
   built in CI).
2. Provide Postgres 17 with the `vector` extension available — the
   `pgvector/pgvector:pg17` image is a drop-in.
3. Set `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, `PHX_HOST`,
   and `PHX_SERVER=true`.
4. Start the container. It runs pending migrations, then serves on `PORT`
   (default `4000`).
5. Put a TLS-terminating reverse proxy in front on 443, and set
   `TRUSTED_PROXIES` so the app sees real client addresses.
6. Register the first user at `/register`, then promote it to admin from a
   release shell (below).
7. Point your restart-triggering healthcheck at `/live` and your load balancer
   or uptime monitor at `/up`.
8. Schedule [`scripts/backup.sh`](../scripts/backup.sh) before you have
   anything to lose.

[`docker-compose.prod.yml`](../docker-compose.prod.yml) at the repository
root does steps 1–4 as a reference; the rest of this document explains each
step and the decisions behind it.

## Required environment

Three variables **raise on boot** when missing; two more are effectively
required because their defaults are wrong for any real deployment. Every
variable is documented in full in
[`environment-variables.md`](environment-variables.md#required-production) —
this is the deploy-time summary.

| Variable | What it is | How to produce it |
|----------|------------|-------------------|
| `DATABASE_URL` | Postgres connection string, `ecto://USER:PASS@HOST/DATABASE`. **Raises if missing.** | From your database provider. TLS is on by default (`DATABASE_SSL`, `DATABASE_SSL_CACERTFILE` — see [database TLS](#database-tls)). |
| `SECRET_KEY_BASE` | Signs and encrypts session cookies and other secrets. **Raises if missing.** | `mix phx.gen.secret` (any 64+ random bytes). **Back it up with the database** — DKIM keys and other encrypted-at-rest values are unreadable without the same one, so restoring a dump under a new key loses them ([backups.md](backups.md#what-must-be-backed-up)). |
| `TOKEN_SIGNING_SECRET` | Signs authentication tokens (AshAuthentication). **Raises if missing.** | `mix phx.gen.secret`. Rotating it signs every user out. |
| `PHX_HOST` | The public hostname — used to generate absolute URLs (links, emails, feeds) *and* to validate the Origin of LiveView and channel sockets. Defaults to `example.com`, so with it unset links are wrong and **the editor's live sockets refuse to connect**. | A bare hostname (`cms.example.com`). A `https://` prefix or trailing `/` is stripped, but don't rely on it. Serving on more than one host? Add the extras to `CHECK_ORIGINS`. |
| `PHX_SERVER` | Tells the release to start the HTTP listener. Without it the release boots, runs migrations, and answers `bin/kiln_cms rpc` — and serves nothing. | The image's boot command runs `bin/server`, which sets `PHX_SERVER=true` for you. Set it yourself if you invoke `bin/kiln_cms start` directly. Off-spellings (`false`/`0`/`no`/`off`) keep it off; anything else, including blank, starts it. |

Two more that a real deployment almost always wants:

- **`PORT`** (default `4000`) — the port the app listens on. The public URL is
  hardcoded to `https`/443; the expected topology is a TLS-terminating proxy on
  443 forwarding to `PORT`.
- **`TRUSTED_PROXIES`** — comma-separated CIDRs of the reverse proxy in front
  (Coolify, Traefik, nginx, a cloud load balancer). Unset behind a proxy, every
  request looks like it came from the proxy, so every rate-limit bucket
  collapses into one counter for the entire internet and the per-IP
  brute-force protection on `/sign-in` stops being per-IP. Nothing errors —
  the app logs a warning once. Leave it unset **only** when the app is
  internet-facing directly. Details and the private-range caveat:
  [`environment-variables.md`](environment-variables.md#optional--server--networking).

Generate the two secrets once, store them in your secret manager, and never
regenerate `SECRET_KEY_BASE` on an existing deployment.

```bash
mix phx.gen.secret   # SECRET_KEY_BASE
mix phx.gen.secret   # TOKEN_SIGNING_SECRET
```

(No checkout to hand? `openssl rand -base64 64 | tr -d '\n'` produces an
equivalent value.)

### Database TLS

The Postgres connection uses `ssl: true` by default. Set `DATABASE_SSL=false`
only for a provider that genuinely cannot offer TLS — a Postgres container on
the same private compose network is the usual case, and the reference compose
file does exactly that. Point `DATABASE_SSL_CACERTFILE` at the provider's CA
bundle to verify the server certificate; without it the connection is
encrypted but skips peer verification.

## Building the image

The [`Dockerfile`](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile) is a multi-stage build: an `hexpm/elixir`
builder compiles the release (with `mix assets.deploy` — there is no separate
front-end build to deploy; the app *is* the site), and a slim Debian runner
carries only the release plus the native libraries it shells out to — libvips
for image processing, `qpdf` for PDF metadata stripping, `postgresql-client-17`
so in-app backups can run `pg_dump`. Nothing in the runner is optional to the
build, and the versions of Elixir/OTP restate `.tool-versions` (the source of
truth; `mix kiln.toolchain.check` fails when they drift).

Build with the commit and date stamped, so a running instance can say what it
is on `/editor/system`:

```bash
docker build \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t kiln:local .
```

Both build args are optional — an image without them boots and reports its
version, it just can't name the commit. See
[`releasing.md`](releasing.md#build-stamping).

Two things about the build worth knowing before you size a build host:

- **Peak RAM is `mix deps.compile`**, not the app compile. The Ash ecosystem
  plus the Nx/Axon/Bumblebee ML stack compiles in one BEAM; the Dockerfile
  splits the ML deps into their own `RUN` and caps the build BEAM to two
  schedulers so a small host isn't OOM-killed. A 2 GB build host is
  marginal; 4 GB is comfortable.
- **The runner is deliberately a newer Debian than the builder** (trixie vs
  bookworm) because bookworm's `qpdf` predates the options PDF stripping
  needs. Building on the older suite and running on the newer is the safe
  direction; don't "fix" the mismatch.

The build is the same wherever it runs — a `docker build` on your laptop, a
CI job, or a PaaS that builds from the Dockerfile (Coolify does exactly that
on Redeploy). Nothing about the image is host-specific: every deployment
difference is environment.

## What happens at boot

The image's `CMD` is:

```sh
/app/bin/migrate && /app/bin/server
```

1. **`bin/migrate`** runs `KilnCMS.Release.migrate/0` — every pending Ecto
   migration, up. It runs **unconditionally on every boot**, so there is no
   separate "run migrations" step to forget on a fresh target or after a failed
   build (a platform's pre-deploy hook typically only runs inside an
   already-running container, which is a no-op precisely when you need it).
   `Ecto.Migrator` serialises concurrent runs with a lock on
   `schema_migrations` (ecto_sql's default `:table_lock`), so this stays safe
   when several replicas start at once: one migrates, the others wait, then
   all serve.
2. **`bin/server`** sets `PHX_SERVER=true` and starts the release. The Ash +
   Nx/Axon/Bumblebee stack is not fast to cold-boot; the image's healthcheck
   allows a generous start period for it (below).

A boot failure is loud. The three required variables raise with a message
naming the variable; a `:prod` release with `dev_routes` enabled refuses to
boot (it would expose `/admin`, LiveDashboard and the mailbox unauthenticated);
`S3_BUCKET` without `S3_PUBLIC_BASE_URL` raises; and so on. If the container
exits immediately, `docker logs` (or the platform's deploy log) has the reason
on the last lines.

Rolling back a migration is a manual step and never automatic, and because
every boot re-runs `bin/migrate`, the order matters:

1. **Stop the app** (`docker compose stop app`). A running or restarting
   container would re-apply the migration you are about to undo.
2. **Run the rollback from the image that contains the migration** — the
   *new* one, not the one you are rolling back to. `Ecto.Migrator` only sees
   migration files present in the image, so an older image would silently
   skip the newer migration and report success:

   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env.prod \
     run --rm --no-deps app /app/bin/kiln_cms eval \
     'KilnCMS.Release.rollback(KilnCMS.Repo, <version>)'
   ```

   `<version>` is the timestamp prefix of the migration to undo (the file name
   in `priv/repo/migrations/`), and `to:` is **inclusive**: everything at or
   after that version is rolled back, so name the oldest one you want undone,
   not the one you want to return to.
3. **Then** switch the image tag back and start.

Read the release's `### Upgrading` notes in [`CHANGELOG.md`](../CHANGELOG.md)
before an upgrade — that section says whether a migration rewrites or drops
data, which is what decides whether rolling the image back is enough.

## Health endpoints — `/live` vs `/up`

Kiln has three probes, and pointing the wrong one at the wrong consumer is the
one deploy mistake that makes a bad day worse:

| Endpoint | Answers | Checks the database? | Point this at |
|----------|---------|----------------------|---------------|
| `GET /live` | `200 OK` iff the endpoint is serving HTTP; connection refused otherwise | **No** | Anything that may **restart** the container on failure: Kubernetes/Swarm liveness, systemd watchdogs, an autoheal sidecar. The image's `HEALTHCHECK` (already wired) probes it — see the note below on what does and does not act on that. |
| `GET /up` | `200 OK` when the database is also reachable, else `503 database unavailable` | Yes | Anything that decides whether to **route traffic here**: a load balancer's backend check, an uptime monitor, Kubernetes readiness. |
| `GET /ready` | JSON with `db` and Oban queue depth; 200/503 like `/up` | Yes | Monitoring and alerting sinks — [`observability.md`](observability.md) has the alert rules that read it. |

Why two: `/up` returning 503 on a database outage is exactly right for a load
balancer (stop sending users to a node that can't serve them) and exactly
wrong for a restart trigger — restarting the app on a database outage it
cannot fix only restart-storms every replica at the moment the platform is
already degraded (#816). `/live` is answered by an endpoint plug *ahead of*
tenant resolution (which itself reads the database), so it stays a pure "is
this process serving" signal even with Postgres down.

Two things the image already handles, and that you must preserve if you
change either: the healthcheck probes `http://127.0.0.1:${PORT}/live`, and
that works because `config/prod.exs`'s `force_ssl` **excludes host
`127.0.0.1`** — without the exclusion `Plug.SSL` answers a 301 to https, and
`curl -f` treats a 3xx as success, so the check would pass without ever
seeing a 200. And the healthcheck asserts the container is *serving HTTP*, not
merely that the BEAM is alive: a container that booted without `PHX_SERVER`
runs migrations, answers rpc, serves nothing, and used to report healthy
forever (#647).

The `HEALTHCHECK` in the Dockerfile — `interval=30s timeout=5s
start-period=60s retries=3` — is what a plain `docker run` or Compose uses.
**Plain Docker and Compose only mark the container `unhealthy`; nothing
restarts it** — `restart:` policies react to the process exiting, not to
health. If you want a wedged-but-alive node restarted on Compose, run an
autoheal sidecar (e.g. `willfarrell/autoheal`, which watches that status) or
use an orchestrator; Kubernetes and Swarm act on their own probes. Coolify
uses the check to judge a deploy and to show status. Platforms with their own
health-check UI ignore the Dockerfile values; set the same path and a start
period of at least a minute there.

## First admin — bootstrap

Self-registration always lands on the `:viewer` role, so sign-up can never
escalate privileges, and there is no seed script in a production release. The
first admin is made by promoting a registered user from a release shell with
authorization bypassed — once, and only for the first one.

1. Register your own account at `https://<PHX_HOST>/register`. (Want
   invite-only sign-up afterwards? `config :kiln_cms, :registration_enabled,
   false` is **compile-time** — set it in `config/config.exs` or a project
   overlay and rebuild the image; there is no environment variable for it.)
2. Attach to the **running** node and promote it:

   ```bash
   docker exec -it <container> /app/bin/kiln_cms remote
   ```

   ```elixir
   alias KilnCMS.Accounts

   user = Accounts.get_user_by_email!("you@example.com", authorize?: false)
   Accounts.manage_user_access!(user, %{role: :admin}, authorize?: false)
   ```

   Or one-shot, without a shell:

   ```bash
   docker exec -it <container> /app/bin/kiln_cms rpc 'KilnCMS.Accounts.manage_user_access!(KilnCMS.Accounts.get_user_by_email!("you@example.com", authorize?: false), %{role: :admin}, authorize?: false)'
   ```

   Both `remote` and `rpc` connect to the live, fully-started app — that is
   why they work. `bin/kiln_cms eval` boots a *separate* instance without the
   repo started, so don't use it for this. Use straight ASCII quotes.

3. Sign in; promote everyone else through the editor UI as that admin — no
   `authorize?: false` needed again.

The same section in the [README](../README.md#creating-an-admin-user) covers
the development seed script and the platform variants (`fly ssh console` and
the like).

## Reverse proxy and TLS

The app listens on plain HTTP on `PORT` and expects a TLS-terminating proxy in
front on 443 — Kiln does not terminate TLS itself, and `force_ssl` redirects
plain-http requests on any host other than `localhost`/`127.0.0.1` to https.
Whatever the proxy — Coolify's Traefik, nginx, Caddy, a cloud load balancer —
it must:

- send **`X-Forwarded-Proto: https`** on every request. `config/prod.exs`
  runs `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so a request the
  proxy forwards as plain HTTP *without* that header is answered with a 301
  to `https://…` — which the proxy terminates and forwards again, forever
  (nginx does not add the header by default; Caddy and Traefik do);
- forward `X-Forwarded-For`, and name the proxy in `TRUSTED_PROXIES` (above),
  or rate limiting keys on the proxy's address;
- pass WebSocket upgrades on `/live`, `/ws/*` — the editor is LiveView, and
  collaboration, GraphQL subscriptions and the visual-editing bridge are
  channels;
- send the request `Host` through unchanged — `PHX_HOST` and the origin check
  are validated against it, and multi-tenant sites are resolved from it.

Two symptoms and their usual causes: the browser reports **too many
redirects** on every page → the proxy is not sending `X-Forwarded-Proto`;
the editor loads but every LiveView shows "disconnected" or the page reloads
in a loop → `PHX_HOST` (wrong host, or a scheme baked in) or the proxy not
upgrading WebSockets.

## Backups

Do this before the first real content, not after the first incident.
[`backups.md`](backups.md) is the full runbook — what constitutes a
deployment's state (the database, media if on the Local adapter, and the
environment including `SECRET_KEY_BASE`), the nightly cron using
[`scripts/backup.sh`](../scripts/backup.sh), retention, off-site copy, and the
**restore runbook** from total loss to serving. Two things it insists on that
are worth repeating here:

- **`SECRET_KEY_BASE` is part of the backup.** A database restored under a
  different key boots and serves, but every database-stored key
  (`KilnCMS.Keys.Vault` — the DKIM private key among them) is unrecoverable,
  and every session and token is invalidated.
- **The client tools must match the server's major version.** The image ships
  `postgresql-client-17`; the in-app Backups page (`/editor/backups`) uses the
  same tools and the same variables (`BACKUP_DIR`, `MEDIA_DIR`, …) as the cron
  script — two front doors to one backup directory. Bump the client pin in the
  Dockerfile alongside any Postgres major upgrade.

In the reference compose stack both doors are wired: Postgres is published on
the host loopback (`127.0.0.1:5432`) so the cron in `backups.md` runs on the
host against `postgres://kiln:…@127.0.0.1:5432/kiln_prod`, and the app has a
`backups` volume mounted at `BACKUP_DIR` (`/var/backups/kiln`) for the in-app
page. That volume is created root-owned while the app runs as `nobody`, so
hand it over once — the compose file's header has the one-liner. On any other
platform, give `BACKUP_DIR` a persistent, writable mount or the in-app page
will report available and every job will fail at run time.

## Optional infrastructure

Nothing beyond Postgres is required. Each of these is opted into by setting
its variables, and the reference compose file starts the matching service
behind a profile so you can enable exactly what you turned on:

| Service | Enable in the app by | Compose profile | Notes |
|---------|----------------------|-----------------|-------|
| **Object storage** (S3, R2, B2, Wasabi, MinIO) | `S3_BUCKET` + `S3_PUBLIC_BASE_URL` + `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`; `S3_ENDPOINT_HOST` for anything non-AWS | `storage` (MinIO) | **Recommended for any Docker deployment.** The Local adapter writes under the release's own `priv/uploads` (`/app/lib/kiln_cms-<version>/priv/uploads` in the image), a path that changes with every version bump, so persisting it across image upgrades means re-mounting a volume per release. Object storage sidesteps that and lets a CDN serve the bytes. [`media-pipeline.md`](media-pipeline.md#production-storage--cdn) is the guide; the CDN hostname goes in `CSP_IMG_SRC`. |
| **Meilisearch** (typo-tolerant, faceted search) | `MEILI_URL` (+ `MEILI_MASTER_KEY`, `MEILI_INDEX`) — then backfill the index once from the running release: `bin/kiln_cms rpc 'KilnCMS.Search.Meilisearch.reindex_all()'` (`mix kiln.meili.reindex` is the same thing from a checkout) | `search` | Postgres full-text search is the default and stays available. Run Meilisearch with `MEILI_ENV=production` and a real master key (16+ bytes) — it refuses to start otherwise. [`meilisearch.md`](meilisearch.md). |
| **Dragonfly / Redis** (shared cache) | Nothing yet — see note | `cache` | Kiln's caches are in-process by decision (D2: minimal ops). **Nothing in the app reads a Redis/Dragonfly URL** — a shared tier-2 cache is a documented intention (`KilnCMS.Firing.Cache`), not a setting you can point at this service. Cross-node cache busts already travel over native PubSub. The profile is kept for parity with the dev compose file; on a single node it does nothing for you. Don't run it expecting a speedup. |

Multi-node itself needs no broker: Phoenix PubSub is native, Oban is
Postgres-backed, and node discovery is `DNS_CLUSTER_QUERY`. Two things a
cluster *does* need: a shared media backend (object storage — Local uploads on
one node are invisible to the others), and **long node names**. The release
ships no `rel/env.sh.eex`, so it starts with `mix release`'s defaults
(`RELEASE_DISTRIBUTION=sname`), and a short-named node cannot connect to the
`kiln_cms@<ip>` names DNSCluster resolves — set `RELEASE_DISTRIBUTION=name`
and `RELEASE_NODE=kiln_cms@<this node's IP>` in each node's environment (the
snippet Phoenix's Fly guide generates), or the nodes stay silently
disconnected and cache busts never cross them.

## The reference `docker-compose.prod.yml`

[`docker-compose.prod.yml`](../docker-compose.prod.yml) runs the app and a
pgvector Postgres, with MinIO, Meilisearch and Dragonfly behind the profiles
above. It is a starting point, not a platform: it does not terminate TLS,
does not schedule backups (it only makes them possible — above), and keeps
Postgres on the compose network with TLS off because the traffic never leaves
the host. It needs the Docker Compose v2 plugin (2.20 or newer); the project
is namespaced `kiln-prod` so it never shares volumes with the dev
`docker-compose.yml` on the same machine.

```bash
# .env.prod (at the repo root): SECRET_KEY_BASE, TOKEN_SIGNING_SECRET, PHX_HOST,
# POSTGRES_PASSWORD (URL-safe: `openssl rand -hex 32`), TRUSTED_PROXIES, plus
# any optional variable from environment-variables.md
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
docker compose -f docker-compose.prod.yml --env-file .env.prod --profile storage up -d   # + MinIO
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f app
```

Configuration is one file, `.env.prod`, used two ways: `--env-file`
interpolates the compose file (image tag, ports, the required secrets — it
**fails fast**, naming the variable, if `SECRET_KEY_BASE`,
`TOKEN_SIGNING_SECRET`, `PHX_HOST` or `POSTGRES_PASSWORD` are unset), and the
app service loads the same file as its `env_file`, so any optional variable
you add there reaches the container. Four things to know about that file:

- **It must be the same file both times.** The `env_file` path is resolved
  from the repository root, not from wherever you pass `--env-file`; keep the
  file elsewhere and you must also set `KILN_ENV_FILE` to that path. A
  missing `env_file` is an error, never a silent "no optional variables".
- **`POSTGRES_PASSWORD` is spliced into `DATABASE_URL`**, so it must be
  URL-safe — `openssl rand -hex 32`. Base64 output (`mix phx.gen.secret`,
  `openssl rand -base64`) contains `/` more often than not, and `/ # ? %`
  break or silently corrupt the URL while Postgres itself accepts them.
- **Compose parses the file, in both roles**: `$VAR` inside a value is
  expanded (write `$$` for a literal `$`, or single-quote the value), quotes
  are stripped, ` #` starts a comment. A secret with a `$` in it would
  otherwise be silently shortened.
- **Optional variables are passed through, never listed with empty
  defaults.** Several are **presence-checked** and treat an empty string as
  "set" (`S3_BUCKET=` would switch the storage adapter to S3 with no bucket;
  `MEILI_URL=` would enable a backend with no server) — absent stays absent.
  The exceptions are the values the stack pins under `environment:`:
  `PHX_SERVER`, `PORT`, `POOL_SIZE`, `BACKUP_DIR`. `DATABASE_URL` and
  `DATABASE_SSL` take your `.env.prod` value first, so **an external or
  managed Postgres is `DATABASE_URL=… DATABASE_SSL=true` in `.env.prod`**
  (plus `DATABASE_SSL_CACERTFILE` if you have the CA) and `up -d --no-deps
  app` to leave the bundled `postgres` service alone.

The file's header enumerates everything it reads; every name is a row in
[`environment-variables.md`](environment-variables.md).

Put a proxy on the same host in front of `127.0.0.1:4000` — the app is
published on loopback only, on purpose. Caddy is the least configuration:

```caddyfile
cms.example.com {
    reverse_proxy 127.0.0.1:4000
}
```

Caddy sends `X-Forwarded-For` and `X-Forwarded-Proto` and upgrades WebSockets
by default; then set `TRUSTED_PROXIES` to the compose network's range
(`docker network inspect kiln-prod_default` shows it — the host's loopback
connections arrive from that bridge). Do **not**
re-publish the app on `0.0.0.0` to reach it from a proxy on another machine:
a Docker-published port bypasses the host firewall, and with
`TRUSTED_PROXIES` set the app honours `X-Forwarded-For` from whoever reaches
it — bind a private interface instead, or run the proxy inside the compose
network.

## Platform notes

**Coolify (the project's own production).** Production for this repository is
a single VPS running Coolify, deploying by a manual **Redeploy** that builds
the Dockerfile and starts the container: migrations run on boot, assets build
at image build, and the health check is `/live`. Everything above applies as
is; environment goes in Coolify's application settings, and Coolify's Traefik
is the proxy — set `TRUSTED_PROXIES` to its docker network range. The
per-release checklists under *Audits & release checklists* were written
against this target and describe, per feature batch, what to verify after a
Redeploy — nothing there changes how to deploy.

**Kubernetes / any orchestrator.** Liveness probe `/live`, readiness probe
`/up`, and a **`startupProbe`** on `/live` with a generous
`failureThreshold × periodSeconds` (minutes, not seconds) rather than a fixed
`initialDelaySeconds`: `/live` only answers once `bin/migrate` has finished,
so a long data-rewriting migration under a 60-second liveness window gets the
pod killed mid-migration and never converges. Several replicas may start
together; the migration lock handles it. Use object storage for media, and
long node names for clustering (above).

**Fly.io / Render / other Dockerfile PaaS.** Build from the Dockerfile; set
the required variables as secrets; internal port `PORT` (4000); health check
path `/up` for routing (the platform is the load balancer here) — and if the
platform *restarts* on health failure, `/live`. `fly ssh console` gets you a
shell for the first-admin `bin/kiln_cms remote`.

## Production hardening checklist

The [README's checklist](../README.md#production-hardening-checklist) is the
canonical list; in deploy order:

- `dev_routes` off — it is; a `:prod` release refuses to boot otherwise.
- Database TLS on (default), with `DATABASE_SSL_CACERTFILE` when the provider
  publishes a CA bundle.
- `TRUSTED_PROXIES` set behind a proxy.
- `PHX_HOST` correct; `CHECK_ORIGINS` for any additional hostnames.
- `CORS_ORIGINS` unset unless a separate front end reads the headless API —
  the write API and the visual-editing bridge are inert cross-origin until it
  is set ([`deploy-write-visual-editing.md`](deploy-write-visual-editing.md)
  is the checklist for turning that on).
- Registration closed once the first admin exists, unless the site is meant
  to be open — `config :kiln_cms, :registration_enabled, false` is compile-time
  config, so this is a rebuild, not an env change.
- Backups scheduled and a restore rehearsed ([`backups.md`](backups.md#restore-drill-quarterly)).
- Error tracking / tracing (`SENTRY_DSN`, OpenTelemetry) — env-gated no-ops
  until set ([`observability.md`](observability.md)).

## Upgrading a deployment

For a running instance an upgrade is: read the release's `### Upgrading`
section in [`CHANGELOG.md`](../CHANGELOG.md), rebuild or pull the new image,
restart. Migrations run on boot; nothing else is automatic, and the changelog
section is where a release says if it needs more (a new required variable, a
reindex, a backfill). Downstream projects that pin Kiln as a submodule move
the pin with `mix kiln.update`, which prints that section before it does —
[`releasing.md`](releasing.md#updating-a-project-to-a-release).
