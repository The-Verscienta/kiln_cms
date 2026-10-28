#!/usr/bin/env bash
#
# subtree_move.sh — what moving a section with a large subtree costs (#1903).
# See scripts/benchmarks/README.md.
#
#   scripts/benchmarks/subtree_move.sh
#   BENCH_ROWS=10000 BENCH_SUBTREES=100,1000 scripts/benchmarks/subtree_move.sh
#
# In order:
#   1. creates its OWN database, kiln_cms_bench_<pid>, and drops it on exit
#      (KEEP=1 keeps it). No other database on the server is touched;
#   2. compiles and migrates a MIX_ENV=prod build against it;
#   3. runs subtree_move.exs: one leg per BENCH_SUBTREES value;
#   4. drops the database.
#
# Results land in $BENCH_WORK (default: a new mktemp dir): results.json,
# results.md and the logs of every step.
#
# Environment:
#   BENCH_WORK       output directory
#   POOL_SIZE        the Repo pool (default 10, the production default)
#   KEEP=1           keep the database afterwards
#   POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD   (localhost / postgres / postgres)
#   plus BENCH_ROWS and BENCH_SUBTREES (see subtree_move.exs).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PG_HOST="${POSTGRES_HOST:-localhost}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-postgres}"
DB="kiln_cms_bench_$$"
WORK="${BENCH_WORK:-$(mktemp -d -t kiln-subtree-bench)}"
mkdir -p "$WORK"

export MIX_ENV=prod
export PHX_HOST=localhost
export DATABASE_URL="ecto://$PG_USER:$PG_PASS@$PG_HOST/$DB"
export DATABASE_SSL=false
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64 | tr -d '\n')}"
export TOKEN_SIGNING_SECRET="${TOKEN_SIGNING_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}"
export POOL_SIZE="${POOL_SIZE:-10}"

log() { printf '[subtree-bench %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

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

log "benchmarking"
BENCH_OUT="$WORK/results.json" mix run scripts/benchmarks/subtree_move.exs 2>"$WORK/run.log" |
  tee "$WORK/results.md"
