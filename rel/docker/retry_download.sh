#!/bin/sh
# Run a build command, and run it again when it failed on a release-asset
# download (#2462). Used by the Dockerfile around the steps that fetch from
# GitHub's release CDN: `mix deps.compile` (the precompiled NIFs of y_ex,
# lazy_html, vix and tokenizers, and vix's libvips tarball) and the
# tailwind/esbuild installers.
#
#   retry_download.sh mix deps.compile
#
# Each of those tools retries about three times within seconds, which a 504
# window outlasts. This waits 15, 30, 60, then 120 seconds between attempts
# (about 4 minutes in all) before giving up with the command's own status.
#
# Only a download failure is retried. The signature is matched against the
# last 40 lines of the command's output, where Mix prints the error that
# stopped it, so a 504 a dep logged early and recovered from does not make a
# later compile error look like an outage. Any other failure exits at once.
#
#   KILN_FETCH_ATTEMPTS  attempts in all (default 5)
#   KILN_FETCH_BACKOFF   first wait in seconds, doubling each time (default 15)
#
# POSIX sh: the builder's /bin/sh is dash, which has no pipefail, so the
# command's status is written to a file from inside the pipeline.
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: retry_download.sh command [args...]" >&2
  exit 2
fi

attempts="${KILN_FETCH_ATTEMPTS:-5}"
delay="${KILN_FETCH_BACKOFF:-15}"

for value in "$attempts" "$delay"; do
  case "$value" in
    '' | *[!0-9]*)
      echo "retry_download.sh: KILN_FETCH_ATTEMPTS and KILN_FETCH_BACKOFF must be whole numbers" >&2
      exit 2
      ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A download error from one of the fetchers, or the HTTP status that caused it.
# elixir_make and rustler_precompiled print "couldn't fetch NIF from <url>"
# (rustler_precompiled inside its "Error while downloading precompiled NIF",
# which is not matched on its own: it also wraps a checksum mismatch, which
# no retry clears), tailwind and esbuild print "Couldn't fetch https://...", and vix's libvips
# download dies on a MatchError carrying httpc's `{~c"HTTP/1.1", 504, ...}`.
download_failure() {
  tail -n 40 "$work/log" | grep -Eiq \
    -e "couldn't fetch NIF from" \
    -e "couldn't fetch https?://" \
    -e '\{~?c?"HTTP/1\.[01]", ?50[234]' \
    -e 'Gateway Time-?out' \
    -e 'Bad Gateway' \
    -e 'Service Unavailable'
}

attempt=1
while :; do
  { status=0; "$@" || status=$?; echo "$status" >"$work/status"; } 2>&1 | tee "$work/log"
  status="$(cat "$work/status")"

  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  if ! download_failure; then
    exit "$status"
  fi

  if [ "$attempt" -ge "$attempts" ]; then
    echo "::warning::retry_download.sh: attempt $attempt of $attempts failed on a download (exit $status); giving up: $*" >&2
    exit "$status"
  fi

  echo "::warning::retry_download.sh: attempt $attempt of $attempts failed on a download (exit $status); retrying in ${delay}s: $*" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
done
