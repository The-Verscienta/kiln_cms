# Deploying / operating the staging-environment tooling

> **Feature-enablement checklist** for the staging-environment tooling — still the
> operator checklist for turning it on. It assumes a deployed Kiln: how to
> deploy at all is [`deploy.md`](deploy.md), the canonical deploy guide.

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
      script (the VPS host, or a container with `postgresql-client`), at the
      **same major version as the servers**. The release runtime image ships
      `postgresql-client-17` (for in-app backups), but `scripts/staging.sh` is
      not in the image: run it from a checkout on the host, or from a
      `postgres:17` / `pgvector/pgvector:pg17` container.
- [ ] The box running the script can reach **both** `PROD_DATABASE_URL` (read) and
      `STAGING_DATABASE_URL` (write).
- [ ] The staging database's role can `CREATE`/`DROP` its own database, **or** you
      pre-create the throwaway DB and skip `createdb` (the script tolerates this).
      `createdb` and `dropdb` run on the server in `STAGING_DATABASE_URL`, as its
      user, connecting through its `postgres` (then `template1`) database, so
      that role needs to be able to connect to one of them.
- [ ] The staging DB is a **separate database** (ideally a separate host/instance)
      from production — never point `STAGING_DATABASE_URL` at the prod database.

## 3. Stand up a staging environment

Full flow, recipe, and the serve step live in
[`staging-environments.md`](staging-environments.md). The deploy-time checklist:

- [ ] `PROD_DATABASE_URL`, `STAGING_DATABASE_URL`, and (recommended)
      `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD` are exported.
