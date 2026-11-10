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
[`kiln_client`](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/elixir/kiln_client/README.md)
— it wraps the JSON:API reads, search, and artifact surfaces with the safe
defaults below (published-only reads, `Req.Test`-stubbable) already encoded,
plus the [JSON:API writes](json-api.md#writing-330) (create, update, workflow
transitions, soft-delete — a `:read_write` key required) and a small `/gql`
helper.

**Building in JS/TS?** Use the official client,
[`@kiln-cms/client`](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/js/README.md)
— the same surfaces and safe defaults as the Elixir client (published-only
reads, writes, GraphQL, injectable `fetch`), plus
preview tokens, `?as_of=` point-in-time reads, the `/api/sync` delta loop, and a bundled `kiln-types`
generator that emits per-site TypeScript types from `GET /api/schema` (dynamic
content types and custom fields included). `examples/astro-blog` consumes it
end to end.

**Building a native app?** [native-apps.md](native-apps.md) covers keeping a
phone's copy current: storing the sync cursor, backoff, iOS/Android background
refresh, ETags, `?fields=` for smaller payloads, and webhooks as the push path.

## Try it live

The project's own site, [kilncms.dev](https://kilncms.dev), is a Kiln
instance, and its published content answers anonymous reads. The guides under
`/docs` are entries of a dynamic `doc` type, so you can try each surface below
with nothing installed:

```bash
# Filterable lists / metadata (JSON:API)
curl -g 'https://kilncms.dev/api/json/entries/published?filter[type_name]=doc&fields[entry]=slug,title&page[limit]=5' \
  -H 'accept: application/vnd.api+json'

# The rendered body of one document (the fired artifact)
curl 'https://kilncms.dev/api/content/doc/getting-started?surface=json'

# Hybrid search
curl 'https://kilncms.dev/api/search?q=migrations'

# What lives at this URL?
curl 'https://kilncms.dev/api/resolve?path=/docs/getting-started'

# Mirroring: the first page of a sync
curl 'https://kilncms.dev/api/sync?initial=true&limit=5'

# A typed query (GraphQL)
curl https://kilncms.dev/gql -H 'content-type: application/json' \
  -d '{"query":"{ publishedEntries(limit: 3) { count results { title slug } } }"}'
```

