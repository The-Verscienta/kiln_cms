# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="a-new-index-on-every-content-tables-titles-is-built-concurrently-by-the"></a>

- **A new index on every content table's titles is built `CONCURRENTLY` by
  the migration; if it is interrupted, drop the invalid index and migrate
  again.** The migration (`search_title_lexemes_index`) adds a GIN index,
  `<table>_title_lexemes_index`, to `pages`, `posts`, `entries` and — when
  their own migrations are next generated — every project content type. It
  runs outside a transaction so the table keeps taking writes while it
  builds; it measured about 20 µs a row (35 ms for 1,700 posts), so a
  million-row table is a matter of seconds, not a maintenance window. The
  cost of `CONCURRENTLY` is that a build killed half-way leaves an `INVALID`
  index behind under the same name, and the next `mix ash.migrate` fails on
  it: `DROP INDEX CONCURRENTLY <table>_title_lexemes_index;` and run it again
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712)).

## Fixed

<a id="search-holds-at-most-two-pooled-connections-and-answers-503-rather-than-500"></a>

- **Search holds at most two pooled connections, and answers `503` rather
  than `500` when the pool is full.** `GET /api/search` also writes its
  analytics off the request now, and sends `Retry-After` with the `503`.
  Found by the v1.0 latency benchmark: at 50 concurrent clients search's p95 was 0.4–2.2 s,
  and an earlier run answered hundreds of `500`s — `connection not available
  and request was dropped from queue` — while every other API surface stayed
  under 50 ms. `Search.global/2` ran up to four sections at once, each with a
  query in flight, so two and a half searches filled a 10-connection pool;
  `section_concurrency` now defaults to 2 (a lone search is still twice as
  fast as at 1, and a busy node was no slower). Holding one checkout for the
  whole search was tried first and rejected: the benchmark answered nearly
  every request of a ten-client run with a 503, because a held connection
  idles across work that needs the pool too. The title leg built a tsquery
  from every title on every search — a sequential scan, 6–7 ms on 1,700
  posts whether anything matched or not; a GIN index on each title's
  lexemes, and a prefilter on it that the phrase match implies (so it
  returns the same rows), make it 0.04–0.5 ms. Every leg read whole rows —
  block trees, `search_text`, the embedding — to keep ids; the legs now read
  ids, the hits kept are read once with their calculations, and
  `/api/search` reads only the fields it renders (so does its "did you
  mean"). `/api/search` wrote the `search_queries` upsert inline, where
  concurrent searches for one term queued on its row lock holding
  connections; it now goes through the bounded task supervisor like the
  editor palette's (`docs/performance.md` said it already did). And the
  endpoint no longer runs the media section it never returned. Warm p95,
  before → after: 52 → 26 ms for one client and 438 → 314 ms for fifty on a
  rare word; 67 → 36 ms and 2,161 → 574 ms on a word every document
  contains, at three times the throughput. Ranking is unchanged — a new test
  pins the exact ranked output, scores and legs of a fixed corpus,
  keyword-only and hybrid, as recorded before the change. The full table is
  in [`docs/performance.md`](../performance.md#search-and-the-pool)
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712)).

