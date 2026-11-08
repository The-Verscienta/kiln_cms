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
| **Media** | Local adapter: the uploads root (originals + variants). S3 adapter (`S3_BUCKET` set): the bucket | Local: `backup.sh media` and the in-app **Back up now** both → one `tar.gz`, or several independent `tar.gz` parts for a library bigger than 400 MB ([below](#media-backups-in-parts-2218)). S3/R2: provider-side (below) |
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
  losing the VPS. Set `BACKUP_RCLONE_REMOTE` (R2/B2/S3 — any rclone remote).
  An off-site copy that fails fails the run, in cron and in the app, so it
  surfaces: cron exits non-zero, and the app marks the run `Failed`.
- **Only the file that verified leaves the host.** Each file (the dump, every
  media part, every `.sha256` sidecar) is hashed again immediately before its
  own off-site copy and compared with the SHA-256 recorded when it verified. A
  file that changed in between is not uploaded and the run fails
  ([When an off-site copy is refused](#when-an-off-site-copy-is-refused)).
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

**Media is split the same way by both.** `backup.sh media` (and `all`) and the
app write a set of independent `tar.gz` parts,
`kiln-media-<stamp>.partNN.tar.gz`, when the media is bigger than one part
([below](#media-backups-in-parts-2218)); a library that fits in one part keeps
the single `kiln-media-<stamp>.tar.gz` name. Given the same media directory and
settings, both put the same files in the same parts under the same names. Every
part is a complete archive, so `tar -tzf` works on each and `restore.sh media`
accepts either shape. Anything of yours that globs `kiln-media-*.tar.gz` (a
rclone filter, a monitoring script, a retention job) must accept the `.partNN`
names too.

The one difference is recovery. A failed in-app backup keeps its finished parts
so it can be [resumed](#media-backups-in-parts-2218); a failed cron run removes
the parts it wrote and keeps nothing to resume ([below](#cron-backups-in-parts)).

That constraint is why the worker shells out to `pg_dump` and `tar` rather than
implementing them in Elixir: a hand-rolled export would be a second format
with a second restore procedure, and the restore path is where a backup system
earns its keep.

### Media backups in parts (#2218)

A large media library as one archive is one multi-gigabyte file to write,
verify, upload and, after a failure, rebuild from nothing. The app and
`backup.sh` split the **set of files** instead. Each part is an ordinary `tar.gz` holding a disjoint
share of the files, so it can be listed, hashed, copied off-site and restored
on its own. (A byte-split of one gzip stream would give pieces that are none of
those.)

**Settings** (read by the app and by `backup.sh`, by the same names; both are
optional, see [environment-variables.md](environment-variables.md)):

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_MEDIA_PART_MB` | `400` | Target ceiling on one part, 16 to 10240. It counts the uncompressed **input** bytes, so the archive on disk is usually smaller. A target, not an exact size: a part closes when the next file would pass it, and a single file bigger than the cap becomes a part of its own. Out of range or not a whole number keeps 400 and warns: a boot warning in the app, a `warning:` line on stderr from `backup.sh`. There is no setting that turns splitting off; 10240 is the largest part. |
| `BACKUP_MEDIA_EXCLUDE` | unset | Comma-separated globs, relative to the media directory, to leave out. `*` and `?` stay within one path segment, `**` crosses segments, and a pattern with no `/` matches a file or directory name at any depth. Example: `tmp/**,cache/**`. A pattern ending in `/` (`cache/`) matches nothing: write `cache` (that name at any depth) or `cache/**`. |

**Names.** A set of two or more parts is `kiln-media-<stamp>.part01.tar.gz`,
`.part02.tar.gz`, and so on: two digits, widening to three past 99. A set that
needs only one part keeps the legacy `kiln-media-<stamp>.tar.gz`.

**What is and is not in the set**

- Regular files and symlinks (stored as symlinks). Sockets and devices are skipped.
- **File names are archived byte-exact, including names that are not valid
  UTF-8.** A name the server's file-name encoding cannot represent or stat is
  left out of the set, never silently: it is counted and shown as a warning in
  the run's log (and in the server log), with up to five examples, so an
  operator can see that files are missing from the backup. (`plan.json` carries
  the two additive keys `unreadable_names` and `unreadable_examples`.)
- **Empty directories and directory modes, owners and timestamps are not
  preserved.** Restoring recreates directories as it extracts files into them,
  owned by the user running the restore with that user's default mode
  (typically `root:root`, `0755`). Restoring as root? `chown -R` the media root
  to the user the app runs as afterwards.
- The file list is fixed when the backup starts. A file uploaded after that is
  in the next backup, not this one. A file deleted before its part is written is
  dropped, and the Run's log (`backup.sh`: a `warning:` line on stderr) says how
  many.

**Checksums.** Every part has a SHA-256, and so does the set (the SHA-256 of
all the parts' bytes joined in order, what `cat part* | sha256sum` prints). They
are recorded three ways (`backup.sh` records the per-part hashes, in the
manifest and the sidecar; the set's hash is the app's alone):

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
files 0600, and it is removed only when the backup and its off-site copy both
succeed, so a run that failed off-site can be resumed too. A directory older
than three days is swept automatically, and with it the chance to resume.

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
so a retention sweep can never leave half a set. Off-site copies the dump, each
part and each sidecar, one `rclone copy` per file, each after its own re-hash.
A failed copy, of a data file or of a sidecar, fails the run: a part set whose
sidecar never left the host is one `restore.sh` refuses to restore from the
remote. There is no retry in Kiln itself; rclone's own retries are the retries
(`--retries`, 3 by default, settable with `RCLONE_RETRIES` in the environment of
the app or the cron line). The run is marked failed only after those.

The app prunes before its off-site copy, so expired sets are removed even when
the off-site copy then fails. Cron prunes only at the end of a run that
succeeded, off-site copy included. Prune never touches the current stamp.

The re-hash costs one extra sequential read of every file, and only when a
remote is set. It is far quicker than the upload that follows, and it leaves
the file in the page cache for rclone's own read.

### When an off-site copy is refused

A refusal means a file changed on disk between the moment this backup verified
it and the moment it was about to be uploaded. The backup wrote that file
once, verified it and recorded its SHA-256, and then something else wrote to
it: a disk fault, a second process with access to `BACKUP_DIR`, a person. The
file is not uploaded, not retried, and not rebuilt in that run, because a
changed backup file is the operator's to look at, not the backup's to paper
over.

**Where it shows (in-app backup).** The run is `Failed`. The error appears in
the **Last run failed** box on `/editor/backups` and on the History row. The
row reads **Not verified**, the refused file loses its **Verified** badge in
the **Artifacts** list, and the overview shows its red backup strip. The error names each file and why, for example (one line,
wrapped here):

```text
Off-site copy REFUSED for 1 file: kiln-media-20261108-031700.part02.tar.gz
(changed on disk after this backup verified it (sha256 expected 3b1f0c9a2e41…,
found 8c02d7e5b6f1…)). Something other than this backup wrote to the backup
directory: check the disk and anything with access to BACKUP_DIR before
trusting this backup. The local files are kept; Resume retries the off-site
copy and rebuilds any file that changed.
```

Other reasons in the same place: `it is missing`, `it is no longer a regular
file` (a symlink or directory swapped in), `the checksum file changed after it
was written` and `the checksum file is no longer well-formed` (a sidecar). A
copy that rclone itself failed is listed separately, as `Off-site copy FAILED
for N files: <name> (rclone exited 1)`. At most five files are named per list,
then "and N more". The server log has a line per refused file with both full
digests, and the run's log in the database has the rclone output for a failed
copy (redacted).

**Where it shows (cron).** `backup.sh` stops at the first refusal, exits
non-zero (so `MAILTO` and the missing `BACKUP_PING_URL` ping catch it), prints
the error to stderr after `error: `, and for `backup.sh all` writes it into a
failure manifest, which the panel shows in **Last run failed** (one line,
wrapped here):

```text
REFUSING off-site copy of kiln-media-20261108-031700.part02.tar.gz: its
sha256 changed after this backup verified it (expected 3b1f…, found 8c02…).
Nothing was uploaded for it. Something other than this backup wrote to
/var/backups/kiln: check the disk before trusting this backup.
```

(The digests in the real message are full length.) A missing file or a
symlink reads `it is missing or no longer a regular file`. A copy that rclone
itself failed stops the run the same way; its manifest error is only
`backup.sh exited <status> - see the backup log`, and rclone's own output is in
that log.

**What did and did not leave the host.**

- **App:** every other file is still re-hashed and copied, one by one, so the
  remote has everything except the refused files (and any whose copy failed).
  A part set missing a part on the remote is not restorable from there:
  `restore.sh` stops with `<sidecar> lists <file>, which is missing from the
  set`.
- **Cron:** files copied before the refusal are on the remote; nothing after it
  was copied, and for `backup.sh all` a refusal during the database phase means
  the media set was never built.
- **Both:** all local files are kept, the changed one included, and the
  manifest records the refused file as not verified and `"offsite": null`.
- **The sidecars differ slightly.** Cron hashes a sidecar's bytes, so any edit
  to it is caught. The app compares the sidecar's parsed lines with the
  digests and names it recorded, in order: a changed digest, name, line order
  or an extra line is caught, while a change the parser ignores (a blank line,
  one space instead of two before the name, `sha256sum`'s `*` binary marker)
  is not.

**What to check.** Look at the disk (`dmesg`, SMART, filesystem errors) and at
anything else that can write to `BACKUP_DIR`: a second cron entry or host, a
sync job pointed the wrong way, a restore unpacked into it. Compare the file
with the digest the error names (`sha256sum <file>`).

**Then retry.**

1. If you want the changed file as evidence, copy it out of `BACKUP_DIR`
   first. A resume replaces it.
2. **App, with a media directory:** open **Backups** as a platform admin and
   click **Resume** on the failed History row (see [Interrupted? Resume
   it.](#media-backups-in-parts-2218)). Files that still match `state.json`
   are reused, and only a file that changed (or was replaced by a symlink or
   other non-regular file) is rebuilt. A rebuilt dump is a fresh `pg_dump`,
   taken at resume time. Every file is re-hashed and copied off-site again;
   rclone skips a file the remote already holds unchanged. The row goes back to
   `Running` and ends `Succeeded`, or `Failed` again and still resumable.
3. **App, database only** (S3 media adapter, or no media directory): there is
   no work directory, so there is no Resume. Click **Back up now** for a new
   backup; the error says "run a new backup to try the off-site copy again".
4. **Cron:** run `backup.sh all` again (or wait for the next run). Cron has no
   resume; the next run is a new stamp.

A copy that failed (rather than was refused) is retried the same way, after
fixing what rclone reported: usually the remote's name, its credentials in
`rclone.conf`, or the network.

### Cron backups in parts

`backup.sh media` and `backup.sh all` split media exactly as the app does, with
the same two settings. Nothing needs to change in an existing cron line; to try
it on a host:

1. Optionally add `BACKUP_MEDIA_PART_MB` and `BACKUP_MEDIA_EXCLUDE` to the cron
   environment, beside `MEDIA_DIR` in the cron entry at the top of this page.
   Unset means 400 MB parts and nothing excluded.
2. Run the media phase by hand as the cron user. This is a real backup (no
   manifest, since only `all` writes one); History shows it as a media-only row.

   ```bash
   MEDIA_DIR=/data/kiln/uploads BACKUP_DIR=/var/backups/kiln \
     BACKUP_MEDIA_EXCLUDE=cache \
     ./scripts/backup.sh media
   ```

   It plans first, then writes one part at a time:

   ```text
   ==> Planning media archive of /data/kiln/uploads
   ==> Planned 48211 file(s) in 3 part(s) (cap 400 MB), 112 excluded by BACKUP_MEDIA_EXCLUDE
   ==> Archiving media part 1 of 3 → /var/backups/kiln/media/kiln-media-20261108-031700.part01.tar.gz
       ok: 371M kiln-media-20261108-031700.part01.tar.gz
   …
   ```

3. Look in `$BACKUP_DIR/media/`. A library that fits in one part is one
   `kiln-media-<stamp>.tar.gz`, as before. A bigger one is
   `kiln-media-<stamp>.part01.tar.gz` … `.partNN.tar.gz` plus one
   `kiln-media-<stamp>.sha256` with a line per part. Every file is mode 0600.
4. `backup.sh all` also writes one `manifest.json` entry per part, with `part`
   and `parts_total`, and the run shows as one row in
   [History](#backup-history-2217) with "N parts".

**What it needs.** GNU tar or bsdtar: every part is built from a NUL-separated
file list (`--null -T`), and a tar that cannot read one (busybox) is refused
before anything is written: "tar cannot read a NUL-separated file list". Also
`stat` (GNU or BSD), `xargs`, `mktemp`, `head`, `gzip`, and `sha256sum` or
`shasum`; bash 3.2 or later. `iconv` is used when present to keep error text in
the manifest valid UTF-8. The file lists are built in `TMPDIR` (default `/tmp`)
and removed when the script exits. Planning a very large library in shell takes
longer than the app does, and grows with the number of files.

**Permissions.** Parts and the sidecar are 0600 from their first byte (the
media phase runs under `umask 077`). If the script creates `$BACKUP_DIR/media`,
it creates it 0700; an existing directory keeps its mode. The app sets the same
directory to 0700 on every run. If cron and the app run as different users, one
of them cannot write there, so run both as the same user.

**When a run fails.** Cron has no resume. If any part fails (`tar` is retried
once from a re-checked list first), or the run is interrupted with `HUP`, `INT`
or `TERM`, the script removes every part it wrote for that stamp, so a partial
set never looks like a backup. A database dump that already finished is kept.
A failed or [refused](#when-an-off-site-copy-is-refused) off-site copy after
the set is complete keeps the set and fails the run, and the files after it are
not copied.

**When a run is killed outright** (`kill -9`, power loss), no cleanup runs. The
run leaves its finished parts and an in-progress marker,
`media/kiln-media-<stamp>.sha256.partial`. While the marker is there, History
does not import the stamp, `backup.sh verify` skips it, and `restore.sh media`
refuses it. The next in-app backup removes a `.partial` file older than an hour;
after that, History imports the leftover parts as failed ("incomplete media
set: parts but no sidecar"). Delete the stamp's `kiln-media-<stamp>*` files by
hand to tidy up sooner.

**`backup.sh verify`** checks the newest media stamp that has no `.partial`
beside it, and names any newer one it skipped ("Skipping media set <stamp>:
still being written, or interrupted"). It fails on parts with no sidecar, and
fails when every media stamp it found is unfinished.

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
would silently lack files. Parts with no media sidecar import as `failed`
with "incomplete media set: parts but no sidecar": every part set is written
with one, so parts without it are what a run killed mid-set leaves (a manifest
calling them verified does not excuse it). A legacy single archive without a
sidecar, from before checksums, imports as before. Sidecars are not rows; they supply the per-file
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

**The official image does not install `rclone`.** With `BACKUP_RCLONE_REMOTE`
set in the app's environment and no `rclone` on its `PATH`, an in-app backup
still runs and succeeds, but copies nothing off-site. That is deliberate: on a
host that copies the same `BACKUP_DIR` off-site by other means, failing every
in-app run would be wrong. It is not silent:

- **Where backups go** on `/editor/backups` shows an **Off-site** line with the
  remote (credentials masked) and "rclone is not installed in this image, so
  backups taken from this page are not copied off-site."
- Each run logs a warning, in the server log and in the run's log:
  "BACKUP_RCLONE_REMOTE is set but rclone is not installed in this image;
  nothing was copied off-site".
- The manifest's `offsite` stays `null`.

To copy in-app backups off-site, build your own image on top of Kiln's with
`rclone` installed and configured for the user the app runs as (`nobody`), or
copy the directory from the host (`rclone sync` of `BACKUP_DIR`, excluding
`.work/**`), or snapshot the volume. `backup.sh` copies only the files its own
run wrote, so a cron entry alone does not carry the app's backups off-site.

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

It also refuses a set with a `kiln-media-<stamp>.*.partial` file beside it: a
backup is still writing that stamp, or was killed while writing it.

Missing sidecar on a legacy single archive: the script prints a loud warning
and continues, because backups from before checksums have none. Set
`RESTORE_REQUIRE_CHECKSUM=1` to abort instead. Missing sidecar on a `.partNN`
set: the script warns and stops, because every complete part set has a sidecar,
so one without is most likely what a killed run left behind and would restore
with files missing. If you know the set is whole (you removed the sidecar
yourself, say), set `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` to restore it
anyway. It never falls back to the hashes in `manifest.json`; the sidecar is the
supported record.

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
| `RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found` | No sidecar next to the archive or parts, and you asked for one. |
| `the part set for <stamp> has no sidecar, so it is probably incomplete` | Parts with no `kiln-media-<stamp>.sha256`. Fetch the sidecar if it exists; otherwise the set is probably from a killed run. `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` restores it anyway. |
| `kiln-media-<stamp>.sha256.partial is beside the set for <stamp>` | A backup is writing this stamp, or was killed while writing it. Wait for a running backup to finish, or pick another stamp; a leftover from a killed run is [removed](#cron-backups-in-parts) by the next in-app backup after an hour, or delete it and the set by hand. |

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
| `BACKUP_MEDIA_PART_MB` | backup + app | target ceiling on one media part's input size, 16 to 10240 (default 400) |
| `BACKUP_MEDIA_EXCLUDE` | backup + app | comma-separated globs the media archive leaves out (default none) |
| `TMPDIR` | backup | where `backup.sh` builds the media file lists (default `/tmp`); removed when it exits |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup + app | off-site rclone remote (strongly recommended). Each file is re-hashed before its copy; a refused or failed copy fails the run. The app needs `rclone` in its image ([above](#it-needs-the-client-tools-in-the-image)) |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill` |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
| `RESTORE_REQUIRE_CHECKSUM=1` | restore | `media`: abort when there is no checksum sidecar (default: warn and continue for a legacy single archive) |
| `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` | restore | `media`: restore a `.partNN` set that has no sidecar (default: refuse, since a set without one is most likely from a killed run) |
