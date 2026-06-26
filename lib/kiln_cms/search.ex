defmodule KilnCMS.Search do
  @moduledoc """
  Semantic / hybrid search facade and config access.

  All knobs live under `config :kiln_cms, KilnCMS.Search` (see
  `docs/semantic-search-plan.md`). With `semantic: false` (the default) the
  embedding model never loads and content writes skip embedding work, so the
  default install pays nothing.
  """

  @doc "Whether semantic search is enabled."
  @spec semantic?() :: boolean()
  def semantic?, do: cfg(:semantic, false)

  @doc "The configured embedder adapter module."
  @spec embedder() :: module()
  def embedder, do: cfg(:embedder, KilnCMS.Search.Embedder.Bumblebee)

  @doc "Hugging Face model id used for embeddings."
  @spec model() :: String.t()
  def model, do: cfg(:model, "BAAI/bge-small-en-v1.5")

  @doc "Embedding vector dimension (must match the model)."
  @spec dim() :: pos_integer()
  def dim, do: cfg(:dim, 384)

  @doc "Embed a single string into a list of floats via the active adapter."
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text), do: embedder().embed(text)

  @doc "Whether reranking is enabled (a reranker model is loaded)."
  @spec rerank?() :: boolean()
  def rerank?, do: cfg(:rerank, false)

  @doc "The configured reranker adapter module."
  @spec reranker() :: module()
  def reranker, do: cfg(:reranker, KilnCMS.Search.Reranker.Bumblebee)

  @doc "Hugging Face model id used for reranking."
  @spec rerank_model() :: String.t()
  def rerank_model, do: cfg(:rerank_model, "BAAI/bge-reranker-base")

  # Top-N taken from each leg before fusion, and the RRF rank constant (the
  # standard k=60 dampens the contribution of low-ranked results).
  @hybrid_candidates 50
  @rrf_k 60

  @doc """
  Hybrid search over a content `type` (`:page` or `:post`): fuse the keyword
  (`:search`, ts_rank) and semantic (`:search_semantic`, cosine) result lists by
  Reciprocal Rank Fusion and return the merged records, best first.

  Degrades to keyword-only when semantic search is disabled — the semantic leg
  then returns nothing. Read options (`:actor`, `:authorize?`) pass through to
  both legs, so visibility is respected. `:limit` caps the result count
  (default 20); `:k` overrides the RRF constant.
  """
  @spec hybrid(:page | :post, String.t(), keyword()) :: [struct()]
  def hybrid(type, query, opts \\ []) when is_binary(query) do
    resource = resource_for(type)
    read_opts = Keyword.take(opts, [:actor, :authorize?])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 20)
    k = Keyword.get(opts, :k, @rrf_k)

    keyword = run_leg(resource, :search, query, locale, read_opts)
    semantic = run_leg(resource, :search_semantic, query, locale, read_opts)

    fused =
      [keyword, semantic]
      |> reciprocal_rank_fusion(k)
      |> Enum.take(limit)

    if Keyword.get(opts, :rerank, false) and rerank?() do
      rerank(query, fused)
    else
      fused
    end
  end

  # Rerank fused results by a stronger (query, doc) relevance model, falling back
  # to the fused order if the reranker errors.
  defp rerank(query, records) do
    case reranker().scores(query, Enum.map(records, &rerank_text/1)) do
      {:ok, scores} when length(scores) == length(records) ->
        records
        |> Enum.zip(scores)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.map(&elem(&1, 0))

      _ ->
        records
    end
  end

  # Text handed to the reranker — title plus excerpt when present.
  defp rerank_text(%{title: title} = record) do
    case Map.get(record, :excerpt) do
      excerpt when is_binary(excerpt) and excerpt != "" -> title <> " — " <> excerpt
      _ -> title
    end
  end

  @doc """
  Global keyword search across content types and media, returning sectioned
  results: `%{pages: [...], posts: [...], media: [...]}`. Pages/posts are
  locale-scoped (via `:locale`, default configured); media is locale-agnostic.
  Read options (`:actor`, `:authorize?`) pass through; `:limit` caps each
  section (default 10). Pass `highlight: true` to load the `highlight` snippet
  calc on the page/post sections (rendered by the admin palette via
  `KilnCMS.Search.Highlight.to_safe_html/1`); media has no such calc.
  """
  @spec global(String.t(), keyword()) :: %{
          pages: [struct()],
          posts: [struct()],
          media: [struct()]
        }
  def global(query, opts \\ []) when is_binary(query) do
    read_opts = Keyword.take(opts, [:actor, :authorize?])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 10)

    content_load =
      if Keyword.get(opts, :highlight, false),
        do: [highlight: %{query: query, locale: locale}],
        else: []

    %{
      pages:
        section(
          KilnCMS.CMS.Page,
          :search,
          %{query: query, locale: locale},
          read_opts,
          limit,
          content_load
        ),
      posts:
        section(
          KilnCMS.CMS.Post,
          :search,
          %{query: query, locale: locale},
          read_opts,
          limit,
          content_load
        ),
      media: section(KilnCMS.CMS.MediaItem, :search, %{query: query}, read_opts, limit, [])
    }
  end

  @doc """
  Record a user-initiated search for analytics (normalized, privacy-first):
  trimmed + downcased query, its locale, and how many results it returned.
  Fire-and-forget — failures are swallowed so analytics never breaks search, and
  blank queries are ignored.
  """
  @spec record_query(String.t(), non_neg_integer(), keyword()) :: :ok
  def record_query(query, result_count, opts \\ []) when is_binary(query) do
    normalized = query |> String.trim() |> String.downcase()

    if normalized != "" do
      locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()

      KilnCMS.Analytics.record_search(
        %{query: normalized, locale: locale, result_count: result_count},
        authorize?: false
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp section(resource, action, params, read_opts, limit, load) do
    resource
    |> Ash.Query.for_read(action, params)
    |> Ash.Query.load(load)
    |> Ash.Query.limit(limit)
    |> Ash.read!(read_opts)
  end

  defp resource_for(:page), do: KilnCMS.CMS.Page
  defp resource_for(:post), do: KilnCMS.CMS.Post

  # Run one search leg via `for_read` so both the query and locale arguments can
  # be passed (the code interfaces only take `query` positionally).
  defp run_leg(resource, action, query, locale, read_opts) do
    resource
    |> Ash.Query.for_read(action, %{query: query, locale: locale})
    |> Ash.read!(read_opts)
    |> Enum.take(@hybrid_candidates)
  end

  # RRF: each list contributes 1/(k + rank) to a record's score; records are
  # deduplicated by id and returned sorted by summed score, highest first.
  defp reciprocal_rank_fusion(lists, k) do
    lists
    |> Enum.flat_map(fn list ->
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {record, rank} -> {record, 1.0 / (k + rank)} end)
    end)
    |> Enum.reduce(%{}, fn {record, score}, acc ->
      Map.update(acc, record.id, {record, score}, fn {existing, total} ->
        {existing, total + score}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_record, score} -> score end, :desc)
    |> Enum.map(fn {record, _score} -> record end)
  end

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
