# @kiln-cms/client

Official JS/TS client for the [Kiln CMS](https://github.com/The-Verscienta/kiln_cms)
delivery APIs — the JSON:API read surface at `/api/json/*`, per-type and hybrid
search, fired artifacts at `/api/content/:type/:slug` (including `?as_of=`
point-in-time reads), and preview tokens. Ships with **`kiln-types`**, a
generator that turns a running site's `GET /api/schema` into TypeScript
declarations — admin-defined dynamic content types and custom fields included.

A port of the official Elixir client
([`clients/elixir/kiln_client`](../elixir/kiln_client/README.md)), which was
extracted from a production consumer and hardened against a live Kiln; it
encodes the safe defaults so consumers don't rediscover the traps one incident
at a time. See Kiln's
[headless consumer guide](../../docs/headless-consumer-guide.md) and
[JSON:API reference](../../docs/json-api.md) for the surfaces themselves.

Zero runtime dependencies; needs Node 18+ (native `fetch`) or any runtime with
the WHATWG fetch API. ESM only.

> **Not yet published to npm.** Until it is, consume it from a checkout with
> `"@kiln-cms/client": "file:../path/to/clients/js"` (run `npm run build` in
> `clients/js` first) — that is exactly what
> [`examples/astro-blog`](../../examples/astro-blog) does.

## Quick start

```ts
import { createClient } from "@kiln-cms/client";

const kiln = createClient({ baseUrl: "https://cms.example.com" });

// Filterable lists / metadata (slug, title, SEO, dates, relationships) —
// published-only by default, via the server-side /published feed.
const { items, included, total } = await kiln.list("posts", {
  filter: { tags: { slug: "news" } },
  sort: ["-published_at"],
  include: ["tags"],
  limit: 10,
});

// The rendered body of a published document: the fired artifact.
const doc = await kiln.artifact("post", "hello-world");
doc.blocks; // typed `_type`-discriminated blocks, ready to render

// What did this document say on March 1st, provably? (?as_of=)
const then = await kiln.artifact("post", "hello-world", { asOf: "2026-03-01" });

// Search (each also has semanticSearch / autocomplete twins).
const hits = await kiln.textSearch("posts", "firing schedules");

// Share-link previews: one draft, behind a signed 15-minute token.
const draft = await kiln.preview(token);
```

Every list-shaped result is the flattened JSON:API document: each resource
becomes its `attributes` plus `id`/`type`, with relationships reduced to
`{type, id}` ref lists and side-loaded resources in an `included` lookup —
join them with `resolve(item, "tags", included)`.

## Generated types: `kiln-types`

The baseline types (`ArtifactDocument`, the `Block` union) describe every Kiln
site loosely. For _your_ site — your content types, dynamic types created in
the admin UI, custom fields — generate exact declarations from the live schema
instead of vendoring shapes that go stale the moment an admin adds a field:

```bash
npx kiln-types --url https://cms.example.com --out src/kiln-types.d.ts
```

```ts
import type { PostDocument } from "./kiln-types";
const post = await kiln.artifact<PostDocument>("post", "hello-world");
```

Options: `--url <base>` (default `$KILN_API_URL` or `http://localhost:4000`),
`--from <file>` (offline, from a saved `mix kiln.export.schema` document),
`--out <file>` (default stdout), `--type post,page`, `--blocks-only`. The
emitter is a faithful port of the server-side one
(`KilnCMS.SchemaExport.TypeScript`), so `kiln-types` and
`mix kiln.export.schema --format ts` produce the same declarations for the
same document.

## Published-only by default

Reads are published-only by default. Do not rely on the credential for that:
Kiln's read policy authorizes any `:editor` actor for every workflow state
(and admins bypass it outright), so an API key minted on a staff account would
otherwise see drafts through the plain index and the base search routes
(kiln_cms#297). This client reads the server-side filtered surfaces instead —
the `/published` feed and the `/search/published`,
`/semantic-search/published`, `/autocomplete/published` twins — whose
`state == :published` filter holds whatever identity the key carries. Callers
that genuinely need drafts must opt out per call with `published: false`.

Two related warnings from the consumer guide:

- **Mint delivery keys on a `:viewer` account.** The hybrid `search()` endpoint
  has no published-only variant — a bearer key widens it to whatever the
  minting account can see.
- **`?as_of=` is a history query, not a delivery** — point-in-time reads don't
  count as views in Kiln's analytics.

## Configuration

```ts
const kiln = createClient({
  baseUrl: "https://cms.example.com",
  apiKey: process.env.KILN_API_KEY, // optional bearer key
  timeoutMs: 15_000, // per-request default
  headers: { "x-custom": "1" }, // merged into every request
  fetch: myFetch, // the test seam
});
```

`fetch` is the test seam: pass a stub and the client is fully testable without
a running Kiln (see `test/helpers.ts`). Every call also accepts a per-request
`signal` — use it to bound a call that must not hang:

```ts
await kiln.semanticSearch("posts", q, { signal: AbortSignal.timeout(1_500) });
```

A degraded embedding backend _stalls_ the semantic routes without failing them
(measured at ~70s per call on a production instance that still answered 200 —
far too late to be useful). Callers with a keyword fallback should bound
`semanticSearch()` and `search()` well above their healthy latency.

Errors: any non-2xx response throws `KilnHttpError` (`status`, `url`, parsed
`body`); narrow with `isKilnHttpError(err)`. `one()` resolves `null` instead
for an empty match, and `artifact()` retries a cold-cache 503 once before
throwing.

## API surface

| Method                               | Endpoint                                            | Notes                                                  |
| ------------------------------------ | --------------------------------------------------- | ------------------------------------------------------ |
| `list(plural, opts)`                 | `GET /api/json/:plural[/published]`                 | filters, sorts, includes, sparse fieldsets, pagination |
| `one(plural, filter, opts)`          | 〃                                                  | first match or `null`, `included` merged in            |
| `byIds(plural, ids, opts)`           | 〃                                                  | one request, results in `ids` order                    |
| `textSearch(plural, q, opts)`        | `GET /api/json/:plural/search[/published]`          | relevance-ranked                                       |
| `semanticSearch(plural, q, opts)`    | `GET /api/json/:plural/semantic-search[/published]` | cosine distance; empty without embeddings              |
| `autocomplete(plural, prefix, opts)` | `GET /api/json/:plural/autocomplete[/published]`    | typo-tolerant, ≤ 10 suggestions                        |
| `search(q, opts)`                    | `GET /api/search`                                   | hybrid; visibility follows the credential              |
| `artifact(type, slug, opts)`         | `GET /api/content/:type/:slug`                      | `surface`, `locale`, `asOf`; 503 retried once          |
| `contentAsOf(type, asOf, opts)`      | `GET /api/content/:type?as_of=`                     | what was published then                                |
| `preview(token)`                     | `GET /preview/:token`                               | one draft, signed 15-minute token                      |

Dynamic (admin-created) types go through the shared `entries` surface:
`kiln.list("entries", { filter: { type_name: "product" } })`; their artifacts
are addressed by type name like compiled types
(`kiln.artifact("product", slug)`).

## Development

```bash
npm install
npm run build      # tsc → dist/
npm test           # vitest
npm run lint       # eslint + prettier --check
```
