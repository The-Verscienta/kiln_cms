# Deploying / operating the staging-environment tooling

Deploy + operator checklist for ephemeral staging / preview environments (#382,
the actionable slice of #334). Shipped in #381. Feature guide:
[`staging-environments.md`](staging-environments.md).

Production is a **manual Coolify _Redeploy_** on the VPS. This feature is docs +
a `mix` task + a `KilnCMS.Release.scrub_staging/0` release helper — it does **not**
change the serving app, so a plain Redeploy carries it with nothing to verify
beyond a normal boot.

## What changed (deploy-relevant)

| Aspect | Impact |
| --- | --- |
| Schema / migrations | **none** |
| Assets | **none** |
| New **required** env/config | **none** |
| New Oban queue / POOL_SIZE | **none** |
| Serving-app behavior | **none** — the new code only runs when an operator invokes the task/helper |

New operator-facing surface (dormant until you run it): `mix kiln.staging.scrub`,
`KilnCMS.Release.scrub_staging/0` (via `bin/kiln_cms eval`), and
[`scripts/staging.sh`](../scripts/staging.sh).

## 1. Ship it (zero-risk carry)

- [ ] Deploy `main` at/after the #381 squash commit. A normal Coolify **Redeploy**
      is all that's needed.
- [ ] No pre-deploy backup step is added by *this* feature (it adds no migration).
- [ ] Post-deploy: `GET /up` returns `200` — that's the whole verification. There
      is nothing new running in the serving app to check.

## 2. Operational prerequisites (only to *use* staging)

The tooling shells out to standard Postgres client utilities and needs network
reach to both databases. Before the first `scripts/staging.sh up`:

- [ ] `pg_dump`, `psql`, `createdb`, `dropdb` are on `PATH` wherever you run the
      script (the VPS host, or a container with `postgresql-client`). The release
      **runtime image ships libvips but not the Postgres client tools** — run the
      script from the host or a `postgres:17` / `pgvector/pgvector:pg17` container.
- [ ] The box running the script can reach **both** `PROD_DATABASE_URL` (read) and
      `STAGING_DATABASE_URL` (write).
- [ ] The staging database's role can `CREATE`/`DROP` its own database, **or** you
      pre-create the throwaway DB and skip `createdb` (the script tolerates this).
- [ ] The staging DB is a **separate database** (ideally a separate host/instance)
      from production — never point `STAGING_DATABASE_URL` at the prod database.

## 3. Stand up a staging environment

Full flow, recipe, and the serve step live in
[`staging-environments.md`](staging-environments.md). The deploy-time checklist:

- [ ] `PROD_DATABASE_URL`, `STAGING_DATABASE_URL`, and (recommended)
      `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` are exported.
- [ ] `STAGING_DATABASE_URL`'s database **name looks ephemeral** (contains
      `staging` / `preview` / `ephemeral` / `tmp` / `scratch`) — the scrub refuses
      otherwise, which is the seat-belt against scrubbing prod. (`--force` /
      `KILN_STAGING_FORCE=1` overrides, so don't set those casually.)
- [ ] Run `./scripts/staging.sh up` (dump → restore → migrate → **scrub**).
- [ ] Confirm the scrub summary printed non-zero `users anonymized` and, if you
      set the admin vars, `staging admin: <email>`.
- [ ] Serve it as a **second** Coolify app from the **same image/repo**, differing
      only by: `DATABASE_URL` → the clone, a **fresh** `SECRET_KEY_BASE`, a staging
      hostname, and outbound integrations left **off** (no `MAIL_MODE`; Meilisearch
      `enabled: false`; `KilnCMS.Storage.Local`). Optionally noindex at the proxy.

## 4. Safety callouts

- [ ] **Never run the scrub against production.** It anonymizes every account,
      purges API keys/tokens/search queries, de-activates webhooks, and drops the
      mail settings (incl. the DKIM private key). The confirmation flag +
      ephemeral-name guard exist to prevent a mistyped `DATABASE_URL` — respect them.
- [ ] **Scrub before exposing** the staging box. `scripts/staging.sh up` and the
      `bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'` path both scrub *before*
      anything serves; if you clone and serve by hand, run the scrub first.
- [ ] A **distinct staging `SECRET_KEY_BASE`** is what invalidates cloned session
      cookies and prod-signed preview tokens — generate a fresh one, don't reuse
      prod's.

## 5. Tear down

- [ ] `./scripts/staging.sh down` drops the throwaway database.
- [ ] Stop/delete the staging Coolify app. Nothing else persists.

## 6. Rollback

- [ ] Nothing feature-specific to reverse — no schema, no serving-app change.
      Redeploying a previous image simply omits the operator tooling.

---

**Bottom line:** shipping this is a plain Redeploy with **no migration, no new
required secret, no POOL_SIZE change, and no serving-app impact**. The only real
checklist is operational — Postgres client tools on `PATH`, an ephemerally-named
throwaway DB, and a fresh `SECRET_KEY_BASE` for the served staging instance.
