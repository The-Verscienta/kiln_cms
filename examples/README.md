# KilnCMS examples

> **The reference frontend is KilnCMS itself.** The public website (pages, blog,
> search, locales) is delivered by Phoenix LiveView/controllers
> (`KilnCMSWeb.ContentController`) — there's no separate frontend to build. The
> examples below are **optional** integrations for *external/mobile* consumers
> that want to use KilnCMS purely as a headless backend.

Reference consumers that demonstrate using KilnCMS as a **headless** backend from
an external frontend.

| Example | Stack | Status | Demonstrates |
|---|---|---|---|
| [`astro-blog/`](astro-blog) | Astro (static) | Optional headless example (not the primary delivery path) | Content discovery via `sitemap.xml`, the v2 content delivery API (`/api/content/:type/:slug`), and GraphQL search (`/gql`) |

## The headless API at a glance

All published content is **world-readable — no authentication required**. The
public delivery surfaces are:

| Surface | Endpoint | Notes |
|---|---|---|
| Content delivery | `GET /api/content/:type/:slug?surface=json` | The v2 artifact API (decision D9): the immutable JSON a document compiled to on publish. Surfaces: `json` (structured blocks), `json_ld` (schema.org), `web` (`{ "html": … }`). |
| Sitemap | `GET /sitemap.xml` | Lists every published URL — the simplest way to enumerate content. |
| GraphQL | `POST /gql` | AshGraphql. Headless search: `searchPosts` / `searchPages`, plus semantic + autocomplete variants. Playground at `/gql/playground` (dev). |
| JSON:API | `GET /api/json/...` | AshJsonApi search/autocomplete routes (e.g. `/api/json/posts/search`). Swagger UI at `/api/json/swaggerui` (served in dev **and** prod). |

See each example's `README.md` for a full, copy-pasteable setup walkthrough
(start Postgres → `mix setup` → seed → `mix phx.server` → run the frontend).
