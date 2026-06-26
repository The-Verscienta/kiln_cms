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
