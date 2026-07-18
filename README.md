# KilnCMS

A modern, high-performance headless + traditional CMS built on the **STAPLE stack**
(Phoenix · Tailwind · LiveView · Elixir) with the **Ash Framework** at its core. Client
interactivity is handled by LiveView + colocated JS hooks; Alpine.js (the *A* in STAPLE)
is optional and not currently wired in.

See [`KilnCMS_Project_Plan.md`](KilnCMS_Project_Plan.md) for the full vision, architecture, and
the resolved architectural decisions (D1–D8).

## Stack

| Concern | Choice |
|---|---|
| Domain modeling | **Ash** (`ash`, `ash_postgres`, `ash_phoenix`) |
| Admin | **AshAdmin** at `/admin` (dev/CRUD tool, not the editor UI) |
| Headless APIs | **AshJsonApi** (`/api/json`) + **AshGraphql** (`/gql`) |
| Versioning | **AshPaperTrail** (full history on Page/Post) |
| Workflow | **AshStateMachine** (draft → in_review → published → archived) |
| Real-time | Native **`Phoenix.PubSub`** — no external broker (decision D1) |
| Database | PostgreSQL via AshPostgres |
| Optional infra | Dragonfly / Meilisearch / MinIO behind Compose profiles (D2) |

## Content model

Resources live in `lib/kiln_cms/cms/`:

- **`Page`** / **`Post`** — strongly-modeled content carrying an **embedded block tree**
  (`blocks` is an array of the embedded `Block` resource — decision **D3**, not a separate
  table). Both have paper-trail history and the publishing state machine.
- **`Block`** — an embedded resource with a `type` (`:rich_text`, `:heading`, `:image`,
  `:quote`, `:embed`, `:divider`, `:columns`, `:custom`), `content`, a flexible `data` map,
  `order`, and nested `children` for composable slices.
- **`MediaItem`** — media-library metadata (binary lives in object storage).

## Getting started

Prerequisites: Elixir 1.18+ / OTP 27+, Docker (for Postgres).

```bash
# 1. Start Postgres (only required service; optional infra via profiles)
docker compose up -d postgres
#    docker compose --profile cache   up -d   # + Dragonfly
#    docker compose --profile search  up -d   # + Meilisearch
#    docker compose --profile storage up -d   # + MinIO

# 2. Install deps, create DB, run Ash migrations
mix setup            # deps.get + ash.setup + assets.setup
#   (or: mix deps.get && mix ash.setup && mix assets.setup)

# 3. Run
mix phx.server
```

Then visit:

- App: <http://localhost:4000>
- Admin: <http://localhost:4000/admin>
- GraphQL playground: <http://localhost:4000/gql/playground>
- JSON:API Swagger UI: <http://localhost:4000/api/json/swaggerui>

## Creating an admin user

The `role` attribute (`:admin`/`:editor`/`:viewer`) can **not** be set through
self-registration — `register_with_password` always lands on `:viewer` so signup
can never escalate privileges. Admins are seeded directly or promoted by an
existing admin.

**Development.** The seed script ([`priv/repo/seeds.exs`](priv/repo/seeds.exs))
creates a pre-confirmed admin and editor. It runs automatically as part of
`mix setup`, or on its own:

```bash
mix run priv/repo/seeds.exs
```

Default dev credentials are `admin@kiln.test` / `kilnadmin123`. Override them
(this is how you bootstrap a real admin) with env vars — the script is
idempotent, so it's safe to re-run:

```bash
ADMIN_EMAIL=you@example.com ADMIN_PASSWORD='a-strong-password' \
  mix run priv/repo/seeds.exs
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `ADMIN_EMAIL` | `admin@kiln.test` | Email for the seeded admin account. |
| `ADMIN_PASSWORD` | `kilnadmin123` | Password for the seeded admin account. |
| `EDITOR_EMAIL` | `editor@kiln.test` | Email for the seeded editor account. |
| `EDITOR_PASSWORD` | `kilneditor123` | Password for the seeded editor account. |

**Production — bootstrap the first admin.** A production OTP release has no
`iex`/`mix` — drive it through the generated `bin/kiln_cms` scripts (in Docker
they live at `/app/bin/kiln_cms`). With no existing admin to authorize the
promotion, run the admin-only `:manage_access` action with `authorize?: false`.

Attach an IEx shell to the **running** node (`remote` connects to the live,
fully-started app — repo included):

```bash
/app/bin/kiln_cms remote
```

```elixir
alias KilnCMS.Accounts

