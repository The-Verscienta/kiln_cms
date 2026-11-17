# 0066. An operator-facing backup problem is a notice row, not a run log line or a security event

- **Status** — accepted (2026-11-16).
- **References** — [#2487](https://github.com/The-Verscienta/kiln_cms/issues/2487)
  (show retention that was skipped or stopped);
  [#2931](https://github.com/The-Verscienta/kiln_cms/issues/2931) (warn when
  a backup a schedule keeps is deleted outside the app);
  [ADR 0045](0045-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md),
  whose rule the marker sync's write follows;
  [ADR 0062](0062-a-schedules-keep-holds-reach-backup-sh-through-a-third-presence-only-marker.md),
  amended for #2931;
  [ADR 0064](0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)
  for retention on a destination.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes and Added
  ([long form](../changelog/unreleased.md#backup-retention-warnings)).

## The problem

Two backup problems leave every backup reading **Succeeded** while the
deployment drifts into trouble:

- **Retention that was skipped or stopped part-way** (#2487). It fails
  closed and deletes nothing, so the disk fills. It said so only in the
  run's log, the server log and an unregistered telemetry event.
- **A backup a schedule keeps, deleted outside the app** (#2931). A host
  whose `scripts/backup.sh` predates the hold markers ignores them (ADR
  0062). The app could see it only as a stale `.hold`, which it quietly
  removed.

Both need a place the Backups page and Home can read without touching the
disk, that says the problem until it is over, and that a backup can write
without any risk to the backup.

## Decision

**One resource, `KilnCMS.Backups.Notice` (table `backup_notices`), one row
per `{kind, scope}`.** The scope is the place: `"local:<dir id>"` for a
backup directory with a `.kiln-dir-id`, `"local"` for one without, and
`"dest:<id>"` for a stored destination.

- **`:retention` is a state.** The prune step and each destination's
  off-site step upsert it on a skip or a stop and delete it on a clean pass
  over the same place (`KilnCMS.Backups.Notices.retention/3`). A destination
  whose retention is off clears it too. It raises the Backups page's
  headline and Home's backup strip.
- **`:held_deleted` is an event with a window.** The hold sync upserts it
  when it finds a held unit gone, merging into a row of the last eight days
  (`Notices.held_deleted/2`); the Backups page and the Schedule tab show it
  for eight days. It doesn't raise the alarm and isn't on Home: the backups
  still run, and Home stays absent when healthy.
- **`Backups.status/0` hides a notice for a place nobody backs up to any
  more**: a local one whose directory id no live node reports, a
  destination's that is disabled, deleted or no longer pruned. When those
  can't be read it shows the notice; a hidden problem is worse than a stale
  line.
- **A notice is what a backup says, never what it does.** Every write is
  wrapped so it returns `:ok` whatever happens (a raise or an exit
  included), logs and counts a failure, and runs through
  `KilnCMS.AfterCommit.run/1`. The marker sync runs under the backup lock's
  transaction, so `Chain.sync_last_good/2` wraps it in
  `AfterCommit.deferring/1` and the write happens after COMMIT (ADR 0045). A
  lost notice is accepted: the log line and the telemetry event still say it.
- **System-only.** Only `Backups.system/0` reads, reports or clears a
  notice; people see notices through `status/0`, on pages that already
  checked for a platform admin. Not exposed through any API.

## Rejected

- **Read the newest run's log line.** A clean prune writes no line, so the
  warning would vanish whenever the newest run failed early or is still
  running and come back with the next; destination skips log under the
  `offsite` step among upload failures; and with per-host directories
  (#2218) the newest run may be another host's.
- **A column on `Backups.Run`.** Most hold syncs run from
  `MarkerSyncWorker` with no run at all, and a state that a later run clears
  is not a property of one run.
- **The instance security log.** Every instance event is a person's action,
  none raises a security alert, and the log carries CSV export, retention
  and erasure rules a backup warning doesn't want. A held backup deleted by
  an old script, an attacker or a hand `rm` look the same from the app, so
  calling it a security event would be a guess.
- **Node-local state** (`:persistent_term`, ETS). Home and the Backups page
  may be served by a node that never ran the backup, and a restart would
  forget the problem.
- **Read the disk on page load.** Home never reads the backup directory,
  and a node serving the page may not have it mounted.
- **Write inside the lock's transaction.** A failed insert would abort the
  marker sync (ADR 0045).
- **Tag the metrics with the reason or the destination.** Both are
  unbounded; the metrics carry `scope` (`local` or `destination`) and `kind`
  only.

## Consequences

- **A local retention notice clears only on the next in-app backup** whose
  prune runs cleanly in that directory. A cron prune, a marker sync and a
  console dry run don't look at it. A cron-only deployment never gets one:
  `backup.sh prune`'s warnings stay in the cron log.
- **Directories without an id share the `"local"` row**: nothing else tells
  them apart. A clean pass in a directory with an id clears `"local"` too, so
  a notice written while the id couldn't be read doesn't outlive the
  problem.
- **The retention events broaden.** `[:kiln_cms, :backups, :retention,
  :skipped | :stopped]` now fire for destinations too, with `scope:
  :destination`; local ones carry `scope: :local`.
- **A held-deleted notice has no dismiss.** It goes after eight days without
  a new detection.

## When to revisit

- If a third kind of operator-facing backup problem appears (cron's own
  prune warnings reaching the app, say), it is a new `kind` here, not a new
  resource.
- If people need to dismiss a notice, add an action for the platform admin
  and a policy for it; today the resource has none on purpose.
