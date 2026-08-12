# Headless JSON:API

KilnCMS exposes a [JSON:API](https://jsonapi.org/)-compliant surface for
headless consumers at **`/api/json`** (powered by
[AshJsonApi](https://hexdocs.pm/ash_json_api)). Reads are anonymous-friendly;
**writes** (create / update / workflow / soft-delete) require an API key —
see [Writing](#writing-330). This document covers the read query params
(filtering, sorting, pagination) for the public content types — **Page**,
**Post** and **MediaItem** (tuned in Phase 5, issue #33) — and the write routes.

> The machine-readable OpenAPI spec (`/api/json/open_api`) and its interactive
> Swagger UI (`/api/json/swaggerui`) are published in dev and test, and in production only with `API_DOCS_ENABLED` (#567) (dev
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
| Category  | `GET /api/json/categories`  | `GET /api/json/categories/:id` | `/categories/by-slug/:slug` |
| Tag       | `GET /api/json/tags`        | `GET /api/json/tags/:id`    | `/tags/by-slug/:slug` |
| TagGroup  | `GET /api/json/tag-groups`  | `GET /api/json/tag-groups/:id` | `/tag-groups/by-slug/:slug` |

`GET /api/json/<plural>/published` returns published records only, ordered
newest first (`-published_at`) — the delivery feed. It exists on **every**
content type (incl. `/entries/published` for dynamic types); on posts it doubles
as the headless blog feed.

Taxonomy is world-readable and read-only over the API (D7). A **tag group** is
the bucket a tag is filed under: `tag-groups` carries `name`, `slug`,
`description`, `position`, a `tag_count` aggregate, and `content_types` — an
array of content-type name strings (`["post"]`) that scopes where the group is
offered, where **an empty array means every content type**. A tag exposes its
group as `tag_group_id` plus an includable `tag_group` relationship
(`/api/json/tags?include=tag_group`); `/api/json/tag-groups?include=tags` goes
the other way. Frontends rebuilding Kiln's grouped tag UI filter
`content_types` client-side — it is a short list, so there is no server-side
`for_content_type` read.

Every content-type search read also has a **published-only twin** at
`…/search/published`, `…/semantic-search/published` and
`…/autocomplete/published` — same query surface, restricted server-side to what
an **anonymous** visitor could read: published, `audience: :public`, and not
passphrase-locked. Delivery sites calling with a bearer key should use these;
see "Search & autocomplete" below.

That is a stronger filter than the read policy, and deliberately so. A bearer key
authorizes as the account that minted it, and an admin account bypasses the
audience and passphrase checks entirely — so on the **base** routes an
admin-minted delivery key enumerates member-only and locked documents (title,
slug, excerpt, SEO fields; `blocks` is not public on any read action). The twins
cannot be widened by any credential (#297, #1013).

The hybrid `GET /api/search` holds the same line — it is actorless, so it always
answers as an anonymous visitor.

`GET /api/json/<plural>/published` deliberately does **not**: an index is a
discovery surface, and the rendered blog index publishes an audience-gated
post's title and excerpt to anonymous visitors with a "Members" badge, so that
metadata is already public. It pins `state` only.

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
empty page — check the error body. The same is true of a public field that
exists but isn't sortable — see [Calculated fields](#calculated-fields).

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
minting account can see. With an editor/admin key that includes drafts — and,
because an admin bypasses the audience and passphrase policies outright, also
audience-gated and passphrase-locked bodies. The optional `state` facet is
merely a request the caller must remember to make, and it does not narrow the
other two axes at all.

Each search read therefore has a published-only twin whose filter is applied
**server-side** and matches exactly what an anonymous visitor could read —
`state == :published`, `audience == :public`, and no passphrase (#297, #1013):

```
GET /api/json/posts/search/published?query=elixir&locale=en
GET /api/json/posts/semantic-search/published?query=elixir
GET /api/json/posts/autocomplete/published?prefix=eli
```

They take the same params minus `state` (the twins have no such argument — the
filter cannot be widened) and keep the same relevance/distance ordering and
pagination. **A delivery key minted by an admin is the case that matters**: on
the base routes it reads gated and locked content; on the twins it reads
neither.
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

## Calculated fields

Every content type also exposes these derived, read-only fields — public
calculations rather than stored columns, so `?fields[post]=title,path` (or any
other explicit selection) is required to load one; they are not returned by
default. `GET /api/json/open_api` describes each of them on the resource's
`attributes` schema.

| Field | Type | Filterable / sortable |
|-------|------|------------------------|
| `path` | string | No — full public URL path (`/blog/my-post`); see [URLs, pathauto & redirects](#urls-pathauto--redirects) |
| `published` | boolean | Yes — convenience flag for `state == :published` (a real SQL expression, unlike the rest of this table) |
| `word_count` | integer | No — total word count across the block tree |
| `reading_time_minutes` | integer | No — `word_count` ÷ the configured words-per-minute rate |
| `effective_seo_title` | string | No — the author's `seo_title`, else the type's pattern expanded (#1102) |
| `effective_seo_description` | string | No — same as above, for `seo_description` |
| `related_links` | array | No — curated related links, projected to `[{id, title, slug}]` |

"No" means exactly that — not merely undocumented as a filter or sort:
`?filter[path]=…` is a clean `400 invalid_filter`, and `?sort=path` is
likewise a clean `400 invalid_sort`, not a match on nothing. These fields
have no SQL expression to filter or sort by (they are computed in Elixir,
several from data outside the row itself — the type registry, the block
tree), so the write side of that query would have nothing to push down to
Postgres. `published` is the one exception: it is a real `state ==
:published` SQL expression, so both filtering and sorting work normally.

## URLs, pathauto & redirects

Slugs auto-derive server-side (focus keyphrase → title, stop words stripped,
collision-deduped `base-2`, `base-3`, …), so a `POST` with just a `title` gets
a final slug back — never implement slugging client-side. A content type may
also define a pathauto-style **slug pattern** (`TypeDefinition.slug_pattern`
or the Content macro's `slug_pattern:` option) such as `[yyyy]-[mm]-[title]`,
which then drives derivation for that type; tokens are `[title]`,
`[focus-keyphrase]`, `[category]`, `[yyyy]`, `[mm]`, `[dd]`, composing the
final URL segment (the type's path prefix stays in front). Date tokens anchor
to the publish date, else the scheduled date, else the record's creation
date; a pattern that expands to nothing for a record (e.g. `[category]` on an
uncategorized entry) falls back to the default derivation, so a title alone
is still always enough. Three surfaces let a
front end handle URLs without mirroring Kiln's scheme:

- **`path` field** — every content read exposes a `path` calculation, the full
  public path (`/blog/my-post`, `/about`, `/<path_segment>/<slug>` for dynamic
  types). Request it explicitly: `?fields[post]=title,slug,path`.
- **`path_alias`** — an optional multi-segment canonical URL
  (`/acupuncture/needle/size/14mm`), settable over the write API. When set it
  becomes the record's `path`; the flat `/<prefix>/<slug>` URL 301s to it, and
  changing or removing it on published content leaves a 301 behind like any
  slug rename. `GET /api/resolve` reports the flat path as `moved` and the
  alias as `ok`.
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
| `PATCH /api/json/posts/:id/return-to-draft` | `:return_to_draft` | `:read_write` key, **admin** | in_review → draft — the return half of the approve/return pair |
| `PATCH /api/json/posts/:id/publish` | `:publish` | `:read_write` key, **admin** | Publishes and fires artifacts |
| `PATCH /api/json/posts/:id/unpublish` | `:unpublish` | `:read_write` key, **admin** | Takes content down, purges artifacts |
| `DELETE /api/json/posts/:id` | `:destroy` | `:read_write` key, **admin** | **Reversible** soft-delete (AshArchival) |

Pages expose the identical set; the dynamic tier is `/api/json/entries` (a
`create` needs a `type_definition_id` — discover types via `/mcp`'s
`read_type_definitions`).

**Authorization** mirrors `/mcp`: a **read-only key** can run none of these; a
**`:read_write` key on a `:viewer`** account can run none; a **`:read_write` key
on an `:editor`** can create/update/submit; **return-to-draft, publish, unpublish
and delete require an `:admin`** account. An editor submits for review; deciding
the outcome — approve or return — is the admin's half. Hard delete (`:purge`) is **never** routed and is
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

### Writing tags — replace vs merge

`tag_ids` is the content's **complete** tag set (append-and-remove), so a
`PATCH` carrying a partial list detaches everything omitted. A partial writer
should use the merge verbs on `PATCH /:id` instead (#521):

| Attribute | Semantics |
|---|---|
| `add_tag_ids` | Attaches the listed tags and leaves the others alone. Re-adding an attached tag is a no-op; a repeated id is de-duplicated; an id that matches no tag is a `404` (`not_found`, no field pointer — the lookup, not the record, is what failed). |
| `remove_tag_ids` | Detaches the listed tags and leaves the others alone. Removing a tag that isn't attached — or an id that matches no tag at all — is a silent no-op, so retries are safe and a wrong id is *not* reported. |
| `tag_ids` | **Replaces** the set. Omitting it leaves tags untouched; both `[]` and `null` clear them. |

```bash
curl -X PATCH http://localhost:4000/api/json/posts/<uuid> \
  -H "authorization: Bearer $KILN_API_KEY" \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data":{"type":"post","id":"<uuid>","attributes":{"add_tag_ids":["<tag-uuid>"]}}}'
```

`tag_ids` may not be sent alongside either merge verb, and an id may not appear
in both `add_tag_ids` and `remove_tag_ids` — both are rejected with a `400`
rather than resolved in some arbitrary order. "Alongside" includes
`"tag_ids": null`, which clears rather than being ignored; an empty
`add_tag_ids`/`remove_tag_ids` carries no intent and is not a conflict, so a
client that always serializes all three keys still gets the replace path. The same three attributes exist on
GraphQL's `updatePost` (`addTagIds` / `removeTagIds`) and on the MCP `update_*`
tools. They are **update-only** — `POST` has no existing links to merge against,
so a create takes `tag_ids` alone.

The related-content arrays carry the **same** verbs (#637): `related_post_ids`
replaces, and `add_related_post_ids` / `remove_related_post_ids` merge, with
identical rules (an explicit `null` in the complete-set argument counts as
replacing; the same id may not appear in both verbs). The sibling arrays follow
the same naming — `add_related_page_ids` / `remove_related_page_ids`, and
`add_related_entry_ids` / `remove_related_entry_ids` on the dynamic tier.

### Writing body content — the `block_tree` attribute

The typed `blocks` union isn't exposed on the auto API (it isn't `public?`), so
body content is written through a public **`block_tree`** attribute: an array of
block maps (the same shape the editor and MCP submit), cast into the union —
which **sanitizes** rich-text HTML and media URLs. On an update, **omit**
`block_tree` to leave the body untouched (a metadata-only `PATCH` never wipes
it); send `[]` to clear it.

**Round-trip block ids when updating.** Read the tree's identity first — the
`block_ids` calculation (`?fields[post]=block_ids`) projects the stored tree to
`_id`/`_type` only, nested `columns` children included in the positions they
render — and echo each block's `_id` on the maps you send back. That is what
lets the server tell an in-place edit from a replacement; on a page carrying an
admin-set nested value (a field behind `editable_by`), a non-admin write that
drops the ids is **refused** (#954), with the error naming this surface. The
fired `:json` artifact carries the same `_id`s for published content.

### Re-fire semantics

Firing (immutable per-surface artifact regeneration) is bound to `:publish`, so
the publish route re-fires automatically. Editing already-published content with
`PATCH /:id` **also** re-fires (a `published`-guarded re-fire on `:update`,
#330), so a write-through to live content never leaves a stale artifact. Draft
edits do not fire.

### Workflow routes take an empty resource object

The workflow `PATCH` routes (`/publish`, `/unpublish`, `/submit-for-review`,
`/return-to-draft`) carry no attributes — send the JSON:API resource identifier only:

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
