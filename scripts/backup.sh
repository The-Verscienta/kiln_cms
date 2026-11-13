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
#                                # last-good backups (kiln-<stamp>.good), the
#                                # newest complete one, and work in flight
#
# Environment:
#   DATABASE_URL         source database (required for `db`/`all`; read-only).
#                        postgres://, postgresql:// or ecto:// (the form the
#                        app documents); the password reaches pg_dump through
#                        PGPASSWORD only, never its argv (see pg_conn_split)
#   BACKUP_DIR           where backups land (default: /var/backups/kiln)
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
#   TMPDIR               where the media file lists are built (default: /tmp);
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
# Needs GNU tar or bsdtar (`--null -T`); busybox tar is refused up front.
# `verify` treats a stamp's files as one set; `prune` treats each component
# of a stamp (db, media) as one unit.
#
# Every dump is verified (pg_restore --list) before it counts as a backup.
# Plain shell + pg_dump/tar so it behaves the same on a laptop and on the VPS
# (bash 3.2 or later; GNU or BSD tar, stat and xargs).

set -euo pipefail

# Set by `die` so a failure manifest can record what actually went wrong.
LAST_ERROR=""

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
# stamp — a start one second later names a run that doesn't exist.
NOW="$(date -u '+%Y%m%d-%H%M%S %Y-%m-%dT%H:%M:%SZ')"
STAMP="${NOW%% *}"
STARTED_AT="${NOW#* }"

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
  echo "==> Off-site copy → ${OFFSITE_REMOTE}"
  # The parameters reach rclone through its environment only: `export` is a
  # builtin, and the subshell keeps them from every other command (#2690).
  (
    if [ "${#OFFSITE_ENV[@]}" -gt 0 ]; then export "${OFFSITE_ENV[@]}"; fi
    rclone copy "$file" "${OFFSITE_REMOTE}/$(basename "$(dirname "$file")")"
  )
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
# PGPASSWORD, in a subshell around the one command that needs it):
#   - `ecto://` (any case) becomes `postgres://`; nothing else is rewritten;
#   - the userinfo password and every query `password` parameter (the key is
#     decoded first, as libpq does: `pass%77ord=` is one) are removed and
#     decoded. The query one wins, as in libpq. The userinfo ends where libpq
#     ends it (fe-connect.c): at the first `@` before the first `/`, so a `?`
#     or `#` before that `@` is part of the password; the password runs from
#     the first `:` in it;
#   - with no non-empty password the URL is left as written, so an inherited
#     PGPASSWORD or ~/.pgpass still applies.
# A string that is not a postgres:// or postgresql:// URI (a `key=value`
# conninfo) is left unchanged.
pg_conn_split() {
  local url="$1" rest userinfo="" has_userinfo=0 host user="" pw="" has_pw=0
  local query="" has_query=0 q seg kept="" sep="" qpw="" has_qpw=0
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
      PG_CONN_DECODED=""
      case "$seg" in
        *=*) pg_conn_decode "${seg%%=*}" ;;
      esac
      if [ "$PG_CONN_DECODED" = "password" ]; then
        qpw="${seg#*=}"
        has_qpw=1
      else
        kept="${kept}${sep}${seg}"
        sep="&"
      fi
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
  PG_CONN_URL+="${host}"
  [ -n "$query" ] && PG_CONN_URL+="?${query}"

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
  local out="$BACKUP_DIR/manifest.json"
  track_partial "${out}.partial"
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
  cat > "${out}.partial" <<JSON
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
  mv "${out}.partial" "$out"
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
  umask "$ORIG_UMASK"

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

  if [ "$status" -ne 0 ] && [ "${WRITE_MANIFEST:-0}" = "1" ]; then
    # `die` sets LAST_ERROR; a command that failed under `set -e` (pg_dump,
    # tar, rclone) never reaches it, so fall back to the exit status rather
    # than recording an empty reason.
    write_manifest false "${LAST_ERROR:-backup.sh exited ${status} - see the backup log}"
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

track_partial() {
  OWN_PARTIALS+=("$1")
}

# A signal must still run on_exit (bash runs the EXIT trap on `exit`, not when
# a signal kills it). bash defers a trap until the foreground child (pg_dump,
# tar) exits, so cleanup happens after that child, not mid-write.
on_signal() {
  LAST_ERROR="interrupted by SIG$1"
  echo "error: ${LAST_ERROR}" >&2
  exit "$2"
}

