import Config

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# ## Meilisearch (optional, Phase 6)
#
# Opt into the typo-tolerant search backend by setting MEILI_URL. Leave it
# unset to keep Postgres full-text search as the only backend. Run
# `mix kiln.meili.reindex` once after enabling to backfill the index.
if meili_url = System.get_env("MEILI_URL") do
  config :kiln_cms, KilnCMS.Search.Meilisearch,
    enabled: true,
    url: meili_url,
    master_key: System.get_env("MEILI_MASTER_KEY"),
    index: System.get_env("MEILI_INDEX") || "kiln_content"
end

# ## Chunked document embeddings (#1940)
#
# Embed the part of a long record's search text past the embedder's 512-token
# window as overlapping chunks, so the semantic side of hybrid search — and the
# relevance floor — sees the whole record, not just its opening. Off by
# default: roughly 2× the embedding work for a corpus of long records. Run
# `mix kiln.embed_all` after turning it on. See docs/semantic-search-plan.md,
# "Long documents".
#
# `fetch/1`, not `flag/2`: an unset variable must not rewrite a project
# overlay's `chunk_long_documents: true` back to false.
with {:ok, chunk_long_documents?} <- KilnCMS.Config.Env.fetch("SEARCH_CHUNK_LONG_DOCUMENTS") do
  config :kiln_cms, KilnCMS.Search, chunk_long_documents: chunk_long_documents?
end

# Aliased here rather than at the top so the Meilisearch block above keeps the
# line numbers docs/environment-variables.md cites.
alias KilnCMS.Config.Env

# ## Hybrid search's relevance floor (#1936)
#
# Runtime overrides for three `KilnCMS.Search` knobs that are otherwise
# compiled config, so retuning — or the model-swap window that runs the floor
# at 0.0 while the corpus re-embeds (docs/semantic-search-plan.md, "Relevance
# floor") — is an env change and a restart, not a deploy each way. Unset
# leaves the compiled value (or a project overlay's) in force, and an
# unusable value keeps it too, with a warning that reaches Logger and Sentry
# once the app is up.
#
# SEARCH_SEMANTIC_MAX_DISTANCE: the floor, a cosine distance in [0, 2]. 0.0
# is legal — it floors every judged hit with a distance at all.
with {:ok, distance} <- Env.float_in("SEARCH_SEMANTIC_MAX_DISTANCE", 0.0, 2.0) do
  config :kiln_cms, KilnCMS.Search, semantic_max_distance: distance
end

# SEARCH_SEMANTIC_FLOOR_LEGS: which legs' hits the floor judges, as a
# comma-separated list. The three semantic legs are required; `keyword_any`
# and `fuzzy` are the optional additions. The lexical legs that vouch for a
# hit (`keyword`, `title`, `alias`) are not accepted at all. A literal table,
# not `String.to_atom/1`: nothing an operator types can mint an atom.
floor_legs = [
  {"semantic", :semantic},
  {"block", :block},
  {"tag", :tag},
  {"keyword_any", :keyword_any},
  {"fuzzy", :fuzzy}
]

with {:ok, names} <-
       Env.list_of("SEARCH_SEMANTIC_FLOOR_LEGS", Enum.map(floor_legs, &elem(&1, 0)),
         required: ~w(semantic block tag)
       ) do
  legs = Map.new(floor_legs)
  config :kiln_cms, KilnCMS.Search, semantic_floor_legs: Enum.map(names, &Map.fetch!(legs, &1))
end

# SEARCH_KEYWORD_ANY_IDF_COVERAGE: the opt-in IDF-coverage variant — a
# keyword_any hit beyond the floor is kept when the query lexemes it matches
# carry at least this share of the query's IDF mass. In (0, 1]; it acts only
# while `keyword_any` is among the floor legs.
with {:ok, coverage} <-
       Env.float_in("SEARCH_KEYWORD_ANY_IDF_COVERAGE", 0.0, 1.0, exclusive_min: true) do
  config :kiln_cms, KilnCMS.Search, keyword_any_idf_coverage: coverage
end
