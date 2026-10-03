# v1.0 success metrics

The [project plan](../KilnCMS_Project_Plan.md) set five success metrics for
v1.0. This page records what each one measured, when, and how, including the
ones that were missed (#1546). A missed metric is information for the 1.0
decision, not an automatic blocker: the maintainer decides.

| Metric | Result (at 1.0.0, 2026-10-02) |
|---|---|
| [An editor builds a page in under 5 minutes](#editor-page-building-and-beta-feedback) | **Met.** Beta round 2 on `v1.0.0-rc.2`: all 10 testers finished Scenario A in under 5 minutes, average 3:33, with 5 non-technical authors (testers 6–10) |
| [Positive beta feedback](#editor-page-building-and-beta-feedback) | **Met.** Round 2 rated it mostly B+ (about 8/10) and met the v1 bar; the same testers found no issues on `v1.0.0-rc.3` |
| [Test coverage over 80%](#test-coverage-over-80) | **Met.** 87.7% on `main` at `v1.0.0-rc.3`, against a CI floor of 85.8 |
| [Headless API p95 under 50 ms](#headless-api-p95-under-50-ms) | **Partly met** (measured 2026-09-27). Delivery, JSON:API and GraphQL reads: p95 under 43 ms with 50 concurrent clients. Search misses from 10 clients (#1712). The sync API initial page, which missed from 10, is under 15 ms p95 from 10 since #1713 (re-measured 2026-10-02) |
| [Zero-downtime releases](#zero-downtime-releases) | **Not shown.** Migrations are now held to expand/contract in CI (#1716), but no swap has been run under traffic. The maintainer accepted shipping 1.0 without it (decision 2026-10-02) |

## Headless API p95 under 50 ms

**Partly met.** Measured on 2026-09-27 against `main` at `1cc4d3c83`
(v0.12.0), with the benchmark in
[`scripts/benchmarks/`](https://github.com/The-Verscienta/kiln_cms/tree/main/scripts/benchmarks).

- **Met** for content delivery and the JSON:API and GraphQL reads, at every
  concurrency tried: the fired artifact (`/api/content/:type/:slug`) and both
  by-slug reads stay under 7 ms p95 with 50 concurrent clients. The JSON:API
  list page is the slowest of them, at 40–43 ms p95 with 50 clients.
- **Missed** by search: a typical query is inside the target for a single
  client (24–28 ms p95) and outside it from 10 concurrent clients (41–101 ms);
  a query for a word nearly every document contains misses even alone
  (51–79 ms). With 50 clients it takes 0.6–1.2 s, and an earlier run returned
  `500`s from pool exhaustion. The causes, with the profile and `EXPLAIN`
  output, are in #1712.
- **Met** by the sync API's initial page since #1713 (re-measured
  2026-10-02): 3.6–14.1 ms p95 with 10 concurrent clients, where it took
  31–57 ms. With 50 it is met warm (13–47 ms) and still missed cold
  (220–237 ms), when every client finds the artifact cache freshly flushed
  at once. See [Sync initial page, after #1713](#sync-initial-page-after-1713).

The plan's wording is "for typical queries". A reader who counts search as
typical should read this as *missed*.

### How it was measured

| | |
|---|---|
| Machine | Apple M5 Pro, 18 cores, 24 GB, macOS; client, server and PostgreSQL 17 on the same machine |
| Other load | Shared with other work. Load average 9–24 during the recorded run (15–65 during an earlier run, below) |
| Build | `MIX_ENV=prod mix phx.server`, Erlang/OTP 29, Elixir 1.20.1, `POOL_SIZE=10` (the production default), logging at `:info`, lean build (no ML) |
| Database | Its own, created for the run and dropped after it |
| Corpus | 500 pages, 1,500 posts and 200 drafts through the domain actions, 12 categories, 40 tags; 8,000 fired artifacts. Text mixes 70 common words with 3,000 rare ones |
| Load | Closed loop at 1, 10 and 50 concurrent clients. Cold: in-BEAM caches flushed, then 500 requests over distinct keys. Warm: 200 warm-up requests, then 2,000 over the same 50 keys |
| Rate limits | Raised through `config :kiln_cms, KilnCMSWeb.RateLimit, limits:` on the running node; nothing disabled in code |
| Latency | Server side: `[:phoenix, :endpoint, :stop]`, the whole endpoint including rate limiting and tenant resolution. Client p95 is shown for comparison |

### Results

Milliseconds. "Non-200" counts every response that was not a `200`,
including GraphQL answers carrying `errors`; there were none in this run.

| Endpoint | Cache | C | Requests (non-200) | req/s | Server p50 | Server p95 | Server p99 | Client p95 |
|---|---|---|---|---|---|---|---|---|
| jsonapi_list | cold | 1 | 500 (0) | 86 | 9.9 | 11.2 | 14.5 | 12.6 |
| jsonapi_list | warm | 1 | 2000 (0) | 99 | 9.1 | 10.3 | 11.3 | 11.5 |
| jsonapi_list | cold | 10 | 500 (0) | 872 | 9.8 | 12.2 | 14.6 | 14.3 |
| jsonapi_list | warm | 10 | 2000 (0) | 843 | 10.4 | 12.0 | 14.4 | 13.7 |
| jsonapi_list | cold | 50 | 500 (0) | 1020 | 23.3 | 40.3 | 44.5 | 68.6 |
| jsonapi_list | warm | 50 | 2000 (0) | 1083 | 25.3 | 42.7 | 53.9 | 62.7 |
| jsonapi_by_slug | cold | 1 | 500 (0) | 325 | 2.2 | 3.3 | 3.8 | 4.3 |
| jsonapi_by_slug | warm | 1 | 2000 (0) | 351 | 2.1 | 2.6 | 3.1 | 3.4 |
| jsonapi_by_slug | cold | 10 | 500 (0) | 2769 | 2.4 | 2.9 | 3.3 | 4.2 |
| jsonapi_by_slug | warm | 10 | 2000 (0) | 2868 | 2.4 | 3.0 | 3.3 | 4.1 |
| jsonapi_by_slug | cold | 50 | 500 (0) | 4202 | 2.8 | 6.7 | 7.2 | 15.4 |
| jsonapi_by_slug | warm | 50 | 2000 (0) | 4589 | 2.5 | 3.2 | 3.6 | 12.5 |
| graphql_list | cold | 1 | 500 (0) | 293 | 2.3 | 3.2 | 3.7 | 4.0 |
| graphql_list | warm | 1 | 2000 (0) | 314 | 2.5 | 3.7 | 4.1 | 4.6 |
| graphql_list | cold | 10 | 500 (0) | 3567 | 1.8 | 2.9 | 3.9 | 4.2 |
| graphql_list | warm | 10 | 2000 (0) | 3890 | 1.5 | 2.2 | 2.8 | 3.2 |
| graphql_list | cold | 50 | 500 (0) | 5167 | 1.8 | 6.0 | 6.5 | 10.9 |
| graphql_list | warm | 50 | 2000 (0) | 4931 | 1.7 | 5.4 | 6.9 | 19.0 |
| graphql_by_slug | cold | 1 | 500 (0) | 550 | 1.0 | 1.5 | 1.7 | 2.4 |
| graphql_by_slug | warm | 1 | 2000 (0) | 576 | 1.0 | 1.4 | 1.6 | 2.2 |
| graphql_by_slug | cold | 10 | 500 (0) | 4967 | 1.0 | 1.4 | 2.4 | 2.4 |
| graphql_by_slug | warm | 10 | 2000 (0) | 4994 | 1.0 | 1.3 | 1.5 | 2.4 |
| graphql_by_slug | cold | 50 | 500 (0) | 7772 | 1.1 | 1.6 | 2.0 | 6.9 |
| graphql_by_slug | warm | 50 | 2000 (0) | 7117 | 1.1 | 1.9 | 2.9 | 7.9 |
| content_by_slug | cold | 1 | 500 (0) | 380 | 1.7 | 2.2 | 3.4 | 3.2 |
| content_by_slug | warm | 1 | 2000 (0) | 1144 | 0.2 | 0.3 | 0.3 | 1.1 |
| content_by_slug | cold | 10 | 500 (0) | 3527 | 1.6 | 2.4 | 3.7 | 3.5 |
| content_by_slug | warm | 10 | 2000 (0) | 7908 | 0.1 | 0.2 | 0.3 | 1.7 |
| content_by_slug | cold | 50 | 500 (0) | 3682 | 1.9 | 5.7 | 7.6 | 17.3 |
| content_by_slug | warm | 50 | 2000 (0) | 7464 | 0.1 | 0.2 | 0.3 | 7.4 |
| search | cold | 1 | 500 (0) | 46 | 19.6 | 28.4 | 32.2 | 29.5 |
| search | warm | 1 | 2000 (0) | 56 | 16.0 | 24.5 | 27.0 | 25.4 |
| search | cold | 10 | 500 (0) | 367 | 22.8 | 41.0 | 49.5 | 42.3 |
| search | warm | 10 | 2000 (0) | 144 | 77.9 | 100.8 | 110.3 | 101.8 |
| search | cold | 50 | 500 (0) | 112 | 469.2 | 690.3 | 697.4 | 692.6 |
| search | warm | 50 | 2000 (0) | 118 | 425.7 | 595.1 | 693.1 | 596.0 |
| search_common | cold | 1 | 500 (0) | 19 | 47.9 | 79.3 | 100.3 | 80.2 |
| search_common | warm | 1 | 2000 (0) | 25 | 38.8 | 51.3 | 56.7 | 52.5 |
| search_common | cold | 10 | 500 (0) | 110 | 98.9 | 139.1 | 151.8 | 140.0 |
| search_common | warm | 10 | 2000 (0) | 76 | 129.1 | 198.2 | 243.8 | 199.0 |
| search_common | cold | 50 | 500 (0) | 78 | 694.4 | 919.6 | 921.1 | 924.5 |
| search_common | warm | 50 | 2000 (0) | 60 | 824.1 | 1203.9 | 1354.5 | 1205.7 |
| sync_initial | cold | 1 | 500 (0) | 73 | 8.6 | 12.7 | 43.1 | 16.5 |
| sync_initial | warm | 1 | 2000 (0) | 80 | 8.5 | 11.4 | 13.4 | 15.7 |
| sync_initial | cold | 10 | 500 (0) | 335 | 18.4 | 56.6 | 100.7 | 61.4 |
| sync_initial | warm | 10 | 2000 (0) | 446 | 15.2 | 31.2 | 52.5 | 36.1 |
| sync_initial | cold | 50 | 500 (0) | 394 | 93.9 | 270.8 | 318.7 | 278.2 |
| sync_initial | warm | 50 | 2000 (0) | 357 | 119.5 | 214.2 | 272.0 | 224.2 |

The surfaces are the anonymous reads a headless front end makes:

- `jsonapi_list`: `GET /api/json/posts/published?page[limit]=20&page[offset]=N`
- `jsonapi_by_slug`: `GET /api/json/posts/by-slug/:slug?locale=en`
- `graphql_list`, `graphql_by_slug`: `POST /gql` with `publishedPosts(limit: 20, offset: N)` and `postBySlug(slug:, locale: "en")`
- `content_by_slug`: `GET /api/content/post/:slug`, the fired JSON artifact
- `search`: `GET /api/search?q=` a rare word, which a handful of documents contain
- `search_common`: the same with a common word, which nearly every document contains
- `sync_initial`: `GET /api/sync?initial=true&limit=100&type=post|page`

Only the fired artifact reads through an in-BEAM cache, so it is the one
surface where cold and warm differ much: 1.7–1.9 ms p50 cold, 0.1–0.2 ms
warm. The others read PostgreSQL on every request, and their cold and warm
rows differ mostly by noise. Search is the exception in the other
direction: its warm runs repeat the same 50 queries, and its per-query
analytics upsert makes concurrent identical searches wait on one row (#1712).

### Sync initial page, after #1713

Re-measured on 2026-10-02 with the same script, machine and corpus, and only
the sync surface (`BENCH_ENDPOINTS=sync_initial BENCH_PROFILE=sync_initial`).
The machine was busier than on 2026-09-27, and busier during the "after"
runs than the "before" one; the load average is in each row.

Server p95 in milliseconds:

| Cache | C | Before (`cb1bd4f53`) | After, run 1 | After, run 2 |
|---|---|---|---|---|
| cold | 1 | 25.9 | 5.2 | 10.5 |
| warm | 1 | 38.0 | 4.7 | 5.6 |
| cold | 10 | 46.5 | 3.7 | 14.1 |
| warm | 10 | 33.7 | 3.6 | 6.5 |
| cold | 50 | 305.2 | 237.3 | 220.2 |
| warm | 50 | 341.1 (86 × `503`) | 12.9 | 46.7 |
| load average | | 17–20 | 19–36 | 37–46 |

"After, run 1" is the change without the batched artifact read below, and
"run 2" the change as merged. Throughput from 10 clients went from 263–345
to 633–1,449 requests a second.

The serial in-process profile (`BENCH_PROFILE=sync_initial`, 20 requests)
went from 13.6 ms and 4.3 queries a request to 3.3–6.5 ms and 2 queries.
What changed:

- **No re-encoding.** Jason's string escaper, `escape_json_chunk`, had most of
  the own time (9.0 M calls over 20 requests; 215 k after). Each request decoded 100
  stored artifacts and encoded them again. The artifact cache now keeps each
  body's JSON beside it, written in the same insert, and a page embeds it as a
  `Jason.Fragment`.
- **No exposure upsert for rows already there.** The `sync_exposures` bulk
  upsert (2.1 ms a request) took a row lock on every row of the page, so
  concurrent requests for one page waited on each other while holding a
  connection. The page now reads which ids are recorded (0.3–0.6 ms) and
  writes only the rest. The warm 50-client run before the change had 86
  `503`s (pool-queue drops); neither run after it had any.
- **One artifact query per type on a cold page**, not one per document.

The `posts` read was not the problem: `EXPLAIN (ANALYZE, BUFFERS)` at the
corpus scale (1,700 posts, after `ANALYZE`) walks `posts_pkey` in id order and
stops after 110 rows, 0.7 ms, 113 buffers. No index was added.

What remains is the cold 50-client case: 50 requests that all find the
cache empty read and encode the same 100 artifacts at once.

### A second run

An earlier run of the same benchmark, at load average 15–65, gave the same
shape with wider spread. JSON:API list p95 was 11–30 ms, the by-slug reads
and GraphQL 1.6–28 ms, the fired artifact 0.2–3.1 ms, search (common
words only, in that run) 57–61 ms alone and 1.6–2.0 s with 50 clients, when
701 of 2,000 requests failed (586 `500`s from `DBConnection` queue drops,
115 client-side errors). Sync's initial page was 30–33 ms alone and
201–238 ms with 50 clients. Load on the machine moves every number; the
pass/miss verdicts did not change.

### Rerunning

```bash
scripts/benchmarks/api_latency.sh                      # ~10 min on a warm _build/prod
BENCH_PROFILE=search,sync_initial scripts/benchmarks/api_latency.sh
```

[`scripts/benchmarks/README.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/scripts/benchmarks/README.md)
lists every knob. A laptop is not a production server: read these numbers as
an order of magnitude and as a regression baseline, not as capacity.
Compare with the delivery baseline in [`performance.md`](performance.md#baseline),
which measured a single hot document.

## Test coverage over 80%

**Met.** The `Coverage (full suite)` job of CI run
[36945564023](https://github.com/The-Verscienta/kiln_cms/actions/runs/36945564023)
on `main` at `ac52b7fcb` (2026-10-02, the `v1.0.0-rc.3` merge) reports
**87.7%**: 39,710 of 45,270 relevant lines, over 1,050 files, merged from six
shards by `mix kiln.coverage.merge`. At the v0.12.0 merge (`1cc4d3c83`,
2026-09-27, run
[36356671129](https://github.com/The-Verscienta/kiln_cms/actions/runs/36356671129))
it was 87.1%.

That is 7.7 points over the plan's 80%, and 1.9 over the floor CI enforces:
`minimum_coverage` in `coveralls.json` is 85.8 (#1526), and the job fails
below it. The floor is set just under the measured number each time it moves,
so coverage cannot silently slide back under the metric.

## Zero-downtime releases

The plan's wording is "deployed and stable on Coolify with zero-downtime
releases". **This has not been shown.** Nobody has swapped one release for the
next while traffic was flowing and counted the failed requests. The pieces a
rolling deploy needs are present, including, since #1716, a rule that keeps
each migration compatible with the release before it. What is missing is the
demonstration.

**The maintainer accepted shipping 1.0 without it (decision 2026-10-02).**
The metric is recorded as missed, not as met.

### What exists

- **Migrations run on boot, safely in parallel.** The image's `CMD` is
  `bin/migrate && bin/server` ([`deploy.md`](deploy.md#what-happens-at-boot)).
  `Ecto.Migrator` takes a lock, so when several replicas start at once one
  migrates and the others wait. A new container serves nothing until its
  migrations are done.
- **Probes that separate "alive" from "ready".** `GET /live` (no database)
  for restart decisions, `GET /up` (database reachable) for routing decisions
  ([`deploy.md`](deploy.md), *Health endpoints*). A proxy that
  gates on `/up` does not send traffic to a replica that cannot serve it yet.
- **Graceful shutdown on `SIGTERM`, by default.** The release stops the
  application in order. Bandit's listener (Thousand Island) stops accepting
  and gives open connections up to 15 s (`shutdown_timeout`) to finish;
  Phoenix's socket drainer closes LiveView sockets in batches, so clients
  reconnect elsewhere; Oban gives running jobs 15 s
  (`shutdown_grace_period`). None of it is configured by Kiln, so these are
  the libraries' defaults.
- **Multi-node correctness.** Cache purges reach every node (#1138),
  rate-limited auth buckets are counted cluster-wide, and Oban coordinates
  through Postgres. Two releases can run side by side.
- **Platform notes.** [`deploy-platforms.md`](deploy-platforms.md) already
  says that Render's disk turns zero-downtime deploys off (the old instance
  stops before the new one starts), and how to avoid it: use object storage.
- **Expand/contract migrations, enforced** (#1716). Every schema change
  keeps working with the release before it: add first, stop reading, drop
  in a later release ([`releasing.md`](releasing.md#migrations-expand-migrate-contract)).
  `mix kiln.migrations.check` runs on every pull request and fails one that
  adds a drop, rename, type change, `NOT NULL` tightening or blocking index
  build without a `kiln:contract-ok` marker naming the shipped release that
  stopped reading the old shape.
- **Upgrade rehearsal** (#1540, `scripts/upgrade_rehearsal/`) proves that
  a database written by an older release migrates forward and reads back. It
  does not run the old and new code at the same time.

`mix kiln.update` is not part of this picture. It moves a downstream
project's pin to a new upstream release. It says nothing about how the result
is deployed.

### What is missing

1. **A demonstration.** Two releases behind one proxy, a request loop running,
   the old one stopped with `SIGTERM` once the new one reports `/up`, and a
   count of non-2xx responses and connection errors. This was not done for
   #1546: the machine had no proxy (nginx, HAProxy, Caddy, Traefik) to put in
   front of them, and a hand-written proxy would test itself as much as Kiln.
2. **The production target does not roll.** Production for this repository
   is one Coolify container, redeployed by hand
   ([`deploy.md`](deploy.md#platform-notes)). Whether Coolify overlaps the old
   and new containers depends on its rolling-update prerequisites (a health
   check, no fixed container name, no host port binding), and nobody has
   written down which ones this deployment meets. Its health check is `/live`,
   so Coolify's gate is "serving HTTP", not "database reachable".
3. **The parts a schema rule cannot cover.** LiveView sessions reconnect,
   jobs past the grace period are rescued and re-run, and readiness does not
   flip before shutdown; [`releasing.md`](releasing.md#what-zero-downtime-does-and-does-not-cover)
   lists them. The expand/contract check also judges only the migrations a
   pull request adds: the history before #1716 is exempt, including
   `20260919191545_drop_webhook_plaintext_secret.exs`, which dropped a
   column in the same release that stopped reading it.

The smallest honest next step: run the demonstration above against two
consecutive release images, on Coolify or with Docker Compose and Traefik,
and record the error count here.

## Editor page-building and beta feedback

Both metrics are measured in the beta rounds, against a bar written down
before the first round ([`beta-testing.md`](beta-testing.md#the-v1-bar),
#1533): at least 80% of testers finish Scenario A in under 5 minutes, and at
least 5 non-technical authors across at least two rounds. NPS is reported but
is not a gate.

**Round 1** ran on 2026-09-26 and 2026-09-27, against the v0.11.0 image
([roll-up in #1534](https://github.com/The-Verscienta/kiln_cms/issues/1534)).
What it did and did not record:

- **Recorded:** findings, triaged by severity. The one S1 (#1683), the S2 and
  accessibility findings (#1671, #1673, #1674, #1676, #1677) and TOTP re-enrol
  (#1675) were fixed in v0.12.0, along with the security findings. The rest
  are P2 polish on the v1.0.0 milestone.
- **Not recorded:** any Scenario A timing, the number of testers, whether
  they were non-technical, and the NPS answers. So round 1 contributes nothing
  measurable to "an editor builds a page in under 5 minutes" or to "positive
  beta feedback", and it cannot count toward the five-author minimum.

**Round 2** (#59) ran against the published `v1.0.0-rc.2` image, a re-run
after some rc.1 sessions had used a local build
([roll-up in #59](https://github.com/The-Verscienta/kiln_cms/issues/59#issuecomment-5939367749)).
It met the v1 bar:

- **10 testers**: 1–5 technical, **6–10 non-technical authors**. With round 1
  unrecorded, round 2 alone supplied the five-author minimum.
- **Scenario A**: every tester finished in under 5 minutes, average **3:33**.
  That is 100% against the bar's 80%.
- **Rating**: mostly **B+, about 8/10**.
- **Findings**: 0 S1; the S2 findings (#1815, #1843, and #1833, found while
  fixing) were fixed before `v1.0.0-rc.3`, which carried every round-2 fix.
  An earlier batch run on v0.12.1 by mistake (#1800–#1806) was fixed but not
  counted toward the bar.

The same testers then checked `v1.0.0-rc.3` and found no issues.
