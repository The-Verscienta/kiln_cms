#!/usr/bin/env bash
#
# staging.sh — stand up (or tear down) an ephemeral staging environment from a
# production clone. See docs/staging-environments.md.
#
#   ./scripts/staging.sh up      # dump PROD → create+restore STAGING → migrate → scrub
#   ./scripts/staging.sh scrub   # (re)run only the scrub against STAGING_DATABASE_URL
#   ./scripts/staging.sh down    # DROP the staging database
#
# `up` and `down` create and drop the database STAGING_DATABASE_URL names, on
# the server it names (not libpq's default one), and refuse first unless that
# name contains staging, preview, ephemeral, tmp or scratch (any case; the
# same list as KilnCMS.Staging). createdb and dropdb connect through the URL's
# own server with dbname=postgres, then template1 if that fails.
#
# Environment:
#   PROD_DATABASE_URL       source to pg_dump (read-only; required for `up`)
#   STAGING_DATABASE_URL    throwaway target (required). For `up` and `down` a
#                           postgres://, postgresql:// or ecto:// URL whose
#                           path names the database (no `dbname` in its query);
#                           a key=value string or a bare name is refused.
#                           Both: postgres://, postgresql:// or ecto://; each
#                           password reaches pg_dump/psql through PGPASSWORD
#                           only, never their argv (see pg_conn_split). A
#                           key=value string with a password is refused. Put
#                           `sslmode=require` (or verify-full) in a URL to
#                           require TLS for pg_dump/psql: DATABASE_SSL does
#                           not reach them
#   KILN_STAGING_FORCE      true/1/yes/on: `up` and `down` accept a database
#                           whose name has none of the markers above (the
#                           scrub reads it too). For a deliberately named clone
#                           only
#   DATABASE_SSL            reaches migrate and scrub, which boot the prod
#                           config: it uses TLS unless DATABASE_SSL=false. Set
#                           that for a local Postgres without TLS
#   STAGING_ADMIN_EMAIL     seed one usable admin (recommended)
#   STAGING_ADMIN_PASSWORD  password for that admin
#   KILN_BIN                how to run migrate + scrub. Default: "mix".
#                           For a release image, e.g. "/app/bin/kiln_cms".
#   MIX_ENV                 with KILN_BIN=mix: unset (the script sets prod) or
#                           prod. Any other value is refused before anything
#                           runs: only the prod config reads DATABASE_URL.
#   SECRET_KEY_BASE         with KILN_BIN=mix: required, as for any prod boot,
#   TOKEN_SIGNING_SECRET    and checked (with the rest of the prod config)
#                           before anything is created or copied
#
# If migrate or scrub fails after `up` copied production, the clone holds
# unscrubbed production data: the script says so and drops it.
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
# after whitespace or a closing quote, in any case: libpq refuses another
# case by name, but only once the value is already in argv; keywords cannot
# be quoted, and a match inside a quoted value only refuses more) or
# `://`: PG_CONN_ERROR says why, PG_CONN_URL is empty, and the caller dies
# with it. A passwordless `key=value` conninfo or a bare database name is
# left unchanged.
# A URI whose query carries `sslpassword` (the key decoded as libpq decodes
# it, in any case) is refused the same way (#3049): libpq has no environment
# variable for a client key's passphrase, so it cannot be moved out of argv
# like the password. So is a query key that is another spelling of
# `password` (`PASSWORD=`, `Password=`): libpq doesn't read it, so it can't
# be moved, and left alone its value would sit in argv.
pg_conn_split() {
  local url="$1" rest userinfo="" has_userinfo=0 host user="" pw="" has_pw=0
  local query="" has_query=0 q seg key val kept="" sep="" shown="" ssep=""
  local qpw="" has_qpw=0 has_sslpw=0 has_pwcase=0
  # In a variable: bash 3.2 reads a quoted right-hand side of `=~` literally.
  # Bracketed letters, not nocasematch: the match is case-insensitive
  # without changing the caller's shell options.
  local secret_kw="(^|[[:space:]'])([Ss][Ss][Ll])?[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*="
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
      case "$key" in
        [Ss][Ss][Ll][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]) has_sslpw=1 ;;
        password)
          qpw="${seg#*=}"
          has_qpw=1
          ;;
        [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]) has_pwcase=1 ;;
        *)
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
          ;;
      esac
      [ "$seg" = "$q" ] && break
      q="${q#*&}"
    done
  fi
  if [ "$has_sslpw" = 1 ]; then
    PG_CONN_URL=""
    PG_CONN_DISPLAY_URL=""
    PG_CONN_ERROR="carries sslpassword, the passphrase of an encrypted client key, which would sit in the command line of pg_dump, pg_restore and psql for every process on the host to read (libpq has no environment variable for it). Use a client key file that is not encrypted, readable only by its owner (chmod 0600), or decrypt the one you have (openssl pkey -in client.key -out client.key.plain), and drop sslpassword from the URL."
    return 0
  fi
  if [ "$has_pwcase" = 1 ]; then
    PG_CONN_URL=""
    PG_CONN_DISPLAY_URL=""
    PG_CONN_ERROR="carries PASSWORD (or another spelling of password) in its query, which libpq does not read and which would sit in the tools' command line; write it as lower-case password, which Kiln moves out of the command line, or drop it."
    return 0
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

