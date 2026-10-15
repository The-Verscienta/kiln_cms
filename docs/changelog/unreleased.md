# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="kilncmsdev-now-publishes-kilns-security-policy-at-security-and-a-security"></a>

- **kilncms.dev now publishes Kiln's security policy at `/security`, and a
  security notice per published GitHub advisory at
  `/security-notices/<ghsa-id>`, with a feed.** A new workflow,
  `publish-security.yml`, runs `scripts/publish_security.exs` daily, when a
  release is published, and when `.github/SECURITY.md` changes on `main`.
  The page is `SECURITY.md`, with its relative links pointed at GitHub, plus
  the list of notices. Each notice is an entry of a `security_notice`
  content type whose custom fields are `package`, `affected_versions`,
  `patched_versions`, `severity`, `advisory_id`, `cve_id`, `published_on`
  and `advisory_url`. `package` is `kiln_cms` for the core and a plugin's
  Hex name for a plugin's notice, so the plugin registry (#1447) can share
  the type and its feed at `/security-notices/feed.xml`. A withdrawn advisory
  is not published, and the script never unpublishes a notice. The type is a
  one-time setup on the site; the script names any field it is missing.
  `SECURITY.md` and the README link to the page and the feed. Nothing
  changes for a self-hosted instance: the script and workflow publish to
  kilncms.dev only. The per-site `security.txt` this issue also asked for
  shipped in 1.1.0 (#1881).
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873))

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
