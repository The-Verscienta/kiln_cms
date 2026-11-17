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
#                           only, never their argv (see pg_conn_split). A
#                           key=value string with a password is refused. Put
#                           `sslmode=require` (or verify-full) in a URL to
#                           require TLS: DATABASE_SSL does not reach this script
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
# does for the app. Keep the copies of pg_conn_decode and pg_conn_split in
# scripts/backup.sh, scripts/restore.sh and scripts/staging.sh identical (a
# test compares them): each script must run alone, so none of them sources a
# shared file.
#
# $1 = percent-encoded text. Sets PG_CONN_DECODED: each valid `%HH` but `%00`
# decoded, anything else, `+` included, as written.
pg_conn_decode() {
  local s="$1" out="" hh
  # `printf -v … %b`, never `$(printf …)`: a substitution drops trailing
  # newlines. Literal backslashes are doubled first so `%b` reads only the
  # `\xHH` escapes made here (a bare `\c` would cut the text short).
  s="${s//\\/\\\\}"
  while :; do
    case "$s" in
      *%*) ;;
      *) break ;;
    esac
    out+="${s%%\%*}"
    s="${s#*\%}"
    hh="${s:0:2}"
    case "$hh" in
      00) out+="%" ;;
      [0123456789ABCDEFabcdef][0123456789ABCDEFabcdef])
        out+="\\x${hh}"
        s="${s:2}"
        ;;
      *) out+="%" ;;
    esac
  done
  out+="$s"
  # Not with an empty argument: bash 3.2 then assigns the output of the
  # previous `printf -v` instead of "".
  PG_CONN_DECODED=""
  if [ -n "$out" ]; then printf -v PG_CONN_DECODED '%b' "$out"; fi
}

