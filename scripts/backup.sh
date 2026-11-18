#!/usr/bin/env bash
#
# backup.sh — back up the Kiln database and (Local-adapter) media uploads.
# See docs/backups.md for the full strategy, schedule, and restore runbook.
#
#   ./scripts/backup.sh db       # pg_dump -Fc DATABASE_URL → $BACKUP_DIR/db/
#   ./scripts/backup.sh media    # tar $MEDIA_DIR → $BACKUP_DIR/media/ (in parts)
#   ./scripts/backup.sh all      # both (media skipped unless MEDIA_DIR is set)
#   ./scripts/backup.sh verify   # sanity-check every file of the newest backup(s)
#   ./scripts/backup.sh prune    # delete backups older than $BACKUP_KEEP_DAYS,
#                                # except recovery points (kiln-<stamp>.keep),
#                                # last-good backups (kiln-<stamp>.good),
#                                # backups a schedule holds (kiln-<stamp>.hold),
#                                # the newest complete one, and work in flight;
#                                # and the .partial files of a run killed
#                                # outright, once every file of its stamp is
#                                # 12 hours old
#
# Environment:
#   DATABASE_URL         source database (required for `db`/`all`; read-only).
#                        postgres://, postgresql:// or ecto:// (the form the
#                        app documents); the password reaches pg_dump through
#                        PGPASSWORD only, never its argv (see pg_conn_split).
#                        A key=value string with a password is refused. Put
#                        `sslmode=require` (or verify-full) in it to require
#                        TLS: the app's DATABASE_SSL does not reach this script
#   BACKUP_LOCK_WAIT_SECONDS how long pg_dump waits for each table lock before
#                        giving up (1-3600, default 600; anything else keeps
#                        600 and warns on stderr) — the same variable the app
#                        reads
#   BACKUP_DIR           where backups land (default: /var/backups/kiln)
#   BACKUP_FREE_SPACE_CHECK refuse a dump or media archive that would not fit
#                        (default on; false/0/no/off skips the check; anything
#                        else keeps it on and warns) — the same variable the
#                        app reads; see check_free_space
#   MEDIA_DIR            uploads root when using the Local storage adapter.
#                        Leave unset on S3/R2 deployments (back up the bucket
#                        provider-side instead — see docs/backups.md).
#                        Defaults to KILN_MEDIA_ROOT when that is set and
#                        S3_BUCKET is not — the same rule the app applies.
#   BACKUP_MEDIA_PART_MB target ceiling, in MB, on the input size of one media
#                        part (16-10240, default 400; anything else keeps 400
#                        and warns on stderr) — the same variable the app reads
#   BACKUP_MEDIA_EXCLUDE comma-separated globs, relative to MEDIA_DIR, left out
#                        of the media archive (same rules as the app: `*` and
#                        `?` stay within one path segment, `**` crosses them,
#                        a pattern without `/` matches a name at any depth)
#   TMPDIR               where the media file lists and the heartbeat's record
#                        of the running child are kept (default: /tmp);
#                        removed when the script exits
#   BACKUP_KEEP_DAYS     local retention in days (1-2147483647, default: 14;
#                        anything else keeps 14 and warns on stderr, as the
#                        app does); see `prune`
#   BACKUP_RCLONE_REMOTE optional rclone target (e.g. "r2:kiln-backups") —
#                        each new backup is copied off-site after it verifies;
#                        each file is re-hashed right before its copy and the
#                        run stops, uploading nothing more, if one changed.
#                        A connection string's parameters go to rclone as
#                        RCLONE_CONFIG_* variables, not argv (see offsite)
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
# verifies both.
#
# Media is written the way the app writes it (#2218,
# KilnCMS.Backups.MediaArchive — keep the two in step): the FILE SET is split
# into independent `tar.gz` parts of at most BACKUP_MEDIA_PART_MB of input
# each. One part keeps the legacy name `kiln-media-<stamp>.tar.gz`; two or more
# are `kiln-media-<stamp>.partNN.tar.gz`, listed in order in the one sidecar.
# Regular files and symlinks are archived; directories are not, so empty
# folders and folder modes are not kept. A file larger than the cap is a part
# of its own. If any part fails, every file of the unfinished set is removed:
# cron has no resume, and a partial set must not look like a backup.
# A change to how MediaArchive walks, excludes, sizes, splits, archives or
# names, or to the sidecar or the manifest's part keys, updates this script
# and test/scripts/backup_script_test.exs in the same pull request (ADR 0042).
# Needs GNU tar or bsdtar (`--null -T`); busybox tar is refused up front.
# `verify` treats a stamp's files as one set; `prune` treats each component
# of a stamp (db, media) as one unit.
#
# Every dump is verified (pg_restore --list) before it counts as a backup.
# Plain shell + pg_dump/tar so it behaves the same on a laptop and on the VPS
# (bash 3.2 or later; GNU or BSD tar, stat and xargs).

set -euo pipefail
# An exported CDPATH makes `cd dir` print the directory it chose, which
# `$(cd -- … && pwd -P)` would then capture as part of the path.
unset CDPATH

# Set by `die` so a failure manifest can record what actually went wrong.
LAST_ERROR=""
# The background heartbeat (start_heartbeat), stopped by on_exit.
HEARTBEAT_PID=""
# The long-running child in flight (pg_dump, pg_restore --list, tar, rclone;
# see run_child), and the file that names it to the heartbeat (#2847).
CHILD_PID=""
CHILD_FILE=""

# A run killed outright (kill -9, the OOM killer, power loss: no trap runs)
# leaves its `.partial` files behind (#2478). While the run lives, a
# background loop touches every `.partial` of its stamp every HEARTBEAT_S
# seconds, so "no file of this stamp has changed for hours" means "no writer":
# the app's Importer records such a stamp as interrupted after 3 hours
# (KilnCMS.Backups.Importer.interrupted_after_s/0), and `prune` removes its
# partials once every file of the stamp is ABANDONED_PARTIAL_MIN minutes old,
# so the Importer has had many chances to read the stamp first. The test suite
# checks the two against the Importer's threshold. Not settings: changing one
# without the other mislabels live runs.
#
# The same loop stops the run's child when the run is killed outright (#2847):
# a pg_dump, tar or rclone orphaned by a SIGKILL would otherwise run on,
# writing a `.partial` nothing keeps fresh, until `prune` unlinks it under
# its feet. It notices within HEARTBEAT_S (see start_heartbeat).
HEARTBEAT_S=300
ABANDONED_PARTIAL_MIN=720
# The app's partial grace (KilnCMS.Backups.Retention.partial_grace_s/0, in
# minutes; the test suite checks the two agree): a `.partial` younger than this
# may still be written. `prune` counts a unit with one as in flight, and
# removes a leftover manifest temporary file only once it is older.
PARTIAL_GRACE_MIN=60

