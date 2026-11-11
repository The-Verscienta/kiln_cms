#!/usr/bin/env bash
#
# feed_sse.sh — fan-out cost of the change feed's SSE transport, GET /api/feed
# (#2275). See scripts/benchmarks/README.md.
#
#   scripts/benchmarks/feed_sse.sh
#   BENCH_CONNECTIONS=1000,5000 BENCH_PUBLISHES=50 scripts/benchmarks/feed_sse.sh
#
# In order:
#   1. creates its OWN database, kiln_cms_bench_<pid>, and drops it on exit
#      (KEEP=1 keeps it). No other database on the server is touched;
#   2. compiles and migrates a MIX_ENV=prod build against it;
#   3. starts `mix phx.server` in prod as a named node on BENCH_PORT (4100);
#   4. runs feed_sse.exs on a second node: per BENCH_CONNECTIONS value, opens
#      that many real SSE connections over loopback, publishes BENCH_PUBLISHES
#      posts through the domain actions on the server, and times each one to
#      the last connection that received it; then closes them;
#   5. stops the server and drops the database.
#
# No corpus is seeded: the feed's cost per event does not read the corpus.
#
# Results land in $BENCH_WORK (default: a new mktemp dir): results.json,
# results.md and the logs of every step.
#
# Environment:
#   BENCH_WORK       output directory
#   BENCH_PORT       server port (4100)
#   POOL_SIZE        the Repo pool (default 10, the production default)
#   KEEP=1           keep the database afterwards
#   POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD   (localhost / postgres / postgres)
#   plus everything feed_sse.exs reads (BENCH_CONNECTIONS, BENCH_PUBLISHES,
#   BENCH_INTERVAL_MS, BENCH_OPEN_CONCURRENCY).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PG_HOST="${POSTGRES_HOST:-localhost}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-postgres}"
DB="kiln_cms_bench_$$"
WORK="${BENCH_WORK:-$(mktemp -d -t kiln-feed-bench)}"
mkdir -p "$WORK"
COOKIE="kiln-bench-$$-$RANDOM"
HOST_SHORT="$(hostname -s)"
SERVER_NODE="kiln_feed_srv_$$"
SERVER_PID=""

export MIX_ENV=prod
export PORT="${BENCH_PORT:-4100}"
export PHX_HOST=localhost
export DATABASE_URL="ecto://$PG_USER:$PG_PASS@$PG_HOST/$DB"
export DATABASE_SSL=false
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64 | tr -d '\n')}"
export TOKEN_SIGNING_SECRET="${TOKEN_SIGNING_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}"
export POOL_SIZE="${POOL_SIZE:-10}"

log() { printf '[feed-bench %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

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
  # `mix phx.server` under `elixir` can leave its BEAM behind; find it by node
  # name (the BEAM's own argv spells it `-sname`).
  pkill -f -- "-sname $SERVER_NODE" 2>/dev/null || true
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

log "starting the server on :$PORT as $SERVER_NODE@$HOST_SHORT"
# `+K true` and a large port limit are the BEAM defaults on macOS and Linux
# already; the per-process file limit is the shell's (`ulimit -n`).
PHX_SERVER=true elixir --sname "$SERVER_NODE" --cookie "$COOKIE" -S mix phx.server \
  >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 120); do
  if curl -fs -o /dev/null -H "Host: localhost" "http://localhost:$PORT/up"; then break; fi
  sleep 1
done
curl -fsS -o /dev/null -H "Host: localhost" "http://localhost:$PORT/up" ||
  { log "server did not come up; tail of $WORK/server.log:"; tail -n 40 "$WORK/server.log" >&2; exit 1; }

log "benchmarking"
BENCH_SERVER_NODE="$SERVER_NODE@$HOST_SHORT" \
  BENCH_PORT="$PORT" \
  BENCH_OUT="$WORK/results.json" \
  elixir --sname "kiln_feed_cli_$$" --cookie "$COOKIE" -S mix run --no-start \
  scripts/benchmarks/feed_sse.exs 2>"$WORK/run.log" | tee "$WORK/results.md"
