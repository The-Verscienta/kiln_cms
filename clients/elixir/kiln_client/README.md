# KilnClient

Official Elixir client for the [Kiln CMS](https://github.com/The-Verscienta/kiln_cms)
delivery APIs: the JSON:API read surface (`/api/json/*`), per-type keyword /
semantic search and autocomplete, hybrid search (`/api/search`), and fired
artifacts (`/api/content/:type/:slug`).

Extracted from the client Verscienta's production site built and hardened
against a live Kiln ([kiln_cms#300](https://github.com/The-Verscienta/kiln_cms/issues/300)).
Its job is to encode the safe defaults once, so consumers don't rediscover the
traps ([kiln_cms#297](https://github.com/The-Verscienta/kiln_cms/issues/297))
one production incident at a time.

## Installation

```elixir
def deps do
  [
    {:kiln_client, "~> 0.1"}
    # or, until it's published to Hex:
    # {:kiln_client, github: "The-Verscienta/kiln_cms", sparse: "clients/elixir/kiln_client"}
  ]
end
```

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
