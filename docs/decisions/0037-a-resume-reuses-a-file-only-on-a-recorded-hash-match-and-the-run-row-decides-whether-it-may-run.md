# 0037. A resume reuses a file only on a recorded hash match, and the Run row decides whether it may run

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2418 in 1.9.0. Resume was file-based and started by hand when it shipped;
  the step chain that followed in the same release (#2537) made
  `.work/<stamp>/state.json` also the way one step hands its results to the
  next (`KilnCMS.Backups.WorkState`, version 2). That changed how the file is
  written, not what this record decides.
- **References** — [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424)
  (this record), [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  and the owner's decision 7 on it of 2026-11-09 (a part changed between
  archive and checksum fails the run, and Resume rebuilds it),
  [#2418](https://github.com/The-Verscienta/kiln_cms/pull/2418),
  [#2537](https://github.com/The-Verscienta/kiln_cms/pull/2537),
  [#2421](https://github.com/The-Verscienta/kiln_cms/issues/2421) (two resumes
  of one stale run);
  [ADR 0034](0034-media-backups-are-split-by-file-set-into-independent-archives-not-by-bytes.md)
  for the parts a resume keeps.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-media-parts), and
  [the step chain](../changelog/v1.9.0.md#backup-step-chain).

## The problem

A backup of a large library can fail hours in, after a verified database dump
and most of its media parts are on disk. Starting again from nothing throws
that away, and a library too big to finish in one attempt never finishes.
Keeping finished work raises two questions:

- **Which files may a resume keep?** A file with a final name was verified
  when it was renamed into place, but anything that writes to the backup
  directory may have changed it since, or put a file with that name there.
- **Which backups may be resumed at all?** The work directory
  (`<BACKUP_DIR>/.work/<stamp>/`) is on disk, so it can outlive the run that
  wrote it, survive a run that has since succeeded, or be written by something
  other than Kiln.

## Decision

- **A recorded hash is the only license to reuse a file.** The dump and each
  media part are recorded in `state.json` with their name, size and SHA-256 as
  each verifies (`WorkState.put_dump/2`, `WorkState.put_part/2`). A resume
  reuses one only when that entry exists *and* the file still matches it now:
  `KilnCMS.Backups.Checksum.recheck/3` re-reads it and requires a regular file
  (a symlink is rebuilt, never followed), the recorded size and the recorded
  digest, the same check the off-site copy makes. The name compared is rebuilt
  from the stamp and the frozen plan, never taken from the state file. A
  final-named file with no entry, or with a different digest, is rebuilt
  (`reuse_dump` and `reuse_part` in `KilnCMS.Backups.Steps`).
- **The partition does not move under a resume.** The media plan
  (`plan.json` and its lists) is frozen when first written, and a resume loads
  it (`KilnCMS.Backups.MediaArchive.load_plan/2`). If the plan is gone, the
  recorded parts mean nothing: they are forgotten (`WorkState.clear_parts/1`)
  and the stamp's media files removed before a new plan is made.
- **The Run row, not the work directory, decides whether a resume may run.**
  `KilnCMS.Backups.resumable_run/3` checks, in order: the stamp's shape (before
  any path is built), that no chain holds it, that a Run exists for it, that
  the Run is resumable (`Backups.run_resumable?/2`: an in-app run that failed,
  was canceled, or is `running` but stale), that a Cancel has had time to
  settle, and only then that `state.json` exists. A work directory is required,
  because it is what the resume builds on, but its presence or contents never
  grant a resume. The request path and the resume's start step both run the
  check, and the Run's `:resume` action, which only the `:backups` system actor
  may call, re-checks it in its UPDATE's WHERE
  (`KilnCMS.Backups.Run.Changes.Resume`), so two callers holding one stale run
  cannot both re-open it.
- **A resume never becomes a fresh backup.** Every refusal is an error with its
  reason; nothing falls back to starting over under a new stamp.

## Rejected

- **Reuse a file because it has a final name.** The rename proves it verified
  once, not that it is unchanged. Owner decision 7 makes a changed part fatal
  precisely so that the operator looks, and the resume then rebuilds that part.
- **Trust the recorded digest without re-reading the file.** Cheaper, but a
  changed file would be carried forward on a record that no longer describes
  it: a media part would fail the run again at the checksum step
  (`MediaArchive.checksum/3`), and a dump, whose sidecar is rewritten from the
  record, would be caught only by the off-site re-check, and only when a
  remote is set.
- **Compare size and mtime instead of the hash.** A copy that preserves mtimes,
  or corruption in place, passes both.
- **Let `state.json` say whether a resume is allowed.** It is a file in a
  directory other processes can write; it would re-open a stamp whose run
  succeeded, and it has no row lock, so it cannot stop two resumes of one run.
  The Run row is behind policy and gives the UPDATE something to guard.
- **Fall back to a fresh backup when a resume is refused.** It would quietly do
  something other than what was asked, under a stamp nobody chose.
- **Re-plan on resume.** New uploads would be picked up, but every recorded
  part would belong to a partition that no longer exists.

## Consequences

- A resumed set can mix times: some parts from the first attempt, some from
  the resume. The Run's log says which parts were reused.
- A resume reads every reused file once more. Because finished parts are kept,
  a library too large for one attempt converges over repeated resumes.
- Only in-app runs can be resumed. `scripts/backup.sh` removes an unfinished
  set, and an imported cron run is not resumable.
- The work directory is swept three days after its last write, and with it
  the chance to resume.

## When to revisit

- Re-hashing reused files becomes a large share of a resume's time.
- Cron runs need a resume of their own.
- Backups are resumed from files that exist only off-site.
