# @kiln-cms/client

Official JS/TS client for the [KilnCMS](https://github.com/The-Verscienta/kiln_cms)
APIs — the JSON:API read surface at `/api/json/*`, the JSON:API **write**
surface (create, update, workflow transitions, soft-delete), per-type and
hybrid search, fired artifacts at `/api/content/:type/:slug` (including
`?as_of=` point-in-time reads), preview tokens, and a minimal GraphQL helper
for `/gql`. Ships with **`kiln-types`**, a
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

> **Publishing is prepared, not yet done.** The package metadata and the
> release workflow are in place (see [Releasing](#releasing)), but the first
> publish to npm is a manual maintainer step. Until it happens, consume the
> client from a checkout with
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

// Share-link previews: one draft, behind a signed 15-minute token. Mint on the
// server (an editor's `:read` key), redeem in the browser (no key needed).
const { token } = await kiln.mintPreview("post", draftId);
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

`one()` resolves `null` for an empty match, and `artifact()` retries a
cold-cache 503 once before throwing; everything else that fails throws — see
[Errors](#errors).

## API surface

| Method                               | Endpoint                                            | Notes                                                   |
| ------------------------------------ | --------------------------------------------------- | ------------------------------------------------------- |
| `list(plural, opts)`                 | `GET /api/json/:plural[/published]`                 | filters, sorts, includes, sparse fieldsets, pagination  |
| `one(plural, filter, opts)`          | 〃                                                  | first match or `null`, `included` merged in             |
| `byIds(plural, ids, opts)`           | 〃                                                  | chunked at the 100-row page cap, results in `ids` order |
| `textSearch(plural, q, opts)`        | `GET /api/json/:plural/search[/published]`          | relevance-ranked                                        |
| `semanticSearch(plural, q, opts)`    | `GET /api/json/:plural/semantic-search[/published]` | cosine distance; empty without embeddings               |
| `autocomplete(plural, prefix, opts)` | `GET /api/json/:plural/autocomplete[/published]`    | typo-tolerant, ≤ 10 suggestions                         |
| `search(q, opts)`                    | `GET /api/search`                                   | hybrid; visibility follows the credential               |
| `artifact(type, slug, opts)`         | `GET /api/content/:type/:slug`                      | `surface`, `locale`, `asOf`; 503 retried once           |
| `contentAsOf(type, asOf, opts)`      | `GET /api/content/:type?as_of=`                     | what was published then                                 |
| `mintPreview(type, id)`              | `POST /api/content/:type/:id/preview-token`         | server side; `{token, url, expires_at, …}`              |
| `preview(token)`                     | `GET /preview/:token`                               | one draft, signed 15-minute token                       |
| `schema(opts)`                       | `GET /api/schema`                                   | the live delivery schema; feed it to `emitTypes`        |
| `create(plural, attrs, opts)`        | `POST /api/json/:plural`                            | a draft; `:read_write` key, editor+                     |
| `update(plural, id, attrs, opts)`    | `PATCH /api/json/:plural/:id`                       | re-fires if published; editor+                          |
| `transition(plural, id, verb, opts)` | `PATCH /api/json/:plural/:id/<verb>`                | empty resource object; wrappers below                   |
| `submitForReview(plural, id)`        | `PATCH …/:id/submit-for-review`                     | draft → in_review; editor+                              |
| `returnToDraft(plural, id)`          | `PATCH …/:id/return-to-draft`                       | in_review → draft; admin                                |
| `publish(plural, id)`                | `PATCH …/:id/publish`                               | fires artifacts; admin                                  |
| `unpublish(plural, id)`              | `PATCH …/:id/unpublish`                             | purges artifacts; admin                                 |
| `delete(plural, id)`                 | `DELETE /api/json/:plural/:id`                      | reversible soft-delete; admin                           |
| `graphql(query, variables, opts)`    | `POST /gql`                                         | resolves to `data`; `errors` throw `KilnGraphQLError`   |

Dynamic (admin-created) types go through the shared `entries` surface:
`kiln.list("entries", { filter: { type_name: "product" } })`; their artifacts
are addressed by type name like compiled types
(`kiln.artifact("product", slug)`). The type registry itself is
`kiln.list("type-definitions", { filter: { name: "product" } })` — it needs an
editor-or-above key, and `include: ["field_definitions"]` adds each type's
custom-field schema.

### Editorial reads (editor-or-above key)

For tools _about_ the content — migrations, audit exports, launch dashboards —
not for a delivery site. Anonymous calls are a 401 and a viewer's key a 404.

| Method                                 | Endpoint                                                    | Notes                                                |
| -------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------- |
| `listRevisions(type, id, opts)`        | `GET /api/content/:type/:id/revisions`                      | newest first; `limit`, `cursor` (`meta.next_cursor`) |
| `revision(type, id, versionId)`        | `GET /api/content/:type/:id/revisions/:version_id`          | the version's `changes` + full `snapshot`            |
| `restoreRevision(type, id, versionId)` | `POST /api/content/:type/:id/revisions/:version_id/restore` | `:read_write` key; a read-only key is a 403          |
| `releases(opts)`                       | `GET /api/json/releases`                                    | read-only; `include: ["items"]`, `filter: {state}`   |
| `release(id, opts)`                    | `GET /api/json/releases/:id`                                | one release, `included` merged in                    |
| `releaseItems(opts)`                   | `GET /api/json/release-items`                               | `filter: { release_id }`                             |

```ts
const editorial = createClient({ baseUrl, apiKey: process.env.KILN_EDITOR_KEY });

let cursor: string | undefined;
do {
  const page = await editorial.listRevisions("post", postId, { cursor });
  for (const rev of page.data) console.log(rev.inserted_at, rev.action, rev.changed_fields);
  cursor = page.meta.next_cursor ?? undefined;
} while (cursor);
```

## Writing content

The write methods drive Kiln's JSON:API write surface (see
[`docs/json-api.md` → Writing](../../docs/json-api.md#writing-330)). They need
a **`:read_write` API key** — editor-or-above to create, update and submit for
review; admin to return to draft, publish, unpublish and delete — and throw
`KilnConfigError` without sending anything when the client has no `apiKey`.
That key is the opposite of the `:viewer` key delivery reads want, so hold
separate clients rather than one widened key:

```ts
const kiln = createClient({ baseUrl, apiKey: process.env.KILN_READ_KEY }); // :viewer
const writer = createClient({ baseUrl, apiKey: process.env.KILN_WRITE_KEY }); // editor, :read_write
const admin = createClient({ baseUrl, apiKey: process.env.KILN_ADMIN_KEY }); // admin, :read_write

// Always created as a draft, attributed to the key's owner.
const post = await writer.create("posts", {
  title: "Written over the API",
  slug: "hello-api",
  body_markdown: "# Hello\n\nFrom the SDK.", // or block_tree: [...], not both
  tag_ids: [newsTagId],
});

// Only what you send changes. `tag_ids` REPLACES the set; merge with
// add_tag_ids / remove_tag_ids instead (not both styles in one call).
await writer.update("posts", post.id, { add_tag_ids: [featuredTagId] });

await writer.submitForReview("posts", post.id);
await admin.publish("posts", post.id); // fires the artifacts
await admin.delete("posts", post.id); // reversible soft-delete
```

- The first argument is the plural route, as for reads. The JSON:API `type`
  the server validates is derived from it (`entries` → `entry`); pass
  `{ type: "person" }` for an irregular plural.
- A dynamic-type entry is created on `"entries"` with its
  `type_definition_id` — look it up with
  `kiln.one("type-definitions", { name: "product" })` (editor-or-above key).
- Editing published content re-fires its artifacts; draft edits do not.
- When rewriting a body with `block_tree`, echo each block's `_id` (read them
  with `fields: { post: ["block_ids"] }`) so the server can tell an edit from
  a replacement.
- `transition(plural, id, verb)` takes any verb (`"publish"`,
  `"submit_for_review"`, …) and kebab-cases it into the route, so a verb a
  newer server adds is reachable before a client release names it.

## GraphQL

```ts
const { postBySlug } = await kiln.graphql<{ postBySlug: { title: string } | null }>(
  `query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }`,
  { slug: "hello-world", locale: "en" },
);
```

A minimal helper, not a GraphQL client: it posts `{query, variables,
operationName?}` to `/gql`, sends the API key if the client has one (the
published-content queries need none), resolves to `data`, and throws
`KilnGraphQLError` (`graphqlErrors`, partial `data`) when the response has a
top-level `errors` array. No codegen, no cache. Ash **mutations** report a
refused write inside `data` — the payload's own `errors` field next to
`result: null` — so select `errors { message code }` on mutations and check it.

## Errors

Everything the client throws is a `KilnError` (`status`, `code`, the JSON:API
`errors` array, `retryAfter` in seconds). HTTP failures are a `KilnHttpError`
(`status`, `url`, parsed `body` — unchanged from 0.1, so `isKilnHttpError(err)`
still narrows) refined by status:

| Class                 | When                                                                                                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `KilnAuthError`       | 401 (no/invalid/expired key) · 403 (the key's owner lacks the right — a `:read` key writing, an editor publishing)               |
| `KilnNotFoundError`   | 404                                                                                                                              |
| `KilnValidationError` | 400 / 422 — `pointers` (`/data/attributes/slug`) and `fieldErrors()`. AshJsonApi answers most attribute errors with 400, not 422 |
| `KilnConflictError`   | 409 — a transition from the wrong state (`code: "invalid_state_transition"`, `currentState`) or a lost race                      |
| `KilnRateLimitError`  | 429 — wait `retryAfter` seconds                                                                                                  |
| `KilnServerError`     | 5xx (a 503 may carry `retryAfter`)                                                                                               |
| `KilnNetworkError`    | no response at all (DNS, refused, TLS); the original error is `cause`                                                            |
| `KilnGraphQLError`    | `/gql` answered with top-level `errors`                                                                                          |
| `KilnConfigError`     | refused client-side — a write with no `apiKey` (`code: "missing_api_key"`)                                                       |

Aborts are not wrapped: a `signal` (or the client's timeout) rejects with the
platform's `AbortError` / `TimeoutError`, exactly as `fetch` does. The API key
is only ever sent as the `Authorization` header — no error carries it.

```ts
try {
  await admin.publish("posts", id);
} catch (error) {
  if (error instanceof KilnConflictError && error.currentState === "published") return;
  throw error;
}
```

## Releasing

Publishing runs from `.github/workflows/release-clients.yml`, triggered only
by a tag named `client-js-vX.Y.Z` (it cannot match the core's `vX.Y.Z` release
tags). The workflow checks the tag equals `package.json`'s `version`, runs the
same lint/build/test/`astro check` gate as CI, `npm pack`s the package, and —
after approval in the `npm` environment — attests the tarball's build
provenance and publishes that same tarball with
`npm publish --provenance --access public`.

1. Bump `version` in `package.json` (then `npm install --package-lock-only`
   here and in `examples/astro-blog`, whose lockfile records it), add a
   `CHANGELOG.md` entry, and merge.
2. Tag the merge commit `client-js-vX.Y.Z` and push the tag.
3. Approve the run in the `npm` environment.

One-time setup a maintainer must do before the first run can succeed:

- **npm:** create the `@kiln-cms` organization (the scope) on npmjs.com — a
  free org is enough for public packages — and a granular access token with
  publish rights to it.
- **GitHub:** create an environment named **`npm`** (Settings →
  Environments), add required reviewers, and store the token there as the
  environment secret **`NPM_TOKEN`**.

`prepublishOnly` runs lint, build and test, so even an accidental
`npm publish` from a checkout has to pass the gate first.

## Development

```bash
npm install
npm run build      # tsc → dist/
npm test           # vitest
npm run lint       # eslint + prettier --check
```
