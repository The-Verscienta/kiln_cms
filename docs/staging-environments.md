# Ephemeral staging / preview environments

Stand up a throwaway copy of your **production content** to test an upgrade, try a
migration, review a redesign, or reproduce a bug — then throw it away. The copy is
**scrubbed of personal data and outbound secrets by default**, so it is safe to run
somewhere less locked-down than production and to hand to a reviewer.

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
sends mail, fires a webhook, or contacts a subprocessor.

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
| **Security log** | purged (`security_events_purged`) | Raw IP addresses, user agents and email snapshots of production's sign-ins: personal data a clone must not carry. See [the security log](security-events.md#privacy-ip-addresses-erasure-and-staging). |
| **Instance security log** | purged (`instance_security_events_purged`) | The same columns for events about the installation: platform admins' addresses and IPs. See [the instance log](security-events.md#the-instance-log). |
| **Security alert dispatches** | purged (`security_alert_dispatches_purged`) | A [security alert](security-alerts.md) still to be sent would mail and notify production's admins from the clone, about production events. |
| **Paid memberships** | scrubbed (`memberships_scrubbed`) | Provider customer/subscription ids nulled and the status set to canceled. **Scrubbed, not deleted**: `billing_membership_events` references them, and the entitlement trail should stay referentially intact — the same audit-retention decision as content history. What must go is the live external reference. |
| **Membership tiers** | deactivated (`tiers_deactivated`) | The catalogue shape keeps staging useful; the price pointer is replaced with a per-row tombstone so nothing in the clone can bill a real account. (Per-row because `provider_price_id` is `NOT NULL` with a per-org unique index.) |
| **A fresh staging admin** | provisioned, opt-in (`admin_provisioned`) | Because every real account is anonymized (nobody can sign in), the scrub can seed **one** known admin from `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` so the environment is usable. |

The scrub is **idempotent** — re-running it anonymizes only accounts that aren't already
anonymized and re-purges empty tables cheaply.

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

The scrub core (`KilnCMS.Staging.scrub!/1`) is callable three ways, so it works in dev
and in a production-style OTP release (which has no Mix):

```bash
# 1. Mix (dev, or any checkout with Mix available):
DATABASE_URL="$STAGING_DATABASE_URL" \
  mix kiln.staging.scrub --yes \
    --admin-email you@example.com --admin-password 'a-strong-password'

# 2. Release, before serving — eval starts the repo itself (like bin/migrate):
KILN_STAGING_SCRUB=confirm \
STAGING_ADMIN_EMAIL=you@example.com STAGING_ADMIN_PASSWORD='a-strong-password' \
  /app/bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'

# 3. Release, against an already-running staging node:
/app/bin/kiln_cms rpc 'KilnCMS.Staging.scrub!(confirm?: true, admin_email: "you@example.com", admin_password: "…")'
```

`scripts/staging.sh up` uses path **2** for you.

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

## `scripts/staging.sh` — the one-command recipe

`scripts/staging.sh` is a thin, dependency-light wrapper around `pg_dump` / `psql` and
the release scrub. It is deliberately plain shell so it works the same on a laptop and
on the production VPS.

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

Both URLs may be `postgres://`, `postgresql://` or `ecto://`. The script gives each password only to its own `pg_dump` or `psql`, as `PGPASSWORD`, never as an argument, and its closing `DATABASE_URL=` line leaves the password out ([backups.md](backups.md#the-database-password-stays-out-of-the-pg_dump-command-line-2726)).
| `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` | recommended | Seed one usable admin; without them you can't sign in to staging. |
| `KILN_BIN` | no (default `mix`) | How to run migrate + scrub: `mix` for a checkout, or a release bin path like `/app/bin/kiln_cms` in Docker. |

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
   # Dump prod and restore into the throwaway DB
   pg_dump --no-owner --no-privileges "$PROD_DATABASE_URL" | psql "$STAGING_DATABASE_URL"

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
- **Secrets in the database are sealed with `SECRET_KEY_BASE`.** `SECRET_KEY_BASE`,
  `DATABASE_URL`, and any key `KilnCMS.Keys` reads from an environment variable or a
  file come from the environment, so a fresh set of staging env vars is a clean break
  from production. Every secret Kiln stores in the database instead is encrypted by
  `KilnCMS.Keys.Vault` under a key derived from `SECRET_KEY_BASE`: the DKIM private key
  and the payment provider's API and webhook keys (when they are kept in the database),
  each site's mail relay password, SSO client secret, storage secret key, AI provider
  and Meilisearch API keys, and push (VAPID) private key, webhook signing secrets, each
  site's ActivityPub key, the instance's content-signing key (provenance), and social
  account credentials. A clone with its own `SECRET_KEY_BASE` cannot decrypt any of them, as
  long as `PREVIOUS_SECRET_KEY_BASE` is not production's: leave it unset on staging.
  The scrub also deletes the DKIM key and the billing keys outright, the billing keys
  before anything else.
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
