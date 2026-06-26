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

## Headless consumption

Published content is world-readable (no auth) over three public surfaces:
`GET /api/content/:type/:slug` (the v2 content delivery API — structured `json`,
`json_ld`, or pre-rendered `web` HTML), `GET /sitemap.xml` for enumeration, and
`POST /gql` (GraphQL search). See [`examples/`](examples) for a runnable
**Astro static blog** that builds entirely from these endpoints, with a complete
headless setup walkthrough.

## Working with Ash

```bash
mix ash.codegen <name>   # generate migrations after changing resources
mix ash.migrate          # run pending migrations
mix ash.setup            # create DB + run migrations
```

## Deployment

Multi-stage [`Dockerfile`](Dockerfile) builds an OTP release and includes **libvips**
in the runtime image for image processing. Target: Coolify (RackNerd VPS) or Fly.io/Render.

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

Not yet wired (next): **magic-link** auth strategy, **Ash policies** enforcing the RBAC
roles, media upload/variant pipeline (`Image`/libvips), the **TipTap LiveView editor** +
real-time visual preview, and removing the default DaisyUI assets (the plan specifies no
DaisyUI).

> **Note:** keep this project at a path **without spaces** (it lives at
> `~/Github/kiln_cms`). Native deps (`bcrypt_elixir`, `libvips`) build via `make`, which
> fails on spaced paths such as iCloud Drive's `Mobile Documents`.
