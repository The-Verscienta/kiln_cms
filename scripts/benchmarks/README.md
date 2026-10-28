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

# Live-blog firing benchmark

The write-side benchmark for a live blog (#2049): one small published update
every few seconds, each related to one parent story. The results are in
[`docs/benchmarks.md`](../../docs/benchmarks.md#live-blog-an-update-every-few-seconds).

```bash
export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:$PATH"
scripts/benchmarks/live_blog.sh                                   # ~105 min: three 30-minute legs
BENCH_DURATION=120 BENCH_SUBSCRIBERS=0 scripts/benchmarks/live_blog.sh   # a smoke run
```

Same prerequisites and the same throwaway database as `api_latency.sh`, and the
same corpus (`seed.exs`, with its knobs). There is no HTTP server: `live_blog.exs`
runs in one `MIX_ENV=prod` BEAM with the application started, so the Oban
queues that fire each update run beside it, with the production queue sizes
and `POOL_SIZE=10`.

## The model

The verscienta-news plan's `LiveStory` and `LiveUpdate`
([N3](../../docs/plans/2026-10-19-verscienta-news.md)), on the compiled types:

- the **story** is a published page in a "Live" category (the section front);
- each **update** is a published post in that category whose `:reference`
  custom field `live_story` points at the story, with an inverse
  (`live_updates`), so the story's reverse field lists its updates.

Each leg (one per `BENCH_SUBSCRIBERS` value) starts a fresh story, then:

1. publishes an update every `BENCH_INTERVAL_MIN`–`BENCH_INTERVAL_MAX` ms for
   `BENCH_DURATION` seconds, each through `CMS.create_post!/2` and
   `CMS.publish_post!/3` as an admin;
2. waits for every update to fire;
3. edits the story once (a live title change, which fires it in place) and
   waits for the re-fire wave that reaches its updates.

## What is measured

| Number | How |
|---|---|
| Fire latency | publish start → the update's `{:fired, :post, id}` on the `"firing"` PubSub topic, which `KilnCMS.Firing.Engine` broadcasts once the artifacts are persisted. "After publish" starts the clock when the publish action returns instead |
| Re-fires | every `"firing"` broadcast during the leg, by type and id: the story's, anything else's, and any update fired twice |
| Oban queue depth | `available` + `executing` rows by queue, sampled every second |
| DB load | `[:kiln_cms, :repo, :query]` count and total time (the sampler's own queries excluded), and the `pg_stat_database` counters for the benchmark database |
| Feed event | publish start → the update's `published` event on the change feed (`KilnCMS.Delivery.Feed`, #2050), timed by its `[:kiln_cms, :delivery, :feed, :event]` telemetry, which fires once the PubSub broadcast is sent. Also the count of feed events per leg and per story edit |
| Last subscriber | with N subscribers, N processes on the site's feed topic (`Feed.topic/1`); the time from publish start until the last of them has received the update's event |
| Idle baseline | `BENCH_BASELINE` seconds with nothing published, after the legs. The per-update DB figures are net of it |

The subscribers are in-BEAM processes: the feed's server side (2.1) with
nothing in front of it. The SSE and channel transports, sockets and the
network are 2.2 and are not measured here.

## Knobs

| Variable | Default | |
|---|---|---|
| `BENCH_DURATION` | 1800 | seconds of updates per leg |
| `BENCH_INTERVAL_MIN`, `BENCH_INTERVAL_MAX` | 2000, 5000 | ms between updates, uniform |
| `BENCH_SUBSCRIBERS` | `0,1000,10000` | one leg per value |
| `BENCH_WAVE_TIMEOUT` | 600 | seconds to wait for the story-edit wave |
| `BENCH_BASELINE` | 300 | seconds of the idle baseline |
| `BENCH_SEED` | 2049 | RNG seed for the update text and intervals |
| `BENCH_WORK` | a `mktemp -d` | where logs, `results.json` and `results.md` go |
| `POOL_SIZE` | 10 | the Repo pool |
| corpus | as `api_latency.sh` | `BENCH_PAGES`, `BENCH_POSTS`, `BENCH_DRAFTS` |

# Subtree-move benchmark

What moving a section with a large subtree costs (#1903), on a type with many
rows: the cost D21 bounded but never measured. The recorded results are in
[`docs/benchmarks.md`](../../docs/benchmarks.md#content-tree-moving-a-large-subtree).

```bash
export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:$PATH"
scripts/benchmarks/subtree_move.sh                                    # ~10 min with a warm _build/prod
BENCH_ROWS=2000 BENCH_SUBTREES=100,500 scripts/benchmarks/subtree_move.sh   # a smoke run
```

Same prerequisites and throwaway database as `api_latency.sh`, without the
corpus: `subtree_move.exs` builds its own tree. Per leg it creates a dynamic
type with `alias_pattern: "/[ancestors]/[slug]"`, one document through the
domain actions, and clones that document with SQL into a published section of
that leg's `BENCH_SUBTREES` size (children of 100, two levels below the section) and
draft roots padding the type to `BENCH_ROWS`. Every alias is set to what the
pattern derives where the document sits. It then re-parents the section under
another root and runs `RegenerateSubtreeAliases.perform/1` in a task, as Oban
would.

| Number | How |
|---|---|
| Job | wall time of `perform/1` |
| Queues idle | from the job's start until no Oban job is `available` or `executing`: the re-fires and index updates the rewrites enqueued |
| Aliases rewritten, Redirects | rows whose alias now starts under the new root; `redirects` rows written |
| Queries, Query ms | `[:kiln_cms, :repo, :query]` events from the job's own process, and their total time |
| Job peak | the job process's memory, sampled every 2 ms; BEAM growth is `:erlang.memory(:total)` over the same window |
| Whole-type read, Subtree CTE | the job's read before #1903 (every `(id, parent_id, slug)` of the storage table) and after (`ContentTree.subtree/3`), timed on their own. On a build without `subtree/3` the CTE column is `–` |

| Variable | Default | |
|---|---|---|
| `BENCH_ROWS` | 50000 | documents of the type, per leg |
| `BENCH_SUBTREES` | `100,1000,10000` | one leg per subtree size |
| `BENCH_WORK` | a `mktemp -d` | where logs, `results.json` and `results.md` go |
| `POOL_SIZE` | 10 | the Repo pool |
