# 0062. A schedule's keep holds reach `backup.sh` through a third presence-only marker

- **Status** — accepted (2026-11-14). Records the contract that ships with a
  schedule's keep settings (part 3 of #2219, without sub-daily intervals).
- **References** — [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219)
  (the owner's decisions on keep N: count and age per schedule, a schedule's
  own minimum age, manual backups not counted, fail closed, cron-made
  backups counted; sign-off (b), the newest verified backup is never
  deleted, extended here to what a schedule keeps);
  [ADR 0041](0041-the-app-and-backup-sh-agree-on-what-to-keep-only-through-presence-only-marker-files.md),
  whose contract this extends;
  [ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md)
  for how the marker sync reaches each host's directory.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes and Added, part of
  #2219 ([long form](../changelog/unreleased.md#backup-schedule-keep)).

## The problem

A schedule can now keep its newest N backups however old (`keep_count`) and
keep its own backups for a number of days (`keep_days`) that may be longer
or shorter than `BACKUP_KEEP_DAYS`. The app's retention
(`KilnCMS.Backups.Retention`) works out what that keeps from the schedules
and the Run history. `scripts/backup.sh prune` prunes the same directory from
host cron with neither: it ages everything by `BACKUP_KEEP_DAYS` and keeps
only what a marker names (ADR 0041). Left alone, cron would delete every
backup a schedule keeps past `BACKUP_KEEP_DAYS` at its next run, whatever the
app decided.

ADR 0041 said that if a third marker were ever needed, its presence-only rule
was the first thing to weigh. It holds here.

## Decision

