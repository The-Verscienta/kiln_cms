# Headless API latency benchmark

The benchmark behind the v1.0 success metric "headless API p95 under 50 ms"
(#1546). The recorded results, and what they mean, are in
[`docs/benchmarks.md`](../../docs/benchmarks.md).

```bash
export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:$PATH"
scripts/benchmarks/api_latency.sh
```

It needs a local PostgreSQL that `postgres`/`postgres` can create databases on
(override with `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`), `openssl`,
`curl`, and a checkout whose `mix deps.get` has run. No load tool is needed:
the client is an Elixir script using `Req`, which the project already depends
on. A run with the defaults takes about 15 minutes, most of it the prod compile
on a cold `_build/prod`.

## What it does

| Step | File | What happens |
|---|---|---|
| database | `api_latency.sh` | creates `kiln_cms_bench_<pid>` and **drops it on exit** (`KEEP=1` keeps it). Nothing else on the server is touched. |
| build | `api_latency.sh` | `MIX_ENV=prod mix compile`, then `mix ash.migrate`. |
| corpus | `seed.exs` | 500 pages, 1,500 posts and 200 drafts, with 12 categories and 40 tags. Body text mixes 70 common words with 3,000 rare made-up ones, so a query can match most documents or a handful. All of it goes through the domain actions as an admin, so each document is versioned, indexed and fired as a real publish leaves it. Waits for every firing job. Refuses any database not named `kiln_cms_bench*`. |
| server | `api_latency.sh` | `PHX_SERVER=true mix phx.server` in prod as a named node on `BENCH_PORT` (4100), `POOL_SIZE=10` (the production default), logging at `:info`. |
| load | `load.exs` | a second node that raises the rate limits, attaches a telemetry collector, and runs every endpoint, cold then warm, at each concurrency. |

### Surfaces

All anonymous, all against `Host: localhost` (the canonical `PHX_HOST`):

| Name | Request |
|---|---|
| `jsonapi_list` | `GET /api/json/posts/published?page[limit]=20&page[offset]=N` |
| `jsonapi_by_slug` | `GET /api/json/posts/by-slug/:slug?locale=en` |
| `graphql_list` | `POST /gql` `publishedPosts(limit: 20, offset: N) { results { id title slug excerpt } }` |
| `graphql_by_slug` | `POST /gql` `postBySlug(slug:, locale: "en") { id title slug excerpt }` |
| `content_by_slug` | `GET /api/content/post/:slug` (the fired JSON artifact) |
| `search` | `GET /api/search?q=<rare word>`: a term a handful of documents contain, the typical query (keyword and title legs; the default build has no ML) |
| `search_common` | `GET /api/search?q=<common word>`: a term nearly every document contains, the worst case for ranking |
| `sync_initial` | `GET /api/sync?initial=true&limit=100&type=post\|page` |

### Cold and warm

- **Cold**: `KilnCMS.Cache.flush_delivery/0` and the host cache are cleared on
  the server, then the run walks distinct keys: a different document, page
  offset or query per request, until they run out. PostgreSQL's own buffers
  stay warm; this measures Kiln's caches, not the disk.
- **Warm**: 200 requests over 50 keys, then the measured run over the same 50.

Only `content_by_slug` and `sync_initial` (and host and type-registry lookups
on every route) read through an in-BEAM cache, the fired-artifact cache, so
for the other surfaces cold and warm differ little by design.

### What is measured

- **Server**: `[:phoenix, :endpoint, :stop]` duration for each request tagged
  with the run's `x-bench-run` header. That is the whole endpoint, including
  rate limiting and tenant resolution, excluding writing the body to the socket.
  This is the number the metric is judged on: it is origin-side, as
  [`docs/performance.md`](../../docs/performance.md) defines its SLOs.
- **Client**: wall time around each `Req` request on the same machine. It adds
  the loopback, the client's own scheduling and JSON decoding.

Concurrency is closed-loop: C workers, each sending its next request as soon
as its last one is answered.

### Rate limits

`load.exs` sets every `KilnCMSWeb.RateLimit` bucket to 100,000,000 a minute
with `Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit, limits: …)` on the
server node: the same configuration key a deployment sets, applied to the
running node. Nothing is disabled in code. Without it, a single client is
answered `429` after the first second (`api` allows 120 a minute per address).
A run where anything is not `200` shows it in the "non-200" column.

## Knobs

| Variable | Default | |
|---|---|---|
| `BENCH_PAGES`, `BENCH_POSTS`, `BENCH_DRAFTS` | 500, 1500, 200 | corpus size |
| `BENCH_SEED` | 1546 | RNG seed for the corpus text |
| `BENCH_CONCURRENCY` | `1,10,50` | concurrency levels |
| `BENCH_WARM_N`, `BENCH_COLD_N` | 2000, 500 | measured requests per run |
| `BENCH_ENDPOINTS` | all | comma list of surface names |
| `BENCH_PROFILE` | none | comma list of surfaces to profile after the load runs (below) |
| `BENCH_PROFILE_N` | 20 | requests per profile |
| `BENCH_PORT` | 4100 | server port |
| `BENCH_WORK` | a `mktemp -d` | where logs, `results.json` and `results.md` go |
| `POOL_SIZE` | 10 | the server's Repo pool |

## Profiling a slow surface

`BENCH_PROFILE=search,sync_initial` adds, after the load runs, a profile of
each named surface: `BENCH_PROFILE_N` serial requests made in-process on the
server through `KilnCMSWeb.Endpoint.call/2`, with

- the wall time per request;
- every Repo query they ran, by table, with database and pool-queue time;
- the three slowest statements, with their SQL, ready for `EXPLAIN ANALYZE`
  (run with `KEEP=1` to keep the database for that);
- the 25 functions with the most own time under `:tprof` (`call_time`).
  Tracing slows everything down, so read those as proportions.

## Reading a result honestly

- **Record the load average.** Each row of `results.json` carries the load
  average when the run started. On a laptop shared with other work, latency
  tracks that more than it tracks Kiln.
- **A laptop is not a server.** Client and server share the CPU, and so does
  PostgreSQL. Treat the numbers as an order of magnitude and a regression
  signal, not a capacity figure.
- **The server has no static manifest.** The benchmark skips `mix
  assets.deploy`, so the log has one "could not find static manifest" error.
  No API route reads it.
- **Leftovers.** If the script is killed with `SIGKILL`, its trap does not run:
  drop `kiln_cms_bench_<pid>` yourself, and look for a BEAM started with
  `--sname kiln_bench_srv_<pid>`.
