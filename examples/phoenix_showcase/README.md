# KilnCMS headless showcase (Phoenix / LiveView)

A small **Phoenix LiveView** app that consumes KilnCMS purely as a **headless
backend** — proving the delivery API works for an Elixir/BEAM consumer, not just
JavaScript frontends.

The point: **this app has no database.** It never touches KilnCMS's Postgres or
shares any code with it. Everything on screen is fetched from the public
delivery API over HTTP (`Req`) and rendered with LiveView. It's a template for
building a decoupled frontend — including one in the same stack as Kiln itself.

## What it demonstrates

| Feature | KilnCMS surface used |
|---|---|
| Blog index | JSON:API — `GET /api/json/posts/published` |
| Article pages (blocks rendered on the BEAM) | Fired artifacts — `GET /api/content/:type/:slug?surface=json` |
| Search-as-you-type | GraphQL — `POST /gql` (`searchPosts`) |
| Locale switcher | `GET /api/locales` (+ per-locale content) |
| Contact form (schema-driven) | `GET /api/forms/:slug` + `POST /api/forms/:slug` |
| Optional authenticated reads | `Authorization: Bearer kiln_…` API key |

`lib/showcase/kiln.ex` is the entire integration — one small module. The
interesting bit is `lib/showcase_web/components/blocks.ex`, which turns Kiln's
**typed block tree** into HTML itself (headings, images, quotes, and
Portable-Text rich text with marks + links) — i.e. the frontend owns
presentation, Kiln owns content.

## Run it

**1. Start KilnCMS** (from the repo root) and seed some content:

```bash
mix setup && mix phx.server   # KilnCMS on http://localhost:4000
```

**2. Start the showcase** (in this directory):

```bash
mix setup          # fetch deps + install esbuild + build the JS bundle
mix phx.server     # showcase on http://localhost:4002
```

Open **http://localhost:4002**.

> The showcase talks to `http://localhost:4000` by default. Point it elsewhere,
> or authenticate with an API key, via env vars — see `.env.example`:
>
> ```bash
> KILN_API_URL=https://cms.example.com KILN_API_KEY=kiln_… mix phx.server
> ```

### Browser-side consumption & CORS

This app fetches from KilnCMS **server-side** (in the LiveView process), so it
needs no CORS. If you build a frontend that calls the API from the **browser**,
enable CORS on KilnCMS by setting `CORS_ORIGINS` (e.g. `http://localhost:4002`
or `*` in dev). See `docs/api.md` → *Cross-origin (CORS)*.

## Notes

- **Content types**: posts render at `/blog/:slug`; any other type (pages, etc.)
  at `/doc/:type/:slug`.
- **Forms**: the contact page renders whatever form is served at
  `/api/forms/contact`. Create one at `/editor/forms` (or set
  `config :showcase, :contact_form_slug, "<slug>"`).
- **API keys are read-only** — a key can never modify content, so this consumer
  is safe to point at production.
