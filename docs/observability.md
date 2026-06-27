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
  [Dockerfile](../Dockerfile) so stack frames in the Sentry UI show the
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
