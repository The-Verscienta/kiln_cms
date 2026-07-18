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
   outbound integrations off (they are off by default — see [What's already safe](#whats-already-safe-by-default)).
5. **Tear down** — drop the throwaway database. Nothing else persists.

## The scrub

`KilnCMS.Staging.Scrub` is the one place that turns a production clone into a
safe-to-share environment. Everything it does is a purge or a de-activation — it never
sends mail, fires a webhook, or contacts a subprocessor.

| What | Action | Why |
|------|--------|-----|
| **User accounts** | `:anonymize` (per user) — the GDPR-erasure action | Emails → non-routable tombstones, names cleared, passwords scrambled, roles reset to `:viewer`, auth-event actors nulled. The exact production erasure path (`data-flows.md`). |
| **API keys** | purged | Live `kiln_*` credentials would otherwise grant API access to the staging copy (and are secrets in their own right). |
| **Auth tokens** | purged | Session / reset / magic-link tokens are stale in a clone and are pseudonymous PII. |
| **Webhook endpoints** | de-activated | A clone must **never** fire deliveries at production consumers' URLs on the next publish. De-activation is data-only (no SSRF DNS re-check). |
| **Mail settings** | purged (singleton row) | Drops the **encrypted DKIM private key** and server IP so staging can't sign mail as your production domain. Recreated blank on next read (`KilnCMS.Mail.ensure_settings!/0`). |
| **Recorded search queries** | purged | Query text can contain names, emails, or confidential titles ([#213/#220](data-flows.md)). |
| **A fresh staging admin** | provisioned (opt-in) | Because every real account is anonymized (nobody can sign in), the scrub can seed **one** known admin from `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` so the environment is usable. |

The scrub is **idempotent** — re-running it anonymizes only accounts that aren't already
anonymized and re-purges empty tables cheaply.

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
  `--force` / `KILN_STAGING_FORCE=1`, but the name check is your seat-belt.
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
| `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` | recommended | Seed one usable admin; without them you can't sign in to staging. |
| `KILN_BIN` | no (default `mix`) | How to run migrate + scrub: `mix` for a checkout, or a release bin path like `/app/bin/kiln_cms` in Docker. |

The script never sets `KILN_STAGING_FORCE`; the ephemeral-name guard stays in force
unless you invoke the scrub yourself.

## Docker / Coolify recipe

Production here is a **manual Coolify _Redeploy_** on a VPS ([`deploy-p2.md`](deploy-p2.md)).
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
3. **Serve it.** In Coolify, add a second application (or a second resource) from the
   **same image/repo** whose only differences are:
   - `DATABASE_URL` → the staging clone,
   - a **fresh** `SECRET_KEY_BASE`,
   - a staging hostname,
   - outbound integrations left **off** (default): no `MAIL_MODE`, `KilnCMS.Search.Meilisearch`
     `enabled: false`, `KilnCMS.Storage.Local`.
   - optionally set the crawler to noindex via your reverse proxy.
4. **Tear down.** Stop/delete the staging application and `dropdb kiln_staging`.

Because it's the same image, "upgrade staging" is just redeploying it — the exact
rehearsal for the production Redeploy.

## What's already safe by default

Staging inherits Kiln's low-ops, privacy-first posture, so the scrub only has to close
the gaps the *data* carries — the *config* is already inert:

- **No third-party scripts** on delivered pages — nothing to point away from prod.
- **Mail is off unless `MAIL_MODE` is set**; Meilisearch and S3 are opt-in and default
  to `enabled: false` / local storage. A staging env that simply doesn't set them talks
  to no subprocessor.
- **Secrets come from the environment** (`SECRET_KEY_BASE`, `DATABASE_URL`, provider
  keys via `KilnCMS.Keys`), not the database — so a fresh set of staging env vars is a
  clean break from production. The DKIM private key is the one secret that lives in the
  DB; the scrub purges it.
- **A distinct `SECRET_KEY_BASE`** invalidates every cloned session cookie and every
  production-signed preview token automatically.

## Cross-references

- [`data-flows.md`](data-flows.md) — the authoritative map of what personal data Kiln
  holds and the `:anonymize` erasure action the scrub reuses.
- [`deploy-p2.md`](deploy-p2.md) — the production Coolify redeploy posture this recipe
  mirrors.
