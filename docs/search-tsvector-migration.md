# Search `tsvector` optimization — decision & migration path

Closes the Phase 6 follow-up from [#38](https://github.com/The-Verscienta/kiln_cms/issues/38):
*"materialized/generated `tsvector` column if profiling warrants; migration path
documented if a tsvector column is added"* and *"highlight snippets in the admin
search UI"*.

This documents **what changed, why, and how to migrate** (forward and back), so
the move off the original functional index is reproducible and reversible.

## TL;DR

KilnCMS no longer searches a *functional* index over
`to_tsvector('english', search_text)`. It searches a **stored, trigger-maintained,
locale-weighted `search_vector tsvector` column** on `pages`/`posts`, indexed with
a plain GIN. Search results can render a highlighted snippet (`highlight`
calculation → `KilnCMS.Search.Highlight.to_safe_html/1`), surfaced in the admin
search palette (`/editor/search`).

## Why a stored column (not the functional index)

The original design (migrations `add_search_text` + `add_search_gin_index`) used a
functional GIN index whose expression — `to_tsvector('english', coalesce(search_text, ''))`
— had to match the `:search` filter *exactly* for the planner to use it. That
worked but pinned two things we needed to change:

1. **Locale correctness.** The expression hardcodes `'english'`, so non-English
   content was stemmed with English rules and couldn't be scoped per language. A
   functional index can't take a *per-row* text-search config because the
   expression must be `IMMUTABLE` over a single config — it can't read the row's
   `locale`. A **stored column** sidesteps this: a trigger computes the vector
   using the row's own locale at write time.
2. **Field weighting.** Ranking title hits above body hits needs `setweight`,
   which is cleanest to bake into the stored vector once rather than recompute in
   every query.

Profiling note: this was driven by **correctness** (i18n) + **relevance**
(weighting), which is exactly the "if profiling warrants it" trigger the roadmap
called out — the stored vector is the shared substrate both features need (see
items #1 and #5 in [`search-roadmap.md`](./search-roadmap.md)). Recomputing
`to_tsvector` per query and per index entry is also avoided.

## What the migrations do

The change is three ordered migrations under `priv/repo/migrations/`:

| Migration | Effect |
|---|---|
| `20260623213323_drop_old_search_gin` | Drops the functional GIN indexes `{pages,posts}_search_text_gin_index`. |
| `20260623213400_add_locale_weighted_search` | Adds `kiln_regconfig/1`, the trigger function, the `search_vector` column + trigger + GIN index on both tables, and backfills existing rows. |
| `20260623215935_add_media_search` | Adds a functional GIN index on `media_items` (locale-agnostic; media stays English-only for now). |

### The locale → config helper

```sql
CREATE OR REPLACE FUNCTION kiln_regconfig(loc text) RETURNS regconfig AS $$
  SELECT CASE lower(left(coalesce(loc, ''), 2))
    WHEN 'en' THEN 'english'  WHEN 'fr' THEN 'french'  -- … de/es/it/pt/nl/ru/sv/no/da/fi
    ELSE 'simple'             -- unknown locale → no stemming
  END::regconfig
$$ LANGUAGE sql IMMUTABLE;
```

`IMMUTABLE` is required so it can be used inside index/trigger expressions.

### The stored vector + trigger

`search_vector` is **database-only — not an Ash attribute**. A `BEFORE INSERT OR
UPDATE` trigger (`kiln_search_vector_refresh`) recomputes it whenever
`title`/`search_text`/`locale` change:

```sql
NEW.search_vector :=
  setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.title, '')),       'A') ||
  setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.search_text, '')), 'B');
```

Keeping it in the trigger (rather than in `Changes.SetSearchText`) means the
vector stays correct **regardless of how a row is written** — Ash actions, seeds,
raw SQL, or bulk backfills. `Changes.SetSearchText` still maintains the
denormalized **`search_text`** plain-text column (title + SEO + block text); the
trigger derives the vector from it.

The Ash resource declares the *other* search indexes (HNSW for embeddings,
trigram for autocomplete) in `postgres.custom_indexes`, but **not** the
`search_vector` GIN — that index lives in the migration because the column itself
isn't Ash-managed. (See the comment in `lib/kiln_cms/cms/content.ex`.)

## How the app uses it

- **Filter** (`:search` action): `search_vector @@ plainto_tsquery(kiln_regconfig(?), ?)`
- **Rank** (`search_rank` calc): `ts_rank(search_vector, plainto_tsquery(kiln_regconfig(?), ?))`
- **Highlight** (`highlight` calc): `ts_headline(kiln_regconfig(?), coalesce(search_text, ''), …, 'StartSel=<mark>, StopSel=</mark>, …')`
  — note the snippet is taken over `search_text` (the readable plain text), while
  matching/ranking use the weighted `search_vector`.

### Highlight rendering is escape-safe

`ts_headline` does **not** HTML-escape the source text, so the raw `highlight`
value must never be rendered as HTML directly. `KilnCMS.Search.Highlight.to_safe_html/1`
escapes the *entire* snippet first and only then reveals the `<mark>` pair, so the
highlight tag is the only live markup no matter what the content contains. The
admin search palette (`KilnCMSWeb.SearchPaletteLive`, `/editor/search`) loads the
calc via `Search.global(query, highlight: true)` and renders each result's snippet
through it.

## Rollback

`add_locale_weighted_search` is fully reversible — `down/0` drops the triggers,
GIN indexes, `search_vector` columns, and both functions; `drop_old_search_gin`'s
`down/0` recreates the functional indexes. `mix ecto.rollback` over these
migrations returns to the functional-index design. (To actually run on the old
design you'd also revert the `:search`/`search_rank`/`highlight` SQL in
`content.ex` to the `to_tsvector('english', search_text)` form.)

## Extending to a new content type

A new table built on `KilnCMS.CMS.Content` (title + `search_text` + `locale`)
joins this scheme with a one-off migration mirroring the per-table block in
`add_locale_weighted_search`: add the `search_vector` column, the
`<table>_search_vector_trg` trigger using the shared `kiln_search_vector_refresh`
function, the `<table>_search_vector_gin` index, and a backfill `UPDATE`. The
`kiln_regconfig`/trigger functions are global, so they don't need redefining.