user = Accounts.get_user_by_email!("you@example.com", authorize?: false)
Accounts.manage_user_access!(user, %{role: :admin}, authorize?: false)
```

Or run it one-shot without an interactive shell via `rpc` (executes on the live
node, prints the result, exits):

```bash
/app/bin/kiln_cms rpc 'KilnCMS.Accounts.manage_user_access!(KilnCMS.Accounts.get_user_by_email!("you@example.com", authorize?: false), %{role: :admin}, authorize?: false)'
```

> Use **straight** ASCII quotes (`"you@example.com"`) — smart/curly quotes
> (`“ ”`) are a syntax error in Elixir.

Both `remote` and `rpc` need a running node — they connect to the live release.
On Docker, `docker exec -it <container> /app/bin/kiln_cms remote`; on Fly.io,
`fly ssh console` then the same command. (`bin/kiln_cms eval` boots a separate,
non-serving instance and does **not** auto-start the repo, so prefer `remote`/`rpc`
for this.)

Once one admin exists, promote further users through the editor UI / API as that
admin actor — no `authorize?: false` needed.

## Delivery

KilnCMS serves its **public website itself**, with Phoenix LiveView and
controllers — `KilnCMSWeb.ContentController` renders pages (`/<slug>`), the blog
(`/blog`, `/blog/<slug>`), on-site search (`/search`), and locale-prefixed
variants (`/fr/...`) straight from published content. There is no separate
frontend build to deploy; the app is the site.

The same content is also **world-readable over headless APIs** for external or
mobile consumers: `GET /api/content/:type/:slug` (the v2 fired-artifact API —
structured `json`, `json_ld`, or pre-rendered `web` HTML), `GET /sitemap.xml`
for enumeration, `POST /gql` (GraphQL), and the JSON:API at `/api/json`. See
[`docs/headless-consumer-guide.md`](docs/headless-consumer-guide.md) for which
surface to use, and [`examples/`](examples) for a runnable headless integration
(an optional Astro example — **not** the reference frontend; the LiveView site
above is).

**API docs:** a published OpenAPI 3 spec (`/api/json/open_api`) and interactive
Swagger UI (`/api/json/swaggerui`) are available in dev **and** prod. Start at
[`docs/api.md`](docs/api.md) — the full reference for authentication, the JSON:API
content endpoints, GraphQL, webhooks, preview tokens and rate limits. New to the
headless surfaces? [`docs/headless-consumer-guide.md`](docs/headless-consumer-guide.md)
is a decision tree for picking the right surface and knowing what JSON shape each
one returns.

## Working with Ash

```bash
mix ash.codegen <name>   # generate migrations after changing resources
mix ash.migrate          # run pending migrations
mix ash.setup            # create DB + run migrations
```

## Deployment

Multi-stage [`Dockerfile`](Dockerfile) builds an OTP release and includes **libvips**
in the runtime image for image processing. Target: Coolify (RackNerd VPS) or Fly.io/Render.

Performance SLOs, Oban queue/`POOL_SIZE` tuning, and load-test recipes are in
[`docs/performance.md`](docs/performance.md).

### Staging / preview environments

Stand up a throwaway copy of production content to rehearse an upgrade or review a
change, then throw it away. `./scripts/staging.sh up` clones the production database,
migrates it, and **scrubs it of personal data and outbound secrets** (reusing the
GDPR-erasure `:anonymize` action) so the copy is safe to run somewhere less
locked-down. See [`docs/staging-environments.md`](docs/staging-environments.md) for
the one-command flow, the Docker/Coolify recipe, and the safety guards, and
[`docs/deploy-staging.md`](docs/deploy-staging.md) for the deploy/operator checklist.

### Production hardening checklist

- **`dev_routes` must stay off.** It is only set in `config/dev.exs`; `config/prod.exs`
  sets it `false` explicitly and the app **refuses to boot** if a `:prod` release has it
  enabled (it would expose `/admin`, LiveDashboard, and the Swoosh mailbox unauthenticated).
- **Database TLS is on by default.** The Postgres connection uses `ssl: true`; set
  `DATABASE_SSL=false` only for a provider that cannot offer TLS. Point
  `DATABASE_SSL_CACERTFILE` at the provider CA bundle to verify the server certificate
  (otherwise the connection is encrypted but uses `verify_none`).
- **Behind a reverse proxy**, set `TRUSTED_PROXIES` (comma-separated CIDRs, e.g.
  `10.0.0.0/8`) so rate limiting keys on the real client IP from `X-Forwarded-For`
  instead of the proxy address. Leave unset when the app is internet-facing directly.
- **Invite-only mode:** set `config :kiln_cms, :registration_enabled, false` to disable
  open `/register` self-signup (the registration action is gated, not just the UI link).

## Status & next steps

Bootstrapped & verified (compiling, migrating, serving):

- Phoenix 1.8 + Ash 3 core, CMS domain (Page/Post/MediaItem + embedded blocks)
- AshPaperTrail history + AshStateMachine publishing workflow
- JSON:API + GraphQL + AshAdmin
- **AshAuthentication** — Accounts domain, User/Token, password strategy, `/sign-in`
  + `/register`, plus a `role` attribute (`:admin`/`:editor`/`:viewer`, defaults to
  `:viewer`) for RBAC
- **Oban** (Postgres-backed, no Redis) + **AshOban** wired into the supervision tree
- Docker infra (Postgres default; Dragonfly/Meilisearch/MinIO optional profiles)
- **Search** — Postgres full-text + optional semantic/hybrid (pgvector) and an
  optional **Meilisearch** backend, both feature-flagged off by default
  ([`docs/meilisearch.md`](docs/meilisearch.md))

Now wired: **magic-link** auth, **Ash policies** enforcing the RBAC roles on every
resource, the media upload/variant pipeline (libvips), the **TipTap LiveView editor**
with real-time visual preview and collaborative locking, and headless GraphQL + JSON:API
delivery. Remaining cleanup: replace the temporary DaisyUI auth-override scaffolding in
`router.ex`/`auth_overrides.ex` with custom components (the plan specifies no DaisyUI).

> **Note:** keep this project at a path **without spaces** (it lives at
> `~/Github/kiln_cms`). Native deps (`bcrypt_elixir`, `libvips`) build via `make`, which
> fails on spaced paths such as iCloud Drive's `Mobile Documents`.
