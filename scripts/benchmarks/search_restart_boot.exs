# Boots one node for `search_restart.py` (#2166): semantic search and
# reranking on the local Bumblebee servings, against the database named by
# BENCH_DB (default kiln_cms_bench_restart; it must start `kiln_cms_bench`).
# Needs a KILN_ML build: `KILN_ML=1 MIX_ENV=dev mix compile`.
#
#   DEMO_MODE=after   the branch as shipped (warm-up gate + budget)
#   DEMO_MODE=before  the old behaviour: latch open from the start, no budget
#   DEMO_SEED=1       seed a corpus (scripts/benchmarks/seed.exs) and exit:
#
#     createdb kiln_cms_bench_restart   # then migrate it, e.g. `MIX_ENV=test
#                                       # MIX_TEST_PARTITION=x mix ash.setup` and rename
#     BENCH_PAGES=100 BENCH_POSTS=300 DEMO_SEED=1 DEMO_RERANK=0 KILN_ML=1 MIX_ENV=dev \
#       BUMBLEBEE_OFFLINE=true mix run --no-start scripts/benchmarks/search_restart_boot.exs
mode = System.get_env("DEMO_MODE", "after")
Logger.configure(level: :info)

put = fn app, key, kw ->
  Application.put_env(app, key, Keyword.merge(Application.get_env(app, key, []), kw))
end

put.(:kiln_cms, KilnCMS.Repo,
  database: System.get_env("BENCH_DB", "kiln_cms_bench_restart"),
  pool_size: 10
)

put.(:kiln_cms, KilnCMS.Search,
  semantic: true,
  embedder: KilnCMS.Search.Embedder.Bumblebee,
  rerank: System.get_env("DEMO_RERANK", "1") == "1",
  reranker: KilnCMS.Search.Reranker.Bumblebee
)

if mode == "before" do
  put.(:kiln_cms, KilnCMS.Search, query_budget: :infinity)
  KilnCMS.Search.Warmup.put_ready(true)
  put.(:kiln_cms, KilnCMS.Search.Warmup, timeout: 0)
end

lifted =
  KilnCMSWeb.RateLimit.default_limits() |> Map.new(fn {b, _} -> {b, {100_000_000, 60_000}} end)

Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit, limits: lifted)

put.(:kiln_cms, KilnCMSWeb.Endpoint,
  server: System.get_env("DEMO_SEED") != "1",
  watchers: [],
  code_reloader: false,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("DEMO_PORT", "4100"))]
)

IO.puts("demo boot: mode=#{mode} t=#{System.os_time(:millisecond)}")
{:ok, _} = Application.ensure_all_started(:kiln_cms)
IO.puts("demo app started: t=#{System.os_time(:millisecond)}")

if System.get_env("DEMO_SEED") == "1" do
  Code.require_file("scripts/benchmarks/seed.exs")
  System.halt(0)
end
