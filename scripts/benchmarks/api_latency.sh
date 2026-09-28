#!/usr/bin/env bash
#
# api_latency.sh — the headless API latency benchmark behind the v1.0 metric
# "headless API p95 under 50 ms" (#1546). See scripts/benchmarks/README.md.
#
#   scripts/benchmarks/api_latency.sh
#   BENCH_POSTS=5000 BENCH_CONCURRENCY=1,10,50,100 scripts/benchmarks/api_latency.sh
#
# In order:
#   1. creates its OWN database, kiln_cms_bench_<pid>, and drops it on exit
#      (KEEP=1 keeps it). No other database on the server is touched;
#   2. compiles and migrates a MIX_ENV=prod build against it;
#   3. seeds a published corpus through the domain actions (seed.exs) and
#      waits for every document's artifacts to fire;
#   4. boots `mix phx.server` in prod as a named node on BENCH_PORT;
#   5. runs load.exs from a second node: rate limits raised through config on
#      the server, then cold and warm passes per endpoint and concurrency;
#   6. stops the server and drops the database.
#
# Results land in $BENCH_WORK (default: a new mktemp dir): results.json,
# results.md and the logs of every step.
#
# Environment:
#   BENCH_PORT       server port (default 4100, so a dev server on 4000 is left alone)
#   BENCH_WORK       output directory
#   POOL_SIZE        the server's Repo pool (default 10, the production default)
#   KEEP=1           keep the database afterwards
#   POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD   (localhost / postgres / postgres)
#   plus everything seed.exs and load.exs read (BENCH_PAGES, BENCH_POSTS,
#   BENCH_CONCURRENCY, BENCH_WARM_N, BENCH_COLD_N, BENCH_ENDPOINTS).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PG_HOST="${POSTGRES_HOST:-localhost}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-postgres}"
DB="kiln_cms_bench_$$"
WORK="${BENCH_WORK:-$(mktemp -d -t kiln-bench)}"
mkdir -p "$WORK"
COOKIE="kiln-bench-$$-$RANDOM"
HOST_SHORT="$(hostname -s)"
SERVER_NODE="kiln_bench_srv_$$"
SERVER_PID=""

export MIX_ENV=prod
export PORT="${BENCH_PORT:-4100}"
export PHX_HOST=localhost
export DATABASE_URL="ecto://$PG_USER:$PG_PASS@$PG_HOST/$DB"
export DATABASE_SSL=false
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64 | tr -d '\n')}"
export TOKEN_SIGNING_SECRET="${TOKEN_SIGNING_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}"
export POOL_SIZE="${POOL_SIZE:-10}"

log() { printf '[bench %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

psql_admin() {
  PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

cleanup() {
  local rc=$?
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping the server"
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # `mix phx.server` under `elixir` can leave its BEAM behind; find it by node name.
  pkill -f -- "--sname $SERVER_NODE" 2>/dev/null || true
  if [ "${KEEP:-}" != "1" ]; then
    log "dropping $DB"
    psql_admin -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
  fi
  log "logs and results in $WORK"
  exit $rc
}
trap cleanup EXIT INT TERM

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  log "port $PORT is taken; set BENCH_PORT"
  exit 1
fi

log "creating $DB"
psql_admin -c "CREATE DATABASE \"$DB\""

log "compiling (MIX_ENV=prod)"
mix compile >"$WORK/compile.log" 2>&1

log "migrating"
mix ash.migrate >"$WORK/migrate.log" 2>&1

log "seeding"
POOL_SIZE=20 mix run scripts/benchmarks/seed.exs >"$WORK/seed.log" 2>&1
grep -E "^(Seed|Done|  [0-9])" "$WORK/seed.log" >&2 || true

log "starting the server on :$PORT as $SERVER_NODE@$HOST_SHORT"
PHX_SERVER=true elixir --sname "$SERVER_NODE" --cookie "$COOKIE" -S mix phx.server \
  >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 120); do
  if curl -fs -o /dev/null -H "Host: localhost" "http://localhost:$PORT/live"; then break; fi
  sleep 1
done
curl -fsS -o /dev/null -H "Host: localhost" "http://localhost:$PORT/live" ||
  { log "server did not come up; tail of $WORK/server.log:"; tail -n 40 "$WORK/server.log" >&2; exit 1; }

log "benchmarking"
BENCH_SERVER_NODE="$SERVER_NODE@$HOST_SHORT" \
  BENCH_BASE="http://localhost:$PORT" \
  BENCH_OUT="$WORK/results.json" \
  elixir --sname "kiln_bench_cli_$$" --cookie "$COOKIE" -S mix run --no-start \
  scripts/benchmarks/load.exs | tee "$WORK/results.md"
