#!/usr/bin/env bash
#
# restore.sh — restore Kiln backups made by scripts/backup.sh.
# See docs/backups.md for the full runbook (env vars, SECRET_KEY_BASE caveat).
#
#   ./scripts/restore.sh db <dump>       # pg_restore into RESTORE_DATABASE_URL
#   ./scripts/restore.sh media <archive>... # extract into RESTORE_MEDIA_DIR
#   ./scripts/restore.sh drill <dump>    # restore into a throwaway DB + sanity checks
#
# Environment:
#   RESTORE_DATABASE_URL  target database (required for `db`/`drill`)
#   RESTORE_MEDIA_DIR     target uploads root (required for `media`)
#   RESTORE_CONFIRM=yes   skip the interactive confirmation (for scripted drills)
#   RESTORE_REQUIRE_CHECKSUM=1  `media`: abort when no checksum sidecar is found
#                         (default: warn loudly on stderr and continue)
#   RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1  `media`: restore a .partNN set that
#                         has no sidecar (refused by default: every complete
#                         part set has one, so a set without it is most likely
#                         what a killed run left behind)
#
# `media` takes any of:
#   * one legacy archive           kiln-media-<stamp>.tar.gz (a single-part
#                                  backup, from backup.sh or the app)
#   * any ONE part of a set        kiln-media-<stamp>.partNN.tar.gz (backup.sh
#                                  and the app both split media into parts) —
#                                  the other parts with the same stamp in the
#                                  same directory are discovered
#   * several explicit paths       (e.g. a shell glob) — taken as the whole set
#   * a stamp prefix               /backups/media/kiln-media-<stamp>
# Parts are ordered by their NUMBER (never by name), must be contiguous from
# 01 with no duplicate, and must share one stamp. Checksums are verified
# BEFORE anything is extracted, from the sidecar kiln-media-<stamp>.sha256
# next to the parts (`sha256sum -c`, or `shasum -a 256 -c` on macOS). Every
# part is also listed first, and the restore aborts if any member has an
# absolute path or a `..` component, or is a symlink/hardlink whose target is
# absolute or contains `..` (so even a harmless `d/x -> ../y` link is refused;
# restore such a set by hand). Nothing is extracted unless every check passed.
# The manifest is not consulted: the sidecar is the supported record. A set
# with a `kiln-media-<stamp>.*.partial` beside it (backup.sh's in-progress
# marker, or a part still being written) is refused: it is being written, or
# its run was killed. A legacy single archive without a sidecar (backups from
# before checksums) is restored with a warning, as before.
#
# `db` is destructive on the target (--clean drops existing objects first) —
# it refuses to run without confirmation. `drill` expects a throwaway target
# (the database name must contain "drill", "staging", "scratch", or "tmp")
# and never needs confirmation.

set -euo pipefail

trap 'cleanup_tmp' EXIT

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

warn_no_checksum() {
  {
    echo "################################################################"
    echo "# WARNING: no checksum found for this media backup."
    echo "# Expected ${1} next to the archive(s)."
    echo "# The archive(s) are NOT verified against corruption or tampering."
    echo "################################################################"
  } >&2
}

# Scratch files for the pre-extraction listings; removed on exit.
LIST_TMP=""
cleanup_tmp() {
  [ -z "$LIST_TMP" ] || rm -f -- "$LIST_TMP" "${LIST_TMP}.v"
}

