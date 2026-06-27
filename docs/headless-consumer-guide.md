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
| **Search** (keyword, semantic, autocomplete) | JSON:API `/<type>/search`,`/semantic-search`,`/autocomplete` **or** GraphQL `search*`/`semanticSearch*`/`autocomplete*` | Matching published records (metadata; no block body) |
| A **typed query** over published content by slug/locale | GraphQL `/gql` (`postBySlug`, `pageBySlug`, …) | Selected fields; no block body, author is the opaque `authorId` only |

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
