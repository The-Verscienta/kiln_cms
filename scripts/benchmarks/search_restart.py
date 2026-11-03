"""Restart a Kiln node under search load and record what clients see (#2166).

    python3 -I scripts/benchmarks/search_restart.py <before|after> <seconds-after-ready> <workers> "$PWD"

See search_restart_boot.exs for the node and its database, and
docs/benchmarks.md ("Search across a restart") for a run.

Starts the node (boot.exs), polls /live every 200 ms from the moment the
process is spawned, and runs <workers> search loops against /api/search the
whole time — including before the probe says ready, which is what a client
sees when nothing gates traffic on the probe. Prints a JSON summary.
"""
import json, os, random, signal, subprocess, sys, threading, time, urllib.request, urllib.error

mode, after_ready, workers, worktree = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
port = os.environ.get("DEMO_PORT", "4100")
base = f"http://127.0.0.1:{port}"
here = os.path.dirname(os.path.abspath(__file__))
words = "kiln clay glaze fire studio vessel porcelain stoneware wheel throw trim bisque".split()

env = dict(os.environ, KILN_ML="1", MIX_ENV="dev", BUMBLEBEE_OFFLINE="true", DEMO_MODE=mode,
           PATH="/opt/homebrew/bin:" + os.environ["PATH"])
work = os.environ.get("BENCH_WORK", "/tmp")
log = open(os.path.join(work, f"search-restart-{mode}.log"), "w")
t0 = time.time()
node = subprocess.Popen(["mix", "run", "--no-start", "--no-halt", os.path.join(here, "search_restart_boot.exs")],
                        cwd=worktree, env=env, stdout=log, stderr=subprocess.STDOUT,
                        start_new_session=True)

stop = threading.Event()
live, searches = [], []
lock = threading.Lock()


def get(url, timeout):
    started = time.time()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            body = r.read()
            return started, time.time(), r.status, body, dict(r.headers)
    except urllib.error.HTTPError as e:
        return started, time.time(), e.code, e.read(), dict(e.headers)
    except (ConnectionRefusedError, urllib.error.URLError) as e:
        reason = getattr(e, "reason", e)
        kind = "refused" if isinstance(reason, ConnectionRefusedError) else f"error:{reason}"
        return started, time.time(), kind, b"", {}
    except Exception as e:  # timeouts, resets
        return started, time.time(), f"error:{type(e).__name__}", b"", {}


def poll_live():
    while not stop.is_set():
        s, e, status, body, _ = get(base + "/live", 2)
        with lock:
            live.append((s - t0, status))
        time.sleep(0.2)


def search_loop():
    while not stop.is_set():
        q = random.choice(words)
        s, e, status, body, headers = get(f"{base}/api/search?q={q}", 60)
        partial = None
        if status == 200:
            try:
                partial = json.loads(body).get("partial")
            except ValueError:
                pass
        with lock:
            searches.append((s - t0, e - s, status, partial, headers.get("server-timing")))
        if status == "refused":
            time.sleep(0.2)


threads = [threading.Thread(target=poll_live, daemon=True)] + \
          [threading.Thread(target=search_loop, daemon=True) for _ in range(workers)]
for t in threads:
    t.start()

ready_at = None
deadline = time.time() + 600
while time.time() < deadline:
    with lock:
        ok = [t for t, s in live if s == 200]
    if ok:
        ready_at = ok[0]
        break
    time.sleep(0.2)

time.sleep(after_ready)
stop.set()
for t in threads:
    t.join(timeout=65)
os.killpg(node.pid, signal.SIGTERM)
node.wait(timeout=60)

first_conn = next((t for t, s in live if s != "refused"), None)
warming = [t for t, s in live if s == 503]


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))] * 1000, 1)


def window(lo, hi):
    rows = [r for r in searches if lo <= r[0] < hi and r[2] != "refused"]
    lat = [r[1] for r in rows if r[2] == 200]
    statuses = {}
    for r in rows:
        statuses[str(r[2])] = statuses.get(str(r[2]), 0) + 1
    return {"answered": len(rows), "statuses": statuses,
            "partial": sum(1 for r in rows if r[3]),
            "p50_ms": pct(lat, 50), "p95_ms": pct(lat, 95), "max_ms": pct(lat, 100)}


end = max((r[0] for r in searches), default=0) + 1
summary = {
    "mode": mode,
    "endpoint_accepting_s": first_conn and round(first_conn, 2),
    "live_first_200_s": ready_at and round(ready_at, 2),
    "live_503_window_s": round(warming[-1] - warming[0], 2) if warming else 0,
    "refused_searches": sum(1 for r in searches if r[2] == "refused"),
    "before_ready": window(first_conn or 0, ready_at or end),
    "after_ready": window(ready_at or end, end),
    "slowest": sorted(([round(r[0], 2), round(r[1] * 1000), r[2], r[3], r[4]] for r in searches if r[2] != "refused"),
                      key=lambda r: -r[1])[:5],
    "sample_server_timing": next((r[4] for r in reversed(searches) if r[4]), None),
}
print(json.dumps(summary, indent=2))