# $1 = a DATABASE_URL. Sets PG_CONN_URL (what goes in argv), PG_CONN_PASSWORD
# and PG_CONN_HAS_PASSWORD (1 when PG_CONN_PASSWORD is to be exported as
# PGPASSWORD, in a subshell around the one command that needs it),
# PG_CONN_DISPLAY_URL and PG_CONN_ERROR:
#   - `ecto://` (any case) becomes `postgres://`, and a `postgres://` or
#     `postgresql://` scheme is lower-cased (libpq reads only those as URIs);
#   - Ecto's own query parameters are translated for libpq (#2833), keys and
#     values compared percent-decoded: `ssl=false` becomes `sslmode=disable`,
#     `pool_size`, `timeout` and `idle_interval` are dropped (and a `?` left
#     with nothing after it); everything else is kept as written;
#   - the userinfo password and every query `password` parameter (the key is
#     decoded first, as libpq does: `pass%77ord=` is one) are removed and
#     decoded. The query one wins, as in libpq. The userinfo ends where libpq
#     ends it (fe-connect.c): at the first `@` before the first `/`, so a `?`
#     or `#` before that `@` is part of the password; the password runs from
#     the first `:` in it;
#   - with no non-empty password and nothing to translate the URL is left as
#     written, so an inherited PGPASSWORD or ~/.pgpass still applies.
# PG_CONN_DISPLAY_URL is the URL without its password but with the query NOT
# translated: the one to print, or to hand the app as its DATABASE_URL (Ecto
# reads `ssl=false` and `pool_size` itself).
# A string that is not a postgres:// or postgresql:// URI is refused (#2831)
# when it holds a `password=` or `sslpassword=` keyword (at the start, or
# after whitespace or a closing quote; libpq keywords are case-sensitive and
# cannot be quoted, and a match inside a quoted value only refuses more) or
# `://`: PG_CONN_ERROR says why, PG_CONN_URL is empty, and the caller dies
# with it. A passwordless `key=value` conninfo or a bare database name is
# left unchanged.
pg_conn_split() {
  local url="$1" rest userinfo="" has_userinfo=0 host user="" pw="" has_pw=0
  local query="" has_query=0 q seg key val kept="" sep="" shown="" ssep=""
  local qpw="" has_qpw=0
  # In a variable: bash 3.2 reads a quoted right-hand side of `=~` literally.
  local secret_kw="(^|[[:space:]'])(ssl)?password[[:space:]]*="
  PG_CONN_URL="$url"
  PG_CONN_DISPLAY_URL="$url"
  PG_CONN_PASSWORD=""
  PG_CONN_HAS_PASSWORD=0
  PG_CONN_ERROR=""

  case "$url" in
    [Ee][Cc][Tt][Oo]://*) url="postgres://${url:7}" ;;
    [Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss]://*) url="postgres://${url:11}" ;;
    [Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss][Qq][Ll]://*) url="postgresql://${url:13}" ;;
  esac
  PG_CONN_URL="$url"
  PG_CONN_DISPLAY_URL="$url"
  case "$url" in
    postgres://* | postgresql://*) ;;
    *)
      if [[ "$url" == *://* || "$url" =~ $secret_kw ]]; then
        PG_CONN_URL=""
        PG_CONN_DISPLAY_URL=""
        PG_CONN_ERROR="is not a postgres:// URL and holds a password or another URL, which would sit in the command line of pg_dump, pg_restore and psql for every process on the host to read. Write it as a postgres:// URL, password included (postgres:///database?host=/socket/dir for a Unix socket), or put the password in PGPASSWORD or ~/.pgpass."
      fi
      return 0
      ;;
  esac

  rest="${url#*://}"
  userinfo="${rest%%[@/]*}"
  host="$rest"
  if [ "${rest:${#userinfo}:1}" = "@" ]; then
    has_userinfo=1
    host="${rest:$((${#userinfo} + 1))}"
    user="$userinfo"
    case "$userinfo" in
      *:*)
        user="${userinfo%%:*}"
        pw="${userinfo#*:}"
        has_pw=1
        ;;
    esac
  fi

  # From here `host` is the hosts and the path, up to the query.
  case "$host" in
    *\?*)
      query="${host#*\?}"
      host="${host%%\?*}"
      has_query=1
      ;;
  esac
  if [ "$has_query" = 1 ]; then
    q="$query"
    while :; do
      seg="${q%%&*}"
      key=""
      val=""
      case "$seg" in
        *=*)
          pg_conn_decode "${seg%%=*}"
          key="$PG_CONN_DECODED"
          pg_conn_decode "${seg#*=}"
          val="$PG_CONN_DECODED"
          ;;
      esac
      if [ "$key" = "password" ]; then
        qpw="${seg#*=}"
        has_qpw=1
      else
        shown="${shown}${ssep}${seg}"
        ssep="&"
        case "$key" in
          pool_size | timeout | idle_interval) ;;
          ssl)
            if [ "$val" = "false" ]; then
              kept="${kept}${sep}sslmode=disable"
            else
              kept="${kept}${sep}${seg}"
            fi
            sep="&"
            ;;
          *)
            kept="${kept}${sep}${seg}"
            sep="&"
            ;;
        esac
      fi
      [ "$seg" = "$q" ] && break
      q="${q#*&}"
    done
  fi

  if [ "$has_qpw" = 0 ] && { [ "$has_pw" = 0 ] || [ -z "$pw" ]; }; then
    # No password to move: only a translated query changes the URL, and the
    # userinfo stays as written.
    if [ "$has_query" = 1 ] && [ "$kept" != "$query" ]; then
      PG_CONN_URL="${url%%://*}://"
      [ "$has_userinfo" = 1 ] && PG_CONN_URL+="${userinfo}@"
      PG_CONN_URL+="${host}"
      [ -n "$kept" ] && PG_CONN_URL+="?${kept}"
    fi
    return 0
  fi
  [ "$has_qpw" = 1 ] && pw="$qpw"

  PG_CONN_URL="${url%%://*}://"
  [ "$has_userinfo" = 1 ] && PG_CONN_URL+="${user}@"
  PG_CONN_URL+="${host}"
  PG_CONN_DISPLAY_URL="$PG_CONN_URL"
  [ -n "$kept" ] && PG_CONN_URL+="?${kept}"
  [ -n "$shown" ] && PG_CONN_DISPLAY_URL+="?${shown}"

  pg_conn_decode "$pw"
  PG_CONN_PASSWORD="$PG_CONN_DECODED"
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

  # Each side gets its own URL's password as PGPASSWORD, in its own subshell,
  # and neither password is ever an argv element (#2726). Split first, so a
  # refused string stops the run before anything is created.
  local prod_url prod_pw prod_has staging_url staging_shown staging_pw staging_has
  pg_conn_split "$PROD_DATABASE_URL"
  [ -z "$PG_CONN_ERROR" ] || die "PROD_DATABASE_URL $PG_CONN_ERROR"
  prod_url="$PG_CONN_URL" prod_pw="$PG_CONN_PASSWORD" prod_has="$PG_CONN_HAS_PASSWORD"
  pg_conn_split "$STAGING_DATABASE_URL"
  [ -z "$PG_CONN_ERROR" ] || die "STAGING_DATABASE_URL $PG_CONN_ERROR"
  staging_url="$PG_CONN_URL" staging_pw="$PG_CONN_PASSWORD" staging_has="$PG_CONN_HAS_PASSWORD"
  staging_shown="$PG_CONN_DISPLAY_URL"

  local name
  name="$(db_name "$STAGING_DATABASE_URL")"
  echo "==> Cloning production into throwaway database: ${name}"

  # createdb is best-effort: the target may already exist, or the URL user may
  # lack CREATEDB (then the operator pre-creates it). Restore still validates.
  createdb "$name" 2>/dev/null || echo "    (createdb skipped — assuming ${name} exists)"

  echo "==> pg_dump PROD → psql STAGING"
  # Checked explicitly: bash 3.2 (Linux builds) does not apply `set -e` to a
  # pipeline that ends in a subshell, so a failed pg_dump went on to migrate
  # and scrub an empty clone. `pipefail` still makes the status non-zero.
  if ! (
    # shellcheck disable=SC2030,SC2031 # PGPASSWORD is meant for this subshell only
    if [ "$prod_has" = 1 ]; then export PGPASSWORD="$prod_pw"; fi
    # Production's queued jobs carry recipients and payloads (#2721): copy the
    # table, not its rows. The scrub purges oban_jobs too, for a clone made
    # some other way (a restored backup).
    pg_dump --no-owner --no-privileges --exclude-table-data=oban_jobs "$prod_url"
  ) | (
    # shellcheck disable=SC2030,SC2031 # PGPASSWORD is meant for this subshell only
    if [ "$staging_has" = 1 ]; then export PGPASSWORD="$staging_pw"; fi
    psql --quiet --set ON_ERROR_STOP=1 "$staging_url"
  ); then
    echo "staging: copying production into ${name} failed; nothing was migrated or scrubbed" >&2
    exit 1
  fi

  echo "==> Migrating staging to the current schema"
  run_migrate

  echo "==> Scrubbing staging (PII + outbound secrets)"
  run_scrub

  cat <<EOF

==> Staging is ready.
    Serve it by pointing a Kiln instance at (password not shown):
      DATABASE_URL=${staging_shown}
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
