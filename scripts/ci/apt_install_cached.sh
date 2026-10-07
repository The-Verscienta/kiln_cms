#!/usr/bin/env bash
#
# apt_install_cached.sh — install apt packages from a restored cache when it
# can, and from the mirror only when it must.
#
#   scripts/ci/apt_install_cached.sh CACHE_DIR PACKAGE...
#
# CACHE_DIR holds two directories that `ci.yml` saves and restores with
# `actions/cache`: `lists/` (the package indexes apt resolved against) and
# `archives/` (the .debs it downloaded). Both go through apt's own
# `Dir::State::Lists` and `Dir::Cache::Archives` options, so the system's
# directories are never touched and the cache directory can stay owned by the
# runner user, which is what `actions/cache` reads and writes as.
#
# Why the indexes too, and not just the .debs: apt picks versions from the
# indexes, then looks for exactly those files. The runner image's own lists
# are a snapshot from whenever the image was built, and the .debs in the cache
# came from whatever an `apt-get update` saw on the day they were fetched — the
# two disagree on some library's point release often enough that
# `--no-download` against the image's lists would miss the cache it was handed.
# Restoring the lists the .debs were resolved against makes a hit a hit.
#
# 1. Offline. If the cache has indexes and .debs, `apt-get install
#    --no-download`. Nothing contacts a mirror. This is the path every shard
#    takes on a warm cache, and the whole point: the stalls on 2026-10-01 and
#    2026-10-07 were the mirror, not the packages.
# 2. Online, only when (1) is impossible or fails (a cold cache, a cache from
#    an older runner image that no longer resolves, a truncated restore).
#    Seed `lists/` from the image's own indexes so `update` can be incremental,
#    then `update` + `install --download-only`, each attempt under a hard
#    `timeout`, three attempts. apt's `Acquire::*::Timeout` is an INACTIVITY
#    timeout: a connection trickling a byte every few seconds never trips it,
#    which is how a step with 30 s timeouts and three retries still spent its
#    full ten minutes on 2026-10-07 (a 9 MB .deb took five minutes; apt never
#    logged an error). The wall-clock bound is what turns a
#    stalled connection into a quick retry. Then install from what was
#    fetched, `--no-download` again, so both paths finish the same way.
#
# Prints which path ran, so the job log says whether the mirror was involved.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 CACHE_DIR PACKAGE..." >&2
  exit 2
fi

cache_dir=$1
shift
lists="$cache_dir/lists"
archives="$cache_dir/archives"

# Wall-clock bounds for each online attempt (seconds), and how many attempts.
# A healthy mirror serves ffmpeg's 62.8 MB in seconds; 3 x (60 + 120) plus
# the backoff stays inside the step's 10-minute ceiling with room for the
# install itself. A killed download is not wasted: finished .debs stay in
# `archives/` and apt resumes the partial one, so each retry starts further on.
update_timeout=${APT_UPDATE_TIMEOUT:-60}
download_timeout=${APT_DOWNLOAD_TIMEOUT:-120}
attempts=${APT_ATTEMPTS:-3}

apt_opts=(
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
  -o DPkg::Lock::Timeout=120
  -o "Dir::State::Lists=$lists"
  -o "Dir::Cache::Archives=$archives"
)
install=(install -y --no-install-recommends)

mkdir -p "$lists/partial" "$archives/partial"

# Hand the cache back to the runner user, minus apt's lock files (root-only,
# unreadable to the cache's tar) and any half-fetched partials.
tidy() {
  sudo rm -f "$lists/lock" "$archives/lock"
  sudo find "$lists/partial" "$archives/partial" -mindepth 1 -delete
  sudo chown -R "$(id -u):$(id -g)" "$cache_dir"
}
trap tidy EXIT

has_files() { [ -n "$(find "$1" -maxdepth 1 -type f -name "$2" -print -quit)" ]; }

if has_files "$lists" '*_Packages*' && has_files "$archives" '*.deb'; then
  if sudo apt-get "${apt_opts[@]}" "${install[@]}" --no-download "$@"; then
    echo "apt: installed $* from the cache; no mirror contacted"
    exit 0
  fi
  echo "::warning::apt: the restored cache could not install $* offline; falling back to the mirror"
else
  echo "apt: no usable cache for $*; fetching from the mirror"
fi

if ! has_files "$lists" '*_Packages*'; then
  # The image's indexes are a head start: `update` then mostly fetches diffs.
  sudo find /var/lib/apt/lists -maxdepth 1 -type f ! -name lock \
    -exec cp -p {} "$lists/" \;
fi

fetched=false
for attempt in $(seq 1 "$attempts"); do
  if sudo timeout -k 10 "$update_timeout" apt-get "${apt_opts[@]}" update -qq &&
     sudo timeout -k 10 "$download_timeout" apt-get "${apt_opts[@]}" "${install[@]}" --download-only "$@"; then
    fetched=true
    break
  fi
  echo "::warning::apt: fetch attempt $attempt/$attempts for $* failed or stalled"
  sleep $((attempt * 5))
done

if [ "$fetched" != true ]; then
  echo "::error::apt: could not fetch $* from the mirror after $attempts attempts"
  exit 1
fi

sudo apt-get "${apt_opts[@]}" "${install[@]}" --no-download "$@"
# .debs the fresh indexes no longer list are dead weight in the next save.
sudo apt-get "${apt_opts[@]}" autoclean -qq
echo "apt: installed $* from the mirror; the cache will be saved for next time"
