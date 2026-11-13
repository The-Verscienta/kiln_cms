# 0044. A schedule sets the alarm threshold only while it can run, and a claimed window is never retried

- **Status** — accepted (2026-11-13).
- **References** — [#2821](https://github.com/The-Verscienta/kiln_cms/issues/2821)
  (this record); part of [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219)
  (the in-app schedules: PR #2820 built the scheduler and the read-only list,
  the next one the Schedule tab);
  [#2540](https://github.com/The-Verscienta/kiln_cms/issues/2540) for why a
  fresh backup never folds into a queued Resume.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md)
  (Added, "In-app backup schedules"), long form in
  [unreleased.md](../changelog/unreleased.md#backup-schedules).

## The problem

An in-app backup schedule (`KilnCMS.Backups.Schedule`) runs the same backup as
**Back up now**, through the same lock and queue, from a scheduler job that
ticks every minute on every node (`KilnCMS.Backups.Scheduler`). Three
questions decide whether a schedule can be trusted, and each has a cheaper
answer that a later reader will be tempted by:

- **Which alarm threshold does a scheduled component get?** The console
  alarms when a component's last good backup is older than
  `BACKUP_STALE_AFTER_HOURS` (default 36). A weekly schedule under that rule
  alarms six days in seven. Letting any schedule set the threshold instead
  means a schedule that never runs silences the alarm.
- **What happens to a window whose backup fails?** Asking again every minute
  until it works looks like resilience.
- **How does a window fire exactly once** when every node ticks, a deploy
  restarts the job, and the backup lock may be held?

## Decision

### A schedule sets a component's threshold only while it can run here

`KilnCMS.Backups.status/0` judges each component by a rule built in
`schedule_rule/4`. A schedule counts for a component only when all of these
hold:

- backups are available on this node (`Backups.availability/0` is `:ok`) and
  the scheduler is on (`Scheduler.enabled?/0`, from
  `KILN_BACKUP_SCHEDULER_CRON`);
- the schedule is enabled and covers the component;
- its last window was not refused (`last_outcome != :refused`:
  `BACKUP_ENABLED=false`, or media-only on a node with no media directory);
- at least one of its windows has already come since its baseline (creation,
  last timing edit or resume) and its start date (`window_passed?/2`, from
  `Schedule.Window.latest/2`).

Then the threshold is the shortest counting schedule's interval plus half of
it, at least six hours (`Schedule.Window.stale_after_hours/1`:
`h + max(div(h, 2), 6)`, so daily 36 h, weekly 252 h, fortnightly 504 h,
monthly 1116 h), with `stale_source: {:schedule, id}`. If none counts, the
component keeps `BACKUP_STALE_AFTER_HOURS` (`{:env, …}`).

When host cron has also backed the component up in the last eight days (an
imported run with trigger `cron`, `cron_backs_up?/1`) and the environment's
threshold is the lower one, the lower one wins (`{:cron, …}`): cron runs on
its own cadence and a weekly schedule must not hide a nightly cron job that
stopped. A read of that evidence that fails counts as "cron backs it up", so
the error is an alarm that comes sooner, never later.

Every condition closes a way for a schedule to silence the alarm without
taking a backup: a scheduler that is off, a node without `pg_dump`, a
deployment with backups turned off, a schedule paused, a start date next
month, a schedule created a minute ago. In each, the environment's threshold
applies, and a schedule shows a next run only when the same conditions say
it will fire, so the Backups page, the Schedule tab and the home strips agree.

### A claimed window is never retried within that window

A window (one occurrence, "03:00 Paris on 12 November") is claimed when its
backup is asked for, not when the backup finishes: `Schedule`'s
`:claim_window` sets `last_window_at`, and `Window.due/2` only offers a window
newer than that. If the backup then fails, after its steps' own retries, the
schedule waits for its next window. An admin who wants a backup sooner takes
one with **Back up now**, or continues the failed one with **Resume**.

A window whose backup was **not** asked for is not claimed and stays due, so
the next tick asks again, each minute until it can:

- the decision refused it for now, `{:queue_busy, _}`, because a Resume is
  queued and a fresh backup never folds into a Resume (#2540);
- the node that ticked has no `pg_dump`, `pg_restore` or database URL, which
  is that node's problem, not the deployment's, so another node may take it;
- the request hit a step conflict, another error or an exception.

Each wait is noted once per window on the row (`:note_deferred`,
`last_deferred_window_at`), so the log says it once while the tick keeps
asking. A window that can never run here, `BACKUP_ENABLED=false` or a
media-only schedule with no media directory, is claimed as refused
(`:refuse_window`), so nothing asks again until the next window.

### The claim runs inside the backup lock transaction, after the decision

`KilnCMS.Backups.Lock.Actions.RequestScheduled` asks for one backup covering
every due schedule and passes `KilnCMS.Backups.Chain.request/1` a `:claim`
function. `Chain.request/1` runs `decide_and_claim/2` inside `Chain.with_lock/1`
(the advisory-locked transaction that writes the lock row and inserts the
step job): it decides first (start, queue or fold), then runs the claim with
that outcome. A refused decision never runs the claim, so nothing is claimed.

The claim is an atomic, filtered update per schedule (enabled, baseline at or
before the window, no newer window claimed). When it matches zero rows (the
window taken by another node, or the schedule paused or edited since the
read), it is a `StaleRecord` error that `claim_all/2` turns into
`:window_taken`, and `with_lock/1` rolls the whole attempt back: the
decision's lock write and its `Oban.insert/2` with it. `RequestScheduled`
then reads the schedules again and asks for what is still due, at most twice
more (`@retries 2`), and otherwise reports `:nothing_due`.

So a window is claimed exactly when the backup it asked for is started,
queued or folded, in the same commit, however many nodes tick. Oban's
`unique` on the scheduler job is only a damper.

## Rejected

- **Leaving the threshold on `BACKUP_STALE_AFTER_HOURS`.** A weekly schedule
  would alarm six days in seven, and admins learn to ignore a red strip.
- **Any enabled schedule sets the threshold from the moment it exists.** A
  schedule that can't fire (scheduler off, backups disabled, a node without
  the client tools, a start date in the future) would raise the threshold and
  stay green while nothing is backed up.
- **The schedule's threshold even when host cron also backs the component
  up.** A broken nightly cron job would go unnoticed for a week behind a
  weekly schedule.
- **Retrying a failed window every minute.** A backup that failed after its
  own step retries fails for a reason (a full disk, a refused remote) that the
  next minute rarely fixes; asking again turns one failure into a backup storm
  against it, and **Resume** already continues the failed run.
- **Retrying a refused window every minute.** `BACKUP_ENABLED=false` doesn't
  change between ticks; asking again only fills the log.
- **Claiming on success.** The claim would be written after the backup ends,
  outside the lock, and two nodes could both start one for the same window.
- **Claim, then request, then compensate on refusal.** A crash between the
  steps loses the window or fires it twice.
- **Letting a lost claim fail alone with `rollback_on_error?: false`,** so
  that the decision and the other claims commit. The first design did this.
  It depends on Ash leaving the outer transaction usable after a failed
  update, which the code would rely on without owning, and a failed statement
  aborts the PostgreSQL transaction for every statement after it. It would
  also commit a backup asked for a window another node had already fired.
  Rolling the whole attempt back and reading again costs one more read on a
  race that is rare.
