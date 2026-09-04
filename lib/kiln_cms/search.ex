defmodule KilnCMS.Search do
  @moduledoc """
  Semantic / hybrid search facade and config access.

  All knobs live under `config :kiln_cms, KilnCMS.Search` (see
  `docs/semantic-search-plan.md`). With `semantic: false` (the default) the
  embedding model never loads and content writes skip embedding work, so the
  default install pays nothing.
  """
  require Logger

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
  How many of `global/2`'s sections may run concurrently.

  Sections are independent, so they fan out rather than running one round trip
  after another. The bound matters because each one holds a DB connection for
  the duration of its queries — unbounded fan-out would drain the Ecto pool
  (`POOL_SIZE`, default 10) and starve everything else on the node. The
  default deliberately leaves most of the pool free for concurrent traffic;
  raise it if your pool is sized for it, and remember a *second* simultaneous
  search wants the same headroom. Default 4.
  """
  @spec section_concurrency() :: pos_integer()
  def section_concurrency, do: cfg(:section_concurrency, 4)

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
  Maximum cosine distance a semantic hit may have and still count as a match,
  or `nil` (the default) for no floor.

  Nearest-neighbour search always returns neighbours. Without a floor the
  semantic leg answers *every* query with its full candidate set, however
  unrelated — a search for gibberish comes back as confident-looking as a real
  one, and because `hybrid/3` fuses that leg in, "no results" becomes
  unreachable. The floor is what lets a semantic search legitimately return
  nothing.

  pgvector's `<=>` yields cosine distance in `[0, 2]`: `0` identical, `1`
  orthogonal (no relationship), `2` opposed. The useful cutoff is **model
  specific** — instruction-tuned embedders like bge sit in a narrow, high
  baseline band, so a value that filters well for one model can silently
  discard everything under another. That is why this defaults to `nil` rather
  than a guess: measure your own corpus with `semantic_distances/3`, then set
  the value just above where the genuinely related results stop.

      config :kiln_cms, KilnCMS.Search, semantic_max_distance: 0.55

  Rows with no embedding are excluded once a floor is set (`NULL <=> v` is
  `NULL`); unset, they merely sort last.
  """
  @spec semantic_max_distance() :: float() | nil
  def semantic_max_distance, do: cfg(:semantic_max_distance, nil)

  @doc """
  Cosine-distance ceiling on a tag suggestion — see
  `KilnCMS.Search.Related.suggest_tags/2`.

  Unlike `semantic_max_distance/0` this ships a real number rather than `nil`,
  because "no ceiling" is not a neutral choice here: the candidate set is the
  site's whole tag list, so on a site with five tags every tag is always
  suggested, however unrelated (#851). A wrong suggestion in a ranked list of
  search results costs a scroll; a wrong suggestion in a five-item panel that
  says "consider these" costs the panel its credibility.

  The number is model-specific, which is why it is a knob rather than a
  literal. `0.35` is **measured** against the default `BAAI/bge-small-en-v1.5`
  (#1086) over `KilnCMS.TagSuggestionCorpus` — eight documents, thirty-five
  tags, human labels for which of them a person would actually tick:

  | | cosine distance |
  |---|---|
  | tags a human would tick | 0.2119 – 0.4292 |
  | tags they would not | 0.2828 – 0.5626 |

  The bands **overlap**, and that is the result. No ceiling keeps every wanted
  tag and admits no unwanted one, so this is a choice about which error to make.
  0.35 keeps 21 of 27 wanted and admits 10 of 253 unwanted — about four
  suggestions per document, under `suggest_tags/2`'s `limit: 5`, so the ceiling
  rather than the limit is what decides what an editor sees.

  > #### What this replaced, and why it was wrong {: .warning}
  >
  > The first number came from the model's published behaviour on **sentence
  > pairs** — unrelated around 0.6-0.8 similarity, i.e. 0.2-0.4 distance — and
  > #1086 warned that band might not transfer to a one- or two-word tag label
  > against a whole-document centroid.
  >
  > It does not. Measured, an unrelated tag sits at 0.35 and up, and a wanted
  > one can sit at 0.43. Reasoning from the sentence-pair band produced `0.25`,
  > which keeps **3 of 27** wanted tags: the panel is empty for most documents,
  > which reads to an editor exactly like a broken feature.

  Measure your own with
  `KilnCMS.Search.Related.suggest_tags(record, threshold: 2.0)` — the ceiling of
  cosine distance, so nothing is filtered — which restores the pre-#851
  behaviour, and read the distances off the result. For a whole corpus at once,
  `test/kiln_cms/search/tag_suggestion_calibration_test.exs` carries the harness
  behind `--include calibration`.
  """
  @spec suggest_tags_threshold() :: float()
  def suggest_tags_threshold, do: cfg(:suggest_tags_threshold, 0.35)

  @doc """
  Cosine-distance ceiling on a near-duplicate — see
  `KilnCMS.Search.Related.near_duplicates/2`.

  Measured on the same corpus as `suggest_tags_threshold/0` (#1086), on the axis
  this one actually compares — document centroid against document centroid,
  which behaves nothing like a tag label against a centroid:

  | | cosine distance |
  |---|---|
  | the same document | 0.0000 |
  | a reworded copy of it | 0.0376 |
  | another document on the same subject | 0.1938 – 0.2097 |
  | an unrelated document | 0.3690 |

  `0.1` sits in the gap with room on both sides, which is what this feature
  needs it to do: "this is the same article rewritten" is a duplicate an editor
  wants flagged, "this is another article about sourdough" is not.

  A knob rather than the literal it used to be, for the reason its sibling is
  one: the number is a property of the model, and an operator who changes the
  model had no way to change this.
  """
  @spec near_duplicate_threshold() :: float()
  def near_duplicate_threshold, do: cfg(:near_duplicate_threshold, 0.1)

  @doc """
  Rate-limit budget for computing an embedding on demand — see
  `KilnCMS.LLM.Budget` and `KilnCMS.Search.Related`'s `centroid/2` fallback,
  which costs one model inference **per block** for a document that has no
  stored vector (#852), plus `suggest_tags/2`'s one inference per taxonomy tag
  not already in `KilnCMS.Search.VectorCache` (#1076).

  Sized well above `KilnCMS.Seo.draft/2`'s default per-user scale (20 calls a
  minute): a single local embedding is far cheaper than an LLM completion,
  and `suggest_tags/2` alone can spend one unit per untagged tag in the
  site's taxonomy in a single call.
  Like the SEO budget, this counts **calls that actually reach the model** —
  `VectorCache` hits are free and are not charged — not the token/compute
  volume behind each one.
  """
  @spec embedding_per_user_limit() :: {pos_integer(), pos_integer()}
  def embedding_per_user_limit, do: cfg(:embedding_per_user_limit, {60, :timer.minutes(1)})

  @doc "The org-wide half of `embedding_per_user_limit/0` — see there."
  @spec embedding_per_org_limit() :: {pos_integer(), pos_integer()}
  def embedding_per_org_limit, do: cfg(:embedding_per_org_limit, {600, :timer.hours(1)})

  @doc """
  The share of `embedding_per_org_limit/0` an unattended caller — the
  `flag_duplicates` / `suggest_tags` automation reactions — may spend before
  they stop, reserving the remainder for an editor's own panel. Mirrors
  `KilnCMS.Seo.unattended_share/0`, the #943 precedent this follows: see
  `KilnCMS.LLM.Budget` for the mechanism. `0.0` keeps these reactions off this
  budget entirely; `1.0` lets them spend the whole org allowance.
  """
  @spec embedding_unattended_share() :: float()
  def embedding_unattended_share, do: cfg(:embedding_unattended_share, 0.5)

  @doc """
  `KilnCMS.LLM.Budget` limits for the `"search_embedding"` feature, shared by
  every caller that computes an embedding on demand
  (`KilnCMS.Search.Related`, `KilnCMS.Search.BlockSearch`) — one assembly
  point so the two buckets and the unattended reserve share stay in sync
  across callers (#1076).

  `units` is the number of inferences the call will actually perform if the
  check passes — 1 for a single query or tag embedding, or an uncached
  block/tag count for a batch — so the budget is charged for real inference
  volume, not once per call regardless of how much work the call does.
  """
  @spec embedding_budget_limits(boolean(), pos_integer()) :: keyword()
  def embedding_budget_limits(unattended?, units \\ 1) do
    [
      per_user: embedding_per_user_limit(),
      per_org: embedding_per_org_limit(),
      unattended?: unattended?,
      unattended_share: embedding_unattended_share(),
      units: units
    ]
  end

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

  # Ceiling on a single `global/2` section. Generous — it exists to stop one
  # wedged query hanging the request forever, not to bound normal latency, and
  # a timeout takes the whole call down rather than silently dropping a
  # section.
  @section_timeout :timer.seconds(30)

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

  Every record comes back carrying the score it was ranked by and the legs
  that returned it — read them with `hit_score/1` and `hit_legs/1`. The list
  itself is plain records, so nothing that reads one changes.
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
    keyword =
      without_search_vector(resource, fn -> run_leg(resource, :search, args, read_opts) end)

    semantic = run_leg(resource, :search_semantic, args, read_opts, semantic_context(opts))

    fuzzy =
      if filters == %{} and length(keyword) < @fuzzy_fallback_threshold do
        run_leg(resource, :autocomplete, %{prefix: query, locale: locale}, read_opts)
      else
        []
      end

    [{:keyword, keyword, 1.0}, {:semantic, semantic, 1.0}, {:fuzzy, fuzzy, @fuzzy_weight}]
    |> reciprocal_rank_fusion(k)
    |> Enum.take(limit)
    |> maybe_rerank(query, opts)
    |> load_results(load, read_opts)
    |> Enum.map(&attach_hit/1)
  end

  @doc """
  The relevance score `hybrid/3` ranked this record by, or `nil` for a record
  that did not come out of `hybrid/3` (a taxonomy or media hit, a plain read).

  It is the record's fused RRF score — `weight / (k + rank)` summed over every
  leg that returned it — or, when the fused list was reranked, the reranker's
  score, so that the number always agrees with the order it came in. The
  fused scores are **comparable across content types**: every `hybrid/3` call
  in a `global/2` sweep shares `k` and the leg weights, so a page scored
  `0.031` and a post scored `0.016` can be sorted against each other, which is
  how `KilnCMS.Ask` picks its sources. They used to be computed and thrown
  away inside fusion, which left the sections' callers nothing to interleave
  on but the order of the registry — so `/api/ask` cited every "Concept"
  before any "Herb", however weak the concept match.
  """
  @spec hit_score(struct()) :: float() | nil
  def hit_score(%{__metadata__: %{search: %{score: score}}}), do: score
  def hit_score(_record), do: nil

  @doc """
  Which legs of `hybrid/3` returned this record — a subset of
  `[:keyword, :semantic, :fuzzy]`, in that order — or `[]` for a record that
  did not come out of `hybrid/3`.

  Provenance, for two readers: a client deciding how much to trust a hit (a
  keyword-and-semantic hit is a stronger claim than a fuzzy-only one), and
  anyone debugging why a result ranked where it did.
  """
  @spec hit_legs(struct()) :: [leg()]
  def hit_legs(%{__metadata__: %{search: %{legs: legs}}}), do: legs
  def hit_legs(_record), do: []

  @typedoc "A leg of `hybrid/3` — see `hit_legs/1`."
  @type leg :: :keyword | :semantic | :fuzzy

  # A fused hit on its way out of `hybrid/3`: the record, the score it is
  # ordered by, and the legs that returned it.
  @typep hit :: {struct(), float(), [leg()]}

  # The score and legs ride on the record's metadata rather than in a tuple,
  # so `hybrid/3` and `global/2` keep returning plain record lists — every
  # existing caller reads them as such — and a caller that wants the number
  # asks `hit_score/1`.
  @spec attach_hit(hit()) :: struct()
  defp attach_hit({record, score, legs}) do
    Ash.Resource.put_metadata(record, :search, %{score: score, legs: legs})
  end

  @spec maybe_rerank([hit()], String.t(), keyword()) :: [hit()]
  defp maybe_rerank(hits, query, opts) do
    if Keyword.get(opts, :rerank, false) and rerank?() do
      rerank(query, hits)
    else
      hits
    end
  end

  # Calculations are loaded once fusion has settled on the records actually
  # being returned — see the note in `hybrid/3`. Loaded by id rather than
  # trusting `Ash.load!` to hand the list back in order, and re-paired with
  # the hit's score and legs, which a load does not carry.
  @spec load_results([hit()], list(), keyword()) :: [hit()]
  defp load_results([], _load, _read_opts), do: []
  defp load_results(hits, [], _read_opts), do: hits

  defp load_results(hits, load, read_opts) do
    loaded =
      hits
      |> Enum.map(fn {record, _score, _legs} -> record end)
      |> Ash.load!(load, read_opts)
      |> Map.new(&{&1.id, &1})

    Enum.map(hits, fn {record, score, legs} ->
      {Map.get(loaded, record.id, record), score, legs}
    end)
  end

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

  @doc """
  The nearest rows of `type` to `query` with their raw cosine distances —
  the measurement behind `semantic_max_distance/0`.

      iex> KilnCMS.Search.semantic_distances(:page, "reishi mushroom")
      {:ok, [{"Ling Zhi", 0.31}, {"Medicinal Mushrooms", 0.42}, {"Sitemap", 0.83}]}

  Run it for a query that *should* match and one that should not: the cutoff
  goes between the two, and if they overlap your corpus isn't separable by
  distance alone and wants reranking instead. Deliberately ignores any
  configured floor — you cannot tune a threshold that has already been applied.

  Options: `:limit` (default 20), plus `:actor` / `:authorize?` / `:tenant`.
  """
  @spec semantic_distances(module() | atom(), String.t(), keyword()) ::
          {:ok, [{String.t(), float()}]} | {:error, term()}
  def semantic_distances(type, query, opts \\ []) when is_binary(query) do
    resource = search_resource(type)
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])

    with {:ok, vector} <- embed_query(query) do
      resource
      |> Ash.Query.new()
      |> Ash.Query.load(semantic_distance: %{query_vector: vector})
      |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
      |> Ash.Query.limit(Keyword.get(opts, :limit, 20))
      |> Ash.read(read_opts)
      |> case do
        {:ok, rows} -> {:ok, Enum.map(rows, &{&1.title, &1.semantic_distance})}
        error -> error
      end
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

  @doc """
  Every content resource a cross-content search sweeps: the compiled types from
  the registry (core and project domains alike — never a hardcoded module list)
  plus `Entry`, the shared tier backing dynamic types, which deliberately isn't
  in `ContentTypes.all/0`.

  Public because it is also the set `KilnCMS.Search.SchemaCheck` holds the
  database to: a resource in here whose table has no `search_vector` column is
  a resource whose keyword leg cannot run.
  """
  @spec content_resources() :: [module()]
  def content_resources do
    Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.resource) ++ [KilnCMS.CMS.Entry]
  end

  # Run a keyword leg, containing the one failure that is a *deployment* fact
  # rather than a fault in the query.
  #
  # `search_vector` is trigger-maintained in the database, not an Ash attribute
  # (`KilnCMS.Migrations.add_search_vector/1`), so a content type whose table
  # never got its own migration has no such column and the leg raises
  # `undefined_column` — for every query, on every surface. `global/2` sweeps
  # every registered type, so ONE half-migrated type used to take the entire
  # site search down with it: the other types' hits, the media and taxonomy
  # sections, the facets, all of it (#295).
  #
  # Contained, that type still answers from its semantic and fuzzy legs and
  # every other section is untouched. The failure stays loud where loudness
  # buys something — an error in the log per query, and `mix kiln.search.check`
  # failing the build *before* the deploy — instead of only where it costs
  # visitors. Every other error still raises: an empty result set must never be
  # how a caller learns their query was broken.
  defp without_search_vector(resource, fun) do
    fun.()
  rescue
    error ->
      if missing_search_vector?(error) do
        Logger.error("""
        Search: #{inspect(resource)} has no `search_vector` column, so its keyword \
        leg cannot run and this query answered without it. Add the migration:

            defmodule KilnCMS.Repo.Migrations.AddSearchVector do
              use Ecto.Migration
              import KilnCMS.Migrations

              def up, do: add_search_vector("#{table_name(resource)}")
              def down, do: drop_search_vector("#{table_name(resource)}")
            end

        `mix kiln.search.check` reports every table in this state.\
        """)

        []
      else
        reraise error, __STACKTRACE__
      end
  end

  defp table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource) || "<table>"
  rescue
    _ -> "<table>"
  end

  # Ash wraps the Postgrex error, and how deeply depends on the action, so this
  # reads the rendered message rather than pattern-matching a nesting that
  # varies. Both markers are required: the column is only *this* problem when
  # the database says it does not exist.
  defp missing_search_vector?(error) do
    message = Exception.message(error)

    message =~ "search_vector" and
      (message =~ "undefined_column" or message =~ "does not exist")
  rescue
    _ -> false
  end

  # Rerank fused results by a stronger (query, doc) relevance model, falling back
  # to the fused order if the reranker errors. A reranked hit carries the
  # reranker's score in place of its fused one: the score's contract
  # (`hit_score/1`) is "the number this order came from", and a caller
  # sorting reranked sections against each other by their RRF scores would
  # quietly undo the reranking.
  @spec rerank(String.t(), [hit()]) :: [hit()]
  defp rerank(query, hits) do
    docs = Enum.map(hits, fn {record, _score, _legs} -> rerank_text(record) end)

    case reranker().scores(query, docs) do
      {:ok, scores} when length(scores) == length(hits) ->
        hits
        |> Enum.zip(scores)
        |> Enum.map(fn {{record, _fused, legs}, score} -> {record, score, legs} end)
        |> Enum.sort_by(fn {_record, score, _legs} -> score end, :desc)

      _ ->
        hits
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
  `%{pages: [...], posts: [...], entries: [...], media: [...], categories: [...],
  tags: [...], tag_groups: [...]}`.

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
  `KilnCMS.Search.Highlight.to_safe_html/1`), and/or `passage: true` to load
  the `passage` calc — the longer, mark-free excerpt a reader answers *from*
  rather than clicks on, which is what `KilnCMS.Ask` cites. `:filters` (see
  `hybrid/3`) narrows the content sections — media and taxonomy don't carry
  facets.

  Every content hit carries its fused score and legs (`hit_score/1`,
  `hit_legs/1`), and the scores are comparable across sections — one `k` and
  one set of leg weights for the whole sweep — so a caller that wants the
  strongest hits *overall* can sort the sections' records together.

  The taxonomy sections come from `KilnCMS.CMS.Taxonomy.searchable/0` — one per
  taxonomy resource, so adding one joins global search with no edit here. They
  were a literal two-element list, which is how `tag_groups` came to be absent
  from every search surface without anything failing (#530); `searchable/0` is
  the contract, and callers that enumerate sections should read it rather than
  restate the keys.

  ## `:sections`

  By default every section runs. Pass `sections: [...]` to run only the ones
  the caller will actually read — each section is a full `Ash.read!` holding a
  DB connection, and three callers were paying for `media`, `categories`,
  `tags` and `tag_groups` on every call and discarding them (#960).

      Search.global(query, sections: Search.content_sections())

  `content_sections/0` is derived, so prefer it to a literal list: it keeps
  meaning "the content sections" when a type is registered. **Sections not
  asked for are absent from the result**, not empty — "you did not ask" and
  "there were no matches" are different answers, and a `KeyError` is the right
  way to learn you asked for the wrong thing. An unrecognised key raises.
  """
  @spec global(String.t(), keyword()) :: %{optional(atom()) => [struct()]}
  def global(query, opts \\ []) when is_binary(query) do
    # `:tenant` scopes the multitenant content legs to the request's org (#336).
    read_opts = Keyword.take(opts, [:actor, :authorize?, :tenant])
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = Keyword.get(opts, :limit, 10)

    snippet_args = %{query: query, locale: locale}

    content_load =
      Enum.flat_map([:highlight, :passage], fn calc ->
        if Keyword.get(opts, calc, false), do: [{calc, snippet_args}], else: []
      end)

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
      Enum.map(KilnCMS.CMS.ContentTypes.all(), fn ct ->
        {ct.section, fn -> hybrid(ct.resource, query, [load: content_load] ++ hybrid_opts) end}
      end)

    fixed =
      [
        # One section across every dynamic type. `type_name` (an expression
        # calc, so it doesn't run TypeDefinition's editor-only read policy for
        # anonymous callers) labels each hit with its dynamic type.
        {:entries,
         fn ->
           hybrid(KilnCMS.CMS.Entry, query, [load: [:type_name | content_load]] ++ hybrid_opts)
         end},
        # Media and taxonomy are org-scoped like content (epic #336), so the
        # `:tenant` in `read_opts` narrows these sections too.
        {:media,
         fn -> section(KilnCMS.CMS.MediaItem, :search, %{query: query}, read_opts, limit, []) end},
        # Taxonomy (name/description, typo-tolerant) — matched categories, tags and
        # tag groups, so editors and headless frontends can jump to filtered
        # listings. Driven off `Taxonomy.searchable/0` rather than a literal list:
        # this was two entries hard-coded here, which is how `TagGroup` came to be
        # unfindable in search without anything failing (#530).
        Enum.map(KilnCMS.CMS.Taxonomy.searchable(), fn {key, resource} ->
          {key, fn -> section(resource, :search, %{query: query}, read_opts, limit, []) end}
        end)
      ]
      |> List.flatten()

    (compiled ++ fixed)
    |> select_sections(Keyword.get(opts, :sections))
    |> run_sections()
  end

  @doc """
  The section keys that hold **content** — one per compiled type, plus
  `:entries` for every dynamic type.

  Derived rather than written out, so a caller asking for "the content
  sections" keeps meaning that when a type is added or a plugin registers one
  (D18). The three callers that want this all used to hardcode the equivalent
  list and then discard the rest of the sweep.
  """
  @spec content_sections() :: [atom()]
  def content_sections, do: Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.section) ++ [:entries]

  # Every section is a full `Ash.read!` holding a DB connection for its
  # duration, so a caller that reads three of them should not pay for all of
  # them (#960). The fan-out already keys by section, so this is a filter on the
  # thunk list rather than a restructure.
  #
  # #530 is why this stopped being a rounding error: the taxonomy leg became
  # registry-driven, so the discarded cost now grows with each taxonomy resource
  # added rather than being a fixed two queries.
  #
  # An unknown key RAISES rather than being ignored. Ignoring it would answer a
  # sweep missing a section the caller asked for, with nothing failing — which
  # is exactly how `TagGroup` came to be unfindable in search (#530). The
  # message lists what is actually registered, because on an install with
  # plugin-registered types that set is not something the caller can read off
  # the source.
  defp select_sections(sections, nil), do: sections

  defp select_sections(sections, keys) do
    wanted = MapSet.new(keys)
    known = MapSet.new(sections, &elem(&1, 0))

    case wanted |> MapSet.difference(known) |> Enum.sort() do
      [] ->
        Enum.filter(sections, &MapSet.member?(wanted, elem(&1, 0)))

      unknown ->
        raise ArgumentError,
              "unknown search section(s) #{inspect(unknown)}; registered sections are " <>
                "#{inspect(known |> Enum.sort())}"
    end
  end

  # Sections are independent — no section's results affect another's — so they
  # run concurrently rather than one round trip after another. On an install
  # with a dozen registered content types that is the difference between ~19
  # sequential sweeps and `section_concurrency/0` at a time.
  #
  # Concurrency is bounded because each section holds a DB connection for the
  # duration of its queries: unbounded fan-out would drain the Ecto pool
  # (`POOL_SIZE`, default 10) and starve every other request on the node. The
  # default leaves most of the pool free for concurrent traffic; raise it if
  # your pool is sized for it.
  #
  # A failing section still takes the whole call down, matching the previous
  # `Ash.read!` behaviour — a search that silently omits a section would be
  # worse than one that errors. (The one exception is a section whose table has
  # no `search_vector` column, contained in `without_search_vector/2`, because
  # that failure is permanent and belongs to one type.)
  #
  # What it must not do is take the call down *anonymously*. A raise inside a
  # linked task exits the caller with a bare `{exception, stacktrace}`, and the
  # `{:ok, pair}` clause this used to have then met a `{:exit, _}` with a
  # `FunctionClauseError` — burying the real error under a clause failure in
  # the search module. Each section is caught inside its own task instead, so
  # the caller re-raises the actual exception with its original stacktrace; a
  # section that times out is reported by name rather than as a bare exit.
  defp run_sections(sections) do
    sections
    |> Task.async_stream(&run_section/1,
      max_concurrency: section_concurrency(),
      timeout: @section_timeout,
      ordered: false,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.into(%{}, &unwrap_section/1)
  end

  defp run_section({key, run}) do
    {key, run.()}
  rescue
    error -> {key, {:section_failed, error, __STACKTRACE__}}
  end

  defp unwrap_section({:ok, {_key, {:section_failed, error, stacktrace}}}),
    do: reraise(error, stacktrace)

  defp unwrap_section({:ok, pair}), do: pair

  defp unwrap_section({:exit, {{key, _run}, reason}}) do
    raise "search section #{inspect(key)} exited: #{inspect(reason)}"
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
      content_resources()
      |> Enum.flat_map(fn resource ->
        # Same containment as the keyword leg: one type missing its
        # `search_vector` migration must not empty every facet on the page.
        without_search_vector(resource, fn ->
          resource
          |> Ash.Query.new()
          |> Ash.Query.limit(@facet_scan_cap)
          |> Ash.Query.for_read(:search, %{query: query, locale: locale})
          |> Ash.Query.select([:id, :category_id])
          |> Ash.Query.load(tags: [:id, :name, :slug])
          |> Ash.read!(read_opts)
        end)
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

    content_resources()
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

  # Weighted RRF: each `{leg, list, weight}` contributes `weight / (k + rank)`
  # to a record's score; records are deduplicated by id and returned as
  # `{record, score, legs}` sorted by summed score, highest first. Ties (two
  # records each found by one leg at the same rank — every keyword-only
  # rank-1, for instance) keep the order the legs were given in and then the
  # order within the leg, so the fused list is deterministic rather than
  # whatever `Map.values/1` felt like.
  @spec reciprocal_rank_fusion([{leg(), [struct()], float()}], pos_integer()) :: [hit()]
  defp reciprocal_rank_fusion(weighted_lists, k) do
    weighted_lists
    |> Enum.flat_map(fn {leg, list, weight} ->
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {record, rank} -> {leg, record, weight / (k + rank)} end)
    end)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{leg, record, score}, seen}, acc ->
      Map.update(acc, record.id, {record, score, [leg], seen}, fn {existing, total, legs, first} ->
        {existing, total + score, legs ++ [leg], first}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_record, score, _legs, first} -> {-score, first} end)
    |> Enum.map(fn {record, score, legs, _first} -> {record, score, legs} end)
  end

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