install_traps() {
  trap on_exit EXIT
  trap 'on_signal HUP 129' HUP
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
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
  # The password reaches pg_dump through PGPASSWORD only: `export` is a
  # builtin, and the subshell keeps it from every other command (#2726).
  pg_conn_split "$DATABASE_URL"
  (
    if [ "$PG_CONN_HAS_PASSWORD" = 1 ]; then export PGPASSWORD="$PG_CONN_PASSWORD"; fi
    pg_dump --format=custom --no-owner --no-privileges \
      --file="${out}.partial" "$PG_CONN_URL"
  )

  echo "==> Verifying dump (pg_restore --list)"
  pg_restore --list "${out}.partial" >/dev/null ||
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
# listed fails the walk. $1 = path relative to MEDIA_DIR ("" for the root).
walk_dir() {
  local rel="$1" abs entry name child d
  local -a entries dirs
  dirs=()
  if [ -z "$rel" ]; then abs="$MEDIA_DIR"; else abs="$MEDIA_DIR/$rel"; fi

  if [ ! -e "$abs" ] && [ ! -L "$abs" ]; then
    return 0
  fi
  if [ ! -d "$abs" ] || [ ! -r "$abs" ] || [ ! -x "$abs" ]; then
    echo "cannot list ${abs}" >&2
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
    if [ "$FILTER_KEPT" -eq 0 ]; then
      # A valid empty tarball, written directly because GNU tar refuses to
      # create an empty archive.
      if head -c 10240 /dev/zero | gzip -n -c > "$partial" 2>> "$err" &&
        tar -tzf "$partial" > /dev/null 2>> "$err"; then
        ok=1
      fi
    else
      if tar -czf "$partial" --null -C "$MEDIA_DIR" -T "$run" 2>> "$err" &&
        tar -tzf "$partial" > /dev/null 2>> "$err"; then
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

cmd_media() {
  require MEDIA_DIR
  [ -d "$MEDIA_DIR" ] || die "MEDIA_DIR does not exist: $MEDIA_DIR"
  local dir="$BACKUP_DIR/media"
  # A media directory this script creates is private (0700), as the app makes
  # it; an existing one keeps its mode.
  mkdir -p "$BACKUP_DIR"
  [ -d "$dir" ] || (umask 077 && mkdir -p "$dir")
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

  # In-progress marker: the Importer holds a stamp with a `.partial` beside it,
  # so a run killed outright (kill -9, power loss: no EXIT trap) never imports
  # its finished parts as a succeeded set. The sidecar is written through it.
  local sidecar="$dir/kiln-media-${STAMP}.sha256"
  local marker="${sidecar}.partial"
  track_partial "$marker"
  (umask 077 && : > "$marker")

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
#   - it is in flight: `.work/<stamp>` exists, or one of its `.partial` files is
#     younger than 60 minutes (the app's partial grace).
#   - it is the newest COMPLETE unit of its kind (see unit_complete) that is
#     not in flight and whose stamp is a real date no later than tomorrow.
#   - any of its regular files is not older than KEEP_DAYS (`-mtime +N`).
#
# The app also keeps anything its run history says is running; this script has
# no database, so it cannot, and it knows the newest VERIFIED backup only
# through the `.good` marker the app keeps on it. It never deletes a
# `.partial`, a symlink, a directory, or a file that is no unit's member.
# Only regular files count, judged with `find` (`[ -f ]` follows symlinks).

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
# newest-complete slot (Retention.plausible_stamp?/2). GNU `date -d @N` or BSD
# `date -r N`, whichever this host has; nothing printed when neither works.
future_limit() {
  local t
  t=$(($(date -u +%s) + 86400))
  if [ "$(date -u -d @0 +%Y 2>/dev/null)" = 1970 ]; then
    date -u -d "@$t" +%Y%m%d-%H%M%S
  elif [ "$(date -u -r 0 +%Y 2>/dev/null)" = 1970 ]; then
    date -u -r "$t" +%Y%m%d-%H%M%S
  fi
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

# Whether unit ($2 = kind, $3 = stamp) in $1 has a `.partial` younger than the
# 60-minute grace. Fails closed: if `find` itself fails, the unit counts as in
# flight.
has_fresh_partial() {
  local ere found
  if [ "$2" = db ]; then
    ere="^kiln-db-${3}\\.(dump|sha256)\\.partial\$"
  else
    ere="^kiln-media-${3}((\\.part${PART_NUM_ERE})?\\.tar\\.gz|\\.sha256)\\.partial\$"
  fi
  if ! found="$(find "$1" -maxdepth 1 -name "kiln-${2}-${3}.*.partial" -mmin -60 -print)"; then
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

case "${1:-}" in
  db) install_traps; cmd_db ;;
  media) install_traps; cmd_media ;;
  # BACKUP_KEEP_DAYS is read before the traps, so a failure manifest records
  # the value `prune` would have used.
  all) WRITE_MANIFEST=1; read_keep_days; install_traps; cmd_all ;;
  verify) cmd_verify ;;
  prune) read_keep_days; cmd_prune ;;
  *) die "usage: $0 {db|media|all|verify|prune}" ;;
esac
