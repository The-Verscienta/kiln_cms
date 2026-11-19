# 0039. A backup step's node is judged by a heartbeat on the database clock, and a superseded step is fenced

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) in 1.9.0; the heartbeat's stop of a canceled step
  (#2538) came after it. Amended 2026-11-17 by
  [#2818](https://github.com/The-Verscienta/kiln_cms/issues/2818) and
  [#2819](https://github.com/The-Verscienta/kiln_cms/issues/2819) (a step's
  files are written outside the lock and only their rename is fenced; see
  "Amendment" and
  [ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md)),
  and by [#2848](https://github.com/The-Verscienta/kiln_cms/issues/2848) (the
  self-fence runs in a watchdog apart from the heartbeat's tick; see
  "Amendment (2026-11-17, #2848)").
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
- If the self-fence stops live steps on nodes whose heartbeat round is only
  slow (a sweep or prune that takes about a minute; see the #2848
  amendment), the 90 seconds, or what a round may do before it beats, needs
  revisiting, again below the 180-second reclaim.

## Amendment (2026-11-17, #2818, #2819): a step's files are its own and only their rename is fenced

Two Consequences above no longer hold, and the Decision's last point is
narrowed. The reasoning is in
[ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md).

- **"A step's own `.partial` files are not fenced."** They are now. Every
  file a step writes goes to a temporary name tagged with its job and attempt
  (`<name>.<job>-<attempt>.partial`, `Artifact.partial_name/2`), and is
  renamed into place by `Chain.fenced_rename/3`, only while the lease holds.
  A superseded step's rename is refused. The 150-second wait after a Cancel
  stays. *Since #3041* (ADR 0067's second amendment) the prune step and each
  off-site upload a step starts are fenced too; the wait is left for an
  upload already under way when the lease is lost.
- **"The fenced `state.json` write holds the cluster-wide advisory lock while
  it writes the file."** The contents of `state.json`, of the failure and
  finish manifests and of every other file are now written outside the lock;
  only the rename runs inside it. A delete is a fenced rename into a trash
  directory, followed by the delete after the lock is released. Renames, the
  moves into the trash and the finish step's marker sync are still
  file-system calls in the lock transaction, so a backup directory that
  stalls between a step's write and its rename still makes Cancel, new
  requests and the sweep wait until their query times out.
- **"The step's `state.json` write goes through `while_holding/2`."** It goes
  through `fenced_rename/3`, which is `while_holding/2` around the rename
  alone.

The fence itself (chain, epoch and job id) is unchanged. So, until #3040,
was its gap: a later attempt of the same job, an Oban retry or a Lifeline
rescue, held the same lease as an earlier attempt still running, and the
renames of both were admitted. *Since #3040* the lease is also the attempt
that last claimed the lock (`executing_job_id`, `executing_attempt`), so the
earlier attempt is superseded once the later one claims; see
[ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md),
"Amendment (#3040, #3041)". Every other rule above is unchanged.

## Amendment (2026-11-17, #2848): the self-fence runs in a watchdog, and fires on no successful beat

The Decision's third point ("A node that cannot beat stops its own steps
first") had the heartbeat's tick do the kill. The tick also does file I/O on
`BACKUP_DIR`: since #2789 it reads, and may create, `.kiln-dir-id` on every
beat, and its sweep cleans up after interrupted runs. On a hard-mounted NFS
export that hangs, that I/O blocks the tick, and a fence inside the tick
never runs, while the other nodes still reclaim the step at 180 seconds. Two
nodes could then write the same backup.

- **The kill is done by `KilnCMS.Backups.Fence`**, a process apart from the
  heartbeat that does no file or database I/O. Every 5 seconds it compares
  the time of the last successful beat (each one is cast to it) with
  `Heartbeat.fence_after_ms/0` (90 seconds), and when it is reached kills
  every process in `KilnCMS.Backups.StepRegistry`. It starts with the
  heartbeat (`heartbeat?: true`) and not without it. The tick still fences
  too, when it gets that far.
- **It fires on no successful beat for 90 seconds, not only on failed
  beats.** A tick that is stuck, or only slow, counts the same as one whose
  beat the database refused. So a heartbeat round (beat, canceled-step stop,
  sweep, prune) that, with the 30-second pause after it, keeps the next beat
  from succeeding within 90 seconds stops this node's steps. That is the
  budget a round now has: about a minute. Stopping a live step that way only
  interrupts it; letting it run on beside a reclaim could cost the backup.
- **A restarted watchdog counts from its own start.** It keeps the last beat
  in its own state, so after a crash it waits up to another 90 seconds (plus
  one 5-second check) before it can fire. A tick that still runs fences on
  its own count meanwhile; only a stuck one goes unfenced for that time. A
  restarted watchdog has no record of the beats before it, and firing at once
  would stop the steps of a healthy node.
- **The id read can no longer block the beat.** It runs in a task under
  `KilnCMS.Backups.DirIdReaders` (at most four at a time), waited on for 5
  seconds (`dir_id_timeout_ms`). While it is held up the beat reports no id,
  so the last-good marker sync stops routing to that node; no second read
  starts until the first ends. Since #2817 each beat also carries
  `last_dir_id`, the id the last answered read gave, kept through a held-up,
  crashed or busy read and cleared by one that finds no id file. A resume's
  start reads it, so a stuck read on the source host doesn't let a copy of
  its directory resume elsewhere
  ([ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md),
  "Amendment (2026-11-17, #2817)"). The marker sync still routes by `dir_id`
  only. A restarted heartbeat takes `last_dir_id` from its own beat row when
  that row beat within 180 seconds (#3091).
- **The sweep's cleanup can no longer block the beat (#3078).** A reclaim
  with no attempts left, a reap or the stranded-step sweep fails the run in
  the caller, right after its commit, with no `BACKUP_DIR` I/O. What is left
  (the failure manifest, a re-send's work directory, and all of an
  interrupted finish, whose verdict needs its files) runs in a task under
  `KilnCMS.Backups.InterruptTasks`, handed over by a cast to
  `KilnCMS.Backups.Interrupts` that the tick never waits on; so does a
  backup request's, which sweeps first. One task runs at a time, so a hung
  directory holds one blocked process; up to 20 more wait in order, and one
  past that is dropped with a line in the log (an error for a finish, whose
  run then waits for the stale-run check). The task's writes are fenced by
  the lock as the release left it (`Chain.released_fenced/3`): the failure
  manifest is renamed into place, and a work directory moved into the trash,
  under the lock and only while it is free at the release's epoch, or held at
  that epoch by the backup the release promoted, before its start step has
  run; the manifest is also skipped when it already names a later stamp
  (read before the lock is taken). A late finish record whose manifest names
  a later stamp can't decide the finish's verdict and leaves its run for the
  stale-run check. On the node with the backup's `state.json`, the task adds
  what that file holds to the failed run (`Run :record_interrupted`, system
  only, own chain, `failed` runs only). While a task has run for over a
  minute the node's heartbeat skips the lock sweep; another node's heartbeat
  or any backup request still sweeps, and on a shared mount hung for every
  node only requests do. The lock's release, the requeue and the promotion
  stay in the sweep's transaction.

The thresholds (90 and 180 seconds) and the reclaim are unchanged. Every
other rule above is unchanged.
