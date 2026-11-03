# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



## Added

<a id="search-explain"></a>

- **Search explain mode: why a hit ranked where it did (#PRNUM).** A site
  comparing Kiln's `/api/search` against Meilisearch could see a hit's `score`
  and `legs`, but nothing like `_rankingScoreDetails`. It had to guess "matched
  some of the words" from the `keyword_any` leg's name. `GET
  /api/search?explain=1`, and `explain: true` on `KilnCMS.Search.hybrid/3` and
  `global/2`, now attach an `explain` object to every content hit
  (`KilnCMS.Search.hit_explain/1`). For each leg it gives the rank fusion used,
  which in a `global/2` sweep is the rank over every section. It also gives
  that rank's contribution to `score` and the raw number the leg ranked by:
  `ts_rank`, cosine distance or trigram similarity. Alongside these are the
  query's terms, which ones the hit's `search_vector` contains, and `coverage`
  (matched / terms). A consumer can sort by coverage and then score without
  re-deriving coverage from snippets. The leg numbers come from the keys
  fusion already collected. The term match adds one query per section, over
  the kept hits only, and the fuzzy leg loads its similarity only under
  explain. Explain is off by default, so the default payload is unchanged. An
  explained response is `private, no-store` with no `ETag`, so it never
  becomes the cached answer for a search URL.

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
