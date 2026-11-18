# 0072. Backup presence is judged per artifact, off the page, and expired means cron's prune would have removed it

- **Status** — accepted (2026-11-18). Supersedes the list of presence states
  in [ADR 0033](0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)
  (its decision "`pruned` is stored; unexplained absence is computed on
  read"), which predates per-artifact presence. The rest of 0033 stands: rows
  only the pipeline writes, files as the truth, `pruned` stored and
  everything else computed on read.
- **References** — [#2940](https://github.com/The-Verscienta/kiln_cms/issues/2940)
  (this record); [#2416](https://github.com/The-Verscienta/kiln_cms/issues/2416)
  (presence per artifact), [#2417](https://github.com/The-Verscienta/kiln_cms/issues/2417)
  (the disk read off the LiveView process) and
  [#2799](https://github.com/The-Verscienta/kiln_cms/issues/2799) (an
  unreadable directory is said to be one), shipped together in pull request
  [#2939](https://github.com/The-Verscienta/kiln_cms/pull/2939);
  [#2942](https://github.com/The-Verscienta/kiln_cms/issues/2942) (the gone
  parts that have an off-site copy);
  [ADR 0041](0041-the-app-and-backup-sh-agree-on-what-to-keep-only-through-presence-only-marker-files.md)
  and [ADR 0062](0062-a-schedules-keep-holds-reach-backup-sh-through-a-third-presence-only-marker.md)
  (the markers prune obeys).
- **Changelog** — the 1.10.0 entry
  [Backups History says what is on this server's disk artifact by artifact](../changelog/v1.10.0.md#backup-history-presence).

## The problem

ADR 0033 judged presence per **run**: one of `:present`, `:pruned`,
`:partly_pruned`, `:off_site_only`, `:expired`, `:missing` or `:none`, with
`:expired` a heuristic (an imported run older than the app's
`BACKUP_KEEP_DAYS` plus a day). Three things made that wrong:

- **A run is not one thing on disk.** Retention ages a stamp's dump and its
  media separately (#2219), and a media set is several files (#2218). A run
  whose dump was pruned while its media is still here read `missing` or
  `partly pruned` for the whole run, and a set with one part gone didn't say
  which.
- **The heuristic called files expired that cron's prune keeps.** Prune never
  deletes the newest complete unit of a kind, nor one a `.keep`, `.good` or
  `.hold` marker pins, and its window is cron's `BACKUP_KEEP_DAYS`, not the
  app's. A file removed by hand could read `expired` and look routine.
- **The list had no word for "couldn't tell".** A directory the app couldn't
  list read as empty, so every file in it was `missing`, and an `lstat` that
  failed with `:eacces` or `:eio` was absence.

And the judgment ran in the LiveView process: a backup directory on a
network mount that hung froze the page, its buttons and its poll.

## Decision

- **Presence is judged per file, then per artifact, then per run.**
  `KilnCMS.Backups.Presence.for/2` takes each file an artifact occupies (the
  dump, the single media archive, or each part of a media set, never the
  checksum sidecar) as one unit:
  - `:present` is a regular file under `db/` or `media/`, by `lstat`, so a
    symlink or a directory with the name is not it.
  - `:unknown` is a directory that couldn't be listed, or an `lstat` that
    failed for any reason but `:enoent`. Nothing is claimed about the file. A
    directory that doesn't exist lists as empty: its files are absent, not
    unknown.
  - An absent unit takes the first reason that applies: `:pruned` (its
    `"local"` destination is marked `"pruned"`, which the app's retention
    records), `:off_site_only` (any other destination recorded `"ok"`; a
    part's own destinations win, else the artifact's), `:expired` or
    `:probably_expired` (below), else `:missing`.

  An **artifact** is `:present` when every unit is, `:unknown` when any unit
  is, `:partly_pruned` when some units are here and every absent one was
  pruned, and `:missing` when some are here and others are gone for another
  reason; `gone` names those files, and `off_site` the ones among them whose
  copy reached a destination (#2942). An artifact with no unit here reads its
  worst reason: `:missing`, then `:probably_expired`, `:expired`, `:pruned`,
  `:off_site_only`. A **run** reads the state its artifacts share, `:mixed`
  when they differ (the row then shows one chip per artifact), and `:none`
  when it has no artifacts.
- **Expired means cron's prune removed it, judged by prune's own rules.**
  Only an imported (cron-made) run with a stamp can expire: the app records
  its own prunes, so an app-made file that is gone is `:missing`, including
  one cron's prune removed from a shared `BACKUP_DIR`. An absent unit of an
  imported run is `:missing`, not expired, when:
  - `db/` or `media/` couldn't be listed, so a marker can't be ruled out;
  - a `kiln-<stamp>.keep` for its stamp is in either directory, or a `.good`
    or `.hold` for its stamp is in its own directory;
  - no newer complete unit of its kind is in the listing (prune never
    deletes the newest complete one). "Complete" is judged from names alone,
    as `scripts/backup.sh` and `KilnCMS.Backups.Retention` judge it: a dump;
    a single media archive and no parts; or parts 01 to N with no gap, no
    single archive and the media sidecar. A stamp with a `.partial` doesn't
    count, nor does an implausible one;
  - it has no `finished_at` or `started_at`, or it is no older than the
    window plus a day.

  The window is cron's `BACKUP_KEEP_DAYS`, which `backup.sh all` writes into
  `manifest.json` as `keep_days`. `KilnCMS.Backups.DiskView` reads it only
  from a manifest without `"components"`, which the app always writes, so the
  value is cron's. Past it, the unit is `:expired`. When the latest manifest
  is the app's, or there is none, cron's window is unknown: the app's
  `BACKUP_KEEP_DAYS` stands in, and past it the unit is only
  `:probably_expired`.
- **The disk is read off the page process.** `KilnCMSWeb.BackupLive` runs
  `KilnCMS.Backups.DiskView.read/3` in `start_async/3`, one read at a time
  per page: a refresh while one is out marks the page dirty, and the read
  that lands starts one more. A read lists `db/` and `media/` once each,
  reads `manifest.json` once, `lstat`s only listed names, checks
  `.work/<stamp>/state.json` only for a row whose status could be resumed
  (whether **Resume** is offered), and does no database reads. Its result fills only the rows on the page when it lands.
  Until the first one lands the rows say `checking…`. One that hasn't landed
  within `disk_timeout_ms` (default 5 s) turns the rows to `couldn't check
  in time`, and the answer is still applied when it comes. A read that
  crashes turns every row to `couldn't check`, the same label as an
  `:unknown` file, and nothing is retried until the next refresh.
- **The row's `?` tip explains its most telling state** (#2940), from
  `couldn't check` (an unreadable directory or file, or a crashed read; it
  comes first, since it changes how the rest is judged), `missing`,
  `probably expired` and `expired`, or `couldn't check in time`. The
  gone parts of a set say whether each has an off-site copy: "1 part
  missing: 04" beside "2 parts missing here, copied off-site: 02, 03" (#2942).

## Rejected

- **One state per run.** It hid which artifact was gone, and a run is
  rarely one thing on disk for long: retention ages a dump and its media
  apart.
- **Expired by age alone.** It called a file removed by hand `expired`, the
  word that tells an admin nothing is wrong. Prune's other rules are
  readable from the same listing, so they cost no extra read.
- **`off-site only` for a set with some parts here and the rest only
  off-site** (#2942). The set can't be restored from this disk as it is,
  and whether one destination holds every part depends on each part's own
  record, so `off-site only` would read as nothing to fix here. It stays
  `missing`, and the chip says which gone parts have a copy.
- **Absence on an unreadable directory.** "Couldn't tell" and "isn't there"
  lead to opposite actions, so `:unknown` claims nothing.
- **Reading the disk in the LiveView process with a timeout.** A blocked
  `lstat` blocks its caller, so a timeout in the same process never fires.
  Off the process, the page answers; the blocked call still holds a dirty
  I/O scheduler thread until the mount answers, and one read at a time per
  tab bounds that to one per open tab.

## When to revisit

- **A host where cron and the app both back up.** The latest manifest is
  often the app's, so cron's `keep_days` is unknown and every eligible
  imported row reads `probably expired`. Neither the importer nor the run
  log keeps an older manifest's `keep_days`; reading it from there would
  need new storage (#2942).
- **A directory per host.** Runs carry the `dir_id` of their directory
  (#2539); presence could say "on another host" instead of `missing`.
