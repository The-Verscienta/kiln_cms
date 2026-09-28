#!/usr/bin/env bash
#
# floating_tags.sh — which floating image tags a release tag may move (#1544).
#
#   scripts/release/floating_tags.sh REF [EXISTING_TAG...]
#
# REF is the tag being released (`v1.0.3`). The remaining arguments are every
# release tag that exists upstream; `release.yml` passes `git ls-remote`'s
# list. REF counts whether or not it is among them.
#
# Prints two `key=value` lines for `$GITHUB_OUTPUT`:
#
#   latest=true|false   REF is a final release and the highest final release
#                       of all. Otherwise `latest` stays where it is.
#   major=true|false    REF is a final release >= 1.0.0 and the highest final
#                       release of its own major line, so the floating major
#                       tag (`1`) follows it. Pre-1.0 there is no floating
#                       major: every release so far would be `0`.
#
# Why "highest" and not "newest": the previous minor gets security fixes for
# 90 days from short-lived branches off its tag (`.github/SECURITY.md`,
# `docs/releasing.md`). `v1.0.3` pushed after `v1.1.0` is the newest tag but
# not the newest release, and moving `latest` or `1` onto it would downgrade
# everyone who floats on them.
#
# A pre-release (`v1.0.0-rc.1`: anything after the patch number) moves
# nothing, the #1541 rule, and neither does a tag that is not a plain `vX.Y.Z`.
# Tags in the list that are not final releases are ignored: a candidate never
# outranks a final.
#
# The reason for each answer goes to stderr, so the run log explains it.
# Plain bash 3.2 (the macOS default), so the test runs anywhere.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 REF [EXISTING_TAG...]" >&2
  exit 2
fi

ref="$1"
shift

final_re='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

# Prints "MAJOR MINOR PATCH" for a final release tag; fails for anything else.
parse() {
  if [[ "$1" =~ $final_re ]]; then
    # 10# so a leading zero is not read as octal.
    echo "$((10#${BASH_REMATCH[1]})) $((10#${BASH_REMATCH[2]})) $((10#${BASH_REMATCH[3]}))"
  else
    return 1
  fi
}

# Succeeds when version A (three numbers) is lower than version B.
lower() {
  local a1=$1 a2=$2 a3=$3 b1=$4 b2=$5 b3=$6
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -lt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -lt "$b2" ]; return; fi
  [ "$a3" -lt "$b3" ]
}

emit() {
  echo "latest=$1"
  echo "major=$2"
}

if ! parsed=$(parse "$ref"); then
  echo "$ref is not a final vX.Y.Z release: no floating tag moves." >&2
  emit false false
  exit 0
fi

read -r r1 r2 r3 <<<"$parsed"

latest=true
major=true
latest_by=""
major_by=""

for tag in "$@"; do
  tag="${tag#refs/tags/}"
  v=$(parse "$tag") || continue
  read -r t1 t2 t3 <<<"$v"

  if lower "$r1" "$r2" "$r3" "$t1" "$t2" "$t3"; then
    if [ "$latest" = true ]; then
      latest=false
      latest_by="$tag"
    fi
    if [ "$t1" -eq "$r1" ] && [ "$major" = true ]; then
      major=false
      major_by="$tag"
    fi
  fi
done

if [ "$latest" = true ]; then
  echo "$ref is the highest final release: latest moves to it." >&2
else
  echo "$ref is below $latest_by: latest stays where it is." >&2
fi

if [ "$r1" -lt 1 ]; then
  major=false
  echo "$ref is pre-1.0: there is no floating major tag." >&2
elif [ "$major" = true ]; then
  echo "$ref is the highest final $r1.x release: $r1 moves to it." >&2
else
  echo "$ref is below $major_by: $r1 stays where it is." >&2
fi

emit "$latest" "$major"
