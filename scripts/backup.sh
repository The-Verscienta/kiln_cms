#!/usr/bin/env bash
#
# backup.sh — back up the Kiln database and (Local-adapter) media uploads.
# See docs/backups.md for the full strategy, schedule, and restore runbook.
#
#   ./scripts/backup.sh db       # pg_dump -Fc DATABASE_URL → $BACKUP_DIR/db/
#   ./scripts/backup.sh media    # tar $MEDIA_DIR → $BACKUP_DIR/media/
#   ./scripts/backup.sh all      # both (media skipped unless MEDIA_DIR is set)
#   ./scripts/backup.sh verify   # sanity-check every file of the newest backup(s)
#   ./scripts/backup.sh prune    # delete backups older than $BACKUP_KEEP_DAYS
#
# Environment:
#   DATABASE_URL         source database (required for `db`/`all`; read-only)
#   BACKUP_DIR           where backups land (default: /var/backups/kiln)
#   MEDIA_DIR            uploads root when using the Local storage adapter.
#                        Leave unset on S3/R2 deployments (back up the bucket
#                        provider-side instead — see docs/backups.md).
#                        Defaults to KILN_MEDIA_ROOT when that is set and
#                        S3_BUCKET is not — the same rule the app applies.
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
# Every artifact gets a sha256 in the manifest and a sidecar next to it
# (`kiln-db-<stamp>.sha256`, `kiln-media-<stamp>.sha256`, `sha256sum -c`
# format) — the same files the in-app backup writes, so one restore path
# verifies both. This script writes ONE media archive and does not split it
# into parts (the app does; see docs/backups.md). `verify` and `prune` handle
# part sets written by the app: a stamp's files are checked, and aged, as a set.
#
# Every dump is verified (pg_restore --list) before it counts as a backup.
# Plain shell + pg_dump/tar so it behaves the same on a laptop and on the VPS.

set -euo pipefail

# Set by `die` so a failure manifest can record what actually went wrong.
LAST_ERROR=""

die() {
  LAST_ERROR="$*"
  echo "error: $*" >&2
  exit 1
}

require() {
  [ -n "${!1:-}" ] || die "$1 is required"
}

BACKUP_DIR="${BACKUP_DIR:-/var/backups/kiln}"
# KILN_MEDIA_ROOT is where the Local adapter writes once it is set (#1529), so
# it is the media root to archive — unless S3 is the adapter, where media is
# not on disk (config/runtime/prod/backups.exs applies the same rule).
if [ -z "${MEDIA_DIR:-}" ] && [ -z "${S3_BUCKET+set}" ]; then
  MEDIA_DIR="${KILN_MEDIA_ROOT:-}"
fi
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

# SHA-256 (lowercase hex) of a file: sha256sum on GNU/Linux, shasum on macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | cut -d' ' -f1
  else
    die "neither sha256sum nor shasum is installed"
  fi
}

# A sidecar is `<64 hex>  <file name>` per line (what the app and this script
# write). `sha256sum -c` / `shasum -c` SKIP lines they cannot parse and still
# exit 0 (Darwin's sha256sum has no --strict), so a truncated digest would
# verify nothing: validate every line ourselves first.
sidecar_well_formed() {
  [ -s "$1" ] && ! grep -Evq '^[0-9a-fA-F]{64} [ *][^/]+$' "$1"
}

# Verify a sidecar ($1 = directory, $2 = sidecar file name) with whichever tool exists.
sha_check() {
  sidecar_well_formed "$1/$2" || {
    echo "error: $2 has a missing or malformed checksum line" >&2
    return 1
  }
  if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "$1" && sha256sum -c -- "$2")
  elif command -v shasum >/dev/null 2>&1; then
    (cd -- "$1" && shasum -a 256 -c -- "$2")
  else
    die "neither sha256sum nor shasum is installed"
  fi
}

# Write the per-stamp sidecar next to the archive in `sha256sum -c` format
# (`<hex>  <filename>`), mode 0600, via .partial + mv. $1 = archive path,
# $2 = hex digest. Sets SIDECAR_PATH.
write_sidecar() {
  local dir name kind stamp
  dir="$(dirname "$1")"
  name="$(basename "$1")"
  kind="${name#kiln-}"
  kind="${kind%%-*}"
  stamp="${name#kiln-"${kind}"-}"
  stamp="${stamp%%.*}"
  SIDECAR_PATH="${dir}/kiln-${kind}-${stamp}.sha256"
  track_partial "${SIDECAR_PATH}.partial"
  (umask 077 && printf '%s  %s\n' "$2" "$name" > "${SIDECAR_PATH}.partial")
  mv "${SIDECAR_PATH}.partial" "$SIDECAR_PATH"
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
  # $1 = kind ("db"/"media"), $2 = absolute path to the verified artifact,
  # $3 = its sha256 (hex)
  local bytes
  bytes="$(wc -c < "$2" | tr -d ' ')"
  local entry
  entry="$(printf '{"kind":"%s","path":"%s/%s","bytes":%s,"verified":true,"sha256":"%s"}' \
    "$1" "$1" "$(basename "$2")" "$bytes" "$3")"

  if [ -n "$MANIFEST_ARTIFACTS" ]; then
    MANIFEST_ARTIFACTS="${MANIFEST_ARTIFACTS},${entry}"
  else
    MANIFEST_ARTIFACTS="$entry"
  fi
}

