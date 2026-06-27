# KilnCMS × Astro — headless blog example

> ⚠️ **Optional example, not the reference frontend.** KilnCMS delivers its own
> public website with Phoenix LiveView/controllers (`KilnCMSWeb.ContentController`
> — pages, blog, search, locales). This Astro project is kept only to demonstrate
> consuming KilnCMS as a *headless* backend from an external/mobile frontend; you
> do **not** need it to run a KilnCMS site.

A reference [Astro](https://astro.build) static site that builds a small blog
**entirely from the KilnCMS headless content API** — no database access, no
shared code, just HTTP. It's the minimal end-to-end example of consuming KilnCMS
as a headless backend from a separate frontend stack.

It exercises all three public delivery surfaces:

| Surface | Endpoint | Used for |
|---|---|---|
| Sitemap | `GET /sitemap.xml` | discovering every published URL |
| Content delivery (v2 artifact API — decision D9) | `GET /api/content/:type/:slug?surface=json` | fetching a document's structured blocks |
| GraphQL (AshGraphql) | `POST /gql` | the `searchPosts` query |

Published content is world-readable, so **no authentication is required**.

## What it does

1. **Discovers** content by fetching `sitemap.xml` and mapping each public URL to
   a `{ type, slug }` (`src/lib/kiln.ts`).
2. **Fetches** each document's `?surface=json` artifact — the immutable,
   pre-serialized output a document compiles to on publish (the live editable
   block tree is *not* exposed).
3. **Renders** the typed blocks to HTML on the client side
   (`src/lib/render.ts`) — a faithful port of KilnCMS's own block + Portable Text
   renderers, so you can see exactly what a headless consumer does with the JSON.
4. **Builds** one static HTML page per document (`src/pages/[type]/[slug].astro`)
   plus an index and a GraphQL-backed search page.

```
src/
  lib/
    kiln.ts        # typed API client: discover / fetch artifact / GraphQL search
    render.ts      # typed-block + Portable Text → HTML (mirrors the server)
  layouts/
    Base.astro     # page shell + minimal styling
  pages/
    index.astro            # blog index (from the sitemap)
    [type]/[slug].astro    # one static page per published document
    search.astro           # GraphQL searchPosts demo (build-time)
```

## Prerequisites

- **A running, seeded KilnCMS** (see the walkthrough below).
- **Node.js 18+** and npm.

## Headless setup walkthrough

### 1. Start and seed KilnCMS

From the KilnCMS repo root:

```bash
docker compose up -d postgres      # Postgres is the only required service
mix setup                          # deps + DB + Ash migrations + assets
mix run priv/repo/seeds.exs        # publishes a "welcome" page + "hello-world" post
mix phx.server                     # serves the API on http://localhost:4000
```

Sanity-check the headless API directly:

```bash
curl http://localhost:4000/sitemap.xml
curl 'http://localhost:4000/api/content/post/hello-world?surface=json'
```

The second call returns the structured artifact this example renders:

```json
{
  "type": "post",
  "title": "Hello World",
  "slug": "hello-world",
  "blocks": [
    { "_type": "heading", "text": "…", "level": 2 },
    { "_type": "rich_text", "body": [ /* Portable Text */ ] },
    { "_type": "image", "url": "…", "alt": "…", "caption": "…" }
  ]
}
```

> Other surfaces: `?surface=web` returns `{ "html": "…" }` (server-rendered HTML,
> if you'd rather not render blocks yourself), and `?surface=json_ld` returns a
> schema.org `@graph` for structured-data/SEO.

### 2. Run this example

```bash
cd examples/astro-blog
cp .env.example .env          # point KILN_API_URL at your KilnCMS (defaults to :4000)
npm install
npm run dev                   # http://localhost:4321
```

`npm run build` produces a fully static site in `dist/` — every published
document is fetched and pre-rendered at build time.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `KILN_API_URL` | `http://localhost:4000` | Base URL of the KilnCMS instance to fetch from |
| `KILN_LOCALE` | `en` | Locale to build (KilnCMS serves the default locale at the bare slug) |

## Notes & extending it

- **URL → type mapping.** KilnCMS serves pages at `/<slug>`, posts at
  `/blog/<slug>`, and any other content type at `/<plural>/<slug>`. The
  `SEGMENT_TO_TYPE` map in `src/lib/kiln.ts` resolves the URL segment back to the
  content type; add an entry there for each custom content type you create with
  `mix kiln.gen.content`.
- **Live search.** `search.astro` runs a sample query at *build time* so the page
  stays static and CORS-free. For type-as-you-go search, move the `searchPosts`
  call into a client `<script>` and enable CORS on KilnCMS for your frontend
  origin (the GraphQL endpoint is `POST /gql`).
- **Rendering shortcut.** If you don't want to render blocks yourself, fetch
  `?surface=web` and inject the returned `html` — but rendering from `?surface=json`
  (as this example does) keeps full control over the markup.
- **Revalidation.** This is a static build; rebuild to pick up new content. KilnCMS
  also emits HMAC-signed webhooks on publish/unpublish, which you can wire to a
  rebuild hook for incremental deploys.