# Print one line per member of archive $1 that is unsafe to extract: an
# absolute path, a ".." path component, or a symlink/hardlink whose target is
# absolute or has a ".." component (a link pointing out of the tree, followed
# by a member written "through" it, escapes RESTORE_MEDIA_DIR even though
# every member NAME looks safe). tar strips a leading "/" and refuses ".." in
# names by default (we never pass -P), but the explicit pre-listing makes the
# refusal independent of which tar this is and happens before ANY part is
# touched.
#
# The listing is captured to a file FIRST and its exit status checked: piping
# `tar -t` into grep would discard tar's status, so a truncated or corrupt
# part would pass the pre-check and a partial extract would follow. Returns
# non-zero (printing nothing) when the archive cannot be listed.
#
# Links are read from `tar -tv` output, which both GNU tar and bsdtar print as
#   lrwxrwxrwx … name -> target          (symlink)
#   hrw-r--r-- … name link to target     (hardlink)
# Names are escaped by both tools, so a record is one line. Extracting into a
# staging directory to inspect the result instead would itself write through
# the hostile link, so the listing is the only safe place to check.
unsafe_members() {
  tar -tzf "$1" >"$LIST_TMP" || return 2
  tar -tvzf "$1" >"${LIST_TMP}.v" || return 2
  grep -E '^/|(^|/)\.\.(/|$)' "$LIST_TMP" || true
  unsafe_links "${LIST_TMP}.v"
}

