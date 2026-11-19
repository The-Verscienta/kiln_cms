# 0064. Retention on a backup destination deletes only what this installation sent there

- **Status** — accepted (2026-11-15); amended 2026-11-18 by
  [#2950](https://github.com/The-Verscienta/kiln_cms/issues/2950)
  (`BACKUP_RCLONE_REMOTE` may be pruned by explicit opt-in, and each
  retention call has its own time limit, see "Amendment"); amended
  2026-11-19 (a stored destination too prunes only this backup directory's
  backups, plus the directories it adopted, see "Amendment (2026-11-19)").
- **References** — [#2220](https://github.com/The-Verscienta/kiln_cms/issues/2220)
  and the owner's approval of its decision E4 "all as proposed"
  (2026-11-15), with the critic's change 2 (where a destination writes is
  fixed, and destinations may not overlap);
  [ADR 0063](0063-each-backup-destination-is-its-own-step-and-a-run-that-reaches-only-some-is-partly-off-site.md)
  (each destination is its own step);
  [ADR 0041](0041-the-app-and-backup-sh-agree-on-what-to-keep-only-through-presence-only-marker-files.md)
  and [ADR 0062](0062-a-schedules-keep-holds-reach-backup-sh-through-a-third-presence-only-marker.md)
  (the local markers, which stay local).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Added, #2220
  ([long form](../changelog/v1.11.0.md#backup-destinations)).

## The problem

`KilnCMS.Backups.Retention` prunes `BACKUP_DIR` by age and by keep rules.
Nothing pruned the off-site copy: `BACKUP_RCLONE_REMOTE` grows until the
operator's own lifecycle rule or script trims it. With several destinations
per backup (ADR 0063), leaving every one to grow without limit fills
buckets and disks the admin added from a form, and the admin can't add a
lifecycle rule to a directory on a NAS.

But a destination is not a directory Kiln owns. A bucket can be shared by
two installations (staging and production, two sites, a restore drill), or
already hold backups copied there by hand or by cron. A listing shows names
that look like Kiln's backups; it does not show who made them. Pruning by
name and age alone would delete another installation's backups, or the
only copies of a cron-made backup someone placed there deliberately.

## Decision

**Retention runs on a stored destination, right after a backup reaches
it** (`Retention.run_on_destination/3`, called by
`KilnCMS.Backups.Steps` once that destination is recorded `ok`), when all
of these hold:

- the destination is stored in the app (a `"dest:<id>"` key), enabled, and
  its **Delete its old backups (retention)** box (`prune`) is ticked when
  the pass starts (the row is read again then, so turning it off mid-backup
  is obeyed);
- its adapter's `supports/0` includes both `:list` and `:delete` (Kiln's
  Local and Rclone do; a plugin's defaults to neither);
- where it writes does not overlap `BACKUP_RCLONE_REMOTE` or any other
  stored destination, enabled or not (checked again here, see below).

**It deletes only units this installation recorded sending there.** The
destination's `list/1` is grouped into units (one stamp of one kind) as the
local disk is, and the same keep rules as `BACKUP_DIR` are applied to them
(`plan/4`: recovery points, backups in flight, the newest verified and
newest complete unit of each kind, the schedules' keep settings,
`BACKUP_KEEP_DAYS`). Of what those rules would delete, a unit is deleted
only when its Run records an artifact of that kind, or one of its parts,
under **this destination's key** with status `ok` (or `pruned`, by an
earlier pass that stopped part-way). Anything else is left in place and
named in the run's log: "Retention on NAS left 2 old backup(s) this
installation has no record of sending there: db 20261101-031700, …".

**`BACKUP_RCLONE_REMOTE` is not pruned by the app unless the operator
turns it on** (`BACKUP_RCLONE_REMOTE_PRUNE`, off by default; see
"Amendment"). Without that switch only a `"dest:<id>"` key is accepted, and
nothing changes for the env remote.

**Where a destination writes is fixed, and destinations may not overlap.**
Ownership is recorded against a key, not a place, so the key must never
come to mean another place:

- the location settings (Local `path`; Rclone `remote_name` and `path`) are
  read-only once a destination is saved; moving one is adding a new
  destination;
- a new destination may not be, contain or sit inside `BACKUP_RCLONE_REMOTE`
  or another stored destination (`Destination.overlap?/2`, by whole path
  segments, after normalizing `foo:bar`, `foo:bar/` and `foo:/bar`);
- because `BACKUP_RCLONE_REMOTE` can change after a destination was saved,
  and two destinations saved at the same moment are not checked against
  each other, **the overlap is checked again before every pass**. A destination that
  overlaps the env remote or another one is skipped ("it overlaps
  BACKUP_RCLONE_REMOTE", "it overlaps another backup destination"). A
  plugin's destination, whose settings mean nothing to Kiln, can't be
  compared with anything: with `BACKUP_RCLONE_REMOTE` set it is skipped
  ("can't confirm it doesn't overlap BACKUP_RCLONE_REMOTE"); without it, it
  is pruned on the ownership rule alone. Letting a plugin say where it
  writes (an optional SDK callback) is a separate follow-up,
  [#3118](https://github.com/The-Verscienta/kiln_cms/issues/3118); until
  then a plugin's location stays unknown, and this rule fails closed.

**It fails closed.** A retention policy that can't be resolved, a local
backup directory that can't be listed, a destination listing that fails, a
Run read that fails or a destination row that can't be read deletes
nothing, and the run's log says "Retention on <name> skipped: <reason>;
nothing was deleted". The first delete that fails stops the pass. None of
this changes the destination's upload status: the backup reached it.

**The local markers stay local.** `.good`, `.hold` and `.keep` are never
uploaded, listed or read on a destination. A `.keep` in `BACKUP_DIR` pins
the same stamp on every destination, and a `.work/<stamp>/` pins a backup
in flight. A unit's age on a destination is the later of its newest remote
modification time and its stamp's own instant, so a store that resets
modification times never makes a backup look older than it is.

## Accepted

**A backup that later fails may already have pruned earlier destinations.**
Each destination is pruned as soon as it is reached, before the chain moves
on. If a later destination then refuses a file (fatal, ADR 0043), the
backup fails, but the destinations before it have already had their older
owned units deleted. Only older units the keep rules allowed deleting go:
the newest verified and newest complete unit of each kind on that
destination stay, and the failed backup's own unit is in flight while the
pass runs. Pruning every destination only at `finish` would hold each
destination's files until the last one finished, and a failure at any
destination would stop the pruning of all of them.

**An rclone `alias` remote, or two remote names for one bucket, can't be
detected.** The overlap check compares names and paths, not what they point
at. Ownership still holds: a unit sent through the other name is recorded
under the other key, and is not deleted through this one.

## Rejected

- **Prune by age alone.** It deletes another installation's backups in a
  shared bucket, and anything placed there by hand.
- **Upload the markers so a destination can "see" them.** It would make a
  file on a remote, writable by whoever else holds the bucket's keys, a
  reason to keep or not. Recovery points are decided on this host.
- **Prune `BACKUP_RCLONE_REMOTE` too, by default.** It changes what an
  operator who configured cron and the env remote has relied on, with no
  switch they asked for. The opt-in this was left for is the amendment
  below.
- **Let a destination's location be edited.** The key's ownership record
  would then license deleting, at the new place, what was sent to the old
  one.

## Consequences

- An admin who shares a bucket between installations sees, on every run,
  what is accumulating there that this installation won't delete.
- A destination whose `prune` is off, whose adapter can't list and delete,
  or that is skipped for an overlap grows without limit until someone
  trims it.
- History marks the deleted files `pruned` under that destination's key on
  their runs, and counts the units on the run that pruned them
  (`RunDestination.pruned`).

## Amendment (2026-11-18, #2950): pruning the env remote by opt-in, and a time limit per call

The owner decided, on the issue, to build the opt-in this record
left open, and to bound each retention call on its own.

- **`BACKUP_RCLONE_REMOTE_PRUNE=true` lets in-app backups prune the env
  remote.** Off by default, read only by the app (`config/runtime/prod/backups.exs`).
  The in-app off-site step prunes the env destination right after it is
  reached, as it does a stored one; with the switch off, any retention
  notice left on the env remote is cleared. `scripts/backup.sh` never reads
  the switch and never prunes the remote, so it does nothing on a
  cron-only install.
- **Ownership is narrower there.** Cron copies to the env remote under the
  same key (`"rclone:<remote>"`) that in-app backups record, so a record
  under that key alone would let the app delete cron's backups. A unit on
  the env remote is deleted only when its Run is an in-app run
  (`origin: :app`) that recorded the copy under the env key (`ok`, or
  `pruned` by an earlier pass that stopped part-way) **and** whose `dir_id`
  is this node's current `.kiln-dir-id`. An imported (cron) run, or a run
  of another backup directory, never makes a file there deletable. A node
  with no `.kiln-dir-id` deletes nothing.
- **The overlap rule is stricter for the env remote than for a stored
  destination.** It is pruned only when no stored destination, enabled or
  not, could share its place: one whose location can't be told (a
  plugin's), an S3 destination (a remote may name the same bucket under
  any name), or one that overlaps it (`Destination.overlap?/2`) blocks it.
  The check runs before every pass and is the one
  `Retention.prune_blocker/3` applies; the Destinations tab shows the same
  answer, so its **Prunes its old backups** badge, on the env row and on
  each stored one, appears only where a pass would prune.
- **How a local env remote compares.** A remote with no `name:` (a plain
  path) is a local directory for the comparison, and so overlaps a Local
  destination at, above or inside that path. A remote written through an
  inline backend (`:local:/mnt/backups`) is compared by that backend name
  like any named remote, so it is never matched against a Local
  destination's path; the ownership rule still holds there, since a Local
  destination's sends are recorded under its own key.
- **Each `list` and `delete` call has its own bound** (10 minutes for a
  listing, 60 seconds for a delete), or the step's deadline when that
  comes first, passed as the call's `:deadline` and worked out right
  before each call. A listing past its bound is a skip, as one that fails
  is; a delete past its bound stops the pass. A delete stopped at its
  bound may already have removed the file at the store; it is not marked
  `pruned`, and the next pass no longer lists it, so nothing is lost. The
  upload sweep's aborts are bounded the same way (60 seconds each).

## Amendment (2026-11-19): a stored destination prunes only this backup directory's backups, and the ones it adopted

The destination rows and the run history live in the database, so a
database restored on another server brings both along. Under the rule
above, that server's in-app backups would then delete, on every stored
destination, what the original server sent there, since each of those
backups has a Run recording it under the destination's key. The staging
scrub purges both tables, but only a copy made through it.

- **A stored destination uses the env remote's rule.** A unit is deleted
  only when its Run is an in-app one (`origin: :app`) that recorded sending
  it under the destination's key (`ok`, or `pruned` by an earlier pass)
  **and** whose `dir_id` is this node's current `.kiln-dir-id`, or one the
  destination adopted for it (below). A Run with no `dir_id`, an imported
  one, or one of another backup directory never makes a file deletable; a
  node with no readable `.kiln-dir-id` deletes nothing and the pass is
  skipped ("couldn't read the backup directory's id"). Every Run that can
  have reached a stored destination records its `dir_id` (the start step
  sets it from the lease), so no existing backup there loses its owner.
  Cron never sends to a stored destination.
- **`destination_plan/5` takes the owners as a list.** With none (`nil` or
  `[]`) nothing is deleted. Units left only because another directory's
  in-app backup sent them are reported apart, as one line on the run:
  "Retention on NAS kept 3 backup(s) sent by another backup directory (see
  Destinations)".
- **Adopting another directory.** A platform admin may tick, on a
  destination's row, a directory whose in-app backups reached it and that
  no live node reports (`DestinationConfig` `:adopt_directories`, its own
  action and audit event, `backup_destination_adoptions_changed`). The
  entry records the backup directories every live node reported then
  (`adopted_by`), and counts only on a node whose `.kiln-dir-id` is one of
  them: a database restored on another server, whose directory has a new
  id, inherits no adoption. A directory a live node reports is refused,
  and so is any adoption when the live nodes can't be read. The step
  re-reads the row just before each pass, so an adoption added or removed
  while a backup runs is obeyed by it. The env remote has no row and so no
  adoption: there, a server move copies `.kiln-dir-id`.
- **Pruning a destination needs a persistent `BACKUP_DIR`.** A directory
  that is recreated on each deploy gets a new id each time, and its earlier
  backups become another directory's: kept until adopted. On a server
  move, the old server is retired first, then its `.kiln-dir-id` is copied
  to the new one or the old directory is adopted.

Rejected: relying on the staging scrub (it covers only copies made through
it); turning pruning off when "the host" changes (there is no stable host
identity; the backup directory's id is the one Kiln already has); an
instance-wide adoption setting (there is no backups settings resource, and
the row is where its effect shows).

## When to revisit

- If pruning `BACKUP_RCLONE_REMOTE` should apply to cron-made backups too,
  cron would need its own record of which installation and directory sent
  each file; until then they are left for the operator's lifecycle rule.
- If a store can report who wrote an object, ownership could be read from
  the store as well as from the Run history.
