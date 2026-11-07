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
| **Media** | Local adapter: the uploads root (originals + variants). S3 adapter (`S3_BUCKET` set): the bucket | Local: `backup.sh media` → one `tar.gz`; the in-app **Back up now** → several independent `tar.gz` parts ([below](#media-backups-in-parts-2218)). S3/R2: provider-side (below) |
| **Secrets/env** | Coolify environment variables — above all **`SECRET_KEY_BASE`**, plus `DATABASE_URL`, S3 creds, OIDC/SMTP config | Manual: keep a copy in your password manager, refreshed whenever an env var changes |

> **`SECRET_KEY_BASE` is part of the backup.** `KilnCMS.Keys.Vault` encrypts
> database-stored key material (e.g. the DKIM private key) with a key **derived
> from `secret_key_base`**. A database restore booted under a *different*
> `SECRET_KEY_BASE` comes up fine, but every database-stored key is
> unrecoverable (and all sessions/tokens invalidate). Store it with the same
> care as the dumps — a dump without it is only a partial backup. Replacing
> it deliberately is its own procedure, with its own losses —
> the `SECRET_KEY_BASE` section of
> [`secrets-rotation.md`](secrets-rotation.md).

Not needed in backups: fired artifacts and search indexes are *derived* state —
they restore with the DB anyway, and can always be rebuilt (`mix kiln.refire_all`,
Meilisearch/embedding reindex) if stale.

## Schedule & retention

| What | Cadence | Local retention | Off-site |
|---|---|---|---|
| DB dump | nightly (cron above) | 14 days (`BACKUP_KEEP_DAYS`) | every dump, via `BACKUP_RCLONE_REMOTE` |
| Media archive (Local adapter) | nightly, same run | 14 days, a whole set at a time | every part and sidecar |
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
  file on failure, loudly. Both paths also record a SHA-256 of every file, so a
  copy that was damaged later can be told from one that was never good.
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
verified — plus a **Back up now** button. The overview grid grows a red strip
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

### The app path and the shell path share one format

`KilnCMS.Backups.Worker` runs the same `pg_dump --format=custom --no-owner
--no-privileges`, writes to the same `db/kiln-db-<stamp>.dump` under the same
`$BACKUP_DIR`, uses the same `.partial`-then-rename discipline, and verifies with
the same `pg_restore --list` / `tar -tzf`. `backup.sh verify` and `restore.sh`
work on an app-made backup, and this page reports on a cron-made one, because
the formats are the same family, not two.

**Media is where the two now differ in layout, not in kind.** `backup.sh media`
still writes ONE `media/kiln-media-<stamp>.tar.gz`. The app writes a set of
independent `tar.gz` parts, `kiln-media-<stamp>.partNN.tar.gz`, when the media
is bigger than one part ([below](#media-backups-in-parts-2218)); a library that
fits in one part keeps the single `kiln-media-<stamp>.tar.gz` name. Every part
is a complete archive, so `tar -tzf` works on each and `restore.sh media`
accepts either shape. Splitting in `backup.sh` is a follow-up. Anything of
yours that globs `kiln-media-*.tar.gz` (a rclone filter, a monitoring script,
a retention job) must accept the `.partNN` names too.

That constraint is why the worker shells out to `pg_dump` and `tar` rather than
implementing them in Elixir: a hand-rolled export would be a second format
with a second restore procedure, and the restore path is where a backup system
earns its keep.

### Media backups in parts (#2218)

A large media library as one archive is one multi-gigabyte file to write,
verify, upload and, after a failure, rebuild from nothing. The app splits the
**set of files** instead. Each part is an ordinary `tar.gz` holding a disjoint
share of the files, so it can be listed, hashed, copied off-site and restored
on its own. (A byte-split of one gzip stream would give pieces that are none of
those.)

**Settings** (in-app path only; both are optional, see
[environment-variables.md](environment-variables.md)):

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_MEDIA_PART_MB` | `400` | Target ceiling on one part, 16 to 10240. It counts the uncompressed **input** bytes, so the archive on disk is usually smaller. A target, not an exact size: a part closes when the next file would pass it, and a single file bigger than the cap becomes a part of its own. Out of range or not a whole number keeps 400 and logs a boot warning. |
| `BACKUP_MEDIA_EXCLUDE` | unset | Comma-separated globs, relative to the media directory, to leave out. `*` and `?` stay within one path segment, `**` crosses segments, and a pattern with no `/` matches a file or directory name at any depth. Example: `tmp/**,cache/**`. |

**Names.** A set of two or more parts is `kiln-media-<stamp>.part01.tar.gz`,
`.part02.tar.gz`, and so on: two digits, widening to three past 99. A set that
needs only one part keeps the legacy `kiln-media-<stamp>.tar.gz`.

**What is and is not in the set**

- Regular files and symlinks (stored as symlinks). Sockets and devices are skipped.
- **Empty directories and directory timestamps are not preserved.** Restoring
  recreates directories as it extracts files into them.
- The file list is fixed when the backup starts. A file uploaded after that is
  in the next backup, not this one. A file deleted before its part is written is
  dropped, and the Run's log says how many.

**Checksums.** Every part has a SHA-256, and so does the set (the SHA-256 of
all the parts' bytes joined in order, what `cat part* | sha256sum` prints). They
are recorded three ways:

- in `manifest.json`, one flat entry per part with the additive keys `sha256`,
  `part` and `parts_total` (the manifest `version` stays 1):

  ```json
  {"kind": "media", "path": "media/kiln-media-20260805-031700.part01.tar.gz",
   "bytes": 419430400, "verified": true, "sha256": "3b1f…",
   "part": 1, "parts_total": 2}
  ```

- on the History row (the Run keeps each part's name, size and hash);
- in sidecar files next to the data, in `sha256sum -c` format:
  `media/kiln-media-<stamp>.sha256` (one line per part) and
  `db/kiln-db-<stamp>.sha256`. `backup.sh` writes both too.

```text
3b1f…e9  kiln-media-20260805-031700.part01.tar.gz
8c02…41  kiln-media-20260805-031700.part02.tar.gz
```

An app-made backup is **verified** only when `tar -tzf` passed, the file's size
matches what was hashed, **and** a SHA-256 was recorded. An imported cron
backup stays `unverified (imported)`; its sidecar supplies the hash recorded
on the row, but nothing is re-checked on import.

**Interrupted? Resume it.** A failed or killed backup leaves its finished work
in `<BACKUP_DIR>/.work/<stamp>/`: the file lists and a `state.json` recording
each finished step and part with its hash. The directory is mode 0700, the
files 0600, and it is removed when the backup succeeds. A directory older than
three days is swept automatically.

1. Open **Backups** (`/editor/backups`) as a platform admin and scroll to
   **History**.
2. On the failed (or "Interrupted") row, click **Resume**. The button shows
   only when the work files are still there. A succeeded, skipped or imported
   row, or a run that is still working, has none.
3. The page shows "Backup resumed — this page updates when it finishes." The
   same row goes back to `Running`, keeping its stamp and start time.

A resume reuses a part only if its recorded SHA-256 still matches the file on
disk; anything else is rebuilt. The file list is the one frozen by the first
attempt. A resumed set can therefore mix times (some parts from the first
attempt, some from the resume), and the Run's log says which parts were reused.
Because finished parts are durable, a library too big to finish in one attempt
converges over repeated resumes. From a release console:
`KilnCMS.Backups.enqueue(resume: "20260805-031700")` queues it, or
`KilnCMS.Backups.Worker.run("console", nil, resume: "20260805-031700")` runs it
inline. A stamp with no failed or stale-running run, or whose work files are
gone, is refused; a resume never turns into a fresh backup. Re-running the
whole backup remains the fallback.

> **Operators who copy the backup directory with `rclone sync $BACKUP_DIR`:**
> exclude `.work/**`. It holds lists of media file names (and is removed on
> success), and has no value off-site.

**Disk space.** There is no free-space check. Budget for the database dump, plus
all finished media parts, plus one part being written, plus the file lists.

**Retention and off-site.** Prune treats one stamp (the dump, every media part
and the sidecars) as ONE set, aged by its newest member, and deletes it whole,
so a retention sweep can never leave half a set. Off-site copies each part and
each sidecar. A failed copy fails the run, as before.

### Backup history (#2217)

**Back up now** is not the only thing the page remembers. Below the status panel,
**History** lists every backup attempt, newest first, 25 to a page. Platform
admins only, like the rest of the page.

1. Open **Backups** (`/editor/backups`) as a platform admin.
2. Scroll to **History**. Each row shows the trigger, a status (`Succeeded`,
   `Failed`, `Running` or `Skipped`), **Database** and **Media** badges, the
   size, whether it was verified, its destinations, and whether its files are
   still on this host. A media set written in several parts shows "N parts".
   A failed or interrupted run shows **Resume**
   ([above](#media-backups-in-parts-2218)).
3. Use **Previous** / **Next** to page ("Page 1 of 3").

The files column reads:

| Shown | Meaning |
|-------|---------|
| `on disk` | Every file is under `BACKUP_DIR`. |
| `pruned (retention)` | The application's own retention removed them. |
| `off-site only` | Gone locally, but every missing file has a successful rclone copy. |
| `expired` | A cron-made backup older than the retention window plus a day; `backup.sh`'s own prune almost certainly removed it. A guess: cron records no prune. |
| `missing` | Gone with no recorded reason: deleted by hand, or recorded by another node. |

"Missing" is worked out when the page is shown, for the 25 rows in view only; it
is never stored, so a restored file turns back to `on disk`.

**Multi-node.** `BACKUP_DIR` belongs to one host. A run recorded by another node
reads `missing` on this one. That is the node's view, not data loss.

**Verified.** An app-made backup is `Verified` once `pg_restore --list` /
`tar -tzf` passed, the size matches the hash and a SHA-256 was recorded. A
backup picked up from cron's files reads `unverified (imported)`: nothing is
hashed or checked on import (a sidecar's hashes are recorded on the row, not re-checked).

**A failed or refused attempt is history too.** A refusal (for example no
`pg_dump` in the image) is a `Skipped` row with the reason, and still leaves
`manifest.json` alone. A backup job killed mid-run stays `Running` until
it has been quiet for 2h15m (measured from the later of its start and its last
update, so a resumed run is not failed for its first attempt's age), then reads
`Failed` ("Interrupted"). Failing to write a row never
fails the backup itself.

### Cron's backups appear in History

`KilnCMS.Backups.Importer.run/0` turns files cron wrote into rows. It runs when
a platform admin opens the page, at the end of every in-app backup, and on
demand:

```bash
bin/kiln eval "KilnCMS.Backups.Importer.run()"
# {:ok, %{imported: 2, pending: 0, skipped: 0, failed: 0}}
```

It scans `$BACKUP_DIR/db` and `$BACKUP_DIR/media` for `kiln-db-<stamp>` and
`kiln-media-<stamp>` files and creates one row per stamp. The parts of one
media set become one artifact. A gap (say `part03` missing) imports the run as
`failed` with "incomplete media set", and a legacy single archive sitting beside
parts of the same stamp is "ambiguous media set", because a restore from either
would silently lack files. Sidecars are not rows; they supply the per-file
SHA-256 shown on an imported row. It is safe to repeat
(idempotent by stamp, never touching a row the application owns), waits until a
stamp's newest file is 10 minutes old and has no `.partial` sibling (`pending`
in the summary), and does not need `BACKUP_ENABLED` or `pg_dump`. `manifest.json`
only enriches a row whose stamped files it names. Run it as a one-off to see
older backups already on disk.

If cron runs `backup.sh db` and `backup.sh media` as separate entries, their
stamps differ and they show as **two** rows, not one. `backup.sh all` is one.

### Secrets in history

Everything stored in a row (errors, log lines, off-site remote) is passed
through `KilnCMS.Backups.Redact`: URL userinfo, `key=value` credentials and
rclone connection-string remotes are replaced with `***`. The status panel's
off-site remote and `manifest.json`'s `offsite` are redacted the same way. Read
access is the platform admin only; the table is written only by the `:backups`
system actor and is purged by the staging scrub (`backup_runs_purged`).

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
will be — see the table above. Rotating them is
[`secrets-rotation.md`](secrets-rotation.md), which is the companion to this
document: this one keeps the data, that one keeps the keys that make some of
the data readable.

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
4. **Restore media.** Local adapter: fetch the whole media set for the stamp
   (every `kiln-media-<stamp>*` file, plus its `.sha256` sidecar) into one
   directory, then run `RESTORE_MEDIA_DIR=/data/kiln/uploads
   ./scripts/restore.sh media kiln-media-<stamp>.part01.tar.gz` (or the legacy
   `kiln-media-<stamp>.tar.gz`) and mount that path into the container at the
   uploads root. The other parts are found automatically; see
   [the multi-part runbook](#restore-a-media-set-that-has-several-parts). S3
   adapter: nothing to do (or promote the replica bucket) — just set the `S3_*`
   env.
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

### Restore a media set that has several parts

Starting point: all parts of one stamp and their sidecar are in a single
directory (for example `rclone copy r2:kiln-backups/media/ . --include
"kiln-media-20260805-031700*"`).

1. Run `restore.sh media` with whichever form is handy; all four mean the same
   set:

   ```bash
   export RESTORE_MEDIA_DIR=/data/kiln/uploads
   ./scripts/restore.sh media ./kiln-media-20260805-031700.part01.tar.gz  # any one part
   ./scripts/restore.sh media ./kiln-media-20260805-031700.part*.tar.gz   # explicit paths
   ./scripts/restore.sh media ./kiln-media-20260805-031700                # stamp prefix
   ./scripts/restore.sh media ./kiln-media-20260805-031700.tar.gz         # legacy single archive
   ```

2. Expect, in order: `==> Verifying checksums from kiln-media-<stamp>.sha256`
   and an `OK` line per part; then `==> [1/2] Extracting …part01.tar.gz →
   /data/kiln/uploads`, `[2/2] …`, and `done.`

What the script checks **before it extracts anything** (a failure stops with
"nothing was extracted"):

- the parts share one stamp, are numbered 01..N with no gap or duplicate
  (sorted by number, not by name), and are not mixed with a legacy single archive;
- the sidecar lists exactly the parts present, every line is a well-formed
  hash, and the hashes match (`sha256sum -c`, or `shasum -a 256 -c` on macOS);
- every part lists cleanly with `tar -tzf`, and no member has an absolute path
  or a `..` component, nor is a symlink or hardlink whose target is absolute or
  contains `..`. That last rule also refuses a harmless `d/x -> ../y` link:
  extract such a set by hand once you have looked at it.

Missing sidecar: the script prints a loud warning and continues, because
backups from before checksums have none. Set `RESTORE_REQUIRE_CHECKSUM=1` to
abort instead. It never falls back to the hashes in `manifest.json`; the
sidecar is the supported record.

**By hand** (no script): check the sidecar, then extract in numeric order.

```bash
cd /backups/media && sha256sum -c kiln-media-20260805-031700.sha256
for p in kiln-media-20260805-031700.part*.tar.gz; do
  tar -xzf "$p" -C /data/kiln/uploads
done
```

Plain `tar -xzf` per part is the supported manual form (the shell glob sorts
two-digit names correctly up to part99). `cat parts | tar -xzi` works only with
GNU tar and is not supported.

What can go wrong:

| Message (abridged) | Meaning |
|---|---|
| `missing part03 in the set for <stamp>` | A part was not copied back. Fetch it; nothing was extracted. |
| `duplicate part02 …` | The same number given twice. |
| `refusing to mix stamps` / `mix a single archive with parts` | Arguments from two backups. Pass one set. |
| `<sidecar> lists <file>, which is missing from the set` | The last part is missing, which contiguity alone cannot see. |
| `checksum verification FAILED` | A part is damaged or was altered. Re-fetch it, or use another copy. |
| `… has a missing or malformed checksum line` | The sidecar is truncated or edited. |
| `contains an absolute or '..' path, or a link pointing outside the tree` | Refused for safety, see above. |
| `RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found` | No sidecar next to the parts. |

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
| `MEDIA_DIR` | backup + app | uploads root (Local adapter only; omit on S3). Defaults to `KILN_MEDIA_ROOT` when that is set |
| `BACKUP_KEEP_DAYS` | backup + app | local retention (default 14) |
| `BACKUP_ENABLED` | app | set false to disable the in-app path only; cron is unaffected (default true) |
| `BACKUP_STALE_AFTER_HOURS` | app | how old before the console warns (default 36) |
| `BACKUP_MEDIA_PART_MB` | app | target ceiling on one media part's input size, 16 to 10240 (default 400) |
| `BACKUP_MEDIA_EXCLUDE` | app | comma-separated globs the media archive leaves out (default none) |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup | off-site rclone remote (strongly recommended) |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill` |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
| `RESTORE_REQUIRE_CHECKSUM=1` | restore | `media`: abort when there is no checksum sidecar (default: warn and continue) |
