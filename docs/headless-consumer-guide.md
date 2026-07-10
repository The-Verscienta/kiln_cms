# Headless consumer guide

KilnCMS exposes content over **four** HTTP surfaces, and they deliberately return
**different JSON shapes**. This guide is a decision tree for picking the right one
and knowing what you'll get back. See also [api.md](api.md) (JSON:API + auth),
[headless-graphql-api.md](headless-graphql-api.md) (GraphQL), and
[json-api.md](json-api.md) (filtering reference).

## Decision tree

| You want… | Use | Returns |
|-----------|-----|---------|
| The **rendered body** of a published page/post (blocks, HTML, JSON-LD) | Artifact: `GET /api/content/:type/:slug?surface=json\|json_ld\|web` | Fired artifact — the immutable, pre-compiled output (Kiln v2 `_type` block model) |
| To **preview a specific draft** by share link | `GET /preview/:token` | The draft's raw, editable block tree (curated public fields), behind a signed 1-hour token |
| **Filterable lists / metadata** (slug, title, SEO, dates, relationships), incl. drafts with a bearer token | JSON:API: `GET /api/json/...` | Resource attributes + relationship linkage. **No block body** (`blocks` is `public? false`) |
| **Taxonomy** (categories, tags) | JSON:API `/api/json/categories`,`/tags` **or** GraphQL `categories`,`tags` | Name, slug, description |
| **Search** (keyword, semantic, autocomplete) | JSON:API `/<type>/search`,`/semantic-search`,`/autocomplete` **or** GraphQL `search*`/`semanticSearch*`/`autocomplete*` | Matching records (metadata; no block body). Published-only **for anonymous callers** — with a bearer token, drafts match too unless you pass `state=published` (see "Drafts") |
| A **typed query** over published content by slug/locale | GraphQL `/gql` (`postBySlug`, `pageBySlug`, …) | Selected fields; no block body, author is the opaque `authorId` only |

## Admin-defined (dynamic) content types

Types created in the admin UI (`/editor/types` — decision D17) are served
through the **same surfaces** as compiled types, with one difference: instead
of a typed schema per type, they share **one generic `entries` surface**,
scoped by the type's name:

| Surface | How |
|---------|-----|
| Artifact | `GET /api/content/<type name>/<slug>` — identical to compiled types; the `json` surface's `type` field is the dynamic type's name |
| JSON:API | `GET /api/json/entries?filter[type_name]=<name>` (+ `/entries/search`, `/semantic-search`, `/autocomplete` with `?query=…`) |
| GraphQL | `entryBySlug(slug, locale, typeDefinitionId)`, `searchEntries(query, filter: {typeName: {eq: "<name>"}})`, `entryTranslations`, `semanticSearchEntries`, `autocompleteEntries` |
| Webhooks | Events are named by the dynamic type — `"<name>.published"` / `.updated` / `.unpublished` — exactly like compiled types |

Admin-defined **custom fields** are delivered in each entry's `custom_fields`
map on every surface, and are **filterable/sortable** on the JSON:API and
GraphQL list surfaces via `custom_filter`/`custom_sort` (see
[json-api.md](json-api.md) → "Custom fields"). Scalar fields are JSON-native values; `media` and
`reference` fields are **write-time snapshots** — `{"id", "url", "alt"}` for
media, `{"id", "type", "slug", "title"}` for references — so no extra
resolution is needed to render them (fetch fresh content by `id`/`type` when
you need more than the label). Per-type typed GraphQL/JSON:API schemas are
deliberately not generated at runtime — promote the type to a compiled one
when you need them.

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
and **all search routes** silently include drafts.

Two independent defenses; use both:

* **Mint delivery keys on a `:viewer` account** (see [api.md](api.md) → "API
  keys"). A viewer identity only ever matches published content, so the key
  *cannot* widen visibility no matter which route it hits.
* **Read the published-only surfaces anyway.** For lists/detail, use
  `GET /api/json/<plural>/published` (the `:published` action filters
  `state == :published` server-side; see [json-api.md](json-api.md) → route
  table) rather than the plain index. For search there is currently **no
  `/published` variant** of `/search` / `/semantic-search` / `/autocomplete`;
  pass the action's `state` argument (`?query=…&state=published`) on every
  call. A server-side published-only search route is tracked in
  [#297](https://github.com/The-Verscienta/kiln_cms/issues/297).

Treat "which states can this credential see" as part of the credential's blast
radius: a leaked editor-keyed delivery config exposes drafts, not just
rate-limit headroom.