die() {
  LAST_ERROR="$*"
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
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
# The stamp and the start from ONE reading of the clock: two `date` calls can
# straddle a second boundary, and the importer keys a failure manifest by its
# stamp — a start one second later names a run that doesn't exist. The same
# reading as seconds since the epoch, for claim_stamp, which may step the
# stamp past one already in use (the start stays when the run started).
NOW="$(date -u '+%Y%m%d-%H%M%S %Y-%m-%dT%H:%M:%SZ %s')"
STAMP="${NOW%% *}"
NOW="${NOW#* }"
STARTED_AT="${NOW%% *}"
NOW_EPOCH="${NOW#* }"

# Copy one file off-site — but only the file this run verified (#2218).
# $1 = file, $2 = the sha256 recorded when it was written. The file is
# re-hashed immediately before its own copy (not all up front, which would
# leave the whole upload window open); a missing file, a symlink, or one whose
# digest changed is REFUSED: never uploaded, never retried, and the run stops
# here. A failed copy (after rclone's own retries) fails the run too: fail
# loudly so cron surfaces it — an off-site copy that silently stopped is the
# classic trap. The app checks the same thing; for a sidecar it compares the
# parsed lines where this hashes the bytes, and either catches a change.
offsite() {
  [ -n "${BACKUP_RCLONE_REMOTE:-}" ] || return 0
  local file="$1" expected="${2:-}" found=""
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    found="$(sha256_of "$file")" || found=""
  fi
  if [ -z "$expected" ] || [ "$found" != "$expected" ]; then
    refuse_offsite "$file" "$expected" "$found"
  fi
  rclone_split_remote "$BACKUP_RCLONE_REMOTE"
  local dest
  dest="${OFFSITE_REMOTE}/$(basename "$(dirname "$file")")"
  echo "==> Off-site copy → ${OFFSITE_REMOTE}"
  # The parameters reach rclone through its environment only: `export` is a
  # builtin, and the subshell keeps them from every other command (#2690).
  # A tracked child (run_child), so it dies with the script (#2847); `exec`
  # makes the subshell rclone itself.
  (
    if [ "${#OFFSITE_ENV[@]}" -gt 0 ]; then export "${OFFSITE_ENV[@]}"; fi
    exec rclone copy "$file" "$dest"
  ) <&0 7>&- 8>&- &
  track_child "$!" rclone
  wait_child
}

# Keep a connection-string remote's credentials out of rclone's argv (#2690),
# as KilnCMS.Backups.RcloneRemote does for the app. argv is world-readable in
# /proc/<pid>/cmdline and shown by `ps`; a copy runs for minutes.
#
# $1 = BACKUP_RCLONE_REMOTE. Sets OFFSITE_REMOTE (the remote to put in argv)
# and OFFSITE_ENV (`RCLONE_CONFIG_<NAME>_<KEY>=value` entries):
#   `:backend,k=v,…:path` → `kiln_offsite:path` + RCLONE_CONFIG_KILN_OFFSITE_TYPE=backend, …
#   `name,k=v,…:path`     → `name:path` + RCLONE_CONFIG_<NAME>_<KEY>=v, …
# A key without `=` is `true`; a value quoted with ' or " (a doubled quote
# standing for itself) may hold `,` and `:`. Anything else — `r2:kiln`, a
# local path, a name that cannot be a variable name, a string this does not
# parse — is left unchanged with no environment.
rclone_split_remote() {
  local remote="$1" rest name prefix key value q c
  local env_list=()
  OFFSITE_REMOTE="$remote"
  OFFSITE_ENV=()

  rest="$remote"
  [ "${rest:0:1}" = ":" ] && rest="${rest:1}"
  name="${rest%%[,:]*}"
  [ -n "$name" ] && [ "$name" != "$rest" ] || return 0
  rest="${rest:${#name}}"
  [ "${rest:0:1}" = "," ] || return 0
  rest="${rest:1}"
  [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || return 0

  if [ "${remote:0:1}" = ":" ]; then
    prefix="RCLONE_CONFIG_KILN_OFFSITE_"
    env_list+=("${prefix}TYPE=$name")
    name="kiln_offsite"
  else
    prefix="RCLONE_CONFIG_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_"
  fi

  while :; do
    key="${rest%%[=,:]*}"
    [ "$key" != "$rest" ] || return 0
    [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
    rest="${rest:${#key}}"
    if [ "${rest:0:1}" = "=" ]; then
      rest="${rest:1}"
      q="${rest:0:1}"
      if [ "$q" = '"' ] || [ "$q" = "'" ]; then
        rest="${rest:1}"
        value=""
        while :; do
          [ -n "$rest" ] || return 0
          c="${rest:0:1}"
          rest="${rest:1}"
          if [ "$c" != "$q" ]; then
            value+="$c"
          elif [ "${rest:0:1}" = "$q" ]; then
            value+="$q"
            rest="${rest:1}"
          else
            break
          fi
        done
      else
        value="${rest%%[,:]*}"
        [ "$value" != "$rest" ] || return 0
        rest="${rest:${#value}}"
      fi
    else
      value="true"
    fi
    env_list+=("${prefix}$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')=$value")
    c="${rest:0:1}"
    rest="${rest:1}"
    [ "$c" = ":" ] && break
    [ "$c" = "," ] || return 0
  done

  OFFSITE_REMOTE="${name}:${rest}"
  OFFSITE_ENV=("${env_list[@]}")
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
# A URI whose query carries `sslpassword` (the key decoded and compared
# case-sensitively, as libpq does) is refused the same way (#3049): libpq has
# no environment variable for a client key's passphrase, so it cannot be
# moved out of argv like the password.
pg_conn_split() {
  local url="$1" rest userinfo="" has_userinfo=0 host user="" pw="" has_pw=0
  local query="" has_query=0 q seg key val kept="" sep="" shown="" ssep=""
  local qpw="" has_qpw=0 has_sslpw=0
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
      if [ "$key" = "sslpassword" ]; then
        has_sslpw=1
      elif [ "$key" = "password" ]; then
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
  if [ "$has_sslpw" = 1 ]; then
    PG_CONN_URL=""
    PG_CONN_DISPLAY_URL=""
    PG_CONN_ERROR="carries sslpassword, the passphrase of an encrypted client key, which would sit in the command line of pg_dump, pg_restore and psql for every process on the host to read (libpq has no environment variable for it). Use a client key file that is not encrypted, readable only by its owner (chmod 0600), or decrypt the one you have (openssl pkey -in client.key -out client.key.plain), and drop sslpassword from the URL."
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

# $1 = file, $2 = recorded sha256, $3 = what it hashes to now (empty: missing
# or not a regular file). The failure manifest must not call it verified.
refuse_offsite() {
  local name pattern why
  name="$(basename "$1")"
  if [ -z "${2:-}" ]; then
    why="no sha256 was recorded for it"
  elif [ -z "${3:-}" ]; then
    why="it is missing or no longer a regular file (expected sha256 $2)"
  else
    why="its sha256 changed after this backup verified it (expected $2, found $3)"
  fi
  pattern="$(printf '%s' "$(basename "$(dirname "$1")")/${name}" | sed 's/[.[\*^$/]/\\&/g')"
  MANIFEST_ARTIFACTS="$(printf '%s' "$MANIFEST_ARTIFACTS" |
    sed "s/\(\"path\":\"${pattern}\",\"bytes\":[0-9]*,\"verified\":\)true/\1false/")"
  die "REFUSING off-site copy of ${name}: ${why}. Nothing was uploaded for it. Something other than this backup wrote to ${BACKUP_DIR}: check the disk before trusting this backup."
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

# Write a sidecar in `sha256sum -c` format, one `<hex>  <name>` line per file
# in the order given, mode 0600, via `<sidecar>.partial` + mv.
# $1 = sidecar path, then `<name> <hex>` pairs.
write_sidecar() {
  local sidecar="$1"
  shift
  track_partial "${sidecar}.partial"
  (
    umask 077
    : > "${sidecar}.partial"
    while [ "$#" -ge 2 ]; do
      printf '%s  %s\n' "$2" "$1" >> "${sidecar}.partial"
      shift 2
    done
  )
  chmod 600 "${sidecar}.partial"
  mv "${sidecar}.partial" "$sidecar"
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
#
# The temporary name is this run's own, `manifest.json.<pid>-<random>.partial`
# (#2832): a cron run and the in-app backup finishing together used to write
# through one `manifest.json.partial` and could publish a mix of the two, or
# fail a rename the other had already done. The PID alone is not unique (two
# containers sharing BACKUP_DIR count PIDs separately), hence the random half,
# and the file is created exclusively (noclobber) so a name already taken is
# never written through. The random half is $RANDOM + 100000 (100000-132767),
# above any attempt number, so it never takes the name of an app step's
# `manifest.json.<job>-<attempt>.partial`. The name has the app's tag shape
# (`<digits>-<digits>`), so a leftover is removed by the app's start sweep and
# by `prune` (prune_manifest_partials) once it is PARTIAL_GRACE_MIN old. Once
# renamed into place the name is no longer tracked: another writer may create
# it next, and on_exit must not remove that writer's file.
MANIFEST_ARTIFACTS=""

record_artifact() {
  # $1 = kind ("db"/"media"), $2 = absolute path to the verified artifact,
  # $3 = its sha256 (hex), and for a media part $4 = its 1-based index and
  # $5 = the number of parts in the set (one flat entry per part, as the app
  # writes them).
  local bytes
  bytes="$(wc -c < "$2" | tr -d ' ')"
  local entry
  entry="$(printf '{"kind":"%s","path":"%s/%s","bytes":%s,"verified":true,"sha256":"%s"' \
    "$1" "$1" "$(basename "$2")" "$bytes" "$3")"
  if [ -n "${4:-}" ]; then
    entry="${entry},\"part\":$4,\"parts_total\":$5"
  fi
  entry="${entry}}"

  if [ -n "$MANIFEST_ARTIFACTS" ]; then
    MANIFEST_ARTIFACTS="${MANIFEST_ARTIFACTS},${entry}"
  else
    MANIFEST_ARTIFACTS="$entry"
  fi
}

# Make text valid UTF-8: drop byte sequences that are not (tar's stderr can
# quote a Latin-1 file name). Jason rejects invalid UTF-8, and a manifest it
# rejects reads as "No backup has ever been recorded".
utf8_clean() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true
  else
    LC_ALL=C tr '\200-\377' '?'
  fi
}

# Escape a value for a JSON string: backslash, quote, and the control
# characters JSON forbids raw. A literal newline in an error message used to
# produce a manifest `Jason.decode` rejects — which the console renders as "No
# backup has ever been recorded", the single most misleading thing it can say,
# in response to a FAILED backup. Control characters other than tab and newline
# become `?` (an error can quote tar's stderr, and tar's stderr can quote a
# file name with anything in it).
json_escape() {
  printf '%s' "$1" | LC_ALL=C tr '\001-\010\013-\037' '?' | utf8_clean |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' |
    awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
}

write_manifest() {
  # $1 = "true"/"false" (did it succeed), $2 = error string (may be empty)
  local out="$BACKUP_DIR/manifest.json" tmp="" _
  local err="null"
  [ -n "${2:-}" ] && err="\"$(json_escape "$2")\""
  local offsite="null"
  # Escaped too: these are operator-supplied strings, and an unescaped quote
  # in either silently breaks the whole file. Only a run that succeeded names
  # the remote (#2218), as the app does: a failure manifest's `offsite` would
  # tell the importer that a refused or never-sent file is safely off-site.
  if [ "$1" = "true" ] && [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
    offsite="\"$(json_escape "$BACKUP_RCLONE_REMOTE")\""
  fi
  local trigger
  trigger="$(json_escape "${BACKUP_TRIGGER:-cron}")"

  mkdir -p "$BACKUP_DIR"
  # Created empty and exclusively first: only a file this run created is
  # tracked (and so removed by on_exit), never one another writer holds.
  for _ in 1 2 3 4 5; do
    tmp="${out}.$$-$((RANDOM + 100000)).partial"
    if [ ! -e "$tmp" ] && [ ! -L "$tmp" ] && (set -C && : > "$tmp") 2>/dev/null; then
      track_partial "$tmp"
      break
    fi
    tmp=""
  done
  [ -n "$tmp" ] || die "could not create a temporary manifest in $BACKUP_DIR"
  cat > "$tmp" <<JSON
{
  "version": 1,
  "stamp": "${STAMP}",
  "started_at": "${STARTED_AT}",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "trigger": "${trigger}",
  "ok": $1,
  "artifacts": [${MANIFEST_ARTIFACTS}],
  "offsite": ${offsite},
  "keep_days": ${KEEP_DAYS},
  "error": ${err}
}
JSON
  mv "$tmp" "$out"
  untrack_partial "$tmp"
}

# ONE exit trap for the whole script, installed once. It has to be one:
# `cmd_db` and `cmd_media` used to install their own `trap … EXIT` to clean up
# a `.partial`, which REPLACED any trap the caller had set and then cleared it
# outright with `trap - EXIT`. A failure-manifest trap set by `cmd_all` would
# therefore never have run — the exact silent-failure shape this file exists
# to prevent.
#
# Three jobs, in order: never leave a `.partial` behind (an unverified artifact
# must not survive to look like a backup), remove the finished parts of a media
# set that did not complete (cron cannot resume one, and the parts that did land
# would import as a clean, smaller set), and — for `all` only — record the
# failure, so the console stops showing the last SUCCESSFUL backup as though
# it answered the question.
#
# Only `all` writes a manifest, because only `all` is a backup: a hand-run
# `backup.sh db` would otherwise record "the last backup" as database-only.
on_exit() {
  local status=$?
  # A second signal must not cut the cleanup short: once a trap's `exit` runs
  # this, another TERM or INT would otherwise abort it halfway, leaving
  # `.partial` files and no failure manifest. Children started from here on
  # inherit the ignore, which is harmless: they are short. (A child stuck in
  # uninterruptible I/O can hold the cleanup; see stop_children.)
  trap '' HUP INT TERM
  # The script's own stdout and stderr, whatever call the trap interrupted
  # (see on_signal).
  exec 1>&7 2>&8
  umask "$ORIG_UMASK"

  # First, so nothing touches a file this trap is about to remove (the loop
  # only ever touches with -c, which never creates one).
  if [ -n "${HEARTBEAT_PID:-}" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi

  # Then the child, before its `.partial` is removed: a pg_dump or tar still
  # running would go on writing to the unlinked file (#2847).
  stop_children
  if [ -n "$CHILD_FILE" ]; then
    rm -f -- "$CHILD_FILE"
  fi

  # Only OUR OWN files, tracked as they are created — never a blanket
  # `find … -name '*.partial' -delete` or a glob on the stamp. Since #484 two
  # writers share $BACKUP_DIR, and a blanket sweep here would unlink the
  # in-progress dump of a concurrent in-app backup: pg_dump keeps writing to
  # the unlinked inode, exits 0, and its verification then fails with ENOENT —
  # a successful cron run reporting the app's run as failed.
  local f
  for f in ${OWN_PARTIALS[@]+"${OWN_PARTIALS[@]}"}; do
    [ -n "$f" ] && rm -f -- "$f"
  done

  if [ "$status" -ne 0 ]; then
    for f in ${SET_FILES[@]+"${SET_FILES[@]}"}; do
      [ -n "$f" ] && rm -f -- "$f"
    done
  fi

  if [ -n "${WORK_DIR:-}" ]; then
    rm -rf -- "$WORK_DIR"
  fi
  if [ -n "${PG_DUMP_ERRORS:-}" ]; then
    rm -f -- "$PG_DUMP_ERRORS"
  fi

  if [ "$status" -ne 0 ] && [ "${WRITE_MANIFEST:-0}" = "1" ]; then
    # `die` sets LAST_ERROR; a command that failed under `set -e` (pg_dump,
    # tar, rclone) never reaches it, so fall back to the exit status rather
    # than recording an empty reason.
    write_manifest false "${LAST_ERROR:-backup.sh exited ${status} - see the backup log}"
  fi

  # Last: this run's stamp claim (claim_stamp), success or failure. Only the
  # directory this run made, and rmdir, which never removes anything inside.
  if [ -n "$CLAIM_DIR" ]; then
    rmdir -- "$CLAIM_DIR" 2>/dev/null || true
  fi
}

# The operator's umask; the media phase narrows it to 077 for its own files.
ORIG_UMASK="$(umask)"
# Every `.partial` this run creates, so on_exit removes exactly those.
OWN_PARTIALS=()
# The finished parts of the media set being built; removed by on_exit if the
# run fails before the set's sidecar is in place, emptied once it is.
SET_FILES=()
# Scratch directory for the media file lists (set by cmd_media).
WORK_DIR=""
# pg_dump's captured stderr while it runs (set by cmd_db).
PG_DUMP_ERRORS=""

track_partial() {
  OWN_PARTIALS+=("$1")
}

# Forget $1 (blank its entry; on_exit skips blanks): it is no longer this
# run's, and another writer may now hold the name.
untrack_partial() {
  local i
  for i in ${OWN_PARTIALS[@]+"${!OWN_PARTIALS[@]}"}; do
    if [ "${OWN_PARTIALS[$i]}" = "$1" ]; then OWN_PARTIALS[i]=""; fi
  done
}

# Run a long command as a background child and wait for it, so that a trapped
# signal interrupts the wait at once and on_exit can stop the child, and so
# that the heartbeat knows which process to stop if this script is killed
# outright (#2847). `"$@" &` forks once and execs the program, so `$!` is the
# program itself. Its status, redirections and stdin (`<&0`: a non-interactive
# shell would give it /dev/null, and rclone may prompt for a config password)
# are the foreground command's; under `set -e` a failure ends the run as
# before. It does not get fds 7 and 8 (on_signal's copies of the script's
# stdout and stderr): an orphan, or anything it starts, must not hold the
# caller's pipe open. A command that needs its own environment runs as
# `( export …; exec prog … ) <&0 7>&- 8>&- & track_child "$!" prog;
# wait_child`, the `exec` again making `$!` the program.
run_child() {
  "$@" <&0 7>&- 8>&- &
  track_child "$!" "${1##*/}"
  wait_child
}

# Record child $1 running program $2: CHILD_PID for on_exit, and
# `<pid> <program>` in CHILD_FILE for the heartbeat, which only sees variables
# set before it forked. Writing the file is best-effort: a full TMPDIR must
# not fail the backup, it only leaves the heartbeat nothing to stop. Only an
# existing regular file is written: a heartbeat that gave up has removed it,
# and recreating the name in a shared TMPDIR could write through a symlink
# planted there since.
track_child() {
  CHILD_PID="$1"
  if child_file_ok; then
    { printf '%s %s\n' "$1" "$2" > "$CHILD_FILE"; } 2>/dev/null || true
  fi
}

# Wait for the tracked child; returns its status.
wait_child() {
  local rc=0
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  if child_file_ok; then
    { : > "$CHILD_FILE"; } 2>/dev/null || true
  fi
  return "$rc"
}

# Whether CHILD_FILE is set and still the regular file mktemp created.
child_file_ok() {
  [ -n "$CHILD_FILE" ] && [ -f "$CHILD_FILE" ] && [ ! -L "$CHILD_FILE" ]
}

# Stop every child this script has not waited for (on_exit): the tracked one,
# and as a backstop any other, such as a child forked just before a signal
# arrived and not yet tracked. They are what running_children lists: bash's
# own record of its children still running or stopped, so a child that has
# ended (whose PID may already belong to another process) is never signaled.
# The heartbeat is disowned, so it is not among them. CONT first, so a stopped
# child (kill -STOP, a SIGTSTP) acts on the TERM; TERM so rclone can abort its
# uploads and pg_dump close its connection; whatever still runs after about 5
# seconds gets KILL. Then each is reaped (the `2>/dev/null` keeps bash's
# "Terminated" notice out of the log).
#
# A child stuck in uninterruptible I/O (a hung NFS mount) ignores TERM and
# KILL alike until the I/O returns; the reaping `wait` then holds on_exit,
# which ignores further signals, until it does. Only a SIGKILL of the script
# itself ends that; the heartbeat then stops the child once it can.
stop_children() {
  local pids p deadline
  pids="$(running_children)"
  CHILD_PID=""
  [ -n "$pids" ] || return 0
  for p in $pids; do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ] && [ -n "$(running_children)" ]; do
    sleep 0.1 2>/dev/null || sleep 1
  done
  for p in $(running_children); do
    kill -KILL "$p" 2>/dev/null || true
  done
  for p in $pids; do
    wait "$p" 2>/dev/null || true
  done
}

# The PIDs of this script's background children still running or stopped,
# one per line. Not `jobs -p`, which also lists a child that has ended and not
# yet been reported. Without job control (a script) bash does not see a child
# stop and lists it under -r; -s covers a run with `set -m`.
running_children() {
  jobs -rp 2>/dev/null || true
  jobs -sp 2>/dev/null || true
}

# A signal must still run on_exit (bash runs the EXIT trap on `exit`, not when
# a signal kills it). The long-running children run in the background under
# `wait` (run_child), which a trapped signal interrupts at once, so HUP, INT
# and TERM stop the run without waiting for a dump or an upload to finish:
# on_exit stops the child, then cleans up. A shell defers a trap only while a
# FOREGROUND child runs; the short helpers still run that way.
#
# A background child of a script ignores INT and QUIT (bash does that when job
# control is off), so a Ctrl-C at a terminal reaches it only through on_exit's
# TERM, not straight from the terminal.
#
# The trap can now run inside a call with its own redirections (archive_part's
# `run_child tar … 2>> "$err"`), so it writes to the script's own stdout and
# stderr, which install_traps keeps open as fds 7 and 8.
on_signal() {
  LAST_ERROR="interrupted by SIG$1"
  echo "error: ${LAST_ERROR}" >&8
  exit "$2"
}

install_traps() {
  exec 7>&1 8>&2
  trap on_exit EXIT
  trap 'on_signal HUP 129' HUP
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
}

# Whether the heartbeat loop is still a child of this script ($1 = the
# script's PID, $2 = 1 when `ps -o ppid= -p` works here): 0 when it is, 1 when
# it definitely is not, 2 when it can't tell. After a SIGKILL the loop is
# re-parented, and the script's PID may be reused by another process, so
# `kill -0` alone could keep a killed run's partials fresh for ever. "Definitely
# not" is `kill -0` failing, or `ps` answering with another parent; a `ps` that
# fails says nothing, and the heartbeat stops a child only on a definite
# answer (#2847).
#
# The loop's own PID: bash 3.2 has no $BASHPID, and a subshell's $$ is the
# script's. `exec` makes sh replace the command substitution's process, so its
# $PPID is the loop itself; without the `exec`, bash 3.2 forks once more and
# this prints a PID that is gone. Keep the form exactly as it is.
#
# Without a usable `ps` (busybox without procps) only `kill -0` is left.
parent_state() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$2" = 1 ] || return 0
  local me parent
  me="$(exec sh -c 'echo "$PPID"')" || return 2
  parent="$(ps -o ppid= -p "$me" 2>/dev/null)" || return 2
  # ps pads the number with spaces.
  parent="${parent//[!0-9]/}"
  [ -n "$parent" ] || return 2
  [ "$parent" = "$1" ] || return 1
}

# Whether process $1 still runs program $2 ($3 = 1 when `ps` works here): 0
# when it does, 1 when it does not or is gone, 2 when nothing here can tell.
# The guard against a PID reused after the child ended: the first word of the
# command line, as a base name, must be the program; or the second, when the
# first is an interpreter running it as a script (Debian's pg_dump is a Perl
# wrapper until it execs the real one). Whole words only, so `tar` never
# matches `start`. The command line comes from `ps`, else from
# /proc/<pid>/cmdline (busybox `ps` has no `-p`).
child_runs() {
  local pid="$1" name="$2" args="" first="" second="" rest=""
  if [ "$3" = 1 ] && args="$(ps -o args= -p "$pid" 2>/dev/null)"; then
    :
  elif [ -r "/proc/$pid/cmdline" ]; then
    args="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || return 1
  elif [ "$3" = 1 ]; then
    # ps works here and does not list it.
    return 1
  elif kill -0 "$pid" 2>/dev/null; then
    return 2
  else
    return 1
  fi
  read -r first second rest <<<"$args" || true
  first="${first##*/}"
  second="${second##*/}"
  [ -n "$first" ] || return 1
  [ "$first" = "$name" ] && return 0
  case "$first" in
    sh | bash | dash | ash | ksh | zsh | perl* | python*) [ "$second" = "$name" ] ;;
    *) return 1 ;;
  esac
}

# The parent PID of process $1 ($2 = 1 when `ps` works here), from `ps`, else
# from /proc/<pid>/stat; fails when neither answers. In stat the parent is the
# second field after the command name, which is in parentheses and may itself
# hold spaces and parentheses, so the line is read from after its LAST `)`.
ppid_of() {
  local out="" stat=""
  if [ "$2" = 1 ] && out="$(ps -o ppid= -p "$1" 2>/dev/null)"; then
    :
  elif [ -r "/proc/$1/stat" ] && stat="$(cat -- "/proc/$1/stat" 2>/dev/null)"; then
    read -r _ out _ <<<"${stat##*)}" || true
  fi
  # ps pads the number with spaces.
  out="${out//[!0-9]/}"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Whether process $1 has the heartbeat's own parent ($2 = 1 when `ps` works
# here): 0 when it does, or when either parent can't be read; 1 when they
# differ. After the script dies its child and the heartbeat are both
# re-parented to the same reaper (init, or the nearest subreaper), so the
# real orphan passes. A PID reused within the up-to-HEARTBEAT_S window by
# another pg_dump, tar or rclone, which the name guard alone would pass, has
# the parent that started it, still alive, and fails.
shares_my_parent() {
  local me mine theirs
  me="$(exec sh -c 'echo "$PPID"')" || return 0
  mine="$(ppid_of "$me" "$2")" || return 0
  theirs="$(ppid_of "$1" "$2")" || return 0
  [ "$theirs" = "$mine" ]
}

# The heartbeat's last job once the script is definitely gone ($1 = 1 when
# `ps` works here): stop the child CHILD_FILE names, if it still runs that
# program (child_runs) and is an orphan beside the heartbeat
# (shares_my_parent). A line that is empty, torn (no program) or not a PID
# above 1 stops nothing. TERM first, as on_exit does; KILL if it still runs
# that program five sleeps later. Where neither `ps` nor /proc can name a
# process or its parent, the PID alone decides.
stop_orphan() {
  local pid="" name="" rest="" n=0 state=0
  [ -n "$CHILD_FILE" ] || return 0
  read -r pid name rest < "$CHILD_FILE" 2>/dev/null || true
  rm -f -- "$CHILD_FILE"
  case "$pid" in
    "" | *[!0-9]* | 0*) return 0 ;;
  esac
  [ "$pid" -gt 1 ] && [ -n "$name" ] || return 0
  child_runs "$pid" "$name" "$1" || state=$?
  [ "$state" != 1 ] || return 0
  shares_my_parent "$pid" "$1" || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  while [ "$n" -lt 5 ]; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || return 0
    n=$((n + 1))
  done
  state=0
  child_runs "$pid" "$name" "$1" || state=$?
  [ "$state" != 1 ] || return 0
  shares_my_parent "$pid" "$1" || return 0
  kill -KILL "$pid" 2>/dev/null || true
}

# The heartbeat (see HEARTBEAT_S): touch every `.partial` of this stamp, both
# kinds, until this script exits. It globs on each pass rather than reading
# OWN_PARTIALS, whose copy in the subshell is frozen at the fork. Its stdio is
# /dev/null, so it never holds open the pipe cron (or a caller) reads the
# script's output from. on_exit stops it with TERM; the trap stops its sleep
# too, so no `sleep` outlives the script. `disown`: the shell reports nothing
# when it ends.
#
# When the script is definitely gone (parent_state; killed outright, so no
# trap ran), the loop stops the script's child before it exits (stop_orphan,
# #2847): run_child names it in CHILD_FILE, created here before the fork so
# both sides know the path. While `ps` can't answer the loop goes on touching;
# after three such answers in a row it removes CHILD_FILE and stops without
# stopping anything, as it always did when `ps` failed.
start_heartbeat() {
  local parent="$$" use_ps=0
  if ps -o ppid= -p "$$" >/dev/null 2>&1; then use_ps=1; fi
  if ! CHILD_FILE="$(mktemp "${TMPDIR:-/tmp}/kiln-backup-child.XXXXXX" 2>/dev/null)"; then
    CHILD_FILE=""
    warn "could not create a file in ${TMPDIR:-/tmp}: a child of this run would outlive a kill -9"
  fi
  (
    trap - EXIT HUP INT
    sleeper=""
    trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null || true; fi; exit 0' TERM
    unknown=0
    while :; do
      state=0
      parent_state "$parent" "$use_ps" || state=$?
      if [ "$state" = 1 ]; then
        stop_orphan "$use_ps"
        break
      elif [ "$state" = 2 ]; then
        unknown=$((unknown + 1))
        if [ "$unknown" -ge 3 ]; then
          if [ -n "$CHILD_FILE" ]; then rm -f -- "$CHILD_FILE"; fi
          break
        fi
      else
        unknown=0
      fi
      for f in "$BACKUP_DIR"/db/kiln-db-"$STAMP".*.partial \
        "$BACKUP_DIR"/media/kiln-media-"$STAMP".*.partial; do
        if [ -f "$f" ]; then touch -c -- "$f" 2>/dev/null || true; fi
      done
      sleep "$HEARTBEAT_S" &
      sleeper=$!
      wait "$sleeper" || true
      sleeper=""
    done
  ) </dev/null >/dev/null 2>&1 7>&- 8>&- &
  HEARTBEAT_PID=$!
  disown "$HEARTBEAT_PID" 2>/dev/null || true
}

# --- free space (mirror KilnCMS.Backups.Preflight, #2423) ------------------

# Added to every estimate, after 10% of it: the app's default
# `free_space_margin_bytes` (256 MB).
FREE_SPACE_MARGIN_BYTES=$((256 * 1048576))
# Set once by read_free_space_check, so `all` warns about a bad value once.
FREE_SPACE_CHECK=""

# FREE_SPACE_CHECK (1 or 0) from BACKUP_FREE_SPACE_CHECK, read like the app's
# Env.flag/2: blank is on; true/1/yes/on and false/0/no/off in any case;
# anything else keeps the check on and warns.
read_free_space_check() {
  [ -z "$FREE_SPACE_CHECK" ] || return 0
  local raw="${BACKUP_FREE_SPACE_CHECK:-}" t
  t="$(trim_ws "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$t" in
    '' | true | 1 | yes | on) FREE_SPACE_CHECK=1 ;;
    false | 0 | no | off) FREE_SPACE_CHECK=0 ;;
    *)
      warn "BACKUP_FREE_SPACE_CHECK=${raw} is not true or false; keeping the free-space check on"
      FREE_SPACE_CHECK=1
      ;;
  esac
}

