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

  @doc """
  Hidden-state pooling for the embedding serving. `:cls_token_pooling` (the
  default) suits the bge family; multilingual models like
  `paraphrase-multilingual-MiniLM-L12-v2` and the e5 family use
  `:mean_pooling`. Must match how the configured model was trained.
  """
  @spec pooling() :: atom()
  def pooling, do: cfg(:pooling, :cls_token_pooling)

  @doc """
  Compiled batch size of the embedding serving.

  `Nx.Serving` **pads a partial batch up to this size**, so a lone
  interactive query costs a full batch's compute. Throughput is largely
  unaffected by the choice (the per-token matmuls dominate, and they are
  already large at batch 1), so an install that embeds one query at a time —
  a semantic search box, a related-content section — wants this small even
  though a bulk backfill does not care. Default 8.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: cfg(:batch_size, 8)

  @doc """
  Compiled sequence length of the embedding serving. Inputs are padded (or
  truncated) to it, so cost is driven by this number and *not* by the real
  input length.

  A **list** compiles one computation per length and routes each input to the
  smallest one that fits it. That is usually what you want: queries are a
  handful of tokens while documents run to the full window, and a single
  fixed length has to serve both — so `[64, 128, 512]` keeps long documents
  at full fidelity while letting a short query skip the padding it does not
  need. The cost is compile time and memory per extra bucket.

  Default 512 (single length, the model's full window).
  """
  @spec sequence_length() :: pos_integer() | [pos_integer()]
  def sequence_length, do: cfg(:sequence_length, 512)

  @doc """
  Instruction prefixes some retrieval models expect, prepended before
  embedding. Asymmetric models (e.g. multilingual-e5) need `query: ` on the
  query and `passage: ` on the document; bge query instructions go here too.
  Both default to `""` (no prefix), preserving the bge-small default.
  """
  @spec query_prefix() :: String.t()
  def query_prefix, do: cfg(:query_prefix, "")

  @spec document_prefix() :: String.t()
  def document_prefix, do: cfg(:document_prefix, "")

  @doc """
  Embed a **search query** — applies `query_prefix/0` before the adapter. Use
  this for the query side of semantic search; `embed_document/1` for content.
  """
  @spec embed_query(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed_query(text) when is_binary(text), do: embed(query_prefix() <> text)

  @doc "Embed a **document** (content) — applies `document_prefix/0` before the adapter."
  @spec embed_document(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed_document(text) when is_binary(text), do: embed(document_prefix() <> text)

  @doc """
  Embed a single string into a list of floats via the active adapter (no
  instruction prefix). Prefer `embed_query/1` / `embed_document/1` on the
  search and indexing paths so instruction-tuned models work correctly.
  """
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

  # The typo-tolerance fallback: when the keyword leg finds fewer hits than
  # this, a trigram leg joins the fusion — at reduced weight, so fuzzy
  # near-misses never outrank real keyword/semantic matches.
  @fuzzy_fallback_threshold 3
  @fuzzy_weight 0.5

  # The facet arguments shared by `:search` and `:search_semantic`.
  @facet_filters [:category_id, :author_id, :state, :tag_ids]

  # Facet counts scan at most this many top keyword matches per content type —
  # counts are exact for anything smaller and become "counts over the best N"
  # beyond it, keeping the scan bounded on large sites.
  @facet_scan_cap 500

  @doc """
  Hybrid search over any content type: fuse the keyword (`:search`, ts_rank)
  and semantic (`:search_semantic`, cosine) result lists by Reciprocal Rank
  Fusion and return the merged records, best first.

  `type` is anything the content registry resolves — `:page`, `:post`, a
  generated type's atom, a dynamic type's name string (searched on the shared
  entry tier) — or a content resource module directly.

  Degrades to keyword-only when semantic search is disabled — the semantic leg
  then returns nothing. When the keyword leg finds almost nothing, a trigram
  fuzzy leg (the `:autocomplete` machinery — word similarity on titles) joins
  the fusion at reduced weight, so typos like "databse" still surface
  "Database Guide". Read options (`:actor`, `:authorize?`) pass through to
  every leg, so visibility is respected. `:limit` caps the result count
  (default 20); `:k` overrides the RRF constant; `:load` applies to all legs
  (e.g. the `highlight` snippet calc); `rerank: true` reorders the fused
  results with the configured reranker (still gated by `rerank?()`).

  `:filters` (a map of the search actions' facet arguments — `:category_id`,
  `:author_id`, `:state`, `:tag_ids`) narrows both legs; the fuzzy leg sits
  out under filters since `:autocomplete` can't apply them.

  `:query_vector` supplies an already-embedded query, skipping the embedding
  the semantic leg would otherwise do. Only worth passing when you are calling
  this repeatedly for one query — `global/2` does, across every content type —
  since embedding dominates the cost of a semantic search. Pass `:unavailable`
  to declare the query unembeddable and skip the semantic leg outright.
  """
  @spec hybrid(atom() | String.t() | module(), String.t(), keyword()) :: [struct()]
  def hybrid(type, query, opts \\ []) when is_binary(query) do
    resource = search_resource(type)
    # `:tenant` scopes the multitenant content legs to the request's org (#336).
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 20)
    k = Keyword.get(opts, :k, @rrf_k)
    load = Keyword.get(opts, :load, [])
    filters = opts |> Keyword.get(:filters, %{}) |> Map.take(@facet_filters)

    args = Map.merge(%{query: query, locale: locale}, filters)

    # The legs fetch bare records. Fusion needs only ids and order, and
    # reranking reads title/excerpt, which are attributes — so loading calcs
    # here would compute them for up to `@hybrid_candidates` rows *per leg*
    # to keep `limit` of them. `highlight` is a `ts_headline` over the whole
    # document, so that is most of the query's cost thrown away.
    keyword = run_leg(resource, :search, args, read_opts)
    semantic = run_leg(resource, :search_semantic, args, read_opts, semantic_context(opts))

    fuzzy =
      if filters == %{} and length(keyword) < @fuzzy_fallback_threshold do
        run_leg(resource, :autocomplete, %{prefix: query, locale: locale}, read_opts)
      else
        []
      end

    [{keyword, 1.0}, {semantic, 1.0}, {fuzzy, @fuzzy_weight}]
    |> reciprocal_rank_fusion(k)
    |> Enum.take(limit)
    |> maybe_rerank(query, opts)
    |> load_results(load, read_opts)
  end

  defp maybe_rerank(records, query, opts) do
    if Keyword.get(opts, :rerank, false) and rerank?() do
      rerank(query, records)
    else
      records
    end
  end

  # Calculations are loaded once fusion has settled on the records actually
  # being returned — see the note in `hybrid/3`.
  defp load_results([], _load, _read_opts), do: []
  defp load_results(records, [], _read_opts), do: records
  defp load_results(records, load, read_opts), do: Ash.load!(records, load, read_opts)

  # The one embedding a global sweep pays. `:unavailable` (disabled, or the
  # embedder failed) tells each section's prepare to skip its semantic leg
  # rather than retry the same failing call once per type.
  defp global_query_vector(query) do
    with true <- semantic?(),
         {:ok, vector} <- embed_query(query) do
      vector
    else
      _ -> :unavailable
    end
  end

  # Pass a caller-supplied query vector (see `:query_vector` in `hybrid/3`)
  # down to the semantic leg's prepare. Absent, the prepare embeds for itself.
  defp semantic_context(opts) do
    case Keyword.fetch(opts, :query_vector) do
      {:ok, vector} -> %{query_vector: vector}
      :error -> %{}
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

  # Every content resource cross-content search sweeps: the compiled types
  # from the registry (core and project domains alike — never a hardcoded
  # module list) plus Entry, the shared tier backing dynamic types, which
  # deliberately isn't in `ContentTypes.all/0`.
  defp content_search_resources do
    Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.resource) ++ [KilnCMS.CMS.Entry]
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
  Global **hybrid** search across content types, media, and taxonomy,
  returning sectioned results:
  `%{pages: [...], posts: [...], entries: [...], media: [...], categories: [...], tags: [...]}`.

  Every content section fuses the keyword and semantic legs (RRF via
  `hybrid/3`), so meaning-based matches surface everywhere search is offered —
  the public `/search` page, the editor palette, the search API — and degrade
  to keyword-only when semantic search is disabled. With reranking enabled
  (`rerank?()`), each section's fused results are reordered by the reranker.

  Content sections are locale-scoped (via `:locale`, default configured);
  media and taxonomy are keyword/trigram-only and locale-agnostic (no
  embeddings). **One section per compiled content type**, keyed by the type's
  plural (`:pages`, `:posts`, …) — discovered from `ContentTypes.all/0`, so a
  type a plugin/project registers on `:content_domains` joins global search
  with no core edit (its table must carry the shared `search_vector`
  column + trigger, or its keyword leg raises — see #295). `entries` spans
  every admin-defined dynamic type
  (D17), each record carrying the `type_name` calc for labeling/linking. Read
  options (`:actor`, `:authorize?`) pass through; `:limit` caps each section
  (default 10). Pass `highlight: true` to load the `highlight` snippet calc on
  the content sections (rendered escape-safely via
  `KilnCMS.Search.Highlight.to_safe_html/1`). `:filters` (see `hybrid/3`)
  narrows the content sections — media and taxonomy don't carry facets.
  """
  @spec global(String.t(), keyword()) :: %{
          required(:entries) => [struct()],
          required(:media) => [struct()],
          required(:categories) => [struct()],
          required(:tags) => [struct()],
          optional(atom()) => [struct()]
        }
  def global(query, opts \\ []) when is_binary(query) do
    # `:tenant` scopes the multitenant content legs to the request's org (#336).
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 10)

    content_load =
      if Keyword.get(opts, :highlight, false),
        do: [highlight: %{query: query, locale: locale}],
        else: []

    hybrid_opts =
      read_opts ++
        [
          locale: locale,
          limit: limit,
          rerank: true,
          filters: Keyword.get(opts, :filters, %{}),
          # Embed the query ONCE for the whole sweep. Every section below runs
          # a semantic leg, and each would otherwise embed this same string
          # itself — one identical embedding per registered content type, the
          # dominant cost of a global search by a wide margin.
          query_vector: global_query_vector(query)
        ]

    # Section key per compiled type — `ct.section` is the plural atom minted
    # at compile time by the `Content` macro. A plural colliding with a
    # reserved section below would be overwritten by the merge — same family
    # of collisions `ContentTypes.path_segment/2` guards public URLs against.
    compiled =
      Map.new(KilnCMS.CMS.ContentTypes.all(), fn ct ->
        {ct.section, hybrid(ct.resource, query, [load: content_load] ++ hybrid_opts)}
      end)

    Map.merge(compiled, %{
      # One section across every dynamic type. `type_name` (an expression
      # calc, so it doesn't run TypeDefinition's editor-only read policy for
      # anonymous callers) labels each hit with its dynamic type.
      entries:
        hybrid(
          KilnCMS.CMS.Entry,
          query,
          [load: [:type_name | content_load]] ++ hybrid_opts
        ),
      # NOTE (#336): MediaItem/Category/Tag are NOT org-scoped yet, so these three
      # sections stay cross-org (they ignore the `:tenant` in `read_opts`). Content
      # + entries above ARE scoped. Closes when those resources gain `org_id`.
      media: section(KilnCMS.CMS.MediaItem, :search, %{query: query}, read_opts, limit, []),
      # Taxonomy (name/description, typo-tolerant) — matched categories and
      # tags so editors and headless frontends can jump to filtered listings.
      categories: section(KilnCMS.CMS.Category, :search, %{query: query}, read_opts, limit, []),
      tags: section(KilnCMS.CMS.Tag, :search, %{query: query}, read_opts, limit, [])
    })
  end

  @doc """
  Facet counts for a query — how many matching documents carry each category
  and each tag, for "Category (12)"-style filter UIs:

      %{categories: [%{id: ..., name: ..., slug: ..., count: 12}, ...],
        tags:       [%{id: ..., name: ..., slug: ..., count: 7}, ...]}

  Sorted by count (name breaks ties). Computed over the policy-respecting
  keyword match set (top #{@facet_scan_cap} matches per content type), so
  anonymous callers only ever count published documents. Locale-scoped like
  the search itself. Counts are for the *unfiltered* query — apply a facet
  and the counts still show the full distribution to switch between.
  """
  @spec facets(String.t(), keyword()) :: %{categories: [map()], tags: [map()]}
  def facets(query, opts \\ []) when is_binary(query) do
    # `:tenant` scopes the multitenant content legs to the request's org (#336).
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()

    matches =
      content_search_resources()
      |> Enum.flat_map(fn resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.limit(@facet_scan_cap)
        |> Ash.Query.for_read(:search, %{query: query, locale: locale})
        |> Ash.Query.select([:id, :category_id])
        |> Ash.Query.load(tags: [:id, :name, :slug])
        |> Ash.read!(read_opts)
      end)

    %{categories: category_facets(matches, read_opts), tags: tag_facets(matches)}
  end

  # Count matches per category id, then resolve names/slugs in one read
  # (taxonomy is world-readable, but go through the policy anyway).
  defp category_facets(matches, read_opts) do
    counts =
      matches |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    case Map.keys(counts) do
      [] ->
        []

      ids ->
        KilnCMS.CMS.Category
        |> Ash.Query.filter_input(id: [in: ids])
        |> Ash.read!(read_opts)
        |> Enum.map(&%{id: &1.id, name: &1.name, slug: &1.slug, count: counts[&1.id]})
        |> sort_facets()
    end
  end

  # Tags come pre-loaded on the matches, so counting needs no extra read.
  defp tag_facets(matches) do
    matches
    |> Enum.flat_map(& &1.tags)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, [tag | _] = hits} ->
      %{id: id, name: tag.name, slug: tag.slug, count: length(hits)}
    end)
    |> sort_facets()
  end

  defp sort_facets(facets), do: Enum.sort_by(facets, &{-&1.count, &1.name})

  @doc """
  A "did you mean" suggestion for a query that looks like a typo: the most
  word-similar published title across content types (backed by the same
  trigram machinery as autocomplete), or `nil` when nothing comes close — or
  when a title word matches the query *exactly*, because then the query isn't
  a typo and there's nothing to correct. Callers show it when a search comes
  back sparse (the fuzzy hybrid leg may still have rescued some hits — the
  suggestion then names the corrected term, "showing results for…"-style).
  Read options pass through, so anonymous callers only ever see published
  titles.
  """
  @spec suggest(String.t(), keyword()) :: String.t() | nil
  def suggest(query, opts \\ []) when is_binary(query) do
    # `:tenant` scopes the multitenant content legs to the request's org (#336).
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    down = String.downcase(query)

    content_search_resources()
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.Query.for_read(:autocomplete, %{prefix: query, locale: locale})
      |> Ash.read!(read_opts)
    end)
    |> Enum.map(&{&1.title, best_word_similarity(down, &1.title)})
    |> Enum.filter(fn {title, score} ->
      score >= 0.83 and score < 1.0 and String.downcase(title) != down
    end)
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

      # The recorded query lands in the request's site (epic #336). Strict-
      # tenancy prep (#419): a caller that omits `:tenant` records against the
      # default org explicitly rather than relying on a nil-tenant global write.
      KilnCMS.Analytics.record_search(
        %{query: normalized, locale: locale, result_count: result_count},
        authorize?: false,
        tenant: Keyword.get(opts, :tenant) || KilnCMS.Accounts.default_org_id()
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

  # Run one search leg via `for_read` so all the action's arguments can be
  # passed (the code interfaces only take `query` positionally).
  # The limit is set before `for_read` so the action's prepare sees it (and the
  # semantic action's disabled branch can still zero it out) — the DB then does
  # the truncation the old post-read `Enum.take/2` did after loading every row.
  # `context` is set before `for_read` so the action's prepares can see it —
  # that is how a precomputed query vector reaches `Content.semantic_sort/1`.
  defp run_leg(resource, action, args, read_opts, context \\ %{}) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.limit(@hybrid_candidates)
    |> Ash.Query.set_context(context)
    |> Ash.Query.for_read(action, args)
    |> Ash.read!(read_opts)
  end

  # Weighted RRF: each `{list, weight}` contributes `weight / (k + rank)` to a
  # record's score; records are deduplicated by id and returned sorted by
  # summed score, highest first.
  defp reciprocal_rank_fusion(weighted_lists, k) do
    weighted_lists
    |> Enum.flat_map(fn {list, weight} ->
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {record, rank} -> {record, weight / (k + rank)} end)
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
