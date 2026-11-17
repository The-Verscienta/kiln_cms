# 0040. A backup chain runs where its backup directory is, routed by `.kiln-dir-id` with a bounded snooze

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) in 1.9.0; a resume's routing (#2539) and the
  marker sync's use of the same id (#2554, #2789) came after it. Amended
  2026-11-17 by [#2817](https://github.com/The-Verscienta/kiln_cms/issues/2817)
  (a copy of a run's files resumes only once the source host stops beating;
  see "Amendment (2026-11-17, #2817)").
- **References** — [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  (owner decision 1 of 2026-11-09, in its comments; PR #2537),
  [#2539](https://github.com/The-Verscienta/kiln_cms/issues/2539),
  [#2817](https://github.com/The-Verscienta/kiln_cms/issues/2817) (owner
  decision of 2026-11-17, in its comments),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  for the heartbeat that carries each node's id.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-step-chain) (Added:
  "Several hosts", #2218), and the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md) (#2539, #2789, #2817).

## The problem

A backup's steps hand over through files: `.work/<stamp>/state.json`, the
dump, the media parts, all in one `BACKUP_DIR`. Each step is its own Oban job,
and Oban gives a job to whichever node fetches it from the queue. On a cluster
whose nodes mount one shared volume that is fine. On a cluster where each host
has its own `BACKUP_DIR`, a step fetched by the wrong node finds no
`state.json`, or worse, starts writing a second half of the backup somewhere
else.

The node is not the right thing to pin to. A node restarts under a new name
or boot; several nodes on one shared volume are, for the backup, one place.
What a step needs is the directory.

## Decision

- **Each backup directory carries a random id**, in
  `<BACKUP_DIR>/.kiln-dir-id` (`KilnCMS.Backups.DirId`, mode 0600). The first
  in-app backup there creates it (`DirId.local/1`), or each node's heartbeat
  does once the directory holds backups and the last-good marker sync is on
  (`DirId.ensure_existing/1`, #2789). It is written to a temporary file,
  synced and hard-linked into place, so no reader sees it empty and two nodes
  racing on a shared volume settle on the first link; a filesystem without
  hard links gets an exclusive create instead.
- **A fresh backup's `start` runs anywhere, and binds the chain at its
  hand-over.** `Chain.begin_step/1` gives the `start` step this node's id;
  the chain's `dir_id` is written to the lock row only when `start` hands
  over to `dump` (`Chain.advance/3`, the Lock's `:move`), once `state.json` is
  in that directory. A `start` that failed before then and is retried on
  another host writes there and binds that directory instead, so a chain's
  files are never split.
- **Every later step carries the id and runs only where it matches.**
  `KilnCMS.Backups.StepWorker` compares the step's `dir` with
  `DirId.current/0`. On a mismatch, or a node with no id, it snoozes for 30
  seconds, which costs no attempt, up to 20 times per attempt (about ten
  minutes, counted from `meta["affinity_base"]`), then fails the attempt with
  `:backup_dir_elsewhere`, and the step's four attempts and their backoff
  take over.
- **A resume's `start` runs where the run's files are (#2539)**: on the node
  whose id is the one the run records (`KilnCMS.Backups.Run`'s `dir_id`), or
  on a node that has `.work/<stamp>/state.json` itself while no live node
  reports that id (#2817; see the amendment). When the last attempt has spent
  its snoozes too, the resume is given up (`Chain.abandon_start/2`): the lock
  is released and the run's row says why. A run with no recorded id runs
  anywhere.

## Rejected

- **Require one shared `BACKUP_DIR`, or a single node, and refuse in-app
  backups otherwise.** The alternative put to the owner on #2218. A cluster
  with a volume per host is an ordinary deployment, and it would have lost
  in-app backups for no fault of the backup.
- **Pin a chain to a node** (its Oban node name or hostname). A node that
  restarts or is replaced would strand its chain, and on a shared volume it
  would refuse nodes that see the same files.
- **Fail the attempt on the first wrong node.** With every node fetching from
  one queue, a few wrong fetches are normal on a cluster of more than one
  host. A snooze puts the job back without spending one of its four attempts.
- **Snooze without a bound.** A chain whose host is gone would hold the lock,
  and every backup queued behind it, for good. Twenty snoozes per attempt,
  across four attempts and their backoff, ends it in about an hour.

## Consequences

- With a `BACKUP_DIR` per host, a backup whose host goes away fails after its
  attempts run out, about an hour, holding the lock meanwhile. A queued backup
  then starts, on whichever host its `start` lands.
- A copied backup directory carries its id, and two directories with one id
  look like one. The copy needs `.kiln-dir-id` deleted or left out
  (`rsync --exclude .kiln-dir-id`). A copied `.work/<stamp>/` resumes only
  once the host it came from has stopped beating (#2817; see the amendment).
- A node whose `BACKUP_DIR` cannot hold an id (read-only, or a file there
  that is not an id) runs no step: its `start` fails the attempt when it
  cannot create the id, and every later step snoozes there.
- The id is also how the last-good marker sync reaches each host's directory
  (`KilnCMS.Backups.MarkerSyncWorker`, #2554), with the same snooze budget.

## When to revisit

- If Oban Pro, or a per-host queue name, makes it possible to send a job to a
  node directly, the snooze loop can go; the id would still name the
  directory.
- If deployments with a volume per host turn out to lose backups to the
  one-hour give-up, a shorter budget, or one that adapts to how many nodes
  report the id, is worth having.

## Amendment (2026-11-17, #2817): a copy resumes only once the source host stops beating

The Decision's last point let local files win over the recorded id: a node
holding `.work/<stamp>/state.json` took a resume's `start` whatever the run
recorded. A copy of the source host's backup directory, made while the run was
there and with `.kiln-dir-id` left out (the practice this ADR recommends),
then resumed beside a source host that was still running, and both directories
went on to hold the same backup. The issue first proposed letting the files
win only when the copied `state.json`'s own `dir_id` matched the run's. That
clause doesn't catch the case: `state.json` records the directory of the
start that wrote it, which is always the run's, copy or not.

- **The run's recorded directory comes first.** `KilnCMS.Backups.StepWorker`
  runs the `start` on a node whose `DirId.current/0` is the run's `dir_id`,
  files or not; the start step there refuses visibly (`:no_state`) when
  `.work/<stamp>/state.json` is gone.
- **A local copy wins only when no live node reports the recorded id.** Live
  is a beat within `Chain.stale_after_s/0` (180 seconds, on the database's
  clock), read through `Backups.dir_id_live?/2`. A node counts as reporting
  the id through its beat's `dir_id` or its `last_dir_id`, the id its last
  answered read gave, which a held-up, crashed or busy read leaves in place.
  Without it, a source host whose read is stuck on a hung mount (its `dir_id`
  goes nil, see ADR 0039's #2848 amendment) would look gone. A copy that
  resumes records its own directory as the run's `dir_id`, as any resume
  does.
- **It fails closed.** Heartbeats that can't be read count as a live source:
  the start snoozes and logs a warning. A run that can't be read makes a node
  with a copy snooze too (the attempt fails with `:run_unreadable` when its
  snoozes run out); a node with no copy starts and refuses visibly on the
  missing files. A `state.json` that can't be parsed (`Backups.local_resume_state?/1`)
  counts as no copy. The heartbeats are read only on a node with a copy.
- **180 seconds, not the marker sync's 600.** The question is whether the
  source host may still write its copy of the backup. The lock answers it at
  180 seconds, when it takes a stopped node's step back; the marker sync's
  longer window asks where a queued sync might still be picked up.

Rejected: keeping the files-first rule and documenting the gap; and comparing
`state.json`'s `chain` with the run's `chain_id`, which catches a copy taken
before a later resume but not one taken mid-run of a run never resumed.

Consequences: on a live source host whose `.work/<stamp>/` was moved away,
the resume is now refused there instead of running from the copy. A copy
resumes once the source host has been silent for 180 seconds; to use it
sooner, stop the app on the source host. A restarted source host whose first
id read hangs reports neither id, so a copy can resume beside it. During a
rolling deploy, a node on an older release keeps the files-first rule. A
deployment with one shared volume, where every node reads the same id, is
unaffected. Every other rule above is unchanged.
