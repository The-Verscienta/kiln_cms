# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

<a id="term-evidence-gate"></a>

- **Hybrid search tells a typo from junk by the query's words, not by a score
  (A6).** A downstream deployment benchmarked `/api/search` against
  Meilisearch on a held-out set and found no score threshold, in either
  engine, that separated the two: Meilisearch's floor rejected all the junk
  and every typo with it, and Kiln passed 17–19 of 40 junk queries while
  missing typos. Both kinds arrive with an empty keyword leg and are answered
  by the legs that always answer — the semantic neighbours, the any-term
  relaxation's one shared word, the trigram guesses.

  `KilnCMS.Search.term_gate/0` (on by default) now reads, for a section whose
  keyword leg is empty, each query term against the section's vocabulary:
  its `search_vector`, its records' names (title, `names_record` fields, tag
  names), and words within one edit (two from eight letters) of those names,
  through the new `fuzzystrmatch` extension. When fewer than 60% of the terms
  have any such evidence (50% when one term is a record's name outright), the
  query is junk, and only the keyword, title and alias legs may answer it —
  in practice nothing comes back. A term one edit from a name is a typo, and
  the fuzzy leg also runs on the corrected query: "gui zi tang" finds Gui Zhi
  Tang, "saffon" now finds Saffron Rice, which trigrams alone never reached.

  What it costs is the synonym-only query — a word the corpus never uses that
  the semantic leg would have answered ("licorice" for a corpus that says
  "glycyrrhiza"). That now returns nothing. `SEARCH_TERM_GATE=false` (or
  `term_gate: false`) turns the gate off; `SEARCH_TERM_GATE_MIN_SHARE` or
  `term_gate: [min_share: …]` retunes it. `KilnCMS.Search.term_evidence/3`
  shows the verdict for a query. The migration adds the extension only.
