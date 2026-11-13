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
#                           Both: postgres://, postgresql:// or ecto://; each
#                           password reaches pg_dump/psql through PGPASSWORD
#                           only, never their argv (see pg_conn_split)
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

# Keep the database password out of pg_dump/pg_restore/psql's argv (#2726) and
# give libpq a URI it reads as one (#2719), as KilnCMS.Backups.PgUrl.split/1
# does for the app. Keep the copies in scripts/backup.sh, scripts/restore.sh and
# scripts/staging.sh identical (a test compares them): each script must run
# alone, so none of them sources a shared file.
#
# $1 = a DATABASE_URL. Sets PG_CONN_URL (what goes in argv), PG_CONN_PASSWORD
# and PG_CONN_HAS_PASSWORD (1 when PG_CONN_PASSWORD is to be exported as
# PGPASSWORD, in a subshell around the one command that needs it):
#   - `ecto://` (any case) becomes `postgres://`; nothing else is rewritten;
#   - the userinfo password (up to the LAST `@` before the first `/`, `?` or
#     `#`, from the first `:`) and every query `password=` are removed. The
#     query one wins, as in libpq. Each valid `%HH` but `%00` is decoded;
#     anything else, `+` included, stays as written;
#   - with no non-empty password the URL is left as written, so an inherited
#     PGPASSWORD or ~/.pgpass still applies.
# A string that is not a postgres:// or postgresql:// URI (a `key=value`
# conninfo) is left unchanged.
pg_conn_split() {
  local url="$1" rest authority tail userinfo="" has_userinfo=0 host user="" pw="" has_pw=0
  local path query="" has_query=0 q seg kept="" sep="" qpw="" has_qpw=0 out hh
  PG_CONN_URL="$url"
  PG_CONN_PASSWORD=""
  PG_CONN_HAS_PASSWORD=0

  case "$url" in
    [Ee][Cc][Tt][Oo]://*) url="postgres://${url:7}" ;;
  esac
  PG_CONN_URL="$url"
  case "$url" in
    postgres://* | postgresql://*) ;;
    *) return 0 ;;
  esac

  rest="${url#*://}"
  authority="${rest%%[/?#]*}"
  tail="${rest:${#authority}}"
  host="$authority"
  case "$authority" in
    *@*)
      has_userinfo=1
      userinfo="${authority%@*}"
      host="${authority##*@}"
      user="$userinfo"
      case "$userinfo" in
        *:*)
          user="${userinfo%%:*}"
          pw="${userinfo#*:}"
          has_pw=1
          ;;
      esac
      ;;
  esac

  path="$tail"
  case "$tail" in
    *\?*)
      path="${tail%%\?*}"
      query="${tail#*\?}"
      has_query=1
      ;;
  esac
  if [ "$has_query" = 1 ]; then
    q="$query"
    while :; do
      seg="${q%%&*}"
      case "$seg" in
        password=*)
          qpw="${seg#password=}"
          has_qpw=1
          ;;
        *)
          kept="${kept}${sep}${seg}"
          sep="&"
          ;;
      esac
      [ "$seg" = "$q" ] && break
      q="${q#*&}"
    done
    [ "$has_qpw" = 1 ] && query="$kept"
  fi

  if [ "$has_qpw" = 0 ] && { [ "$has_pw" = 0 ] || [ -z "$pw" ]; }; then
    return 0
  fi
  [ "$has_qpw" = 1 ] && pw="$qpw"

  PG_CONN_URL="${url%%://*}://"
  [ "$has_userinfo" = 1 ] && PG_CONN_URL+="${user}@"
  PG_CONN_URL+="${host}${path}"
  [ -n "$query" ] && PG_CONN_URL+="?${query}"

  # `printf -v … %b`, never `$(printf …)`: a substitution drops trailing
  # newlines. Literal backslashes are doubled first so `%b` reads only the
  # `\xHH` escapes made here (a bare `\c` would cut the password short).
  pw="${pw//\\/\\\\}"
  out=""
  while :; do
    case "$pw" in
      *%*) ;;
      *) break ;;
    esac
    out+="${pw%%\%*}"
    pw="${pw#*\%}"
    hh="${pw:0:2}"
    case "$hh" in
      00) out+="%" ;;
      [0123456789ABCDEFabcdef][0123456789ABCDEFabcdef])
        out+="\\x${hh}"
        pw="${pw:2}"
        ;;
      *) out+="%" ;;
    esac
  done
  out+="$pw"
  printf -v PG_CONN_PASSWORD '%b' "$out"
  [ -n "$PG_CONN_PASSWORD" ] && PG_CONN_HAS_PASSWORD=1
  return 0
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

  # Each side gets its own URL's password as PGPASSWORD, in its own subshell,
  # and neither password is ever an argv element (#2726).
  local prod_url prod_pw prod_has staging_url staging_pw staging_has
  pg_conn_split "$PROD_DATABASE_URL"
  prod_url="$PG_CONN_URL" prod_pw="$PG_CONN_PASSWORD" prod_has="$PG_CONN_HAS_PASSWORD"
  pg_conn_split "$STAGING_DATABASE_URL"
  staging_url="$PG_CONN_URL" staging_pw="$PG_CONN_PASSWORD" staging_has="$PG_CONN_HAS_PASSWORD"

  echo "==> pg_dump PROD → psql STAGING"
  (
    # shellcheck disable=SC2030,SC2031 # PGPASSWORD is meant for this subshell only
    if [ "$prod_has" = 1 ]; then export PGPASSWORD="$prod_pw"; fi
    pg_dump --no-owner --no-privileges "$prod_url"
  ) | (
    # shellcheck disable=SC2030,SC2031 # PGPASSWORD is meant for this subshell only
    if [ "$staging_has" = 1 ]; then export PGPASSWORD="$staging_pw"; fi
    psql --quiet --set ON_ERROR_STOP=1 "$staging_url"
  )

  echo "==> Migrating staging to the current schema"
  run_migrate

  echo "==> Scrubbing staging (PII + outbound secrets)"
  run_scrub

  cat <<EOF

==> Staging is ready.
    Serve it by pointing a Kiln instance at:
      DATABASE_URL=${STAGING_DATABASE_URL}
    with a FRESH SECRET_KEY_BASE and outbound integrations left off.

    Also set KILN_ENV_LABEL on that instance, e.g.:
      KILN_ENV_LABEL=staging
    The clone keeps production's content AND branding, so without a label its
    console is indistinguishable from the real one. Leave it unset in production.

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
