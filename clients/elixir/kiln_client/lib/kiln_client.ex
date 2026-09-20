defmodule KilnClient do
  @moduledoc """
  Official Elixir client for the KilnCMS APIs — the JSON:API read surface at
  `/api/json/*`, per-type and hybrid search, fired artifacts at
  `/api/content/:type/:slug`, the JSON:API write surface (create, update,
  workflow transitions, soft-delete), the media upload API (`upload_media/2`
  and friends) the `/api/sync` delta API and a minimal `/gql` helper (see Kiln's `docs/json-api.md` and
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

  ## Errors

  Writes and `graphql/3` return `{:error, %KilnClient.Error{}}` with a
  `:reason` atom (`:forbidden`, `:validation`, `:conflict`, `:rate_limited`, …
  — see `KilnClient.Error`). The read functions keep their original
  `{:error, {:http_status, status, body}}` shape; `KilnClient.Error.normalize/1`
  converts one when a caller wants a single error handler for both.
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
    * `:sort` / `:custom_sort` — list of field strings, `-` prefix descends.
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
  @spec list(String.t(), keyword()) :: {:ok, list_result()} | {:error, term()}
  def list(plural, opts \\ []) do
    path =
      if published?(opts),
        do: "/api/json/#{plural}/published",
        else: "/api/json/#{plural}"

    case request(:get, path, params: query_params(opts), req: opts[:req]) do
      {:ok, doc} -> {:ok, flatten_doc(doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch the first record matching `filter`, or `{:error, :not_found}`.

  Same options as `list/2`. The included lookup is merged into the result
  under `"included"` so detail callers get their joins in one value.
  """
  @spec one(String.t(), map(), keyword()) :: {:ok, item()} | {:error, term()}
  def one(plural, filter, opts \\ []) do
    opts = opts |> Keyword.put(:filter, filter) |> Keyword.merge(limit: 1, count: false)

    case list(plural, opts) do
      {:ok, %{items: [item | _], included: included}} ->
        {:ok, Map.put(item, "included", included)}

      {:ok, %{items: []}} ->
        {:error, :not_found}

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
  @spec by_ids(String.t(), [String.t()], keyword()) :: {:ok, [item()]} | {:error, term()}
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
  contract kiln_cms#310 pinned), `:limit` (`page[limit]`; the action caps its
  own maximum), `:include`, `:fields`, `:published`, `:req`.
  """
  @spec text_search(String.t(), String.t(), keyword()) ::
          {:ok, list_result()} | {:error, term()}
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
          {:ok, list_result()} | {:error, term()}
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
          {:ok, list_result()} | {:error, term()}
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
  @spec search(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  A cold cache answers 503; this retries once after `:retry_delay_ms`
  (default 2000) before giving up. Pass `retry: false` to fail fast.
  """
  @spec artifact(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def artifact(plural, slug, opts \\ []) do
    params =
      []
      |> put_param(:surface, opts[:surface])
      |> put_param(:locale, opts[:locale])

    path = "/api/content/#{plural}/#{slug}"

    case request(:get, path, params: params, req: opts[:req]) do
      {:error, {:http_status, 503, _}} = error ->
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

  `{:error, {:http_status, 400, %{"errors" => [%{"code" => "invalid_cursor"} | _]}}}`
  means the cursor can no longer be honoured (the server's secret was
  rotated, or it came from another site): start over without `:cursor`.
  """
  @spec sync(keyword()) :: {:ok, %{items: [map()], cursor: String.t()}} | {:error, term()}
  def sync(opts \\ []), do: sync_pages(opts[:cursor], opts, [])

  defp sync_pages(cursor, opts, acc) do
    case sync_page(cursor, opts, Keyword.get(opts, :retries, 3)) do
      {:ok, %{"items" => items, "cursor" => next, "has_more" => true}} ->
        sync_pages(next, opts, [items | acc])

      {:ok, %{"items" => items, "cursor" => next}} ->
        {:ok, %{items: [items | acc] |> Enum.reverse() |> Enum.concat(), cursor: next}}

      {:error, _} = error ->
        error
    end
  end

  defp sync_page(cursor, opts, retries) do
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
      {:error, {:http_status, 503, _}} when retries > 0 ->
        Process.sleep(Keyword.get(opts, :retry_delay_ms, 2_000))
        sync_page(cursor, opts, retries - 1)

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
    |> media_item()
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
    |> media_item()
  end

  @doc """
  Edit an item's metadata: `PATCH /api/json/media-items/:id`. `changes` takes
  `:alt`, `:caption`, `:decorative`, `:focal_x`/`:focal_y` (moving the point
  re-derives the crops) and tags with content's verbs — `:tag_ids` replaces
  the set, `:add_tag_ids`/`:remove_tag_ids` merge (don't combine the two).
  """
  @spec update_media(String.t(), keyword() | map(), keyword()) ::
          {:ok, item()} | {:error, term()}
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
          {:ok, map()} | {:error, term()}
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
    |> media_item()
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
  # the upload response's `meta.processing` when it carries one.
  defp media_item({:ok, %{"data" => %{} = resource}}) do
    item = flatten_resource(resource)

    case resource do
      %{"meta" => %{"processing" => processing}} -> {:ok, Map.put(item, "processing", processing)}
      _ -> {:ok, item}
    end
  end

  defp media_item({:ok, other}), do: {:error, {:unexpected_body, other}}
  defp media_item({:error, reason}), do: {:error, reason}

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
  @spec list_revisions(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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
          {:ok, map()} | {:error, term()}
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
  `{:error, {:http_status, 403, body}}`. Workflow state is untouched; the
  restore is itself recorded as a new revision, returned under `"revision"`
  with `"id"`, `"type"`, `"state"` and `"restored_version_id"`.
  """
  @spec restore_revision(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
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
  @spec list_releases(keyword()) :: {:ok, list_result()} | {:error, term()}
  def list_releases(opts \\ []), do: json_api_index("/api/json/releases", opts)

  @doc """
  One release by id: `GET /api/json/releases/:id`. `:include` (`["items"]`)
  and `:fields` as for `list_releases/1`; the included lookup is merged into
  the result under `"included"`, as `one/3` does.
  """
  @spec release(String.t(), keyword()) :: {:ok, item()} | {:error, term()}
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
  @spec list_release_items(keyword()) :: {:ok, list_result()} | {:error, term()}
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

    * `:api_key` — the `:read_write` key for this call (falls back to the
      configured `:api_key`; with neither, nothing is sent).
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

  # Reads: the original return contract, `{:ok, body}` or
  # `{:error, {:http_status, status, body}}` / `{:error, exception}` — kept
  # as-is so existing callers' pattern matches hold.
  defp request(method, path, opts) do
    case do_request(method, path, opts, Application.get_env(:kiln_client, :api_key)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:error, {:http_status, 404, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Kiln #{method} #{path} returned #{status}: #{inspect(body)}")
        {:error, {:http_status, status, body}}

      {:error, exception} ->
        Logger.error("Kiln #{method} #{path} failed: #{inspect(exception)}")
        {:error, exception}
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

        # Req's `:json` encodes the body but only *defaults* the content
        # type, so the media type set here is the one sent.
        req_opts =
          cond do
            opts[:form_multipart] ->
              [headers: [{"accept", accept}], form_multipart: opts[:form_multipart]]

            body == nil ->
              [headers: [{"accept", accept}]]

            true ->
              [
                headers: [{"accept", accept}, {"content-type", opts[:content_type] || @json_api}],
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
