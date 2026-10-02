# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="search-now-needs-postgresqls-unaccent-extension"></a>

- **Search now needs PostgreSQL's `unaccent` extension; the upgrade migration
  installs it, refolds non-ASCII search rows and rebuilds the title indexes.**
  `unaccent` ships in PostgreSQL's contrib package (the official and pgvector
  images carry it) and is a *trusted* extension, so the database owner can
  create it without superuser; the migration runs `CREATE EXTENSION IF NOT
  EXISTS unaccent` itself. A managed database that does not offer it fails the
  migration at boot — enable it there first.

  The same migration (`*_accent_folding_extensions_1`, generated from the
  `KilnCMS.Search.AccentFolding` custom extension) then, inside its
  transaction:

  - rebuilds every index whose expression calls `kiln_regconfig`
    (`<table>_title_lexemes_index` on each content table) with `REINDEX`,
    which blocks writes to that table while it runs — seconds on a large
    table, milliseconds on a typical site;
  - rewrites `search_vector` on every content row whose title or
    `search_text` holds a non-ASCII character. A pure-ASCII row yields the
    same vector either way and is not touched.

  Nothing to run by hand, and it is expand-safe: the release before this one
  reads the same columns and calls the same function, and simply gets folded
  answers from it once the migration has run. Rolling the pin back leaves the
  folding in place (the down migration restores the stock configurations, but
  the stored vectors stay folded until each row is next saved).
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628))

## Changed

<a id="search-ranks-faster-under-load"></a>

- **Search ranks faster under load: the query is parsed once per statement,
  not once per matching row, and `/api/search` skips an empty entries section.**
  Profiling `/api/search` with the `scripts/benchmarks/` harness put most of a
  common-word search in two statements, the keyword leg of `posts` and of
  `pages`, and `EXPLAIN` showed why: Postgres switches a prepared statement to
  a *generic* plan after five executions on a connection, and on a generic
  plan the query text is a parameter, not a constant. Every expression built
  from it — `plainto_tsquery(kiln_regconfig($2), $3)` in the filter's recheck
  and in both `ts_rank` calls of the `ORDER BY` — was evaluated once per
  matching row: a word on 1,500 posts parsed and stemmed the query 4,500
  times. The ranking itself was cheap; rebuilding its input was not.

  Each of those expressions (the keyword and any-term filters, `search_rank`,
  `search_rank_any`, the title and alias legs' query tsvector, `highlight`
  and `passage`) is now a scalar `(SELECT …)`, which Postgres runs once per
  execution as an InitPlan. Same values, so the same results: the fixed-corpus
  ranking test is unchanged. On the benchmark corpus the posts keyword leg
  went from 17–24 ms to 5 ms on a generic plan. A test explains the real
  generic plan of every statement a search issues and fails if a query-side
  expression appears outside an InitPlan.

  `/api/search` also stops running the entries section on a site with no
  dynamic content type. Its hits were always dropped there (an entry whose
  type does not resolve is not rendered), and finding none cost three reads
  per search.

  Measured before and after with the same harness: see
  [`docs/benchmarks.md`](../benchmarks.md#headless-api-p95-under-50-ms).
  ([#1725](https://github.com/The-Verscienta/kiln_cms/issues/1725))

## Fixed

<a id="search-folds-diacritics"></a>

- **Search folds diacritics: `Zusanli` finds `Zúsānlǐ`, `creme brulee` finds
  `Crème brûlée`, in every full-text leg.**
  `kiln_regconfig/1` resolved a locale to a stock text-search configuration,
  which keeps diacritics, so the two spellings were different lexemes and a
  name was findable only by a reader who typed its marks — pinyin with tone
  marks, Vietnamese, French, Spanish. It now returns `kiln_<language>`
  configurations, copies of the stock ones whose dictionary chain for
  non-ASCII words starts with `unaccent`. Every leg goes through that function
  on both the indexed and the query side, so the keyword, any-term, title,
  alias and prefix legs and the highlight all fold at once, with no call-site
  change. Han text is unaffected, as it was already matched. The trigram legs
  (autocomplete, the fuzzy fallback) compare characters and do not fold.

  The function body is a SQL-standard `BEGIN ATOMIC` body, so each
  configuration is bound by OID when it is created: it resolves under any
  `search_path`, including the empty one `pg_dump` restores with, when the
  expression indexes over it are rebuilt. See the upgrade note for what the
  migration does to existing rows.
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628))

<a id="a-custom-field-flagged-searchable-is-indexed"></a>

- **A custom field flagged `searchable` is indexed with the record's text, so
  search finds a record by a Chinese name or a Latin binomial.**
  `SetSearchText` built `search_text` from the title, SEO fields, excerpt and
  blocks, and never read `custom_fields`, so a record's structured identity
  fields were findable only where its prose repeated them — for a Han name,
  nowhere. `FieldDefinition` gains a `searchable` boolean (default `false`,
  on the Fields screen and in the JSON:API `field_definition` type); a flagged
  field's value is appended after the body as body-weight text. Strings and
  numbers are indexed, and the strings inside a list or map value (a list of
  `{language, name}` pairs); map keys and `id`s are not. Opt-in, because most
  keys are numbers, enums and snapshots that would only add noise.

  `custom_fields` is readable with its record, and search runs under the
  record's read policy, so a flagged value is never shown to a reader who
  could not read the record. Flipping the flag, or deleting a flagged field,
  re-fires the type's published documents, which recomputes their
  `search_text`; a draft catches up on its next save. `names_record` is
  unchanged and separate: it makes a value a *name* (the alias leg).
  ([#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585))

<a id="concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own"></a>

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  `:conclude` took `winner_variant_id` as a `:uuid` argument and wrote it
  straight to the attribute, so the type was the only gate: a non-uuid was
  refused and any well-formed uuid was accepted and stored — one belonging to no
  variant at all, or to a variant of a different experiment on the same site.

  Nothing mis-read it. `Promotion` looks the winner up among *this* experiment's
  arms and answers `:winner_missing`, so no wrong copy was ever written into a
  document. The cost was the row, and the row could not be corrected:
  `winner_variant_id` is `writable? false`, the state machine has no
  `concluded → concluded` transition, and `:update` refuses anything but a
  draft — so all three remedies were shut and nothing short of SQL took the bad
  id back out.

  What it left behind contradicted itself. The Promote button renders on
  `state == :concluded and winner_variant_id`, so it was offered and could never
  succeed, while `winner?/2` matched no row so no `winner` badge showed. The
  page said both "there is a winner to promote" and "no arm won", and the only
  way out was to archive the experiment. The dangling id also shipped in the
  `experiment.concluded` payload, to webhook endpoints, automation rules and
  federation, where nothing could tell it from a real one.

  Ordinary use never produced one. `mix kiln.experiment conclude --winner NAME`
  resolves the name among the experiment's variants and raises on one that is
  not there, and the editor's `<select>` is built from `@experiment.variants` —
  whose options cannot even go stale, because `RefuseWhenRunning` freezes the
  arms for as long as the conclude form is on screen. The action was the only
  layer without the check, which is the layer a crafted LiveView event and any
  other caller of the `conclude_experiment/3` code interface reach.

  `Validations.WinnerIsAVariant` now refuses it, on `field: :winner_variant_id`.
  Concluding with no winner is unchanged — it is a real choice, and the common
  outcome for a test that found no difference. The check reads the arms as the
  system actor with `authorize_with: :error` so it fails closed: a refused read
  answers `[]` under a filter policy, which would otherwise read as "not an arm"
  and refuse a perfectly good winner.
  ([#1851](https://github.com/The-Verscienta/kiln_cms/pull/1851))

