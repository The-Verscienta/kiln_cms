# Backups from the command line

`bin/backup` is the backup command line of a release. It lists the backups
in History, starts one, re-checks a backup's files, reports what retention
would delete, and imports the backups cron made. It does from a shell what
the Backups page does in the browser, with output a script can read
(`--json`) and an exit status it can act on. In a checkout the same commands
are `mix kiln.backup.list`, `mix kiln.backup.run` and so on.

What backups are, where they live and how retention decides are in
[Backups & restore](backups.md). This guide covers the commands only.

It has no `restore` and no `unlock` yet (those are tracked in #2226 and
#2239), and `rescan` and `prune` cover this host's backup directory only (see
[What it does not do yet](#what-it-does-not-do-yet)).

## The commands

| Command | What it does | Runs |
|---|---|---|
| `bin/backup list [--limit N] [--json]` | The newest backups in History (default 20, at most 100), whether each one's files are on this host's disk, and what is running now. | beside the node |
| `bin/backup run [--components db,media] [--wait [--timeout SECONDS]] [--json]` | Asks for a backup now, as the Backups page's button does, with the trigger `console`. `--wait` follows it to its end. | inside the node |
| `bin/backup verify <stamp or id> [--json]` | Re-checks one backup's files on this host. Records nothing. | beside the node |
| `bin/backup prune [--dry-run] [--json]` | Reports what retention would delete here, and each destination's pruning state. Deletes nothing. `--dry-run` is accepted and changes nothing, since every `prune` is a dry run. | inside the node |
| `bin/backup rescan [--json]` | Imports the backups cron made in this host's backup directory into History. | inside the node |
| `bin/backup help` | Prints the usage. So do `--help` and `-h`, on their own or after a command. | beside the node |

Flags go **after** the command. `bin/backup --json list` is a usage error
(exit 2); `bin/backup list --json` is right. The one exception is
`bin/backup --help`.

`verify` takes a backup's stamp (`YYYYMMDD-HHMMSS`, as History and the file
names show it) or its run id (a UUID, the `id` that `list --json` prints).
Anything else is a usage error, and nothing is read.

`--components` names `db`, `media`, or both, each once (`db,media`). Without
it, a backup covers everything this deployment backs up.

## Where each command runs

`bin/backup` hands each command to the release's own `bin/kiln_cms`, in one of
two ways:

- **Beside the node** (`list`, `verify`, `help`): `bin/kiln_cms eval` starts a
  second, short-lived Erlang VM that starts only the database connection. It
  works while the application is stopped, as long as the database is up.
  `verify` must run here: it hashes every file of a backup, which can be
  gigabytes, and that work stays off the VM serving your sites. Sent to the
  serving node, `verify` is refused with exit 2 and the code
  `runs_beside_node`.
- **Inside the node** (`run`, `rescan`, `prune`): `bin/kiln_cms rpc` runs the
  command in the serving application. These need what only that VM has: its
  job queue for the backup's steps, and the importer state that `rescan`
  resets. They fail when the application is not running. Started beside the
  node, they are refused before anything is started, with exit 1 and the
  code `needs_running_node`.

Under `rpc`, a command's own output comes back to your terminal, but the
application's log lines (for example "Backup retention skipped: …") go to the
server's log, as every other log line of the running app does. Under `eval`
in a release, log lines go to stderr, so `--json` output on stdout stays one
clean JSON object.

What you type never becomes part of an Elixir expression. `bin/backup` joins
its arguments with newlines and base64-encodes them, and the release decodes
them as plain strings. An argument that holds a line break is refused with
exit 2 before anything runs.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The command did what it was asked. |
| `1` | The command ran and failed, or couldn't run (the database unreachable, a backup that failed, a file that doesn't match). |
| `2` | A usage error: an unknown command or flag, a bad value, a misplaced flag. Nothing ran. |

When the application isn't running, `run`, `rescan` and `prune` never reach
the command line's code: `bin/kiln_cms rpc` prints its own error and exits
non-zero, with no JSON.

