# Performance: SLOs, tuning, and load checks

KilnCMS serves public content as **server-rendered HTML** (`KilnCMSWeb.ContentController`)
plus headless **fired artifacts** (`KilnCMSWeb.ArtifactController`). This doc records the
target SLOs, the knobs that hit them, and how to run a basic load check. It complements
[`observability.md`](observability.md) (telemetry events) and the production hardening
checklist in the [README](https://github.com/The-Verscienta/kiln_cms/blob/main/README.md).

## SLO targets

| Surface                                    | p95 target | Baseline (see [below](#baseline)) |
| ------------------------------------------ | ---------- | --------------------------------- |
| Public HTML — cache **hit**                | < 50 ms    | 1.7–10.4 ms                       |
| Public HTML — cache **miss**               | < 250 ms   | not yet measured                  |
| Headless API — fired artifact (`GET /api/content/:type/:slug`) | < 50 ms | 2.7–7.4 ms |
| Editor autosave                            | < 500 ms   | not yet measured                  |
| Publish response                           | < 2 s      | not yet measured                  |

These are origin-side targets (excluding network/CDN). The delivery path is designed so the
**hit** path does no database work — see below. The headless-API row is the v1.0 success
metric "headless API p95 under 50 ms" (#1546).

## How the targets are met

- **Cache-hit delivery does no DB work.** The cached payload carries the record, the
  media-enriched blocks (resolved `srcset`), and the locale `translations` list, so a hit
  issues zero queries (`KilnCMS.Cache`, `ContentController.payload/3`). Every lookup is
  emitted as `[:kiln_cms, :cache, :content]` telemetry, tagged `hit`, `miss`, `coalesced`
  (the request found no entry and was served by another caller's in-flight read — the shape
  a stampede is made of, so a spike here is the signal, not a healthy hit rate) or `error`
  (the fetch failed and the caller recomputed outside the per-key deduplication; a sustained
  rate here means every concurrent request is hitting the database at once).
- **CDN offload.** Published HTML sends `Cache-Control: public, max-age=60,
  stale-while-revalidate=300`, a content `ETag` (→ `304` on `If-None-Match`), and
  `Vary: Accept-Language`. The URL is the whole cache key: a public page,
  the blog and event indexes (`/<plural>/index.json` too), the stock home and
  a form's page and embed take their language from the path prefix, or the
  site's default without one, never from the visitor's session (#2595). Kiln
  does not read `Accept-Language` for these; the `Vary` header is kept
  unchanged. The `ETag` names the URL's language
  as well as the record's, so `/fr/x` and `/x`, which can be answered by one
  English record in two different chromes, never `304` each other. The `ETag`
  also names the running build
  (`KilnCMSWeb.BuildFingerprint`: the code of Kiln, its overlay and plugins,
  the version of every application they depend on, and the asset manifest), so a deploy
  that changes markup is not `304`ed to a client holding the old page. Nodes
  of one image agree; during a rolling deploy the tag flips between old and
  new nodes until it finishes. A markup change made only by runtime
  configuration does not move it. Beyond the record's own columns, the tag
  folds in everything else the page is built from, so a `304` only ever
  validates the page that would be rendered now (#2765):
  - **The cached delivery payload.** A hash of the whole payload: the blocks
    with fragments expanded, media resolved (alt text, `srcset`, dimensions,
    focal point) and forms embedded; the published sibling translations
    behind the hreflang links and the language switcher; fields inherited
    along a locale fallback chain; bylines; the author; and the category an
    SEO pattern can name. None of these moves the page's `updated_at`; each
    has a write that drops the payloads it affects, and the next build hashes
    differently. That covers a fragment's republish, a media edit, a form edit,
    a sibling translation's publish, a category rename (that site's
    payloads, because the `[category]` SEO token can put the name in the
    `<title>`) and a change to a user's display name (every site's payloads,
    because it is the byline fallback and the JSON-LD `author`). A save that
    leaves a name unchanged drops nothing, and neither does a tag or tag
    group rename: no delivered page shows a tag. The hash is taken once when
    the payload is built and stored with it, so a cache hit pays nothing for
    it, and two builds of unchanged data hash the same, so a rebuild on its
    own (a TTL expiry, a flush) does not move the tag. It covers more than
    the page shows (whole sibling records, the author's record), which can
    cost a `200` where a `304` would have done, never a stale `304`.
  - **The header and footer menus**, as the page renders them. A menu item
    that links to a page shows that page's current published path, and drops
    out when the page is unpublished; neither touches the page the menu sits
    on. Menu trees are cached for 5 minutes, so after a linked page is
    renamed or unpublished, revalidations get a `200` once that entry
    expires.
  - **The site's head generation**, a token moved on every node by a save of
    branding, code injection, feed settings or a menu; any write to a content
    type or one of its fields (feed and calendar links and the type's label
    come from the type registry, not the page); and a save of the site's
    locale fallback settings (they decide the language switcher). Each such
    save costs every page on the site one `200`; they are rare. A site with
    no such save since a node started carries a token that node drew at
    random, so without sticky sessions two nodes can tag one page
    differently until the next save, and a restart moves the tag: extra
    `200`s, never a stale `304` (#2502).

  404s send `Cache-Control: no-store`. The in-BEAM cache is
  single-node, so a CDN in front is what absorbs a viral spike.
- **Flushing by hand.** Invalidation is automatic and precise on writes, so a
  manual purge is not part of publishing. For the states precise invalidation
  cannot see — a config change, a template deploy, an external source feeding a
  custom block — there is a **Flush delivery cache** button on `/editor/system`
  (admin-only) and `mix kiln.cache.flush` for local use (#483). Both clear the
  published-record cache *and* the fired-artifact cache: clearing one leaves the
  site serving half-stale. They leave each site's `<head>` and menus
  generation tokens and its last-known admin allowlist in place, because those
  live in a store no flush or eviction reaches (#2502): moving a token back
  would answer `304` to a browser holding a page with the old `<head>`. A
  flush moves a page's `ETag` only when the rebuilt payload differs from the
  one it replaced (#2765). Anything a block reads while the HTML renders,
  after the payload is built, is not in the tag, so a browser or CDN
  revalidating such a page still gets a `304` until something the tag covers
  moves: a deploy that changes the build, or one of the saves that move the
  head generation. Every
  request re-reads the database until the caches warm again, and on a
  multi-node deployment the purge reaches **every** node
  (#1138) — the count shown is from the node that served the request. On a
  release use
  `bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"` — the `mix` task boots a
  second node that would clear its own empty caches and start draining
  production Oban queues on the way.
- **Publish returns before firing.** The publish transition enqueues a `Firing.FireWorker`
  (queue `:firing`) instead of rendering every surface inline, so the publish response isn't
  blocked on firing. Delivery falls back to a live render on miss; the artifact API answers
  `503` + `Retry-After` for the brief window before the artifact lands.
- **Analytics never block or exhaust the pool.** `track_view` and search-query recording —
  from the editor palette and from `GET /api/search` alike (`Search.record_query_async/3`;
  until #1712 the API wrote it inline, inside the request) — run on a bounded
  `Task.Supervisor` (`max_children: 100`); excess best-effort writes are dropped under a
  spike rather than queuing on the DB pool.
- **A search holds one connection at a time.** See [Search and the pool](#search-and-the-pool).
- **Bounded editor mounts.** The editor index, media library, content-editor media picker,
  related-content picker, and trash each load at most **500** rows (newest first) per mount.

## Oban queues & pool sizing

Workers are split by workload so a bulk publish or embedding backfill can't starve mail or
the cron triggers (`config/config.exs`):

```elixir
queues: [firing: 5, search: 5, mail: 3, newsletter: 3, billing: 3, media: 3, webhooks: 3,
         scheduling: 5, link_check: 3, federation: 3, push: 3, backups: 1, backup_steps: 1,
         occurrence_backfill: 1, default: 10]
```

| Queue        | Workers                                                |
| ------------ | ----------------------------------------------------- |
| `firing`     | `FireWorker`, `RefireWorker`                           |
| `search`     | `EmbeddingWorker`, `BlockEmbeddingWorker`, `MeilisearchWorker` |
| `mail`       | `WorkflowMailWorker`                                   |
| `media`      | `VariantWorker`                                        |
| `webhooks`   | `DeliveryWorker`                                       |
| `newsletter` | `SendWorker`, `MailWorker` (newsletter fan-out)        |
| `billing`    | `WebhookWorker` (inbound payment webhooks)             |
| `link_check` | `Links.CheckWorker` (outbound link checking, paced per domain) |
| `federation` | `Federation.DeliveryWorker`, `AnnounceWorker`, `ActorUpdateWorker` |
| `push`       | `Push.Worker` (Web Push)                               |
| `backup_steps` | `Backups.StepWorker`: one step of an in-app backup, concurrency 1 per node ([backups.md](backups.md#how-an-in-app-backup-runs-2218)) |
| `backup_dir_<id>` | `Backups.StepWorker` and `Backups.MarkerSyncWorker`: the backup steps and last-good marker syncs that must run where one backup directory is. Not in the list above: each node's backup heartbeat starts the queue of the directory it reads at runtime, concurrency 1, on that node only ([backups.md](backups.md#which-node-runs-a-step)) |
| `backups`    | `Backups.Worker`: only jobs enqueued before #2218, which it hands to `backup_steps`; still in 1.11, removed in a later release |
| `occurrence_backfill` | `Events.BackfillWorker`: the boot-time recompute of events' next dates, one job per recurrence engine version per day, ten minutes after boot ([events.md](events.md#recomputing-stored-dates-at-boot)) |
| `scheduling` | Every-minute AshOban triggers (scheduled publish, scheduled unpublish/embargo) |
| `default`    | Daily AshOban triggers (trash purge, untitled sweep), and the boot-time and cron jobs that have no queue of their own, among them `Jobs.PrivateArgsScrub` (drops private args from finished jobs, ten minutes after boot and daily) and `Accounts.ErasureBackfill` |

The `scheduling` queue is isolated because its triggers run on a `* * * * *` cron: if they
share `default` with bulk publish/embedding work, the scheduler and worker jobs can sit queued
longer than their one-minute cadence, drifting scheduled publish/unpublish past their target
time.

The `newsletter` and `billing` queues are isolated for the same reason as `scheduling`, from
the other direction: a large newsletter blast must not starve transactional `mail`, and an
inbound payment webhook must not queue behind one — a delayed entitlement event is a paying
member locked out of what they just bought.

The `backup_steps` and `occurrence_backfill` queues are isolated for the version they run
under rather than for load: during a rolling deploy, a node of the previous release still
polls `default`, and would run a newer release's job with the older code. A deployment that
builds Oban's `queues:` list itself must carry both, or their jobs are queued and never run.

**Pool sizing.** Total worker concurrency above is 52, plus 1 for the backup directory queue
each node starts at runtime, all sharing the Ecto pool with web requests. Size `POOL_SIZE` (in `config/runtime.exs`) so jobs and web requests don't starve
each other:

```
POOL_SIZE ≈ (sum of Oban queue limits that do DB work) + (peak concurrent web DB checkouts)
```

A reasonable production starting point is **`POOL_SIZE=25`** for the default queue config on a
small node, then tune from the `kiln_cms.repo.query.queue_time` metric (rising queue time =
pool too small). Tune individual queue limits per deployment; cap the most bursty (`search`)
lower if embeddings dominate.

**Change-feed streams.** Each open `GET /api/feed` stream holds one request
process on its node for as long as the client stays connected, but no database
connection while it waits for events. A resume replays from the database, and
at most 8 resumes replay at once per node. Streams are capped per API key or client
address (50) and per node (20,000), and they are left out of the Phoenix
request-duration metrics, which they would swamp; watch
`[:kiln_cms, :delivery, :feed, :sse, …]` instead. The limits and the proxy
settings are in [api.md → Change feed (SSE)](api.md#change-feed-sse).

## Search and the pool

A search is the heaviest anonymous read Kiln serves: `KilnCMS.Search.global/2` runs a
section per content type, taxonomy resource and (outside `/api/search`) media, and each
content section fuses up to eight legs. Since #1712 it is built to share the pool:

- **At most two sections in flight.** `section_concurrency` (`config :kiln_cms,
  KilnCMS.Search`) caps how many sections run at once, and so how many connections one
  search can hold. It defaults to **2**. It was 4, which filled the default 10-connection
  pool at two and a half concurrent searches. At 1 a lone search takes about twice as long,
  so 2 is the default. Raise it only on a pool sized for `section_concurrency × concurrent
  searches` on top of Oban and every other request.
- **A connection per query, not per search.** Each query checks a connection out and gives
  it back. Holding one checkout for a whole search was tried and made things worse. The
  connection sat idle between queries, and a cache fallback inside the search, which then
  ran in Cachex's own process, needed a second one. At ten clients the pool dropped nearly
  every request. (Since #2823 a cache miss from a process that holds a connection runs on
  that connection, uncached; the idle connection is still reason enough.)
- **`503`, not `500`, when the pool gives up.** A checkout the pool drops
  (`connection not available and request was dropped from queue`) makes `GET /api/search`
  answer `503 temporarily_unavailable` with `Retry-After: 1`, which is never cached.
- **Legs read ids.** Fusion needs only ids. The records are read once, for the hits kept,
  and `/api/search` reads only the fields it renders, so a search no longer decodes block
  trees it throws away.
- **The title leg is indexed.** `<table>_title_lexemes_index` is a GIN index on each
  title's lexemes. A rare-word title lookup on 1,700 posts went from a 7.4 ms sequential
  scan to 0.04 ms.
- **Analytics off the request.** The `search_queries` upsert runs on the task supervisor.
- **A budget per search** (#2166). `query_budget` (`config :kiln_cms, KilnCMS.Search`,
  milliseconds, default **1500**, `:infinity` for none) caps how long one sweep may take.
  The query embedding gets half of it. A leg still running at the deadline is dropped
  unless it finishes within `cut_grace` (below), the legs that finished are fused, and
  a reranker that misses it leaves fused order.
  `GET /api/search` then answers `partial: true` with the cut legs under `incomplete`,
  and sends `cache-control: no-store` so no shared cache keeps the cut answer. A normal
  search takes tens of milliseconds, so the budget only bounds the tail: a cold serving,
  a slow nearest-neighbour scan, a pool queue during a deploy. Every response carries a
  `Server-Timing` header with the time per leg, so the slow part shows in the browser's
  network panel or a `curl -D -`.
- **A grace before the budget kills a section** (#2614). With `section_concurrency`
  above 1 (the default is 2) each content section runs in its own task, and a section
  checks the deadline only between its legs. A task still running at the deadline used
  to be killed at once. Killing one mid-query costs its database connection: Postgrex
  sends Postgres a cancel request, so the query does not keep running there, but
  DBConnection drops the connection and opens a new one, which against a remote
  database is a TLS handshake and authentication. Now the sections still running at
  the deadline get `cut_grace` (`config :kiln_cms, KilnCMS.Search`, milliseconds,
  default **100**) to return on their own; a section that does is kept, with its
  finished legs, and only the ones still running after the grace are killed. The cost is the tail: a cut search may answer up to `cut_grace`
  after `query_budget`. The grace saves only the connections whose query ends inside
  it. A longer query is still killed, and a section that was waiting for a connection
  at the deadline may get one during the grace and start its query. Set `cut_grace: 0`
  for the old behavior. At `section_concurrency: 1` nothing is killed and the setting
  does nothing. `kiln_cms_search_budget_cut_returned` and
  `kiln_cms_search_budget_cut_killed` show how often each happens
  ([observability.md](observability.md#search-budget-cuts)).

Measured with `scripts/benchmarks/api_latency.sh` (#1546): `MIX_ENV=prod`, `POOL_SIZE=10`,
500 pages, 1,500 posts and 200 drafts, closed-loop clients, Apple M5 Pro with PostgreSQL
on the same host. The laptop was shared with other work: load average 10–25 before and
6–12 after. Server-side p50 / p95 / p99 in ms, for the warm pass (the cold pass reads
the same):

| Query | Clients | Before | After | Throughput before → after |
|---|---|---|---|---|
| rare word | 1 | 36.0 / 52.3 / 65.4 | 23.4 / 25.8 / 27.9 | 26 → 43 req/s |
| rare word | 10 | 69.2 / 110.0 / 125.8 | 50.4 / 93.5 / 108.0 | 141 → 186 req/s |
| rare word | 50 | 351.3 / 437.8 / 550.1 | 246.8 / 314.0 / 359.2 | 144 → 206 req/s |
| common word | 1 | 48.2 / 66.9 / 75.8 | 29.2 / 36.3 / 38.5 | 20 → 33 req/s |
| common word | 10 | 280.0 / 486.3 / 571.3 | 94.6 / 140.7 / 152.1 | 34 → 102 req/s |
| common word | 50 | 1,254 / 2,161 / 3,334 | 481.6 / 574.0 / 624.9 | 36 → 106 req/s |

A single search now meets the 50 ms target. Beyond ten clients, latency is bounded by
throughput rather than by the pool: with 50 closed-loop clients at 206 req/s, each request
waits about 240 ms by Little's law. What is left per request is CPU, the Ash
query-building for about thirteen reads, and, for a word on every document, ranking every
match before the top-N sort (#1712, cause 3).

## Telemetry to watch

These are defined in `KilnCMSWeb.Telemetry.metrics/0`. Two things can read them:

- **LiveDashboard → Metrics**, at `/dev/dashboard` in development.
- **The Prometheus exporter**, in production, but **only when `KILN_METRICS_ENABLED` is on**.
  It is off by default, and a stock install records none of them. For the listener, its
  exposure and the scrape config, see
  [`observability.md`](observability.md#prometheus-and-grafana).

Durations are histograms in milliseconds, so a p95 is
`histogram_quantile(0.95, sum by (le, route) (rate(<name>_bucket[5m])))`.

- `phoenix.router_dispatch.stop.duration` (tag `route`) — **per-route latency**. The
  headless-API row above is this metric with `route="/api/content/:type/:slug"`.

- `kiln_cms.cache.content.count` (tag `result: hit | miss`) — **cache hit rate**
- `kiln_cms.delivery.render.duration` (tags `type`, `status`) — delivery latency
- `kiln_cms.firing.fire.duration` (tags `type`, `mode`) — publish/firing cost
- `kiln_cms.repo.query.queue_time` — DB pool pressure (pool-size signal)
- `oban.job.stop.duration` / `oban.job.exception.count` (tags `queue`, `worker`) — queue
  throughput, latency, and failures (alert on queue backlog)
- `kiln_cms.search.budget.cut.returned` / `kiln_cms.search.budget.cut.killed` — search
  sections that stopped on their own inside `cut_grace` after the query budget's
  deadline, and those killed after it; a steady `killed` rate means reconnects
  ([Search and the pool](#search-and-the-pool))

## Running a basic load check

The delivery hit path is the one to baseline. With the app running (`mix phx.server`) and a
published page at `/<slug>`:

```bash
# Cache-hit HTML delivery (warm the cache with one request first).
curl -s -o /dev/null http://localhost:4000/<slug>
hey -z 30s -c 50 http://localhost:4000/<slug>          # or: oha / wrk / k6

# Headless artifact (JSON surface).
hey -z 30s -c 50 http://localhost:4000/api/content/page/<slug>
```

k6 sketch for the two surfaces:

```js
import http from "k6/http";
import { check } from "k6";

export const options = { vus: 50, duration: "30s" };

export default function () {
  const html = http.get(`${__ENV.BASE}/${__ENV.SLUG}`);
  check(html, { "html 200": (r) => r.status === 200 });

  const api = http.get(`${__ENV.BASE}/api/content/page/${__ENV.SLUG}`);
  check(api, { "api ok/503": (r) => r.status === 200 || r.status === 503 });
}
// BASE=http://localhost:4000 SLUG=my-page k6 run delivery.js
```

Watch `kiln_cms.cache.content.count` (should be almost all `hit`), the route p95 against
the table above, and `repo.query.queue_time` for pool pressure. For the editor
autosave / publish SLOs, the matching `kiln_cms.editor.*` metrics exist
(`KilnCMSWeb.EditorTelemetry`). They are recorded only when the exporter is on, like
everything else.

Two things make a single-machine load test measure the wrong thing:

- **The per-IP rate limits.** `KilnCMSWeb.RateLimit` allows `api` 120 requests a minute
  and `delivery` 300 a minute from one address. From a single client, anything past the
  first second is a `429`. Check the status counts: if `ab` reports `Non-2xx responses`,
  the run measured the limiter, not delivery. For a benchmark run, raise the limits on
  the node under test:
  `Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit, limits: %{api: {100_000_000, 60_000}, delivery: {100_000_000, 60_000}})`.
  Every client class inside `:delivery` is a percentage of that limit
  ([bot-budgets.md](bot-budgets.md)), so raising it raises them all. Two things to
  know: `curl` counts as another bot (150 a minute at the shipped limit, half a
  browser's), while `hey`, `oha`, `k6` and `ab` count as browsers; and this
  `put_env` replaces the whole `KilnCMSWeb.RateLimit` config, which drops the
  `delivery_classes` key the `KILN_BOT_BUDGET_*_PERCENT` variables write, so the
  built-in class defaults apply on that node until it restarts.
- **The `Host` header.** Send the canonical `PHX_HOST`. A host that names no org (such as
  `127.0.0.1` when `PHX_HOST=localhost`) falls back to the default org through a database
  read on every request. Under load that read queues on the pool behind the view-tracking
  writes and adds 10–20 ms at p95. Real traffic doesn't pay that, so the run would
  overstate latency.

To read p95 off the exporter rather than the load tool, scrape `/metrics` before and after
the run and apply `histogram_quantile` to the difference in bucket counts. Sub-millisecond
values all fall in the first bucket (`le="1.0"`), so the histograms can't resolve below
1 ms.

## Baseline

The first recorded baseline, taken on 2026-09-19 against `main` after v0.9.0, plus the exporter (#1362).
**It comes from a laptop, not a server.** Treat it as an order of magnitude, and as proof
that the measuring path works. It is not a capacity figure.

- **Host:** Apple M5 Pro, 18 cores, 24 GB. The machine was shared with other workloads
  during the run (load average 27–52), which is why the ranges are wide.
- **Stack:** Erlang/OTP 29 with Elixir 1.20, PostgreSQL 17 on the same
  host, `MIX_ENV=prod mix phx.server`, default `POOL_SIZE` (10), logging at `:info`.
- **Data:** one published page with its artifacts fired, so every request is a cache hit.
- **Load:** `ab -k -c 20 -n 30000 -H "Host: localhost"`, after a 3,000-request warm-up.
  Rate limits were raised as described above.
- **How p95 was read:** from `phoenix_router_dispatch_stop_duration` on the exporter,
  using the difference between scrapes. It is origin-side and excludes the client and the
  network.

| Route | Runs | Throughput (req/s) | Server-side p50 | Server-side p95 | Server-side p99 |
|---|---|---|---|---|---|
| `GET /api/content/page/welcome` (fired JSON artifact) | 4 | 6,400–15,300 | 0.6–1.6 ms | **2.7–7.4 ms** | 5.7–16.7 ms |
| `GET /welcome` (HTML, cache hit) | 4 | 3,600–18,000 | 0.8–3.1 ms | **1.7–10.4 ms** | 2.6–23.3 ms |

Both are well inside the 50 ms targets. `GET /api/locales`, which does no database work
and no view tracking, reached 16,000 req/s at a p95 of 1.9 ms, which is roughly the cost of
the endpoint and the `:api` pipeline alone.

The spread tracks the other load on the machine more than anything Kiln did. The delivery
routes also pay for their own side effect: each view writes two upserts from a supervised
task (`KilnCMSWeb.ViewTracking`), and with every request on one document those upserts
contend for the same rows. `repo.query.queue_time` p95 reached 56 ms (API) and 232 ms (HTML) in the runs where it was recorded,
without reaching request latency. The writes are asynchronous, and the task supervisor
sheds them at `max_children`. Under a real spread of documents the contention is lower.

The headless API across a realistic corpus (JSON:API, GraphQL, search, sync;
cold and warm; 1–50 concurrent clients) was measured for #1546 on 2026-09-27:
see [`benchmarks.md`](benchmarks.md), and `scripts/benchmarks/` to rerun it.
Still to measure: the cache-miss HTML path, editor autosave and publish, and
all of it on production-shaped hardware.
