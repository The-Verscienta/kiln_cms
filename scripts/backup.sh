#!/usr/bin/env bash
#
# backup.sh — back up the Kiln database and (Local-adapter) media uploads.
# See docs/backups.md for the full strategy, schedule, and restore runbook.
#
#   ./scripts/backup.sh db       # pg_dump -Fc DATABASE_URL → $BACKUP_DIR/db/
#   ./scripts/backup.sh media    # tar $MEDIA_DIR → $BACKUP_DIR/media/
#   ./scripts/backup.sh all      # both (media skipped unless MEDIA_DIR is set)
#   ./scripts/backup.sh verify   # sanity-check the newest dump + media archive
#   ./scripts/backup.sh prune    # delete backups older than $BACKUP_KEEP_DAYS
#
# Environment:
#   DATABASE_URL         source database (required for `db`/`all`; read-only)
#   BACKUP_DIR           where backups land (default: /var/backups/kiln)
#   MEDIA_DIR            uploads root when using the Local storage adapter.
#                        Leave unset on S3/R2 deployments (back up the bucket
#                        provider-side instead — see docs/backups.md).
#   BACKUP_KEEP_DAYS     local retention in days (default: 14)
#   BACKUP_RCLONE_REMOTE optional rclone target (e.g. "r2:kiln-backups") —
#                        each new backup is copied off-site after it verifies
#   BACKUP_PING_URL      optional URL curl'd on success (healthchecks.io-style
#                        dead-man's switch; the check fires when pings STOP)
#   BACKUP_TRIGGER       label recorded in the manifest (default: "cron")
#
# `all` writes $BACKUP_DIR/manifest.json — the file the in-app backup panel
# reads (#484). Kept in the same format KilnCMS.Backups.Manifest writes, so
# either path can produce it and the console reports on whichever ran last.
#
# Every dump is verified (pg_restore --list) before it counts as a backup.
# Plain shell + pg_dump/tar so it behaves the same on a laptop and on the VPS.

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  [ -n "${!1:-}" ] || die "$1 is required"
}

BACKUP_DIR="${BACKUP_DIR:-/var/backups/kiln}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

offsite() {
  # $1 = file to copy off-site (best-effort is NOT enough: fail loudly so cron
  # surfaces it — an off-site copy that silently stopped is the classic trap).
  if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
    echo "==> Off-site copy → ${BACKUP_RCLONE_REMOTE}"
    rclone copy "$1" "${BACKUP_RCLONE_REMOTE}/$(basename "$(dirname "$1")")"
  fi
}

