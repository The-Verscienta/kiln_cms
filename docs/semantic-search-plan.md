# Semantic / Hybrid Search — Implementation Plan

**Status:** Phases 0 ✅, 1 ✅, 2 ✅, 3 ✅ done — **and wired in (2026-07-03)**:
the rerank pass shipped (Bumblebee cross-encoder adapter), and hybrid now
powers every user-facing surface — `Search.global/2` sections (public
`/search`, editor palette) fuse both legs over every content type incl.
dynamic entries, and `GET /api/search` exposes it headlessly with
"did you mean" suggestions. The search-roadmap tail closed the same day: a
fuzzy trigram fallback leg in the fusion, taxonomy sections, and facet
counts/filters (`Search.facets/2`, `?facets=true`, public category filter
bar) — see `search-roadmap.md`. **Decisions locked
(2026-06-23):** pgvector available in production Postgres; **local Bumblebee**
embeddings (no hosted API), model `BAAI/bge-small-en-v1.5` (384-d, CLS pooling +
L2 norm); Bumblebee/Nx/EXLA included in the build but the serving only starts
when `semantic: true`; in-Postgres (pgvector + HNSW) preferred over the
Meilisearch already in `docker-compose.yml`.

## Goal
Add meaning-based search alongside the existing `ts_rank` keyword search
(`:search` action in `lib/kiln_cms/cms/content.ex`), self-hosted by default so no
content leaves the box. Ship in thin, independently-mergeable slices, gated
behind config so the default install stays lean.

## Architecture
```
Content create/update
  └─ SetSearchText (before_action)              ← exists today
  └─ EnqueueEmbedding (after_action) ──► Oban: EmbeddingWorker
                                              └─ Embedder.embed(search_text)
                                              └─ write embedding vector + embedded_at

Query "how do I reset my password"
  ├─ keyword leg:  :search          → ts_rank                  (exists today)
  ├─ semantic leg: :search_semantic → embedding <=> q_vec      (new)
  └─ KilnCMS.Search.hybrid/3 → Reciprocal Rank Fusion → (optional rerank top-k)
```
`Embedder` is a behaviour (like `KilnCMS.Storage`): `Bumblebee` adapter is the
local default; an `Http` adapter (Voyage/OpenAI) stays opt-in.

## Phase 0 — Infra & dependencies
- Add `"vector"` to `KilnCMS.Repo.installed_extensions/0`; codegen the
  `CREATE EXTENSION` migration.
- Swap `postgres:17-alpine` → `pgvector/pgvector:pg17` in `docker-compose.yml`.
- Add `{:pgvector, "~> 0.3"}`; register `Pgvector.extensions()` via a
  `KilnCMS.PostgrexTypes` module wired to the Repo (`types:` option).
- Add `{:bumblebee, "~> 0.6"}`, `{:nx, "~> 0.9"}`, `{:exla, "~> 0.9"}` (EXLA as
  the Nx backend). Model: `BAAI/bge-small-en-v1.5` (384-dim). Start an
  `Nx.Serving` (`Bumblebee.Text.text_embedding`) in the supervision tree **only
  when semantic search is enabled**, so default builds skip the model load.

> EXLA is a heavy compile dep (included unconditionally; serving/model only when
> enabled). If that build cost is unacceptable for the lean default, fall back to
> the `Http` embedder as the only built-in and make Bumblebee a documented
> opt-in dep.

## Phase 1 — Embedding storage + pipeline
- Custom Ash type `KilnCMS.Search.Embedding` (`storage_type` `:vector` with the
  model dimension; cast/dump via `Pgvector.Ecto.Vector`).
- On `Content` (shared macro → Page + Post): `attribute :embedding,
  KilnCMS.Search.Embedding` and `attribute :embedded_at, :utc_datetime_usec`
  (internal staleness marker).
