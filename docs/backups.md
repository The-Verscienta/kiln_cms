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

The cadence above is host cron's. An in-app schedule, created from a release
console, can take the database and media backups instead
([Schedule backups in the app](#schedule-backups-in-the-app), part of #2219);
run one or the other on each component, not both, or each window takes two
backups.

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

Both paths read the value the same way: a whole number of days from 1 to
2147483647, with surrounding spaces, a leading `+` and leading zeros allowed.
Blank or unset means 14. Anything else (`0`, `-1`, `14d`, `1.5`) also means 14,
with a warning; `backup.sh all` and `backup.sh prune` write it to stderr:

```text
warning: BACKUP_KEEP_DAYS=14d is not a whole number of days from 1 to 2147483647; using 14
```

`0` is not "keep nothing" and `14d` is not 14: guessing either way would delete
backups or keep them forever. (Before #2727 the script used the value
unchecked.)

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

**Never deleted by retention:** symlinks, directories, `.work/`, and
recovery-point markers. `.partial` files are cleared by two narrower rules,
each of which lets History read the stamp first: the start of every in-app
backup removes those whose stamp has a History row once every file of that
stamp is more than an hour old, and `backup.sh prune` removes those of a run
killed outright once every file of that stamp is 12 hours old
([When a cron run is killed outright](#when-a-cron-run-is-killed-outright-2478)).
Last-good markers are never aged either; the app moves them itself
([below](#the-last-good-marker)). A `kiln-*` file in `db/` or `media/` that belongs to no
unit, such as a part named `part001` instead of `part01`, is a stray: the app
deletes it once it is older than `BACKUP_KEEP_DAYS`, and `backup.sh` leaves it
alone.

In History, a run whose dump retention removed while its media is still on disk
reads `partly pruned (retention)` ([Backup history](#backup-history-2217)).

### Keep a backup as a recovery point

Pin one backup, say the last one before a migration, so retention never deletes
it. You need a shell on the host, as the user that runs the backups. The Backups
page shows recovery points but cannot set or release one.

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
4. Open **Backups** (`/editor/backups`) as a platform admin. The backup's row
   in **History** now carries a **Recovery point** badge (one per row, whether
   the marker is in `db/` or `media/`). The page reads the marker from this
   server's `BACKUP_DIR` whenever it loads History, so reload the page if it
   was already open.

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
- **Every 15 minutes, from a scheduled job** (`KilnCMS.Backups.MarkerSyncWorker`,
  #2554), for the backups cron makes. It imports cron's backups into History,
  then moves the markers under the backup lock, so it never moves them at the
  same time as an in-app backup. While an in-app backup runs, the job writes
  nothing that slot: that backup moves the markers itself. The schedule is
  `KILN_BACKUP_MARKER_SYNC_CRON` (default `*/15 * * * *`; `false` turns it
  off). It runs in the app, so it needs the app to be running and to see
  `BACKUP_DIR`; on a node with no backup directory it does nothing and logs
  nothing. `BACKUP_ENABLED=false` does not stop it: that switch turns off the
  in-app backup path, and the marker exists for the cron path.
- **Never on a dry run, and never by `backup.sh`.** The script reads markers
  and writes none.

The new marker is written first, and the component's other `.good` markers are
removed only once it is there, so a cron prune that runs in between keeps both
units, never neither. The app itself does not read `.good` markers: it works out
the newest verified backup from History every time, so a stale marker pins
nothing in the app, and its unit ages there like any other.

**Turn it on.** Nothing to configure; you only need the new script on the host,
and the app able to see the backup directory.

1. Replace the host's copy of `scripts/backup.sh` (the one your cron line
   runs, `/opt/kiln_cms/scripts/backup.sh` in the cron line at the top of
   this guide) with this release's. An older copy
   ignores `.good` markers and can still delete the newest verified backup.
2. Check that the app sees the same `BACKUP_DIR` as cron (the same volume
   mounted at the path `BACKUP_DIR` names in the app's environment). A cron-only
   host whose app can't see the directory gets no marker.
3. Take an in-app backup, or wait for the scheduled job. With in-app backups
   the marker is there when the backup finishes. With cron only, it appears
   at the first scheduled run that can import the backup into History: any
   run once `manifest.json` names the backup's stamp (`backup.sh all` writes
   it), otherwise a run after the stamp's newest file is 10 minutes old (see
   *Cron's backups appear in History* below). With the default schedule,
   allow up to about 25 minutes after a cron backup finishes.
4. Open **Backups** (`/editor/backups`) as a platform admin. Under
   **History**, **Last-good marker (kept by backup.sh prune)** lists each
   component the deployment backs up (**Database**, and **Media** when media
   backups are configured) with the stamp its marker names, or "none yet". The
   backup's row in History carries a **Last good: Database** and/or **Last
   good: Media** badge. Or list the backup directories on the host; each
   component with a verified backup has one marker:

   ```bash
   ls /var/backups/kiln/db/ /var/backups/kiln/media/
   # /var/backups/kiln/db/:
   # kiln-20261107-031700.good  kiln-db-20261107-031700.dump  kiln-db-20261107-031700.sha256  …
   #
   # /var/backups/kiln/media/:
   # kiln-20261107-031700.good  kiln-media-20261107-031700.sha256  kiln-media-20261107-031700.tar.gz  …
   ```

With the job turned off, or an app that can't see the directory, a deployment
that backs up only with cron gets no marker, and its prune keeps only the
newest complete set, as before.

**Several nodes.** The job runs once per slot across the cluster, and reaches
each backup directory by its id, `.kiln-dir-id`
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)).
While the job is on, each node's heartbeat (every 30 seconds) gives its
`BACKUP_DIR` an id if it has none (#2789), but only once the directory holds
backups (it has a `db/` or `media/` subdirectory). An empty directory, such as
the one the image creates on every replica or the mountpoint of a mount that
failed, never gets one. Each slot then:

- **syncs the directory of the node that picked up the job**, in place, with
  or without an id. One shared volume, where every node reads the same id, is
  covered every slot this way.
- **queues one sync for every other directory** whose id a node reported in
  the last 10 minutes (judged on the database's clock, so a node whose clock
  runs ahead still counts). That sync waits for a node that reads the id,
  putting itself back every 30 seconds up to 20 times (about 10 minutes). If
  none picks it up, the server log says "Backup last-good marker sync for
  backup directory `<id>` gave up: no node with that directory picked it up",
  and the next slot tries again.

So with a `BACKUP_DIR` per host, each host's directory is synced in a slot
as long as its node picks up one of the about 21 releases of its queued sync
in those 10 minutes, the same assumption every backup step makes. A host whose
node is down is left out until its heartbeat is back.

Two things stop a directory getting an id, and leave it synced only in the
slots its own node happens to pick up the job:

- **The app can't write `BACKUP_DIR`.** The server log says, once per boot for each error,
  "Backup heartbeat: no id for the backup directory `<dir>` (`<reason>`). The
  last-good marker sync can't route to it, so it is synced only in the slots
  this node runs the sync job." Give the app's user write access to the
  directory (run cron and the app as the same user).
- **The job is off** (`KILN_BACKUP_MARKER_SYNC_CRON=false`). The heartbeat
  then creates no id; only an in-app backup does.

**A cloned directory now always carries an id.** Copying a backup directory to
another host (`rsync`, a volume snapshot) copies its `.kiln-dir-id`, and two
directories with one id look like one: the sync for that id is queued once and
reaches whichever of the two picks it up. Leave the file out of the copy
(`rsync --exclude .kiln-dir-id`) or delete it on the copy, and the copy's node
gives it its own.

Things to know:

- **Don't delete a `.good` by hand while the app keeps it in step.** The app
  writes it again at the next backup or scheduled run anyway, and until then
  cron can delete the backup it named.
- **If you turn the job off and stop taking in-app backups**, the last marker
  of each component stays, and cron keeps that unit past `BACKUP_KEEP_DAYS`
  indefinitely. Delete the marker by hand when you want cron to age that
  backup. While the job runs, the marker moves to each newer verified backup
  on its own.
- **A marker the app cannot remove** (a directory or symlink of that name, or a
  file it has no permission to delete) pins its unit for cron indefinitely.
  The app leaves it, logs a warning, and emits the telemetry event below.
  Remove it by hand.
- **Rolling back to a release before 1.9.0.** Its in-app prune ignores
  `.good` markers and deletes each one as a stray once the marker file is older
  than `BACKUP_KEEP_DAYS`; harmless. If the host's `backup.sh` stays at this
  release, cron keeps honoring the markers that remain until then.
- **Rolling back to 1.9.x** stops the scheduled sync (those releases write the
  marker only from in-app backups and prunes). On a cron-only deployment the
  markers it wrote stay where they are, so cron keeps those two units past
  `BACKUP_KEEP_DAYS` until you delete the markers by hand.

**Watch it.** Each scheduled run that gets through (markers written, moved,
already right, or none to write because no backup is verified yet) emits
`[:kiln_cms, :backups, :last_good, :synced]` with measurements `%{count: 1}`
and metadata `%{dir: dir, db: stamp | nil, media: stamp | nil}`: the newest
verified stamp of each component, or `nil` for one with none (its marker, if
any, is left alone). A run skipped because an
in-app backup holds the lock emits nothing. On a cron-only deployment, an
alert on this event going quiet for an hour tells you the markers have stopped
moving.

**When a marker can't be moved.** The backup, prune or scheduled run still
succeeds or fails on its own terms; the marker is housekeeping, and the next
scheduled run tries again. Each of these logs a warning, and the first four
emit `[:kiln_cms, :backups, :last_good, :failed]` with measurements
`%{count: 1}`:

| Server log | Telemetry metadata | Meaning |
|---|---|---|
| `Backup last-good marker not updated: <reason>` | `%{reason: reason}` | After an in-app backup, before an in-app prune, or in a scheduled run: importing cron's backups, listing `db/`, `media/` or `.work/`, reading a file in them, or reading History failed. From a scheduled run it also covers the wait for the backup lock or one of its queries failing (`it crashed (…)`). No marker was written or removed. The reasons read as in [When retention is skipped or stops](#when-retention-is-skipped-or-stops). |
| `Backup last-good marker db/kiln-<stamp>.good couldn't be written (<reason>); the previous marker stays` | `%{kind: :db, stamp: stamp, reason: posix}` | The new marker could not be created, so the old one was left pinning the previous backup. A `reason` of `:eacces` is a permission problem on that directory. |
| `Couldn't remove old last-good marker db/kiln-<stamp>.good (<reason>)` | `%{marker: "db/kiln-<stamp>.good", reason: {:remove, posix}}` | The new marker is in place, but an old one could not be deleted. Cron keeps both units. |
| `Left db/kiln-<stamp>.good in place: a directory, not a regular file` | `%{marker: "db/kiln-<stamp>.good", reason: {:not_regular, type}}` | Something other than a regular file has an old marker's name. The app removes only regular files. |
| `Couldn't list db/ to remove old last-good markers (<reason>)` | none | The new marker is in place; old ones stay until the next sync. |
| `Backup last-good marker sync skipped: couldn't read the node heartbeats (<message>)` | none | A scheduled run couldn't tell which nodes report a directory id, so it synced nothing. |
| `Couldn't queue the last-good marker sync for backup directory <id> (<reason>)` | none | A scheduled run couldn't queue the sync for that directory; the next slot tries again. |
| `Backup last-good marker sync for backup directory <id> gave up: no node with that directory picked it up` | none | No running node reads that directory id; see **Several nodes** above. A node that has just stopped can cause it: its id counts until its last heartbeat is 10 minutes old. |

### What the cron prune cannot see

`backup.sh` has no database, so it sees two of the rules above only partly:

- **It knows the newest verified backup only through the last-good marker.**
  It keeps the unit the app marked with `kiln-<stamp>.good`, so when the newest
  complete set on disk came from a run that failed (for example its off-site
  copy was refused), cron keeps both that set and the older verified one. This
  holds only while the app keeps the marker in step: a host whose copy of
  `backup.sh` predates the marker, an app that can't see the backup directory
  or has the scheduled sync turned off (and takes no in-app backups), a backup
  the app has not yet imported, and a marker deleted by hand all leave cron
  keeping the
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

The console has a **Backups** page (`/editor/backups`, platform admins only:
a backup covers every site on the deployment, so a site admin cannot open it)
showing when
the database and the media were last backed up, how big the last backup was,
which files it produced and whether each verified — plus a **Back up now**
button. For platform admins, the overview grid grows a red strip when either
component's last good backup is older than `BACKUP_STALE_AFTER_HOURS`
(default 36, or the threshold an
[in-app schedule](#how-a-schedule-sets-the-alarm-threshold) sets), when its
last attempt failed, or when one has been backed up and
the other never has; a neutral "Backups aren't set up yet" strip when neither
ever has ([Check the last backup of each component](#check-the-last-backup-of-each-component)).

### It reports on cron's backups too

The panel reads `$BACKUP_DIR/manifest.json`, and **`backup.sh all` writes it**.
That is the whole design: cron remains the canonical path, and a panel that
only knew about app-triggered runs would show "never" on precisely the
deployments that are backing up correctly.

A failed run overwrites the manifest with `"ok": false` and the error, rather
than leaving the last successful one on screen — "is my data safe right now"
is the question the page is being asked, and the previous backup does not
answer it.

### Check the last backup of each component

A backup can cover only the database or only the media
([Back up only the database or only the media](#back-up-only-the-database-or-only-the-media)),
so the manifest, which describes the last backup, can't say how each is doing
on its own: a database-only backup would hide the media's state. The status is
therefore worked out per component, from History and the manifest together.
Platform admins only, like the rest of the page.

1. Open **Backups** (`/editor/backups`). The status panel has one line per
   component this deployment backs up: **Database**, and **Media** when there
   is a media directory (`MEDIA_DIR`).
2. Each line names the component and reads one of (for example "Database:
   Backed up 3 hours ago"):
   - "Backed up 3 hours ago": its last good backup is newer than
     `BACKUP_STALE_AFTER_HOURS`, or than the threshold an in-app schedule
     sets for it
     ([How a schedule sets the alarm threshold](#how-a-schedule-sets-the-alarm-threshold)).
     The **Schedules** section shows each component's threshold and where it
     came from.
   - "Last backup was 2 days ago": its last good backup is older than that.
   - "The last backup failed": the newest attempt that covered it failed.
   - "No backup has ever been recorded": neither History nor the manifest has
     one.
3. The panel's border and icon turn to the alarm when any line is failed or
   stale: a fresh database backup does not make stale media fine. The file
   list and the **Last run failed** box below still describe the manifest,
   the last backup, whatever it covered.

The **Overview** page says the same for platform admins: a red strip with one
line per component that needs attention ("The last media backup was 3 days
ago.", "The last database backup failed.", "No media backup has been
recorded."). Media that has never been backed up while the database has is the
red strip, not the neutral set-up notice, which shows only when neither
component has ever been backed up or tried.

**Where each answer comes from.** For each component:

- **Last good** is the newest `Succeeded` run that covered it and still has a
  verified file of that kind (not pruned), or the manifest when it is newer and
  was a successful backup with a verified file of that kind. A backup imported
  from cron counts only when the manifest it came with marks its files
  verified.
- **Last attempt** is the newest `Succeeded` or `Failed` run that covered it,
  or the manifest, whichever is newer. `Skipped` and `Canceled` runs don't
  count.
- **Failing closed.** A failed run that doesn't say what it covered counts
  against every component: a failed imported (cron) run, whose components are
  only the kinds of the files it left, and a failed run that names none. So
  does a failed manifest without a `"components"` key.

**When History can't be read** (a database error, a revoked grant), the status
comes from the manifest alone, as it did before #2219, rather than failing the
page or calling anything healthy. Each time, Kiln emits
`[:kiln_cms, :backups, :status, :history_unreadable]` (measurements
`%{count: 1}`, metadata `error`, the error's module); the warning "Backup
status from the manifest alone: the run history could not be read" is logged
at most once every 15 minutes, since the page asks every few seconds while a
backup runs.

**The manifest's `"components"`.** An in-app backup writes what it covered as
an additive `"components"` key in `manifest.json` (`["db"]`, `["media"]` or
`["db", "media"]`), on success and on failure; the manifest `version` stays 1.
`scripts/backup.sh` does not write it, and a manifest without it (cron's, or
one from an earlier release) covers the kinds of the files it lists.

**The manifest's `"stamp"`.** Both backup paths write the run's stamp
(`"20260805-031700"`, the one its file names and its History row carry) as an
additive `"stamp"` key; the `version` stays 1. The importer keys a failed
manifest that names no files by it. The stamp can't be recomputed from
`"started_at"`: the app takes the stamp when the backup is queued and records
the start a moment later, so the two can name different seconds. A manifest
without the key (one from an earlier release) is keyed by its `"started_at"`,
as before.

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

### Which database URL the backup tools accept (#2719)

`pg_dump`, `pg_restore` and `psql` read a connection string as a URL only
when it starts with `postgres://` or `postgresql://`. Kiln documents
`DATABASE_URL` as `ecto://…`, so every Kiln path that hands a URL to them
rewrites a leading `ecto://` (in any case) to `postgres://` first, and changes
nothing else in the string:

| Path | Reads |
|---|---|
| In-app backup | `BACKUP_DATABASE_URL`, else `DATABASE_URL` when it names the database the app is connected to, else a URL rebuilt from the Repo |
| [Demo reset](demo-mode.md) | the same URL as the in-app backup |
| `scripts/backup.sh` | `DATABASE_URL` |
| `scripts/restore.sh` | `RESTORE_DATABASE_URL` |
| `scripts/staging.sh` | `PROD_DATABASE_URL`, `STAGING_DATABASE_URL` |

So `ecto://`, `postgres://` and `postgresql://` all work, and the query
string (`?sslmode=require`, several hosts, an IPv6 `[::1]`) reaches libpq as
you wrote it.

**Ecto-only query parameters are not translated.** libpq refuses any
parameter it doesn't know, by name:

```text
pg_dump: error: invalid URI query parameter: "pool_size"
```

`ssl=true` is the exception: libpq reads it itself, as `sslmode=require`,
while `ssl=false` is refused like `pool_size`. When the app's `DATABASE_URL`
carries such a parameter, set `BACKUP_DATABASE_URL` to the same connection
without it for the in-app backup, and give `backup.sh` a `DATABASE_URL` in
libpq's form:

```bash
BACKUP_DATABASE_URL=postgres://kiln:…@postgres/kiln_prod?sslmode=require
```

A `key=value` connection string (`host=postgres dbname=kiln_prod`) is passed
through as written; see the next section for why a URL is better.

### The database password stays out of the pg_dump command line (#2726)

A process's arguments are readable by every user on the host, through
`/proc/<pid>/cmdline` and `ps`, for as long as it runs. So neither the app nor
the scripts put the database password there. Each takes it out of the URL and
gives it to the one `pg_dump`, `pg_restore` or `psql` that needs it as
`PGPASSWORD` (the scripts set it in a subshell around that command, so
`rclone`, `tar` and `curl` never see it):

| URL | the command's argument | its `PGPASSWORD` |
|---|---|---|
| `ecto://kiln:hunter2@postgres/kiln_prod` | `postgres://kiln@postgres/kiln_prod` | `hunter2` |
| `postgres://kiln:p%40ss@db/kiln?sslmode=require` | `postgres://kiln@db/kiln?sslmode=require` | `p@ss` |
| `postgres://kiln@db/kiln?sslmode=require&password=hunter2` | `postgres://kiln@db/kiln?sslmode=require` | `hunter2` |
| `postgres://kiln:a@db/kiln?password=b` | `postgres://kiln@db/kiln` | `b` |
| `postgres://kiln@db/kiln` | `postgres://kiln@db/kiln` | not set: yours, or `~/.pgpass`, applies |
| `host=db password=hunter2 dbname=kiln` | as written, password included | not set |

The URL is split where libpq splits it:

- **The user and password end at the first `@` before the first `/`.** Write an
  `@` in the password as `%40`: `postgres://u:p@ss@h/db` gives the password
  `p`. A `?` or `#` before that `@` is part of the password.
- **Percent-escapes in the password are decoded** (`%40` is `@`, `%25` is `%`);
  `+` stays a `+`, and a malformed escape such as `%zz` stays as written.
- **A `password=` query parameter is moved too**, also when its name is
  escaped (`pass%77ord=`). With a password in both places, the query one
  wins, as in libpq.
- **A URL without a password** (or with an empty one, `kiln:@db`) is left as
  written, apart from `ecto://`, so your own `PGPASSWORD` or `~/.pgpass`
  decides.
- **A `key=value` string is not a URL** and is passed as it is, password
  included. Use a URL.

The scripts don't print it either. `restore.sh drill` suggests a
`STAGING_DATABASE_URL=… ./scripts/staging.sh scrub` line with the password
removed, and `staging.sh up` prints the staging `DATABASE_URL=` the same way;
both say "password not shown". Put the password back in the URL, or export
`PGPASSWORD`, before using them.

### How an in-app backup runs (#2218)

An in-app backup is a chain of Oban jobs, one per step, on the `backup_steps`
queue:

**start** → **dump** → **plan** → **archive** (one job per media part) →
**checksum** → **prune** → **offsite** → **finish**

`dump` runs only when the backup covers the database, and `plan`, `archive` and
`checksum` only when it covers the media and there is a media directory; a step
with nothing to do hands straight over to the next one that has
([Back up only the database or only the media](#back-up-only-the-database-or-only-the-media)).
Each step reads what the previous ones did from `.work/<stamp>/state.json`, does its
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
| `[:kiln_cms, :backups, :request, :folded]` | `trigger`, `resume`, `components` (the folding request's; `nil` for everything or a resume) | A request folded into the queued one. |
| `[:kiln_cms, :backups, :lock, :reclaimed]` | `chain`, `stamp`, `step`, `node`, `outcome` (`:requeued` or `:interrupted`) | A step was taken back from a node that stopped responding ([below](#several-nodes-and-the-backup-lock)). |
| `[:kiln_cms, :backups, :status, :history_unreadable]` | `error` (the error's module) | The status could not read History and fell back to the manifest ([above](#check-the-last-backup-of-each-component)). |

The in-app schedules emit their own events,
`[:kiln_cms, :backups, :schedule, …]` and
`[:kiln_cms, :backups, :status, :schedules_unreadable]`
([The scheduler job](#the-scheduler-job)).

### Back up while another backup runs

**Back up now** stays enabled while a backup runs. Platform admins only, like
the rest of the page. The help under the button sums up the rules below: "A
backup asked for while another runs waits for it; only one waits. A request of
a different kind, or a resume of a different backup, is refused until the
queue clears."

1. Open **Backups** (`/editor/backups`). While a backup runs, a strip below
   **Back up now** says which step it is on: "Starting a backup", "Dumping the
   database", "Planning the media archive", "Archiving media: part 2 of 5",
   "Checking the media parts", "Applying retention", "Copying off-site" or
   "Finishing", with the backup's stamp. ("part 2 of 5" shows the total only on
   a node that has the backup's directory.) The page refreshes every 3 seconds
   while a backup runs, for up to an hour.
2. Click **Back up now**. The page says "A backup is running; this one starts
   when it finishes." and the strip adds "1 queued (requested 2026-11-09 03:17
   UTC) · Database + Media", ending with what the queued backup covers (a
   queued resume doesn't say).
3. Click it again. The page says "A backup is running and another is already
   queued; that queued backup covers this request." The strip adds "1 later
   request folded into it". At most one backup waits; every later request of
   the same kind folds into it and is logged at `info`: "Backup request
   folded: a backup (manual) was asked for while one runs and another is
   queued; the queued backup covers it".
4. When the running backup ends (succeeded, failed or canceled), the queued
   one starts with a new stamp. Its log in History starts with "Started from
   the queue (requested at …); 1 later request(s) folded into it".

A **Resume** click queues the same way. Resuming the backup that is running
right now is refused: "That backup is running right now." A queued request
cannot be removed; cancel it once it has started.

**Only like folds into like (#2540).** A request folds into the queued one
only when the queued one does the same work:

| You click | A fresh backup is queued | A resume of the same backup is queued | A resume of another backup is queued |
|---|---|---|---|
| **Back up now** | Folds | Refused | Refused |
| **Resume** | Refused | Folds: "A backup is running and a resume of this backup is already queued; that queued resume covers this request." | Refused |

A refused request changes nothing: no backup is queued, no run appears in
History and the fold count stays the same. The page says what is queued, for
example "A backup is running and a resume of 20261101-101010 is queued after
it, so this backup was not queued. Try again once the queue clears." Click
again once the queued backup has started (the strip no longer shows "1
queued").

Folding them would lose work: a resume finishes the old backup's stamp, so a
fresh backup folded into it would never be taken, and a resume folded into a
fresh backup would never resume. In-app schedules (part of #2219) get the same
answer: a scheduled backup is never folded into a queued Resume. Its window
stays due and is asked for again every minute until the queue clears
([When a schedule fires](#when-a-schedule-fires)).

**What the queued backup covers after a fold.** A request that folds into a
queued backup never leaves it covering less than either asked for:

| Queued | Folding in | The queued backup then covers |
|---|---|---|
| A fresh backup of some components | A fresh backup | Both requests' components (database-only and media-only make both) |
| A resume | A resume of the same backup | The queued resume's run's components (unchanged) |

Every other pairing is refused ([above](#back-up-while-another-backup-runs)),
so a resume never widens a queued fresh backup and a fresh backup never folds
into a resume, even one whose run covers the components it asks for.

### Cancel a running backup

A platform admin can stop an in-app backup that is running. Its files are kept
so it can be resumed later.

1. Open **Backups** (`/editor/backups`) as a platform admin.
2. Click **Cancel**, on the in-flight strip or on the `Running` row in
   **History**. There is none until the backup's row appears in History, and
   both the strip and the row drop it once the backup is finishing.
3. Confirm "Cancel this backup? Its files are kept, so it can be resumed
   later." (with "A queued backup will start next." when one is waiting).
4. The page says "Backup canceled. Its files are kept, so it can be resumed."
   The row reads `Canceled`, its error "Canceled by a platform admin", and its
   log "Canceled by `<your email>`".

What Cancel does:

- It cancels the backup's step jobs. A step that is running is stopped, and
  the `pg_dump`, `tar` or `rclone` it started is killed. The signal reaches
  the step's node through the database; a node that has lost the database
  stops the step itself instead (see
  [Several nodes and the backup lock](#several-nodes-and-the-backup-lock)).
- It releases the lock, so a queued backup starts next.
- It does **not** write `manifest.json`: the status panel keeps showing the
  last backup that finished.
- It keeps every file and `.work/<stamp>/`. **Resume** on the `Canceled` row
  continues from them, after a short wait (below). Retention does not delete a
  backup whose work directory still exists; the work directory is swept after
  three days, like any other.
- It records a **Backup canceled** event in the instance security log, which
  only platform admins can read (not in any site's log, #2541), with the
  backup's stamp and the step it was on
  ([security-events.md](security-events.md#the-instance-log)).

What can go wrong:

| Message | Meaning |
|---|---|
| "Too late to cancel: the backup is finishing." | The backup has reached its `finish` step and is about to succeed. |
| "That backup already finished." | It ended between the page loading and the click. |
| "Only a platform admin can cancel a backup." | Your account is no longer a platform admin. |
| "That backup can't be canceled." | Anything else, for example a run that is not an in-app backup. |

**Resume waits about two and a half minutes after a Cancel (#2538).** A node
that lost the database misses the Cancel, and stops its step only once its
heartbeat has failed for 90 seconds. A resume that started sooner could write
the same files as that step. So for 150 seconds after the Cancel (counted from
the time the row was canceled), **Resume** on that row is refused with "That
backup was canceled moments ago. Resume it again in N seconds: a step on a
server that lost contact with the database may still be stopping." The button
stays; click it again when the time is up. The `Canceled` row's tooltip says
to wait about two and a half minutes.

- A resume that starts inside the window without a click (one queued
  earlier, or a start step Oban retries) waits inside its step instead, at
  most 180 seconds, and the run's log says "Waited N s after the Cancel
  before resuming".
- From a console, `KilnCMS.Backups.request/2` returns
  `{:error, {:canceled_recently, seconds}}`. A legacy `KilnCMS.Backups.Worker`
  job waits that many seconds and asks again.

The window is typically enough, not a guarantee. A heartbeat that hangs on a
half-open database connection waits out the database timeouts first, and so
stops its step later. The backup's `state.json` and its History row are
protected from such a step either way; only its temporary `.partial` files
depend on the window ([below](#what-a-step-that-outlives-its-cancel-can-write)).

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
- A node that missed a Cancel or a take-back while it couldn't reach the
  database (it got the connection back before the 90 seconds were up, say)
  stops that step after its next successful beat: it looks up the job of each
  backup step it runs, and stops the step whose job is `cancelled`,
  `completed` or `discarded`. The server log says "Backup heartbeat: stopping
  N backup step(s) whose job was canceled or has ended, a signal this node
  missed while it couldn't reach the database". A job row that is missing
  stops nothing: a failover to a lagging standby, or a database restore, can
  lose the row of a step that is legitimately running. That step is left to
  the 90-second self-fence and the lock.

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
holds a random id, created the first time a node starts a backup there, or
earlier by the node's heartbeat when the
[last-good marker sync](#the-last-good-marker) is on and the directory already
holds backups. It is written to a temporary file, synced, and hard-linked into
place, so no node ever reads an empty or half-written id, and two nodes racing
on a shared volume settle on the first one linked. (On a filesystem without
hard links it is created in place with an exclusive create instead.) Every
step after `start` runs only on a node that reads the same id:

- **One shared volume** mounted on every node: every node reads the same id,
  so any node runs any step.
- **A `BACKUP_DIR` per host**: the backup's steps stay on the host whose
  directory its `start` wrote to. Another node that picks up a step waits
  30 seconds and puts it back, up to 20 times (about 10 minutes) per attempt,
  then fails the attempt (`:backup_dir_elsewhere`), which uses one of the four.
  If that host is gone, the backup ends up failed; take a new one.
- **A copied backup directory** (restored onto a new host, or cloned) carries
  the old host's id. Delete `.kiln-dir-id` on the copy, or leave it out of the
  copy (`rsync --exclude .kiln-dir-id`), so it gets its own. A
  resume follows the files, not the id, so a backup whose `.work/<stamp>/`
  came along with the copy can still be resumed there.

**A resume runs on the host with the files (#2539).** The Resume button shows
only on a node that can see the backup's `.work/<stamp>/`. Each run records
the id of the directory its files are in (its `dir_id`, set when it starts and
again each time it is resumed), and the resume's `start` step runs only on a
node that either:

- has `.work/<stamp>/state.json` in its own backup directory, or
- reads the run's recorded id in its `.kiln-dir-id`.

The local files win, so a directory that was copied, or given a new
`.kiln-dir-id`, still resumes where its files are. A run with no recorded id
(imported from cron, or last run before this release) is resumed by whichever
node picks it up, and records an id when it does.

Any other node that picks up the start waits 30 seconds and puts it back, up
to 20 times per attempt, like every other step, across the job's four attempts
and the 1-, 5- and 15-minute pauses between them. When the last attempt has
waited too, the resume is given up:

- the lock is released, and a queued backup starts;
- the History row keeps its status and its **Resume** button, and reads
  "Resume refused: no server with its backup directory (id `<id>`) picked it
  up; every attempt waited about 10 minutes for one", above its original
  error.

That is about an hour in which the resume holds the lock, and a backup asked
for meanwhile [queues behind it](#back-up-while-another-backup-runs): the price of not refusing a resume just
because the wrong nodes happened to pick it up first. Nothing on the page can
cancel it while it waits, because **Cancel** appears only once the row is
`Running` again. Bring the host with the files back, or wait for the give-up.

**Pool size.** The `backup_steps` queue runs one job at a time on each node.
If you size `POOL_SIZE` as the sum of queue limits plus web traffic
([performance.md](performance.md)), add one.

**Cron is not locked.** `scripts/backup.sh` runs outside the application and
does not take the lock, so a cron backup and an in-app backup can run at the
same time. They write different stamps; schedule them apart to keep the load
down.

### What a step that outlives its Cancel can write

A step on a node that missed its Cancel or its take-back keeps running until
its node stops it ([above](#several-nodes-and-the-backup-lock)). Until then:

- **`state.json`**: it can't overwrite it. Each step writes it under the
  cluster-wide backup lock, and only while its job still holds the lock, so a
  step whose chain was canceled or taken back stops there and writes nothing
  else.
- **The History row**: it can't write it. A step's progress, success and
  failure land only on a `Running` run that is still on that step's chain,
  so it can't overwrite a Cancel or the progress of a resume of the same run.
- **Its own temporary files** (`kiln-db-<stamp>.dump.partial`, a media part's
  `.partial`): these are not fenced. A resume of the same backup could share
  them, and only the wait after a Cancel
  ([above](#cancel-a-running-backup)) keeps the two apart.

Because the `state.json` write holds the backup lock, a backup directory that
stalls (a hung NFS mount) makes Cancel, new backup requests and the
heartbeat's sweep wait behind it until their database query times out.

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
| `{:ok, %{status: :folded, chain: running}}` | One of the same kind is already queued (a fresh backup, or a resume of the same stamp), and it covers this request. |
| `{:error, {:queue_busy, queued}}` | One of another kind is queued (`queued` is `:backup` or `{:resume, stamp}`). Nothing changed; ask again once it has started ([above](#back-up-while-another-backup-runs)). |
| `{:error, reason}` | `:disabled`, `:no_database_url`, `:no_pg_dump` or `:no_pg_restore`; for a resume, `:invalid_stamp`, `:in_flight`, `:no_such_run`, `{:not_resumable, status}`, `{:canceled_recently, seconds}` (canceled less than 150 seconds ago, [above](#cancel-a-running-backup); `seconds` is what is left) or `:no_state`; for `:components`, `:invalid_components`, `:components_with_resume` or `:no_media_dir` ([below](#back-up-only-the-database-or-only-the-media)); or `:forbidden` for an actor who may not ask. |

The trigger is cut to 64 characters, with credentials redacted, before it is
stored. Other calls:

- **Resume**: `KilnCMS.Backups.request([trigger: "console", resume: "20260805-031700"], KilnCMS.Backups.system())`.
- **Only some components**: `KilnCMS.Backups.request([trigger: "console", components: [:db]], KilnCMS.Backups.system())`
  ([below](#back-up-only-the-database-or-only-the-media)).
- **What is running**: `KilnCMS.Backups.in_flight()` returns `nil`, or the
  chain, its stamp, trigger, step, part, `parts_total`, `components` (what the
  running backup covers, as `[:db]`, `[:media]` or `[:db, :media]`; `nil` on a
  node without the backup's directory, and until its start step has run),
  phase (`:running` or `:finishing`), `acquired_at` and the queued request
  (`%{trigger, resume, components, requested_at, folds}`, where `components`
  `nil` means everything, or `nil`).
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
is running (`{:error, {:queue_busy, queued}}` when one of another kind is
queued). For an off-site failure the reason is the run's error text. Both,
the `backups` queue and `KilnCMS.Backups.Worker` are removed in the next minor
release.

### Back up only the database or only the media

A backup can cover just the database or just the media: a database dump before
a risky migration, say, without archiving a large media library again. From a
release console only; **Back up now** on the Backups page always backs up
everything the deployment has (**Resume** continues a run with the components
it had). You need a running node and the backup
system actor (or a platform admin as the actor).

1. Ask for the components on a running node:

   ```bash
   bin/kiln_cms rpc '{:ok, result} = KilnCMS.Backups.request([trigger: "console", components: [:db]], KilnCMS.Backups.system()); IO.inspect(result)'
   # %{status: :started, chain: "5f0c7c1e-…"}
   ```

   `components:` takes `[:db]`, `[:media]` or `[:db, :media]` (the names as
   strings work too). Leaving it out, or `nil`, backs up everything, as before.
2. Open **Backups** (`/editor/backups`). The in-flight strip shows the backup
   as usual. Its log in **History** starts with "Backup started (console)"
   and then "Backing up only: db" (the line is there only when the backup
   leaves something out), and the row shows only the **Database** badge.
3. When it has finished, the **Database** line of the status panel says
   "Backed up less than a minute ago"; the **Media** line still reports the
   last backup that covered the media
   ([Check the last backup of each component](#check-the-last-backup-of-each-component)).

What a partial backup does differently:

- `dump` is skipped when the backup leaves out the database, and `plan`,
  `archive` and `checksum` when it leaves out the media; the rest of the chain
  (prune, off-site copy, finish) runs as usual.
- The run records its components (`Backups.Run.components`), and the manifest
  records them as `"components"`. Retention and the
  [last-good marker](#the-last-good-marker) treat the database and the media
  of each backup separately already, so a database-only backup never stands in
  for the media.
- **Resume** continues a run with the components it had: a resumed
  database-only run backs up only the database. A resume of a media-only run
  whose start step lands on a node without a media directory is refused there
  (server log: "Backup resume refused: :no_media_dir"), and its History row
  reads "Resume refused: it backs up only media, and the server that picked it
  up has no media directory".
- A request queued behind a running backup keeps its components, and a fresh
  request folding into it widens them
  ([What the queued backup covers after a fold](#back-up-while-another-backup-runs)).

What can go wrong:

| Result | Meaning |
|---|---|
| `{:error, :invalid_components}` | `components:` is empty, not a list, names something other than `:db` or `:media`, or names one twice. |
| `{:error, :components_with_resume}` | `components:` together with `resume:`. A resume backs up what its run did; leave `components:` out. |
| `{:error, :no_media_dir}` | `components:` names `:media`, and this deployment has no media directory (S3 media, or no `MEDIA_DIR`). |
| `{:error, {:queue_busy, {:resume, stamp}}}` | A resume is queued behind the running backup. A fresh backup never folds into it; nothing was queued. Ask again once it starts. |
| A `Skipped` row, "Refused: no_media_dir" | The media directory was gone by the time a media-only backup started. The manifest is left alone. |

**During a rolling deploy.** The migration adds the columns before any node
runs this release, and an older node never reads them, so mixing releases is
safe, but a partial request can turn into a full one:

- a start job that a node from an older release picks up ignores
  `components` and backs up everything;
- a request that an older node queued, or folded into the queued one, covers
  everything, whatever was asked before; this release detects such a request
  by the scope fields that older nodes don't write;
- a resume an older node queued covers everything, so any fresh request folds
  into it.

Nothing is backed up less than asked for. Once every node runs this release,
partial requests are kept as asked.

### Schedule backups in the app

An in-app schedule takes backups from inside the application, as an
alternative to the host's cron job (part of #2219). It runs the same backup as
**Back up now**, through the same lock and queue, and writes the same files.
In this release a schedule is **created, changed and deleted from a release
console only**; the **Backups** page lists the schedules read-only. Only a
platform admin may manage them: the actor must be an account whose effective
platform role is admin.

**Before you start:** a running release with the `add_backup_schedules`
migration applied, in-app backups working on at least one node (**Back up
now** succeeds), and the email address of a platform admin account.

1. Create the schedule on a running node with `rpc`. This one backs up the
   database every day at 03:00 Paris time, starting today:

   ```bash
   bin/kiln_cms rpc '
   admin = KilnCMS.Accounts.get_user_by_email!("you@example.com", authorize?: false)

   {:ok, s} =
     KilnCMS.Backups.create_backup_schedule(
       %{components: [:db], interval: :daily, time_of_day: ~T[03:00:00],
         starts_on: Date.utc_today(), time_zone: "Europe/Paris"},
       actor: admin
     )

   IO.inspect(Map.take(s, [:id, :interval, :time_of_day, :time_zone, :starts_on, :enabled, :baseline_at]))'
   # %{baseline_at: ~U[2026-11-12 10:41:07.512903Z], enabled: true, id: "0c4e…",
   #   interval: :daily, starts_on: ~D[2026-11-12], time_of_day: ~T[03:00:00],
   #   time_zone: "Europe/Paris"}
   ```

   The match makes `rpc` fail loudly on a refusal rather than exit 0. The
   fields are:

   | Field | Values | Default |
   |---|---|---|
   | `components` | `[:db]`, `[:media]` or `[:db, :media]` (de-duplicated and put in that order) | required |
   | `interval` | `:daily`, `:weekly`, `:fortnightly` or `:monthly` ([sub-daily ones are refused](#sub-daily-schedules-wait-for-keep-n-retention)) | required |
   | `time_of_day` | local wall time in `time_zone`, cut to the minute | required |
   | `starts_on` | a local date in `time_zone`; nothing fires before it. Weekly and fortnightly take their weekday from it, fortnightly also its week parity, monthly its day of the month (the 31st becomes the month's last day) | required |
   | `time_zone` | an IANA zone such as `"Europe/Paris"` | `"Etc/UTC"` |
   | `enabled` | `true` or `false` | `true` |

   The create is recorded in the instance security log as **Backup schedule
   created** ([security-events.md](security-events.md#the-instance-log)).
2. Open **Backups** (`/editor/backups`) as a platform admin. The **Schedules**
   section, above **History**, has one line per schedule: its cadence ("Every
   day at 03:00 (Europe/Paris)", "Every week on Thursday at 02:30 (Etc/UTC)",
   "Every 2 weeks on Thursday at 02:30 (Etc/UTC), from 2026-01-01", "Every
   month on day 15 at 03:00 (Etc/UTC)"), what it backs up ("Database",
   "Database + Media") and "Next run: in 16 hours".
3. After the window has passed, the schedule's line reads "Last window:
   started", and **History** has a new row whose trigger reads **Scheduled**.

**Other calls**, each with `actor: admin` as above:

- **List them:** `KilnCMS.Backups.list_backup_schedules(actor: admin)`.
- **Fetch one:** `KilnCMS.Backups.get_backup_schedule(id, actor: admin)`
  (`{:ok, nil}` when there is none).
- **Change one:** `KilnCMS.Backups.update_backup_schedule(s, %{time_of_day: ~T[02:00:00]}, actor: admin)`.
  It accepts the same six fields; anything else is refused.
- **Pause and resume:** `update_backup_schedule(s, %{enabled: false}, actor: admin)`,
  then `%{enabled: true}`. A paused schedule keeps its settings and its line
  reads "Paused".
- **Delete one:** `KilnCMS.Backups.destroy_backup_schedule(s, actor: admin)`
  returns `:ok`.

Every change that alters a field is recorded as **Backup schedule changed**,
and a delete as **Backup schedule deleted**. A change that resubmits the same
values records nothing.

**What can go wrong:**

| Error | Meaning |
|---|---|
| `time_zone`: "is not a known time zone" | The zone isn't in the time zone database. Use an IANA name (`"Europe/Paris"`, `"America/New_York"`), not an abbreviation (`"CET"`). |
| `interval`: "sub-daily schedules arrive with keep-N retention; choose daily or longer" | `:every_2h`, `:every_4h`, `:every_8h` or `:every_12h` ([below](#sub-daily-schedules-wait-for-keep-n-retention)). |
| `components`: "media isn't archived on this deployment" | `:media` on a deployment with no media directory (S3 media, or no `MEDIA_DIR`). |
| `Ash.Error.Invalid` on `components` or `interval` | An empty list, a component other than `:db` or `:media`, or an interval that doesn't exist. |
| `Ash.Error.Forbidden` | The actor is not a platform admin (a site admin is not enough), or you passed `KilnCMS.Backups.system()`, which may not manage schedules. |
| `** (Ash.Error.Query.NotFound)` from `get_user_by_email!` | No account has that email address. |

### What the Schedules list shows

Everything in the section comes from the same status the alarm uses, so a
"Next run" shown there is one the scheduler will act on:

- **"Next run: in 16 hours"** (or "due now") only when the schedule can fire
  here: it is enabled, the scheduler is on, this node can run backups, and it
  covers a component this deployment has. Otherwise there is no next run.
- **"Paused"** for a disabled schedule.
- **The last window's outcome:** "Last window: started", "Last window: queued
  behind another backup", "Last window: joined a queued backup", "Waiting:
  another kind of backup is queued; this one starts once the queue clears.",
  "Waiting: the server that checked can't run backups (`<reason>`); another
  server can take it." (`no_pg_dump`, `no_pg_restore` or `no_database_url` on
  the node that ticked), or "Last window refused: `<reason>`" (`disabled` or
  `no_media_dir`).
- **One alarm line per component**, with its threshold and where it came from:
  "Alarm after 36 hours without a good backup (BACKUP_STALE_AFTER_HOURS)",
  "Alarm after 252 hours without a good backup (its schedule)", or "Alarm after
  36 hours without a good backup (BACKUP_STALE_AFTER_HOURS; host cron backs it
  up too)" ([below](#how-a-schedule-sets-the-alarm-threshold)).
- **Warnings:** "In-app schedules are turned off (KILN_BACKUP_SCHEDULER_CRON)."
  when the scheduler job is off, and "Scheduled backups can't run here:
  `<reason>`" when this node can't run backups (`BACKUP_ENABLED=false`, no
  database connection, or no PostgreSQL client tools).
- "No schedules yet. Backups run when you click Back up now, or from the
  host's cron job." when there are none, and "Couldn't load the backup
  schedules." when they can't be read (the thresholds are then the
  environment's).

Once an enabled schedule exists, the **Overview** page's backup strips for
platform admins say that scheduled backups run "from the in-app schedules
listed on the Backups page or from" the host's cron job, rather than from cron
alone.

### When a schedule fires

`KilnCMS.Backups.Scheduler` runs every minute on the `scheduling` queue
(`KILN_BACKUP_SCHEDULER_CRON`). Each tick reads the enabled schedules and asks
for a backup for every schedule whose **window** (one occurrence, such as
"03:00 Paris on 12 November") has come and not yet been claimed. The claim is
written in the same transaction that starts, queues or folds the backup, so a
window fires once however many nodes tick.

- **Schedules due together make one backup.** Two schedules due in the same
  minute (a database one and a media one, say) are one backup covering both,
  not one queued behind the other.
- **It goes through the queue like Back up now.** While a backup runs, the
  scheduled one queues behind it ("Last window: queued behind another
  backup"), or folds into a queued fresh backup ("Last window: joined a queued
  backup"). It never folds into a queued **Resume** (#2540): the window stays
  due, is asked for again every minute, and starts once the queue clears. The
  wait is logged once per window, "Scheduled backup `<id>` waits: a resume of
  `<stamp>` is queued; …".
- **Only the latest window fires.** A window that passed while nothing ran the
  scheduler (the app was down, or the job was off) is not made up later: when
  the scheduler runs again, the latest window fires within a minute, and
  earlier skipped ones are logged once, "Scheduled backup `<id>` missed earlier
  windows (nothing ran the scheduler): only the latest one runs".
- **No retry within a window.** A window is claimed when its backup is asked
  for. If that backup then fails (after its steps' own retries), the schedule
  waits for its next window; take one with **Back up now** or **Resume** in
  the meantime.
- **Editing rebaselines it.** Changing the interval, time, time zone, start
  date or components, or resuming a paused schedule, means no window from
  before the change fires: moving a 03:00 schedule to 02:00 at 02:30 doesn't
  fire 02:00 at once, and resuming a schedule paused for a week doesn't fire
  the window it missed. Pausing changes nothing else.
- **Time zones and daylight saving.** A time that doesn't exist on a
  spring-forward night moves forward past the gap (02:30 fires at 03:00 local),
  and a time that occurs twice on a fall-back night fires at its first
  occurrence. It fires once either way.
- **Media on a node without a media directory.** The node that ticks decides.
  A database and media schedule there backs up the database only, with the
  warning "Scheduled backup `<id>` covers the media, but this node has no
  media directory configured (MEDIA_DIR): only the database is backed up". A
  media-only schedule there has nothing to back up: its window is refused
  ("Last window refused: no_media_dir").
- **`BACKUP_ENABLED=false` refuses each window.** The window is claimed as
  refused ("Last window refused: disabled", logged once), so nothing asks
  again until the next window.
- **A node that can't run backups defers the window.** With no `pg_dump`, no
  `pg_restore` or no database URL on the node that ticked, the window stays
  due and is asked for again every minute, so a node that can run backups
  takes it. The wait is logged once per window, "Scheduled backup `<id>` waits:
  :no_pg_dump on this node; …".
- **Host cron and a schedule on one component take two backups.** The
  scheduler does not know about cron. Turn one of them off, or schedule them
  apart (cron does not take the backup lock).
- **Retention is unchanged.** Every scheduled backup is a full set of its
  components and is pruned by `BACKUP_KEEP_DAYS` like any other
  ([What retention deletes and what it keeps](#what-retention-deletes-and-what-it-keeps)).
  A schedule does not change what is deleted.

### Sub-daily schedules wait for keep-N retention

`:every_2h`, `:every_4h`, `:every_8h` and `:every_12h` exist in the schema but
are refused when a schedule is created or its interval changed, until keep-N
retention (a later part of #2219) can cap how many backups a schedule keeps.
Retention today is by age alone, and every run is a full set, so the sets on
disk for each component are about:

> runs per day × `BACKUP_KEEP_DAYS`

With the default 14 days, a daily schedule keeps about 14 sets of each
component it covers; a two-hourly one would keep 12 × 14 = 168, each a full
database dump (and a full media archive, if it covers media). Need more than
one backup a day now? Run host cron more often, where you control what
`backup.sh prune` keeps.

### How a schedule sets the alarm threshold

Without a schedule, a component's last good backup is stale after
`BACKUP_STALE_AFTER_HOURS` (default 36). A schedule replaces that threshold for
the components it covers, but only while it is known to run: this node can
run backups, the scheduler is on, the schedule is enabled, its last window was
not refused, and at least one of its windows has come since it was created or
last rebaselined (and since `starts_on`). Until then the environment's
threshold applies, so a schedule that never fires never silences the alarm.

The threshold is the interval plus half of it, at least six hours, for the
shortest such schedule on that component:

| Interval | Stale after |
|---|---|
| daily | 36 h |
| weekly | 252 h |
| fortnightly | 504 h |
| monthly | 1116 h |

A weekly schedule therefore **raises** the threshold from the default 36 h:
weekly backups are not an alarm on day two. When host cron has also backed the
component up in the last eight days (an imported run with trigger `cron`), the
threshold is the lower of the schedule's and `BACKUP_STALE_AFTER_HOURS`, and
the Backups page says "host cron backs it up too".

### Restoring the database brings back the schedules

The schedules are rows in the database, so restoring a dump restores them as
they were when it was taken: deleted schedules come back, paused or enabled as
they were then, with the last window they had claimed. On the first tick after
the restore, each enabled schedule whose latest window is newer than that fires
within a minute (one extra backup). To avoid it, pause the schedules before
anything ticks: start the restored release with `KILN_BACKUP_SCHEDULER_CRON=false`,
pause or delete them from a console, then unset the variable and restart.

A staging clone made with the [staging scrub](staging-environments.md#the-scrub)
pauses every schedule (`backup_schedules_disabled` in the scrub's summary), so
a clone never runs production's schedules against its own backup directory.

### The scheduler job

`KILN_BACKUP_SCHEDULER_CRON` (default `* * * * *`) is when the scheduler checks
the schedules, not when they fire: a window is the schedule's own time, so a
coarser cadence such as `*/5 * * * *` only makes a backup start up to five
minutes late. Every minute leaves about 10 000 completed job rows a week, which
Oban prunes after 7 days. `false` (also `off`, `no`, `0` or blank) turns every
schedule off, and the Backups page says so; an unparseable value does the same
and warns on stderr at boot. It is read in every environment, and
`BACKUP_ENABLED=false` does not remove it
([environment-variables.md](environment-variables.md)).

From a console, `KilnCMS.Backups.Scheduler.tick(DateTime.utc_now())` runs one
tick now and returns `:ok`; what it did is in the log and the telemetry below.

**Telemetry.** Each event has measurements `%{count: n}`, emitted only when
`n` is above zero:

| Event | Metadata | When |
|---|---|---|
| `[:kiln_cms, :backups, :schedule, :fired]` | `status` (`:started`, `:queued` or `:folded`), `schedule_ids`, `chain` | A tick asked for a backup and claimed the windows. |
| `[:kiln_cms, :backups, :schedule, :deferred]` | `schedule_ids` | Due windows were refused for now (a queued Resume, or this node can't run backups). Every tick while they wait; the log line is once per window. |
| `[:kiln_cms, :backups, :schedule, :refused]` | `schedule_ids` | Windows were claimed as refused (`BACKUP_ENABLED=false`, or media-only with no media directory). |
| `[:kiln_cms, :backups, :schedule, :narrowed]` | `schedule_ids` | Database and media schedules backed up the database only (no media directory on this node). |
| `[:kiln_cms, :backups, :schedule, :missed]` | `schedule_ids` | Schedules skipped earlier windows; only the latest fired. |
| `[:kiln_cms, :backups, :schedule, :invalid]` | `schedule_ids` (one) | A schedule's window can't be computed (an interval, zone or component this release doesn't know). Logged at most once an hour per schedule per node. |
| `[:kiln_cms, :backups, :schedule, :unreadable]` | `error` (the error's module) | The tick couldn't read the schedules. Logged at most once every 15 minutes. |
| `[:kiln_cms, :backups, :status, :schedules_unreadable]` | `error` (the error's module) | The status couldn't read the schedules and used `BACKUP_STALE_AFTER_HOURS` for every component. Logged at most once every 15 minutes. |

**Rolling deploys and rolling back.** The `add_backup_schedules` migration
only creates the `backup_schedules` table, so an older release runs against
it unchanged. During a rolling deploy a node from before this release that
picks up a scheduler job discards it as an unknown worker; the window stays
due, and the next tick on a newer node fires it. After rolling back, the
older release has no scheduler, so **no schedule fires**: make sure host cron
covers you. The table and its rows stay, and fire again when you roll
forward. (`mix ecto.rollback` of the migration drops the table and the
schedules with it.)

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

Right after a Cancel, wait about two and a half minutes before clicking
**Resume** ([why](#cancel-a-running-backup)); a click sooner is refused with
how many seconds are left.

**A resume that can't run says so on its row (#2539).** A resume can be
refused after the click, once its start step runs: its files aren't on the
server that picked it up, no server with its backup directory picked it up
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)), or
its start step crashed before it re-opened the run. The row then shows
"Resume refused: `<reason>`" above the error it already had, and keeps its
status (`Failed` or `Canceled`) and its **Resume** button. A second refusal
replaces the first note rather than adding to it. An interrupted row (still
`Running`, but quiet) is marked `Failed` instead, with the refusal above
"Interrupted: the job was killed or the node stopped". The lock is released,
so a queued backup starts.

What can go wrong when you click **Resume**:

| Message | Meaning |
|---|---|
| "That backup was canceled moments ago. Resume it again in N seconds: a step on a server that lost contact with the database may still be stopping." | It was canceled less than 150 seconds ago. Click again when the time is up. |
| "That backup is running right now." | It is the backup that is running. |
| "That backup can't be resumed: only a failed, interrupted or canceled backup can." | It succeeded, was skipped or imported, or is still working. |
| "That backup can't be resumed: the files it had written are gone." | Its `.work/<stamp>/` is not on this server (swept, deleted, or on another host). |
| "That backup can't be resumed." | Anything else, for example a malformed stamp. |

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

### Off-site credentials stay out of the rclone command line (#2690)

A command's arguments are not private: `/proc/<pid>/cmdline` is
world-readable, `ps` on the host shows a container's processes, and monitoring
agents record them, for the minutes a copy takes. So when `BACKUP_RCLONE_REMOTE` is a connection
string, the app and `backup.sh` both hand its parameters to rclone as
`RCLONE_CONFIG_<NAME>_<KEY>` environment variables of that one `rclone`
process, and give rclone only the remote's name and path:

| `BACKUP_RCLONE_REMOTE` | rclone's argument | rclone's environment |
|---|---|---|
| `r2:kiln-backups` | `r2:kiln-backups/db` | nothing added |
| `:s3,provider=Cloudflare,access_key_id=…,secret_access_key=…:kiln-backups` | `kiln_offsite:kiln-backups/db` | `RCLONE_CONFIG_KILN_OFFSITE_TYPE=s3`, `…_PROVIDER=Cloudflare`, `…_ACCESS_KEY_ID=…`, `…_SECRET_ACCESS_KEY=…` |
| `r2,secret_access_key=…:kiln-backups` | `r2:kiln-backups/db` | `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=…` (overrides that key of `r2` in `rclone.conf`) |

A key without a value means `true`; a value in `'…'` or `"…"` may contain `,`
and `:`, and a doubled quote stands for one, as in rclone. Two forms are left
as written, credentials included, so prefer a named remote:

- an overridden named remote whose name is not letters, digits and `_` only
  (`my-r2,secret_access_key=…:bucket`): rclone cannot look such a name up as a
  variable;
- a string neither the app nor rclone can parse; rclone then fails, and its
  error is redacted before it is recorded.

The name `kiln_offsite` is reserved for this: a `[kiln_offsite]` section in
your `rclone.conf` would supply the keys the connection string does not set.

The same holds for what is written down. The run's log, its error and the
off-site destination key go through `KilnCMS.Backups.Redact`, which removes
`key=value` credentials and every value it passed to rclone. `backup.sh` prints
`Off-site copy → kiln_offsite:kiln-backups`, not the string, but still writes
the string as given to `manifest.json`'s `offsite` (redacted when the app
imports it): one more reason to prefer a named remote.

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

**When a run is killed outright** (`kill -9`, the OOM killer, power loss), no
cleanup runs, and the run's `.partial` files stay behind. It recovers on its
own: see [When a cron run is killed outright](#when-a-cron-run-is-killed-outright-2478).

**`backup.sh verify`** checks the newest media stamp that has no `.partial`
beside it, and names any newer one it skipped ("Skipping media set <stamp>:
still being written, or interrupted"). It fails on parts with no sidecar, and
fails when every media stamp it found is unfinished.

### When a cron run is killed outright (#2478)

A `backup.sh` run that is killed outright (`kill -9`, the OOM killer, a power
cut) runs no cleanup. It leaves its `.partial` files behind: the in-progress
marker `media/kiln-media-<stamp>.sha256.partial`, and the dump or part it was
writing. `backup.sh all` creates the marker before the database dump whenever
`MEDIA_DIR` is set, so a run killed during its dump, or during the dump's
off-site copy, leaves one too. While a `.partial` is there, `backup.sh verify`
skips that stamp's media set and `restore.sh media` refuses it.

Nobody has to step in. While a run is alive, a background loop in `backup.sh`
touches every `.partial` of its stamp every 5 minutes, so a run that is slow
(planning a large media tree, a dump waiting on a lock) never looks dead. Once
the loop stops, the files go quiet, and this is what happens, counting from the
newest file of the stamp:

1. **For the first 3 hours** the stamp is pending. History has no row for it,
   and the importer's summary counts it under `pending`.
2. **After 3 hours with every file of the stamp unchanged**, the next import
   records it. An import runs when a platform admin opens **Backups**, in every
   [last-good marker](#the-last-good-marker) sync (every 15 minutes by
   default), and at the start of every in-app backup. History then shows a
   **Failed** run whose error reads "Interrupted: the backup stopped before it
   finished and left .partial files behind". Its log names up to five of the
   files left behind with their age ("No backup has written to this stamp for
   hours; left behind: …"). Its artifacts are the finished files (none if the
   run was killed in its first file), and its components are the kinds of all
   its files, partial or finished. The row is never rewritten.
3. **After 12 hours with every file of the stamp unchanged**, `backup.sh prune`
   deletes the stamp's `.partial` files and prints the path of each. Prune runs
   at the end of every `backup.sh all` that succeeds and on its own as
   `backup.sh prune`, so with the nightly cron line at the top of this guide
   that is the next night's run; with an hourly cron, about the twelfth run
   after the kill. The stamp's finished files are not touched there: they age
   under `BACKUP_KEEP_DAYS` like any other unit.

What keeps a killed run's `.partial` files from `backup.sh prune`: a
`.work/<stamp>/` directory for the stamp, or any file of the stamp, in `db/` or
`media/`, changed in the last 12 hours. A recovery point (`.keep`) does not:
`restore.sh` refuses a set with a `.partial` beside it, so keeping one would
leave the pinned set unrestorable.

The start of every in-app backup also clears `.partial` files, and reads the
stamp first in the same way. It runs the importer, then removes the `.partial`
files of a stamp that has a History row (the app's own run, or an imported
one) once every file of the stamp is more than an hour old. A cron leftover
with no row yet is left for the importer. A `.partial` whose name carries no
backup stamp is removed once it is an hour old, as before.

**If the stamp was never read.** With the marker sync turned off
(`KILN_BACKUP_MARKER_SYNC_CRON=false`) and nobody opening the Backups page, or
with the host's app down for more than 12 hours after the kill, `prune` can
remove the marker before the importer has seen the stamp. The stamp then
imports as what is left of it:

| Left on disk | Imported as |
|---|---|
| Media parts with no sidecar | **Failed**, "incomplete media set: parts but no sidecar" |
| A single media archive with no sidecar (the archive was finished; its sidecar wasn't) | **Succeeded** |
| A finished dump and no media file | **Succeeded**, database only |
| Only `.partial` files | No row: prune removed everything the run wrote |

**Run the same `backup.sh` on every host as the app.** The heartbeat loop is
new in this release. An older copy of the script doesn't keep its files fresh,
so a live run with a phase in which nothing is written for 3 hours (planning a
very large media tree on NFS, or `pg_dump` waiting for a lock) can be recorded
as Interrupted, and that row stays.

What can go wrong:

| Message | Where | Meaning |
|---|---|---|
| `Backup files dated in the future (<stamps>): kept pending, as if still being written; check the clocks of this node and of the backup directory's file server` | Server log | A file of a held stamp is dated more than 5 minutes ahead of the node's clock. The stamp stays pending until the clocks agree: a clock that is off must not turn a live run into a dead one. |
| `warning: could not look for recent files of <stamp>; keeping its partials` | `backup.sh prune` | `find` failed on `db/` or `media/`. Nothing of that stamp was deleted; the next prune tries again. |
| `warning: could not remove <path>` | `backup.sh prune` | The `.partial` could not be deleted (permissions). The rest went on. |
| `Removing an abandoned backup partial: <name>` | Server log | The start of an in-app backup removed a `.partial`, as above. |
| `Partial sweep skipped db/: it can't be listed (<reason>)` | Server log | That directory's `.partial` files were left for the next in-app backup; the other directory's were still swept. |
| `Partial sweep kept every stamped partial: <error>` | Server log | History could not be read, so no `.partial` named after a stamp was removed. |

### Backup history (#2217)

**Back up now** is not the only thing the page remembers. Below the status panel,
**History** lists every backup attempt, newest first, 25 to a page. Platform
admins only, like the rest of the page.

1. Open **Backups** (`/editor/backups`) as a platform admin.
2. Scroll to **History**. Each row shows the trigger (**Manual**, **Cron** or
   **Console**; any other value as recorded), a status (`Succeeded`,
   `Failed`, `Running`, `Skipped` or `Canceled`), **Database** and **Media** badges, the
   size, whether it was verified, its destinations, and whether its files are
   still on this host. A media set written in several parts shows "N parts".
   A failed, interrupted or canceled run shows **Resume**
   ([above](#media-backups-in-parts-2218)); its tooltip names which of the
   three it is and, for a canceled one, says to wait about two and a half
   minutes after the Cancel. A resume that was refused after the click shows
   "Resume refused: …" above the row's error. A running in-app one shows **Cancel**
   ([above](#cancel-a-running-backup)) until it is finishing.
3. Use **Previous** / **Next** to page ("Page 1 of 3").

**Retention markers on the page (#2542).** The page shows which backups the
on-disk markers protect, so you don't need a shell to check:

- A **Recovery point** badge on a row: a `kiln-<stamp>.keep` for that stamp is
  in `db/` or `media/`, so retention keeps every file of that backup
  ([Keep a backup as a recovery point](#keep-a-backup-as-a-recovery-point)).
- A **Last good: Database** or **Last good: Media** badge: that component's
  `kiln-<stamp>.good` names this backup, so `backup.sh prune` keeps that
  component of it ([The last-good marker](#the-last-good-marker)).
- **Last-good marker (kept by backup.sh prune)**, above the list: the stamp each
  component's marker names, or "none yet". It is there even when the marked
  backup is on another page of History. It lists only the components this
  deployment backs up (**Media** only when media backups are configured).
  Should a directory hold more than one `.good`, the newest stamp is shown.

The markers are read from this server's `BACKUP_DIR` whenever the page loads
History (opening it, paging, after an action, and on each refresh while a
backup runs); they are never stored. With a backup directory per host,
another server may show different markers. A `db/` or `media/` the app can't
list contributes no badges, and the summary reads "none yet" for that component
even if a marker is there; the page itself still loads. Check the host with `ls`
when the summary disagrees with what you expect.

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
a platform admin opens the page, at the end of every in-app backup, in every
run of the [last-good marker](#the-last-good-marker) sync (every 15 minutes by
default), and on demand:

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
with one, so parts without it are what a run killed mid-set leaves once its
`.partial` marker went before the importer read the stamp (a manifest calling
them verified does not excuse it). A legacy single archive without a sidecar,
from before checksums, imports as before. Sidecars are not rows; they supply
the per-file SHA-256 shown on an imported row. It is safe to repeat (idempotent
by stamp, never touching a row the application owns), and does not need
`BACKUP_ENABLED` or `pg_dump`. A stamp that `manifest.json` doesn't name is
`pending` in the summary until:

- **with no `.partial` beside it**, its newest file is 10 minutes old; it then
  imports as what it is;
- **with a `.partial` beside it** (of any kind, in `db/` or `media/`), every
  file of the stamp has been unchanged for 3 hours; it then imports as a failed
  "Interrupted" run
  ([When a cron run is killed outright](#when-a-cron-run-is-killed-outright-2478)).
  A file dated more than 5 minutes in the future keeps the stamp pending, with
  a warning. `manifest.json`
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
`rclone.conf` mounted read-only with `RCLONE_CONFIG` pointing at it. A
connection-string remote (`:s3,secret_access_key=…:bucket`) works too: its
parameters reach `rclone` as environment variables, not as a command-line
argument ([Off-site credentials stay out of the rclone command
line](#off-site-credentials-stay-out-of-the-rclone-command-line-2690)), but a
named remote keeps the credentials in separate secrets.
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
   env. The newest media set need not share the dump's stamp: a database-only
   or media-only backup
   ([above](#back-up-only-the-database-or-only-the-media)) has files of one
   kind only, so pick the newest verified set of each kind.
5. **Recreate the app in Coolify** from the env snapshot — **the same
   `SECRET_KEY_BASE`** (see above), `DATABASE_URL`, storage/OIDC/SMTP vars —
   and deploy. Boot runs `bin/migrate`, which also catches the dump up to a
   newer image's schema.
   The restored database holds the in-app backup schedules as they were when
   the dump was taken, and each enabled one fires its latest window within a
   minute of the app starting
   ([Restoring the database brings back the schedules](#restoring-the-database-brings-back-the-schedules)).
   Set `KILN_BACKUP_SCHEDULER_CRON=false` for the first boot if that backup
   is unwanted.
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
| `kiln-media-<stamp>.sha256.partial is beside the set for <stamp>` | A backup is writing this stamp, or was killed while writing it. Wait for a running backup to finish, or pick another stamp. A leftover from a killed run is [removed](#when-a-cron-run-is-killed-outright-2478) by `backup.sh prune` once every file of the stamp is 12 hours old, or sooner by an in-app backup once History has recorded the run; the set is then refused for its missing sidecar, unless it was a single finished archive. |

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

The rows marked **backup + app** are read by both paths, `scripts/backup.sh`
and the app (`config/runtime/prod/backups.exs` → `KilnCMS.Backups`), by the same
names, so a deployment configured for cron needs nothing extra for the console.
The app reads them in production only.

| Variable | Script | Meaning |
|---|---|---|
| `DATABASE_URL` | backup | source DB (read-only): `postgres://`, `postgresql://` or `ecto://`; the password reaches `pg_dump` as `PGPASSWORD` only ([connection URLs](#which-database-url-the-backup-tools-accept-2719)) |
| `BACKUP_DIR` | backup + app | local backup root (default `/var/backups/kiln`) |
| `MEDIA_DIR` | backup + app | uploads root (Local adapter only; omit on S3). Defaults to `KILN_MEDIA_ROOT` when that is set |
| `BACKUP_KEEP_DAYS` | backup + app | local retention, 1 to 2147483647 days (default 14; anything else keeps 14 and warns): the age at which a backup may be deleted ([keep rules](#what-retention-deletes-and-what-it-keeps)) |
| `BACKUP_ENABLED` | app | set false to disable the in-app path only; cron is unaffected (default true) |
| `KILN_BACKUP_MARKER_SYNC_CRON` | app | when the app moves the [last-good markers](#the-last-good-marker) for cron's backups (default `*/15 * * * *`; `false` turns it off). Read in every environment, and not turned off by `BACKUP_ENABLED=false` |
| `BACKUP_STALE_AFTER_HOURS` | app | how old before the console warns (default 36); an in-app schedule replaces it for the components it covers ([threshold rules](#how-a-schedule-sets-the-alarm-threshold)) |
| `KILN_BACKUP_SCHEDULER_CRON` | app | when the app checks its [in-app schedules](#schedule-backups-in-the-app) (default `* * * * *`; `false` turns every schedule off). Read in every environment, and not turned off by `BACKUP_ENABLED=false` |
| `BACKUP_MEDIA_PART_MB` | backup + app | target ceiling on one media part's input size, 16 to 10240 (default 400) |
| `BACKUP_MEDIA_EXCLUDE` | backup + app | comma-separated globs the media archive leaves out (default none) |
| `TMPDIR` | backup | where `backup.sh` builds the media file lists (default `/tmp`); removed when it exits |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup + app | off-site rclone remote (strongly recommended). Each file is re-hashed before its copy; a refused or failed copy fails the run. The official image ships `rclone`; set without it, an in-app run fails ([above](#it-needs-the-client-tools-in-the-image)) |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `BACKUP_DATABASE_URL` | app | connection string the in-app backup dumps, for a connection the app cannot derive from `DATABASE_URL` or the Repo config (a unix-socket repo). Unset, it uses `DATABASE_URL` when that names the connected database, else a URL rebuilt from the Repo. Any of them may be `ecto://`; Ecto-only query parameters are refused by libpq ([connection URLs](#which-database-url-the-backup-tools-accept-2719)) |
| `RCLONE_CONFIG`, `RCLONE_CONFIG_<NAME>_*`, `RCLONE_RETRIES` | rclone | read by `rclone` itself, which inherits the environment of whichever path runs it: the named remote's configuration file or settings, and rclone's retry count (default 3). Kiln does not read them. `kiln_offsite` is reserved ([above](#off-site-credentials-stay-out-of-the-rclone-command-line-2690)) |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill`: `postgres://`, `postgresql://` or `ecto://`; the password reaches `pg_restore`/`psql` as `PGPASSWORD` only |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
| `RESTORE_REQUIRE_CHECKSUM=1` | restore | `media`: abort when there is no checksum sidecar (default: warn and continue for a legacy single archive) |
| `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` | restore | `media`: restore a `.partNN` set that has no sidecar (default: refuse, since a set without one is most likely from a killed run) |
