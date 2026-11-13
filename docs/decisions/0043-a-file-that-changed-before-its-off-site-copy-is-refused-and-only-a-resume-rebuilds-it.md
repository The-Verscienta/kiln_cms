# 0043. A file that changed before its off-site copy is refused, and only a Resume rebuilds it

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2481 in 1.9.0.
- **References** — [#2480](https://github.com/The-Verscienta/kiln_cms/issues/2480)
  (the owner's comment adding this record);
  [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218) and the
  owner's decisions on it of 2026-11-08 (decision 2: refuse a mismatch and
  fail the run, loudly, with no rebuild; decision 3: a failed off-site copy
  fails the run) and of 2026-11-09 (decision 7: a part that changed between
  archive and checksum is fatal, and Resume rebuilds it);
  [#2481](https://github.com/The-Verscienta/kiln_cms/pull/2481), PR (b) of
  #2218, which made the choice;
  [ADR 0042](0042-backup-sh-re-implements-the-media-planner-in-bash-and-both-change-in-the-same-pull-request.md)
  for why the cron script implements the same check on its own.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-offsite-rehash-upgrade)
  (Upgrade notes: every file is re-hashed right before its off-site copy).

## The problem

A backup writes each file once, verifies it (`pg_restore --list` for a dump,
`tar -tzf` for a media part) and records its SHA-256. The off-site copy
(`rclone copy`, when `BACKUP_RCLONE_REMOTE` is set) comes later, sometimes
much later: a large media set uploads one part after another. In between,
something else can write to `BACKUP_DIR`: a failing disk, a second cron
entry or host, a sync job pointed the wrong way, a person. The file that
leaves the host would then not be the file the backup verified, and the
remote copy, the one kept for the day the host is gone, would be the one
nobody checked.

Two questions follow. How is a changed file caught before it is uploaded?
And once it is caught, what does the backup do about it?

## Decision

- **Each file is re-hashed immediately before its own copy.** In the app,
  `KilnCMS.Backups.Steps` (`offsite_results/2`) checks every file just before
  the `rclone copy` of that file: the dump and every media part with
  `KilnCMS.Backups.Checksum.recheck/3` (still a regular file, read with
  `lstat` so a swapped-in symlink is not followed, the same size, the same
  SHA-256, compared in constant time), and each stamp's sidecar with
  `Checksum.check_sidecar/2` (its parsed lines equal the names and digests
  recorded for that stamp, in order). `scripts/backup.sh` does the same in
  `offsite`, hashing every file, the sidecars included, byte for byte.
- **A file that fails the check is refused.** It is not uploaded, not retried
  and not rebuilt in that run, and the run fails. A file with no digest on
  record is refused the same way, since nothing can vouch for it; so is a
  missing file or one that is no longer a regular file. A changed backup file
  means something other than the backup wrote to the backup directory, and
  that is the operator's to look at, not the backup's to paper over.
- **The app checks the rest; cron stops.** The app goes on checking and
  copying every other file, then fails the run naming every refused and every
  failed file (`Steps.describe_offsite/2`). A refusal is fatal to the step
  (`offsite_chain_step`), so `StepWorker` does not retry it, where a copy
  that rclone failed is retried with the step. The refused file is marked
  unverified on the Run (`Recorder.put_unverified/2`) and in the failure
  manifest, which records `"offsite": null`. `backup.sh` stops at the first
  refusal, under the `set -e` model it already had: `refuse_offsite` flips
  that file's manifest entry to `"verified": false` and exits with
  `REFUSING off-site copy of <name>: …`.
- **Only a deliberate Resume rebuilds.** The app keeps every local file and
  `.work/<stamp>/` after a refusal. A platform admin's **Resume** reruns the
  chain: a file that still matches `state.json` (checked with the same
  `Checksum.recheck/3`) is reused, and only one that changed, or was replaced
  by a non-regular file, is rebuilt. A rebuilt dump is a fresh `pg_dump`,
  taken at resume time. Cron has no resume: its set is kept, and the next run
  is a new stamp.

## Rejected

- **Re-hash everything up front, then upload.** It leaves the whole upload
  window open: a part changed while an earlier part uploads goes out
  unchecked. That is the race the check exists for, and the tests reproduce
  it in the app and in cron (an rclone stub that appends to part 2 while it
  copies part 1). When #2481 was built, a version that hashed up front failed
  five of them.
- **Compare size and modification time instead of hashing.** Cheaper, but a
  change that keeps the size (a flipped byte, an in-place rewrite) passes, and
  a modification time can be set back. The size is still compared, as well as
  the digest. The cost of the hash is one extra sequential read of each file,
  only when a remote is set, much faster than the upload it precedes.
- **Stream the file through a hash into `rclone rcat`.** The bytes hashed
  would be the bytes sent, but the digest is known only once they have been
  sent, so a mismatch could be reported but not refused. rclone also cannot
  retry an upload from standard input, and the run counts on rclone's own
  `--retries` and on `rclone copy` skipping a file the remote already holds
  unchanged, which is what keeps a Resume's second copy cheap.
- **Upload, then verify the remote copy.** It finds a bad file after it is
  already off-site, and it depends on the remote reporting a SHA-256, which
  many object stores do not (an S3 ETag is not one, and a multipart ETag is
  not even an MD5), or on downloading the file again.
- **Retry or rebuild a mismatch in the same run.** It hides the evidence:
  whatever changed the file is still there, and an automatic rebuild
  overwrites what the operator would want to inspect. A rebuilt dump would be
  a later `pg_dump` than the rest of the backup, without anyone having
  decided that. The owner's decision 2 on #2218 is "no rebuild"; decision 7
  applies the same rule to a part that changed between archive and checksum.

## Consequences

- A refusal turns a backup red, and an operator has to look before the next
  Resume (in the app) or the next run (cron) produces a clean off-site copy.
  `docs/backups.md`, "When an off-site copy is refused", says what to check,
  and to copy a suspect file aside first: a Resume replaces it.
- The check narrows the window to the moment between one file's re-hash and
  rclone reading it. It does not close it.
- The app and cron leave different things on the remote after a refusal:
  everything except the refused (and failed) files from the app, and only
  the files copied before the refusal from cron. In both, a part set missing
  a part on the remote is not restorable from there.
- The app compares a sidecar's parsed lines, cron its bytes. A change the
  parser ignores (a blank line, one space instead of two, `sha256sum`'s `*`
  marker) is refused by cron and not by the app.

## When to revisit

- If off-site copies move to a store that reports a SHA-256 for every
  object, verifying the remote afterwards becomes cheap enough to add, as a
  second check rather than a replacement for this one.
- If refusals turn out to have a benign, recurring cause, that cause is the
  thing to fix; rebuilding automatically would still hide the next one that
  is not benign.