# A throwaway database's name contains one of these (any case), so `down`
# cannot drop, and `up` cannot overwrite, a production database by accident.
# Keep it the same as KilnCMS.Staging's @ephemeral_markers (a test compares
# them): the scrub refuses the same names.
STAGING_EPHEMERAL_MARKERS="staging preview ephemeral tmp scratch"

# $1 = a URL as pg_conn_split leaves it. Sets PG_URI_PATH (the database part,
# still percent-encoded; empty without one), PG_URI_HAS_QUERY and
# PG_URI_QUERY, splitting where libpq does (fe-connect.c): the userinfo ends
# at the first `@` before the first `/`, the hosts at the first `/` or `?`
# after it, and the path at the first `?`.
pg_uri_parts() {
  local rest="${1#*://}" userinfo hosts after
  userinfo="${rest%%[@/]*}"
  if [ "${rest:${#userinfo}:1}" = "@" ]; then
    rest="${rest:$((${#userinfo} + 1))}"
  fi
  hosts="${rest%%[/?]*}"
  after="${rest:${#hosts}}"
  PG_URI_PATH=""
  PG_URI_HAS_QUERY=0
  PG_URI_QUERY=""
  case "$after" in
    /*)
      after="${after:1}"
      PG_URI_PATH="${after%%\?*}"
      after="${after:${#PG_URI_PATH}}"
      ;;
  esac
  case "$after" in
    \?*)
      PG_URI_HAS_QUERY=1
      PG_URI_QUERY="${after:1}"
      ;;
  esac
}

# $1 = a URL as pg_conn_split leaves it, $2 = a database. Prints the URL with
# `dbname=$2` appended to its query: libpq takes the last dbname it is given,
# so createdb and dropdb connect to $2 on the URL's server, as its user, with
# its TLS settings.
maintenance_url() {
  pg_uri_parts "$1"
  if [ "$PG_URI_HAS_QUERY" = 0 ]; then
    printf '%s' "$1?dbname=$2"
  elif [ -z "$PG_URI_QUERY" ]; then
    printf '%s' "$1dbname=$2"
  else
    printf '%s' "$1&dbname=$2"
  fi
}

# Whether KILN_STAGING_FORCE is on, read as KilnCMS.Config.Env reads a flag:
# true, 1, yes or on, in any case, around whitespace.
staging_forced() {
  local v
  v="$(printf '%s' "${KILN_STAGING_FORCE:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    true | 1 | yes | on) return 0 ;;
  esac
  return 1
}

# $1 = STAGING_DATABASE_URL as pg_conn_split leaves it, $2 = what is refused
# ("dropped", "created or copied"). Sets STAGING_NAME to the database libpq
# connects to, percent-decoded, or dies: on a string that is not a URL (its
# database could not be checked), a URL with no database in its path or with
# a `dbname` in its query (which overrides the path), and a name with none of
# STAGING_EPHEMERAL_MARKERS unless KILN_STAGING_FORCE is on.
require_ephemeral_name() {
  local url="$1" nothing="$2" q seg lower marker
  case "$url" in
    postgres://* | postgresql://*) ;;
    *)
      die "STAGING_DATABASE_URL must be a postgres://, postgresql:// or ecto:// URL whose path names the database (postgres://user@host/kiln_staging): up and down check the name of the database they act on, and that of a key=value string or a bare name cannot be checked. Nothing was ${nothing}"
      ;;
  esac
  pg_uri_parts "$url"
  if [ "$PG_URI_HAS_QUERY" = 1 ]; then
    q="$PG_URI_QUERY"
    while :; do
      seg="${q%%&*}"
      pg_conn_decode "${seg%%=*}"
      case "$PG_CONN_DECODED" in
        [Dd][Bb][Nn][Aa][Mm][Ee])
          die "STAGING_DATABASE_URL sets dbname in its query, which overrides the database in its path: name the database in the path only (postgres://user@host/kiln_staging). Nothing was ${nothing}"
          ;;
      esac
      [ "$seg" = "$q" ] && break
      q="${q#*&}"
    done
  fi
  pg_conn_decode "$PG_URI_PATH"
  STAGING_NAME="$PG_CONN_DECODED"
  [ -n "$STAGING_NAME" ] ||
    die "STAGING_DATABASE_URL names no database: put it in the path (postgres://user@host/kiln_staging). Nothing was ${nothing}"

  lower="$(printf '%s' "$STAGING_NAME" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  for marker in $STAGING_EPHEMERAL_MARKERS; do
    case "$lower" in
      *"$marker"*) return 0 ;;
    esac
  done
  if staging_forced; then
    echo "==> KILN_STAGING_FORCE is on: accepting ${STAGING_NAME}, whose name does not look like a throwaway clone"
    return 0
  fi
  die "STAGING_DATABASE_URL names ${STAGING_NAME}, which does not look like a throwaway clone: a staging database's name contains one of: ${STAGING_EPHEMERAL_MARKERS// /, }. If ${STAGING_NAME} really is one, re-run with KILN_STAGING_FORCE=true. Nothing was ${nothing}"
}

# $1 = createdb or dropdb, $2 = the URL as pg_conn_split leaves it, $3 = 1
# when $4 is its password, $5 = the database, then the tool's options.
# Runs the tool against the URL's server through its postgres database, then
# template1 if that fails (dropdb's own fallback, which an explicit
# --maintenance-db turns off). The password reaches it through PGPASSWORD
# only. Fails with the errors of both attempts in PG_ADMIN_ERROR.
pg_admin() {
  local tool="$1" url="$2" has_pw="$3" pw="$4" name="$5" db err=""
  shift 5
  PG_ADMIN_ERROR=""
  for db in postgres template1; do
    # shellcheck disable=SC2030,SC2031 # PGPASSWORD is meant for this subshell only
    if err="$(
      if [ "$has_pw" = 1 ]; then export PGPASSWORD="$pw"; fi
      "$tool" ${1+"$@"} --maintenance-db="$(maintenance_url "$url" "$db")" -- "$name" 2>&1 >/dev/null
    )"; then
      return 0
    fi
    PG_ADMIN_ERROR+="${PG_ADMIN_ERROR:+
}    through ${db}: ${err:-${tool} failed}"
  done
  return 1
}

# Only config/runtime/prod reads DATABASE_URL (#2977). Under MIX_ENV=dev, Mix
# migrates and scrubs the database config/dev.exs names (kiln_cms_dev), not
# the clone: migrate changes the developer's database, and the scrub then
# refuses, leaving the clone unscrubbed. So with mix, MIX_ENV is prod: set
# here when unset, refused when it says anything else. Called before anything
# is created or copied.
require_mix_env() {
  [ "$KILN_BIN" = "mix" ] || return 0
  case "${MIX_ENV:-}" in
    "")
      echo "==> MIX_ENV is unset: running mix with MIX_ENV=prod"
      export MIX_ENV=prod
      ;;
    prod) ;;
    *)
      die "KILN_BIN=mix needs MIX_ENV=prod (or unset), not MIX_ENV=${MIX_ENV}: only the prod config reads DATABASE_URL, so mix would migrate and scrub the ${MIX_ENV} database instead of the clone"
      ;;
  esac
}

# With mix, the prod config must load before production is copied anywhere: a
# migrate that fails on a missing SECRET_KEY_BASE after the copy leaves an
# unscrubbed clone behind. The two variables every prod boot needs are named
# first; then the config itself is loaded, without starting the app or
# connecting, which catches whatever else it requires. Nothing is checked for
# a release, whose image carries its own configuration.
preflight_mix() {
  [ "$KILN_BIN" = "mix" ] || return 0
  local missing="" var
  for var in SECRET_KEY_BASE TOKEN_SIGNING_SECRET; do
    [ -n "${!var:-}" ] || missing="${missing} ${var}"
  done
  [ -z "$missing" ] ||
    die "KILN_BIN=mix boots the prod config, which needs:${missing}. Export them (fresh values, not production's) and re-run; nothing was created or copied"
  echo "==> Checking that the prod config loads"
  DATABASE_URL="$STAGING_DATABASE_URL" mix run --no-start -e ':ok' ||
    die "the prod config does not load under MIX_ENV=prod (see above); nothing was created or copied"
}

# `up` copied production into the clone and could not finish: what is there is
# production's personal data and secrets, unscrubbed. Dropped, so nobody
# serves or shares it by mistake. $1 = database name, $2 = the step, $3 = the
# staging URL as pg_conn_split leaves it, $4 = 1 when $5 is its password.
unscrubbed_clone() {
  cat >&2 <<EOF

!!! staging: ${2} failed after production was copied into ${1}.
!!! ${1} holds UNSCRUBBED production data (accounts, personal data, secrets).
!!! Dropping it now. Do not serve or share it.
EOF
  if pg_admin dropdb "$3" "$4" "$5" "$1" --if-exists; then
    echo "!!! Dropped ${1}. Fix the error above and run \`up\` again." >&2
  else
    echo "!!! Could not drop ${1}:" >&2
    echo "$PG_ADMIN_ERROR" >&2
    # $3 never holds the password: pg_conn_split moved it out.
    echo "!!! Drop it yourself NOW (STAGING_DATABASE_URL=… ./scripts/staging.sh down, or dropdb --if-exists --maintenance-db='$(maintenance_url "$3" postgres)' -- '${1}'$([ "$4" = 1 ] && printf ' with its password in PGPASSWORD'))." >&2
  fi
  exit 1
}

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
  require_mix_env

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
  require_ephemeral_name "$staging_url" "created or copied"
  name="$STAGING_NAME"

  preflight_mix

  echo "==> Cloning production into throwaway database: ${name}"

  # createdb is best-effort: the target may already exist, or the URL user may
  # lack CREATEDB (then the operator pre-creates it). Restore still validates.
  if ! pg_admin createdb "$staging_url" "$staging_has" "$staging_pw" "$name"; then
    echo "    (createdb skipped — assuming ${name} exists)"
    echo "$PG_ADMIN_ERROR"
  fi

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
  run_migrate || unscrubbed_clone "$name" "migrate" "$staging_url" "$staging_has" "$staging_pw"

  echo "==> Scrubbing staging (PII + outbound secrets)"
  run_scrub || unscrubbed_clone "$name" "the scrub" "$staging_url" "$staging_has" "$staging_pw"

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
  require_mix_env
  preflight_mix
  echo "==> Scrubbing staging (PII + outbound secrets)"
  if ! run_scrub; then
    # Not dropped: `scrub` runs against a clone someone else made, perhaps
    # already scrubbed once. Whether it still holds production's data is
    # unknown, so it is treated as if it did.
    cat >&2 <<EOF

!!! staging: the scrub failed. Treat the clone as holding UNSCRUBBED
!!! production data: do not serve or share it. Fix the error above and run
!!! \`scrub\` again, or drop it with \`./scripts/staging.sh down\`.
EOF
    exit 1
  fi
}

cmd_down() {
  require STAGING_DATABASE_URL
  pg_conn_split "$STAGING_DATABASE_URL"
  [ -z "$PG_CONN_ERROR" ] || die "STAGING_DATABASE_URL $PG_CONN_ERROR"
  local url="$PG_CONN_URL" pw="$PG_CONN_PASSWORD" has="$PG_CONN_HAS_PASSWORD" name
  require_ephemeral_name "$url" "dropped"
  name="$STAGING_NAME"
  echo "==> Dropping throwaway database: ${name}"
  pg_admin dropdb "$url" "$has" "$pw" "$name" --if-exists ||
    die "could not drop ${name} on the server in STAGING_DATABASE_URL:
${PG_ADMIN_ERROR}"
  echo "    done."
}

case "${1:-}" in
  up) cmd_up ;;
  scrub) cmd_scrub ;;
  down) cmd_down ;;
  *) die "usage: $0 {up|scrub|down}" ;;
esac
