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
# One exception is matched anywhere in the output: elixir_make (vix,
# lazy_html) does not stop on a failed NIF download. It prints "Error happened
# while installing <app> from precompiled binary" and falls back to a source
# build, which this builder cannot finish (no cmake, a lexbor git clone, a
# screenful of gcc errors), so the error that ends the step is the fallback's
# and the download line has scrolled out of the last 40. On the retry the NIF
# downloads, or the same fallback fails the same way; once the dep compiled,
# the line is gone, so an unrelated later error costs at most one retry.
#
# The fetchers' messages name the URL, not the cause, so a 403, a rate limit
# or a permanent 404 (a lock bump to a release with no NIF for this target)
# is retried too, and fails after the full backoff rather than at once.
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
  grep -Eq "Error happened while installing [A-Za-z0-9_]+ from precompiled binary" "$work/log" \
    && return 0
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
