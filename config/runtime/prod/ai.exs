import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# ## AI-assisted SEO drafting (optional)
#
# Opt in by setting SEO_MODEL to a `req_llm` model spec. Leave it unset and
# the editor's "Suggest" control never renders and nothing leaves the
# deployment; the deterministic SEO analysis is unaffected either way.
#
#     SEO_MODEL=ollama:llama3.1          # on-prem, no egress
#     SEO_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
#
# Provider API keys are read by `req_llm` from its own environment variables
# (ANTHROPIC_API_KEY, OPENAI_API_KEY, …) — Kiln never reads or stores them.
# SEO_GENERATOR overrides the adapter module for a bespoke implementation.
if seo_model = System.get_env("SEO_MODEL") do
  seo_generator =
    case System.get_env("SEO_GENERATOR") do
      nil -> KilnCMS.Seo.Generator.ReqLLM
      module -> Module.concat([module])
    end

  config :kiln_cms, KilnCMS.Seo, model: seo_model, generator: seo_generator
end

# ## AI block assist in the editor (optional)
#
# The body-copy twin of SEO_MODEL, and a deliberately separate switch: this
# one sends a block's prose *and the editor's typed instruction* on each
# request, and returns text bound for the page body. Setting SEO_MODEL alone
# leaves it off; the per-block "AI" control never renders.
#
#     ASSIST_MODEL=ollama:llama3.1           # on-prem, no egress
#     ASSIST_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
#
# Provider API keys are read by `req_llm` from its own environment variables
# — Kiln never reads or stores them. ASSIST_GENERATOR overrides the adapter
# module for a bespoke implementation. See docs/ai-assist.md.
if assist_model = System.get_env("ASSIST_MODEL") do
  assist_generator =
    case System.get_env("ASSIST_GENERATOR") do
      nil -> KilnCMS.Assist.Generator.ReqLLM
      module -> Module.concat([module])
    end

  config :kiln_cms, KilnCMS.Assist, model: assist_model, generator: assist_generator
end

# ## Generated answers for /api/ask (optional)
#
# The third AI switch, and the one to think hardest about: `/api/ask` is a
# **public, anonymous** endpoint. Leave ASK_MODEL unset and it stays what it
# is by default — retrieval-only, returning cited published passages and
# `"answer": null` — with nothing leaving the deployment. Set it and a
# stranger's question causes the retrieved passages to be sent to the model.
#
#     ASK_MODEL=ollama:llama3.1           # on-prem, no egress
#     ASK_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
#
# Only *published, world-readable* content is ever retrieved — for EVERY
# caller, bearer token or not (#916). Generation carries its own rate-limit
# buckets on top of the pipeline's per-IP limiter, keyed on the client address
# for anonymous callers; an exhausted bucket degrades to retrieval-only rather
# than refusing the request. Provider API keys are read by `req_llm` from its
# own environment — Kiln never reads or stores them. ASK_GENERATOR overrides
# the adapter module. See docs/rag.md.
if ask_model = System.get_env("ASK_MODEL") do
  ask_generator =
    case System.get_env("ASK_GENERATOR") do
      nil -> KilnCMS.Ask.Generator.ReqLLM
      module -> Module.concat([module])
    end

  config :kiln_cms, KilnCMS.Ask, model: ask_model, generator: ask_generator
end

# Rerank /api/ask's retrieved candidates with the `KilnCMS.Search` reranker
# (bge-reranker-base by default) — and only /api/ask's. `KilnCMS.Search`'s
# own `rerank` switch reranks every search surface on every query, which is
# CPU inference a modest host cannot afford; this one is a bounded call per
# question (at most `limit` candidates per content type). Two things to know
# before setting it, both from the report that asked for it: it fixes the
# ORDER of the candidates and cannot recover a record the fused legs never
# returned, and the cross-encoder runs on the CPU — the deployment that
# asked for this runs on hardware without AVX2 and could not afford it on
# every query; measure a question's cost on your host before exposing it.
# See docs/rag.md, "Reranking ask's sources".
#
# `fetch/1`, not `flag/2`: an unset variable must not rewrite a project
# overlay's `config :kiln_cms, KilnCMS.Ask, rerank: true` back to false.
with {:ok, ask_rerank?} <- Env.fetch("ASK_RERANK") do
  config :kiln_cms, KilnCMS.Ask, rerank: ask_rerank?
end
