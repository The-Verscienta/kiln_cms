# 0068. A resumable backup upload is recorded by the installation that started it, and only it aborts it

- **Status** — accepted (2026-11-17).
- **References** — [#2223](https://github.com/The-Verscienta/kiln_cms/issues/2223)
  (resumable uploads; this record covers its first part, the seam in the
  core and the SDK) and the owner's decisions recorded on
  [#2221](https://github.com/The-Verscienta/kiln_cms/issues/2221)
  (2026-11-17): abort only on a permanent failure or a changed file, keep
  an upload for resume on a transient failure or a timeout, sweep only
  recorded uploads after four days, run the sweep even with retention off;
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md)
  (the lease and the fence);
  [ADR 0043](0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md)
  (a refusal is fatal);
  [ADR 0063](0063-each-backup-destination-is-its-own-step-and-a-run-that-reaches-only-some-is-partly-off-site.md)
  (each destination is its own step);
  [ADR 0064](0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)
  (retention deletes only what this installation sent);
  [ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md)
  (the off-site uploads were left unfenced).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes and Added
  ([long form](../changelog/v1.11.0.md#resumable-backup-uploads)).

## The problem

Each destination is its own off-site step (ADR 0063), with four attempts and
two hours per attempt. A store's multipart upload of a multi-gigabyte media
part can be cut off by any of: the step's deadline, a dropped connection, a
deploy that kills the node, Oban's Lifeline rescuing the job, or a reclaim
that fences the step (ADR 0039). Before this record every attempt started
the file over, so a file that takes longer than one attempt never arrived.

Resuming needs the store upload's state (its id, the parts acknowledged) to
outlive the attempt, and it raises three questions that a quick answer gets
wrong:

- **Who may continue an upload.** A step that lost its lease may still be
  running on a node that missed the signal. If it records progress after the
  step that took over did, the next resume trusts parts that belong to the
  other step's upload, and the file on the store is corrupt.
- **Who may abort one.** An aborted upload can't be resumed, and an
  unaborted one costs storage on the store until something removes it. A
  bucket can be shared by installations (ADR 0064), and a store will list
  every pending upload under a prefix, whoever started it.
- **What a file the store already holds means.** A retry after a put that
  finished but whose outcome was lost finds the file there. ADR 0064's
  retention deletes only what this installation recorded sending.

## Decision

**The installation that started an upload records it, in its own
database.** `KilnCMS.Backups.Upload` (table `backup_uploads`) holds one row
per file and destination: the destination's
`KilnCMS.Backups.Destination.target_key/2` (its id plus a fingerprint of
where it writes, the key `state.json`'s `"sent"` map already uses), the
file's subdir, name, stamp, size and SHA-256, the adapter's checkpoint, and
a status (`open`, `abandoned`, `completed`, `aborted`). At most one row per
file and destination is open (a partial unique identity). The checkpoint is
the adapter's opaque state, JSON of at most 8 KiB, never a secret. A row is
written on the adapter's first `save` (`Kiln.BackupDestination.Resume`), and
the SDK asks the adapter to save right after it creates the store upload,
before sending data, so an upload that could cost storage is recorded before
it can.

**Ownership is the step's Oban job id and attempt, and it only moves
forward.** `owner_job_id` and `owner_attempt` are integers. `claim` takes a
row only for a step at least as new as its owner (a later job, or the same
job at an attempt no smaller), as a filter on the update itself, not a read
followed by a write. `save_checkpoint`, `note_error` and `complete` write
only for the exact owner while the row is open; `abandon` and
`mark_aborted` only from the status and owner the caller read. A write that
matches no row is a `StaleRecord`, which `KilnCMS.Backups.Uploads` returns
to the adapter's `save` as `{:error, :superseded}`. The adapter stops. It
aborts a store upload only when nothing recorded it (its first `save`
failed); one already recorded is left for its newer owner, who may resume
it, or for the sweep (#3041). Oban job ids grow, and a
job's attempts grow, so a retry, a Lifeline rescue and a reclaim's new job
each outrank the step they replace, and the replaced step can never write
again.

**A checkpoint is handed back only for the same file.** `Uploads.handle/3`
compares the open row's size and SHA-256 with the file about to be sent. A
file that changed (a resume rebuilt it) abandons and aborts the old upload
and starts over. The adapter is still asked to confirm with the store what
a checkpoint claims.

**Only this installation aborts, and only what it recorded.** Kiln calls
`abort_upload/3` for a recorded upload when:

- the put failed permanently (`{:error, {:permanent, message}}`);
- the file changed since the upload started;
- the put answered `{:ok, :already_present}` while a checkpointed upload of
  that file was open;
- the sweep finds it `abandoned`, or `open` and untouched for four days.

A transient failure or a timeout keeps the row open, with its error, for the
next attempt. An abort first marks the row `abandoned`, so an abort that
fails is the sweep's to retry. The sweep (`Uploads.sweep/4`) runs each time a
backup reaches a destination, whatever that destination's `prune`, takes
only that destination's key, at most 50 rows per pass within the step's
deadline, and skips the stamp the backup lock holds. Four days is longer
than a backup's retries, reclaims and the three-day work-directory sweep.
Closed rows, and a deleted destination's rows, are purged after 30 days.
Nothing ever lists the store's pending uploads to abort them.

**A file the destination already holds, with the same size and SHA-256, is
recorded as sent, and so becomes retention's to delete.** `put/3` may answer
`{:ok, :already_present}`; the step records the file `ok` under the
destination's key exactly as if it had sent it, and its log says so. By ADR
0064 that record is what licenses retention to delete the file later. That
is deliberate: the name carries this backup's stamp and the content its
verified SHA-256, so the file on the store *is* this backup's file, however
it got there (most often an earlier attempt that finished but whose outcome
was lost). The adapter must vouch for the content, not the name: Kiln's
Local destination compares the size and then hashes the target, and the SDK
forbids answering it on a name alone. A sidecar found present is logged but
not recorded, as a sent sidecar never is.

**A permanent failure fails the destination at once.** `{:error,
{:permanent, message}}` ends that destination's attempt and fails it
whatever attempt this is, and the chain moves on to the next destination.
A refusal (ADR 0043) is unchanged and still fails the whole backup.

## Rejected

- **The checkpoint in `state.json`, the Run, or the work directory.** Those
  are written by the step and fenced by file rename (ADR 0067); a
  per-part progress write there would take the lock on every part, and the
  sweep must find uploads of backups whose work directory is gone.
- **A row per attempt.** The next attempt couldn't find the previous one's
  upload without guessing; one row per file and destination, with an owner
  that moves forward, is what makes resume and fencing the same mechanism.
- **An owner tag compared as text** (`"<job>-<attempt>"`, as ADR 0067's file
  names use). Text compares `"10-1"` below `"9-1"`; ownership must compare
  integers.
- **Aborting on every failure.** It throws away exactly the progress resume
  exists to keep; a timeout or a dropped connection is the common case.
- **Aborting every pending upload the store lists.** In a shared bucket it
  aborts another installation's live uploads, the same harm ADR 0064 avoids
  for files. Operators set the store's own lifecycle rule for what Kiln
  never recorded.
- **Trusting the checkpoint alone.** A checkpoint says what the adapter
  saved, not what the store kept; the adapter checks.
- **Treating `{:ok, :already_present}` as "skipped, not ours".** The file
  would then stay on the destination forever, outside retention, for a
  backup this installation made. Same stamp and same SHA-256 is the same
  backup.
- **Concurrent parts within one put.** Out of scope for the seam; an adapter
  may do it, as long as it saves only parts the store acknowledged.

## Consequences

- An upload of a file larger than one attempt can carry can now arrive,
  across attempts, retries, a Lifeline rescue or a reclaim.
- Kiln can leave store uploads it never recorded: one cut off before its
  first save, one on a destination that was deleted (its rows are purged,
  not aborted), one whose row a database restore lost, another
  installation's. Operators of an S3-style destination need a lifecycle
  rule for incomplete multipart uploads.
- A destination that keeps failing is never swept, because the sweep runs
  only after a backup reaches it; its abandoned uploads wait until it works
  again or the store's lifecycle rule removes them.
- A Local destination reads a target of the right size whole to hash it
  before deciding not to copy, so a resend costs a read instead of a write.
- An adapter that declares `:resume` without `abort_upload/3` is treated as
  not resumable, and `mix kiln.plugins.doctor` says so.

## When to revisit

- If a store can report who started a pending upload, the sweep could
  abort unrecorded uploads of this installation too.
- If a destination's deletion should free its unfinished uploads, the
  delete would have to call the adapter before the row goes.
- If the lease gains a per-attempt epoch (ADR 0067's last "When to
  revisit"), ownership could use it instead of the Oban job and attempt.
