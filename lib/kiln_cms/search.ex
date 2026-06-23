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

    [keyword, semantic]
    |> reciprocal_rank_fusion(k)
    |> Enum.take(limit)
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
