# 0040. A backup chain runs where its backup directory is, routed by `.kiln-dir-id` with a bounded snooze

- **Status** — accepted (2026-11-13). Records the choice that shipped with the
  backup step chain (#2537) in 1.9.0; a resume's routing (#2539) and the
  marker sync's use of the same id (#2554, #2789) came after it.
- **References** — [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  (owner decision 1 of 2026-11-09, in its comments; PR #2537),
  [#2539](https://github.com/The-Verscienta/kiln_cms/issues/2539),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  for the heartbeat that carries each node's id.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-step-chain) (Added:
  "Several hosts", #2218), and the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md) (#2539, #2789).

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
- **A resume's `start` runs where the run's files are (#2539)**: on a node
  that has `.work/<stamp>/state.json` itself, or whose id is the one the run
  records (`KilnCMS.Backups.Run`'s `dir_id`). Local files win over the
  recorded id. When the last attempt has spent its snoozes too, the resume is
  given up (`Chain.abandon_start/2`): the lock is released and the run's row
  says why. A run with no recorded id runs anywhere.

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
  (`rsync --exclude .kiln-dir-id`). A resume follows the files, not the id, so
  a copied `.work/<stamp>/` still resumes.
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