It is a documentation site, so it has no categories, tags or menus, and few
posts: those reads answer `200` with an empty list. It is read-only for you,
and the [rate limits](api.md#rate-limits) are a stock install's. The examples
in the rest of this guide use `localhost:4000` or `cms.example.com`, meaning a
site of your own.

## Decision tree

| You want… | Use | Returns |
|-----------|-----|---------|
| The **rendered body** of a published page/post (blocks, HTML, JSON-LD) | Artifact: `GET /api/content/:type/:slug?surface=json\|json_ld\|web` | Fired artifact — the immutable, pre-compiled output (Kiln v2 `_type` block model) |
| To **preview a specific draft** by share link (draft mode) | Mint: `POST /api/content/:type/:id/preview-token` (editor key, server side) — or an editor's **Copy preview link**. Redeem: `GET /preview/:token` | The draft's raw, editable block tree (curated public fields) — the working copy for a live document — behind a signed, read-only 15-minute token for that one document |
| To **mirror** the public site — a build cache, search index or edge store — and learn what was **taken down** | Sync: `GET /api/sync?initial=true`, then `?cursor=` | Upserts (with the fired artifact) and id-only deletes since your last cursor — see [api.md → Sync](api.md#sync-delta-api) |
| **Filterable lists / metadata** (slug, title, SEO, dates, relationships), incl. drafts with a bearer token | JSON:API: `GET /api/json/...` | Resource attributes + relationship linkage. **No block body** (`blocks` is `public? false`) |
| **Taxonomy** (categories, tags) | JSON:API `/api/json/categories`,`/tags` **or** GraphQL `categories`,`tags` | Name, slug, description |
| **Search** (keyword, semantic, autocomplete) | JSON:API `/<type>/search`,`/semantic-search`,`/autocomplete` **or** GraphQL `search*`/`semanticSearch*`/`autocomplete*` | Matching records (metadata; no block body). Published-only **for anonymous callers** — with a bearer token, drafts match too. Delivery sites: use the `…/published` twins (`searchPublished*` etc.), which pin `state == :published` server-side (see "Drafts") |
| A **typed query** over published content by slug/locale | GraphQL `/gql` (`postBySlug`, `pageBySlug`, …) | Selected fields; no block body, author is the opaque `authorId` only |
| An **image at a size, crop or format** the upload variants don't have | `GET /media/:id/t/:ops` via `kiln.imageUrl` / `KilnClient.image_url` | The image bytes, cached and immutable when version-pinned (see "Images") |

## Locales: what you get when a translation is missing

Every slug lookup — the artifact API, `/api/resolve`, JSON:API
`/<plural>/by-slug/:slug`, GraphQL `*BySlug`, and the built-in site — answers a
missing translation the same way: it walks the **site's fallback chain** for
the requested locale (`fr-CA → fr → en`, set at `/editor/locales`; a locale
with no chain falls back to the default locale) and serves the first published
variant. So:

- **Always read back which locale you got.** `x-kiln-locale` /
  `Content-Language` on HTTP responses, `locale` on the JSON:API resource and
  the GraphQL result, `locale` in `/api/resolve` and `/api/menus` bodies. A
  static build that generates `/fr-ca/…` pages should decide whether an
  English answer there is a page it wants (and whether it canonicalises to the
  English URL) — the API tells you, it does not decide for you.
- **Want exactly one locale?** Pass `fallback=false` (GraphQL
  `fallback: false`): you get that locale or a 404 / `null`. `fallback_locale=`
  replaces the chain with one locale.
- **A locale the site does not run is a `400 unsupported_locale`**, never a
  silent default — check `GET /api/locales`, which also publishes every
  locale's chain.
- **Navigation** follows a configured chain only, never the implicit hop to
  the default locale.

Details and the full parameter table: [api.md → Locale fallback](api.md#locale-fallback).

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
| Webhooks | Events are named by the dynamic type — `"<name>.published"` / `.updated` / `.unpublished` / `.archived` / `.deleted` / `.restored` / `.created` — exactly like compiled types |

Admin-defined **custom fields** are delivered in each entry's `custom_fields`
map on every surface — including the fired artifact's `json` surface — and are
**filterable/sortable** on the JSON:API and GraphQL list surfaces via
`custom_filter`/`custom_sort` (see
[json-api.md](json-api.md) → "Custom fields"). Scalar fields are JSON-native values; `media` and
`reference` fields are **write-time snapshots** — `{"id", "url", "alt"}` for
media, `{"id", "type", "slug", "title"}` for references, and an ordered
array of those for a media gallery or a list of references (a field defined
with `multiple: true`; `/api/schema` types it as an array) — so no extra
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
**preview tokens** to share an unpublished draft. The artifact, JSON:API,
GraphQL `GET` and search surfaces are all CDN-cacheable when read anonymously —
see [Caching](#caching).

### Draft mode with a preview token

A front end's draft/preview mode needs one draft in a browser, and the browser
must not hold your API key. Mint on the server, redeem in the page:

1. Your server (holding an editor's `:read` key) calls
   `POST /api/content/:type/:id/preview-token` — or the editor pastes a link
   from **Copy preview link**, whose last path segment is the token.
2. Pass the returned `token` to the page (a cookie, a query param).
3. The page reads `GET /preview/:token` — no credential — until it expires 15
   minutes later; mint again on the next render.

To render the draft **in your own templates** (headless draft mode, #1887),
present the same token on the reads your published pages already make, as
`x-kiln-preview-token: <token>` (or `?preview_token=`):

- `GET /api/json/<type>/:id?include=content_links,incoming_links,tags` — the
  draft's record (a live document's working copy), with its edges to
  published documents. The id is the minting response's `id` (or
  `GET /preview/:token`'s);
- `GET /api/content/:type/:slug?surface=json|web|json_ld|llm` — the body,
  rendered live from the working copy in the published artifact's shape.

The token adds that one record to what the read returns; everything else is
answered as for an anonymous reader. Search, `by-slug` and the `/published`
twins stay published-only, GraphQL and `/mcp` ignore the token, writes never
read it, and a token that lapsed is a `404 invalid_preview` rather than the
published page.

See [api.md → Preview tokens](api.md#preview-tokens) for the response shape and
who may mint.

## Code blocks in rendered HTML

A code block with a line wider than your column scrolls sideways, and a
keyboard user can scroll it only if the block itself takes focus
([#2164](https://github.com/The-Verscienta/kiln_cms/issues/2164)). Kiln marks
up its code blocks for that on the `web` surface. On the `json` surface you
add the markup yourself.

### On the `web` surface

Every code block in a rich-text block carries `tabindex="0"`, `role="group"`
and an `aria-label`:

```bash
curl 'http://localhost:4000/api/content/page/install?surface=web'
```

```json
{
  "html": "<p>Run:</p><pre class=\"highlight\" tabindex=\"0\" role=\"group\" aria-label=\"Code sample\"><code class=\"language-elixir\">…</code></pre>"
}
```

- A block Kiln highlighted is `<pre class="highlight" …>`; one with no
  language, or a language Kiln has no highlighter for, is a plain
  `<pre tabindex="0" …>`.
- The label is translated into the document's locale: "Code sample",
  "Exemple de code" (`fr`), "Ejemplo de código" (`es`). It follows the
  document, not the request, so an English document served as a fallback for
  `?locale=fr` keeps "Code sample".
- Authors cannot set these attributes. The sanitizer strips them from stored
  HTML and Kiln adds them afterwards, so the values above are the only ones
  you will see.
- Code inside a plugin's own block is whatever the plugin renders, and may
  not carry them.

Kiln's stylesheet does not travel with the HTML, so **style the focus ring
yourself**. Without one, a keyboard reader can't see which block has focus.
Kiln's own pages use:

```css
pre[tabindex="0"]:focus-visible {
  outline: 2px solid var(--your-accent);
  outline-offset: -2px; /* inside the block, so an overflow: hidden parent can't trim it */
}
```

Pick a colour with 3:1 contrast against the code block's background (WCAG
1.4.11). Keep the attributes if you post-process the HTML: a sanitizer on
your side that drops `tabindex` or `aria-label` undoes this.

### On the `json` surface

The `json` surface is data, and its rich-text blocks are the stored prose
unchanged: a Portable Text block with `"style": "code"` in `body`, or sanitized
HTML in `legacy_html` (a plain `<pre>` or `<pre class="highlight">`, with no
`tabindex`). The guides at kilncms.dev `/docs` are stored as `legacy_html`.
If you render either one, add `tabindex="0"`, `role="group"` and a translated
`aria-label` to each `<pre>` and the focus ring above.

### After a Kiln upgrade

The attributes arrived in a release without a `format_version` change, so an
artifact fired before that release keeps its old markup until the document is
next published, edited or re-fired. A read does not re-fire it. An operator
re-fires every artifact at once after the upgrade
([Re-render published content after an upgrade](releasing.md#re-render-published-content-after-an-upgrade)).
What you see depends on how you cache:

- **You revalidate with `If-None-Match`** (a CDN, a browser, `URLCache`,
  OkHttp): you get the new markup on your next revalidation once the
  re-fire has run. A fired artifact's `ETag` is a digest of the body it
  serves, so it moves when the markup does
  ([#2463](https://github.com/The-Verscienta/kiln_cms/issues/2463)).
- **You keep a copy until a webhook says otherwise** (a static build, ISR, a
  mirror): you hear about it only if the operator ran the sweep with
  `notify: true` (`mix kiln.refire_all --notify`). Each document then
  arrives as `<type>.updated` with `"reason": "refire"` in `data` and an
  unchanged `updated_at`, so refetch it rather than drop it as a duplicate
  ([Webhooks](webhooks.md)). A silent sweep sends
  nothing; ask the operator which they ran.
- **You mirror with `/api/sync`**: a re-fire does not move a document's
  `updated_at`, so a delta does not report it. Run a full resync
  (`initial=true`) after an upgrade that re-renders.

If you can't wait for the re-fire, add the attributes on your side as you
would for the `json` surface, skipping any `<pre>` that already has
`tabindex`.

## Tables in rendered HTML

A table wider than your column scrolls sideways inside its wrapper, and a
keyboard user can scroll it only if the wrapper takes focus
([#2464](https://github.com/The-Verscienta/kiln_cms/issues/2464)). It works
like [code blocks](#code-blocks-in-rendered-html): Kiln adds the markup on the
`web` surface, and on the `json` surface you add it yourself.

### Tables on the `web` surface

Every table in a rich-text block arrives inside a `div.kiln-table-wrap` that
carries `tabindex="0"`, `role="group"` and an `aria-label`:

```json
{
  "html": "<div class=\"kiln-table-wrap\" tabindex=\"0\" role=\"group\" aria-label=\"Scrollable table\"><table><tbody><tr><td>Flour</td></tr></tbody></table></div>"
}
```

- **A `legacy_html` table is wrapped too.** Before this, a table stored as
  HTML reached the `web` surface as a bare `<table>` with no wrapper. It now
  arrives in the same `div.kiln-table-wrap`. If your stylesheet targets
  tables as direct children (`.kiln-block > table`), switch to a descendant
  selector (`.kiln-block table`) or style `.kiln-table-wrap > table`.
- The label is translated into the document's locale, like the code-block
  label: "Scrollable table", "Tableau défilant" (`fr`), "Tabla desplazable"
  (`es`).
- Authors cannot set these attributes; the sanitizer strips them and Kiln
  adds them afterwards.
- A table nested inside another table's cell gets no wrapper of its own; it
  scrolls with the outer one.

Give the wrapper a horizontal scroll and a focus ring. Kiln's stylesheet does
not travel with the HTML. Kiln's own rules, minus its `.kiln-block` scope:

```css
.kiln-table-wrap {
  overflow-x: auto;
}
.kiln-table-wrap[tabindex="0"]:focus-visible {
  outline: 2px solid var(--your-accent);
  outline-offset: 2px; /* outside the wrapper, clear of the cell borders */
}
```

Pick a color with 3:1 contrast against the page background around the table
(WCAG 1.4.11). Keep the wrapper and its attributes if you post-process the
HTML.

### Tables on the `json` surface

The `json` surface carries the stored prose unchanged: a Portable Text
`"_type": "table"` block in `body`, or sanitized HTML in `legacy_html`, where a
table is either bare or in a `div.kiln-table-wrap` with no other attributes.
If you render either one, put each top-level table in a scrolling wrapper with
`tabindex="0"`, `role="group"` and a translated `aria-label`, and add the
focus ring above.

An artifact fired before the release that added this keeps its old table
markup until it is re-fired; [After a Kiln upgrade](#after-a-kiln-upgrade)
covers how that reaches you. If you add the wrapper on your side meanwhile,
skip any `.kiln-table-wrap` that already has `tabindex`.

## Images: sizes, crops and formats on request

A `media_item` (JSON:API `/api/json/media-items`, GraphQL `featuredImage`)
carries `url`, `width`, `height`, `focal_x`, `focal_y` and a `variants` map of
the fixed renditions made at upload. For anything else — a 16:9 crop at 1080px,
a square thumbnail, AVIF — ask the transform endpoint:

```ts
import { createClient } from "@kiln-cms/client";

const kiln = createClient({ baseUrl: "https://cms.example.com" });

// <img src srcset sizes> for a 16:9 card, cropped around the editor's focal point
const src = kiln.imageUrl(media, { width: 1080, aspectRatio: "16:9", format: "auto" });
const srcset = kiln.imageSrcset(media, { aspectRatio: "16:9", format: "auto" });
```

What to know:

- **The builders need the media object, not just its id.** `v` (the version
  pin that makes a response cacheable for a year) is computed from `url` and
  the focal point, so pass the whole `media_item`. Without `url` the URL still
  works, with a five-minute lifetime.
- **Unsigned URLs snap.** From a browser the builders round `width`/`height`
  up to the server's size ladder, because the server only renders allowlisted
  sizes for unsigned URLs. Use `aspectRatio` rather than `height` for a fixed
  crop — snapping two sides independently changes the shape.
- **Signed URLs don't.** A server-side frontend holding the operator's
  `KILN_IMAGE_TRANSFORM_KEY` can sign (`kiln.signedImageUrl`,
  `KilnClient.image_url(media, sign_key: key)`) and ask for exact sizes. The
  key is a secret — never ship it to a browser bundle.
- **`format: "auto"`** returns the best format the browser accepts and sends
  `Vary: Accept`; behind a CDN that ignores `Vary`, pick explicit formats.
- **Visibility matches downloads.** A gated item's transforms are 404 for
  anyone who couldn't download it.

Full reference: [media-pipeline.md § On-the-fly transforms](media-pipeline.md#on-the-fly-transforms).

### Draft mode with a preview token

A front end's draft/preview mode needs one draft in a browser, and the browser
must not hold your API key. Mint on the server, redeem in the page:

1. Your server (holding an editor's `:read` key) calls
   `POST /api/content/:type/:id/preview-token` — or the editor pastes a link
   from **Copy preview link**, whose last path segment is the token.
2. Pass the returned `token` to the page (a cookie, a query param).
3. The page reads `GET /preview/:token` — no credential — until it expires 15
   minutes later; mint again on the next render.

See [api.md → Preview tokens](api.md#preview-tokens) for the response shape and
who may mint.

## Link previews: the `social` object

A front end that renders its own pages needs Open Graph and X (Twitter) card
tags that agree with Kiln's. The `json` surface carries the document's part of
them in `social` (#2258):

```bash
curl -s 'https://cms.example.com/api/content/post/hello-world?fields=social'
```

```json
{"id": "…", "type": "post",
 "social": {"title": "Hello, world",
            "description": "Our first post.",
            "image": "https://cms.example.com/uploads/hello.png"}}
```

| Key | Value |
|---|---|
| `title` | The effective SEO title (the author's, else the type's pattern), else the document's title. Always present; `null` only when the document has no title. |
| `description` | The effective SEO description. Absent when there is none. |
| `image` | The SEO image as an absolute URL. A site-relative image is put on the document's own site: its custom domain, else its subdomain, else `PUBLIC_BASE_URL` for the default site. Absent when there is none. |

These are the values Kiln's own pages use for `og:title` / `twitter:title`,
`og:description` / `twitter:description` and the page's own `og:image` /
`twitter:image` ([seo.md](seo.md#link-previews-open-graph-and-x-twitter-cards)).
`?fields=social` returns just this object, as above. Under an experiment
(`?variant_key=`), `title` at the top level is the variant's while
`social.title` stays the canonical one: a link preview is read by a machine,
and a variant never changes what a machine reads.

**What you supply yourself.** `social` is per document, so it leaves out the
three values that belong to the site rather than the document:

- **The card type.** Use `summary_large_image` when you have an image
  (`social.image`, or your own default) and `summary` when you don't. That is
  Kiln's own rule.
- **`twitter:site`.** The site's X username is set in Kiln's Branding settings,
  but branding is not on any API yet, so put your handle in your front end's
  config.
- **A fallback image.** Kiln's pages fall back to Branding's Default social
  image; the artifact does not, so `image` is absent on a document without one.
  Use your own default.

Not provided: `twitter:creator` and image alt text (`og:image:alt`).

**`image` is fixed when the document is fired.** It names the host the site
had at that moment. After a site's custom domain or slug, or the
deployment's `PUBLIC_BASE_URL`, changes, artifacts keep the old host until they
are re-fired (`mix kiln.refire_all`); Kiln's own pages resolve the host on
every request and are not affected.

**Older artifacts.** `social` arrived with `format_version` 4, so the schema
from `GET /api/schema` marks it optional, and an artifact fired by an earlier
release lacks it until it is re-fired. Kiln re-fires such an artifact in the
background after the first read that misses its cache; that read, and cached
reads for up to an hour after it, still get the old body. An operator can
re-fire everything at once with `mix kiln.refire_all`. Even after the re-fire,
two kinds of consumer keep the old body until the document is next edited:

- **A `/api/sync` mirror** gets a document again only when it changes
  editorially, and a re-fire is not an edit. To refresh a mirror, wait until
  the operator's `mix kiln.refire_all` has finished, then run a fresh
  `?initial=true` sync.
- **A client or CDN that revalidates with `If-None-Match`.** The artifact's
  `ETag` names the document's last edit, not the body, so it gets `304` for the
  old body ([#2463](https://github.com/The-Verscienta/kiln_cms/issues/2463)).
  Re-read without the validator, or use `?fields=`, whose `ETag` is a digest
  of the body.

Read `social` as optional and fall back to `title` when it is missing.

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

### A bad bearer token is a `401`

A malformed, expired or foreign JWT in `Authorization: Bearer …` is answered
`401` with an `invalid_token` error envelope and
`WWW-Authenticate: Bearer error="invalid_token"`, on `/api/json`, `/gql` and the
other `/api` routes. It used to be served as anonymous, so a client with a
stale token read public content and took it for success; treat this `401` as
"re-authenticate", not as "forbidden". A request with no `Authorization` header
is still anonymous, and a bad `kiln_` key was always a `401`.

An operator who needs time to fix a client can set
`KILN_API_REJECT_INVALID_BEARER=false` to restore the anonymous fallback. That
escape hatch lasts one release and is then removed
([ADR 0012](decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)).

## Mirroring: sync instead of re-reading everything

A static build or search index that polls JSON:API with
`filter[updated_at][gt]=<last run>` picks up new and edited documents, but
never a removal: an unpublished, archived, deleted, locked or members-only
document just stops matching. It stays in your mirror indefinitely — and for a
document someone *locked* or moved behind a paywall, that is a leak.

`GET /api/sync` is built for this ([api.md → Sync](api.md#sync-delta-api)).
Run `?initial=true` once, follow `cursor` while `has_more`, store the final
cursor, and poll with it; every `delete` is a document to drop. In JS:

```ts
const { items, cursor } = await kiln.sync({ cursor: await load() });
for (const item of items) {
  if (item.op === "upsert") await mirror.put(item.id, item.artifact);
  else await mirror.remove(item.id);
}
await save(cursor);
```

What sync reports is the **anonymous** view whatever key you configure, so it
is safe to point a delivery key at it — and a delete never says why a document
left, or names one you were never sent.

For an app on a phone, see [native-apps.md](native-apps.md#mirroring-with-sync)
for where to keep the cursor and when (not) to start over.

## Submitting drafts from your app: the `draft_write` key

If your app needs to **send content to Kiln for a human to review** (a
user-submitted article, an imported listing), give its service a
`draft_write` API key rather than a `read_write` one. It can create content and
edit **its own drafts** and nothing else, whatever the account behind it can do
([ADR 0012](decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)).

* **Minting is admin-only**, at `/editor/api-keys`. Pick the `draft_write`
  access; the key must expire within `:draft_write_key_max_ttl_days` (default
  30 days), and its owner must be a viewer-tier service account, not an editor
  or admin. An admin can also give it a **self-rotation window** (below), so
  the service renews it without a person re-minting it every month.
* **It may:** `create` (JSON:API `POST`, GraphQL `create…`, `/mcp` `create_*`),
  and `update`/autosave a document that is still a **draft** and that the key's
  account **authored**. Nothing in review, archived or live.
* **It may not:** publish, unpublish, schedule, archive, delete, submit for
  review (a person moves a draft into the queue), restore a version, edit a
  live document or someone else's draft, or touch media. Each is refused
  (`403`; a row it may not read is a `404`).
* **Drafts cannot set tags, a category or related links.** Those links are
  separate writes the key is refused, so a human files the draft when they
  review it. Custom fields, blocks, title and the like are fine.
* **Media is refused** on every route: `/api/media*`, the media `PATCH` and
  GraphQL `updateMediaItem`. Upload through a `read_write` key on an editor
  account, or ask an editor to attach images.
* **It reads as its account does:** published content (audience permitting)
  plus the drafts it authored. It cannot read other authors' unpublished
  content and has no revision history.

### Keeping the key alive: self-rotation

If the admin minted the key with a self-rotation window ("Self-rotation" at
`/editor/api-keys`; up to a year), the service can exchange it for a fresh one
before it expires:

```bash
curl -X POST https://kiln.example.com/api/keys/rotate \
  -H "Authorization: Bearer $KILN_DRAFT_KEY"
```

```json
{"data": {"id": "…", "api_key": "kiln_…", "expires_at": "2026-12-06T…",
          "rotatable_until": "2027-05-05T…", "rotated_from_id": "…"}}
```

* The new key has the same account, scope and name. It expires 30 days out
  (`:draft_write_key_max_ttl_days`), or at `rotatable_until` if that is sooner.
  After `rotatable_until`, ask an admin for a new key.
* **The old key is revoked the moment this answers.** Write the new key to
  your secret store first, then switch to it. Workers still using the old key
  get `401` until they reload; that is expected.
* **Rotate from one place**, on a schedule (for example when fewer than 7 days
  are left), not from every worker on a 401.
* **Never present a rotated-away key to this endpoint again.** Kiln reads that
  as a stolen key: more than 120 seconds after the rotation it revokes the
  whole chain, including your current key, and alerts the admins. If you lose
  the `201` (a network failure mid-request), do not retry with the old key;
  ask an admin to mint a new one.
* `401` (`invalid_api_key`): no key, or it is revoked/expired. `403`
  (`forbidden`): not a drafts-only key, or it has no rotation window or the
  window has closed. `409` (`not_rotatable`): it was rotated by a concurrent
  request, or its account was given an editor or admin role. `500`: a server
  failure; the old key still works, so retry later. This endpoint
  never treats a request as anonymous, with or without
  `KILN_API_REJECT_INVALID_BEARER`.

### Telling reviewers who it was for: `X-Kiln-On-Behalf-Of`

Send `X-Kiln-On-Behalf-Of: <your user id>` on the **create** (`POST`) and Kiln
stores it on the draft, with the key's id and name, so a reviewer can see
"submitted by Verscienta for user 42". It is an opaque label of your choosing,
trimmed of control characters and capped in length. It is **stored only, never
authorization**: Kiln does not check it, trust it or act on it, and sending it
with any other key is ignored. These **provenance fields**
(`created_via_key_id`, `created_via_key_name`, `on_behalf_of`) are readable on
JSON:API, GraphQL and `/mcp` by **authenticated callers only**: an editor or
admin, and your own `draft_write` key for the drafts *it* created (not another
key's). Anonymous callers, preview-link holders and viewer-tier accounts never
get them, on a published row or a draft: the label may identify an end user
and a published document is world-readable. For them the field is **absent**
from a JSON:API `attributes` object (also with `?fields[post]=on_behalf_of`),
and `null` in GraphQL, where a query that selects the field also receives a
`forbidden_field` entry in `errors` beside the data. They are deliberately not
in webhook payloads, the preview endpoint or `/api/sync`. They show in the
editor, read from the draft itself; they are **not** recorded in version
history, whose read scope (every draft of the key's owner) is wider than theirs
(the drafts this key created).

## Editorial tooling: version history and releases

Two editor-tier reads exist for tools *about* the content rather than sites
that render it — a migration script, an audit export, a launch dashboard. Both
need an editor's (or admin's) credential and answer nothing to an anonymous
caller or a viewer key, so they never belong in a delivery site's config.

* **Version history** — `GET /api/content/:type/:id/revisions` lists a
  document's revisions (who, when, which fields), `…/revisions/:version_id`
  returns one revision's changes plus the full document as it stood then, and
  `POST …/revisions/:version_id/restore` reverts the content to it (a
  `:read_write` key; a read-only key is refused). Keyed by document id, paged
  with a cursor. See [api.md](api.md) → "Version history (revisions)".
* **Content releases** — `GET /api/json/releases` (`?include=items`) shows what
  is scheduled to go live together, when, and what each release will publish or
  take down. Read-only: releases are shipped from the console. See
  [json-api.md](json-api.md) → "Content releases (read-only)".

To show a visitor "what this page said on a date", use the public
point-in-time read (`GET /api/content/:type/:slug?as_of=`), not revisions: it
serves only what was *published* at that instant, to anyone.

## Caching

Anonymous reads of the main delivery surfaces are shared-cacheable: fired
artifacts (`public, max-age=300`), and JSON:API, GraphQL queries over `GET` and
`/api/search` (`public, max-age=60, stale-while-revalidate=60`). Each carries an
`ETag`; send it back as `If-None-Match` and an unchanged response is a bodyless
`304`. The full table, the headers and CDN setup are in
[api.md → Caching and CDNs](api.md#caching-and-cdns).

What that means for a front end:

* **Read delivery anonymously if you want it cached.** Any credential — an
  `Authorization` header (including a delivery API key), an unlock grant, even a
  cookie — makes the response `private, no-store`. That is deliberate: an
  editor's token sees drafts on the same URLs, so its answer must not land in a
  shared cache. If a build or server needs a key, keep it off the requests your
  CDN serves to readers ([Delivery sites](#delivery-sites-an-api-key-widens-what-you-see)
  has the other reason to).
* **Query GraphQL with `GET` for cacheable reads.** `POST /gql` is never cached.
  Put the document (and `variables`, JSON-encoded) in the query string — a
  document sent in a `GET` body is never cached — and a query that returns
  `errors` is not cached either.
* **A publish shows up within the `max-age`**, or at once if the operator set
  `KILN_CDN_PURGE_URL`, which purges the site's `Surrogate-Key`/`Cache-Tag` on
  every publish, unpublish and live edit (not on taxonomy or schema edits,
  which age out). Static builds and ISR should still
  rebuild from [webhooks](webhooks.md); the purge only covers the CDN in front of
  Kiln.
* **Don't build your own ETag from fields.** On JSON:API, GraphQL, search
  and fired artifacts, Kiln's is a digest of the response body, so it already
  changes whenever anything in the body does, and only then: keying on
  `updatedAt` or an id misses a re-render after a Kiln upgrade, which changes
  the body without touching either ([After a Kiln upgrade](#after-a-kiln-upgrade)).
  A page rendered by Kiln itself has an `ETag` that also names the build
  serving it, so it moves on every deploy that changes Kiln's code, dependencies or
  assets.

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
  delivery. Neither does `GET /api/sync`: a mirror's fetch is replication, and
  counting it would credit every document on every snapshot.

The stored counters have no surface dimension, so headless and rendered views
sum together in the dashboard. If you export metrics, the
`kiln_cms.analytics.view.count` telemetry counter is tagged with `surface`
(`"html"` for the rendered site, otherwise the fired surface name), which is
where the two can be told apart.

If you need true reader counts, that has to come from your own frontend's
analytics — Kiln deliberately cannot see the browser.