# $1 = bytes, $2 = down or up. Prints them as Preflight.human/2 does: KB
# below 1 MB, whole MB below 1 GB, GB to a tenth from there, rounded down
# (what is free) or up (what is needed).
human_bytes() {
  local b="$1" add=0 unit
  if [ "$b" -lt 1048576 ]; then
    unit=1024
    [ "$2" = down ] || add=$((unit - 1))
    printf '%s KB' "$(((b + add) / unit))"
  elif [ "$b" -lt 1073741824 ]; then
    unit=1048576
    [ "$2" = down ] || add=$((unit - 1))
    printf '%s MB' "$(((b + add) / unit))"
  else
    local tenths
    [ "$2" = down ] || add=$((1073741824 - 1))
    tenths=$(((b * 10 + add) / 1073741824))
    printf '%s.%s GB' "$((tenths / 10))" "$((tenths % 10))"
  fi
}

# $1 = what is about to be written ("database dump", "media archive"),
# $2 = the directory it goes to, $3 = its estimated size in bytes. Fails the
# run, before anything is written, when the free space there is below the
# estimate plus 10% plus the margin, in the app's words. A `df` that fails or
# prints something unexpected is warned about and the run goes ahead, as the
# app does: an unknown is not a reason to stop every backup.
#
# Compared in KB, as df reports it: a file system that says it has 16 EiB
# free (s3fs) overflows bash's 64-bit arithmetic in bytes.
check_free_space() {
  local what="$1" dir="$2" estimate="$3" needed needed_kb avail
  read_free_space_check
  [ "$FREE_SPACE_CHECK" = 1 ] || return 0
  needed=$((estimate * 11 / 10 + FREE_SPACE_MARGIN_BYTES))
  needed_kb=$(((needed + 1023) / 1024))
  # POSIX output (-P), one line per file system. Available is the field two
  # before the capacity (`NN%`) that follows three whole numbers, not the 4th
  # field: a file system name may hold a space (`//host/Share Name`). A
  # negative available (BSD's reserve, overdrawn) reads as none.
  avail="$(df -Pk "$dir" 2>/dev/null | awk '
    NR == 2 {
      for (i = 4; i <= NF; i++) {
        if ($i ~ /^[0-9]+%$/ && $(i-3) ~ /^[0-9]+$/ && $(i-2) ~ /^[0-9]+$/ && $(i-1) ~ /^-?[0-9]+$/) {
          print $(i-1)
          exit
        }
      }
    }')" || avail=""
  case "$avail" in
    -[0-9]*) avail=0 ;;
    '' | *[!0-9]*)
      warn "could not read the free space in ${dir}; going ahead without the free-space check"
      return 0
      ;;
  esac
  # Strip leading zeros so the number is not read as octal; 0 stays 0.
  avail="${avail#"${avail%%[!0]*}"}"
  avail="${avail:-0}"
  if [ "$avail" -lt "$needed_kb" ]; then
    die "Not enough free space for the ${what} in ${dir}: $(human_bytes "$((avail * 1024))" down) free, about $(human_bytes "$needed" up) needed. Free up space there, or point BACKUP_DIR at a larger disk (BACKUP_FREE_SPACE_CHECK=false skips this check)"
  fi
}

