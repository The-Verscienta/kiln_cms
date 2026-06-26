# Observability: editor telemetry & performance profiling

KilnCMS instruments the **editor hot path** with `:telemetry` so the actions that
matter for authoring latency — save, autosave, and the publish workflow — can be
profiled live in LiveDashboard or scraped into Prometheus/Grafana. This is the
Phase 6 "Performance profiling and editor Telemetry" work (issue #41).

## Events

All editor events share the `[:kiln_cms, :editor, …]` prefix and are emitted by
[`KilnCMSWeb.EditorTelemetry`](../lib/kiln_cms_web/editor_telemetry.ex), which
wraps the underlying Ash submit/transition with a timing span.

| Event                              | Fired by                              | Metadata |
|------------------------------------|---------------------------------------|----------|
| `[:kiln_cms, :editor, :save]`      | explicit **Save** button              | `kind`, `result` |
| `[:kiln_cms, :editor, :autosave]`  | debounced draft autosave              | `kind`, `result` |
| `[:kiln_cms, :editor, :publish]`   | **publish** workflow transition       | `kind`, `result` |
| `[:kiln_cms, :editor, :workflow]`  | submit / return / unpublish / archive | `kind`, `action`, `result` |

**Measurements** on every event:

- `:duration` — wall-clock of the persisted change in `System.monotonic_time/0`
  native units (rendered as milliseconds by the metrics below).
- `:count` — always `1`, for event counters.

**Metadata:**

- `:kind` — the content type (`:page`, `:post`, or any type generated with
  `mix kiln.gen.content`).
- `:action` — the workflow verb (only on `:workflow` events).
- `:result` — `:ok` or `:error`, derived from the action's return tuple, so you
  can split success from failure latency and alert on error rate.

## LiveDashboard panel

The matching `Telemetry.Metrics` definitions live in
[`KilnCMSWeb.Telemetry.metrics/0`](../lib/kiln_cms_web/telemetry.ex) (a `summary`
for duration + a `counter` per event, tagged by `kind`/`action`/`result`). They
surface automatically on the LiveDashboard **Metrics** page under the
`kiln_cms.editor.*` group:

- `dev`: <http://localhost:4000/dev/dashboard/metrics> (`:dev_routes` gate).
- `prod`: mount `live_dashboard` behind admin auth (see the commented guidance in
  `router.ex`) and read it there.

LiveDashboard keeps the series in memory only while the page is open — fine for
spot-profiling a slow save, but not for historical trends. For that, export to
Prometheus.

## Prometheus / Grafana path

For persistent dashboards and alerting, attach a Prometheus reporter and point
Grafana at it:

1. Add `{:telemetry_metrics_prometheus, "~> 1.1"}` to `mix.exs`.
2. Start it as a child in `KilnCMSWeb.Telemetry.init/1`, reusing the existing
   metric list so editor metrics are exported with no duplication:

   ```elixir
   children = [
     {TelemetryMetricsPrometheus, metrics: metrics()},
     {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
   ]
   ```

   This serves `/metrics` on port `9568` by default (keep it on an internal
   interface / behind auth).
3. Scrape it from Prometheus and graph in Grafana. Useful panels:
   - `histogram_quantile(0.95, kiln_cms_editor_save_duration_milliseconds_bucket)`
     — p95 save latency, broken down by `kind`.
   - `rate(kiln_cms_editor_publish_count[5m])` split by `result` — publish
     throughput and error rate.
   - Compare `autosave` vs `save` duration to watch the debounced background path
     against explicit saves.

The same metric definitions feed both LiveDashboard and Prometheus, so adding the
reporter needs no change to the event-emitting code.

## Health & readiness probes (issue #56)

Two HTTP probes back the platform healthcheck and external monitoring:

| Probe | Purpose | Body | Status |
|-------|---------|------|--------|
| `GET /up` | Liveness — used by the Coolify/LB healthcheck | `OK` | 200 if the DB answers `SELECT 1`, else 503 |
| `GET /ready` | Readiness — for monitoring/alert sinks | JSON | 200 when the DB is reachable, else 503 |

`/ready` returns a machine-readable snapshot:

```json
{
  "status": "ok",
  "db": "ok",
  "oban": { "available": 0, "retryable": 0, "backlog": 0 }
}
```

- `db` — `"ok"` when `SELECT 1` succeeds, `"error"` otherwise (drives the 503).
- `oban.available` / `oban.retryable` — jobs queued to run now or awaiting a
  retry; `backlog` is their sum. Counted straight from `oban_jobs`, so the probe
  works without any Oban Pro/Met dependency.

Both probes live in
[`KilnCMSWeb.HealthController`](../lib/kiln_cms_web/controllers/health_controller.ex).

### Alert rules

Point an uptime monitor and/or Prometheus blackbox/JSON exporter at these and
alert on:

- **Database connectivity** — `GET /up` returns non-200 for > 1 min, **or**
  `/ready` reports `db != "ok"`. Page immediately: the app cannot serve content.
- **Oban queue depth** — `/ready` `oban.backlog` stays above a threshold
  (e.g. > 100 jobs for > 5 min). A climbing backlog means workers can't keep up,
  so emails, webhooks, search indexing, and image variants fall behind. Warn at
  100, page at 1000 (tune to traffic).
- **Readiness flapping** — repeated `/ready` 503s indicate an unstable DB
  connection (pool exhaustion, failover) even when liveness recovers.

A minimal Prometheus rule sketch (via a JSON exporter scraping `/ready`):

```yaml
- alert: KilnCMSDatabaseDown
  expr: probe_success{job="kiln_cms_ready"} == 0
  for: 1m
  labels: { severity: critical }
- alert: KilnCMSObanBacklogHigh
  expr: kiln_cms_oban_backlog > 1000
  for: 5m
  labels: { severity: warning }
```
