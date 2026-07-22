#!/usr/bin/env bash
#
# restore.sh — restore Kiln backups made by scripts/backup.sh.
# See docs/backups.md for the full runbook (env vars, SECRET_KEY_BASE caveat).
#
#   ./scripts/restore.sh db <dump>       # pg_restore into RESTORE_DATABASE_URL
#   ./scripts/restore.sh media <tar.gz>  # extract into RESTORE_MEDIA_DIR
#   ./scripts/restore.sh drill <dump>    # restore into a throwaway DB + sanity checks
#
# Environment:
#   RESTORE_DATABASE_URL  target database (required for `db`/`drill`)
#   RESTORE_MEDIA_DIR     target uploads root (required for `media`)
#   RESTORE_CONFIRM=yes   skip the interactive confirmation (for scripted drills)
#
# `db` is destructive on the target (--clean drops existing objects first) —
# it refuses to run without confirmation. `drill` expects a throwaway target
# (the database name must contain "drill", "staging", "scratch", or "tmp")
# and never needs confirmation.

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  [ -n "${!1:-}" ] || die "$1 is required"
}

# Extract the database name from a postgres:// URL (same as scripts/staging.sh).
db_name() {
  local path="${1#*://}"
  path="${path#*/}"
  echo "${path%%\?*}"
}

confirm() {
  if [ "${RESTORE_CONFIRM:-}" != "yes" ]; then
    local name
    name="$(db_name "$RESTORE_DATABASE_URL")"
    echo "About to RESTORE OVER database '${name}' — existing objects will be dropped."
    read -r -p "Type the database name to continue: " reply
    [ "$reply" = "$name" ] || die "confirmation did not match — aborting"
  fi
}

do_restore() {
  # $1 = dump file. createdb is best-effort (target may exist / role may lack
  # CREATEDB); pg_restore still validates the connection.
  local dump="$1" name
  name="$(db_name "$RESTORE_DATABASE_URL")"
  createdb "$name" 2>/dev/null || echo "    (createdb skipped — assuming ${name} exists)"

  echo "==> pg_restore $(basename "$dump") → ${name}"
  # --clean --if-exists: idempotent over a previous restore. --no-owner /
  # --no-privileges mirrors how the dump was taken.
  pg_restore --no-owner --no-privileges --clean --if-exists \
    --dbname="$RESTORE_DATABASE_URL" "$dump"
  echo "    done."
}

cmd_db() {
  require RESTORE_DATABASE_URL
  local dump="${1:-}"
  [ -n "$dump" ] || die "usage: $0 db <dump-file>"
  [ -f "$dump" ] || die "no such file: $dump"
  confirm
  do_restore "$dump"
  cat <<'EOF'

==> Restore complete. Before serving from this database:
    * boot with the SAME SECRET_KEY_BASE the backup was taken under —
      database-stored keys (e.g. the DKIM private key) are encrypted with a
      key derived from it and are unrecoverable under a new one
    * run migrations if the code is newer than the dump (bin/migrate)
    * restore/point media storage (restore.sh media, or the S3 bucket)
    See docs/backups.md → "Restore runbook".
EOF
}

cmd_media() {
  require RESTORE_MEDIA_DIR
  local archive="${1:-}"
  [ -n "$archive" ] || die "usage: $0 media <tar.gz>"
  [ -f "$archive" ] || die "no such file: $archive"
  mkdir -p "$RESTORE_MEDIA_DIR"
  echo "==> Extracting $(basename "$archive") → ${RESTORE_MEDIA_DIR}"
  tar -xzf "$archive" -C "$RESTORE_MEDIA_DIR"
  echo "    done."
}

cmd_drill() {
  require RESTORE_DATABASE_URL
  local dump="${1:-}" name
  [ -n "$dump" ] || die "usage: $0 drill <dump-file>"
  [ -f "$dump" ] || die "no such file: $dump"

  name="$(db_name "$RESTORE_DATABASE_URL")"
  case "$name" in
    *drill* | *staging* | *scratch* | *tmp*) ;;
    *) die "drill target '${name}' must look throwaway (contain drill/staging/scratch/tmp) — never drill against production" ;;
  esac

  do_restore "$dump"

  echo "==> Sanity checks"
  local failed=0 t count
  for t in users pages posts media_items schema_migrations; do
    count="$(psql -Atc "select count(*) from ${t}" "$RESTORE_DATABASE_URL" 2>/dev/null)" ||
      {
        echo "    FAIL ${t}: table missing"
        failed=1
        continue
      }
    if [ "${count}" -gt 0 ]; then
      echo "    ok   ${t}: ${count} rows"
    else
      echo "    WARN ${t}: 0 rows"
    fi
  done
  [ "$failed" -eq 0 ] || die "drill FAILED — a core table is missing from the restore"

  cat <<EOF

==> Drill restore looks sane.
    * To poke at it with a real instance, scrub it first (it holds prod PII):
        STAGING_DATABASE_URL="${RESTORE_DATABASE_URL}" ./scripts/staging.sh scrub
    * Tear down when done:
        dropdb ${name}
    Record the drill (date, backup file, outcome) per docs/backups.md.
EOF
}

case "${1:-}" in
  db) shift; cmd_db "$@" ;;
  media) shift; cmd_media "$@" ;;
  drill) shift; cmd_drill "$@" ;;
  *) die "usage: $0 {db|media|drill} <file>" ;;
esac