# The dump estimate, as Preflight.dump_estimate/2: the size of the regular
# file kiln-db-<YYYYMMDD-HHMMSS>.dump in $BACKUP_DIR/db with the newest stamp
# earlier than this run's. A name without a stamp (kiln-db-manual.dump) or
# stamped later is passed over. Stamps sort by time, and so does the glob.
# 0 when there is none.
dump_estimate() {
  local f name stamp newest=""
  local d='[0-9]'
  for f in "$BACKUP_DIR"/db/kiln-db-*.dump; do
    name="${f##*/}"
    # shellcheck disable=SC2254 # the pattern is meant to glob
    case "$name" in
      kiln-db-$d$d$d$d$d$d$d$d-$d$d$d$d$d$d.dump) ;;
      *) continue ;;
    esac
    stamp="${name#kiln-db-}"
    stamp="${stamp%.dump}"
    if [[ "$stamp" < "$STAMP" ]] && [ -f "$f" ] && [ ! -L "$f" ]; then newest="$f"; fi
  done
  if [ -n "$newest" ]; then
    wc -c < "$newest" | tr -d ' '
  else
    echo 0
  fi
}

cmd_db() {
  require DATABASE_URL
  pg_conn_split "$DATABASE_URL"
  [ -z "$PG_CONN_ERROR" ] || die "DATABASE_URL $PG_CONN_ERROR"
  read_lock_wait
  mkdir -p "$BACKUP_DIR/db"
  check_free_space "database dump" "$BACKUP_DIR/db" "$(dump_estimate)"
  local out="$BACKUP_DIR/db/kiln-db-${STAMP}.dump" status=0 errors

  track_partial "${out}.partial"
  echo "==> pg_dump → ${out}"
  # Custom format (-Fc): compressed, restorable table-by-table with pg_restore.
  # --no-owner/--no-privileges matches scripts/staging.sh: restores don't
  # depend on the production role existing on the target.
  # Dump to a .partial name and rename only after verification, so an aborted
  # or unverified dump can never be picked up as a backup.
  # The password reaches pg_dump through PGPASSWORD only: `export` is a
  # builtin, and the subshell keeps it from every other command (#2726).
  # --lock-wait-timeout: a dump behind a migration's or VACUUM FULL's lock
  # gives up instead of waiting for as long as it is held (#2844).
  # stderr goes to a file first so a failure manifest can say why (under
  # `set -e` the run would otherwise record only its exit status); it is
  # copied to stderr either way.
  # A tracked child (run_child), so it dies with the script (#2847); `exec`
  # makes the subshell pg_dump itself.
  PG_DUMP_ERRORS="$(mktemp "${TMPDIR:-/tmp}/kiln-pg_dump.XXXXXX")"
  (
    if [ "$PG_CONN_HAS_PASSWORD" = 1 ]; then export PGPASSWORD="$PG_CONN_PASSWORD"; fi
    exec pg_dump --format=custom --no-owner --no-privileges \
      --lock-wait-timeout="$LOCK_WAIT_MS" \
      --file="${out}.partial" "$PG_CONN_URL"
  ) <&0 2>"$PG_DUMP_ERRORS" 7>&- 8>&- &
  track_child "$!" pg_dump
  wait_child || status=$?
  cat -- "$PG_DUMP_ERRORS" >&2
  errors="$(tail -n 5 -- "$PG_DUMP_ERRORS")"
  rm -f -- "$PG_DUMP_ERRORS"
  PG_DUMP_ERRORS=""
  [ "$status" -eq 0 ] || die "$(pg_dump_failure "$status" "$errors")"

  echo "==> Verifying dump (pg_restore --list)"
  run_child pg_restore --list "${out}.partial" >/dev/null ||
    die "dump failed verification and was removed — this backup did NOT succeed"
  mv "${out}.partial" "$out"

  echo "    ok: $(du -h "$out" | cut -f1) $(basename "$out")"
  local sha sidecar_sha sidecar="$BACKUP_DIR/db/kiln-db-${STAMP}.sha256"
  sha="$(sha256_of "$out")"
  write_sidecar "$sidecar" "$(basename "$out")" "$sha"
  sidecar_sha="$(sha256_of "$sidecar")"
  record_artifact db "$out" "$sha"
  offsite "$out" "$sha"
  offsite "$sidecar" "$sidecar_sha"
}

# $1 = pg_dump's exit status, $2 = the last lines of its stderr. Prints the
# reason for the failure manifest: pg_dump's own words, the URL's password
# removed wherever it appears literally, cut to 500 characters (the app's
# Importer scrubs the text again). pg_dump reports its lock-wait timeout as a
# statement timeout on `LOCK TABLE`, which reads as nothing to do with locks;
# that one is said in plain words, as the app does.
pg_dump_failure() {
  local status="$1" text="$2" msg
  # Only a password of 6 or more characters, as KilnCMS.Backups.Redact does:
  # a shorter one would turn every occurrence of its letters into `***` and
  # garble the message.
  if [ "${#PG_CONN_PASSWORD}" -ge 6 ]; then text="${text//"$PG_CONN_PASSWORD"/***}"; fi
  text="${text//$'\n'/ / }"
  case "$text" in
    *[Ss][Tt][Aa][Tt][Ee][Mm][Ee][Nn][Tt]\ [Tt][Ii][Mm][Ee][Oo][Uu][Tt]*"LOCK TABLE"*)
      msg="pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS (${LOCK_WAIT_S} s) for a table lock and gave up: another session held a conflicting lock (a migration, VACUUM FULL, a long transaction). pg_dump said: ${text}"
      ;;
    *) msg="pg_dump exited ${status}: ${text}" ;;
  esac
  printf '%s' "${msg:0:500}"
}

# --- media settings (mirror config/runtime/prod/backups.exs) ---------------

# Trim what Elixir's String.trim/1 trims, from both ends: ASCII whitespace and
# the UTF-8 encodings of U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028,
# U+2029, U+202F, U+205F and U+3000. Byte-wise (LC_ALL=C), so a name in any
# encoding passes through unchanged. Prints the result.
trim_ws() (
  # shellcheck disable=SC2030 # the C locale is meant for this subshell only
  export LC_ALL=C
  local s="$1" seq changed=1
  local -a seqs
  seqs=(' ' $'\t' $'\n' $'\v' $'\f' $'\r' $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80'
    $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84'
    $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89'
    $'\xe2\x80\x8a' $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f'
    $'\xe3\x80\x80')
  while [ "$changed" = 1 ]; do
    changed=0
    for seq in "${seqs[@]}"; do
      if [ "${s#"$seq"}" != "$s" ]; then
        s="${s#"$seq"}"
        changed=1
      fi
      if [ "${s%"$seq"}" != "$s" ]; then
        s="${s%"$seq"}"
        changed=1
      fi
    done
  done
  printf '%s' "$s"
)

# MEDIA_PART_BYTES from BACKUP_MEDIA_PART_MB, read like Env.integer_in/3 with
# 16..10240: blank is the default (400) silently; a whole number in range (an
# optional `+`, leading zeros allowed) is used; anything else keeps 400 and
# warns. Never clamped.
read_media_part_bytes() {
  local raw="${BACKUP_MEDIA_PART_MB:-}" t digits mb=""
  t="$(trim_ws "$raw")"
  if [ -n "$t" ]; then
    if [[ "$t" =~ ^\+?[0-9]+$ ]]; then
      digits="${t#+}"
      while [ "${#digits}" -gt 1 ] && [ "${digits#0}" != "$digits" ]; do
        digits="${digits#0}"
      done
      if [ "${#digits}" -le 6 ] && [ "$((10#$digits))" -ge 16 ] && [ "$((10#$digits))" -le 10240 ]; then
        mb="$((10#$digits))"
      fi
    fi
    if [ -z "$mb" ]; then
      warn "BACKUP_MEDIA_PART_MB=${raw} is not a whole number from 16 to 10240; using 400"
    fi
  fi
  MEDIA_PART_MB="${mb:-400}"
  MEDIA_PART_BYTES=$((MEDIA_PART_MB * 1048576))
}

# KEEP_DAYS from BACKUP_KEEP_DAYS, read like Env.positive_integer/1 (what
# config/runtime/prod/backups.exs reads it with): blank is the default (14)
# silently; a whole number from 1 to 2147483647 (an optional `+`, leading
# zeros allowed) is used, written back without its zeros so the manifest holds
# a valid JSON number; anything else keeps 14 and warns. `0` is not "keep
# nothing", and `14d` is not 14: guessing either would delete backups or keep
# them forever (#2727).
read_keep_days() {
  local raw="${BACKUP_KEEP_DAYS:-}" t digits days=""
  t="$(trim_ws "$raw")"
  if [ -n "$t" ]; then
    if [[ "$t" =~ ^\+?[0-9]+$ ]]; then
      digits="${t#+}"
      while [ "${#digits}" -gt 1 ] && [ "${digits#0}" != "$digits" ]; do
        digits="${digits#0}"
      done
      if [ "${#digits}" -le 10 ] && [ "$((10#$digits))" -ge 1 ] && [ "$((10#$digits))" -le 2147483647 ]; then
        days="$((10#$digits))"
      fi
    fi
    if [ -z "$days" ]; then
      warn "BACKUP_KEEP_DAYS=${raw} is not a whole number of days from 1 to 2147483647; using 14"
    fi
  fi
  KEEP_DAYS="${days:-14}"
}

