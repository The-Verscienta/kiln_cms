# Headless JSON:API

KilnCMS exposes a [JSON:API](https://jsonapi.org/)-compliant surface for
headless consumers at **`/api/json`** (powered by
[AshJsonApi](https://hexdocs.pm/ash_json_api)). Reads are anonymous-friendly;
**writes** (create / update / workflow / soft-delete) require an API key —
see [Writing](#writing-330). This document covers the read query params
(filtering, sorting, pagination) for the public content types — **Page**,
**Post** and **MediaItem** (tuned in Phase 5, issue #33) — and the write routes.

> The machine-readable OpenAPI spec (`/api/json/open_api`) and its interactive
> Swagger UI (`/api/json/swaggerui`) are published in **all environments** (dev
> and prod). See [api.md](api.md) for the full API documentation index
> (authentication, GraphQL, webhooks, preview tokens, rate limits).

## Content negotiation

Every request must use the JSON:API media type:

```
Accept: application/vnd.api+json
```

Requests are **anonymous by default** and go through each resource's read
policy, so only **published** content is returned. To read drafts / in-review /
archived content, authenticate with a bearer token belonging to an editor or
admin:

```
Authorization: Bearer <token>
```

## Routes

| Resource  | Collection                  | Single record               | Extra reads |
|-----------|-----------------------------|-----------------------------|-------------|
| Page      | `GET /api/json/pages`       | `GET /api/json/pages/:id`   | `/pages/search`, `/pages/semantic-search`, `/pages/autocomplete`, `/pages/published` |
| Post      | `GET /api/json/posts`       | `GET /api/json/posts/:id`   | `/posts/search`, `/posts/semantic-search`, `/posts/autocomplete`, `/posts/published` |
| MediaItem | `GET /api/json/media-items` | `GET /api/json/media-items/:id` | `/media-items/search` |

`GET /api/json/<plural>/published` returns published records only, ordered
newest first (`-published_at`) — the delivery feed. It exists on **every**
content type (incl. `/entries/published` for dynamic types); on posts it doubles
as the headless blog feed.

Every content-type search read also has a **published-only twin** at
`…/search/published`, `…/semantic-search/published` and
`…/autocomplete/published` — same query surface, with `state == :published`
filtered server-side. Delivery sites calling with a bearer key should use
these; see "Search & autocomplete" below.

## Filtering

Filter on any public attribute with `filter[<field>]=<value>` (equality) or
`filter[<field>][<operator>]=<value>` for other operators (`gt`, `lt`, `gte`,
`lte`, `in`, `not_eq`, `ilike`, …). Multiple `filter[...]` params are ANDed.

**Page / Post filterable fields:** `title`, `slug`, `locale`, `state`,
`published_at`, `scheduled_at`, `seo_title`, `seo_description`, `canonical_url`,
`category_id`, `featured_image_id`, `author_id` (Post also: `excerpt`).
Relationship filters such as `filter[category][slug]=news` are also supported.

**MediaItem filterable fields:** `filename`, `content_type`, `byte_size`,
`width`, `height`, `alt`, `caption`, `url`.

Examples:

```
# Published English posts in one category
GET /api/json/posts?filter[locale]=en&filter[category_id]=<uuid>

# Posts by exact slug
GET /api/json/posts?filter[slug]=my-first-post

# Drafts (requires an editor/admin bearer token)
GET /api/json/posts?filter[state]=draft

# Media of a given content type
GET /api/json/media-items?filter[content_type]=image/png
```

## Sorting

Use `sort=<field>` (ascending) or `sort=-<field>` (descending). Comma-separate
for multi-key sorts: `sort=-published_at,title`.

```
GET /api/json/posts?sort=-published_at        # newest first
GET /api/json/posts?sort=title                # A → Z
```

Any sortable public field may be used. The collection routes have no implicit
ordering unless you pass `sort` (except `/posts/published`, which defaults to
`-published_at`).

Two recency fields, two meanings: `inserted_at`/`updated_at` are the record's
row timestamps (public read-only), while `published_at` is set by the publish
transition — for published feeds, `-published_at` is what "newest" means
editorially. Note a non-public or unknown field in `sort` fails the request
with `invalid_sort` (it is not silently ignored), so a naive client renders an
empty page — check the error body.

### Sorting search results

`/…/search` orders by **relevance** by default (title hits above body hits,
newest breaking ties). An explicit `sort=` **overrides** it — your keys rank
first and relevance degrades to the tiebreaker:

```
GET /api/json/posts/search?query=tea             # best match first
GET /api/json/posts/search?query=tea&sort=title  # A → Z, relevance breaks ties
```

`/…/semantic-search` behaves the same way with cosine distance as the default
order (overriding it usually defeats the point — but it is not an error).
`custom_sort` is not accepted on the search routes.

## Custom fields (`custom_filter` / `custom_sort`)

Admin-defined custom fields (see
[extending-content.md](extending-content.md)) live in one `custom_fields`
JSONB map, so the derived `filter[...]`/`sort=` machinery above can't reach
them. Two dedicated params close the gap:

```
# Equality (bare value) and operators
GET /api/json/posts?custom_filter[color]=red
GET /api/json/posts?custom_filter[price][gt]=10

# Combined, and mixed with regular filters
GET /api/json/posts?filter[locale]=en&custom_filter[price][lte]=20&custom_sort=-price
```

**Filtering** — `custom_filter[<name>]=<value>` (equality) or
`custom_filter[<name>][<op>]=<value>` with `eq`, `not_eq`, `gt`, `gte`, `lt`,
`lte`, `in`, `ilike`, `null`. Conditions are ANDed (with each other and with
`filter[...]`). Semantics:

- Field names are validated against the `FieldDefinition` registry — an
  unknown name is a **400**, not an empty result.
- Values are cast to the field's declared type and compared **as jsonb**, so
  an `integer`/`float` field compares numerically (`9 < 10`), `boolean` as a
  boolean, and `date`/`datetime` (ISO-8601 strings) chronologically.
- `in` matches any of a list: `custom_filter[color][in][]=red&custom_filter[color][in][]=blue`.
- `ilike` (text-like fields only) takes the usual `%` wildcards:
  `custom_filter[subtitle][ilike]=%herb%`.
- `null` takes `true`/`false` and tests whether the record has the field at
  all.
- `media`/`reference` fields match on their snapshot's stable `id`
  (`custom_filter[hero_image]=<media uuid>`) and support `eq`/`not_eq`/`in`/`null` only.
- Records without the field are excluded by every comparison (they're SQL
  `NULL`), and a record whose stored value has another JSON type simply
  doesn't match — it can't error the query.

**Sorting** — `custom_sort=<name>` (ascending) or `custom_sort=-<name>`,
comma-separated for multi-key. Records lacking the field always sort last.
`custom_sort` composes with `sort=`: explicit `sort` keys take precedence, but
`custom_sort` outranks an action's *default* order (e.g. `/posts/published`'s
`-published_at`). `media`/`reference` fields are not sortable.

**Entries (dynamic types)** — the same params work on `/api/json/entries`,
where the field's type is resolved through the query's
`filter[type_name]=<name>` (or `filter[type_definition_id]=<uuid>`) scope.
Unscoped queries still work when every dynamic type declaring the field agrees
on its type; if declarations diverge, the API asks you to scope rather than
guessing a cast.

**Search facets** — `/…/search` and `/…/semantic-search` accept
`custom_filter` too (not `custom_sort`; relevance/distance is the default
order, and only an explicit `sort=` overrides it — see "Sorting search
results" above).

> **Performance.** These predicates run on unindexed JSONB extractions. They're
> built for the long tail of editor-owned fields; a field you filter or sort by
> on every request belongs as a real attribute (promote the type / add the
> column, D4). GraphQL exposes the same capability as `customFilter` /
> `customSort` arguments — see
> [headless-graphql-api.md](headless-graphql-api.md).

## Pagination

All collection reads support **offset** and **keyset** pagination via the
`page[...]` family of params:

| Param           | Meaning                                                        |
|-----------------|----------------------------------------------------------------|
| `page[limit]`   | Page size. Defaults to **25**, capped server-side at **100**.  |
| `page[offset]`  | Offset-based paging (row offset into the result set).          |
| `page[after]`   | Keyset cursor — records after the given cursor.                |
| `page[before]`  | Keyset cursor — records before the given cursor.               |
| `page[count]`   | `true` to include the total record count in `meta.page.total`. |

A requested `page[limit]` above the max is accepted but only the first 100 rows
are returned (the cap is applied silently, not as an error).

When you paginate, the response carries pagination metadata and links:

```jsonc
{
  "data": [ /* ... */ ],
  "meta": { "page": { "total": 42, "limit": 2, "offset": 0 } },
  "links": {
    "self": "http://host/api/json/posts?page[limit]=2",
    "next": "http://host/api/json/posts?page[limit]=2&page[offset]=2",
    "prev": null
  }
}
```

Example — page through a category newest-first, with a total count:

```
GET /api/json/posts?filter[category_id]=<uuid>&sort=-published_at&page[limit]=10&page[count]=true
GET /api/json/posts?filter[category_id]=<uuid>&sort=-published_at&page[limit]=10&page[offset]=10
```

> Internal callers (`CMS.list_posts!/1`, etc.) still receive a plain list:
> pagination is `required?: false` and not applied by default, so only requests
> that supply `page[...]` (i.e. the JSON:API layer) get a paginator.

## Search & autocomplete

The `/<type>/search` and `/<type>/autocomplete` routes wrap the resources'
full-text search actions. They take the action arguments as plain query params:

```
GET /api/json/posts/search?query=elixir&locale=en
GET /api/json/posts/autocomplete?prefix=eli
GET /api/json/media-items/search?query=logo
```

`search` also accepts the optional facets `category_id`, `author_id`, `state`
and `tag_ids[]`.

### Published-only search (`…/published`)

The base search routes go through the read policy: anonymous callers match
published content only, but a **bearer-keyed** caller matches whatever its
minting account can see — with an editor/admin key that includes drafts, and
the optional `state` facet is merely a request the caller must remember to
make. Each search read therefore has a published-only twin whose
`state == :published` filter is applied **server-side** (#297):

```
GET /api/json/posts/search/published?query=elixir&locale=en
GET /api/json/posts/semantic-search/published?query=elixir
GET /api/json/posts/autocomplete/published?prefix=eli
```

They take the same params minus `state` (the twins have no such argument — the
filter cannot be widened) and keep the same relevance/distance ordering and
pagination.
Delivery sites should use these — the search counterpart of reading
`/…/published` instead of the plain index. See
[headless-consumer-guide.md](headless-consumer-guide.md) → "Delivery sites: an
API key widens what you see".

## Sparse fieldsets & includes

Standard JSON:API `fields[<type>]` and `include` params work too, e.g.
`?include=category&fields[post]=title,slug`. The includable relationships on
every content type are `tags`, `category`, `featured_image`,
`content_links`, `incoming_links` and `related_<type>s`; anything else —
notably `author`, which stays excluded for PII redaction (#183) — is a 400.

Link edges arrive as `content_link` compound members carrying their payload
(`kind`, `position`, `label`, `metadata`, `source_id`, `target_id`), so a
consumer can join outgoing/incoming relations (and e.g. per-link dosage
metadata) without extra requests. The embedded block tree is **not**
exposed over JSON:API for *reads* — rendered content is served as fired
artifacts at `GET /api/content/:type/:slug`. For *writes*, send the body via the
`block_tree` attribute (see [Writing](#writing-330)).

## URLs, pathauto & redirects

Slugs auto-derive server-side (focus keyphrase → title, stop words stripped,
collision-deduped `base-2`, `base-3`, …), so a `POST` with just a `title` gets
a final slug back — never implement slugging client-side. Three surfaces let a
front end handle URLs without mirroring Kiln's scheme:

- **`path` field** — every content read exposes a `path` calculation, the full
  public path (`/blog/my-post`, `/about`, `/<path_segment>/<slug>` for dynamic
  types). Request it explicitly: `?fields[post]=title,slug,path`.
- **`GET /api/resolve?path=/blog/old-slug&locale=en`** — one call answers
  "what lives at this URL?", for catch-all routes in live (SSR) front ends:
  `{"status":"ok","type":"post","slug":…,"id":…}` renders,
  `{"status":"moved","to":"/blog/new-slug",…}` should be answered with your
  own 301, and a 404 `{"status":"not_found"}` is a real 404. Mirrors delivery
  exactly: published-only, content beats stale redirects, no redirect chains.
- **`GET /api/json/redirects`** — the redirect table (world-readable, written
  automatically when a *published* record's slug changes). Static-site
  generators pull it — filterable, e.g.
  `?filter[updated_at][greater_than]=2026-07-01T00:00:00Z` for incremental
  builds — and emit platform-native maps (Netlify `_redirects`, Next.js
  `redirects()`). Rows carry `path`, `locale`, `target_type`, `target_id`;
  resolve a row's *current* destination via `/api/resolve` or the target's
  `path` field. The `<type>.updated` webhook fires on published renames, so
  SSGs can rebuild redirect maps on push instead of polling.

## Writing (#330)

> **Reverses D7.** The JSON:API was originally read-only *by design*; write
> routes were added so external apps can write back into the CMS. **Writes
> require an API key** (`Authorization: Bearer kiln_…`) or an editor/admin JWT —
> a read-only key and anonymous callers are rejected by the resource policies.
> This is the same auth model as [`/mcp`](mcp.md): a key acts as its owning
> user, bounded by its `access` scope. Mint keys at `/editor/api-keys`.

Use the JSON:API media type on both `Accept` and `Content-Type`:
`application/vnd.api+json`.

| Route | Action | Who | Effect |
|-------|--------|-----|--------|
| `POST /api/json/posts` | `:create` | `:read_write` key, editor+ | Creates a **draft**, attributed to the key's owner |
| `PATCH /api/json/posts/:id` | `:update` | `:read_write` key, editor+ | Edits content; **re-fires** if already published |
| `PATCH /api/json/posts/:id/submit-for-review` | `:submit_for_review` | `:read_write` key, editor+ | draft → in_review |
| `PATCH /api/json/posts/:id/publish` | `:publish` | `:read_write` key, **admin** | Publishes and fires artifacts |
| `PATCH /api/json/posts/:id/unpublish` | `:unpublish` | `:read_write` key, **admin** | Takes content down, purges artifacts |
| `DELETE /api/json/posts/:id` | `:destroy` | `:read_write` key, **admin** | **Reversible** soft-delete (AshArchival) |

Pages expose the identical set; the dynamic tier is `/api/json/entries` (a
`create` needs a `type_definition_id` — discover types via `/mcp`'s
`read_type_definitions`).

**Authorization** mirrors `/mcp`: a **read-only key** can run none of these; a
**`:read_write` key on a `:viewer`** account can run none; a **`:read_write` key
on an `:editor`** can create/update/submit; **publish, unpublish and delete
require an `:admin`** account. Hard delete (`:purge`) is **never** routed and is
API-key-banned regardless of scope — `DELETE` is the reversible soft-delete.

### Creating and editing

```bash
# Create a draft post
curl -s http://localhost:4000/api/json/posts \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{
    "data": {
      "type": "post",
      "attributes": {
        "title": "Written over the API",
        "slug": "hello-api",
        "block_tree": [{ "type": "rich_text", "content": "<p>Body</p>", "order": 1 }]
      }
    }
  }'
```

`tag_ids` / `category_id` / `featured_image_id` and the SEO / `audience` /
`custom_fields` / scheduling attributes are all writable. Relationship arrays
(`tag_ids`, `related_post_ids`) are passed as attributes.

### Writing body content — the `block_tree` attribute

The typed `blocks` union isn't exposed on the auto API (it isn't `public?`), so
body content is written through a public **`block_tree`** attribute: an array of
block maps (the same shape the editor and MCP submit), cast into the union —
which **sanitizes** rich-text HTML and media URLs. On an update, **omit**
`block_tree` to leave the body untouched (a metadata-only `PATCH` never wipes
it); send `[]` to clear it.

### Re-fire semantics

Firing (immutable per-surface artifact regeneration) is bound to `:publish`, so
the publish route re-fires automatically. Editing already-published content with
`PATCH /:id` **also** re-fires (a `published`-guarded re-fire on `:update`,
#330), so a write-through to live content never leaves a stale artifact. Draft
edits do not fire.

### Workflow routes take an empty resource object

The workflow `PATCH` routes (`/publish`, `/unpublish`, `/submit-for-review`)
carry no attributes — send the JSON:API resource identifier only:

```bash
curl -s -X PATCH http://localhost:4000/api/json/posts/<uuid>/publish \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_ADMIN_API_KEY" \
  -d '{ "data": { "type": "post", "id": "<uuid>", "attributes": {} } }'
```

The full request/response schemas (including the write routes) are in the
published OpenAPI spec at `/api/json/open_api` and the Swagger UI at
`/api/json/swaggerui`.
