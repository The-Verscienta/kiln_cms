# Environment variables

This is the canonical list of every environment variable KilnCMS reads, grouped
by whether it is **required** or **optional**, with a pointer to where each one is
consumed. Unless noted otherwise, variables are read at boot in
[`config/runtime.exs`](../config/runtime.exs), which executes for releases after
compilation and before the system starts.

> **Scope.** Most variables only take effect when `config_env() == :prod` (i.e. in
> a `mix release` / `MIX_ENV=prod` build). In dev and test, sensible defaults from
> `config/dev.exs` and `config/test.exs` are used instead, so you do not need to
> set these locally. The exceptions — read in *every* environment, because they
> sit outside the `if config_env() == :prod` block in `runtime.exs` — are:
>
> `PHX_SERVER`, `PORT`, `CSP_IMG_SRC`, `UNSPLASH_ACCESS_KEY`, `CORS_ORIGINS`,
> `KILN_READING_TIME_WPM`, `VISUAL_EDITING_ENABLED`, `KILN_LINK_CHECK_CRON` /
> `KILN_LINK_CHECK_USER_AGENT`, `KILN_TASK_DIGEST_CRON`,
> `KILN_OCCURRENCE_SWEEP_CRON` / `KILN_OCCURRENCE_BACKFILL_ON_BOOT`,
> `PRESENTATION_PREVIEW_URL`, the `KILN_UPDATE_*`
> group (plus `KILN_PIN_PATH`), `KILN_ANALYTICS_REFERRERS`,
> `KILN_ANALYTICS_LOW_COUNT_THRESHOLD`, `SENTRY_DSN` / `SENTRY_ENV` /
> `RELEASE_VSN`, and the `OTEL_*` group.
>
> Several more are read in every environment **except `:test`**, where they are
> skipped so the suite cannot depend on a developer's exported shell:
> `KILN_ENV_LABEL` / `KILN_ENV_COLOR`, `EMBED_ORIGINS` / `EMBED_ORIGINS_LOCKED`,
> `KILN_AUDIT_ANCHORS_ENABLED`, `KILN_AUDIT_ANCHOR_EVERY_WRITE`, the
> `KILN_GOVERNANCE_WITNESS*` group (plus `KILN_GOVERNANCE_CHECKPOINT_CRON`), and
> the `KILN_PROVENANCE_*` group. `MIX_TEST_PARTITION` and `KILN_STRICT_TEST`
> are the reverse — test-only.

## On/off variables

Every boolean variable in this document is parsed by one shared function,
[`KilnCMS.Config.Env`](../lib/kiln_cms/config/env.ex), so the rules below hold
for all of them (`PHX_SERVER` is a partial exception — see its row):

* **Accepted spellings.** `true` / `1` / `yes` / `on` and `false` / `0` / `no` /
  `off`. Values are trimmed and lower-cased first, so `TRUE`, `On` and
  `" true "` all work.
* **Unset or blank** (`FOO=`, a common `.env` and `--env-file` artifact) means
  the variable was not set — the default in the table applies.
* **Anything else keeps the default and warns.** A misspelling is never
  *interpreted* — it cannot flip a flag in either direction. For the switches
  that default to on (`DATABASE_SSL`, `SMTP_TLS`, `SMTP_TLS_VERIFY`) that means
  a typo can no longer turn TLS off, which is the whole point of #606. For a
  switch that defaults to **off**, the flip side holds: a typo leaves it off, so
  if you set `KILN_AUDIT_ANCHOR_EVERY_WRITE` to turn signing *on*, the warning
  is the only signal that it didn't take.

### Where that warning goes

