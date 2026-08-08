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
  [Transport & at-rest notes](#transport--at-rest-notes)), and
  [sticky A/B assignment](#sticky-assignment-cookie-984) is an opt-in that is off
  unless you turn it on.
- The only personal data we store is **operator/editor account data** (email,
  optional display name, RBAC role, notification preferences) and **auth tokens**.
- Data only leaves the system through integrations you explicitly enable
  (webhooks, optional Meilisearch/S3) or through transactional email.
- Retention is bounded and automated: expired auth tokens, recorded search
  queries, and trashed content are all purged on a schedule.

## What personal data we store

| Data | Where | Personal? | Notes |
|------|-------|-----------|-------|
| Account email | `users` | Yes | Login identity; also the email recipient for workflow mail. |
| Display name | `users.name` | Yes (optional) | Shown to other editors (presence) and as the JSON-LD author byline. Blank by default. |
| RBAC role | `users.role` | No | `:admin` / `:editor` / `:viewer`. |
| Notification preferences | `users.notify_on_*` | No | Per-user opt-out (issue #46). |
| Auth tokens | `tokens` | Pseudonymous | jti, subject (`user?id=<uuid>`), purpose, expiry. See [Auth tokens](#auth-token-retention-218). |
| Audit / version history | `document_events`, AshPaperTrail versions | Pseudonymous | Carries `actor_id`. See [Audit trail vs erasure](#audit-trail-vs-user-erasure-219). |
| Recorded search queries | `search_queries` | Possibly | Query text only — **no** actor/IP. See [Search query retention](#search-query-retention-213--disclosure-220). |
| Consumer audiences | `users.audiences`, `org_memberships.audiences` | No | Which gated content a reader may see. Granted by an admin or by an active paid membership. Cleared on erasure. |
| Paid memberships | `billing_memberships` | Pseudonymous | Status, period end, and the payment provider's customer/subscription ids. See [Payments](#payments-337). |
| Entitlement audit trail | `billing_membership_events` | Pseudonymous | Status transitions and the audience delta, with the causing provider event id. `actor_id` nulled on erasure. |
| Recorded payment webhooks | `billing_webhook_events` | Yes (transient) | The provider's full event payload, which can carry a customer email and amounts. Purged on retention and by the staging scrub. |
| Aggregate view counts | `content_views` | No | One upserting counter per content item — no visitor data. |
| Daily view buckets | `content_view_days` | No | One counter per content item per UTC day, for 7d/30d trends — no visitor data. Purged on retention (below). |
| Daily referrer buckets | `referrer_days` | No | One counter per content item per coarse source category (`direct`/`internal`/`search`/`social`/`other`) per UTC day — never a raw referrer URL or host. Off by default (`KILN_ANALYTICS_REFERRERS`, #619); turning it back off stops new writes but does not clear rows already recorded — those still age out on the retention purge (below). |
| Recorded 404 paths | `missed_paths` | Possibly | The unresolvable request path and its hit count — **no** IP, user agent, referrer, or actor. A path can still be incidentally identifying (`/invoices/jane-doe`), so rows are purged on retention (below). Vulnerability probing is filtered out before anything is written, and the table is hard-capped per site. See [404 capture](#404-capture-472). |
| Funnel definitions | `funnels`, `funnel_steps` | No | Admin-authored ordered list of content items (landing → pricing → signup, #621). No visitor data, no counter table — step traffic is derived from `content_view_days` at read time. Not on a retention purge; kept until an admin deletes the funnel. |
| Daily experiment buckets | `content_experiment_variant_days` | No | Impression and conversion counters per variant per UTC day (#499) — no visitor data. |
| Sticky assignment bucket | **visitor's browser only** | No (see below) | **Off by default.** When enabled, a `_kiln_ab` cookie holding one integer in `0..99` — a bucket, not an identifier. Nothing server-side is keyed by it and no row is written. See [Sticky assignment](#sticky-assignment-cookie-984). |
| A/B exposure | **visitor's browser only** | Weakly (see below) | **Off by default**, and only for a `content_view` goal. A `_kiln_ab_x` cookie holding up to 4 variant ids — which arm the visitor was shown — each removed the moment it converts. The one part of this feature with a real, if small, identifying edge; see [Sticky assignment](#sticky-assignment-cookie-984). |

## What data leaves the system

### Webhooks (opt-in, per endpoint)

When configured, a `WebhookEndpoint` receives the **full `ContentSerializer`
payload** (title, slug, blocks, SEO fields, state) on publish/update. Requests are
HMAC-signed and SSRF-guarded (see `KilnCMS.SafeURL`).

- **Disable:** delete the webhook endpoint(s) in `/editor/webhooks` (admin only).
  No endpoints configured ⇒ nothing is sent.

### Preview tokens (opt-in, short-lived)

A preview link carries a **signed token** that grants read access to the full
draft JSON (including unpublished blocks) for **1 hour**. The token is bearer
authorization — anyone with the link can view that draft until it expires. The
`/preview` endpoint is tightly rate-limited per IP.

### Transactional & workflow email

Two kinds of email leave the system via the configured Swoosh adapter:

- **Auth email** — confirmation, password reset, magic-link sign-in.
- **Workflow email** — review-requested / published / changes-requested
  notifications to the relevant admins or author.

The recipient address is, necessarily, the user's email. The **display name** in
the body is the user's chosen `name`, never the email local-part (#214); with no
name set it renders a neutral "An editor" / "A reviewer". Each user can mute
workflow email per-event in `/editor/settings`.

Configure the sender and adapter in `config/runtime.exs`
(`config :kiln_cms, KilnCMS.Mailer, …` and `:email_from`).

### Optional subprocessors

| Subprocessor | Sends | Enabled by | Disable |
|--------------|-------|-----------|---------|
| **Meilisearch** | Published content (title, blocks, SEO) for the search index | `config :kiln_cms, KilnCMS.Search.Meilisearch, enabled: true` | `enabled: false` (default) — no content write talks to it. |
| **S3 / MinIO** | Uploaded media blobs | `config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3` | Default is `KilnCMS.Storage.Local` (no third party). |
| **LLM provider** (SEO drafting) | On an editor's explicit request: the page title, excerpt, headings, existing SEO values and body text (truncated) | `config :kiln_cms, KilnCMS.Seo, generator: …, model: …` — or `SEO_MODEL` | `generator: nil` (default) — no module is called. Pointing `model:` at an on-prem endpoint (`ollama:`/`vllm:`) keeps content in the deployment; Kiln logs a warning at boot and shows an editor notice when the configured provider is third-party. See `docs/seo.md`. |
| **Stripe** (paid memberships) | The member's email address at checkout, and the tier's price id. Card details never touch Kiln — the member is redirected to a provider-hosted page. Kiln stores only the returned customer/subscription ids. | An admin storing API credentials in `/editor/billing` | **Off by default** — with no credentials `KilnCMS.Billing.configured?/0` is false, no tier is offered, the checkout and webhook routes 404, and no request is made. "Disconnect" in the console clears the keys. See [Paid memberships](memberships.md). |
| **GitHub (api.github.com)** | **Nothing about this instance.** An unauthenticated GET for the upstream repo's latest release, sent only when an admin opens `/editor/system`. The request carries a bare `KilnCMS` user-agent — no version, no identifier, no content — so GitHub sees only the originating IP. | **On by default** (it needs no credential, so there is no unset secret to imply consent) | `KILN_UPDATE_CHECK=false` |

If you enable any of these, add it to your DPA's subprocessor list. Note the
update check is the one entry that is **on by default**: if your deployment must
make no third-party requests at all, set `KILN_UPDATE_CHECK=false` explicitly
rather than relying on leaving something unset.

## Retention & automated purge

All five retention jobs are AshOban triggers wired through the Oban `Cron`
plugin; they run as trusted system jobs (no actor).

| Data | Default retention | Trigger (cron) | Config key |
|------|-------------------|----------------|------------|
| Expired auth tokens | purged within ~24h of expiry | `Token` `:expunge_expired` (`0 4 * * *`) | — (driven by token expiry) |
| Recorded search queries | 90 days since last search | `SearchQuery` `:purge_expired` (`0 3 * * *`) | `config :kiln_cms, :search_analytics, retention_days: 90` |
| Daily view buckets | 400 days since first recorded | `ContentViewDay` `:purge_expired` (`15 3 * * *`) | `config :kiln_cms, :view_analytics, retention_days: 400` |
| Daily referrer buckets | 400 days since first recorded | `ReferrerDay` `:purge_expired` (`30 3 * * *`) | `config :kiln_cms, :view_analytics, retention_days: 400` (shared with view buckets) |
| Recorded 404 paths | 30 days since last hit | `MissedPath` `:purge_expired` (`40 3 * * *`) | `config :kiln_cms, :missed_paths, retention_days: 30` |
| Trashed (soft-deleted) content | 30 days | `Page`/`Post` `:purge_trashed` (`0 3 * * *`) | `config :kiln_cms, :trash, retention_days: 30` |

View buckets keep a longer window than search queries on purpose: a bucket is
`(content type, id, UTC day, count)` with no query text and no visitor data, so
the limit is a capacity choice rather than a privacy one, and 400 days is the
smallest window in which year-over-year comparisons always resolve. The all-time
`content_views` counter is never purged, so totals stay correct as buckets age
out — which is also why the two will not sum to the same number.

### Auth token retention (#218)

`User` sets `store_all_tokens? true`: every issued token (sign-in, reset, magic
link, confirmation, and the revocation markers) is persisted in `tokens` so it can
be individually verified and revoked. Each row holds the jti, subject
(`user?id=<uuid>`), purpose, expiry, and any `extra_data`.

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
with audit-retention obligations (below). An **admin** runs
`KilnCMS.Accounts.anonymize_user(user, actor: admin)` (the `:anonymize` action).
It:

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
   survived.)
8. **Cancels every paid membership** and drops the stored provider customer and
   subscription ids. Without this, a late webhook or the nightly reconcile would
   recompute entitlements and re-grant access to the erased account.

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
| **What is stored** | `_kiln_ab` — one integer in `0..99`. And, only where a `content_view` goal is running, `_kiln_ab_x` — up to four variant ids. |
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
the running `content_view` experiments — with one such experiment it tells an
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

One operational cost, since it is easy to miss: a `content_view` experiment takes
the **goal** page out of your CDN for its duration as well as the experimented
page, because the conversion is counted at the origin.

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
