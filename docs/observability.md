# Observability: editor telemetry & performance profiling

KilnCMS instruments the **editor hot path** with `:telemetry` so the actions that
matter for authoring latency — save, autosave, and the publish workflow — can be
profiled live in LiveDashboard (development) or, with the opt-in exporter
turned on, scraped into Prometheus/Grafana. This is the
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

Referrer attribution, funnels and CSV/JSON export are built (#618–#622), but
not on this event: they read the stored analytics tables, not the telemetry
stream. Referrer attribution is off by default (`KILN_ANALYTICS_REFERRERS`).
See [`advanced-analytics-plan.md`](./advanced-analytics-plan.md).

## Where the metrics go

The matching `Telemetry.Metrics` definitions live in
[`KilnCMSWeb.Telemetry.metrics/0`](../lib/kiln_cms_web/telemetry.ex): a
`distribution` for each duration and a `counter` for each event, tagged by
`kind`/`action`/`result`. They have exactly two consumers, and **a stock
production install has neither**:

| Consumer | Where | When |
|---|---|---|
| LiveDashboard **Metrics** page | <http://localhost:4000/dev/dashboard/metrics> | Development only. The route is compiled out with `dev_routes`, and a `:prod` release refuses to boot with that flag on. In-memory, only while the page is open. |
| Prometheus exporter ([`KilnCMSWeb.Metrics`](../lib/kiln_cms_web/metrics.ex)) | `GET /metrics` on its own port, default `127.0.0.1:9568` | Any environment, **only when `KILN_METRICS_ENABLED` is on** (#1362). Off by default. |

With the exporter off, `:telemetry.execute/3` dispatches to an empty handler
list, exactly as it always has. Adding a `counter(...)` or `distribution(...)`
to the list documents an *intent* to measure; it only becomes a signal on a
deployment whose operator turned the exporter on and scrapes it. This is why #678
was withdrawn: its threat-model note claimed a refusal counter "can be alerted
on" when it was visible nowhere.

So **anything that must reach every operator still goes through `Logger`**
(stdout, so the platform's log viewer) **or `Sentry.capture_message/2`**,
whether or not the exporter is on:

- [`KilnCMSWeb.TenantRefusalAlert`](../lib/kiln_cms_web/tenant_refusal_alert.ex)
- [calendar re-query coalescing](#calendar-re-query-coalescing-1336)
- `KilnCMS.Mail.RelayAlert`

A metric complements those alerts. It never replaces one. Note that plain
`Logger.warning` does **not** reach Sentry.

## Prometheus and Grafana

### Turning it on

```bash
KILN_METRICS_ENABLED=true   # starts the reporter and the listener
KILN_METRICS_PORT=9568      # default
KILN_METRICS_BIND=loopback  # default; `all` for a scraper on a private network
KILN_METRICS_TOKEN=…        # optional; required as `Authorization: Bearer …` when set
```

The exporter is [Peep](https://hexdocs.pm/peep). It aggregates as events
arrive: counters and gauges are kept as numbers, and distributions go into
log-spaced histogram buckets with about 10% relative error. Its memory is set by
the number of series, not by traffic. A node that nobody scrapes does not grow.

### Exposure

A scrape reveals traffic shape, editorial volume and your route table, so
`/metrics` is **not** a route on the public endpoint. It gets its own listener:

- **Nothing to hide at the proxy.** Blocking the path at a reverse proxy or CDN
  would be one more rule to get wrong, and here there is nothing to block.
- **The pipeline is skipped.** A scrape never passes through host-based tenant
  resolution, sessions or rate limiting.
- **Scrapes don't skew the numbers.** A scrape never appears in the `phoenix.*`
  latency it is reporting.

| Deployment | Setting | Why |
|---|---|---|
| Scraper or agent on the same host / in the same pod (Grafana Alloy, a Prometheus sidecar) | `KILN_METRICS_BIND=loopback` (default) | Nothing off-box can reach it. Scrape `127.0.0.1:9568`, not `localhost`, which may resolve to `::1`. |
| Scraper on a private network (docker compose network, Fly 6PN, k8s pod IP) | `KILN_METRICS_BIND=all` | Do **not** publish the port. None of the one-click templates do. On Fly, `[metrics] port = 9568, path = "/metrics"` in `fly.toml` scrapes it over 6PN. |
| Anything that can't be kept off a shared network | `KILN_METRICS_BIND=all` + `KILN_METRICS_TOKEN` | The token is compared in constant time. A missing or wrong token gets `401`. |

`KILN_METRICS_BIND=all` without a token logs a warning at boot rather than
refusing to start. Some platform scrapers (Fly's) cannot send a header, and on
a private network the port itself is the control.

A Prometheus scrape job with a token:

```yaml
scrape_configs:
  - job_name: kiln_cms
    authorization: { type: Bearer, credentials_file: /etc/prometheus/kiln_metrics_token }
    static_configs:
      - targets: ["kiln:9568"]
```

### Names, labels and cardinality

A metric name is its dotted name joined with `_`. For example,
`kiln_cms.editor.save.duration` becomes the histogram
`kiln_cms_editor_save_duration_bucket` / `_sum` / `_count`, in **milliseconds**.
Counters carry no `_total` suffix.

Every label is bounded:

- **No metric carries** an org id, a content id, a user or a slug.
- **`route`** is the router pattern (`/api/content/:type/:slug`), never the
  request path.
- **`queue` and `worker`** are Oban's.
- **`result`, `status`, `surface`, `mode`, `action` and `event`** are small
  enumerations.
- **The content-type label (`type`, `kind`)** keeps a compiled type's name but
  folds every admin-defined type into `dynamic`. Admin-defined types are
  per-org, so on a multi-tenant host they have no ceiling.

`test/kiln_cms_web/metrics_test.exs` rejects an unbounded tag.

### Useful panels

- **Headless API latency, p95 by route:**
  `histogram_quantile(0.95, sum by (le, route) (rate(phoenix_router_dispatch_stop_duration_bucket{route=~"/api/.*"}[5m])))`.
  This is the series behind the SLO table in
  [`performance.md`](performance.md#slo-targets).
- **Editor save latency, p95 by content type:**
  `histogram_quantile(0.95, sum by (le, kind) (rate(kiln_cms_editor_save_duration_bucket[5m])))`.
- **Publish throughput and error rate:** `rate(kiln_cms_editor_publish_count[5m])`, split
  by `result`.
- **Cache hit rate:** `sum(rate(kiln_cms_cache_content_count{result="hit"}[5m])) / sum(rate(kiln_cms_cache_content_count[5m]))`.
- **Pool pressure:** p95 of `kiln_cms_repo_query_queue_time`. When it rises,
  `POOL_SIZE` is too small (see "Oban queues & pool sizing" in [`performance.md`](performance.md)).
- **Oban failures:** `sum by (queue, worker) (rate(oban_job_exception_count[5m]))`.

The same definitions feed LiveDashboard in development, so adding a metric needs
no change to the exporter.

## Calendar re-query coalescing (#1336)

`KilnCMSWeb.CalendarLive` collapses a burst of `:calendar_changed` broadcasts
into one window re-query — the first message arms a fixed 100ms window, the
re-query runs when it closes — and emits `[:kiln_cms, :calendar, :requery]`
carrying how many messages each re-query answered. That window replaced a
`receive ... after 0` mailbox drain, which only coalesced messages already
queued and so re-queried once per write through a sequential bulk import
([#1336][]).

[`KilnCMS.CMS.CalendarRequeryMonitor`](../lib/kiln_cms/cms/calendar_requery_monitor.ex)
is what makes it readable without a metrics stack: it attaches a real handler
and logs one aggregated line per org per minute, **only when a calendar
actually re-queried** — an idle deployment stays silent.

With the [exporter](#prometheus-and-grafana) on, the same event is also the
histogram `kiln_cms_calendar_requery_messages`. It has no labels, so it
aggregates across orgs. The log line stays either way: it is the per-org view,
and it is the one that reaches an operator who doesn't run Prometheus.

```
calendar re-query coalescing, last 60s (#1336 — a high re-queries count with
mean near 1 is coalescing being defeated):
  org=0000…0001 re-queries=412 messages=498 mean=1.21 max=4
```

Reading it, during a bulk import or a release go-live with a calendar open:

| What you see | What it means |
|---|---|
| `mean` comfortably above 1 | Coalescing is working — each re-query answered several writes. |
| `mean` near 1 **with a high `re-queries`** | Coalescing is being defeated: one re-query per write. #1336's failure mode; with the window in place `re-queries` cannot exceed ten a second per open calendar, so seeing this means it regressed. |
| `mean` 1.0 with `re-queries` of 1–2 | Nothing. A lone editorial change looks exactly like this. |

The pairing matters: the mean alone is not evidence, because a quiet
deployment and defeated coalescing both sit at 1.0. It is the *volume* alongside
it that separates them.

Deliberately **no threshold alert**. Choosing "mean below X over Y re-queries
is broken" would bake in a constant picked from argument rather than
measurement. Read a real burst first; a threshold belongs in a follow-up
informed by those numbers.

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

With the [exporter](#prometheus-and-grafana) on, two more come straight from
`/metrics` and need no JSON exporter:

```yaml
- alert: KilnCMSObanJobsFailing
  expr: sum by (queue) (rate(oban_job_exception_count[10m])) > 0.1
  for: 10m
  labels: { severity: warning }
- alert: KilnCMSDbPoolSaturated
  expr: histogram_quantile(0.95, sum by (le) (rate(kiln_cms_repo_query_queue_time_bucket[5m]))) > 50
  for: 10m
  labels: { severity: warning }
```

The thresholds are placeholders. Set them from a week of your own traffic.

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
