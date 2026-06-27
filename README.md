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
