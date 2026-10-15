# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

<a id="propagation-records"></a>

- **Every publish and withdrawal is measured end to end: one propagation
  record per transition, `mix kiln.propagation` for p50/p95, and a telemetry
  event to graph it.** The path forward's first claim, that a correction
  reaches everything a site serves within N seconds, had no N. The webhook
  fan-out now opens a `propagation` record for each `published`,
  `unpublished`, or trashing of a live document, with the number of
  endpoints it was sent to. Each delivery points back at it. The record
  settles once every delivery has a 2xx or has been given up on, and the CDN
  purge (when `KILN_CDN_PURGE_URL` is set) has been acknowledged or has
  failed. Settling stamps the transition-to-last-endpoint and
  transition-to-purge latencies and emits
  `[:kiln_cms, :propagation, :complete]`, summarised in
  `KilnCMSWeb.Telemetry`. `KilnCMS.Propagation.percentiles/2` and
  `mix kiln.propagation` report p50/p95 over a window, counting lost and
  still-open transitions apart. `docs/benchmarks.md` describes the method and
  has the table for the first measurement. A migration adds the
  `propagations` table (pruned after 90 days) and
  `webhook_deliveries.propagation_id`.
  ([#1927](https://github.com/The-Verscienta/kiln_cms/issues/1927))
