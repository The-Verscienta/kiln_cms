# 0071. A partly off-site backup is completed by a re-send that holds the backup lock and never changes the run's status

- **Status** — accepted (2026-11-18). Amends
  [ADR 0063](0063-each-backup-destination-is-its-own-step-and-a-run-that-reaches-only-some-is-partly-off-site.md),
  whose partly off-site run could only be followed by a new backup.
- **References** — [#2949](https://github.com/The-Verscienta/kiln_cms/issues/2949)
  and the owner's decisions recorded on it (2026-11-18): the lock's advisory
  transaction dedupes two clicks (O1); a re-send is refused, not queued,
  while the lock is held (O2); the "unreadable" entry expands to the stored
  destinations enabled now (O3); a file that changed is refused, the
  artifact marked unverified and the file left in place (O4); a removed or
  disabled destination is skipped (O5); the `:backups` system actor may ask
  (O8); any partial run whose files are present (O9); the request is not
  audited, the Cancel is (O10); refused while `BACKUP_ENABLED=false` (O11).
  [ADR 0043](0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md)
  (each file re-hashed right before its own copy);
  [ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md)
  (a step's deletes are fenced trash moves);
  [ADR 0070](0070-a-directory-pinned-backup-job-runs-from-a-queue-named-for-its-directory-which-the-nodes-reporting-it-start.md)
  (directory queues).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Added and Upgrade notes, #2949.

## The problem

A backup that reaches some of its destinations and not others succeeds,
partly off-site (ADR 0063). Until #2949 the only way to get the missing
copies was the next backup: Resume is for a run that failed, and a
succeeded run's work directory is gone. A destination that was down for a
night therefore missed that night's backup for good, even after it was
fixed, and the alarm stayed up until a whole new backup reached every
destination.

Sending the run's files again looks like a small job, but it touches
everything the step chain guards:

1. **Retention.** A copy that runs beside a backup's prune, or beside
   `backup.sh prune` on the host, can have its files deleted under it.
2. **Fencing.** A copy that outlives its Cancel, or a node that lost the
   database, must not keep writing the run or a destination.
3. **The run's outcome.** The run succeeded; nothing a re-send does may turn
   it into a failure, write a failure manifest over a good one, or rebuild
   a file that was verified once.
4. **Mixed releases.** A node of the previous release reads the lock row,
   reaps and reclaims, and interrupts chains it finds; it must never take a
   re-send for a backup.

## Decision

**A re-send is a third kind of holder of the backup lock**, beside a backup
and a resume. `Lock :hold_resend` takes a free lock with step `:resend`,
part 1, the run's own stamp and backup directory, and trigger `"resend"`;
each further destination is the usual `:move` to the next part. One
`StepWorker` job per target destination, in that directory's queue, so the
re-send is fenced, reclaimed, reaped and routed exactly as a backup's steps
are. There is no start step. While it holds the lock, a backup request
queues behind it as behind any backup, and another re-send is refused
(`:busy`, or `:in_flight` for the same stamp): never queued (O2), so the
lock's single waiting slot keeps meaning "a backup".

**It never changes the run's status.** `Run :begin_resend` moves the run to
the re-send's chain, `Run :record_resend` writes only the artifacts'
per-file outcomes, the log, the destination entries and the
`offsite_status` they add up to, and only on a run that is still
`succeeded` under that chain. Nothing in the re-send's path calls the
backup's `fail`, writes a failure manifest or runs the Importer: a step
that can go no further *stops* the re-send.

**The order of its first step is fixed.** Part 1 makes `.work/<stamp>`
before anything else, so retention (the app's and `backup.sh`'s) treats
the stamp as in flight; discards what an earlier re-send left there with a
fenced trash move (ADR 0067); reads the run; checks its lease; and begins
the run at once from that read, its UPDATE pinned to the read's
`updated_at`. A Cancel that commits before the check stops the step there;
one that commits between the check and the begin makes the begin match
nothing. Only then does it `lstat` the files: one that is gone stops the
re-send as "local files missing", said on the run.

**A re-send's `state.json` names its chain under `"resend_chain"`, never
`"chain"`.** Every place that writes a failure manifest, in this release
and the previous one, matches on `"chain"`: a re-send's state never
matches, so no node can write a failure manifest for it, whatever path
reaches it (a reaped job, a reclaimed step, an older node's step that
finds the state and calls it lost). This release also routes an
interrupted re-send to its own "Re-send stopped" path.

**A file that changed is refused, and the backup says so (O4).** Each file
is re-hashed immediately before each copy (ADR 0043). One that no longer
matches is not sent; the re-send stops; that destination is recorded
failed ("REFUSED"); the artifact is marked unverified on the run, and in
`manifest.json` too when the manifest is still this run's, written under
the lease, as `backup.sh`'s `refuse_offsite` does. The file is left where
it is, under its own name: it is the backup's only copy and nothing will
rebuild it, so it is not set aside as a backup's refused file is (#2484).
The marker sync runs at the end, so an unverified backup stops counting as
the last good one. A file that is **gone** is not that: it says nothing of
whether the backup verified, so it stops the re-send as "local files
missing" and leaves `verified` alone.

**Cancel is its own action.** `Run :cancel_resend`, a platform admin's,
takes the advisory lock, refuses unless the lock holds a re-send of this
stamp that is not finishing, cancels its jobs, releases the lock and
clears the run's `chain_id`, so a step that outlives it can't write. The
run's log says "Re-send canceled by a platform admin", naming nobody
(#3029); the instance security log's `backup_canceled` event does, with
`"resend" => true` (O10). A new re-send of the run waits out the settle
window counted from that log line, as a Resume does from a Cancel. The
run's plain `:cancel` is refused while a re-send runs, and a re-send marks
itself finishing before its last Run write, from where its Cancel is
refused.

## Rejected

- **A standalone worker without the lock.** It races the backup's prune and
  retention on the destinations, and has no fencing.
- **A standalone worker that takes the lock.** It would duplicate reclaim,
  reap, routing and Cancel, which the chain already has.
- **Reusing Resume, or the backup's `offsite` and `finish` steps.** Their
  failure path writes a failure manifest and closes the run, and finish
  rewrites the manifest: all three are what a re-send must never do.
- **Queuing a re-send behind a running backup.** The lock has one waiting
  slot, which holds a backup's request; a second kind there needs a
  migration and folding rules. Refusing costs one more click.
- **Hashing every file once, up front.** ADR 0043's rule is per copy: a
  file that changes while one destination is sent to is refused at the
  next.
- **Flipping the target entries to pending first.** A canceled or
  interrupted re-send would then leave "pending" entries on a finished run,
  which read as never tried. The entries stay failed until reached.

## Consequences

- A re-send changes the run's `chain_id` to its own. Nothing reads a
  succeeded run's chain except the re-send's own writes.
- A run older than a destination's retention is sent there anyway; that
  destination's next retention pass may delete it again. The Re-send
  confirmation says so when the destination prunes.
- The `:resend` step value is new on the lock row. The column has no check
  constraint, so no migration. A node of the previous release loads the
  row only because the atom happens to exist in its VM, which nothing here
  relies on, and its step code knows no `resend` step. Hence the upgrade note: finish a rolling deploy before you re-send,
  and cancel a running re-send before you roll back. Even if one is
  missed, the `"resend_chain"` key keeps an older node from writing a
  failure manifest or changing the run.
- A canceled re-send leaves `.work/<stamp>` until the next re-send of the
  run clears it or the work-directory sweep removes it after three days.
  Until then retention keeps the run's files, as it does for any stamp with
  a work directory.

## When to revisit

If re-sends become routine (a destination that is often down), queue them
behind a running backup, with their own waiting slot and a migration, and
consider re-sending automatically when a destination's Test passes again.