unsafe_links() {
  local line rest piece
  while IFS= read -r line; do
    case "$line" in
      l*" -> "*) rest="${line#*" -> "}" ;;
      h*" link to "*) rest="${line#*" link to "}" ;;
      l* | h*)
        # A link record we cannot take apart is not one we can vouch for.
        echo "$line"
        continue
        ;;
      *) continue ;;
    esac
    # A name or target containing the separator makes the split ambiguous:
    # check every piece, which can only over-report.
    rest="${rest// -> /$'\n'}"
    rest="${rest// link to /$'\n'}"
    while IFS= read -r piece; do
      if [[ "$piece" == /* ]] || [[ "$piece" =~ (^|/)\.\.(/|$) ]]; then
        echo "$line"
        break
      fi
    done <<<"$rest"
  done <"$1"
}

media_name_re='^kiln-media-([0-9]{8}-[0-9]{6})(\.part([0-9]{2,}))?\.tar\.gz$'

# Resolve every operator-supplied argument into MEDIA_DIR_SRC (one directory)
# and MEDIA_NAMES (newline-separated base names). Nothing is globbed or
# word-split here: all expansions are quoted.
collect_media_arg() {
  local arg="$1" d b abs name rest found=0
  if [ -f "$arg" ]; then
    d="$(dirname -- "$arg")"
    b="$(basename -- "$arg")"
    abs="$(cd -- "$d" && pwd -P)"
    add_media_name "$abs" "$b"
    return 0
  fi
  # Not a file: a stamp prefix such as /backups/media/kiln-media-<stamp>.
  d="$(dirname -- "$arg")"
  b="$(basename -- "$arg")"
  [ -d "$d" ] || die "no such file or archive set: $arg"
  abs="$(cd -- "$d" && pwd -P)"
  while IFS= read -r name; do
    case "$name" in
      "$b"*)
        rest="${name#"$b"}"
        if [[ "$rest" =~ ^(\.part[0-9]{2,})?\.tar\.gz$ ]]; then
          add_media_name "$abs" "$name"
          found=1
        fi
        ;;
    esac
  done < <(ls -1 -- "$abs")
  [ "$found" -eq 1 ] || die "no such file or archive set: $arg"
}

add_media_name() {
  if [ -z "$MEDIA_DIR_SRC" ]; then
    MEDIA_DIR_SRC="$1"
  elif [ "$MEDIA_DIR_SRC" != "$1" ]; then
    die "media parts must all be in one directory (got ${MEDIA_DIR_SRC} and ${1})"
  fi
  if [ -z "$MEDIA_NAMES" ]; then
    MEDIA_NAMES="$2"
  else
    MEDIA_NAMES="${MEDIA_NAMES}"$'\n'"$2"
  fi
}

# A sidecar is `<64 hex>  <file name>` per line (what Checksum.write_sidecar
# writes). `sha256sum -c` / `shasum -c` SKIP lines they cannot parse and still
# exit 0 (Darwin's sha256sum has no --strict), so a truncated digest would
# verify nothing. Validate every line ourselves first.
sidecar_well_formed() {
  [ -s "$1" ] && ! grep -Evq '^[0-9a-fA-F]{64} [ *][^/]+$' "$1"
}

sha_check() {
  # $1 = directory, $2 = sidecar file name; verifies every line in it.
  sidecar_well_formed "$1/$2" || {
    echo "error: ${2} has a missing or malformed checksum line" >&2
    return 1
  }
  if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "$1" && sha256sum -c -- "$2")
  elif command -v shasum >/dev/null 2>&1; then
    (cd -- "$1" && shasum -a 256 -c -- "$2")
  else
    die "neither sha256sum nor shasum is installed — cannot verify ${2}"
  fi
}

cmd_media() {
  require RESTORE_MEDIA_DIR
  [ "$#" -ge 1 ] || die "usage: $0 media <archive|part|stamp-prefix> [more parts...]"
  MEDIA_DIR_SRC=""
  MEDIA_NAMES=""
  local arg name count stamp="" first_stamp="" kind="" foreign=0 only

  for arg in "$@"; do
    collect_media_arg "$arg"
  done

  # --- classify names: stamp, legacy vs part ---
  count=0
  while IFS= read -r name; do
    count=$((count + 1))
    if [[ "$name" =~ $media_name_re ]]; then
      stamp="${BASH_REMATCH[1]}"
      if [ -n "${BASH_REMATCH[3]}" ]; then
        [ -z "$kind" ] || [ "$kind" = parts ] || die "refusing to mix a single archive with parts of a set"
        kind=parts
      else
        [ -z "$kind" ] || [ "$kind" = legacy ] || die "refusing to mix a single archive with parts of a set"
        kind=legacy
      fi
      if [ -z "$first_stamp" ]; then
        first_stamp="$stamp"
      elif [ "$first_stamp" != "$stamp" ]; then
        die "refusing to mix stamps (${first_stamp} and ${stamp}) — pass one backup set"
      fi
    else
      foreign=1
    fi
  done <<<"$MEDIA_NAMES"

  if [ "$foreign" -eq 1 ]; then
    # An archive not named by Kiln: only a single one is accepted, with no
    # sibling discovery and no sidecar (there is no stamp to find it by).
    [ "$count" -eq 1 ] || die "unrecognised media archive name — expected kiln-media-<stamp>[.partNN].tar.gz"
    kind=foreign
  fi

  # One part given: discover the rest of its set.
  if [ "$kind" = parts ] && [ "$count" -eq 1 ]; then
    only=""
    while IFS= read -r name; do
      if [[ "$name" =~ $media_name_re ]] && [ "${BASH_REMATCH[1]}" = "$first_stamp" ] &&
        [ -n "${BASH_REMATCH[3]}" ]; then
        only="${only:+${only}$'\n'}${name}"
      fi
    done < <(ls -1 -- "$MEDIA_DIR_SRC")
    MEDIA_NAMES="$only"
  fi

  # --- order numerically, then require 01..N with no gap and no duplicate ---
  local sorted
  if [ "$kind" = parts ]; then
    sorted="$(printf '%s\n' "$MEDIA_NAMES" |
      sed -E 's/^kiln-media-[0-9]{8}-[0-9]{6}\.part([0-9]+)\.tar\.gz$/\1 &/' |
      sort -n | cut -d' ' -f2-)"
    local expected=1 n
    while IFS= read -r name; do
      [[ "$name" =~ $media_name_re ]]
      n=$((10#${BASH_REMATCH[3]}))
      if [ "$n" -eq $((expected - 1)) ]; then
        die "duplicate part$(printf '%02d' "$n") in the set for ${first_stamp} — nothing was extracted"
      elif [ "$n" -ne "$expected" ]; then
        die "missing part$(printf '%02d' "$expected") in the set for ${first_stamp} (found part$(printf '%02d' "$n")) — nothing was extracted"
      fi
      expected=$((expected + 1))
    done <<<"$sorted"
  else
    sorted="$MEDIA_NAMES"
    if [ "$count" -ne 1 ]; then
      die "duplicate archive in the set for ${first_stamp} — nothing was extracted"
    fi
  fi

  # --- an unfinished set: a run in progress, or one killed outright ---
  if [ "$kind" != foreign ]; then
    local f
    for f in "${MEDIA_DIR_SRC}/kiln-media-${first_stamp}".*.partial; do
      if [ -e "$f" ]; then
        die "$(basename -- "$f") is beside the set for ${first_stamp}: it is still being written, or the run that wrote it was interrupted — nothing was extracted"
      fi
    done
  fi

  # --- checksums, before anything is extracted ---
  local sidecar="" sidecar_path
  if [ "$kind" != foreign ]; then
    sidecar="kiln-media-${first_stamp}.sha256"
    sidecar_path="${MEDIA_DIR_SRC}/${sidecar}"
  fi
  if [ -n "$sidecar" ] && [ -f "$sidecar_path" ]; then
    echo "==> Verifying checksums from ${sidecar}"
    local listed
    listed="$(sed -E 's/^[0-9a-fA-F]+ [ *]//' "$sidecar_path")"
    # Every file the sidecar names must be in the set (catches a missing
    # LAST part, which contiguity alone cannot), and vice versa.
    while IFS= read -r name; do
      printf '%s\n' "$sorted" | grep -Fxq -- "$name" ||
        die "${sidecar} lists ${name}, which is missing from the set — nothing was extracted"
    done <<<"$listed"
    while IFS= read -r name; do
      printf '%s\n' "$listed" | grep -Fxq -- "$name" ||
        die "${name} is not listed in ${sidecar} — nothing was extracted"
    done <<<"$sorted"
    sha_check "$MEDIA_DIR_SRC" "$sidecar" ||
      die "checksum verification FAILED — nothing was extracted"
  else
    warn_no_checksum "${sidecar:-a kiln-media-<stamp>.sha256 sidecar}"
    if [ "${RESTORE_REQUIRE_CHECKSUM:-}" = "1" ]; then
      die "RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found — nothing was extracted"
    fi
    # Every part set is written with a sidecar (one part keeps the legacy
    # name), so parts without one are most likely the leftovers of a run
    # killed mid-set: restoring them would silently lack files.
    if [ "$kind" = parts ] && [ "${RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM:-}" != "1" ]; then
      die "the part set for ${first_stamp} has no sidecar, so it is probably incomplete (a run killed mid-set); set RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1 to restore these parts anyway — nothing was extracted"
    fi
  fi

  # --- extraction safety: list every part first ---
  local bad
  # Created here, not inside unsafe_members: that runs in a $(…) subshell, and
  # the EXIT trap must see the path.
  LIST_TMP="$(mktemp "${TMPDIR:-/tmp}/kiln-restore.XXXXXX")"
  while IFS= read -r name; do
    bad="$(unsafe_members "${MEDIA_DIR_SRC}/${name}")" ||
      die "unreadable archive: ${name} — nothing was extracted"
    if [ -n "$bad" ]; then
      echo "$bad" | head -5 >&2
      die "${name} contains an absolute or '..' path, or a link pointing outside the tree — refusing to extract (nothing was extracted)"
    fi
  done <<<"$sorted"

  # --- extract, in order ---
  mkdir -p "$RESTORE_MEDIA_DIR"
  local i=0 total
  total="$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')"
  while IFS= read -r name; do
    i=$((i + 1))
    echo "==> [${i}/${total}] Extracting ${name} → ${RESTORE_MEDIA_DIR}"
    tar -xzf "${MEDIA_DIR_SRC}/${name}" -C "$RESTORE_MEDIA_DIR"
  done <<<"$sorted"
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
  *) die "usage: $0 {db|drill} <dump> | media <archive|part|stamp-prefix>..." ;;
esac
