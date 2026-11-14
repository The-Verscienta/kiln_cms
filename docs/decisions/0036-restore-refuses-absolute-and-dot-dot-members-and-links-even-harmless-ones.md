# 0036. Restore refuses absolute and `..` members and links, even harmless ones

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2418 in 1.9.0.
- **References** — [#2424](https://github.com/The-Verscienta/kiln_cms/issues/2424)
  (this record), [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218),
  [#2418](https://github.com/The-Verscienta/kiln_cms/pull/2418) ("Not done":
  links that stay inside the tree through `..` are refused too);
  [ADR 0035](0035-the-per-stamp-sidecar-not-the-manifest-is-the-only-restore-time-checksum-authority.md)
  for the checksum check that runs before this one.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#backup-media-parts).

## The problem

`scripts/restore.sh media` extracts archives into `RESTORE_MEDIA_DIR`, often
as root, and often from a copy fetched back from an off-site remote. A matching
checksum says the archive is the one the backup wrote; it does not say the
archive is safe to extract. A member named `/etc/cron.d/x` or `../../x` writes
outside the target. So does a symlink member pointing out of the tree followed
by a member written through it, even though every member *name* looks safe;
with parts (ADR 0034), the link and the member written through it can be in
different archives.

`tar` strips a leading `/` and refuses `..` in member names by default (the
script never passes `-P`), but that protects names, not link targets, and the
restore must not depend on which `tar` the host has or refuse halfway through a
set.

## Decision

- **Every archive is listed before any is extracted, and one unsafe member
  stops the whole restore.** `unsafe_members` in `scripts/restore.sh` runs
  `tar -tzf` and `tar -tvzf` on each archive of the set, a legacy single
  archive and an archive not named by Kiln included, and the restore aborts
  with "nothing was extracted" if any archive reports a member that:
  - has an absolute name, or a `..` path component; or
  - is a symlink or hardlink whose target is absolute or has a `..` component.

  A `..` component, not the substring: `a..b` is an ordinary name.
- **Harmless `..` links are refused too.** `d/x -> ../y` stays inside the tree,
  and the rule refuses it anyway. The check is a text rule on the listing, not
  a resolution of where each link lands.
- **When in doubt, refuse.** A link record the script cannot take apart is
  reported as unsafe. A name or target containing the separator (` -> `,
  ` link to `) is split at every occurrence and each piece checked, which can
  only over-report.
- **A listing that fails is a refusal.** Each listing is written to a file
  first and `tar`'s exit status checked; piping it into `grep` would drop the
  status and let a truncated part pass the check.

The rule lives in `restore.sh` only. Nothing in the app extracts an archive:
restore is a documented operator procedure
([What it deliberately does not do](../backups.md#what-it-deliberately-does-not-do)).

## Rejected

- **Resolve each link and refuse only those that leave the tree.** Doing that
  correctly means normalizing every target against its link's directory and
  against the links other members create, in this archive and in the other
  parts, from `tar -tv` text whose quoting differs between GNU tar and bsdtar.
  A mistake there is a write outside the target as root; a mistake in the text
  rule is a refused restore that an operator finishes by hand.
- **Rely on `tar`'s own protections.** They differ between `tar`
  implementations and versions, and the refusal would come mid-extraction,
  after earlier parts had been written.
- **Extract into a staging directory and inspect the result.** Extraction is
  exactly what writes through a hostile link, so the staging directory is no
  protection; the listing is the only safe place to look.
- **Check only member names.** A safe-looking name written through an outward
  link escapes the target all the same.

## Consequences

- A media directory that legitimately holds a `..` symlink backs up normally
  (the planner archives a symlink as a symlink) and is refused by `restore.sh`.
  The operator looks at the set and extracts it with `tar -xzf` by hand, as
  [the multi-part restore runbook](../backups.md#restore-a-media-set-that-has-several-parts)
  says.
- Every part is read twice before extraction (`-t` and `-tv`), on top of the
  checksum read: three reads of the set before the first byte is written.

## When to revisit

- Reports of real media directories whose in-tree `..` links make restores
  fail.
- An in-app restore, which would need this rule in Elixir, where a path can be
  resolved without parsing `tar` text.
- A `tar` with a safe-extract mode that every supported host has.