**The contract.** The app keeps one `kiln-<stamp>.hold` in a component's own
directory (`db/` or `media/`) for every unit the schedules' keep rules hold.
Like `.good`, it pins only that component of that stamp, only its presence
counts (an entry of that exact name of any kind), and the name is strict
(`Artifact.hold_name/1`, `parse_hold_name/1`: a full `YYYYMMDD-HHMMSS`
stamp). `backup.sh prune` keeps a unit with a `.hold` in its own directory
(`is_held`, next to `is_last_good`) and never deletes a `.hold`. The app
never reads a `.hold` as a keep rule: it works out the holds from the
schedules every time (`Retention.plan/4`'s `holds`), and reads the markers
only to move them and count them (`KilnCMS.Backups.Markers`).

**What a schedule keeps** (retention's rules 5 to 8, after the recovery
point, in flight, newest verified and newest complete):

5. **Keep count.** For each kind a schedule with `keep_count` N backs up: its
   own newest N, and the newest N of its own and the cron-made ones together
   ("keep more"), however old. Only good units count: complete on disk, of a
   succeeded run whose artifact is verified (or imported), not in flight, of
   a plausible stamp, and not a recovery point.
6. **Unrecorded** units age at the kind's floor.
7. **A schedule's own** units age at the longest `keep_days` of the live
   schedules they were made for, which may be below `BACKUP_KEEP_DAYS`.
8. **Imported and orphaned** units age at the floor.

The **floor** of a kind is `max(BACKUP_KEEP_DAYS, keep_days of every schedule
covering the kind)`, a schedule without `keep_days` counting as
`BACKUP_KEEP_DAYS`. No backup a schedule did not make ages out sooner than
one it did.

**Whose backup it is.**

- A unit is a schedule's own only when its run is an app run of trigger
  `"schedule"`, the kind is in the run's `scheduled_components`, and a live
  schedule covering the kind is in its `schedule_ids`. Paused schedules are
  live: `Retention.Policy.current/0` reads every schedule, enabled or not.
- **Imported runs count toward keep more whatever their trigger.**
  `BACKUP_TRIGGER` relabels a cron run, and over-counting only keeps more:
  a unit counted that should not have been is kept a while longer, never
  deleted sooner.
- **A deleted schedule's runs**, or runs of a schedule that no longer covers
  the kind, count like cron's: in the keep-more pool of the live schedules
  covering the kind, and aged at the floor. Deleting a schedule therefore
  never shortens anything below `BACKUP_KEEP_DAYS`.
- **A non-scheduled request that folds into a queued scheduled one takes over
  the trigger** (`Chain`'s fold sets `waiting_trigger`; a scheduled request
  folding into a queued manual one keeps the manual trigger). The run is then
  not the schedule's own: never counted, and aged at no less than
  `BACKUP_KEEP_DAYS` (or its schedules' `keep_days` when longer). A manual
  backup must never age out on a schedule's shorter keep days.

**Which units are held.** Every unit kept by rules 5 to 8 on something other
than plain `BACKUP_KEEP_DAYS`: every unit a keep count holds, and every unit
kept on a schedule's own `keep_days` or a raised floor until that age passes,
whatever rules 1 to 4 say of it (a `.keep` stamp included; it is still never
counted toward N). Membership is decided by rank and policy, not by whether a
unit has crossed `BACKUP_KEEP_DAYS`, so the hold is in place before cron
could delete the unit rather than up to a marker-sync interval after it, and
the set does not depend on the host's `BACKUP_KEEP_DAYS`.

**When it moves.** Wherever `.good` is synced, in the same order: after a
successful in-app backup, before an in-app prune deletes anything, and every
15 minutes from `MarkerSyncWorker`; plus one sync queued after every schedule
create, update and destroy (`Schedule.Changes.SyncHolds`, after the
transaction commits). New holds are written first; stale ones are removed
last, regular files only.

**Fail closed.** The schedules are read as the `:backups` system actor with
`authorize_with: :error`; a refused or failed read is
`{:read_schedules, error_module}`, never "no schedules". In a prune nothing
is deleted. In a marker sync the `.good` markers still move (they don't
depend on the schedules) and every hold is left as it is, with a warning and
`[:kiln_cms, :backups, :hold, :failed]`: a hold too many keeps a backup
longer, one too few lets cron delete what a schedule keeps.

**Cron keeps at least what the app keeps.** Every unit the app keeps past
`BACKUP_KEEP_DAYS` is held; a unit the app deletes sooner (a schedule's own,
on short `keep_days`) cron keeps until `BACKUP_KEEP_DAYS` or until the hold
goes. The two prunes' survivors are a superset relation, cron's ⊇ the app's,
not equality (`test/scripts/backup_script_test.exs`'s parity fixture).

**Steady state is N + 1 sets.** The in-app prune runs while its own run's
`.work/<stamp>` exists, so that run is in flight and not counted: N finished
backups plus the one being made, until the next prune. The Schedule tab's
estimate says N + 1.

## Rejected

- **Reuse `.good` for holds.** There is one `.good` per directory: the
  sync removes every other `.good` once the new one is written, so holds
  would be deleted by the very code that keeps the last-good marker right.
  Allowing several would also mislabel the Backups page, which reads `.good`
  as "the last good backup".
- **Hold only once a unit crosses `BACKUP_KEEP_DAYS`.** Cron can prune in
  the up-to-15-minute gap before the next sync writes the hold.
- **Markers with contents** (the schedule id, a keep-until date), or
  **`backup.sh` reading the database.** Both were rejected in ADR 0041 for
  reasons that hold unchanged.
- **A `BACKUP_KEEP_COUNT` environment variable for cron.** One count for the
  whole host can't express per-schedule, per-component counts, and the owner
  decided against a new variable (#2219).
- **Classify by trigger text alone** (`"schedule"` vs `"cron"`). A fold kept
  the queued trigger, and `BACKUP_TRIGGER` relabels cron runs; `schedule_ids`,
  `scheduled_components` and `origin` are the record, the trigger only the
  fold's tie-breaker.
- **A deleted schedule's runs keep counting as its own**, or fall to plain
  `BACKUP_KEEP_DAYS` age. The first lets a schedule that no longer exists
  hold backups; the second lets deleting a schedule age out backups sooner
  than the floor that other schedules covering the kind set.
- **Validate the maxima in `Policy.validate/1`.** The schedule's own
  constraints (`keep_count` 1 to 1000, `keep_days` 1 to 3650) are the
  maxima; the policy checks positivity only, so a schedule written by a newer
  release with a wider range doesn't stop every prune.

## Consequences

- **A host whose `backup.sh` predates this release ignores `.hold`** and
  deletes what a schedule keeps past `BACKUP_KEEP_DAYS`, without a warning
  in the app. The upgrade note asks for the script first, and the Schedule
  tab asks when host cron backed a component up in the last eight days.
  Detecting an orphan hold (a `.hold` whose backup cron deleted anyway) is a
  follow-up.
- **A schedule change made while a marker-sync job is executing** may wait
  for the next slot (15 minutes by default) or the next in-app backup: the
  job is unique while one is available, scheduled, executing or retryable, so
  `SyncHolds` queues nothing then, and the executing job may have read the
  schedules before the change.
- **With `KILN_BACKUP_MARKER_SYNC_CRON=false`**, holds move only on the app's
  own backups and prunes; a cron-only deployment then has none.
- **Rolling back to 1.9.x** ignores the keep settings and deletes `.hold`
  files as strays in its in-app prune once they are older than
  `BACKUP_KEEP_DAYS`. 1.9.x has no scheduled marker sync, so a deployment
  that takes no in-app backups keeps its holds, and this release's script
  keeps their backups, until they are deleted by hand.
- **Sub-daily intervals stay refused** (`Validations.IntervalAvailable`).
  A keep count is a minimum, not a cap; whether a sub-daily schedule must set
  its own `keep_days` is an open owner question on #2219.

## When to revisit

- If a fourth marker is needed, a marker with contents (or one manifest of
  markers) becomes cheaper than another name; weigh it against ADR 0041 and
  this record together.
- If `backup.sh` ever ships inside the release image, both records' reason
  for the markers goes away.
