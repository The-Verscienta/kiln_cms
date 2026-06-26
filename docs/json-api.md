# Headless JSON:API

KilnCMS exposes a [JSON:API](https://jsonapi.org/)-compliant read surface for
headless consumers at **`/api/json`** (powered by
[AshJsonApi](https://hexdocs.pm/ash_json_api)). This document covers the
filtering, sorting and pagination query params for the public content types —
**Page**, **Post** and **MediaItem** — tuned in Phase 5 (issue #33).

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
| Page      | `GET /api/json/pages`       | `GET /api/json/pages/:id`   | `/pages/search`, `/pages/autocomplete` |
| Post      | `GET /api/json/posts`       | `GET /api/json/posts/:id`   | `/posts/search`, `/posts/autocomplete`, `/posts/published` |
| MediaItem | `GET /api/json/media-items` | `GET /api/json/media-items/:id` | `/media-items/search` |

`GET /api/json/posts/published` returns published posts only, ordered newest
first — the headless blog feed.

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

## Sparse fieldsets & includes

Standard JSON:API `fields[<type>]` and `include` params work too, e.g.
`?include=category&fields[post]=title,slug`. The embedded block tree is **not**
exposed over JSON:API — rendered content is served as fired artifacts at
`GET /api/content/:type/:slug`.
