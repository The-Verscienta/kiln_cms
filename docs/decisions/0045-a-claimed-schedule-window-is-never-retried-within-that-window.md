# 0045. A claimed schedule window is never retried within that window

- **Status** — accepted (2026-11-13), recording the rule that shipped with
  the in-app schedules backend (part of #2219), not yet released.
- **References** — [#2821](https://github.com/The-Verscienta/kiln_cms/issues/2821),
  [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219) and its pull
  request [#2820](https://github.com/The-Verscienta/kiln_cms/pull/2820);
  [#2540](https://github.com/The-Verscienta/kiln_cms/issues/2540) for why a
  scheduled backup never folds into a queued Resume;
  [ADR 0044](0044-a-schedule-sets-a-components-alarm-threshold-only-while-it-can-run-here.md)
  for the alarm that reports a failed window.
- **Changelog** — the Unreleased entry
  [In-app backup schedules](../changelog/unreleased.md#backup-schedules).

## The problem

A schedule's **window** is one occurrence of it ("03:00 Paris on 12
November"). `KilnCMS.Backups.Scheduler` ticks every minute (one cron job, run by
whichever node fetches it; ticks can overlap across a leader change, a deploy
or a console `tick/1`) and asks for a backup for each schedule whose latest window is due
(`KilnCMS.Backups.Schedule.Window.due/2`). Whatever records "this window was
taken" decides three things at once:

- **that a window fires once**, however many nodes tick and however a deploy
  overlaps them;
- **what happens when its backup fails**, which can be an hour after the
  window was taken;
- **what happens when it cannot be taken yet**: a Resume is queued, or the
  node that ticked has no `pg_dump`.

## Decision

- **A window is claimed when its backup is asked for, in the same
  transaction.** `KilnCMS.Backups.Lock.Actions.RequestScheduled` hands
  `KilnCMS.Backups.Chain.request/1` a `:claim` function. The chain runs it
  inside the backup lock transaction, only after its decision succeeded, so
  the claim (`:claim_window`, setting `last_window_at` with the outcome
  `:started`, `:queued` or `:folded`) commits together with the Lock write and
  the `Oban.insert/2` it decided on. Schedules due together are one backup and
  are claimed in id order inside one request.
- **A claimed window is never asked for again.** Once `last_window_at` is the
  window, `Window.due/2` no longer returns it. A backup that then fails, after
  its steps' own retries, is not retried by the scheduler; the schedule waits
  for its next window, and **Back up now** or **Resume** takes one in the
  meantime.
- **A window that can't run on this deployment is claimed as refused.**
  `BACKUP_ENABLED=false`, or a media-only schedule on a node with no media
  directory, is `:refuse_window`: claimed, so nothing asks again until the
  next window.
- **Only deferrals are retried, every minute.** A request that is refused for
  now claims nothing, and the window stays due: `{:queue_busy, _}` (a Resume is
  queued, and a scheduled backup never folds into one, #2540); a node with no
  `pg_dump`, `pg_restore` or database URL, so a node that has them takes the
  window; and any other error or exception from the request. `:note_deferred`
  records the first deferral of each window (`last_deferred_window_at`), so it
  is logged once, not every minute. A deferred window stays due only until
  the schedule's next window comes.
- **A lost claim rolls the whole attempt back, and the scheduler reads
  again.** The claim is a guarded update (the schedule enabled, the window not
  before `baseline_at` and after `last_window_at`). Another node's claim, a
  pause or an edit since the read makes it match zero rows, which is a
  `StaleRecord` error (`:window_taken`). That error rolls back the decision's
  Lock write and its `Oban.insert/2` with it; `RequestScheduled` then reads the
  schedules again and asks for what is still due, at most twice more.

## Rejected

- **Retry a failed backup within its window.** The window would have to stay
  due until a backup succeeds, so the scheduler would follow each backup's
  outcome. A failure that repeats (a full disk, a broken `pg_dump`, a
  database that refuses the dump) would start a full backup every minute, each
  one load on the database and a set on disk. The failure is already visible:
  a failed run in History, a Resume button, and the stale alarm at the
  schedule's threshold.
- **Claim when the backup finishes.** The window would stay due for the whole
  run, and every tick on every node would ask for it again, queueing or
  folding a second backup.
- **Claim outside the lock transaction.** Claiming first loses the window when
  the request is then refused (a queued Resume); claiming after the commit
  fires the window twice if the node dies between the two.
- **`rollback_on_error?: false` on a lost claim** (keeping the decision and
  dropping only the losing claim, an earlier review suggestion). The decision
  would commit a backup for a window another node had already fired, or one
  that covers schedules whose claims lost. Rolling everything back and reading
  again costs at most two more reads, and the next tick reads again anyway.

## Consequences

- A scheduled backup that fails leaves that window without a backup unless
  someone takes one. The signals are the failed run, the "Last window" line
  in the Schedules list, and the stale alarm
  ([ADR 0044](0044-a-schedule-sets-a-components-alarm-threshold-only-while-it-can-run-here.md)).
- A deferral that lasts past the next window becomes a missed window: only
  the latest window fires, and the earlier one is logged as missed.
- Restoring a database dump restores `last_window_at` as it was, so each
  enabled schedule whose latest window is newer than that fires within a
  minute. Restoring the newest scheduled dump before the next window fires
  nothing: that dump was taken after its own window was claimed.

## When to revisit

- **Operators want automatic retries** of a failed scheduled backup: a
  bounded retry count with a backoff recorded on the schedule, not a window
  left unclaimed.
- **Sub-daily intervals ship** (#2219, part 3): with a window every two hours
  a failed one costs less, and a deferral is more likely to run into the next
  window.
- **Two retries stop being enough**, because many schedules fall due in the
  same minute across many nodes: the losers are read again on the next tick,
  so this would show up as windows firing a minute late, not as lost ones.
