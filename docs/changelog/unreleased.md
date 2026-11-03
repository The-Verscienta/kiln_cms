# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="han-bigrams-upgrade"></a>

- **The upgrade migration rewrites `search_vector` on every content row whose
  title or `search_text` holds a Han (Chinese) character.** The migration
  (`*_install_kiln_han_grams_v1_extension`, generated from the
  `KilnCMS.Search.HanGrams` custom extension) creates four SQL functions
  (`kiln_han_runs`, `kiln_han_grams`, `kiln_han_tsquery`,
  `kiln_search_vector`), points the shared `kiln_search_vector_refresh()`
  trigger at `kiln_search_vector`, and recomputes the vector of every row
  with Han text in every table that has a `search_vector` — overlay tables
  included, so an overlay runs nothing extra and needs no `mix ash.codegen`.
  A row with no Han yields exactly the vector it had and is not touched.

  The rewrite runs inside the migration's transaction and locks the rows it
  updates: seconds on a large Chinese catalogue, nothing on a site without
  Chinese text. It is expand-safe: the release before this one reads the
  same column with queries that only name whole-run lexemes, which are still
  there. Rolling the pin back restores the old trigger body; the stored
  bigrams stay until each row is next saved, and nothing reads them.
  `KilnCMS.Migrations.add_search_vector/1` computes the new vector for a
  table added after this release.

## Added

<a id="han-bigrams"></a>

- **Chinese text is searchable at the grain it is written in (A8).**
  Postgres has no Chinese segmenter: it reads an unbroken run of ideographs
  as one word, so `本方以吴茱萸为君药` was a single lexeme that neither
  `吴茱萸` nor `茱萸` matched, and a name was findable only where punctuation
  happened to cut it out (`黄连、黄芩`) or where it began a run (the keyword
  leg's prefix match: `黄连` finds `黄连解毒汤`). Verscienta measured both
  engines on their TCM catalogue: `黄连` put Huang Lian at rank 3 among
  formulas containing 黄连, and `吴茱萸` put Wu Zhu Yu at rank 11 —
  Meilisearch did worse (rank 13).

  Two changes:

  - **Bigrams.** `search_vector` now also carries every Han run as
    overlapping character bigrams (`吴茱萸汤` → `吴茱 茱萸 萸汤`; a lone
    character stays a unigram), at the weight of the text it came from,
    after the existing lexemes so no other lexeme's position moves. A new
    leg of `KilnCMS.Search.hybrid/3`, `:han` (`:search_han`), matches the
    query's runs as bigram phrases (`'吴茱' <-> '茱萸'`) at the keyword leg's
    weight, ranked by `ts_rank` over them. It runs only for a query holding
    a Han character; `hit_legs/1` reports it as `:han`, and like `:keyword`
    it vouches for a hit against the semantic floor.
  - **Exactness.** A Han query now also *names* a record whose title, or
    whose `names_record` field, has exactly the query's Han text — the same
    runs, in order, whatever else surrounds them. `黄连` names "Huang Lian
    黄连" and a name field holding `黄连 (huáng lián)`, and not
    `黄连解毒汤`, which merely contains it. Such a record is a `:title` or
    `:alias` hit, at the title leg's weight, so it ranks above records whose
    names contain the query; `ts_rank` cannot say this, since every one of
    them holds the query's lexeme. A query without Han runs the title and
    alias legs exactly as before.

  Non-Chinese search is unchanged: a text without Han stores the same vector,
  and a query without Han runs no new SQL (`RankingStabilityTest` is
  untouched). A Chinese name kept in a custom field that is `searchable` but
  not flagged `names_record` is body text to search, as before: flag it to
  have the query name the record. Simplified and traditional forms (`黄连` /
  `黃連`) are still different text.
