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
| DB dump | nightly (cron above) | 14 days (`BACKUP_KEEP_DAYS`), and always the newest good one ([below](#what-retention-deletes-and-what-it-keeps)) | every dump, via `BACKUP_RCLONE_REMOTE` |
| Media archive (Local adapter) | nightly, same run | 14 days, all parts of a set together, and always the newest good one | every part and sidecar |
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

### What retention deletes and what it keeps

Both paths delete old local backups. The app does it during every in-app
backup, once that backup's own files have verified and before its off-site
copy; a backup whose own files failed prunes nothing. `backup.sh` does it at the
end of a `backup.sh all` that succeeded, and on its own as `backup.sh prune`.
Neither touches the off-site copies.

`BACKUP_KEEP_DAYS` (default 14) is the age at which a backup **may** be
deleted, not a promise that it will be. "Older than `BACKUP_KEEP_DAYS`" means
what `find -mtime +N` means: at least N + 1 whole days old. With the default, a
dump 14 days and 6 hours old stays and one 15 days old may go.

**The unit is one component of one stamp.** A stamp's database dump and its
sidecar are one unit; its media archive (or every part of it) and the media
sidecar are another. Each unit is aged by its own newest file and deleted
whole: the data files first, the sidecar last, so a unit that stops half-way
still has its checksums. The two components of a stamp come and go
independently, so an old dump can be deleted while the same stamp's newer media
stays. A resumed backup is the usual case: its dump keeps the time of the first
attempt, while the parts the resume rebuilt are newer. With a very small
`BACKUP_KEEP_DAYS`, that dump can age out before its media does.

**Keep rules.** For each unit, the first rule that holds decides:

1. **Recovery point.** A `kiln-<stamp>.keep` marker in `db/` or `media/` keeps
   both components of that stamp, however old
   ([below](#keep-a-backup-as-a-recovery-point)).
2. **In flight.** The stamp has a `.work/<stamp>/` directory, or a `.partial`
   file of that unit younger than an hour, or (app only) its History row is
   still `Running`. This is what keeps the backup doing the pruning, and one
   still being written by cron or another job, out of reach.
3. **Newest verified.** The newest unit of its kind, by stamp, that is complete
   on disk and belongs to a `Succeeded` run whose artifact of that kind is
   verified (app-made) or present (imported from cron, which is never
   verified). The app never deletes it. Cron has no History, so it learns
   which unit this is from the app's
   [last-good marker](#the-last-good-marker) and keeps that.
4. **Newest complete.** The newest unit of its kind, by stamp, that is complete on disk,
   whatever its run says. `backup.sh prune` keeps the same one, so the two
   prunes together cannot empty a component.
5. **Age.** Anything else is deleted once it is older than `BACKUP_KEEP_DAYS`.
   That includes a unit with no History row, with a `Skipped` row, or whose
   row records no artifact of that kind.

Rules 3 and 4 choose only among units that are not in flight and whose stamp is
a real date and time no more than a day ahead of the clock. A backup still being
written, a misnamed file or a future-dated stamp never takes the slot from the
last finished backup.

**Complete on disk** is judged from the final files alone. A database unit
needs its dump; a media unit needs either the single archive and no parts, or
parts `01` to `N` with no gap, no single archive beside them, and the media
sidecar. Each of those must be a regular, non-empty file: a symlink, a
directory or an empty file does not count. A `.partial` younger than an hour
makes the unit in flight; an older one is ignored.

**What this means for the disk.** When backups stop (cron not running, every
run failing), the last good backup of each component stays past
`BACKUP_KEEP_DAYS` instead of being pruned away. Budget for up to two units per
component older than the window (the newest verified and the newest complete
can be different stamps), plus every recovery point, plus for cron any unit a
stale [last-good marker](#the-last-good-marker) still names.

**Never deleted by retention:** `.partial` files (the next in-app backup
removes those older than an hour), symlinks, directories, `.work/`, and
recovery-point markers. Last-good markers are never aged either; the app moves
them itself ([below](#the-last-good-marker)). A `kiln-*` file in `db/` or `media/` that belongs to no
unit, such as a part named `part001` instead of `part01`, is a stray: the app
deletes it once it is older than `BACKUP_KEEP_DAYS`, and `backup.sh` leaves it
alone.

In History, a run whose dump retention removed while its media is still on disk
reads `partly pruned (retention)` ([Backup history](#backup-history-2217)).

### Keep a backup as a recovery point

Pin one backup, say the last one before a migration, so retention never deletes
it. You need a shell on the host, as the user that runs the backups. The Backups
page does not show or set recovery points yet.

1. Find the backup's stamp: the `YYYYMMDD-HHMMSS` (UTC) in its file names.

   ```bash
   ls /var/backups/kiln/db/
   # kiln-db-20261020-031700.dump  kiln-db-20261020-031700.sha256  …
   ```

2. Create the marker in `db/` or `media/`. One marker pins both components of
   the stamp.

   ```bash
   touch /var/backups/kiln/db/kiln-20261020-031700.keep
   ```

3. The next prune, in-app or cron, keeps every file of that stamp. Nothing is
   printed for a kept backup; `backup.sh prune` prints only the files it
   removes.

To release it, delete the marker. The backup then ages like any other, so one
already older than `BACKUP_KEEP_DAYS` goes at the next prune unless it is the
newest verified or newest complete one.

Things to know:

- Only the marker's name counts. It can be an empty file, a directory or a
  symlink; its contents are never read.
- The name must be exactly `kiln-<stamp>.keep` with a full stamp.
  `kiln-20261020.keep` pins nothing, and is left alone too.
- Retention never creates or deletes a `.keep`. A marker whose backup is gone
  is harmless.
- Markers live on this host's disk, not in the database, so they survive a
  database restore. `rclone sync` of `BACKUP_DIR` copies them like any file.
- Rolling back to a release before markers existed: its in-app prune does not
  honour them, and deletes a marker itself once the marker file is older than
  `BACKUP_KEEP_DAYS`.

**See what the app would delete.** A dry run plans without deleting. Run it
against the live app with `rpc` (as in [deploy.md](deploy.md)), since it reads
History. It imports cron-made backups into History first, as every retention
run does.

```bash
bin/kiln_cms rpc 'KilnCMS.Backups.Retention.run(KilnCMS.Backups.dir(), dry_run: true) |> IO.inspect()'
```

It returns `{:ok, %{deleted: [], units: 0, stopped: nil, plan: plan}}`. Each
entry of `plan.delete` and `plan.keep` names its unit, its files and the rule
that decided. For example, the plan for this directory with
`BACKUP_KEEP_DAYS=7`, a recovery point on `20261020-031700`, and none of the
stamps in History yet (reformatted):

```text
db/    kiln-20261020-031700.keep
db/    kiln-db-20261020-031700.dump   kiln-db-20261020-031700.sha256   (19 days old)
db/    kiln-db-20261025-031700.dump   kiln-db-20261025-031700.sha256   (14 days old)
db/    kiln-db-20261107-031700.dump   kiln-db-20261107-031700.sha256   (today)
media/ kiln-media-20261025-031700.tar.gz                               (14 days old)
```

```elixir
%{
  delete: [
    %{stamp: "20261025-031700", kind: :db, sub: "db",
      files: ["kiln-db-20261025-031700.dump", "kiln-db-20261025-031700.sha256"],
      reason: {:expired, :unrecorded, 7}}
  ],
  keep: [
    %{stamp: "20261020-031700", kind: :db, sub: "db",
      files: ["kiln-db-20261020-031700.dump", "kiln-db-20261020-031700.sha256"],
      reason: :recovery_point},
    %{stamp: "20261025-031700", kind: :media, sub: "media",
      files: ["kiln-media-20261025-031700.tar.gz"],
      reason: :newest_complete},
    %{stamp: "20261107-031700", kind: :db, sub: "db",
      files: ["kiln-db-20261107-031700.dump", "kiln-db-20261107-031700.sha256"],
      reason: :newest_complete}
  ],
  last_good: %{db: nil, media: nil}
}
```

The `20261025-031700` dump goes while that stamp's media stays: it is the
newest complete media unit, and the newer `20261107-031700` stamp has no media.
`backup.sh prune` on the same directory removes the same two files. A kept
unit's `reason` is one of `:recovery_point`, `:in_flight`, `:newest_verified`,
`:newest_complete`, `:unrecorded` or `:keep_days`; a deleted one's is
`{:expired, rule, days}`, where `rule` is `:unrecorded`, `:keep_days` or
`:stray`. Once the newest unit of a kind belongs to a succeeded run that verified it (or
imported it from cron), it reads `:newest_verified` instead. `plan.last_good`
is that newest verified stamp of each kind, or `nil` when there is none: what
the [last-good markers](#the-last-good-marker) should name. A dry run writes no
marker.

### The last-good marker

`kiln-<stamp>.good` tells `backup.sh prune` which backup of each component the
app last saw verified, so cron keeps it too (rule 3 above). Cron has no
History to work that out; the app writes the answer to disk. You don't create
these markers; this section is what to expect on the host and what to do when
one is left behind.

What it is:

- **An empty file in the component's own directory**, mode 0600. It pins only
  that component of that stamp: `db/kiln-20261107-031700.good` keeps that
  dump and its sidecar from `backup.sh prune`, never the media of the same
  stamp. A recovery point (`.keep`) pins both.
- **Only its presence counts.** `backup.sh prune` reads the directory listing,
  so an entry of that exact name of any kind (file, directory, symlink) keeps
  the unit; its contents are never read.
- **At most one per directory**, once the app has brought it in step: the
  newest verified dump in `db/`, the newest verified media set in `media/`.
  A component with no verified unit keeps whatever marker it already has.
- **It can name a cron-made backup.** A backup imported from cron counts as
  verified once its run is `Succeeded` and its file is present (rule 3), so the
  marker often lands on last night's cron set.

When the app writes it:

- **At the end of every successful in-app backup**, after the run is closed and
  its `.work/<stamp>/` is gone, while it still holds the backup lock. It imports
  cron's backups into History first, so the newest verified backup is chosen
  from both.
- **Before every in-app prune deletes anything.** The prune runs during each
  in-app backup (the backup in progress is in flight, so the marker names the
  previous one at that point), and when you call
  `KilnCMS.Backups.Retention.run/2` yourself.
- **Never on a dry run, and never by cron.** `backup.sh` reads markers and
  writes none.

The new marker is written first, and the component's other `.good` markers are
removed only once it is there, so a cron prune that runs in between keeps both
units, never neither. The app itself does not read `.good` markers: it works out
the newest verified backup from History every time, so a stale marker pins
nothing in the app, and its unit ages there like any other.

**Turn it on.** Nothing to configure; you only need the new script on the host.

1. Replace the host's copy of `scripts/backup.sh` (the one your cron line
   runs, `/opt/kiln_cms/scripts/backup.sh` in the cron line at the top of
   this guide) with this release's. An older copy
   ignores `.good` markers and can still delete the newest verified backup.
2. Take an in-app backup, or wait for the next one. No marker exists before
   the first one finishes.
3. List the backup directories. Each component with a verified backup has one
   marker:

   ```bash
   ls /var/backups/kiln/db/ /var/backups/kiln/media/
   # /var/backups/kiln/db/:
   # kiln-20261107-031700.good  kiln-db-20261107-031700.dump  kiln-db-20261107-031700.sha256  …
   #
   # /var/backups/kiln/media/:
   # kiln-20261107-031700.good  kiln-media-20261107-031700.sha256  kiln-media-20261107-031700.tar.gz  …
   ```

A deployment that backs up only with cron never runs an in-app backup, so it
gets no marker, and its prune keeps only the newest complete set, as before.

Things to know:

- **Don't delete a `.good` by hand while in-app backups run.** The app moves
  it at the next backup anyway, and until then cron can delete the backup it
  named.
- **If you stop taking in-app backups**, the last marker of each component
  stays, and cron keeps that unit past `BACKUP_KEEP_DAYS` indefinitely.
  Delete the marker by hand when you want cron to age that backup.
- **A marker the app cannot remove** (a directory or symlink of that name, or a
  file it has no permission to delete) pins its unit for cron indefinitely.
  The app leaves it, logs a warning, and emits the telemetry event below.
  Remove it by hand.
- **Rolling back to a release before this one.** Its in-app prune ignores
  `.good` markers and deletes each one as a stray once the marker file is older
  than `BACKUP_KEEP_DAYS`; harmless. If the host's `backup.sh` stays at this
  release, cron keeps honoring the markers that remain until then.

**When a marker can't be moved.** The backup or prune still succeeds; the
marker is housekeeping. Each of these logs a warning, and all but the last
emit `[:kiln_cms, :backups, :last_good, :failed]` with measurements
`%{count: 1}`:

| Server log | Telemetry metadata | Meaning |
|---|---|---|
| `Backup last-good marker not updated: <reason>` | `%{reason: reason}` | After an in-app backup or before an in-app prune, importing cron's backups, listing `db/`, `media/` or `.work/`, reading a file in them, or reading History failed. No marker was written or removed. The reasons read as in [When retention is skipped or stops](#when-retention-is-skipped-or-stops). |
| `Backup last-good marker db/kiln-<stamp>.good couldn't be written (<reason>); the previous marker stays` | `%{kind: :db, stamp: stamp, reason: posix}` | The new marker could not be created, so the old one was left pinning the previous backup. A `reason` of `:eacces` is a permission problem on that directory. |
| `Couldn't remove old last-good marker db/kiln-<stamp>.good (<reason>)` | `%{marker: "db/kiln-<stamp>.good", reason: {:remove, posix}}` | The new marker is in place, but an old one could not be deleted. Cron keeps both units. |
| `Left db/kiln-<stamp>.good in place: a directory, not a regular file` | `%{marker: "db/kiln-<stamp>.good", reason: {:not_regular, type}}` | Something other than a regular file has an old marker's name. The app removes only regular files. |
| `Couldn't list db/ to remove old last-good markers (<reason>)` | none | The new marker is in place; old ones stay until the next sync. |

### What the cron prune cannot see

`backup.sh` has no database, so it sees two of the rules above only partly:

- **It knows the newest verified backup only through the last-good marker.**
  It keeps the unit the app marked with `kiln-<stamp>.good`, so when the newest
  complete set on disk came from a run that failed (for example its off-site
  copy was refused), cron keeps both that set and the older verified one. This
  holds only while the app keeps the marker in step: a host whose copy of
  `backup.sh` predates the marker, a deployment where the app has not yet run
  a backup or a prune, and a marker deleted by hand all leave cron keeping the
  newest complete set alone, and deleting the verified one once it is past
  `BACKUP_KEEP_DAYS` ([The last-good marker](#the-last-good-marker)).
- **It cannot see an in-app backup that is `Running`.** It relies on that
  backup's `.work/<stamp>/` directory and `.partial` files instead.

It never deletes strays, and never deletes a `.keep` or a `.good` marker.

### When retention is skipped or stops

Retention fails closed: when it cannot see everything its rules need, it deletes
nothing. The backup itself is not affected either way; it succeeds or fails on
its own files and off-site copy.

**In the app**, retention is skipped when importing cron's backups into History
fails, when `db/`, `media/` or `.work/` cannot be listed, when a file in them
cannot be read, or when History cannot be read. It writes an error to the
server log ("Backup retention skipped: …; nothing was deleted"), emits the
`[:kiln_cms, :backups, :retention, :skipped]` telemetry event (measurements
`%{count: 1}`, metadata `%{reason: reason}`), and adds a `prune` line at error
level to the run's log in the database:

```text
Retention skipped: couldn't read the backup history (Ash.Error.Forbidden); nothing was deleted
```

Other reasons in the same place: `couldn't import cron-made backups into the
backup history (…)`, `couldn't list media/ in the backup directory (…)`,
`couldn't read <file> (…)`, and `the retention policy is invalid
(BACKUP_KEEP_DAYS must be a whole number of days, 1 or more)`.

Right before each unit goes, the app looks again: a unit that has gained a
`.work/<stamp>/` directory or a recovery-point marker, whose run is now `Running`, or whose run
cannot be read is left in place. A file that cannot be removed stops that unit,
so its sidecar stays. If the deleting itself breaks off, the run's log reads
"Retention removed 2 file(s) from 1 backup(s), then stopped: …", the server log
has the error, and `[:kiln_cms, :backups, :retention, :stopped]` is emitted
(measurements `%{count: 1, deleted: n}`). The files already removed are still
marked `pruned` in History. A normal sweep logs "Retention removed N file(s)
from M backup(s)".

**In cron**, `backup.sh prune` prints a `warning:` line on stderr, deletes
nothing and exits 0 (so `backup.sh all` still succeeds) when `db/`, `media/` or
`.work` exists but cannot be listed, or when this host's `date` supports neither
GNU `date -d @N` nor BSD `date -r N`. A unit whose `.partial` files it cannot
look for is kept, and a file it cannot remove stops that unit. Read the cron
log for these: no ping or exit code reports them.

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

The in-app backup (`KilnCMS.Backups.Steps`) runs the same `pg_dump --format=custom --no-owner
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

That constraint is why the app shells out to `pg_dump` and `tar` rather than
implementing them in Elixir: a hand-rolled export would be a second format
with a second restore procedure, and the restore path is where a backup system
earns its keep.

### How an in-app backup runs (#2218)

An in-app backup is a chain of Oban jobs, one per step, on the `backup_steps`
queue:

**start** → **dump** → **plan** → **archive** (one job per media part) →
**checksum** → **prune** → **offsite** → **finish**

`plan`, `archive` and `checksum` run only when there is a media directory. Each
step reads what the previous ones did from `.work/<stamp>/state.json`, does its
own work and hands over to the next. A failure therefore costs one step, not the
whole backup: a database dump that verified is not taken again because the
fourth media part failed.

**One at a time, cluster-wide.** A lock in the database (one row in
`backup_locks`) lets one chain run at a time across every node. A backup asked
for while one runs waits behind it ([below](#back-up-while-another-backup-runs)).

**Retries.** Each step has four attempts, 1, 5 and 15 minutes apart, and at
most 2 hours per attempt. Neither is configurable. The run's log in History
records each failed attempt. After the fourth, the backup fails.

**Failures a retry cannot fix fail at once**, without spending the remaining
attempts:

| Failure | Error on the run | What to do |
|---|---|---|
| A media part changed on disk between being archived and being checksummed | "Media part(s) changed on disk between being archived and being checksummed: `<names>`. Something other than this backup wrote to the backup directory; Resume rebuilds the changed part(s)." | Find what writes to `BACKUP_DIR`, then **Resume**: it rebuilds only the parts whose hash no longer matches. |
| A file refused before its off-site copy | "Off-site copy REFUSED for …" | [When an off-site copy is refused](#when-an-off-site-copy-is-refused). |
| The work state is gone, or belongs to another backup | "The backup's work state (.work/`<stamp>`/state.json) is missing or belongs to another backup; nothing more can be done for this one" | Take a new backup. No failure manifest is written, so the panel keeps showing the previous backup. |

**When a backup fails**, it writes a failure manifest (when its `state.json`
is there to say what landed), marks the run `Failed`, releases the lock and
starts the queued backup, if there is one. A backup the deployment cannot run
at all (`BACKUP_ENABLED=false`, no `pg_dump` in the image on the node that
picked up the start step) is a `Skipped` row and leaves `manifest.json` alone,
as before.

**Telemetry.** The chain emits, each with measurements `%{count: 1}`:

| Event | Metadata | When |
|---|---|---|
| `[:kiln_cms, :backups, :chain, :settled]` | `chain`, `stamp`, `outcome` (`:ok` or `{:error, reason}`) | A chain ended: succeeded, failed, canceled or refused at its start. |
| `[:kiln_cms, :backups, :request, :folded]` | `trigger`, `resume` | A request folded into the queued one. |
| `[:kiln_cms, :backups, :lock, :reclaimed]` | `chain`, `stamp`, `step`, `node`, `outcome` (`:requeued` or `:interrupted`) | A step was taken back from a node that stopped responding ([below](#several-nodes-and-the-backup-lock)). |

### Back up while another backup runs

**Back up now** stays enabled while a backup runs. Platform admins only, like
the rest of the page.

1. Open **Backups** (`/editor/backups`). While a backup runs, a strip below
   **Back up now** says which step it is on: "Starting a backup", "Dumping the
   database", "Planning the media archive", "Archiving media: part 2 of 5",
   "Checking the media parts", "Applying retention", "Copying off-site" or
   "Finishing", with the backup's stamp. ("part 2 of 5" shows the total only on
   a node that has the backup's directory.) The page refreshes every 3 seconds
   while a backup runs, for up to an hour.
2. Click **Back up now**. The page says "A backup is running; this one starts
   when it finishes." and the strip adds "1 queued (requested 2026-11-09 03:17
   UTC)".
3. Click it again. The page says "A backup is running and another is already
   queued; that queued backup covers this request." The strip adds "1 later
   request folded into it". At most one backup waits; every later request
   folds into it and is logged at `info`: "Backup request folded: a backup
   (manual) was asked for while one runs and another is queued; the queued
   backup covers it".
4. When the running backup ends (succeeded, failed or canceled), the queued
   one starts with a new stamp. Its log in History starts with "Started from
   the queue (requested at …); 1 later request(s) folded into it".

A **Resume** click queues and folds the same way. Resuming the backup that is
running right now is refused: "That backup is running right now." A queued
request cannot be removed; cancel it once it has started.

### Cancel a running backup

A platform admin can stop an in-app backup that is running. Its files are kept
so it can be resumed later.

1. Open **Backups** (`/editor/backups`) as a platform admin.
2. Click **Cancel**, on the in-flight strip or on the `Running` row in
   **History**. There is none until the backup's row appears in History, and
   the strip drops it once the backup is finishing.
3. Confirm "Cancel this backup? Its files are kept, so it can be resumed
   later." (with "A queued backup will start next." when one is waiting).
4. The page says "Backup canceled. Its files are kept, so it can be resumed."
   The row reads `Canceled`, its error "Canceled by a platform admin", and its
   log "Canceled by `<your email>`".

What Cancel does:

- It cancels the backup's step jobs. A step that is running is stopped, and
  the `pg_dump`, `tar` or `rclone` it started is killed.
- It releases the lock, so a queued backup starts next.
- It does **not** write `manifest.json`: the status panel keeps showing the
  last backup that finished.
- It keeps every file and `.work/<stamp>/`. **Resume** on the `Canceled` row
  continues from them. Retention does not delete a backup whose work directory
  still exists; the work directory is swept after three days, like any other.
- It records a **Backup canceled** event in the security log of the default
  site, with the backup's stamp and the step it was on
  ([security-events.md](security-events.md)).

What can go wrong:

| Message | Meaning |
|---|---|
| "Too late to cancel: the backup is finishing." | The backup has reached its `finish` step and is about to succeed. |
| "That backup already finished." | It ended between the page loading and the click. |
| "Only a platform admin can cancel a backup." | Your account is no longer a platform admin. |
| "That backup can't be canceled." | Anything else, for example a run that is not an in-app backup. |

### Several nodes and the backup lock

The lock is held by a step job on some node. If that node stops, its step must
not hold every later backup for ever, and two nodes must never write the same
backup's files at once. Three things keep both true.

**A heartbeat on every node.** Every 30 seconds each node writes a beat to
`backup_node_beats`, timed by the database's clock, never the node's. It also
looks at the lock:

- A step on a node with no beat for 180 seconds, or on a node that has
  restarted since it took the step, is taken back: its job is canceled and
  requeued with the attempts it had left, under the same stamp, so it reuses
  every file already finished. The server log says "Backup step `<step>` of
  `<stamp>` was on node `<node>`, which stopped responding: requeued (job
  `<id>`)". With no attempts left the backup fails as "Interrupted: node
  `<node>` stopped responding".
- A step whose job ended without handing over (its last attempt timed out
  after 2 hours, or the job was discarded or deleted) fails the backup as
  "Interrupted: the backup's step job ended without finishing its step", and
  the lock is released.
- A node that cannot write its beat for 90 seconds (it lost the database)
  stops its own backup steps before the others take them over.

The same checks run before every backup request, so a stopped node's backup
never makes a request queue behind it for good. The heartbeat is on by
default (`config :kiln_cms, KilnCMS.Backups, heartbeat?: true`). Leave it on:
it is off only in the test build. With it off, a stopped node's step is never
reclaimed and holds the lock until Oban's Lifeline rescues it (about 3 hours)
or a platform admin cancels it.

**Node names must be unique.** A beat is keyed by the Oban node name: the
Erlang node name when the release runs distributed (`kiln_cms@<hostname>` by
default), else `DYNO`, else the hostname. Two nodes with the same name (say,
replicas given one fixed `hostname:`) overwrite each other's beat, and a step
can be taken from a node that is still running it. The server log then reports
"Backup heartbeat: another node is beating as …".

**Each backup directory has an id.** `<BACKUP_DIR>/.kiln-dir-id` (mode 0600)
holds a random id, created the first time a node starts a backup there. Every
step after `start` runs only on a node that reads the same id:

- **One shared volume** mounted on every node: every node reads the same id,
  so any node runs any step.
- **A `BACKUP_DIR` per host**: the backup's steps stay on the host whose
  directory its `start` wrote to. Another node that picks up a step waits
  30 seconds and puts it back, up to 20 times (about 10 minutes) per attempt,
  then fails the attempt (`:backup_dir_elsewhere`), which uses one of the four.
  If that host is gone, the backup ends up failed; take a new one.
- **A copied backup directory** (restored onto a new host, or cloned) carries
  the old host's id. Delete `.kiln-dir-id` on the copy so it gets its own.

**Resume needs the host with the files.** The Resume button shows only on a
node that can see the backup's `.work/<stamp>/`, and the resume's `start` step
must run on such a node too. On a cluster with a `BACKUP_DIR` per host, a
resume whose `start` lands elsewhere is refused there (server log: "Backup
resume refused: :no_state") and the row keeps its status; click **Resume**
again.

**Pool size.** The `backup_steps` queue runs one job at a time on each node.
If you size `POOL_SIZE` as the sum of queue limits plus web traffic
([performance.md](performance.md)), add one.

**Cron is not locked.** `scripts/backup.sh` runs outside the application and
does not take the lock, so a cron backup and an in-app backup can run at the
same time. They write different stamps; schedule them apart to keep the load
down.

### Start a backup from a release console

`KilnCMS.Backups.request/2` is how every in-app backup starts: the page's
buttons call it as the signed-in platform admin, and a console calls it as the
backup system actor. Run it on a running node with `rpc`:

```bash
bin/kiln_cms rpc '{:ok, result} = KilnCMS.Backups.request([trigger: "console"], KilnCMS.Backups.system()); IO.inspect(result)'
# %{status: :started, chain: "5f0c7c1e-…"}
```

The match makes `rpc` fail loudly on a refusal rather than exit 0. The result
is one of:

| Result | Meaning |
|---|---|
| `{:ok, %{status: :started, chain: chain}}` | It is running. |
| `{:ok, %{status: :queued, chain: running}}` | Another backup is running; this one starts after it. `chain` is the running one. |
| `{:ok, %{status: :folded, chain: running}}` | One is already queued, and it covers this request. |
| `{:error, reason}` | `:disabled`, `:no_database_url`, `:no_pg_dump` or `:no_pg_restore`; for a resume, `:invalid_stamp`, `:in_flight`, `:no_such_run`, `{:not_resumable, status}` or `:no_state`; or `:forbidden` for an actor who may not ask. |

The trigger is cut to 64 characters, with credentials redacted, before it is
stored. Other calls:

- **Resume**: `KilnCMS.Backups.request([trigger: "console", resume: "20260805-031700"], KilnCMS.Backups.system())`.
- **What is running**: `KilnCMS.Backups.in_flight()` returns `nil`, or the
  chain, its stamp, trigger, step, part, `parts_total`, phase (`:running` or
  `:finishing`), `acquired_at` and the queued request
  (`%{trigger, resume, requested_at, folds}` or `nil`).
- **Wait for it**: `KilnCMS.Backups.await(chain)` returns `:ok` once that
  chain's backup succeeded, else `{:error, reason}`: the run's error,
  `:canceled`, `{:skipped, error}`, `:no_run` or `:timeout`. It polls the
  database (every 2 s, for up to 3 hours by default; `:interval` and
  `:timeout` in ms), so it works from any node. A timeout stops the wait, not
  the backup.

**Deprecated.** `KilnCMS.Backups.enqueue/1` is `request/2` as the system actor
and returns the same map (it returned the `Oban.Job` before #2218).
`KilnCMS.Backups.Worker.run/3` no longer runs a backup inline in the console:
it requests one and waits for it, returning `:ok` or `{:error, reason}`, and
`{:error, :queued}` or `{:error, :folded}` without waiting when another backup
is running. For an off-site failure the reason is the run's error text. Both,
the `backups` queue and `KilnCMS.Backups.Worker` are removed in the next minor
release.

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

**Interrupted? Resume it.** A failed, killed or canceled backup leaves its
finished work in `<BACKUP_DIR>/.work/<stamp>/`: the file lists and a
`state.json` recording each finished step and part with its hash. Every in-app
backup has this directory, a database-only one (S3 media adapter, or no media
directory) included. The directory is mode 0700, the files 0600, and it is
removed only when the backup and its off-site copy both succeed, so a run that
failed off-site can be resumed too. A directory older than three days is swept
automatically, and with it the chance to resume.

1. Open **Backups** (`/editor/backups`) as a platform admin and scroll to
   **History**.
2. On the `Failed` (or "Interrupted") or `Canceled` row, click **Resume**. The
   button shows only when the work files are still there. A succeeded, skipped
   or imported row, or a run that is still working, has none.
3. The page shows "Backup resumed — this page updates when it finishes." The
   same row goes back to `Running`, keeping its stamp and start time. If
   another backup is running, the resume
   [queues behind it](#back-up-while-another-backup-runs) instead.

A resume reuses a part only if its recorded SHA-256 still matches the file on
disk; anything else is rebuilt. The file list is the one frozen by the first
attempt. A resumed set can therefore mix times (some parts from the first
attempt, some from the resume), and the Run's log says which parts were reused.
Because finished parts are durable, a library too big to finish in one attempt
converges over repeated resumes. From a release console, pass `resume:` to
`KilnCMS.Backups.request/2` ([Start a backup from a release
console](#start-a-backup-from-a-release-console)). A stamp with no failed,
canceled or stale-running run, or whose work files are gone, is refused; a
resume never turns into a fresh backup. Re-running the whole backup remains
the fallback.

> **Operators who copy the backup directory with `rclone sync $BACKUP_DIR`:**
> exclude `.work/**`. It holds lists of media file names (and is removed on
> success), and has no value off-site.

**Disk space.** There is no free-space check. Budget for the database dump, plus
all finished media parts, plus one part being written, plus the file lists.

**Retention and off-site.** Retention deletes a media set whole (every part,
then the sidecar), aged by its newest file, so a sweep can never leave half a
set; the dump of the same stamp is aged on its own
([What retention deletes and what it keeps](#what-retention-deletes-and-what-it-keeps)).
Off-site copies the dump, each
part and each sidecar, one `rclone copy` per file, each after its own re-hash.
A failed copy, of a data file or of a sidecar, fails the run: a part set whose
sidecar never left the host is one `restore.sh` refuses to restore from the
remote. rclone's own retries come first (`--retries`, 3 by default, settable
with `RCLONE_RETRIES` in the environment of the app or the cron line). In the
app, a copy that still failed retries the whole off-site step, up to four
attempts 1, 5 and 15 minutes apart
([How an in-app backup runs](#how-an-in-app-backup-runs-2218)); rclone skips
the files the remote already holds unchanged. The run is marked failed only
after the last attempt. Cron does not retry.

The app prunes before its off-site copy, so expired backups are removed even
when the off-site copy then fails. Cron prunes only at the end of a run that
succeeded, off-site copy included. Neither touches the backup being taken: the
app's is in flight, and cron's is the newest complete one.

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
2. **App:** open **Backups** as a platform admin and
   click **Resume** on the failed History row (see [Interrupted? Resume
   it.](#media-backups-in-parts-2218)). Files that still match `state.json`
   are reused, and only a file that changed (or was replaced by a symlink or
   other non-regular file) is rebuilt. A rebuilt dump is a fresh `pg_dump`,
   taken at resume time. Every file is re-hashed and copied off-site again;
   rclone skips a file the remote already holds unchanged. The row goes back to
   `Running` and ends `Succeeded`, or `Failed` again and still resumable. A
   database-only backup (S3 media adapter, or no media directory) resumes the
   same way.
3. **Cron:** run `backup.sh all` again (or wait for the next run). Cron has no
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
   `Failed`, `Running`, `Skipped` or `Canceled`), **Database** and **Media** badges, the
   size, whether it was verified, its destinations, and whether its files are
   still on this host. A media set written in several parts shows "N parts".
   A failed, interrupted or canceled run shows **Resume**
   ([above](#media-backups-in-parts-2218)), and a running in-app one
   **Cancel** ([above](#cancel-a-running-backup)).
3. Use **Previous** / **Next** to page ("Page 1 of 3").

The files column reads:

| Shown | Meaning |
|-------|---------|
| `on disk` | Every file is under `BACKUP_DIR`. |
| `pruned (retention)` | The application's own retention removed them. |
| `partly pruned (retention)` | Some files are still here; every missing one was removed by the application's own retention (it ages a backup's dump and media separately). |
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
`manifest.json` alone. A backup whose node stopped is requeued or failed
("Interrupted") by the heartbeat within a few minutes
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)). A
`Running` row the lock no longer holds (a run from before the upgrade, or one
the heartbeat could not reach) reads `Failed` ("Interrupted") once it has been
quiet for 2h15m, measured from the later of its start and its last update.
Failing to write a row never fails the backup itself.

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

An in-app backup calls `pg_dump`/`pg_restore`, so the runtime image installs
`postgresql-client-17`. **Its major version must match the server** — `pg_dump`
refuses to run against a newer one — so bump the pin in the `Dockerfile`
alongside your Postgres upgrade.

Where they are absent, the page says so and the button is disabled rather than
failing at the point of use. Cron backups on the host are unaffected either
way.

**The official image ships `rclone`** (since #2482), a pinned release whose
SHA-256 the `Dockerfile` checks at build time; `rclone version` in the
container names it. The app runs as `nobody`, whose home directory does
not exist, so give it the remote's configuration explicitly: either
`RCLONE_CONFIG_<NAME>_*` variables in the app's environment (for
`BACKUP_RCLONE_REMOTE=r2:kiln-backups`: `RCLONE_CONFIG_R2_TYPE=s3`,
`RCLONE_CONFIG_R2_PROVIDER=Cloudflare`, `RCLONE_CONFIG_R2_ACCESS_KEY_ID`,
`RCLONE_CONFIG_R2_SECRET_ACCESS_KEY`, `RCLONE_CONFIG_R2_ENDPOINT`), or an
`rclone.conf` mounted read-only with `RCLONE_CONFIG` pointing at it. Avoid
a connection-string remote (`:s3,secret_access_key=…:bucket`) for the app:
it reaches `rclone` as a command-line argument, which other users and
process monitors on the host can read.
Bumping the pin is a `Dockerfile` change: the comment above the `rclone`
stage says how to take the new version's digest and check its signature.

**A remote with no `rclone` fails the run.** On a custom image that leaves
`rclone` out, with `BACKUP_RCLONE_REMOTE` set in the app's environment, an
in-app backup takes and verifies its local files, then fails at the
off-site step, like any other failed copy. Nothing is tried again within
the run, since no retry installs a binary. It is visible ahead of time and
afterward:

- **Where backups go** on `/editor/backups` shows an **Off-site** line with
  the remote (credentials masked) and "rclone is not installed in this
  image, so backups taken from this page fail at the off-site copy. Install
  rclone in the image or unset BACKUP_RCLONE_REMOTE."
- The run fails with:

  ```text
  Off-site copy FAILED: BACKUP_RCLONE_REMOTE is set but rclone is not
  installed in this image, so no file was copied. The local files are kept.
  Install rclone in the image (the official image ships it) or unset
  BACKUP_RCLONE_REMOTE, then Resume this backup.
  ```

  Its Run log has the error line "BACKUP_RCLONE_REMOTE is set but rclone is
  not installed in this image; nothing was copied off-site", and the server
  log has the same line with the remote, redacted.
- The failure manifest's `offsite` is `null`, and its files stay verified.

Fix it either way: install `rclone` in your image, or, when the host copies
`BACKUP_DIR` off-site by other means (`rclone sync` of `BACKUP_DIR`,
excluding `.work/**`, or a volume snapshot), unset `BACKUP_RCLONE_REMOTE` in
the app's environment. `backup.sh` copies only the files its own run wrote,
so a cron entry alone does not carry the app's backups off-site. A run that
failed this way can be resumed once the image has `rclone`.

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
| `BACKUP_KEEP_DAYS` | backup + app | local retention (default 14): the age at which a backup may be deleted ([keep rules](#what-retention-deletes-and-what-it-keeps)) |
| `BACKUP_ENABLED` | app | set false to disable the in-app path only; cron is unaffected (default true) |
| `BACKUP_STALE_AFTER_HOURS` | app | how old before the console warns (default 36) |
| `BACKUP_MEDIA_PART_MB` | backup + app | target ceiling on one media part's input size, 16 to 10240 (default 400) |
| `BACKUP_MEDIA_EXCLUDE` | backup + app | comma-separated globs the media archive leaves out (default none) |
| `TMPDIR` | backup | where `backup.sh` builds the media file lists (default `/tmp`); removed when it exits |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup + app | off-site rclone remote (strongly recommended). Each file is re-hashed before its copy; a refused or failed copy fails the run. The official image ships `rclone`; set without it, an in-app run fails ([above](#it-needs-the-client-tools-in-the-image)) |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill` |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
| `RESTORE_REQUIRE_CHECKSUM=1` | restore | `media`: abort when there is no checksum sidecar (default: warn and continue for a legacy single archive) |
| `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` | restore | `media`: restore a `.partNN` set that has no sidecar (default: refuse, since a set without one is most likely from a killed run) |
