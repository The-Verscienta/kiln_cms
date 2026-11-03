# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="field-role-weights-upgrade"></a>

- **Run the re-fire sweep after deploying; overlays first run `mix ash.codegen`
  (#2175, A3).** Every content table gains a nullable `search_weighted` column:
  `pages`, `posts` and `entries` in core, and each overlay content table through
  the overlay's own codegen. An overlay's reads fail until that column exists.
  No overlay needs a trigger migration, because the one shared
  `kiln_search_vector_refresh()` function looks for the column on each table it
  runs for. The column's values are computed in Elixir, so the migration cannot
  backfill them. Until a row is re-saved or re-fired it keeps the old vector, with
  the title at `A` and all its other text at `B`, and a corpus that is half old
  and half new ranks unevenly. `mix kiln.refire_all` fills every published
  document (`/app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"` on a release).
  A draft is filled on its next save.

## Changed

<a id="field-role-weights"></a>

- **Keyword search weights a record's text by role and scores phrase proximity
  (#2175, A3).** `search_vector` used to hold the title at `A` and everything
  else at `B`, and `ts_rank` saturated near 1 on any long document that repeated
  the query's words. A monograph that scattered "clears", "heat", "dries" and
  "dampness" therefore outranked the record whose own field says "clears heat
  and dries dampness" (0.97 against 0.95).

  The vector is now built from `search_weighted`, which
  `KilnCMS.CMS.Changes.SetSearchText` writes beside `search_text`:

  - `A`: the title, and every `names_record` field, searchable or not;
  - `B`: the summary fields (`seo_title`, `seo_description`, `seo_keywords`,
    `excerpt`) and the first 48 words of the searchable custom fields, in
    extractor order;
  - `C`: the rest of those fields;
  - `D`: the body.

  `search_rank` and `search_rank_any` use `ts_rank_cd`. A query of two or more
  words adds the score of its phrase (`phraseto_tsquery`, last word as a
  prefix). Cover density alone still let repetition win inside one field
  ("Intensely bitter and cold." scored 0.20 against 0.28 for a field that
  repeats "bitter" and "cold" apart); the phrase score settles it. Every content
  table ranks with the same expression over the same weights, so `global/2` can
  still compare keyword ranks across sections. A field definition reports the
  weight its text gets as the `search_weight` calculation (`"A"`, `"B"` or nil).

  The trigger keeps the old vector for a row whose `search_weighted` is nil. It
  does the same when an update changes `title` or `search_text` and leaves
  `search_weighted` alone, which is what the previous release writes during a
  rolling deploy; the stale buckets are cleared. `RankingStabilityTest` moved on
  one query. On "pad thai tom yum", Pad Thai and Tom Yum, whose titles carry the
  words, now lead the any-term leg over Thai Street Food, which names all four
  in its body. Fused scores moved by one or two reciprocal ranks in that leg, and
  no result changed position.