ping_ok() {
  if [ -n "${BACKUP_PING_URL:-}" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "$BACKUP_PING_URL" || true
  fi
}

# --- manifest (#484) --------------------------------------------------------
#
# The console reads this to report the last backup — including this one, which
# it never saw run. Kept in sync with KilnCMS.Backups.Manifest: same file, same
# keys, same relative paths. Written atomically (.partial then mv) for the same
# reason the dumps are: a reader catching a half-written manifest would report
# a backup that did not happen.
MANIFEST_ARTIFACTS=""

record_artifact() {
  # $1 = kind ("db"/"media"), $2 = absolute path to the verified artifact
  local bytes
  bytes="$(wc -c < "$2" | tr -d ' ')"
  local entry
  entry="$(printf '{"kind":"%s","path":"%s/%s","bytes":%s,"verified":true}' \
    "$1" "$1" "$(basename "$2")" "$bytes")"

  if [ -n "$MANIFEST_ARTIFACTS" ]; then
    MANIFEST_ARTIFACTS="${MANIFEST_ARTIFACTS},${entry}"
  else
    MANIFEST_ARTIFACTS="$entry"
  fi
}

write_manifest() {
  # $1 = "true"/"false" (did it succeed), $2 = error string (may be empty)
  local out="$BACKUP_DIR/manifest.json"
  local err="null"
  [ -n "${2:-}" ] && err="\"$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
  local offsite="null"
  [ -n "${BACKUP_RCLONE_REMOTE:-}" ] && offsite="\"${BACKUP_RCLONE_REMOTE}\""

  mkdir -p "$BACKUP_DIR"
  cat > "${out}.partial" <<JSON
{
  "version": 1,
  "started_at": "${STARTED_AT}",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "trigger": "${BACKUP_TRIGGER:-cron}",
  "ok": $1,
  "artifacts": [${MANIFEST_ARTIFACTS}],
  "offsite": ${offsite},
  "keep_days": ${BACKUP_KEEP_DAYS},
  "error": ${err}
}
JSON
  mv "${out}.partial" "$out"
}

# ONE exit trap for the whole script, installed once. It has to be one:
# `cmd_db` and `cmd_media` used to install their own `trap … EXIT` to clean up
# a `.partial`, which REPLACED any trap the caller had set and then cleared it
# outright with `trap - EXIT`. A failure-manifest trap set by `cmd_all` would
# therefore never have run — the exact silent-failure shape this file exists
# to prevent.
#
# Two jobs, in order: never leave a `.partial` behind (an unverified artifact
# must not survive to look like a backup), and — for `all` only — record the
# failure, so the console stops showing the last SUCCESSFUL backup as though
# it answered the question.
#
# Only `all` writes a manifest, because only `all` is a backup: a hand-run
# `backup.sh db` would otherwise record "the last backup" as database-only.
on_exit() {
  local status=$?

  find "$BACKUP_DIR" -type f -name '*.partial' -delete 2>/dev/null || true

  if [ "$status" -ne 0 ] && [ "${WRITE_MANIFEST:-0}" = "1" ]; then
    write_manifest false "backup.sh exited ${status} — see the backup log"
  fi
}

newest() {
  # newest file matching $1 glob, or empty
  ls -1t $1 2>/dev/null | head -1 || true
}

cmd_db() {
  require DATABASE_URL
  mkdir -p "$BACKUP_DIR/db"
  local out="$BACKUP_DIR/db/kiln-db-${STAMP}.dump"

  echo "==> pg_dump → ${out}"
  # Custom format (-Fc): compressed, restorable table-by-table with pg_restore.
  # --no-owner/--no-privileges matches scripts/staging.sh: restores don't
  # depend on the production role existing on the target.
  # Dump to a .partial name and rename only after verification, so an aborted
  # or unverified dump can never be picked up as a backup.
  pg_dump --format=custom --no-owner --no-privileges \
    --file="${out}.partial" "$DATABASE_URL"

  echo "==> Verifying dump (pg_restore --list)"
  pg_restore --list "${out}.partial" >/dev/null ||
    die "dump failed verification and was removed — this backup did NOT succeed"
  mv "${out}.partial" "$out"

  echo "    ok: $(du -h "$out" | cut -f1) $(basename "$out")"
  record_artifact db "$out"
  offsite "$out"
}

cmd_media() {
  require MEDIA_DIR
  [ -d "$MEDIA_DIR" ] || die "MEDIA_DIR does not exist: $MEDIA_DIR"
  mkdir -p "$BACKUP_DIR/media"
  local out="$BACKUP_DIR/media/kiln-media-${STAMP}.tar.gz"

  echo "==> Archiving media uploads → ${out}"
  # -C so the archive holds relative paths (restores anywhere). Same
  # .partial-then-rename discipline as the dump.
  tar -czf "${out}.partial" -C "$MEDIA_DIR" .

  echo "==> Verifying archive (tar -tzf)"
  tar -tzf "${out}.partial" >/dev/null ||
    die "media archive failed verification and was removed"
  mv "${out}.partial" "$out"

  echo "    ok: $(du -h "$out" | cut -f1) $(basename "$out")"
  record_artifact media "$out"
  offsite "$out"
}

cmd_all() {
  cmd_db
  if [ -n "${MEDIA_DIR:-}" ]; then
    cmd_media
  else
    echo "==> MEDIA_DIR not set — skipping media archive (S3-adapter deployments back up the bucket instead)"
  fi
  cmd_prune
  write_manifest true ""
  ping_ok
}

cmd_verify() {
  local dump archive
  dump="$(newest "$BACKUP_DIR/db/kiln-db-*.dump")"
  [ -n "$dump" ] || die "no dumps found under $BACKUP_DIR/db"
  echo "==> Newest dump: $(basename "$dump") ($(du -h "$dump" | cut -f1))"
  pg_restore --list "$dump" >/dev/null && echo "    dump: ok"

  archive="$(newest "$BACKUP_DIR/media/kiln-media-*.tar.gz")"
  if [ -n "$archive" ]; then
    echo "==> Newest media archive: $(basename "$archive") ($(du -h "$archive" | cut -f1))"
    tar -tzf "$archive" >/dev/null && echo "    media: ok"
  else
    echo "==> No media archives (fine on S3-adapter deployments)"
  fi
}

cmd_prune() {
  echo "==> Pruning backups older than ${BACKUP_KEEP_DAYS} days"
  find "$BACKUP_DIR" -type f \
    \( -name 'kiln-db-*.dump' -o -name 'kiln-media-*.tar.gz' \) \
    -mtime "+${BACKUP_KEEP_DAYS}" -print -delete 2>/dev/null || true
}

case "${1:-}" in
  db) trap on_exit EXIT; cmd_db ;;
  media) trap on_exit EXIT; cmd_media ;;
  all) WRITE_MANIFEST=1; trap on_exit EXIT; cmd_all ;;
  verify) cmd_verify ;;
  prune) cmd_prune ;;
  *) die "usage: $0 {db|media|all|verify|prune}" ;;
esac