# LOCK_WAIT_S and LOCK_WAIT_MS from BACKUP_LOCK_WAIT_SECONDS, read like
# Env.integer_in/3 with 1..3600 (config/runtime/prod/backups.exs): blank is
# the default (600) silently; a whole number in range (an optional `+`,
# leading zeros allowed) is used; anything else keeps 600 and warns. `0` is
# not "no limit": pg_dump would read it as waiting forever (#2844).
read_lock_wait() {
  local raw="${BACKUP_LOCK_WAIT_SECONDS:-}" t digits seconds=""
  t="$(trim_ws "$raw")"
  if [ -n "$t" ]; then
    if [[ "$t" =~ ^\+?[0-9]+$ ]]; then
      digits="${t#+}"
      while [ "${#digits}" -gt 1 ] && [ "${digits#0}" != "$digits" ]; do
        digits="${digits#0}"
      done
      if [ "${#digits}" -le 4 ] && [ "$((10#$digits))" -ge 1 ] && [ "$((10#$digits))" -le 3600 ]; then
        seconds="$((10#$digits))"
      fi
    fi
    if [ -z "$seconds" ]; then
      warn "BACKUP_LOCK_WAIT_SECONDS=${raw} is not a whole number of seconds from 1 to 3600; using 600"
    fi
  fi
  LOCK_WAIT_S="${seconds:-600}"
  LOCK_WAIT_MS=$((LOCK_WAIT_S * 1000))
}

# One BACKUP_MEDIA_EXCLUDE glob as an anchored POSIX ERE, the translation the
# app's MediaArchive.glob_source/1 makes: leading `./` (repeated) dropped,
# `**/` → `(.*/)?`, `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]` (one BYTE, as in
# the app), everything else literal. Byte-wise (LC_ALL=C).
glob_to_ere() (
  # shellcheck disable=SC2030,SC2031 # the C locale is meant for this subshell only
  export LC_ALL=C
  local g="$1" out="" c
  while [ "${g#./}" != "$g" ]; do
    g="${g#./}"
  done
  while [ -n "$g" ]; do
    case "$g" in
      '**/'*) out="${out}(.*/)?" g="${g:3}" ;;
      '**'*) out="${out}.*" g="${g:2}" ;;
      '*'*) out="${out}[^/]*" g="${g:1}" ;;
      '?'*) out="${out}[^/]" g="${g:1}" ;;
      *)
        c="${g:0:1}"
        g="${g:1}"
        case "$c" in
          '.' | '[' | \\ | '(' | ')' | '+' | '{' | '|' | '^' | '$') out="${out}\\${c}" ;;
          ']') out="${out}[]]" ;;
          '}') out="${out}[}]" ;;
          *) out="${out}${c}" ;;
        esac
        ;;
    esac
  done
  printf '^%s$' "$out"
)

# EXCL_RE / EXCL_SLASH from BACKUP_MEDIA_EXCLUDE, split and trimmed as the
# app's config does. A pattern containing `/` (checked before `./` is dropped)
# is matched against the path relative to MEDIA_DIR, any other against the
# entry's own name.
EXCL_RE=()
EXCL_SLASH=()
read_media_excludes() {
  local rest="${BACKUP_MEDIA_EXCLUDE:-}" item glob re
  [ -n "$rest" ] || return 0
  rest="${rest},"
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    rest="${rest#*,}"
    glob="$(trim_ws "$item")"
    [ -n "$glob" ] || continue
    re="$(glob_to_ere "$glob")"
    # A translation is literal by construction; a regex the C library still
    # refuses (status 2) must stop the run, not silently exclude nothing.
    local rc=0
    # shellcheck disable=SC2030,SC2031 # the C locale is meant for this subshell only
    (export LC_ALL=C && [[ "" =~ $re ]]) || rc=$?
    [ "$rc" -ne 2 ] || die "BACKUP_MEDIA_EXCLUDE pattern could not be compiled: ${glob}"
    EXCL_RE+=("$re")
    case "$glob" in
      */*) EXCL_SLASH+=(1) ;;
      *) EXCL_SLASH+=(0) ;;
    esac
  done
}

# --- media planning (mirror KilnCMS.Backups.MediaArchive.plan/3) -----------

# Whether a media entry is excluded. $1 = path relative to MEDIA_DIR, $2 = name.
is_excluded() {
  local i=0 n="${#EXCL_RE[@]}" re
  while [ "$i" -lt "$n" ]; do
    re="${EXCL_RE[$i]}"
    if [ "${EXCL_SLASH[$i]}" = 1 ]; then
      if [[ "$1" =~ $re ]]; then return 0; fi
    else
      if [[ "$2" =~ $re ]]; then return 0; fi
    fi
    i=$((i + 1))
  done
  return 1
}

# Walk one directory, pre-order like the app: its regular files and symlinks
# in byte order, each written to fd 3 as `./<rel>` + NUL, then its
# subdirectories in byte order. Excluded entries (a directory whole) are
# counted, never listed. Sockets and devices are skipped; so is a directory
# that vanished since its parent was listed. One that exists but cannot be
# listed fails the walk, and so does one that can be listed but not entered
# (no execute permission: none of its files could be read), in the words the
# app uses (MediaArchive.describe_not_enterable/1, #2477).
# $1 = path relative to MEDIA_DIR ("" for the root).
walk_dir() {
  local rel="$1" abs entry name child d
  local -a entries dirs
  dirs=()
  if [ -z "$rel" ]; then abs="$MEDIA_DIR"; else abs="$MEDIA_DIR/$rel"; fi

  if [ ! -e "$abs" ] && [ ! -L "$abs" ]; then
    return 0
  fi
  if [ ! -d "$abs" ] || [ ! -r "$abs" ]; then
    echo "cannot list ${abs}" >&2
    exit 1
  fi
  if [ ! -x "$abs" ]; then
    # Quoted as the app's `inspect` quotes it: `\` and `"` escaped. A newline
    # or a byte that is not UTF-8 in the name can still print differently.
    name="$(printf '%s' "${rel:-.}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    echo "media folder \"${name}\" can be listed but not entered (no execute permission): fix its permissions, or leave it out with BACKUP_MEDIA_EXCLUDE" >&2
    exit 1
  fi

  entries=("$abs"/*)
  for entry in ${entries[@]+"${entries[@]}"}; do
    name="${entry##*/}"
    if [ "$name" = "." ] || [ "$name" = ".." ]; then continue; fi
    if [ -z "$rel" ]; then child="$name"; else child="$rel/$name"; fi

    if [ "${#EXCL_RE[@]}" -gt 0 ] && is_excluded "$child" "$name"; then
      WALK_EXCLUDED=$((WALK_EXCLUDED + 1))
    elif [ -L "$entry" ] || [ -f "$entry" ]; then
      # A failed write (TMPDIR full) must stop the run, never truncate the list.
      printf './%s\0' "$child" >&3 || exit 1
      WALK_FILES=$((WALK_FILES + 1))
    elif [ -d "$entry" ]; then
      dirs+=("$child")
    fi
  done

  for d in ${dirs[@]+"${dirs[@]}"}; do
    walk_dir "$d"
  done
}

# List MEDIA_DIR into $WORK_DIR/walk.list (NUL-separated `./rel`). Runs in a
# subshell with the C locale so names sort, and globs match, byte by byte —
# Elixir's Enum.sort on binaries — and with every globbing option pinned.
# Sets PLAN_FILES and PLAN_EXCLUDED.
walk_media() {
  local rc
  # Not `( … ) || rc=$?`: on the left of `||` bash ignores `set -e` inside the
  # subshell, and a failed write would leave a short list that looks complete.
  set +e
  (
    set -e
    # shellcheck disable=SC2031 # the C locale is meant for this subshell only
    export LC_ALL=C
    unset GLOBIGNORE GLOBSORT
    set +f
    shopt -s dotglob nullglob
    shopt -u nocaseglob nocasematch
    shopt -u failglob 2>/dev/null || true
    WALK_FILES=0
    WALK_EXCLUDED=0
    walk_dir ""
    printf '%s %s\n' "$WALK_FILES" "$WALK_EXCLUDED" > "$WORK_DIR/walk.counts" || exit 1
  ) 3> "$WORK_DIR/walk.list" 2> "$WORK_DIR/walk.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    # A folder that can't be entered is named in the app's words, unprefixed.
    if grep -q '^media folder ' "$WORK_DIR/walk.err"; then
      die "$(head -c 1000 "$WORK_DIR/walk.err")"
    fi
    die "could not list the media directory: $(tail -c 500 "$WORK_DIR/walk.err")"
  fi
  read -r PLAN_FILES PLAN_EXCLUDED < "$WORK_DIR/walk.counts"
}

# The size-of-a-path command, lstat semantics (a symlink's own size): GNU
# `stat -c %s` or BSD `stat -f %z`. Apparent size, as the app's File.lstat.
detect_stat() {
  if stat -c %s / >/dev/null 2>&1; then
    STAT_SIZE=(stat -c %s)
  elif stat -f %z / >/dev/null 2>&1; then
    STAT_SIZE=(stat -f %z)
  else
    die "stat supports neither -c %s (GNU) nor -f %z (BSD)"
  fi
}

# $WORK_DIR/walk.sizes: one size per line, in walk.list order, from batched
# `stat` runs. If the media changed under a run (a listed file vanished), the
# entries that no longer exist are dropped — builtin tests, no fork per file —
# as the app's planner skips them, and the batch runs again; a few rounds at
# most. Only if the batches still disagree is each entry stat'ed on its own,
# where a failure on a file that still exists is an error.
size_media() {
  local list="$WORK_DIR/walk.list" sizes="$WORK_DIR/walk.sizes" round=1
  : > "$sizes"
  # GNU xargs runs its command once even on empty input.
  [ "$PLAN_FILES" -gt 0 ] || return 0

  while :; do
    if batch_sizes; then return 0; fi
    [ "$round" -lt 3 ] || break
    drop_vanished
    if [ "$PLAN_FILES" -eq 0 ]; then
      : > "$sizes"
      return 0
    fi
    round=$((round + 1))
  done

  local entry size kept=0 kept_list="$WORK_DIR/walk.kept"
  : > "$kept_list"
  : > "$sizes"
  while IFS= read -r -d '' entry; do
    if size="$(cd "$MEDIA_DIR" && "${STAT_SIZE[@]}" "$entry" 2> "$WORK_DIR/stat.err")" &&
      [[ "$size" =~ ^[0-9]+$ ]]; then
      printf '%s\0' "$entry" >> "$kept_list"
      printf '%s\n' "$size" >> "$sizes"
      kept=$((kept + 1))
    elif [ -e "$MEDIA_DIR/${entry#./}" ] || [ -L "$MEDIA_DIR/${entry#./}" ]; then
      die "could not read the size of ${entry}: $(tail -c 300 "$WORK_DIR/stat.err")"
    fi
  done < "$list"
  mv "$kept_list" "$list"
  PLAN_FILES="$kept"
}

# One batched size pass over walk.list; succeeds only if stat exited 0 and gave
# one number per entry.
batch_sizes() {
  local rc=0 lines
  (cd "$MEDIA_DIR" && xargs -0 "${STAT_SIZE[@]}" < "$WORK_DIR/walk.list" \
    > "$WORK_DIR/walk.sizes" 2> "$WORK_DIR/stat.err") || rc=$?
  lines="$(wc -l < "$WORK_DIR/walk.sizes" | tr -d ' ')"
  [ "$rc" -eq 0 ] && [ "$lines" = "$PLAN_FILES" ] &&
    ! grep -qv '^[0-9][0-9]*$' "$WORK_DIR/walk.sizes"
}

# Rewrite walk.list without the entries that no longer exist (a dangling
# symlink still does). Updates PLAN_FILES.
drop_vanished() {
  local entry kept=0 kept_list="$WORK_DIR/walk.kept"
  : > "$kept_list"
  while IFS= read -r -d '' entry; do
    if [ -e "$MEDIA_DIR/${entry#./}" ] || [ -L "$MEDIA_DIR/${entry#./}" ]; then
      printf '%s\0' "$entry" >> "$kept_list"
      kept=$((kept + 1))
    fi
  done < "$WORK_DIR/walk.list"
  mv "$kept_list" "$WORK_DIR/walk.list"
  PLAN_FILES="$kept"
}

