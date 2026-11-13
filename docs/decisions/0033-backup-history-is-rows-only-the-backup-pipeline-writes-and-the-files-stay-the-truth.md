# 0033. Backup history is rows only the backup pipeline writes, and the files stay the truth

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  the backup history (#2217) in 1.9.0. The writers and the one write a person
  makes are described as they are today, after the step chain (#2218) and
  retention (#2219) added theirs.
- **References** — [#2415](https://github.com/The-Verscienta/kiln_cms/issues/2415),
  [#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217) and its pull
  request [#2414](https://github.com/The-Verscienta/kiln_cms/pull/2414);
  [#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218) for
  `:cancel` and `:resume`, [#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219)
  for retention, [#2554](https://github.com/The-Verscienta/kiln_cms/issues/2554)
  for the marker sync; the `Backups.Run` rows of the
  [policy matrix](../policy-matrix.md).
- **Changelog** — the 1.9.0 entry
  [Backups has a History](../changelog/v1.9.0.md#backup-history).

## The problem

`manifest.json` answers "what was the last backup". It is one object,
rewritten by whichever path ran last (`scripts/backup.sh` writes it only for
`all`), so it cannot answer "what happened every time", and it says nothing
about backups cron made before it. The Backups page needed a history of every
attempt, app-made and cron-made, and four questions decide whether that
history can be trusted:

- **Where does it live?** On disk next to the backups, or in the database.
- **Who may write it?** The pipeline, a platform admin, or both.
- **What is true when a row and the disk disagree?** A row says a file was
  written; an operator's `rm`, retention, or a restore onto another host
  changes the disk without telling it.
- **How do cron's backups get in?** `backup.sh` runs outside the application
  and has no database.

## Decision

- **A row per attempt, in Postgres, keyed by its stamp.**
  `KilnCMS.Backups.Run` (`backup_runs`) is instance-wide: no `multitenancy`
  block, and the read gate is `KilnCMS.Accounts.Checks.PlatformAdmin`, never
  `OrgAdmin`. The stamp (`YYYYMMDD-HHMMSS`, the one in the files' names) is the
  identity (`unique_stamp`). The chain opens a run (`:start`) before any file
  lands; a refused attempt is a `:skip` row and leaves `manifest.json` alone.
- **The pipeline's writes are the `:backups` system actor's alone.** One
  policy names `:start`, `:skip`, `:record_progress`, `:finish`, `:fail`,
  `:resume`, `:note_resume_refused`, `:import` and `:mark_pruned` and admits
  only `{KilnCMS.Checks.SystemActor, subsystem: :backups}`
  (`KilnCMS.Backups.system/0`); there is no `authorize_if PlatformAdmin` ahead
  of it and no `authorize?: false`. The writers today are:
  - the step chain, through `KilnCMS.Backups.Recorder`: opening, progress,
    finishing, failing (a chain whose node stopped included), skipping, and
    the chain's own `:resume` and `:note_resume_refused`;
  - `KilnCMS.Backups.Importer.run/0` (`:import`);
  - retention, which marks another run's deleted files through
    `KilnCMS.Backups.Recorder.mark_pruned/1` (`:mark_pruned`);
  - `KilnCMS.Backups.reconcile_stale_runs/1`, which fails a `running` run
    nothing has touched for longer than a step's timeout plus 15 minutes
    (`:fail`).

  Every Recorder write is best-effort: a refused or failed write logs a
  warning and never fails the backup.
- **People read, and make one write.** A platform admin reads the history
  (`:history` is theirs alone; the system actor's reads are narrowed to
  `:read`, `:running` and `:by_stamp`). The one write a person makes is
  `:cancel` (#2218): a platform admin stops a running backup. It has its own
  policy, the system actor is refused it, and it is recorded in the instance
  security log (`backup_canceled`). The **Resume** button writes no row: it
  requests a backup, and the chain's start step does the `:resume` as the
  system actor. There is no `destroy` action; the only delete is the staging
  scrub's (`KilnCMS.Staging.Scrub`, `backup_runs_purged`), which empties the
  table of a staging clone.
- **The files are the source of truth; the importer records what it finds.**
  The importer lists `db/` and `media/`, groups files by stamp and inserts one
  run per new stamp with an upsert whose `upsert_fields` are empty, so a row
  the application wrote, or an earlier import, is never modified.
  `manifest.json` only enriches a stamp whose files it names. The importer
  never reads a file's contents and never hashes or verifies one: an imported
  artifact is `verified: false` ("unverified (imported)"), and its SHA-256,
  taken from `manifest.json` or else from a well-formed checksum sidecar, is
  recorded as it stands, not checked against the file. It runs when a platform admin opens the Backups page, inside the chain
  (before the start step's `.partial` sweep, before retention prunes, and when
  a step fails), and in every marker sync.
- **`pruned` is stored; unexplained absence is computed on read.** Retention
  knows what it deleted, so it records it at the moment: the artifact's
  `local` destination becomes `pruned`. Everything else is worked out by
  `KilnCMS.Backups.Presence.for/4` when the page is shown, for the rows in
  view only, with an `lstat` per file: `:present`, `:pruned`,
  `:partly_pruned`, `:off_site_only`, `:expired` (a heuristic for imported
  runs past the retention window plus a day, since cron records no prune),
  `:missing` or `:none`. Nothing about presence is stored, so a restored file
  reads `on disk` again, and a run recorded by another node reads `missing` on
  a node whose `BACKUP_DIR` is its own.

## Rejected

- **Manifest-only history.** One object rewritten per run cannot hold a
  history, and growing it into a list would change a file cron also writes.
  The manifest stays as it was, for cron compatibility and for
  `KilnCMS.Backups.status/0`, and the history lives beside it.
- **A persisted `missing` flag.** Absence is relative to a host and a moment:
  `BACKUP_DIR` is host-local, and an `rm` or a restored file changes it
  without the application seeing. A stored flag would be wrong in both
  directions and need a sweep to keep it current. `pruned` is different
  because it records something the application did, when it did it.
- **Rows a platform admin can write.** The history is the record of what the
  pipeline did, and the rest of the pipeline now reads it
  (`KilnCMS.Backups.Retention`, #2219): retention never deletes the newest
  unit of each kind whose run succeeded with a verified artifact (for an
  imported run, a present one), and keeps a unit with no run until it ages
  out; the per-component status and its cron evidence read the runs too. A row a person could edit would let them change what
  retention deletes and what the alarm says. `:cancel` is the exception
  because it records a person's act, guarded and audited, and changes only a
  running backup's status.
- **An import cron.** In #2217 the importer was given no timer of its own: it
  runs where its result is read (the page) and where it matters (the
  pipeline), it is idempotent and bounded (one listing, one `select stamp`,
  one insert per new stamp), and a periodic job would add a job per node with
  nobody reading the result. Since #2554 the importer does run every 15
  minutes, as the first step of `KilnCMS.Backups.MarkerSyncWorker`'s sync,
  because that sync must classify cron's backups from their rows. It is still
  not a schedule of its own: with `KILN_BACKUP_MARKER_SYNC_CRON=false` the
  triggers are the page and the pipeline.

## When to revisit

- **Restore (#2226 and after) needs a person to mark a run**, for example as
  restored from. That is a new, named action with its own policy, as
  `:cancel` is, not a way into the pipeline's actions.
- **Rows can be deleted** (#2225): retention or an admin removing history
  needs its own action and decides whether a row outlives its files.
- **Imported runs get verified** (#2225): a verification that hashes files
  is a separate action that can set `verified`, never the import upsert,
  which must stay unable to modify a row.
- **A directory per host makes `missing` common.** Runs now carry the
  `dir_id` of their directory (#2539); presence could say "on another host"
  instead of `missing` once it reads it.
