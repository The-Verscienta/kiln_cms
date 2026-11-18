# 0067. A backup step's temporary files are its own, and only their rename is fenced

- **Status** — accepted (2026-11-17). Amended 2026-11-17 by
  [#2832](https://github.com/The-Verscienta/kiln_cms/issues/2832) (every
  manifest writer has a temporary name of its own; see "Amendment"), and
  2026-11-18 by [#3040](https://github.com/The-Verscienta/kiln_cms/issues/3040)
  and [#3041](https://github.com/The-Verscienta/kiln_cms/issues/3041) (the
  lease is per attempt; the prune step and the off-site uploads are fenced;
  see "Amendment (#3040, #3041)").
- **References** — [#2818](https://github.com/The-Verscienta/kiln_cms/issues/2818)
  (no file write inside the lock transaction),
  [#2819](https://github.com/The-Verscienta/kiln_cms/issues/2819) (a step
  that outlives its Cancel can still write its `.partial` files), both
  follow-ups of [#2538](https://github.com/The-Verscienta/kiln_cms/issues/2538);
  [ADR 0039](0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md),
  amended by this record;
  [ADR 0045](0045-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md)
  for the Run writes, which this leaves as they were.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Upgrade notes and Fixed
  ([long form](../changelog/v1.11.0.md#backup-step-files-fenced)).

## The problem

A backup step is fenced by its lease (ADR 0039): chain, epoch and job id. A
step that outlived its Cancel or its take-back, on a node that missed the
signal, must not change what the step that took over has written. Before this
record two things fell short of that.

- **The fence held the lock while it wrote.** `state.json` was written inside
  `Chain.while_holding/2`, which runs in the transaction holding the
  cluster-wide `pg_advisory_xact_lock`. On a backup directory that stalls (a
  hung NFS mount), the write blocked in the kernel and Cancel, new requests
  and every node's heartbeat sweep waited behind it until their query timed
  out. Cancel could not stop the stuck backup. The failure manifest was
  written the same way.
- **The step's own files were not fenced at all.** The dump and each media
  part were written to fixed names (`kiln-db-<stamp>.dump.partial`,
  `<part>.partial`, `partNN.run.list`) and renamed into place unconditionally.
  A resume of the same stamp writes the same names, so a step that outlived
  its Cancel could write into the resume's temporary file, or rename its own
  file over the resume's verified one. Only the 150-second wait after a
  Cancel kept them apart, and a heartbeat hung on a half-open connection can
  stretch past it.

## Decision

- **A step's temporary files are its own.** Every file a step writes goes to
  `<name>.<job>-<attempt>.partial` (`KilnCMS.Backups.Artifact.partial_name/2`,
  `Artifact.tag/2`): the dump, each media part and its `partNN.<tag>.run.list`,
  the checksum sidecars, `state.json`, `plan.json` and its
  `partNN.<tag>.list` lists, and `manifest.json`. No two writers share a
  temporary name, so the one that lost the lock can remove its own on any
  error without touching anyone else's. The attempt keeps a retried job's
  files apart from a late write of the attempt before it.
- **The contents are written outside the lock.** A step writes, verifies
  (`pg_restore --list`, `tar -tzf`), sets the mode and hashes its file under
  that name with no lock held.
- **Only the rename is fenced.** The rename into place is
  `Chain.fenced_rename/3`: a `while_holding/2` around one `File.rename/2`.
  A superseded step's rename is refused with `{:error, :superseded}`, the
  step removes its temporary file and cancels itself. The rename is the last
  thing a writer does, so a refused or failed one leaves the file under the
  final name as it was.
- **A delete is a fenced rename too.** A step that must delete something of
  the chain's (a leftover work directory at a fresh start, an earlier plan's
  media files, the work directory at the finish, a dump whose sidecar failed)
  moves it, in one fenced transaction, into a trash entry on its own file
  system (`.work/.trash/`, `db/.kiln-trash/`, `media/.kiln-trash/`) and
  deletes the entry after the lock is released. The start step clears what a
  crash left there. A rename that fails with `:exdev` deletes that path in
  place, under the lock: the one delete left inside it.
- **Every reader accepts both shapes.** `Artifact.parse_file/1` and
  `parse_sidecar_name/1`, and through them retention, the importer and
  History, report a tagged name as `partial?: true`, as they do an untagged
  one. `scripts/backup.sh` keeps writing the untagged `<name>.partial` for
  its dump, parts and sidecars, and its prune and verify, and `restore.sh`,
  match either. *Amended (#2832):* its manifest is the exception,
  `manifest.json.<pid>-<random>.partial`, and so is a manifest the app writes
  without a step, `manifest.json.<random digits>.partial`; see "Amendment".
- **The start step reads the directory id before the lock.**
  `Chain.begin_step/1` reads `.kiln-dir-id` (`DirId.current/1`) first. Only
  the first start on a directory with no id creates one, inside the lock and
  only once the job is known to be current.

**What this does not do.** The rule met is "no file *content* is written
under the lock". A rename, a move into the trash and the finish step's
marker sync (#3013) are still file-system calls inside the lock transaction,
and can still hang on a stalled mount. The window shrinks from "every state
write" to "the mount stalls between the write and the rename"; a stalled
directory can still hold Cancel back.

## Rejected

- **Per-chain temporary names** (`<name>.<chain>.partial`, the option on
  #2819). Two attempts of one job are one chain, so a timed-out attempt's
  late write and its retry would still share a name. Job and attempt are
  finer, and are what the step already has.
- **Random or UUID tags.** Nothing could tell from the name which job left
  it, and the tag regex could not be narrow enough for `backup.sh`'s prune to
  match it safely.
- **Check the lease, then rename outside the lock.** The lease can be lost
  between the check and the rename; the rename must run while the lock is
  held.
- **Keep writing the contents inside the lock.** That is the stall #2818
  is about.
- **Hash after the rename.** The final file is then briefly unverified under
  its real name, and a superseded step would hash a file that may be the
  resume's.
- **`O_EXCL` temporary files, or `flock`.** Neither fences against a step
  whose lease is gone, and `flock` is unreliable on the network file systems
  this is for.
- **Tag the files `backup.sh` writes.** Cron takes no lock and has no lease;
  a tag would fence nothing.
- **Drop the 150-second wait after a Cancel.** An off-site upload already
  under way when the lease is lost (an `rclone copy`, a single-request S3
  upload, a plugin's `put/3`) can't be stopped by a lease check, and still
  relies on it (see "Amendment (#3040, #3041)").

## Consequences

- A step that outlived its Cancel can't replace or delete the backup's
  `state.json`, dump, media parts, sidecars, plan or manifest. Its refused
  rename leaves no temporary file behind.
- A media part or dump that fails on every attempt leaves a file already
  under its final name (from an earlier attempt) as it was, which can leave it
  without a matching sidecar until retention ages the stamp out. Nothing
  trusts it: a resume reuses a file only on a recorded hash match (ADR 0037).
- Operators see `.kiln-trash/` in `db/` and `media/`, and `.work/.trash/`;
  they are normally empty.
- An older node's readers and an older `backup.sh` don't parse tagged names.
  The host's `backup.sh` is updated in the same rollout; until then an app
  backup is still protected by its `.work/<stamp>/`.
- **Still not fenced:** an off-site upload already under way when the lease
  is lost (see "Amendment (#3040, #3041)"); `interrupt/4`'s failure manifest
  and `finished_from_outside/3`'s removal of the work directory, which run
  from the reclaim with no lease.

## When to revisit

- If a stalled mount holding Cancel back through a rename is seen in
  practice, the renames have to move out of the lock transaction too, which
  needs a fence that does not hold a transaction open across a file-system
  call.
- If an off-site upload can ever be committed under the lease (a store, or
  an rclone mode, that stages under a temporary name the step then renames),
  the 150-second wait after a Cancel can be revisited: nothing else in a
  step depends on it.
- If `backup.sh` ever takes the backup lock, its temporary files should be
  tagged and fenced the same way.

## Amendment (2026-11-17, #2832): every manifest writer has a temporary name of its own

`manifest.json` has more writers than a step: `scripts/backup.sh`, and
`Manifest.write/3` called without a lease, when a backup interrupted on
another node is recorded from outside its step (`interrupt/4`). Both wrote
through the untagged `manifest.json.partial`, so a cron run and an in-app
write finishing together could interleave in one file and publish a mix of
the two, or fail a rename the other had already done. Two of the Rejected
points above read as if they forbid the fix, and neither does.

- **"Random or UUID tags."** Rejected there as the tag of a *step's* files,
  where the name has to say which job left it. A write with no step has no
  job to name, so `Manifest.write/3` without a `:tag` now tags with a random
  positive integer (`manifest.json.<digits>.partial`; random rather than
  `System.unique_integer/1`, because the nodes of a cluster share the
  directory). Digits only, so the narrow tag regex the rejection protects,
  `\A\d+(?:-\d+)?\z` (`Artifact.tag?/1`), is unchanged, and `backup.sh
  prune` matches the same shape. Steps keep their `<job>-<attempt>` tags.
- **"Tag the files `backup.sh` writes."** Rejected there because a tag would
  fence nothing, and that still holds: cron takes no lock. `backup.sh` now
  tags one file, its manifest temporary, as
  `manifest.json.<pid>-<random>.partial` with the random half between 100000
  and 132767, above any attempt number, so it never takes a step's name. It
  creates the file exclusively and picks another number when the name is
  taken. The tag is for uniqueness, not fencing: the PID alone collides
  between containers that share `BACKUP_DIR`. Its dump, parts and sidecars
  keep the untagged `<name>.partial`.

A leftover manifest temporary file older than the partial grace (60 minutes)
is removed by the start step's sweep, and now by `backup.sh prune` as well,
whichever of the three writers left it. The untagged `manifest.json.partial`
of an older `backup.sh` is removed by neither: it may still be that script's
live file. The fence itself, and every other rule above, is unchanged.

## Amendment (2026-11-18, #3040, #3041): the lease is per attempt; prune and off-site are fenced

- **Per attempt (#3040).** `Chain.begin_step/1` already recorded the
  claiming attempt on the lock row (`executing_job_id`,
  `executing_attempt`); the lease check (`holds?`) now compares them too, so
  an earlier attempt of the same job (a retry after a timeout, a Lifeline
  rescue) is superseded once a later attempt has claimed, and an attempt
  older than the one that last claimed is refused at the claim. No column
  was added. Oban's attempt only rises from one execution of a job to the
  next: a snooze (an affinity wait, or a move to the directory's queue,
  #2845) takes back the attempt it was fetched with, so the job comes back
  with the same number and claims again. A lease without an attempt is
  judged by its job, as before.
- **Prune (#3041).** The prune step's marker sync runs under the lease
  (`Chain.while_holding/2`, as the finish step's does, #3013), and each unit
  is moved into the trash under it and deleted after, like every other
  delete here. A prune that lost its lease deletes nothing more and cancels
  itself.
- **Off-site (#3041).** The lease is checked before each file's upload,
  whatever the destination, a plugin's included (`Chain.check_lease/1`), and
  before the destination's upload sweep and retention. Kiln's own adapters
  get more, through options a plugin's adapter is never given: a Local
  destination copies under `<name>.<job>-<attempt>.partial` and renames into
  place with `Chain.fenced_rename/3`, the same rule as the backup's own
  files; an S3 destination checks the lease just before it completes a
  multipart upload. That check is outside the lock (ADR 0045), so a lease
  lost between it and the Complete is not caught.
- **What still is not fenced** is an upload already under way: an `rclone
  copy`, a single-request S3 upload, a plugin's `put/3`. It can land after a
  resume's copy of the same file, which matters only when the resume rebuilt
  that file. The 150-second wait after a Cancel stays for it.