# Assign the listed files to parts exactly as the app's add_file/3: a file
# larger than the cap (strictly) is a part of its own; otherwise a part closes
# when the next file would push its input total past the cap. An empty (or
# fully excluded) tree is one empty part. Writes $WORK_DIR/partNN.list and sets
# PLAN_PARTS and PLAN_OVERSIZE.
PLAN_PARTS=0
PLAN_OVERSIZE=0
PART_OPEN=0
PART_COUNT=0
PART_BYTES=0
PART_IS_OVERSIZE=0

open_part() {
  PLAN_PARTS=$((PLAN_PARTS + 1))
  exec 5> "$WORK_DIR/$(printf 'part%02d.list' "$PLAN_PARTS")"
  PART_OPEN=1
  PART_COUNT=0
  PART_BYTES=0
  PART_IS_OVERSIZE="$1"
  if [ "$1" = 1 ]; then PLAN_OVERSIZE=$((PLAN_OVERSIZE + 1)); fi
}

close_part() {
  if [ "$PART_OPEN" = 1 ]; then
    exec 5>&-
    PART_OPEN=0
  fi
}

assign_parts() {
  local cap="$MEDIA_PART_BYTES" entry size
  exec 4< "$WORK_DIR/walk.sizes"
  while IFS= read -r -d '' entry; do
    IFS= read -r size <&4 || die "media size list ended early"
    if [ "$size" -gt "$cap" ]; then
      close_part
      open_part 1
    elif [ "$PART_COUNT" -gt 0 ] && [ "$((PART_BYTES + size))" -gt "$cap" ]; then
      close_part
      open_part 0
    elif [ "$PART_OPEN" = 0 ]; then
      open_part 0
    fi
    printf '%s\0' "$entry" >&5
    PART_COUNT=$((PART_COUNT + 1))
    PART_BYTES=$((PART_BYTES + size))
    # An oversize part holds exactly its one file.
    if [ "$PART_IS_OVERSIZE" = 1 ]; then close_part; fi
  done < "$WORK_DIR/walk.list"
  exec 4<&-
  close_part
  if [ "$PLAN_PARTS" -eq 0 ]; then
    open_part 0
    close_part
  fi
}

# --- media archiving (mirror MediaArchive.archive_part/4) ------------------

# Refuse a tar that cannot read a NUL-separated list (busybox): every part is
# built with `--null -T`, the only list flags GNU tar and bsdtar share.
probe_tar() {
  local d="$WORK_DIR/probe" listing=""
  mkdir "$d" "$d/in"
  : > "$d/in/a b"
  printf './a b\0' > "$d/list"
  if tar -czf "$d/p.tar.gz" --null -C "$d/in" -T "$d/list" >/dev/null 2>&1; then
    listing="$(tar -tzf "$d/p.tar.gz" 2>/dev/null || true)"
  fi
  case "$listing" in
    *"a b"*) rm -rf -- "$d" ;;
    *) die "tar cannot read a NUL-separated file list (--null -T); install GNU tar or bsdtar" ;;
  esac
}

# Copy part $1's list to $2, dropping entries that no longer exist (a dangling
# symlink still counts). Sets FILTER_KEPT and FILTER_DROPPED.
filter_list() {
  local entry
  FILTER_KEPT=0
  FILTER_DROPPED=0
  : > "$2"
  while IFS= read -r -d '' entry; do
    if [ -e "$MEDIA_DIR/${entry#./}" ] || [ -L "$MEDIA_DIR/${entry#./}" ]; then
      printf '%s\0' "$entry" >> "$2"
      FILTER_KEPT=$((FILTER_KEPT + 1))
    else
      FILTER_DROPPED=$((FILTER_DROPPED + 1))
    fi
  done < "$1"
}

# Build part $1 of $2 as $3 (final path). Never trusts tar's exit code alone:
# a part counts only if tar exited 0 AND the archive lists cleanly. Anything
# else removes the .partial, re-filters the list and tries once more; the
# second failure stops the run. Not called from an `if`, so `set -e` holds.
archive_part() {
  local index="$1" total="$2" final="$3"
  local partial="${final}.partial"
  local list run err ok attempt=1
  list="$WORK_DIR/$(printf 'part%02d.list' "$index")"
  run="$WORK_DIR/$(printf 'part%02d.run.list' "$index")"
  err="$WORK_DIR/tar.err"
  track_partial "$partial"

  while :; do
    filter_list "$list" "$run"
    if [ "$FILTER_DROPPED" -gt 0 ]; then
      warn "media archive part ${index}: ${FILTER_DROPPED} listed file(s) vanished since planning and were left out"
    fi
    rm -f -- "$partial"
    : > "$err"
    ok=0
    # tar runs as a tracked child (run_child), so it dies with the script
    # (#2847). The empty tarball is a pipeline of milliseconds and stays in
    # the foreground.
    if [ "$FILTER_KEPT" -eq 0 ]; then
      # A valid empty tarball, written directly because GNU tar refuses to
      # create an empty archive.
      if head -c 10240 /dev/zero | gzip -n -c > "$partial" 2>> "$err" &&
        run_child tar -tzf "$partial" > /dev/null 2>> "$err"; then
        ok=1
      fi
    else
      if run_child tar -czf "$partial" --null -C "$MEDIA_DIR" -T "$run" 2>> "$err" &&
        run_child tar -tzf "$partial" > /dev/null 2>> "$err"; then
        ok=1
      fi
    fi
    [ "$ok" = 1 ] && break

    rm -f -- "$partial"
    if [ "$attempt" -eq 1 ]; then
      warn "media archive part ${index} of ${total} failed ($(tail -c 200 "$err" | tr '\n' ' ')); retrying once from a re-filtered list"
      attempt=2
      continue
    fi
    die "media archive part ${index} of ${total} failed: $(tail -c 500 "$err")"
  done

  # Tracked before the rename: a signal between the two must not leave a
  # finished part nobody removes.
  SET_FILES+=("$final")
  mv -- "$partial" "$final"
  chmod 600 "$final"
}

# In-progress marker: the Importer holds a stamp with a `.partial` beside it,
# and records it as interrupted once it has been quiet for hours, so a run
# killed outright (kill -9, power loss: no EXIT trap) never imports its
# finished parts as a succeeded set. `all` opens it before the dump, so a run
# killed in its db phase (or the dump's off-site copy) is not taken for a
# finished database-only backup either. The heartbeat keeps it fresh; the
# sidecar is written through it. Once per run.
MEDIA_MARKER=""
open_media_marker() {
  [ -z "$MEDIA_MARKER" ] || return 0
  private_media_dir
  MEDIA_MARKER="$BACKUP_DIR/media/kiln-media-${STAMP}.sha256.partial"
  track_partial "$MEDIA_MARKER"
  (umask 077 && : > "$MEDIA_MARKER")
}

# The media directory is private (0700) on every run, as the app makes it
# each time it writes there (#2477): created that way, and an existing one
# set back to it. A chmod that fails (a directory this user doesn't own)
# fails the run, as it fails the app's.
private_media_dir() {
  local dir="$BACKUP_DIR/media"
  mkdir -p "$BACKUP_DIR"
  [ -d "$dir" ] || (umask 077 && mkdir -p "$dir")
  chmod 700 "$dir" || die "could not make ${dir} private (chmod 700)"
}

require_media_dir() {
  require MEDIA_DIR
  [ -d "$MEDIA_DIR" ] || die "MEDIA_DIR does not exist: $MEDIA_DIR"
}

cmd_media() {
  require_media_dir
  local dir="$BACKUP_DIR/media"
  private_media_dir
  # Everything the media phase writes (lists, parts, sidecar) is private from
  # the first byte, not only after the final chmod. on_exit and the end of
  # this function restore the operator's umask.
  umask 077

  read_media_part_bytes
  read_media_excludes
  detect_stat

  # Lists live outside $BACKUP_DIR (whose .work/ is the app's resumable
  # namespace). Absolute, because tar resolves `-T` after `-C <media dir>`.
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kiln-backup-media.XXXXXX")"
  WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
  probe_tar

  open_media_marker
  local sidecar="$dir/kiln-media-${STAMP}.sha256"
  local marker="${sidecar}.partial"

  echo "==> Planning media archive of ${MEDIA_DIR}"
  walk_media
  size_media
  assign_parts

  local note=""
  if [ "$PLAN_EXCLUDED" -gt 0 ]; then
    note=", ${PLAN_EXCLUDED} excluded by BACKUP_MEDIA_EXCLUDE"
  fi
  echo "==> Planned ${PLAN_FILES} file(s) in ${PLAN_PARTS} part(s) (cap ${MEDIA_PART_MB} MB)${note}"
  if [ "$PLAN_OVERSIZE" -gt 0 ]; then
    warn "${PLAN_OVERSIZE} file(s) larger than the part size were archived as parts of their own"
  fi
  # Every part is still to be written: cron has no resume. Its lists are in
  # TMPDIR, often a small tmpfs the margin alone would refuse: not checked.
  check_free_space "media archive" "$dir" \
    "$(awk '{ s += $1 } END { printf "%.0f\n", s }' "$WORK_DIR/walk.sizes")"

  local total="$PLAN_PARTS" i name final sha
  local -a names shas
  names=()
  shas=()
  i=1
  while [ "$i" -le "$total" ]; do
    if [ "$total" -eq 1 ]; then
      name="kiln-media-${STAMP}.tar.gz"
    else
      name="$(printf 'kiln-media-%s.part%02d.tar.gz' "$STAMP" "$i")"
    fi
    final="$dir/$name"
    touch "$marker"
    echo "==> Archiving media part ${i} of ${total} → ${final}"
    archive_part "$i" "$total" "$final"
    sha="$(sha256_of "$final")"
    echo "    ok: $(du -h "$final" | cut -f1) ${name}"
    names+=("$name")
    shas+=("$sha")
    i=$((i + 1))
  done

  # The sidecar lists every part in order; it lands through the marker.
  local -a pairs
  pairs=()
  i=0
  while [ "$i" -lt "$total" ]; do
    pairs+=("${names[$i]}" "${shas[$i]}")
    i=$((i + 1))
  done
  write_sidecar "$sidecar" "${pairs[@]}"
  local sidecar_sha
  sidecar_sha="$(sha256_of "$sidecar")"
  # The set is complete: a later failure (off-site copy) keeps it.
  SET_FILES=()

  i=0
  while [ "$i" -lt "$total" ]; do
    record_artifact media "$dir/${names[$i]}" "${shas[$i]}" "$((i + 1))" "$total"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$total" ]; do
    offsite "$dir/${names[$i]}" "${shas[$i]}"
    i=$((i + 1))
  done
  offsite "$sidecar" "$sidecar_sha"
  umask "$ORIG_UMASK"
}

