# 0042. `backup.sh` re-implements the media planner in bash, and both change in the same pull request

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2476 in 1.9.0.
- **References** — [#2480](https://github.com/The-Verscienta/kiln_cms/issues/2480);
  [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218) and the
  owner's decision 1 on it of 2026-11-08 (cron splits media by default, like
  the app); [#2476](https://github.com/The-Verscienta/kiln_cms/pull/2476),
  PR (a) of #2218, which made the choice;
  [ADR 0043](0043-a-file-that-changed-before-its-off-site-copy-is-refused-and-only-a-resume-rebuilds-it.md)
  for the off-site check the two paths also share.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-sh-media-parts-upgrade)
  (Upgrade notes: `scripts/backup.sh media` and `all` split media into parts
  like the app).

## The problem

Two programs write Kiln's backups into the same `BACKUP_DIR`: the app's
in-app pipeline (`KilnCMS.Backups.Steps`) and the cron script
`scripts/backup.sh`. Everything that reads a backup reads both: `restore.sh`,
`backup.sh verify`, the History importer (`KilnCMS.Backups.Importer`) and the
Backups page. So they must write one format, not two.

Since #2418 the app writes media as a set of independent `tar.gz` parts
(`KilnCMS.Backups.MediaArchive`). The owner decided that cron splits the same
way, by default. That leaves the question of **how the script gets the app's
plan**: which files go in which part, in what order, under which names. The
planner is Elixir. Cron, however, is the backup that still has to run when the
app cannot boot: a broken deploy, a bad runtime configuration, a host that has
`pg_dump` and `tar` but no release.

## Decision

- **The script carries its own copy of the planner, in bash.** The media
  section of `scripts/backup.sh` (`walk_media`, `walk_dir`, `glob_to_ere`,
  `read_media_excludes`, `size_media`, `assign_parts`, `archive_part`) mirrors
  `MediaArchive.plan/3` and `MediaArchive.archive_part/4`. It needs nothing
  from the release, only bash 3.2 or later, GNU tar or bsdtar, `stat`,
  `xargs`, `gzip` and a sha256 tool.
