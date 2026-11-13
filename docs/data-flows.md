# Data flows, retention & privacy (operator guide)

This document answers the question an operator or DPO needs for a Data Protection
Impact Assessment / DPA: **what personal data does KilnCMS hold, where does it go,
how long is it kept, and how do we satisfy an access or erasure request?**

It is the operator-facing companion to the June 2026 privacy audit (epic #211).
Where a control is configurable, the config key is given so you can tighten it for
your deployment.

## TL;DR

- KilnCMS is **privacy-first by default**: HTML is delivered by the LiveView app
  itself, so there is **no third-party analytics, ad, or tag-manager script** on
  any page. Content analytics are aggregate counters only — no IP, user-agent, or
  cookie is recorded for visitors. Two narrow exceptions, neither of which
  happens on an ordinary page view: a visitor who types a passphrase into a
  locked page gets an unlock cookie carrying no identifier (see
  *Transport & at-rest notes* below), and
  [sticky A/B assignment](#sticky-assignment-cookie-984) is an opt-in that is off
  unless you turn it on.
- The only personal data we store is **operator/editor account data** (email,
  optional display name, RBAC role, notification preferences) and **auth tokens**.
- Data only leaves the system through integrations you explicitly enable
  (webhooks, optional Meilisearch/S3), through transactional email, or through
  the few checks that are on by default (see
  [Optional subprocessors](#optional-subprocessors)). One of those sends visitor
  data: crawler verification asks the node's DNS resolver about the address of
  a client claiming to be a search engine (`KILN_CRAWLER_VERIFICATION=false`
  turns it off). One runs on a schedule: crawler verification fetches Google's,
  Bing's, Apple's and DuckDuckGo's published crawler IP lists every 6 hours,
  sending nothing about the instance or its visitors
  (`KILN_CRAWLER_RANGES=false` turns it off).
- Retention is bounded and automated: expired auth tokens, recorded search
  queries, and trashed content are all purged on a schedule.

## What personal data we store

| Data | Where | Personal? | Notes |
|------|-------|-----------|-------|
| Account email | `users` | Yes | Login identity; also the email recipient for workflow mail. |
| Display name | `users.name` | Yes (optional) | Shown to other editors (presence) and as the JSON-LD author byline. Blank by default. |
| RBAC role | `users.role` | No | `:admin` / `:editor` / `:viewer`. |
| Notification preferences | `users.notify_on_*` | No | Per-user opt-out (issue #46): review requested, published, returned to draft, comments, new registrations (`notify_on_registration`, #2251, offered to site admins), and site security alert email (`notify_on_security_alert`, #2245, offered to site member admins; only the account holder can change it). All are included in the self-export and reset to on by erasure. |
| In-app notifications | `notifications` | Yes | One row per recipient (#1320): event, content title, a comment excerpt, and the acting user's display name (`actor_name`) plus `actor_id`. Readable only by the recipient — no admin bypass. Deleted when the recipient is erased (#2514); `actor_name`/`actor_id` nulled when the *actor* is erased. No retention purge yet. A "registrations waiting" row (#2251) is titled with the site's name and carries no applicant data: no address, name, excerpt or actor. A security alert or notice row (#2245) is titled with the site's name and has no actor; its excerpt names what happened and, for an alert, the client's network (`/24`, `/48`), or the full IP address when the site opted in. Its `details` map holds the same facts as the excerpt (phase, kind, change, count, that address, the event type) so the inbox can say it in the reader's language. A blocked-address alert names no address: its excerpt and `details` carry the block rule that matched, masked the same way. |
| Auth tokens | `tokens` | Pseudonymous | jti, subject (`user?id=<uuid>`), purpose, expiry; for a session, browser and OS family, last use and the site it signed in on; for a revoked one, why. See [Auth tokens](#auth-token-retention-218). |
| Audit / version history | `document_events`, AshPaperTrail versions | Pseudonymous | Carries `actor_id`. See [Audit trail vs erasure](#audit-trail-vs-user-erasure-219). |
| Security log | `security_events` | Yes | Admin-only audit log (#2241): the acting user's id and an **email snapshot** (known accounts only), the target, the **raw IP address** and **user agent** of the request, and a short allowlisted metadata map with no secrets. Kept 365 days by default (per-site setting, `0` keeps forever; then raw IPs are kept indefinitely). Scrubbed on erasure, purged on retention and by the staging scrub. A request refused by the site's block list (`ip_block_refused`, #2245) is the exception: it records the rule and surface only, with no IP address or user agent. See [Security log](security-events.md). |
| Instance security log | `instance_security_events` | Yes | Platform-admin-only audit log of events about the installation rather than a site (#2541; today `backup_canceled`): the same columns as the site log (acting user's id and **email snapshot**, target, **raw IP address**, **user agent**, allowlisted metadata), with no site. Kept 365 days by default (`KILN_INSTANCE_SECURITY_LOG_RETENTION_DAYS`, `0` keeps forever). Scrubbed on erasure, purged on retention and by the staging scrub. See [The instance log](security-events.md#the-instance-log). |
| Security alert queue | `security_alert_dispatches` | Pseudonymous (transient) | One row per security alert window or silencing notice (#2245): the site, the alert kind, the window, the id of the security event that raised it, delivery stamps, and for a notice what changed, the kinds, the webhook endpoint's id and the acting user's id. Never an address, email, URL or token. Deleted by an hourly prune a day after its window ends, and by the staging scrub. Not touched by erasure: it holds ids only and is gone within a day. See [Security alerts](security-alerts.md). |
| Security alert settings | `site_security_alerts` | No | Per site (#2245): the alert kinds turned off, whether admins get the bell and email, whether alerts show full IP addresses. |
| Platform security alert settings | `platform_security_alerts` | No | One row for the installation (#2245): the platform alert kinds a platform admin turned off (today only `api_key_rate_limited` can be). No person, address or key. Each save is recorded in the instance security log (`platform_alerts_changed`). |
| Verified API keys | **memory only**, on each node | Pseudonymous (transient) | The SHA-256 of each API key that authenticated on the node in the last 5 minutes, with the key's id and when (#2245, `KilnCMS.Security.ApiKeyTrip`), so a rate-limit refusal can tell a real key from a forged one without a database read. Never the key itself, a user or an address. At most 10,000 entries; swept every minute, gone on restart, never shared between nodes or written to disk. |
| Site invitations | `invitations` | Yes | One row per address a platform admin invited to a site (#2135): the **email address**, the site, the tier and custom role, who sent it, when it expires and how often it was sent, and the SHA-256 of the link's token (never the token). The person may have no account. Removed when the invitation is accepted or revoked; otherwise usable for 7 days and deleted by the daily prune 30 days after that, so an address is kept at most about 37 days. Not touched by erasure (see below); deleted by the staging scrub. |
| Recorded search queries | `search_queries` | Possibly | Query text only — **no** actor/IP. See *Search query retention (#213) + disclosure (#220)* below. |
| Web Push subscriptions | `push_subscriptions` | Yes | One row per browser a user turned push notifications on in: the push service endpoint and its keys, a coarse browser label, and which VAPID key it was made against. Deleted on erasure (#2514). |
| Saved views | `saved_views` | Pseudonymous | A named content-list filter and its owner's id. A private view is deleted on erasure (#2514); a shared one is the team's and stays, pointing at the anonymized account. |
| Consumer audiences | `users.audiences`, `org_memberships.audiences` | No | Which gated content a reader may see. Granted by an admin or by an active paid membership. Cleared on erasure. |
| Paid memberships | `billing_memberships` | Pseudonymous | Status, period end, and the payment provider's customer/subscription ids. See [Paid memberships](memberships.md). |
| Entitlement audit trail | `billing_membership_events` | Pseudonymous | Status transitions and the audience delta, with the causing provider event id. `actor_id` nulled on erasure. |
| Recorded payment webhooks | `billing_webhook_events` | Yes (transient) | The provider's full event payload, which can carry a customer email and amounts. Purged on retention and by the staging scrub. |
| Idempotency keys | `idempotent_requests` | Pseudonymous (transient) | One row per `Idempotency-Key` a caller used on a write ([api.md](api.md)), holding the key, the acting user's id, a hash of the request and **the response that was sent** — so it carries whatever that response did. Pruned hourly, 24-hour lifetime. |
| Aggregate view counts | `content_views` | No | One upserting counter per content item — no visitor data. |
| Daily view buckets | `content_view_days` | No | One counter per content item per UTC day, for 7d/30d trends — no visitor data. Purged on retention (below). |
| Daily referrer buckets | `referrer_days` | No | One counter per content item per coarse source category (`direct`/`internal`/`search`/`social`/`other`) per UTC day — never a raw referrer URL or host. Off by default (`KILN_ANALYTICS_REFERRERS`, #619); turning it back off stops new writes but does not clear rows already recorded — those still age out on the retention purge (below). |
| Recorded 404 paths | `missed_paths` | Possibly | The unresolvable request path and its hit count — **no** IP, user agent, referrer, or actor. A path can still be incidentally identifying (`/invoices/jane-doe`), so rows are purged on retention (below). Vulnerability probing is filtered out before anything is written, and the table is hard-capped per site. See [404 capture](#404-capture-472). |
| Funnel definitions | `funnels`, `funnel_steps` | No | Admin-authored ordered list of content items (landing → pricing → signup, #621). No visitor data, no counter table — step traffic is derived from `content_view_days` at read time. Not on a retention purge; kept until an admin deletes the funnel. |
| Daily experiment buckets | `content_experiment_variant_days` | No | Impression and conversion counters per variant per UTC day (#499) — no visitor data. |
| Sticky assignment bucket | **visitor's browser only** | No (see below) | **Off by default.** When enabled, a `_kiln_ab` cookie holding one integer in `0..99` — a bucket, not an identifier. Nothing server-side is keyed by it and no row is written. See [Sticky assignment](#sticky-assignment-cookie-984). |
| A/B exposure | **visitor's browser only** | Weakly (see below) | **Off by default**, and only for a goal that converts on a *later* page (`content_view`, `funnel_completion`). A `_kiln_ab_x` cookie holding up to 4 variant ids — which arm the visitor was shown — each removed the moment it converts. The one part of this feature with a real, if small, identifying edge; see [Sticky assignment](#sticky-assignment-cookie-984). |

## What data leaves the system

### Webhooks (opt-in, per endpoint)

When configured, a `WebhookEndpoint` receives the **full `ContentSerializer`
payload** (title, slug, blocks, SEO fields, state, audience, locked) on
publish/update.
Requests are HMAC-signed and SSRF-guarded (see `KilnCMS.SafeURL`).

**Audience-gated and passphrase-locked content is included**, with the full block
tree, and the payload marks both gates — `audience` and a derived `locked`
boolean — so a subscriber can filter (#1014). A webhook endpoint is somewhere you
deliberately send content — HMAC-signed, SSRF-guarded — unlike the
anonymously-queryable Meilisearch index, so this is not treated as a leak. But if
your sink feeds a public surface the filtering is yours to do, and it takes both
fields: a document published openly and locked afterwards still reads
`"audience": "public"`.

- **Deletions reach the receiver too:** `<type>.archived`, `<type>.deleted`
  and `<type>.restored` are on by default and carry only the document's
  identity (`id`, `slug`, `locale`, `state`, `updated_at`), so a mirror can
  drop what the site dropped. The opt-in `<type>.created` carries a new
  draft's full body.
**Personal data in non-content events.** `form.submitted` carries the
submitted fields, and `membership.activated` / `membership.canceled` carry the
member's **email** and user id — only to endpoints an admin subscribed to those
events (they are opt-in). The opt-in `security.*` events (#2245) carry the
acting and target user ids of a security log event, its metadata, and its IP
address cut to the network (`/24`, `/48`), or in full when the site turned on
**Show the full IP address in alerts**; never an email address or user agent
([Security alerts](security-alerts.md#payload)). Each delivered payload is kept in the delivery log
for its retention window (30 days by default) so it can be redelivered; GDPR
erasure does not rewrite that log. See
[Paid memberships](memberships.md#webhook-events).

A **Slack-format endpoint** (#2245) receives only `security.*` events, as a
chat message: the alert's headline, the site's name, the time, the address as
above and a link to the console, without user ids. The message lands in a
chat workspace, under that tool's retention, not Kiln's.

Endpoint URLs are stored in full in `webhook_endpoints.url` and in each
delivery row's `endpoint_url`, in the clear. The console, the governance
trail and its exports, notices and logs show them masked
([Webhooks](webhooks.md#see-or-change-an-endpoint-url)).

- **Disable:** delete the webhook endpoint(s) in `/editor/webhooks` (admin only).
  No endpoints configured ⇒ nothing is sent.

### Preview tokens (opt-in, short-lived)

A preview link carries a **signed token** that grants read access to the full
draft JSON (including unpublished blocks) for **1 hour**. The token is bearer
authorization — anyone with the link can view that draft until it expires. The
`/preview` endpoint is tightly rate-limited per IP.

### Transactional & workflow email

These kinds of email leave the system via the configured Swoosh adapter:

- **Auth email** — confirmation, password reset, magic-link sign-in, and a
  site invitation or "you were added to a site" notice (#2135). An invitation
  goes to an address an admin typed, which may belong to someone with no
  account. The invitation mail names the site, the tier and the inviting
  admin's display name ("An administrator" if they have none, never their
  email).
- **Second factor added** (#2247), to the account's own address, whenever an
  authenticator app is set up or replaced or a passkey is added. It names the
  kind of factor, the time, a browser and platform family ("Firefox on
  macOS", reduced from the user agent, which is not sent) and the site it was
  added from; never the secret, recovery codes, or the passkey's name or
  credential id. It goes through the instance relay (`KilnCMS.Mailer`), never
  a site's own, cannot be muted, and is not sent to an erased account
  ([We email you when a second factor is added](two-factor-auth.md#we-email-you-when-a-second-factor-is-added)).
- **Workflow email** — review-requested / published / changes-requested
  notifications to the relevant admins or author.
- **Registration email** (#2251), about a site's registration approval queue:
  - to each of the site's admins, "Registrations are waiting for approval on
    (site)", once an applicant has confirmed their address. It names the site
    and links to the queue and to the setting that mutes it; it carries no
    applicant's address or name. One per admin per unread notice, not one per
    applicant.
  - to the applicant, the decision: approved (with a sign-in link) or "wasn't
    approved", one neutral sentence with no reason and no free text. A
    rejection goes only to an address the applicant has confirmed, and
    nothing goes to an erased account.

  Both are sent for the site, so they go out through the site's own SMTP
  relay when it has one switched on (#1322).
- **Security alert email** (#2245), to a site's member admins about that
  site's alerts and silencing notices, and to every platform admin about the
  platform's alerts ([Security alerts](security-alerts.md)). It names the
  site and what happened, with the time and the client's network (or full
  address, if the site opted in); never another person's email address. It
  always goes through the **instance** relay (`KilnCMS.Mailer`), never a
  site's own: a site admin can change that relay, and alerts about the site
  must not depend on it.

The recipient address is, necessarily, the user's email. The **display name** in
the body is the user's chosen `name`, never the email local-part (#214); with no
name set it renders a neutral "An editor" / "A reviewer". Each user can mute
workflow email per-event in `/editor/settings`, and a site admin can mute the
registration email there (**New registrations**) and the email of site
security alerts (**Security alerts**); the in-app notice is still written.
Platform security alerts and silencing notices cannot be muted.

Configure the sender and adapter in `config/runtime.exs`
(`config :kiln_cms, KilnCMS.Mailer, …` and `:email_from`).

### Optional subprocessors

| Subprocessor | Sends | Enabled by | Disable |
|--------------|-------|-----------|---------|
| **Meilisearch** | **Public** published content only — title, slug, locale, excerpt and the denormalized body (`search_text`), plus `org_id`/`type`/`published_at` facets. No SEO fields and no actor data — never audience-gated or passphrase-locked documents, which are actively removed from the index rather than skipped (#1006, #496). The index has no audience facet and its queries are anonymous, so anything in it is readable by anyone who can reach it. | `config :kiln_cms, KilnCMS.Search.Meilisearch, enabled: true` — or, for one site, that site's admin at `/editor/site-search` (#1558), which sends that site's content to an instance the site chose | `enabled: false` (default) — no content write talks to it. A site's own instance: switch it off or remove it on that page. |
| **S3 / MinIO** | Uploaded media blobs | `config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3` | Default is `KilnCMS.Storage.Local` (no third party). |
| **LLM provider** (SEO drafting) | On an editor's explicit request: the page title, excerpt, headings, existing SEO values and body text (truncated) | `config :kiln_cms, KilnCMS.Seo, generator: …, model: …` — or `SEO_MODEL` | `generator: nil` (default) — no module is called. Pointing `model:` at an on-prem endpoint (`ollama:`/`vllm:`) keeps content in the deployment; Kiln logs a warning at boot and shows an editor notice when the configured provider is third-party. See `docs/seo.md`. |
| **Stripe** (paid memberships) | The member's email address at checkout, and the tier's price id. Card details never touch Kiln — the member is redirected to a provider-hosted page. Kiln stores only the returned customer/subscription ids. | An admin storing API credentials in `/editor/billing` | **Off by default** — with no credentials `KilnCMS.Billing.configured?/0` is false, no tier is offered, the checkout and webhook routes 404, and no request is made. "Disconnect" in the console clears the keys. See [Paid memberships](memberships.md). |
| **kilncms.dev release feed** | **Nothing about this instance.** An unauthenticated GET of kilncms.dev's published `release` entries, sent only when an admin opens `/editor/system` (#1877), or a platform admin opens `/editor/security-posture`, or calls `GET /api/security/posture` with their credential (#2521), while no answer is cached (one background request, which the page does not wait for, #2252). The request carries a bare `KilnCMS` user-agent and a fixed query — no version, no identifier, no content — and kilncms.dev keeps no client IP for that route. Not asked by a fork or mirror (`KILN_UPDATE_REPO` / `KILN_UPDATE_RELEASES_URL` set) unless `KILN_UPDATE_FEED_URL` says so. | **On by default**, with the GitHub check | `KILN_UPDATE_CHECK=false` (both), or `KILN_UPDATE_FEED_URL=false` (this one only) |
| **GitHub (api.github.com)** | **Nothing about this instance.** An unauthenticated GET for the upstream repo's latest release, sent only when an admin opens `/editor/system` (or `/editor/security-posture`, or a platform admin calls `GET /api/security/posture`, with nothing cached) and the kilncms.dev feed above failed or is off. The request carries a bare `KilnCMS` user-agent — no version, no identifier, no content — so GitHub sees only the originating IP. | **On by default** (it needs no credential, so there is no unset secret to imply consent) | `KILN_UPDATE_CHECK=false` |
| **hex.pm** (plugin health check) | **The package name and version of each plugin locked from hex.pm**, in the URL path: two unauthenticated GETs per plugin (`/api/packages/<name>` and `/api/packages/<name>/releases/<version>`), with a bare `KilnCMS` user-agent and nothing else. hex.pm sees them together with the server's IP, so it can tell which plugins this installation runs. Sent only when a platform admin opens `/editor/system`, opens `/editor/security-posture` or calls `GET /api/security/posture` while no answer is cached (one background check), or selects **Check plugins now** (at most one round a minute); cached 24 h per node, 15 min after a failure (#2244). Not sent for git, path, private-repo or `projects/` plugins. | **On by default**, whenever some plugin comes from hex.pm | `KILN_PLUGIN_HEALTH_CHECK=false`, or `KILN_UPDATE_CHECK=false` with `KILN_PLUGIN_HEALTH_CHECK` unset |
| **kilncms.dev security notices feed** (plugin health check and core security notices) | **Nothing about this instance.** An unauthenticated GET of the published `security_notice` entries (up to five pages, same origin only), with a bare `KilnCMS` user-agent and a fixed query. One fetch, cached 24 h per node (15 min after a failure), serves two readers. The plugin health check asks it at the same moments as the hex.pm row, when some plugin comes from Hex, git or a path. The core's notices check (#2522) asks it, with no plugin installed too, when a platform admin opens `/editor/system` or opens `/editor/security-posture` or calls `GET /api/security/posture` (one background request) with nothing cached, or selects **Check now** on System (at most one forced request a minute). Not asked by a fork or mirror, or with `KILN_UPDATE_FEED_URL=false`, unless `KILN_SECURITY_NOTICES_URL` names a feed. | **On by default** | `KILN_SECURITY_NOTICES_URL=false` (both readers). Otherwise each reader has its own switch: `KILN_UPDATE_CHECK=false` stops the core's reader, and the hex.pm row's switches stop the plugin reader. `KILN_PLUGIN_HEALTH_CHECK=false` alone does not stop this request. |
| **The node's DNS resolver** (crawler verification) | **A visitor's IP address**, as a reverse (PTR) query for its `in-addr.arpa` / `ip6.arpa` name, then a forward (A or AAAA) query for up to two of the names it returns that fall under a search engine's domain. Sent only for a public delivery request (a page, `/search`, a media download or stream) whose `User-Agent` names Googlebot, Google-InspectionTool, bingbot, Applebot, YandexBot or Baiduspider, from a public address that is not a trusted proxy, is not in the claimed engine's fresh published IP list (next row), and was not checked recently: at most three queries per address, then cached on that node for 6 h (verified), 1 h (proven false) or 5 min (no answer) (#2254). The queries go to the nameservers in the node's `/etc/resolv.conf` (your host's, your cloud's, or a public resolver you chose), which resolve them through the internet, so the operator of the address's reverse zone (usually its ISP or hosting provider) can also see the query. No user agent, path or other request data is sent. With the smart 404 guard on (`KILN_SCANNER_BLOCKING`), a node whose lookups have had no answer for a minute also sends at most one PTR query a minute for a fixed address, `8.8.8.8` by default, to check that its resolver works; it carries no visitor data (#2588). A DuckDuckBot claim is never sent to DNS: it is checked against DuckDuckGo's published list only (#2586). | **On by default** | `KILN_CRAWLER_VERIFICATION=false` |
| **Google, Microsoft (Bing), Apple and DuckDuckGo** (published crawler IP lists, crawler verification) | **Nothing about this instance or its visitors.** Unauthenticated HTTPS GETs of four fixed URLs (`developers.google.com/static/crawling/ipranges/common-crawlers.json`, `www.bing.com/toolbox/bingbot.json`, `search.developer.apple.com/applebot.json`, `duckduckgo.com/duckduckbot.json`) with a bare `KilnCMS` user-agent and no query, cookie, version or identifier, so each vendor sees only the fetching node's IP address. Sent by one node every 6 hours (`KILN_CRAWLER_RANGES_CRON`), plus a fetch of a missing or stale list that a node queues about 20 seconds after it starts and at its 10-minute checks, at most one job per 10 minutes across the cluster (#2586). The lists are kept in memory only and passed to the other nodes over the cluster's own connection. Visitors' addresses are compared against the lists locally and never sent. | **On by default** (scheduled, unlike the rows above) | `KILN_CRAWLER_RANGES=false`, or `KILN_CRAWLER_VERIFICATION=false`. `KILN_CRAWLER_RANGES_CRON=false` stops the automatic fetches only |

If you enable any of these, add it to your DPA's subprocessor list. Note the
update check (kilncms.dev release feed and GitHub), the security notices
feed, the plugin health check (hex.pm) and crawler verification (the DNS
resolver and the four vendors' published lists) are
the entries that are **on by default**, and the published lists are the one
fetched on a schedule rather than in answer to something a person did. hex.pm learns something about the
installation (which plugins it runs), and crawler verification is the one that
sends a visitor's IP address out: if your resolver is a third party's (a
public resolver, or your cloud's), list it. If your deployment must make no
third-party requests at all, set `KILN_UPDATE_CHECK=false` explicitly rather
than relying on leaving something unset; it turns off the update check, the
core's security notices check and the plugin health check (unless
`KILN_PLUGIN_HEALTH_CHECK` is set). Set `KILN_CRAWLER_VERIFICATION=false` too
(it stops the DNS lookups and the published-list fetches), or
`KILN_CRAWLER_RANGES=false` to stop only the fetches.

## Retention & automated purge

The retention jobs in this table are AshOban triggers wired through the Oban `Cron`
plugin; they run as trusted system jobs (no actor).

| Data | Default retention | Trigger (cron) | Config key |
|------|-------------------|----------------|------------|
| Expired auth tokens | purged within ~24h of expiry | `Token` `:expunge_expired` (`0 4 * * *`) | — (driven by token expiry) |
| Recorded search queries | 90 days since last search | `SearchQuery` `:purge_expired` (`0 3 * * *`) | `config :kiln_cms, :search_analytics, retention_days: 90` |
| Daily view buckets | 400 days since first recorded | `ContentViewDay` `:purge_expired` (`15 3 * * *`) | `config :kiln_cms, :view_analytics, retention_days: 400` |
| Daily referrer buckets | 400 days since first recorded | `ReferrerDay` `:purge_expired` (`30 3 * * *`) | `config :kiln_cms, :view_analytics, retention_days: 400` (shared with view buckets) |
| Recorded 404 paths | 30 days since last hit | `MissedPath` `:purge_expired` (`40 3 * * *`) | `config :kiln_cms, :missed_paths, retention_days: 30` |
| Trashed (soft-deleted) content | 30 days | `Page`/`Post` `:purge_trashed` (`0 3 * * *`) | `config :kiln_cms, :trash, retention_days: 30` |
| Site invitations | 30 days past expiry (expiry is 7 days after the last send) | `Invitation` `:prune_expired` (`35 4 * * *`) | — (fixed, `KilnCMS.Accounts.Invitations.prune_after_days/0`) |

View buckets keep a longer window than search queries on purpose: a bucket is
`(content type, id, UTC day, count)` with no query text and no visitor data, so
the limit is a capacity choice rather than a privacy one, and 400 days is the
smallest window in which year-over-year comparisons always resolve. The all-time
`content_views` counter is never purged, so totals stay correct as buckets age
out — which is also why the two will not sum to the same number.

### Mail job retention

Every mail is queued as an Oban job whose args hold the rendered message,
recipient included. Oban's Pruner deletes finished jobs after 7 days
(`config/config.exs`). Until then the job holds any link the mail carried: a
magic link, a password reset, a sign-in unlock link (#2250), or a site
invitation (#2135), whose token is otherwise stored only as a hash. Backups taken in that window hold them too.

### Security log retention (#2241)

The security log (`security_events`) is pruned daily by
`KilnCMS.Security.PruneWorker` (`20 3 * * *`; `KILN_SECURITY_LOG_PRUNE_CRON`,
`false` disables). The window is per site: 365 days by default, set by an admin on
`/editor/security-log`, and `0` keeps events forever. It holds raw IP addresses
and user agents, so with `0` (or the cron off) they are kept until the person is
erased. It is not one of the AshOban triggers in the table above. The staging
scrub deletes the whole table from a clone. See [Security log](security-events.md).

The instance security log (`instance_security_events`, #2541: events about the
installation rather than a site, such as a canceled backup) is pruned by the
same job, first, on `KILN_INSTANCE_SECURITY_LOG_RETENTION_DAYS` (365 by default,
`0` keeps forever) rather than a site's setting. The staging scrub deletes it
too. See [The instance log](security-events.md#the-instance-log).

The security alert queue (`security_alert_dispatches`, #2245) is pruned every
hour (`17 * * * *`, `AlertDispatch` `:prune`): a row is deleted a day after its
alert window ends. No setting. The staging scrub deletes the whole table.

### Auth token retention (#218)

`User` sets `store_all_tokens? true`: every issued token (sign-in, reset, magic
link, confirmation, and the revocation markers) is persisted in `tokens` so it can
be individually verified and revoked. Each row holds the jti, subject
(`user?id=<uuid>`), purpose, expiry, and any `extra_data`.

A sign-in session's row also carries what the *Active sessions* list in
settings shows (#1823): a browser family and an operating system name
(`"Firefox"`, `"macOS"` — reduced from the user agent, which is not stored),
when the session was last used (written at most every five minutes), and the
jti of the remember-me cookie issued to the same browser, so signing that
session out retires the cookie too. No IP address is recorded. These fields
live and die with the row: the nightly sweep below removes them with it.

Since #2246 a session's row and its remember-me row also record the site
(`org_id`) they signed in on, and a revoked row records why (`revoked_reason`:
`idle` for the site's idle timeout, `admin_sign_out_all` for an admin's "sign
out everyone", empty otherwise), so the sign-in page can tell the person.
`last_used_at` is now also written on the remember-me row, and by signed-in
page requests and console clicks as well as page loads: at most every five
minutes, or every tenth of the site's idle timeout when it has one (never more
often than every 30 seconds). The site's own settings row
(`site_session_policy`) holds two timeouts, when they last changed and when an
admin last signed everyone out; it names no person.

One row in that table is **not** an issued token: `purpose: "pending_sign_in"`
(#743), written once per completed *headless* two-factor sign-in to make the
pending blob single-use. It carries no credential — the jti is a random nonce,
not a JWT — but it is still a timestamped record that a given account completed
a second factor, so it counts as personal data for a DSAR or an erasure review.
It is written independently of `store_all_tokens?`, expires 301 seconds after
the sign-in, and is removed by the same nightly sweep below.

A sign-in unlock link (#2250) is a stored token with `purpose:
"sign_in_unlock"`, written when the link is mailed. Its `extra_data` holds
`act` (`"sign_in_unlock"`), `org` (the id of the site it was asked for on) and
`ed`, an HMAC-SHA256 of the account's email address keyed from the endpoint's
`secret_key_base`. Keyed, so the stored value cannot be matched against a list
of addresses without the server secret. It expires 15 minutes after it is
minted, is revoked when redeemed or when the password is changed or reset, and is
removed by the same nightly sweep. The mailed link itself also sits in the
mail job's args (see *Mail job retention*).

Without cleanup these rows would accumulate forever, so the nightly
`:expunge_expired` trigger (`lib/kiln_cms/accounts/token.ex`) deletes every token
whose `expires_at` has passed. **Operator-visible policy: an expired token is
removed within 24 hours of expiry.** Tighten by lowering the per-strategy token
lifetime (AshAuthentication `token_lifetime`) or raising the cron frequency.

A user erasure (below) additionally **revokes** all of that user's stored tokens
immediately, independent of the nightly job.

### Search query retention (#213) + disclosure (#220)

`search_queries` records the **normalized query text**, locale, a count, and the
last-searched timestamp — recorded only from the editor command palette
(`/editor/search`), and deliberately with **no actor, user id, or IP**. Because
the text itself can contain names, emails, or confidential titles, it is not kept
indefinitely: the `:purge_expired` trigger deletes rows last searched more than
`retention_days` (default 90) ago.

The search palette discloses this to editors inline ("Searches are logged
anonymously … purged after N days"), so the logging is not silent.

### 404 capture (#472)

`missed_paths` records the paths **public delivery couldn't serve**, so
`/editor/redirects` can show an admin what actually broke after a migration and
offer a one-click redirect for it. It is a counter table, not a request log: one
row per `(path, locale)` with a hit count, upserted atomically — a crawler
hammering one dead URL adds one row, not ten thousand.

Stored: the path, its locale, a count, and when it was last seen. **Not** stored:
IP, user agent, referrer, or actor. The path alone can still be incidentally
identifying, so rows are purged `retention_days` (default 30) after their last
hit.

Because anonymous traffic writes this table, three bounds apply, all in
`KilnCMSWeb.MissedPathTracking`:

* **junk filtering** — probe-shaped requests (`/wp-login.php`, `/.env`,
  `/.git/…`, asset extensions, absurd lengths) are dropped before any DB work.
  `.html`/`.htm` are deliberately kept: those are the legacy paths a migration
  off a static site leaves behind;
* **a per-site cap** (`max_paths`, default 5000) — at the cap a new path evicts
  the least-requested row rather than being refused. Refusing would let one
  cheap flood pin the table full of one-hit junk and deny the feature outright;
  with eviction, displacing a genuine row costs an attacker more traffic than
  that row has;
* **off-request writes** — the upsert runs in a supervised task, so delivery
  never waits on it and a spike drops counters rather than queueing 404s.

The path recorded is the one delivery actually resolved against — routed and
percent-decoded, empty segments collapsed — so the tab's one-click redirect
writes a rule that fires, and one URL can't occupy several rows.

Turn the whole thing off with `config :kiln_cms, :missed_paths, enabled: false`;
delivery then does no extra work at all. `enabled` and `max_paths` are read at
runtime; `retention_days` is compile-time (it is baked into the purge filter),
so changing it needs a rebuild. The staging scrub purges the table.

## Subject-rights workflows

### Access / portability (GDPR Art. 15/20)

Any signed-in user can self-export their own data from **`/editor/settings` →
"Export my data"** — and a member from **`/account` → "Export my data"** — which
downloads `kiln-account-export.json` (profile, notification preferences, and paid
memberships; no secrets). The export is deliberately **cross-organization**: it
answers "what do you hold about me" for the whole instance, not just the site the
request arrived on. Programmatically this is
`KilnCMS.Accounts.export_user_data/1`, served by
`KilnCMSWeb.AccountController.export/2` (scoped to `current_user`).

### Erasure (GDPR Art. 17) — anonymization

Erasure is implemented as **anonymization**, not row deletion, so it reconciles
with audit-retention obligations (below). It is the `:anonymize` action, and it
runs in two ways:

- **A platform admin** runs `KilnCMS.Accounts.anonymize_user(user, actor: admin)`
  ([Removing an account](account-administration.md#removing-an-account)).
- **Rejecting a registration** (#2514), on a site whose **When you reject
  someone** setting is **Erase the account if the email address was never
  confirmed**, erases an applicant who never confirmed their address and whose
  account is nothing but that application. A standing site or platform admin
  rejects; the erasure runs in the same transaction as the `:registrations`
  system actor, which may erase that one account and no other
  ([Erase unconfirmed applicants you reject](account-administration.md#erase-unconfirmed-applicants-you-reject)).

Either way, it:

1. Replaces the email with a unique non-routable tombstone
   (`anonymized-<id>@deleted.invalid`) and clears the display name.
2. Scrambles the password hash so the credentials can never sign in again.
3. Resets the role to the least-privileged `:viewer` and restores default
   notification preferences.
4. Stamps `anonymized_at`.
5. **Revokes** every stored auth token for the subject (logs out everywhere,
   removes token PII).
6. **Nulls `actor_id`** on the user's `document_events` and
   `billing_membership_events`, so both audit trails keep the *what* without the
   *who*.
7. **Clears `audiences`**, so a tombstoned account keeps no read access. (Before
   #337 Phase 2 this was missed: credentials were destroyed while access
   survived.) Since #2514 it is cleared in its own statement: before, the
   cleared value was dropped when the caller's copy of the account already
   read `[]` while the stored row had audiences (granted by a billing
   recompute after that copy was read), so the stored audiences survived until
   the next recompute.
8. **Cancels every paid membership** and drops the stored provider customer and
   subscription ids. Without this, a late webhook or the nightly reconcile would
   recompute entitlements and re-grant access to the erased account.
9. **Blanks their name in other people's in-app notifications** — nulls
   `actor_name` and `actor_id` on every `notifications` row the user caused, on
   every site. The name was copied into each recipient's inbox when the event
   happened, so scrubbing `users.name` alone left it there. The rows stay and
   render a neutral "An editor".

10. **Scrubs the security log** (`security_events`, #2241) on every site: on
    each event the user acted in it nulls `actor_id`, `actor_label` (the email
    snapshot), `ip` and `user_agent`; on each event that names them as its target
    it nulls `target_id`; and it empties `metadata` on every event it touches. The
    event itself (type and time) stays. The instance security log
    (`instance_security_events`, #2541) is scrubbed the same way in the same
    sweep. If any site's sweep, or the instance log's, fails, the erasure
    raises so it can be retried. See [Security log](security-events.md#privacy-ip-addresses-erasure-and-staging).
11. **Deletes its Web Push subscriptions** (#2514): each is a way to reach the
    person's device, and nothing needs it once they are gone.
12. **Deletes its private saved views** (#2514), on every site. Shared views
    are the team's filters and stay, as authored content does; their owner is
    the anonymized account, which names nobody.
13. **Deletes the notifications addressed to it** (#2514), on every site: its
    own inbox, which nobody can sign in to read any more. If any site's delete
    fails, the erasure raises so it can be retried.

Erasure works on an account, and an invitation is not one: an invitation to
the person's address is left as it is. To remove one, revoke it on **Team**
(`/editor/team`) on the invited site, or let it expire and be pruned. An
invitation the erased user *sent* keeps pointing at their (now anonymous)
account, and an admin-tier one can no longer be accepted.

The account **row is retained** (with no personal data) so authorship links and
referential integrity in content/version history are preserved. Membership rows
are likewise retained, scrubbed, so the entitlement audit trail stays
referentially intact.

> **Operator action required: cancel the subscription at the payment provider.**
> Step 8 is **local only** — Kiln does not call the provider during erasure. Two
> reasons: erasure runs inside a database transaction and must not depend on a
> third party being reachable, and the same code path is used by
> `KilnCMS.Staging.Scrub` over a *clone* of production, where cancelling would
> terminate real customers' billing from a staging environment.
>
> So after erasing a paying member, **cancel or refund their subscription in the
> provider's dashboard**. Until you do, they remain billed. Kiln keeps no
> invoices; invoice retention is the provider's obligation as controller of its
> own records.

## Audit trail vs. user erasure (#219)

KilnCMS keeps two overlapping history substrates, both of which can reference a
user:

- **`document_events`** — append-only block-level events powering fine-grained
  history and time-travel. Each event carries `actor_id`.
- **AshPaperTrail versions** — the publish/restore snapshot anchor, which records
  the acting user and the full content at each version.

These exist for **integrity and audit** (who changed what, and the ability to
restore), which is a legitimate-interest / legal-obligation basis for retaining
some actor reference even after an erasure request. KilnCMS's policy balances the
two as follows:

- **`document_events.actor_id` is anonymized (nulled)** on erasure — the event
  (the content change) is retained, the personal link is removed.
- **PaperTrail version content is retained** as the audit record. Versions are
  not rewritten on erasure; treat them as audit data with the same retention as
  your backup/audit policy. If a regulator requires erasure to reach version
  metadata, apply a **legal-hold review** and prune versions out of band — this is
  a deliberate manual step, not automated, so an erasure cannot silently destroy
  the audit anchor.

Document your chosen audit-retention period (e.g. "content versions are retained
for N years for audit, then pruned") in your records-of-processing; KilnCMS does
not impose one because it is jurisdiction- and policy-dependent.

## Sticky assignment cookie (#984)

Content experiments (#499) are stateless by default: a variant is drawn per
request, nothing is stored, and no visitor is identified. That is what keeps the
"no cookie is recorded for visitors" claim above literally true — but it also
means a reload can show a different arm, so only a *same-page* goal
(`:form_submission`) can be attributed honestly.

**Sticky assignment** is the opt-in that trades that away:

```elixir
config :kiln_cms, KilnCMS.Experiments, sticky: true
```

| | |
|---|---|
| **What is stored** | `_kiln_ab` — one integer in `0..99`. And, only where a goal that converts on a later page is running (`content_view` or `funnel_completion`), `_kiln_ab_x` — up to four variant ids. |
| **Where** | The visitor's browser only. No database row, no log line, nothing server-side is keyed by either. |
| **How long** | 30 days by default; set `sticky_max_age_days:` to shorten it. |
| **Why** | `_kiln_ab` so a returning visitor keeps the same arm instead of re-drawing, which is what makes their behaviour across a visit comparable between arms. `_kiln_ab_x` because a conversion that happens on a *later* page can only be attributed to an arm the visitor is known to have seen. |
| **Flags** | `http_only`, `SameSite=Lax`, `Path=/`, and — wherever the deployment's cookies are `Secure` — `Secure` plus the `__Host-` name prefix, so a sibling org's origin cannot plant one. |

**It is a bucket, not an identifier.** With only 100 possible values, every value
is shared by a large share of your visitors on any site with meaningful traffic,
so it cannot single anybody out. It is deliberately *not* signed or encrypted: a
signature would derive from the deployment secret and make the value unique-ish
and opaque, which is the opposite of what a bucket wants to be. A visitor who
edits it picks their own arm — exactly the power they already have by clearing it.

**`_kiln_ab_x` is the weaker claim, and it is worth stating rather than
glossing.** It names which arm you saw, so its value space is the set of arms of
the running later-page experiments — with one such experiment it tells an
observer nothing beyond which arm you are in, but with several the *combination*
starts to narrow a visitor down. That is why it is capped at four entries, why an
entry is deleted the moment it converts, and why it is written only for the one
goal that cannot work without it. It is also the only one of the two your cookie
notice needs to describe as more than a bucket.

Both cookies are minted **only on a page that is actually under experiment**, and
only when a visitor arrives without a valid one. An ordinary page — nearly every
page — sets nothing, so turning the switch on does not put a marker on your whole
site. A returning visitor's cookies are read and not re-set, so their lifetime is
bounded rather than rolling.

One operational cost, since it is easy to miss: a `content_view` or
`funnel_completion` experiment takes the **goal** page out of your CDN for its
duration as well as the experimented page, because the conversion is counted at
the origin. For a funnel goal the goal page is the funnel's *final step*.

> **Consent is yours to decide.** KilnCMS ships this off and does not render a
> consent banner. Whether these cookies — used solely to keep an A/B arm stable
> and attribute its outcome — are "strictly necessary" under your regime, and
> therefore whether you need consent before enabling them, is a judgement for
> your DPO and not a default we can make for you. If you enable them, put **both
> names** in your cookie notice, and gate the config on your consent mechanism if
> your assessment says so.

## Transport & at-rest notes

- **Session cookie** (`__Host-_kiln_cms_key` in production, `_kiln_cms_key` in
  dev, test and e2e over plain HTTP) is both **signed and encrypted** (#217), so its
  contents are neither tamperable nor readable client-side. Both salts derive
  keys from `secret_key_base`; rotating that invalidates existing sessions. The
  `__Host-` prefix keeps a sibling org's origin from shadowing it (#686).
  Since #2247 a signed-in session also holds a sign-in marker under
  `"sign_in"`: the session token's `jti`, how it signed in (`password`,
  `magic_link`, `sso`, `password_reset`, `passkey`, `remember_me`, …) and,
  when one was verified, the Unix time of the second factor. No address, no
  device and nothing about the factor itself. It lives in the cookie only, is
  never written to the database, and is cleared with the rest of the session
  at sign-out.
- **Content-unlock cookie** (`_kiln_unlock`, #496) — the only cookie a *visitor*
  can end up with, and only ever by typing a passphrase into a page an editor
  locked. It is signed and http-only, expires in 12 hours, and holds short-lived
  grant tokens naming *documents' passphrases* — a `sha256` of a bcrypt hash.

  It contains **no identifier of any kind**: two visitors who unlock the same
  page hold byte-identical cookies, so it cannot distinguish them and there is
  nothing in it to join to anything else. Nothing reads it but the unlock check;
  no analytics counter is keyed on it. Rotating the passphrase (or
  `secret_key_base`) invalidates every outstanding grant.

  If your policy requires a cookie banner, this is strictly-necessary state for
  a feature the visitor asked for. Deployments that never lock a page never set
  it.
- **Uploaded images are metadata-stripped on upload** (#215): EXIF/GPS, camera
  info, and the original client filename are removed from the stored original and
  every generated variant (`KilnCMS.ImageProcessor.strip_metadata/2`).
- **Media is served with `Content-Disposition: attachment` + `nosniff`** so a
  stored file can't be interpreted as active content in the app origin.

## Quick operator checklist

- [ ] Reviewed configured webhook endpoints (`/editor/webhooks`).
- [ ] Decided on Meilisearch / S3 / Stripe — listed as subprocessors if enabled.
- [ ] If memberships are sold: know that erasing a member does **not** cancel
      their subscription at the provider — do that in the provider's dashboard.
- [ ] Set `search_analytics.retention_days`, `view_analytics.retention_days`
      (shared by daily view and referrer buckets) and `trash.retention_days`
      to policy.
- [ ] Decided whether referrer attribution is worth enabling
      (`KILN_ANALYTICS_REFERRERS`, off by default, #619).
- [ ] Decided whether [sticky A/B assignment](#sticky-assignment-cookie-984) is
      worth a visitor cookie (`sticky:`, off by default, #984) — and if so,
      whether your regime wants consent for it first.
- [ ] Documented your content-version (PaperTrail) audit-retention period.
- [ ] Know the two subject-rights paths: self-export (`/editor/settings`) and
      admin erasure (`anonymize_user`).

## Staging / preview environments

Non-production copies of the database are a privacy concern too: a naive `pg_dump`
of production carries every editor's email, live API keys, webhook signing secrets,
the DKIM private key, **and live payment-provider credentials and subscription
ids** into a less-locked-down box. KilnCMS ships a **scrub** that
reuses the `:anonymize` erasure action above (plus the same retention purges) to make
a clone PII-free and secret-free by default. See
[`staging-environments.md`](staging-environments.md).
