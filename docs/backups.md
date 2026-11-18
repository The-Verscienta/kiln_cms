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

The app's `DATABASE_SSL` doesn't reach this line: when the database is on
another host, add `?sslmode=require` (or `verify-full`) to its
`DATABASE_URL` ([How the backup tools choose TLS](#how-the-backup-tools-choose-tls-2830)).

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
| **Secrets/env** | Coolify environment variables — above all **`SECRET_KEY_BASE`**, plus `DATABASE_URL`, S3 creds, OIDC/SMTP config, rclone's configuration, and where each [backup destination](#send-backups-to-several-destinations) writes with its credentials | Manual: keep a copy in your password manager, refreshed whenever an env var or a destination changes |

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

The cadence above is host cron's. An in-app schedule, set up on the
**Schedule** tab of the Backups page, can take the database and media backups
instead
([Schedule backups in the app](#schedule-backups-in-the-app), part of #2219);
run one or the other on each component, not both, or each window takes two
backups. A schedule can also keep its own backups longer or shorter than
`BACKUP_KEEP_DAYS`, or keep its newest N however old
([Set how long a schedule keeps its backups](#set-how-long-a-schedule-keeps-its-backups)).

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
5. **A schedule's keep count.** A schedule that keeps its newest N keeps, for
   each component it backs up, its own newest N backups and the newest N of
   its own and cron's together, however old. Only good units count: complete
   on disk, of a `Succeeded` run as in rule 3, not in flight, of a plausible
   stamp, and not a recovery point.
6. **Unrecorded.** A unit with no History row, with a `Skipped` row, or whose
   row records no artifact of that kind is deleted once it is older than the
   component's floor (below).
7. **A schedule's own age.** A backup a schedule made is deleted once it is
   older than that schedule's **Keep for (days)**, which can be shorter or
   longer than `BACKUP_KEEP_DAYS`.
8. **Cron's and orphaned backups.** A backup imported from cron, or one a
   schedule made that no live schedule backing that component up claims any
   more (the schedule was deleted, or no longer backs that component up), is
   deleted once it is older than the component's floor.
9. **Age.** Anything else (a **Back up now**, a console backup) is deleted
   once it is older than `BACKUP_KEEP_DAYS`.

A component's **floor** is the longest of `BACKUP_KEEP_DAYS` and the **Keep
for (days)** of every schedule that backs that component up: no backup a
schedule did not make ages out sooner than one it did. Without schedules, or
with schedules that set no keep values, rules 5 to 8 come down to rule 9 and
retention is `BACKUP_KEEP_DAYS` for every backup, as before
([Set how long a schedule keeps its backups](#set-how-long-a-schedule-keeps-its-backups)).

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
stale [last-good marker](#the-last-good-marker) still names, plus what the
schedules keep beyond `BACKUP_KEEP_DAYS` (their keep counts and longer keep
days).

**Never deleted by retention:** symlinks, directories, `.work/`, and
recovery-point markers. `.partial` files are cleared by two narrower rules,
each of which lets History read the stamp first: the start of every in-app
backup removes those whose stamp has a History row once every file of that
stamp is more than an hour old, and `backup.sh prune` removes those of a run
killed outright once every file of that stamp is 12 hours old
([When a cron run is killed outright](#when-a-cron-run-is-killed-outright-2478)).
Last-good and hold markers are never aged either; the app moves them itself
([The last-good marker](#the-last-good-marker),
[The hold markers](#the-hold-markers)). A `kiln-*` file in `db/` or `media/` that belongs to no
unit, such as a part named `part001` instead of `part01`, is a stray: the app
deletes it once it is older than `BACKUP_KEEP_DAYS`, and `backup.sh` leaves it
alone. The one exception is a file kept after its off-site copy was refused,
`<name>.refused-<stamp>`: both prunes delete it once it is older than
`BACKUP_KEEP_DAYS` counted from the refusal as well as from its mtime
([When an off-site copy is refused](#when-an-off-site-copy-is-refused)).

In History, a run whose dump retention removed while its media is still on disk
reads `Database: pruned (retention)` beside `Media: on disk`
([Backup history](#backup-history-2217)).

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
  last_good: %{db: nil, media: nil},
  holds: %{db: [], media: []}
}
```

The `20261025-031700` dump goes while that stamp's media stays: it is the
newest complete media unit, and the newer `20261107-031700` stamp has no media.
`backup.sh prune` on the same directory removes the same two files. A kept
unit's `reason` is one of `:recovery_point`, `:in_flight`, `:newest_verified`,
`:newest_complete`, `{:keep_count, schedule_ids}` (rule 5, with the ids of
the schedules whose count holds it), `:unrecorded`, `:schedule` (rule 7),
`:schedule_floor` (rule 8 when the floor is above `BACKUP_KEEP_DAYS`) or
`:keep_days`; a
deleted one's is `{:expired, rule, days}`, where `rule` is `:unrecorded`,
`:schedule`, `:schedule_floor`, `:keep_days` or `:stray`, and `days` the age
it was held to. Once the newest unit of a kind belongs to a succeeded run that verified it (or
imported it from cron), it reads `:newest_verified` instead. `plan.last_good`
is that newest verified stamp of each kind, or `nil` when there is none: what
the [last-good markers](#the-last-good-marker) should name. `plan.holds` lists
the stamps of each kind the schedules' keep rules hold: what the
[hold markers](#the-hold-markers) should name. A dry run writes no marker.

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
  from both. A finish step that has lost the lock by then (it stalled long
  enough to be [taken back](#several-nodes-and-the-backup-lock)) writes no
  marker: the step that took over finishes the backup and syncs them (#3013).
  Two syncs for different backups could otherwise remove each other's
  markers.
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
nothing in the app, and its unit ages there like any other. The reasoning is in [ADR 0041](decisions/0041-the-app-and-backup-sh-agree-on-what-to-keep-only-through-presence-only-marker-files.md).

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
   backups are configured) with the stamp its marker names, or "none yet"
   (or why it couldn't tell: [Backup history](#backup-history-2217)). The
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
  runs ahead still counts). When a node that beat in the last 180 seconds
  runs that directory's own queue, `backup_dir_<id>`, the sync goes there,
  and only a node with the directory picks it up
  ([Which node runs a step](#which-node-runs-a-step), #2845). Otherwise it
  goes to `default` and waits for a node that reads the id, putting itself
  back every 30 seconds up to 20 times (about 10 minutes); a node without
  the directory that picks it up moves it to the directory's queue once one
  runs. If none picks it up, the server log says "Backup last-good marker
  sync for backup directory `<id>` gave up: no node with that directory
  picked it up", and the next slot tries again. A sync left in a directory's
  queue that no node runs is canceled with the same line, after 5 minutes
  when the directory's node is up but its queue isn't running, and after 30
  when no node has reported the directory for 180 seconds
  ([Jobs left in a directory queue](#jobs-left-in-a-directory-queue)).

So with a `BACKUP_DIR` per host, each host's directory is synced in a slot
its node can reach: through the directory's queue, or, without one, as long
as its node picks up one of the about 21 releases of its queued sync in
those 10 minutes. The sync shares the directory's queue with the backup
steps, one job at a time, so it can wait behind a long step. A host whose
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

For as long as reading `BACKUP_DIR` hangs (a hard-mounted NFS export that
stopped answering, say), the node also reports no id, so the queued syncs
stop going to it until the directory answers again
([The backup-directory id read](#the-backup-directory-id-read-2848)). A job
already on such a node gives up after a bounded wait instead of holding an
Oban slot
([The marker sync on a hung backup directory](#the-marker-sync-on-a-hung-backup-directory-3079)).

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
and metadata `%{dir: dir, db: stamp | nil, media: stamp | nil, held: n}`: the
newest verified stamp of each component, or `nil` for one with none (its
marker, if any, is left alone), and how many [hold markers](#the-hold-markers)
the directory has once the run is done, counted from the disk. A run skipped because an
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
| `Backup last-good marker sync for backup directory <id> gave up: no node with that directory picked it up` | none | No running node reads that directory id, or the one that does doesn't run its queue; see **Several nodes** above. A node that has just stopped can cause it: its id counts until its last heartbeat is 10 minutes old. |
| `Backup last-good marker sync: the id read of the backup directory <dir> took more than <ms> ms (a hung mount?). Giving up for this slot; the id read is left running.` (or `the marker sync of`) | none (emits `[:kiln_cms, :backups, :marker_sync, :timeout]` instead) | The directory didn't answer in time, so the job gave up for this slot and left the task running ([The marker sync on a hung backup directory](#the-marker-sync-on-a-hung-backup-directory-3079)). |
| `Backup last-good marker sync didn't start the id read of <dir>: 2 earlier ones it gave up on are still running (a hung mount?)` (or `the marker sync of`) | none | Two tasks the job gave up on are still stuck, so this one started none ([same section](#the-marker-sync-on-a-hung-backup-directory-3079)). |

### The hold markers

`kiln-<stamp>.hold` tells `backup.sh prune` which backups the in-app
schedules' keep settings hold (rules 5 to 8 above), so cron keeps them too.
Cron has no schedules to work that out from; the app writes the answer to
disk, as it does for the [last-good marker](#the-last-good-marker). You don't
create these markers. A deployment with no schedule that sets **Keep the
newest** or **Keep for (days)** has none.

What it is:

- **An empty file in the component's own directory**, like `.good`: it pins
  only that component of that stamp. `db/kiln-20261107-031700.hold` keeps that
  dump and its sidecar from `backup.sh prune`, never the media of the same
  stamp.
- **Only its presence counts.** An entry of that exact name of any kind keeps
  the unit; its contents are never read.
- **One per held unit**, so a directory can have many: every unit a keep
  count holds, and every unit kept on a number of days other than
  `BACKUP_KEEP_DAYS` (a schedule's own **Keep for (days)**, or a floor raised
  above `BACKUP_KEEP_DAYS`), until that age passes. A recovery point the
  schedules hold gets one too. Which units are held follows from the
  schedules and the backups on disk, not from whether a backup has already
  passed `BACKUP_KEEP_DAYS`, so a hold is in place before cron would delete
  the backup, not 15 minutes after.
- **Only for a backup that still has its data.** A unit with nothing left
  but its `.sha256` sidecar gets no hold, and a hold it had is removed.

When the app writes and removes them: wherever it moves the `.good` markers
(after every successful in-app backup, before every in-app prune deletes
anything, and every 15 minutes from `KilnCMS.Backups.MarkerSyncWorker`), and
also right after a schedule is created, changed or deleted, which queues one
run of that job so the holds follow the new keep settings at once. Every new
hold is written first and only then are holds no longer needed removed, so a
cron prune in between keeps too much, never too little. Only regular files
are removed. The app never reads a `.hold` back as a keep rule.

**Turn it on.** Replace the host's copy of `scripts/backup.sh` (the one your
cron line runs) with this release's before any schedule keeps backups past
`BACKUP_KEEP_DAYS`. An older copy ignores `.hold` and deletes those backups
once they are older than `BACKUP_KEEP_DAYS`. Then, on the host:

```bash
ls -1 /var/backups/kiln/db/
# kiln-20261101-030000.hold
# kiln-20261107-030000.good
# kiln-20261107-030000.hold
# kiln-db-20261101-030000.dump
# kiln-db-20261101-030000.sha256
# kiln-db-20261107-030000.dump
# kiln-db-20261107-030000.sha256
```

Here a daily database schedule keeping its newest two holds both dumps, and
the newer one is also the last good backup.

Things to know:

- **When the schedules can't be read**, the in-app prune deletes nothing
  ([When retention is skipped or stops](#when-retention-is-skipped-or-stops)),
  and the marker sync still moves the `.good` markers but leaves every hold
  as it is: a hold too many keeps a backup a while longer, one too few lets
  cron delete what a schedule keeps.
- **With `KILN_BACKUP_MARKER_SYNC_CRON=false`**, holds move only when an
  in-app backup succeeds or prunes; a schedule change does not queue a sync.
- **A schedule change made while a marker sync is running** queues one more
  sync, which waits for the running one to release the backup lock and then
  reads the change (#2932). One already queued absorbs the change. While an
  in-app backup holds the lock, the sync writes nothing and the backup
  syncs the markers when it succeeds; if it fails, the next slot (15 minutes
  by default) does.
- **History shows them**: a row whose backup a `.hold` names has a **Kept by
  a schedule: Database** or **Kept by a schedule: Media** badge
  ([Backup history](#backup-history-2217)).
- **Don't delete a `.hold` by hand** while the app keeps them in step: until
  the next sync, cron can delete the backup it named.
- **Rolling back to 1.9.x** ignores the schedules and their keep settings:
  its in-app prune deletes by `BACKUP_KEEP_DAYS` alone, and deletes `.hold`
  files as strays once they are older than `BACKUP_KEEP_DAYS`. 1.9.x has no
  scheduled sync, so on a deployment that takes no in-app backups the holds
  stay, and a `backup.sh` from this release keeps those backups until you
  remove them: `rm /var/backups/kiln/db/kiln-*.hold /var/backups/kiln/media/kiln-*.hold`.
- **An older `backup.sh` is caught after the fact.** Nothing on the host
  tells the app which copy of the script cron runs. The Schedule tab's keep
  settings always say the script must be this release's, and its preview
  asks you to replace it when host cron backed up here in the last eight
  days
  ([Set how long a schedule keeps its backups](#set-how-long-a-schedule-keeps-its-backups)).
  Once an older copy has deleted a held backup, the next marker sync reports
  it ([When a backup a schedule keeps is deleted outside the app](#when-a-backup-a-schedule-keeps-is-deleted-outside-the-app)).

**When a hold can't be moved.** The backup, prune or sync succeeds or fails
on its own terms. Each of these logs a warning, and all but the listing one
emit `[:kiln_cms, :backups, :hold, :failed]` with measurements `%{count: 1}`:

| Server log | Telemetry metadata | Meaning |
|---|---|---|
| `Backup hold markers not updated: couldn't read the backup schedules (<error>)` | `%{reason: reason}` | After an in-app backup or in a marker sync: the schedules couldn't be read (or the policy was invalid). The `.good` markers moved; every hold was left as it is. |
| `Backup hold marker db/kiln-<stamp>.hold couldn't be written (<reason>); backup.sh prune may delete that backup` | `%{kind: :db, stamp: stamp, reason: posix}` | A new hold couldn't be created. `:eacces` is a permission problem on the directory. |
| `Couldn't remove old hold marker db/kiln-<stamp>.hold (<reason>)` | `%{marker: "db/kiln-<stamp>.hold", reason: {:remove, posix}}` | A hold no longer needed couldn't be deleted. Cron keeps that backup until it is removed. |
| `Left db/kiln-<stamp>.hold in place: a directory, not a regular file` | `%{marker: "db/kiln-<stamp>.hold", reason: {:not_regular, type}}` | Something other than a regular file has the name. The app removes only regular files. |
| `Couldn't list db/ to remove old hold markers (<reason>)` | none | New holds are in place; old ones stay until the next sync. |

Why a third marker rather than reusing `.good`, and what was traded:
[ADR 0062](decisions/0062-a-schedules-keep-holds-reach-backup-sh-through-a-third-presence-only-marker.md).

### When a backup a schedule keeps is deleted outside the app

A host whose `scripts/backup.sh` is older than the hold markers ignores
them, so its cron prune deletes backups a schedule keeps once they are older
than `BACKUP_KEEP_DAYS`. The app can't stop that, but it notices at the next
marker sync (after an in-app backup, before an in-app prune, every 15
minutes, and after a schedule change) and tells you (#2931).

What counts: a backup with a `.hold` whose data file is gone, either
entirely or leaving only its `.sha256` sidecar (what the `find`-based prune
of 1.8 and older leaves), and that the app didn't delete itself. A backup
still being written (it has a `.work/<stamp>/` directory, or its run is
`Running`) and one whose History row records the app pruning it here are
never reported. The report comes once, when the sync removes the stale
`.hold`; a `.hold` the app can't remove (a directory, say) is never
reported. When History can't be read, the sync reports nothing and looks
again next time.

What you see:

- **Backups page:** a yellow warning under the headline, one sentence per
  backup directory: "On 2026-11-16 03:30 UTC, a backup a schedule keeps was
  deleted outside the app: Database backup of 2026-07-01 03:17 UTC." (or "…,
  3 backups a schedule keeps were deleted outside the app: …", naming up to
  ten, then "and N more"), followed by "This usually means the host's
  scripts/backup.sh is older than this release and ignores .hold markers.
  Replace it with this release's copy." and an **About the hold markers**
  link. The date at the start is when the sync found it. It doesn't turn the
  headline red: the backups themselves still run.
- **Schedule tab:** the same warning in the box above the schedule list.
- **Not on Home.**
- **Server log**, at warning level: "1 backup(s) a schedule keeps were
  deleted outside the app although their .hold markers kept them: db backup
  20260701-031700. The host's scripts/backup.sh is probably older than this
  release and ignores .hold markers".
- **Telemetry:** `[:kiln_cms, :backups, :hold, :deleted_outside]`, measurements
  `%{count: n}`, metadata `%{dir: dir, scope: :local, units: [%{stamp: stamp, kind: :db | :media}]}`,
  counted as `kiln_cms_backups_hold_deleted_outside_count` when the metrics
  exporter is on ([observability.md](observability.md#backups)).

The warning stays for eight days after the latest detection. A second
detection in the same directory within those eight days joins the first:
the list grows (a backup already listed isn't counted twice), and the date
moves to the newest. There is no dismiss button.

To fix it, as whoever runs the host:

1. Find the cron line that runs `backup.sh` (`/etc/cron.d/kiln-backup` in
   the example at the top of this guide) and note the script's path.
2. Replace that file with `scripts/backup.sh` from this release, on every
   host whose cron prunes this backup directory.
3. Check that the copy knows the holds: `grep -c is_held scripts/backup.sh`
   prints a number above 0 (any copy from 1.10.0 on). An older copy prints
   `0`.
4. List the directory after the next cron run: every `kiln-<stamp>.hold`
   still has its `kiln-db-<stamp>.dump` (or media archive) beside it.

The deleted backups don't come back. If you need one, copy it back from an
off-site destination that still has it, with its `.sha256` file.

### What the cron prune cannot see

`backup.sh` has no database, so it sees some of the rules above only partly:

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
- **It knows what the schedules keep only through the hold markers.** It
  keeps every unit with a `kiln-<stamp>.hold` in its own directory, and
  otherwise ages by `BACKUP_KEEP_DAYS`. Where a schedule keeps its own
  backups for fewer days than `BACKUP_KEEP_DAYS`, cron keeps them longer than
  the app does, never shorter. A host whose copy of `backup.sh` predates the
  hold marker deletes what a schedule keeps past `BACKUP_KEEP_DAYS`
  ([The hold markers](#the-hold-markers)).
- **It cannot see an in-app backup that is `Running`.** It relies on that
  backup's `.work/<stamp>/` directory and `.partial` files instead.

It never deletes strays, other than a file kept after a refusal, and never
deletes a `.keep`, `.good` or `.hold` marker.

### When retention is skipped or stops

Retention fails closed: when it cannot see everything its rules need, it deletes
nothing. The backup itself is not affected either way; it succeeds or fails on
its own files and off-site copy.

**In the app**, retention is skipped when importing cron's backups into History
fails, when `db/`, `media/` or `.work/` cannot be listed, when a file in them
cannot be read, or when History cannot be read. It writes an error to the
server log ("Backup retention skipped: …; nothing was deleted"), emits the
`[:kiln_cms, :backups, :retention, :skipped]` telemetry event (measurements
`%{count: 1}`, metadata `%{scope: :local, reason: reason}`), and adds a
`prune` line at error level to the run's log in the database:

```text
Retention skipped: couldn't read the backup history (Ash.Error.Forbidden); nothing was deleted
```

Other reasons in the same place: `couldn't import cron-made backups into the
backup history (…)`, `couldn't list media/ in the backup directory (…)`,
`couldn't read <file> (…)`, `couldn't read the backup schedules (…)`, and `the
retention policy is invalid (BACKUP_KEEP_DAYS must be a whole number of days,
1 or more)`. The schedules are read as the backup system actor and a refused
read is an error, never "no schedules": a prune that missed a schedule's keep
count would delete what it keeps.

Right before each unit goes, the app looks again: a unit that has gained a
`.work/<stamp>/` directory or a recovery-point marker, whose run is now `Running`, or whose run
cannot be read is left in place. A file that cannot be removed stops that unit,
so its sidecar stays. If the deleting itself breaks off, the run's log reads
"Retention removed 2 file(s) from 1 backup(s), then stopped: …", the server log
has the error, and `[:kiln_cms, :backups, :retention, :stopped]` is emitted
(measurements `%{count: 1, deleted: n}`, metadata `%{scope: :local, reason: reason}`).
The files already removed are still
marked `pruned` in History. A normal sweep logs "Retention removed N file(s)
from M backup(s)".

Retention on a stored destination emits the same two events, with metadata
`%{scope: :destination, destination: "dest:<id>", reason: reason}`
([Retention on a destination](#retention-on-a-destination)). Until #2487 they
were local only; a handler that should count only the local directory
matches on `scope: :local`. With the metrics exporter on, they are counted
as `kiln_cms_backups_retention_skipped_count` and
`kiln_cms_backups_retention_stopped_count`, labeled `scope`
([observability.md](observability.md#backups)).

**Where it shows.** A skipped or stopped retention leaves every backup
`Succeeded`, so it would otherwise be found only in the run's log, after the
disk fills. Each place where it happened (this backup directory, or a stored
destination) adds a line to the headline of the **Backups** page, which
turns red, and raises the red backup strip on **Home** for platform admins,
with the same line:

- "Retention was skipped on the backup of 2026-11-16 02:00 UTC: couldn't
  read the backup history (Ash.Error.Forbidden). Nothing was deleted, so
  local backups will build up until this is fixed."
- "Retention stopped part-way on the backup of 2026-11-16 02:00 UTC: … What
  it hadn't reached stays until this is fixed."
- "Retention on NAS was skipped on the backup of 2026-11-16 02:00 UTC: …
  Nothing was deleted there, so backups will build up there until this is
  fixed." (and "Retention on NAS stopped part-way …")

The date is the backup whose prune it was. The reason is the run log's, in
English whatever the interface language. When more than one backup
directory has a line (a cluster whose nodes back up to their own disks),
each local line ends with "(backup directory 3f2a9c1e)", the first eight
characters of the directory's `.kiln-dir-id`. On the Backups page the lines
are followed by a **Why retention skips** link to this section.

A line goes away:

- **Local:** after the next in-app backup whose retention runs cleanly in
  that directory. Nothing else clears it: a cron prune, a marker sync, or a
  retention dry run from the console doesn't. It is also left out while no
  live node (a backup heartbeat in the last day, or the node reading the
  status) reports that directory's id, so a directory nobody backs up to any
  more doesn't keep the alarm on. A directory without an id is always
  shown.
- **Destination:** after a clean pass there, or when retention there is
  off: its **Delete its old backups (retention)** box unticked, or an
  adapter that can't list and delete. It is left out at once when the
  destination is disabled or deleted.

If the status can't read the heartbeats or the destinations to decide that,
the lines are shown anyway. If it can't read the warnings themselves, it
shows none. Either failure emits
`[:kiln_cms, :backups, :status, :notices_unreadable]` (measurements
`%{count: 1}`, metadata `error`, the error's module) and logs "Backup status
may leave out a retention or held-backup notice: a read failed (…)" at most
once every 15 minutes. Recording a warning never changes a backup's outcome:
when the write fails, the run's log and the events above still say it, and
the server logs "Backup notice not recorded (retention): …" with
`[:kiln_cms, :backups, :notice, :failed]` (metadata `kind`).

To clear the warning, as a platform admin:

1. Read the reason in the line. It names what retention couldn't do, and
   the list above says what each reason means.
2. Fix it: restore the database grant, the directory permissions, or the
   `BACKUP_KEEP_DAYS` value it names; for a destination, see
   [Retention on a destination](#retention-on-a-destination).
3. On **Backups**, click **Back up now** (or wait for the next scheduled
   backup). When it succeeds, the line is gone from the Backups page and
   Home. If it comes back, retention failed again: the line names the new
   backup's date.

Why these warnings are stored as their own rows rather than read from the
run's log or the security log:
[ADR 0066](decisions/0066-an-operator-facing-backup-problem-is-a-notice-row-not-a-run-log-line-or-a-security-event.md).

**In cron**, `backup.sh prune` prints a `warning:` line on stderr, deletes
nothing and exits 0 (so `backup.sh all` still succeeds) when `db/`, `media/` or
`.work` exists but cannot be listed, or when this host's `date` supports neither
GNU `date -d @N` nor BSD `date -r N`. A unit whose `.partial` files it cannot
look for is kept, and a file it cannot remove stops that unit. Read the cron
log for these: no ping or exit code reports them, and the Backups page and
Home don't show them either.

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
last attempt failed, when one has been backed up and
the other never has, when the last backup reached only some of its
destinations, or when retention was skipped or stopped part-way
([When retention is skipped or stops](#when-retention-is-skipped-or-stops)); a neutral "Backups aren't set up yet" strip when neither
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
     The **Alarm thresholds** section shows each component's threshold and
     where it came from.
   - "Last backup was 2 days ago": its last good backup is older than that.
   - "The last backup failed": the newest attempt that covered it failed.
   - "No backup has ever been recorded": neither History nor the manifest has
     one.
3. The panel's border and icon turn to the alarm when any line is failed or
   stale: a fresh database backup does not make stale media fine. A
   partly off-site backup and a retention warning add lines of their own
   and turn it too
   ([When a backup reaches only some destinations](#when-a-backup-reaches-only-some-destinations),
   [When retention is skipped or stops](#when-retention-is-skipped-or-stops)). The file
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
`$BACKUP_DIR`, uses the same `.partial`-then-rename discipline (the app's
temporary names also carry its step's job and attempt,
[below](#temporary-files-and-the-trash-directories)), and verifies with
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
accepts either shape. A glob such as `kiln-media-*.tar.gz` already matches the
`.partNN.tar.gz` names. What it leaves out is the checksum sidecar,
`kiln-media-<stamp>.sha256` (and `kiln-db-*.dump` leaves out
`kiln-db-<stamp>.sha256`). Without its sidecar a part set does not restore by
default ([below](#restore-a-media-set-that-has-several-parts)), and a dump
cannot be checked. So an rclone filter, a monitoring script or a retention job
of yours must take the sidecars too:

```bash
rclone copy /var/backups/kiln/media r2:kiln-backups/media \
  --include "kiln-media-*.tar.gz" --include "kiln-media-*.sha256"
rclone copy /var/backups/kiln/db r2:kiln-backups/db \
  --include "kiln-db-*.dump" --include "kiln-db-*.sha256"
```

Don't widen it to `kiln-media-*`: that also copies a running backup's
`.partial` files (and a killed one's), and `restore.sh` refuses a set with one
beside it. The Backups page says the same in the `?` beside **Where backups
go** (**About copying backups**): "If you copy backups off this host yourself,
copy each backup's .sha256 files with it: without them a media backup in parts
won't restore, and nothing can check the others. The built-in off-site copy
already includes them." `BACKUP_RCLONE_REMOTE` copies every sidecar, so the
hint is for copies you make yourself. Why the two writers split media the same way is in [ADR 0042](decisions/0042-backup-sh-re-implements-the-media-planner-in-bash-and-both-change-in-the-same-pull-request.md).

The one difference is recovery. A failed in-app backup keeps its finished parts
so it can be [resumed](#media-backups-in-parts-2218); a failed cron run removes
the parts it wrote and keeps nothing to resume ([below](#cron-backups-in-parts)).

That constraint is why the app shells out to `pg_dump` and `tar` rather than
implementing them in Elixir: a hand-rolled export would be a second format
with a second restore procedure, and the restore path is where a backup system
earns its keep.

### Temporary files and the trash directories

Every file a backup writes goes to a temporary name first and is renamed into
place once it is complete, so nothing half-written ever carries a real
backup's name. The two writers name their temporary files differently:

- **`backup.sh`** writes `<name>.partial`, as it always has:
  `db/kiln-db-20261117-031700.dump.partial`. Its manifest is the exception:
  it goes to `manifest.json.<pid>-<random>.partial`
  (`manifest.json.48211-117342.partial`), where `<random>` is between 100000
  and 132767 (#2832). The script creates that file only if the name is
  free, and picks another number if it is taken.
- **An in-app backup step** writes `<name>.<job>-<attempt>.partial`, where
  `<job>` is the step's Oban job id and `<attempt>` its attempt (#2819):
  `db/kiln-db-20261117-031700.dump.48211-2.partial`,
  `media/kiln-media-20261117-031700.part02.tar.gz.48211-2.partial`,
  `media/kiln-media-20261117-031700.sha256.48211-2.partial`. The same tag is on
  the files in `.work/<stamp>/` (`state.json.48211-2.partial`,
  `plan.json.48211-2.partial`, the media file lists `part01.48211-2.list` and
  `part01.48211-2.run.list`) and on `manifest.json.48211-2.partial` at the top
  of `BACKUP_DIR`.
- **A manifest the app writes without a step**, the failure manifest of an
  interrupted backup recorded from outside its step, goes to
  `manifest.json.<random digits>.partial` (#2832).

**No two writers share a manifest temporary name.** A cron run and an
in-app backup that finish at the same moment each write their own file and
rename it over `manifest.json`, so `manifest.json` is always one writer's
complete file, the one that renamed last. Before #2832 both wrote
`manifest.json.partial`, and could publish a mix of the two. The random and
`<pid>-<random>` names keep writers apart; they fence nothing, since cron
takes no lock.

A manifest temporary file is renamed a moment after it is written, so one
left at the top of `BACKUP_DIR` belongs to a writer stopped in between. Once
it is more than 60 minutes old, the start of the next in-app backup and
`backup.sh prune` (which also runs at the end of every `backup.sh all` that
succeeds) both remove it. They remove only `manifest.json.<digits>.partial`
and `manifest.json.<digits>-<digits>.partial`. The plain
`manifest.json.partial` that an older `backup.sh` writes is never removed by
either; delete one by hand once no older script is running.

The same two remove a `.kiln-dir-id.<uuid>.tmp` at the top of `BACKUP_DIR`
once it is more than 60 minutes old (#2849). The app writes the
[backup-directory id](#several-nodes-and-the-backup-lock) to that name and
links it to `.kiln-dir-id` a moment later, so one that old was left by a node
stopped in between. Nothing reads it. `backup.sh` never writes one, but a
host that backs up only with cron gets them from each node's heartbeat, which
is why `backup.sh prune` removes them too and prints each one it removes.
Both remove only regular files with exactly that name (a lowercase UUID);
`prune` keeps a file whose age it can't read, with a warning.

A step writes, checks (`pg_restore --list`, `tar -tzf`) and hashes its file
under that name, outside the backup lock. Only the rename into place runs
under the lock, and only while the step still holds the backup
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)). So
two steps of the same backup, a resume and a step that outlived its Cancel,
never write the same file, and the one that lost the lock can't rename its
file over the resume's. Why is in
[ADR 0067](decisions/0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md).

Every reader takes both shapes as the same thing, a file still being written:
retention's "in flight" rule, the importer, History, the start step's sweep,
`backup.sh prune` and `verify`, and `restore.sh`. A media part or dump that
fails on every attempt leaves a file already under its final name (from an
earlier attempt) as it was, which can leave it without a matching sidecar.
Nothing trusts such a file: a resume reuses a file only when its hash matches
the one recorded in `state.json`, and retention deletes the incomplete unit
once it ages out.

**Deleting goes through a trash directory.** When a step has to delete
something of the backup's (a leftover `.work/<stamp>/` at a fresh start, an
earlier plan's media files under the same stamp, the work directory at the
end, a dump whose sidecar couldn't be written), it moves it aside into a trash
directory with one rename under the lock, and deletes it after the lock is
released. The trash is on the same file system as what it holds, because a
rename can't cross one:

| Moved from | Into |
|---|---|
| `.work/<stamp>/` | `.work/.trash/<stamp>.<job>-<attempt>.work/` |
| a file in `db/` | `db/.kiln-trash/<stamp>.<job>-<attempt>.db/` |
| a file in `media/` | `media/.kiln-trash/<stamp>.<job>-<attempt>.media/` |

These directories are normally empty. An entry stays only when a node stopped
between moving something aside and deleting it, and the start of the next
in-app backup removes it, whatever its age. The `.kiln-trash` directories
themselves stay once created. Retention, the importer, History, `backup.sh`
and `restore.sh` never look inside them. If a rename fails because the file
is on another file system after all (a single file bind-mounted on its own),
the step deletes that file in place, under the lock.

**During a rolling upgrade**, update `scripts/backup.sh` on the host in the
same rollout. A node still on an older release, or an older `backup.sh`, does
not recognize a tagged name:

- its retention and importer don't count it as in flight, and its start-step
  sweep removes it as an unrecognized `.partial` once it is an hour old. The
  backup it belongs to is still protected by its `.work/<stamp>/` directory;
- an older `backup.sh prune` neither counts nor removes it;
- History on an older node can show a media set as complete while one of its
  parts is being rebuilt under a tagged name (display only);
- an older node that plans the media removes the tagged file lists of an
  earlier plan, which nothing needs once its own `plan.json` replaces them;
- after a rollback, an older node reads a `plan.json` that names tagged lists,
  and uses them as it would any list.

### Which database URL the backup tools accept (#2719)

`pg_dump`, `pg_restore` and `psql` read a connection string as a URL only
when it starts with `postgres://` or `postgresql://`, in lower case. Kiln
documents `DATABASE_URL` as `ecto://…`, so every Kiln path that hands a URL to
them rewrites a leading `ecto://` (in any case) to `postgres://` first, and
lower-cases a `POSTGRES://` or `PostgreSQL://` scheme:

| Path | Reads |
|---|---|
| In-app backup | `BACKUP_DATABASE_URL`, else `DATABASE_URL` when it names the database the app is connected to, else a URL rebuilt from the Repo |
| [Demo reset](demo-mode.md) | the same URL as the in-app backup |
| `scripts/backup.sh` | `DATABASE_URL` |
| `scripts/restore.sh` | `RESTORE_DATABASE_URL` |
| `scripts/staging.sh` | `PROD_DATABASE_URL`, `STAGING_DATABASE_URL` |

So `ecto://`, `postgres://` and `postgresql://` all work, and the host part
(several hosts, an IPv6 `[::1]`) reaches libpq as you wrote it.

**The query parameters only Ecto reads are translated (#2833).** libpq
refuses any parameter it doesn't know, by name
(`pg_dump: error: invalid URI query parameter: "pool_size"`), so before a URL
reaches the tools, every path above changes the ones Ecto itself defines.
Keys and values are compared after percent-decoding, as both Ecto and libpq
decode them (`%73sl=%66alse` is `ssl=false`):

| In the URL | What the tools get | Why |
|---|---|---|
| `ssl=false` | `sslmode=disable`, in the same place | Ecto reads it as "no TLS" for the app's own connection, whatever `DATABASE_SSL` says, so the tools connect the same way |
| `pool_size`, `timeout`, `idle_interval` | dropped (and a `?` left with nothing after it) | Ecto's pool settings; none changes which server is reached or how securely |
| `ssl=true` | kept: libpq reads it as `sslmode=require` | but see [How the backup tools choose TLS](#how-the-backup-tools-choose-tls-2830): when the app verifies the server, it is replaced by the stronger mode |
| anything else | kept as written | |

```text
ecto://kiln:…@db/kiln_prod?ssl=false&pool_size=10   →   postgres://kiln@db/kiln_prod?sslmode=disable
```

Anything else libpq doesn't know still fails by name. That includes
`ssl=1` and `ssl=FALSE` (Ecto reads neither as `false`) and Ecto's
`socket_dir`, which is kept on purpose: it decides which server the app
reaches, and dropping it would point the dump at another one. For a socket,
write libpq's form, `postgres:///kiln_prod?host=/run/postgresql`, in
`BACKUP_DATABASE_URL` (in-app) or in `DATABASE_URL` on the cron line.

Only the URL given to the tools is translated. `restore.sh drill` and
`staging.sh up` still print the URL as you wrote it (password removed), and
`staging.sh` hands `STAGING_DATABASE_URL` to the app's migrate and scrub
commands untranslated: Ecto reads `ssl=false` and `pool_size` itself there.

**A `key=value` connection string is accepted only without a password
(#2831).** A string that is not a `postgres://` or `postgresql://` URL after
the scheme rewrite is passed through unchanged when it carries no secret, and
refused before any tool runs when it does:

| String | Result |
|---|---|
| `host=/run/postgresql dbname=kiln_prod` | passed through as written |
| `kiln_prod` (a bare database name) | passed through as written |
| `host=db password=hunter2 dbname=kiln` | refused |
| `host=db sslpassword=… dbname=kiln` | refused |
| `host=db PASSWORD=hunter2 dbname=kiln` (any case) | refused |
| `dbname='postgres://kiln:hunter2@db/kiln'` | refused (libpq would expand it into that URL) |
| `mysql://u:pw@h/db`, or a URL with a leading space | refused (contains `://` but is not a URL libpq reads) |

The reason: libpq's `key=value` syntax (quoting, backslash escapes, a
`dbname` that is itself a URL) can't be rewritten safely, so a password in
it would sit in the tool's command line for the whole dump, and libpq
echoes an unreadable string back in its errors. `password` and `sslpassword`
are refused in any case (`PASSWORD=`, `Password=`). libpq reads only the
lower-case keywords and would refuse another case itself, but only after the
tool had started with the value in its command line, where execve auditing,
process accounting and EDR agents record it. A refused string fails with:

```text
BACKUP_DATABASE_URL (or DATABASE_URL) is not a postgres:// URL and holds a password or another URL, which would sit in the command line of pg_dump, pg_restore and psql for every process on the host to read. Write it as a postgres:// URL, password included (postgres:///database?host=/socket/dir for a Unix socket), or put the password in PGPASSWORD or ~/.pgpass.
```

The scripts print the same sentence after `error: DATABASE_URL`,
`RESTORE_DATABASE_URL`, `PROD_DATABASE_URL` or `STAGING_DATABASE_URL`, and
`backup.sh all` records it in the failure manifest. In the app, the backup
fails at once (no retry), and a demo reset or golden capture fails with it.
Rewrite the string as a URL, password included:

```bash
# was: host=/run/postgresql user=kiln password=hunter2 dbname=kiln_prod
BACKUP_DATABASE_URL=postgres://kiln:hunter2@/kiln_prod?host=/run/postgresql
```

**A URL with `sslpassword` is refused (#3049).** `sslpassword` is the
passphrase of an encrypted client key (`sslkey`). Unlike the password, libpq
has no environment variable for it, so the only way to hand it to `pg_dump`,
`pg_restore` or `psql` is the command line, where every process on the host
can read it. A `postgres://`, `postgresql://` or `ecto://` URL whose query
carries `sslpassword=` (also when the name is escaped, `sslpass%77ord=`, and
also when it is empty) is refused before any tool runs, on every path above,
with:

```text
BACKUP_DATABASE_URL (or DATABASE_URL) carries sslpassword, the passphrase of an encrypted client key, which would sit in the command line of pg_dump, pg_restore and psql for every process on the host to read (libpq has no environment variable for it). Use a client key file that is not encrypted, readable only by its owner (chmod 0600), or decrypt the one you have (openssl pkey -in client.key -out client.key.plain), and drop sslpassword from the URL.
```

The scripts print it after their own variable's name, as above. To fix it,
point `sslkey` at a key that is not encrypted and readable only by the user
the tools run as:

```bash
openssl pkey -in client.key -out client.key.plain   # asks for the passphrase once
chmod 0600 client.key.plain
# was: postgres://kiln@db/kiln_prod?sslmode=verify-full&sslkey=/etc/kiln/client.key&sslpassword=…
BACKUP_DATABASE_URL=postgres://kiln@db/kiln_prod?sslmode=verify-full&sslkey=/etc/kiln/client.key.plain
```

Every spelling is refused: `SSLPASSWORD=`, `SslPassword=` and an escaped
`%53slPassword=` as well. libpq reads only `sslpassword` and would refuse the
others by name, but only after the tool had started with the value in its
command line, where execve auditing, process accounting and EDR agents
record it. No URL that works is refused.

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
| `host=db password=hunter2 dbname=kiln` | refused, nothing runs ([above](#which-database-url-the-backup-tools-accept-2719)) | |
| `postgres://kiln@db/kiln?sslkey=/k.key&sslpassword=…` | refused, nothing runs ([above](#which-database-url-the-backup-tools-accept-2719)) | |
| `postgres://kiln@db/kiln?PASSWORD=hunter2` (any spelling but `password`) | refused, nothing runs: libpq doesn't read it, so it can't be moved; write `password` | |

The URL is split where libpq splits it:

- **The user and password end at the first `@` before the first `/`.** Write an
  `@` in the password as `%40`: `postgres://u:p@ss@h/db` gives the password
  `p`. A `?` or `#` before that `@` is part of the password.
- **Percent-escapes in the password are decoded** (`%40` is `@`, `%25` is `%`);
  `+` stays a `+`, and a malformed escape such as `%zz` stays as written.
- **A `password=` query parameter is moved too**, also when its name is
  escaped (`pass%77ord=`). With a password in both places, the query one
  wins, as in libpq. Only the lower-case name is: libpq reads no other, so
  `PASSWORD=` or `Password=` is refused (#3049).
- **A URL without a password** (or with an empty one, `kiln:@db`) keeps its
  user part as written (only the scheme and Ecto's query parameters change),
  so your own `PGPASSWORD` or `~/.pgpass` decides.
- **A `key=value` string with a password is refused** (#2831), and one
  without is passed as it is. Use a URL.
- **A URL with `sslpassword` is refused** (#3049): libpq can't read a client
  key's passphrase from the environment. Use a key that is not encrypted.

The scripts don't print it either. `restore.sh drill` suggests a
`STAGING_DATABASE_URL=… ./scripts/staging.sh scrub` line with the password
removed, and `staging.sh up` prints the staging `DATABASE_URL=` the same way;
both say "password not shown". Put the password back in the URL, or export
`PGPASSWORD`, before using them.

### How the backup tools choose TLS (#2830)

The app's own database connection is encrypted unless `DATABASE_SSL` is off,
and verifies the server when `DATABASE_SSL_CACERTFILE` is set
([database TLS](environment-variables.md#database-tls)). libpq's default is
weaker: `sslmode=prefer` falls back to cleartext without a word when TLS
fails, and never checks the certificate. So the in-app backup and the demo
reset and golden capture give `pg_dump` and `psql` a `PGSSLMODE` (and
sometimes `PGSSLROOTCERT`) that matches the app's connection, in their own
environment only:

| The app connects with | The tools get |
|---|---|
| `DATABASE_SSL` off (or `ssl=false` in the URL the app reads) | nothing: libpq's default (`prefer`) |
| `DATABASE_SSL` on (the default), no `DATABASE_SSL_CACERTFILE` | `PGSSLMODE=require`: encrypted, certificate not checked, as the app does |
| `DATABASE_SSL` on with `DATABASE_SSL_CACERTFILE=/path/ca.pem` | `PGSSLMODE=verify-full`, `PGSSLROOTCERT=/path/ca.pem` |
| any other configuration that verifies the server (`ssl: true`, `cacerts`, set in code) | `PGSSLMODE=verify-full`, `PGSSLROOTCERT=system` (the system trust store; libpq 16 or later) |

The rule follows the Repo's effective `:ssl` option, after Ecto has merged
the URL's own `ssl=` into it, so it cannot disagree with the connection the
app is actually using.

**Your explicit choice wins, even a weaker one.** Nothing is added when:

- the URL has `sslmode=` or `requiressl=` in its query
  (`?sslmode=verify-full&sslrootcert=/etc/kiln/ca.pem`), or
- `PGSSLMODE` is set, and not blank, in the app's environment (the tools
  inherit it).

That is by design: it lets you reach a backup host the app's settings don't
fit (a replica over a private network, a cert issued to a different name).
It also means `?sslmode=disable`, or `PGSSLMODE=prefer`, makes the backup
weaker than the app, and Kiln does not warn about it.

Two settings are **not** treated as that choice, because neither alone makes
libpq require TLS:

- **A root certificate alone** (`sslrootcert=` in the URL, or a non-blank
  `PGSSLROOTCERT` in the environment). Your certificate is kept and no
  `PGSSLROOTCERT` is added; `PGSSLMODE` is still set to the mode in the
  table, except that `require` becomes `verify-full` when the certificate is
  `system` (libpq refuses `system` with a weaker mode).
- **Ecto's `ssl=true` in the URL.** libpq reads it as `sslmode=require`.
  When the app only requires TLS, it stays and nothing is added. When the
  app verifies the server, `ssl=true` is removed from the tools' URL and
  `PGSSLMODE=verify-full` applies, so the backup is never weaker than the
  app.

A Unix-socket connection is unaffected: libpq does not use TLS over a
socket, whatever `PGSSLMODE` says.

**What can now fail, and the fix.** With `DATABASE_SSL` on (the default),
an in-app backup now requires TLS where it used to fall back to cleartext:

- `BACKUP_DATABASE_URL` points at another server that offers no TLS: the
  run fails with `pg_dump exited 1: … server does not support SSL, but SSL
  was required`. Add `?sslmode=disable` (or `prefer`) to that URL if the
  link is private, or enable TLS on that server.
- With `DATABASE_SSL_CACERTFILE` set, `BACKUP_DATABASE_URL` names a host the
  certificate doesn't list (an IP address, an internal alias): libpq's
  `verify-full` checks the name in that URL. Use a name on the
  certificate, or set `?sslmode=verify-ca&sslrootcert=/path/ca.pem` to
  check the chain without the name.
- `DATABASE_SSL_CACERTFILE` holds only an intermediate CA. The app's
  connection accepts a chain that ends at it; libpq needs the root
  certificate too. Put the root (and the intermediate) in the file.

**Cron and the other scripts don't read `DATABASE_SSL`.** `backup.sh`,
`restore.sh` and `staging.sh` run outside the app, and a cron line can't see
the app's `DATABASE_SSL`, so they add no TLS settings of their own. Put the
mode in the URL itself:

```cron
17 3 * * * kiln  DATABASE_URL='postgres://kiln:…@db.example.com/kiln_prod?sslmode=verify-full&sslrootcert=/etc/kiln/ca.pem' \
  BACKUP_DIR=/var/backups/kiln \
  /opt/kiln_cms/scripts/backup.sh all >> /var/log/kiln-backup.log 2>&1
```

(`?sslmode=require` to encrypt without checking the certificate, as the app
does without a CA file.) An exported `PGSSLMODE`/`PGSSLROOTCERT` works too.

### When pg_dump waits for a table lock (#2844)

`pg_dump` takes a shared lock on every table it dumps. A migration,
`VACUUM FULL` or another long transaction holding a conflicting lock used to
make it wait for as long as that lock was held: forever in cron, and up to
the step's 2-hour job timeout in the app. Every `pg_dump` Kiln runs (the
in-app backup, `backup.sh db`/`all`, and the demo golden capture) is now
given `--lock-wait-timeout`, set by `BACKUP_LOCK_WAIT_SECONDS`:

- **Default 600** (10 minutes). Any whole number of seconds from 1 to 3600.
  Anything else (`0`, `10m`, `5000`) keeps 600 and warns: at boot in the
  app, on stderr from `backup.sh`. There is no "wait forever": pg_dump reads
  `0` that way, so it is refused.
- **It applies to each `LOCK TABLE`** separately. A dump blocked on several
  tables in turn can wait several times the value.
- **Set it for both paths**, in the app's environment and on the cron line;
  each reads its own copy.
- `pg_restore`, `psql` and `staging.sh` don't take it.

To change it, set the variable and restart the app (or edit the cron line):

```bash
BACKUP_LOCK_WAIT_SECONDS=120
```

**What a lock timeout looks like.** pg_dump implements the option as a
statement timeout around each `LOCK TABLE`, so its own words don't mention a
lock. Kiln recognizes that pair and records:

```text
pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS (600 s) for a table lock and gave up: another session held a conflicting lock (a migration, VACUUM FULL, a long transaction). pg_dump said: pg_dump: error: query failed: ERROR:  canceling statement due to statement timeout / pg_dump: detail: Query was: LOCK TABLE public.pages IN ACCESS SHARE MODE
```

(That is the cron manifest's form, one line. The app keeps pg_dump's line
break where the ` / ` is.)

In the app, this is the dump step's error in the run's log, and the step is
retried like any failed dump (after 1, 5 and 15 minutes); the run's error
when it fails for good. From cron, `backup.sh all` writes it to the failure
manifest, which the Backups page shows under **Last run failed**: the last
five lines of pg_dump's stderr, newlines joined with ` / `, a URL password of
6 or more characters replaced with `***`, cut to 500 characters. Any other
`pg_dump` failure is recorded the same way, as `pg_dump exited <status>:
<its last lines>`, where the manifest used to say only `backup.sh exited
<status> - see the backup log`. pg_dump's full stderr is still in the log.

Find what holds the lock with `pg_locks` joined to `pg_stat_activity`, and
schedule backups away from migrations and maintenance windows.

### How an in-app backup runs (#2218)

An in-app backup is a chain of Oban jobs, one per step, on the `backup_steps`
queue, or, for the steps that must run where the backup's files are, on the
queue of its backup directory, `backup_dir_<id>`
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)):

**start** → **dump** → **plan** → **archive** (one job per media part) →
**checksum** → **prune** → **offsite** (one job per off-site destination) →
**finish**

`dump` runs only when the backup covers the database, and `plan`, `archive` and
`checksum` only when it covers the media and there is a media directory; a step
with nothing to do hands straight over to the next one that has
([Back up only the database or only the media](#back-up-only-the-database-or-only-the-media)).
Each step reads what the previous ones did from `.work/<stamp>/state.json`, does its
own work and hands over to the next. A failure therefore costs one step, not the
whole backup: a database dump that verified is not taken again because the
fourth media part failed.

**Off-site, one destination at a time (#2220).** The start step settles where
the backup is sent: `BACKUP_RCLONE_REMOTE` first, when it is set, then each
enabled destination on the **Destinations** tab, in that tab's order
([Send backups to several destinations](#send-backups-to-several-destinations)).
`offsite` then runs once per destination, each with its own attempts. A
destination that still fails on its last attempt is recorded failed and the
backup moves on to the next one; the backup fails only when it reached none
of them, and succeeds **partly off-site** when it reached some
([When a backup reaches only some destinations](#when-a-backup-reaches-only-some-destinations)).
With `BACKUP_RCLONE_REMOTE` as the only destination, nothing about this step
changed: the same `rclone copy` commands, log lines and errors as before.

**One at a time, cluster-wide.** A lock in the database (one row in
`backup_locks`) lets one chain run at a time across every node. A backup asked
for while one runs waits behind it ([below](#back-up-while-another-backup-runs)).

**Retries.** Each step has four attempts, 1, 5 and 15 minutes apart, and at
most 2 hours per attempt. Neither is configurable. The run's log in History
records each failed attempt. After the fourth, the backup fails.

**When a step is interrupted.** A step writes what it did to `state.json`
before it hands over to the next one, so a step that fails, times out or is
[taken back from a stopped node](#several-nodes-and-the-backup-lock) is run
again from what the earlier steps recorded, under the same stamp. A step run
again, whether its first attempt stopped halfway or stopped just after it
wrote `state.json`, reuses what is already done:

- a database dump that verified, once its sha256 and size are checked again
  ("Database dump reused from the original attempt … sha256 re-verified");
- each media part that verified, checked the same way ("Reused N of M media
  part(s) from the original attempt"). A part or a dump that no longer
  matches is rebuilt;
- the media plan, which is frozen when it is first made, so the parts keep
  the same files;
- at each destination, the files this backup already sent there with the same
  sha256.

A step run again after its `state.json` landed lists each file once, in the
manifest, the checksum sidecars and History. (Earlier releases listed that
step's files twice, and the off-site copy then refused the sidecar, "the
checksum file changed after it was written", and failed the backup.)

A finish interrupted after it had closed the run (the run reads `Succeeded`,
or the manifest is already written ok for this stamp) has finished the
backup: its retry, its take-back or the cleanup of its ended job only does
the bookkeeping that is left. It closes a run still `Running` as succeeded,
recording a destination it never got to as failed ("not attempted: its
off-site step never ran"), syncs the
[`.good`](#the-last-good-marker) and [`.hold`](#the-hold-markers) markers,
releases the lock and starts the queued backup. The server log says "Backup
complete … (finished after an interruption)". If the run can't be read, a
retry tries again; when no retry is left, the backup is recorded as
interrupted, as before.

The 2-hour limit is per attempt of one step, and every media part and every
destination is a step of its own. There is no limit on the whole backup: one
with many parts or destinations can run for longer than 2 hours, but a single
part, upload or database dump that needs more fails each attempt.

**Failures a retry cannot fix fail at once**, without spending the remaining
attempts:

| Failure | Error on the run | What to do |
|---|---|---|
| A media part changed on disk between being archived and being checksummed | "Media part(s) changed on disk between being archived and being checksummed: `<names>`. Something other than this backup wrote to the backup directory; Resume rebuilds the changed part(s)." | Find what writes to `BACKUP_DIR`, then **Resume**: it rebuilds only the parts whose hash no longer matches. |
| A file refused before its off-site copy, at any destination | "Off-site copy REFUSED for …" | [When an off-site copy is refused](#when-an-off-site-copy-is-refused). |
| Too little free space for the dump or the media (#2423) | "Not enough free space for the database dump in `<dir>`: 1.1 GB free, about 3.4 GB needed. Free up space there, or point BACKUP_DIR at a larger disk (BACKUP_FREE_SPACE_CHECK=false skips this check)" (or "the media archive", "the media file lists") | Free space on that disk, or move `BACKUP_DIR`, then take a new backup or **Resume**. If the media would fit after compression, set `BACKUP_FREE_SPACE_CHECK=false`. See **Disk space** in [Media backups in parts](#media-backups-in-parts-2218). |
| The work state is gone, or belongs to another backup (except at a finish that had already closed the run, [above](#how-an-in-app-backup-runs-2218)) | "The backup's work state (.work/`<stamp>`/state.json) is missing or belongs to another backup; nothing more can be done for this one" | Take a new backup. No failure manifest is written, so the panel keeps showing the previous backup. |

**When a backup fails**, it writes a failure manifest (when its `state.json`
is there to say what landed), marks the run `Failed`, releases the lock and
starts the queued backup, if there is one. A backup the deployment cannot run
at all (`BACKUP_ENABLED=false`, no `pg_dump` in the image on the node that
picked up the start step) is a `Skipped` row and leaves `manifest.json` alone,
as before.

**Telemetry.** The chain, the heartbeat and the marker sync emit, each with measurements `%{count: 1}`:

| Event | Metadata | When |
|---|---|---|
| `[:kiln_cms, :backups, :chain, :settled]` | `chain`, `stamp`, `outcome` (`:ok` or `{:error, reason}`) | A chain ended: succeeded, failed, canceled or refused at its start. |
| `[:kiln_cms, :backups, :request, :folded]` | `trigger`, `resume`, `components` (the folding request's; `nil` for everything or a resume) | A request folded into the queued one. |
| `[:kiln_cms, :backups, :lock, :reclaimed]` | `chain`, `stamp`, `step`, `node`, `outcome` (`:requeued` or `:interrupted`) | A step was taken back from a node that stopped responding ([below](#several-nodes-and-the-backup-lock)). |
| `[:kiln_cms, :backups, :lock, :stranded]` | `chain`, `stamp`, `step`, `queue`, `outcome` (`:moved_back`, `:returned` or `:interrupted`) | The backup's step had waited in a backup directory's queue that no node runs: moved back to `backup_steps`, or the backup failed ([below](#jobs-left-in-a-directory-queue)). |
| `[:kiln_cms, :backups, :dir_queue, :started]` | `queue`, `node` | A backup directory's queue began running on this node ([below](#which-node-runs-a-step)). |
| `[:kiln_cms, :backups, :dir_queue, :paused]` | `queue`, `node`, `reason` (`:changed`: the directory now has another id; `:gone`: no id for 180 seconds) | This node paused a backup directory's queue. |
| `[:kiln_cms, :backups, :dir_queue, :resumed]` | `queue`, `node` | This node resumed a queue it had paused, because the directory's id came back. |
| `[:kiln_cms, :backups, :dir_queue, :start_failed]` | `queue`, `node` | A backup directory's queue hadn't started on this node three ticks after the first try. Once per queue until it starts. Check Oban's notifier. |
| `[:kiln_cms, :backups, :dir_queue, :routed]` | `queue` (where the job went), `from` (the queue it was in), `worker` | A node without the directory moved a job it fetched into the directory's queue. |
| `[:kiln_cms, :backups, :status, :history_unreadable]` | `error` (the error's module) | The status could not read History and fell back to the manifest ([above](#check-the-last-backup-of-each-component)). |
| `[:kiln_cms, :backups, :offsite, :partial]` | `stamp`, `chain`, `missed` (the keys of the destinations not reached); measurements also `reached` and `total` | A backup finished having reached some of its off-site destinations but not all ([below](#when-a-backup-reaches-only-some-destinations)). |
| `[:kiln_cms, :backups, :heartbeat, :dir_id_timeout]` | `node`; measurements also `waited_ms` | A heartbeat beat with no backup-directory id because reading `.kiln-dir-id` is held up, once per beat while it is ([below](#the-backup-directory-id-read-2848)). |
| `[:kiln_cms, :backups, :marker_sync, :timeout]` | `phase` (`:dir_id` or `:sync`); measurements also `waited_ms` | A last-good marker sync job stopped waiting on the backup directory's id read or sync and gave up for the slot ([below](#the-marker-sync-on-a-hung-backup-directory-3079)). |

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
([When a schedule fires](#when-a-schedule-fires)). The reasoning is in [ADR 0038](decisions/0038-a-backup-asked-for-while-one-runs-queues-and-only-like-folds-into-like.md).

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
that lost the database misses the Cancel, and stops its step only once it
has gone 90 seconds without a successful heartbeat. A resume that started sooner could run
beside that step: its file writes, its prune and each off-site upload it
starts are fenced, but an upload already on its way is not
([below](#what-a-step-that-outlives-its-cancel-can-write)). So for 150 seconds after the Cancel (counted from
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
stops its step later. The backup's files and its History row are protected
from such a step either way: it writes only under temporary names of its own,
and its renames into place are refused (#2819). What still depends on the
window is its off-site copy and its prune
([below](#what-a-step-that-outlives-its-cancel-can-write)).

### Cancel a resume that is waiting to start

A resume holds the backup lock from the moment it is requested, but its
`start` step can wait before it picks the backup up again: up to about an hour
for [the server that has the backup's files](#several-nodes-and-the-backup-lock)
(and up to 30 minutes more if the start was waiting in that directory's
queue when the server stopped,
[Jobs left in a directory queue](#jobs-left-in-a-directory-queue)),
or up to three minutes for a step of the canceled backup to stop
([above](#cancel-a-running-backup)). New and scheduled backups queue behind it
all that time. A platform admin can cancel it (#2816).

1. Open **Backups** (`/editor/backups`) as a platform admin. The in-flight
   strip shows the backup's stamp and what the resume waits for:

   | Strip label | The resume is waiting for |
   |---|---|
   | "Waiting for the server that has this backup's files" | The node whose backup directory the run records or, for a copy of the backup's `.work/<stamp>/` on another host, the source host to stop beating for 180 seconds ([why](#several-nodes-and-the-backup-lock)). Other nodes keep putting the step back, or the start waits in that directory's own queue ([Which node runs a step](#which-node-runs-a-step)). Also shown while a node with a copy waits for the run's row to be readable. |
   | "Waiting for the canceled backup's step to stop" | The window after the backup's Cancel to pass. |
   | "Starting a resume" | Nothing the page can name: its start step is about to run, or is running. |

2. Click **Cancel** on the strip. The History row has no **Cancel** while the
   resume waits; the strip's is the one that stops it.
3. Confirm "Cancel this resume? The backup stays as it was, so it can be
   resumed later." (with "A queued backup will start next." when one is
   waiting).
4. The page says "Resume canceled. The backup stays as it was, so it can be
   resumed later." The strip shows the queued backup, if there was one, or
   disappears.

What happens to the backup:

- The resume's start job is canceled and the lock released, so a queued
  backup starts next.
- The History row keeps its status, `Failed` or `Canceled`, and its
  **Resume** button. Its error reads "Resume canceled by a platform admin
  before it started" above the original error, and its log gains the same
  line. A second canceled or refused resume replaces that line rather than
  adding another. A canceled backup's 150-second wait still counts from its
  original Cancel.
- A row still `Running` from an attempt that stopped (one the resume was
  about to take over) becomes `Failed`, with the same line above
  "Interrupted: the job was killed or the node stopped".
- Nothing on disk changes: `.work/<stamp>/` and the files already written
  stay.
- The instance security log records a **Backup canceled** event with the
  backup's stamp, `step` `start` and `resume` `true`
  ([security-events.md](security-events.md#the-instance-log)). Your email is
  in that event, not on the History row.
- From a console, `KilnCMS.Backups.await(chain)` on the resume's chain
  returns `{:error, :no_run}`: the chain ended without re-opening a run.

What can go wrong:

| Message | Meaning |
|---|---|
| "The resume started meanwhile. Cancel it again to stop the backup." | The resume picked the backup up before your click landed. It is a running backup now; its **Cancel** is on the strip and the row. |
| "The backup changed meanwhile. Try again." | Something else wrote the backup's row between the page loading and the click. The page has been refreshed. |
| "Only a platform admin can cancel a backup." | Your account is no longer a platform admin. |
| "That resume can't be canceled." | Anything else, for example no resume of this backup is waiting any more. |

The same action from a release console, as a platform admin (the backup
system actor is refused):

```bash
bin/kiln_cms rpc 'admin = KilnCMS.Accounts.get_user_by_email!("admin@example.com", authorize?: false); {:ok, run} = KilnCMS.Backups.get_run_by_stamp("20260805-031700", actor: admin); {:ok, run} = KilnCMS.Backups.cancel_run_resume(run, actor: admin); IO.inspect(run.status)'
```

A fresh backup (not a resume) can also wait at its `start` step, for up to
three hours, while a legacy `KilnCMS.Backups.Worker` job still runs on a node
from an older release during an upgrade. The strip shows "Starting a backup"
with no **Cancel**: it has no History row yet. Let the old job finish.

### Several nodes and the backup lock

The lock is held by a step job on some node. If that node stops, its step must
not hold every later backup for ever, and two nodes must never write the same
backup's files at once. Three things keep both true. The reasoning is in [ADR 0039](decisions/0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md).

**A heartbeat on every node.** Every 30 seconds each node writes a beat to
`backup_node_beats`, timed by the database's clock, never the node's. It also
looks at the lock:

- A step on a node with no beat for 180 seconds, or on a node that has
  restarted since it took the step, is taken back: its job is canceled and
  requeued with the attempts it had left, under the same stamp, so it reuses
  every file already finished. The server log says "Backup step `<step>` of
  `<stamp>` was on node `<node>`, which stopped responding: requeued (job
  `<id>`)". With no attempts left the backup fails as "Interrupted: node
  `<node>` stopped responding". A `finish` step taken back stays finishing,
  so **Cancel** is still refused ("Too late to cancel") until it completes
  (#3012). During a rolling upgrade, a node still on an older release that
  takes back a finish step drops that state until the replacement step marks
  it finishing again, and a Cancel in that gap is accepted.
- A step whose job ended without handing over (its last attempt timed out
  after 2 hours, or the job was discarded or deleted) fails the backup as
  "Interrupted: the backup's step job ended without finishing its step", and
  the lock is released.
- Either way, a `finish` step that had already closed the run is completed,
  not failed ([When a step is interrupted](#how-an-in-app-backup-runs-2218)).
- A node with no successful beat for 90 seconds stops its own backup steps
  before the others take them over. That covers a node that lost the
  database, and also one whose heartbeat is stuck, for example on a
  `BACKUP_DIR` mount that hangs (#2848). The stop is made by a watchdog
  process of its own (`KilnCMS.Backups.Fence`) that does no file or database
  work: every 5 seconds it checks how long ago the heartbeat last beat, so it
  fires within 5 seconds of the 90 even while the heartbeat waits on a hung
  directory. The server log says "Backup heartbeat: no successful beat for
  N s; stopping N backup step(s) on this node before another node takes them
  over". It counts from the end of the last successful beat, so a heartbeat
  that is only slow can trip it too: the next beat starts 30 seconds after
  the previous round (beat, sweep and prune) ends, and a round that takes
  more than about a minute stops this node's steps. While no beat succeeds,
  it stops every step that starts on the node, every 5 seconds. If the
  watchdog itself restarts, it counts from its own start.
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
or a platform admin cancels it. The self-fence's watchdog starts only with
the heartbeat.

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
hard links it is created in place with an exclusive create instead.) The
temporary file is `.kiln-dir-id.<uuid>.tmp`, removed a moment after the link;
one left behind by a node stopped in between is removed once it is an hour
old ([Temporary files](#temporary-files-and-the-trash-directories)). Every
step after `start` runs only on a node that reads the same id:

- **One shared volume** mounted on every node: every node reads the same id,
  so any node runs any step.
- **A `BACKUP_DIR` per host**: the backup's steps stay on the host whose
  directory its `start` wrote to. Each host runs an Oban queue named for its
  directory, `backup_dir_<id>`, and only that host fetches from it, so a
  step goes there and no other node picks it up
  ([Which node runs a step](#which-node-runs-a-step), #2845). A step that
  lands in the shared `backup_steps` queue first is moved there by the first
  other node to fetch it, without spending an attempt. Only when no node
  runs the directory's queue (a node on an older release, or Oban's notifier
  down) does the old rule apply: another node that picks up a step waits 30
  seconds and puts it back, up to 20 times (about 10 minutes) per attempt,
  then fails the attempt (`:backup_dir_elsewhere`), which uses one of the
  four. If that host is gone, the backup ends up failed: for a step waiting
  in the directory's queue, once it has waited there 30 minutes and no node
  reports the directory
  ([Jobs left in a directory queue](#jobs-left-in-a-directory-queue)), or,
  for a step taken back from the host or still in `backup_steps`, once its
  attempts have waited (about an hour). Take a new one.
- **A copied backup directory** (restored onto a new host, or cloned) carries
  the old host's id. Delete `.kiln-dir-id` on the copy, or leave it out of the
  copy (`rsync --exclude .kiln-dir-id`), so it gets its own. A backup whose
  `.work/<stamp>/` came along with the copy can be resumed there once the
  host it was copied from has stopped (**A resume runs on the host that holds
  its directory**, below).

Why each step runs where its backup directory is, and the bounded wait, is argued in [ADR 0040](decisions/0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md);
why the directory's own queue replaced that wait, in
[ADR 0070](decisions/0070-a-directory-pinned-backup-job-runs-from-a-queue-named-for-its-directory-which-the-nodes-reporting-it-start.md).

**A resume runs on the host that holds its directory (#2539, #2817).** The
Resume button shows only on a node that can see the backup's `.work/<stamp>/`.
Each run records the id of the directory its files are in (its `dir_id`, set
when it starts and again each time it is resumed). The resume's `start` step
runs on:

1. **The node that reads the run's recorded id** in its `.kiln-dir-id`, files
   or not. If `.work/<stamp>/state.json` is gone from that directory, the
   resume is refused there, visibly: "Resume refused: its work files
   (.work/`<stamp>`/state.json) are not on the server that picked it up".
2. **A node with a readable `.work/<stamp>/state.json` of its own, only when no
   live node reports the recorded id.** Live means a heartbeat in the last
   180 seconds, on the database's clock: the threshold at which a stopped
   node's step is taken back. So a copy of the directory, or one given a new
   `.kiln-dir-id`, resumes only once the host it came from has stopped. The
   resume then records the copy's directory as the run's `dir_id`, and its
   later steps run there.
3. **Nowhere else.** Any other node that picks up the start moves it to the
   queue of the run's directory when a node runs that queue, and otherwise
   waits 30 seconds and puts it back. A run whose directory no running node
   reports keeps this wait, so a copy of the directory can still take the
   start once the source host has stopped.

While the source host runs, the copy waits; the source host takes the start
and either resumes the backup or refuses it as above. A source host whose id
read is held up by a hung mount (beats report no id then, see
[The backup-directory id read](#the-backup-directory-id-read-2848)) still
counts as live: each beat also reports the last id it read, until a read
finds no id file. One gap remains: a source host that restarts and whose
first id read hangs reports no id at all, so a copy elsewhere can resume
while it runs.

The start waits, rather than trust the copy, in three more cases:

- the `state.json` in the copy can't be read or parsed: it counts as no copy;
- the node heartbeats can't be read: the start waits, and logs why;
- the run's own row can't be read on a node with a copy: the start waits
  too, and each attempt that uses up its 20 waits fails with
  `:run_unreadable`. A node with no copy starts the resume anyway, and the
  resume is refused there if the files are not there either.

A run with no recorded id (imported from cron, or last run before #2539) is
resumed by whichever node picks it up, and records an id when it does.

When a node that reads the run's recorded id runs that directory's queue,
the start is moved there and waits for that node, without counting against
the limit below ([Which node runs a step](#which-node-runs-a-step)). Without
one, a node that is not allowed to start the resume puts it back up to 20
times per attempt, like every other step, across the job's four attempts and
the 1-, 5- and 15-minute pauses between them. When the last attempt has
waited too, the resume is given up:

- the lock is released, and a queued backup starts;
- the History row keeps its status and its **Resume** button, and reads
  "Resume refused: no server with its backup directory (id `<id>`) picked it
  up; every attempt waited about 10 minutes for one", above its original
  error. A resume whose run couldn't be read ends instead when the lock's
  reap finds its job gone, and the row reads "Resume refused: Interrupted:
  the backup's step job ended without finishing its step".

That is about an hour in which the resume holds the lock, and a backup asked
for meanwhile [queues behind it](#back-up-while-another-backup-runs): the price of not refusing a resume just
because the wrong nodes happened to pick it up first. Bring the host with the
files back, wait for the give-up, or
[cancel the resume](#cancel-a-resume-that-is-waiting-to-start) to let other
backups run. To resume from a copy while the source host still runs, stop
the app on the source host: the copy can take the start 180 seconds after its
last beat.

**180 seconds here, 10 minutes for the marker sync.** The
[last-good marker sync](#the-last-good-marker) routes to every directory a
node reported in the last 10 minutes (600 seconds). The two windows answer
different questions. The marker sync asks where a sync might still be picked
up, and a host that missed a few beats is worth a sync job that waits for it.
A resume asks whether the source host might still be writing to its copy of
the backup, and that is the question the backup lock answers at 180 seconds,
when it takes a stopped node's step back. A longer window would only keep a
copy waiting after the lock already treats the source host as gone. Routing
a job into a backup directory's queue uses 180 seconds too, for the marker
sync's jobs as well: a directory whose node beat 5 minutes ago still gets a
queued sync, but it waits in `default` on the 30-second put-backs rather
than in a queue no running node may fetch.

**During a rolling deploy** a node still on the previous release keeps the
old rule: a copy of the files there resumes at once, whether or not the
source host is alive. The new rule holds once every node runs this release.

What the server log says:

| Log line | Level | Meaning |
|---|---|---|
| "Backup resume of `<stamp>`: couldn't read the node heartbeats (…); waiting for the server with its backup directory (id `<id>`) rather than resuming from the files here" | warning | This node has a copy of the files but can't tell whether the source host is alive, so it puts the start back. If it lasts, the give-up names the directory id; this line says why no copy took over. |
| "Backup resume of `<stamp>`: couldn't read where its files are (…); waiting rather than resuming from the files here" | warning | The run's row can't be read on a node with a copy, so it puts the start back. Check the database connection. |
| "Backup resume of `<stamp>`: couldn't read where its files are (…); starting it here" | warning | The run's row can't be read on a node with no copy. The start runs, and refuses the resume if the files are missing here too. |

**The lock is a Postgres advisory lock.** Every decision about the chain
(a request, a hand-over, a take-back, a Cancel, a step's rename of a file
into place) runs in
a transaction that first takes `pg_advisory_xact_lock` on one fixed key, then
reads the single row of `backup_locks`. The advisory lock is what keeps two of
them apart; the row records which chain, step and job hold the backup.

**Pool size.** The `backup_steps` queue runs one job at a time on each node,
and so does the node's backup directory queue. If you size `POOL_SIZE` as
the sum of queue limits plus web traffic ([performance.md](performance.md)),
add two. A queue the node has paused, for a directory it no longer reports,
fetches nothing.

**Cron is not locked.** `scripts/backup.sh` runs outside the application and
does not take the lock, so a cron backup and an in-app backup can run at the
same time. They write different stamps; schedule them apart to keep the load
down.

### Which node runs a step

A backup step after `start`, a resume's `start` and the last-good marker
sync's per-directory job must each run on a node that has the backup
directory. Each backup directory has an Oban queue of its own,
`backup_dir_<id>`, named for its [`.kiln-dir-id`](#several-nodes-and-the-backup-lock),
and only the nodes that read that id run it (#2845):

- **Each node's heartbeat starts its directory's queue**, on that node only,
  one job at a time, after a beat that reported the id. Nothing to add to
  Oban's `queues:` list: the queue is started at runtime, and again by the
  first beat after a restart.
- **It advertises the queue once it runs.** The next beat records it in
  `backup_node_beats` (`dir_queue`, with the node's boot id in
  `dir_queue_boot_id`). A brand-new directory is advertised one or two beats,
  30 to 60 seconds, after its id is first read.
- **A job goes to the queue only while a live node advertises it.** Live is
  a beat in the last 180 seconds, on the database's clock, from the boot that
  wrote the advertisement. The chain inserts its next step straight into the
  queue then. A step in `backup_steps` (every `start`, a step taken back from
  a stopped node, or one queued before a node advertised) is moved there by
  the first node without the directory that fetches it: the same job, with no
  attempt spent. The marker sync's per-directory job does the same from
  `default`.
- **Otherwise the job keeps the 30-second put-backs** of earlier releases:
  in `backup_steps` (or `default` for the marker sync), up to 20 per attempt.
  That is what happens while a node on an older release has the directory,
  while Oban's notifier is down (below), and for a resume whose directory no
  running node reports.
- **A queue is paused, never stopped.** When a node's id read gives another
  id (the directory was replaced or remounted), the old directory's queue is
  paused at once. When reads give no id (a hung or missing mount), it is
  paused after 180 seconds. A paused queue lets its running job finish and
  fetches no other; it is resumed when the id comes back. Each beat checks
  the queues it paused and pauses again one that runs.
- **A queue paused by something else stays paused.** The heartbeat resumes
  only a queue it paused itself. One paused by an operator, or by
  `Oban.pause_all_queues(Oban)` (the demo reset uses it), is left paused and not
  advertised, so its jobs take the put-backs until it runs again. The
  heartbeat also counts a queue it finds already paused when it starts as
  paused by someone else, so after the heartbeat process itself crashes and
  restarts, a queue it had paused stays paused until the app restarts on
  that node. Its jobs are moved back to `backup_steps` after 5 minutes
  ([below](#jobs-left-in-a-directory-queue)) and run from there.
- **The marker sync shares the queue**, one job at a time, so a sync for a
  directory can wait behind a long backup step there.

**It needs Oban's notifier.** Starting, pausing and resuming a queue are
signals through Oban's Postgres notifier (`LISTEN`/`NOTIFY`, the
`notifier: Oban.Notifiers.Postgres` in `config/config.exs`). A database
connection that can't hold a `LISTEN`, such as one through a pooler in
transaction mode, never delivers them. The heartbeat checks that the queue
really runs before it advertises it, so nothing is routed to a queue that
didn't start: those jobs take the put-backs, and three beats after the
first try the server log warns once and
`[:kiln_cms, :backups, :dir_queue, :start_failed]` fires.

To switch the queues off and keep every job on the put-backs:
`config :kiln_cms, KilnCMS.Backups, dir_queues?: false`. It defaults to the
heartbeat's own switch, `heartbeat?:`. There is no reason to turn it off
on a working deployment.

What the server log says:

| Log line | Level | Meaning |
|---|---|---|
| "Backup directory queue `backup_dir_<id>`: running on this node" | info | The queue started here. The next beat advertises it. |
| "Backup directory queue `backup_dir_<id>`: paused on this node, whose backup directory now has another id" | info | The node's id read now gives another id. |
| "Backup directory queue `backup_dir_<id>`: paused on this node, whose backup directory has given no id for 180 s" | info | The directory has been unreadable or missing its id for 180 seconds. |
| "Backup directory queue `backup_dir_<id>`: resumed on this node" | info | The id is back. |
| "Backup directory queue `backup_dir_<id>` hasn't started on this node after 3 tries (is Oban's notifier working?). This node doesn't advertise it, so jobs for its backup directory stay in backup_steps and snooze until a node with the directory picks them up." | warning | The start signal hasn't arrived. Once per queue until it starts. Check that the app's database connection can `LISTEN`. |
| "Backup heartbeat couldn't manage its backup directory's queue: …" | warning | Starting, pausing or checking the queue raised. The beat goes out without advertising a queue; the next tick tries again. |

The `[:kiln_cms, :backups, :dir_queue, …]` telemetry events are in the
table under [How an in-app backup runs](#how-an-in-app-backup-runs-2218).

### Jobs left in a directory queue

A job in a backup directory's queue runs only when a node with that
directory runs the queue. Each heartbeat (every 30 seconds) sweeps the jobs
that have waited there 5 minutes or more, judged on the database's clock;
the backup steps are swept before every backup request too:

| What the heartbeats show | After | A backup step | A resume's `start` | A marker sync |
|---|---|---|---|---|
| A live node reports the directory, none advertises its queue (paused, or not started) | 5 minutes in the queue | Moved back to `backup_steps`, same job, due now | Moved back to `backup_steps` | Canceled |
| No node has reported the directory for 180 seconds | 30 minutes in the queue | **The backup fails** (below) | Moved back to `backup_steps`, where the 20 put-backs per attempt decide | Canceled |
| A live node advertises the queue | never | Left: it runs when the queue gets to it | Left | Left |

A node reports a directory through its beat's current id or the last id its
read gave, so a host whose `BACKUP_DIR` mount is only stuck still counts.

A backup that fails this way has its step's job canceled, the lock released
and the queued backup, if any, started. Its History row is `Failed` with
"Interrupted: no server with its backup directory (id `<id>`) picked up the
`<step>` step for 30 minutes". Bring the host back and **Resume** it, or take
a new backup. A step job left in a directory queue after its backup moved on
is canceled in either of the first two rows.

What the server log says:

| Log line | Level | Meaning |
|---|---|---|
| "Backup step `<step>` of `<stamp>` waited 30 minutes for a server with its backup directory (id `<id>`), and none is running: the backup failed and the lock was released" | error | The second row, for a step. |
| "Backup step `<step>` of `<stamp>` moved back to backup_steps: the servers with its backup directory (id `<id>`) don't run its queue" | warning | The first row ("of a starting backup" for a resume's start). Look for a paused queue, or the start warning above, on the node with that directory. |
| "Backup step start of a starting backup moved back to backup_steps: no server with its backup directory (id `<id>`) is running" | warning | The second row, for a resume's start (which has no stamp of its own on the lock until it runs). |
| "Backup step job `<id>` was left in `backup_dir_<id>` after its backup moved on: canceled" | warning | A stray job, cleaned up. |
| "Backup stranded-step sweep skipped: couldn't read the node heartbeats (…)" | warning | Nothing was moved or failed this time; the next sweep tries again. |
| "Backup stranded-step sweep failed: …" | warning | The sweep raised; the next one tries again. |
| "Backup last-good marker sync for backup directory `<id>` gave up: no node with that directory picked it up" | warning | A marker sync was canceled, once per directory per sweep. The next slot queues another. |
| "Backup heartbeat couldn't sweep the stranded marker syncs: …" | warning | The marker sync sweep raised; the next tick tries again. |

Each moved-back or failed backup step also emits
`[:kiln_cms, :backups, :lock, :stranded]` (`outcome` `:moved_back`,
`:returned` or `:interrupted`).

### Rolling back past backup directory queues

A release from before #2845 never runs a `backup_dir_<id>` queue. A step
waiting in one when you roll back never runs there, and that release
neither takes it back (it takes back only a running step) nor fails the
backup (its job hasn't ended), so the backup holds the lock, and every
backup queued behind it, until a platform admin cancels it.

**Before rolling back, cancel the running backup or let it finish.**
Pause the in-app schedules for the length of the rollback if one could
fire. To check that nothing is waiting in a directory queue:

```sql
SELECT id, queue, worker, state
FROM oban_jobs
WHERE queue LIKE 'backup_dir_%'
  AND state IN ('available', 'scheduled', 'retryable', 'executing');
```

No rows: the rollback is safe for backups. If you rolled back with a
backup still waiting there, cancel it on the Backups page. Its job stays
in `oban_jobs`, harmless, until you roll forward again. A marker sync left
in such a queue is also harmless: the next slot queues a new one in
`default`.

The migration's two `backup_node_beats` columns stay after a rollback; the
older release doesn't read them.

**During a rolling deploy**, a node on the older release:

- never advertises a queue, so its directory's jobs keep the put-backs in
  `backup_steps`;
- whose node name is reused by a node of this release, or the other way
  round, carries a new boot id, so an advertisement left by the other is
  ignored;
- cancels only the steps in `backup_steps`. Its **Cancel** of a backup
  whose step waits in a directory queue still cancels the run and releases
  the lock, and the step cancels itself when it runs (or the sweep cancels
  it); a step already running there stops at its next fenced call
  ([What a step that outlives its Cancel can write](#what-a-step-that-outlives-its-cancel-can-write)).

Finish the rolling deploy before you start, cancel or resume a backup.

### The backup-directory id read (#2848)

Every beat reports the id in `<BACKUP_DIR>/.kiln-dir-id` (and, with the
[last-good marker sync](#the-last-good-marker) on, creates it in a directory
that holds backups). On a hard-mounted NFS export that stops answering, that
read blocks, and before #2848 it blocked the whole heartbeat with it, its
self-fence included. Now:

- **The read runs in a task of its own**, which the heartbeat waits on for
  at most 5 seconds. A read that takes longer is left running, and the beat
  goes out without an id.
- **While it is held up, every beat reports no id.** The directory is hung,
  so the last-good marker sync stops routing to this node until it answers.
  The heartbeat starts no second read until the first one ends (a process
  blocked on a hung mount can't be killed, so one per tick would pile up).
  Once it ends, the next beat reads the id afresh.
- **Each beat also reports the last id it read** (`last_dir_id`, #2817),
  kept while a read is held up, crashes or can't start. Only a resume's
  start uses it, so a copy of the directory elsewhere doesn't resume while
  this host is alive but its read is stuck
  ([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)).
  The marker sync routes by the current id only. A read that finds no id
  file clears it, and a node that restarts has none until its first read
  answers.
- **The beat always goes out.** A read that crashes, or that answers with
  something other than an id or an error, is logged and the beat reports no
  id.
- **At most four reads run on a node at once.** If heartbeats restarted on a
  hung mount have left four stuck, a tick starts none and beats with no id.

What the server log says:

| Log line | Level | Meaning |
|---|---|---|
| "Backup heartbeat: reading the id of the backup directory `<dir>` has taken more than N s (a hung mount?). Beating with no id, so the last-good marker sync stops routing here; no other read starts until this one finishes." | warning | A read passed the 5-second wait. Once per stall. |
| "Backup heartbeat: the backup-directory id read of `<dir>` finished after N s" | info | The stalled read ended. The next beat reads the id again. |
| "Backup heartbeat couldn't start the backup-directory id read: … (earlier reads of `<dir>` are still hung?). Beating with no id." | warning | Four reads are already stuck. Once, until a read starts again. |
| "Backup heartbeat: the backup-directory id read failed, beating with no id: …" | warning | The read raised, exited, or gave an unexpected answer. |

Each beat that a read holds up also emits
`[:kiln_cms, :backups, :heartbeat, :dir_id_timeout]`, with measurements
`%{count: 1, waited_ms: ms}` (how long the read has run so far) and metadata
`%{node: node}` (the node's Oban node name). Alert on it: a node that emits it
for minutes has a backup directory that isn't answering, and anything else
that reads or writes it there, an in-app backup step included, waits on it
too.

The wait is `config :kiln_cms, KilnCMS.Backups, dir_id_timeout_ms: 5000`.
There is no reason to change it; the stall doesn't stop the self-fence,
which runs apart from the heartbeat
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)).

### The marker sync on a hung backup directory (#3079)

The [last-good marker sync](#the-last-good-marker) job reads the directory's
id, then syncs its markers, and both touch `BACKUP_DIR`. Before #3079 a job on
a node whose directory had stopped answering blocked in that read, holding
one of the Oban `default` queue's slots (10 by default) for as long as the
mount hung, and the heartbeat stopping its routing didn't free the jobs
already routed there. Now:

- **The job waits a bounded time.** Each piece of directory I/O runs in a
  task of its own, under `KilnCMS.Backups.MarkerSyncIO`. The job waits up to
  5 seconds for the id read (the heartbeat's `dir_id_timeout_ms`, the same
  setting) and up to 120 seconds for the sync. The sync's wait includes any
  wait for the backup lock behind another marker sync.
- **On a timeout the job gives up for the slot.** It logs a warning, emits
  the event below and fails with `{:error, :backup_dir_unresponsive}`, so its
  Oban slot is free again. The task is left running: a process blocked in a
  file operation on a hung mount can't be killed. If it finishes later, a
  line at info says how long it took, so a slow but healthy directory shows
  up as one.
- **A routed job whose id read times out snoozes**, as it does whenever the
  id isn't its directory's, so another node with that directory can still
  pick it up. After 20 snoozes it gives up as usual.
- **A scheduled job whose own id read times out** still queues the jobs for
  every other reported directory, then fails without syncing its own. An id
  read that crashes counts as no id, and that job syncs in place as before.
- **Only tasks a job gave up on are limited.** While two of them are still
  running, no job starts any more directory I/O: it logs a warning and fails
  with `{:error, :backup_dir_io_busy}` (a routed job snoozes instead). Each
  stuck task holds one of the VM's dirty I/O schedulers, which the
  heartbeat's id reads share. Jobs that were already waiting when the mount
  hung can each still leave one behind, so the count can go past two.
  Tasks a job is still waiting on are never "busy": the queue's concurrency
  bounds them.
- **The job's own timeout is both waits plus 60 seconds** (185 seconds by
  default), so a hung directory fails it with one of the reasons above
  rather than through Oban's timeout.

What the server log says:

| Log line | Level | Meaning |
|---|---|---|
| "Backup last-good marker sync: the id read of the backup directory `<dir>` took more than N ms (a hung mount?). Giving up for this slot; the id read is left running." | warning | The id read passed `dir_id_timeout_ms`. A routed job snoozes; a scheduled job queues the other directories' jobs and fails. |
| "Backup last-good marker sync: the marker sync of the backup directory `<dir>` took more than N ms (a hung mount?). Giving up for this slot; the marker sync is left running." | warning | The sync passed `marker_sync_io_timeout_ms`. The job fails; the next slot tries again. |
| "Backup last-good marker sync didn't start the id read of `<dir>`: 2 earlier ones it gave up on are still running (a hung mount?)" (or "the marker sync of") | warning | Two abandoned tasks are still stuck, so this job started none. |
| "Backup last-good marker sync: the id read of `<dir>` finished after N s more, after the job had given up on it" (or "the marker sync of") | info | An abandoned task ended, N seconds after the job stopped waiting. A task that ended abnormally reads "ended after N s more (`<reason>`)". |

Each timeout emits `[:kiln_cms, :backups, :marker_sync, :timeout]`, with
measurements `%{count: 1, waited_ms: ms}` (the wait that ran out) and
metadata `%{phase: :dir_id | :sync}`. Alert on it alongside the heartbeat's
`dir_id_timeout`: both mean the backup directory on some node isn't
answering.

Both waits are set under `config :kiln_cms, KilnCMS.Backups`:

```elixir
config :kiln_cms, KilnCMS.Backups,
  # The id read, shared with the heartbeat.
  dir_id_timeout_ms: 5_000,
  # The marker sync, backup-lock wait included.
  marker_sync_io_timeout_ms: 120_000
```

The defaults suit most deployments. Raise `marker_sync_io_timeout_ms` only if
a healthy directory's sync (import and marker writes on a slow volume) takes
longer than two minutes; the job's timeout follows it.

**Known limit: a sync stuck inside the backup lock keeps it.** The sync runs
under the backup lock (`Chain.with_lock/1`, a cluster-wide advisory lock in a
transaction). A task that blocks on the directory inside that transaction
keeps holding the lock and its database connection until the file operation
returns. Until then anything else that takes the backup lock, on any node,
waits for it until its query times out: other marker syncs, in-app backup
requests and steps, and the heartbeat's lock sweep on each tick. Bring the
directory back (or force-unmount it) to release the lock.

### What a step that outlives its Cancel can write

A step on a node that missed its Cancel or its take-back keeps running until
its node stops it ([above](#several-nodes-and-the-backup-lock)). Until then:

- **The backup's files**: it can't replace them. It writes `state.json`, the
  dump, each media part, the checksum sidecars, the media plan and
  `manifest.json` under temporary names tagged with its own job and attempt
  ([Temporary files and the trash directories](#temporary-files-and-the-trash-directories)),
  and renames each into place under the cluster-wide backup lock, only while
  its job still holds the lock. A step whose backup was canceled or taken back
  has its rename refused, removes its temporary file and stops there, writing
  nothing else (#2818, #2819). It can't delete the backup's files either: a
  step deletes only by moving the file aside under the same check.
- **The History row**: it can't write it. A step's progress, success and
  failure land only on a `Running` run that is still on that step's chain,
  so it can't overwrite a Cancel or the progress of a resume of the same run. The fence is argued in [ADR 0039](decisions/0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md), and why History writes stay out of the lock transaction in [ADR 0045](decisions/0045-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md).
- **Prune**: it can't delete anything or move a marker. The `prune` step
  syncs the `.good` and `.hold` markers under the lock, only while its job
  still holds it, and deletes each backup by moving its files into the trash
  the same way. A prune whose backup was canceled or taken back deletes
  nothing more and stops (#3041).
- **Off-site**: it starts no upload. Before each file, the `offsite` step
  checks that its job still holds the lock, and stops when it doesn't, so it
  sends nothing more, and neither sweeps nor prunes that destination. A
  [Local destination](#let-backups-be-written-to-a-directory-on-this-server) copies each file under a
  temporary name tagged with the step's job and attempt and renames it into
  place under the lock, so a late copy never replaces the resumed backup's
  file. An S3 destination checks again just before it completes a multipart
  upload (#3041).
  **What is not fenced:** an upload already under way when the backup was
  canceled. An `rclone copy` (`BACKUP_RCLONE_REMOTE` or an rclone
  destination), a single-request S3 upload, or a plugin's upload runs to its
  end, and can land after a resume's own copy of that file. The wait after a
  Cancel ([above](#cancel-a-running-backup)) covers it.
- **A retry of the same job**: an earlier attempt can't write once a later
  one has started. A step's lease is its job and the attempt that last
  claimed it, so an earlier attempt that is somehow still running (an Oban
  retry after a timeout, or the job rescued by Oban's Lifeline after about
  three hours) has its renames, its prune and its uploads refused like any
  superseded step's (#3040). A job that waited for its backup directory and
  runs again keeps its attempt, and claims the lock again.

**A stalled backup directory can still hold the lock.** The contents of every
file are written outside the lock, so a hung NFS mount no longer holds the
lock while a step writes its state or its manifest. But the renames into
place, the moves into the trash, and the finish step's
[marker sync](#the-last-good-marker) are file-system calls made inside the
lock's transaction. A mount that stalls between a step's write and its rename
still makes Cancel, new backup requests and the heartbeat's sweep wait behind
it until their database query times out. The start step reads the
directory's `.kiln-dir-id` before it takes the lock; only the very first
start on a directory with no id creates one inside it.

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
  chain, its stamp, `resume` (the stamp a resume continues, `nil` for a fresh
  backup), trigger, step, part, `parts_total`, `components` (what the
  running backup covers, as `[:db]`, `[:media]` or `[:db, :media]`; `nil` on a
  node without the backup's directory, and until its start step has run),
  phase (`:running` or `:finishing`), `acquired_at` and the queued request
  (`%{trigger, resume, components, requested_at, folds}`, where `components`
  `nil` means everything, or `nil`).
- **Wait for it**: `KilnCMS.Backups.await(chain)` returns `:ok` once that
  chain's backup succeeded, else `{:error, reason}`: the run's error,
  `:canceled`, `{:skipped, error}`, `:no_run` (the chain ended without a run,
  as a resume refused or [canceled](#cancel-a-resume-that-is-waiting-to-start)
  before it picked its backup up does) or `:timeout`. It polls the
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
the `backups` queue and `KilnCMS.Backups.Worker` are still in 1.10 and will be
removed in a later release, which its changelog will name. Drain the `backups`
queue before upgrading to it.

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
Schedules are managed on the **Schedule** tab of the Backups page
(`/editor/backups/schedules`), or from a release console when you script it
([Manage schedules from a release console](#manage-schedules-from-a-release-console)).
Only a platform admin may manage them, as on the Backups page: a schedule
backs up every site on the deployment, so a site admin who opens the tab is
turned away.

**Before you start:** a running release with the `add_backup_schedules`
migration applied, in-app backups working on at least one node (**Back up
now** succeeds), the scheduler job on (`KILN_BACKUP_SCHEDULER_CRON` not set to
`false`; [The scheduler job](#the-scheduler-job)), and a platform admin
account.

1. Open **Backups** (`/editor/backups`) and click the **Schedule** tab. The
   page is headed **Backup schedule**. With no schedules yet, the
   **Schedules** list reads "No schedules yet. Backups run when you click
   Back up now, or from the host's cron job." Any reason a schedule couldn't
   run here is a warning above the list
   ([What the Schedule tab shows](#what-the-schedule-tab-shows)).
2. Click **Add a schedule**. The **Add a schedule** form opens, filled in
   with a daily backup at 03:00 of everything this deployment backs up,
   starting today, in the deployment's default time zone (`Etc/UTC` unless
   `config :kiln_cms, KilnCMS.Events, time_zone: …` sets another), enabled.
3. Fill it in:

   | Field | What it takes |
   |---|---|
   | **What to back up** | **Database**, **Media**, or both. **Media** is greyed out, with "Media isn't archived on this deployment, so a schedule can't include it.", when the media are in S3 or there is no `MEDIA_DIR`. |
   | **How often** | **Every 2 hours**, **Every 4 hours**, **Every 8 hours**, **Every 12 hours**, **Every day**, **Every week**, **Every 2 weeks** or **Every month**. The four sub-daily ones need **Keep for (days)** ([Back up more often than daily](#back-up-more-often-than-daily)). |
   | **At** | The local time, `HH:MM`, in the schedule's time zone. For a sub-daily schedule, the first backup of the day; the hint under the box says "One backup at this time, and the others every 8 hours around the clock." |
   | **Starting on** | The first local date it may fire. Every week and every 2 weeks take their weekday from it (every 2 weeks also its week), every month its day of the month (the 31st becomes the month's last day). |
   | **Time zone** | An IANA name such as `Europe/Paris`. The box suggests about thirty common zones as you type, and takes any zone the time zone database knows. |
   | **Enabled** | Ticked, it runs; unticked, it is saved paused. |
   | **Keep the newest** | Optional, 1 to 1000: how many of this schedule's newest backups of each component to keep however old. Empty for none. |
   | **Keep for (days)** | 1 to 3650: how long this schedule's own backups are kept. Optional for daily and longer, where empty keeps them for `BACKUP_KEEP_DAYS` (the hint under the box gives this deployment's value). Required for a sub-daily schedule. |

   The two keep fields are under **How long to keep its backups**, and are
   explained in
   [Set how long a schedule keeps its backups](#set-how-long-a-schedule-keeps-its-backups).

   As you change it, a preview under the fields shows the cadence in words
   ("Every week on Tuesday at 04:15 (Europe/Paris)") and when it would first
   back up: "Next backup: in 3 days (2026-11-17 04:15)", in the schedule's
   own zone. When it wouldn't run, the preview says why instead: "It won't
   run while it's paused." with **Enabled** unticked, or "It won't run on
   this deployment until the warning above is resolved." when the scheduler
   is off or backups can't run here. A time zone the database doesn't know
   shows no preview, and "is not a known time zone" under the box. The
   preview also estimates what the schedule keeps: "Keeps about 15 backups at
   a time of each of: Database." for a daily schedule with the keep fields
   empty and the default 14 days.
4. Click **Save schedule**. The page flashes "Schedule saved.", the form
   closes, and the schedule is a card in the **Schedules** list: its cadence,
   what it backs up ("Database", "Database + Media"), "Next run: in 16 hours"
   and "No scheduled run yet". The create is recorded in the instance
   security log as **Backup schedule created**
   ([security-events.md](security-events.md#the-instance-log)).
5. After its window has passed, the card reads "Last window: started" and
   "Last scheduled run: Succeeded (2026-11-13 02:00 UTC)". Click that line:
   **Backups** opens on the **History** page that holds the run
   (`/editor/backups?run=<id>`), scrolled to its row, which is highlighted
   and whose trigger reads **Scheduled**.

The **Backups** tab then shows "Next scheduled backup: in 16 hours" under its
heading, linking back to the Schedule tab.

**Change, pause or delete a schedule** from its card:

- **Edit** opens the **Edit schedule** form with the stored values. Change
  them and click **Save schedule**, or **Cancel**. One form is open at a
  time: while one is, **Add a schedule** and every **Edit** are hidden.
  Changing the interval, time, start date, time zone or components means no
  window from before the edit fires
  ([When a schedule fires](#when-a-schedule-fires)).
- **Pause** flashes "Schedule paused.": the card reads "Paused" and shows no
  next run. **Resume** flashes "Schedule resumed." and, like an edit, fires
  no window it missed while paused.
- **Delete** asks first, "Delete this schedule? Backups it already took stay,
  and age out after 14 days (BACKUP_KEEP_DAYS), never sooner.", then
  flashes "Schedule deleted." For a schedule with a keep value set, the
  question starts "Delete this schedule? Its keep settings stop applying."

Each change that alters a value is recorded as **Backup schedule changed**,
and a delete as **Backup schedule deleted**. The line under the list reads
"Backups are kept for BACKUP_KEEP_DAYS (14 days) unless a schedule keeps its
own longer or shorter; the newest finished backup of each component is always
kept."

**When someone else changes the schedule you are editing.** The values the
form edits (what to back up, how often, the time, start date, time zone,
**Enabled** and the two keep fields) are noted when you click **Edit**. If
another admin, or a console, changes any of them before you save, nothing is
saved, so a form opened earlier never undoes their change (a pause, say):

1. The page flashes "This schedule changed since you opened it, so it wasn't
   saved. The form now holds the stored values, with what you entered beside
   them: re-enter the changes you still want and save."
2. The form stays open, now holding the values as stored. Above it, **Not
   saved: another admin changed this schedule** lists each field with **You
   entered** and **Stored now**, and marks the fields that differ
   "(differs)".
3. Re-enter what you still want and click **Save schedule**; it is compared
   with the stored values you now see. **Cancel** closes the form and the
   comparison.

A schedule deleted meanwhile, or changed to one the form can't offer, closes
the form instead. The scheduler's own writes on the schedule, such as
claiming a window, don't count as a change.

**If your platform admin role ends while the tab is open** (you were demoted,
or a time-limited grant expired), your next click on either Backups tab, or
the Schedule tab's minute refresh, takes you to the access-denied page;
nothing is read or changed first.

**What can go wrong:**

| Message | Meaning |
|---|---|
| "is not a known time zone" under **Time zone** | The zone isn't in the time zone database. Use an IANA name (`Europe/Paris`, `America/New_York`), not an abbreviation (`CET`). |
| "must have 1 or more items" under **What to back up** | Every box is unticked. Tick **Database**, **Media** or both. |
| "This schedule changed since you opened it, so it wasn't saved. …" | Someone changed the schedule since you clicked **Edit** (above). Nothing you entered was saved; it is shown beside the stored values. |
| "must be at least as long as the schedule's interval, unless a number of backups to keep is set" under **Keep for (days)** | **Keep for (days)** is shorter than one interval (1 day for daily, 7 weekly, 14 every 2 weeks, 31 monthly) and **Keep the newest** is empty. The schedule would keep nothing of its own but the newest backup. Raise the days or set **Keep the newest**. |
| "is required for a schedule that runs more often than daily" under **Keep for (days)** | **How often** is every 2, 4, 8 or 12 hours and **Keep for (days)** is empty ([Back up more often than daily](#back-up-more-often-than-daily)). |
| "That schedule no longer exists." | It was deleted in another tab or by another admin. |
| "This schedule can't be edited here: it can only be paused, resumed or deleted." | The schedule holds a value the form can't offer ([A schedule the tab can only pause, resume or delete](#a-schedule-the-tab-can-only-pause-resume-or-delete)). |
| "Only a platform admin can change backup schedules." | The schedule's policy refused the write: the account is not a platform admin. |
| "Couldn't change the backup schedule." | The write failed for another reason, usually the database; try again. |

### A schedule the tab can only pause, resume or delete

The form offers what this release and this deployment can run: every
interval from every 2 hours to monthly, the database, and the media when
there is a media directory. A
schedule that stores anything else has no **Edit** button, only **Pause** or
**Resume** and **Delete**, and its card says why:

- "A newer release saved this schedule with a value this release doesn't
  know, …": an interval or component written by a newer release, seen after
  rolling back. Its cadence reads "An interval this release doesn't know
  (`<value>`)" when the interval is the unknown value.
- "This schedule backs up media, which isn't archived on this deployment,
  …": the media directory was removed after the schedule was made.

Editing one would mean changing a value the form can't show, so the tab
doesn't. Pause it, or delete it and add a new one.

### Manage schedules from a release console

For scripts and automation, the same code interfaces the tab uses work from a
release console. The actor must be an account whose effective platform role
is admin.

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
   | `interval` | `:every_2h`, `:every_4h`, `:every_8h`, `:every_12h`, `:daily`, `:weekly`, `:fortnightly` or `:monthly` | required |
   | `time_of_day` | local wall time in `time_zone`, cut to the minute | required |
   | `starts_on` | a local date in `time_zone`; nothing fires before it. Weekly and fortnightly take their weekday from it, fortnightly also its week parity, monthly its day of the month (the 31st becomes the month's last day) | required |
   | `time_zone` | an IANA zone such as `"Europe/Paris"` | `"Etc/UTC"` |
   | `enabled` | `true` or `false` | `true` |
   | `keep_count` | 1 to 1000: keep this schedule's newest N backups of each component, however old ([below](#set-how-long-a-schedule-keeps-its-backups)) | `nil` (none) |
   | `keep_days` | 1 to 3650: how long this schedule's own backups are kept; at least one interval long unless `keep_count` is set; required for the four sub-daily intervals ([below](#back-up-more-often-than-daily)) | `nil` (`BACKUP_KEEP_DAYS`) |

2. Open the **Schedule** tab (`/editor/backups/schedules`): the schedule is
   a card there, as in the steps above.

**Other calls**, each with `actor: admin` as above:

- **List them:** `KilnCMS.Backups.list_backup_schedules(actor: admin)`.
- **Fetch one:** `KilnCMS.Backups.get_backup_schedule(id, actor: admin)`
  (`{:ok, nil}` when there is none).
- **Change one:** `KilnCMS.Backups.update_backup_schedule(s, %{time_of_day: ~T[02:00:00]}, actor: admin)`.
  It accepts the same eight fields; anything else is refused. `nil` clears a
  keep field, and changing only the keep fields never rebaselines the
  schedule. A console change
  to a schedule someone has open in the tab makes their save refused, as
  above.
- **Pause and resume:** `update_backup_schedule(s, %{enabled: false}, actor: admin)`,
  then `%{enabled: true}`.
- **Delete one:** `KilnCMS.Backups.destroy_backup_schedule(s, actor: admin)`
  returns `:ok`.

The security log records console changes as it records the tab's. A change
that resubmits the same values records nothing.

**What can go wrong:**

| Error | Meaning |
|---|---|
| `time_zone`: "is not a known time zone" | The zone isn't in the time zone database. Use an IANA name (`"Europe/Paris"`, `"America/New_York"`), not an abbreviation (`"CET"`). |
| `keep_days`: "is required for a schedule that runs more often than daily" | A sub-daily `interval` with no `keep_days`, on a create, a switch to a sub-daily interval, a change that clears `keep_days`, or any change but `enabled` to a sub-daily schedule that has none ([below](#back-up-more-often-than-daily)). |
| `keep_days`: "must be at least as long as the schedule's interval, unless a number of backups to keep is set" | `keep_days` below 1 (daily), 7 (weekly), 14 (fortnightly) or 31 (monthly) with no `keep_count`. Checked when the interval or either keep field changes. |
| `keep_count`: "must be less than or equal to 1000", `keep_days`: "… 3650", or either "must be greater than or equal to 1" | A keep value out of range. |
| `components`: "media isn't archived on this deployment" | `:media` on a deployment with no media directory (S3 media, or no `MEDIA_DIR`). |
| `Ash.Error.Invalid` on `components` or `interval` | An empty list, a component other than `:db` or `:media`, or an interval that doesn't exist. |
| `Ash.Error.Forbidden` | The actor is not a platform admin (a site admin is not enough), or you passed `KilnCMS.Backups.system()`, which may not manage schedules. |
| `** (Ash.Error.Query.NotFound)` from `get_user_by_email!` | No account has that email address. |

### What the Schedule tab shows

Everything on the tab comes from the same status the alarm uses, so a "Next
run" shown there is one the scheduler will act on. Each schedule's card shows:

- **Its cadence**, such as "Every 8 hours from 03:00 (Europe/Paris)", "Every
  day at 03:00 (Europe/Paris)", "Every week on Thursday at 02:30 (Etc/UTC)", "Every 2 weeks on Thursday at 02:30
  (Etc/UTC), from 2026-01-01" or "Every month on day 15 at 03:00 (Etc/UTC)",
  and what it backs up ("Database", "Database + Media").
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
  `no_media_dir`). This says what the window asked for, not how the backup
  went.
- **The last scheduled run:** "Last scheduled run: Failed (2026-11-13 02:00
  UTC)", the newest backup run that this schedule took part in and how it
  ended (Succeeded, Failed, Running, Skipped or Canceled), linking to that
  run's row in **History** (`/editor/backups?run=<id>`, on whichever page
  holds it); or "No scheduled run yet". A link to a run that is gone, or
  that isn't a run id, opens the first History page with "That backup isn't
  in the history."
- **What it keeps:** "Keeps its newest 7 backups, and every one from the last
  30 days" with **Keep the newest** set, otherwise "Keeps its backups for 30
  days", or "Keeps its backups for 14 days (BACKUP_KEEP_DAYS)" with neither
  set.
- **"This schedule runs more often than daily without Keep for (days), …"**
  on a sub-daily schedule stored without keep days
  ([Back up more often than daily](#back-up-more-often-than-daily)).

Above the list, a warning box appears when any of these holds:

| Warning | When |
|---|---|
| "The scheduler is turned off on this deployment (KILN_BACKUP_SCHEDULER_CRON), so these schedules don't run." | `KILN_BACKUP_SCHEDULER_CRON` is `false` ([The scheduler job](#the-scheduler-job)). |
| "KILN_BACKUP_SCHEDULER_CRON isn't a valid cron expression, so the scheduler is off and these schedules don't run." | `KILN_BACKUP_SCHEDULER_CRON` doesn't parse, such as `0 0 31 2 *` (31 February), which Oban refuses ([The scheduler job](#the-scheduler-job)). |
| "KILN_BACKUP_SCHEDULER_CRON only matches a date that doesn't exist, such as 31 February, so these schedules never run." | `KILN_BACKUP_SCHEDULER_CRON` parses but names no real date, on an Oban release that accepts such an expression ([The scheduler job](#the-scheduler-job)). |
| "In-app backups can't run here, so schedules are skipped: `<reason>`" | This node can't run backups: `BACKUP_ENABLED=false`, no database connection, or no PostgreSQL client tools. |
| "The scheduler hasn't run since 2026-11-13 09:12 UTC. Check that background jobs are running." (or "… hasn't run yet.") | The scheduler is on, and no scheduler job has started since the newest run of `KILN_BACKUP_SCHEDULER_CRON` (read in UTC) that is at least five minutes old, although an enabled schedule was created, edited or resumed before that run. Each run gets five minutes to start: at the default `* * * * *` that is five minutes of silence, at `0 * * * *` a tick missed at 09:00 shows from 09:05. A weekday-only cron such as `* * * * 1-5` expects nothing after Friday 23:59 until Monday 00:00, so a weekend shows no warning. With `@reboot`, the threshold is five minutes. It reads Oban's `oban_jobs` table, so a job queue that has stopped shows here. |
| "Couldn't check when the scheduler last ran." | Reading `oban_jobs` for that check failed. |
| "Media isn't archived on this deployment, so a schedule can't include it." | A schedule names media and this deployment has no media directory. |
| "On 2026-11-16 03:30 UTC, a backup a schedule keeps was deleted outside the app: Database backup of 2026-07-01 03:17 UTC." and "This usually means the host's scripts/backup.sh is older than this release and ignores .hold markers. …" | In the last eight days, a marker sync found a backup a schedule keeps deleted by something other than the app, usually the host's cron with an older `backup.sh` ([When a backup a schedule keeps is deleted outside the app](#when-a-backup-a-schedule-keeps-is-deleted-outside-the-app)). |

In the list, "Couldn't load the backup schedules." means the schedules
couldn't be read (the alarm thresholds are then the environment's), and
"Couldn't load the last runs." appears once, instead of every card claiming
there was no run, when the runs couldn't be read. While the tab is open it
reads all of this again every minute, and leaves an open form as it is.

**On the Backups tab**, the schedules show as:

- "Next scheduled backup: in 16 hours" under the heading, the soonest window
  of any schedule that can run here, linking to the Schedule tab;
- the **Alarm thresholds** section, one line per component with its
  threshold and where it came from: "Alarm after 36 hours without a good
  backup (BACKUP_STALE_AFTER_HOURS)", "Alarm after 252 hours without a good
  backup (its schedule)", or "Alarm after 36 hours without a good backup
  (BACKUP_STALE_AFTER_HOURS; host cron backs it up too)"
  ([below](#how-a-schedule-sets-the-alarm-threshold)). When schedules exist,
  it warns "In-app schedules are turned off (KILN_BACKUP_SCHEDULER_CRON)."
  (`false`), "In-app schedules don't run: KILN_BACKUP_SCHEDULER_CRON isn't a
  valid cron expression.", "In-app schedules never run:
  KILN_BACKUP_SCHEDULER_CRON only matches a date that doesn't exist, such as
  31 February." ([The scheduler job](#the-scheduler-job)), or "Scheduled
  backups can't run here: `<reason>`".

**On the Overview page**, once an enabled schedule exists, the platform
admins' backup strips (the neutral "Backups aren't set up yet" one and the red
one) gain an **Open the schedule** link beside **Open Backups**, and say:

- "First scheduled backup: in 3 hours. You can take one now from Backups."
  (neutral strip) or "Next scheduled backup: in 3 hours. You can also take
  one now from Backups." (red strip), when every component the strip is about
  (never backed up, failed, or stale) has an enabled schedule that can run
  here; the time is the soonest of theirs;
- otherwise, that scheduled backups run "from the in-app schedules on the
  Schedule tab of Backups or from" the host's cron job: a schedule that covers
  only some of those components, or can't run here, is no promise for the
  rest.

Without an enabled schedule, the strips say scheduled backups are the host's
cron job, as before.

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
  the meantime. Only a window whose backup was never asked for (a queued
  Resume, a node without the client tools, below) is asked for again each
  minute. Why it is this way, and why the claim shares the backup lock's
  transaction: [ADR 0044](decisions/0044-a-schedule-sets-the-alarm-threshold-only-while-it-can-run-and-a-claimed-window-is-never-retried.md).
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
- **Retention follows the schedule's keep settings.** Every scheduled backup
  is a full set of its components. Without keep settings it is pruned by
  `BACKUP_KEEP_DAYS` like any other; with them, as in
  [Set how long a schedule keeps its backups](#set-how-long-a-schedule-keeps-its-backups).
- **A Back up now that joins a scheduled backup makes it not the schedule's
  own.** When a manual or console request folds into a queued scheduled one
  (or the other way round), the run takes the manual or console trigger. Its
  backups never count toward the schedule's keep count, and are kept for
  `BACKUP_KEEP_DAYS` or the schedule's **Keep for (days)**, whichever is
  longer.

### Set how long a schedule keeps its backups

A schedule can keep its own backups longer or shorter than `BACKUP_KEEP_DAYS`,
and can keep its newest N backups however old, so a weekly schedule keeps a
few weeks of history and a component no one backs up for a while still has
its last few sets (part of #2219). You need a platform admin account and a
schedule, or the steps to add one
([Schedule backups in the app](#schedule-backups-in-the-app)).

**Before you start**, if host cron prunes this backup directory
(`backup.sh all` or `backup.sh prune`), replace the host's copy of
`scripts/backup.sh` with this release's on every such host. The app tells
cron what a schedule keeps through [hold markers](#the-hold-markers), and an
older copy ignores them: it deletes a backup the schedule keeps once the
backup is older than `BACKUP_KEEP_DAYS`. During a rolling deploy, wait until
every node runs this release: an older node's prune knows nothing of keep
settings.

1. Open **Backups** (`/editor/backups`), click the **Schedule** tab, and click
   **Edit** on the schedule's card (or **Add a schedule**).
2. Under **How long to keep its backups** ("Both are optional. The newest
   backups are kept however old; the days apply to this schedule's own
   backups. Whichever keeps more wins."), fill in either field or both:
   - **Keep the newest**: a number of backups of each component, 1 to 1000.
   - **Keep for (days)**: 1 to 3650. The hint says what an empty box means
     on this deployment: "Empty keeps them for BACKUP_KEEP_DAYS, 14 days on
     this deployment."

   Under the fields, a standing note reads "If host cron prunes this backup
   directory, its scripts/backup.sh must be from this release: an older
   copy deletes the backups these settings keep.", with an **About the hold
   markers** link. It is always there, adding a schedule or editing one,
   whatever the preview below says: the app can't tell which copy cron
   runs.
3. Read the preview under the fields. It estimates what the schedule keeps,
   "Keeps about 31 backups at a time of each of: Database." for a daily
   schedule keeping 30 days, and warns when:
   - **Keep for (days)** is shorter than `BACKUP_KEEP_DAYS`: "This schedule's
     own backups age out after 5 days, sooner than BACKUP_KEEP_DAYS (14).
     Backups made by hand or by the host's cron still keep BACKUP_KEEP_DAYS."
   - the schedule keeps backups past `BACKUP_KEEP_DAYS` (a longer **Keep for
     (days)**, or a **Keep the newest** reaching further back than that) and
     host cron backed one of its components up here in the last eight days:
     "Host cron also backs up Database here, and this schedule keeps backups
     past BACKUP_KEEP_DAYS. Replace the host's scripts/backup.sh with this
     release's copy first: an older copy deletes them after
     BACKUP_KEEP_DAYS." If you haven't replaced it yet, do it before you
     save.
4. Click **Save schedule**. The page flashes "Schedule saved." and the card
   reads, for example, "Keeps its newest 7 backups, and every one from the
   last 30 days". The security log records **Backup schedule changed** with
   `changed` naming the keep fields
   ([security-events.md](security-events.md#the-instance-log)). Changing only
   the keep fields doesn't move the schedule's next run.
5. The save queues a marker sync, which writes a `kiln-<stamp>.hold` marker
   beside each backup the schedule holds (with
   `KILN_BACKUP_MARKER_SYNC_CRON=false`, the next in-app backup does). List
   `db/` or `media/` on the host to see them, or ask the app what the next
   prune would do; `holds` lists the held stamps of each component:

   ```bash
   bin/kiln_cms rpc '
   {:ok, %{plan: plan}} = KilnCMS.Backups.Retention.run(KilnCMS.Backups.dir(), dry_run: true)
   IO.inspect(plan.holds)'
   # %{db: ["20261012-030000", "20261013-030000", …, "20261113-030000"], media: []}
   ```

   A unit a keep count holds reads `reason: {:keep_count, ["<schedule id>"]}`
   in `plan.keep` ([Keep a backup as a recovery point](#keep-a-backup-as-a-recovery-point)
   has the plan's shape).

The same from a release console, with the admin and schedule fetched as in
[Manage schedules from a release console](#manage-schedules-from-a-release-console):

```elixir
{:ok, s} = KilnCMS.Backups.update_backup_schedule(s, %{keep_count: 7, keep_days: 30}, actor: admin)
# s.keep_count == 7, s.keep_days == 30; %{keep_count: nil, keep_days: nil} clears both
```

**How the two settings decide**, per component the schedule backs up:

- **Keep the newest N** keeps the schedule's own newest N backups, and the
  newest N of its own and host cron's together, however old. Only good
  backups count: complete on disk, from a `Succeeded` run that verified them
  (or imported from cron), not in flight, and not a recovery point. A failed
  backup doesn't use up a place, and a backup taken with **Back up now** or
  from a console never counts.
- **Keep for (days)** is how long the schedule's own backups are kept. It may
  be shorter than `BACKUP_KEEP_DAYS`: then only this schedule's own backups
  age out sooner; manual and cron backups of the same component keep at
  least `BACKUP_KEEP_DAYS`. It may be longer: then cron's backups of that
  component, and backups with no History row, are kept that long too, so a
  backup no schedule made never ages out sooner than one it did. With **Keep
  the newest** empty, it must be at least one interval long (1 day for
  daily, 7 weekly, 14 every 2 weeks, 31 monthly).
- **Both set**: whichever keeps a backup longer. **Neither**: `BACKUP_KEEP_DAYS`,
  as before.
- The newest verified and newest complete backup of each component are kept
  whatever the schedule says (rules 1 to 4 of
  [What retention deletes and what it keeps](#what-retention-deletes-and-what-it-keeps)).
- **A paused schedule still keeps.** Its settings apply to the backups it
  already took.
- **Several schedules on one component** each keep what they keep; a backup
  stays while any of them holds it.
- **Deleting a schedule**, or taking a component out of it, ends its keep
  settings for those backups. They then count like cron's: kept for the
  component's floor (at least `BACKUP_KEEP_DAYS`) and counted toward other
  schedules' **Keep the newest**. Deleting a schedule never shortens how
  long a backup is kept below `BACKUP_KEEP_DAYS`.

**What the estimate means for the disk.** "Keeps about N backups at a time"
is the larger of the backups younger than **Keep for (days)** (one per
interval, counted in hours, plus one) and **Keep the newest** plus one, and
never under two.
The plus one is the backup being made: the prune runs while it is still in
flight, so it keeps N finished backups beside it, and N + 1 sets are on disk
until the next prune. Budget for that with large media archives.

**What can go wrong:**

| Message | Meaning |
|---|---|
| "must be at least as long as the schedule's interval, unless a number of backups to keep is set" under **Keep for (days)** | Raise the days to one interval or more, or set **Keep the newest**. |
| The host-cron notice in the preview | Replace the host's `scripts/backup.sh` (above). The notice is shown whenever cron backed up a component here in the last eight days; the app can't tell which copy of the script cron runs. |
| "Backup retention skipped: couldn't read the backup schedules (…); nothing was deleted" in the server log and the run's log | The prune couldn't read the schedules, so it deleted nothing ([When retention is skipped or stops](#when-retention-is-skipped-or-stops)). |
| "… a backup a schedule keeps was deleted outside the app: …" on the Backups page and the Schedule tab | The host's `backup.sh` predates the hold marker and deleted a backup this schedule keeps. Replace it ([When a backup a schedule keeps is deleted outside the app](#when-a-backup-a-schedule-keeps-is-deleted-outside-the-app)). |
| Backups past `BACKUP_KEEP_DAYS` disappear from a cron-pruned directory, with no warning | The app can't see the directory or reach it with the marker sync, so it neither writes the holds nor notices what cron deleted ([The hold markers](#the-hold-markers)). |

### Back up more often than daily

A schedule can back up every 2, 4, 8 or 12 hours, for a site whose content
changes through the day (part of #2219). You need a platform admin account
([Schedule backups in the app](#schedule-backups-in-the-app)).

Every run is a full set, a database dump (and a media archive, if the
schedule covers media), and **Keep the newest** is a minimum, not a cap. Kept
by age alone, a schedule keeps about

> runs per day × `BACKUP_KEEP_DAYS`

sets of each component: 12 × 14 = 168 for a two-hourly schedule on the
default 14 days. So a sub-daily schedule must set its own **Keep for
(days)**.

1. On **Backups** → **Schedule**, click **Add a schedule** (or **Edit** on a
   schedule's card).
2. Under **What to back up**, tick **Database** only, unless your media
   change as often. A media archive every few hours is the costly part.
3. In **How often**, choose **Every 2 hours**, **Every 4 hours**, **Every 8
   hours** or **Every 12 hours**. **Keep for (days)** is now marked
   required, its hint reads "Required for a schedule that runs more often
   than daily.", and the hint under **At** reads "One backup at this time,
   and the others every 2 hours around the clock."
4. In **At**, enter the first backup of the day. The others follow every N
   hours, wrapping past midnight: 03:00 every 8 hours backs up at 03:00,
   11:00 and 19:00 local time. On a daylight-saving night two of them can be
   an hour closer together or further apart.
5. In **Keep for (days)**, enter how long to keep this schedule's backups,
   say `2`. The preview reads "Keeps about 25 backups at a time of each of:
   Database." for every 2 hours kept 2 days (2 × 12, plus the one being
   made).
6. Click **Save schedule**. The card reads "Every 2 hours from 03:00
   (Europe/Paris)" and "Keeps its backups for 2 days".

From a release console, the same with `interval: :every_2h` and a
`keep_days` ([Manage schedules from a release console](#manage-schedules-from-a-release-console)):

```elixir
KilnCMS.Backups.create_backup_schedule(
  %{components: [:db], interval: :every_2h, time_of_day: ~T[03:00:00],
    starts_on: Date.utc_today(), time_zone: "Europe/Paris", keep_days: 2},
  actor: admin
)
```

How it behaves:

- **Keep for (days) is required** when the schedule is created, switched to
  a sub-daily interval, or has its keep days cleared, and on any edit of a
  sub-daily schedule that has none. **Pause**, **Resume** and **Delete**
  never need it.
- **A sub-daily schedule stored without keep days** (written past the form,
  from a console) still fires, and its backups are kept for
  `BACKUP_KEEP_DAYS`. Its card reads "This schedule runs more often than
  daily without Keep for (days), so its backups are kept for
  BACKUP_KEEP_DAYS. Set Keep for (days) to edit it; you can still pause,
  resume or delete it." **Edit** opens with **Keep for (days)** empty, so
  saving it means setting one.
- **A backup that outlasts the interval** never overlaps the next. The next
  window queues behind it ("Last window: queued behind another backup"),
  and a window after that joins the queued request ("Last window: joined a
  queued backup"), so at most one backup waits.
- **The alarm gets stricter**: a component a sub-daily schedule covers is
  stale after 8 to 18 hours, not the default 36
  ([below](#how-a-schedule-sets-the-alarm-threshold)).
- **The scheduler job must check at least as often as the interval.** Only
  the latest due window fires, so with `KILN_BACKUP_SCHEDULER_CRON` coarser
  than the interval (say `0 */6 * * *` for a two-hourly schedule) the
  windows in between are skipped and logged as missed
  ([The scheduler job](#the-scheduler-job)). The default, every minute, is
  fine.
- **Rolling back to 1.10** keeps the schedule firing on its keep days, and
  its Schedule tab shows it with "Schedules more often than daily can't be
  edited here yet. You can pause, resume or delete it."

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
| every 2 hours | 8 h |
| every 4 hours | 10 h |
| every 8 hours | 14 h |
| every 12 hours | 18 h |
| daily | 36 h |
| weekly | 252 h |
| fortnightly | 504 h |
| monthly | 1116 h |

A weekly schedule therefore **raises** the threshold from the default 36 h:
weekly backups are not an alarm on day two. When host cron has also backed the
component up in the last eight days (an imported run with trigger `cron`), the
threshold is the lower of the schedule's and `BACKUP_STALE_AFTER_HOURS`, and
the Backups page says "host cron backs it up too". Why a schedule that can't
run never sets the threshold:
[ADR 0044](decisions/0044-a-schedule-sets-the-alarm-threshold-only-while-it-can-run-and-a-claimed-window-is-never-retried.md).

### Restoring the database brings back the schedules

The schedules are rows in the database, so restoring a dump restores them as
they were when it was taken: deleted schedules come back, paused or enabled as
they were then, with the last window they had claimed. On the first tick after
the restore, each enabled schedule whose latest window is newer than that fires
within a minute (one extra backup). To avoid it, pause the schedules before
anything ticks: start the restored release with `KILN_BACKUP_SCHEDULER_CRON=false`,
pause or delete them on the **Schedule** tab (it works with the scheduler
off) or from a console, then unset the variable and restart.

A staging clone made with the [staging scrub](staging-environments.md#the-scrub)
pauses every schedule (`backup_schedules_disabled` in the scrub's summary), so
a clone never runs production's schedules against its own backup directory.

### The scheduler job

`KILN_BACKUP_SCHEDULER_CRON` (default `* * * * *`) is when the scheduler checks
the schedules, not when they fire: a window is the schedule's own time, so a
coarser cadence such as `*/5 * * * *` only makes a backup start up to five
minutes late. A cadence coarser than a schedule's interval skips windows,
since only the latest due one fires
([Back up more often than daily](#back-up-more-often-than-daily)). Every minute leaves about 10 000 completed job rows a week, which
Oban prunes after 7 days. `false` (also `off`, `no`, `0` or blank) turns every
schedule off, and the Backups page says so; an unparseable value does the same
and warns on stderr at boot, and the Schedule tab says it isn't a valid cron
expression. One that names no date that exists, such as `0 0 31 2 *`
(31 February), never runs: Oban refuses it as unparseable, and where an Oban
release accepts it, the Schedule tab says it never matches. It is read in every environment, and
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
| `[:kiln_cms, :backups, :import, :failed]` | `stamp`, `attempt`, `retry_at` (a `DateTime`), `error` (the redacted cause) | The History importer couldn't write a stamp's row; it waits out a backoff before the next try. Not a scheduler event, listed here with the other backup events ([When an import keeps failing](#when-an-import-keeps-failing)). |

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
those.) The reasoning is in [ADR 0034](decisions/0034-media-backups-are-split-by-file-set-into-independent-archives-not-by-bytes.md).

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
- **A folder that can be listed but not entered** (mode 0644, say) fails the
  backup, naming the folder: fix its permissions, or leave it out with
  `BACKUP_MEDIA_EXCLUDE`. Before #2477 the app left its files out and counted
  them as names the encoding cannot represent.
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
| "A backup is running and a new backup is queued after it, so this resume was not queued. Try again once the queue clears." | A fresh backup waits behind the running one, and a resume never folds into it ([Back up while another backup runs](#back-up-while-another-backup-runs)). Click again once it has started. |
| "A backup is running and a resume of `<stamp>` is queued after it, so this resume was not queued. Try again once the queue clears." | A resume of another backup is already waiting. |
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
the fallback. The reasoning is in [ADR 0037](decisions/0037-a-resume-reuses-a-file-only-on-a-recorded-hash-match-and-the-run-row-decides-whether-it-may-run.md).

> **Operators who copy the backup directory with `rclone sync $BACKUP_DIR`:**
> exclude `.work/**`. It holds lists of media file names (and is removed on
> success), and has no value off-site. Exclude `**/.kiln-trash/**` too: it
> holds files on their way to being deleted
> ([Temporary files and the trash directories](#temporary-files-and-the-trash-directories)).

**Disk space.** A backup needs room for the database dump, plus all finished
media parts, plus one part being written, plus the file lists. Before the
dump, and again before the first media part, the app and `backup.sh` check
the free space where they are about to write (`df -Pk` on `BACKUP_DIR/db` or
`BACKUP_DIR/media`; the app also checks `.work/`, where its lists are)
against an estimate plus 10% plus a 256 MB margin. The dump's estimate is the
size of the newest earlier dump (0 for a first backup); the media's is the
uncompressed input size of the parts still to archive. Too little room fails
the run at once, with no retries, naming the free space and what was needed:
free up space, or point `BACKUP_DIR` at a larger disk. If `df` can't be read,
the run warns and goes ahead.

The media estimate is an upper bound. Photos and video are compressed already,
so their parts come out about that size, but TIFF, BMP, SVG, uncompressed
audio and sparse files shrink, and a file linked under two names counts twice.
If a library like that is refused although it fits, or `df` misreports the
disk (some network and FUSE file systems), set `BACKUP_FREE_SPACE_CHECK=false`
for the app and the cron line; a disk that then fills fails the step as
before. In the app, `config :kiln_cms, KilnCMS.Backups,
free_space_margin_bytes:` changes the margin; `backup.sh` always uses 256 MB.

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
over. The reasoning is in [ADR 0043](decisions/0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md).

**Where it shows (in-app backup).** The run is `Failed`. The error appears in
the **Last run failed** box on `/editor/backups` and on the History row. The
row reads **Not verified**, the refused file loses its **Verified** badge in
the **Artifacts** list, and the overview shows its red backup strip. The error names each file and why, for example (one line,
wrapped here):

```text
Off-site copy REFUSED for 1 file: kiln-media-20261108-031700.part02.tar.gz
(changed on disk after this backup verified it (sha256 expected 3b1f0c9a2e41…,
found 8c02d7e5b6f1…); kept as /var/backups/kiln/media/kiln-media-20261108-
031700.part02.tar.gz.refused-20261108-034512). Something other than this backup wrote to the backup
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

**With several destinations** ([below](#send-backups-to-several-destinations)),
a file refused at any one of them fails the whole backup, the same way:
destinations earlier in the list have already received their copies, and
those after it are not sent to. A copy that failed rather than was refused
is different: it fails only that destination, and the backup fails only
when it reached none ([When a backup reaches only some
destinations](#when-a-backup-reaches-only-some-destinations)).

**Where it shows (cron).** `backup.sh` stops at the first refusal, exits
non-zero (so `MAILTO` and the missing `BACKUP_PING_URL` ping catch it), prints
the error to stderr after `error: `, and for `backup.sh all` writes it into a
failure manifest, which the panel shows in **Last run failed** (one line,
wrapped here):

```text
REFUSING off-site copy of kiln-media-20261108-031700.part02.tar.gz: its
sha256 changed after this backup verified it (expected 3b1f…, found 8c02…).
Nothing was uploaded for it. It was kept as /var/backups/kiln/media/kiln-media-
20261108-031700.part02.tar.gz.refused-20261108-034512; prune removes it once
it is older than BACKUP_KEEP_DAYS. Something other than this backup wrote to
/var/backups/kiln: check the disk before trusting this backup.
```

(The digests in the real message are full length.) A missing file or a
symlink reads `it is missing or no longer a regular file`. A copy that rclone
itself failed stops the run the same way; its manifest error is only
`backup.sh exited <status> - see the backup log`, and rclone's own output is in
that log.

**What did and did not leave the host.**

- **App:** every other file is still re-hashed and copied, one by one, so the
  destination that refused has everything except the refused files (and any
  whose copy failed).
  A part set missing a part on the remote is not restorable from there:
  `restore.sh` stops with `<sidecar> lists <file>, which is missing from the
  set`.
- **Cron:** files copied before the refusal are on the remote; nothing after it
  was copied, and for `backup.sh all` a refusal during the database phase means
  the media set was never built.
- **Both:** all local files are kept, and the manifest records the refused
  file as not verified and `"offsite": null`. The changed file is kept under
  a new name (below).
- **The sidecars differ slightly.** Cron hashes a sidecar's bytes, so any edit
  to it is caught. The app compares the sidecar's parsed lines with the
  digests and names it recorded, in order: a changed digest, name, line order
  or an extra line is caught, while a change the parser ignores (a blank line,
  one space instead of two before the name, `sha256sum`'s `*` binary marker)
  is not.

**The changed file is kept (#2484).** The moment a file is refused because
its content changed (a checksum sidecar too), it is renamed beside itself to
`<name>.refused-<UTC stamp>`, the stamp being the moment of the refusal, not
the backup's: for example
`media/kiln-media-20261108-031700.part02.tar.gz.refused-20261108-034512`. The
rename keeps the file's bytes and its mtime, which says when it last changed.
The error names where it went, `… found 8c02d7e5b6f1…); kept as
/var/backups/kiln/media/kiln-media-20261108-031700.part02.tar.gz.refused-20261108-034512)`,
and the run's log adds `Kept the refused <name> as <path>; retention removes
it once it is older than <N> days`. Cron's error adds `It was kept as <path>;
prune removes it once it is older than BACKUP_KEEP_DAYS.` A file refused as
missing, or as no longer a regular file, has nothing to keep. If the rename
itself fails (a read-only directory, say), the file stays where it is and the
run's log says `Couldn't keep the refused <name> aside (<reason>); it is still
at <path>. Move it out of BACKUP_DIR before you Resume`; cron prints `warning:
could not keep <name> aside; it is still at <path>`.

Nothing reads a kept file as a backup: not History, `backup.sh verify`,
`restore.sh` (a stamp prefix or one part never picks it up), the cron prune's
units or the off-site copies. Its stamp still counts as in use, so no new
backup takes it. Both the app's retention and `backup.sh prune` delete it once
it is older than `BACKUP_KEEP_DAYS` counted from **both** its mtime and the
refusal stamp in its name, so a file that changed long before it was refused
is still kept that long after the refusal. A refusal stamp that is not a real
moment, or more than a day ahead, counts for nothing. To remove it sooner,
delete it by hand once you are done with it: `rm <path>`.

Don't restore from a kept `.refused-` file. Its name is not one `restore.sh`
recognizes, so given one by path it treats it as a dump or archive Kiln did not
name: there is no sidecar to check it against, and it only warns, unless
`RESTORE_REQUIRE_CHECKSUM=1`, which refuses it.

A resume (or a retried step) that finds a file it recorded no longer matching
its recorded SHA-256, for example a media part that changed between its archive
and the checksum step, or the database's `.sha256` file beside a dump it
reuses, keeps it the same way before rebuilding or rewriting it, and says so on
the run: `<name> no longer matched the sha256 this backup recorded for it:
kept as <path>, and rebuilt`. If it can't be kept, the resume does not rebuild
over it: the run fails with `Couldn't keep the changed <name> aside (<reason>),
so it was not rebuilt: it is still at <path>. Move it out of BACKUP_DIR, then
Resume.` (The media `.sha256` file is rewritten on a resume without this
check: a rebuilt part changes it legitimately.)

**What to check.** Look at the disk (`dmesg`, SMART, filesystem errors) and at
anything else that can write to `BACKUP_DIR`: a second cron entry or host, a
sync job pointed the wrong way, a restore unpacked into it. Compare the kept
file with the digest the error names (`sha256sum <path>`).

**Then retry.**

1. The changed file is normally already kept aside, and a resume leaves it
   alone. If the run's log says it couldn't be kept, move it out of
   `BACKUP_DIR` yourself first; a resume that can't keep it fails rather than
   rebuild over it. If you need a kept file for longer than
   `BACKUP_KEEP_DAYS`, copy it out of `BACKUP_DIR`.
2. **App:** open **Backups** as a platform admin and
   click **Resume** on the failed History row (see [Interrupted? Resume
   it.](#media-backups-in-parts-2218)). Files that still match `state.json`
   are reused, and only a file that changed (or was replaced by a symlink or
   other non-regular file) is rebuilt. A rebuilt dump is a fresh `pg_dump`,
   taken at resume time. Every file is re-hashed and copied off-site again;
   rclone skips a file the remote already holds unchanged. A destination added
   on the **Destinations** tab is not sent a file this backup already sent it
   with the same SHA-256 (its log line reads "`<file>` was already copied to
   `<destination>`; not sent again"); `BACKUP_RCLONE_REMOTE` is sent every
   file again, as it always was. The row goes back to
   `Running` and ends `Succeeded`, or `Failed` again and still resumable. A
   database-only backup (S3 media adapter, or no media directory) resumes the
   same way.
3. **Cron:** run `backup.sh all` again (or wait for the next run). Cron has no
   resume; the next run is a new stamp.

A copy that failed (rather than was refused) is retried the same way, after
fixing what rclone reported: usually the remote's name, its credentials in
`rclone.conf`, or the network. With several destinations that applies only
when none was reached; a backup that reached some is not resumable, and the
next backup sends to every destination again.

### Send backups to several destinations

An in-app backup keeps its files in `BACKUP_DIR` and, when it is set,
copies them to `BACKUP_RCLONE_REMOTE`. On the **Destinations** tab of the
Backups page a platform admin adds more places to copy them to (#2220): a
directory on this server (a NAS mount, a second disk), a remote already
named in rclone's configuration, an S3-compatible bucket, or a kind a plugin
adds. Each backup is
then sent to every enabled destination, one after another, and a
destination that fails doesn't stop the others.

Destinations are used by **in-app backups only**. Cron (`scripts/backup.sh`)
never reads them, and still copies only to `BACKUP_RCLONE_REMOTE`.

**Before you start:** a running release with the `add_backup_destinations`
and `backup_run_destinations` migrations applied, a platform admin account,
and what the kind of destination needs:

- **Directory on this server:** `BACKUP_LOCAL_DESTINATION_ROOTS` set on
  every node, and the directory there on every node
  ([Let backups be written to a directory on this server](#let-backups-be-written-to-a-directory-on-this-server)).
- **Rclone remote:** the remote defined in rclone's own configuration on
  every node, as for `BACKUP_RCLONE_REMOTE`
  ([It needs the client tools in the image](#it-needs-the-client-tools-in-the-image)):
  an `rclone.conf` named by `RCLONE_CONFIG`, or `RCLONE_CONFIG_<NAME>_*`
  variables. The form takes only the remote's name, so no credential is
  stored in Kiln's database.
- **S3-compatible storage:** a bucket and an access key for it, and
  `BACKUP_S3_PRIVATE_HOSTS` for a store on your own network
  ([Back up to S3-compatible storage](#back-up-to-s3-compatible-storage)).

1. Open **Backups** (`/editor/backups`) and click the **Destinations** tab.
   The page is headed **Backup destinations**. When `BACKUP_RCLONE_REMOTE`
   is set, it is listed first, with its remote (credentials masked) and the
   badge "From BACKUP_RCLONE_REMOTE — change it in the server's
   environment". It can't be edited, tested or removed here, and what you
   add is sent to as well as it, never instead of it. With no destination at
   all, the list reads "No off-site destination: backups stay on this server
   only."
2. Click **Add a destination**. Under **What kind of destination?** pick
   **Directory on this server**, **Rclone remote**, **S3-compatible
   storage**, or a plugin's kind.
   **Directory on this server** is missing, with "A directory on this server
   can be added once BACKUP_LOCAL_DESTINATION_ROOTS lists where it may
   write.", until that variable is set.
3. Fill in the form:

   | Field | What it takes |
   |---|---|
   | **Name** | Required, unique, at most 80 characters. History and the alarm name the destination by it. |
   | **Path** (Directory on this server) | An absolute directory under one of `BACKUP_LOCAL_DESTINATION_ROOTS`, for example `/mnt/nas/kiln`. It need not exist yet below the root; it is created, mode 0700. |
   | **Remote name** (Rclone remote) | The name of a remote in rclone's configuration, without the colon: `nas`, not `nas:`. |
   | **Path** (Rclone remote) | Optional. The directory on that remote, for example a bucket and prefix: `kiln-backups/site`. |
   | **Enabled** | Ticked, backups are sent to it; unticked, it is kept but skipped. |
   | **Delete its old backups (retention)** | Ticked by default: prune it after each backup reaches it ([Retention on a destination](#retention-on-a-destination)). |

   A plugin's kind shows its own fields. A secret field is a password box
   that is never filled in again; on Edit, leaving it blank keeps the stored
   value.
4. Click **Save destination**. The button reads **Checking…** while the
   destination is validated: a directory against the rules
   [below](#let-backups-be-written-to-a-directory-on-this-server), a remote
   name against `rclone listremotes` on this node. Then "Destination added."
   appears, and the destination is a row in the list, with its kind, where
   it writes, a **Prunes its old backups** badge, and "Not tested yet".
5. Click **Test** on the row. It reads **Testing…** while it writes a small
   `kiln-test-<random>.txt` under `.kiln-test/` at the destination, reads it
   back and deletes it, at most 30 seconds. Then "NAS: the test passed (on
   kiln@node1)." and the row reads "Last test passed 2026-11-15 10:42 UTC on
   kiln@node1". A failure is "NAS: the test failed (on kiln@node1): …", with
   the reason. The test runs on the node serving the page. A backup's copy
   runs on the node that has the backup's directory, which can be another
   node, so on a cluster test what that node sees by taking a backup.
6. Go back to the **Backups** tab and click **Back up now**. While the
   backup is sent to more than one destination, the progress line reads, for
   example, "Copying off-site (2 of 3: NAS)". When it finishes, its History
   row has a chip per destination ("NAS · ok"), and **Where backups go**
   lists each destination under **Last in-app backup off-site**.

The arrows on each row (**Move NAS up**, **Move NAS down**) set the order
the stored destinations are sent to, always after `BACKUP_RCLONE_REMOTE`.
**Disable** keeps a destination without sending to it. At most eight can be
enabled at once, because the backup holds the cluster's backup lock while
it sends to each in turn. **Delete** asks "Delete the destination NAS?
Backups stop being sent to it; the files already there stay, and are no
longer pruned."

**Where a destination writes can't be changed.** On **Edit**, the location
fields (a directory's **Path**; a remote's **Remote name** and **Path**; an
S3 destination's **Endpoint**, **Bucket** and **Prefix**) are read-only, with "Where a destination writes can't be changed. To move
it, add a new destination and delete this one." Retention deletes only what
was sent to a destination, recorded against the destination itself, so
letting it point somewhere new would let it delete what it never sent
there ([ADR 0064](decisions/0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)).
For the same reason a new destination may not be, contain or sit inside
`BACKUP_RCLONE_REMOTE` or another destination. That check compares rclone
remote names and paths, and S3 endpoints, buckets and prefixes, so an rclone
`alias` remote, or two names for the same bucket, can't be caught: don't
point two destinations at one place.

Every add, change, delete and Test is in the
[instance security log](security-events.md#the-instance-log)
(`backup_destination_created`, `backup_destination_changed`,
`backup_destination_deleted`, `backup_destination_tested`), with the
destination's name and kind but never where it writes or a secret. The
staging scrub deletes every destination (`backup_destinations_purged`), so
a clone neither holds production's credentials nor sends to production's
destinations ([staging-environments.md](staging-environments.md)).

### Let backups be written to a directory on this server

A **Directory on this server** destination writes only under a directory
the operator lists in `BACKUP_LOCAL_DESTINATION_ROOTS`, so that a form in
the console can't put a database dump where the app serves files, or over
what it backs up. Set it in the app's environment on every node, for
example:

```bash
BACKUP_LOCAL_DESTINATION_ROOTS=/mnt/nas/kiln,/mnt/disk2/kiln-backups
```

- Comma-separated absolute directories; blank entries are ignored.
- **One unusable entry drops the whole list.** A relative path or one with
  a `..` segment makes the app warn at boot and offer no Local destination
  at all, rather than keep the other entries: a typo must not change where a
  dump may be written.
- Unset or blank, Local destinations aren't offered, and each backup records
  a stored one failed, its files' reason "Local destinations are off:
  BACKUP_LOCAL_DESTINATION_ROOTS is not set".
- Read in production and in development; `scripts/backup.sh` doesn't read
  it.

A destination's directory must be a root or inside one, and every time a
backup writes, lists or deletes there, on whichever node runs it, it is
checked again that:

- no component of its path, from `/` down, is a symbolic link;
- it is not inside, equal to, or above `BACKUP_DIR`, `MEDIA_DIR`,
  `priv/static`, or the public or private uploads directory;
- the root exists on that node (a root that was unmounted is refused, not
  written into).

Files land as `BACKUP_DIR` lays them out, `db/` and `media/` under the
destination's directory, mode 0600; a directory it has to create is made
mode 0700, and one that exists is left as it is. Each is
written as `<name>.<job>-<attempt>.partial` (the backup step's own
temporary name), hashed again and compared with the SHA-256
the backup verified, and only then renamed, under the backup lock and only
while that step still holds it, so a file that doesn't match
never appears under its real name, and a step that outlived its Cancel never
replaces the resumed backup's copy (#3041). A temporary file left by a node
that stopped mid-copy is removed by the next copy of that file once it is an
hour old. A file already in place with the same
size and SHA-256 is not copied again: the size is compared first, and only
a file of the right size is read whole to hash it, so a resend reads a
large media part back from the mount once instead of writing it
([Resumable uploads](#resumable-uploads)). Mount the same storage at the same path
on every node that can run backups: a node where the directory is missing
fails that destination for the backups it runs.

### Back up to S3-compatible storage

A destination of the kind **S3-compatible storage** sends each in-app
backup straight to a bucket over the S3 API (#2221): AWS S3, Cloudflare R2,
Backblaze B2, Wasabi, or a MinIO or Garage you run yourself. Unlike an
**Rclone remote**, it needs nothing in the image and nothing in rclone's
configuration: the form takes the endpoint, the bucket and a key pair, and
Kiln talks to the store itself. Large files go up in parts and resume where
they stopped ([Resumable uploads](#resumable-uploads)).

**Before you start:**

- a running release with the `add_backup_destinations`,
  `backup_run_destinations` and `add_backup_uploads` migrations applied, and
  a platform admin account;
- a bucket, and an access key that may use it
  ([Give the key only what it needs](#give-the-key-only-what-it-needs));
- for a store on your own network or reached over `http://`, its host name
  in `BACKUP_S3_PRIVATE_HOSTS` on every node
  ([Reach a store on your own network](#reach-a-store-on-your-own-network)).

1. Open **Backups** (`/editor/backups`), click the **Destinations** tab, then
   **Add a destination**.
2. Under **What kind of destination?** pick **S3-compatible storage**. The
   form shows the fields below, and under them the hint "Add a lifecycle rule
   to the bucket that aborts incomplete multipart uploads after a few days:
   Kiln aborts the uploads it recorded, but not one a crash left before it
   could record it."
3. Fill in the form. The values for each provider are in
   [Settings for each provider](#settings-for-each-provider).

   | Field | What it takes |
   |---|---|
   | **Name** | Required, unique, at most 80 characters, for example `Offsite S3`. |
   | **Endpoint** | The store's URL, scheme and host only (a port is allowed, a path is not): `https://s3.us-east-1.amazonaws.com`. Must be `https://` unless `BACKUP_S3_PRIVATE_HOSTS` lists the host. |
   | **Region** | The bucket's region, lowercase letters, digits and `-`: `us-east-1`, `auto` for R2. |
   | **Bucket** | The bucket's name, 3 to 63 lowercase letters, digits, dots and hyphens. |
   | **Prefix** | Optional. A folder in the bucket to keep the backups under, for example `kiln/site`. Slashes at either end are dropped; no `.` or `..` segment. |
   | **Path style** | Ticked, the bucket goes in the URL's path (`https://host/bucket/…`) rather than its host name (`https://bucket.host/…`). Tick it for MinIO and Garage. A bucket name with a dot, or an endpoint that is an IP address, is always addressed this way. |
   | **Access key** | The access key id. A password box: stored encrypted and never shown again. |
   | **Secret access key** | The secret. The same: stored encrypted and never shown again. |
   | **Enabled**, **Delete its old backups (retention)** | As for every destination ([above](#send-backups-to-several-destinations)). |

4. Click **Save destination**. While it reads **Checking…**, Kiln checks the
   settings and looks the endpoint up in DNS (the host it will connect to:
   `<bucket>.<host>` unless path-style). It does not contact the store yet.
   Then "Destination added." appears, and the row reads, for example,
   `s3://kiln-backups/kiln/site (s3.us-east-1.amazonaws.com)`.
5. Click **Test** on the row. In at most 30 seconds it:
   1. checks the bucket (`HeadBucket`), and compares the store's clock with
      this server's;
   2. lists one key under the prefix;
   3. writes `kiln-test-<random>.txt` under `<prefix>/.kiln-test/`, reads it
      back and deletes it (the delete is tried even when the read fails).

   "Offsite S3: the test passed (on kiln@node1)." means a backup can be sent
   there. A failure names the step that failed, for example "Offsite S3: the
   test failed (on kiln@node1): checking the bucket: the bucket does not
   exist" ([What can go wrong with an S3 destination](#what-can-go-wrong-with-an-s3-destination)).
6. Click **Back up now** on the **Backups** tab. When it finishes, the
   History row has the chip "Offsite S3 · ok", and the bucket holds
   `kiln/site/db/kiln-db-<stamp>.dump` and its `.sha256`, and the media
   files under `kiln/site/media/`, laid out as in `BACKUP_DIR`.

The endpoint, bucket and prefix can't be changed after saving, as for every
destination's location; the region, **Path style** and the keys can. On
**Edit**, leave a key blank to keep the stored one.

<a id="give-the-key-only-what-it-needs"></a>

#### Give the key only what it needs

Create a key for Kiln alone, allowed on this bucket and nothing else. It
needs six permissions:

| Permission | Used for |
|---|---|
| `s3:ListBucket` | The Test's `HeadBucket` and listing, retention's listing, and telling a missing file from a refused one. Without it a store answers `403`, not `404`, for a file that isn't there, so every upload reads as refused access. |
| `s3:PutObject` | Uploading, in one request or in parts. |
| `s3:GetObject` | The Test's read-back, and checking whether a file is already there. |
| `s3:DeleteObject` | Retention, and removing the Test's file. |
| `s3:AbortMultipartUpload` | Aborting an upload Kiln recorded and no longer needs. |
| `s3:ListMultipartUploadParts` | Checking what the store holds before resuming an upload. |

An AWS IAM policy for the bucket `kiln-backups` and the prefix `kiln/site`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KilnBackupsBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::kiln-backups"
    },
    {
      "Sid": "KilnBackupsObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::kiln-backups/kiln/site/*"
    }
  ]
}
```

Grant `s3:ListBucket` on the whole bucket, without an `s3:prefix`
condition: `HeadBucket`, and the listing Kiln makes to explain a refused
`HEAD`, are not limited to the prefix. Wasabi and MinIO take the same
policy document. On R2 and B2, give the key read and write access to this
bucket only (below).

<a id="settings-for-each-provider"></a>

#### Settings for each provider

| Provider | Endpoint | Region | Path style |
|---|---|---|---|
| AWS S3 | `https://s3.<region>.amazonaws.com`, for example `https://s3.eu-west-1.amazonaws.com` | the bucket's region, `eu-west-1` | off |
| Cloudflare R2 | `https://<account id>.r2.cloudflarestorage.com` (`<account id>.eu.r2.cloudflarestorage.com` for an EU-jurisdiction bucket) | `auto` | off |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com`, for example `https://s3.us-west-004.backblazeb2.com` (the bucket's "Endpoint" in B2's console) | the region in that host, `us-west-004` | off |
| Wasabi | `https://s3.<region>.wasabisys.com`, for example `https://s3.us-central-1.wasabisys.com` | the bucket's region, `us-central-1` | off |
| MinIO on your network | `http://minio.lan:9000`, or `https://` if it has a certificate | `us-east-1` unless you set another in MinIO | on |
| Garage on your network | `http://garage.lan:3900` | the `s3_region` in Garage's config (`garage` in its sample config) | on |

- **AWS S3.** Use the regional endpoint of the bucket's region. A bucket in
  another region than the one you enter fails at once, with the region the
  store names: "the bucket is in the region eu-west-1; set the region (and
  endpoint) to match". Use the policy above.
- **Cloudflare R2.** Create an R2 API token with **Object Read & Write**,
  limited to the bucket; it gives an access key id and a secret access key.
  The region is always `auto`.
- **Backblaze B2.** Create an application key limited to the bucket, with
  read and write access. The **keyID** is the access key and the
  **applicationKey** the secret.
- **Wasabi.** Create an access key for a sub-user with the policy above.
  Wasabi may bill a deleted object for a minimum storage period, so
  retention's deletes don't lower the bill right away; check your plan.
- **MinIO or Garage** on your own network: see the next section.

<a id="reach-a-store-on-your-own-network"></a>

#### Reach a store on your own network

The endpoint is typed into a form, so Kiln treats it as it treats a webhook
URL: by default it must be `https://`, and its host must resolve only to
public addresses. To allow a MinIO or Garage on your network, the operator
lists its host in `BACKUP_S3_PRIVATE_HOSTS`, on every node:

```bash
BACKUP_S3_PRIVATE_HOSTS=minio.lan
```

and the destination uses `http://minio.lan:9000`, region `us-east-1`, with
**Path style** ticked.

- **List the name Kiln connects to.** With **Path style** ticked that is the
  endpoint's host, `minio.lan`. Without it, it is `<bucket>.<host>`, for
  example `kiln-backups.minio.lan`, which must then be listed instead (and
  resolve). Listing a host opens none of its subdomains. Ticking **Path
  style** is usually simpler.
- **Exact names only**, comma-separated, case-insensitive. An IP address
  works too (`10.0.0.5`, or `fd12::5` for `http://[fd12::5]:9000`). An entry
  with a scheme, a port, a path or a `*` is ignored.
- **A listed host may** use `http://`, resolve to a private or loopback
  address, and be a `localhost`, `.local` or `.internal` name.
- **Nothing opens** a link-local or cloud-metadata address
  (`169.254.0.0/16`, `fe80::/10`, `fd00:ec2::254`), including one reached
  through a NAT64 (`64:ff9b::/96`) or 6to4 (`2002::/16`) address, nor a
  metadata host name such as `metadata.google.internal`.
- It is read in every environment, so a MinIO in development works as in
  production. `scripts/backup.sh` doesn't read it
  ([environment-variables.md](environment-variables.md#in-app-backups-484)).

The address is checked when the destination is saved and again before every
call, and each call connects to the address it checked, so a name that
starts resolving somewhere else is refused rather than followed. A redirect
from the store is never followed either. Two limits follow from the DNS
lookup:

- **A name that doesn't resolve can't be saved.** Save looks it up on the
  node serving the page, so a store only the backup nodes can resolve must
  be resolvable there too.
- **A host name with only IPv6 (AAAA) addresses can't be saved:** it reads
  as not resolving. Give the store an IPv4 address, or enter its IPv6
  address as the endpoint (`https://[2001:db8:1::5]`).

Why the policy is this one is in
[ADR 0069](decisions/0069-an-admin-entered-backup-endpoint-is-pinned-per-call-and-only-the-operator-opens-private-hosts.md).

<a id="set-a-lifecycle-rule-for-unfinished-uploads"></a>

#### Set a lifecycle rule for unfinished uploads

A file of 16 MiB or more goes up as a multipart upload. Until it is
completed or aborted, the parts sent so far cost storage, and they don't
show in a normal listing. Kiln aborts the uploads it recorded when they are
no longer needed ([When Kiln aborts an upload](#resumable-uploads)), but
never one it has no record of: an upload cut off before its first
checkpoint was saved, one on a destination you deleted, one whose record a
database restore lost. Add a lifecycle rule to the bucket as the backstop.
On AWS, with the AWS CLI:

```json
{
  "Rules": [
    {
      "ID": "abort-incomplete-multipart-uploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "kiln/site/" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket kiln-backups --lifecycle-configuration file://lifecycle.json
```

This replaces the bucket's whole lifecycle configuration: if it has rules
already, add this one to them (`aws s3api get-bucket-lifecycle-configuration`
shows them). Keep it to four days or more, so it never aborts an upload
Kiln could still resume. Other providers set the same rule in their console
or through the same API call, where they support it; check theirs.

<a id="how-an-upload-to-s3-works"></a>

#### How an upload to S3 works

- **A file already there is not sent again.** Before each upload Kiln asks
  for the object (`HEAD`). One with the same size and the same
  `x-amz-meta-kiln-sha256` metadata is recorded as sent.
- **Files under 16 MiB** (the dumps' `.sha256` sidecars, a small database)
  go in one request, with `Content-MD5`, so the store checks what arrived.
- **Larger files** go in parts of at least 16 MiB, one after another, each
  with `Content-MD5`; a file that would need more than 9,000 parts gets
  larger parts, in whole MiB. Each acknowledged part is recorded. Before the
  upload is completed, the file's SHA-256, computed while reading the parts,
  must equal the one the backup verified, and after it is completed Kiln
  reads the object's size and `x-amz-meta-kiln-sha256` back to confirm.
- **Resuming** asks the store which parts it holds (`ListParts`) and checks
  them against the record, by part number, ETag and size. ETags are not
  assumed to be MD5s, so a bucket with SSE-KMS or MinIO's encryption resumes
  as well. Anything that doesn't match aborts that upload and starts the
  file over.
- **Every object carries `x-amz-meta-kiln-sha256`**, the file's SHA-256.
  A multipart object's ETag is not its MD5, so check a download against
  this metadata or the backup's `.sha256` file, not the ETag.
- **A file over 5 TiB** (S3's largest object) is refused before anything is
  sent.

**Failures.** A request that fails for a reason that may pass (a `5xx`,
`SlowDown`, a `429`, a timeout, a dropped connection, any `4xx` Kiln has no
rule for) is retried up to six times in all, after a random wait of up to
1, 2, 4, 8 and 16 seconds, and no retry starts within
30 seconds of the step's deadline. A failure no retry fixes fails the
destination at once, without the backup's other attempts
([Resumable uploads](#resumable-uploads)): refused credentials, a missing
bucket, the wrong region, a clock more than five minutes off the store's,
a part or a file the store refuses (`InvalidPart`, `EntityTooLarge`), a file
over 5 TiB. Kiln writes its own sentence for each, naming the store's error
code; it never shows the text a store sends with it.

Each request emits the `[:kiln_cms, :backups, :s3, :request]` telemetry
event, with its `duration`, `operation`, `method`, `status` and `class`
(`:ok`, `:transient`, `:permanent`, …), and never a key, a URL, a header or
a body.

<a id="retention-on-an-s3-bucket"></a>

#### Retention on an S3 bucket

Retention works as on any destination
([Retention on a destination](#retention-on-a-destination)), with these
limits:

- **Not while `BACKUP_RCLONE_REMOTE` is set.** An rclone remote can name the
  same bucket under any name, so Kiln can't tell that the two don't overlap.
  Each pass is skipped with "can't confirm it doesn't overlap
  BACKUP_RCLONE_REMOTE; nothing was deleted", as for a plugin's destination
  ([ADR 0064](decisions/0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)).
  Untick retention on the S3 destination and use a lifecycle rule, or unset
  `BACKUP_RCLONE_REMOTE`.
- **Two S3 destinations overlap** only when they have the same endpoint host
  and port (case and the default port ignored) and the same bucket, and one
  prefix is inside the other. Such a destination can't be saved. Two names
  for one store are not caught: `s3.amazonaws.com` and
  `s3.us-east-1.amazonaws.com`, or a MinIO by name and by IP address, look
  like two stores. **Don't point two destinations at one bucket** unless
  their prefixes are separate.
- **A versioned bucket keeps what retention deletes.** A delete there adds a
  delete marker and keeps the old version, which still costs storage. Add a
  lifecycle rule that expires noncurrent versions, or use a bucket without
  versioning.
- **Object Lock keeps locked versions** until their retention date,
  whatever Kiln deletes. If you lock backups, size the lock to your
  retention, or untick retention here.

<a id="what-can-go-wrong-with-an-s3-destination"></a>

#### What can go wrong with an S3 destination

When saving:

| Message | Meaning |
|---|---|
| "the endpoint must use https:// (http:// only for a host in BACKUP_S3_PRIVATE_HOSTS)" | An `http://` endpoint whose host isn't listed. Use `https://`, or list the host ([above](#reach-a-store-on-your-own-network)). |
| "the endpoint resolves to a private or loopback address; list its host in BACKUP_S3_PRIVATE_HOSTS to allow it" | A store on your network. List the name Kiln connects to. |
| "the endpoint must not be a .local or .internal host unless BACKUP_S3_PRIVATE_HOSTS lists it", "the endpoint must not be a loopback host" | As it says. |
| "the endpoint resolves to a link-local or metadata address, which no setting allows", "the endpoint must not be a metadata host" | No listing allows these. |
| "kiln-backups.minio.lan: hostname could not be resolved" | The name Kiln connects to doesn't resolve on this node. Without **Path style** that is `<bucket>.<host>`: tick **Path style**, or fix DNS. A host with only IPv6 addresses reads this way too. |
| "the endpoint must not have a path", "the endpoint must be a bare URL", "the endpoint must not contain credentials" | Enter the scheme, host and port only. The bucket goes in **Bucket**, the folder in **Prefix**, the keys in their own fields. |
| "the bucket name must be 3 to 63 lowercase letters, digits, dots and hyphens, …" and the other bucket-name messages | The name breaks S3's naming rules. |
| "the region must be lowercase letters, digits and hyphens, e.g. us-east-1 or auto" | As it says. |
| "the prefix must be folder names of letters, digits, dots, hyphens and underscores, separated by /" | No spaces or other characters, no `.` or `..` folder. |
| "the access key id must not contain spaces" | Usually a paste with a space in it. |
| "this is, contains or is inside another destination; choose a place of its own" | Another S3 destination has this bucket on this endpoint with a prefix inside or around this one. |

On a Test or a backup (on a Test, after the step: "checking the bucket: …"):

| Error | What to do |
|---|---|
| "the store refused access (AccessDenied); check the key's permissions", "the store refused to read the file (AccessDenied); …" | The key lacks a permission ([above](#give-the-key-only-what-it-needs)), often `s3:ListBucket`, or the bucket's own policy refuses it. |
| "the store doesn't know the access key id (InvalidAccessKeyId)", "the store refused the secret access key (SignatureDoesNotMatch)" | Re-enter both keys on **Edit**. |
| "the bucket does not exist (NoSuchBucket)", "the bucket does not exist" | Check **Bucket** and the endpoint (an R2 bucket is under its account's endpoint). |
| "the bucket is in the region eu-west-1; set the region (and endpoint) to match", "the bucket is in another region or behind another endpoint; …", "the store refused the request's region (AuthorizationHeaderMalformed); check the region" | The region, or the endpoint, is not the bucket's. |
| "this server's clock is more than 5 minutes off the store's (RequestTimeTooSkewed); fix the clock (NTP)" | Fix the server's clock; no retry helps. |
| "the endpoint answered with a redirect (HTTP 302); check the endpoint" | The endpoint is not the store's S3 API (a web console's address, say). Kiln never follows a redirect. |
| "the store refused a part of the upload (InvalidPart)", "the file is larger than the store accepts (EntityTooLarge)" | The store refused the upload for good; that upload is aborted. The next backup starts the file over. |
| "the store failed the request (HTTP 500, InternalError)", "the store asked to slow down (SlowDown)", "couldn't reach the store (timeout)", "the store refused the request (HTTP 400)" | Retried six times; this is the last answer. The next attempt of the step tries again, continuing the upload. |
| "the store's answer was larger than the 8388608 bytes expected; it was cut off" | The store sent far more than an S3 answer holds. Check the endpoint. |
| "kiln-media-20261117-031700.part01.tar.gz is larger than the 5 TiB an S3 object can hold" | S3 holds no larger object, so this file can't go to an S3 destination; nothing was sent. |
| "the file read back doesn't match its sha256; it was not kept" | A read from the store didn't match the object's `x-amz-meta-kiln-sha256`. |
| "… timed out after 30 s" (a Test) | The store didn't answer in time, or its retries ran past the Test's 30 seconds. |

### Manage destinations from a release console

The tab's code interfaces work from a release console too, with an actor
whose effective platform role is admin. This adds a Local destination
(`BACKUP_LOCAL_DESTINATION_ROOTS=/mnt/nas`) and tests it:

```bash
bin/kiln_cms rpc '
admin = KilnCMS.Accounts.get_user_by_email!("you@example.com", authorize?: false)

{:ok, d} =
  KilnCMS.Backups.create_backup_destination(
    %{name: "NAS", kind: "local", settings: %{"path" => "/mnt/nas/kiln"}},
    actor: admin
  )

{:ok, d} = KilnCMS.Backups.test_destination(d.id, actor: admin)
IO.inspect(Map.take(d, [:name, :kind, :enabled, :prune, :settings, :last_test_ok, :last_test_error]))'
# %{enabled: true, kind: "local", last_test_error: nil, last_test_ok: true,
#   name: "NAS", prune: true, settings: %{"path" => "/mnt/nas/kiln"}}
```

`kind` is `"local"`, `"rclone"` (settings `"remote_name"` and `"path"`),
`"s3"` (settings `"endpoint"`, `"region"`, `"bucket"`, `"prefix"` and
`"path_style"`, a boolean; secrets `"access_key_id"` and
`"secret_access_key"`), or a plugin's kind; secret fields go in a
`secrets:` map beside `settings`. A refused save is `{:error, %Ash.Error.Invalid{}}` with the
messages in the table [below](#what-can-go-wrong-with-a-destination). The
other calls, each with `actor: admin`:
`KilnCMS.Backups.list_backup_destinations/1`,
`get_backup_destination(id, actor: admin)` (`{:ok, nil}` when there is
none), `update_backup_destination(d, %{enabled: false}, actor: admin)` and
`destroy_backup_destination(d, actor: admin)`. A test that fails still
returns `{:ok, d}`, with `last_test_ok: false` and the reason in
`last_test_error`.

### When a backup reaches only some destinations

A backup that reached at least one of its destinations but not all of them
**succeeds, partly off-site**. Its local files are as good as any backup's,
and at least one copy left the host, so it still counts as the last good
backup; but a destination you added for safety has stopped receiving
backups, so it raises the backup alarm. The reasoning is in
[ADR 0063](decisions/0063-each-backup-destination-is-its-own-step-and-a-run-that-reaches-only-some-is-partly-off-site.md).

Where it shows:

- **History:** the row is `Succeeded` and badged **Partly off-site**. Each
  destination is a chip with how it fared ("NAS · failed"); hover a failed
  one for its error.
- **Backups page:** the headline, in the alarm's red, adds "The last backup
  reached 1 of 2 off-site destinations — NAS failed", and **Where backups
  go** lists each destination of the last in-app backup with its error.
- **Home page:** platform admins' backup strip turns red with the same line.
- **The run's log:** "Partly off-site: reached 1 of 2 destination(s); not
  reached: NAS", also logged as an error on the server, with the
  `[:kiln_cms, :backups, :offsite, :partial]` telemetry event.

**It can't be resumed.** It succeeded, so its work directory is gone, and
**Resume** is only on failed, interrupted and canceled runs. Fix the
destination (its error and its **Test** button say what is wrong), then
**Back up now** or wait for the next backup, which tries every destination
again. The alarm clears when an in-app backup reaches all its destinations.

A backup that reached **none** of its destinations fails, as a failed
`BACKUP_RCLONE_REMOTE` copy always did, with "Off-site copy FAILED to every
destination (2): NAS: …; offsite-b2: …" naming each one, and it can be
resumed.

Two other badges and states:

- **Off-site unknown:** a succeeded backup that recorded no outcome for its
  destinations, which happens when a node of an older release finished it
  during an upgrade. Check the destinations, and take a new backup.
- **The stored destinations couldn't be read** when the backup started
  (the database refused the read four times): the backup is sent to
  `BACKUP_RCLONE_REMOTE` alone, if it is set, and records "Couldn't read the
  backup destinations; this backup is sent only to BACKUP_RCLONE_REMOTE".
  It reads partly off-site, never complete, whatever the env remote did.

### Retention on a destination

With **Delete its old backups (retention)** ticked, a destination is pruned
right after each backup reaches it, by the same keep rules as `BACKUP_DIR`
([What retention deletes and what it keeps](#what-retention-deletes-and-what-it-keeps)):
`BACKUP_KEEP_DAYS`, the schedules' keep settings, and never the newest
verified or newest complete backup of each component that destination
holds. A `.keep` recovery point in `BACKUP_DIR` keeps that backup on every
destination too. The markers themselves are never copied to a destination.

**It deletes only what this installation sent there.** A backup is deleted
from a destination only when its History row records it being sent to that
destination. Anything else that looks like a Kiln backup there (another
installation sharing the bucket, a cron backup copied by hand) is left
alone, and each run's log names it: "Retention on NAS left 2 old backup(s)
this installation has no record of sending there: db 20261101-031700,
media 20261101-031700". The reasoning is in
[ADR 0064](decisions/0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md).

It never runs on `BACKUP_RCLONE_REMOTE`, which the app has never pruned,
nor on a destination whose adapter can't list and delete files (a plugin's
says so). What it did is on the run's log:

| Log line | Meaning |
|---|---|
| "Retention on NAS removed 4 file(s) from 2 backup(s)" | Those backups were deleted there, and are marked `pruned` for that destination in History. |
| "Retention on NAS skipped: it overlaps BACKUP_RCLONE_REMOTE; nothing was deleted" | The destination is, contains or is inside the env remote, which changed since the destination was added. Point the two at separate places. |
| "Retention on NAS skipped: it overlaps another backup destination; nothing was deleted" | Two destinations share a place. Delete one. |
| "Retention on NAS skipped: can't confirm it doesn't overlap BACKUP_RCLONE_REMOTE; nothing was deleted" | A plugin's destination, whose location Kiln can't compare, or an S3 destination, which can't be compared with an rclone remote, while `BACKUP_RCLONE_REMOTE` is set ([Retention on an S3 bucket](#retention-on-an-s3-bucket)). Untick retention on it and prune it yourself, or unset the env remote. |
| "Retention on NAS skipped: couldn't list the destination (…); nothing was deleted" | The listing failed. Nothing is deleted on a guess. |
| "Retention on NAS removed … , then stopped: couldn't delete … (…)" | A delete failed; the pass stopped there. The next backup tries again. |

A skipped or stopped pass is also a line in the **Backups** page's
headline and on **Home**'s red backup strip, "Retention on NAS was skipped
on the backup of 2026-11-16 02:00 UTC: … Nothing was deleted there, so
backups will build up there until this is fixed.", until a clean pass on
that destination, or until you untick retention on it, disable it or
delete it (#2487). It emits the same
`[:kiln_cms, :backups, :retention, :skipped]` and `… :stopped` events as
local retention, with `scope: :destination` and the destination's key
([When retention is skipped or stops](#when-retention-is-skipped-or-stops)).

A failed or skipped pass doesn't change the destination's upload status:
the backup reached it. A backup that later fails at another destination
may already have pruned the destinations before it; only older backups
the keep rules allowed deleting go.

### Keep destination credentials outside Kiln

In a full loss, the database that lists your destinations is one of the
files on them. Keep, outside Kiln and with `SECRET_KEY_BASE` (in the same
password manager), what you need to reach each destination without the app:
where it writes, and its credentials.

- **Rclone remotes** keep their credentials in rclone's configuration
  (`rclone.conf` or `RCLONE_CONFIG_<NAME>_*`), never in the database. Back
  that configuration up as you would the app's environment.
- **An S3 destination's** endpoint, bucket, prefix and region are on its
  row; keep them, and the key pair (or a way to make a new one), outside
  Kiln. Its two keys are secret fields, stored as below.
- **A plugin's destination** may have secret fields. Those are stored in
  the database, encrypted with a key derived from `SECRET_KEY_BASE`, and
  never shown again. Rotating `SECRET_KEY_BASE` keeps them with
  `PREVIOUS_SECRET_KEY_BASE` and `mix kiln.vault.reencrypt`
  ([secrets-rotation.md](secrets-rotation.md#data-at-rest-re-encrypt-before-you-retire-the-old-value)).
  A database restored under another `SECRET_KEY_BASE` can't open them: each
  backup then records that destination failed with "credentials can't be
  decrypted (was SECRET_KEY_BASE changed?); re-enter them". Open **Edit**,
  enter the secret fields again and **Save destination**.

### What can go wrong with a destination

An S3 destination's own messages are in
[What can go wrong with an S3 destination](#what-can-go-wrong-with-an-s3-destination).

When saving (the form shows the message under the field, or above the form):

| Message | Meaning |
|---|---|
| "… is not under BACKUP_LOCAL_DESTINATION_ROOTS (…)" | The path is outside every root. Pick a directory under one, or add a root to the variable. |
| "… overlaps BACKUP_DIR (…); choose a directory outside it" (or `MEDIA_DIR`, `priv/static`, the uploads directory, the private uploads directory) | The path is inside, equal to, or above one of the app's own directories. |
| "… is a symbolic link; a destination's path must have none" | A component of the path is a link. Use the real path. |
| "… does not exist on this server" | The root itself, or a component above it, is missing on the node serving the page. |
| "the path must be absolute", "the path must not contain .." | As it says. |
| "rclone has no remote named nas; define it in rclone.conf first" | `rclone listremotes` on this node doesn't list it. Define the remote, then save again. |
| "the remote name must be the name of a remote in rclone.conf, without a colon" | **Remote name** holds something a plain remote name can't: a colon, a comma or a slash (so no connection string or local path), or it doesn't start with a letter, a digit or `_`. Name a configured remote. |
| "rclone is not installed in this image" | The image has no `rclone` ([It needs the client tools in the image](#it-needs-the-client-tools-in-the-image)). |
| "this is, contains or is inside another destination; choose a place of its own" | It overlaps `BACKUP_RCLONE_REMOTE` or a stored destination. |
| "at most 8 destinations can be enabled" | Disable or delete one first, or save this one unticked. |
| "where a destination writes can't be changed; add a new destination instead" | A change to the location sent from outside the form. |
| "the stored credentials can't be decrypted (was SECRET_KEY_BASE changed?); enter them again" | Enter every secret field again ([above](#keep-destination-credentials-outside-kiln)). |
| "the other backup destinations couldn't be read; try again" | The checks for the cap and overlaps couldn't read the list. Nothing was saved. |
| "Only a platform admin can change backup destinations." | Your account is no longer a platform admin. |

On a backup's run, as a destination's error (the chip's tooltip, and the
**Last in-app backup off-site** list):

| Error | Meaning |
|---|---|
| "FAILED for 2 files: kiln-db-20261115-031700.dump (…), …" | Those files' copies still failed on the step's last attempt, or one of them failed permanently on an earlier one. In the brackets is each one's reason: rclone's output, the adapter's error, or one of the reasons below. |
| "REFUSED for 1 file: kiln-media-20261115-031700.part02.tar.gz (changed on disk after this backup verified it (…))" | The file changed after the backup verified it, and the whole backup failed ([When an off-site copy is refused](#when-an-off-site-copy-is-refused)). |
| (in the brackets) the adapter's own sentence, on the first attempt | The adapter said no retry fixes it (the bucket doesn't exist, the credentials are refused for good). The destination failed at once, without waiting for the backup's other attempts, and the backup went on to the next destination ([Resumable uploads](#resumable-uploads)). Fix what it names; the next backup tries it again. |
| (in the brackets) "… timed out after …" | A call ran past what was left of the step's run time, or past `call_timeout` ([below](#how-long-a-destination-may-take)). The rest of that destination's files wait for the next attempt. |
| (in the brackets) "Local destinations are off: BACKUP_LOCAL_DESTINATION_ROOTS is not set", "… does not exist on this server" | The node that ran the backup has no roots, or not this directory ([above](#let-backups-be-written-to-a-directory-on-this-server)). |
| "removed or disabled during this backup" | The destination was deleted or disabled after the backup started. |
| "not attempted: its off-site step never ran" | A node of an older release ran the off-site step during an upgrade. |
| "rclone is not installed in this image" | The node that ran the backup has no `rclone`. No retry fixes it, so it fails at once. |
| "credentials can't be decrypted (was SECRET_KEY_BASE changed?); re-enter them" | [Above](#keep-destination-credentials-outside-kiln). |
| "the adapter for this destination is not installed (was its plugin removed?)" | A plugin's destination whose plugin is gone. Reinstall it, or disable or delete the destination. |
| (in the brackets) "stopped before the step's time ran out; the upload resumes on the next attempt" | A resumable adapter stopped at the step's deadline, having recorded how far it got. The rest of that destination's files wait for the next attempt, which continues the upload. |
| (in the brackets) "a later attempt of this backup took over the upload" | This step lost its lease to a newer one (a retry, or a step that took over from a node that went away), which owns the upload now. |
| (in the brackets) "MyPlugin.BackupDestination.put/3 returned an unexpected value" | A plugin's `put/3` answered something the contract doesn't allow. That file counts as failed; report it to the plugin's author. |

### How long a destination may take

Each upload, listing and delete on a destination may take as long as what
is left of the off-site step's own run time (two hours per attempt) less
five minutes, kept to record the outcome; a call that runs past it is
stopped and counts as that destination's failure for the attempt. To stop
a hanging destination sooner, cap every call:

```elixir
# config/runtime.exs (or your overlay's config/project.exs)
config :kiln_cms, KilnCMS.Backups.Destination, call_timeout: :timer.minutes(30)
```

The cap applies to each call, so a large media set with many parts still
gets as many calls as it has files. A Test is held to 30 seconds and the
adapter's checks on Save to 30 seconds, whatever the cap.

### Resumable uploads

A large file can be cut off part-way to a destination: the step's time runs
out, the connection drops, the node goes away, or a newer step takes the
backup over. On a destination whose adapter can resume, the next attempt
continues that upload from where it stopped instead of sending the whole
file again (#2223).

**Which destinations resume.** An **S3-compatible storage** destination
([Back up to S3-compatible storage](#back-up-to-s3-compatible-storage)), and
a plugin's adapter that opts in ([below](#a-plugin-opts-in)). A **Directory
on this server**, an **Rclone remote** and `BACKUP_RCLONE_REMOTE` send each
file whole, as before. There is nothing to configure. The upgrade only needs
`mix ash.migrate`, which creates the `backup_uploads` table.

**What is recorded, and where.** One row in `backup_uploads`, in Kiln's
database, per file being uploaded to a destination
(`KilnCMS.Backups.Upload`). It holds:

- the destination's key, which is its id plus a fingerprint of where it
  writes, so a row never follows a destination to another place;
- the file's directory (`db` or `media`), name and backup stamp, and the
  size and SHA-256 it verified with;
- the adapter's checkpoint and how far the upload got (`bytes_done`);
- the status: `open`, `abandoned`, `completed` or `aborted`;
- the Oban job and attempt of the step that owns it, how many steps have
  worked on it, and the last error.

The checkpoint is the adapter's own small state, such as the store's upload
id and the parts it has acknowledged. It is at most 8 KiB of JSON and never
a credential. A row is written on the adapter's first checkpoint, so an
upload that never saved one leaves no row. Nothing shows the table: not the
Backups page, not History, not any API. Only the backup pipeline reads or
writes it ([policy matrix](policy-matrix.md#backup-uploads)),
and the staging scrub empties it (`backup_uploads_purged`).

**Only the newest step may continue an upload.** Each row belongs to one
step, named by its Oban job id and attempt. A step may take a row over only
if it is at least as new as the owner: a retry of the same job (a higher
attempt), or a step that took the backup over from a node that went away (a
newer job). Job ids and attempts only grow, so ownership only moves forward.
A step that has lost its lease ([Several nodes and the backup
lock](#several-nodes-and-the-backup-lock)) can no longer record progress.
Its next save matches no row, its adapter is told the upload was superseded
and stops, and the progress of the step that took over stands. The reasoning
is in [ADR 0068](decisions/0068-a-resumable-backup-upload-is-recorded-by-the-installation-that-started-it-and-only-it-aborts-it.md).

**Only the same file resumes.** A checkpoint is handed back only for a file
with the size and SHA-256 the upload started with. If the file changed (a
**Resume** rebuilt it), its old upload is abandoned and aborted, and the
upload starts over. An adapter also checks what the store holds before it
trusts a checkpoint.

**A file already there is not sent again.** An adapter may answer that the
destination already holds this file with the same size and SHA-256. Kiln
then records it as sent, exactly as if it had just uploaded it, and the
run's log reads "kiln-db-20261117-031700.dump was already on NAS with the
same checksum; not sent again". A **Directory on this server** answers this
way ([above](#let-backups-be-written-to-a-directory-on-this-server)). Such a
file is then retention's to delete on that destination like any file this
installation sent there. The same stamp and SHA-256 make it the same backup.

**Permanent and transient failures.** An adapter may say a failure is
permanent, meaning no retry fixes it: the bucket doesn't exist, or the
credentials are refused for good. That destination then fails on the
attempt it happened in, without spending the backup's other attempts, and
the backup goes on to the next destination. The adapter's sentence is the
destination's error. Every other failure is transient: a timeout, a dropped
connection, a store that answered 500. The destination is tried again on the
step's next attempt (after 1, 5, then 15 minutes, four attempts in all), and
an open upload is kept, with its error, for that attempt to continue. A
refused file is unchanged by any of this. It still fails the whole backup
([When an off-site copy is refused](#when-an-off-site-copy-is-refused)).

**When Kiln aborts an upload.** On most stores an unfinished upload costs
storage until it is aborted, but an aborted one can't be resumed. Kiln
aborts an upload it recorded only when:

- it failed permanently;
- the file changed since the upload started;
- the destination turned out to hold the file already, while an upload of
  it was under way;
- the sweep finds it abandoned, or open and untouched for four days.

A timeout or a transient error never aborts an upload: the next attempt
needs it. An abort that fails leaves the row `abandoned`, for the sweep to
try again.

**The sweep.** Each time a backup reaches a destination, Kiln aborts that
destination's recorded uploads that were abandoned, or left open and
untouched for four days. Four days is longer than any backup's retries and
reclaims, and than the three-day sweep of old work directories. The sweep
runs before retention, and it runs whether or not **Delete its old backups
(retention)** is ticked. It takes at most 50 uploads per pass, starts no
abort within 30 seconds of the step's deadline for destination calls, and
never touches an
upload of the backup that holds the backup lock. The run's log reads
"Aborted 2 unfinished upload(s) on NAS", with "; 1 couldn't be, and are
tried again later" when some aborts failed. The pass is also the
`[:kiln_cms, :backups, :upload, :swept]` telemetry event, with `aborted` and
`failed` counts and the destination's key as `destination`. Then, whichever
destination was reached, rows that closed (`completed` or `aborted`) more
than 30 days ago are deleted, and so is every row of a deleted destination
once it is 30 days old.

**Time limits.**

- **The step: 2 hours.** Each attempt of the off-site step may run two
  hours. Every call to a destination must be done five minutes before that,
  or sooner with `call_timeout`
  ([How long a destination may take](#how-long-a-destination-may-take)). A
  resumable adapter that watches the deadline stops cleanly with its
  progress saved. The destination's error then reads "stopped before the
  step's time ran out; the upload resumes on the next attempt". One that
  doesn't is killed at the deadline, and its last checkpoint stands.
- **A node that dies: 3 hours.** A step whose node died mid-upload is
  rescued by Oban's Lifeline after `KILN_OBAN_RESCUE_AFTER_MINUTES` (180 by
  default), and, if it has attempts left, runs again as the next attempt,
  which continues the upload.
  The step's two hours fit inside that window, so the rescued attempt never
  runs beside the one it replaces. Keep the variable above two hours.
- **A step that is fenced.** When another node reclaims the backup, the old
  step is stopped, its upload stays open, and the step that took over
  continues it. If the old step was still running somewhere, its saves are
  refused, as above.

A resumed upload is on the run's log as "Resumed
kiln-media-20261117-031700.part01.tar.gz on NAS at 268435456 of 1073741824
bytes", or "… from its last checkpoint" when the adapter doesn't report its
progress.

**Set a lifecycle rule on the bucket.** Once you use an S3 destination, or
another S3-style adapter that resumes, also set the bucket's own lifecycle
rule for incomplete multipart uploads, for example "abort incomplete
multipart uploads after 7 days"
([Set a lifecycle rule for unfinished uploads](#set-a-lifecycle-rule-for-unfinished-uploads)). Kiln aborts only the uploads it recorded. It never lists the store's
own pending uploads, so it never aborts:

- an upload cut off before its first checkpoint was saved;
- an upload on a destination you deleted, since Kiln no longer calls it;
- an upload whose row was lost when the database was restored from an
  older backup;
- another installation's uploads in the same bucket.

<a id="a-plugin-opts-in"></a>

#### A plugin opts in

An adapter resumes when its `supports/0` includes `:resume` and it
implements `abort_upload/3`. It then gets a `Kiln.BackupDestination.Resume`
in `put/3`'s `opts[:resume]`, holding the last checkpoint and a `save`
function to record a new one. An adapter that declares `:resume` without
`abort_upload/3` is never resumed, since Kiln could never free an upload it
started, and `mix kiln.plugins.doctor` says so. What an adapter must do is
under *Backup destinations* in
[plugin-extensibility.md](plugin-extensibility.md#resumable-uploads-in-a-backup-destination).

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
before any media part is written: "tar cannot read a NUL-separated file list".
In `backup.sh all` the database dump runs first, so it is kept and verified,
the run exits 1, and `manifest.json` records the refusal as the run's error
with the dump as its one artifact. Also
`stat` (GNU or BSD), `xargs`, `mktemp`, `head`, `gzip`, and `sha256sum` or
`shasum`; bash 3.2 or later. `iconv` is used when present to keep error text in
the manifest valid UTF-8. The file lists are built in `TMPDIR` (default `/tmp`)
and removed when the script exits. Planning a very large library in shell takes
longer than the app does, and grows with the number of files.

CI runs the script tests under bash 5 with GNU tar, bash 3.2.57 with GNU tar,
and bash 5 with bsdtar, and checks that busybox tar is refused. BSD
`stat -f %z`, BSD `xargs` and AppleDouble (`._*`) members are checked only on
macOS, which CI does not run;
[system-requirements.md](system-requirements.md#running-the-backup-scripts-on-the-host)
has the details.

**Permissions.** Parts and the sidecar are 0600 from their first byte (the
media phase runs under `umask 077`). The script creates `$BACKUP_DIR/media`
0700 and sets an existing one back to 0700 on every run, as the app does. If
that `chmod` fails (a directory the cron user doesn't own), the run fails:
"could not make `<dir>` private (chmod 700)". If cron and the app run as
different users, one of them cannot write there, so run both as the same user.

**A media folder that can be listed but not entered** (read permission without
execute, such as mode 0644) fails the run in both paths, because none of its
files can be read. The error names the folder, relative to the media directory:
`media folder "<folder>" can be listed but not entered (no execute permission):
fix its permissions, or leave it out with BACKUP_MEDIA_EXCLUDE`.

**A cron run and the app starting in the same second.** A stamp is in use
when any `kiln-db-<stamp>.*` or `kiln-media-<stamp>.*` file is in
`$BACKUP_DIR`, when the app has a `.work/<stamp>` directory (an in-app backup
makes it first, as soon as its start step runs), or when another cron run has
claimed it. The script moves on one second at a time to a free stamp ("Stamp
`<stamp>` is already in use in `<dir>`; this run is `<stamp>`"), claims it by
creating `.claims/<stamp>` (a `mkdir` only one run can win, so two cron runs
cannot share a stamp whatever they back up), and looks for the app's
`.work/<stamp>` once more. The claim is removed when the run exits. After 60
stamps in use the run fails, under the next stamp when that one is free, so
History records the failure. The app moves past a stamp with files or a
claim on disk the same way. A cron run and an in-app backup that check within
the same few milliseconds can still choose the same stamp. A run killed
outright leaves its empty `.claims/<stamp>` behind; it only makes later runs
skip that stamp, and can be deleted.

**When a run fails.** Cron has no resume. If any part fails (`tar` is retried
once from a re-checked list first), or the run is interrupted with `HUP`, `INT`
or `TERM`, the script removes every part it wrote for that stamp, so a partial
set never looks like a backup. A database dump that already finished is kept.
A failed or [refused](#when-an-off-site-copy-is-refused) off-site copy after
the set is complete keeps the set and fails the run, and the files after it are
not copied.

**`HUP`, `INT` and `TERM` stop the run at once (#2847).** The script runs
`pg_dump`, `pg_restore --list`, `tar` and `rclone` in the background and
waits for them, so a signal no longer waits for the dump, part or upload in
progress to finish. It stops that program (`TERM`, then `KILL` if it still
runs about 5 seconds later; a program paused with `kill -STOP` or Ctrl-Z is
resumed first so it can act on the `TERM`), then removes its `.partial`
files and, for `backup.sh all`, writes the failure manifest ("interrupted by
SIGTERM"). A second signal during that cleanup is ignored, so it always
finishes. At a terminal, Ctrl-C reaches the running program through the
script's `TERM`, not directly. One case still waits: a program stuck in the
kernel on a hung mount (a stalled NFS server) ignores both signals until the
I/O returns, and the cleanup waits with it; only `kill -9` of the script ends
that, and its [background loop](#when-a-cron-run-is-killed-outright-2478)
stops the program once it can.

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

**The program it was running is stopped too (#2847).** A `pg_dump`, `tar` or
`rclone` that the killed run started would otherwise run on, writing a
`.partial` that nothing keeps fresh, until `prune` deleted the file under it
and it went on filling disk through the deleted file. The script's background
loop (below) stops it within 5 minutes of the kill: `TERM` first, then `KILL`
if it still runs about 5 seconds later. It only does so when the script is
certainly gone, and only to a process that still runs the same program and
has the loop's own parent (both were adopted by the same process when the
script died), so a process that has since taken the same PID is left alone.
It reads the process's command line and parent with `ps`, or from `/proc`
where `ps` has no `-p` (busybox). Where neither works it goes by the PID
alone. While `ps` can't tell whether the script is alive, the loop keeps
going, and after three such answers in a row it stops without stopping
anything.

What it can't stop:

- a child the script started in the instant before the kill, before it
  recorded the child's PID;
- the commands it does not track: the `head | gzip` that writes an empty
  media part, and those that only read (`find`, `stat`, the `sha256sum` that
  hashes a finished file);
- any child at all if `backup.sh` could not create its record in `TMPDIR`; the
  run then warns "could not create a file in `<TMPDIR>`: a child of this run
  would outlive a kill -9" and carries on.

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
backup stamp is removed once it is an hour old, as before, and so is a
manifest temporary file left at the top of `BACKUP_DIR`: a step's
`manifest.json.<job>-<attempt>.partial`, the app's
`manifest.json.<random digits>.partial`, or `backup.sh`'s
`manifest.json.<pid>-<random>.partial` (#2832), and the app's leftover
`.kiln-dir-id.<uuid>.tmp` (#2849). `backup.sh prune` removes the
same files once they are an hour old. The plain `manifest.json.partial` of an
older `backup.sh` is removed by neither
([Temporary files](#temporary-files-and-the-trash-directories)). The start of
an in-app backup also empties the
[trash directories](#temporary-files-and-the-trash-directories).

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
2. Scroll to **History**. Each row shows the trigger (**Manual**, **Cron**,
   **Console** or **Scheduled**, the last for a backup an
   [in-app schedule](#schedule-backups-in-the-app) took; any other value as
   recorded), a status (`Succeeded`,
   `Failed`, `Running`, `Skipped` or `Canceled`), **Database** and **Media** badges, the
   size, whether it was verified, its destinations (one chip each, with how
   that destination fared; a backup that reached only some is badged
   **Partly off-site**, [above](#when-a-backup-reaches-only-some-destinations)),
   and whether its files are still on this host. A media set written in several parts shows "N parts",
   a link that opens
   [Restore a media set that has several parts](#restore-a-media-set-that-has-several-parts)
   in a new tab.
   A failed, interrupted or canceled run shows **Resume**
   ([above](#media-backups-in-parts-2218)); its tooltip names which of the
   three it is and, for a canceled one, says to wait about two and a half
   minutes after the Cancel. Beside it, a `?` (**About Resume**) says what a
   resume reuses: "Continues from the files already written; each is reused
   only if its checksum still matches. It backs up the files listed when the
   backup first started, so its files can be from different times." A resume
   that was refused after the click shows
   "Resume refused: …" above the row's error. A running in-app one shows **Cancel**
   ([above](#cancel-a-running-backup)) until it is finishing.
3. Use **Previous** / **Next** to page ("Page 1 of 3").

To open one run's row directly, use `/editor/backups?run=<run id>`, which is
what the Schedule tab's "Last scheduled run" links to: the page that holds the
run opens, scrolled to its row, which is highlighted. It wins over `?page=`,
and paging drops it. An id that isn't a run's opens page 1 with "That backup
isn't in the history."

**Retention markers on the page (#2542).** The page shows which backups the
on-disk markers protect, so you don't need a shell to check:

- A **Recovery point** badge on a row: a `kiln-<stamp>.keep` for that stamp is
  in `db/` or `media/`, so retention keeps every file of that backup
  ([Keep a backup as a recovery point](#keep-a-backup-as-a-recovery-point)).
- A **Last good: Database** or **Last good: Media** badge: that component's
  `kiln-<stamp>.good` names this backup, so `backup.sh prune` keeps that
  component of it ([The last-good marker](#the-last-good-marker)).
- **Last-good marker (kept by backup.sh prune)**, above the list: the stamp each
  component's marker names, or what the page could not find out (table
  below). It is there even when the marked backup is on another page of
  History. It lists only the components this deployment backs up (**Media**
  only when media backups are configured). Should a directory hold more than
  one `.good`, the newest stamp is shown.

| Last-good summary shows | Meaning |
|-------|---------|
| a stamp | That component's `.good` marker names this backup. |
| `none yet` | The directory was listed and holds no `.good`, or it doesn't exist yet. |
| `checking…` | The page's first read of the backup directory hasn't answered yet. |
| `couldn't read this server's backup directory` | `db/` or `media/` exists but can't be listed: its permissions, an I/O error, or a file where the directory should be. Badges from that directory are missing too. |
| `couldn't check in time` | The read of the backup directory didn't answer within 5 seconds ([below](#what-history-reads-from-disk)). |
| `couldn't check` | The read of the backup directory failed outright. |

- A **Kept by a schedule: Database** or **Kept by a schedule: Media** badge:
  that component's `kiln-<stamp>.hold` names this backup, because a
  schedule's **Keep the newest** or **Keep for (days)** holds it, so
  `backup.sh prune` keeps it too ([The hold markers](#the-hold-markers)).
  Hover it for "Kept by backup.sh prune: a schedule's keep settings hold this
  backup (kiln-<stamp>.hold)". Like the other marker badges, it is missing
  while the page's read of the directory is `checking…`, and when that read
  failed or timed out.

The markers are read from this server's `BACKUP_DIR` whenever the page loads
History (opening it, paging, after an action, and on each refresh while a
backup runs); they are never stored. With a backup directory per host,
another server may show different markers. Before #2799 a directory the app
couldn't list read "none yet", a claim about markers it never saw; now it
says so, and the page itself still loads. Check the host with
`ls -ld $BACKUP_DIR/db $BACKUP_DIR/media` as the user the app runs as.

The files column reads, for the backup as a whole:

| Shown | Meaning |
|-------|---------|
| `checking…` | This row's files haven't been read yet: the page has just opened, or you paged to it. |
| `on disk` | Every file is under `BACKUP_DIR`. |
| `pruned (retention)` | The application's own retention removed them. |
| `partly pruned (retention)` | Some parts of a media set are still here, and every part that's gone was removed by the application's own retention. |
| `off-site only` | Gone locally, but every missing file has a successful rclone copy. |
| `expired` | `backup.sh prune` on cron removed it. See [Expired, probably expired, missing](#expired-probably-expired-missing). |
| `probably expired` | Most likely removed by `backup.sh prune`, but cron's `BACKUP_KEEP_DAYS` isn't known here, so the app's own is used. |
| `missing` | Gone with no recorded reason: deleted by hand, or recorded by another node. |
| `couldn't check` | Its directory or one of its files couldn't be read (permissions, an I/O error, a stale network mount), so nothing is claimed. Also shown on every row when the read of the backup directory failed outright. |
| `couldn't check in time` | The read of the backup directory didn't answer within 5 seconds. |

Presence is judged per artifact, so the dump and the media set of one backup
can differ:

- **Mixed.** When they differ, the row shows one chip per artifact instead,
  for example `Database: pruned (retention)` `Media: on disk`. Retention ages
  a backup's dump and media separately, so this is the usual shape of an
  older backup.
- **A part of a media set is gone.** When some parts are still here and
  others aren't, the set reads `missing` and a chip names them:
  `1 part missing: 02` or `2 parts missing: 02, 05` (hover it for the file
  names). A part counts as gone even if its off-site copy succeeded: the set
  on this disk can't be restored as it is.
- A row whose state needs explaining (`missing`, `expired`,
  `probably expired`) has a **?** tip ("About these files") saying why, with
  a link to this section.

"Missing" is worked out when the page is shown, for the 25 rows in view only; it
is never stored, so a restored file turns back to `on disk`. The reasoning is in [ADR 0033](decisions/0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md).

**Multi-node.** `BACKUP_DIR` belongs to one host. A run recorded by another node
reads `missing` on this one. That is the node's view, not data loss.

**Verified.** An app-made backup is `Verified` once `pg_restore --list` /
`tar -tzf` passed, the size matches the hash and a SHA-256 was recorded. A
backup picked up from cron's files reads `unverified (imported)`: nothing is
hashed or checked on import (a sidecar's hashes are recorded on the row, not re-checked).
Such a row has a **?** tip ("Made by cron") saying so: run
`scripts/backup.sh verify` on the server to check the newest backup.

**A failed or refused attempt is history too.** A refusal (for example no
`pg_dump` in the image) is a `Skipped` row with the reason, and still leaves
`manifest.json` alone. A backup whose node stopped is requeued or failed
("Interrupted") by the heartbeat within a few minutes
([Several nodes and the backup lock](#several-nodes-and-the-backup-lock)). A
`Running` row the lock no longer holds (a run from before the upgrade, or one
the heartbeat could not reach) reads `Failed` ("Interrupted") once it has been
quiet for 2h15m, measured from the later of its start and its last update.
Failing to write a row never fails the backup itself.

### Expired, probably expired, missing

The app's own retention records what it deletes (`pruned (retention)`).
`backup.sh prune` records nothing, so for a backup cron made (an imported
row), the page works out whether cron's prune would have removed a file that
is gone, by cron's own rules as far as the app can see them. A gone file is
`missing`, not expired, when:

- a `kiln-<stamp>.keep` (a recovery point) for its stamp is in `db/` or
  `media/`, or a `.good` or `.hold` for its stamp is in its own directory:
  prune keeps those, so something else removed it;
- no newer complete backup of the same kind (database or media) is in the
  directory: prune never deletes the newest complete one;
- it is no older than the retention window plus a day (below), by the
  run's finish time, else its start;
- `db/` or `media/` couldn't be listed, so a marker can't be ruled out.

Otherwise it is `expired`. Cron's `BACKUP_KEEP_DAYS` is read from the
`keep_days` that `backup.sh all` writes into `manifest.json`. When the
manifest there is the app's own (the last backup was an in-app one) or
there is none, cron's value is unknown: the app's `BACKUP_KEEP_DAYS` stands
in, and an old enough file reads `probably expired`. Only the latest
manifest is read, so a host that changed cron's `BACKUP_KEEP_DAYS` is judged
by the newer value.

A backup the app made is never `expired`: the app records its own prunes.
If cron's `backup.sh prune` shares a `BACKUP_DIR` with in-app backups and
removes the app's files, those rows read `missing`.

### What History reads from disk

What the page shows from `BACKUP_DIR` (the markers, each row's files, and
whether **Resume** is offered) is read off the page itself, after it
connects, so a backup directory on a network mount that hangs can't freeze
the page, its buttons or its refresh. The status panel (`manifest.json`)
is read the same way; until it answers the page says "Reading this server's
backup status…".

- **One read at a time.** A refresh while a read is still running waits for
  it, then reads once more. A read started before you paged fills in nothing
  on the new page.
- **Until the first read answers**, the rows say `checking…` and the line
  under the last-good summary says "Checking this server's backup
  directory…". **Resume** appears only once a read has answered.
- **A read that doesn't answer within 5 seconds** turns the page to
  `couldn't check in time`, with "This server's backup directory didn't
  answer within 5 seconds, so the files on disk, the markers and Resume
  aren't shown. Reload the page to check again." The status panel reads
  "Couldn't read this server's backup status. Reload the page to try again."
  if it never answered. If the stuck read answers later, the page fills in.
- **A read that fails outright** turns the page to `couldn't check`, with
  "Couldn't check this server's backup directory, so the files on disk, the
  markers and Resume aren't shown. Reload the page to check again." Nothing
  is retried on its own; the next refresh, page change or reload reads again.

The timeout fixes what the page shows, not the stuck read. A file system
call that blocks in the kernel holds one of the VM's dirty I/O scheduler
threads until the mount answers. Because no tab starts a second read while
its first is out, each open Backups tab adds at most one. A host where this
happens has a mount problem to fix; the page only stops hiding it.

The budget is an application setting in milliseconds (default `5000`), not
an environment variable; set it in `config/runtime.exs` of your build:

```elixir
config :kiln_cms, KilnCMSWeb.BackupLive, disk_timeout_ms: 10_000
```

It covers the disk read and the status read alike, and the timeout message
quotes it in whole seconds.

### Cron's backups appear in History

`KilnCMS.Backups.Importer.run/0` turns files cron wrote into rows. It runs when
a platform admin opens the page, at the end of every in-app backup, in every
run of the [last-good marker](#the-last-good-marker) sync (every 15 minutes by
default), and on demand:

```bash
bin/kiln_cms rpc '{:ok, r} = KilnCMS.Backups.Importer.run(); IO.inspect(r)'
# %{deferred: 0, failed: 0, imported: 2, pending: 0, skipped: 0}
```

It runs on the serving node, as the other commands on this page do; `eval`
starts no Repo, so the read fails and nothing is imported. When the directory
cannot be listed or the history cannot be read, the match fails and `rpc` exits
non-zero. A row that could not be written does not: it is counted in `failed`
and the call still returns `{:ok, _}`, so read `failed` as well. `deferred`
counts stamps whose write failed on an earlier call and that wait out a
backoff before the next try
([When an import keeps failing](#when-an-import-keeps-failing)).

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

While History has no rows, it says "No backups have been recorded yet." and
that cron's backups appear there about ten minutes after they finish: that is
the settle window above, so a backup still being written is never recorded
half-done.

### When an import keeps failing

The importer runs often (every History mount, marker sync, backup end and
retention pass), so a stamp whose row can't be written would otherwise be
retried, and warned about, on every one of them. Instead, a failed write puts
that stamp in a backoff:

- The first retry waits 15 minutes; each further failure doubles the wait,
  up to 6 hours. Until then the stamp counts as `deferred` and is neither
  tried nor logged.
- Each real attempt that fails logs one warning, with the cause redacted and
  cut to 300 characters:
  `Couldn't import backup 20261107-031700 (attempt 2): <cause>. Next try after 2026-11-07T04:02:11Z; KilnCMS.Backups.Importer.retry_failed() retries now`
- Each also emits `[:kiln_cms, :backups, :import, :failed]` with
  measurements `%{count: 1}` and metadata `stamp`, `attempt`, `retry_at`
  (a `DateTime`) and `error` (the redacted cause).
- A success clears the stamp's entry, and so does a row for it appearing
  (another node imported it) or its files going.

The backoff is kept per node, in memory, keyed by backup directory and stamp,
and holds at most 500 stamps (the soonest due are dropped first, which only
brings their retry forward). A restart forgets it.

Once you have fixed what made the write fail, retry every deferred stamp at
once on the serving node:

```bash
bin/kiln_cms rpc 'IO.inspect(KilnCMS.Backups.Importer.retry_failed())'
# {:ok, %{deferred: 0, failed: 0, imported: 1, pending: 0, skipped: 0}}
```

`failed: 1` again means the cause is still there; the warning in the log
says what it is. Waiting is also safe: a deferred stamp has no History row,
so retention treats its files as **Unrecorded** (rule 6 of
[What retention deletes and what it keeps](#what-retention-deletes-and-what-it-keeps)) and keeps them until they are older than the component's floor,
as it does for any stamp whose write fails, and the
start of an in-app backup removes a stamp's `.partial` files only once the
stamp has a row. A deferred stamp never makes the importer return
`{:error, _}`, so it doesn't stop retention or the `.partial` sweep for every
other stamp.

### Secrets in history

Everything stored in a row (errors, log lines, off-site remote, each
destination's name and error) is passed
through `KilnCMS.Backups.Redact`: URL userinfo, `key=value` credentials and
rclone connection-string remotes are replaced with `***`. The status panel's
off-site remote and `manifest.json`'s `offsite` are redacted the same way, and
so, since #2220, is the remote in a backup's `.work/<stamp>/state.json`, which
held it as configured before. A destination's errors are also scrubbed of its
own secret fields. Read
access is the platform admin only. The table is written by the `:backups`
system actor, and by one person's action: a platform admin's `:cancel` of a
running backup, which sets its status, finish time and error ("Canceled by a
platform admin") and appends a log line naming that admin by email. It is
purged by
the staging scrub (`backup_runs_purged`).

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

The list of [destinations added in the app](#send-backups-to-several-destinations)
is in the database you are about to restore, so it can't tell you where the
backups are. Work from the copy you kept outside Kiln
([Keep destination credentials outside Kiln](#keep-destination-credentials-outside-kiln)).

1. **Provision Postgres** (same major version, with the `vector`, `pg_trgm`,
   `citext` extensions available — the dump creates them, the server just needs
   the packages).
2. **Fetch the newest verified dump** from the off-site remote:
   `rclone copy r2:kiln-backups/db/<newest>.dump .`
   Every destination lays files out as `BACKUP_DIR` does, `db/` and
   `media/` under its own place, so from one added in the app:
   - an **Rclone remote** destination: the same command with its remote name
     and path, `rclone copy nas:kiln-backups/site/db/<newest>.dump .`, with
     rclone configured for that remote again;
   - a **Directory on this server** destination (a NAS share, a second
     disk, mounted on the new host): `cp /mnt/nas/kiln/db/<newest>.dump .`
   - an **S3-compatible storage** destination: any S3 client, with the
     endpoint, bucket, prefix and a key you kept, for example
     `aws s3 cp s3://kiln-backups/kiln/site/db/<newest>.dump . --endpoint-url https://s3.eu-west-1.amazonaws.com`.

   Take the backup's `kiln-db-<stamp>.sha256` with it, into the same
   directory as the dump and under its own name: `restore.sh` checks the
   dump against it in the next step. A destination that was failing lacks
   the newest backups, so list each one
   (`rclone lsf nas:kiln-backups/site/db/`, `ls /mnt/nas/kiln/db/`,
   `aws s3 ls s3://kiln-backups/kiln/site/db/`) and take
   the newest stamp that has both its dump and its `.sha256`.
3. **Restore the database:**
   ```bash
   RESTORE_DATABASE_URL=postgres://…/kiln_prod \
     ./scripts/restore.sh db kiln-db-<stamp>.dump
   ```
   Expect `==> Verifying checksum from kiln-db-<stamp>.sha256` and
   `kiln-db-<stamp>.dump: OK` first (#2877), then the prompt to type the
   database name, then `==> pg_restore kiln-db-<stamp>.dump → kiln_prod`.
   The check runs before the prompt and before anything touches the
   database, so a damaged dump stops there with "nothing was restored". The
   dump must keep its `kiln-db-<stamp>.dump` name, and a symlink to it must
   too: the sidecar is looked for next to the path you give, by that name.
   With no sidecar, `restore.sh` prints a warning and restores anyway (a dump
   from before checksums has none), unless `RESTORE_REQUIRE_CHECKSUM=1` is
   set. What can go wrong is under
   [What can go wrong when restoring a dump](#what-can-go-wrong-when-restoring-a-dump).
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

### What can go wrong when restoring a dump

`restore.sh db` and `restore.sh drill` check the dump against its sidecar
`kiln-db-<stamp>.sha256` before they ask for confirmation, create the
database or run `pg_restore` (#2877). The sidecar must hold one well-formed
line, name exactly the dump and nothing else, and match its bytes
(`sha256sum -c`, or `shasum -a 256 -c` on macOS). It is the same check
`restore.sh media` makes, and the reason it reads the sidecar and never
`manifest.json` is in
[ADR 0035](decisions/0035-the-per-stamp-sidecar-not-the-manifest-is-the-only-restore-time-checksum-authority.md).

| Message (abridged) | Meaning |
|---|---|
| `checksum verification FAILED for kiln-db-<stamp>.dump — nothing was restored` | The dump is not the file the backup wrote: damaged in transit, truncated, or altered. Fetch it again, or use another copy or an older stamp. |
| `kiln-db-<stamp>.sha256 does not list exactly kiln-db-<stamp>.dump — nothing was restored` | The sidecar names another file, or more than one. Fetch the sidecar that belongs to this dump. |
| `kiln-db-<stamp>.sha256 has a missing or malformed checksum line — nothing was restored` | The sidecar is empty, truncated or edited. |
| `WARNING: no checksum found for this database dump.` (a banner) | No sidecar next to the dump, or the dump is not named `kiln-db-<stamp>.dump`, so there is no stamp to find one by. The restore continues unverified. Fetch the sidecar, or rename the dump back, to have it checked. |
| `RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found — nothing was restored` | As above, with `RESTORE_REQUIRE_CHECKSUM=1` set, which now covers `db` and `drill` as well as `media`. |
| `neither sha256sum nor shasum is installed — cannot verify kiln-db-<stamp>.sha256` | Install coreutils (or use macOS's `shasum`); nothing was restored. |

To check a dump by hand, from the directory that holds both files:
`sha256sum --strict -c kiln-db-<stamp>.sha256` (`shasum -a 256 --strict -c`
on macOS).

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
  extract such a set by hand once you have looked at it. The reasoning is in [ADR 0036](decisions/0036-restore-refuses-absolute-and-dot-dot-members-and-links-even-harmless-ones.md).

It also refuses a set with a `kiln-media-<stamp>.*.partial` file beside it,
cron's (`kiln-media-<stamp>.sha256.partial`) or an in-app step's
(`kiln-media-<stamp>.part02.tar.gz.48211-2.partial`): a backup is still
writing that stamp, or was killed while writing it.

Missing sidecar on a legacy single archive: the script prints a loud warning
and continues, because backups from before checksums have none. Set
`RESTORE_REQUIRE_CHECKSUM=1` to abort instead. Missing sidecar on a `.partNN`
set: the script warns and stops, because every complete part set has a sidecar,
so one without is most likely what a killed run left behind and would restore
with files missing. If you know the set is whole (you removed the sidecar
yourself, say), set `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` to restore it
anyway. It never falls back to the hashes in `manifest.json`; the sidecar is the
supported record. The reasoning is in [ADR 0035](decisions/0035-the-per-stamp-sidecar-not-the-manifest-is-the-only-restore-time-checksum-authority.md).

**By hand** (no script): check the sidecar, and extract only if it passed.

```bash
cd /backups/media &&
  sha256sum --strict -c kiln-media-20260805-031700.sha256 &&
  for p in kiln-media-20260805-031700.part*.tar.gz; do
    tar -xzf "$p" -C /data/kiln/uploads
  done
```

On macOS, use `shasum -a 256 --strict -c` in place of `sha256sum --strict -c`.
The `&&` is the point: without it a failed check still extracts, and `--strict`
fails on a sidecar line it cannot parse instead of skipping it. Unlike
`restore.sh`, the check only covers the parts the sidecar lists: a stray
`.partNN` file that it doesn't list passes the check and the glob extracts it
anyway, so first make sure the directory holds only the parts the sidecar
names (`restore.sh` refuses such a set). The order
of the parts does not matter, past `part99` too: each file is in exactly one
part, and directories are not archived, so no part overwrites another. Plain
`tar -xzf` per part is the supported manual form. `cat parts | tar -xzi` works
only with GNU tar and is not supported.

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

Run it on the dump where its `kiln-db-<stamp>.sha256` sidecar sits beside it,
as in `BACKUP_DIR/db/`: the drill checks the dump against it first (#2877),
exactly as `restore.sh db` does
([what can go wrong](#what-can-go-wrong-when-restoring-a-dump)), so a drill
also proves the sidecar matches. The drill restores into a throwaway DB (the
name must look throwaway — it refuses otherwise, before the checksum check)
and sanity-checks core tables (`users`, `pages`, `posts`,
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
| `DATABASE_URL` | backup | source DB (read-only): `postgres://`, `postgresql://` or `ecto://`; the password reaches `pg_dump` as `PGPASSWORD` only, and a `key=value` string with a password, or a URL with `sslpassword`, is refused ([connection URLs](#which-database-url-the-backup-tools-accept-2719)). The app's `DATABASE_SSL` doesn't reach the script: put `sslmode=` in this URL to require TLS ([TLS](#how-the-backup-tools-choose-tls-2830)) |
| `BACKUP_DIR` | backup + app | local backup root (default `/var/backups/kiln`) |
| `MEDIA_DIR` | backup + app | uploads root (Local adapter only; omit on S3). Defaults to `KILN_MEDIA_ROOT` when that is set and `S3_BUCKET` is not |
| `BACKUP_KEEP_DAYS` | backup + app | local retention, 1 to 2147483647 days (default 14; anything else keeps 14 and warns): the age at which a backup may be deleted ([keep rules](#what-retention-deletes-and-what-it-keeps)); an in-app schedule may keep its own backups longer or shorter ([per schedule](#set-how-long-a-schedule-keeps-its-backups)) |
| `BACKUP_ENABLED` | app | set false to disable the in-app path only; cron is unaffected (default true) |
| `KILN_BACKUP_MARKER_SYNC_CRON` | app | when the app moves the [last-good](#the-last-good-marker) and [hold](#the-hold-markers) markers for cron's backups (default `*/15 * * * *`; `false` turns it off). Read in every environment, and not turned off by `BACKUP_ENABLED=false` |
| `BACKUP_STALE_AFTER_HOURS` | app | how old before the console warns (default 36); an in-app schedule replaces it for the components it covers ([threshold rules](#how-a-schedule-sets-the-alarm-threshold)) |
| `KILN_BACKUP_SCHEDULER_CRON` | app | when the app checks its [in-app schedules](#schedule-backups-in-the-app) (default `* * * * *`; `false` turns every schedule off, and so does a value that isn't a cron expression or names no real date, such as `0 0 31 2 *`; the Schedule tab says which). Read in every environment, and not turned off by `BACKUP_ENABLED=false` |
| `BACKUP_MEDIA_PART_MB` | backup + app | target ceiling on one media part's input size, 16 to 10240 (default 400) |
| `BACKUP_MEDIA_EXCLUDE` | backup + app | comma-separated globs the media archive leaves out (default none) |
| `BACKUP_LOCK_WAIT_SECONDS` | backup + app | how long `pg_dump` waits for each table lock before it gives up, 1 to 3600 (default 600; anything else keeps 600 and warns). Also the demo golden capture's ([lock waits](#when-pg_dump-waits-for-a-table-lock-2844)) |
| `TMPDIR` | backup | where `backup.sh` builds the media file lists and keeps the record of its running child that the [heartbeat](#when-a-cron-run-is-killed-outright-2478) reads (default `/tmp`); removed when it exits |
| `BACKUP_TRIGGER` | backup | label recorded in the manifest (default `cron`) |
| `BACKUP_RCLONE_REMOTE` | backup + app | off-site rclone remote (strongly recommended). Each file is re-hashed before its copy; a refused copy fails the run, and so does a failed one, unless an in-app backup reached another [destination](#send-backups-to-several-destinations) (then it is partly off-site). The official image ships `rclone`; set without it, an in-app run fails ([above](#it-needs-the-client-tools-in-the-image)) |
| `BACKUP_LOCAL_DESTINATION_ROOTS` | app | comma-separated absolute directories a **Directory on this server** destination may be under (default unset: that kind isn't offered). One relative or `..` entry drops the whole list with a boot warning ([details](#let-backups-be-written-to-a-directory-on-this-server)). Read in production and development |
| `BACKUP_PING_URL` | backup | dead-man's-switch ping on success |
| `BACKUP_DATABASE_URL` | app | connection string the in-app backup dumps, for a connection the app cannot derive from `DATABASE_URL` or the Repo config (a unix-socket repo). Unset, it uses `DATABASE_URL` when that names the connected database, else a URL rebuilt from the Repo. Any of them may be `ecto://`; `ssl=false` becomes `sslmode=disable` and Ecto's pool options are dropped ([connection URLs](#which-database-url-the-backup-tools-accept-2719)). The tools' TLS follows the app's unless this URL sets `sslmode` ([TLS](#how-the-backup-tools-choose-tls-2830)) |
| `RCLONE_CONFIG`, `RCLONE_CONFIG_<NAME>_*`, `RCLONE_RETRIES` | rclone | read by `rclone` itself, which inherits the environment of whichever path runs it: the named remote's configuration file or settings, and rclone's retry count (default 3). Kiln does not read them. `kiln_offsite` is reserved ([above](#off-site-credentials-stay-out-of-the-rclone-command-line-2690)) |
| `RESTORE_DATABASE_URL` | restore | target DB for `db`/`drill`: `postgres://`, `postgresql://` or `ecto://`; the password reaches `pg_restore`/`psql` as `PGPASSWORD` only, and a `key=value` string with a password, or a URL with `sslpassword`, is refused. Put `sslmode=` in it to require TLS |
| `RESTORE_MEDIA_DIR` | restore | target uploads root for `media` |
| `RESTORE_CONFIRM=yes` | restore | skip the interactive confirmation |
| `RESTORE_REQUIRE_CHECKSUM=1` | restore | `db`, `drill` and `media`: abort when there is no checksum sidecar (default: warn and continue for a dump, or a legacy single archive, with none). `db` and `drill` read it since #2877 ([details](#what-can-go-wrong-when-restoring-a-dump)) |
| `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` | restore | `media`: restore a `.partNN` set that has no sidecar (default: refuse, since a set without one is most likely from a killed run) |
