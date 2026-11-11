defmodule KilnClient do
  @moduledoc """
  Official Elixir client for the KilnCMS APIs — the JSON:API read surface at
  `/api/json/*`, per-type and hybrid search, fired artifacts at
  `/api/content/:type/:slug` (including `:as_of` point-in-time reads), path
  resolution, menus, locales, related content, forms, preview tokens, the
  delivery schema, the JSON:API write surface (create, update, workflow
  transitions, soft-delete), the media upload API (`upload_media/2` and
  friends), the `/api/sync` delta API and a minimal `/gql` helper (see Kiln's `docs/json-api.md` and
  `docs/headless-consumer-guide.md`). The writes and the uploads need a read +
  write key on an editor account; the reads need no key at all.

  Extracted from the client Verscienta's production site hand-rolled and
  hardened against a live Kiln (kiln_cms#300); it encodes the safe defaults so
  consumers don't rediscover the traps one incident at a time.

  ## Configuration

      config :kiln_client,
        base_url: "https://cms.example.com",
        api_key: System.get_env("KILN_API_KEY"),   # optional bearer key
        public_url: "https://cms.example.com",     # optional, defaults to base_url
        req_options: []                            # merged into every Req request

  `req_options` is the test seam: point it at `Req.Test` and the client is
  fully stubbable without a running Kiln —

      config :kiln_client, req_options: [plug: {Req.Test, KilnClient}]

  Every read also accepts a per-call `:req` option — `Req` options merged
  into that one request last (via `Req.merge/2`), after the defaults and the
  configured `req_options`. Use it to bound a call that must not hang:

      KilnClient.semantic_search("posts", q, req: [receive_timeout: 1_500, retry: false])

  A degraded embedding backend stalls the semantic routes without failing
  them (measured at ~70s per call on a production instance that still
  answered 200 — far too late to be useful). Callers with a keyword fallback
  should bound `semantic_search/3` and `search/2` well above their healthy
  latency and skip retries: retrying a timeout only multiplies load on a
  backend that is already struggling.

  ## Published-only by default

  Reads are published-only by default. Do not rely on the credential for
  that: Kiln's read policy authorizes any `:editor` actor for every workflow
  state (and admins bypass it outright), so an API key minted on a staff
  account would otherwise see drafts through the plain index and the base
  search routes (kiln_cms#297). This client reads the server-side filtered
  surfaces instead — the `/published` feed and the `/search/published`,
  `/semantic-search/published`, `/autocomplete/published` twins — whose
  `state == :published` filter holds whatever identity the key carries.
  Callers that genuinely need drafts must opt out per call with
  `published: false`.

  ## Result shape

  JSON:API documents are flattened before they're returned: each resource
  becomes its `attributes` map (string keys) plus `"id"`/`"type"`, with
  relationships reduced to `{type, id}` ref maps under `"relationships"`.
  Included resources come back as a `%{{type, id} => item}` lookup so callers
  can join links without re-walking the document (see `resolve/3`).

  ## Writes need a key, and a different one

  `create/3`, `update/4`, `transition/4` (and its wrappers `submit_for_review/3`,
  `return_to_draft/3`, `publish/3`, `unpublish/3`) and `delete/3` drive the
  JSON:API write surface (Kiln's `docs/json-api.md` → "Writing"). They take
  the key from a per-call `:api_key` option, falling back to the configured
  `:api_key`, and refuse to send anything without one —
  `{:error, %KilnClient.Error{reason: :no_api_key}}` — because an anonymous
  write can only ever be a 401/403.

  The key must be a `:read_write` key: editor-or-above to create, update and
  submit for review, admin to return to draft, publish, unpublish and delete.
  That is the opposite of the `:viewer` key delivery reads want, so pass the
  writer's key per call rather than widening the configured one:

      KilnClient.create("posts", %{title: "Hi", slug: "hi"},
        api_key: System.fetch_env!("KILN_WRITE_KEY"))

  A service that only **submits drafts for a person to review** should use a
  `:draft_write` key instead (a server newer than Kiln 1.8, kiln_cms#2273): it may `create/3`, and
  `update/4` a draft it authored that is still a draft, and nothing else —
  every transition, `delete/3`, a live or someone else's document and all media
  calls are `reason: :forbidden`. Pass `on_behalf_of:` to `create/3` to record
  which of your users the draft is for (stored for reviewers, never
  authorization). Kiln's `docs/headless-consumer-guide.md` has the full rules.

  ## Errors

  Every function returns `{:error, %KilnClient.Error{}}` on failure, reads and
  writes alike, with a `:reason` atom (`:not_found`, `:forbidden`,
  `:validation`, `:conflict`, `:rate_limited`, … see `KilnClient.Error`).
  Before 0.5.0 the reads returned `{:http_status, status, body}`, a bare
  transport exception, or `:not_found`; `KilnClient.Error.normalize/1` still
  converts those, for code that stored or wrapped them.
  """

  require Logger

  alias KilnClient.Error

  @json_api "application/vnd.api+json"
  # The media upload API is plain JSON, not JSON:API — it is not an
  # AshJsonApi route (see `KilnCMSWeb.MediaUploadController`).
  @json "application/json"

  @typedoc "A flattened JSON:API resource: attributes + id/type/relationships."
  @type item :: %{optional(String.t()) => term()}

  @type list_result :: %{
          items: [item()],
          included: %{optional({String.t(), String.t()}) => item()},
          total: non_neg_integer() | nil
        }

  # --- JSON:API content reads ---

  @doc """
  List records of a content type (plural route name, e.g. `"posts"`;
  dynamic types go through `"entries"` with a `type_name` filter).

  Options:

    * `:filter` — map of public attribute => value (equality) or
      `{op, value}` (e.g. `{:in, ids}`, `{:ilike, "%q%"}`). Encoded as
      `filter[field]=` / `filter[field][op]=`. Nested maps express
      relationship filters (`%{tags: %{slug: "x"}}`).
    * `:custom_filter` — same shape, for admin-defined fields living in
      `custom_fields` (validated against Kiln's FieldDefinition registry).
      The server also accepts a custom field's bare name in `:filter`
      (`filter[price]`) when no built-in attribute has that name, but
      `:custom_filter` is the stable form (a later built-in with the same name
      would shadow it); this client keeps emitting `custom_filter`.
    * `:sort` / `:custom_sort` — list of field strings, `-` prefix descends.
      A custom name also works in `:sort` (`sort=-price`) if custom names come
      last; `:custom_sort` is the stable form and has no ordering rule.
    * `:include` — list of relationship paths (`["tags", "content_links"]`).
    * `:fields` — sparse fieldsets, `%{"post" => ["title", "slug"]}`. Also the
      way to pull public calculations, which are not serialized by default.
    * `:limit` / `:offset` — pagination (server caps limit at 100).
    * `:count` — include `meta.page.total` (default `true`; the total comes
      back as `:total` in the result, `nil` when disabled).
    * `:published` — read the server-side state-filtered `/published` feed
      (default `true`; newest first). Pass `false` for an editor-facing
      caller that must see drafts through the plain index.
    * `:req` — per-call `Req` overrides, applied last (see the module doc).

  Returns `{:ok, %{items:, included:, total:}}`.
  """
  @spec list(String.t(), keyword()) :: {:ok, list_result()} | {:error, Error.t()}
  def list(plural, opts \\ []) do
    case request(:get, list_path(plural, opts), params: query_params(opts), req: opts[:req]) do
      {:ok, doc} -> {:ok, flatten_doc(doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch the first record matching `filter`, or
  `{:error, %KilnClient.Error{reason: :not_found, status: 404}}` when nothing
  matches. The list answered 200 with no rows, so `:body` is `nil`; 404 is
  reported so a "no such record" handler covers this and a real 404 alike.

  Same options as `list/2`. The included lookup is merged into the result
  under `"included"` so detail callers get their joins in one value.
  """
  @spec one(String.t(), map(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def one(plural, filter, opts \\ []) do
    opts = opts |> Keyword.put(:filter, filter) |> Keyword.merge(limit: 1, count: false)

    case list(plural, opts) do
      {:ok, %{items: [item | _], included: included}} ->
        {:ok, Map.put(item, "included", included)}

      {:ok, %{items: []}} ->
        {:error,
         %Error{reason: :not_found, status: 404, method: :get, path: list_path(plural, opts)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The server accepts a larger `page[limit]` but returns only the first 100
  # rows, so batched reads must chunk at this bound to stay lossless.
  @max_page_size 100

  @doc """
  Fetch records by id list (`filter[id][in]=`). Returns the items in `ids`
  order; ids that resolve to nothing are dropped. The server clamps
  `page[limit]` at 100, so longer id lists are fetched in 100-id chunks —
  without that, records past the clamp would be silently indistinguishable
  from misses.
  """
  @spec by_ids(String.t(), [String.t()], keyword()) :: {:ok, [item()]} | {:error, Error.t()}
  def by_ids(plural, ids, opts \\ [])

  def by_ids(_plural, [], _opts), do: {:ok, []}

  def by_ids(plural, ids, opts) do
    ids
    |> Enum.chunk_every(@max_page_size)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, by_id} ->
      chunk_opts =
        opts
        |> Keyword.put(:filter, %{id: {:in, chunk}})
        |> Keyword.merge(limit: length(chunk), count: false)

      case list(plural, chunk_opts) do
        {:ok, %{items: items}} ->
          {:cont, {:ok, Map.merge(by_id, Map.new(items, &{&1["id"], &1}))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, by_id} -> {:ok, ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- per-type search ---

  @doc """
  Per-type full-text search: `GET /api/json/:plural/search[/published]?query=…`.

  Published-only by default via the server-side `/search/published` twin
  (kiln_cms#297) — pass `published: false` to search drafts too (requires an
  editor/admin bearer key). Relevance-ranked; unlike the index routes this
  returns a plain (unpaginated) list — the action caps its own result size —
  so `:total` is always `nil`.

  Options: `:locale`, `:tag_ids` (match content carrying any of these tag
  ids), `:custom_filter` (facets compose with the search), `:sort` (an
  explicit sort overrides relevance, which degrades to the tiebreaker — the
  contract kiln_cms#310 pinned), `:custom_sort` (list of custom-field names,
  `-` prefix descends; precedence is `:sort`, then `:custom_sort`, then
  relevance; on `semantic_search/3` a leading custom sort replaces distance
  ordering; not accepted by `autocomplete/3`), `:limit` (`page[limit]`; the action caps its
  own maximum), `:include`, `:fields`, `:published`, `:req`.
  """
  @spec text_search(String.t(), String.t(), keyword()) ::
          {:ok, list_result()} | {:error, Error.t()}
  def text_search(plural, query, opts \\ []) do
    search_request(plural, "search", [{"query", query}], opts)
  end

  @doc """
  Per-type semantic (vector) search:
  `GET /api/json/:plural/semantic-search[/published]?query=…`.

  Same surface and options as `text_search/3`, ordered by cosine distance.
  Degrades to an empty result set when the server has no embeddings.

  If you have a keyword fallback, bound this call with `:req` (see the module
  doc) — a degraded embedding backend stalls rather than fails.
  """
  @spec semantic_search(String.t(), String.t(), keyword()) ::
          {:ok, list_result()} | {:error, Error.t()}
  def semantic_search(plural, query, opts \\ []) do
    search_request(plural, "semantic-search", [{"query", query}], opts)
  end

  @doc """
  Typo-tolerant title autocomplete:
  `GET /api/json/:plural/autocomplete[/published]?prefix=…`.

  Published-only by default (the base route would suggest draft titles to a
  keyed editor). Options: `:locale`, `:published`. Returns at most 10
  suggestions, best match first.
  """
  @spec autocomplete(String.t(), String.t(), keyword()) ::
          {:ok, list_result()} | {:error, Error.t()}
  def autocomplete(plural, prefix, opts \\ []) do
    search_request(plural, "autocomplete", [{"prefix", prefix}], opts)
  end

  defp search_request(plural, route, base_params, opts) do
    path =
      if published?(opts),
        do: "/api/json/#{plural}/#{route}/published",
        else: "/api/json/#{plural}/#{route}"

    params =
      base_params
      |> put_param(:locale, opts[:locale])
      |> array_param("tag_ids", opts[:tag_ids])
      |> filter_params("custom_filter", opts[:custom_filter])
      |> put_param(:sort, join_sort(opts[:sort]))
      |> put_param(:custom_sort, join_sort(opts[:custom_sort]))
      |> put_param("page[limit]", opts[:limit])
      |> put_param(:include, join_list(opts[:include]))
      |> sparse_fields(opts[:fields])

    case request(:get, path, params: params, req: opts[:req]) do
      {:ok, doc} -> {:ok, flatten_doc(doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- other delivery surfaces ---

  @doc """
  Hybrid (keyword + semantic) search at `/api/search`.

  Options: `:limit` (server caps at 25), `:locale`, `:category` (slug),
  `:facets` (boolean), `:req` (worth a bound + `retry: false` here too — the
  semantic leg stalls when the embedding backend degrades, see the module
  doc). Returns the raw response map — sections under
  `"results"` (`"pages"`, `"posts"`, `"entries"`, `"categories"`, `"tags"`,
  `"tag_groups"`),
  plus `"facets"` when requested, and a `"suggestion"` ("did you mean") on
  sparse results.

  > #### Visibility follows the credential {: .warning}
  >
  > This endpoint has no published-only variant: anonymous calls match
  > published content only, but a bearer key widens it to whatever the
  > minting account can see. Mint delivery keys on a `:viewer` account
  > (see Kiln's `docs/api.md` → "API keys").
  """
  @spec search(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def search(q, opts \\ []) do
    params =
      [q: q]
      |> put_param(:limit, opts[:limit])
      |> put_param(:locale, opts[:locale])
      |> put_param(:category, opts[:category])
      |> put_param(:facets, if(opts[:facets], do: "true"))

    request(:get, "/api/search", params: params, req: opts[:req])
  end

  @doc """
  Fired artifact for a published record: pre-rendered content at
  `GET /api/content/:plural/:slug`. `:surface` is `"json"` (default),
  `"json_ld"` or `"web"`; `:locale` selects a translation.

  `:as_of` reads the document as it was at that moment, reconstructed from
  its version history (`?as_of=`). It takes a `DateTime`, a `NaiveDateTime`
  (read as UTC), a `Date` (the end of that day, UTC) or an ISO 8601 string.
  Two 404 codes tell the cases apart: `"not_published"` (nothing was
  published by then) and `"withdrawn"` (unpublished before then and not
  republished).

  A cold cache answers 503; this retries once after `:retry_delay_ms`
  (default 2000) before giving up. Pass `retry: false` to fail fast.
  """
  @spec artifact(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def artifact(plural, slug, opts \\ []) do
    params =
      []
      |> put_param(:surface, opts[:surface])
      |> put_param(:locale, opts[:locale])
      |> put_param(:as_of, as_of_param(opts[:as_of]))

    path = "/api/content/#{plural}/#{slug}"

    case request(:get, path, params: params, req: opts[:req]) do
      {:error, %Error{status: 503}} = error ->
        if opts[:retry] == false do
          error
        else
          Process.sleep(Keyword.get(opts, :retry_delay_ms, 2_000))
          request(:get, path, params: params, req: opts[:req])
        end

      other ->
        other
    end
  end

  @doc """
  What a content type's collection looked like at a moment:
  `GET /api/content/:type?as_of=`. `as_of` takes the same values as
  `artifact/3`'s `:as_of`.

  Returns the raw response, `%{"as_of", "type", "entries"}`. Each entry
  carries `"slug"`, `"title"`, `"published_at"` and an `"href"` to the
  per-document snapshot. The `"href"` is `nil` when the document has since
  been unpublished or renamed. Unlike the single-document read, the index
  respects unpublish.

  Options: `:limit` (server default 100, max 500), `:req`.
  """
  @spec content_as_of(String.t(), as_of(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def content_as_of(type, as_of, opts \\ []) do
    params =
      [{"as_of", as_of_param(as_of)}]
      |> put_param(:limit, opts[:limit])

    json_get("/api/content/" <> segment(type), params, opts)
  end

  @doc """
  Mint a draft preview link: `POST /api/content/:type/:id/preview-token`.

  The server half of a front end's draft mode. Call it where the API key
  lives, then hand the returned `"token"` (or `"url"`) to the browser, which
  redeems it at `GET /preview/:token` and holds no credential of its own.
  Tokens are signed, read-only, bound to this one document and expire after
  `"expires_in"` seconds.

  The key's owner must be able to see this document's drafts as an editor;
  a `:read` key is enough, since the token only grants a read. Like the
  writes, this takes the key per call (`:api_key`) or from config, and
  returns `{:error, %KilnClient.Error{reason: :no_api_key}}` without sending
  anything when there is none. A 403 means the key's owner cannot edit the
  document, a 404 that it does not exist.

  Returns `{:ok, %{"token", "url", "type", "id", "expires_at",
  "expires_in"}}`. Options: `:api_key`, `:req`.
  """
  @spec mint_preview(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def mint_preview(type, id, opts \\ []) do
    path = "/api/content/#{segment(type)}/#{segment(id)}/preview-token"

    write_request(:post, path, nil, accept: @json, api_key: opts[:api_key], req: opts[:req])
  end

  @doc """
  The site's live delivery schema: `GET /api/schema`, a JSON Schema of the
  `:json` fired-artifact shape, dynamic content types and custom fields
  included. Generate typed models from it rather than from a vendored copy.

  Options: `:types` (a list of content type names, to restrict the
  document), `:blocks_only` (`true` returns the block union alone and reads
  no database), `:req`.
  """
  @spec schema(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def schema(opts \\ []) do
    params =
      []
      |> put_param(:type, join_list(opts[:types]))
      |> put_param(:blocks, if(opts[:blocks_only], do: "only"))

    json_get("/api/schema", params, opts)
  end

  # --- headless routing and site structure ---

  @doc """
  What lives at a URL path: `GET /api/resolve?path=`. The read a front end's
  catch-all route makes, so it can render or redirect without mirroring
  Kiln's URL scheme or redirect table.

  The answer is a verdict, and all three are `{:ok, map}`:

    * `%{"status" => "ok", "type", "slug", "id", "path", "locale"}`:
      published content lives here, found in `"locale"`.
    * `%{"status" => "moved", "to", "type", "slug", "id"}`: a pathauto
      redirect. Send the visitor a 301 to `"to"`.
    * `%{"status" => "not_found"}`: nothing is here. The server answers this
      with a 404, but it is an answer about the path, not a failed call.

  `path` needs its leading slash (`"/blog/hello"`). A missing one, or a
  locale the site does not run, is `{:error, %KilnClient.Error{reason:
  :validation}}`.

  Options: `:locale`, `:fallback` (`false` turns the locale fallback chain
  off), `:fallback_locale`, `:req`.
  """
  @spec resolve_path(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve_path(path, opts \\ []) do
    params = locale_params([{"path", path}], opts)

    case json_get("/api/resolve", params, opts) do
      {:error, %Error{status: 404, body: %{"status" => "not_found"} = verdict}} -> {:ok, verdict}
      other -> other
    end
  end

  @doc """
  Every navigation menu on the site: `GET /api/menus`. Returns
  `{:ok, %{"menus" => [%{"key", "name", "locale"}]}}`; read one with
  `menu/2`. Options: `:req`.
  """
  @spec menus(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def menus(opts \\ []), do: json_get("/api/menus", [], opts)

  @doc """
  One resolved navigation menu: `GET /api/menus/:key`.

  Returns `%{"key", "name", "locale", "items"}`. Each item carries `"id"`,
  `"label"`, `"url"`, `"link_type"`, `"open_in_new_tab"` and its own
  `"children"`. A content item's `"url"` is the target's current published
  path, so renaming a slug moves the menu with it. Items whose target is not
  published are left out with their children; a heading's `"url"` is `nil`.

  A menu missing in the requested locale follows the site's fallback chain;
  `"locale"` names the variant served. Options: `:locale` (default: the
  site's default locale), `:fallback`, `:fallback_locale`, `:req`.
  """
  @spec menu(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def menu(key, opts \\ []) do
    json_get("/api/menus/" <> segment(key), locale_params([], opts), opts)
  end

  @doc """
  The site's locales: `GET /api/locales`. Returns `%{"default", "locales",
  "fallbacks"}`, where `"fallbacks"` maps each locale to the chain a missing
  translation falls back along (`%{"fr-CA" => ["fr", "en"], "en" => []}`).
  Enough to build a locale switcher or an hreflang set. Options: `:req`.
  """
  @spec locales(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def locales(opts \\ []), do: json_get("/api/locales", [], opts)

  @doc """
  Published documents semantically closest to one:
  `GET /api/content/:type/:slug/related`.

  Returns `%{"type", "slug", "locale", "related"}`, each related document
  carrying `"type"`, `"slug"`, `"title"`, a `"score"` (higher is closer) and
  an `"href"` to its artifact. `"related"` is empty when semantic search is
  off. The anchor document must be published.

  Options: `:limit` (server default 5, max 20), `:locale`, `:fallback`,
  `:fallback_locale`, `:req`.
  """
  @spec related(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def related(type, slug, opts \\ []) do
    params = locale_params([], opts) |> put_param(:limit, opts[:limit])

    json_get("/api/content/#{segment(type)}/#{segment(slug)}/related", params, opts)
  end

  # --- forms ---

  @doc """
  An admin-defined form's schema: `GET /api/forms/:slug`, so a front end can
  render it itself. Returns `%{"slug", "name", "description",
  "success_message", "submit_label", "honeypot_field", "submit_url",
  "fields"}`, each field with `"name"`, `"label"`, `"type"`, `"required"`,
  `"options"`, `"help_text"`, `"placeholder"`, `"default_value"`, `"width"`
  and `"min"`, `"max"`, `"step"` (`nil` unless the field is a `"number"` or
  `"rating"`). `"type"` is one of `"string"`, `"text"`, `"email"`,
  `"integer"`, `"boolean"`, `"date"`, `"select"`, `"radio"`, `"checkboxes"`,
  `"phone"`, `"url"`, `"hidden"`, `"number"` and `"rating"`; the list only
  grows, so treat a type you do not know as `"text"`. Newer servers add
  `"challenge"`: `nil`, or the form's
  human-verification check (`"provider"`, `"site_key"`, `"script_url"`,
  `"global"`, `"onload_param"`, `"render_options"`, `"action"`,
  `"action_option"`, `"interactive"`, `"api"`, `"field"`). An unknown or
  inactive form is
  `reason: :not_found`. Options: `:req`.
  """
  @spec form(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def form(slug, opts \\ []), do: json_get("/api/forms/" <> segment(slug), [], opts)

  @doc """
  Submit a form: `POST /api/forms/:slug` with `values` (field name => value)
  as JSON. A `"checkboxes"` value is a list of option strings. Returns `{:ok, %{"ok" => true, "message" => success_message}}`.

  A refusal is `{:error, %KilnClient.Error{reason: :validation, status:
  422}}`; `KilnClient.Error.field_errors/1` reads the messages by field
  name.

  Submission is anonymous by design, so this never sends an API key. The
  server's spam checks still run. If you are relaying a visitor's browser
  submission, pass the honeypot field (`form/2`'s `"honeypot_field"`) and
  `"_kiln_rendered_at"` through untouched. A filled honeypot is discarded
  and still answers success, so never set it yourself.

  A form whose schema has a `"challenge"` wants the visitor's
  human-verification token as `"_kiln_challenge"`: relay it untouched as
  well. Without it the submission is accepted but held for review, and the
  result carries `"challenge" => "held"` (`"verified"` when it passed).

  Options: `:locale` (recorded on the submission), `:req`.
  """
  @spec submit_form(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def submit_form(slug, values, opts \\ []) when is_map(values) do
    body = if opts[:locale], do: Map.put(values, "locale", opts[:locale]), else: values

    request(:post, "/api/forms/" <> segment(slug),
      json: body,
      headers: [{"accept", @json}, {"content-type", @json}],
      anonymous: true,
      req: opts[:req]
    )
  end

  # A plain-JSON delivery read (not JSON:API): the raw body.
  defp json_get(path, params, opts) do
    request(:get, path, params: params, headers: [{"accept", @json}], req: opts[:req])
  end

  # The `?locale=` / `?fallback=` / `?fallback_locale=` trio every
  # locale-aware delivery surface reads (`KilnCMSWeb.DeliveryLocale`).
  defp locale_params(params, opts) do
    fallback =
      case opts[:fallback] do
        nil -> nil
        value -> to_string(value)
      end

    params
    |> put_param(:locale, opts[:locale])
    |> put_param(:fallback, fallback)
    |> put_param(:fallback_locale, opts[:fallback_locale])
  end

  @typedoc "A moment for a point-in-time read: an ISO 8601 string, or a date/time struct."
  @type as_of :: DateTime.t() | NaiveDateTime.t() | Date.t() | String.t()

  defp as_of_param(nil), do: nil
  defp as_of_param(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp as_of_param(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  defp as_of_param(%Date{} = date), do: Date.to_iso8601(date)
  defp as_of_param(value) when is_binary(value), do: value

  # --- sync (delta) API ---

  @doc """
  Mirror the site's public content through `GET /api/sync`: a full snapshot
  when called without `:cursor`, otherwise only what changed since that
  cursor — upserts **and** deletions. Follows `has_more` to the end and returns
  every item in order plus the cursor to store for next time:

      {:ok, %{items: items, cursor: cursor}} = KilnClient.sync(cursor: stored)

      Enum.each(items, fn
        %{"op" => "upsert", "id" => id, "artifact" => body} -> Mirror.put(id, body)
        %{"op" => "delete", "id" => id} -> Mirror.delete(id)
      end)

  Visibility is always anonymous, whatever key is configured: an upsert is a
  document anyone could read now, and one that became unpublished, archived,
  deleted, locked or members-only arrives as a `"delete"` with no body. Items
  are idempotent and may repeat across polls — apply them in order.

  Options: `:cursor`; `:type` (one content type, singular) and `:surface`
  (`"json"` default) for a new sync — a cursor carries its own; `:limit`
  (items per page, max 500); `:retries` (default 3) and `:retry_delay_ms`
  (default 2000) for a page answering 503 while a just-published document's
  artifact compiles; `:req`.

  `{:error, %KilnClient.Error{code: "invalid_cursor"}}` (a 400, so `reason:
  :validation`) means the cursor can no longer be honoured (the server's secret was
  rotated, or it came from another site): start over without `:cursor`.
  """
  @spec sync(keyword()) :: {:ok, %{items: [map()], cursor: String.t()}} | {:error, Error.t()}
  def sync(opts \\ []), do: sync_pages(opts[:cursor], opts, [])

  @doc """
  One page of `GET /api/sync`, for a caller that streams pages instead of
  collecting them all as `sync/1` does. `nil` starts a new sync; otherwise
  pass the previous page's `"cursor"`.

  Returns the raw page, `%{"items" => items, "cursor" => cursor,
  "has_more" => boolean}`. Apply its items, store its cursor, and ask again
  while `"has_more"` is `true`:

      {:ok, page} = KilnClient.sync_page(stored_cursor)

  Options are `sync/1`'s: `:type`, `:surface` and `:limit` for a new sync,
  and `:req`. A page answering 503 while a just-published artifact compiles
  is returned as the error unless you pass `:retries` (default 0 here, 3 in
  `sync/1`) with `:retry_delay_ms`.
  """
  @spec sync_page(String.t() | nil, keyword()) :: {:ok, map()} | {:error, Error.t()}
  def sync_page(cursor \\ nil, opts \\ []),
    do: fetch_sync_page(cursor, opts, Keyword.get(opts, :retries, 0))

  defp sync_pages(cursor, opts, acc) do
    case fetch_sync_page(cursor, opts, Keyword.get(opts, :retries, 3)) do
      {:ok, %{"items" => items, "cursor" => next, "has_more" => true}} ->
        sync_pages(next, opts, [items | acc])

      {:ok, %{"items" => items, "cursor" => next}} ->
        {:ok, %{items: [items | acc] |> Enum.reverse() |> Enum.concat(), cursor: next}}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_sync_page(cursor, opts, retries) do
    params =
      case cursor do
        nil ->
          [{"initial", "true"}]
          |> put_param(:type, opts[:type])
          |> put_param(:surface, opts[:surface])

        cursor ->
          [{"cursor", cursor}]
      end
      |> put_param(:limit, opts[:limit])

    case request(:get, "/api/sync", params: params, req: opts[:req]) do
      {:error, %Error{status: 503}} when retries > 0 ->
        Process.sleep(Keyword.get(opts, :retry_delay_ms, 2_000))
        fetch_sync_page(cursor, opts, retries - 1)

      other ->
        other
    end
  end

  # --- media uploads ---
  #
  # The one write surface this client covers. Every call needs a read + write
  # API key on an editor (or admin) account; a read-only key is a 403. See
  # Kiln's docs/api.md → "Uploading media".

  # Uploads are bounded by the file and the link, not by server read latency.
  @upload_timeout 300_000

  @metadata_opts [:alt, :caption, :decorative, :focal_x, :focal_y, :tag_ids]

  @doc """
  Upload the file at `path` to the media library: `POST /api/media`
  (multipart, streamed from disk).

  The server byte-sniffs the file (its name is not trusted), strips its
  metadata, stores it and queues its variants — the pipeline the editor's
  library runs. Returns the created item, flattened like any other resource,
  with `"processing" => true` while an A/V file's metadata strip is pending
  (its `"url"` isn't live until then).

  An upload is a **write**: it needs a `:read_write` API key — per call
  (`api_key:`) or configured — and returns
  `{:error, %KilnClient.Error{reason: :no_api_key}}` without sending anything
  when there is none, like `create/3` and friends.

  Options: `:filename` (default: the path's basename), the metadata `:alt`,
  `:caption`, `:decorative`, `:focal_x`, `:focal_y` (0.0–1.0) and `:tag_ids`,
  plus `:api_key` and `:req`.
  """
  @spec upload_media(Path.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def upload_media(path, opts \\ []) do
    filename = opts[:filename] || Path.basename(path)

    # Req names multipart fields with atoms. `:"tag_ids[]"` is the one list
    # (multipart repeats a `name[]` field per value); every key here comes
    # from `@metadata_opts`, so no atom is minted from input.
    fields =
      Enum.flat_map(metadata(opts), fn
        {:tag_ids, values} -> Enum.map(List.wrap(values), &{:"tag_ids[]", to_string(&1)})
        {key, value} -> [{key, to_string(value)}]
      end) ++ [file: {File.stream!(path, 65_536), filename: filename}]

    :post
    |> write_request("/api/media", nil,
      form_multipart: fields,
      accept: @json,
      receive_timeout: @upload_timeout,
      api_key: opts[:api_key],
      req: opts[:req]
    )
    |> media_item("/api/media")
  end

  @doc """
  Import a file from a public URL: `POST /api/media/import-url`. The server
  fetches it (public http(s) addresses only, a few re-validated redirects,
  25 MB) and ingests it like an upload. Same options as `upload_media/2`,
  `:filename` overriding the name the URL implies.
  """
  @spec import_media(String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def import_media(url, opts \\ []) do
    body =
      opts
      |> metadata()
      |> Map.new()
      |> Map.put(:url, url)
      |> put_present(:filename, opts[:filename])

    :post
    |> write_request("/api/media/import-url", body,
      accept: @json,
      content_type: @json,
      receive_timeout: @upload_timeout,
      api_key: opts[:api_key],
      req: opts[:req]
    )
    |> media_item("/api/media/import-url")
  end

  @doc """
  Edit an item's metadata: `PATCH /api/json/media-items/:id`. `changes` takes
  `:alt`, `:caption`, `:decorative`, `:focal_x`/`:focal_y` (moving the point
  re-derives the crops) and tags with content's verbs — `:tag_ids` replaces
  the set, `:add_tag_ids`/`:remove_tag_ids` merge (don't combine the two).
  """
  @spec update_media(String.t(), keyword() | map(), keyword()) ::
          {:ok, item()} | {:error, Error.t()}
  def update_media(id, changes, opts \\ []) do
    attributes =
      Map.new(changes, fn {key, value} -> {key, value} end)
      |> Map.take(@metadata_opts ++ [:add_tag_ids, :remove_tag_ids])

    # The JSON:API write route, so it goes through `update/4` — the type is
    # passed explicitly because `"media-items"` does not singularize to
    # `"media_item"`.
    update("media-items", id, attributes, Keyword.put(opts, :type, "media_item"))
  end

  @doc """
  First leg of a direct upload: `POST /api/media/uploads`. Returns
  `{:ok, %{"token", "upload_url", "method", "headers", "expires_at", "max_bytes"}}`
  — `PUT` exactly `byte_size` bytes to `"upload_url"` with `"headers"` as given,
  then `complete_direct_upload/2`. A 501 means the server's storage can't
  presign (it needs S3 with a private bucket); use `upload_media/2` instead.
  """
  @spec begin_direct_upload(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def begin_direct_upload(filename, byte_size, opts \\ []) do
    :post
    |> write_request("/api/media/uploads", %{filename: filename, byte_size: byte_size},
      accept: @json,
      content_type: @json,
      api_key: opts[:api_key],
      req: opts[:req]
    )
    |> case do
      {:ok, %{"data" => upload}} ->
        {:ok, upload}

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_body, body: other, path: "/api/media/uploads"}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Last leg of a direct upload: `POST /api/media/uploads/complete`. The server
  runs the staged bytes through the normal pipeline and deletes the staged
  copy; a token completes once. Takes the metadata options of `upload_media/2`.
  """
  @spec complete_direct_upload(String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def complete_direct_upload(token, opts \\ []) do
    :post
    |> write_request(
      "/api/media/uploads/complete",
      opts |> metadata() |> Map.new() |> Map.put(:token, token),
      accept: @json,
      content_type: @json,
      api_key: opts[:api_key],
      receive_timeout: @upload_timeout,
      req: opts[:req]
    )
    |> media_item("/api/media/uploads/complete")
  end

  @doc """
  `begin_direct_upload/3` → `PUT` → `complete_direct_upload/2` for the file at
  `path`: the bytes go straight to object storage, streamed from disk, for a
  file too large to send through the app. Same options as `upload_media/2`.
  """
  @spec upload_media_direct(Path.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def upload_media_direct(path, opts \\ []) do
    filename = opts[:filename] || Path.basename(path)

    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, upload} <- begin_direct_upload(filename, size, opts),
         :ok <- put_staged(upload, path) do
      complete_direct_upload(upload["token"], opts)
    end
  end

  # Straight to the bucket: no Kiln base URL and no Kiln credentials — the
  # presigned URL is the authorization, and the signed `content-length` in
  # `"headers"` is what the store checks the streamed body against.
  defp put_staged(%{"upload_url" => url, "headers" => headers}, path) do
    [
      method: :put,
      url: url,
      headers: Map.to_list(headers),
      body: File.stream!(path, 65_536),
      receive_timeout: @upload_timeout,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:kiln_client, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      # The store's own refusal (a 403 `SignatureDoesNotMatch` on a stale URL),
      # not Kiln's envelope — so it carries the raw body rather than a `code`.
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         %Error{reason: :storage_refused, status: status, body: body, method: :put, path: url}}

      {:error, exception} ->
        {:error, %Error{reason: :transport, exception: exception, method: :put, path: url}}
    end
  end

  defp metadata(opts),
    do: opts |> Keyword.take(@metadata_opts) |> Enum.reject(&is_nil(elem(&1, 1)))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A created/updated media item: the resource flattened like a list item, plus
  # the upload response's `meta.processing` when it carries one. `path` is the
  # endpoint, for the error when a 2xx carries no `data` resource.
  defp media_item({:ok, %{"data" => %{} = resource}}, _path) do
    item = flatten_resource(resource)

    case resource do
      %{"meta" => %{"processing" => processing}} -> {:ok, Map.put(item, "processing", processing)}
      _ -> {:ok, item}
    end
  end

  defp media_item({:ok, other}, path),
    do: {:error, %Error{reason: :unexpected_body, body: other, method: :post, path: path}}

  defp media_item({:error, _reason} = error, _path), do: error

  # --- editorial reads (editor-tier credential) ---
  #
  # Unlike everything above, these need an editor's (or admin's) API key: an
  # anonymous call is a 401, a viewer's key a 404. They are for tools *about*
  # the content — never configure that key on a delivery site.

  @doc """
  A document's version history, newest first:
  `GET /api/content/:type/:id/revisions` (singular type name; `id` is the
  document's id, not its slug).

  Each revision (`"id"`, `"action"`, `"action_type"`, `"inserted_at"`,
  `"user_id"`, `"changed_fields"`) names the editorial fields its write
  changed, never their values.

  Options: `:limit` (1–100, server default 20), `:cursor` (the previous
  page's `meta.next_cursor`), `:req`.

  Returns `{:ok, %{"data" => [revision], "meta" => %{"limit" => n,
  "next_cursor" => cursor | nil}}}` — page until `next_cursor` is `nil`.
  """
  @spec list_revisions(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_revisions(type, id, opts \\ []) do
    params =
      []
      |> put_param(:limit, opts[:limit])
      |> put_param(:cursor, opts[:cursor])

    request(:get, revisions_path(type, id), params: params, req: opts[:req])
  end

  @doc """
  One revision with its values: that version's own `"changes"` and the full
  `"snapshot"` of the document as it stood at that revision (folded from
  every version up to it), alongside the list fields. Returns
  `{:ok, revision}`.
  """
  @spec revision(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def revision(type, id, version_id, opts \\ []) do
    path = revisions_path(type, id) <> "/" <> segment(version_id)

    case request(:get, path, req: opts[:req]) do
      {:ok, %{"data" => revision}} -> {:ok, revision}
      other -> other
    end
  end

  @doc """
  Revert the document's content to a revision, as the key's owner:
  `POST /api/content/:type/:id/revisions/:version_id/restore`.

  Needs a `:read_write` key — a read-only key gets
  `{:error, %KilnClient.Error{reason: :forbidden}}`. Workflow state is untouched; the
  restore is itself recorded as a new revision, returned under `"revision"`
  with `"id"`, `"type"`, `"state"` and `"restored_version_id"`.
  """
  @spec restore_revision(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def restore_revision(type, id, version_id, opts \\ []) do
    path = revisions_path(type, id) <> "/" <> segment(version_id) <> "/restore"

    case request(:post, path, req: opts[:req]) do
      {:ok, %{"data" => result}} -> {:ok, result}
      other -> other
    end
  end

  @doc """
  Content releases — bundles of publishes/unpublishes that go live together:
  `GET /api/json/releases`. Read-only.

  Takes `list/2`'s JSON:API options (`:filter` — e.g. `%{state: "scheduled"}`
  — `:sort`, `:include` — `["items"]` side-loads each release's contents —
  `:fields`, `:limit`, `:offset`, `:count`, `:req`); there is no
  `/published` feed here. Returns `{:ok, %{items:, included:, total:}}`.
  """
  @spec list_releases(keyword()) :: {:ok, list_result()} | {:error, Error.t()}
  def list_releases(opts \\ []), do: json_api_index("/api/json/releases", opts)

  @doc """
  One release by id: `GET /api/json/releases/:id`. `:include` (`["items"]`)
  and `:fields` as for `list_releases/1`; the included lookup is merged into
  the result under `"included"`, as `one/3` does.
  """
  @spec release(String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def release(id, opts \\ []) do
    params =
      []
      |> put_param(:include, join_list(opts[:include]))
      |> sparse_fields(opts[:fields])

    case request(:get, "/api/json/releases/" <> segment(id), params: params, req: opts[:req]) do
      {:ok, doc} ->
        %{items: [release | _], included: included} = flatten_doc(doc)
        {:ok, Map.put(release, "included", included)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Release items: `GET /api/json/release-items` — `filter: %{release_id: id}`
  for one release's. Each names its document as `"content_type"` +
  `"content_id"`. Same options as `list_releases/1`.
  """
  @spec list_release_items(keyword()) :: {:ok, list_result()} | {:error, Error.t()}
  def list_release_items(opts \\ []), do: json_api_index("/api/json/release-items", opts)

  defp json_api_index(path, opts) do
    case request(:get, path, params: query_params(opts), req: opts[:req]) do
      {:ok, doc} -> {:ok, flatten_doc(doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revisions_path(type, id), do: "/api/content/#{segment(type)}/#{segment(id)}/revisions"

  # Path segments are caller data here (ids, type names), so they are encoded
  # rather than interpolated raw.
  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  # --- JSON:API writes (#330) ---

  @typedoc """
  A workflow transition the JSON:API routes as `PATCH /:plural/:id/<verb>`, by
  its Ash action name. Any other atom or string passes through (kebab-cased
  into the route), so a verb a newer server adds is reachable before this
  client learns it.
  """
  @type workflow_verb ::
          :submit_for_review | :return_to_draft | :publish | :unpublish | atom() | String.t()

  @doc """
  Create a record: `POST /api/json/:plural`.

  Content is always created as a **draft**, attributed to the key's owner;
  publishing is the separate, admin-only `publish/3`. Body content goes in
  `"block_tree"` (a list of block maps) or `"body_markdown"` — never both.
  Relationship arrays (`tag_ids`, `related_post_ids`) and `category_id` are
  plain attributes. A dynamic-type entry needs `type_definition_id` (look it
  up with `one("type-definitions", %{name: "product"})`).

      {:ok, post} =
        KilnClient.create("posts", %{title: "Hi", slug: "hi", body_markdown: "# Hi"},
          api_key: writer_key)

  Options:

    * `:api_key` — the `:read_write` (or `:draft_write`) key for this call
      (falls back to the configured `:api_key`; with neither, nothing is sent).
    * `:on_behalf_of` — sent as the `X-Kiln-On-Behalf-Of` header: an opaque
      label (typically your own user id) that Kiln stores on a draft created
      with a `:draft_write` key, beside the key's id and name, so a reviewer
      sees who it was for. Stored only, never authorization; any other key
      ignores it. `nil` sends no header. The created record carries it back as
      `"on_behalf_of"` (with `"created_via_key_id"` / `"created_via_key_name"`)
      to an editor, an admin, or the key that created it; other readers never
      see those three attributes.
    * `:type` — the JSON:API resource type sent as `data.type`, which the
      server validates. Derived from `plural` (`"entries"` → `"entry"`,
      `"posts"` → `"post"`); pass it for an irregular plural.
    * `:req` — per-call `Req` overrides (see the module doc).

  Returns `{:ok, item}` — the created record, flattened like a read — or
  `{:error, %KilnClient.Error{}}`.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def create(plural, attributes, opts \\ []) do
    # No `id`: the create schema is `additionalProperties: false`, so a
    # client-chosen id is a 400, not a hint.
    body = %{data: %{type: resource_type(plural, opts), attributes: attributes}}

    opts =
      case opts[:on_behalf_of] do
        nil -> opts
        who -> Keyword.put(opts, :extra_headers, [{"x-kiln-on-behalf-of", to_string(who)}])
      end

    :post |> write_request("/api/json/#{plural}", body, opts) |> only_item()
  end

  @doc """
  Edit a record: `PATCH /api/json/:plural/:id`. Same options as `create/3`.

  Only the attributes you send change — omit `"block_tree"` and the body is
  untouched; `[]` clears it. Editing already-published content re-fires its
  artifacts, so the live site never serves a stale render.

  `tag_ids` **replaces** the whole tag set (a partial list detaches the rest);
  send `add_tag_ids` / `remove_tag_ids` to merge instead — not both styles in
  one call (a 400). When rewriting a body, echo each block's `_id` (read them
  with `fields: %{"post" => ["block_ids"]}`) so the server can tell an edit
  from a replacement.
  """
  @spec update(String.t(), String.t(), map(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def update(plural, id, attributes, opts \\ []) do
    body = %{data: %{type: resource_type(plural, opts), id: id, attributes: attributes}}
    :patch |> write_request("/api/json/#{plural}/#{encode(id)}", body, opts) |> only_item()
  end

  @doc """
  Run a workflow transition: `PATCH /api/json/:plural/:id/<verb>` with the
  empty resource object the routes take. Same options as `create/3`.

  A transition from the wrong state is `{:error, %KilnClient.Error{reason:
  :conflict, code: "invalid_state_transition"}}` (the record's actual state
  via `KilnClient.Error.current_state/1`); a key whose owner lacks the right
  is `reason: :forbidden`. Returns `{:ok, item}` in its new state.
  """
  @spec transition(String.t(), String.t(), workflow_verb(), keyword()) ::
          {:ok, item()} | {:error, Error.t()}
  def transition(plural, id, verb, opts \\ []) do
    route = verb |> to_string() |> String.replace("_", "-") |> encode()
    body = %{data: %{type: resource_type(plural, opts), id: id, attributes: %{}}}

    :patch
    |> write_request("/api/json/#{plural}/#{encode(id)}/#{route}", body, opts)
    |> only_item()
  end

  @doc "draft → in_review. Editor-or-above `:read_write` key. See `transition/4`."
  @spec submit_for_review(String.t(), String.t(), keyword()) ::
          {:ok, item()} | {:error, Error.t()}
  def submit_for_review(plural, id, opts \\ []),
    do: transition(plural, id, :submit_for_review, opts)

  @doc "in_review → draft — the reviewer's \"send it back\". Admin key. See `transition/4`."
  @spec return_to_draft(String.t(), String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def return_to_draft(plural, id, opts \\ []), do: transition(plural, id, :return_to_draft, opts)

  @doc "Publish and fire the record's artifacts. Admin key. See `transition/4`."
  @spec publish(String.t(), String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def publish(plural, id, opts \\ []), do: transition(plural, id, :publish, opts)

  @doc "Take published content down and purge its artifacts. Admin key. See `transition/4`."
  @spec unpublish(String.t(), String.t(), keyword()) :: {:ok, item()} | {:error, Error.t()}
  def unpublish(plural, id, opts \\ []), do: transition(plural, id, :unpublish, opts)

  @doc """
  Soft-delete a record: `DELETE /api/json/:plural/:id`. Reversible — the
  record moves to the trash, restorable from the editor. Admin key. There is
  no hard delete over the API, by design. Options: `:api_key`, `:req`.

  Returns `:ok` or `{:error, %KilnClient.Error{}}`.
  """
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(plural, id, opts \\ []) do
    case write_request(:delete, "/api/json/#{plural}/#{encode(id)}", nil, opts) do
      {:ok, _body} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # --- GraphQL ---

  @doc """
  Run a GraphQL operation: `POST /gql`. Returns `{:ok, data}`; a response
  carrying a top-level `errors` array is `{:error, %KilnClient.Error{reason:
  :graphql}}` with the errors in `:errors` and any partial result in `:data`.

      {:ok, %{"postBySlug" => post}} =
        KilnClient.graphql(
          "query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }",
          %{slug: "hello-world", locale: "en"}
        )

  Sends the API key (`:api_key` option, else the configured one) when there
  is one, but does not require it — the published-content queries are
  anonymous. Options: `:api_key`, `:operation_name`, `:req`.

  Ash mutations report a refused write *inside* `data` — the payload's own
  `errors` field, with `result: nil` — not as a top-level error, so select
  `errors { message code }` on mutations and check it.
  """
  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def graphql(query, variables \\ %{}, opts \\ []) do
    payload =
      case opts[:operation_name] do
        nil -> %{query: query, variables: variables}
        name -> %{query: query, variables: variables, operationName: name}
      end

    req_opts = [
      json: payload,
      headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
      req: opts[:req]
    ]

    case do_request(:post, "/gql", req_opts, api_key(opts)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        graphql_result(body, status)

      # Absinthe refuses an unparseable document with a 400 whose body is
      # still GraphQL-shaped; surface it as the GraphQL error it is.
      {:ok, %Req.Response{status: 400, body: %{"errors" => [_ | _]} = body}} ->
        graphql_result(body, 400)

      other ->
        to_error(other, :post, "/gql")
    end
  end

  defp graphql_result(%{"errors" => [_ | _] = errors} = body, status) do
    first = hd(errors)

    code =
      if is_map(first), do: first["code"] || get_in(first, ["extensions", "code"])

    {:error,
     %Error{
       reason: :graphql,
       status: status,
       code: code,
       errors: errors,
       data: body["data"],
       body: body,
       method: :post,
       path: "/gql"
     }}
  end

  defp graphql_result(%{"data" => data}, _status), do: {:ok, data || %{}}
  defp graphql_result(_body, _status), do: {:ok, %{}}
  @doc "Browser-facing Kiln base URL (media `url`s are absolute, so this is rarely needed)."
  @spec public_url() :: String.t()
  def public_url do
    Application.get_env(:kiln_client, :public_url) ||
      Application.get_env(:kiln_client, :base_url, "")
  end

  # --- image transforms ---

  @doc """
  Absolute on-the-fly transform URL for a media item — see
  `KilnClient.Image.url/2` for the options and signing.

      KilnClient.image_url(media, width: 800, aspect_ratio: "16:9", format: :auto)
  """
  @spec image_url(map(), keyword()) :: String.t()
  defdelegate image_url(media, opts \\ []), to: KilnClient.Image, as: :url

  @doc """
  `srcset` of transform URLs for a media item, or `nil` without dimensions —
  see `KilnClient.Image.srcset/2`.
  """
  @spec image_srcset(map(), keyword()) :: String.t() | nil
  defdelegate image_srcset(media, opts \\ []), to: KilnClient.Image, as: :srcset

  # --- shapes ---

  @doc "Relationship refs of `item` under `name`, always as a list of `%{\"type\", \"id\"}`."
  @spec rel(item(), String.t()) :: [map()]
  def rel(item, name), do: item |> get_in(["relationships", name]) |> List.wrap()

  @doc "Resolve a relationship of `item` through an included lookup, dropping misses."
  @spec resolve(item(), String.t(), map()) :: [item()]
  def resolve(item, name, included) do
    item
    |> rel(name)
    |> Enum.map(&included[{&1["type"], &1["id"]}])
    |> Enum.reject(&is_nil/1)
  end

  # --- internal: JSON:API document flattening ---

  defp flatten_doc(%{"data" => data} = doc) do
    included =
      doc
      |> Map.get("included", [])
      |> Map.new(fn res -> {{res["type"], res["id"]}, flatten_resource(res)} end)

    items = data |> List.wrap() |> Enum.map(&flatten_resource/1)

    %{items: items, included: included, total: get_in(doc, ["meta", "page", "total"])}
  end

  defp flatten_doc(doc), do: %{items: [], included: %{}, total: nil, raw: doc}

  defp flatten_resource(res) do
    relationships =
      res
      |> Map.get("relationships", %{})
      |> Map.new(fn
        {name, %{"data" => refs}} ->
          {name, refs |> List.wrap() |> Enum.map(&Map.take(&1, ["type", "id"]))}

        {name, _} ->
          {name, []}
      end)

    res
    |> Map.get("attributes", %{})
    |> Map.put("id", res["id"])
    |> Map.put("type", res["type"])
    |> Map.put("relationships", relationships)
  end

  # --- internal: query params ---

  defp query_params(opts) do
    []
    |> filter_params("filter", opts[:filter])
    |> filter_params("custom_filter", opts[:custom_filter])
    |> put_param(:sort, join_sort(opts[:sort]))
    |> put_param(:custom_sort, join_sort(opts[:custom_sort]))
    |> put_param(:include, join_list(opts[:include]))
    |> sparse_fields(opts[:fields])
    |> page_params(opts)
  end

  defp filter_params(params, _prefix, nil), do: params

  defp filter_params(params, prefix, filter) do
    params ++
      Enum.flat_map(filter, fn {field, spec} -> filter_param("#{prefix}[#{field}]", spec) end)
  end

  # {op, value} tuples, nested relationship filters, and bare equality values.
  defp filter_param(key, {:in, values}), do: Enum.map(values, &{"#{key}[in][]", to_string(&1)})
  defp filter_param(key, {op, value}), do: [{"#{key}[#{op}]", to_string(value)}]

  defp filter_param(key, %{} = nested),
    do: Enum.flat_map(nested, fn {field, spec} -> filter_param("#{key}[#{field}]", spec) end)

  defp filter_param(key, value), do: [{key, to_string(value)}]

  # A bare (non-`filter[...]`) array-typed read-action argument — e.g. the
  # `tag_ids` facet argument `search_read`/`semantic_read` declare (kiln_cms's
  # `Content` macro), which JSON:API only resolves as its own top-level
  # `tag_ids[]=` param, the same way `custom_filter` resolves as `custom_
  # filter[field]=` rather than nesting under a generic `filter[...]`
  # namespace: AshJsonApi's `filter[...]` only reaches resource fields
  # (attributes/relationships), never a custom action's own arguments.
  defp array_param(params, _key, empty) when empty in [nil, []], do: params

  defp array_param(params, key, values),
    do: params ++ Enum.map(values, &{"#{key}[]", to_string(&1)})

  defp page_params(params, opts) do
    params
    |> put_param("page[limit]", opts[:limit])
    |> put_param("page[offset]", opts[:offset])
    |> put_param("page[count]", if(Keyword.get(opts, :count, true), do: "true"))
  end

  defp sparse_fields(params, nil), do: params

  defp sparse_fields(params, fields) do
    Enum.reduce(fields, params, fn {type, names}, acc ->
      acc ++ [{"fields[#{type}]", join_list(names)}]
    end)
  end

  defp join_sort(nil), do: nil
  defp join_sort(sort), do: Enum.join(sort, ",")

  defp join_list(nil), do: nil
  defp join_list(values), do: Enum.join(values, ",")

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  # Published-only unless a caller explicitly opts out. Safe by default: the
  # alternative (opting *in* per call site) re-arms the moment someone adds one.
  defp published?(opts), do: Keyword.get(opts, :published, true)

  defp list_path(plural, opts) do
    if published?(opts), do: "/api/json/#{plural}/published", else: "/api/json/#{plural}"
  end

  # --- internal: write shapes ---

  # The singular JSON:API `type` the server validates `data.type` against.
  # Every built-in plural is regular (`posts`, `pages`) or `-ies` (`entries`);
  # an irregular overlay type passes `:type` explicitly.
  defp resource_type(plural, opts) do
    cond do
      opts[:type] -> to_string(opts[:type])
      String.ends_with?(plural, "ies") -> String.slice(plural, 0..-4//1) <> "y"
      String.ends_with?(plural, "s") -> String.slice(plural, 0..-2//1)
      true -> plural
    end
  end

  # Every write route answers a single-resource document.
  defp only_item({:ok, body}) do
    case flatten_doc(body || %{}) do
      %{items: [item | _]} ->
        {:ok, item}

      _ ->
        {:error, %Error{reason: :http, code: "empty_response", body: body}}
    end
  end

  defp only_item({:error, %Error{}} = error), do: error

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  # --- internal: transport ---

  # Reads: `{:ok, body}` or `{:error, %Error{}}`, the same struct the writes
  # return (0.5.0; before that a read returned `{:http_status, status, body}`
  # or the bare exception). A 404 isn't logged: a missing slug is an expected
  # answer for a read, not a fault.
  #
  # `anonymous: true` sends no key even when one is configured: a public form
  # submission is anonymous by design, and a key there would only leak the
  # credential to a route that ignores it.
  defp request(method, path, opts) do
    {anonymous?, opts} = Keyword.pop(opts, :anonymous, false)
    key = if anonymous?, do: nil, else: Application.get_env(:kiln_client, :api_key)

    case do_request(method, path, opts, key) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 404, body: body, headers: headers}} ->
        {:error, Error.from_response(404, body, headers, method: method, path: path)}

      other ->
        to_error(other, method, path)
    end
  end

  # Writes fail fast without a key: an anonymous write can only be refused,
  # and finding that out client-side costs no round trip and no rate-limit
  # budget. The error names the option, never a value.
  #
  # `opts` carries the media upload API's departures from JSON:API — it speaks
  # plain JSON, takes a `:form_multipart` body on `POST /api/media` (whose
  # content type Req must write itself, boundary and all), and is bounded by
  # the upload timeout rather than the read one. The defaults reproduce the
  # JSON:API behaviour exactly, so the content writes are unchanged.
  defp write_request(method, path, body, opts) do
    case api_key(opts) do
      nil ->
        {:error, %Error{reason: :no_api_key, method: method, path: path}}

      key ->
        accept = opts[:accept] || @json_api
        extra = opts[:extra_headers] || []

        # Req's `:json` encodes the body but only *defaults* the content
        # type, so the media type set here is the one sent.
        req_opts =
          cond do
            opts[:form_multipart] ->
              [headers: [{"accept", accept} | extra], form_multipart: opts[:form_multipart]]

            body == nil ->
              [headers: [{"accept", accept} | extra]]

            true ->
              [
                headers: [
                  {"accept", accept},
                  {"content-type", opts[:content_type] || @json_api} | extra
                ],
                json: body
              ]
          end
          |> Keyword.put(:req, opts[:req])
          |> put_present_opt(:receive_timeout, opts[:receive_timeout])

        case do_request(method, path, req_opts, key) do
          # A soft-delete may answer 200 with the record or an empty 204.
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {:ok, if(body == "", do: nil, else: body)}

          other ->
            to_error(other, method, path)
        end
    end
  end

  defp to_error({:ok, %Req.Response{status: status, body: body, headers: headers}}, method, path) do
    error = Error.from_response(status, body, headers, method: method, path: path)
    Logger.warning("Kiln #{method} #{path} returned #{status} (#{error.code || error.reason})")
    {:error, error}
  end

  defp to_error({:error, exception}, method, path) do
    Logger.error("Kiln #{method} #{path} failed: #{inspect(exception)}")
    {:error, %Error{reason: :transport, exception: exception, method: method, path: path}}
  end

  defp put_present_opt(opts, _key, nil), do: opts
  defp put_present_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp api_key(opts) do
    case Keyword.get(opts, :api_key) || Application.get_env(:kiln_client, :api_key) do
      key when key in [nil, ""] -> nil
      key -> key
    end
  end

  defp do_request(method, path, opts, key) do
    base_url = Application.get_env(:kiln_client, :base_url, "http://localhost:4000")

    # Per-call `:req` overrides apply LAST, via `Req.merge/2` — so they win
    # over the defaults and the configured `req_options`, and composite
    # options like `:headers` merge instead of clobbering.
    {overrides, opts} = Keyword.pop(opts, :req)

    [
      method: method,
      url: base_url <> path,
      headers: [{"accept", @json_api}],
      receive_timeout: 15_000
    ]
    |> Keyword.merge(opts)
    |> maybe_auth(key)
    |> Keyword.merge(Application.get_env(:kiln_client, :req_options, []))
    |> Req.new()
    |> Req.merge(overrides || [])
    |> Req.request()
  end

  defp maybe_auth(opts, key) when key in [nil, ""], do: opts
  defp maybe_auth(opts, key), do: Keyword.put(opts, :auth, {:bearer, key})
end
