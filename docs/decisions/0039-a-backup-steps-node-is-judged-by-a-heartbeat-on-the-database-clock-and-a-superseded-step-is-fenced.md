# 0039. A backup step's node is judged by a heartbeat on the database clock, and a superseded step is fenced

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) in 1.9.0; the heartbeat's stop of a canceled step
  (#2538) came after it.
- **References** — [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  (owner decision 9 of 2026-11-09, in its comments; PR #2537),
  [#2538](https://github.com/The-Verscienta/kiln_cms/issues/2538),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0038](0038-a-backup-asked-for-while-one-runs-queues-and-only-like-folds-into-like.md)
  for the lock this frees,
  [ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md)
  for which node a requeued step lands on.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-step-chain) (Added:
  "Nodes that stop", #2218), and the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md) (#2538).

## The problem

The backup lock (ADR 0038) is held by one step job on one node. Two things
must stay true when that node stops, hangs or loses the database:

- **The lock must come free.** Otherwise every later backup, scheduled ones
  included, queues behind a chain that will never move.
- **Two nodes must never write the same backup's files at once.** Freeing the
  lock means another node runs the step again, under the same stamp, reusing
  the files already written. If the first node is in fact alive, both write.

What Oban offers on its own is `Oban.Lifeline`, which moves a job that has
sat `executing` for too long back to `available`. Its rescue is purely
time-based, so it must exceed the longest legitimate job: a backup step may
take 2 hours (`StepWorker.timeout/1`), and the rescue is set to 3 hours
(`:oban_rescue_after_minutes`, 180). A node that died would hold every backup
for three hours. And a rescue fences nothing: it cannot tell a dead node from
a slow one.

## Decision

- **Every node beats, on the database's clock.** `KilnCMS.Backups.Heartbeat`
  upserts this node's `KilnCMS.Backups.NodeBeat` every 30 seconds (its Oban
  node name, this boot's id, its backup-directory id). `beat_at` is the
  database's `now()`, a fragment in the INSERT and in the conflict's UPDATE,
  because Ash would evaluate `expr(now())` with this node's clock.
- **The sweep judges the holder's node by its beat, not by the step.**
  `KilnCMS.Backups.Chain.reclaim_stale/0`, under the lock, looks at the
  holder's job only while it is `executing`. Its node (the job's
  `attempted_by`) is stale when its beat is older than 180 seconds by the
  database's clock (with no beat: when the job was attempted that long ago),
  or when the beat's boot id is not the one that claimed the job's current
  attempt (`executing_boot_id`, `executing_job_id`, `executing_attempt`). The
  old job is canceled first; with attempts left the step is requeued under a
  new job with the remaining budget and the same stamp, and with none the
  backup fails as interrupted and the waiting request is promoted.
  `Chain.reap/0` releases a lock whose job ended without moving the chain on.
  Both run on every tick, and before every request.
- **A node that cannot beat stops its own steps first.** Once its last
  successful beat is 90 seconds old (by its own monotonic clock), the
  heartbeat kills every step registered in `KilnCMS.Backups.StepRegistry`,
  and `KilnCMS.ExternalCommand`'s watchers kill the `pg_dump`, `tar` or
  `rclone` each started. 90 is below 180, so the node stops before the others
  may take over. After every successful beat it also kills each step whose
  job is `cancelled`, `completed` or `discarded`, a Cancel or reclaim it
  missed (#2538); a missing job row kills nothing.
- **Every step is fenced by epoch and job id.** `Lock.epoch` goes up on every
  `:hold`, `:move` and `:clear`. `Chain.begin_step/1` admits a job only when
  the row names its chain, step, part and job id, and returns the epoch.
  `advance/3`, `mark_finishing/1`, `release/1` and `while_holding/2` act only
  while the row still has that chain, epoch and job id; otherwise the step
  gets `{:error, :superseded}`, cancels itself and its results are
  discarded. The step's `state.json` write goes through `while_holding/2`,
  and its Run writes are filtered to its own chain
  (`KilnCMS.Backups.Run.Changes.OwnChain`, #2538).

## Rejected

- **Wait for Lifeline.** It was the state before decision 9: about three
  hours per dead node, with every backup, scheduled ones included, queued
  behind it. Lifeline stays as the backstop: a job it discards is reaped.
- **A time lease on the lock row.** The holder would have to renew it, from
  the step itself or something beside it, through a `pg_dump` or a part that
  may take two hours, and a lease long enough not to need renewing is as slow
  as Lifeline. A per-node beat separates "the node is alive" from "the step is
  making progress", and the step's own 2-hour timeout bounds the second. The
  planning on #2218 had already put liveness on something other than a time
  lease.
- **Judge liveness from the job's Oban state alone.** A dead node's job stays
  `executing` until Lifeline rescues it; the state says nothing until then.
- **Each node's own clock.** A beat timed by the node that wrote it would be
  judged by the node that reads it, and nodes drift. One clock, the
  database's, means the 180 seconds are 180 seconds on every node.
- **Reclaim without fencing.** A node that was only partitioned, not dead,
  wakes up holding a lease for a chain that has moved on. Without the epoch
  and job id it could advance, release or rewrite `state.json` over its
  replacement.

## Consequences

- A stopped node's step is taken back about 180 seconds after its last beat,
  plus up to one 30-second tick, instead of about three hours.
- The heartbeat is on by default (`config :kiln_cms, KilnCMS.Backups,
  heartbeat?: true`) and off only in the test build. With it off nothing beats,
  so `request/1` skips the reclaim (every step would look stale), and a dead
  node's step waits for Lifeline or a Cancel.
- Oban node names must be unique per node: two nodes sharing one overwrite
  each other's beat, and a live step can be taken back. The heartbeat logs an
  error when the boot id on its row changes under it.
- A step's own `.partial` files are not fenced. A resume right after a Cancel
  waits 150 seconds (#2538) so a step on a node that missed the Cancel has
  stopped. A heartbeat hung on a half-open connection waits out its database
  timeouts first, so the window is typical, not guaranteed.
- The fenced `state.json` write holds the cluster-wide advisory lock while it
  writes the file. A backup directory that stalls makes Cancel, new requests
  and the sweep wait behind it until their query times out.

## When to revisit

- If Oban Pro's `DynamicLifeline` or another liveness signal with fencing
  becomes available, the heartbeat could defer to it.
- If the 180-second threshold reclaims live steps in practice (a database
  that stalls every beat for minutes), the thresholds, fixed in `Heartbeat`
  and `Chain` rather than configured, need revisiting together: the
  self-fence must stay below the reclaim.
