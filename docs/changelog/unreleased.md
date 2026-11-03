# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



## Added

<a id="search-ranking-fixture"></a>

- **An adversarial ranking fixture gates search ranking in CI (A10).** The
  #2175 lone-record defect was found by a downstream site comparing
  `/api/search` with Meilisearch, not by Kiln's CI.
  `test/kiln_cms/search/ranking_fixture_test.exs` now seeds a synthetic corpus
  and scores it with `KilnCMS.Search.Eval` against
  `test/support/fixtures/search_ranking/adversarial.json`. The corpus covers a
  one-record section next to a large one, an exact phrase against its words
  scattered through a ~10,000-word document, a CJK name that another record's
  name contains, a typo and a junk query, a half-typed last word ("huang l")
  and a joined name ("huangqi"). The file's gates fail the test. Ranked per
  section again, `cross_section` recall@25 drops from 1.000 to 0.960 and the
  test fails. The classes the engine does not pass yet, `cjk_name` (r@1 0.5)
  and `joined_name` (r@1 0.0), are recorded as baselines. A run that moves one
  prints a notice rather than failing. Golden sets accept the new class names
  (`cross_section`, `exact_phrase`, `prefix`, `joined_name`, `cjk_name`), so a
  deployment's own set can use them.

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