cmd_all() {
  if [ -n "${MEDIA_DIR:-}" ] && [ -d "$MEDIA_DIR" ]; then
    open_media_marker
  fi
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

# Whether stamp $2 has any `.partial` beside it in $1: the in-progress marker
# (`kiln-media-<stamp>.sha256.partial`) a cron run keeps while it builds the
# set, which stays behind when the run is killed outright, or a part still
# being written.
has_partial() {
  local f
  for f in "$1/kiln-media-${2}".*.partial; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# Whether stamp $2 has any `.partNN` archive in $1.
has_parts() {
  local f
  for f in "$1/kiln-media-${2}".part*.tar.gz; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# The newest media stamp in $1 with no `.partial` beside it. A newer one that
# is in progress or was interrupted is named on stderr and skipped.
newest_settled_media_stamp() {
  local stamp
  # shellcheck disable=SC2012 # names are filtered by the sed regex below
  for stamp in $(ls -1 "$1" 2>/dev/null |
    sed -n -E 's/^kiln-media-([0-9]{8}-[0-9]{6})(\.part[0-9]+)?\.tar\.gz$/\1/p' |
    sort -ru); do
    if has_partial "$1" "$stamp"; then
      echo "==> Skipping media set ${stamp}: still being written, or interrupted (a .partial is beside it)" >&2
      continue
    fi
    echo "$stamp"
    return 0
  done
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
  # `|| die`, not `&& echo`: `set -e` ignores a failure that is not the last
  # command of an `&&` list, so a corrupt dump used to verify clean.
  pg_restore --list "$f" >/dev/null || die "dump $(basename "$f") failed pg_restore --list"
  echo "    dump: ok"
  verify_sidecar "$BACKUP_DIR/db" "kiln-db-${dump_stamp}.sha256"

  media_stamp="$(newest_settled_media_stamp "$BACKUP_DIR/media")"
  if [ -n "$media_stamp" ]; then
    echo "==> Newest media backup: ${media_stamp}"
    # Every file of the stamp — a single legacy archive or all its parts —
    # not just whichever is newest by mtime.
    verify_part_contiguity "$BACKUP_DIR/media" "$media_stamp"
    # Every part set gets a sidecar (one part keeps the legacy name), so parts
    # without one are what a run killed mid-set leaves behind.
    if [ ! -f "$BACKUP_DIR/media/kiln-media-${media_stamp}.sha256" ] &&
      has_parts "$BACKUP_DIR/media" "$media_stamp"; then
      die "media set ${media_stamp} has parts but no sidecar (kiln-media-${media_stamp}.sha256) — it is incomplete"
    fi
    for f in "$BACKUP_DIR/media/kiln-media-${media_stamp}.tar.gz" \
      "$BACKUP_DIR/media/kiln-media-${media_stamp}".part*.tar.gz; do
      [ -f "$f" ] || continue
      echo "    $(basename "$f") ($(du -h "$f" | cut -f1))"
      tar -tzf "$f" >/dev/null || die "media archive $(basename "$f") failed tar -tzf"
    done
    echo "    media: ok"
    verify_sidecar "$BACKUP_DIR/media" "kiln-media-${media_stamp}.sha256"
  elif [ -n "$(newest_stamp "$BACKUP_DIR/media" kiln-media)" ]; then
    die "no complete media set under $BACKUP_DIR/media — every one found is still being written or was interrupted"
  else
    echo "==> No media archives (fine on S3-adapter deployments)"
  fi
}

# --- prune (#2219; keep in step with KilnCMS.Backups.Retention) ------------
#
# The unit is one COMPONENT of one stamp: the dump and its sidecar, or the
# media archive (or ALL its parts) and the media sidecar. A unit is aged by its
# newest regular file and deleted whole, data first and the sidecar last, so
# the database and the media of one stamp come and go independently. Per kind,
# a unit is KEPT when, in order:
#
#   - a recovery point pins its stamp: `kiln-<stamp>.keep` (any kind of entry)
#     in db/ or media/. Only its presence counts; prune never removes one.
#   - it is the last good backup of its kind: `kiln-<stamp>.good` (any kind of
#     entry) in ITS OWN directory, so db/kiln-<stamp>.good keeps the dump and
#     not the media of that stamp. The app writes it on the newest backup its
#     run history says verified, and moves it; prune never removes one.
#   - an in-app schedule holds it: `kiln-<stamp>.hold` (any kind of entry) in
#     ITS OWN directory, like `.good`. The app writes one on every unit a
#     schedule's keep count or keep days keep (which may be longer than
#     KEEP_DAYS), and removes it once they no longer do; prune never removes
#     one.
#   - it is in flight: `.work/<stamp>` exists, or one of its `.partial` files is
#     younger than PARTIAL_GRACE_MIN (60 minutes, the app's partial grace).
#   - it is the newest COMPLETE unit of its kind (see unit_complete) that is
#     not in flight and whose stamp is a real date no later than tomorrow.
#   - any of its regular files is not older than KEEP_DAYS (`-mtime +N`).
#
# The app also keeps anything its run history says is running; this script has
# no database, so it cannot, and it knows the newest VERIFIED backup only
# through the `.good` marker the app keeps on it, and what the schedules keep
# only through the `.hold` markers. It never deletes a symlink,
# a directory, or a file that is no unit's member. Only regular files count,
# judged with `find` (`[ -f ]` follows symlinks).
#
# Before the units, the `.partial` files of runs killed outright (#2478; see
# HEARTBEAT_S): a stamp's partials go once EVERY file of that stamp in db/ and
# media/, partial or finished, is older than ABANDONED_PARTIAL_MIN, unless
# `.work/<stamp>` exists. A live run's heartbeat keeps its partials fresh, and
# by then the app's Importer has recorded the stamp as interrupted (if the app
# reaches this directory: without it, the stamp's finished files import as
# what they are once the marker is gone). A recovery point does not keep them:
# `restore.sh` refuses a set with a `.partial` beside it, so keeping one would
# make the pinned set unrestorable. The finished files of the stamp are not
# touched here; they age as an incomplete unit like any other.
#
# Then the manifest temporary files at BACKUP_DIR's root that a writer stopped
# between its write and its rename left behind (prune_manifest_partials), and
# the app's abandoned backup-directory id temporary files (prune_dir_id_temps).

PART_NUM_ERE='(0[1-9]|[1-9][0-9]|[1-9][0-9]{2,})'

# The final member names of one unit ($1 = kind, $2 = stamp) among the names
# in $3 (one per line), exactly as Artifact.parse_file names them: a part
# number is two digits (01-99) or three or more with no leading zero.
unit_members() {
  local ere
  if [ "$1" = db ]; then
    ere="^kiln-db-${2}\\.(dump|sha256)\$"
  else
    ere="^kiln-media-${2}((\\.part${PART_NUM_ERE})?\\.tar\\.gz|\\.sha256)\$"
  fi
  printf '%s\n' "$3" | grep -E "$ere" || true
}

# Whether $1 is a regular file (never through a symlink); `solid` also needs
# it non-empty.
is_regular() { [ -n "$(find "$1" -prune -type f -print 2>/dev/null)" ]; }
is_solid() { [ -n "$(find "$1" -prune -type f -size +0c -print 2>/dev/null)" ]; }

# Whether a unit is whole on disk, from its final files only (Retention's
# complete?/1): a db unit needs its dump; a media unit needs either the single
# archive and no parts, or parts 01..N with no gap, no single archive, and the
# media sidecar. Every one of those a regular, non-empty file.
# $1 = directory, $2 = kind, $3 = stamp, $4 = the unit's member names.
unit_complete() {
  local dir="$1" kind="$2" stamp="$3" members="$4" name n single=0 nums="" expected=1
  if [ "$kind" = db ]; then
    is_solid "$dir/kiln-db-${stamp}.dump"
    return
  fi
  for name in $members; do
    case "$name" in
      "kiln-media-${stamp}.tar.gz") single=1 ;;
      "kiln-media-${stamp}.sha256") ;;
      *)
        is_solid "$dir/$name" || return 1
        n="${name#"kiln-media-${stamp}.part"}"
        n="${n%.tar.gz}"
        nums="$nums $((10#$n))"
        ;;
    esac
  done
  if [ -z "$nums" ]; then
    [ "$single" = 1 ] && is_solid "$dir/kiln-media-${stamp}.tar.gz"
    return
  fi
  [ "$single" = 0 ] || return 1
  is_solid "$dir/kiln-media-${stamp}.sha256" || return 1
  # shellcheck disable=SC2086 # $nums is a space-separated list of integers
  for n in $(printf '%s\n' $nums | sort -n); do
    [ "$n" -eq "$expected" ] || return 1
    expected=$((expected + 1))
  done
}

# The stamps with at least one unit member, newest first ($1 = kind, $2 = names).
unit_stamps() {
  printf '%s\n' "$2" |
    sed -n -E "s/^kiln-${1}-([0-9]{8}-[0-9]{6})(\\.part[0-9]+)?\\.(dump|tar\\.gz|sha256)\$/\\1/p" |
    sort -ru
}

# Whether line $2 is one of the lines of $1. grep reads all of its input: with
# pipefail, `grep -q` exiting early could SIGPIPE printf and turn a match into
# a miss.
has_line() {
  printf '%s\n' "$1" | grep -Fx -- "$2" >/dev/null
}

# `YYYYMMDD-HHMMSS` (UTC) one day from now: the latest stamp that may hold the
# newest-complete slot (Retention.plausible_stamp?/2). Nothing printed when
# this host's `date` can't format a given time (stamp_of).
future_limit() {
  stamp_of $(($(date -u +%s) + 86400)) || true
}

