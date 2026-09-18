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
