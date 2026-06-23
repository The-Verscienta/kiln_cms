# Semantic / Hybrid Search — Implementation Plan

**Status:** Phases 0 ✅, 1 ✅, 2 ✅ done (semantic search is usable); Phase 3
(hybrid RRF) next. **Decisions locked
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

## Phase 3 — Hybrid fusion (+ optional rerank)
- `KilnCMS.Search.hybrid(type, query, opts)` runs both legs (top-N each), fuses
  by **Reciprocal Rank Fusion** in Elixir, returns merged records; falls back to
  keyword-only when semantic is disabled.
- Optional `Reranker` behaviour (cross-encoder via Bumblebee, hosted rerank, or
  LLM) over the top-k. Deferred until hybrid quality is proven insufficient.

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

## Risks / open items
1. pgvector in production — **confirmed available**.
2. Local vs hosted embeddings — **local Bumblebee** chosen.
3. EXLA build size in the default image — accept, or gate Bumblebee as opt-in.
4. Meilisearch (already in compose) is the consciously-not-taken alternative.

## Cut line
Ship **Phases 0–2** first (semantic search working + maintained), validate on
real content, **then** add Phase 3 hybrid. Rerank stays on the roadmap.