Two places, because one of them is not enough (#634):

* **stderr, at boot.** Config providers run before `Logger` exists, so this is
  all that is available at the moment the value is read. In a release it lands
  in container stdout — `docker logs` — and is forwarded nowhere. If it scrolls
  past during a deploy it is gone.
* **`Logger`, once the application is up**, at `warning` level. Every
  unrecognized read is carried out of `config/runtime.exs` in
  `:kiln_cms, :config_warnings` and replayed as soon as observability is
  attached, so it goes through the normal logging pipeline — formatted,
  timestamped, and picked up by whatever collects the application's output.
* **Sentry**, as a `warning`-level message, when `SENTRY_DSN` is set. This is
  reported explicitly rather than left to the log line: Sentry's logger handler
  runs at `level: :error` with `capture_log_messages: false`, so a
  `Logger.warning` never reaches it. Issues are grouped per variable, so a flag
  that stays misspelled is one issue rather than a new one on every restart.

Only variables that hold a **flag**, a **count**, or a short constrained value
like an enum spelling or a colour go through this. Nothing here echoes a
credential; a variable carrying a secret is read elsewhere and its value is
never logged.

Until #607 each variable had its own parser, and two of them matched the raw
string: `DATABASE_SSL=True` silently gave you a **plaintext** Postgres
connection (#606), and `VISUAL_EDITING_ENABLED=False` left the bridge on.

## Count variables

The variables that hold a **positive integer** — `KILN_READING_TIME_WPM`,
`KILN_ANALYTICS_LOW_COUNT_THRESHOLD`, `KILN_EXPERIMENTS_STICKY_DAYS`,
`BACKUP_KEEP_DAYS` and `BACKUP_STALE_AFTER_HOURS` — go through the same module,
as `Env.positive_integer/1` (#1009). Before that each had hand-rolled its own
`Integer.parse`, its own positivity check and its own warning.

* **Unset or blank** (including whitespace-only) means the variable was not set,
  exactly as for a flag — the default in the table applies, silently.
* **Zero and negatives are refused**, not read literally. Every one of these is
  a rate, a window or a retention, where `0` reads as "never" or "delete
  everything" rather than as "unset": `BACKUP_KEEP_DAYS=0` taken at face value
  would delete the backup it had just taken.
* **A partly-numeric value is refused, not truncated.** `BACKUP_KEEP_DAYS=7 days`
  keeps the default rather than quietly becoming 7 — the operator meant a week
  and would otherwise never learn the unit was wrong.
* **Anything above 2147483647 is refused** (#1091). Elixir integers have no
  upper bound, so without this a *digit* slip was accepted where a *letter* slip
  warned — `BACKUP_KEEP_DAYS=144444444444444` parsed cleanly into a
  four-billion-year retention. The ceiling is not a claim about a sensible
  value; every real one here is smaller by orders of magnitude, so what it
  catches is a typo.
* **Anything refused keeps the default and warns**, through all three sinks
  above. The count case is what #1009 added to that replay: the hand-rolled
  parsers wrote to stderr and stopped there, so a mistyped count reached neither
  `Logger` nor Sentry. The replayed line names the shape it wanted — a count is
  told to write a positive integer, not offered the boolean spellings.

## Required (production)

These must be set when running a production release. Missing `DATABASE_URL`,
`SECRET_KEY_BASE`, or `TOKEN_SIGNING_SECRET` will **raise on boot**.

| Variable | Purpose | Where it's read |
|----------|---------|-----------------|
| `PHX_SERVER` | Set to start the web server in a release; without it the release boots but does not serve HTTP. The generated `bin/server` script sets this for you. **Presence-checked, not parsed** — the partial exception to the on/off rules above. *Any* value starts the server, including a blank `PHX_SERVER=` and an unrecognized one, because Phoenix documents this as "any truthy value" and reading a declared-but-empty variable as "serve nothing" is a silent outage. The one rule it does honour is the off-spellings: `false`/`0`/`no`/`off` keep the server off, where they used to start it anyway. | [`config/runtime.exs:65`](../config/runtime.exs#L65) |
| `DATABASE_URL` | Postgres connection string, e.g. `ecto://USER:PASS@HOST/DATABASE`. Raises if missing. | [`config/runtime.exs:706`](../config/runtime.exs#L706) |
| `SECRET_KEY_BASE` | Signs/encrypts session cookies and other secrets. Generate with `mix phx.gen.secret`. Raises if missing. | [`config/runtime.exs:759`](../config/runtime.exs#L759) |
| `TOKEN_SIGNING_SECRET` | Signs authentication tokens (AshAuthentication). Raises if missing. | [`config/runtime.exs:951`](../config/runtime.exs#L951) |
| `PHX_HOST` | Public hostname used to generate URLs and validate socket origins (defaults to `example.com`, so effectively required — wrong values break links, emails, **and LiveView socket connections**). Bare hostname; any `https://` prefix or trailing `/` is stripped. | [`config/runtime.exs:772`](../config/runtime.exs#L772) |

## Optional — server & networking

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `PORT` | `4000` | HTTP listen port the Bandit server binds to. | [`config/runtime.exs:70`](../config/runtime.exs#L70) |
| `CHECK_ORIGINS` | unset | Comma-separated **extra** origins allowed to open LiveView/channel sockets, for when the app is served from more than one hostname (e.g. mid domain migration). Entries may be full origins (`https://cms.example.com`), scheme-less (`//cms.example.com` — any scheme/port), or bare hosts (normalized to `//host`). The `PHX_HOST` origin is always allowed. Unset ⇒ only `PHX_HOST` may connect. | [`config/runtime.exs:785`](../config/runtime.exs#L785) |
| `CORS_ORIGINS` | unset | Comma-separated allowlist (or `*`) of origins allowed cross-origin **HTTP** reads of the headless API (`/api/*`, `/gql`). Read in every environment; without it prod stays same-origin-only. Does not affect sockets — that's `CHECK_ORIGINS`. See [`KilnCMSWeb.CORS`](../lib/kiln_cms_web/cors.ex). | [`config/runtime.exs:156`](../config/runtime.exs#L156) |
| `EMBED_ORIGINS` | unset ⇒ same-origin only | Comma-separated allowlist of sites permitted to **iframe** an embeddable form (`/forms/:slug/embed`) — sets that page's CSP `frame-ancestors`. **Unset (or blank) means same-origin only, so cross-site embedding is off until you set it** (#562 — the default used to be `*`). `*` re-opens it to any site; that is a clickjacking surface, since form submission is deliberately CSRF-free. This is the **default** for forms that do not set their own allowlist in the builder's Embed tab; on a multi-org deployment set it there instead, or this variable has to be the union of every org's embedders and every org's forms become framable by all of them (#648). See [`KilnCMSWeb.Embed`](../lib/kiln_cms_web/embed.ex) and [forms.md](forms.md#embedding-on-another-site). | [`config/runtime.exs:168`](../config/runtime.exs#L168) |
| `EMBED_ORIGINS_LOCKED` | `false` | Set to `true`/`1`/`yes`/`on` to make `EMBED_ORIGINS` a **ceiling** as well as a default (#1133): a form's or an org's own embed allowlist (#648, #1131) may narrow it but not reach outside it — an admin's write naming an origin the ceiling does not cover is refused (naming the entry, never the ceiling), and the served `frame-ancestors` is clamped to it, so a list saved before the cap was turned on takes no effect beyond it. Off, the #1130/#1131 behaviour is unchanged. `EMBED_ORIGINS=*` under the cap is a ceiling of everything; `EMBED_ORIGINS` unset under it closes cross-site framing deployment-wide. Parsed by the shared [on/off rules](#onoff-variables). See [`KilnCMS.Forms.EmbedCeiling`](../lib/kiln_cms/forms/embed_ceiling.ex). | [`config/runtime.exs:177`](../config/runtime.exs#L177) |
| `VISUAL_EDITING_ENABLED` | `true` | Set to an off-spelling to disable the visual-editing bridge (#355): the annotated preview route (`/api/visual-editing/:type/:slug`) 404s and the live-preview socket (`/ws/bridge`) refuses. Which origins may use the bridge (annotated read, write API, socket) is governed by **`CORS_ORIGINS`** — the bridge is cross-origin *to a different app*, so it uses that allowlist, not `CHECK_ORIGINS` (same-app extra hosts). See [visual-editing-bridge.md](visual-editing-bridge.md) and [`KilnCMS.VisualEditing`](../lib/kiln_cms/visual_editing.ex). | [`config/runtime.exs:201`](../config/runtime.exs#L201) |
| `REQUIRE_AV_METADATA_STRIP` | `false` | Refuse a video or audio upload whose container metadata could not be stripped, instead of storing it as it arrived and logging a warning (#820). An MP4 off a phone carries GPS coordinates, device model and OS version, and a local wall-clock creation date; Kiln remuxes those away with `ffmpeg -map_metadata -1` when ffmpeg is present. **Only set this to `true` on a host that has ffmpeg** — without it, every A/V upload is refused. Off by default because flipping it for existing deployments would be exactly that outage, silently, on upgrade; see the guarantee table in [media-pipeline.md](media-pipeline.md). One case ignores this setting: an upload that cannot be stripped because the temp filesystem is out of space is refused either way (#1100), since that failure is transient and retrying works. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_CONSOLE_HOST` | unset | Serve the editor console from this host and only this host (#740): console routes on any other host redirect here (`GET`) or 404, and tenant content is never served here (the bare host goes to `/editor`); shared routes — sign-in/account, the headless APIs, previews, media download/stream, probes — serve on both. Which routes are which is `KilnCMSWeb.Surface`, pinned by a test. Add this host to `CHECK_ORIGINS`. Org resolution is host-derived, so this host is the **default org's** console (never refused, even under `TENANT_STRICT_HOST`) — a single-org deployment's fit; see [code-injection.md](code-injection.md#read-this-before-granting-the-role). | [`config/runtime.exs:214`](../config/runtime.exs#L214) |
| `KILN_AV_STRIP_MODE` | `sync` | `deferred` moves the A/V metadata strip off the upload request (#1122): the upload is staged to **private** storage as a quarantined `MediaItem` — invisible to every non-editor read (policy, not a UI filter), a 404 on `/media/:id/download` and `/stream`, its public `url` pointing at nothing — and `KilnCMS.Media.AVStripWorker` strips, promotes the stripped copy to the public key, releases the quarantine and only then enqueues derivation. Needs private storage (the Local adapter always has it; S3 needs a private bucket) and falls back to `sync` with a one-time warning otherwise. `sync` is the bounded synchronous path (#1112). Failure outcomes and `REQUIRE_AV_METADATA_STRIP` apply the same, one step later. See [media-pipeline.md](media-pipeline.md#the-deferred-strip-behind-a-quarantine-1122). | [`config/runtime.exs:243`](../config/runtime.exs#L243) |
| `KILN_MEDIA_QUARANTINE_REAPER_CRON` | `20 * * * *` | When `KilnCMS.Media.QuarantineReaper` runs (#1122): removes quarantined uploads whose deferred strip never completed — private blob deleted, row purged — once older than `KILN_MEDIA_QUARANTINE_MAX_AGE_HOURS`. `false` disables the schedule. | [`config/runtime.exs:252`](../config/runtime.exs#L252) |
| `KILN_MEDIA_QUARANTINE_MAX_AGE_HOURS` | `24` | How long a quarantined upload may wait for its strip before the reaper removes it (#1122). Generous on purpose: the failure it exists for is "stuck", not "slow". Positive integer. | [`config/runtime.exs:256`](../config/runtime.exs#L256) |
| `PRESENTATION_PREVIEW_URL` | unset | The external front end's URL template for the Presentation console (`/editor/presentation/:type/:slug`, #355) — placeholders `{path}`/`{type}`/`{slug}`/`{locale}` (a bare base URL gets `{path}` appended). Unset ⇒ the console shows a setup hint. The front-end origin is derived from this for `postMessage` validation. See [visual-editing-bridge.md](visual-editing-bridge.md#the-presentation-console-side-by-side-editing) and [`KilnCMSWeb.Presentation`](../lib/kiln_cms_web/presentation.ex). | [`config/runtime.exs:602`](../config/runtime.exs#L602) |
| `POOL_SIZE` | `10` | Ecto database connection pool size. See the pool-sizing formula in [`docs/performance.md`](performance.md). | [`config/runtime.exs:746`](../config/runtime.exs#L746) |
| `ECTO_IPV6` | unset | Set to an on-spelling to connect to Postgres over IPv6. | [`config/runtime.exs:712`](../config/runtime.exs#L712) |
| `TRUSTED_PROXIES` | unset | Comma-separated reverse-proxy CIDRs (e.g. `10.0.0.0/8,172.16.0.0/12`). When set, `KilnCMSWeb.Plugs.ClientIp` rewrites `remote_ip` from `X-Forwarded-For` for rate limiting. Leave unset **only** when the app is internet-facing directly, where `X-Forwarded-For` is spoofable. **If you run behind a proxy — Coolify, Traefik, nginx, a cloud load balancer — set this.** Unset there, every request carries the proxy's address, so every rate-limit bucket becomes one shared counter for the whole internet: one noisy client exhausts `:auth` (40/min) for everybody, and the per-IP brute-force protection on `/sign-in` stops being per-IP. Nothing errors, so the app logs a warning once per node the first time a forwarded request arrives while this is unset (#564). Note the CIDRs name **which hops to skip while walking the forwarded chain**, not which peers are allowed to forward — once this is set at all, `X-Forwarded-For` is honoured whatever address the request arrives from, so set it only on a deployment that really is behind a proxy. And **every private range is skipped regardless** (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `::1`, `fc00::/7`), so listing those has no effect on the chain — its only job there is flipping the honour-the-header switch. If your proxy has a **public** address (a cloud load balancer), you must list *its* CIDR or the app will key every bucket on the balancer instead of the client. The same rule serves `/live` handshakes through `ClientIp.resolve/2`, so a socket keys the bucket on the same client its HTTP request would have (#715, #934). | [`config/runtime.exs:824`](../config/runtime.exs#L824) |
| `DNS_CLUSTER_QUERY` | unset | DNS query for libcluster-style node discovery. | [`config/runtime.exs:812`](../config/runtime.exs#L812) |
| `KILN_READING_TIME_WPM` | `230` | Words per minute behind the `reading_time_minutes` calculation and the `reading_time()` computed-field function (#492). A non-positive or unparseable value keeps the default and warns on stderr. 230 is a mid-range figure for adult silent reading of English prose; a single rate is an English assumption, so see the caveat in [headless-consumer-guide.md](headless-consumer-guide.md#word-count-and-reading-time). | [`config/runtime.exs:187`](../config/runtime.exs#L187) |
| `CSP_IMG_SRC` | unset | Space-separated **extra** origins allowed in the browser CSP's `img-src` **and `media-src`** (#494) — needed when media serves from a CDN or media host on a different hostname than the site (e.g. `https://media.example.com`). Without it, `default-src 'self'` blocks a cross-host `<video>` as well as a cross-host `<img>`. See [media-pipeline.md](media-pipeline.md#production-storage--cdn). | [`config/runtime.exs:76`](../config/runtime.exs#L76) |

> **Note on ports.** The public URL is hardcoded to port `443`/`https`
> ([`config/runtime.exs:938`](../config/runtime.exs#L938)); the app itself listens
> on `PORT`. The expected topology is a TLS-terminating reverse proxy on 443
> forwarding to the app on `PORT`.

## Optional — API documentation (#567)

The OpenAPI 3 document and the Swagger UI explorer over it. Served in dev and
test; **off in a production build**, for the reason GraphQL introspection is —
since #330 the described surface includes the write routes, so the document is
a complete machine-readable map of the mutation API. It grants nothing (the Ash
policies and the API key's scope still enforce every route), but it removes the
guesswork.

Disabled, both paths answer **404** rather than 403: a 403 confirms the route
exists and is merely closed.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `API_DOCS_ENABLED` | on outside prod, **off in prod** | Serve `GET /api/json/open_api` and `GET /api/json/swaggerui`. Turn it on for a deployment that publishes a public API. | [`config/runtime.exs:855`](../config/runtime.exs#L855) |

## Optional — multi-tenancy (#336)

One deployment can serve many organizations, each on its own host. The request's
`Host` picks the org: a subdomain of `TENANT_BASE_HOST` (`acme.example.com` → org
`acme`), else an exact `custom_domain` on an org, else the default org. See
[`KilnCMSWeb.Tenant`](../lib/kiln_cms_web/tenant.ex).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `TENANT_BASE_HOST` | `PHX_HOST` | The apex tenant subdomains are carved from. Set it only when tenant subdomains live under a different apex than the canonical URL host. | [`config/runtime.exs:834`](../config/runtime.exs#L834) |
| `TENANT_STRICT_HOST` | `false` | Reject a request whose `Host` matches no org (404) instead of serving it the **default org**. **Recommended for every multi-tenant deployment** (#563) — without it a bare hostname, an IP literal, `localhost` or an attacker-supplied `Host` is served the default site's content, branding and analytics. Leave it off for a single-host install, where the bare host and an IP legitimately arrive unmatched and would start 404ing. Kiln tells you three ways if it is off on a deployment with more than one org (#660): a warning at boot, a warning when the *second* organization is created — the create that makes the Host header start deciding which site a request gets — and a standing notice on `/editor/system` for every org after that. | [`config/runtime.exs:847`](../config/runtime.exs#L847) |

**What it covers.** Everything the router serves, plus LiveView mounts and all
three sockets — GraphQL (`/ws/gql`), visual editing (`/ws/bridge`) and
collaborative editing (`/ws/collab`, since #655) — each resolving its tenant
from its own connect URI and refusing rather than falling back. One thing sits
outside it, and it performs no org-scoped reads:

- **Static files**, including `/uploads` under the local storage adapter. Both
  `Plug.Static` mounts run earlier in the endpoint and halt on a match, so an
  asset URL answers on any `Host`. Keys are unguessable UUIDs, and putting
  tenant resolution ahead of static would add two DB lookups to every asset
  request; treat media URLs as host-agnostic, as they would be behind a CDN.

**What stays reachable.** Two controllers are exempt, because both are
deliberately host-independent and neither reads the ambient tenant:

- **The liveness and readiness probes** (`/up`, `/ready`), so a load balancer or
  orchestrator sending the container's IP as `Host` keeps getting a 200 —
  turning this on will not mark a healthy deployment unhealthy.
- **The payment-provider webhook** (`POST /billing/webhooks/stripe`), which
  arrives at whatever host the endpoint was registered with, is authorized by an
  HMAC over the raw body, and resolves its organization from the event payload.

The exemption keys on the controller, not on a path list, so it tracks the
router.

> **Before turning it on**, confirm every host that must reach the app is
> accounted for: each org's subdomain or `custom_domain`, and the `PHX_HOST`
> apex itself (it resolves to the default org, and is never refused even if the
> database is briefly unreachable). Anything else now gets a 404.

**404 means "no such host"; a database outage gets a 503** (#341). A host that
could not be *looked up* is a different answer from one that matches no org, and
Kiln keeps them apart:

- With `TENANT_STRICT_HOST` **off** — the default, and the whole single-host
  install — a failed lookup falls back to the default org exactly as an
  unmatched host does. Nothing is refused in this mode, including during an
  outage, which is what lets warm content keep being served from cache without a
  database (#341): tenant resolution runs in the endpoint, *above* the cache.
- With it **on**, an unresolvable host is still refused (falling back would serve
  the default org on an unrecognized host, which is what this setting exists to
  prevent), but as a plain-text `503` with `retry-after`, not a `404`. The host
  may well exist; a 404 is what a CDN caches, an uptime monitor pages the tenant
  about, and a search engine deindexes on. The health-probe and webhook
  exemptions above apply to this refusal too.

**The refusal no longer costs a query every time** (#659). A refused request is
halted before the router, and every rate limiter lives in a router pipeline — so
turning this on originally took the path out of the `:delivery` ceiling and left
one uncached organization lookup per request, metered by nothing. Unresolvable
hosts are now cached as misses, in a cache of their own (`KilnCMS.Cache.Hosts`,
one-minute negative TTL) so that a flood of invented hosts cannot evict hot
published pages the way it would have in the shared content cache. A repeated
flood costs one lookup per distinct host per minute rather than one per request;
a flood of *distinct* hosts still costs a lookup each, which is the price of
never refusing a host that does exist. Terminate unknown hosts at the proxy if
that load matters. As a side effect, tenant resolution no longer evaporates when
an editor saves a media item — it used to live in the cache that a content bust
clears wholesale.

**What the refusal reveals.** An unknown host gets a plain-text 404; a known
host with an unmatched path gets the branded HTML 404. The two are
distinguishable, so a dictionary sweep of `<candidate>.<base host>` will
enumerate which org slugs exist, and which `custom_domain`s are configured. This
is accepted rather than fixed: making them identical means either showing
unknown hosts the branded page — the default-org leak this control exists to
prevent — or degrading every tenant's real 404 to plain text, to hide names that
are already public in DNS and in TLS certificates. If your tenant list is itself
confidential, terminate unknown hosts at the proxy, where one uniform response
covers both cases.

## Optional — white-label branding (#48)

The instance-wide branding layer, beneath each site's own editor-managed
`SiteBranding` row — a per-org row always wins, so these set the fallback every
org inherits until it overrides them. Unset vars fall through to the stock
KilnCMS defaults. All four are read only under `:prod`; for dev or test, set
`config :kiln_cms, :branding, …` in a config file. See
[`KilnCMS.Branding`](../lib/kiln_cms/branding.ex).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `SITE_NAME` | `KilnCMS` | Instance name in the admin chrome, page titles and outbound email. Also the default provenance `signer` identity when `KilnCMS.Provenance`'s `:signer` is unset. | [`config/runtime.exs:906`](../config/runtime.exs#L906) |
| `BRAND_LOGO_URL` | unset | Logo shown in the admin chrome and on branded error pages. If the host differs from the site's origin it must also be in `CSP_IMG_SRC`, or the browser blocks the image. | [`config/runtime.exs:913`](../config/runtime.exs#L913) |
| `BRAND_FAVICON_URL` | unset | Favicon URL. Same `CSP_IMG_SRC` caveat as the logo. | [`config/runtime.exs:920`](../config/runtime.exs#L920) |
| `BRAND_PRIMARY_COLOR` | unset | Hex colour driving the emitted OKLCH theme tokens — `#1d4ed8` or the `#1d4` shorthand, stored in canonical long lowercase form. Anything else is **ignored with a warning** rather than interpreted, since the value feeds contrast computation. Validated at boot alongside every other variable here, so a bad value reaches `Logger` and Sentry and not just container stdout (#1089); before that it was checked only at render time, where a bare `Logger.warning` never reaches Sentry. | [`config/runtime.exs:873`](../config/runtime.exs#L873) |

## Optional — Unsplash (media library)

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `UNSPLASH_ACCESS_KEY` | unset | The Unsplash API **Access Key** (not the secret key, which this never needs). Setting it adds the Unsplash tab to the media library, where an editor can search and import stock photos; unset, the tab never renders and no request reaches Unsplash. Read in every environment. **Where to get it:** register an application at [unsplash.com/oauth/applications](https://unsplash.com/oauth/applications). A new app is in Demo mode (50 requests/hour) — enough to evaluate the tab, but production traffic needs Unsplash to approve the application. | [`config/runtime.exs:82`](../config/runtime.exs#L82) |

## Optional — database TLS

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `DATABASE_SSL` | `true` | Encrypt the Postgres connection. Set to an off-spelling only for a provider that genuinely cannot offer TLS — an unrecognized value keeps TLS on rather than silently downgrading to plaintext (#606). | [`config/runtime.exs:723`](../config/runtime.exs#L723) |
| `DATABASE_SSL_CACERTFILE` | unset | Path to the provider's CA bundle. When set, the server cert is verified (`verify_peer`); unset — or blank, like every variable above — leaves the connection encrypted but `verify_none`. | [`config/runtime.exs:731`](../config/runtime.exs#L731) |

## Optional — object storage (S3-compatible)

Opt into the S3 storage adapter by setting `S3_BUCKET`. When it is set,
`S3_PUBLIC_BASE_URL`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` become
required (the latter two raise via `System.fetch_env!`). See
[`KilnCMS.Storage.S3`](../lib/kiln_cms/storage/s3.ex) for per-provider hosts,
and [`media-pipeline.md`](media-pipeline.md#production-storage--cdn) for the
CDN deployment guide.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `S3_BUCKET` | unset | Enables the S3 adapter. Leave unset to use local storage. | [`config/runtime.exs:1045`](../config/runtime.exs#L1045) |
| `S3_PUBLIC_BASE_URL` | — | Public base URL objects are served from — the CDN hostname, including the bucket path if the provider's URLs carry one. **Required when `S3_BUCKET` is set** (raises otherwise). | [`config/runtime.exs:1052`](../config/runtime.exs#L1052) |
| `AWS_ACCESS_KEY_ID` | — | S3 access key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:1078`](../config/runtime.exs#L1078) |
| `AWS_SECRET_ACCESS_KEY` | — | S3 secret key. **Required when `S3_BUCKET` is set** (`fetch_env!`). | [`config/runtime.exs:1079`](../config/runtime.exs#L1079) |
| `AWS_REGION` | `us-east-1` | Region. Use `auto` for Cloudflare R2; a real region for B2/Wasabi/AWS. | [`config/runtime.exs:1081`](../config/runtime.exs#L1081) |
| `S3_ACL` | unset | Per-object canned ACL (e.g. `public_read`). Only needed if the bucket isn't public at the bucket level. | [`config/runtime.exs:1059`](../config/runtime.exs#L1059) |
| `S3_PRIVATE_BUCKET` | unset | A separate bucket for gated documents (#481) — this app's own AWS credentials read it directly, so it needs no public-read config, CDN, or public-base-URL equivalent. Without it, gating a document is refused rather than silently falling back to the public bucket. | [`config/runtime.exs:1070`](../config/runtime.exs#L1070) |
| `S3_ENDPOINT_HOST` | unset | Custom endpoint host for non-AWS stores (R2/B2/Wasabi/MinIO). Leave unset for AWS S3. | [`config/runtime.exs:1085`](../config/runtime.exs#L1085) |
| `S3_ENDPOINT_SCHEME` | `https://` | Scheme for the custom endpoint. | [`config/runtime.exs:1087`](../config/runtime.exs#L1087) |
| `S3_ENDPOINT_PORT` | `443` | Port for the custom endpoint. | [`config/runtime.exs:1089`](../config/runtime.exs#L1089) |

Media objects are uploaded with `Cache-Control: public, max-age=31536000,
immutable` — there is no env var for it, because storage keys are write-once
UUIDs so a URL's bytes never change. If the CDN hostname differs from the
site's origin, add it to `CSP_IMG_SRC` or the browser will block the images.

## Optional — in-app backups (#484)

Read in production only. Every one of these is a variable `scripts/backup.sh`
already reads, **by the same name** — the cron path and the in-app path are two
front doors to one backup directory, and an operator who configured the script
does not configure this separately. See [backups.md](backups.md#in-app-backups-484).

The console's Backups page (`/editor/backups`, admin only) reads
`$BACKUP_DIR/manifest.json`, which `backup.sh all` writes — so it reports on
cron's backups, not only ones taken from the app.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `BACKUP_ENABLED` | `true` | Set to an off-spelling to disable the **in-app** backup path — the console explains why and the button is disabled. Cron backups on the host are unaffected, which is the point: turning off the button is not turning off backups. Parsed by the shared [on/off rules](#onoff-variables). | [`config/runtime.exs:1004`](../config/runtime.exs#L1004) |
| `BACKUP_DIR` | `/var/backups/kiln` | Where backups land, for both paths. | [`config/runtime.exs:1005`](../config/runtime.exs#L1005) |
| `BACKUP_KEEP_DAYS` | `14` | Local retention in days, enforced by both paths. A non-positive or unparseable value keeps the default and warns — read literally, `0` would delete the backup it had just taken. | [`config/runtime.exs:1006`](../config/runtime.exs#L1006) |
| `BACKUP_STALE_AFTER_HOURS` | `36` | How old the newest backup may be before the console warns and the overview shows a red strip. Deliberately longer than a daily cadence: a warning that fires because a nightly job ran at 03:20 instead of 03:17 is one an admin learns to ignore. | [`config/runtime.exs:1007`](../config/runtime.exs#L1007) |
| `MEDIA_DIR` | unset | Uploads root to archive — **Local storage adapter only**. Leave unset on S3/R2, where the bucket is backed up provider-side: tarring a directory that doesn't hold the media produces an archive that looks like a media backup and restores nothing. | [`config/runtime.exs:1033`](../config/runtime.exs#L1033) |

> **The runtime image needs `pg_dump`.** It installs `postgresql-client-17`,
> and the **major version must match your Postgres server** — `pg_dump` refuses
> to run against a newer one. Bump the pin in the `Dockerfile` alongside a
> server upgrade. Where the tools are absent, the console says so rather than
> failing at the point of use.

## Optional — SSO (OpenID Connect, #331)

Only read when SSO was compiled in (`config :kiln_cms, :sso_oidc, enabled:
true` — see docs/sso.md). All four are then required for the flow to work.

**Where to get them.** Register a confidential (server-side web) application at
your identity provider — Entra ID, Okta, Keycloak, Auth0, Google Workspace, any
OIDC-conformant IdP. It issues the client id and secret; you hand it
`OIDC_REDIRECT_URI` as the permitted callback. Kiln authenticates with
`client_secret_basic`, so the IdP must allow that token-endpoint auth method.
`OIDC_ISSUER` is the provider's base URL — whatever serves
`<issuer>/.well-known/openid-configuration` — and discovery supplies the rest,
so there are no other endpoints to copy across.

| Variable | Purpose | Where it's read |
|----------|---------|-----------------|
| `OIDC_CLIENT_ID` | Client id registered at the IdP | `config/runtime.exs` |
| `OIDC_CLIENT_SECRET` | Client secret (`client_secret_basic`) | `config/runtime.exs` |
| `OIDC_ISSUER` | Provider base URL (OIDC discovery) | `config/runtime.exs` |
| `OIDC_REDIRECT_URI` | This site's callback base, e.g. `https://cms.example.com/auth` | `config/runtime.exs` |

## Optional — outbound email

With none of these set, production uses the dev-only in-memory adapter: the
app runs, but every delivery job fails in Oban and no email leaves. Opt into
real delivery with `MAIL_MODE` (or, for back-compat, just `SMTP_HOST`, which
implies `MAIL_MODE=smtp`). Direct mode is configured and verified from
`/editor/mail` — see the operator guide
[`docs/direct-email-delivery.md`](direct-email-delivery.md) for the DNS
requirements (SPF/DKIM/DMARC/PTR) and the big caveat: many cloud hosts block
outbound port 25.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MAIL_MODE` | unset | `smtp` = relay through an SMTP server; `direct` = deliver straight to each recipient domain's MX hosts (built-in MTA, no relay). Anything else raises at boot. | [`config/runtime.exs:1266`](../config/runtime.exs#L1266) |
| `MAIL_FROM_EMAIL` | unset | From address for all outbound mail. **Required when `MAIL_MODE=direct`** (raises otherwise) — its domain is the sending/DKIM domain. | [`config/runtime.exs:1306`](../config/runtime.exs#L1306) |
| `MAIL_FROM_NAME` | `KilnCMS` | Display name for the From address. | [`config/runtime.exs:1338`](../config/runtime.exs#L1338) |
| `SMTP_HOST` | unset | Relay host. **Required when `MAIL_MODE=smtp`**; setting it without `MAIL_MODE` also selects smtp mode. | [`config/runtime.exs:1267`](../config/runtime.exs#L1267) |
| `SMTP_PORT` | `587` | Relay port. 587 (STARTTLS) is the right default, and 25 belongs to `MAIL_MODE=direct`. **465 will not work**: that port expects implicit TLS from the first byte, and the adapter is configured for STARTTLS only (`tls:`, never gen_smtp's `ssl:`) with no environment variable to change it — a relay that offers both ports should be pointed at 587. | [`config/runtime.exs:1298`](../config/runtime.exs#L1298) |
| `SMTP_USERNAME` | unset | Relay username (`auth: :always`). **From the relay provider's dashboard** — providers name the pair differently: Postmark issues one Server API Token used as *both* username and password; SES issues dedicated SMTP credentials, which are **not** your AWS access keys; Gmail requires an App Password rather than the account password. | [`config/runtime.exs:1299`](../config/runtime.exs#L1299) |
| `SMTP_PASSWORD` | unset | Relay password; see `SMTP_USERNAME` for where it comes from. | [`config/runtime.exs:1300`](../config/runtime.exs#L1300) |
| `SMTP_TLS` | `true` | STARTTLS to the relay. Set to an off-spelling only for a local dev/test relay. | [`config/runtime.exs:1284`](../config/runtime.exs#L1284) |
| `SMTP_TLS_VERIFY` | `true` | Verify the relay's certificate against [CAStore](https://hex.pm/packages/castore)'s bundle, with SNI. Set to an off-spelling for a relay with a self-signed or mismatched certificate: the connection stays encrypted but the peer is not verified (`verify_none`). | [`config/runtime.exs:1284`](../config/runtime.exs#L1284) |
| `MAIL_HELO_HOST` | `PHX_HOST` | Direct mode only: HELO/EHLO hostname. Deliverability requires the sending IP's PTR record to resolve to this name. | [`config/runtime.exs:1314`](../config/runtime.exs#L1314) |
| `DKIM_PRIVATE_KEY` | unset | Direct mode's DKIM signing key (PKCS#1 RSA PEM, same shape as the provenance key). **Most deployments should not set this**: `/editor/mail` generates the keypair, picks a selector, prints the TXT record to publish and then verifies it against DNS alongside SPF, DMARC, PTR and outbound port 25. This variable exists for a deployment whose policy forbids a private key in the database — select the env provider on that page (it falls back to this variable name when none is given, [`KilnCMS.Keys.Providers.Env`](../lib/kiln_cms/keys/providers/env.ex#L4)) and supply the PEM yourself, because that provider is read-only and the Generate button can no longer help. A blank value counts as unset. Being a multi-line PEM, it takes the same forms as `KILN_PROVENANCE_PRIVATE_KEY` — an escaped one-line double-quoted value (literal `\n`, unescaped on read, #609), a true multi-line double-quoted value, or the file provider. Generate with `openssl genrsa -traditional -out kiln-dkim.pem 2048`, and stay at 2048 bits — a 4096-bit public half overflows the 255-byte TXT string limit. See [direct-email-delivery.md](direct-email-delivery.md). | [`KilnCMS.Keys.Providers.Env`](../lib/kiln_cms/keys/providers/env.ex) |

## Optional — search (Meilisearch)

Opt into the typo-tolerant search backend by setting `MEILI_URL`; otherwise
Postgres full-text search is the only backend. Run `mix kiln.meili.reindex` once
after enabling. See [`docs/meilisearch.md`](meilisearch.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MEILI_URL` | unset | Meilisearch server URL. Enables the backend when set. | [`config/runtime.exs:1098`](../config/runtime.exs#L1098) |
| `MEILI_MASTER_KEY` | unset | Meilisearch API master key. | [`config/runtime.exs:1102`](../config/runtime.exs#L1102), [`lib/kiln_cms/search/meilisearch.ex:14`](../lib/kiln_cms/search/meilisearch.ex#L14) |
| `MEILI_INDEX` | `kiln_content` | Index name. | [`config/runtime.exs:1103`](../config/runtime.exs#L1103) |

## Optional — AI-assisted SEO drafting

Opt in by setting `SEO_MODEL`. Unset, the editor's suggest control never
renders and no content leaves the deployment — the deterministic SEO analysis
and score are unaffected either way. Like the other variables on this page these
are read in the production branch of `runtime.exs`; for dev or test, set
`config :kiln_cms, KilnCMS.Seo, …` in a config file. Prefer an on-prem model
(`ollama:`/`vllm:`); a hosted provider is announced at boot and in the editor,
and should be added to your DPA's subprocessor list. See [`docs/seo.md`](seo.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `SEO_MODEL` | unset | `req_llm` model spec, e.g. `ollama:llama3.1` or `anthropic:claude-sonnet-5`. Enables drafting when set. | [`config/runtime.exs:1118`](../config/runtime.exs#L1118) |
| `SEO_GENERATOR` | `KilnCMS.Seo.Generator.ReqLLM` | Override the adapter module with your own `KilnCMS.Seo.Generator`. | [`config/runtime.exs:1120`](../config/runtime.exs#L1120) |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, … | unset | Provider credentials. **Read by `req_llm`, never by Kiln** — they don't enter Kiln's config or database. | `req_llm` |

## Optional — AI block assist in the editor

The body-copy twin of `SEO_MODEL`, and a **separate** switch: this one sends a
block's prose *and the editor's typed instruction* on each request, and returns
text bound for the page body. Setting `SEO_MODEL` alone leaves it off and the
per-block "AI assist" control never renders. Same on-prem preference and same
boot warning for a hosted provider. See [`docs/ai-assist.md`](ai-assist.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `ASSIST_MODEL` | unset | `req_llm` model spec, e.g. `ollama:llama3.1`. Enables block assist when set. | [`config/runtime.exs:1141`](../config/runtime.exs#L1141) |
| `ASSIST_GENERATOR` | `KilnCMS.Assist.Generator.ReqLLM` | Override the adapter module with your own `KilnCMS.Assist.Generator`. | [`config/runtime.exs:1143`](../config/runtime.exs#L1143) |

## Optional — generated answers for `/api/ask`

The third AI switch, and the one to think hardest about, because it is the only
one a **stranger** can trigger: `/api/ask` is a public, anonymous endpoint.
Unset, it stays what it is by default — retrieval-only, returning cited
published passages, `"answer": null` and `"generation": "disabled"` — and
nothing leaves the deployment.

Only *published, world-readable* content is ever retrieved, so no draft can
reach the model whatever the setting. Generation carries its own rate-limit
buckets on top of the pipeline's per-IP limiter, keyed on the client address for
anonymous callers; an exhausted bucket degrades to retrieval-only rather than
refusing the request, and says so — `"generation": "rate_limited"` with a
`retry_after`, so a client can tell a throttle from a switch. Same on-prem
preference and same boot warning for a hosted provider. See
[`docs/rag.md`](rag.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `ASK_MODEL` | unset | `req_llm` model spec, e.g. `ollama:llama3.1`. Enables generated answers when set. | [`config/runtime.exs:1169`](../config/runtime.exs#L1169) |
| `ASK_GENERATOR` | `KilnCMS.Ask.Generator.ReqLLM` | Override the adapter module with your own `KilnCMS.Ask.Generator`. | [`config/runtime.exs:1171`](../config/runtime.exs#L1171) |

## Optional — rich embed cards (oEmbed, #489)

Off by default, and **enabling it is egress**: the server makes an outbound
HTTPS request when an editor saves a document containing an embed block whose
URL one of the curated providers claims. With it off, an embed renders exactly
as it always has — a bare figure for anything but YouTube and Vimeo, which are
framed without any network call.

Requests only ever go to the provider endpoints listed in
`KilnCMS.OEmbed.Provider` — never to a URL discovered from content — and through
the address-pinned, size-capped `KilnCMS.SafeFetch`. The provider's `html` is
discarded rather than sanitized; only title, author, provider name and a
thumbnail are stored, and the thumbnail must be on that provider's own CDN.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `OEMBED_ENABLED` | `false` | Resolve oEmbed metadata so embeds render as cards. | [`config/runtime.exs:1198`](../config/runtime.exs#L1198) |
| `OEMBED_PROVIDERS` | unset (all) | Comma-separated provider names to **narrow** the built-in list. Cannot add one — a new provider is a host this server dials, so it is a code change. | [`config/runtime.exs:1200`](../config/runtime.exs#L1200) |

## Optional — outbound link checking (#474)

Neither of these switches the feature on. Outbound checking is **opt-in per
site**, in the console at `/editor/links`, because it is the site's content that
decides which third parties get requested — see
[`docs/link-checking.md`](link-checking.md). An unconfigured deployment with no
site opted in makes no outbound requests at all, so the sweep is scheduled
everywhere by default.

Internal links need none of this: they are checked by a database query in the
editor's advisory panel, with no switch and no schedule.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_LINK_CHECK_CRON` | `20 4 * * *` | Oban cron expression for the sweep. `false` (or an unparseable value, which warns on stderr) leaves it unscheduled, for a deployment driving `KilnCMS.Links.Sweep.run/0` from its own scheduler. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_LINK_CHECK_USER_AGENT` | `KilnCMS-LinkCheck (+github.com/…)` | What the checker calls itself to every site it asks about. Worth setting to something with your own contact URL: it is what an operator on the receiving end reads before deciding whether to block you. Deliberately carries **no version** — a link checker announces itself to every site an author has ever cited, and a build number there is a permanent broadcast of what to try. | [`config/runtime.exs`](../config/runtime.exs) |

## Optional — editorial tasks (#501)

Safe to leave scheduled everywhere: with no tasks assigned in any org, the
digest sweep enqueues nothing.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_TASK_DIGEST_CRON` | `0 8 * * *` | Oban cron expression for the daily due-soon/overdue task digest email. `false` (or an unparseable value, which warns on stderr) leaves it unscheduled, for a deployment driving the equivalent itself. | [`config/runtime.exs`](../config/runtime.exs) |

## Optional — Web Push notifications (#628)

Unset ⇒ push is **off**: `/editor/settings` never offers the toggle and nothing
is sent. Generate a pair with `mix kiln.vapid.gen` (the same format
`npx web-push generate-vapid-keys` emits, so an existing pair carries over).

Rotating the pair invalidates every live subscription — the push service answers
`403`, the row is pruned, and reviewers must re-enable notifications on each
device. Notifications never carry draft content; see
[`KilnCMS.Push`](../lib/kiln_cms/push.ex).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_VAPID_PUBLIC_KEY` | unset | base64url, unpadded, uncompressed P-256 point (65 bytes). Handed to the browser as `applicationServerKey` when it subscribes, and published in the VAPID header so a push service can verify the signature. Must be the public half of `KILN_VAPID_PRIVATE_KEY` — a mismatched pair disables push and logs an error at the first send rather than failing per message months later. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_VAPID_PRIVATE_KEY` | unset | base64url, unpadded, the 32-byte scalar. **A secret**: anyone holding it can push a notification to every subscriber of this deployment. Keep it with the rest of the secret store, not in shell history or a committed `.env`. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_VAPID_SUBJECT` | the deployment's public base URL | A contactable `mailto:` or `https:` URL, so a push service operator can reach whoever is sending (RFC 8292 §2.1). | [`config/runtime.exs`](../config/runtime.exs) |

## Optional — events, the "what's on" index (#766)

Safe to leave scheduled everywhere: a site with no event-shaped content does one
indexed probe per content type and matches nothing. See
[`docs/events.md`](events.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_OCCURRENCE_SWEEP_CRON` | `50 * * * *` | Oban cron expression for the sweep that advances `next_occurrence_at` once an occurrence has gone by. **The interval is how stale the listing may be** — a finished event keeps its place until the next run — so shorten it on a site whose events turn over during the day. `false` (or an unparseable value, which warns on stderr) leaves it unscheduled, for a deployment driving `KilnCMS.Events.Sweep.run/0` from its own scheduler. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_FEDERATION_NONCE_SWEEP_CRON` | `40 * * * *` | When `KilnCMS.Federation.SeenSignatureSweeper` removes expired rows from the inbound-signature replay store (#967). Hygiene, not security: an expired row cannot verify anyway. `false` disables. | [`config/runtime.exs:430`](../config/runtime.exs#L430) |
| `KILN_HEALTH_SWEEP_CRON` | `30 7 * * *` | Oban cron expression for the content-freshness sweep: finds published content whose `health` has gone `:overdue`/`:expired` and dispatches one automation event per record, so a rule can turn staleness into an assigned task. Daily is the right period — a review cadence is measured in months. Scheduled before the task digest so a task it raises lands in that morning's email rather than tomorrow's. Safe everywhere: with no review cadences set it matches nothing. `false` (or an unparseable value, which warns on stderr) leaves it unscheduled, for a deployment driving `KilnCMS.CMS.HealthSweep.run/0` itself. See [`docs/content-lifecycles.md`](content-lifecycles.md). | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_OCCURRENCE_BACKFILL_ON_BOOT` | `true` | Whether booting enqueues the one-off backfill that gives pre-existing content its first `next_occurrence_at`. On, because the alternative is an upgrade step someone has to remember and the index is empty until they do. Deduplicated for a day at the database level, so a rolling deploy queues one job across replicas; a redundant pass writes nothing, which also makes it a repair pass for a value knocked out of sync. Set `false` to run `mix kiln.occurrences.backfill` yourself. | [`config/runtime.exs`](../config/runtime.exs) |

## Optional — error tracking (Sentry)

Enabled in any environment only when `SENTRY_DSN` is set; otherwise every Sentry
capture is a no-op. See [`docs/observability.md`](observability.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `SENTRY_DSN` | unset | Sentry DSN (`https://<publickey>@o0.ingest.sentry.io/0`, or your own host when self-hosting). Enables error reporting when set. **Where to get it:** the Sentry project's Settings → Client Keys (DSN). It is not confidential in the strict sense — browser SDKs ship it publicly — but it does authorize writes to the project, so handle it like a credential anyway. | [`config/runtime.exs:119`](../config/runtime.exs#L119) |
| `SENTRY_ENV` | `config_env()` | Environment name tag for Sentry events. | [`config/runtime.exs:122`](../config/runtime.exs#L122) |
| `RELEASE_VSN` | unset | Release version tag (set automatically by the release runtime) to pin regressions to a deploy. | [`config/runtime.exs:125`](../config/runtime.exs#L125) |

## Optional — distributed tracing (OpenTelemetry)

Enabled only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, which flips the
`:otel_enabled` flag and points the OTLP exporter at the collector. See
[`docs/observability.md`](observability.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | OTLP collector endpoint — anything that speaks OTLP: a local `otel-collector`, Grafana Alloy, Jaeger, or a vendor's ingest URL. Enables tracing when set. Port 4318 is the conventional HTTP port, 4317 gRPC; match it to the protocol below. | [`config/runtime.exs:135`](../config/runtime.exs#L135) |
| `OTEL_SERVICE_NAME` | `kiln_cms` | Service name attached to spans. Free-form — this is how the deployment is labelled in the tracing UI. | [`config/runtime.exs:141`](../config/runtime.exs#L141) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | OTLP protocol: `http_protobuf`, `http_json` or `grpc`. | [`config/runtime.exs:145`](../config/runtime.exs#L145) |
| `OTEL_EXPORTER_OTLP_HEADERS` | unset | Standard OTLP headers, as comma-separated `key=value` pairs (`api-key=abc123,x-tenant=acme`) — usually the ingest credential from whichever vendor `OTEL_EXPORTER_OTLP_ENDPOINT` points at. Honored by the exporter library, not by Kiln. | OpenTelemetry exporter (standard `OTEL_*`) |

## Optional — tamper-evident history & content signing (#356, #340)

Every publish folds the document's version chain into a canonical hash and
records it append-only in `history_anchors`, RSA-signed when a signing key is
configured. See [editorial-consent.md](editorial-consent.md) and
[`KilnCMS.Governance.Chain`](../lib/kiln_cms/governance/chain.ex).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_AUDIT_ANCHORS_ENABLED` | `true` | The tamper-evident history master switch (#356). `Chain.extend/2` requires **both** this and `KILN_AUDIT_ANCHOR_EVERY_WRITE` below, so turning this off is a complete kill switch for anchoring regardless of the per-write setting. Set to `false`/`0`/`no`/`off` to disable, recoverable at runtime without a rebuild (#611 — before this variable existed, the only way back was a rebuild with `:audit_anchors_enabled` compiled to `true`). Only a recognized spelling writes config; an unrecognized value keeps the default (`true`) — the safe side, opposite of `KILN_AUDIT_ANCHOR_EVERY_WRITE`'s. Ignored under `MIX_ENV=test`. | [`config/runtime.exs:275`](../config/runtime.exs#L275) |
| `KILN_AUDIT_ANCHOR_EVERY_WRITE` | `false` | Set to `true`/`1`/`yes`/`on` to anchor **every** versioned write, not just publishes — #356's "sign every version, not just published artifacts". Closes the window between two publishes, at the cost of one signature and one `history_anchors` row per save — **and** of autosave coalescing, which cannot collapse rows an anchor has committed to, so every debounced draft save keeps its own version row (#671; `docs/editorial-consent.md` has the reasoning). A regulated deployment wants this; a blog does not. Read at runtime so it can be turned off without rebuilding the image — this governs only the per-write extension; it is a no-op whenever `KILN_AUDIT_ANCHORS_ENABLED` above is off. Only a recognized spelling writes config, so an unrecognized value keeps the configured default rather than being read as "off" — silently not signing is the dangerous direction. Ignored under `MIX_ENV=test` so the suite stays deterministic. | [`config/runtime.exs:302`](../config/runtime.exs#L302) |
| `KILN_PROVENANCE_PRIVATE_KEY` | unset | PKCS#1 RSA private key PEM (`BEGIN RSA PRIVATE KEY`) used to sign history anchors and C2PA-*style* content manifests (#340). Unset ⇒ anchors are stored **unsigned** — still an integrity checksum, but the anchor row itself is no longer tamper-proof, and `verify` reports `:unsigned` rather than `:verified`. The key source is configurable (`config :kiln_cms, KilnCMS.Provenance, signing_key:`); this var is only the default `{:env, …}` binding, so a deployment that set `signing_key: :dkim` or a `{:file, …}` in source ignores it. It is a multi-line PEM: write it as an escaped one line (double-quoted, each newline a literal `\n` — unescaped on read, #609) or as a double-quoted true multi-line value, or mount it via `KILN_PROVENANCE_KEY_FILE`. PKCS#8 is rejected — convert with `openssl rsa -in key.pem -traditional -out key-pkcs1.pem` (the `-out` matters — without it the private key streams to stdout instead of a file). | [`config/config.exs:766`](../config/config.exs#L766) |
| `KILN_PROVENANCE_KEY_FILE` | unset | Path to the same PEM, mounted as a file (Docker/K8s secret). Sets `signing_key: {:file, …}` at runtime — before #608 this shape existed only in `config/config.exs`, i.e. only with a rebuild. It replaces `signing_key` **wholesale**, so it wins over `KILN_PROVENANCE_PRIVATE_KEY` (mount the file first, unset the var after) but equally over a source-configured `:dkim` or `{:file, …}` — setting it switches the signing key, and every new anchor gets a new `key_id`. | [`config/runtime.exs:543`](../config/runtime.exs#L543) |
| `KILN_PROVENANCE_RETIRED_KEY_FILES` | unset | Comma-separated **paths** to the public halves of keys that no longer sign but must still verify. Sets `:retired_key_files`, which `KeyRegistry.retired/0` **unions** with any `:retired_keys` configured in source — so the env route can only add verification keys, never drop one. (That holds because this var is the sole writer of `:retired_key_files`; put source config in `:retired_keys`.) Blank entries are ignored, so a trailing comma is harmless, and a value with no paths at all warns and changes nothing rather than clearing the list. An unreadable path is logged and skipped rather than blinding the keys that do resolve. Paths only — a public key is multi-line too — and since `,` separates and each entry is trimmed, a path containing a comma or significant leading/trailing whitespace can't be expressed here; use `retired_keys` in source for those. | [`config/runtime.exs:569`](../config/runtime.exs#L569) |
| `KILN_PROVENANCE_ENABLED` | `false` | Set to `true`/`1`/`yes`/`on` to produce signed manifests for fired artifacts and serve `/api/provenance/*`. **A signing key alone is not enough**: with this unset, the key signs history anchors and every provenance endpoint still returns `404`. Parsed by the shared [on/off rules](#onoff-variables), so an unrecognized value keeps the default and warns rather than turning signing off. Ignored under `MIX_ENV=test`. See [provenance.md](provenance.md). | [`config/runtime.exs:493`](../config/runtime.exs#L493) |
| `KILN_FEDERATION_ENABLED` | `false` | Set to `true`/`1`/`yes`/`on` to let sites on this deployment be followed from Mastodon and other fediverse servers (#491). This is the **deployment** half of a two-part gate: with it unset, every federation route `404`s no matter what a site admin enabled. Turning it on means the server signs and POSTs to hosts chosen by strangers who followed a site, indefinitely and unattended — if your egress policy forbids that, leave it alone, since no tenant admin can override it. A site still opts in individually (`mix kiln.federation enable`). Parsed by the shared [on/off rules](#onoff-variables). Ignored under `MIX_ENV=test`. See [federation.md](federation.md). | [`config/runtime.exs:505`](../config/runtime.exs#L505) |
| `KILN_EXPERIMENTS_ENABLED` | `false` | Set to `true`/`1`/`yes`/`on` to serve A/B content experiments (#499). OFF by default, and the deployment gets a say because a page under a running experiment is served `private, no-store` — with the usual `public, max-age=60` a CDN would cache one arm and hand it to every visitor, which is a 100/0 split reported as 50/50. No visitor is tracked unless you also set `KILN_EXPERIMENTS_STICKY` below: on-site assignment is stateless and headless callers supply their own `?variant_key=`. Parsed by the shared [on/off rules](#onoff-variables). Ignored under `MIX_ENV=test`. See [content-experiments-plan.md](content-experiments-plan.md). | [`config/runtime.exs:515`](../config/runtime.exs#L515) |
| `KILN_EXPERIMENTS_STICKY` | `false` | Set to `true`/`1`/`yes`/`on` to keep a visitor in the same A/B arm across page loads (#984). **This is the one switch that puts a cookie on visitors**, so it is deliberately separate from `KILN_EXPERIMENTS_ENABLED` rather than implied by it. What is stored is a *bucket* — one integer in `0..99`, shared by a crowd, joined to nothing server-side — plus, for a goal that converts on a later page (`content_view`, `funnel_completion`), a second cookie `_kiln_ab_x` naming the arm the visitor was shown (up to 4, each cleared the moment it converts) — the weaker of the two claims, since a combination of arms starts to narrow a visitor down. Both are `__Host-`-prefixed wherever your cookies are `Secure`, and are only minted on a page actually under experiment. Whether your regime wants consent for it is your call; see [data-flows.md](data-flows.md#sticky-assignment-cookie-984). Parsed by the shared [on/off rules](#onoff-variables). | [`config/runtime.exs:525`](../config/runtime.exs#L525) |
| `KILN_EXPERIMENTS_STICKY_DAYS` | `30` | Lifetime of the sticky cookies above, in days. Long enough to outlive the experiment a visitor is in, short enough not to be a standing marker — a year is the reflex default and would be one. A non-positive or unparseable value warns and keeps the default. | [`config/runtime.exs:531`](../config/runtime.exs#L531) |
| `KILN_PROVENANCE_SIGNER` | `:site_name` | Human-readable signer identity recorded in every manifest a consumer verifies — part of what the deployment publicly asserts about its content (#644). Unset falls back to the site name (which a released image can already set), so it is lower stakes than the three above; set it only to override the claim's signer without a rebuild. A blank value counts as unset. Ignored under `MIX_ENV=test`. | [`config/runtime.exs:1360`](../config/runtime.exs#L1360) |
| `KILN_PROVENANCE_ORIGIN` | `:public_base_url` | Origin URL recorded in the manifest claim (#644). Unset falls back to the public base URL a released image already configures; set it only to override. A blank value counts as unset. Ignored under `MIX_ENV=test`. | [`config/runtime.exs:1366`](../config/runtime.exs#L1366) |
| `KILN_PROVENANCE_AI_DISCLOSURE` | `human` | Default AI-generation disclosure embedded when a document declares none (an editor can override per-document via `custom_fields["ai_disclosure"]`). One of `human`/`ai_assisted`/`ai_generated` (case-insensitive). **An unrecognized value warns and keeps the default** rather than being coerced — it rides into a signed claim, so a typo must not silently rewrite what the deployment asserts (#644). A blank value counts as unset. Ignored under `MIX_ENV=test`. | [`config/runtime.exs:1387`](../config/runtime.exs#L1387) |

> **Rotating the signing key.** Verification resolves the key named by each
> signature's `key_id`, so pre-rotation anchors and manifests keep verifying —
> **once** the outgoing key's public half is registered
> (`KILN_PROVENANCE_RETIRED_KEY_FILES`, or `retired_keys` in source).
> Register it **before** destroying the
> outgoing private half: until it is registered, those signatures resolve to
> `{:error, {:unknown_key_id, …}}`, and with the private half gone there is no
> way to re-derive the public one. Order matters — export the public half,
> point the var at it, restart, confirm an old anchor still verifies, and only
> then destroy the private key. See
> [`KilnCMS.Provenance.KeyRegistry`](../lib/kiln_cms/provenance/key_registry.ex).

## Optional — governance checkpoint witness (#666)

Anchors make a document's history tamper-evident against everything except
**truncation**: delete its newest anchors and the surviving prefix still
verifies, because nothing inside the document says how many there were. A
*checkpoint* is the statement from outside — a signed, org-wide commitment to
every document's head anchor, minted on a schedule and published to a sink the
database credentials do not own. See
[`KilnCMS.Governance.Checkpoint`](../lib/kiln_cms/governance/checkpoint.ex) and
[`KilnCMS.Governance.Witness`](../lib/kiln_cms/governance/witness.ex).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_GOVERNANCE_WITNESS` | `none` | Where checkpoints are published: `none`, `file`, `s3`, or `http`. `none` keeps the commitment in the database, which still catches an attacker who deletes anchors and forgets `chain_checkpoints` — and does not survive one who remembers, so it is not the property the feature claims. An unrecognized value keeps `none` and warns on stderr; note that is the **weaker** side, so the warning is the only signal a typo left you unwitnessed. Ignored under `MIX_ENV=test`. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_WITNESS_DIR` | unset | Directory for the `file` adapter. Files are created exclusively, so a checkpoint is never overwritten. Point it at something the application user cannot unlink from — an append-only mount, a WORM volume, a spool an off-host agent drains — or it buys distance rather than the property. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_WITNESS_BUCKET` | unset | Bucket for the `s3` adapter. **Use a different bucket from media storage**, which is request-path writable and public-read by design. Objects are written with `If-None-Match: *`, so a re-publish cannot silently replace one; pair that with Object Lock in compliance mode, or a policy denying `s3:DeleteObject` to the application's principal, or the object is as deletable as the row. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_WITNESS_PREFIX` | `""` | Key prefix inside that bucket. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_WITNESS_URL` | unset | Base URL for the `http` adapter — a transparency log, or a thin shim in front of one. Listings are followed across pages (`Link: rel="next"`, or a `{"keys": [], "next": ""}` body) — a log that pages and says nothing about the rest would report the sink as smaller than it is, and for this audit "smaller" reads as *no missing rows*. Kiln `POST`s each checkpoint to `<url>/<key>` with `If-None-Match: *` and requires a **`201`**: a `2xx` that is not a create is refused, because a service that silently replaces an object answers `200` and looks exactly like one that appended. Overwrite protection still has to come from the log itself; the status check is a guard against a shim that forgot — and note a log answering `200` (RFC 6962 `add-chain`) or `202` (queued) needs that shim, or nothing publishes. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_WITNESS_TOKEN` | unset | Bearer token for that endpoint. Read through `KilnCMS.Keys`' env provider, so it can be pointed at a file or a secret manager by configuring `:token` as a provider tuple instead. Unset means no `Authorization` header — an unresolvable token sends none rather than the string `"nil"`. | [`config/runtime.exs`](../config/runtime.exs) |
| `KILN_GOVERNANCE_CHECKPOINT_CRON` | `40 3 * * *` | Oban cron expression for the checkpoint run. **This is a security parameter, not a performance one**: anchors minted since the last checkpoint are not yet witnessed, so the window in which a chain can be truncated undetected is exactly one interval. A regulated deployment sets `0 * * * *`. Set `config :kiln_cms, :governance_checkpoint_cron, false` in source to drive it from an external scheduler instead. | [`config/runtime.exs`](../config/runtime.exs) |

> **Publishing is only half of it.** A checkpoint nobody reads back is a file.
> `mix kiln.audit.checkpoint --audit` re-fetches every published checkpoint and
> diffs it against the database row, so a deleted or rewritten `chain_checkpoints`
> is visible. Run it from a host the application does not control, on
> credentials that can read the sink and not write it — an audit run by the same
> role that writes the checkpoints only establishes that a system agrees with
> itself.

> **Unsigned deployments.** With no `KILN_PROVENANCE_PRIVATE_KEY`, a checkpoint's
> root and links are ordinary columns an attacker can recompute, and every
> verdict is floored to `:unsigned` regardless. The structural checks still run
> and still report, so a truncation is still *named* — but treat it as advisory:
> it raises the cost of a forgery, it does not attest anything. Configure a
> signing key before relying on any of this.

## Optional — upstream update check

The admin system page (`/editor/system`) reports whether a newer Kiln release
exists. The check is a single unauthenticated GET to the GitHub releases API,
made only when an admin opens the page. The request carries a bare `KilnCMS`
user-agent — no version, no instance identifier, no content — so it discloses
nothing about this deployment beyond its IP address. Results are cached for 24
hours (15 minutes for a failure) and manual re-checks are floored at one per
minute. See [`docs/releasing.md`](releasing.md).

**This is the only outbound integration that is on by default.** Unlike
Meilisearch, S3, Unsplash and mail, it needs no credential to work, so there is
no unset-secret that implicitly disables it — set `KILN_UPDATE_CHECK=false` if
your deployment must make no third-party requests at all.

**If you run a fork, set `KILN_UPDATE_REPO`.** The default compares this build
against `The-Verscienta/kiln_cms`, which for a fork is an answer about someone
else's code — and the failure is silent in the direction that matters: a fork
ahead of upstream compares as newer, so the page reports "Up to date"
indefinitely and the fork's own security releases never surface.

`GIT_SHA` and `BUILD_DATE` are Docker **build args**, not runtime variables —
the Dockerfile records them as `KILN_GIT_SHA` / `KILN_BUILD_DATE` so a running
instance can name the commit it was built from. Omitting them is harmless; the
page then reports the version alone.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_UPDATE_CHECK` | enabled | Set to an off-spelling for an instance that must make no outbound requests. | [`config/runtime.exs:628`](../config/runtime.exs#L628) |
| `KILN_UPDATE_REPO` | `The-Verscienta/kiln_cms` | The `owner/name` this build compares itself against. **Forks must set this.** Left at the default, a fork is told about upstream's releases — and a fork *ahead* of upstream compares as newer, so the page reports "Up to date" forever and the fork's own security releases never surface. A value that isn't `owner/name` is rejected, not ignored. | [`config/runtime.exs:658`](../config/runtime.exs#L658), [`Kiln.Updates`](../lib/kiln/updates.ex) |
| `KILN_UPDATE_RELEASES_URL` | derived from `KILN_UPDATE_REPO` | Full releases-API endpoint, for GitHub Enterprise or an internal mirror that can't reach `api.github.com`. Overrides the endpoint only — set `KILN_UPDATE_REPO` alongside it so the release link has a fallback. | [`config/runtime.exs:664`](../config/runtime.exs#L664), [`Kiln.Updates`](../lib/kiln/updates.ex) |
| `KILN_PIN_PATH` | unset | Path to this project's pinned Kiln checkout (`kiln/upstream`, `upstream`, …). Display only: the update page prefixes its `mix kiln.update` command with a matching `cd`. Unset by default because the pin's path is a downstream choice — see [`projects/README.md`](../projects/README.md). | [`config/runtime.exs:641`](../config/runtime.exs#L641), [`Kiln.Updates`](../lib/kiln/updates.ex) |
| `KILN_GIT_SHA` | unset | Commit the image was built from. Set via `--build-arg GIT_SHA`. | [`Kiln.Version`](../lib/kiln/version.ex) |
| `KILN_BUILD_DATE` | unset | ISO-8601 UTC build timestamp. Set via `--build-arg BUILD_DATE`. | [`Kiln.Version`](../lib/kiln/version.ex) |

## Optional — referrer attribution (#619)

Coarse "where did readers come from" categories (`direct` / `internal` /
`search` / `social` / `other`) per content item per UTC day — never a raw
referrer URL or host. Off by default; enabling requires no rebuild. See
[`docs/advanced-analytics-plan.md`](advanced-analytics-plan.md) and
[`docs/data-flows.md`](data-flows.md).

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_ANALYTICS_REFERRERS` | disabled | Enable recording classified referrer buckets (`KilnCMS.Analytics.ReferrerDay`). Turning it back off stops new writes and hides the dashboard breakdown/export columns, but does **not** delete buckets already recorded — those age out on the normal retention purge like any other bucket. | [`config/runtime.exs:681`](../config/runtime.exs#L681) |
| `KILN_ANALYTICS_LOW_COUNT_THRESHOLD` | `5` | Below this many hits, the dashboard breakdown (#620) and the export render a referrer category as `"< n"` rather than an exact number — a very small count can describe a single visitor's arrival. A second category is also rendered as `hidden` whenever any is naturally low, so that a single `"< n"` is not the sole unknown among four exact numbers (#620, #777); `hidden` is not `"< n"`, since a complementary-suppressed count can be at or above the threshold. The partner is the **largest** of the others, which is what makes the residual split many ways instead of one (#1073) — so raising this hides bigger categories, not just more of them. Where no partner makes the split ambiguous — a handful of views with four genuine zeros — the **whole breakdown** is hidden, zeros included, because a published `0` is one unknown removed from an equation that has only one. That is the exactness this gives up: on the lowest-traffic days the breakdown says nothing at all rather than saying something recoverable. Must be a positive integer; an unparseable or non-positive value keeps the default and warns rather than being interpreted (e.g. `0`, which would silently disable suppression). | [`config/runtime.exs:700`](../config/runtime.exs#L700) |

## Optional — environment indicator

A coloured strip across the top of every console page naming this deployment
(#469). A scrubbed staging clone keeps production's content *and* branding, so
the two consoles are otherwise byte-for-byte identical — which is what invites
"I edited the wrong environment".

**Unset means no strip**, so production stays clean with nothing configured. It
is the environment you recognise by the absence of a label; staging and
development are the ones that set these.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `KILN_ENV_LABEL` | unset | The name shown in the strip (`staging`, `dev`, `qa`). Unset ⇒ no strip at all. | [`KilnCMS.Environment`](../lib/kiln_cms/environment.ex) |
| `KILN_ENV_COLOR` | `warning` | Which design-kit tone to render it in: `warning`, `error`, `info`, `success`. **A tone name, not a hex** — the kit pairs each tone with an `-ink` text token chosen to clear WCAG contrast against that tone's tint, and a supplied colour would take the tint while keeping ink picked for a different one. An unrecognized name logs a warning and falls back to `warning`. | [`KilnCMS.Environment`](../lib/kiln_cms/environment.ex) |

`mix kiln.staging.scrub` and `scripts/staging.sh up` both close with a reminder
to set this. Neither can set it: the scrub runs as a throwaway process against a
remote `DATABASE_URL`, not inside the application that will serve the clone.

## Optional — seeding and staging

Not read at boot: these are consumed by a seed script and by the staging-scrub
task, so they matter only for the command that reads them.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `ADMIN_EMAIL` | `admin@kiln.test` | Email of the admin user created by `mix run priv/repo/seeds.exs`. | [`priv/repo/seeds.exs:62`](../priv/repo/seeds.exs#L62) |
| `ADMIN_PASSWORD` | `kilnadmin123` | That user's password. **The default is a published credential** — override it for anything reachable from a network. | [`priv/repo/seeds.exs:63`](../priv/repo/seeds.exs#L63) |
| `EDITOR_EMAIL` | `editor@kiln.test` | Email of the seeded editor user. | [`priv/repo/seeds.exs:64`](../priv/repo/seeds.exs#L64) |
| `EDITOR_PASSWORD` | `kilneditor123` | That user's password; same caveat as `ADMIN_PASSWORD`. | [`priv/repo/seeds.exs:65`](../priv/repo/seeds.exs#L65) |
| `KILN_STAGING_SCRUB` | unset | Authorizes the destructive scrub in a release (the Mix task uses `--yes`). **A sentinel word, not a boolean** — only the literal `confirm` authorizes it, so `true` deliberately does *not*, and the on/off rules above do not apply to this one. | [`KilnCMS.Staging`](../lib/kiln_cms/staging.ex#L33) |
| `KILN_STAGING_FORCE` | `false` | Skip the ephemeral-database-name check that stops a scrub from running against something that doesn't look like a clone. This one **is** a boolean and follows the shared spellings — it previously matched the literal `1`, so `KILN_STAGING_FORCE=true` read as "not forced". | [`KilnCMS.Staging`](../lib/kiln_cms/staging.ex#L35) |
| `STAGING_ADMIN_EMAIL` | unset | Admin account minted in the scrubbed clone. Unset (with no `--admin-email`) ⇒ the scrub reports `staging admin: NONE` and **nobody can sign in to the clone**, since the scrub removes the real users. | [`KilnCMS.Staging`](../lib/kiln_cms/staging.ex#L38) |
| `STAGING_ADMIN_PASSWORD` | unset | That account's password. | [`KilnCMS.Staging`](../lib/kiln_cms/staging.ex#L38) |

See [staging-environments.md](staging-environments.md) for the full clone →
scrub → serve procedure.

## Test / CI only

These are read by `config/test.exs` and `config/e2e.exs` and are not relevant to
production.

| Variable | Default | Purpose | Where it's read |
|----------|---------|---------|-----------------|
| `MIX_TEST_PARTITION` | unset | Suffix appended to the test database name for partitioned test runs — also what keeps two concurrent worktrees off the same database. | [`config/test.exs:219`](../config/test.exs#L219) |
| `KILN_STRICT_TEST` | unset | Set to an on-spelling (`true`/`1`/`yes`/`on`) to select the strict-tenancy CI leg: `:strict_tenancy` is flipped on so tenancy scoping compiles fail-closed, and the suite runs **only** the `strict_tenancy`-tagged tests. Uses the same spellings as every other flag in this document, via the standalone [`config/strict_test_flag.exs`](../config/strict_test_flag.exs) (#646) — it can't call `KilnCMS.Config.Env` directly because it's read in `config/test.exs`, which cannot call project modules. An unrecognized value stays non-strict **and warns on stderr**, like every other flag: without that the strict leg runs zero tests and exits 0, which is indistinguishable from never having invoked it. | [`config/test.exs:323`](../config/test.exs#L323) |
| `POSTGRES_USER` | `postgres` | E2E database user. | [`config/e2e.exs:11`](../config/e2e.exs#L11) |
| `POSTGRES_PASSWORD` | `postgres` | E2E database password. | [`config/e2e.exs:12`](../config/e2e.exs#L12) |
| `POSTGRES_HOST` | `localhost` | E2E database host. | [`config/e2e.exs:13`](../config/e2e.exs#L13) |
| `POSTGRES_DB` | `kiln_cms_e2e` | E2E database name. | [`config/e2e.exs:14`](../config/e2e.exs#L14) |
