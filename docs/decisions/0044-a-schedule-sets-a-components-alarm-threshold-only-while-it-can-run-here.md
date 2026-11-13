# 0044. A schedule sets a component's alarm threshold only while it can run here

- **Status** — accepted (2026-11-13), recording the rule that shipped with
  the in-app schedules backend (part of #2219), not yet released.
- **References** — [#2821](https://github.com/The-Verscienta/kiln_cms/issues/2821),
  [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219) and its pull
  request [#2820](https://github.com/The-Verscienta/kiln_cms/pull/2820);
  [ADR 0045](0045-a-claimed-schedule-window-is-never-retried-within-that-window.md),
  which leaves this alarm as the signal that a scheduled backup failed.
- **Changelog** — the Unreleased entry
  [In-app backup schedules](../changelog/unreleased.md#backup-schedules).

## The problem

The Backups page and the overview call a component (the database, the media)
stale when its last good backup is older than a threshold. Before in-app
schedules that threshold was `BACKUP_STALE_AFTER_HOURS` (default 36), set by
an operator who knows how often host cron runs. A schedule changes the
expected gap: a weekly schedule makes a 36-hour threshold an alarm six days in
seven, and an alarm that is always on is one nobody reads. So a schedule must
be able to move the threshold. But moving it is also the way to silence the
alarm: a weekly schedule raises it to 252 hours, and if that schedule never
actually runs, the alarm stays quiet for ten days while nothing is backed up.

Three questions follow: when does a schedule get to set the threshold, to
what, and what happens when host cron backs up the same component too?

## Decision

The rule is `KilnCMS.Backups.status/0`'s, for each component:

- **A schedule counts only while it is known to run on this node.** All of
  these must hold:
  - backups can run here (`KilnCMS.Backups.availability/0` is `:ok`: not
    `BACKUP_ENABLED=false`, and `pg_dump`, `pg_restore` and a database URL
    present) and the scheduler is on (`KilnCMS.Backups.Scheduler.enabled?/0`,
    `KILN_BACKUP_SCHEDULER_CRON`);
  - the schedule is enabled and covers the component;
  - its last window was not refused (`last_outcome` is not `:refused`);
  - at least one of its windows has come since its baseline and its start
    date (`KilnCMS.Backups.Schedule.Window.latest/2` is not before
    `baseline_at`), so a schedule created or edited today does not move the
    threshold before its first window.
- **The threshold is the interval plus half of it, at least six hours**
  (`KilnCMS.Backups.Schedule.Window.stale_after_hours/1`: daily 36 h, weekly
  252 h, fortnightly 504 h, monthly 1116 h), for the shortest counting
  schedule on that component, with `stale_source: {:schedule, id}`.
- **When host cron backs the component up too, the lower one wins.** If an
  imported run with trigger `cron` covered the component in the last eight
  days, the threshold is the lower of the schedule's and
  `BACKUP_STALE_AFTER_HOURS` (`{:cron, "BACKUP_STALE_AFTER_HOURS"}` when the
  environment's wins). A read of the runs that fails counts as "cron backs it
  up": the lower threshold alarms sooner, never later.
- **Otherwise the environment's threshold applies**
  (`{:env, "BACKUP_STALE_AFTER_HOURS"}`), and also when the schedules can't be
  read.

## Rejected

- **Keep `BACKUP_STALE_AFTER_HOURS` for everything.** A weekly or monthly
  schedule would alarm on most days, and the operator's only fix would be to
  raise the variable for every component, cron's included.
- **Let any enabled schedule set the threshold.** A schedule on a node whose
  scheduler is off, that has no `pg_dump`, whose windows are refused
  (`BACKUP_ENABLED=false`), or that has not reached its first window would
  raise the threshold for backups that are not happening. Each condition above
  is a way a schedule exists without running; failing any of them falls back
  to the operator's own setting.
- **Let the schedule win over cron's evidence.** The application does not know
  cron's cadence. A nightly cron job and a weekly schedule on one component
  would otherwise move the threshold to 252 hours, and a cron job that stopped
  would go unnoticed for ten days. Eight days covers a weekly cron job plus a
  day.

## Consequences

- The condition is that a window has **come**, not that it succeeded. A
  window whose backup failed or was deferred still counts, and that is safe:
  staleness is measured from the last good backup, so a schedule that keeps
  failing becomes stale at its own threshold.
- "Here" is the node that renders the status. On a deployment whose nodes
  differ (one without `pg_dump`), that node shows the environment's threshold
  and no "Next run", although another node runs the schedule.
- A schedule's first window arms the new threshold. Until then, a weekly
  schedule on a deployment with no other backups shows the 36-hour alarm.

## When to revisit

- **Sub-daily intervals ship with keep-N retention** (#2219, part 3): an
  every-2-hours schedule's threshold (8 h) is below the environment's
  default, so schedules start lowering thresholds, and the cron rule (the
  lower wins) needs a second look.
- **The scheduler gets a liveness signal** ("the scheduler hasn't ticked"): it
  could replace "a window has come" as the evidence that a schedule runs.
- **Status looks across nodes** (the node beats of `KilnCMS.Backups.NodeBeat`
  could say whether any node can run backups): "here" could become
  "somewhere".
