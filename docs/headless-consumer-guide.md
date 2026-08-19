# Headless consumer guide

KilnCMS exposes content over **four** HTTP surfaces, and they deliberately return
**different JSON shapes**. This guide is a decision tree for picking the right one
and knowing what you'll get back. See also [api.md](api.md) (JSON:API + auth),
[headless-graphql-api.md](headless-graphql-api.md) (GraphQL), and
[json-api.md](json-api.md) (filtering reference).

Every Kiln site also serves a human-readable summary of these surfaces at
**`/developers`** (linked from the site header) — endpoints, auth in brief, and
the Swagger UI / OpenAPI spec links (#319).

**Building in Elixir?** Use the official client,
[`kiln_client`](../clients/elixir/kiln_client/README.md) — it wraps the
JSON:API reads, search, and artifact surfaces with the safe defaults below
(published-only reads, `Req.Test`-stubbable) already encoded.

## Decision tree

| You want… | Use | Returns |
|-----------|-----|---------|
| The **rendered body** of a published page/post (blocks, HTML, JSON-LD) | Artifact: `GET /api/content/:type/:slug?surface=json\|json_ld\|web` | Fired artifact — the immutable, pre-compiled output (Kiln v2 `_type` block model) |
| To **preview a specific draft** by share link | `GET /preview/:token` | The draft's raw, editable block tree (curated public fields), behind a signed 15-minute token |
| **Filterable lists / metadata** (slug, title, SEO, dates, relationships), incl. drafts with a bearer token | JSON:API: `GET /api/json/...` | Resource attributes + relationship linkage. **No block body** (`blocks` is `public? false`) |
| **Taxonomy** (categories, tags) | JSON:API `/api/json/categories`,`/tags` **or** GraphQL `categories`,`tags` | Name, slug, description |
| **Search** (keyword, semantic, autocomplete) | JSON:API `/<type>/search`,`/semantic-search`,`/autocomplete` **or** GraphQL `search*`/`semanticSearch*`/`autocomplete*` | Matching records (metadata; no block body). Published-only **for anonymous callers** — with a bearer token, drafts match too. Delivery sites: use the `…/published` twins (`searchPublished*` etc.), which pin `state == :published` server-side (see "Drafts") |
| A **typed query** over published content by slug/locale | GraphQL `/gql` (`postBySlug`, `pageBySlug`, …) | Selected fields; no block body, author is the opaque `authorId` only |

## Admin-defined (dynamic) content types

Types created in the admin UI (`/editor/types` — decision D17) are served
through the **same surfaces** as compiled types, with one difference: instead
of a typed schema per type, they share **one generic `entries` surface**,
scoped by the type's name:

| Surface | How |
|---------|-----|
| Artifact | `GET /api/content/<type name>/<slug>` — identical to compiled types; the `json` surface's `type` field is the dynamic type's name |
| JSON:API | `GET /api/json/entries?filter[type_name]=<name>` (+ `/entries/search`, `/semantic-search`, `/autocomplete` with `?query=…`, each with a published-only `…/published` twin) |
| GraphQL | `entryBySlug(slug, locale, typeDefinitionId)`, `searchEntries(query, filter: {typeName: {eq: "<name>"}})`, `entryTranslations`, `semanticSearchEntries`, `autocompleteEntries` (+ `searchPublishedEntries` / `semanticSearchPublishedEntries` / `autocompletePublishedEntries`) |
| Webhooks | Events are named by the dynamic type — `"<name>.published"` / `.updated` / `.unpublished` — exactly like compiled types |

Admin-defined **custom fields** are delivered in each entry's `custom_fields`
map on every surface — including the fired artifact's `json` surface — and are
**filterable/sortable** on the JSON:API and GraphQL list surfaces via
`custom_filter`/`custom_sort` (see
[json-api.md](json-api.md) → "Custom fields"). Scalar fields are JSON-native values; `media` and
`reference` fields are **write-time snapshots** — `{"id", "url", "alt"}` for
media, `{"id", "type", "slug", "title"}` for references — so no extra
resolution is needed to render them (fetch fresh content by `id`/`type` when
you need more than the label). A `geolocation` field is
`{"lat", "lng"}` (plus optional `"zoom"`/`"label"`), and also appears on the
`json_ld` surface as the document's `contentLocation`. A `computed` field is
**derived server-side and read-only** — writing to its key is silently ignored,
and the artifact always carries a freshly recomputed value. Per-type typed
GraphQL/JSON:API schemas are deliberately not generated at runtime — promote
the type to a compiled one when you need them.

> **After an upgrade that changes a surface's shape**, a document last published
> before it keeps its old artifact until something reads it. The first read
> serves the old shape and enqueues a re-fire behind the request; reads in
> between are served from cache, so the new shape appears once that background
> job lands — usually seconds, longer if the firing queue is backed up (#615).
> Treat the transition as eventual, not next-request: **read
> `format_version` if you need to know which shape you have** rather than
> assuming the keys are present. An operator can migrate a whole corpus up front
> with `mix kiln.refire_all` instead of waiting for reads to drive it.

## Word count and reading time

Every document exposes `word_count` (`wordCount` in GraphQL) and
`reading_time_minutes` (`readingTimeMinutes`) — folded from the block tree and
served wherever the rest of the document is, so you do not have to divide by
your own constant and get a different number from the editor's.

Reading time is `ceil(word_count / wpm)` at 230 words per minute by default,
configurable per deployment with `KILN_READING_TIME_WPM` (or `config :kiln_cms,
:reading_time_wpm` in a project overlay). The same rate drives the
`reading_time()` computed-field function, so a site using both gets one answer. Rounded
up, so any content at all is at least `1` and only genuinely empty content is
`0`.

> **Caveat.** One words-per-minute figure is an English-prose assumption.
> Scripts without spaces — Chinese, Japanese, Thai — are counted as words rather
> than characters, so their estimate is wrong in a way the calculation cannot
> see. Locale-aware rates are a follow-up.

## Why three different block shapes?

| Surface | Blocks field | Shape |
|---------|--------------|-------|
| Artifact `GET /api/content/:type/:slug` | ✅ `blocks` | Fired typed model (`{"_type": "...", ...}` per block), sanitized, ready to render |
| Preview `GET /preview/:token` | ✅ `blocks` | Raw editable blocks (what the editor holds), for a single draft |
| JSON:API / GraphQL | ❌ none | Block tree is **not** auto-exposed (`public? false`); these surfaces are for metadata, lists, search, and relationships |

**Rule of thumb:** render published bodies from the **artifact** surface (it has
CDN cache headers — `Cache-Control`/`ETag`/`Last-Modified`, see #188); use
**JSON:API/GraphQL** for discovery, lists, filtering, taxonomy, and search; use
**preview tokens** to share an unpublished draft.

## Author / PII

No surface exposes author email or role. Content carries only the opaque
`authorId` (JSON:API/GraphQL) and the display `name` is used server-side for the
JSON-LD/byline. See [headless-graphql-api.md](headless-graphql-api.md) → "Author
PII".

## Drafts

`*BySlug` GraphQL queries always return published content only (the action
hard-filters `state == :published`). To read a known draft, use a bearer token
with JSON:API `filter[state]=draft` or a `/preview/:token` link. See
[api.md](api.md) → "Reading drafts".

### Delivery sites: an API key widens what you see

The read policy authorizes **any editor/admin identity for every workflow
state** — and that includes a service API key attached as a bearer token. A
public frontend that sets its key "for rate limits" or "as a service identity"
is *not* an anonymous caller: its plain-index reads (`GET /api/json/<plural>`)
and **all search routes** silently include drafts. With an **admin** key it is
worse than drafts — the admin policy bypass skips the audience and passphrase
checks too, so the base routes also return audience-gated and passphrase-locked
bodies (#1013).

Two independent defenses; use both:

* **Mint delivery keys on a `:viewer` account** (see [api.md](api.md) → "API
  keys"). A viewer identity only ever matches published content, so the key
  *cannot* widen visibility no matter which route it hits.
* **Read the published-only surfaces anyway.** For lists/detail, use
  `GET /api/json/<plural>/published` (the `:published` action filters
  `state == :published` server-side; see [json-api.md](json-api.md) → route
  table) rather than the plain index. Search has the same twins (#297):
  `/search/published`, `/semantic-search/published` and
  `/autocomplete/published` (GraphQL: `searchPublished*`,
  `semanticSearchPublished*`, `autocompletePublished*`) pin, server-side,
  exactly what an anonymous visitor could read — published, `audience: :public`,
  and no passphrase (#1013) — with the same query surface minus the `state`
  facet, so the filter cannot be widened by any credential. Prefer these over
  remembering to pass `state=published` on every call to the base routes.

Treat "what can this credential see" as part of its blast radius: a leaked
editor-keyed delivery config exposes drafts, and an admin-keyed one exposes
every paying member's content as well — not just rate-limit headroom.

## Analytics: your fetches are what get counted

A successful `GET /api/content/:type/:slug` records a view against that
document, so a headless site's traffic appears at `/editor/analytics` instead of
reading as zero. There is nothing to install: no beacon, no cookie, no client
JS. Counting happens server-side on the request you already make, and stores
only the same aggregate counters the rendered site uses — no visitor data. (For
the same reason there is no ingest endpoint to POST your own numbers to; see
[advanced-analytics-plan.md](advanced-analytics-plan.md) → "Privacy constraints".)

What that number means depends on how you cache, so read it as a **floor rather
than a census**:

* **Your cache absorbs readers.** With ISR, a CDN in front of your frontend, or
  a static build, you fetch once and serve that document to everyone until it
  expires. Those readers are invisible to Kiln.
* **A build-time fetch counts a deploy**, not a reader. A CI pipeline that
  prerenders every page inflates counts by one per page per build.
* **Each surface counts separately.** Rendering a page from `?surface=json` plus
  `?surface=json_ld` is two views of one document.
* **Revalidation counts.** A conditional request that gets a `304` still counts
  — the client is actively serving that document. Excluding it would make a
  CDN-fronted site report near-zero.
* **Point-in-time reads do not count.** `?as_of=` is a history query, not a
  delivery.

The stored counters have no surface dimension, so headless and rendered views
sum together in the dashboard. If you export metrics, the
`kiln_cms.analytics.view.count` telemetry counter is tagged with `surface`
(`"html"` for the rendered site, otherwise the fired surface name), which is
where the two can be told apart.

If you need true reader counts, that has to come from your own frontend's
analytics — Kiln deliberately cannot see the browser.
