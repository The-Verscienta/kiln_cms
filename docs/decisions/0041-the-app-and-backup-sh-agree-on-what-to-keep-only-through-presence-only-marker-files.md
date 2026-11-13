# 0041. The app and `backup.sh` agree on what to keep only through presence-only marker files

- **Status** — accepted (2026-11-13). Records the contract as it stands after
  the last-good marker (#2552, part of #2219) in 1.9.0; the recovery point
  (`.keep`) came with retention by component (PR #2486) in the same release, and
  the scheduled marker sync for cron-only deployments (#2554, #2789) after it.
- **References** — [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219)
  (the owner's sign-off (b) of 2026-11-09: the newest verified backup is
  never deleted; PR #2552),
  [#2554](https://github.com/The-Verscienta/kiln_cms/issues/2554),
  [#2789](https://github.com/The-Verscienta/kiln_cms/issues/2789),
  [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424);
  [ADR 0040](0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md)
  for how the sync reaches each host's directory.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-last-good-marker-upgrade)
  (Upgrade: the last-good marker, part of #2219),
  [1.9.0](../changelog/v1.9.0.md#backup-retention-by-component) (Changed:
  retention by component and recovery points, PR #2486), and the Unreleased
  section of [CHANGELOG.md](../../CHANGELOG.md) (#2554, #2789).

## The problem

Two programs prune the same backup directory: the app's retention
(`KilnCMS.Backups.Retention`) and `scripts/backup.sh prune`, run by host
cron. They ship and upgrade separately. The app is a release image; the
script is a copy on the host that an operator replaced once and may not
replace again. Nothing on the host tells either one which version the other
is.

They must still keep the same backups:

- **A recovery point.** An operator pins one backup, say the last before a
  migration, and both prunes must keep it. It has to survive a database
  restore, so it cannot live in the database.
- **The newest verified backup.** The app never deletes it (rule 3 of
  retention), but "verified" is in the Run history, and `backup.sh prune`
  has no database. Before #2552 cron kept only the newest *complete* set, so
  when that set came from a failed run, cron deleted the older verified one
  once it passed `BACKUP_KEEP_DAYS`.

## Decision

The contract is two marker names in `db/` and `media/`, and nothing else:

- **`kiln-<stamp>.keep` is a recovery point and pins every component of its
  stamp.** One in either directory keeps the dump and the media of that
  stamp, in both prunes. The operator creates and deletes it; neither the app
  nor the script ever does.
- **`kiln-<stamp>.good` is the last-good marker and pins only its own
  component.** `db/kiln-<stamp>.good` keeps that dump and its sidecar from
  `backup.sh prune`, never the media of the same stamp, because retention's
  unit is one component of one stamp and the newest verified dump and media
  set can have different stamps. Only the app writes and moves it
  (`Retention.sync_last_good/2`): after each successful in-app backup, before
  an in-app prune deletes anything, and every 15 minutes from
  `KilnCMS.Backups.MarkerSyncWorker` for cron-made backups (#2554). The new
  marker is written before the old one is removed; only regular files are
  removed. `backup.sh` reads markers and writes none.
- **Markers are presence-only.** An entry of that exact name, of any kind
  (empty file, directory, symlink), counts; its contents are never read.
  `backup.sh` matches names in the directory listing, not a `stat`, so an
  entry it cannot stat still counts, and the app's sync treats any existing
  entry of the name as a marker already written. The names are strict:
  `Artifact.parse_keep_name/1` and `parse_good_name/1` want a full
  `YYYYMMDD-HHMMSS` stamp, as does the script. A marker-shaped name with a
  bad stamp pins nothing, and is never a stray in either prune.
- **The app never reads a `.good` as a keep rule.** Retention works out the
  newest verified unit from History every time (`Retention.plan/4`'s
  `last_good`), so the marker is the app's output, never its input: a stale
  marker pins nothing in the app, and its unit ages there like any other. The
  app reads `.good` only to move it and to show it on the Backups page
  (`KilnCMS.Backups.Markers`). The importer does not take a marker for an
  artifact.
- **Cron honors a new marker only once the host's script is upgraded.** The
  release that introduces a marker says so in its upgrade note; an older copy
  of `backup.sh` ignores `.good` and can still delete the newest verified
  backup.

## Rejected

- **Markers with contents** (the components they pin, a format version). A
  parser in bash 3.2 for each, and a malformed file to decide about. A name
  is enough, `touch` makes one, and an entry that can't be read still counts.
- **One `.good` per stamp, pinning both components** like `.keep`. The newest
  verified dump and the newest verified media set are often different stamps
  (a database-only or media-only backup, #2219), so a
  shared marker would either pin a unit that is not the newest verified of
  its kind or leave one unpinned.
- **Let `backup.sh prune` read the Run history.** The prune takes no
  database URL today, and it would tie the script to the app's schema, which
  is exactly what the two shipping separately cannot carry.
- **Have the app read `.good` back as a keep rule.** A marker the app could
  not remove (a directory of that name, a permission error), or an operator's
  copy, would then pin a unit in the app too, indefinitely, with History
  saying something else.
- **Keep the markers in the database.** A database restore would bring back
  old markers, or none, and on a cluster with a backup directory per host
  (ADR 0040) the database is shared while the files are not.
- **A version handshake between the app and the script.** Nothing in the
  script's prune talks to the app, and adding a channel for it would be a
  second contract. The upgrade note carries the requirement instead.

## Consequences

- A host still running an older `backup.sh` keeps only the newest complete
  set, as before the marker; nothing warns the app.
- Deleting a `.good` by hand while the app keeps markers in step lets cron
  delete the backup it named until the next sync writes it again. If the sync
  is off and no in-app backups run, the last marker of each component pins its
  unit for cron indefinitely; deleting it by hand ends that.
- A marker the app cannot remove pins its unit for cron indefinitely; the
  app logs it and emits `[:kiln_cms, :backups, :last_good, :failed]`.
- Rolling the app back past the marker is harmless for the script: an older
  in-app prune deletes `.good` files as strays once they are older than
  `BACKUP_KEEP_DAYS`, and a host script left at the newer release honors them
  until then.

## When to revisit

- If a third marker is needed, or a marker needs to say more than "keep",
  the presence-only rule is the first thing to weigh against it.
- If `backup.sh` ever ships inside the release image and runs from there,
  the separate-upgrade problem this record works around goes away.
