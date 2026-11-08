# Backups, UpdraftPlus-style — plan

Status: in progress. Tracking epic: #2216 (children are checklisted there).
#2217 (backup history) is built; #2218 (split archives and checksums) is built
except for the Oban job-per-step chain, which stays open as a follow-up;
#2219 has its retention module (per-component units, recovery-point markers,
fail-closed prune) built, with the schedules, scheduler and UI still to come;
the rest is proposed.
Builds on #484 (in-app status + "Back up now"), `scripts/backup.sh`,
`scripts/restore.sh` and `docs/backups.md`.

## Why

UpdraftPlus is the benchmark for "backups a non-ops person can trust". What
makes it good is not the dump format, it is the whole loop being in the UI:

1. **Schedule it** — files and database on separate schedules, with retention.
2. **Send it elsewhere** — several remote destinations at once, a "test
   connection" button, resumable uploads.
3. **See it** — a list of backups with components, sizes, dates, logs.
4. **Get it back** — pick a backup, pick components, click Restore.
5. **Move it** — migrate/clone to another URL.
6. **Trust it** — email reports, checksums, encryption, auto-backup before risky
   changes.

Kiln today does (3) partly and (1)/(2) only through cron + rclone + env vars.
It deliberately has no (4), (5) or (6). This plan closes those gaps.

## Decisions to make first

