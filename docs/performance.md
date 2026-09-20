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
  `Vary: Accept-Language`. 404s send `Cache-Control: no-store`. The in-BEAM cache is
  single-node, so a CDN in front is what absorbs a viral spike.
- **Flushing by hand.** Invalidation is automatic and precise on writes, so a
  manual purge is not part of publishing. For the states precise invalidation
  cannot see — a config change, a template deploy, an external source feeding a
  custom block — there is a **Flush delivery cache** button on `/editor/system`
  (admin-only) and `mix kiln.cache.flush` for local use (#483). Both clear the
  published-record cache *and* the fired-artifact cache: clearing one leaves the
  site serving half-stale. Every request re-reads the database until the caches
  warm again, and on a multi-node deployment the purge reaches **every** node
  (#1138) — the count shown is from the node that served the request. On a
  release use
  `bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"` — the `mix` task boots a
  second node that would clear its own empty caches and start draining
  production Oban queues on the way.
- **Publish returns before firing.** The publish transition enqueues a `Firing.FireWorker`
  (queue `:firing`) instead of rendering every surface inline, so the publish response isn't
  blocked on firing. Delivery falls back to a live render on miss; the artifact API answers
  `503` + `Retry-After` for the brief window before the artifact lands.
- **Analytics never block or exhaust the pool.** `track_view` and search-query recording run
  on a bounded `Task.Supervisor` (`max_children: 50`); excess best-effort writes are dropped
  under a spike rather than queuing on the DB pool.
- **Bounded editor mounts.** The editor index, media library, content-editor media picker,
  related-content picker, and trash each load at most **500** rows (newest first) per mount.

## Oban queues & pool sizing

Workers are split by workload so a bulk publish or embedding backfill can't starve mail or
the cron triggers (`config/config.exs`):

```elixir
queues: [firing: 5, search: 5, mail: 3, media: 3, webhooks: 3, scheduling: 5, default: 10]
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
| `scheduling` | Every-minute AshOban triggers (scheduled publish, scheduled unpublish/embargo) |
| `default`    | Daily AshOban triggers (trash purge, untitled sweep)   |

The `scheduling` queue is isolated because its triggers run on a `* * * * *` cron: if they
share `default` with bulk publish/embedding work, the scheduler and worker jobs can sit queued
longer than their one-minute cadence, drifting scheduled publish/unpublish past their target
time.

The `newsletter` and `billing` queues are isolated for the same reason as `scheduling`, from
the other direction: a large newsletter blast must not starve transactional `mail`, and an
inbound payment webhook must not queue behind one — a delayed entitlement event is a paying
member locked out of what they just bought.

**Pool sizing.** Total worker concurrency above is ~40, all sharing the Ecto pool with web
requests. Size `POOL_SIZE` (in `config/runtime.exs`) so jobs and web requests don't starve
each other:

```
POOL_SIZE ≈ (sum of Oban queue limits that do DB work) + (peak concurrent web DB checkouts)
```

A reasonable production starting point is **`POOL_SIZE=25`** for the default queue config on a
small node, then tune from the `kiln_cms.repo.query.queue_time` metric (rising queue time =
pool too small). Tune individual queue limits per deployment; cap the most bursty (`search`)
lower if embeddings dominate.

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

Still to measure for #1546: the cache-miss HTML path, editor autosave and publish, and
the same runs on production-shaped hardware.
