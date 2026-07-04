defmodule Showcase.Kiln do
  @moduledoc """
  A small headless client for the KilnCMS delivery API — the only way this app
  talks to KilnCMS. There is no database and no shared code: everything is HTTP.

  It exercises the public delivery surfaces an external frontend would use:

    * `GET /api/json/posts/published` — the published blog index (JSON:API)
    * `GET /api/content/:type/:slug?surface=json` — a document's typed blocks
      (the v2 fired-artifact API, decision D9)
    * `POST /gql` — GraphQL search (`searchPosts`)
    * `GET /api/locales` — the configured content locales
    * `GET /api/forms/:slug` + `POST /api/forms/:slug` — public forms

  Published content is world-readable, so none of this *requires* auth. If a
  `:api_key` is configured it's sent as a bearer token, which is how a
  third-party integrator would authenticate (and how you'd widen access beyond
  public content). See `config/runtime.exs`.
  """
  require Logger

  @doc "Base URL of the KilnCMS instance, e.g. `http://localhost:4000`."
  def base_url, do: config(:base_url, "http://localhost:4000")

  @doc "Locale to request from the delivery API."
  def locale, do: config(:locale, "en")

  defp api_key, do: config(:api_key, nil)
  defp config(key, default), do: Application.get_env(:showcase, __MODULE__, [])[key] || default

  # ── blog index (JSON:API) ──────────────────────────────────────────────────

  @doc """
  The published posts, newest first, as `%{title, slug, excerpt, published_at}`
  maps. Uses the JSON:API `/posts/published` index.
  """
  def list_posts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    loc = Keyword.get(opts, :locale, locale())

    case get("/api/json/posts/published",
           params: [
             {"page[limit]", limit},
             {"sort", "-published_at"},
             {"filter[locale]", loc}
           ],
           headers: [{"accept", "application/vnd.api+json"}]
         ) do
      {:ok, %{"data" => data}} when is_list(data) ->
        {:ok, Enum.map(data, &jsonapi_post/1)}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp jsonapi_post(%{"attributes" => attrs}) do
    %{
      title: attrs["title"],
      slug: attrs["slug"],
      excerpt: attrs["excerpt"],
      published_at: attrs["published_at"]
    }
  end

  # ── document delivery (fired artifacts) ─────────────────────────────────────

  @doc """
  Fetch one published document's typed blocks via the `json` surface, returned
  as `%{"type" => …, "title" => …, "slug" => …, "blocks" => [...]}`. Returns
  `:not_found` for an unknown/unpublished slug, `:compiling` while the artifact
  is still being fired (HTTP 503), or `{:error, reason}`.
  """
  def fetch_document(type, slug, opts \\ []) do
    loc = Keyword.get(opts, :locale, locale())

    case get("/api/content/#{URI.encode(type)}/#{URI.encode(slug)}",
           params: [{"surface", "json"}, {"locale", loc}]
         ) do
      {:ok, %{"errors" => _}} -> :not_found
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:error, {:status, 404, _}} -> :not_found
      {:error, {:status, 503, _}} -> :compiling
      {:error, reason} -> {:error, reason}
    end
  end

  # ── search (GraphQL) ────────────────────────────────────────────────────────

  @doc """
  Search published posts via the AshGraphql `searchPosts` query. Returns a list
  of `%{title, slug, excerpt}` hits (empty on error or blank query).
  """
  def search_posts(query, opts \\ [])
  def search_posts("", _opts), do: {:ok, []}

  def search_posts(query, opts) do
    loc = Keyword.get(opts, :locale, locale())

    body = %{
      query: """
      query Search($q: String!, $locale: String) {
        searchPosts(query: $q, locale: $locale) { title slug excerpt }
      }
      """,
      variables: %{q: query, locale: loc}
    }

    case post("/gql", body) do
      {:ok, %{"data" => %{"searchPosts" => hits}}} when is_list(hits) ->
        {:ok, Enum.map(hits, &%{title: &1["title"], slug: &1["slug"], excerpt: &1["excerpt"]})}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── locales ─────────────────────────────────────────────────────────────────

  @doc "The configured content locales: `%{default: \"en\", locales: [...]}`."
  def locales do
    case get("/api/locales") do
      {:ok, %{"default" => default, "locales" => locales}} ->
        {:ok, %{default: default, locales: locales}}

      {:ok, _} ->
        {:ok, %{default: locale(), locales: [locale()]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── public forms ────────────────────────────────────────────────────────────

  @doc "Fetch an admin-defined form's schema by slug."
  def form_schema(slug) do
    case get("/api/forms/#{URI.encode(slug)}") do
      {:ok, %{"errors" => _}} -> :not_found
      {:ok, schema} when is_map(schema) -> {:ok, schema}
      {:error, {:status, 404, _}} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Submit a form (JSON) to `POST /api/forms/:slug`. Returns:

    * `{:ok, message}` on success,
    * `{:error, {:validation, %{field => message}}}` on a 422 with field errors,
    * `{:error, reason}` otherwise.
  """
  def submit_form(slug, fields) when is_map(fields) do
    case post("/api/forms/#{URI.encode(slug)}", fields) do
      {:ok, %{"ok" => true} = body} ->
        {:ok, body["message"]}

      {:error, {:status, 422, %{"errors" => errors}}} ->
        {:error, {:validation, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── HTTP plumbing ───────────────────────────────────────────────────────────

  # Fail fast: no retries and a short connect timeout, so a slow/down KilnCMS
  # can't hang a page render for many seconds.
  @req_opts [retry: false, connect_options: [timeout: 2_000], receive_timeout: 5_000]

  defp get(path, opts \\ []) do
    [url: base_url() <> path, headers: auth_headers()]
    |> Keyword.merge(@req_opts)
    |> Keyword.merge(opts, fn :headers, a, b -> a ++ b end)
    |> Req.request()
    |> handle()
  end

  defp post(path, json) do
    [method: :post, url: base_url() <> path, json: json, headers: auth_headers()]
    |> Keyword.merge(@req_opts)
    |> Req.request()
    |> handle()
  end

  defp auth_headers do
    case api_key() do
      nil -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:status, status, body}}

  defp handle({:error, exception}) do
    Logger.warning("KilnCMS request failed: #{Exception.message(exception)}")
    {:error, exception}
  end
end