- [ ] `STAGING_DATABASE_URL`'s database **name looks ephemeral** (contains
      `staging` / `preview` / `ephemeral` / `tmp` / `scratch`) — the scrub refuses
      otherwise, which is the seat-belt against scrubbing prod, and so do
      `scripts/staging.sh up` and `down`, before they create or drop anything.
      (`--force` / `KILN_STAGING_FORCE=true` overrides, so don't set those
      casually.) For `up` and `down` it must be a `postgres://`,
      `postgresql://` or `ecto://` URL with the database in its path, not a
      `key=value` string
      ([what they check](staging-environments.md#what-up-and-down-check-before-they-create-or-drop)).
- [ ] Run `./scripts/staging.sh up` (dump → restore → migrate → **scrub**). With
      the default `KILN_BIN=mix`, export the variables a prod boot requires
      (`SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`) first, and
      `DATABASE_SSL=false` for a local Postgres without TLS. The script checks
      the prod config loads before it copies anything, runs Mix with
      `MIX_ENV=prod` when `MIX_ENV` is unset and refuses any other value,
      since only the prod config reads `DATABASE_URL`. If migrate or the
      scrub fails after the copy, it drops the clone, which then holds
      unscrubbed production data
      ([staging-environments.md](staging-environments.md#running-the-scrub)).
      Or set `KILN_BIN` to a release's `bin/kiln_cms`.
- [ ] Confirm the scrub summary printed non-zero `users anonymized` and, if you
      set the admin vars, `staging admin: <email>`.
- [ ] Serve it as a **second** Coolify app from the **same image/repo**, differing
      only by: `DATABASE_URL` → the clone, a **fresh** `SECRET_KEY_BASE`, a staging
      hostname, and outbound integrations left **off** (no `MAIL_MODE`; Meilisearch
      `enabled: false`; `KilnCMS.Storage.Local`). Never give it production's
      `S3_*`, `KILN_PROVENANCE_PRIVATE_KEY` / `KILN_PROVENANCE_KEY_FILE`
      (a mounted key signs as production, whatever the scrub removed) or
      `KILN_GOVERNANCE_WITNESS*` (staging's checkpoints would be published
      beside production's)
      ([Serving the clone](staging-environments.md#serving-the-clone)).
      The clone generates a signing key of its own from its first boot.
      The scrub has removed each site's own bucket credentials and switched
      its own storage off, so existing media loads read-only from
      production's public URLs and new uploads stay on staging
      ([Media on a scrubbed clone](staging-environments.md#media-on-a-scrubbed-clone)).
      Leaving a variable unset
      does not turn off the calls Kiln makes by default: set
      `KILN_UPDATE_CHECK=false`, `KILN_CRAWLER_VERIFICATION=false` and
      `BREACHED_PASSWORD_CHECK=false`, and leave `KILN_PLUGIN_HEALTH_CHECK`
      unset, if the clone must make none
      ([data-flows.md](data-flows.md#optional-subprocessors)). Optionally
      noindex at the proxy.
- [ ] **Don't copy production's backup settings.** Leave `BACKUP_RCLONE_REMOTE`
      and any `RCLONE_CONFIG*` variables unset, or point them at a staging
      remote, and give the clone its own `BACKUP_DIR`: otherwise a backup taken
      from the clone's **Backups** page lands in production's off-site store,
      beside production's own backups under the same file names, where a
      restore can pick it up by mistake. Set
      `BACKUP_ENABLED=false` if the clone needs no backups at all. The scrub
      pauses every in-app backup schedule the clone carried over
      (`backup_schedules_disabled`); resume one on the clone's **Schedule** tab
      of **Backups** only after these settings are the clone's own
      ([backups.md](backups.md#restoring-the-database-brings-back-the-schedules)).

## 4. Safety callouts

- [ ] **Never run the scrub against production.** It anonymizes every account,
      purges API keys/tokens/search queries, de-activates webhooks, drops the
      mail settings (incl. the DKIM private key), deletes the backup history
      and both security logs (the sites' and the instance's), pauses every
      in-app backup schedule, and deletes every queued job, newsletter
      subscriber, form submission, suppression list entry, federation
      follower and per-site integration (mail relay, SSO, AI, Meilisearch),
      removes every site's storage credentials and deletes the generated
      content-signing key. The confirmation flag +
      ephemeral-name guard exist to prevent a mistyped `DATABASE_URL` — respect them.
- [ ] **Scrub before exposing** the staging box. `scripts/staging.sh up` and the
      `bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'` path both scrub *before*
      anything serves; if you clone and serve by hand, run the scrub first.
      A serving node is refused (its queues could run production's cloned
      jobs first); `allow_live?: true` over `rpc` is only for re-scrubbing a
      clone that was already scrubbed, and leaves every queue paused until you
      restart it.
- [ ] Before sharing the clone, read
      [what the scrub keeps](staging-environments.md#what-the-scrub-keeps):
      where production's media is (without its credentials), staff free text,
      and the plugin tables a plugin keeps. An overlay whose domains own a table
      with no `staging_scrub/0` entry makes the scrub refuse, with nothing
      changed ([Plugin tables](staging-environments.md#plugin-tables)).
- [ ] **Re-scrub a clone made before 1.11 before you share it.** An older scrub
      left newsletter subscribers, form submissions, the suppression lists,
      federation followers and keys, per-site integrations and production's
      queued jobs in the clone, and left its site admins with their tiers.
      Run `./scripts/staging.sh scrub` (this release's copy) against the
      clone, or one of the other paths in
      [Running the scrub](staging-environments.md#running-the-scrub).
- [ ] **Re-scrub a clone made before 1.12 before you share it.** An older scrub
      kept each site's storage credentials and the content-signing key, so a
      clone started with production's `SECRET_KEY_BASE` could write to and
      delete from production's buckets and sign as production. Run
      `./scripts/staging.sh scrub` against it.
- [ ] A **distinct staging `SECRET_KEY_BASE`** is what invalidates cloned session
      cookies and prod-signed preview tokens — generate a fresh one, don't reuse
      prod's.

## 5. Tear down

- [ ] `./scripts/staging.sh down` drops the throwaway database, on the server
      `STAGING_DATABASE_URL` names. It refuses a name that doesn't look
      ephemeral unless `KILN_STAGING_FORCE` is on.
- [ ] Stop/delete the staging Coolify app. Nothing else persists.

## 6. Rollback

- [ ] Nothing feature-specific to reverse — no schema, no serving-app change.
      Redeploying a previous image simply omits the operator tooling.

---

**Bottom line:** shipping this is a plain Redeploy with **no migration, no new
required secret, no POOL_SIZE change, and no serving-app impact**. The only real
checklist is operational — Postgres client tools on `PATH`, an ephemerally-named
throwaway DB, and a fresh `SECRET_KEY_BASE` for the served staging instance.
