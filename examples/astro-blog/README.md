# KilnCMS × Astro — headless blog example

> ⚠️ **Optional example, not the reference frontend.** KilnCMS delivers its own
> public website with Phoenix LiveView/controllers (`KilnCMSWeb.ContentController`
> — pages, blog, search, locales). This Astro project is kept only to demonstrate
> consuming KilnCMS as a *headless* backend from an external/mobile frontend; you
> do **not** need it to run a KilnCMS site.

A reference [Astro](https://astro.build) static site that builds a small blog
**entirely from the KilnCMS headless content API**, through the official
JS/TS client, [`@kiln-cms/client`](../../clients/js/README.md) — no database
access, no shared code, just HTTP. It's the minimal end-to-end example of
consuming KilnCMS as a headless backend from a separate frontend stack, and it
doubles as the client's integration test.

It exercises the client over two public delivery surfaces:

| Surface | Endpoint | Used for |
|---|---|---|
| JSON:API (published feeds) | `GET /api/json/:plural/published` | discovering every published post/page (slug + title metadata) |
| JSON:API (published search twin) | `GET /api/json/posts/search/published` | the search page |
| Content delivery (v2 artifact API — decision D9) | `GET /api/content/:type/:slug?surface=json` | fetching a document's structured blocks |

Published content is world-readable, so **no authentication is required** —
and the client reads the server-side *published-only* surfaces by default, so
a mistakenly configured staff API key could not leak drafts into the build.

## What it does

1. **Discovers** content from the JSON:API `/published` feeds — one metadata
   request per content type (`src/lib/kiln.ts` → `discoverContent`).
2. **Fetches** each document's `?surface=json` artifact — the immutable,
   pre-serialized output a document compiles to on publish (the live editable
   block tree is *not* exposed). A cold artifact cache answers 503; the client
   retries that once on its own.
3. **Renders** the typed blocks to HTML on the consumer side
   (`src/lib/render.ts`) — a faithful port of KilnCMS's own block + Portable Text
   renderers, so you can see exactly what a headless consumer does with the JSON.
4. **Builds** one static HTML page per document (`src/pages/[type]/[slug].astro`)
   plus an index and a search page (the JSON:API published search twin).

```
src/
  lib/
    kiln.ts        # the site's client: @kiln-cms/client + discovery/search helpers
    render.ts      # typed-block + Portable Text → HTML (mirrors the server)
  layouts/
    Base.astro     # page shell + minimal styling
  pages/
    index.astro            # blog index (from the JSON:API published feeds)
    [type]/[slug].astro    # one static page per published document
    search.astro           # JSON:API published-search demo (build-time)
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
curl 'http://localhost:4000/api/json/posts/published'
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

### 2. Build the client, then run this example

The example consumes `@kiln-cms/client` from this repo via a `file:`
dependency (it is not on npm yet), so build it once first:

```bash
cd clients/js && npm install && npm run build
```

Then:

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

- **Generated types.** The client ships a `kiln-types` CLI that turns your
  running site's `GET /api/schema` into exact TypeScript declarations —
  dynamic content types and custom fields included:
  `npx kiln-types --url http://localhost:4000 --out src/kiln-types.d.ts`, then
  `kiln.artifact<PostDocument>("post", slug)`.
- **Custom content types.** Compiled types get their own JSON:API routes —
  add a `kiln.list("<plural>")` call to `discoverContent`. Types created in
  the admin UI share the generic `entries` surface:
  `kiln.list("entries", { filter: { type_name: "product" } })`; their
  artifacts are addressed by type name (`kiln.artifact("product", slug)`).
- **Live search.** `search.astro` runs a sample query at *build time* so the
  page stays static and CORS-free. For type-as-you-go search, move the
  `searchPosts` call into a client `<script>` and enable CORS on KilnCMS for
  your frontend origin (`CORS_ORIGINS`; see `docs/api.md` → "Cross-origin").
- **Rendering shortcut.** If you don't want to render blocks yourself, fetch
  `?surface=web` and inject the returned `html` — but rendering from `?surface=json`
  (as this example does) keeps full control over the markup.
- **Revalidation.** This is a static build; rebuild to pick up new content. KilnCMS
  also emits HMAC-signed webhooks on publish/unpublish, which you can wire to a
  rebuild hook for incremental deploys.