- HNSW index via hand-edited migration:
  `CREATE INDEX … USING hnsw (embedding vector_cosine_ops)` per table
  (`custom_indexes` can't express the opclass).
- `Embedder` behaviour + `Bumblebee` adapter (calls the serving) and `Http`
  adapter (`req`). Config-selected, mirroring `KilnCMS.Storage`.
- `EmbeddingWorker` (Oban, `queue: :default`, mirrors `VariantWorker`):
  re-read row, embed `search_text`, write `embedding` + `embedded_at`; skip when
  empty/fresh; no-op on deleted rows.
- `EnqueueEmbedding` change (after_action) on `:create`/`:update` in `Content`,
  beside `SetSearchText`. (Alternative: AshOban trigger on
  `embedded_at < updated_at` — more declarative, auto-batches, higher latency.)
- Backfill: `mix kiln.embed_all` enqueues a worker per existing row.

## Phase 2 — Semantic search action
- `read :search_semantic` on `Content` with a `:query` arg; a `prepare` fn
  embeds the query at runtime and sorts by cosine distance (a `semantic_distance`
  calc taking the query vector as argument, ascending) — same shape as the
  `ts_rank` sort. Reuses the read policy (published-only for anon).
- Interfaces in `cms.ex`: `semantic_search_pages` / `semantic_search_posts`.

### Relevance floor

Nearest-neighbour search always returns neighbours. Sorting by distance orders
results but never rejects any, so left alone the semantic leg answers *every*
query with a full candidate set — and since `hybrid/3` fuses that leg in,
"no results" becomes unreachable for the whole search. Gibberish comes back
looking exactly as confident as a real query.

`semantic_max_distance` is the ceiling that makes an empty result possible:

```elixir
config :kiln_cms, KilnCMS.Search, semantic_max_distance: 0.55
```

Default `nil` (no floor). There is no safe default to ship — pgvector's `<=>`
runs `0` (identical) to `2` (opposed), but where *related* stops is a property
of the model and the corpus, and instruction-tuned embedders like bge cluster
in a narrow high-similarity band. A value tuned for one setup can silently
empty another, and a value measured on a sample of the corpus drifts as the
corpus grows around it.

**Where it applies.** `hybrid/3` — the search page, `/api/search`, `/api/ask`
— applies the floor *after* fusion, to hits only the semantic leg returned. A
record the keyword or fuzzy (title) leg also found is kept whatever its
distance: a lexical match needs no distance alibi. The per-type
`semantic-search` API routes have no other leg, so they filter the leg itself.

The placement matters. Filtering the leg before fusion made the floor the
judge of every row, and a short query naming a record embeds far from that
record's long prose — on an entity-heavy corpus with a floor of 0.35, "huang
qi dang shen" kept two marginal neighbours and dropped both named records, so
the semantic leg fed fusion noise and withheld the answers (the "Why Shen Beat
Huang Qi" report, D2/P3). Junk still returns nothing: with no lexical hit every
fused hit is semantic-only, and every one is over the floor.

**Measuring it.** Write a sheet of queries — one per line, `query<TAB>slug`
for a query that should find a record, a bare line for one that should find
nothing — covering the classes the floor has to serve (single names, name
lists, paraphrases, question forms, junk), then:

```bash
mix kiln.search.measure_floor queries.tsv          # every content type
mix kiln.search.measure_floor queries.tsv --type herb --limit 50
```

It reports each expected record's raw distance against its nearest competitor
and each junk query's nearest neighbour, ignoring any floor already
configured, and proposes the cutoff between the two bands. When they overlap
it says which queries overlap and what each edge would keep and admit — that
is a choice about which error to make, or a sign the corpus wants
`rerank: true` rather than a floor. Since corroborated hits are never floored,
set the value by where the junk band starts, not by the hardest expected
record. The numbers behind the task are `KilnCMS.Search.semantic_neighbours/3`
(`semantic_distances/3` for titles only):

```elixir
KilnCMS.Search.semantic_distances(:page, "a query that should match")
KilnCMS.Search.semantic_distances(:page, "asdfghjkl")
```

## Phase 3 — Hybrid fusion (+ optional rerank)
- `KilnCMS.Search.hybrid(type, query, opts)` runs both legs (top-N each), fuses
  by **Reciprocal Rank Fusion** in Elixir, returns merged records; falls back to
  keyword-only when semantic is disabled.
- Optional `Reranker` behaviour (cross-encoder via Bumblebee, hosted rerank, or
  LLM) over the top-k. Deferred until hybrid quality is proven insufficient.

## Recall is approximate, and filters make it worse (#998)

HNSW is an approximate index, and pgvector applies a query's `WHERE` clauses to
rows the index has **already** chosen. Every semantic query here is filtered —
by `org_id` always (the HNSW index is on `embedding` alone and `all_tenants?:
true`, because HNSW cannot be multicolumn), and often by `block_type`, a
published state, or an excluded document.

With pgvector's default `hnsw.iterative_scan = off` the scan produces one batch
of `ef_search` (40) candidates and stops. Anything the filter rejects is lost,
and nothing distinguishes the short list from a genuinely empty one. Measured on
20 000 rows in one org and 3 in another: a search issued by the small org
returned **zero** rows.

`KilnCMS.Repo` therefore sets `hnsw.iterative_scan = strict_order` on every
connection (`init/2`), so a filtered scan resumes until it satisfies the `LIMIT`
or reaches `hnsw.max_scan_tuples` (default 20 000, which is the bound on the
extra work). `strict_order` rather than `relaxed_order` because callers treat the
ordering as meaningful — relevance floors, near-duplicate thresholds — and
approximate ordering would trade a silent recall bug for a silent ranking one.

Two things follow:

- **Recall is good, not guaranteed.** At the scan-tuple ceiling the answer is
  still a short list. Nothing downstream may claim exhaustiveness — near-
  duplicate detection reads as if it does, and it does not.
- **If searches feel lossy on a large corpus**, raise `hnsw.ef_search` (per
  connection or per transaction) before reaching for a bigger index; it widens
  each batch. `hnsw.scan_mem_multiplier` is the other knob, and buys iterative
  scans more working memory.

### The cost, and the knob that caps it

Iterative scanning is not free, and the cost falls **entirely on filtered scans
that legitimately match nothing** — they walk to `hnsw.max_scan_tuples` before
concluding it. Measured on 50 000 rows × 384-d with the index path forced,
median of 10:

| query | `iterative_scan = off` | `strict_order` |
|---|---|---|
| unfiltered, limit 10 | 1.00 ms | 1.00 ms |
| dominant tenant (49 900 rows) | 1.09 ms | 1.09 ms |
| small tenant (100 rows) | 1.53 ms | 26.9 ms |
| **empty tenant** | 0.97 ms | **80.7 ms** |
| **facet miss** (`block_type` with no rows) | 1.00 ms | **69.3 ms** |

The fast paths are untouched; it is the empty result that got expensive. That
matters because `/api/related` is public and anonymous and is correctly empty
for most documents.

`hnsw.max_scan_tuples` (default 20 000) is the cap. It is deliberately left at
the default here: lowering it trades recall straight back, and choosing a number
needs a **real** corpus to measure recall against — a synthetic one of random
high-dimensional vectors has no meaningful "nearest" to lose, so it cannot
answer the question. If `/api/related` latency becomes a problem on a large
install, lower it there and measure recall on that install's own content.

## Cross-cutting
- **Config flag:** `config :kiln_cms, KilnCMS.Search, semantic: false, embedder:
  KilnCMS.Search.Embedder.Bumblebee, model: "BAAI/bge-small-en-v1.5", dim: 384`.
  Off by default → no serving; hybrid degrades to keyword.
- **Tests:** stub `Embedder` with deterministic vectors for fast unit tests
  (storage, worker, action sort, RRF); one tagged integration test that loads the
  real model. Mirror `content_search_test.exs` with a semantic case.
- **Deployment:** pgvector image/extension; cache the model in the Docker image
  or a volume to avoid cold-start downloads; size the box for inference.
- **Observability:** telemetry on embed latency, queue depth, query `ef_search`.

## Multilingual semantic search

The default model (`bge-small-en-v1.5`) is English-centric: non-English
content embeds poorly and cross-language matches don't work. Swap in a
multilingual model via config — the embedder now exposes the knobs each model
family needs:

- **`pooling`** — `:cls_token_pooling` (default, bge) or `:mean_pooling`
  (MiniLM / e5). Must match the model's training.
- **`query_prefix` / `document_prefix`** — instruction prefixes prepended
  before embedding (`Search.embed_query/1` / `embed_document/1`). Default
  `""`; e5 needs `"query: "` / `"passage: "`.
- **`model` / `dim`** — the HF id and its vector width. `dim` is read at
  **compile time** by `KilnCMS.Search.Vector`, so it defines the
  `vector(N)` column type.

### Recommended: a 384-dim drop-in (no column migration)

`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` is 384-dim
(same as bge-small) and covers 50+ languages, so switching needs **no
migration** — only a re-embed:

```elixir
config :kiln_cms, KilnCMS.Search,
  semantic: true,
  model: "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
  dim: 384,
  pooling: :mean_pooling
```

Then `mix kiln.embed_all` (now covers Page, Post, **and** dynamic entries) —
old English embeddings are meaningless under the new model, so every record
must be recomputed.

### Higher quality: a different-dimension model (needs a migration)

`BAAI/bge-m3` (1024-dim, CLS pooling) or `intfloat/multilingual-e5-base`
(768-dim, mean pooling, `query:`/`passage:` prefixes) are stronger but change
the vector width. Set `dim:` to match, then migrate every content table's
`embedding` column and its HNSW index (the dimension is fixed in the column
type, so this is a one-time destructive-to-embeddings step, followed by
`mix kiln.embed_all`):

```elixir
# priv/repo/migrations/..._widen_embedding.exs
for table <- ~w(pages posts entries)a do
  execute "DROP INDEX IF EXISTS #{table}_embedding_hnsw_index"
  # Old vectors are the wrong width; clear then re-type, then re-embed.
  execute "UPDATE #{table} SET embedding = NULL, embedded_at = NULL"
  alter table(table), do: modify(:embedding, :"vector(1024)")
  execute """
  CREATE INDEX #{table}_embedding_hnsw_index ON #{table}
  USING hnsw (embedding vector_cosine_ops)
  """
end
```

**Reranking** (`bge-reranker-base`) is likewise English-centric; pair a
multilingual embedder with `BAAI/bge-reranker-v2-m3` via `rerank_model:`.

## Risks / open items
1. pgvector in production — **confirmed available**.
2. Local vs hosted embeddings — **local Bumblebee** chosen.
3. EXLA build size in the default image — accept, or gate Bumblebee as opt-in.
4. Meilisearch (already in compose) is the consciously-not-taken alternative.

## Cut line
Ship **Phases 0–2** first (semantic search working + maintained), validate on
real content, **then** add Phase 3 hybrid. Rerank stays on the roadmap.
