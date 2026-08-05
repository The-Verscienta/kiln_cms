# Backups & restore

What gets backed up, on what schedule, where copies live, and — the part that
matters — how to restore, including the quarterly restore drill. Tooling:
[`scripts/backup.sh`](../scripts/backup.sh) and
[`scripts/restore.sh`](../scripts/restore.sh) (plain shell + `pg_dump`/`tar`,
same on a laptop and on the VPS).

**TL;DR for the production VPS (Coolify / RackNerd):**

```cron
# /etc/cron.d/kiln-backup — nightly at 03:17 UTC, as a user that can reach PG
17 3 * * * kiln  DATABASE_URL=postgres://…/kiln_prod \
  MEDIA_DIR=/data/kiln/uploads \
  BACKUP_DIR=/var/backups/kiln \
  BACKUP_RCLONE_REMOTE=r2:kiln-backups \
  BACKUP_PING_URL=https://hc-ping.com/<uuid> \
  /opt/kiln_cms/scripts/backup.sh all >> /var/log/kiln-backup.log 2>&1
```

> **Client tools must match the server's major version** — a `pg_dump` older
> than the server refuses to run ("server version mismatch"). On the VPS use
> the distro's `postgresql-client-17`; on macOS/Homebrew, put
> `/opt/homebrew/opt/postgresql@17/bin` first on `PATH`.

---

## What must be backed up

Three things constitute a Kiln deployment's state. Losing any one of them loses
data or capability:

| What | Where it lives | How it's backed up |
|---|---|---|
| **Database** | Postgres (`DATABASE_URL`) — all content, versions, the event log, fired artifacts, Oban jobs, orgs/users, form submissions, webhook config, mail settings incl. the **encrypted DKIM private key** | `backup.sh db` → verified `pg_dump -Fc` |
| **Media** | Local adapter: the uploads root (originals + variants). S3 adapter (`S3_BUCKET` set): the bucket | Local: `backup.sh media` → `tar.gz`. S3/R2: provider-side (below) |
| **Secrets/env** | Coolify environment variables — above all **`SECRET_KEY_BASE`**, plus `DATABASE_URL`, S3 creds, OIDC/SMTP config | Manual: keep a copy in your password manager, refreshed whenever an env var changes |

> **`SECRET_KEY_BASE` is part of the backup.** `KilnCMS.Keys.Vault` encrypts
> database-stored key material (e.g. the DKIM private key) with a key **derived
> from `secret_key_base`**. A database restore booted under a *different*
> `SECRET_KEY_BASE` comes up fine, but every database-stored key is
> unrecoverable (and all sessions/tokens invalidate). Store it with the same
> care as the dumps — a dump without it is only a partial backup.

Not needed in backups: fired artifacts and search indexes are *derived* state —
they restore with the DB anyway, and can always be rebuilt (`mix kiln.refire_all`,
Meilisearch/embedding reindex) if stale.

## Schedule & retention

| What | Cadence | Local retention | Off-site |
|---|---|---|---|
| DB dump | nightly (cron above) | 14 days (`BACKUP_KEEP_DAYS`) | every dump, via `BACKUP_RCLONE_REMOTE` |
| Media archive (Local adapter) | nightly, same run | 14 days | every archive |
| Media (S3/R2 adapter) | continuous | — | bucket **versioning + lifecycle** (e.g. keep noncurrent versions 30 days), or a nightly `rclone sync` to a second bucket/provider |
| Secrets/env snapshot | on change | — | password manager |
| **Restore drill** | **quarterly** | — | recorded below |

Implied objectives with the nightly cadence: **RPO ≤ 24 h** (worst case, one day
of content; tighten by raising the cron frequency — dumps are cheap at this DB
size), **RTO ≈ 1 h** (fresh-VPS walkthrough below). If either stops being
acceptable, step up to WAL-based point-in-time recovery (pgBackRest / wal-g) —
deliberately *not* the default here, because a verified nightly dump you have
drilled beats a PITR setup you haven't.

Rules that make this a strategy rather than a script:

- **A backup that isn't verified doesn't count.** `backup.sh` runs
  `pg_restore --list` / `tar -tzf` on everything it produces and deletes the
  file on failure, loudly.
- **A backup that only lives on the VPS doesn't count.** The threat model is
  losing the VPS. Set `BACKUP_RCLONE_REMOTE` (R2/B2/S3 — any rclone remote);
  the off-site copy failing fails the run, so cron surfaces it.
