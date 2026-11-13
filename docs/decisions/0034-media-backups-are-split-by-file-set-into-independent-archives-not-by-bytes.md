# 0034. Media backups are split by file set into independent archives, not by bytes

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2418 in 1.9.0. `scripts/backup.sh` adopted the same split in #2476, in the
  same release.
- **References** — [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424)
  (this record), [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218)
  and the owner's decision 1 on it of 2026-11-08 (`backup.sh` splits by
  default, like the app),
  [#2418](https://github.com/The-Verscienta/kiln_cms/pull/2418),
  [#2476](https://github.com/The-Verscienta/kiln_cms/pull/2476);
  [ADR 0035](0035-the-per-stamp-sidecar-not-the-manifest-is-the-only-restore-time-checksum-authority.md)
  for how a set's parts are checked at restore,
  [ADR 0037](0037-a-resume-reuses-a-file-only-on-a-recorded-hash-match-and-the-run-row-decides-whether-it-may-run.md)
  for how a failed set is resumed part by part.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-media-parts), with the
  upgrade notes [for the app](../changelog/v1.9.0.md#backup-media-parts-upgrade)
  and [for `backup.sh`](../changelog/v1.9.0.md#backup-sh-media-parts-upgrade).

## The problem

Media used to be one `tar.gz` of the whole media directory. On a large library
that is one multi-gigabyte file to write, list, hash, upload and, after any
failure, rebuild from nothing. A run that dies near the end has nothing to keep,
and an off-site store that limits the size of one upload cannot take it.

Cutting the backup into pieces answers that only if each piece is useful on its
own: something that can be listed and hashed when it is written, copied
off-site alone, kept by a resume, and restored without the others.

## Decision

- **The file set is split, not the byte stream.**
  `KilnCMS.Backups.MediaArchive.plan/3` walks the media directory in a fixed
  order (names sorted, subdirectories taken in sorted order) and assigns every regular file
  and symlink to exactly one part, writing a null-separated list per part. Each
  part is then an ordinary `tar.gz` of its own list
  (`MediaArchive.archive_part/4`, `tar -czf … --null -C <media_dir> -T <list>`),
  so the parts are disjoint and each is a complete, valid archive.
- **The cap is a ceiling on a part's uncompressed input, not an exact size.**
  A part closes when the next file would push the sum of its input sizes past
  `KilnCMS.Backups.media_part_bytes/0`. A file larger than the cap is never cut:
  it becomes a part of its own, flagged `oversize`. An empty or fully excluded
  tree is still one (empty) part, so a set always has a member.
- **400 MB by default, 16 to 10240 MB accepted** (`BACKUP_MEDIA_PART_MB`, read
  by `KilnCMS.Config.Env.integer_in/3` in `config/runtime/prod/backups.exs`, and
  the same way by `read_media_part_bytes` in `scripts/backup.sh`). Below 16 MB a
  part is not worth its sidecar line and manifest entry; past 10240 MB (10 GB)
  is more than a single request to most off-site stores survives. A value
  outside the range is refused, not clamped: the default stays and a warning is
  logged (a boot warning in the app, a `warning:` line from `backup.sh`),
  because `4` is not obviously a request for `16`. There is no setting that
  turns splitting off.
- **Names say how many parts there are.** A set that needs one part keeps the
  legacy `kiln-media-<stamp>.tar.gz`; two or more are
  `kiln-media-<stamp>.partNN.tar.gz`, two digits widening past 99
  (`KilnCMS.Backups.Artifact.set_names/2`; `Artifact.parse_file/1` refuses a
  padded `part0001`, so a part has one name).
- **Both backup paths split the same way.** `scripts/backup.sh` re-implements
  the planner (walk order, exclusion globs, part assignment, names, `tar`
  flags), so cron and the app produce sets that one `restore.sh` and one
  importer read.

## Rejected

- **Byte-splitting one stream (`tar -cz … | split -b`).** The pieces are not
  archives: none can be listed or verified alone, a restore needs every piece
  concatenated in order, and one damaged piece loses everything after it in the
  stream. A resume could not keep a finished piece: the stream would have to be
  produced again from its start to reach the next one.
- **GNU tar multi-volume archives (`--multi-volume`).** GNU only (`backup.sh`
  and the app must also work with bsdtar), and it cannot be combined with
  compression.
- **Keeping one archive.** The status quo, with every problem above.
- **Exact part sizes, or cutting a large file across parts.** An exact size
  needs a byte split; a file cut across parts is a file no single part can
  restore. A part over the cap is the price of keeping every file whole.
- **Clamping an out-of-range part size.** Clamping is interpreting a typo; the
  default plus a warning is visible and harmless.

## Consequences

- Directories are not archived, only the files in them: **empty directories and
  directory modes, owners and timestamps are not preserved**, and a restore
  creates directories as it extracts into them. `backup.sh` archives lost them
  in the same change.
- A set is several files that belong together. Retention deletes a set whole,
  aged by its newest file; off-site copies each part and the sidecar; the
  importer groups the parts into one History artifact and marks a set with a
  gap failed ("incomplete media set"); `restore.sh media` requires parts
  `01..N` with no gap or duplicate. Scripts outside Kiln that glob
  `kiln-media-*.tar.gz` still match the parts but not the sidecar.
- The plan is frozen when it is written (`plan.json`), so a resume archives the
  same partition; a file uploaded after planning is in the next backup.

## When to revisit

- Off-site stores that need parts larger than 10 GB, or smaller than 16 MB.
- Media that needs directory metadata or empty directories restored.
- A media library that lives only in object storage (the S3 adapter has no
  media directory to split), if that becomes the only supported layout.
