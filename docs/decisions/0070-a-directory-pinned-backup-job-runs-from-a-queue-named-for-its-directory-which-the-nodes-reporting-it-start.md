# 0070. A directory-pinned backup job runs from a queue named for its directory, which the nodes reporting it start

- **Status** — accepted (2026-11-17). Supersedes the snooze bullets of
  [ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md)
  (a step on the wrong node snoozes, the resume's start snoozes elsewhere):
  the bounded snooze is kept only as the fallback below. ADR 0040's
  `.kiln-dir-id`, its rule that a fresh `start` runs anywhere, and its
  #2817 amendment stand.
- **References** — [#2845](https://github.com/The-Verscienta/kiln_cms/issues/2845)
  and the owner's two rounds of decisions recorded on it (2026-11-17):
  per-directory dynamic queues, a stranded deadline of 30 minutes, a
  bounded-snooze fallback for a resume whose directory no node reports,
  "cancel or let a backup finish before rolling back" with no shutdown
  hook; then a capability column on the beat, stranded only when no node
  reports the directory, and falling back to the snooze when Oban's
  notifier is down.
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  (the heartbeat and its 180 seconds);
  [ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md)
  (the directory id).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes
  ([long form](../changelog/v1.11.0.md#backup-dir-queues-upgrade)) and
  Changed ([long form](../changelog/v1.11.0.md#backup-dir-queues)).

## The problem

ADR 0040 pins every backup step after `start` to the backup directory its
`start` wrote to, and routes it by a snooze: the step sits in the shared
`backup_steps` queue, any node may fetch it, and a node whose
`.kiln-dir-id` is not the chain's puts it back for 30 seconds, up to 20
times per attempt. On a cluster with a `BACKUP_DIR` per host, that makes
where a step runs a matter of which node fetches first. With three nodes,
two of them are wrong for every step; a host whose node is slow to fetch
can lose all twenty draws of an attempt and fail it with
`:backup_dir_elsewhere`, spending one of the four attempts with nothing
wrong. A resume's `start` and the last-good marker sync's per-directory jobs
have the same shape. The snooze budget exists to make the loop end, not
because waiting is what the step needs. #2845 asked for the job to go to a
node that has the files, with no snooze budget to spend.

Oban (the open-source edition Kiln uses) can't send a job to a node. It can
start a queue at runtime on one node (`Oban.start_queue/1` with
`local_only: true`), and only the nodes running a queue fetch from it.

## Decision

**A job pinned to a backup directory runs from that directory's queue,
`backup_dir_<dir_id>`.** `KilnCMS.Backups.DirQueues` names it from the id
(only a lowercase UUID, `KilnCMS.Backups.DirId.valid?/1`, makes a name).
Every node's heartbeat (`KilnCMS.Backups.Heartbeat`) starts the queue of the
directory it reports, on that node only, with limit 1. On a shared volume
every node reads the same id and runs the same queue, so any of them can
take a step, as before. With a directory per host, exactly the host that has
the files runs it. The pin is still to the directory, never the node, as
ADR 0040 decided.

**A node advertises its queue, and only an advertised queue is routed to.**
Each beat carries two new `backup_node_beats` columns: `dir_queue` (the
directory whose queue this node runs and has not paused) and
`dir_queue_boot_id` (the boot that wrote it). The heartbeat writes
`dir_queue` only after `Oban.check_queue/1` on this node shows the queue
running and unpaused, so it lands one or two 30-second ticks after a new
directory's first id read. `DirQueues.routable?/1` routes a job into the
queue only when a node with a beat under 180 seconds old reports that
directory as its `dir_id`, advertises its queue, and wrote the
advertisement in its current boot. Beats that can't be read are a no.
Everything else stays in `backup_steps` (or `default` for a marker sync) on
ADR 0040's bounded snooze:

- a node from before #2845, which never writes the columns (a rolling
  deploy, or a rollback);
- a queue whose start or resume hasn't taken, because those are signals
  through Oban's Postgres notifier and the notifier is down. After three
  ticks the heartbeat logs one warning and emits `:start_failed`;
- no node with the directory at all (the lost-directory fallback for a
  resume of a copied directory).

**Routing happens on insert and on fetch.** `Chain.advance/3` reads the
beats before it takes the lock and inserts the next step straight into the
queue when it is routable. Every `start`, and a step taken back from a
stopped node, goes into `backup_steps`. A node that fetches a pinned job
from the shared queue and lacks the directory moves it to the routable
queue in place (`DirQueues.move/2`: an `UPDATE` of the job's `queue`, same
id), then returns `{:snooze, 0}`, which spends no attempt. A node whose id
changed after it started a queue and that fetches a job there falls back to
the snooze budget. Both workers' uniqueness is over `[:args, :worker]`, not
Oban's default which includes the queue, so a moved job still counts.

**A queue is paused, never stopped.** Stopping a queue orphans its running
job once Oban's shutdown grace period ends. The heartbeat pauses another
directory's queue at once when the id read succeeds with a different id,
and after 180 seconds of reads with no id (a hung or missing directory); it
resumes the queue when the id comes back. Each tick pauses again any queue
it paused that is running (a pause signal lost while the notifier was down,
or a later `Oban.resume_all_queues(Oban)`). It resumes only a queue it paused
itself: one paused by anything else (an operator, the demo reset's
`Oban.pause_all_queues(Oban)`) is left paused and not
advertised. A queue the heartbeat finds paused when it starts is counted as
paused by someone else.

**A job left in a queue no node runs is swept.** `Chain.sweep_stranded/0`
runs in the lock's `:reclaim_stale` action on every heartbeat tick and
before every backup request, and `MarkerSyncWorker.sweep_stranded/0` after
it on each tick. For a job that has waited in a directory queue
(`scheduled_at` on the database's clock):

1. a live node reports the directory but none advertises its queue, for 5
   minutes: a backup step is moved back to `backup_steps` (same id,
   available now), where it snoozes as before; a marker sync is canceled;
2. no live node reports the directory, for 30 minutes: a pinned step is
   interrupted (its job canceled, the lock released, the waiting request
   promoted, the run failed with "Interrupted: no server with its backup
   directory (id `<id>`) picked up the `<step>` step for 30 minutes"); a
   resume's `start` is moved back to `backup_steps`, where the
   lost-directory fallback decides; a marker sync is canceled;
3. otherwise it is left: a node runs the queue, or will.

"Reports" counts a beat's `dir_id` or its `last_dir_id`, as #2817's
resume rule does, so a node whose id read is held up by a hung mount still
counts as having the directory. A job that is not the lock's (its backup
moved on) is canceled in either of the first two cases.

**Cancel finds a step in any queue.** `Chain.cancel_chain_jobs/1` selects
`StepWorker` jobs by worker and `args @> {"chain": …}`, no longer by
`queue = 'backup_steps'`.

`config :kiln_cms, KilnCMS.Backups, dir_queues?: false` turns routing and
the queues off; it defaults to the heartbeat's switch.

## Rejected

- **A queue per node** (`backup_node_<name>`, or `Oban.start_queue/1` with
  `node:`). Node names change on a redeploy, so a job queued for the old
  name would never run, and on a shared volume it would refuse the other
  nodes that see the same files. ADR 0040 rejected pinning to a node for
  the same reasons.
- **An adaptive snooze** (shorter, or a budget scaled by how many nodes
  report the id). It makes the loss less likely, not gone, and the issue
  asked for no snooze budget at all.
- **Oban Pro**, whose job-level node targeting would do this directly. Kiln
  runs the open-source edition (`config :ash_oban, pro?: false`).
- **A shutdown hook that moves a node's directory-queue jobs back to
  `backup_steps`.** It can't run on a crash or a kill, which is when it would
  matter, and a rollback through a crashed node would still strand the job.
  The documented rule, cancel or let a backup finish before rolling back,
  covers it.
- **Stranded by time alone** (any job 30 minutes in a directory queue).
  A job rescued by Oban's Lifeline keeps its old `scheduled_at`, and a
  long step ahead of it in the queue can hold it there; neither means the
  directory is gone. A pinned step is interrupted only when no node has
  reported its directory for 180 seconds as well.
- **Starting a queue through Oban's private API** (`Oban.Queues`), to
  get a synchronous start without the notifier. It is not public and can
  change in any Oban release. The notifier is a signal Kiln can check
  (`Oban.check_queue/1`) and fall back from.
- **Stopping a queue** when its directory goes, on the first tick without an
  id, or when it looks idle. A stopped queue's running job is orphaned once
  Oban's shutdown grace period ends; a paused queue finishes its running job
  and costs nothing.
- **Inserting a resume's `start` straight into a directory queue.** It is
  inserted inside the lock transaction, and reading the beats there would
  hold the lock for the read. The fetch-time move routes it instead.
- **Cancel and reinsert instead of moving the job.** The move keeps the
  job's id, which the lock records as its `step_job_id`, and costs no
  attempt; a reinsert would give the step a new job the lock has to be
  pointed at.

## Consequences

- With a `BACKUP_DIR` per host, a step is inserted into its host's queue, or
  moved there by the first other node to fetch it, and spends no attempt
  getting there. The "about an hour" ADR 0040 gives a backup whose
  host has gone is now at least 30 minutes of that host's absence, then a
  failure that says why, and the lock is released.
- **Rollback.** A release from before #2845 never runs `backup_dir_*`
  queues. A step parked in one when the deployment rolls back never runs,
  and its backup holds the lock until a platform admin cancels it (that
  release's reclaim and reap need an executing or ended job). The documented
  rule is to cancel running backups, or let them finish, before rolling
  back past this release. A job left in such a queue stays in `oban_jobs`
  until a later release clears it.
- **Mixed versions.** An old node never advertises, so its directory's jobs
  keep the snooze. An old node restarted under a new node's name has a new
  boot id, so the advertisement the new node left is ignored. An old node's
  Cancel filters on `backup_steps` and misses a step in a directory queue:
  a waiting one cancels itself as superseded when it runs, or the sweep
  cancels it; an executing one stops at its next fenced call
  (ADR 0039). The docs say to finish a rolling deploy before acting on
  backups.
- **The notifier.** Starting, pausing and resuming a queue are signals
  through Oban's Postgres notifier (`LISTEN`/`NOTIFY`). Where it doesn't
  work, nothing is advertised and every job keeps the snooze, with one
  warning per queue.
- **A heartbeat restart keeps its pauses (#3095).** The queues a heartbeat
  paused are recorded in a node-local ETS table owned by
  `KilnCMS.Backups.DirQueues.Paused`, a process started before the
  heartbeat. A restarted heartbeat counts a paused queue in that table as
  its own, so it resumes it when the id comes back; any other paused queue
  is still someone else's. The table goes when the node restarts, as Oban's
  runtime queues do. (Before #3095 such a queue stayed paused until Oban
  restarted on that node, and its jobs ran from `backup_steps` after the
  5-minute move-back.)
- **Pool size.** Each node runs one more queue at limit 1 (its paused queues
  fetch nothing).
- **Shared limit.** `StepWorker` and `MarkerSyncWorker` share a directory's
  queue at limit 1, so a marker sync can wait behind a long step.
- **A schema change.** Two nullable `uuid` columns on `backup_node_beats`,
  expand-only; the staging scrub already purges the table.

## When to revisit

- If Oban's open-source edition gains node targeting for a job, the queues
  and the advertisement can go; the directory id would still name the
  target.
- If the marker sync waiting behind a long step matters (a missed slot is
  retried at the next one), give the marker sync its own per-directory
  queue.
- If a lost pause after a heartbeat crash is seen in practice, record the
  heartbeat's own pauses somewhere that outlives it (the beat row) rather
  than counting every pause found at start as someone else's.
- If 30 minutes proves too short for a host that is rebooting, or too long
  for a lock other backups wait behind, change `DirQueues.stranded_after_s/0`.
