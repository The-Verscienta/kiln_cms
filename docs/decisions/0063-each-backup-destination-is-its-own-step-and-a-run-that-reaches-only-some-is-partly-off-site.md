# 0063. Each backup destination is its own step, and a run that reaches only some is partly off-site

- **Status** — accepted (2026-11-15). For a backup with more than one
  destination, supersedes the rule
  [ADR 0043](0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md)
  records from decision 3 of #2218 ("a failed off-site copy fails the
  run"). With `BACKUP_RCLONE_REMOTE` as the only destination, that rule
  holds unchanged. Amended 2026-11-18 by
  [#2951](https://github.com/The-Verscienta/kiln_cms/issues/2951): a run
  that reached nothing because the stored destinations couldn't be read and
  no `BACKUP_RCLONE_REMOTE` was set succeeds with `offsite_status: failed`
  (it read "reached 0 of 1" before), and the alarm counts only failed
  destinations that are still configured.
  Amended 2026-11-18 by [ADR 0071](0071-a-partly-off-site-backup-is-completed-by-a-re-send-that-holds-the-backup-lock-and-never-changes-the-runs-status.md)
  ([#2949](https://github.com/The-Verscienta/kiln_cms/issues/2949)): a
  partly off-site (or not off-site) run can be re-sent to the destinations
  it missed, under the backup lock, without changing its status.
- **References** — [#2220](https://github.com/The-Verscienta/kiln_cms/issues/2220)
  and the owner's approval of its decisions E1, E2 and E3 "all as proposed"
  (2026-11-15); [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  and its owner decision 3 of 2026-11-08 (a failed off-site copy fails the
  run); [ADR 0043](0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md)
  (each file re-hashed right before its own copy);
  [ADR 0064](0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)
  (retention on a destination).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes and Added, #2220
  ([long form](../changelog/v1.11.0.md#backup-destinations)).

## The problem

Until #2220 an in-app backup had one place to copy its files besides
`BACKUP_DIR`: the rclone remote in `BACKUP_RCLONE_REMOTE`. The off-site step
copied every file there, and if the copy failed the backup failed (#2218,
decision 3). That rule is simple because there is one remote: either the
backup is off the host or it isn't.

With a list of destinations (a directory on a NAS, a second rclone remote,
a plugin's store) three questions have no answer in that rule:

1. **What is a backup that reached some destinations and not others?** If
   it is `failed`, the backup's local files are as good as any, and one or
   more off-site copies exist, yet History, retention and the staleness
   alarm all treat it as a failure.
2. **What happens to `BACKUP_RCLONE_REMOTE` when an admin adds a destination
   in the app?** Settings stored in the app usually win over the
   environment (the plan's rule B3).
3. **How finely is the copy split into jobs?** The chain already runs one
   Oban job per step and one per media part (#2218).

## Decision

**One step job per destination (E3).** The `offsite` step runs once per
destination, `part` k sending every file to the k-th destination of the
list `KilnCMS.Backups.Destination.active/0` gave at the backup's start and
`state.json` froze. Each has its own four attempts, its own retries and its
own bound on each adapter call (the step's run time less five minutes,
optionally capped by `config :kiln_cms, KilnCMS.Backups.Destination,
call_timeout: ms`). Each file is re-hashed immediately before each
destination's copy, so ADR 0043's check holds once per destination: a file
that changed while destination 1 was being sent to is refused at
destination 2. The outcome of each destination is recorded on the Run
(`destinations`, `KilnCMS.Backups.RunDestination`) and on each artifact's
`destinations` map, under the destination's key.

**`BACKUP_RCLONE_REMOTE` is a destination, read-only and first (E2).** It is
not stored; it is read from the environment on every backup, keeps the key
its results always had (`"rclone:<redacted remote>"`), and is copied to
with exactly the command it always was. Destinations stored in the app
(`KilnCMS.Backups.DestinationConfig`) are added after it. They never
replace it, and the Destinations tab shows where it comes from: "From
BACKUP_RCLONE_REMOTE — change it in the server's environment".

**The run's outcome counts destinations (E1).** `finish` settles
`offsite_status` from the destinations (`Recorder.offsite_outcome/1`):

| Destinations reached | Run status | `offsite_status` | Alarm |
|---|---|---|---|
| All | `succeeded` | `complete` | no |
| Some, not all | `succeeded` | `partial` | yes: "The last backup reached N of M off-site destinations — … failed" on the Backups page and the home strip, an error line on the run, `Logger.error`, and `[:kiln_cms, :backups, :offsite, :partial]` |
| None, with at least one configured | `failed` | `failed` | yes, as any failed backup |
| No destination configured | `succeeded` | `none` | no |
| None: the stored destinations couldn't be read and `BACKUP_RCLONE_REMOTE` is unset (#2951) | `succeeded` | `failed` | yes: "The last backup was not copied off-site: …" on the Backups page and the home strip, "Not off-site" in History, an error line on the run, `Logger.error`, and `[:kiln_cms, :backups, :offsite, :failed]` |
| Some or none, then re-sent to the ones it missed (#2949, [ADR 0071](0071-a-partly-off-site-backup-is-completed-by-a-re-send-that-holds-the-backup-lock-and-never-changes-the-runs-status.md)) | `succeeded`, unchanged | what the destinations then add up to | as that outcome says: none once every destination is reached |

A refused file is still fatal to the whole backup, whichever destination
refused it (ADR 0043 is unchanged there). A destination that fails on its
last attempt, or in a way no retry fixes (no `rclone`, credentials no key
decrypts, the row deleted since the backup started), is recorded failed and
the chain moves on to the next one. Only when the last destination fails
and none was reached does the backup fail, with the text ADR 0043
describes when the env remote is the only destination, or "Off-site copy
FAILED to every destination (N): …" naming each one.

**What a destination list that can't be read means.** The start step
retries; on its fourth attempt the backup goes ahead with
`BACKUP_RCLONE_REMOTE` alone and records a failed "unreadable" entry, so the
run can be no better than `partial`. It never reads as complete having
reached fewer places than were asked for. With no `BACKUP_RCLONE_REMOTE`
the "unreadable" entry is the run's only one, and the run is `failed`
off-site while it succeeds (#2951; the table's last row).

**A partial run is not resumable.** It succeeded, so its work directory is
removed as any succeeded backup's is. The next backup tries every
destination again, and since #2949 the run itself can be **re-sent** to the
destinations it missed ([ADR 0071](0071-a-partly-off-site-backup-is-completed-by-a-re-send-that-holds-the-backup-lock-and-never-changes-the-runs-status.md)). A run that reached no destination failed and keeps its
work directory, and Resume sends it again; a stored destination skips a
file it was already sent with the same SHA-256, while the env remote copies
every file, as before.

## Rejected

- **A partial run is `failed`.** Retention's rule that the newest verified
  backup is never deleted, the last-good marker and the staleness alarm all
  read "failed" as "not a good backup". A good local backup already copied
  to a second place would then not count as the last good one, and the
  previous one would be held instead. The alarm the admin needs is "a
  destination is failing", which `partial` raises without misreporting the
  backup.
- **A partial run is plain `succeeded`.** Silent: the admin who added a
  second destination for safety would not learn that it stopped working
  until they needed it.
- **Stored destinations replace `BACKUP_RCLONE_REMOTE` (settings win).** An
  operator who set the env remote and then added a Local destination in the
  app would silently stop getting the copy they configured.
- **One loop over every destination inside the single `offsite` job.** No
  isolation: one retry budget for all of them, one failure retrying the
  others, and one hanging store using up the step's two hours.
- **One job per file and destination.** Hundreds of jobs for a large media
  set, an integer `part` that would have to encode two indexes, and the
  backup lock held across all of them anyway. Resumable uploads within a
  file are #2223.
- **Hash each file once and copy it to every destination.** It reopens the
  window ADR 0043 closes, for every destination after the first.
- **Copy to the destinations in parallel.** The cluster's backup lock admits
  one step at a time, by design (#2218), and the cap of eight enabled
  destinations (decision E8) keeps the serial chain bounded.

## Consequences

- An env-only deployment sees no change: the same `rclone` commands,
  the same log lines and error text, the same `manifest.json` `offsite`.
  `test/kiln_cms/backups/offsite_parity_test.exs` pins it.
- `manifest.json` gains an additive `destinations` list on in-app backups;
  `offsite` still means `BACKUP_RCLONE_REMOTE`, and only when it was
  reached. Cron (`scripts/backup.sh`) never reads stored destinations and
  keeps decision 3 of #2218 as it was: a failed copy fails its run.
- A succeeded backup can now mean "not everywhere". History badges it
  **Partly off-site**, and a succeeded run that recorded no outcome for its
  destinations (finished by a node of an older release) **Off-site
  unknown**.
- A rolling upgrade from a release without destinations is not safe for a
  backup that runs during it, and a rollback below it can't write runs
  that carry a `dest:` key ([docs/releasing.md](../releasing.md#rolling-back-past-backup-destinations)).

## When to revisit

- When a partial run can be completed after the fact (a follow-up to send a
  succeeded backup again to the destinations it missed), "can't be resumed"
  above changes, and this record gains a status line.
- If the backup lock ever admits more than one step at a time, parallel
  uploads across destinations become possible, and the serial chain is the
  first thing to weigh against them.
