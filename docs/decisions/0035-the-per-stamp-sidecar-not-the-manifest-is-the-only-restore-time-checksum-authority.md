# 0035. The per-stamp sidecar, not the manifest, is the only restore-time checksum authority

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2418 in 1.9.0.
- **References** — [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424)
  (this record), [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218),
  [#2418](https://github.com/The-Verscienta/kiln_cms/pull/2418),
  [#2476](https://github.com/The-Verscienta/kiln_cms/pull/2476) (`backup.sh`
  writes the same sidecars, and parts without one are refused);
  [ADR 0034](0034-media-backups-are-split-by-file-set-into-independent-archives-not-by-bytes.md)
  for the part sets the sidecar describes,
  [ADR 0036](0036-restore-refuses-absolute-and-dot-dot-members-and-links-even-harmless-ones.md)
  for the check that follows it.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-media-parts).

## The problem

A backup's SHA-256 digests are recorded in three places:

- `manifest.json` at the root of the backup directory (`KilnCMS.Backups.Manifest`),
  one flat entry per file with an additive `sha256` key;
- the History row (`KilnCMS.Backups.Run`'s `artifacts`, each part's name, size
  and hash);
- a sidecar beside the files, `kiln-media-<stamp>.sha256` and
  `kiln-db-<stamp>.sha256`, in the format `sha256sum -c` reads
  (`KilnCMS.Backups.Checksum.write_sidecar/2`).

A restore that checks against more than one of them has to say what happens
when they disagree, and one that checks against the wrong one checks nothing on
the day it matters. `manifest.json` describes only the most recent backup: the
next run replaces it, and neither the app nor `backup.sh` copies it off-site.
The History row lives in the database a full-loss restore is about to recreate.
An operator restoring from a bare directory, or from the remote, has neither.

## Decision

- **`scripts/restore.sh media` verifies a set against its sidecar and nothing
  else, before it extracts anything.** It never reads `manifest.json` and never
  falls back to it.
- **The sidecar must describe the set exactly.** Every line is checked to be
  `<64 hex> <name>` first (`sidecar_well_formed`), because `sha256sum -c` and
  `shasum -c` skip lines they cannot parse and still exit 0, and Darwin's
  `sha256sum` has no `--strict`. Every file the sidecar names must be in the
  set, which catches a missing last part that contiguity cannot, and every part
  must be named in it. Then `sha256sum -c` (or `shasum -a 256 -c`) checks the
  digests.
- **The sidecar travels with its files.** It is written next to them, landing
  only after every part has (`backup.sh` writes it through a `.sha256.partial`
  marker, the app's checksum step after the last part), so a complete part set
  always has one. It is copied off-site with them, each copy after its own
  re-check (`Checksum.check_sidecar/2` in the app), and a failed sidecar copy
  fails the run. Retention deletes it with its set.
- **A missing sidecar is handled by what it implies.** A legacy single archive
  from before checksums restores with a loud warning, or aborts with
  `RESTORE_REQUIRE_CHECKSUM=1`. A `.partNN` set without one is refused, because
  it is most likely what a killed run left behind;
  `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` overrides that for an operator who
  knows the set is whole. The importer marks such a set failed ("incomplete
  media set: parts but no sidecar").
- **`backup.sh verify` reads the same sidecars**, for the newest dump and the
  newest complete media set, and fails a part set that has none.

The manifest and the History row keep their hashes for what they are for: the
console's report on the last backup, and History. Inside a run, the digests
recorded in `.work/<stamp>/state.json` gate a resume's reuse and each off-site
copy; those are the backup's own checks, not a restore's.

## Rejected

- **The manifest as the authority.** It is replaced by the next run, holds one
  backup, is never copied off-site, and is not next to the files a restore is
  given. A checksum that lives only there is lost with it (the reasoning in
  `KilnCMS.Backups.Checksum`'s moduledoc).
- **The History row.** It is in the database being restored, and cron's
  backups reach it only through the importer.
- **Checking the sidecar and falling back to the manifest when it is missing.**
  Two authorities that can disagree, and a fallback that would accept the
  parts of a killed run because an older manifest happened to describe the
  stamp.
- **A Kiln-specific checksum format.** `sha256sum -c` lets an operator verify a
  set by hand with tools every host has; a format only `restore.sh` reads would
  not.

## Consequences

- The sidecar proves the files are the ones the backup wrote, not who wrote
  them: anyone who can rewrite a part in the backup directory or on the remote
  can rewrite its sidecar too. Integrity, not authenticity. At-rest encryption
  is [#2224](https://github.com/The-Verscienta/kiln_cms/issues/2224), still
  open; nothing signs a backup.
- `restore.sh db` does not check `kiln-db-<stamp>.sha256` today; `pg_restore`
  reads the dump's own structure, and `backup.sh verify` and a manual
  `sha256sum -c` check the digest. The sidecar is still the file to check it
  against.
- Removing a set's sidecar makes `restore.sh` refuse the parts until an
  operator says otherwise. That is the intended direction: a part set without a
  sidecar is indistinguishable from an incomplete one.

## When to revisit

- Backups that are encrypted (#2224) or signed: an authenticated tag or a
  signature, not a plain digest, would then be the thing a restore trusts.
- An in-app restore, which would have the History row available and would have
  to choose between it and the sidecar.
- If `restore.sh db` gains a checksum step: it should read the db sidecar, by
  this record.
