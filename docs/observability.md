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

## Blocked addresses

`kiln_cms.ip_block.refused.count` counts requests and socket connects refused by
a site's IP block list ([ip-blocking.md](ip-blocking.md), #2242). It is tagged by
`surface`: `http`, `live`, `gql`, `collab` or `bridge`. The address is deliberately
not a tag, a metadata field or a log line, so the counter says that blocking is
happening and where, not who. The underlying telemetry event is
`[:kiln_cms, :ip_block, :refused]` (measurement `count`, metadata `surface`).

Useful Grafana panel: `sum(rate(kiln_cms_ip_block_refused_count[5m])) by (surface)`.
`kiln_cms.scanner_guard.blocked.count` counts addresses the scanner guard
blocked by itself ([ip-blocking.md](ip-blocking.md#block-scanners-automatically),
#2253), tagged `reason`: `miss_threshold` or `bait_path`. The underlying event is
`[:kiln_cms, :scanner_guard, :blocked]` (measurement `count`, metadata `reason`).
The address is not a tag. A block that is skipped (rule cap, database fault) logs a
warning, `ScannerGuard: block skipped, ...`, without an address.

A rise in the refused counter right after you add a rule is expected. A rise on `http` with no rule
change, or a rule that suddenly matches everyone (a proxy not declared in
`TRUSTED_PROXIES`), is worth a look.

## Admin allowlist refusals

`kiln_cms.admin_allowlist.refused.count` counts requests, LiveView joins and
collaboration connects refused by a site's
[admin allowlist](admin-allowlist.md) (#2248). It is tagged `surface` (`http`,
`api`, `live` or `collab`) and `reason`: `not_listed` (the address is not on
the list) or `unavailable` (the list could not be read, so the gate failed
closed). The address is not a tag. The underlying telemetry event is
`[:kiln_cms, :admin_allowlist, :refused]` (measurement `count`, metadata
`surface` and `reason`).

Useful Grafana panel:
`sum(rate(kiln_cms_admin_allowlist_refused_count[5m])) by (surface, reason)`.

Any sustained `reason="unavailable"` is worth an alert: the console and sign-in
are answering `503` on that site. A burst of `not_listed` right after a save is
someone on a network the list no longer covers; one with no change to the list
can be an admin whose address changed, or a proxy that stopped being trusted.

## Sign-in unlock requests

A request for a [sign-in unlock link](account-administration.md#lift-a-sign-in-pause-by-email)
(#2250) is answered at once and handed to a task under its own supervisor,
`KilnCMS.Accounts.SignInUnlock.TaskSupervisor`, which runs at most 20 at a
time. When it is full, or restarting, the request is dropped: the person was
already shown the usual answer and can ask again. Each drop emits
`[:kiln_cms, :accounts, :sign_in_unlock_shed]` (measurement `count`, always
`1`; no metadata, so no address) and, at most once a minute, logs a warning:

```text
Dropped a sign-in unlock request: the unlock task supervisor is full. Further drops are not logged for a minute.
```

The event is not in `KilnCMSWeb.Telemetry.metrics/0`, so it is not exported
to Prometheus; attach a `:telemetry` handler to count it. Each task looks up
one account and sends at most one mail, so the supervisor fills only under a
flood of requests to `/sign-in/unlock`, which the per-IP `:auth` limit (40 a
minute) already slows. Sustained drops mean a flood from many addresses, or
tasks running slowly because the database is; check both before anything
else.

A request whose task fails logs `Sign-in unlock request failed: <error
module>` or `Sign-in unlock request exited`, at `warning`, and never the
address. A mailed link, a redeemed one and a refused one are recorded in the
site's [security log](security-events.md#what-is-recorded), not as telemetry.

## Delivery client classes

Every request on the `:delivery` rate limit (public pages, `/search`, media
downloads and streams) emits `[:kiln_cms, :delivery, :client_class]` from
`KilnCMSWeb.Plugs.RateLimit`, with measurement `count` (always `1`) and two
metadata fields ([bot-budgets.md](bot-budgets.md), #2243):

- `:class` -- the class the request was **charged** as: `:browser`,
  `:search_engine`, `:ai_crawler`, `:declared_bot` or `:empty`. This is what the
  `User-Agent` claims, except that since #2254 a search-engine claim that DNS
  has proven false is charged, and reported, as `:empty` (see
  [Crawler verification](#crawler-verification)).
- `:result` -- `:allowed`, or `:throttled` when that class's ceiling refused it.

The user agent, the address and the org are deliberately not in the event. It is
exported as the counter `kiln_cms.delivery.client_class.count` (Prometheus:
`kiln_cms_delivery_client_class_count`), tagged `class` and `result`: at most ten
series.

Useful Grafana panel: `sum(rate(kiln_cms_delivery_client_class_count[5m])) by (class, result)`.
It shows the traffic mix, and which classes are being refused. A steady
`declared_bot` or `empty` throttle rate is the feature working. A `search_engine`
throttle rate after a site lowered that class can slow indexing. A sudden
`browser` throttle rate is ordinary flood limiting, as before. Apart from
search-engine claims proven false, the class is only a claim, so read the split
as "what clients say they are". An `empty` series that grows after upgrading to
#2254 may be spoofed search-engine claims; the
`kiln_cms_delivery_unverified_crawler_count{reason="failed"}` series below
separates them.

## Crawler verification

A `:delivery` request whose user agent names a search engine is checked against
DNS (#2254, `KilnCMS.CrawlerVerification`; see
[bot-budgets.md](bot-budgets.md#verified-search-engines)). Three events cover
it. None carries an address, a hostname, a user agent or an org.

| Event | Emitted | Measurements | Metadata |
|---|---|---|---|
| `[:kiln_cms, :delivery, :unverified_crawler]` | by `KilnCMSWeb.Plugs.RateLimit`, once per search-engine request whose claim is not verified | `count` (always `1`) | `engine`, `reason` |
| `[:kiln_cms, :crawler_verification, :lookup]` | once per finished background lookup | `duration` (native units) | `engine`, `result`, `reason` |
| `[:kiln_cms, :crawler_verification, :skipped]` | once per lookup that was not started | `count` (always `1`) | `engine`, `reason` |

- `engine` -- `:google`, `:bing`, `:duckduckgo`, `:baidu`, `:yandex` or
  `:apple`: what the user agent claims.
- `reason` on `unverified_crawler` -- `:failed` (proven false: charged as
  `empty`), `:pending` (a lookup is running or was just started), `:error` (the
  last lookup got no DNS answer), `:skipped` (no lookup could start),
  `:unverifiable` (DuckDuckBot) or `:not_public` (a private or
  `TRUSTED_PROXIES` address, or a forwarding header nothing trusts). Every
  reason but `:failed` keeps the search-engine class, held to the browser
  limit. A verified claim, and every claim while `KILN_CRAWLER_VERIFICATION` is
  off, emits nothing here.
- `result` on `lookup` -- `:verified`, `:rejected`, `:timeout` (the 3-second
  deadline, or the resolver's own timeout) or `:error`. Its `reason` is `nil`,
  the rejection (`:no_ptr`, `:wrong_domain`, `:forward_mismatch`) or the error
  (`:timeout`, `:servfail`, `:refused`, `:formerr`, `:notimp`,
  `:econnrefused`, `:nxdomain`, or `:other`).
- `reason` on `skipped` -- `:busy` (16 lookups already running on this node)
  or `:rate_limited` (the address's network, or the node, used its lookup
  budget for the minute).

Exported metrics (Prometheus names in brackets):

- `kiln_cms.delivery.unverified_crawler.count`, tagged `engine` and `reason`
  (`kiln_cms_delivery_unverified_crawler_count`).
- `kiln_cms.crawler_verification.lookup.count`, tagged `engine` and `result`
  (`kiln_cms_crawler_verification_lookup_count`).
- `kiln_cms.crawler_verification.lookup.duration`, a distribution in
  milliseconds tagged `result`
  (`kiln_cms_crawler_verification_lookup_duration_bucket` / `_sum` / `_count`).
- `kiln_cms.crawler_verification.skipped.count`, tagged `reason`
  (`kiln_cms_crawler_verification_skipped_count`).

Useful panels:

- `sum(rate(kiln_cms_crawler_verification_lookup_count[5m])) by (result)`:
  a real crawler's lookups end `verified`, a spoofer's `rejected`. A steady
  `timeout` or `error` share means the node cannot reach its resolver.
- `sum(rate(kiln_cms_delivery_unverified_crawler_count[5m])) by (reason)`:
  `failed` is spoofed claims being charged as `empty`; a large `not_public`
  share means the node sees a proxy's address (set `TRUSTED_PROXIES`).
- `sum(rate(kiln_cms_crawler_verification_skipped_count[5m])) by (reason)`:
  should be near zero. A steady `busy` rate means lookups are slow.

Two warnings are also logged, each once per node: the first time the
concurrency limit turns a lookup away, and after 20 lookups in a row got no DNS
answer (that one names `KILN_CRAWLER_VERIFICATION=false`).

## Breached-password checks

Every lookup the breached-password check makes (#2240) emits one event,
`[:kiln_cms, :password, :breach_check]`, from
`KilnCMS.Accounts.Changes.CheckBreachedPassword`. Nothing is emitted when the
policy resolves to off (including `BREACHED_PASSWORD_CHECK=false`), and nothing
identifying the password, its hash, the account or the org is ever in the event.

| Event | Fired by | Metadata |
|-------|----------|----------|
| `[:kiln_cms, :password, :breach_check]` | a register, change-password, reset or first-run-setup action, once per lookup | `result`, `action`, `policy`, `enforcement`, `reason` |

- **Measurements:** `:duration` (native units) and `:count` (always `1`).
- `:result` -- `:clean`, `:breached`, or `:error` (could not tell).
- `:action` -- `:register`, `:change`, `:reset` or `:bootstrap`.
- `:policy` -- the policy applied to this account: `:warn` or `:block`.
- `:enforcement` -- `:blocked`, `:warned`, or `:allowed` (clean, or an error: the check fails open).
- `:reason` -- on `:error` only: `:timeout`, `:http_status`, `:transport`,
  `:blocked` or `:malformed`; otherwise `nil`.

A rising share of `result: :error` means the node cannot reach
`api.pwnedpasswords.com` (egress firewall, outage) and passwords are being
accepted unchecked. The counter `kiln_cms.password.breach_check.count`
(tags `result`, `action`, `enforcement`) is defined in
[`KilnCMSWeb.Telemetry.metrics/0`](../lib/kiln_cms_web/telemetry.ex); alert on
the `result="error"` share.

## Human verification

The adaptive sign-in and registration check and the check on public forms
([human-verification.md](human-verification.md), #2249) emit two events. No
address, account, token or anything the provider echoed is ever in either.

| Event | Fired by | Measurements | Metadata |
|-------|----------|--------------|----------|
| `[:kiln_cms, :challenge, :decision]` | `KilnCMS.Challenge.Gate`, once per password sign-in or registration that the check applies to, and once per submission to a form that asks for a check | `count` (always `1`) | `action`, `decision` |
| `[:kiln_cms, :challenge, :verify, :stop]` | `KilnCMS.Challenge.verify/4`, once per token check (only when a check is required) | `duration` (native units) | `provider`, `action`, `result` |

- `:action` -- `:sign_in`, `:register` or `:form`.
- `:decision` -- `:not_required` (under both thresholds), `:passed`,
  `:missing` (a check was required and no token came), `:failed` (the provider
  refused the token), `:fail_open` (the provider could not be asked and the
  attempt was let through) or `:fail_closed` (could not be asked, and this
  sign-in was refused because its address is past `ip_closed_after`).
  Registration is never `:fail_closed`. A `POST /api/auth/sign_in` with
  `CHALLENGE_API_SIGN_IN` off, or anything with the feature off, emits nothing.
- For `action: :form` the decision is what happened to the submission:
  `:passed`; `:failed` (refused, the visitor got the form back); or one of
  the three *held* outcomes, stored in Spam and not acted on: `:missing` (no
  token), `:wrong_host` (solved on a host this deployment does not serve) or
  `:unavailable` (the provider could not be asked). A form never fails open
  or closed. A form that does not ask, a submission with a field error and a
  tripped honeypot emit nothing.
- `:provider` -- the id the operator chose: `"turnstile"`, `"recaptcha"`,
  or a plugin provider's id.
- `:result` -- `:passed`; a refusal: `:missing` and `:malformed` (Kiln's own
  check before the provider is asked), `:invalid`, `:expired`,
  `:hostname_mismatch`, `:action_mismatch`; or why the provider could not be
  asked: `:timeout`, `:transport`, `:http_status`, `:malformed_response`,
  `:not_configured` (the secret is unreadable or the provider rejected it),
  `:crashed`. A provider answering outside its contract is counted
  conservatively: a refusal Kiln does not know is `:invalid`, and any other
  unexpected answer is `:crashed`. With reCAPTCHA a wrong secret shows as
  `:invalid`, not `:not_configured`: Google answers it with the code for a
  bad token.

Metrics, in [`KilnCMSWeb.Telemetry.metrics/0`](../lib/kiln_cms_web/telemetry.ex):

- `kiln_cms.challenge.decision.count`, tagged `action` and `decision`;
- `kiln_cms.challenge.verify.stop.count`, tagged `provider`, `action` and
  `result`;
- `kiln_cms.challenge.verify.stop.duration`, a distribution in milliseconds,
  tagged `provider`.

Useful Grafana panel:
`sum(rate(kiln_cms_challenge_decision_count[5m])) by (action, decision)`.

Alert on a sustained `decision="fail_open"` share: tokens are not being
checked, and sign-ins that needed a check are getting through without one.
On forms, watch `action="form"`: a rise in `unavailable` is the provider
path again (submissions are being held, not admitted), and a steady
`wrong_host` is almost always a headless site whose host is not in
`CHALLENGE_HOSTNAMES`. The log then says "A form submission's
human-verification token was solved on "www.example.org", which this
deployment does not serve; it was held as spam. If that is your own site,
add it to CHALLENGE_HOSTNAMES." at most once a minute per node, naming the
host the provider reported. A high `missing` share on a form usually means a
headless front end is not sending `_kiln_challenge`.
`result="not_configured"` in the verify counter is the secret (wrong or
unreadable); `timeout` or `transport` is the network path to the provider
(`challenges.cloudflare.com` for Turnstile, `www.recaptcha.net` for
reCAPTCHA). With reCAPTCHA, `result="invalid"` on nearly every check, with
no `passed`, points at a wrong secret first. Any `fail_closed` means password sign-in is being
refused for some addresses, and the log says "Human verification is
unavailable (...); refusing password sign-ins from client addresses past the
failure threshold until the provider answers." at most once a minute per node.

Configuration problems are reported at boot through `KilnCMS.Config.Report`
(a log warning and a Sentry message, grouped by source), so a misnamed
provider is visible before anyone signs in:

| Sentry source | When |
|---|---|
| `CHALLENGE_PROVIDER` | `CHALLENGE_PROVIDER` is not a provider id ("CHALLENGE_PROVIDER is set to an unrecognized value ..."), names an id no installed provider answers to ("... but names no installed provider (installed: turnstile, recaptcha) ..."), or names a plugin provider that fails the provider contract ("... does not meet the provider contract: ..."). Human verification is off in all three. |
| `challenge_response_fields` | An installed plugin's provider posts its token under a field the request log does not filter ("A human-verification provider posts its token as ..., which the request log does not filter: add it to config :phoenix, :filter_parameters."). Add it; see [Privacy](human-verification.md#privacy). |

A missing site key or secret is not a boot warning: it is logged ("... has no
site key (CHALLENGE_SITE_KEY) ...") at most once a minute per node, when a
page first asks.

## Security posture checks

Each check on the [Security posture](security-posture.md) page (#2252) emits
an event when it finishes, from `KilnCMS.Security.Posture.Runner`. The events
carry the check's id and outcome, never what it found.

| Event | Fired by | Measurements | Metadata |
|-------|----------|--------------|----------|
| `[:kiln_cms, :security_posture, :check, :stop]` | every check, once per report | `duration` (native units) | `id`, `status`, `error` |
| `[:kiln_cms, :security_posture, :check, :exception]` | a check that raised, threw or exited, in addition to `:stop` | `duration` (native units) | `id`, `kind` |

- `:status` -- `:pass`, `:warn`, `:fail`, `:unknown`, `:n_a`, or `:error`
  when the check produced no result.
- `:error` -- with `status: :error`: `:crashed`, `:timeout`,
  `:invalid_result` or `:busy` (no room under the checks' task supervisor);
  otherwise `nil`.
- `:kind` -- `:error`, `:throw` or `:exit`.

No metric is defined for these by default. A crashed check is also logged,
with its stack trace: "Security posture check `<id>` (`<module>`) failed
with ...". A plugin check the core skips is logged at warning level when the
page runs ("Security posture: ... is not a usable check and is skipped", "...
takes the reserved id ...", "... repeats the id ...").

These events say how the checks ran, not what the site's settings are. To
alert on the posture itself (a line turning **Fix now**), poll
`GET /api/security/posture` with a site administrator's read-only API key:
see [Monitor the posture from a script](security-posture.md#monitor-the-posture-from-a-script)
and the [API guide](api.md#security-posture-monitoring). A run for that
endpoint emits the same events, at most once per site and scope set every
30 seconds on each node.

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
- **`result`, `status`, `surface`, `mode`, `action`, `event` and `class`** are small
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
| `GET /live` | **Liveness** — the Docker `HEALTHCHECK` (restart trigger) probes this | `OK` | 200 iff the endpoint is serving; **no** DB check. 503 until search has warmed up after boot |
| `GET /up` | **Readiness** — for a load balancer / uptime monitor routing traffic | `OK` | 200 if the DB answers `SELECT 1`, else 503. 503 until warm, like `/live` |
| `GET /ready` | Readiness+ — for monitoring/alert sinks | JSON | 200 when the DB is reachable and search is warm, else 503 |

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
  "search": "ok",
  "oban": { "available": 0, "retryable": 0, "backlog": 0 }
}
```

- `db` — `"ok"` when `SELECT 1` succeeds, `"error"` otherwise (drives the 503).
- `search` — `"warming"` from boot until `KilnCMS.Search.Warmup` has run its
  first search through the embedding and reranker servings, then `"ok"` for
  the life of the node (also drives the 503; see *Health endpoints* in
  [`deploy.md`](deploy.md)).
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
