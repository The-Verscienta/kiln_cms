# Search Roadmap — specs

Builds on the shipped keyword (`:search`, ts_rank + GIN), semantic
(`:search_semantic`, pgvector/HNSW), and hybrid (`KilnCMS.Search.hybrid/3`, RRF)
search. Each item below is specced to be independently buildable; suggested
phasing is at the end.

> **Status refresh (2026-07-03).** Hybrid is no longer dark-launched: it powers
> every `Search.global/2` content section (public `/search`, the ⌘K palette)
> with the rerank pass applied when enabled, works over any content type
> (dynamic entries included), and is exposed headlessly at `GET /api/search`
> (sectioned hits + public paths + safe highlights + "did you mean").
> Remaining below: facet *counts* (#2), the fuzzy hybrid leg (#6 tail),
> taxonomy coverage (#7 tail), and the multilingual embedding model (#1 caveat).

Conventions: **Effort** S (<½ day) / M (½–1½ days) / L (2+ days). **Risk** is
implementation risk, not blast radius.

---

## 1. Locale-aware search  ·  Effort M–L · Risk M · *shipped*

**Status.** Shipped via the stored, trigger-maintained, locale-weighted
`search_vector` column (`kiln_regconfig/1` + `setweight`). Migration path and
rationale: [`search-tsvector-migration.md`](./search-tsvector-migration.md).

**Problem.** `:search`, the `search_rank` calc, the GIN index, and
`:search_semantic` all hardcode `'english'` (`content.ex:181,247,525`). Content
now carries a `:locale` (i18n). Two bugs: non-English content is stemmed with
English rules, and results aren't scoped to a locale.

**Approach.**
- `KilnCMS.Search.Language.config/1` maps a locale → Postgres regconfig
  (`"en"→"english"`, `"fr"→"french"`, …, unknown → `"simple"` = no stemming).
- The functional GIN index can't take a per-row config (not `IMMUTABLE`).
  Replace the flat `search_text` + functional index with a **stored
  `search_vector tsvector` column**, populated by `Changes.SetSearchText` (or a
  generated column) using the row's locale config, indexed with a plain GIN.
  `:search`/`search_rank` then query `search_vector @@ ...` / `ts_rank(...)`
  with the *query's* locale config.
- Add a `locale` argument (default = config default) to `:search` and
  `:search_semantic`, applied as a filter.
- **Semantic caveat:** `bge-small-en-v1.5` is English-centric. True multilingual
  semantic ranking needs a multilingual model (e.g. `bge-m3`) — a separate
  config decision; the locale *filter* is independent and lands here.

**Touches.** `content.ex` (actions, calc, replace index with stored vector),
new `Search.Language`, `SetSearchText`, migration, config. Pairs with #5.

## 2. Faceted filtering  ·  Effort M · Risk L · *filter args shipped; counts remain*

**Goal.** Combine search with filters: `category_id`, `tag_ids`, `author_id`,
`state`, `locale`, published-date range.

**Approach.**
- Add optional arguments to `:search` / `:search_semantic`; apply as `filter`
  expressions (tags via the existing `Tagging` relationship). `hybrid/3` passes
  the same opts to both legs.
- **Facet counts** (sidebar "Category (12)") are a second step: group-by
  aggregates over the match set — heavier, ship after basic filtering.

**Touches.** `content.ex` search actions, `Search.hybrid/3`, `cms.ex`
interfaces. Phase counts separately.

## 3. Highlighting / snippets  ·  Effort S–M · Risk L · *shipped (#38)*

**Status.** Shipped: a `highlight` calc (`ts_headline` over `search_text`, marking
matches with `<mark>`), rendered escape-safely via
`KilnCMS.Search.Highlight.to_safe_html/1` and surfaced in the admin search palette
(`/editor/search`). See [`search-tsvector-migration.md`](./search-tsvector-migration.md).

**Goal.** Show *why* a result matched — a snippet with the terms marked.

**Approach.**
- A `headline` calculation wrapping `ts_headline(config, search_text, query,
  'StartSel=<mark>, StopSel=</mark>, MaxFragments=2')`, loaded on demand.
- Snippet is over the denormalized `search_text` (concatenated plain text), not
  original blocks — fine for a results snippet.
- **XSS:** only `<mark>` is introduced; HTML-escape the source first / restrict
  delimiters and treat output as the single allowed tag.

**Touches.** `content.ex` (calc), optional default load on `:search`.

## 4. Headless exposure + autocomplete  ·  Effort M · Risk L–M · *shipped (incl. `GET /api/search` hybrid)*

**Problem.** Search is code-interface-only — **not** in GraphQL or JSON:API, so
external frontends can't use it.

**Approach.**
- GraphQL: add `queries do … end` to the Content `graphql` block exposing
  `:search` and `:search_semantic`. JSON:API: add `routes do … end`. Expose
  deliberately (D7), keyset-paginated.
- Hybrid isn't a single Ash action → expose via a thin Absinthe resolver (and/or
  a controller route) that calls `KilnCMS.Search.hybrid/3`.
- **Autocomplete:** a lightweight `:autocomplete` read action (prefix match,
  `to_tsquery(... :*)` or trigram on title), returning minimal fields, hard
  `limit`. Rate-limit public search (Hammer is already wired).

**Touches.** `content.ex` graphql/json_api blocks, a web resolver, router, rate
limit. Enables #10.

## 5. Field-weighted ranking  ·  Effort S–M · Risk L · *pairs with #1*

**Goal.** Title matches outrank body matches.

**Approach.** Build the stored `search_vector` with `setweight`: title `A`,
excerpt/SEO `B`, block body `C` (`setweight(to_tsvector(cfg, title),'A') || …`).
`ts_rank` then weights by section automatically. Strong synergy with #1 — both
want the same materialized vector, so build them together.

**Touches.** `SetSearchText` / generated column, `search_rank` calc.

## 6. Typo tolerance  ·  Effort M · Risk L · *autocomplete trigram + "did you mean" shipped; fuzzy hybrid leg remains*

**Goal.** Match misspellings ("databse" → "database") and power "did you mean".

**Approach.** Enable `pg_trgm`; add a GIN trgm index on `title` (and optionally
`search_text`). Use trigram similarity as a **fallback leg** (when tsquery
yields few hits) or a low-weight third leg in `hybrid/3`. Suggestions via
`similarity()` ranking.

**Touches.** `Repo.installed_extensions`, migration, `hybrid/3` (optional leg),
an `:fuzzy`/suggestion action.

## 7. Broaden coverage  ·  Effort M–L · Risk L–M · *media + entries + `Search.global` shipped; taxonomy remains*

**Goal.** Search media (alt/caption/filename) and taxonomy (category/tag
name+description), not just Page/Post.

**Approach.**
- Add a `search_text` + `:search` to `MediaItem`; optional for `Category`/`Tag`.
- `KilnCMS.Search.global(query, opts)` queries each type and merges (RRF or
  per-type sections). Keep result shape tagged by type.

**Touches.** `media_item.ex` (+ taxonomy), a global facade. Feeds #10.

## 8. Reranking  ·  Effort M–L · Risk M · *shipped (Bumblebee cross-encoder adapter, applied in hybrid/global when enabled)*

**Goal.** Reorder the top-k hybrid results with a stronger relevance model.

**Approach.** `KilnCMS.Search.Reranker` behaviour, optional `rerank: true` stage
in `hybrid/3` over the top ~20. Adapters: local cross-encoder via Bumblebee
(`bge-reranker-base`, another `Nx.Serving`), an LLM judge (Claude), or a hosted
rerank API. Gated like semantic search; off by default.

**Touches.** new `Search.Reranker` + adapter, `hybrid/3`, config, supervision.

## 9. Search analytics  ·  Effort M · Risk L · *shipped*

**Goal.** Learn what users search for — especially **zero-result** queries
(content gaps).

**Approach.** A privacy-first `KilnCMS.Analytics.SearchQuery` resource (query,
result_count, locale, timestamp; **no PII**, matching the existing page-view
analytics ethos). Record from the search entry points (user-initiated only, not
internal/backfill). Reports: top queries, zero-result queries, no-result rate.

**Touches.** `analytics.ex` + new resource + migration, recording hook in the
search facade, a dashboard panel.

## 10. Admin ⌘K global search  ·  Effort M · Risk L · *shipped*

**Goal.** Editor command palette to jump straight to content.

**Approach.** A LiveView modal + JS hook (`Cmd/Ctrl-K`) calling `:autocomplete`
(#4) across types (#7), grouped results, keyboard nav, navigate-to-edit.

**Touches.** an admin LiveComponent + hook, admin layout. Depends on #4, #7.

---

## Suggested phasing

- **A — Relevance core** (`#1` locale + `#5` weighting): shared stored weighted
  `search_vector`; fixes the i18n correctness gap and lifts ranking quality.
- **B — Results experience** (`#2` facets + `#3` highlighting).
- **C — Reach** (`#4` headless + autocomplete, `#6` typo tolerance).
- **D — Breadth & intelligence** (`#7` coverage, `#8` reranking).
- **E — Insight & UX** (`#9` analytics, `#10` ⌘K palette).

Dependencies: #1 & #5 share infrastructure (do together); #10 wants #4 + #7;
#2/#3 are independent enhancements to the existing actions. Start with **A** —
it's a correctness fix plus the biggest relevance win, and contained.
