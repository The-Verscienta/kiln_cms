# 0038. A backup asked for while one runs queues behind it, and only like folds into like

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) and was narrowed by #2540, both in 1.9.0.
- **References** — [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  (owner decision 2 of 2026-11-09, in its comments; PR #2537),
  [#2540](https://github.com/The-Verscienta/kiln_cms/issues/2540) (the
  owner's decisions of 2026-11-10 for scheduled and manual requests),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0046](0046-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md)
  for what the lock transaction may write,
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  for how a stopped holder lets the queue move.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-step-chain) (Added:
  the step chain and its lock, #2218) and
  [1.9.0](../changelog/v1.9.0.md#backup-fold-like-into-like) (Changed: like
  folds only into like, #2540).

## The problem

Before #2218 an in-app backup was one Oban job on the `backups` queue, limited
to one per node. Oban here is the open-source edition, with no global limit,
so on a cluster two nodes could run two backups at once, writing into the same
backup directory. Whatever replaced it had to answer what happens to a backup
asked for while another runs: a second click on **Back up now**, a **Resume**,
a console call, and (since #2219) a schedule whose window comes due during a
long backup.

Each answer loses something:

- **Refusing it** loses the request. A schedule tick refused that way is a
  window with no backup, and the caller has to notice and try again.
- **Queuing every request** turns ten impatient clicks into ten backups, run
  back to back, each a full copy of the same data.
- **Folding every later request into one queued backup** (decision 2 as
  first shipped) loses work when the two differ: a resume finishes an old
  backup's stamp, so a fresh backup folded into a queued resume is never
  taken, and a resume folded into a queued fresh backup never resumes
  (#2540).

## Decision

- **One chain at a time, cluster-wide.** A backup is a chain of
  `KilnCMS.Backups.StepWorker` jobs, and one chain holds the backup pipeline
  at a time, recorded on the singleton `KilnCMS.Backups.Lock` row. Every
  decision about it runs in `KilnCMS.Backups.Chain.with_lock/1`: a
  transaction that takes `pg_advisory_xact_lock` on one fixed key, then reads
  the row, and commits the row's writes together with the `Oban.insert/2` or
  cancel they decide on.
- **A request while a chain runs queues behind it; at most one waits.**
  `Chain.request/1` writes the request onto the row's `waiting_*` fields
  (`:queue_waiting`). When the running chain ends, by success, failure,
  Cancel, a reclaim with no attempts left, or a reap,
  `Chain.release_in_txn/1` promotes it to a new chain (a fresh backup under a
  new stamp, a resume under the stamp it resumes), in the same transaction as
  the release.
- **A later request folds into the queued one, but only when it does the
  same work** (#2540). A fresh backup folds into a queued fresh backup, and a
  resume into a queued resume of the same stamp (`:fold`, which counts it in
  `waiting_folds`). The fold is logged at `info` and emits
  `[:kiln_cms, :backups, :request, :folded]`. Any other pairing returns
  `{:error, {:queue_busy, :backup | {:resume, stamp}}}` and leaves the queue as
  it was; a resume of the stamp the running chain holds returns
  `{:error, :in_flight}`.
- **A fold never leaves the queued backup covering less than either request
  asked for.** A fresh request folded into a queued fresh one widens it to the
  union of their components (`Chain.fold_fields/2`). A queued resume keeps its
  run's components. A queued request whose scope fields were written by a node
  from before #2219 (`Chain.waiting_scope/1` says they are not valid) covers
  everything.
- **A scheduled request gets the same answer, and its window claim rides on
  it.** The claim runs inside the lock transaction only after the decision
  succeeded (`request/1`'s `:claim`). A refusal never runs it, so the window
  stays due, and the scheduler asks again on a later tick; a scheduled backup
  is never folded into a queued resume.

## Rejected

- **Refuse a second backup with "already running".** It was the
  recommended default in the planning of #2218; the owner chose to queue
  (decision 2). Refusing hands every collision back to the caller, and a
  schedule collides by design whenever a backup outlasts the gap to the next
  window.
- **An unbounded queue.** The queued backup starts only after the running one
  ends, so it copies the newest data anyway; a second queued backup would copy
  the same data again a few minutes later. One waiting request, with later
  ones folded in and counted, does the same work once.
- **Fold anything into the queued request** (decision 2 as #2537 shipped it,
  option 1 of #2540 with a reworded message). It tells the caller the queued
  backup covers the request when it does not.
- **Let a resume replace a queued fresh backup, or the reverse** (option 3
  of #2540). The request it replaces was accepted and acknowledged; replacing
  it silently loses that one instead.
- **Oban's own limits.** `backup_steps: 1` is per node, and a global limit is
  an Oban Pro feature. A unique job cannot say "one chain of many steps", nor
  hold a request behind it.

## Consequences

- A refused request changes nothing: no backup is queued, no run appears in
  History. The person asks again once the queue clears (the Backups page says
  so); a schedule's window is asked for again every minute until it is.
- A queued request cannot be removed. It can be canceled once it starts.
- Folded requests leave no run of their own. The promoted chain's log in
  History says how many folded into it.
- `scripts/backup.sh` does not take the lock, so a cron backup and an in-app
  backup can run at the same time. They normally write different stamps;
  nothing coordinates them, so a cron run and an in-app backup started in the
  same second would share one.

## When to revisit

- If a queued request needs to be removable or reordered, or more than one
  kind of request needs to wait at once.
- If Oban Pro (a global limit, workflows) becomes a dependency, the lock row
  may no longer be the cheapest way to hold one chain at a time; the fold
  rule would still be needed.
