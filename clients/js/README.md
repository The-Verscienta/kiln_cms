# @kiln-cms/client

Official JS/TS client for the [KilnCMS](https://github.com/The-Verscienta/kiln_cms)
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
`--out <file>` (default stdout), `--type post,page`, `--blocks-only`,
`--api-key <key>` (default `$KILN_API_KEY`). The CLI fetches through the
client's `schema()` method, so it shares the transport: 15s timeout, bearer
auth, `KilnHttpError` bodies.

The emitter is a faithful port of the server-side one
(`KilnCMS.SchemaExport.TypeScript`), so `kiln-types` and
`mix kiln.export.schema --format ts` produce the same declarations for the
same document — a promise both test suites enforce against the shared golden
in `test/fixtures/` (see `test/parity.test.ts` and the ExUnit twin
`test/kiln_cms/schema_export/type_script_parity_test.exs` in the Kiln repo),
so the two emitters cannot drift silently.

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

| Method                               | Endpoint                                            | Notes                                                        |
| ------------------------------------ | --------------------------------------------------- | ------------------------------------------------------------ |
| `list(plural, opts)`                 | `GET /api/json/:plural[/published]`                 | filters, sorts, includes, sparse fieldsets, pagination       |
| `one(plural, filter, opts)`          | 〃                                                  | first match or `null`, `included` merged in                  |
| `byIds(plural, ids, opts)`           | 〃                                                  | chunked at the 100-row page cap, results in `ids` order      |
| `textSearch(plural, q, opts)`        | `GET /api/json/:plural/search[/published]`          | relevance-ranked                                             |
| `semanticSearch(plural, q, opts)`    | `GET /api/json/:plural/semantic-search[/published]` | cosine distance; empty without embeddings                    |
| `autocomplete(plural, prefix, opts)` | `GET /api/json/:plural/autocomplete[/published]`    | typo-tolerant, ≤ 10 suggestions                              |
| `search(q, opts)`                    | `GET /api/search`                                   | hybrid; visibility follows the credential                    |
| `artifact(type, slug, opts)`         | `GET /api/content/:type/:slug`                      | `surface`, `locale`, `asOf`; 503 retried once                |
| `contentAsOf(type, asOf, opts)`      | `GET /api/content/:type?as_of=`                     | what was published then                                      |
| `preview(token)`                     | `GET /preview/:token`                               | one draft, signed 15-minute token                            |
| `schema(opts)`                       | `GET /api/schema`                                   | the live delivery schema; feed it to `emitTypes`             |
| `imageUrl(media, opts)`              | `GET /media/:id/t/:ops`                             | builds the URL, no request; unsigned, sizes snapped          |
| `imageSrcset(media, opts)`           | 〃                                                  | `null` without dimensions; `signedImage*` twins take the key |

Dynamic (admin-created) types go through the shared `entries` surface:
`kiln.list("entries", { filter: { type_name: "product" } })`; their artifacts
are addressed by type name like compiled types
(`kiln.artifact("product", slug)`). The type registry itself is
`kiln.list("type-definitions", { filter: { name: "product" } })` — it needs an
editor-or-above key, and `include: ["field_definitions"]` adds each type's
custom-field schema.

## Image transforms

Kiln resizes, crops and re-encodes media on the fly at
`GET /media/:id/t/:ops` — e.g. `/media/<id>/t/w_828,ar_16:9,fm_auto,v_4b87b277`.
The builders take a flattened `media_item` (`id`, `url`, `focal_x`, `focal_y`,
`width`, `height` — what `kiln.list("media-items")` returns) and emit the
canonical URL, including a `v` version pin (a hash of the item's `url` and focal
point) that lets the server cache the result as `immutable`:

```ts
const src = kiln.imageUrl(media, { width: 800, aspectRatio: "16:9", format: "auto" });
// → https://cms.example.com/media/<id>/t/w_828,ar_16:9,fm_auto,v_…

const srcset = kiln.imageSrcset(media, { aspectRatio: "16:9", format: "auto" });
// → "…/t/w_256,ar_16:9,fm_auto,v_… 256w, …/t/w_384,… 384w, …" (null without dimensions)
```

Options: `width`, `height` (CSS px), `aspectRatio` (`"16:9"` or `[16, 9]`, instead
of `height`), `dpr` (1–3), `fit` (`cover` | `contain`), `crop` (`focal` |
`center` | `top` | `bottom` | `left` | `right`), `format` (`auto` | `jpg` | `png` |
`webp` | `avif`), `quality` (1–100). `format: "auto"` lets the server pick from
the browser's `Accept` header (AVIF when the operator enabled it, then WebP, then
the source format). The server never upscales, so a `srcset` describes each
candidate by the width it really renders at and drops the duplicates past the
source's own width. Invalid options throw.

**Unsigned vs signed.** Every distinct transform costs the server a render, so
**unsigned** URLs are held to an allowlist: widths and heights from a size ladder
(`DEFAULT_TRANSFORM_SIZES`, Next.js's default device and image sizes), and by
default aspect ratios `1:1 4:3 3:4 3:2 2:3 4:5 5:4 16:9 9:16 21:9` and qualities
`50 75 90`. The unsigned builders **snap `width`/`height` up** to the next rung
(pass `sizes` if the operator configured a different ladder); keep ratios and
qualities on their lists. **Signed** URLs may use any in-range value and are not
snapped:

```ts
const kiln = createClient({
  baseUrl: "https://cms.example.com",
  imageTransformKey: process.env.KILN_IMAGE_TRANSFORM_KEY, // server-side only!
});
const exact = await kiln.signedImageUrl(media, { width: 801, height: 451 });
const set = await kiln.signedImageSrcset(media, { widths: [300, 600, 1200] });
```

> **The signing key is a server secret.** `KILN_IMAGE_TRANSFORM_KEY` lets whoever
> holds it make the server render any size — sign on a server (SSR, a build
> step), never in code that ships to a browser. Signing uses WebCrypto
> (`globalThis.crypto.subtle`), hence the `await`.

The same builders are exported as pure functions returning paths —
`transformPath`, `transformSrcset`, `signedTransformPath`,
`signedTransformSrcset`, `transformVersion`, `snapTransformSize` — for callers
without a client. They reproduce the server's own builders byte for byte, a
promise the shared vectors in `test/fixtures/image_transform_vectors.json` hold
all three implementations (server, this SDK, the Elixir client) to.

## Development

```bash
npm install
npm run build      # tsc → dist/
npm test           # vitest
npm run lint       # eslint + prettier --check
```