# Escape a value for a JSON string: backslash, quote, and the control
# characters JSON forbids raw. A literal newline in an error message used to
# produce a manifest `Jason.decode` rejects — which the console renders as "No
# backup has ever been recorded", the single most misleading thing it can say,
# in response to a FAILED backup.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' |
    awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
}

write_manifest() {
  # $1 = "true"/"false" (did it succeed), $2 = error string (may be empty)
  local out="$BACKUP_DIR/manifest.json"
  track_partial "${out}.partial"
  local err="null"
  [ -n "${2:-}" ] && err="\"$(json_escape "$2")\""
  local offsite="null"
  # Escaped too: these are operator-supplied strings, and an unescaped quote
  # in either silently breaks the whole file.
  [ -n "${BACKUP_RCLONE_REMOTE:-}" ] && offsite="\"$(json_escape "$BACKUP_RCLONE_REMOTE")\""
  local trigger
  trigger="$(json_escape "${BACKUP_TRIGGER:-cron}")"

  mkdir -p "$BACKUP_DIR"
  cat > "${out}.partial" <<JSON
{
  "version": 1,
  "started_at": "${STARTED_AT}",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "trigger": "${trigger}",
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

  # Only OUR OWN partials, tracked as they are created — never a blanket
  # `find … -name '*.partial' -delete`. Since #484 two writers share
  # $BACKUP_DIR, and a blanket sweep here would unlink the in-progress dump of
  # a concurrent in-app backup: pg_dump keeps writing to the unlinked inode,
  # exits 0, and its verification then fails with ENOENT — a successful cron
  # run reporting the app's run as failed.
  local f
  for f in $OWN_PARTIALS; do
    [ -n "$f" ] && rm -f "$f"
  done

  if [ "$status" -ne 0 ] && [ "${WRITE_MANIFEST:-0}" = "1" ]; then
    # `die` sets LAST_ERROR; a command that failed under `set -e` (pg_dump,
    # tar, rclone) never reaches it, so fall back to the exit status rather
    # than recording an empty reason.
    write_manifest false "${LAST_ERROR:-backup.sh exited ${status} - see the backup log}"
  fi
}

# Set by `die` so the manifest records what actually went wrong rather than
# only an exit status. Anything that kills the script without going through
# `die` (a pg_dump non-zero exit under `set -e`) falls back to the status.
OWN_PARTIALS=""

track_partial() {
  OWN_PARTIALS="${OWN_PARTIALS} $1"
}

cmd_db() {
  require DATABASE_URL
  mkdir -p "$BACKUP_DIR/db"
  local out="$BACKUP_DIR/db/kiln-db-${STAMP}.dump"

  track_partial "${out}.partial"
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
  local sha
  sha="$(sha256_of "$out")"
  write_sidecar "$out" "$sha"
  record_artifact db "$out" "$sha"
  offsite "$out"
  offsite "$SIDECAR_PATH"
}

cmd_media() {
  require MEDIA_DIR
  [ -d "$MEDIA_DIR" ] || die "MEDIA_DIR does not exist: $MEDIA_DIR"
  mkdir -p "$BACKUP_DIR/media"
  local out="$BACKUP_DIR/media/kiln-media-${STAMP}.tar.gz"

  track_partial "${out}.partial"
  echo "==> Archiving media uploads → ${out}"
  # -C so the archive holds relative paths (restores anywhere). Same
  # .partial-then-rename discipline as the dump.
  tar -czf "${out}.partial" -C "$MEDIA_DIR" .

  echo "==> Verifying archive (tar -tzf)"
  tar -tzf "${out}.partial" >/dev/null ||
    die "media archive failed verification and was removed"
  mv "${out}.partial" "$out"

  echo "    ok: $(du -h "$out" | cut -f1) $(basename "$out")"
  local sha
  sha="$(sha256_of "$out")"
  write_sidecar "$out" "$sha"
  record_artifact media "$out" "$sha"
  offsite "$out"
  offsite "$SIDECAR_PATH"
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

# The newest stamp among the files of one kind in $1/$2 ($2 = "kiln-db" or
# "kiln-media"): stamps sort lexicographically, so the largest is the newest —
# unlike mtime, which a part set's files do not share.
newest_stamp() {
  # shellcheck disable=SC2012 # names are filtered by the sed regex below
  ls -1 "$1" 2>/dev/null |
    sed -n -E "s/^${2}-([0-9]{8}-[0-9]{6})(\\.part[0-9]+)?\\.(dump|tar\\.gz)\$/\\1/p" |
    sort -u | tail -1 || true
}

# Check a stamp's sidecar if there is one ($1 = directory, $2 = sidecar name).
verify_sidecar() {
  if [ -f "$1/$2" ]; then
    sha_check "$1" "$2" >/dev/null || die "checksum mismatch against $2"
    echo "    sha256: ok ($2)"
  else
    echo "    sha256: no sidecar ($2) — structure checked only"
  fi
}

# A part set must be numbered 01..N with no gap. Without a sidecar nothing
# else notices a missing middle part (a missing LAST one is only visible to the
# sidecar). $1 = directory, $2 = stamp.
verify_part_contiguity() {
  local n expected=1 num f
  for f in "$1/kiln-media-${2}".part*.tar.gz; do
    [ -f "$f" ] || continue
    n="${f##*.part}"
    n="${n%.tar.gz}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    num=$((10#$n))
    echo "$num"
  done | sort -n | {
    while IFS= read -r num; do
      if [ "$num" -ne "$expected" ]; then
        echo "error: media set ${2} is missing part$(printf '%02d' "$expected") (found part$(printf '%02d' "$num"))" >&2
        exit 1
      fi
      expected=$((expected + 1))
    done
  } || die "media part set ${2} is not contiguous from part01"
}

cmd_verify() {
  local dump_stamp media_stamp f

  dump_stamp="$(newest_stamp "$BACKUP_DIR/db" kiln-db)"
  [ -n "$dump_stamp" ] || die "no dumps found under $BACKUP_DIR/db"
  f="$BACKUP_DIR/db/kiln-db-${dump_stamp}.dump"
  echo "==> Newest dump: $(basename "$f") ($(du -h "$f" | cut -f1))"
  pg_restore --list "$f" >/dev/null && echo "    dump: ok"
  verify_sidecar "$BACKUP_DIR/db" "kiln-db-${dump_stamp}.sha256"

  media_stamp="$(newest_stamp "$BACKUP_DIR/media" kiln-media)"
  if [ -n "$media_stamp" ]; then
    echo "==> Newest media backup: ${media_stamp}"
    # Every file of the stamp — a single legacy archive or all its parts —
    # not just whichever is newest by mtime.
    verify_part_contiguity "$BACKUP_DIR/media" "$media_stamp"
    for f in "$BACKUP_DIR/media/kiln-media-${media_stamp}.tar.gz" \
      "$BACKUP_DIR/media/kiln-media-${media_stamp}".part*.tar.gz; do
      [ -f "$f" ] || continue
      echo "    $(basename "$f") ($(du -h "$f" | cut -f1))"
      tar -tzf "$f" >/dev/null || die "media archive $(basename "$f") failed tar -tzf"
    done
    echo "    media: ok"
    verify_sidecar "$BACKUP_DIR/media" "kiln-media-${media_stamp}.sha256"
  else
    echo "==> No media archives (fine on S3-adapter deployments)"
  fi
}

# Prune whole backups, not files: everything stamped alike (the dump, the media
# archive or ALL its parts, and the sidecars) is one set, deleted together once
# even its NEWEST member is older than the retention. A per-file `find -mtime`
# would reap an old part while its fresh siblings survive, leaving a set that
# can't be restored.
cmd_prune() {
  echo "==> Pruning backups older than ${BACKUP_KEEP_DAYS} days"
  local stamps stamp dirs=()
  [ -d "$BACKUP_DIR/db" ] && dirs+=("$BACKUP_DIR/db")
  [ -d "$BACKUP_DIR/media" ] && dirs+=("$BACKUP_DIR/media")
  [ "${#dirs[@]}" -gt 0 ] || return 0

  # shellcheck disable=SC2012 # names are filtered by the sed regex below
  stamps="$(ls -1 "${dirs[@]}" 2>/dev/null |
    sed -n -E 's/^kiln-(db|media)-([0-9]{8}-[0-9]{6})\.(dump|tar\.gz|sha256|part[0-9]+\.tar\.gz)$/\2/p' |
    sort -u || true)"

  for stamp in $stamps; do
    # Any member that is not older than the cutoff keeps the whole set.
    if [ -z "$(find "${dirs[@]}" -maxdepth 1 -type f \
      \( -name "kiln-db-${stamp}.*" -o -name "kiln-media-${stamp}.*" \) \
      ! -name '*.partial' ! -mtime "+${BACKUP_KEEP_DAYS}" -print 2>/dev/null | head -1)" ]; then
      find "${dirs[@]}" -maxdepth 1 -type f \
        \( -name "kiln-db-${stamp}.*" -o -name "kiln-media-${stamp}.*" \) \
        ! -name '*.partial' -print -delete 2>/dev/null || true
    fi
  done
}

case "${1:-}" in
  db) trap on_exit EXIT; cmd_db ;;
  media) trap on_exit EXIT; cmd_media ;;
  all) WRITE_MANIFEST=1; trap on_exit EXIT; cmd_all ;;
  verify) cmd_verify ;;
  prune) cmd_prune ;;
  *) die "usage: $0 {db|media|all|verify|prune}" ;;
esac
