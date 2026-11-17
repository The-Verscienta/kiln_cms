# Ephemeral staging / preview environments

Stand up a throwaway copy of your **production content** to test an upgrade, try a
migration, review a redesign, or reproduce a bug — then throw it away. The copy is
**scrubbed of personal data and outbound secrets by default**, so it is safe to run
somewhere less locked-down than production and to hand to a reviewer, once you have
checked the few things it keeps ([What the scrub keeps](#what-the-scrub-keeps)).

This is the actionable, self-host-friendly slice of the "managed cloud / hosting"
discussion ([#334](https://github.com/The-Verscienta/kiln_cms/issues/334)). A hosted
SaaS offering (billing, a control plane, multi-tenancy — [#336](https://github.com/The-Verscienta/kiln_cms/issues/336))
is a product/business decision and is **not** built here; a documented "clone prod →
ephemeral env" flow is useful to every operator regardless, so that's what this is.

## TL;DR

```bash
# One command: dump prod → restore into a throwaway DB → migrate → scrub → print how to serve
PROD_DATABASE_URL="postgres://…/kiln_prod" \
STAGING_DATABASE_URL="postgres://…/kiln_staging" \
STAGING_ADMIN_EMAIL="you@example.com" STAGING_ADMIN_PASSWORD="a-strong-password" \
  ./scripts/staging.sh up

# …point a Kiln instance at STAGING_DATABASE_URL and serve it…

# When you're done:
STAGING_DATABASE_URL="postgres://…/kiln_staging" ./scripts/staging.sh down
```

The scrub reuses the existing privacy work — the GDPR-erasure `:anonymize` action and
the retention purges documented in [`data-flows.md`](data-flows.md) — so staging data
is PII-free using the same code path production erasure uses. Nothing new decides
"what counts as personal data"; it's the one definition.

## The flow

```
 production DB                    throwaway staging DB
┌──────────────┐   pg_dump   ┌──────────────────────────┐
│  real data   │ ──────────▶ │  clone                    │
│  + PII       │             │  → migrate (catch up)     │
└──────────────┘             │  → SCRUB (this repo)      │  ← PII + secrets removed
                             │  → serve (Kiln instance)  │
                             │  → drop when done         │
                             └──────────────────────────┘
```

1. **Clone** — `pg_dump` production into a fresh, throwaway database. The dump carries
   the schema, the required extensions (`vector`, `pg_trgm`, `citext`), and the data.
2. **Migrate** — run pending migrations against the clone so it matches the image you're
   about to run (`bin/migrate`, i.e. `KilnCMS.Release.migrate` — same step prod runs at
   boot). Harmless if the clone is already current.
3. **Scrub** — remove personal data and outbound secrets (below). **Do this before you
   expose the environment.**
4. **Serve** — start a Kiln instance with `DATABASE_URL` pointing at the clone. Keep
   outbound integrations off (they are off by default — see *What's already safe by default* below).
5. **Tear down** — drop the throwaway database. Nothing else persists.

## The scrub

`KilnCMS.Staging.Scrub` is the one place that turns a production clone into a
safe-to-share environment. Everything it does is a purge or a de-activation — it never
sends mail, fires a webhook, or contacts a subprocessor, and it deletes every queued job
so that nothing on the clone does so later on production's behalf.

| What | Action | Why |
|------|--------|-----|
| **User accounts** | `:anonymize` (per user) — the GDPR-erasure action (`users_anonymized`) | Emails → non-routable tombstones, names cleared, passwords scrambled, roles reset to `:viewer`, auth-event actors nulled. The exact production erasure path (`data-flows.md`). |
| **API keys** | purged (`api_keys_purged`) | Live `kiln_*` credentials would otherwise grant API access to the staging copy (and are secrets in their own right). |
| **Auth tokens** | purged (`tokens_purged`) | Session / reset / magic-link tokens are stale in a clone and are pseudonymous PII. |
| **Webhook endpoints** | de-activated (`webhooks_deactivated`) | A clone must **never** fire deliveries at production consumers' URLs on the next publish. De-activation is data-only (no SSRF DNS re-check). |
| **Mail settings** | purged, singleton row (`mail_settings_purged`) | Drops the **encrypted DKIM private key** and server IP so staging can't sign mail as your production domain. Recreated blank on next read (`KilnCMS.Mail.ensure_settings!/0`). |
| **Site invitations** | purged (`invitations_purged`) | Each names a production address, and its link would set up an account on the clone for whoever holds the mail. |
| **Recorded search queries** | purged (`search_queries_purged`) | Query text can contain names, emails, or confidential titles ([#213/#220](data-flows.md)). |
| **Recorded 404 paths** | purged (`missed_paths_purged`) | Traffic data about the *production* site, and a path can be incidentally identifying (`/invoices/jane-doe`). See [404 capture](data-flows.md#404-capture-472). |
| **Payment credentials** | purged, singleton row (`billing_settings_purged`) | Live provider API and webhook-signing keys. Removed **first**, before anything else touches billing rows, so a clone can never act on a real payment account. |
| **Recorded payment webhooks** | purged (`billing_events_purged`) | The provider's raw event payloads carry customer emails and amounts. |
| **Backup history** | purged (`backup_runs_purged`) | Records where production's backups go (rclone destinations), who started them, and their errors. The staging host's own backups start a [history](backups.md#backup-history-2217) of their own. |
| **In-app backup schedules** | paused (`backup_schedules_disabled`) | A clone must not run production's [backup schedules](backups.md#schedule-backups-in-the-app) against the staging host's backup directory. Paused rather than deleted, so whoever runs staging can see them and resume one on the Backups page's Schedule tab or from a console (part of #2219). |
| **Backup destinations** | purged (`backup_destinations_purged`) | The off-site places production's in-app backups go, with their encrypted credentials. A clone must not hold them, test them, or back up to (and prune) production's destinations. Deleted rather than paused (#2220). |
| **Security log** | purged (`security_events_purged`) | Raw IP addresses, user agents and email snapshots of production's sign-ins: personal data a clone must not carry. See [the security log](security-events.md#privacy-ip-addresses-erasure-and-staging). |
| **Instance security log** | purged (`instance_security_events_purged`) | The same columns for events about the installation: platform admins' addresses and IPs. See [the instance log](security-events.md#the-instance-log). |
| **Security alert dispatches** | purged (`security_alert_dispatches_purged`) | A [security alert](security-alerts.md) still to be sent would mail and notify production's admins from the clone, about production events. |
| **Paid memberships** | scrubbed (`memberships_scrubbed`) | Provider customer/subscription ids nulled and the status set to canceled. **Scrubbed, not deleted**: `billing_membership_events` references them, and the entitlement trail should stay referentially intact — the same audit-retention decision as content history. What must go is the live external reference. |
| **Membership tiers** | deactivated (`tiers_deactivated`) | The catalogue shape keeps staging useful; the price pointer is replaced with a per-row tombstone so nothing in the clone can bill a real account. (Per-row because `provider_price_id` is `NOT NULL` with a per-org unique index.) |
| **Queued jobs** | purged, every state (`oban_jobs_purged`) | A cloned job is production's work: its args carry recipients, message bodies, form data and outbound URLs, and running it on the clone would mail, notify or call out on production's behalf. Deleted rather than canceled, because a canceled job keeps its args. Purged first, before anything else runs, and again last, for any job the scrub's own work queued. `scripts/staging.sh up` doesn't copy the rows in the first place. |
| **Newsletter subscribers** | purged (`newsletter_subscribers_purged`) | Readers' addresses and names, with live confirm and unsubscribe tokens. |
| **Newsletter segment memberships** | purged (`newsletter_segment_memberships_purged`) | Which subscriber is in which segment. Deleted before the subscribers; the segments themselves stay. |
| **Form submissions** | purged (`form_submissions_purged`) | Free-form visitor input: whatever a contact form asked for, names and addresses included. The forms and their fields stay. |
| **Form notification addresses** | cleared (`form_notify_emails_cleared`) | Each form's `notify_email` is a production inbox. The form stays, with no address to mail. |
| **Mail suppression list** | purged (`suppressed_recipients_purged`) | The instance's list of addresses not to mail: recipients' addresses and nothing else. |
| **Per-site mail suppression lists** | purged (`site_suppressed_recipients_purged`) | The same, per site. |
| **Webhook delivery log** | purged (`webhook_deliveries_purged`) | Each delivery keeps its payload, and a `form.submitted` payload is the submission itself. |
| **Federation deliveries** | purged (`federation_deliveries_purged`) | Pending deliveries would post production's activities to real fediverse inboxes. |
| **Federation followers** | purged (`federation_followers_purged`) | Remote people's actor and inbox URIs. |
| **Site federation identities** | purged (`federation_sites_purged`) | Each row holds the private key that signs as the production site's actor. With it gone, the clone federates with no one. |
| **Web Push subscriptions** | purged (`push_subscriptions_purged`) | Browsers' push endpoints and keys. Anonymizing an account already deletes its subscriptions; this catches any row that step did not reach. |
| **Web Push (VAPID) keys** | purged (`vapid_keys_purged`) | Each site's push identity, production's. |
| **Social accounts** | deactivated (`social_accounts_deactivated`) | Switched off and their stored credential removed, so the clone cannot post as production. Not deleted, because deleting an account deletes its post history with it. |
| **Automation rules** | deactivated (`automation_rules_disabled`) | Every rule is switched off, and a `send_email` rule loses its `to` address, a production inbox. The rules stay so you can see them. |
| **Per-site mail relays** | purged (`mail_relays_purged`) | Production's relay host, username, encrypted password and From address. A site with no row falls back to the staging host's own mail configuration, as the mail settings purge does. |
| **Per-site SSO providers** | purged (`sso_providers_purged`) | Production's identity provider (issuer, client id) and its encrypted client secret. |
| **Per-site AI providers** | purged (`ai_providers_purged`) | Production's AI provider, base URL and encrypted API key. |
| **Per-site Meilisearch settings** | purged (`meilisearch_sites_purged`) | Production's Meilisearch URL, index name and encrypted API key: the clone must not write into production's index. |
| **Rate-limit counters** | purged (`throttle_counters_purged`) | Keyed on hashed client identifiers from production traffic. |
| **Idempotency keys** | purged (`idempotent_requests_purged`) | Each row caches the response production sent, which carries whatever that response did. |
| **Backup lock** | purged (`backup_locks_purged`) | Names production's nodes and backup jobs the scrub deletes. An empty table is a free lock for the staging host's own backups. |
| **Backup node heartbeats** | purged (`backup_node_beats_purged`) | Production's node ids. |
| **Backup notices** | purged (`backup_notices_purged`) | Production's retention and held-backup warnings, naming its backup directories and destinations. The staging host's own backups report their own (#2487). |
| **A fresh staging admin** | provisioned, opt-in (`admin_provisioned`) | Because every real account is anonymized (nobody can sign in), the scrub can seed **one** known admin from `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` so the environment is usable. |

The names in parentheses are the keys of the summary map `KilnCMS.Staging.scrub!/1`
returns. The summary the scrub prints lists every one of them, sorted, with the
underscores as spaces (`oban jobs purged`), then the staging admin.

The scrub is **idempotent** — re-running it anonymizes only accounts that aren't already
anonymized and re-purges empty tables cheaply.

### What the scrub keeps

A scrubbed clone still holds a few things to know about before you share it:

- **Media storage settings.** Storage profiles (`storage_profiles`, `site_storages`)
  keep their S3 endpoint, bucket names and access key id, and the secret access key
  encrypted under production's `SECRET_KEY_BASE`. Media breaks without them, so they
  stay. A clone with its own `SECRET_KEY_BASE` cannot decrypt the secret, but it still
  names production's buckets: point staging at its own storage before anyone uploads.
- **The content-signing key** (`provenance_settings`), for the same reason and under the
  same encryption: removing it would break governance on the clone.
- **Webhook endpoints** are de-activated, not deleted: their URLs and encrypted signing
  secrets stay.
- **Free text written by staff.** Comment bodies, task notes and the `grantor` of a
  content consent are kept with the content they belong to. The accounts that wrote
  them are anonymized, but a name or address typed into the text is not.
- **Tables a plugin owns.** The scrub only knows the core schema. Check what your
  plugins store before sharing a clone.

Every core table is accounted for: a test classifies each one as scrubbed (from
`KilnCMS.Staging.Scrub.dispositions/0`) or kept with a reason, so a new table cannot
reach a clone without someone deciding.

> **The scrub never contacts a payment provider.** Erasing a member cancels their
> membership *locally* only, precisely so this path — which runs over a clone of
> production — can never terminate a real customer's billing. The corollary is
> that erasing a real member in **production** doesn't cancel their subscription
> either; do that in the provider's dashboard. See
> *Erasure (GDPR Art. 17) — anonymization* in [data flows](data-flows.md).

### Preview tokens need no scrub

Draft-preview tokens are **stateless** (signed with `Phoenix.Token`, no DB rows) and
short-lived (15 min). A production-signed token can't verify in staging anyway, because
staging runs with a **different `SECRET_KEY_BASE`** — which also invalidates every
production session cookie the clone carried. Generate a fresh `SECRET_KEY_BASE` for
staging (the recipe below does).

## Running the scrub

The scrub core (`KilnCMS.Staging.scrub!/1`) is callable three ways, so it works from a
checkout and from a production-style OTP release (which has no Mix). Paths 1 and 2 scrub
a clone that is not serving yet; path 3 is only for re-scrubbing a node that is already a
scrubbed clone.

```bash
# 1. Mix, from a checkout. MIX_ENV=prod is required (see below):
MIX_ENV=prod \
DATABASE_URL="$STAGING_DATABASE_URL" \
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
TOKEN_SIGNING_SECRET="$(openssl rand -base64 48)" \
  mix kiln.staging.scrub --yes \
    --admin-email you@example.com --admin-password 'a-strong-password'

# 2. Release, before serving — eval starts the repo itself (like bin/migrate):
KILN_STAGING_SCRUB=confirm \
STAGING_ADMIN_EMAIL=you@example.com STAGING_ADMIN_PASSWORD='a-strong-password' \
  /app/bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'

# 3. Release, re-scrubbing a running node that is already a scrubbed clone:
/app/bin/kiln_cms rpc 'KilnCMS.Staging.scrub!(confirm?: true, allow_live?: true, admin_email: "you@example.com", admin_password: "…")'
```

`scripts/staging.sh` uses path **1** by default (`KILN_BIN=mix`), and path **2** when
`KILN_BIN` names a release's `bin/kiln_cms`.

**Path 1 reads `DATABASE_URL` only under `MIX_ENV=prod`.** The dev configuration
hard-codes the `kiln_cms_dev` database, so without `MIX_ENV=prod` the task ignores
`DATABASE_URL` and targets your dev database instead. The scrub then refuses, because
`kiln_cms_dev` doesn't look ephemeral, but `scripts/staging.sh`'s `mix ecto.migrate`
step has already run against it. A prod boot also needs the variables it always
requires, `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET` among them
([environment-variables.md](environment-variables.md)). The task starts the
application with Oban inert (`KilnCMS.Staging.inert_oban_config/1`: no queue runs a job
and no Oban plugin runs) and the backup heartbeat off, so no job cloned from production
can run before the scrub deletes it. Path 2 starts the repo alone, with no Oban at all.

**Path 3 refuses a node whose Oban runs jobs** unless you pass `allow_live?: true`. A
serving node's queues could execute the clone's copy of production's jobs (mail,
webhooks, federation deliveries) before the scrub deletes them, so on a fresh clone use
path 1 or 2. With `allow_live?: true`, the scrub first pauses every queue on every node
of the cluster and prints "Oban is live on this node: every queue is now paused.
Restart the application after the scrub to resume them." The queues stay paused until
you do: restart the staging application once the scrub finishes.

### Safety guards

The scrub is destructive by design, so it refuses to run unless you clearly mean it —
the guards exist so a mistyped `DATABASE_URL` can't scrub production:

- **Explicit confirmation is required** — `--yes` (Mix) or `KILN_STAGING_SCRUB=confirm`
  (release). Without it the task prints the target and stops.
- **The target database name must look ephemeral** — it must contain `staging`,
  `preview`, `ephemeral`, `tmp`, or `scratch`. Override a deliberately-named clone with
  `--force` / `KILN_STAGING_FORCE=true`, but the name check is your seat-belt.
- **The target is always printed first** (`database@host`) so you can see what you're
  about to scrub before it happens.
- **A node whose Oban queues are running is refused** (path 3 without
  `allow_live?: true`), with "Refusing to scrub from a node whose Oban queues are
  running." Run the scrub before serving instead (path 1 or 2).

## `scripts/staging.sh` — the one-command recipe

`scripts/staging.sh` is a thin, dependency-light wrapper around `pg_dump` / `psql` and
the scrub (path 1 or 2 above). It is deliberately plain shell so it works the same on a
laptop and on the production VPS.

```bash
./scripts/staging.sh up      # dump PROD_DATABASE_URL → create+restore STAGING_DATABASE_URL → migrate → scrub
./scripts/staging.sh scrub   # (re)run just the scrub against STAGING_DATABASE_URL
./scripts/staging.sh down    # DROP the staging database
```

`up` reads:

| Variable | Required | Purpose |
|----------|----------|---------|
| `PROD_DATABASE_URL` | yes (`up`) | Source to `pg_dump`. Read-only; the script never writes to it. |
| `STAGING_DATABASE_URL` | yes | Throwaway target. Its **name must look ephemeral** (see guards). |
| `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` | recommended | Seed one usable admin; without them you can't sign in to staging. |
| `KILN_BIN` | no (default `mix`) | How to run migrate + scrub: `mix` for a checkout, or a release bin path like `/app/bin/kiln_cms` in Docker. With `mix`, also export `MIX_ENV=prod` and the variables a prod boot needs, or migrate and scrub target your dev database (see [Running the scrub](#running-the-scrub)). |

Both URLs may be `postgres://`, `postgresql://` or `ecto://`. The script gives
each password only to its own `pg_dump` or `psql`, as `PGPASSWORD`, never as an
argument. Its closing `DATABASE_URL=` line, which says "password not shown",
leaves the password out: put it back, or export `PGPASSWORD`, before you use
that line
([backups.md](backups.md#the-database-password-stays-out-of-the-pg_dump-command-line-2726)).

`up` dumps production with `--exclude-table-data=oban_jobs`: the clone gets the job
table but none of production's queued jobs. The scrub purges the table anyway, for a
clone made some other way, such as a restored backup.

The script never sets `KILN_STAGING_FORCE`; the ephemeral-name guard stays in force
unless you invoke the scrub yourself.

## Docker / Coolify recipe

Production here is a **manual Coolify _Redeploy_** on a VPS ([`deploy.md`](deploy.md)).
The lean-ops way to get a staging box is to run the **same image** against a separate,
scrubbed database — no new build, no new service definition:

1. **Create a throwaway DB.** On the same Postgres (or a scratch container from
   [`docker-compose.yml`](../docker-compose.yml)):
   ```bash
   createdb -h "$PGHOST" -U "$PGUSER" kiln_staging
   ```
2. **Clone + migrate + scrub** with the release image already on the host:
   ```bash
   # Dump prod (without its queued jobs) and restore into the throwaway DB
   pg_dump --no-owner --no-privileges --exclude-table-data=oban_jobs \
     "$PROD_DATABASE_URL" | psql "$STAGING_DATABASE_URL"

   # Run the same image, pointed at the clone, to migrate then scrub — nothing served yet
   docker run --rm \
     -e DATABASE_URL="$STAGING_DATABASE_URL" \
     -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
     your-kiln-image /app/bin/migrate

   docker run --rm \
     -e DATABASE_URL="$STAGING_DATABASE_URL" \
     -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
     -e KILN_STAGING_SCRUB=confirm \
     -e STAGING_ADMIN_EMAIL="you@example.com" \
     -e STAGING_ADMIN_PASSWORD="a-strong-password" \
     your-kiln-image /app/bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'
   ```
   Run by hand like this, `pg_dump` and `psql` need `postgres://` URLs (they
   read `ecto://` as a database name), and a password in the URL is visible in
   `ps` while they run. Leave the passwords out of the URLs and give each
   command its own (`PGPASSWORD=… pg_dump … | PGPASSWORD=… psql …`), or use
   `staging.sh up`, which does both for you.
3. **Serve it.** In Coolify, add a second application (or a second resource) from the
   **same image/repo** whose only differences are:
   - `DATABASE_URL` → the staging clone,
   - a **fresh** `SECRET_KEY_BASE`,
   - a staging hostname,
   - **`KILN_ENV_LABEL=staging`** (and optionally `KILN_ENV_COLOR`) — see below,
   - outbound integrations left **off** (default): no `MAIL_MODE`, `KilnCMS.Search.Meilisearch`
     `enabled: false`, `KilnCMS.Storage.Local`.
   - **not** production's backup settings: leave `BACKUP_RCLONE_REMOTE` and any
     `RCLONE_CONFIG*` variables unset (or point them at a staging remote), and give
     the clone its own `BACKUP_DIR`, or set `BACKUP_ENABLED=false`. A backup taken on
     the clone would otherwise land beside production's under the same file names.
     The scrub has already paused the clone's in-app backup schedules; resume one on
     the **Schedule** tab of **Backups** only once these are set.
     ([deploy-staging.md](deploy-staging.md#3-stand-up-a-staging-environment)
     has the checklist.)
   - optionally set the crawler to noindex via your reverse proxy.
4. **Tear down.** Stop/delete the staging application and `dropdb kiln_staging`.

Because it's the same image, "upgrade staging" is just redeploying it — the exact
rehearsal for the production Redeploy.

## Label the clone

A scrub removes the personal data; it does not change how the console **looks**.
The clone keeps production's content, its branding and its logo, so the two
consoles are byte-for-byte identical — which is exactly the setup for someone
publishing to the wrong one.

Set `KILN_ENV_LABEL` on the staging application (#469) and every console page
gets a strip across the top naming it:

```bash
KILN_ENV_LABEL=staging
KILN_ENV_COLOR=warning   # or error, info, success — a tone name, never a hex
```

**Leave both unset in production.** No label means no strip: production is the
environment you recognise by the *absence* of a warning, and nothing has to be
configured for that to hold. See
[`environment-variables.md`](environment-variables.md#environment-indicator).

`scripts/staging.sh up` and the scrub both print this as a closing reminder.
Neither can *set* the variable: the scrub runs as a throwaway process against a
remote `DATABASE_URL`, not inside the application that will serve the clone, so
it has no way to read or write that application's environment.

## What's already safe by default

Staging inherits Kiln's low-ops, privacy-first posture, so the scrub only has to close
the gaps the *data* carries — the *config* is already inert:

- **No third-party scripts** on delivered pages — nothing to point away from prod.
- **Mail is off unless `MAIL_MODE` is set**; Meilisearch and S3 are opt-in and default
  to `enabled: false` / local storage. A staging env that simply doesn't set them talks
  to no subprocessor — except for the checks Kiln makes by default. The upstream
  **update check** is on by default, so an admin opening `/editor/system` makes
  an anonymous request to kilncms.dev, or to api.github.com if that fails (no
  instance data, see [data-flows.md](data-flows.md)). Set
  `KILN_UPDATE_CHECK=false` on the staging env if that request is unwelcome.
  A second exception runs on a schedule: crawler verification fetches Google's,
  Bing's, Apple's and DuckDuckGo's published crawler IP lists every 6 hours
  (#2586), sending nothing about the instance. A staging env that search
  engines do not crawl gains nothing from them, so set
  `KILN_CRAWLER_RANGES=false` there unless you are testing crawler
  verification itself, or the staging firewall does not allow those hosts
  (blocked, it only logs a warning per engine). See
  [bot-budgets.md](bot-budgets.md#published-ip-ranges).
  The others are on by default too. Registering, changing or resetting a
  password on the clone sends a five-character fragment of its hash to Have I
  Been Pwned; the scrub's own staging admin is not checked, and
  `BREACHED_PASSWORD_CHECK=false` stops it. With a plugin from Hex, an admin
  opening `/editor/system` asks hex.pm about it, which `KILN_UPDATE_CHECK=false`
  stops while `KILN_PLUGIN_HEALTH_CHECK` is unset. Crawler verification asks
  the node's DNS resolver about clients claiming to be search engines
  (`KILN_CRAWLER_VERIFICATION=false` stops it and the list fetches).
  [data-flows.md](data-flows.md#optional-subprocessors) lists every call a
  default install makes and the variable that stops each.
- **Keys and credentials kept in the database are sealed with `SECRET_KEY_BASE`.**
  `SECRET_KEY_BASE`, `DATABASE_URL`, and any key `KilnCMS.Keys` reads from an
  environment variable or a file come from the environment, so a fresh set of staging
  env vars is a clean break from production. These, when kept in the database, are
  encrypted by `KilnCMS.Keys.Vault` under a key derived from `SECRET_KEY_BASE`: the DKIM
  private key and the payment provider's API and webhook keys, each site's mail relay
  password, SSO client secret, storage secret key, AI provider and Meilisearch API keys,
  and push (VAPID) private key, webhook signing secrets, each site's ActivityPub key,
  the instance's content-signing key (provenance), social account credentials, and
  every account's authenticator-app (TOTP) secret. A
  clone with its own `SECRET_KEY_BASE` cannot decrypt any of them, as long as
  `PREVIOUS_SECRET_KEY_BASE` is not production's: leave it unset on staging. The scrub
  also deletes the DKIM key, the billing keys (before anything else), each site's
  ActivityPub key, VAPID keys, mail relay, SSO and AI provider and Meilisearch settings,
  and social account credentials outright, and clears every account's authenticator
  app, recovery codes and passkeys as it anonymizes the account (`KilnCMS.Accounts.Changes.AnonymizeUser`).
- **A distinct `SECRET_KEY_BASE`** invalidates every cloned session cookie and every
  production-signed preview token automatically.

## Cross-references

- [`deploy-staging.md`](deploy-staging.md) — the deploy + operator checklist for this
  feature (prerequisites, guards, teardown, rollback).
- [`data-flows.md`](data-flows.md) — the authoritative map of what personal data Kiln
  holds and the `:anonymize` erasure action the scrub reuses.
- [`deploy.md`](deploy.md) — the canonical deploy guide; the production posture this
  recipe mirrors.
- [`demo-mode.md`](demo-mode.md) — the other destructive, guarded operation: a public
  demo that resets to a golden snapshot on a schedule. Same sentinel convention
  (`KILN_DEMO_RESET=confirm`), but its name checks have no override.
