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
  cookie is recorded for visitors.
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
| Aggregate view counts | `content_views` | No | One upserting counter per content item — no visitor data. |

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

If you enable either, add it to your DPA's subprocessor list.

## Retention & automated purge

All three retention jobs are AshOban triggers wired through the Oban `Cron`
plugin; they run as trusted system jobs (no actor).

| Data | Default retention | Trigger (cron) | Config key |
|------|-------------------|----------------|------------|
| Expired auth tokens | purged within ~24h of expiry | `Token` `:expunge_expired` (`0 4 * * *`) | — (driven by token expiry) |
| Recorded search queries | 90 days since last search | `SearchQuery` `:purge_expired` (`0 3 * * *`) | `config :kiln_cms, :search_analytics, retention_days: 90` |
| Trashed (soft-deleted) content | 30 days | `Page`/`Post` `:purge_trashed` (`0 3 * * *`) | `config :kiln_cms, :trash, retention_days: 30` |

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

## Subject-rights workflows

### Access / portability (GDPR Art. 15/20)

Any signed-in user can self-export their own data from **`/editor/settings` →
"Export my data"**, which downloads `kiln-account-export.json` (profile +
notification preferences; no secrets). Programmatically this is
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
6. **Nulls `actor_id`** on the user's `document_events` so the audit trail keeps
   the *what* without the *who*.

The account **row is retained** (with no personal data) so authorship links and
referential integrity in content/version history are preserved.

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

## Transport & at-rest notes

- **Session cookie** (`_kiln_cms_key`) is both **signed and encrypted** (#217), so
  its contents are neither tamperable nor readable client-side. Both salts derive
  keys from `secret_key_base`; rotating that invalidates existing sessions.
- **Uploaded images are metadata-stripped on upload** (#215): EXIF/GPS, camera
  info, and the original client filename are removed from the stored original and
  every generated variant (`KilnCMS.ImageProcessor.strip_metadata/2`).
- **Media is served with `Content-Disposition: attachment` + `nosniff`** so a
  stored file can't be interpreted as active content in the app origin.

## Quick operator checklist

- [ ] Reviewed configured webhook endpoints (`/editor/webhooks`).
- [ ] Decided on Meilisearch / S3 — listed as subprocessors if enabled.
- [ ] Set `search_analytics.retention_days` and `trash.retention_days` to policy.
- [ ] Documented your content-version (PaperTrail) audit-retention period.
- [ ] Know the two subject-rights paths: self-export (`/editor/settings`) and
      admin erasure (`anonymize_user`).

## Staging / preview environments

Non-production copies of the database are a privacy concern too: a naive `pg_dump`
of production carries every editor's email, live API keys, webhook signing secrets,
and the DKIM private key into a less-locked-down box. KilnCMS ships a **scrub** that
reuses the `:anonymize` erasure action above (plus the same retention purges) to make
a clone PII-free and secret-free by default. See
[`staging-environments.md`](staging-environments.md).
