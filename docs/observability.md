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

## Content-view events

Public content delivery emits one event per recorded page view, so an external
sink can graph read traffic without polling the analytics tables (issue #45).

| Event                              | Fired by                                      | Measurements | Metadata |
|------------------------------------|-----------------------------------------------|--------------|----------|
| `[:kiln_cms, :analytics, :view]`   | `ContentController.track_view/3` on delivery  | `count`      | `type`, `content_id` |

- `:type` — the content type as a string (`"page"`, `"post"`, …).
- `:content_id` — the viewed record's id.

**Metadata is not the same as tag cardinality.** `content_id` is deliberately
*not* a tag on the metric below: one Prometheus series per content item grows
without bound. Keep high-cardinality values in metadata (where a handler can use
them) and tag only low-cardinality dimensions. `org_id` is omitted from this
event entirely — metadata can reach Sentry/OTLP exporters, the same reasoning
that scrubs recipient addresses in [`KilnCMS.Mail`](../lib/kiln_cms/mail.ex).

The event is emitted **before** the database write is dispatched, and the write
is a best-effort supervised task that is shed under load. So this counter tracks
real traffic while the stored counters track what the database absorbed; a
sustained gap between them is a backpressure signal, not a bug.

Useful Grafana panel: `sum(rate(kiln_cms_analytics_view_count[5m])) by (type)`.

Referrer attribution, funnels and export are designed on top of this event but
not built — see [`advanced-analytics-plan.md`](./advanced-analytics-plan.md).

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

> **A `Telemetry.Metrics` entry is not instrumentation.** Until you attach a
> reporter, `metrics/0` has **no consumer in production**: the `live_dashboard`
> route is compiled out with `dev_routes`, the reporter child in
> `KilnCMSWeb.Telemetry.init/1` is commented out, and no
> `telemetry_metrics_prometheus`/`_statsd` dependency is declared — so
> `:telemetry.execute/3` dispatches to an empty handler list. Adding a
> `counter(...)` or `summary(...)` to that list documents an *intent* to
> measure; on its own nothing records it and nothing can alert on it. This is
> not hypothetical: it is why #678 was withdrawn, after its threat-model note
> claimed a refusal counter "can be alerted on" while it was visible nowhere.
>
> Signals that must reach an operator on a stock deployment therefore go
> through `Logger` (stdout, and so the deployment's log viewer) or
> `Sentry.capture_message/2` — see
> [`KilnCMSWeb.TenantRefusalAlert`](../lib/kiln_cms_web/tenant_refusal_alert.ex)
> and [calendar re-query coalescing](#calendar-re-query-coalescing-1336) for the
> two shapes that does take. Note plain `Logger.warning` does **not** reach
> Sentry.

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

## Calendar re-query coalescing (#1336)

`KilnCMSWeb.CalendarLive` collapses a burst of `:calendar_changed` broadcasts
into one window re-query, and emits `[:kiln_cms, :calendar, :requery]` carrying
how many messages each re-query answered. Whether that coalescing actually
holds under production write bursts is [#1336][], and it is a question about a
live deployment rather than about a test.

[`KilnCMS.CMS.CalendarRequeryMonitor`](../lib/kiln_cms/cms/calendar_requery_monitor.ex)
is what makes it readable without a metrics stack: it attaches a real handler
and logs one aggregated line per org per minute, **only when a calendar
actually re-queried** — an idle deployment stays silent.

```
calendar re-query coalescing, last 60s (#1336 — a high re-queries count with
mean near 1 is the drain failing to coalesce):
  org=0000…0001 re-queries=412 messages=498 mean=1.21 max=4
```

Reading it, during a bulk import or a release go-live with a calendar open:

| What you see | What it means |
|---|---|
| `mean` comfortably above 1 | The drain is working — each re-query answered several writes. |
| `mean` near 1 **with a high `re-queries`** | The coalescing is being defeated: it re-queries for one message, and the next write lands immediately after. #1336's failure mode. |
| `mean` 1.0 with `re-queries` of 1–2 | Nothing. A lone editorial change looks exactly like this. |

The pairing matters: the mean alone is not evidence, because a quiet
deployment and a defeated drain both sit at 1.0. It is the *volume* alongside
it that separates them.

Deliberately **no threshold alert**. Choosing "mean below X over Y re-queries
is broken" would bake in a constant picked from argument rather than
measurement — the objection that closed the first attempt at #1336. Read a real
burst first; a threshold belongs in a follow-up informed by those numbers.

Disable with:

```elixir
config :kiln_cms, KilnCMS.CMS.CalendarRequeryMonitor, enabled: false
```

[#1336]: https://github.com/The-Verscienta/kiln_cms/issues/1336

## Health & readiness probes (issue #56)

Three HTTP probes back the container healthcheck and external monitoring:

| Probe | Purpose | Body | Status |
|-------|---------|------|--------|
| `GET /live` | **Liveness** — the Docker `HEALTHCHECK` (restart trigger) probes this | `OK` | 200 iff the endpoint is serving; **no** DB check |
| `GET /up` | **Readiness** — for a load balancer / uptime monitor routing traffic | `OK` | 200 if the DB answers `SELECT 1`, else 503 |
| `GET /ready` | Readiness+ — for monitoring/alert sinks | JSON | 200 when the DB is reachable, else 503 |

**Use `/live`, not `/up`, for anything that RESTARTS the app.** `/up` returns
503 on a database outage, and restarting the app cannot fix an unreachable
database — it only restart-storms the replicas exactly when the platform is
already degraded (#816). `/live` returns 200 while the process is serving,
regardless of the database, so a restart-triggering healthcheck only fires when
the process itself is wedged. `/up` and `/ready` stay DB-coupled on purpose:
that is the signal a load balancer wants when deciding whether to *route* here.

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

## Error tracking (Sentry)

Crashes and unhandled exceptions are reported to [Sentry](https://sentry.io) when
a DSN is configured. **It is a no-op unless `SENTRY_DSN` is set** — dev, test,
and `mix precommit` never reach out, so there is nothing to stub or disable
locally.

Wiring (all gated on the DSN):

- **Capture** — `Sentry.LoggerHandler` is attached in
  [`KilnCMS.Application.setup_observability/0`](../lib/kiln_cms/application.ex)
  only when `SENTRY_DSN` is present. It turns process crashes (with their
  stacktraces) into Sentry events.
- **Request context** — `Sentry.PlugContext` in
  [the endpoint](../lib/kiln_cms_web/endpoint.ex) attaches the request method,
  path, and **scrubbed** headers/params to any event raised while handling a
  request. We deliberately do **not** use `Sentry.PlugCapture`: on Bandit (this
  app's webserver) it double-reports.
- **Background jobs** — Oban job failures are captured via Sentry's built-in
  integration (`config :sentry, integrations: [oban: [capture_errors: true]]` in
  `config/config.exs`).
- **Transport** — the default `Sentry.FinchClient`. Finch is already in the tree
  via Req, so no extra HTTP client (e.g. hackney) is pulled in.
- **Source context** — `mix sentry.package_source_code` runs in the
  [Dockerfile](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile) so stack frames in the Sentry UI show the
  surrounding code.

Environment variables:

| Variable | Effect |
|----------|--------|
| `SENTRY_DSN` | Enables Sentry. Unset = fully disabled. |
| `SENTRY_ENV` | Environment tag (defaults to the `MIX_ENV`, e.g. `prod`). |
| `RELEASE_VSN` | Tags events with the release version (set automatically in a release). |

Send a test event after deploying with `bin/kiln_cms eval "Sentry.capture_message(\"test\")"`.

## Distributed tracing (OpenTelemetry)

Request/query/job spans are exported over OTLP to any OpenTelemetry collector
(Grafana Tempo, Honeycomb, Jaeger, Datadog, etc.). **It is a no-op unless
`OTEL_EXPORTER_OTLP_ENDPOINT` is set** — without it the instrumentation is never
attached and no spans are created, so dev/test/precommit pay nothing.

When enabled (`config/runtime.exs` flips `:otel_enabled` and the exporter on),
[`KilnCMS.Application.setup_observability/0`](../lib/kiln_cms/application.ex)
attaches:

- **`OpentelemetryBandit`** — the root HTTP server span.
- **`OpentelemetryPhoenix`** (`adapter: :bandit`, `liveview: true`) — router
  dispatch and LiveView lifecycle spans, as children of the Bandit span.
- **`OpentelemetryEcto`** (`[:kiln_cms, :repo]`) — a span per DB query. SQL text
  is included (`db_statement: :enabled`); it is safe because Ecto sends values as
  bound parameters rather than inlining them into the statement.
- **`OpentelemetryOban`** — a span per background job, trace-linked to the
  request that enqueued it.

Environment variables (the standard OTel set):

| Variable | Effect |
|----------|--------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector URL, e.g. `http://otel-collector:4318`. Enables tracing. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` (default) or `grpc`. |
| `OTEL_SERVICE_NAME` | Service name in traces (defaults to `kiln_cms`). |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers for hosted collectors, e.g. `x-honeycomb-team=…`. |

Sentry can also act as the tracing backend via its OpenTelemetry span processor;
this wiring keeps traces vendor-neutral (plain OTLP) instead, so the collector
choice stays independent of error tracking.