- **Silence must be an alarm.** Set `BACKUP_PING_URL` to a
  [healthchecks.io](https://healthchecks.io)-style check: the *absence* of the
  nightly ping alerts you. Cron `MAILTO` alone tells you about loud failures,
  not about cron quietly not running.
- If Postgres runs as a **Coolify-managed database resource**, also enable
  Coolify's built-in scheduled backups to S3 — belt and braces; the host cron
  works regardless of how PG is run.

## In-app backups (#484)

The console has a **Backups** page (`/editor/backups`, admin only) showing when
the last backup ran, how big it was, which files it produced and whether each
verified — plus a **Back up now** button. The bagua overview grows a red strip
when the newest backup is older than `BACKUP_STALE_AFTER_HOURS` (default 36),
or when there has never been one.

### It reports on cron's backups too

The panel reads `$BACKUP_DIR/manifest.json`, and **`backup.sh all` writes it**.
That is the whole design: cron remains the canonical path, and a panel that
only knew about app-triggered runs would show "never" on precisely the
deployments that are backing up correctly.

A failed run overwrites the manifest with `"ok": false` and the error, rather
than leaving the last successful one on screen — "is my data safe right now"
is the question the page is being asked, and the previous backup does not
answer it.

### The app path and the shell path produce the same files

`KilnCMS.Backups.Worker` runs the same `pg_dump --format=custom --no-owner
--no-privileges`, writes to the same `db/kiln-db-<stamp>.dump` and
`media/kiln-media-<stamp>.tar.gz` under the same `$BACKUP_DIR`, uses the same
`.partial`-then-rename discipline, and verifies with the same `pg_restore
--list` / `tar -tzf`. `backup.sh verify` and `restore.sh` work on an app-made
backup, and this page reports on a cron-made one, because there is one format —
not two.

That constraint is why the worker shells out to `pg_dump` rather than
implementing a dump in Elixir: a hand-rolled export would be a second format
with a second restore procedure, and the restore path is where a backup system
earns its keep.

### It needs the client tools in the image

The worker calls `pg_dump`/`pg_restore`, so the runtime image installs
`postgresql-client-17`. **Its major version must match the server** — `pg_dump`
refuses to run against a newer one — so bump the pin in the `Dockerfile`
alongside your Postgres upgrade.

Where they are absent, the page says so and the button is disabled rather than
failing at the point of use. Cron backups on the host are unaffected either
way.

### What it deliberately does not do

**Restore.** That is the runbook below, and it stays a documented operations
procedure: an in-app restore means taking the application down and replacing
the database underneath a running BEAM, with a credible answer for a failure
halfway. Akeeba-class complexity, and Akeeba-class risk.

**Secrets.** `SECRET_KEY_BASE` and friends are not in these files and never
will be — see the table above.

## Restore runbook (full loss → serving)

Scenario: the VPS is gone; you have off-site dumps + media archives and the
env snapshot. Order matters.

1. **Provision Postgres** (same major version, with the `vector`, `pg_trgm`,
   `citext` extensions available — the dump creates them, the server just needs
   the packages).
2. **Fetch the newest verified dump** from the off-site remote:
   `rclone copy r2:kiln-backups/db/<newest>.dump .`
3. **Restore the database:**
   ```bash
   RESTORE_DATABASE_URL=postgres://…/kiln_prod \
     ./scripts/restore.sh db kiln-db-<stamp>.dump
   ```
4. **Restore media.** Local adapter: `RESTORE_MEDIA_DIR=/data/kiln/uploads
   ./scripts/restore.sh media kiln-media-<stamp>.tar.gz` and mount that path
   into the container at the uploads root. S3 adapter: nothing to do (or
   promote the replica bucket) — just set the `S3_*` env.
5. **Recreate the app in Coolify** from the env snapshot — **the same
   `SECRET_KEY_BASE`** (see above), `DATABASE_URL`, storage/OIDC/SMTP vars —
   and deploy. Boot runs `bin/migrate`, which also catches the dump up to a
   newer image's schema.
6. **Verify** (the same checks the drill runs, plus app-level):
   - sign in; content list renders; a published page serves publicly
   - media renders (an image URL resolves)
   - `/editor/mail` still shows the DKIM key (proves `SECRET_KEY_BASE` matched)
   - Oban queues draining (`/editor` dashboards), webhooks intentionally
     **re-enabled only when you're sure** this instance should notify consumers
7. **Re-point DNS / SSL** via Coolify.

Partial-loss variants: single-table mishaps can restore selectively
(`pg_restore --table=…` from the same `-Fc` dump into a scratch DB, then copy
rows over); content-level mistakes usually don't need backups at all — prefer
in-app version restore / trash first.

## Restore drill (quarterly)

An untested backup is a hope, not a backup. Once a quarter:

```bash
RESTORE_DATABASE_URL=postgres://localhost/kiln_drill \
  ./scripts/restore.sh drill /var/backups/kiln/db/<newest>.dump
```

The drill restores into a throwaway DB (the name must look throwaway — it
refuses otherwise) and sanity-checks core tables (`users`, `pages`, `posts`,
`media_items`, `schema_migrations`). To go further and boot a real instance
against the drill DB, **scrub it first** — it contains production PII and
webhook config: `STAGING_DATABASE_URL=… ./scripts/staging.sh scrub` (the
staging tooling exists precisely for "serve a prod clone safely" —
[staging-environments.md](staging-environments.md)). Then `dropdb kiln_drill`.

Record each drill here:

| Date | Backup file | Restored by | Outcome |
|---|---|---|---|
| _(add rows as drills happen)_ | | | |

## Environment reference

The `backup` rows are read by **both** paths — `scripts/backup.sh` and the app
(`config/runtime.exs` → `KilnCMS.Backups`), by the same names, so a deployment
configured for cron needs nothing extra for the console.

| Variable | Script | Meaning |
|---|---|---|
| `DATABASE_URL` | backup | source DB (read-only) |
| `BACKUP_DIR` | backup + app | local backup root (default `/var/backups/kiln`) |
| `MEDIA_DIR` | backup + app | uploads root (Local adapter only; omit on S3) |
| `BACKUP_KEEP_DAYS` | backup + app | local retention (default 14) |
| `BACKUP_ENABLED` | app | set false to disable the in-app path only; cron is unaffected (default true) |
| `BACKUP_STALE_AFTER_HOURS` | app | how old before the console warns (default 36) |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup | off-site rclone remote (strongly recommended) |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill` |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
