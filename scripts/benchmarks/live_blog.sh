#!/usr/bin/env bash
#
# live_blog.sh — firing cost of a live blog that publishes an update every few
# seconds (#2049). See scripts/benchmarks/README.md.
#
#   scripts/benchmarks/live_blog.sh
#   BENCH_DURATION=300 BENCH_SUBSCRIBERS=0 scripts/benchmarks/live_blog.sh
#
# In order:
#   1. creates its OWN database, kiln_cms_bench_<pid>, and drops it on exit
#      (KEEP=1 keeps it). No other database on the server is touched;
#   2. compiles and migrates a MIX_ENV=prod build against it;
#   3. seeds a published corpus through the domain actions (seed.exs), so the
#      updates land in a database with content in it;
#   4. runs live_blog.exs in one prod BEAM with the application (and its Oban
#      queues) started: one leg per BENCH_SUBSCRIBERS value;
#   5. drops the database.
#
# Results land in $BENCH_WORK (default: a new mktemp dir): results.json,
# results.md and the logs of every step.
#
# Environment:
#   BENCH_WORK       output directory
#   POOL_SIZE        the Repo pool (default 10, the production default)
#   KEEP=1           keep the database afterwards
#   POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD   (localhost / postgres / postgres)
#   plus everything seed.exs and live_blog.exs read (BENCH_PAGES, BENCH_POSTS,
#   BENCH_DURATION, BENCH_INTERVAL_MIN, BENCH_INTERVAL_MAX, BENCH_SUBSCRIBERS).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PG_HOST="${POSTGRES_HOST:-localhost}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-postgres}"
DB="kiln_cms_bench_$$"
WORK="${BENCH_WORK:-$(mktemp -d -t kiln-live-bench)}"
mkdir -p "$WORK"

export MIX_ENV=prod
export PHX_HOST=localhost
export DATABASE_URL="ecto://$PG_USER:$PG_PASS@$PG_HOST/$DB"
export DATABASE_SSL=false
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64 | tr -d '\n')}"
export TOKEN_SIGNING_SECRET="${TOKEN_SIGNING_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}"
export POOL_SIZE="${POOL_SIZE:-10}"

log() { printf '[live-bench %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

psql_admin() {
  PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

cleanup() {
  local rc=$?
  if [ "${KEEP:-}" != "1" ]; then
    log "dropping $DB"
    psql_admin -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
  fi
  log "logs and results in $WORK"
  exit $rc
}
trap cleanup EXIT INT TERM

log "creating $DB"
psql_admin -c "CREATE DATABASE \"$DB\""

log "compiling (MIX_ENV=prod)"
mix compile >"$WORK/compile.log" 2>&1

log "migrating"
mix ash.migrate >"$WORK/migrate.log" 2>&1

log "seeding"
POOL_SIZE=20 mix run scripts/benchmarks/seed.exs >"$WORK/seed.log" 2>&1
grep -E "^(Seed|Done|  [0-9])" "$WORK/seed.log" >&2 || true

log "benchmarking"
BENCH_OUT="$WORK/results.json" mix run scripts/benchmarks/live_blog.exs 2>"$WORK/run.log" |
  tee "$WORK/results.md"