- **The parity contract.** Given the same media directory and the same
  settings, the two must agree on all of these:
  - **Walk order.** Pre-order: within a directory, its regular files and
    symlinks in byte order, then its subdirectories in byte order (Elixir's
    `Enum.sort/1` on binaries; the script globs under `LC_ALL=C` with
    `dotglob`, so dotfiles are included). Symlinks are members and are never
    followed, a symlink to a directory included. Sockets and devices are
    skipped. Directories are not members, so empty directories and directory
    modes are not kept. An entry that vanished since its directory was listed
    is skipped.
  - **Exclusion globs.** `BACKUP_MEDIA_EXCLUDE` is split on commas. Each piece
    is trimmed of what `String.trim/1` trims (the script's `trim_ws` strips the
    same ASCII and Unicode whitespace, U+00A0 and U+3000 included), and blank
    pieces are dropped. A pattern that contains `/` is matched against the path
    relative to the media directory; any other is matched against the entry's
    own name, at any depth. A leading `./` is dropped (after that test), `**/`
    matches any number of whole directories, `**` crosses segments, `*` stays
    within one segment, `?` is one byte, and everything else is literal,
    byte for byte. A matching directory is skipped whole. A pattern ending in
    `/` (`cache/`) contains a `/` and is matched against relative paths, which
    never end in `/`, so it excludes nothing on either path. Exclusions are
    applied by the planner, never by `tar`.
  - **The cap rule.** `BACKUP_MEDIA_PART_MB` is read as
    `KilnCMS.Config.Env.integer_in/3` reads it, 16 to 10240: trimmed, an
    optional `+` and leading zeros allowed; anything else keeps 400 and warns,
    and it is never clamped. A file's size is its `lstat` apparent size. A file
    strictly larger than the cap is a part of its own. Otherwise a part closes
    when the next file would push its input total past the cap. A tree with
    nothing to archive is one part holding a valid empty tarball, written
    directly because GNU tar refuses to create an empty archive.
  - **Archiving.** `tar -czf <part>.partial --null -C <media dir> -T <list>`,
    the only list flags GNU tar and bsdtar share. A part counts only if tar
    exited 0 and `tar -tzf` lists it. Anything else removes the `.partial` and
    tries once more from a re-filtered list, with vanished files dropped and
    counted.
  - **Names.** A single part keeps the legacy `kiln-media-<stamp>.tar.gz`. Two
    or more are `kiln-media-<stamp>.partNN.tar.gz`, two digits, widening past
    99 (`KilnCMS.Backups.Artifact.set_names/2`; the script's `%02d`).
  - **Sidecar.** One `kiln-media-<stamp>.sha256` per set, mode 0600, with one
    `<sha256>  <name>` line per part in part order (`Checksum.write_sidecar/2`;
    the script's `write_sidecar`).
  - **Manifest.** One flat `manifest.json` entry per part, with `kind`,
    `path`, `bytes`, `verified`, `sha256`, `part` and `parts_total`, under
    `"version": 1`.
- **Cleanup is the one deliberate difference.** The app keeps a failed run's
  finished parts and its `.work/<stamp>/` so that Resume can reuse them. Cron
  has no resume: a failed run, or one ended by `HUP`, `INT` or `TERM`, removes
  the parts it wrote, by the paths it tracked and never by a glob, and keeps a
  finished database dump. A `kiln-media-<stamp>.sha256.partial` marker covers
  a run killed outright. The set's whole-set SHA-256 (all parts concatenated)
  is also the app's alone; the script records only the per-part digests.
- **Both change in the same pull request.** A change to how `MediaArchive`
  walks, excludes, sizes, splits, archives or names, or to the sidecar or the
  manifest's part keys it shares with the script, updates `scripts/backup.sh`
  and `test/scripts/backup_script_test.exs` in the same pull request. The
  `MediaArchive` moduledoc says so, and so does the script's header. The
  parity tests run the real script and the app's `MediaArchive.plan/3` on one
  tree and compare part membership and order ("the parts hold the same files,
  in the same order, as the app's planner"), the exclusion matrix
  ("`BACKUP_MEDIA_EXCLUDE` matches exactly what the app's planner excludes",
  thirteen pattern sets), the oversize and exactly-at-the-cap cases,
  thirteen `BACKUP_MEDIA_PART_MB` inputs, and the names, sidecar and manifest
  entries of an eleven-part run.

## Rejected

- **`tar | split -b`.** The pieces of one byte-split gzip stream are not
  archives. None of them can be listed, verified, restored or rebuilt on its
  own, and a restore needs every piece. It would also be a second format next
  to the app's parts, with a second restore procedure.
- **GNU tar multi-volume archives** (`--multi-volume`). GNU tar only, where the
  script also supports bsdtar (macOS); GNU tar cannot compress a multi-volume
  archive; and a file can span two volumes, so a volume is not a complete
  archive either.
- **Calling the release** (`bin/kiln_cms eval` or `rpc` into
  `MediaArchive.plan/3`). One implementation, but cron would then need a
  release on its host and a configuration that boots, which is exactly what
  is missing on the day cron is the backup that matters.
- **`tar --exclude`.** GNU tar and bsdtar match exclude patterns differently
  (whether a wildcard crosses `/`, what a pattern is anchored to), so one
  `BACKUP_MEDIA_EXCLUDE` would leave out different files under each tool and
  under the app. Excluding in tar also comes too late: the parts are sized
  before tar runs, so the cap would count files that are never archived.
- **`find` ordering.** `find` returns entries in the filesystem's directory
  order, which is not sorted and differs between filesystems. Sorting its
  output sorts whole paths, which puts `a/b/x` before the file `a/c`, where
  the app's walk lists a directory's files before its subdirectories. Either
  way the parts would hold different files from the app's.

## Consequences

- Every change to the media planner is made twice, once in Elixir and once in
  bash, and is reviewed against the parity tests rather than by reading the
  two side by side.
- Planning a large library in shell is slower than in the app, and grows with
  the number of files.
- Parity is as good as the tests and the platforms they run on: macOS (bash
  3.2 and bsdtar) locally, GNU tar and bash 5 in CI. No CI job runs bash 3.2.
- Known divergence today: a media directory that can be listed but not
  entered (read permission without execute) stops a cron run with
  `cannot list`, where the app counts its entries as unreadable names, warns
  and continues.

## When to revisit

- If the planner can run outside a booted release, for example as a
  standalone executable built from `MediaArchive`, the script could call it
  and this record would be superseded.
- If cron backups are dropped in favor of the app's own schedules only, the
  script's planner goes with them.
- If the parity tests start needing exceptions for one path, the two have
  stopped being one format, and that is the problem to fix first.
