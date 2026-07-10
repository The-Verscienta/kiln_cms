defmodule KilnClient do
  @moduledoc """
  Official Elixir client for the Kiln CMS delivery APIs — the JSON:API read
  surface at `/api/json/*`, per-type and hybrid search, and fired artifacts at
  `/api/content/:type/:slug` (see Kiln's `docs/json-api.md` and
  `docs/headless-consumer-guide.md`).

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
  """

  require Logger

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

  Returns `{:ok, %{items:, included:, total:}}`.
  """
  @spec list(String.t(), keyword()) :: {:ok, list_result()} | {:error, term()}
  def list(plural, opts \\ []) do
    path =
      if published?(opts),
        do: "/api/json/#{plural}/published",
        else: "/api/json/#{plural}"

    case request(:get, path, params: query_params(opts)) do
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

  @doc """
  Fetch records by id list (one request, `filter[id][in]=`). Returns the
  items in `ids` order; ids that resolve to nothing are dropped.
  """
  @spec by_ids(String.t(), [String.t()], keyword()) :: {:ok, [item()]} | {:error, term()}
  def by_ids(plural, ids, opts \\ [])

  def by_ids(_plural, [], _opts), do: {:ok, []}

  def by_ids(plural, ids, opts) do
    opts =
      opts
      |> Keyword.put(:filter, %{id: {:in, ids}})
      |> Keyword.merge(limit: length(ids), count: false)

    with {:ok, %{items: items}} <- list(plural, opts) do
      by_id = Map.new(items, &{&1["id"], &1})
      {:ok, ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)}
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

  Options: `:locale`, `:custom_filter` (facets compose with the search),
  `:include`, `:fields`, `:published`.
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
      |> filter_params("custom_filter", opts[:custom_filter])
      |> put_param(:include, join_list(opts[:include]))
      |> sparse_fields(opts[:fields])

    case request(:get, path, params: params) do
      {:ok, doc} -> {:ok, flatten_doc(doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- other delivery surfaces ---

  @doc """
  Hybrid (keyword + semantic) search at `/api/search`.

  Options: `:limit` (server caps at 25), `:locale`, `:category` (slug),
  `:facets` (boolean). Returns the raw response map — sections under
  `"results"` (`"pages"`, `"posts"`, `"entries"`, `"categories"`, `"tags"`),
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

    request(:get, "/api/search", params: params)
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

    case request(:get, path, params: params) do
      {:error, {:http_status, 503, _}} = error ->
        if opts[:retry] == false do
          error
        else
          Process.sleep(Keyword.get(opts, :retry_delay_ms, 2_000))
          request(:get, path, params: params)
        end

      other ->
        other
    end
  end

  @doc "Browser-facing Kiln base URL (media `url`s are absolute, so this is rarely needed)."
  @spec public_url() :: String.t()
  def public_url do
    Application.get_env(:kiln_client, :public_url) ||
      Application.get_env(:kiln_client, :base_url, "")
  end

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

  # --- internal: transport ---

  defp request(method, path, opts) do
    base_url = Application.get_env(:kiln_client, :base_url, "http://localhost:4000")

    req =
      [
        method: method,
        url: base_url <> path,
        headers: [{"accept", "application/vnd.api+json"}],
        receive_timeout: 15_000
      ]
      |> Keyword.merge(opts)
      |> maybe_auth(Application.get_env(:kiln_client, :api_key))
      |> Keyword.merge(Application.get_env(:kiln_client, :req_options, []))
      |> Req.new()

    case Req.request(req) do
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

  defp maybe_auth(opts, key) when key in [nil, ""], do: opts
  defp maybe_auth(opts, key), do: Keyword.put(opts, :auth, {:bearer, key})
end
