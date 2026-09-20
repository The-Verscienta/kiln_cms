# KilnClient

Official Elixir client for the [KilnCMS](https://github.com/The-Verscienta/kiln_cms)
APIs: the JSON:API read surface (`/api/json/*`), the JSON:API **write** surface
(create, update, workflow transitions, soft-delete), per-type keyword /
semantic search and autocomplete, hybrid search (`/api/search`), fired
artifacts (`/api/content/:type/:slug`), and a minimal GraphQL helper for
`/gql`.

Extracted from the client Verscienta's production site built and hardened
against a live Kiln ([kiln_cms#300](https://github.com/The-Verscienta/kiln_cms/issues/300)).
Its job is to encode the safe defaults once, so consumers don't rediscover the
traps ([kiln_cms#297](https://github.com/The-Verscienta/kiln_cms/issues/297))
one production incident at a time.

## Installation

```elixir
def deps do
  [
    {:kiln_client, "~> 0.3"}
    # or, until it's published to Hex:
    # {:kiln_client, github: "The-Verscienta/kiln_cms", sparse: "clients/elixir/kiln_client"}
  ]
end
```

> **Publishing is prepared, not yet done.** The package metadata and the
> release workflow are in place (see [Releasing](#releasing)), but the first
> publish to Hex is a manual maintainer step. Until it happens, use the
> `github:` / `sparse:` dependency above.

## Configuration

```elixir
config :kiln_client,
  base_url: "https://cms.example.com",
  api_key: System.get_env("KILN_API_KEY"),   # optional bearer key
  public_url: "https://cms.example.com",     # optional, defaults to base_url
  req_options: []                            # merged into every Req request
```

Mint delivery keys on a **`:viewer` account** (see Kiln's `docs/api.md` →
"API keys") so a leaked credential can't widen visibility anywhere.

## Published-only by default

Kiln's read policy authorizes any `:editor`/`:admin` identity for **every**
workflow state — including a service API key minted on such an account. This
client therefore reads the **server-side filtered surfaces** by default:

| Call | Route |
|---|---|
| `list/2`, `one/3`, `by_ids/3` | `GET /api/json/:plural/published` |
| `text_search/3` | `GET /api/json/:plural/search/published` |
| `semantic_search/3` | `GET /api/json/:plural/semantic-search/published` |
| `autocomplete/3` | `GET /api/json/:plural/autocomplete/published` |

The `state == :published` filter lives in the server action, so it holds
whatever identity your key carries. Editor-facing callers that genuinely need
drafts opt out **per call** with `published: false` (which uses the plain
routes and requires an editor/admin bearer key).

The hybrid `search/2` (`GET /api/search`) has no published-only variant —
its visibility follows the credential, which is why viewer-minted keys matter.

## Usage

```elixir
# Lists, filters, includes, pagination
{:ok, %{items: posts, total: total}} =
  KilnClient.list("posts", filter: %{locale: "en"}, include: ["tags"], limit: 10)

# First match or {:error, :not_found}
{:ok, post} = KilnClient.one("posts", %{slug: "hello-world", locale: "en"})

# Admin-defined custom fields (filter[…] can't reach into custom_fields)
{:ok, %{items: cheap}} =
  KilnClient.list("entries",
    filter: %{type_name: "product"},
    custom_filter: %{price: {:lte, 10}}
  )

# The dynamic-type registry (editor-or-above key) and its custom-field schema
{:ok, product_type} =
  KilnClient.one("type-definitions", %{name: "product"}, include: ["field_definitions"])

# Search
{:ok, %{items: hits}} = KilnClient.text_search("posts", "elixir", locale: "en")
{:ok, %{items: near}} = KilnClient.semantic_search("posts", "functional programming")
{:ok, %{items: sugg}} = KilnClient.autocomplete("posts", "eli")
{:ok, sections} = KilnClient.search("kiln", facets: true)

# Rendered content (fired artifact; retries once on a cold cache)
{:ok, artifact} = KilnClient.artifact("posts", "hello-world", surface: "json")

# Join relationships through the included lookup
{:ok, %{items: [post | _], included: included}} =
  KilnClient.list("posts", include: ["tags"], limit: 1)

tags = KilnClient.resolve(post, "tags", included)
```

Results are flattened JSON:API resources: the `attributes` map (string keys)
plus `"id"`/`"type"`, with relationships reduced to `{type, id}` ref maps.

## Image transforms

`KilnClient.Image` builds URLs for Kiln's on-the-fly image transforms
(`GET /media/:id/t/:ops`) from a media item as the client returns it. Pure
string building — no request is made.

```elixir
# `media` is a media item as the client returns it — e.g. joined through
# `resolve/3` — needing "id", "url", "focal_x"/"focal_y" (and "width"/"height"
# for a srcset); atom keys work too.
KilnClient.Image.url(media, width: 800, aspect_ratio: "16:9", format: :auto)
#=> "https://cms.example.com/media/<id>/t/w_828,ar_16:9,fm_auto,v_4b87b277"

KilnClient.Image.srcset(media, aspect_ratio: "16:9", format: :auto)
#=> "https://cms.example.com/media/<id>/t/w_256,ar_16:9,fm_auto,v_… 256w, …"
```

Options: `:width`, `:height`, `:aspect_ratio` (`"16:9"` or `{16, 9}`),
`:dpr` (1–3), `:fit` (`:cover`/`:contain`), `:crop` (`:focal`, `:center`,
`:top`, `:bottom`, `:left`, `:right`), `:format` (`:auto`, `:jpg`, `:png`,
`:webp`, `:avif`), `:quality` (1–100). `srcset/2` also takes `:widths`.
`path/2` gives the root-relative path; `KilnClient.image_url/2` and
`KilnClient.image_srcset/2` are shorthands.

**Unsigned** (the default) URLs are served only for allowlisted values, so
`:width`/`:height` snap up to Kiln's size ladder (pass `:sizes` if the server's
ladder was changed). **Signed** URLs take any size exactly as given. Signing
needs the server's `KILN_IMAGE_TRANSFORM_KEY`, which is a server-side secret —
configure it only in code that runs on your server, never in a browser bundle:

```elixir
config :kiln_client, image_transform_key: System.get_env("KILN_IMAGE_TRANSFORM_KEY")
```

Pass `sign_key: nil` on a call to build an unsigned URL anyway.

## Verifying webhooks

`KilnClient.Webhook.verify/4` checks a delivery's `x-kilncms-webhook-signature`
(`t=<unix>,v1=<hex>`, an HMAC-SHA256 of `"<t>.<raw body>"`) against the
endpoint's signing secret. It refuses a `t` more than five minutes from your
clock, so a captured request can't be replayed later. Verify the **raw** body.
A re-encoded parse won't match.

```elixir
with [header] <- Plug.Conn.get_req_header(conn, KilnClient.Webhook.signature_header()),
     :ok <- KilnClient.Webhook.verify(secret, conn.assigns.raw_body, header) do
  %{"event" => event, "delivery_id" => delivery_id, "data" => data} =
    Jason.decode!(conn.assigns.raw_body)

  # delivery_id is stable across retries: remember it for the window to drop duplicates.
else
  _ -> send_resp(conn, 400, "bad signature")
end
```

The error reasons are `:malformed`, `:expired` and `:mismatch`. Pass
`tolerance: seconds` to change the window.

## Media uploads

The one write surface the client covers — it needs a **read + write** API key
on an editor (or admin) account; a read-only key gets `{:error, {:http_status, 403, _}}`.

```elixir
# Multipart, streamed from disk; metadata optional.
{:ok, item} = KilnClient.upload_media("priv/kiln.jpg", alt: "The kiln at dusk", focal_x: 0.3)
item["processing"]  # true while a video's metadata strip is pending — its url isn't live yet

# Server-side fetch of a public URL (SSRF-guarded, ≤ 25 MB).
{:ok, item} = KilnClient.import_media("https://example.com/cat.png", tag_ids: [tag_id])

# Metadata edits: alt/caption/decorative/focal point/tags (add_tag_ids / remove_tag_ids merge).
{:ok, item} = KilnClient.update_media(item["id"], caption: "Firing day", add_tag_ids: [tag_id])

# Large files straight to object storage (server on S3 with a private bucket; else a 501).
{:ok, item} = KilnClient.upload_media_direct("footage.mp4", alt: "Loading the kiln")
```

The server byte-sniffs every file and runs it through the media library's own
pipeline — metadata stripping, size caps, variants. See Kiln's `docs/api.md` →
"Uploading media".

### Editorial reads (editor-or-above key)

For tools *about* the content — migrations, audit exports, launch dashboards —
never a delivery site's key. Anonymous calls are a 401, a viewer's key a 404.

```elixir
# A document's version history, newest first (by id, not slug)
{:ok, %{"data" => revisions, "meta" => %{"next_cursor" => cursor}}} =
  KilnClient.list_revisions("post", post_id, limit: 50)

# One revision's changes + the full document as it stood then
{:ok, %{"snapshot" => snapshot}} = KilnClient.revision("post", post_id, version_id)

# Revert the content to it (a :read_write key; a read-only key gets a 403)
{:ok, %{"revision" => new_revision}} = KilnClient.restore_revision("post", post_id, version_id)

# Content releases (read-only) and what each will publish or take down
{:ok, %{items: releases, included: included}} =
  KilnClient.list_releases(filter: %{state: "scheduled"}, include: ["items"])
```

## Writing content

`create/3`, `update/4`, `transition/4` (with `submit_for_review/3`,
`return_to_draft/3`, `publish/3`, `unpublish/3`) and `delete/3` drive Kiln's
JSON:API write surface (see
[`docs/json-api.md` → Writing](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/json-api.md#writing-330)). They need
a **`:read_write` API key** — editor-or-above to create, update and submit for
review; admin to return to draft, publish, unpublish and delete. The key comes
from the per-call `:api_key` option, else the configured `:api_key`; with
neither, the call returns `{:error, %KilnClient.Error{reason: :no_api_key}}`
without sending anything.

A writer's key is the opposite of the `:viewer` key delivery reads want, so
keep the configured key for reads and pass the writer's per call:

```elixir
writer = [api_key: System.fetch_env!("KILN_WRITE_KEY")]   # editor, :read_write
admin = [api_key: System.fetch_env!("KILN_ADMIN_KEY")]    # admin, :read_write

# Always created as a draft, attributed to the key's owner.
{:ok, post} =
  KilnClient.create(
    "posts",
    %{title: "Written over the API", slug: "hello-api", body_markdown: "# Hello"},
    writer
  )

# Only what you send changes. `tag_ids` REPLACES the set; merge with
# add_tag_ids / remove_tag_ids instead (not both styles in one call).
{:ok, _} = KilnClient.update("posts", post["id"], %{add_tag_ids: [tag_id]}, writer)

{:ok, _} = KilnClient.submit_for_review("posts", post["id"], writer)
{:ok, _} = KilnClient.publish("posts", post["id"], admin)   # fires the artifacts
:ok = KilnClient.delete("posts", post["id"], admin)         # reversible soft-delete
```

- The first argument is the plural route, as for reads. The JSON:API `type`
  the server validates is derived from it (`"entries"` → `"entry"`); pass
  `type: "person"` for an irregular plural.
- A dynamic-type entry is created on `"entries"` with its
  `type_definition_id` — look it up with
  `KilnClient.one("type-definitions", %{name: "product"})`.
- Body content goes in `block_tree` (a list of block maps) or `body_markdown`,
  never both. When rewriting a `block_tree`, echo each block's `_id` (read them
  with `fields: %{"post" => ["block_ids"]}`) so the server can tell an edit
  from a replacement.
- Editing published content re-fires its artifacts; draft edits do not.
- `transition/4` takes any verb and kebab-cases it into the route, so a verb
  a newer server adds is reachable before a client release names it.

## GraphQL

```elixir
{:ok, %{"postBySlug" => post}} =
  KilnClient.graphql(
    "query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }",
    %{slug: "hello-world", locale: "en"}
  )
```

A minimal helper, not a GraphQL client: it posts `{query, variables,
operationName?}` to `/gql` (`operation_name:` option), sends the API key when
there is one (the published-content queries need none), and returns
`{:ok, data}` — or `{:error, %KilnClient.Error{reason: :graphql}}` with the
`errors` and any partial `data` when the response carries a top-level `errors`
array. No codegen. Ash **mutations** report a refused write inside `data` —
the payload's own `errors` field next to `result: nil` — so select
`errors { message code }` on mutations and check it.

## Errors

Writes and `graphql/3` return `{:error, %KilnClient.Error{}}`. Branch on
`:reason`:

| `:reason` | When |
|---|---|
| `:no_api_key` | a write with no key configured or passed — nothing was sent |
| `:unauthorized` / `:forbidden` | 401 (no/invalid/expired key) / 403 (the key's owner lacks the right) |
| `:not_found` | 404 |
| `:validation` | 400 / 422 — `KilnClient.Error.pointers/1`, `field_errors/1`. AshJsonApi answers most attribute errors with 400, not 422 |
| `:conflict` | 409 — a transition from the wrong state (`code: "invalid_state_transition"`, `KilnClient.Error.current_state/1`) or a lost race |
| `:rate_limited` | 429 — wait `:retry_after` seconds |
| `:server` | 5xx (a 503 may carry `:retry_after`) |
| `:transport` | no response (DNS, refused, TLS, timeout); the exception is in `:exception` |
| `:graphql` | `/gql` answered with top-level `errors` |
| `:http` | any other status |

Every error also carries `:status`, `:code` (the first error's) and `:errors`
(the JSON:API `errors` list). The API key is only ever sent as the
`Authorization` header — no error carries it.

**Reads are unchanged:** `list/2` and friends still return
`{:error, {:http_status, status, body}}` (or a transport exception), exactly as
before. `KilnClient.Error.normalize/1` converts one into the struct when you
want a single error handler for both.
## Testing your integration

Every request honors `req_options`, so [`Req.Test`](https://hexdocs.pm/req/Req.Test.html)
stubs the whole client without a running Kiln:

```elixir
# config/test.exs
config :kiln_client, req_options: [plug: {Req.Test, KilnClient}]

# in a test
Req.Test.stub(KilnClient, fn conn ->
  Req.Test.json(conn, %{"data" => [%{"id" => "1", "type" => "post", "attributes" => %{}}]})
end)
```

## Releasing

Publishing runs from `.github/workflows/release-clients.yml`, triggered only
by a tag named `kiln_client-vX.Y.Z` (it cannot match the core's `vX.Y.Z`
release tags). The workflow checks the tag equals `@version` in `mix.exs`,
runs the same format/compile/test gate as CI, builds the package with
`mix hex.build`, and — after approval in the `hex` environment — attests the
tarball's build provenance, proves a rebuild is byte-identical to it (Hex has
no "publish this tarball" task, but its tarballs are reproducible), and runs
`mix hex.publish --yes` (package and HexDocs).

1. Bump `@version` in `mix.exs`, add a `CHANGELOG.md` entry, and merge.
2. Tag the merge commit `kiln_client-vX.Y.Z` and push the tag.
3. Approve the run in the `hex` environment.

One-time setup a maintainer must do before the first run can succeed:

- **Hex:** the first publish claims the name `kiln_client` (check it is still
  free on hex.pm) and makes the account whose key published it the package
  owner — so generate the key on the maintainers' Hex account, not a personal
  one: hex.pm → Dashboard → Keys, with the `api:write` permission. Add
  co-owners afterwards with `mix hex.owner add kiln_client <user>`.
- **GitHub:** create an environment named **`hex`** (Settings →
  Environments), add required reviewers, and store the key there as the
  environment secret **`HEX_API_KEY`**.