# Whether stamp $1 may hold the newest-complete slot: a real date and time
# (1970 or later; month, day for that month, hour, minute and second in range)
# no later than $PRUNE_FUTURE_LIMIT. Any other stamp's units still age as usual.
plausible_stamp() {
  local s="$1" y m d max
  y=$((10#${s:0:4}))
  m=$((10#${s:4:2}))
  d=$((10#${s:6:2}))
  [ "$y" -ge 1970 ] && [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] || return 1
  [ $((10#${s:9:2})) -le 23 ] && [ $((10#${s:11:2})) -le 59 ] && [ $((10#${s:13:2})) -le 59 ] || return 1
  case "$m" in
    2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then max=29; else max=28; fi ;;
    4 | 6 | 9 | 11) max=30 ;;
    *) max=31 ;;
  esac
  [ "$d" -le "$max" ] || return 1
  [ $((10#${s/-/})) -le $((10#${PRUNE_FUTURE_LIMIT/-/})) ]
}

# Whether unit ($2 = kind, $3 = stamp) in $1 is being written: `.work/<stamp>`
# exists (from the listing in $PRUNE_WORK) or it has a fresh `.partial`.
in_flight() {
  has_line "$PRUNE_WORK" "$3" || has_fresh_partial "$1" "$2" "$3"
}

# The newest stamp whose unit of kind $2 is complete in $1 ($3 = names), among
# units not in flight and with a plausible stamp — so a run still writing, or a
# misnamed or future-dated file, never takes the slot from the last finished
# backup.
newest_complete_stamp() {
  local stamp
  for stamp in $(unit_stamps "$2" "$3"); do
    plausible_stamp "$stamp" || continue
    in_flight "$1" "$2" "$stamp" && continue
    if unit_complete "$1" "$2" "$stamp" "$(unit_members "$2" "$stamp" "$3")"; then
      echo "$stamp"
      return 0
    fi
  done
}

# Whether a recovery point pins stamp $1: an entry named `kiln-<stamp>.keep`
# (of any kind) in the listings of db/ or media/ ($PRUNE_PINS) — the listing,
# not a stat, so an entry this user can't stat still counts.
is_pinned() {
  has_line "$PRUNE_PINS" "kiln-${1}.keep"
}

# Whether the app marked unit ($1 = kind, $2 = stamp) its last good backup of
# that kind: an entry named `kiln-<stamp>.good` (of any kind) in the listing of
# that kind's own directory ($PRUNE_DB_NAMES or $PRUNE_MEDIA_NAMES).
is_last_good() {
  if [ "$1" = db ]; then
    has_line "$PRUNE_DB_NAMES" "kiln-${2}.good"
  else
    has_line "$PRUNE_MEDIA_NAMES" "kiln-${2}.good"
  fi
}

# Whether an in-app schedule holds unit ($1 = kind, $2 = stamp): an entry named
# `kiln-<stamp>.hold` (of any kind) in the listing of that kind's own directory,
# as for is_last_good.
is_held() {
  if [ "$1" = db ]; then
    has_line "$PRUNE_DB_NAMES" "kiln-${2}.hold"
  else
    has_line "$PRUNE_MEDIA_NAMES" "kiln-${2}.hold"
  fi
}

# Whether unit ($2 = kind, $3 = stamp) in $1 has a `.partial` younger than
# PARTIAL_GRACE_MIN. A partial is `<name>.partial` (this script's) or
# `<name>.<tag>.partial`, a temporary file the app's backup step tags with its
# job and attempt (`48211-2`, #2819); both count. Fails closed: if `find`
# itself fails, the unit counts as in flight.
has_fresh_partial() {
  local ere found
  if [ "$2" = db ]; then
    ere="^kiln-db-${3}\\.(dump|sha256)(\\.[0-9]+(-[0-9]+)?)?\\.partial\$"
  else
    ere="^kiln-media-${3}((\\.part${PART_NUM_ERE})?\\.tar\\.gz|\\.sha256)(\\.[0-9]+(-[0-9]+)?)?\\.partial\$"
  fi
  if ! found="$(find "$1" -maxdepth 1 -name "kiln-${2}-${3}.*.partial" -mmin "-${PARTIAL_GRACE_MIN}" -print)"; then
    warn "could not look for partials of ${2} ${3} in $1; keeping it"
    return 0
  fi
  printf '%s\n' "$found" | sed 's#.*/##' | grep -E "$ere" >/dev/null
}

# Delete one unit's regular members ($1 = directory, $2 = kind, $3 = stamp,
# $4 = member names): data first, the sidecar last. Stops at the first file
# that can't be removed, so a unit cut short keeps its checksums.
remove_unit() {
  local dir="$1" sidecar="kiln-${2}-${3}.sha256" name
  for name in $4; do
    [ "$name" = "$sidecar" ] && continue
    is_regular "$dir/$name" || continue
    rm -f -- "$dir/$name" || { warn "could not remove $dir/$name; kept the rest of ${2} ${3}"; return 1; }
    echo "$dir/$name"
  done
  if is_regular "$dir/$sidecar"; then
    rm -f -- "$dir/$sidecar" || { warn "could not remove $dir/$sidecar"; return 1; }
    echo "$dir/$sidecar"
  fi
}

# The `.partial` files of abandoned runs ($1 = db names, $2 = media names; see
# above), untagged or tagged by the app (`<name>.<job>-<attempt>.partial`,
# see has_fresh_partial). A stamp is judged by `find -mmin` over both directories; if that
# fails, its partials are kept. Each removal is echoed; one that fails is
# warned about and the rest go on.
prune_abandoned_partials() {
  local kind dir names name stamp ere recent
  local -a dirs
  dirs=()
  for kind in db media; do
    [ -d "$BACKUP_DIR/$kind" ] && dirs+=("$BACKUP_DIR/$kind")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  for kind in db media; do
    dir="$BACKUP_DIR/$kind"
    if [ "$kind" = db ]; then
      names="$1"
      ere="^kiln-db-[0-9]{8}-[0-9]{6}\\.(dump|sha256)(\\.[0-9]+(-[0-9]+)?)?\\.partial\$"
    else
      names="$2"
      ere="^kiln-media-[0-9]{8}-[0-9]{6}((\\.part${PART_NUM_ERE})?\\.tar\\.gz|\\.sha256)(\\.[0-9]+(-[0-9]+)?)?\\.partial\$"
    fi
    [ -n "$names" ] || continue
    for name in $(printf '%s\n' "$names" | grep -E "$ere" || true); do
      is_regular "$dir/$name" || continue
      stamp="${name#kiln-"$kind"-}"
      stamp="${stamp:0:15}"
      has_line "$PRUNE_WORK" "$stamp" && continue
      if ! recent="$(find "${dirs[@]}" -maxdepth 1 -name "kiln-*-${stamp}.*" \
        -mmin "-${ABANDONED_PARTIAL_MIN}" -print)"; then
        warn "could not look for recent files of ${stamp}; keeping its partials"
        continue
      fi
      [ -z "$recent" ] || continue
      if rm -f -- "$dir/$name"; then
        echo "$dir/$name"
      else
        warn "could not remove $dir/$name"
      fi
    done
  done
}

# The manifest temporary files at BACKUP_DIR's root (#2832) older than
# PARTIAL_GRACE_MIN: `manifest.json.<tag>.partial`, where the tag is digits or
# `<digits>-<digits>` (this script's `<pid>-<random>`, an app step's
# `<job>-<attempt>` or a random number). A manifest write lasts a moment, so
# one that old was abandoned by a writer killed between its write and its
# rename. Only regular files (never a symlink) of exactly that shape: the
# untagged `manifest.json.partial` of an older backup.sh is left alone, as the
# app leaves it. A file whose age `find` can't tell is kept; each removal is
# echoed, and one that fails is warned about while the rest go on. A glob, not
# a `find` listing: a file name holding a newline can't then name another path.
prune_manifest_partials() {
  local path old
  for path in "$BACKUP_DIR"/manifest.json.*.partial; do
    [[ "${path##*/}" =~ $MANIFEST_PARTIAL_ERE ]] || continue
    if ! old="$(find "$path" -prune -type f -mmin "+${PARTIAL_GRACE_MIN}" -print)"; then
      warn "could not check the age of $path; kept it"
      continue
    fi
    [ -n "$old" ] || continue
    if rm -f -- "$path"; then
      echo "$path"
    else
      warn "could not remove $path"
    fi
  done
}

# In a variable: bash 3.2 reads a quoted right-hand side of `=~` literally.
MANIFEST_PARTIAL_ERE='^manifest\.json\.[0-9]+(-[0-9]+)?\.partial$'

# The app's backup-directory id temporary files at BACKUP_DIR's root (#2849)
# older than PARTIAL_GRACE_MIN: `.kiln-dir-id.<uuid>.tmp`, which the app
# writes, links to `.kiln-dir-id` and removes in a moment, so one that old was
# left by a node stopped in between. This script never writes one, but a host
# that backs up only with cron gets them from each app node's heartbeat and
# never runs the app's own sweep. Same rules as prune_manifest_partials: only
# regular files of exactly that name, a file of unknown age is kept, each
# removal is echoed, and a failure is warned about.
prune_dir_id_temps() {
  local path old
  for path in "$BACKUP_DIR"/.kiln-dir-id.*.tmp; do
    [[ "${path##*/}" =~ $DIR_ID_TEMP_ERE ]] || continue
    if ! old="$(find "$path" -prune -type f -mmin "+${PARTIAL_GRACE_MIN}" -print)"; then
      warn "could not check the age of $path; kept it"
      continue
    fi
    [ -n "$old" ] || continue
    if rm -f -- "$path"; then
      echo "$path"
    else
      warn "could not remove $path"
    fi
  done
}

DIR_ID_TEMP_ERE='^\.kiln-dir-id\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$'

cmd_prune() {
  echo "==> Pruning backups older than ${KEEP_DAYS} days"
  local kind dir names stamp members newest fresh name db_names="" media_names=""
  local work="$BACKUP_DIR/.work"

  # Both listings first: a marker in either directory pins both components,
  # so a directory that can't be listed means nothing is deleted at all.
  for kind in db media; do
    dir="$BACKUP_DIR/$kind"
    [ -d "$dir" ] || continue
    # shellcheck disable=SC2012 # every name is matched against a strict regex below
    if ! names="$(ls -1 "$dir")"; then
      warn "could not list $dir — nothing was pruned"
      return 0
    fi
    if [ "$kind" = db ]; then db_names="$names"; else media_names="$names"; fi
  done
  PRUNE_PINS="$(printf '%s\n%s\n' "$db_names" "$media_names")"
  PRUNE_DB_NAMES="$db_names"
  PRUNE_MEDIA_NAMES="$media_names"

  # A backup in flight keeps `.work/<stamp>`; a `.work` that exists but can't
  # be listed means none of them can be ruled out.
  PRUNE_WORK=""
  if [ -e "$work" ] || [ -L "$work" ]; then
    # shellcheck disable=SC2012 # names are only compared whole against a stamp
    if [ ! -d "$work" ] || ! PRUNE_WORK="$(ls -1 "$work")"; then
      warn "could not list $work — nothing was pruned"
      return 0
    fi
  fi

  if ! PRUNE_FUTURE_LIMIT="$(future_limit)" || [ -z "$PRUNE_FUTURE_LIMIT" ]; then
    warn "could not work out tomorrow's date with this date(1) — nothing was pruned"
    return 0
  fi

  prune_abandoned_partials "$db_names" "$media_names"
  prune_manifest_partials
  prune_dir_id_temps

  for kind in db media; do
    dir="$BACKUP_DIR/$kind"
    if [ "$kind" = db ]; then names="$db_names"; else names="$media_names"; fi
    [ -n "$names" ] || continue
    newest="$(newest_complete_stamp "$dir" "$kind" "$names")"

    for stamp in $(unit_stamps "$kind" "$names"); do
      members="$(unit_members "$kind" "$stamp" "$names")"
      [ -n "$members" ] || continue
      is_pinned "$stamp" && continue
      is_last_good "$kind" "$stamp" && continue
      is_held "$kind" "$stamp" && continue
      in_flight "$dir" "$kind" "$stamp" && continue
      [ "$stamp" = "$newest" ] && continue

      # Any regular member not older than the retention keeps the unit; a unit
      # with no regular member has nothing to delete.
      fresh=1
      for name in $members; do
        is_regular "$dir/$name" || continue
        fresh=0
        if [ -z "$(find "$dir/$name" -prune -mtime "+${KEEP_DAYS}" -print 2>/dev/null)" ]; then
          fresh=1
          break
        fi
      done
      [ "$fresh" = 1 ] && continue

      remove_unit "$dir" "$kind" "$stamp" "$members" || true
    done
  done
}

# --- this run's stamp (#2477) -----------------------------------------------
#
# An in-app schedule and a cron line set for the same minute can read the same
# second. Sharing a stamp would fold one run's files into the other's Run, and
# one's prune or cleanup could remove the other's files. So a stamp is in use
# when any file of either kind carries it (`db/kiln-db-<stamp>.*`,
# `media/kiln-media-<stamp>.*`: dumps, parts, sidecars, partials), when the
# app has a work directory for it (`.work/<stamp>`, which the app's start step
# makes first thing), or when another cron run claims it (`.claims/<stamp>`).
# The run steps forward one second at a time to a free one and claims it with
# `mkdir .claims/<stamp>`, which only one caller can win: two cron runs never
# share a stamp, whatever they back up. It then looks for the app's work
# directory once more, and steps on if the app took the stamp meanwhile. The
# claim is removed when the run exits (on_exit); the run's files mark the
# stamp from then on.
#
# The claim is not `.work/<stamp>`: the app's retention and `prune` treat
# that as a backup in flight, so the one a run killed outright leaves would
# pin the stamp's files and keep `prune` off its partials. A claim left that
# way only makes later runs skip its stamp. The app skips stamps with a claim
# or files on disk too (KilnCMS.Backups.Chain); a cron run and an app start
# that look within the same few milliseconds can still pick one stamp
# (docs/backups.md). Before the heartbeat starts, which reads STAMP.
CLAIM_DIR=""

# `YYYYMMDD-HHMMSS` (UTC) for $1 seconds since the epoch: GNU `date -d @N` or
# BSD `date -r N`, whichever this host has. Fails, printing nothing, when
# neither works.
stamp_of() {
  if [ "$(date -u -d @0 +%Y 2>/dev/null)" = 1970 ]; then
    date -u -d "@$1" +%Y%m%d-%H%M%S
  elif [ "$(date -u -r 0 +%Y 2>/dev/null)" = 1970 ]; then
    date -u -r "$1" +%Y%m%d-%H%M%S
  else
    return 1
  fi
}

# Whether `$BACKUP_DIR/$1` exists (lstat: a dangling symlink counts).
present() { [ -e "$BACKUP_DIR/$1" ] || [ -L "$BACKUP_DIR/$1" ]; }

# Whether stamp $1 has files or an app work directory (see above). Without
# nullglob an unmatched pattern stays literal, and the test fails on it.
stamp_used() {
  local f
  present ".work/$1" && return 0
  for f in "$BACKUP_DIR"/db/kiln-db-"$1".* "$BACKUP_DIR"/media/kiln-media-"$1".*; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 0; fi
  done
  return 1
}

# Claim STAMP: `.claims/<stamp>` created by this run, and nothing else using
# the stamp once it is. Fails when another writer has it; dies when the claim
# can't be made for any other reason.
claim() {
  local dir="$BACKUP_DIR/.claims/$STAMP"
  stamp_used "$STAMP" && return 1
  if ! mkdir "$dir" 2>/dev/null; then
    present ".claims/$STAMP" && return 1
    die "could not create ${dir}"
  fi
  if stamp_used "$STAMP"; then
    rmdir "$dir" 2>/dev/null || true
    return 1
  fi
  CLAIM_DIR="$dir"
}

# Sets STAMP and CLAIM_DIR. After 60 stamps in use the run fails, under a
# stamp no file carries (the next one, when it is free), so its failure
# manifest names no other run's backup.
claim_stamp() {
  local epoch="$NOW_EPOCH" tries=0 from="$STAMP"
  mkdir -p "$BACKUP_DIR"
  (umask 077 && mkdir -p "$BACKUP_DIR/.claims") || die "could not create ${BACKUP_DIR}/.claims"
  while :; do
    if claim; then
      if [ "$STAMP" != "$from" ]; then
        echo "==> Stamp ${from} is already in use in ${BACKUP_DIR}; this run is ${STAMP}"
      fi
      return 0
    fi
    tries=$((tries + 1))
    epoch=$((epoch + 1))
    STAMP="$(stamp_of "$epoch")" || die "date cannot format a time (neither GNU -d @N nor BSD -r N)"
    if [ "$tries" -ge 60 ]; then
      if stamp_used "$STAMP" || present ".claims/$STAMP"; then STAMP=""; fi
      die "no free backup stamp from ${from}: the 60 seconds from it are all in use in ${BACKUP_DIR}"
    fi
  done
}

case "${1:-}" in
  db) install_traps; claim_stamp; start_heartbeat; cmd_db ;;
  media) install_traps; require_media_dir; claim_stamp; start_heartbeat; cmd_media ;;
  # BACKUP_KEEP_DAYS is read before the traps, so a failure manifest records
  # the value `prune` would have used.
  all) WRITE_MANIFEST=1; read_keep_days; install_traps; claim_stamp; start_heartbeat; cmd_all ;;
  verify) cmd_verify ;;
  prune) read_keep_days; cmd_prune ;;
  *) die "usage: $0 {db|media|all|verify|prune}" ;;
esac
