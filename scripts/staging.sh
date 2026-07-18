#!/usr/bin/env bash
#
# staging.sh — stand up (or tear down) an ephemeral staging environment from a
# production clone. See docs/staging-environments.md.
#
#   ./scripts/staging.sh up      # dump PROD → create+restore STAGING → migrate → scrub
#   ./scripts/staging.sh scrub   # (re)run only the scrub against STAGING_DATABASE_URL
#   ./scripts/staging.sh down    # DROP the staging database
#
# Environment:
#   PROD_DATABASE_URL       source to pg_dump (read-only; required for `up`)
#   STAGING_DATABASE_URL    throwaway target (required; name must look ephemeral)
#   STAGING_ADMIN_EMAIL     seed one usable admin (recommended)
#   STAGING_ADMIN_PASSWORD  password for that admin
#   KILN_BIN                how to run migrate + scrub. Default: "mix".
#                           For a release image, e.g. "/app/bin/kiln_cms".
#
# Deliberately plain shell + pg_dump/psql so it behaves the same on a laptop and
# on the production VPS. It never writes to PROD_DATABASE_URL.

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  [ -n "${!1:-}" ] || die "$1 is required"
}

# Extract the database name from a postgres:// URL (strip path + query).
db_name() {
  local path="${1#*://}"
  path="${path#*/}"
  echo "${path%%\?*}"
}

KILN_BIN="${KILN_BIN:-mix}"

# Run migrate / scrub either via mix (checkout) or a release bin path.
run_migrate() {
  if [ "$KILN_BIN" = "mix" ]; then
    DATABASE_URL="$STAGING_DATABASE_URL" mix ecto.migrate
  else
    DATABASE_URL="$STAGING_DATABASE_URL" "$KILN_BIN" eval 'KilnCMS.Release.migrate()'
  fi
}

run_scrub() {
  if [ "$KILN_BIN" = "mix" ]; then
    DATABASE_URL="$STAGING_DATABASE_URL" \
    STAGING_ADMIN_EMAIL="${STAGING_ADMIN_EMAIL:-}" \
    STAGING_ADMIN_PASSWORD="${STAGING_ADMIN_PASSWORD:-}" \
      mix kiln.staging.scrub --yes
  else
    DATABASE_URL="$STAGING_DATABASE_URL" \
    KILN_STAGING_SCRUB=confirm \
    STAGING_ADMIN_EMAIL="${STAGING_ADMIN_EMAIL:-}" \
    STAGING_ADMIN_PASSWORD="${STAGING_ADMIN_PASSWORD:-}" \
      "$KILN_BIN" eval 'KilnCMS.Release.scrub_staging()'
  fi
}

cmd_up() {
  require PROD_DATABASE_URL
  require STAGING_DATABASE_URL

  local name
  name="$(db_name "$STAGING_DATABASE_URL")"
  echo "==> Cloning production into throwaway database: ${name}"

  # createdb is best-effort: the target may already exist, or the URL user may
  # lack CREATEDB (then the operator pre-creates it). Restore still validates.
  createdb "$name" 2>/dev/null || echo "    (createdb skipped — assuming ${name} exists)"

  echo "==> pg_dump PROD → psql STAGING"
  pg_dump --no-owner --no-privileges "$PROD_DATABASE_URL" \
    | psql --quiet --set ON_ERROR_STOP=1 "$STAGING_DATABASE_URL"

  echo "==> Migrating staging to the current schema"
  run_migrate

  echo "==> Scrubbing staging (PII + outbound secrets)"
  run_scrub

  cat <<EOF

==> Staging is ready.
    Serve it by pointing a Kiln instance at:
      DATABASE_URL=${STAGING_DATABASE_URL}
    with a FRESH SECRET_KEY_BASE and outbound integrations left off.
    Tear it down with: ./scripts/staging.sh down
EOF
}

cmd_scrub() {
  require STAGING_DATABASE_URL
  echo "==> Scrubbing staging (PII + outbound secrets)"
  run_scrub
}

cmd_down() {
  require STAGING_DATABASE_URL
  local name
  name="$(db_name "$STAGING_DATABASE_URL")"
  echo "==> Dropping throwaway database: ${name}"
  dropdb --if-exists "$name"
  echo "    done."
}

case "${1:-}" in
  up) cmd_up ;;
  scrub) cmd_scrub ;;
  down) cmd_down ;;
  *) die "usage: $0 {up|scrub|down}" ;;
esac
