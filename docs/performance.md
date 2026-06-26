# Performance: SLOs, tuning, and load checks

KilnCMS serves public content as **server-rendered HTML** (`KilnCMSWeb.ContentController`)
plus headless **fired artifacts** (`KilnCMSWeb.ArtifactController`). This doc records the
target SLOs, the knobs that hit them, and how to run a basic load check. It complements
[`observability.md`](observability.md) (telemetry events) and the production hardening
checklist in the [README](../README.md).

## SLO targets

| Surface                     | p95 target |
| --------------------------- | ---------- |
| Public HTML — cache **hit** | < 50 ms    |
| Public HTML — cache **miss**| < 250 ms   |
| Editor autosave             | < 500 ms   |
| Publish response            | < 2 s      |

These are origin-side targets (excluding network/CDN). The delivery path is designed so the
**hit** path does no database work — see below.

## How the targets are met

- **Cache-hit delivery does no DB work.** The cached payload carries the record, the
  media-enriched blocks (resolved `srcset`), and the locale `translations` list, so a hit
  issues zero queries (`KilnCMS.Cache`, `ContentController.payload/3`). Hit/miss is emitted
  as `[:kiln_cms, :cache, :content]` telemetry.
- **CDN offload.** Published HTML sends `Cache-Control: public, max-age=60,
  stale-while-revalidate=300`, a content `ETag` (→ `304` on `If-None-Match`), and
  `Vary: Accept-Language`. 404s send `Cache-Control: no-store`. The in-BEAM cache is
  single-node, so a CDN in front is what absorbs a viral spike.
- **Publish returns before firing.** The publish transition enqueues a `Firing.FireWorker`
  (queue `:firing`) instead of rendering 3 surfaces inline, so the publish response isn't
  blocked on firing. Delivery falls back to a live render on miss; the artifact API answers
  `503` + `Retry-After` for the brief window before the artifact lands.
- **Analytics never block or exhaust the pool.** `track_view` and search-query recording run
  on a bounded `Task.Supervisor` (`max_children: 50`); excess best-effort writes are dropped
  under a spike rather than queuing on the DB pool.
- **Bounded editor mounts.** The editor index, media library, content-editor media picker,
  related-content picker, and trash each load at most **500** rows (newest first) per mount.

## Oban queues & pool sizing

Workers are split by workload so a bulk publish or embedding backfill can't starve mail or
the cron publish/purge triggers (`config/config.exs`):

```elixir
queues: [firing: 5, search: 5, mail: 3, media: 3, webhooks: 3, default: 10]
```

| Queue      | Workers                                                |
| ---------- | ----------------------------------------------------- |
| `firing`   | `FireWorker`, `RefireWorker`                           |
| `search`   | `EmbeddingWorker`, `BlockEmbeddingWorker`, `MeilisearchWorker` |
| `mail`     | `WorkflowMailWorker`                                   |
| `media`    | `VariantWorker`                                        |
| `webhooks` | `DeliveryWorker`                                       |
| `default`  | AshOban triggers (scheduled publish, trash purge)      |

**Pool sizing.** Total worker concurrency above is ~29, all sharing the Ecto pool with web
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

Visible in LiveDashboard → Metrics (`/dev/dashboard` in dev) and scrapeable into Prometheus:

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

Watch `kiln_cms.cache.content.count` (should be almost all `hit`), `delivery.render.duration`
p95 against the table above, and `repo.query.queue_time` for pool pressure. For the editor
autosave / publish SLOs, the matching `kiln_cms.editor.*` metrics already exist
(`KilnCMSWeb.EditorTelemetry`).
