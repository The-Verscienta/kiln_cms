# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



## Fixed

<a id="global-search-ranks"></a>

- **`global/2` ranks its legs across sections, so fused scores compare (#2175).**
  Each section used to fuse over its own records, so `weight / (k + rank)` used
  a rank within the section. A section with one published record put it at rank
  1 in every leg that returned it, and on `/api/search?q=heat interior` the only
  post (0.0410 = 2.5 / 61) outscored records that matched both terms. A sweep
  now collects every requested content section's legs first. It then ranks the
  keyword, any-term, semantic, block and tag legs over all of them at once, by
  `ts_rank` or cosine distance, with ties sharing a rank, and fuses each section
  at those ranks. The title, alias and fuzzy legs still rank per section. A
  title or alias hit is a record the query names outright, and the fuzzy leg is
  a per-section fallback. A direct `hybrid/3` call is unchanged. Scores from
  `global/2` move, and so does the order within a section where semantic-only
  neighbours were spaced differently. `KilnCMS.Search.RankingStabilityTest` is
  re-pinned for this reason.

<a id="search-warmup-and-budget"></a>

- **Search stays up across a deploy, and a sweep answers within a budget (#2166).**
  Around the 2026-11-02 deploy one production search took 27.6 s. The
  embedding and reranker servings start after the endpoint, so a fresh node
  answered `/live` with 200, the platform swapped traffic onto it, and its
  first searches waited for the servings to compile. Three changes. First,
  `KilnCMS.Search.Warmup` runs one search through the servings after boot,
  and `/live`, `/up` and `/ready` answer 503 until it has (`/ready` says
  `"search": "warming"`). The latch only ever opens, so `/live` stays a
  startup gate, not a restart trigger (#816). It gives up after 90 s, inside
  the image healthcheck's window, and an install with semantic search and
  reranking off opens it at once. Second, `global/2` runs within
  `query_budget` (1500 ms, `:infinity` for none). The query embedding gets
  half of it, a section still running at the deadline is fused from the legs
  it finished, and a reranker that misses it leaves fused order. Work the
  budget gives up on still runs in its `Nx.Serving`, so budgeted embeddings
  are capped at one batch in flight and reranks at `rerank_slots` (4). Past
  that a search skips the leg instead of queueing behind abandoned work. A
  local restart under four search clients with reranking on showed the cap
  is needed: without it, client latency drifted to 10 s while Kiln's own
  timing read 1.5 s. `global_report/2` returns what was cut, and
  `GET /api/search` sends it as `partial` and `incomplete`, with
  `cache-control: no-store` on a cut answer. Third, every search response
  carries `Server-Timing`, one metric per leg. The Bumblebee embedder now
  turns a serving's exit (not running yet, timed out) into an error, so the
  search keeps its keyword legs rather than answering 500. Measurements are
  in `docs/benchmarks.md`.
