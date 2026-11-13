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

**Try it now.** [kilncms.dev](https://kilncms.dev) runs Kiln, and its guides
are published entries of a dynamic `doc` type, so these reads answer
anonymously. `-g` stops curl from reading the brackets as a URL range:

```bash
A='accept: application/vnd.api+json'

# The delivery feed, with a sparse fieldset and a page size
curl -g -H "$A" 'https://kilncms.dev/api/json/entries/published?filter[type_name]=doc&fields[entry]=slug,title&page[limit]=5'

# Filter by exact slug
curl -g -H "$A" 'https://kilncms.dev/api/json/entries?filter[type_name]=doc&filter[slug]=getting-started&fields[entry]=slug,title,published_at'

# One page by slug (locale fallback applies)
curl -g -H "$A" 'https://kilncms.dev/api/json/pages/by-slug/documentation?locale=en&fields[page]=slug,title'

# Published-only full-text search and typeahead
curl -g -H "$A" 'https://kilncms.dev/api/json/entries/search/published?query=migrations&fields[entry]=slug,title'
curl -g -H "$A" 'https://kilncms.dev/api/json/entries/autocomplete/published?prefix=dep&fields[entry]=slug,title'
```

The site has no categories or tags, so those routes answer an empty list,
and it does not publish its OpenAPI document. The rest of this page uses
`localhost:4000`, meaning a site of your own.

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

Anonymous means no `Authorization` header at all. A token that does not
verify (malformed, expired, another instance's) is a `401` `invalid_token`,
not an anonymous read; see
[api.md → Authentication](api.md#authentication).

## Routes

| Resource  | Collection                  | Single record               | Extra reads |
|-----------|-----------------------------|-----------------------------|-------------|
| Page      | `GET /api/json/pages`       | `GET /api/json/pages/:id`   | `/pages/by-slug/:slug`, `/pages/search`, `/pages/semantic-search`, `/pages/autocomplete`, `/pages/published` |
| Post      | `GET /api/json/posts`       | `GET /api/json/posts/:id`   | `/posts/by-slug/:slug`, `/posts/search`, `/posts/semantic-search`, `/posts/autocomplete`, `/posts/published` |
| MediaItem | `GET /api/json/media-items` | `GET /api/json/media-items/:id` | `/media-items/search`, `/media-items/library`; `PATCH /media-items/:id` edits metadata ([below](#editing-media-metadata)) |
| Category  | `GET /api/json/categories`  | `GET /api/json/categories/:id` | `/categories/by-slug/:slug` |
| Tag       | `GET /api/json/tags`        | `GET /api/json/tags/:id`    | `/tags/by-slug/:slug` |
| TagGroup  | `GET /api/json/tag-groups`  | `GET /api/json/tag-groups/:id` | `/tag-groups/by-slug/:slug` |
| Entry (dynamic types) | `GET /api/json/entries` | `GET /api/json/entries/:id` | same set as Post, filtered by `filter[type_name]=`; `/entries/by-slug/:slug` takes `?type_definition_id=` |
| TypeDefinition | `GET /api/json/type-definitions` | `GET /api/json/type-definitions/:id` | `/type-definitions/by-name/:name` — **editor-or-above** credential; see [Discovering dynamic types](#discovering-dynamic-types) |
| ContentRelease | `GET /api/json/releases` | `GET /api/json/releases/:id` | `?include=items` — **editor-or-above** credential, read-only; see [Content releases](#content-releases-read-only) |
| ReleaseItem | `GET /api/json/release-items` | `GET /api/json/release-items/:id` | `?filter[release_id]=` — same |
| ContentLink | — | `GET /api/json/content-links/:id` | `POST`, `PATCH /:id`, `DELETE /:id` write **payload links** — see [Writing relationships](#writing-relationships) |

`GET /api/json/<plural>/by-slug/:slug?locale=fr-CA` is the single published
document for a slug, resolved through the site's **locale fallback chain** —
`?locale=` is where the walk starts and defaults to the site's default locale
when left out (it was required, a `400`, before 1.7),
`?fallback=false` and `?fallback_locale=` narrow it, the served locale is
`attributes.locale` and the `x-kiln-locale` / `Content-Language` headers, and a
locale the site does not run is a `400`. See
[api.md → Locale fallback](api.md#locale-fallback). It authorizes like every
route here, so a caller sees exactly the variants the read policies let it
read; a variant it may not read is skipped along the chain like a missing one.
(Filtering the collection with `filter[slug]=…&filter[locale]=…` still works
and never falls back.)

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

## Content releases (read-only)

A **content release** (#500) is a named bundle of publishes and unpublishes that
goes live as one unit. Releases are composed and shipped in `/editor/releases`;
over the API they are **read-only**, for a headless editorial tool or a status
board that needs to know what is planned to go live and when.

| Route | Answers |
|-------|---------|
| `GET /api/json/releases` | Every release in the request's org; `filter[state]=scheduled`, `sort=scheduled_at`, `page[...]` as usual |
| `GET /api/json/releases/:id` | One release; add `?include=items` for its contents |
| `GET /api/json/release-items` | Release items; `filter[release_id]=<id>` for one release's |
| `GET /api/json/release-items/:id` | One item |

A release (`type: "release"`) carries `name`, `description`, `state` (`open`,
`scheduled`, `publishing`, `published`, `failed`, `rolling_back`,
`rolled_back`, `archived`), `scheduled_at`, `published_at`, `rolled_back_at`,
`failure_reason` and `failed_item_id`. An item (`type: "release_item"`) carries
`release_id`, `content_type` + `content_id` (the document it acts on — fetch it
through that type's own route, under that route's own read policy), `action`
(`publish` / `unpublish`), `status` (`pending`, `applied`, `skipped`,
`cancelled`, `rolled_back`), `prior_state`, `prior_version_id` and `applied_at`.
Who created, triggered or added to a release is not exposed — those are user
ids.

Same read and policy as the console: the credential must belong to an **editor
or admin of the request's org** (a read-only key is enough). A viewer's key or
an anonymous caller gets an empty list and a `404` on a single record; the host
bounds the org, as everywhere else.

There are **no write routes**. Shipping a release publishes every item it holds
as the admin who triggered it — an admin approval step that stays in the
console — so neither composing nor scheduling a release is reachable from a key.

```bash
# What goes live next, with its contents
curl -s 'http://localhost:4000/api/json/releases?filter[state]=scheduled&sort=scheduled_at&include=items' \
  -H 'accept: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY"
```

A document's own version history is not a JSON:API resource — see
[api.md → Version history](api.md#version-history-revisions).

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
editorially. Note a bad name in `sort` fails the request (it is not silently
ignored), so a naive client renders an empty page — check the error body. A
public field that exists but isn't sortable is `400 invalid_sort` — see
[Calculated fields](#calculated-fields). Any other name is looked up as a
custom field, so an unknown or non-public one is `400 invalid_argument` with
detail `unknown custom field "<name>"` (see
[Naming a custom field like a column](#naming-a-custom-field-like-a-column)).

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
A custom field can lead the order instead: `custom_sort=-price` on a search
route, see "Sorting" under "Custom fields" below.

## Custom fields (`custom_filter` / `custom_sort`)

A **private** custom field (`private: true`, see
[extending-content.md](extending-content.md)) is not in `custom_fields` for a
caller below editor, and naming it in `custom_filter` or `custom_sort` is a
`400` for them, as for a field that does not exist. The same holds for an
editor whose role hides that private field from them (a read restriction,
see [granular-rbac.md](granular-rbac.md#per-custom-field-grants-and-read-restrictions)),
and a create or update response omits it too.

Admin-defined custom fields (see
[extending-content.md](extending-content.md)) live in one `custom_fields`
JSONB map, so the derived `filter[...]`/`sort=` machinery above can't reach
them. Two dedicated params close the gap (and a field's bare name works in
`filter[...]` / `sort=` too, see "Naming a custom field like a column" below):

```
# Equality (bare value) and operators
GET /api/json/posts?custom_filter[color]=red
GET /api/json/posts?custom_filter[price][gt]=10

# Combined, and mixed with regular filters
GET /api/json/posts?filter[locale]=en&custom_filter[price][lte]=20&custom_sort=-price
```

**Filtering** — `custom_filter[<name>]=<value>` (equality) or
`custom_filter[<name>][<op>]=<value>` with `eq`, `not_eq`, `gt`, `gte`, `lt`,
`lte`, `in`, `ilike`, `contains`, `starts_with`, `null` (`is_nil` is a synonym). Conditions are ANDed (with each other and with
`filter[...]`). Semantics:

- Field names are validated against the `FieldDefinition` registry — an
  unknown name is a **400**, not an empty result.
- Values are cast to the field's declared type and compared **as jsonb**, so
  an `integer`/`float` field compares numerically (`9 < 10`), `boolean` as a
  boolean, and `date`/`datetime` (ISO-8601 strings) chronologically.
- `in` matches any of a list: `custom_filter[color][in][]=red&custom_filter[color][in][]=blue`.
- **Equality operands also match the value as a save stores it.** A save
  tidies some types: it trims a string or URL, stores a select option's
  value when given its label, and gives an email, color, telephone, time or
  slug its canonical spelling ([Built-in format types](extending-content.md#built-in-format-types)).
  On a single field of one of those types, `eq` (or a bare value), `not_eq`
  and each item of `in` match the operand both as sent and as a save would
  have stored it: `#FFF` finds `#ffffff`, `a@Example.com` finds
  `a@example.com`, `+44 20 7946 0958` finds `+442079460958`, `9:30` finds
  `09:30`, `Hello World` finds the slug `hello-world`, and an option's label
  (in any letter case) finds the option. Matching the operand as sent as
  well means a value stored before the field's type changed (a string field
  holding `#FFF`, since made a color field) is still found by its own
  spelling. `not_eq` leaves out both spellings, so
  `custom_filter[accent][not_eq]=#FFF` drops records holding `#FFF` and
  `#ffffff`.
  - Range operators (`gt`, `gte`, `lt`, `lte`) and `ilike`, `contains` and
    `starts_with` take the operand as sent: a time's tidy drops its seconds,
    which would move a range bound, and a pattern is not a value.
  - A `text` field and a plugin's field type compare the operand as the text
    sent; numbers, booleans, dates and date-times are cast as above.
  - An operand the field could never hold (`custom_filter[email]=foo` on an
    email field) matches nothing. It is not a `400`.
- **One value per operator, a list only for `in`.** An object operand
  (`custom_filter[subtitle][eq][x]=1`, or a JSON object from GraphQL
  `customFilter` or an MCP read tool), or a list beside any operator other
  than `in` (`custom_filter[subtitle][ilike][]=a`), is a `400`
  `invalid_argument` whose `detail` names the operator and the field:

  | Operand | `detail` |
  |---|---|
  | an object | `eq on custom field "subtitle" takes a value, not a nested filter` |
  | a list beside `ilike`, `eq`, `gt`, … | `ilike on custom field "subtitle" takes one value, not a list` |
  | an object or a list as an item of `in` | `in on custom field "subtitle" takes a value, not a nested filter` (or `takes one value, not a list`) |
  | `null` (JSON) for `ilike` | `invalid value for custom field "subtitle"` |

  A link field says `link field "cta.link.label"` instead. This holds on
  media and reference fields too, so `[eq][]=<id>` is refused: write
  `[in][]=<id>`.
- `ilike` (text-like fields only) takes the usual `%` wildcards:
  `custom_filter[subtitle][ilike]=%leather%`.
- `contains` / `starts_with` (text-like fields only) match case-insensitively
  and take the value literally: `%`, `_` and `\` are escaped, unlike `ilike`.
  GraphQL's typed `customWhere` uses them too
  ([headless-graphql-api.md](headless-graphql-api.md)).
- `null` takes `true`/`false` and tests whether the record has the field at
  all. `is_nil` is accepted as the same operator, so `filter[x][is_nil]=true`
  reads the same on a column and on a custom field.
- `media`/`reference` fields match on their snapshot's stable `id`
  (`custom_filter[hero_image]=<media uuid>`) and support `eq`/`not_eq`/`in`/`null`
  (references also take the relationship operators below).
  On a media **gallery** or a **list of references** (`multiple: true`) they
  test membership: `eq` matches a list holding that id, `not_eq` one that
  doesn't, `in` one holding any of the listed ids.
- A **list of values** (`multiple` on a string, select, number, date, link,
  … field) reads the same way for its items and also takes `has`,
  `has_all`, `has_none` and `count`; see [Lists of values](#lists-of-values).
- Records without the field are excluded by every comparison (they're SQL
  `NULL`), and a record whose stored value has another JSON type simply
  doesn't match — it can't error the query.

**Relationship operators** — a `reference` field, single or a list, also
takes `has` (holds any of the ids), `has_all` (holds every one), `has_none`
(holds none of them) and `count` (how many targets it holds, compared with
`eq`, `gt`, `gte`, `lt`, `lte`; a bare number means `eq`):

```
GET /api/json/posts?custom_filter[ingredients][has][]=<id>&custom_filter[ingredients][has][]=<id>
GET /api/json/posts?custom_filter[ingredients][has_all][]=<id>&custom_filter[ingredients][has_all][]=<id>
GET /api/json/posts?custom_filter[ingredients][has_none]=<id>
GET /api/json/posts?custom_filter[ingredients][count][gte]=3
```

The same three set operators work on the built-in relationships `tags` and
`related_<type>s` (`related_posts` on posts, `related_pages` on pages, …):

```
GET /api/json/posts?custom_filter[tags][has_all][]=<tag id>&custom_filter[tags][has_all][]=<tag id>
GET /api/json/posts?custom_filter[related_posts][has_none]=<post id>
```

An included `related_<type>s` list comes back in the order the editor set
(each link's `position`), as does the `related_links` projection
(`fields[post]=related_links`, `{id, title, slug}` per record).

- They read the relationship's edges (`content_links`, or the taggings),
  through their indexes, rather than the stored snapshot. `eq`/`in` keep the
  snapshot meaning above, and every operator can be combined on one field.
- `has`, `has_all` and `has_none` take one id or a list of at most 100;
  an empty list, or something that is not an id, is a **400**. `count` takes
  a whole number ≥ 0.
- **A target you may not read is not there.** A draft (or audience-gated,
  or locked) target never matches `has`/`has_all`, is not counted by `count`,
  and `has_none` of it is true — exactly what you would see if it did not
  exist, so a filter cannot be used to find out that a draft exists. An
  editor's token sees drafts here as everywhere else.
- `tags` and `related_<type>s` take `has`, `has_all` and `has_none` only.
  A custom field that happens to be named `tags` keeps the name: on such a
  type `custom_filter[tags]` means the field.
- The derived `filter[tags][id][in][]=<id>` (any of) still works as before.
- **Cost.** `has`, `has_all` and `has_none` are index probes per candidate
  record, about a millisecond in the database on 600k edges. `count`
  aggregates each candidate's edges, so it costs in proportion to the
  records scanned to fill the page, not the page size: about 100 ms when
  every one of 20,000 records has to be looked at, a few milliseconds when
  the first matches fill the page. Pair it with a narrowing filter on a big
  type. The numbers are in [relationships-plan.md](relationships-plan.md),
  workstream R6.

**Link fields** — a reference field's link fields (data on each
connection, R3; see [extending-content.md](extending-content.md) §1) filter
under `<field>.link.<name>`, with the scalar operators (`eq`, `not_eq`,
`gt`, `gte`, `lt`, `lte`, `in`, `ilike`, `null`), cast to the link field's
type:

```
GET /api/json/posts?custom_filter[ingredients.link.role]=main
GET /api/json/posts?custom_filter[ingredients.link.quantity][gte]=100
```

- A record matches when **some** connection of that field carries a
  matching value. Two operators on the same link field are separate
  conditions and may be met by different connections.
- They read the edges' `metadata` (the copy of each snapshot's `"link"`
  map), under the same read rule as the relationship operators: a
  connection to a target you may not read is not there, so a link value
  cannot be used to learn that a draft target exists.
- **`target`** ties the condition to particular records: beside the
  operators, it narrows them to the connections pointing at those ids. "Is
  *this* person the photographer?" rather than "is anyone?":

  ```
  GET /api/json/posts?custom_filter[contributors.link.role][eq]=photographer&custom_filter[contributors.link.role][target]=<author id>
  ```

  It takes one id or a list (`[target][]=…`, at most 100), and needs an
  operator beside it (a bare value can't carry one, so write `[eq]`).
  Several targets match a record where any one of them has the value.
- On a string, URL or select link field, `eq`, `not_eq` and `in` match the
  operand as sent and as a save stores it (trimmed, an option's label as its
  value), as on a field. An object operand, or a list beside any operator
  other than `in`, is a `400`: `ilike on link field
  "ingredients.link.role" takes one value, not a list`.
- An unknown link field, or a field that is not a reference, is a **400**.
  `customFilter` in GraphQL takes the same key: `{"ingredients.link.role":
  "main"}`, and `{"contributors.link.role": {"eq": "photographer",
  "target": "<id>"}}`.

In the response a reference's snapshot carries its link values as an added
`"link"` map — `{"id", "type", "slug", "title", "link": {"role": "main"}}`
— and `?include=content_links` serves the same map as each edge's
`metadata`. A connection with no link value has no `"link"` key.

**Sorting** — `custom_sort=<name>` (ascending) or `custom_sort=-<name>`,
comma-separated for multi-key. Records lacking the field always sort last, as do those storing a JSON
`null`, array or object under it (read as no value).
`custom_sort` composes with `sort=`: explicit `sort` keys take precedence, but
`custom_sort` outranks an action's *default* order (e.g. `/posts/published`'s
`-published_at`). `media`/`reference` fields are not sortable: the `400` says
why. Their stored label can lag the target's current title (a read relabels it
from the target as it is now), and an order over targets the caller may not read
would reveal where they sit, so a reference or media sort is refused rather than
ordered by a stale or leaky key. Sort by a built-in or a text custom field instead.

A built-in column can follow a custom one in the same order by spelling it
`_native:<name>` in `custom_sort`: `custom_sort=price,_native:title` or
`custom_sort=-price,-_native:title`. You rarely write this by hand: `sort=price,title`
is rewritten to it (see below). It takes any public attribute, calculation or
aggregate that `sort=` takes.

**Boolean groups** — `custom_filter` conditions are ANDed. To OR them, negate
them or mix them with built-in columns, use the group keys `_or`, `_and` and
`_not` (they start with `_`, so no field name can collide with them):

```
GET /api/json/posts?custom_filter[_or][0][price][gt]=100&custom_filter[_or][1][color]=red
GET /api/json/posts?custom_filter[_not][color]=red
GET /api/json/posts?custom_filter[_or][0][price][lt]=10&custom_filter[_or][1][_native][title]=Sale
```

`_or` / `_and` hold a list of conditions (a map keyed `0`, `1`, … in a query
string); `_not` holds one condition. A condition is a map of custom field names
to the operators above, may itself hold `_or` / `_and` / `_not`, and may hold
`_native`: a map of built-in `filter[...]` conditions (`title`, `state`,
`tags[slug]`, …) parsed exactly as `filter[...]` is. Keys of one condition are
ANDed. Groups nest at most 4 deep and hold at most 50 conditions in all.
Everything else is unchanged inside a group: an unknown or private field is the
same `400` as outside one, definitions are read for the requesting site only,
and `not` follows SQL, so `_not` of a comparison leaves out records lacking the
field. GraphQL takes the same keys in `customFilter` (built-in names there are
snake_case); `customWhere` has no groups.

Custom sorts are always **nulls last**, ascending or descending. A native
`sort=-x` is plain `desc`, which in Postgres puts nulls first.

### Typed conditions (`custom_where`)

`custom_where` is the typed form of `custom_filter`. It's here for parity with
GraphQL's `customWhere` and the [MCP read tools](mcp.md#tools). A condition
names a field and gives exactly one kind key (`string`, `int`, `float`,
`boolean`, `date`, `date_time`), which must be the field's kind. The kinds,
their operators and the limits are in
[headless-graphql-api.md](headless-graphql-api.md#typed-filters-customwhere);
spell them snake_case here (`date_time`, `not_eq`, `starts_with`, `is_null`).

A query string carries **one condition**, with as many operators as you like:

```
GET /api/json/posts?custom_where[][name]=price&custom_where[][int][gt]=10
GET /api/json/posts?custom_where[][name]=price&custom_where[][int][gt]=10&custom_where[][int][lte]=50
GET /api/json/posts?custom_where[][name]=price&custom_where[][int][in][]=10&custom_where[][int][in][]=20
```

- Every `custom_where[][…]` pair lands in the same list item, so a second
  `[name]` replaces the first and its operators join the first condition. For
  conditions on several fields, use `custom_filter`: it takes the same
  operators (there the null test is `null`, not `is_null`), and groups too.
  This is how the query-string decoder (Plug) reads repeated `[]` keys, which
  Plug itself calls unspecified; a test pins it, but prefer `custom_filter`.
- The indexed form (`custom_where[0][name]=price`) is a `400`
  `invalid_query`. The query string decodes it to a map, and the parameter is
  a list.
- A wrong kind, an unknown operator or a bad operand is a `400`
  `invalid_argument`, as in `custom_filter`. A wrong kind's `detail` names the
  field's own kind.

### Lists of values

A custom field with `multiple: true` of a scalar type holds a JSON array: a
list of strings or select terms, or a typed list of integers, floats, dates,
date-times, times, URLs, emails, phone numbers, colours or slugs
([extending-content.md](extending-content.md#make-a-field-hold-a-list-of-values)).
Write it as an array; read it back as the array the field stored, tidied and
in order:

```bash
curl -s -X PATCH http://localhost:4000/api/json/posts/$ID \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{"data": {"type": "post", "id": "'$ID'", "attributes": {
        "custom_fields": {"scores": ["3", 5, 5], "event_dates": ["2026-03-08", "2026-03-01"]}}}}'
```

```json
"custom_fields": {"scores": [3, 5, 5], "event_dates": ["2026-03-08", "2026-03-01"]}
```

On such a field `custom_filter` asks about the items:

```
GET /api/json/posts?custom_filter[scores]=5
GET /api/json/posts?custom_filter[scores][has][]=3&custom_filter[scores][has][]=7
GET /api/json/posts?custom_filter[event_dates][has_all][]=2026-03-01&custom_filter[event_dates][has_all][]=2026-03-08
GET /api/json/posts?custom_filter[scores][count][gte]=2
```

| Operator | Matches a record whose list… | A record with no value |
|---|---|---|
| `eq` (or a bare value) | contains the value | no match |
| `not_eq` | does not contain the value | no match |
| `in` | contains any of the values | no match |
| `has` | contains any of the values (one, or a list of at most 100) | no match |
| `has_all` | contains every one of them | no match |
| `has_none` | contains none of them | **matches** |
| `count` | has that many items: a whole number (`eq`) or `eq` / `gt` / `gte` / `lt` / `lte` | counts as 0 |
| `null` | has no value (`true`) or has one (`false`) | per the operand |

- **`has_none` and `not_eq` differ on purpose.** `has_none` asks "is none of
  these in the list", which an empty field answers yes, as a reference's
  `has_none` does. `not_eq` compares against a value, and like every
  comparison it leaves out a record without one.
- **Operands are tidied as the items were.** On a typed list each operand is
  checked and tidied as a stored item is, so `#FFF` finds `#ffffff`, `9:30`
  finds `09:30`, `a@Example.com` finds `a@example.com`, `"10"` finds the
  number `10` on an integer list, and `10` finds `10.0` on a float list. An
  operand the field could never hold is a `400` (`invalid date value`).
  A single email, color, telephone, time, slug, string, URL or select field
  tidies its `eq`, `not_eq` and `in` operands too, and also matches them as
  sent (see "Equality operands also match the value as a save stores it"
  under **Filtering** above). An object operand
  (`custom_filter[event_dates][eq][year]=2026`) is a `400` on every list, as
  on a single field.
- **A value stored before the field was a list** (a field retyped, or
  switched to a list while a reshape did not finish) is read as a one-item
  list by every operator: `eq` matches it, `count` counts it as 1, and it
  never makes the query fail.
- **Not supported yet:** comparing items (`gt`, `gte`, `lt`, `lte`) and
  matching text in them (`contains`, `starts_with`, `ilike`). They answer
  `400`: `gt is not supported on custom field "scores" (a list): it supports
  eq/not_eq/in/has/has_all/has_none/count/null`.
- **Not sortable.** `custom_sort=scores` is a `400`: `custom field "scores"
  (a list) is not sortable`.
- **`has` / `has_all` / `has_none`** take one value or a non-empty list of at
  most 100 (`has_all for "scores" needs at least one value`, `has for
  "scores" takes at most 100 values`). `count` takes a whole number ≥ 0.
- **Entries.** On `/api/json/entries` without `filter[type_name]`, a field
  name that is a typed list on one dynamic type and a single value on another
  is the same `400` as a type mismatch (`has a different type per content
  type`); scope the query.
- **A single field sent an array** keeps the array's first non-blank item,
  so send one value. An object item there is refused (`must be a single
  value`).

### Naming a custom field like a column

In `filter[...]` and `sort=` on the
index routes you can drop the `custom_` prefix. A name that is not a public
attribute, calculation, aggregate or relationship of the type is looked up as a
custom field:

```
GET /api/json/posts?filter[price][gt]=10&sort=title,price
GET /api/json/posts?filter[tags][has_none][]=<tag id>
```

- **A built-in name always wins.** `filter[title]` is the column. Use
  `custom_filter[title]` / `custom_sort=title` for a custom field that shares a
  column's name. They always mean a custom field.
- **`custom_filter` / `custom_sort` are the stable form.** If a later release
  adds a built-in with your field's name, `filter[x]` silently starts meaning
  the built-in. Programmatic consumers should keep sending `custom_*`; the
  official clients do.
- **Tokens keep the order you wrote.** `sort=title,price`, `sort=price,title`
  and `sort=title&custom_sort=price` all work. Built-in tokens that lead stay in
  `sort`; from the first custom token on, every token moves to `custom_sort`, a
  built-in one as `_native:<name>`. Tokens found in `sort` run before an explicit
  `custom_sort`. (Before, `sort=price,title` was a `400` `invalid_sort`.)
- **Groups in `filter[or]` / `[and]` / `[not]`.** While every name inside is a
  built-in the group is native. When any condition inside names a custom field
  (`filter[or][0][price][gt]=100&filter[or][1][title]=Sale`) the whole group moves
  to `custom_filter[_or]` with its built-ins under `_native`, so the two spellings
  mean the same. If `custom_filter` already holds that group key, `filter` is left
  as written (a native `400`).
- **Both spellings together.** `filter[x]` and `custom_filter[x]` for the same
  custom field merge into one condition. A built-in `x` applies both (ANDed). The same
  operator on both is a `400`.
- **Unknown names.** `filter[ttile]=x` and `sort=ttile` are `400`
  `invalid_argument`, detail `unknown custom field "ttile"`, with no `source`
  member. Before this, `filter[ttile]` got ash_json_api's own "No such field".
  A private field answers the same way for a caller below editor, so the
  message does not reveal it exists. An anonymous typo costs one uncached
  registry read before the `400`.
- **Built-in relations.** `filter[tags][has][]=…`, `has_all`, `has_none` and
  `count` work natively on `tags` and `related_<type>s`
  (`filter[related_posts][has_none]=<id>`). `filter[tags][slug]=x` stays the
  derived relationship filter.
- **Only index routes.** Get-by-id, relationship routes and writes are not
  rewritten.
- **OpenAPI.** The `sort` parameter's `format` lists built-in fields only. A
  client that validates `sort` strictly against it rejects `sort=price`; use
  `custom_sort` there.
- **`links.self`** echoes the URL as you sent it, with the original
  `filter[price]` / `sort=price`.

What differs between a custom field and a column, in one table:

| | Custom field | Column |
|---|---|---|
| Operators | `eq`, `not_eq`, `gt`, `gte`, `lt`, `lte`, `in`, `ilike`, `contains`, `starts_with` (the last three text only), `null` / `is_nil` | the derived ash_json_api set |
| Value typing | cast to the field's declared type, compared as jsonb | the attribute's type |
| Records without the field | excluded by every comparison | per the column's nulls |
| Unknown name | `400` `invalid_argument`, `unknown custom field "x"` | native `400` |
| Sort | nulls last in both directions; in the order written, with built-in keys mixed in | plain `asc` / `desc` |
| Sort on `media` / `reference` | not supported | n/a |
| Relationship operators (`has`, `has_all`, `has_none`, `count`) | on `reference` fields and on `tags` / `related_<type>s`; the same names on [lists of values](#lists-of-values) | not available |
| Index | the GIN index for equality and membership; ranges and sort only for a name in `indexed_custom_fields` ([Which custom filters use an index](#which-custom-filters-use-an-index)) | per column |

### Entries and search facets

**Entries (dynamic types)** — the same params work on `/api/json/entries`,
where the field's type is resolved through the query's
`filter[type_name]=<name>` (or `filter[type_definition_id]=<uuid>`) scope.
Unscoped queries still work when every dynamic type declaring the field agrees
on its type; if declarations diverge, the API asks you to scope rather than
guessing a cast ("has a different type per content type"). That includes a bare
`filter[x]` / `sort=x` without `filter[type_name]`.

**Search facets** — `/…/search` and `/…/semantic-search` accept
`custom_filter`, and, on `/search`, `/search/published`, `/semantic-search` and
`/semantic-search/published`, `custom_sort` (GraphQL `customSort`). Precedence
is explicit `sort` > `custom_sort` > relevance (distance on semantic search) >
recency. On semantic search a leading custom sort replaces the distance order
(the vector index cannot serve it) and the rule that a record whose name
matches the query comes first no longer holds. `/autocomplete` does not take
`custom_sort`.

> **Performance.** These predicates run on JSONB extractions. Equality and
> membership use one GIN index; ranges and sorts are unindexed unless the
> field is listed in `indexed_custom_fields` (see
> [Which custom filters use an index](#which-custom-filters-use-an-index)).
> They're built for the long tail of editor-owned fields; a field you filter
> or sort by on every request belongs as a real attribute (promote the type /
> add the column, D4). GraphQL exposes the same capability as `customFilter` /
> `customSort` arguments — see
> [headless-graphql-api.md](headless-graphql-api.md).

### Which custom filters use an index

Since #2291 a GIN index (`jsonb_path_ops`) on each content table's
`custom_fields` serves the filters that ask "does this record hold exactly
this value": `eq` (a bare value), `in`, membership in a media or reference
field (`eq`, `in`) or in a [list of values](#lists-of-values) (`eq`, `in`,
`has`, `has_all`), and a single media or reference field matched by id. One index covers every field name of every
dynamic type. The rows returned are the same as before; only the speed
changes, and the planner still prefers a scan when a filter matches a large
share of the table.

These are **not** accelerated by default: `not_eq`, `gt`, `gte`, `lt`, `lte`,
`ilike`, `contains`, `starts_with`, `null`, `has_none` and `count` on a list
of values, and `custom_sort`. `not_eq` stays on the older `->` form on
purpose, because a record without the field must stay excluded from it.

The index costs about 26% of the table's size, slows bulk inserts by about
25% and single saves by 10-35%; see
[Custom-field filters at 100k rows](benchmarks.md#custom-field-filters-at-100k-rows)
for the method and the caveats.

#### Range filters and sort for a hot field (`indexed_custom_fields`)

If a field is range-filtered or sorted on, and promoting it to a compiled
attribute (the D4 answer in
[dynamic-content-types-plan.md](dynamic-content-types-plan.md)) is more than
you want, list its name in the config of the build that runs `mix ash.codegen`
(an overlay keeps it in its own `config/config.exs`). It is read at compile
time:

```elixir
config :kiln_cms, :indexed_custom_fields, ["price", "rating"]
# or, to index only one table's rows:
config :kiln_cms, :indexed_custom_fields, %{"entries" => ["price"]}
```

Then `mix ash.codegen indexed_custom_fields` and `mix ash.migrate`. Each name
gets two btrees per content table (`pages`, `posts`, `entries`, and an
overlay's own), `org_id` first: one `ASC NULLS LAST` and one `DESC NULLS
LAST`, built concurrently. Nothing is indexed unless you list it, and Kiln
never runs DDL itself.

What is accelerated, for a listed field:

| Request | Index |
|---|---|
| `custom_filter[price][gt]` / `gte` / `lt` / `lte` | yes |
| `custom_sort=price` and `custom_sort=-price`, with a page limit (also the keyset page after the first) | yes |
| `custom_filter[price]` (`eq`), `in` | the GIN index above |
| `not_eq`, `ilike`, `contains`, `starts_with`, `null` | no |

Rules to know:

- **Use it for integer, float, date and datetime fields.** A string btree can
  exceed the index row limit (about 2.7 KB); a boolean index is nearly useless.
  Values that are not the field's type (a string in an integer field) sort and
  compare by JSON type order, as before.
- **A range never matches a stored JSON `null`, array or object**, listed or
  not: they read as "no value", the way `custom_sort` has always read them.
- **Each btree costs writes.** `custom_fields` is rewritten on every save, so
  every listed name adds two index updates to each save of a record, whether
  or not that save changes the field. At 100,000 rows two fields (four btrees)
  next to the GIN index made 20,000 unrelated saves about 6x slower and 100,000
  inserts about 1.7x slower. See
  [the measurements](benchmarks.md#range-and-sort-indexes-for-custom-fields).
  List what you sort or range-filter on, per table where you can.
- **Adding a name, removing one, or renaming a field is a migration.** Add the
  name, generate, apply: queries answer correctly (from the table) until the
  concurrent build finishes. A failed build leaves an invalid index; drop it and
  rebuild.
- **Check for drift** with `mix kiln.custom_fields.index --check` (read-only,
  exits non-zero): a listed name with no or an invalid index, an index no name
  asks for, a name no field definition carries, an ineligible type.

The reasoning is in
[ADR 0025](decisions/0025-a-site-declares-which-custom-fields-get-range-and-sort-indexes-in-config.md).

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

### Media library browse (`/media-items/library`)

The media library's faceted browse. Every argument is optional; absent means
"don't filter on that axis", and they compose:

```
GET /api/json/media-items/library?kind=image
GET /api/json/media-items/library?tag_ids[]=<uuid>&unused=true
GET /api/json/media-items/library?uploaded_by_id=<uuid>&uploaded_after=2026-01-01&uploaded_before=2026-06-30
```

- `kind` — one of `image`, `video`, `audio`, `captions`, `document` (the
  `MediaKind` bucket, derived from `content_type`; also exposed as the
  filterable calculated field `kind` on the base route).
- `tag_ids[]` — items carrying **any** of the listed tags. Media shares the
  content taxonomy, so these are the same tags `/api/json/tags` lists; the
  `tags` relationship is includable (`?include=tags`) on every media read.
- `uploaded_by_id` — the uploading user's id. Ids only: like content's
  `author`, `User` is deliberately not a JSON:API resource (PII redaction),
  so there is no `?include=uploaded_by`.
- `uploaded_after` / `uploaded_before` — ISO dates bounding `inserted_at`,
  both inclusive of the named day.
- `unused=true` — only items with **no recorded reference from a published
  document** (`unused=false` inverts). "Used" is the reference-edge graph the
  fire path maintains, with that graph's lifecycle: references are recorded
  when a document publishes and replaced on its next publish — so an item
  referenced only by never-published drafts counts as unused, while a
  reference from a document that was later **unpublished** keeps counting as
  a use until that document publishes again without it — and a reference
  from a document that was **deleted** keeps counting indefinitely (nothing
  removes a deleted document's recorded references).

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
consumer can join outgoing/incoming relations (and e.g. per-link quantity
metadata) without extra requests.

Since 1.1 every `:reference` custom field value also has an edge (#1594):
`kind: "reference"`, with `field` naming the custom field (a list of
references, `multiple: true`, has one edge per item, `position` its 0-based
place in the list) and `source_type` /
`target_type` naming both ends' content types (the same vocabulary as the
snapshot's `"type"`; on a field that links to several types, each edge
carries its own item's type). So `?include=incoming_links` on a record answers *what
links here* — curated related content and references alike — and
`?include=content_links` gives a referrer's targets by id, which stay right
when a target is renamed, where the snapshot's `slug` and `title` may lag
until the referrer is next saved. The snapshot in `custom_fields` is
unchanged. `field`, `source_type` and `target_type` are `null` on curated and
payload links, and on links written before 1.1.

**The targets themselves, in one request.** `?include=content_links.target` is
not available: a reference can point at several content types, and a JSON:API
include follows a relationship to exactly one (relationships plan, §7 Q1).
Ask the delivery API instead —
`GET /api/content/:type/:slug?expand=<field>` returns each target's fired
`json` artifact under `"expanded"` ([api.md → Expanding references](api.md#expanding-references))
— or GraphQL's typed `references(field:)`
([headless-graphql-api.md → Relationships](headless-graphql-api.md#relationships-references-and-referencedby)).

**Writing a reference.** A `:reference` value is read back as the snapshot
`{"id", "type", "slug", "title"}` (a list of them when the field is
`multiple`), and a write accepts the same shape. What a write must carry
depends on how many types the field allows (`target_type` or
`target_types` on its `field_definition`; the schema export lists them as
`x-kiln-target-types`):

- **One type**: a bare id is enough (`"custom_fields": {"author":
  "<uuid>"}`), and so is a snapshot; its `"type"` is not consulted.
- **Several types**: every item names its type, `{"id": "<uuid>", "type":
  "post"}`. A bare id, or a type the field does not allow, is refused, naming
  the item. The id is looked up among that type's records only.

`slug` and `title` on input are ignored; the stored snapshot is always
re-read from the target.

An edge is returned only when the reader may read **both** of its ends: an
anonymous reader of a published page never sees the edge from a draft that
links to it, nor an edge to a target that has been unpublished. Editors and
admins see every edge of their site. The embedded block tree is **not**
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
| `path` | string | No — full public URL path (`/blog/my-post`); see *URLs, pathauto & redirects* below |
| `published` | boolean | Yes — convenience flag for `state == :published` (a real SQL expression, unlike the rest of this table) |
| `word_count` | integer | No — total word count across the block tree |
| `reading_time_minutes` | integer | No — `word_count` ÷ the configured words-per-minute rate |
| `effective_seo_title` | string | No — the author's `seo_title`, else the type's pattern expanded (#1102) |
| `effective_seo_description` | string | No — same as above, for `seo_description` |
| `related_links` | array | No — curated related links, projected to `[{id, title, slug}]`, in the order the editor set |
| `inherited_fields` | object | No — what this locale variant inherits along the site's fallback chain for its `:fallback` fields, with the source locale: `{"excerpt": {"value", "locale"}, "custom_fields": {…}}` (#1327). Served only when asked for with `fields[<type>]=…` |
| `latest_edit_severity` | string \| null | No — `critical` / `notable` / `routine`: how much the document's latest safety-field edit mattered. `null` when unpublished or none; see *Change severity* under Writing. Readable with a viewer key |
| `latest_edit_at` | datetime \| null | No — when that edit was made (the version's time, not `published_at`) |
| `custom_fields_plain` | object | No — the plain-text rendition of the `:text` custom fields marked "Also deliver as plain text" (`deliver_plain`): `{"<name>": "text without tags" \| null}`, `null` when the type marks none — one line, or with `"\n\n"` between paragraphs and `"\n"` per line break for a field marked "Keep paragraph breaks" (`plain_breaks`). `custom_fields` keeps the stored HTML. Served only when asked for with `fields[<type>]=…`; the fired artifact (`/api/content`, `/api/sync`) carries it whenever the type marks a field |
| `custom_fields_portable` | object | No — the Portable Text rendition of the rich `:text` custom fields marked "Also deliver as Portable Text" (`deliver_portable`): `{"<name>": [<Portable Text block>, …] \| null}`, the shape a `rich_text` block's `body` holds; `null` when the type marks none. `custom_fields` keeps the stored HTML. Served only when asked for with `fields[<type>]=…`; the fired artifact (`/api/content`, `/api/sync`) carries it whenever the type marks a field |

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
  (`/products/shoes/size/42`), settable over the write API. When set it
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
| `PATCH /api/json/posts/:id/publish` | `:publish` | `:read_write` key, **admin** (or editor where editors may publish) | Publishes and fires artifacts |
| `PATCH /api/json/posts/:id/unpublish` | `:unpublish` | `:read_write` key, **admin** (or editor where editors may publish) | Takes content down, purges artifacts |
| `DELETE /api/json/posts/:id` | `:destroy` | `:read_write` key, **admin** | **Reversible** soft-delete (AshArchival) |

Pages expose the identical set; the dynamic tier is `/api/json/entries` (a
`create` needs a `type_definition_id` — look it up with
`GET /api/json/type-definitions/by-name/:name`, see
[Discovering dynamic types](#discovering-dynamic-types); `/mcp`'s
`read_type_definitions` is the same read).

**Authorization** mirrors `/mcp`: a **read-only key** can run none of these; a
**`:read_write` key on a `:viewer`** account can run none; a **`:read_write` key
on an `:editor`** can create/update/submit; **return-to-draft and delete
require an `:admin`** account, and so do **publish and unpublish** unless the
site lets editors publish (Team → Publishing; see `scheduled_at` below). An
editor submits for review; deciding the outcome — approve or return — is the
admin's half, and so is taking content down (#2134). A refused route answers
`403` and changes nothing. Hard delete (`:purge`) is **never** routed and is
API-key-banned regardless of scope — `DELETE` is the reversible soft-delete.

A **`:draft_write` key** (#2273) may `POST` a create and `PATCH` a draft its
account authored while it is still a draft, whatever the owner's role; every
other route in the table is refused, as are tag, category, link and media
writes. A create may send `X-Kiln-On-Behalf-Of: <your user id>`, which Kiln
stores on the draft (`on_behalf_of`, beside `created_via_key_id` /
`created_via_key_name`) for reviewers; those three attributes are returned only
to editors, admins and the creating key. See
[headless-consumer-guide.md](headless-consumer-guide.md#submitting-drafts-from-your-app-the-draft_write-key).

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

**A single custom field takes one value.** On a `text`, `string`, `url`,
`select`, `integer`, `float`, `boolean`, `date` or `datetime` field that is
not a list (`multiple`), an object, or an empty list `[]`, is refused with a
`400` `invalid_attribute` on `custom_fields`. So is any list on a `text` or
`boolean` field. Send `null` or `""` to clear a field. A number or a
boolean sent to a text-like field is stored as its text (`42` as `"42"`).
A non-empty list on a single `string`, `url`, `select`, number or date
field still keeps its first item, as before. Each locale of a document is
its own record, so a map of locales (`{"en": …, "fr": …}`) is an object
like any other: write each value on its locale's record. A map of locales
sent to a string field `subtitle`:

```bash
curl -s -X PATCH http://localhost:4000/api/json/pages/$ID \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{"data": {"type": "page", "id": "'$ID'", "attributes": {
        "custom_fields": {"subtitle": {"en": "Spring menu"}}}}}'
```

```json
{"errors": [{"code": "invalid_attribute",
             "detail": "Subtitle (subtitle) must be a single value, not an object or a list",
             "source": {"pointer": "/data/attributes/custom_fields"}, …}]}
```

Nothing is written. The same rule holds for a reference's link values
(`"link": {"role": {"x": 1}}` names the field, the item and the link field)
and for GraphQL and MCP writes. The format types (`email`, `color`, …) and a
plugin's field type decide in their own `cast/2`, so a composite such as a
geolocation still takes an object.

`scheduled_at` takes publish rights (an admin, or an editor on a site that lets
editors publish). Without them, write **`proposed_publish_at`** instead: a date
you are asking for, which publishes nothing until someone with publish rights
sets `scheduled_at` (which clears the proposal, as publishing does). Like the
body's `blocks`, it is write-only on the APIs: no read returns it. It is an
editorial request, not something a reader of the content should see
([content lifecycles](content-lifecycles.md#proposed-publish-dates)).

`unpublish_at` and `expiry_action` take the same rights on a `PATCH` of a
record that is published or has `scheduled_at` set (#2134): there the
scheduler takes the record down on that date with nobody checked, so moving
it is an unpublish. Without the rights, a `PATCH` that changes either one on
such a record is refused as a whole (`403`); leave them out, or send the value
the record already has. On a draft nobody has scheduled, and on a create, any
editor may set them
([content lifecycles](content-lifecycles.md#authorization)).

### Discovering dynamic types

An entry of an admin-defined type is created on `/api/json/entries` with the
type's `type_definition_id`. The type registry is read-only over the API:

| Route | Answers |
|-------|---------|
| `GET /api/json/type-definitions` | Every live type in the request's org; `filter[name]=`, `sort=`, `page[...]` as usual |
| `GET /api/json/type-definitions/by-name/:name` | One type by its machine `name` — `404` on a miss |
| `GET /api/json/type-definitions/:id` | One type by id |

Each row carries `name` (the permanent machine key), `label`, `plural_label`,
`path_segment`, `description`, `icon`, `schema_org_type`, `has_excerpt`,
`has_published_feed`, the slug/alias/SEO patterns and
`default_review_after_days`. Add `?include=field_definitions` to get the type's
custom-field schema (`name`, `label`, `field_type`, `required`, `options`,
`default`, `help_text`, `position`, …) — the keys an entry's `custom_fields`
map takes, `validation`: the field's value constraints (`min`, `max`,
`min_length`, `max_length`, `pattern`, `pattern_message`, `unique`; `{}` when
none), which a write to `custom_fields` is checked against — see
[Constrain the values of a field](extending-content.md#constrain-the-values-of-a-field) —
and `visible_when` / `required_when`, the field's conditional rules (or `null`); see
[extending-content.md](extending-content.md#make-a-field-conditional). A hidden
field is an editor concept: its value is still in every read. `widget` is the
editor input an admin chose for the field (`"radios"`, `"single_line"`, a
plugin's own), or `null` for the type's default; it changes nothing about the
value (see
[Choose how editors fill in a field](extending-content.md#choose-how-editors-fill-in-a-field)).
`?include=field_definitions.group_fields` adds the sub-fields of
each `:group` field — the keys each of its rows takes; a sub-field names its
group in `group_of_id`.

It is the same read as `/mcp`'s `read_type_definitions`, with the same policy:
the credential must belong to an **editor or admin of the request's org** (a
read-only key is enough — this is a read). A viewer's key or an anonymous
caller gets an empty list and a `404` on a single type. The org is the host's,
as everywhere else, so a key never sees another site's types; archived
(trashed) types are not listed. There are no write routes — types are defined
in `/editor/types`.

```bash
# 1. Resolve the type's machine name to its id
TYPE_ID=$(curl -s http://localhost:4000/api/json/type-definitions/by-name/doc \
  -H 'accept: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" | jq -r '.data.id')

# 2. Create a draft entry of that type (`:read_write` key, editor+)
curl -s http://localhost:4000/api/json/entries \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{
    "data": {
      "type": "entry",
      "attributes": {
        "title": "Written against a discovered type",
        "slug": "hello-doc",
        "type_definition_id": "'"$TYPE_ID"'",
        "custom_fields": {}
      }
    }
  }'
```

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

### Writing relationships

Kiln has two kinds of relationship a client writes, and they go through
different doors.

**A `:reference` custom field is part of the record.** Write it with
`PATCH /api/json/<plural>/:id`, sending the field's whole new value under
`custom_fields` (other custom fields are left alone; see *Partial updates
merge* in `KilnCMS.CMS.Changes.ApplyCustomFields`). It is the record's normal
update, so policies, `If-Match`, versioning, the webhook and the re-fire all
apply, and the edges in `content_links` are rewritten to match in the same
transaction. The list's order is the order you send.

A field that connects several records (`multiple: true`), one type:

```json
{
  "data": {
    "type": "post",
    "id": "<post-uuid>",
    "attributes": {
      "custom_fields": { "ingredients": ["<page-uuid-1>", "<page-uuid-2>"] }
    }
  }
}
```

Several allowed types (`target_types`): every item names its type.

```json
{ "custom_fields": { "see_also": [
  { "id": "<page-uuid>", "type": "page" },
  { "id": "<entry-uuid>", "type": "recipe" }
] } }
```

Link fields (R3) ride on each item as `"link"`. A link value left out keeps
what that connection stored, so a reorder that re-sends bare ids keeps every
connection's data:

```json
{ "custom_fields": { "ingredients": [
  { "id": "<page-uuid-1>", "link": { "quantity": 2, "role": "main" } },
  { "id": "<page-uuid-2>", "link": { "quantity": 1 } }
] } }
```

To clear the field send `[]` (or `null` for a single-valued one). A repeated
id, a target that doesn't exist, a type the field doesn't allow, a link value
of the wrong type, or a list outside `min_items` / `max_items` fails the
`PATCH` with a 400 naming the item. GraphQL has the same edit as
connect / disconnect / reorder mutations that build the list server-side
([headless-graphql-api.md](headless-graphql-api.md#writing-relationships)).

**A payload link is not part of either record.** It is a `content_link` with
no `field`: a curated link with a `kind` (default `related`), `position`,
`label` and free `metadata`. It has routes of its own:

| Route | Action | Who | Effect |
|-------|--------|-----|--------|
| `POST /api/json/content-links` | `:create_link` | may update the **source** record | Links `source_id` → `target_id` |
| `PATCH /api/json/content-links/:id` | `:update_link` | may update the source | Changes `position`, `label`, `metadata` |
| `DELETE /api/json/content-links/:id` | `:destroy_link` | may update the source | Removes the link |
| `GET /api/json/content-links/:id` | `:read` | may read both ends | One link |

```bash
curl -s -X POST http://localhost:4000/api/json/content-links \
  -H 'accept: application/vnd.api+json' -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{"data":{"type":"content_link","attributes":{
        "source_id":"<page-uuid>","target_id":"<post-uuid>",
        "label":"Further reading","metadata":{"order":"2"}}}}'
```

A link belongs to its source: every write is authorized as an **update of the
source record**, by that record's own policy — a read-only key, a viewer, or
an editor whose `editable_types` leave out the source's type gets a 403. The
target must be a record the writer can read on the same site, and a record
can't link to itself. `source_type` and `target_type` are set from the
records. The ends are fixed: to point somewhere else, delete the link and
create another. A link is not part of its source's document, so it does not
bump the source's `lock_version`, write a version or send a webhook.

`kind` takes a name the server already knows (`related` and the kinds Kiln
uses); an unknown name is refused rather than created. `reference` is refused
on create, and `PATCH` / `DELETE` refuse a reference edge (one with a `field`):
those are a copy of a custom field's value, and change only when the field
does. A payload link to a record of the source's own type also shows in the
source's `related_<type>s`, beside the related content the editor curates.

`Idempotency-Key` works on `POST` and `PATCH` here as on every other write.

### Writing body content — the `block_tree` attribute

The typed `blocks` union isn't exposed on the auto API (it isn't `public?`), so
body content is written through a public **`block_tree`** attribute: an array of
block maps (the same shape the editor and MCP submit), cast into the union —
which **sanitizes** rich-text HTML and media URLs. On an update, **omit**
`block_tree` to leave the body untouched (a metadata-only `PATCH` never wipes
it); send `[]` to clear it.

**Or send Markdown — `body_markdown`.** A Markdown string in place of
`block_tree`, converted server-side by `KilnCMS.Markdown` (the converter the
editor's paste and `.md` import use) into the same block maps, then cast and
sanitized the same way: headings, lists, tables and fenced code become
Portable Text, a standalone image an `image` block, a bare YouTube/Vimeo link
an `embed`. Raw HTML in it goes through the rich-text allowlist. Send one or
the other — both is a 400. `""` clears the body; front matter is dropped (title
and slug are their own attributes). The blocks it produces carry no `_id`s, so
it replaces the body wholesale, like an id-less `block_tree`. Details:
[Markdown](markdown.md#writing-markdown-through-the-api).

**Round-trip block ids when updating.** Read the tree's identity first — the
`block_ids` calculation (`?fields[post]=block_ids`) projects the stored tree to
`_id`/`_type` only, nested `columns` children included in the positions they
render — and echo each block's `_id` on the maps you send back. That is what
lets the server tell an in-place edit from a replacement; on a page carrying an
admin-set nested value (a field behind `editable_by`), a non-admin write that
drops the ids is **refused** (#954), with the error naming this surface. The
fired `:json` artifact carries the same `_id`s for published content.

### Concurrency: `ETag` and `If-Match`

Without a precondition, a `PATCH` is last-write-wins: the server reads the
record and applies your attributes in the same request, so a client editing
from a copy it fetched earlier overwrites anything an editor saved in between,
without an error. To make a write conditional on the version you read:

1. Every single-record response carries an `ETag`: `GET /:id`, and the
   responses to `PATCH /:id` and the workflow routes. It looks like `"4-draft"`
   and is built from the record's `lock_version` (bumped by every content edit)
   and its `state` (moved by every workflow transition). Treat it as opaque and
   echo it back unchanged.
2. Send it as `If-Match` on `PATCH /:id`, on `PATCH /:id/publish`,
   `/unpublish`, `/submit-for-review`, `/return-to-draft`, or on `DELETE /:id`.
   The write happens only if the record still carries that tag. Otherwise you
   get **`412 Precondition Failed`** and nothing changes:

```jsonc
{
  "errors": [{
    "status": "412",
    "code": "precondition_failed",
    "detail": "this content was changed since you read it — it is now version 5 (draft); re-read it and retry",
    "meta": { "etag": "\"5-draft\"", "lock_version": 5, "state": "draft" }
  }]
}
```

```bash
# Read, keeping the ETag…
curl -si http://localhost:4000/api/json/posts/<uuid> \
  -H 'accept: application/vnd.api+json' -H "authorization: Bearer $KEY" | grep -i etag
# etag: "4-draft"

# …and write only if nobody has changed it since.
curl -s -X PATCH http://localhost:4000/api/json/posts/<uuid> \
  -H 'accept: application/vnd.api+json' -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KEY" -H 'if-match: "4-draft"' \
  -d '{ "data": { "type": "post", "id": "<uuid>", "attributes": { "title": "New" } } }'
```

- **`If-Match: *`** passes whenever the record exists. Several tags,
  comma-separated, pass if any one matches.
- **A tag the server could not have issued fails with 412.** That covers a weak
  `W/"…"` tag (`If-Match` uses strong comparison), a mistyped tag, or one
  without quotes. It is not ignored: ignoring it would turn a typo into an
  unguarded write.
- **Publishing moves the tag even though it doesn't edit content.** A client
  that read a draft and PATCHes after someone published it gets a 412 rather
  than silently editing live content. `If-Match` on `/publish` likewise means
  "publish the version I reviewed": an edit made after your read refuses it.
- The check runs inside the write's transaction, against the row locked for
  update, so a save that lands between your request arriving and the write
  cannot slip past it.
- No `If-Match`, no check: existing clients behave exactly as before.

`lock_version` is also a read-only attribute on every content type, if you'd
rather track versions yourself. The write routes accept it as an optional
`expected_lock_version` attribute, which compares `lock_version` alone, like
the GraphQL argument. Browsers can read `ETag` and send `If-Match` cross-origin:
both are allowed in the CORS headers.

### Change severity: how much an edit matters

An edit to a **published** document that touches a field the site lists as
safety-relevant (`/editor/safety-fields`, per content type, or "every field")
is recorded with a *severity* on the version it creates: `critical`, `notable`
or `routine`. Sites that mirror the content use it to decide how loudly to
surface the change. The answer belongs to that one edit; it is never a field of
the record and never carries over to the next edit.

`PATCH` (`update`) and the `publish` route accept an optional
`change_severity` attribute (so do the GraphQL `update*` / `publish*` mutations;
`publish_changes` and `restore_version` have no public route, and the editor and
internal callers of those actions default to `notable`):

```json
{"data": {"type": "post", "id": "…",
          "attributes": {"title": "…", "change_severity": "critical"}}}
```

* **Omitted:** a safety edit is recorded `notable`. Never `routine`, and never
  empty. (The admin editor is the one surface that asks: it will not publish a
  safety edit until a severity is chosen.)
* **Sent without a safety edit:** ignored. The version records none.
* **Per request only.** There is no batch write endpoint, so each write names
  its own severity; MCP's `update_page` / `update_post` / `update_entry` take the
  same `change_severity` argument.
* **Computed fields:** don't list them as safety fields. The daily refresh
  rewrites them, and each new value would be recorded as a `notable` edit.

Read the latest one back with the `latest_edit_severity` and `latest_edit_at`
[calculated fields](#calculated-fields) (and on every `/api/sync` upsert item).
They describe the document's last **safety** edit, not its last edit of any
kind, and are `null` for a document that is not published or has none. A first
publish counts as an edit when a listed field is non-empty. Webhooks and the
change feed do not carry the severity yet.

### Retrying a write safely

Send an `Idempotency-Key` header and a retry of the same `POST` or `PATCH`
replays the first attempt's response instead of creating a second document or
running a second transition. See
[api.md](api.md) → *Idempotent writes*.

### Re-fire semantics

Firing (immutable per-surface artifact regeneration) is bound to `:publish`, so
the publish route re-fires automatically. Editing already-published content with
`PATCH /:id` **also** re-fires (a `published`-guarded re-fire on `:update`,
#330), so a write-through to live content never leaves a stale artifact. Draft
edits do not fire.

### Editing media metadata

Files are **created** through the upload API (`POST /api/media` — JSON:API has
no file upload; see [api.md → Uploading media](api.md#uploading-media)). What
an item says about itself is edited here:

| Route | Action | Who | Effect |
|-------|--------|-----|--------|
| `PATCH /api/json/media-items/:id` | `:update_metadata` | `:read_write` key (or JWT), editor+ | Edits `alt`, `caption`, `decorative`, `focal_x`, `focal_y` and tags |

```bash
curl -s -X PATCH http://localhost:4000/api/json/media-items/<uuid> \
  -H 'accept: application/vnd.api+json' \
  -H 'content-type: application/vnd.api+json' \
  -H "authorization: Bearer $KILN_API_KEY" \
  -d '{ "data": { "type": "media_item", "id": "<uuid>",
        "attributes": { "alt": "The kiln at dusk", "focal_x": 0.3, "add_tag_ids": ["<tag uuid>"] } } }'
```

- The focal point is `0.0`–`1.0` on each axis; moving it **re-derives** the
  focal-aware crops in the background, as clicking the point in the media
  library does.
- Tags take the same three arguments as content — `tag_ids` replaces the set,
  `add_tag_ids` / `remove_tag_ids` merge — with the same rules (see "Writing
  tags — replace vs merge" above).
- Nothing the pipeline owns is writable: `url`, `storage_key`, `variants`,
  `content_type`, dimensions and sizes come from the bytes. Sending one is a
  `400`, not a silent write. `audience` (gating a document) stays an editor-UI
  action for now, because it moves the file between storage buckets.
- Deleting media is not routed for any key.

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
