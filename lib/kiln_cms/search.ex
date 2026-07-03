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

  @doc """
  Nx `defn_options` for the local Bumblebee servings. Uses the EXLA compiler when
  the `:exla` dependency is compiled in (dev/test); otherwise returns `[]` so the
  servings fall back to Nx's default backend instead of crashing on a missing
  `EXLA` module. EXLA is required for acceptable embedding/rerank performance —
  restore it in prod (off-box image build) before enabling semantic search.
  """
  @spec defn_options() :: keyword()
  def defn_options do
    if Code.ensure_loaded?(EXLA), do: [compiler: EXLA], else: []
  end

  # Top-N taken from each leg before fusion, and the RRF rank constant (the
  # standard k=60 dampens the contribution of low-ranked results).
  @hybrid_candidates 50
  @rrf_k 60

  @doc """
  Hybrid search over any content type: fuse the keyword (`:search`, ts_rank)
  and semantic (`:search_semantic`, cosine) result lists by Reciprocal Rank
  Fusion and return the merged records, best first.

  `type` is anything the content registry resolves — `:page`, `:post`, a
  generated type's atom, a dynamic type's name string (searched on the shared
  entry tier) — or a content resource module directly.

  Degrades to keyword-only when semantic search is disabled — the semantic leg
  then returns nothing. Read options (`:actor`, `:authorize?`) pass through to
  both legs, so visibility is respected. `:limit` caps the result count
  (default 20); `:k` overrides the RRF constant; `:load` applies to both legs
  (e.g. the `highlight` snippet calc); `rerank: true` reorders the fused
  results with the configured reranker (still gated by `rerank?()`).
  """
  @spec hybrid(atom() | String.t() | module(), String.t(), keyword()) :: [struct()]
  def hybrid(type, query, opts \\ []) when is_binary(query) do
    resource = search_resource(type)
    read_opts = Keyword.take(opts, [:actor, :authorize?])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 20)
    k = Keyword.get(opts, :k, @rrf_k)
    load = Keyword.get(opts, :load, [])

    keyword = run_leg(resource, :search, query, locale, read_opts, load)
    semantic = run_leg(resource, :search_semantic, query, locale, read_opts, load)

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

  # Resolve what to search: a registered content type (compiled → its
  # resource; dynamic → the shared entry tier) or a resource module as-is.
  defp search_resource(resource) when resource in [KilnCMS.CMS.Entry], do: resource

  defp search_resource(type) do
    case KilnCMS.CMS.ContentTypes.get(type) do
      %{source: :dynamic} -> KilnCMS.CMS.Entry
      %{resource: resource} when not is_nil(resource) -> resource
      nil when is_atom(type) -> type
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
  Global **hybrid** search across content types and media, returning sectioned
  results: `%{pages: [...], posts: [...], entries: [...], media: [...]}`.

  Every content section fuses the keyword and semantic legs (RRF via
  `hybrid/3`), so meaning-based matches surface everywhere search is offered —
  the public `/search` page, the editor palette, the search API — and degrade
  to keyword-only when semantic search is disabled. With reranking enabled
  (`rerank?()`), each section's fused results are reordered by the reranker.

  Content sections are locale-scoped (via `:locale`, default configured);
  media is keyword-only and locale-agnostic (no embeddings). `entries` spans
  every admin-defined dynamic type (D17), each record carrying the `type_name`
  calc for labeling/linking. Read options (`:actor`, `:authorize?`) pass
  through; `:limit` caps each section (default 10). Pass `highlight: true` to
  load the `highlight` snippet calc on the content sections (rendered
  escape-safely via `KilnCMS.Search.Highlight.to_safe_html/1`).
  """
  @spec global(String.t(), keyword()) :: %{
          pages: [struct()],
          posts: [struct()],
          entries: [struct()],
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

    hybrid_opts =
      read_opts ++ [locale: locale, limit: limit, rerank: true]

    %{
      pages: hybrid(KilnCMS.CMS.Page, query, [load: content_load] ++ hybrid_opts),
      posts: hybrid(KilnCMS.CMS.Post, query, [load: content_load] ++ hybrid_opts),
      # One section across every dynamic type. `type_name` (an expression
      # calc, so it doesn't run TypeDefinition's editor-only read policy for
      # anonymous callers) labels each hit with its dynamic type.
      entries:
        hybrid(
          KilnCMS.CMS.Entry,
          query,
          [load: [:type_name | content_load]] ++ hybrid_opts
        ),
      media: section(KilnCMS.CMS.MediaItem, :search, %{query: query}, read_opts, limit, [])
    }
  end

  @doc """
  A "did you mean" suggestion for a query that found nothing: the most
  word-similar published title across content types (backed by the same
  trigram machinery as autocomplete), or `nil` when nothing comes close or the
  best match is just the query itself. Read options pass through, so anonymous
  callers only ever see published titles.
  """
  @spec suggest(String.t(), keyword()) :: String.t() | nil
  def suggest(query, opts \\ []) when is_binary(query) do
    read_opts = Keyword.take(opts, [:actor, :authorize?])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    down = String.downcase(query)

    [KilnCMS.CMS.Page, KilnCMS.CMS.Post, KilnCMS.CMS.Entry]
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.Query.for_read(:autocomplete, %{prefix: query, locale: locale})
      |> Ash.read!(read_opts)
    end)
    |> Enum.map(&{&1.title, best_word_similarity(down, &1.title)})
    |> Enum.filter(fn {title, score} -> score >= 0.83 and String.downcase(title) != down end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      {title, _score} -> title
      nil -> nil
    end
  end

  # The query's closeness to its best-matching word in a title ("databse" vs
  # "The Database Guide" → jaro("databse", "database")).
  defp best_word_similarity(down_query, title) do
    title
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.map(&String.jaro_distance(down_query, &1))
    |> Enum.max(fn -> 0.0 end)
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

  # Run one search leg via `for_read` so both the query and locale arguments can
  # be passed (the code interfaces only take `query` positionally).
  # The limit is set before `for_read` so the action's prepare sees it (and the
  # semantic action's disabled branch can still zero it out) — the DB then does
  # the truncation the old post-read `Enum.take/2` did after loading every row.
  defp run_leg(resource, action, query, locale, read_opts, load) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.limit(@hybrid_candidates)
    |> Ash.Query.for_read(action, %{query: query, locale: locale})
    |> Ash.Query.load(load)
    |> Ash.read!(read_opts)
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
