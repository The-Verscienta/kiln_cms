# 0045. A backup Run write never shares the lock transaction, except Cancel's

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) in 1.9.0.
- **References** — [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  (PR #2537), [#2538](https://github.com/The-Verscienta/kiln_cms/issues/2538),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0038](0038-a-backup-asked-for-while-one-runs-queues-and-only-like-folds-into-like.md)
  for the lock and its queue,
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  for the fencing that keeps a late Run write off another chain's row.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-step-chain) (Added:
  the step chain and its lock, #2218).

## The problem

Every decision about the backup lock (start, queue, fold, advance, release,
reclaim, reap) runs in one transaction, `KilnCMS.Backups.Chain.with_lock/1`:
the advisory lock, the `KilnCMS.Backups.Lock` row's write, and the
`Oban.insert/2` or cancel it decides on commit together, so a step job exists
exactly when the row names it.

Each of those moments also has something to say to History, the
`KilnCMS.Backups.Run` row: a step's progress, an interrupted backup, a refused
resume, the queued request's log line. It is tempting to write it in the same
transaction, so the row and the lock never disagree.

But a Run write can fail for reasons that have nothing to do with the lock: a
validation, a policy, a database error such as a constraint or a timeout. An
Ash action that fails that way inside a transaction rolls the enclosing
transaction back (`Ash.DataLayer.rollback`), and a failed PostgreSQL
statement aborts it outright; catching the error in Elixir does not bring the
transaction back. A History write that failed inside the lock transaction
would roll back the step insert it rode with, and stall the chain on
bookkeeping. The one exemption is a stale record: a zero-row update that
returns `Ash.Error.Changes.StaleRecord` (a row filtered away by
`Run.Changes.OwnChain`, #2538) leaves the enclosing transaction alone.

## Decision

- **No Run write happens inside `with_lock/1`.** A step writes its progress
  before it moves the chain on, outside the lock (`Recorder.progress/1`, after
  the fenced `state.json` write and before `Chain.advance/3`); the
  bookkeeping of a reclaim, a reap or a given-up resume
  (`Steps.interrupt/4`, `Steps.resume_refused/3`) runs after the commit. A
  Run write is best-effort: a failed one costs a line of History, never the
  backup.
- **Anything that writes Run rows runs outside the lock too.**
  `Chain.sync_last_good/2` runs the importer, which writes Run rows for
  cron-made backups, first and on its own, and takes the lock only for the
  scan, the Run read and the marker writes.
- **A failing chain closes its Run before it releases the lock**
  (in `KilnCMS.Backups.Steps`' failure path, the Run first and then
  `Chain.release/1`), so a Resume can never re-open a run
  that this chain is still about to write.
- **The one Run write that does share the lock is Cancel's.** `Run`'s
  `:cancel` action is the platform admin's request, and the Run row is its
  result. Its own transaction takes the same advisory lock
  (`Chain.locked_row/0`, from a `before_action` hook in
  `Run.Changes.Cancel`), cancels the chain's jobs and releases the lock
  (`Chain.release_in_txn/1`), so the row says `canceled` exactly when the
  chain was stopped. When that write fails, the whole cancel rolls back and
  the admin sees the error; nothing is half-canceled.
- **The other write inside the lock transaction is not a Run write**: a
  scheduled request's window claim (#2219). When the window was taken
  elsewhere it comes back as a stale record, which leaves the transaction
  alone, and the claim rolls back with the request.

## Rejected

- **Write the Run in the lock transaction everywhere,** for a row that never
  disagrees with the lock. Any History failure would then undo the decision
  it described, and the next step's job with it.
- **Write Cancel's Run row after the lock is released,** like the other
  bookkeeping. A failed write would leave a stopped chain whose row still says
  `running`, and a person who clicked Cancel told it worked. Cancel is a person's action whose outcome
  is the row, so it fails as a whole or not at all.

## Consequences

- The Run row can lag the lock. Readers allow for it: Cancel matches a lock
  that holds the run's stamp even when the row's `chain_id` has not caught up
  ("a resume or retry whose Run write lagged"), and the stale-run sweep
  (`Backups.reconcile_stale_runs/1`) fails a `running` row nothing has
  touched for longer than a step's timeout plus 15 minutes, unless the lock
  holds it.
- A late Run write from a superseded step is refused by `Run.Changes.OwnChain`
  rather than by the lock, with an `Ash.Error.Changes.StaleRecord`.
- A failed Run write is visible only in the server log; History may miss a
  progress line or an interrupted note.

## When to revisit

- If History becomes something a backup's correctness depends on (a resume
  that reads its progress from the Run row rather than `state.json`), its
  writes would need the same guarantees as the lock's.