| # | Decision | Proposal |
|---|---|---|
| B1 | **Reverse "restore is not here"** (`docs/backups.md`, `Backups` moduledoc). | Yes, but only with the safety design in #2226: maintenance mode, pre-restore safety snapshot, restore into a *scratch database then swap*, refuse on version mismatch. Record as a decision doc under `docs/decisions/`. |
| B2 | **One format, still.** The `.dump` + `.tar.gz` layout stays the interchange format so `restore.sh` keeps working on app-made backups. New metadata (checksums, encryption, parts) is additive in the manifest. | Keep. |
| B3 | **Where config lives.** Today env vars (`BACKUP_*`). UI-managed schedule/destinations need DB storage. | DB settings win when present; env vars are the fallback/default; the UI shows which source is in effect. Secrets (destination credentials) are Vault-encrypted columns. |
| B4 | **Destinations as a behaviour with a plugin seam**, core ships S3-compatible + SFTP/WebDAV; OAuth drives (Google Drive, Dropbox, OneDrive) ship as plugins (Plugin SDK), like the Cloudflare/Cloudinary image plugins. | Keep core lean; no new heavy deps. |
| B5 | **Whole instance only.** Backups stay instance-wide; per-org export remains `Portability`. Per-org restore (managed cloud, #334) is out of scope here. | Confirm. |

## Target feature map (UpdraftPlus → Kiln)

| UpdraftPlus | Kiln today | This plan |
|---|---|---|
| Manual backup, choose components | Back up now (all) | Component choice, S3-aware (#2217) |
| Schedules 2h…monthly, files vs DB separate | cron only | In-app schedules, per-component (#2219) |
| Retention per schedule | days only | Count per component/interval (#2219) |
| Remote storage (many), multiple at once | rclone single remote | Destination behaviour, fan-out (#2220, #2221, #2222) |
| Test settings button | none | Per-destination test (#2221) |
| Resumable uploads / chunked | `.partial` rename | Chunked, resumable (#2223) |
| Split archives by size | one tar | Parts + sha256 (#2218, built for the in-app path; `backup.sh` still writes one archive) |
| Existing backups list, rescan remote, upload, download | status of newest only | Backup history + rescan/import/download (#2217, #2225) |
| Restore with component choice | runbook only | Restore wizard + engine (#2226, #2227) |
| Backup before updates | none | Pre-risky-operation hook (#2228) |
| Email reports, logs | ping URL only | Reports, notifications, log viewer (#2229, #2230) |
| Encryption | none | At-rest encryption (#2224) |
| Incremental (premium) | none | Media incremental (#2232) |
| Migrate/clone with search-replace (premium) | staging scrub script | Migration wizard (#2233) |
| WP-CLI (premium) | scripts | `mix`/release CLI (#2234) |
| Onboarding wizard | none | Setup wizard + page redesign (#2231) |
| Integrity checksums | `pg_restore --list` | sha256 + scheduled restore drill (#2218, #2235) |

## Architecture sketch

- **`KilnCMS.Backups.Run`** (Ash resource, Postgres): one row per attempt —
  trigger, status, started/finished, components, error, log. Files are embedded
  `artifacts` (kind, name, bytes, sha256, parts, encrypted?, destinations
  status map). `manifest.json` is still written for cron compatibility and
  still read to surface cron runs (they are imported as `Run` rows, idempotent
  by stamp).
- **`KilnCMS.Backups.Destination`** behaviour: `test/1`, `put/3` (resumable,
  streaming), `list/1`, `get/3`, `delete/2`. Core adapters: `Local`, `S3`
  (reuses ExAws), `SFTP`, `WebDAV`, `Rclone` (wraps today's env var path).
  Config rows are Ash resources with Vault-encrypted credentials.
- **Scheduling**: one Oban cron entry ticks every minute-ish into
  `Backups.Scheduler`, which reads schedule rows and enqueues work. (Crontab is
  static at boot; user-editable schedules can't live in it.) Idempotent by
  schedule + window so a deploy mid-window can't double fire.
- **Pipeline** as separate Oban jobs on the `backups` queue (concurrency 1):
  `dump → archive(parts) → checksum → encrypt → upload(dest, part)` so a
  failure resumes at the failed step, not from scratch.
  **Decision for #2218:** the resume property ships first without the job
  chain. One Oban job still runs the steps in order, but each finished step and
  media part is durable in `<BACKUP_DIR>/.work/<stamp>/` (`state.json` plus the
  frozen file lists, with a recorded sha256 per part), and a platform admin's
  **Resume** button re-runs the same backup, reusing only parts whose hash
  still verifies. The job-per-step chain is a follow-up on top of that state;
  #2218 stays open for it.
- **Restore engine**: `Backups.Restore` — preflight (versions, extensions,
  space, checksums, decrypt), safety snapshot, maintenance mode, restore DB to
  a scratch database then rename/swap, restore media to a staging dir then
  swap, post-restore migrate, cache bust/refire, leave maintenance mode. Every
  phase logged, resumable or cleanly rolled back.
- **UI**: `/editor/backups` becomes tabs — *Backups* (history, actions),
  *Schedule*, *Destinations*, *Settings* (retention, encryption, reports), *Log*.
  Admin only; every handler re-checks authorization (the #1160 family). Uses
  the design-language kit; no DaisyUI.
- **Authorization/audit**: all new resources carry `Ash.Policy.Authorizer`
  (admin-only; code interfaces on the domain). Restore, download, destination
  edits and key operations write audit events.

## Phases

1. **Foundation** — #2217, #2218, #2219, #2231 (shell).
2. **Destinations** — #2220, #2221, #2222, #2223.
3. **Restore** — decision doc, #2226, #2227, #2225.
4. **Trust** — #2224, #2228, #2229, #2230, #2235, #2236.
5. **Advanced** — #2232, #2233, #2234, OAuth plugins (in #2222).

Each issue is independently shippable and additive under the 1.x compatibility
rules (expand/contract migrations, `mix kiln.migrations.check`).

## Risks

- **Restore is destructive** — mitigated by scratch-DB-then-swap, a mandatory
  safety snapshot, and a restore drill that runs the same engine in CI.
- **`SECRET_KEY_BASE` coupling** — a restored DB under another key loses
  Vault-encrypted columns, now including backup destination credentials.
  Restore preflight must warn; backups can optionally carry a re-keying
  sidecar (see `docs/secrets-rotation.md`).
- **Large media** — tar-in-memory/serial is not acceptable; stream, split,
  and upload in parts.
- **pg_dump version coupling** — already handled; extend preflight to restore.
- **Backups containing secrets/PII** — encryption (#2224) and download links
  must be short-lived and audited.
