# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



<a id="compound-names"></a>

- **Search matches names written spaced or joined (proposal A5).** A
  downstream TCM catalogue measured `huangqi` reaching Huang Qi at rank 30,
  and `xiaoyaosan` and `He Gu` not reaching their records at all:
  `to_tsvector` splits at spaces and never inside a word, so the title and
  alias legs could not see either spelling as the other. `hybrid/3` gains a
  `compound` leg (`:search_compound`) that rewrites the query one span at a
  time — two or three adjacent words joined, or one word split into two or
  three — and matches the rewrites against titles and `names_record` fields
  at the title leg's weight. A rewrite is made only from the site's name
  terms (`KilnCMS.Search.NameTerms`: the words of published titles and
  flagged names, per organization, cached five minutes), so body text never
  produces one; and a split names a record only when the record's name
  holds the whole split, so `carpet` → `car pet` never finds "Car". A query
  with nothing to rewrite does not run the leg: on a 2,000-record catalogue
  the added work is ~0.07 ms of a 11–18 ms query, and a query that does
  rewrite pays one more index-guarded leg query. `legs` on `/api/search` and
  `/api/ask` hits may now include `compound`.