`run` without `--wait` exits `0` when the request was accepted, including when
the backup was queued behind a running one. It doesn't say whether the backup
later succeeds; `--wait` does.

## List the backups

1. On the server, in the release directory (in Docker, see
   [Run it in Docker](#run-it-in-docker)), run:

   ```bash
   bin/backup list --limit 5
   ```

2. You see one line per backup, newest first: stamp, status, origin (`app`
   for an in-app backup, `imported` for one cron made), components, whether
   its files are here, and its size. A backup running now has its own line
   at the top and `(running now)` on its row.

   ```text
   20261126-031700  succeeded app      db,media present          1.2 GiB
   20261125-031700  succeeded imported db       present          48.3 MiB
   20261119-031700  succeeded app      db,media pruned           1.1 GiB
   ```

The presence column reads the backup directory the way the History page does:
`present`, `partly_pruned`, `pruned` (this app's retention removed it),
`off_site_only`, `expired` or `probably_expired` (cron's prune removed it),
`missing` (gone for no recorded reason, or recorded on another node), `unknown`
(the directory or a file couldn't be read), `mixed` (the backup's components
differ; `--json` has each one) or `none` (the backup produced no files).

## Start a backup and wait for it

1. Run:

   ```bash
   bin/backup run --components db --wait
   ```

2. You see `Backup started (chain 5f0c7c1e-…).` at once. The backup runs in
   the application's job queue, exactly as one started from the Backups page.
   History shows it with the trigger `console`.
3. When it ends you see `Backup succeeded (20261126-101500).` and the
   command exits `0`. A backup that fails, is canceled or is skipped exits
   `1` with an `error:` line that says which.

Without `--wait`, the command returns once the backup is requested, and
`bin/backup list` shows how it goes.

**Stopping the wait doesn't stop the backup.** Ctrl-C, a closed SSH session
or `--timeout` ends the waiting only; the backup carries on in its chain. To
stop the backup itself, cancel it from the Backups page
([Cancel a running backup](backups.md#cancel-a-running-backup)). Under `rpc`
the serving node notices that the caller left within about ten seconds and
stops following the backup.

**`--timeout SECONDS`** bounds the wait: 3 hours by default, 1 to 86400
seconds (24 hours). It applies only with `--wait`; on its own it is a usage
error. Reaching it exits `1` with the code `timeout`: "stopped waiting at
--timeout; the backup carries on (bin/backup list shows it)".

**`--wait` follows only a backup this request started.** When another backup
is running, the request is still made, but there is nothing of its own to
follow yet:

- **queued**: the request is queued behind the running backup and starts when
  that one ends. With `--wait` the command exits `1` with the code `queued` at
  once; the queued backup still runs. Run `bin/backup run --wait` again
  after the running one ends, or leave out `--wait`.
- **folded**: a backup of the same kind is already queued behind the running
  one, and it covers this request. With `--wait` the command exits `1` with
  the code `not_started`; follow it with `bin/backup list`.

Without `--wait`, both exit `0` and print what happened. A request refused
outright (another kind of backup already queued, backups turned off, no
`pg_dump`) exits `1`; the codes are under
[What can go wrong](#what-can-go-wrong).

## Verify a backup

1. Find the backup's stamp with `bin/backup list`.
2. Run, with that stamp:

   ```bash
   bin/backup verify 20261126-031700
   ```

3. You see one line per check, then the verdict. Exit `0` means every file
   that is here matched:

   ```text
   Backup 20261126-031700:
     ok      sha256     kiln-db-20261126-031700.dump: matches the digest the backup recorded
     ok      sidecar    kiln-db-20261126-031700.sha256: lists the recorded digests
     ok      pg_restore kiln-db-20261126-031700.dump: pg_restore --list reads it
     ok      sha256     kiln-media-20261126-031700.tar.gz: matches the digest the backup recorded
     ok      sidecar    kiln-media-20261126-031700.sha256: lists the recorded digests
   Backup 20261126-031700 verified here (2 file(s) hashed).
   ```

For each file of each component, in this order, it checks:

1. **Its name.** Every file name in History must be a file of this backup's
   stamp and component, not a `.partial`, with part numbers in order. A name
   that isn't fails as `unsafe_name`, and no path is built from it.
2. **That it is here**, as a regular file (a symlink fails as
   `not_regular`). A file that is gone is skipped, not failed, when History
   says why: this app's retention pruned it, a copy reached an off-site
   destination (it is never fetched back to check), or cron's prune removed
   it, judged as the History page judges it. Otherwise it fails as
   `missing`.
3. **Its SHA-256 and size** against what the backup recorded (`changed`
   when they differ), and for a media set whose every part is here, the
   set's own digest. A backup with no recorded digest (a cron backup imported
   without one) is checked against its sidecar's digest instead, without a
   size; with neither, the file fails as `no_digest`.
4. **The sidecar** (`kiln-<component>-<stamp>.sha256`) against the recorded
   digests: `sidecar_missing`, `sidecar_changed` or `sidecar_malformed` when
   it isn't right.
5. **A dump whose digest matched** is listed with `pg_restore --list`, so its
   table of contents still reads. A missing `pg_restore` is a failure
   (`pg_restore_missing`), never a pass. Media archives are checked by
   digest; they aren't listed.

A backup is verified only when at least one file was hashed and nothing
failed. When every file was skipped (all pruned, or off-site only), the
command exits `1` with the code `nothing_local`: there was nothing here to
check, which is not a pass.

**It records nothing.** `verify` writes no History field, no marker and no
sidecar. In particular it never sets a backup's **verified** flag: only the
backup that wrote a file vouches for it
([ADR 0033](decisions/0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)).
`list` keeps showing what the backup recorded, and `verify --json` reports it
per component as `recorded_verified`, next to what it found now.

**A backup that is still being written isn't checked.** One whose status is
running, or whose stamp the backup lock holds, exits `1` with the code
`in_progress`. When the lock can't be read, whether the backup is still being
written can't be told either, so `verify` checks nothing and exits `1` with
the code `lock_unreadable`; try again.

**Run it on the node that holds the files.** The backup directory is
per host. When a backup was recorded on another node, its files are reported
`missing` with "this run's files are in another node's backup directory",
and `--json` has `dir_id_mismatch: true`. When this host's directory id
can't be read, `dir_id_error` says so, and a missing file's detail says that
it can't be told whether the backup was recorded on another node.

**When the database is down,** `verify` can't read History and exits `1`
with the code `database_unreachable`. Use `scripts/backup.sh verify` on the
host instead: it needs no database. It checks the newest backup only, and it
is more lenient than `bin/backup verify`: a backup with no sidecar passes it
with "structure checked only", while `bin/backup verify` fails a missing
sidecar (`sidecar_missing`) and a file with nothing to check it against
(`no_digest`).

## See what retention would delete

1. Run:

   ```bash
   bin/backup prune
   ```

2. The first line is always the reminder that this is a report, followed by
   what would go and each destination's pruning state:

   ```text
   Report only — nothing is deleted. A real prune runs inside every backup (bin/backup run).
   Would delete here (1; 5 kept):
     db/kiln-db-20261020-031700.dump, kiln-db-20261020-031700.sha256  (expired)
   Destinations:
     NAS (local): pruning on
   ```

`prune` never deletes. It is the dry run of the retention pass
([What retention deletes and what it keeps](backups.md#what-retention-deletes-and-what-it-keeps)):
it plans, then stops, writing no file, no `.good` or `.hold` marker and
nothing about a pruned file into History. **A real prune runs inside every
backup**, as the backup's prune step, under that backup's hold on the backup
lock ([ADR 0067](decisions/0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md)).
To prune now, start a backup with `bin/backup run`.

Two things it does do, because every retention pass does:

- **It imports cron-made backups into History first**, so a backup cron wrote
  is judged from its row. That writes History rows, as `rescan` would.
- **A report that can't be made counts as a skipped retention pass.** When
  the import, the policy, the directory listing or the History read fails,
  the command exits `1`, and the server log gets "Backup retention skipped:
  …; nothing was deleted" and the `kiln_cms_backups_retention_skipped_count`
  counter (`scope="local"`) goes up by one, as for a backup's own prune step
  ([When retention is skipped or stops](backups.md#when-retention-is-skipped-or-stops)).
  An alert on that counter fires for a failed `bin/backup prune` too.

For a destination, `prune` reports the pruning state only: `on`, `off` (its
**Prune** setting, or for `BACKUP_RCLONE_REMOTE`, `BACKUP_RCLONE_REMOTE_PRUNE`)
or `blocked` with the reason (for example "it overlaps another backup
destination"). It doesn't list what would be deleted there; see
[What it does not do yet](#what-it-does-not-do-yet). Disabled destinations
aren't listed, but they still count when deciding whether an enabled one
overlaps them, as they do for retention.

## Import the backups cron made

When `scripts/backup.sh` runs from cron, the application imports its backups
into History on its own. After you fixed what made an import fail (the server
log names it), import at once:

```bash
bin/backup rescan
```

You see `Rescanned this host's backup directory: 0 deferred, 0 failed, 1 imported, 0 pending, 0 skipped`.
It clears the importer's backoff for every stamp first, so a stamp that
failed before is tried again now. A stamp that still fails exits `1` with
the code `import_failed`; the server log says why.

`rescan` covers this host's backup directory only (`"scope": "local"` in its
JSON). It doesn't look at off-site destinations.

## From a checkout

In a checkout, each command is a Mix task, with the same flags, output, JSON
and exit codes:

```bash
mix kiln.backup.list --json
mix kiln.backup.run --components db --wait
mix kiln.backup.verify 20261126-031700
mix kiln.backup.prune
mix kiln.backup.rescan
```

Each task starts the application **without its job queues and without the
backup heartbeat**: Oban starts in manual mode (no queues, no plugins, never
the leader) and the heartbeat is off. A checkout pointed at a deployment's
database would otherwise start working off that deployment's jobs (its
mail, its webhooks, and the very backup it just asked for) and join the
backup lock as one more backup node.

So **`mix kiln.backup.run` only asks for the backup**; the serving
application runs it, as its queues pick up the steps. With no application
running against the same database (in development, `mix phx.server` in
another terminal), the backup stays queued. Every command is allowed from a
checkout, and `verify`, `prune` and `rescan` run in the task's own VM against
the backup directory the checkout is configured with.

## Run it in Docker

The official image has `bin/backup` in `/app/bin`, and `/app` is the working
directory. Run it in the running container:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod exec app bin/backup list
```

Where the `app` service is in your default compose file, that is
`docker compose exec app bin/backup list`. `exec` matters: `run`, `rescan`
and `prune` talk to the application in that container, and `list` and
`verify` read the backup directory mounted there. `docker compose run --rm app bin/backup …` starts a
fresh container with no running application, where only `list` and
`verify` work.

## JSON output

With `--json`, every command prints exactly one JSON object and a newline on
stdout. A usage error is JSON too when `--json` is anywhere in the arguments.
Keys are only ever added, never renamed or removed. The keys of `prune` and
`rescan` are **provisional**: they will gain keys when destinations get their
own rescan and dry run, so read them by name and ignore keys you don't know.

Times are ISO 8601 strings, and atoms (statuses, kinds, codes) are strings.

### Every command

| Key | Value |
|---|---|
| `schema` | `1`. |
| `command` | The command (`"list"`, `"run"`, …); `null` on a usage error. |
| `ok` | `true` when `exit_code` is `0`. |
| `exit_code` | `0`, `1` or `2`, the process's exit status. |
| `error` | `null`, or `{"code": …, "message": …}`. The codes are under [What can go wrong](#what-can-go-wrong). |

### list

| Key | Value |
|---|---|
| `limit` | The `--limit` used. |
| `in_flight` | `null`, or the backup running now: `chain`, `stamp`, `resume`, `trigger`, `step`, `part`, `phase`, `acquired_at`, `components` and `waiting` (the request queued behind it, or `null`). |
| `runs` | The backups, newest first. Each has `id`, `stamp`, `status`, `origin`, `trigger`, `components`, `started_at`, `finished_at`, `error`, `offsite_status`, `dir_id`, `presence`, `in_flight` (it is the one running now), `resumable` and `artifacts`. |
| `runs[].artifacts[]` | One per component: `kind`, `name`, `bytes`, `verified` (as the backup recorded it), `sha256`, `parts` (the number of parts, or `null` for a single file), `presence` and `gone` (the files that are absent). |

### run

| Key | Value |
|---|---|
| `status` | `"started"`, `"queued"` or `"folded"`; `null` when the request was refused. |
| `chain` | The chain id: this backup's when it started, the running one's when queued or folded; `null` when refused. |
| `stamp` | The new backup's stamp when the lock already names it, else `null`. |
| `components` | What `--components` asked for, or `null` for everything. |
| `waited` | Whether `--wait` followed the backup. |
| `outcome` | With `--wait`: `"succeeded"`, `"failed"`, `"canceled"`, `"skipped"`, `"no_run"` (the chain ended without a backup) or `"timeout"`; else `null`. |
| `run` | After a wait, the backup's `id`, `stamp`, `status` and `error`; else `null`. |

A refused request carries only `status` and `chain`, both `null`, beside the
envelope. For example, `bin/backup run --components db --wait --json`, piped
through `jq`:

```json
{
  "chain": "5f0c7c1e-8a4b-4f3e-9d2a-1c6b7e0f3a92",
  "command": "run",
  "components": ["db"],
  "error": null,
  "exit_code": 0,
  "ok": true,
  "outcome": "succeeded",
  "run": {
    "error": null,
    "id": "0b6f5a3e-2d71-4c8e-a9f4-5e3d2c1b0a98",
    "stamp": "20261126-101500",
    "status": "succeeded"
  },
  "schema": 1,
  "stamp": null,
  "status": "started",
  "waited": true
}
```

### verify

| Key | Value |
|---|---|
| `run` | The backup: `id`, `stamp`, `status` and `dir_id`. Also present on `in_progress` and `lock_unreadable`, where it is the only key. |
| `verified` | `true` only when at least one file was hashed and no check failed. |
| `hashed` | How many files matched their digest. |
| `failed` | How many checks failed. |
| `dir_id_mismatch` | `true` when the backup was recorded against another node's backup directory. |
| `dir_id_error` | `null`, or why this host's backup directory id couldn't be read. |
| `artifacts` | One per component: `kind`, `name`, `recorded_verified` (what the backup recorded) and `result` (`"ok"`, `"failed"` or `"skipped"`). |
| `checks` | Every check made: `kind`, `file`, `check` (`"name"`, `"present"`, `"sha256"`, `"set_sha256"`, `"sidecar"` or `"pg_restore"`), `result` (`"ok"`, `"failed"` or `"skipped"`), `code` (why it failed or was skipped, else `null`) and `detail` (a sentence). |

### prune (provisional)

| Key | Value |
|---|---|
| `report_only` | Always `true`. |
| `would_delete` | What retention would delete here: `stamp`, `kind`, `sub` (`"db"` or `"media"`), `files` and `reason_code` (`"expired"`). `null` when retention couldn't plan. |
| `kept` | How many units it would keep, or `null`. |
| `last_good` | `{"db": …, "media": …}`: the newest verified stamp of each, or `null`, which the `.good` markers would name. |
| `destinations` | Each enabled destination, `BACKUP_RCLONE_REMOTE` first when it is set: `key`, `name`, `kind`, `state` (`"on"`, `"off"` or `"blocked"`), `reason_code` and `reason` (both `null` unless blocked). |
| `in_flight` | As in `list`. |

### rescan (provisional)

| Key | Value |
|---|---|
| `scope` | `"local"`: this host's backup directory. |
| `summary` | The importer's counts: `imported`, `pending` (not settled yet), `skipped`, `failed` and `deferred` (waiting out a backoff). `null` when the rescan couldn't run. |

## What can go wrong

| Code | Exit | Command | Meaning and what to do |
|---|---|---|---|
| `usage` | 2 | any | The arguments are wrong; the message says which, and the usage follows in text mode. |
| `runs_beside_node` | 2 | `verify` | `verify` reached the serving node. Run it through `bin/backup`, which uses `eval`. |
| `needs_running_node` | 1 | `run`, `rescan`, `prune` | The command was started beside the node, where it is refused. `bin/backup` sends it through `rpc`; check that the application is up. |
| (no JSON) | non-zero | `run`, `rescan`, `prune` | The application isn't running, so `bin/kiln_cms rpc` can't reach it and prints its own error. Start the application, or check its node name and cookie. |
| `database_unreachable` | 1 | `list`, `verify` | The database can't be reached. On the host, `scripts/backup.sh verify` checks the newest backup's files without it. |
| `read_failed` | 1 | `list`, `verify` | History couldn't be read for another reason; the message has it. |
| `queue_busy` | 1 | `run` | A backup of another kind (a fresh one, or a resume) is already queued. Ask again once it has started. |
| `disabled`, `no_database_url`, `no_pg_dump`, `no_pg_restore`, `no_media_dir`, `invalid_components`, `forbidden` | 1 | `run` | The request was refused, as the Backups page would refuse it: backups turned off (`BACKUP_ENABLED=false`), no database URL, a tool missing, no media directory for `--components media`, or the backup system actor refused. |
| `queued`, `not_started` | 1 | `run --wait` | Another backup is running, so there is nothing of this request's own to follow. The request stands. See [Start a backup and wait for it](#start-a-backup-and-wait-for-it). |
| `failed`, `canceled`, `skipped`, `no_run` | 1 | `run --wait` | How the backup ended. History has the details. |
| `timeout` | 1 | `run --wait` | `--timeout` was reached. The backup carries on. |
| `not_found` | 1 | `verify` | No backup with that stamp or id is in History. |
| `invalid_stamp` | 1 | `verify` | The History row's own stamp isn't a valid backup stamp, so no file name is built from it and nothing is read. |
| `in_progress` | 1 | `verify` | The backup is still being written. Verify it once it has finished. |
| `lock_unreadable` | 1 | `verify` | The backup lock couldn't be read, so nothing was checked. Try again. |
| `not_verified` | 1 | `verify` | At least one check failed; the `checks` say which file and why. |
| `nothing_local` | 1 | `verify` | None of the backup's files is on this host's disk (pruned, or off-site only). |
| `destinations_unreadable` | 1 | `prune` | The stored destinations couldn't be read. The local report is still printed. |
| `import`, `read_runs`, `policy`, `ls`, `lstat`, `crashed` | 1 | `prune` | Retention couldn't plan: the import of cron's backups, the History read, the retention policy, or the directory listing failed. Counted as a skipped retention pass (see [above](#see-what-retention-would-delete)). |
| `import_failed` | 1 | `rescan` | Some backups couldn't be imported; the server log says why. |
| `rescan_failed` | 1 | `rescan` | The rescan couldn't run at all, for example the directory couldn't be listed. |

## What it does not do yet

- **Rescan a destination.** `rescan` reads this host's backup directory
  only; importing what is on an off-site destination waits for the
  destination rescan of #2225.
- **List what would be pruned on a destination.** `prune` shows each
  destination's pruning state, not the files that would go there. That needs
  a dry run of the destination prune in the application.
- **Mark a backup verified.** `verify` reports only; see
  [Verify a backup](#verify-a-backup).
- **Restore or unlock.** Tracked in #2226 and #2239. Restoring is
  `scripts/restore.sh`, in [Backups & restore](backups.md).

`bin/backup` is a POSIX `sh` script for the Linux release; there is no
Windows version. No release smoke test in CI runs `bin/kiln_cms rpc`, so the
`rpc` path (`run`, `rescan`, `prune`) is covered by the tests of each piece,
not by one run through a built release.

Why the commands are split this way, and why `prune` only reports:
[ADR 0087](decisions/0087-the-backup-command-line-reads-beside-the-node-and-writes-inside-it-and-prunes-only-inside-a-backup.md).
