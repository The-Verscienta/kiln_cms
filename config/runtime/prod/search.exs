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
