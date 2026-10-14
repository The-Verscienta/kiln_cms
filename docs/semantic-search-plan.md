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
L2 norm); the serving only starts when `semantic: true`, and since #1321
Bumblebee/Nx/EXLA are **not in the build at all** unless `KILN_ML=1` — see
"Building with the ML stack" below; in-Postgres (pgvector + HNSW) preferred
over the Meilisearch already in `docker-compose.yml`.

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
  ├─ block leg:    BlockEmbedding :nearest_to_vector → nearest block per document (D16)
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

> EXLA is a heavy compile dep. This paragraph used to end "if that build cost is
> unacceptable for the lean default, fall back to the `Http` embedder". It was
> unacceptable — see below — and the answer taken was neither of the two offered
> here: the deps became opt-in, the Bumblebee adapter stayed the only built-in.

## Building with the ML stack (`KILN_ML=1`)

Bumblebee, Nx and EXLA are **left out of the dependency tree** unless `KILN_ML`
is set to an on-spelling (#1321). They are 671 MB of `deps/` — 773 MB with them,
102 MB without, `deps/exla` alone accounting for 666 MB — plus a one-time 110 MB
download of the prebuilt XLA archive, which is not a price a first `mix setup`
should pay for a feature that ships `semantic: false`. `only: [:dev, :test]` did
not avoid it: `mix deps.get` fetches every dependency regardless of `:only`,
which filters compilation, not the download.

The cost is disk and bandwidth rather than time: adding the whole stack to an
otherwise-complete build measured ~46 s on an Apple Silicon laptop, of which the
EXLA NIF was ~16 s. EXLA links against a **prebuilt** `xla_extension` archive
and compiles only its own eight C++ files; the "~13 min" figure that used to sit
in `mix.exs` describes building XLA itself (`XLA_BUILD=1`), which nothing here
asks for.

```bash
KILN_ML=1 mix deps.get
KILN_ML=1 mix compile
```

Keep the variable exported for every subsequent `mix` invocation — it decides
the dependency tree, so a `mix test` without it compiles the other shape.

**What a lean build does instead.** `KilnCMS.Search.ML.available?/0` is the
compile-time answer, and every module on this path is compiled in one of two
shapes around it: `KilnCMS.Search.Embedder.Bumblebee.embed/1` and
`KilnCMS.Search.Reranker.Bumblebee.scores/2` return
`{:error, %KilnCMS.Search.ML.NotCompiledError{}}` — the `{:error, term()}` their
behaviours already document, which callers already treat as "no vector" —
`KilnCMS.Application` starts no serving, and hybrid search runs its keyword,
title, alias, block and tag legs without the semantic one. An install that has
set `semantic: true` on a lean build is told so once at boot.

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
— applies the floor *after* fusion, to hits only the judged legs returned —
by default the semantic legs alone (see "Which legs it judges" below). A
record any other leg (keyword, its any-term relaxation, title, alias or fuzzy)
also found is kept whatever its distance: a lexical match needs no distance
alibi. The per-type `semantic-search` API routes have no fusion to leave it
to, so they filter the leg themselves — exempting a row the query names (by
title, or by a field flagged as a name), the way the title and alias legs do
in hybrid search, but not a row only the keyword, any-term or fuzzy legs vouch
for. A named row also ranks *first* there, as it does in hybrid search: a
record's one vector is embedded from its whole text, so a long record sits far
from a bare-name query, and a named row left at its distance rank fell below
short records whose names merely sound alike (Verscienta, 2026-09-28: 14 of
602 acupuncture points missed their own name's top 10). Ranking a named row
first costs the HNSW plan for that query — the distance no longer leads the
`ORDER BY` — so Postgres computes every admitted row's distance; a query that
names nothing keeps the index. One value, two (close) edges, and
the measurement below labels both. A non-numeric value raises on first use rather than comparing
as "greater than every distance" and flooring nothing.

The placement matters. Filtering the leg before fusion made the floor the
judge of every row, and a short query naming a record embeds far from that
record's long prose — on an entity-heavy corpus with a floor of 0.35, "pad
thai tom yum" kept two marginal neighbours and dropped both named records,
so the semantic leg fed fusion noise and withheld the answers (the 2026-09-04
search-ranking report, D2/P3). Junk still returns nothing: with no lexical hit
every fused hit is semantic-only, and every one is over the floor.

**Which legs it judges (#1936).** "No lexical hit" turned out to be the catch
on a corpus of long prose. A several-word junk query ("best pizza near me")
shares one ordinary word, or a prefix of its last word, with dozens of long
documents; the any-term relaxation (`keyword_any`) admits every one, and the
floor never looked at them. Measured on a production deployment (bge-small,
floor 0.35), that leg was behind 21 of 40 and 20 of 32 junk failures on two
independent query sets — and no floor value inside the old rule could help,
because the semantic-only hits it judged overlapped the junk band.

`semantic_floor_legs` names the legs whose hits the floor judges; a hit is
floored only when *every* leg that returned it is listed:

```elixir
config :kiln_cms, KilnCMS.Search,
  semantic_max_distance: 0.39,
  semantic_floor_legs: [:semantic, :block, :tag, :keyword_any]
```

The default, `[:semantic, :block, :tag]`, is the v1.1.0 rule exactly. The
three semantic legs are required (dropping one would reopen #871 for its
hits); `:keyword_any` and `:fuzzy` are the optional additions; `:keyword`,
`:title` and `:alias` vouch for a hit — every term matched, or the query names
the record — and listing one raises. A judged lexical hit is measured by the
nearest distance it has: the semantic leg's reading of it, else its document
distance read for it, its nearest block's, and its tag's. One with no vector
at all (not yet embedded, or the query could not be embedded) is kept — a
lexical match with nothing to judge it by is still a match.

Simulated on the same deployment's hit lists, judging `keyword_any` at a floor
of 0.37–0.40 let 40 of 45 and 29 of 32 junk queries return nothing, keeping
every one of the 23 + 5 real hits it judged. That is a direction, not a value:
the decisive band was the farthest real `keyword_any`-only hit (0.370) against
the nearest junk one (0.405). Measure your own before you copy a number.

**Long documents.** A document's vector covers its first ~512 tokens. A query
that matches only a late passage of a long document is judged, under
`:keyword_any`, by a vector that never saw that passage — in the issue's
late-passage probe, half of 100 such targets sat beyond the 0.39 floor. A
deployment that judges `:keyword_any` should have chunked document vectors
(#1940, `chunk_long_documents`), so the late passage has a vector the floor
can find, or accept that blind spot.

**The IDF-coverage variant.** Preregistered on #1936 and shipped opt-in so a
deployment can measure it rather than adopted as a rule:
`keyword_any_idf_coverage: x` (or `SEARCH_KEYWORD_ANY_IDF_COVERAGE`) keeps a
judged `keyword_any` hit beyond the floor when the query lexemes it matches
carry at least `x` of the query's IDF mass. Lexemes are the keyword legs' own
`plainto_tsquery(kiln_regconfig(locale), …)` parse, each once, with the last
matched as a prefix; IDF is `ln(1 + (N − df + 0.5) / (df + 0.5))` per section
(content type and locale) over its published documents, read under the
caller's tenant and policies like every leg. The whole definition is part of
the variant — `KilnCMS.Search.keyword_any_idf_coverage/0` spells it out. Off
(`nil`) by default; it acts only while `:keyword_any` is judged, and costs two
queries per section only when a judged `keyword_any` hit is beyond the floor.

**Runtime overrides.** `SEARCH_SEMANTIC_MAX_DISTANCE`,
`SEARCH_SEMANTIC_FLOOR_LEGS` and `SEARCH_KEYWORD_ANY_IDF_COVERAGE` override the
compiled values at boot ([environment-variables.md](environment-variables.md#search-relevance-floor-1936)),
so none of them needs a rebuild. That matters most for a **model swap**: while
the corpus re-embeds into the new model's space, distances between a new query
vector and an old document vector mean nothing, so the runbook runs the floor
at `0.0` for the window — every judged hit with a vector is dropped, lexical
hits stay — with `keyword_any` out of the floor legs, then re-measures and sets
the new model's floor. Before this it was a deploy each way.

**Measuring it.** Use the golden set `mix kiln.search.eval` scores
([search-roadmap.md](search-roadmap.md) §11, *Ranking eval harness*) — rows of
`query`, `expected` slugs, `class`, and optionally `type` (give one when the
slug exists in more than one type) and `locale`; a `junk` row expects nothing
— covering the classes the floor has to serve, then:

```bash
mix kiln.search.measure_floor golden.json          # every content type
mix kiln.search.measure_floor golden.json --type recipe --limit 50
mix kiln.search.measure_floor golden.json --org acme --locale fr
```

It measures each query through **the semantic leg hybrid search runs** — the
query's locale, embedded and published rows only, a dynamic type within its
own definition — and reports each expected record's raw distance against its
nearest competitor and each junk query's nearest neighbour, ignoring any
floor already configured, with the bands overall and per class. When they
separate it proposes the midpoint; when they overlap it says which queries
overlap and what each edge would keep and admit — that is a choice about
which error to make, or a sign the corpus wants `rerank: true` rather than a
floor. The two surfaces want different edges: hybrid search never floors a
corroborated hit, so set it at the junk edge for the search page and the
APIs; the per-type routes exempt only a title match, so they return a record
reached by its prose alone only from the expected edge up. The numbers behind the task are
`KilnCMS.Search.semantic_neighbours/3` (`semantic_distances/3` for titles
only):

```elixir
KilnCMS.Search.semantic_distances(:page, "a query that should match")
KilnCMS.Search.semantic_distances(:page, "asdfghjkl")
```

The task measures documents' distances; it does not split them by which leg
would have returned each hit, so it cannot report the `keyword_any` band (the
farthest real hit only that leg finds against the nearest junk one) that
judging `:keyword_any` turns on. Take that band from `hybrid/3`'s `legs`
provenance (`/api/search` returns it per hit) with the floor at `2.0`, as
#1936's measurement did.

## Block leg (2026-09-11)

A document's embedding covers the first ~512 tokens of its `search_text`, so a
long monograph's vector describes its opening and nothing after it. The
per-block embeddings the fire pipeline writes (`KilnCMS.Search.BlockIndexer`,
D16) describe each section; `hybrid/3` now fuses a **block leg** — documents
ranked by their nearest block, one entry per document — at the semantic leg's
weight, reported as `block` in `legs`. The relevance floor judges a hit only
the semantic legs returned by the nearer of its document and block distances,
so a section within the floor keeps a document whose opening is not. On
wherever semantic search is on (`block_leg: false` switches it off); block
rows exist for fired documents only, so a draft is reached by the other legs.
It sits out under facet filters, like the fuzzy leg.

## Alias leg (2026-09-11)

A title is not always the only name a record answers to: an herb has a Latin
binomial and a pinyin spelling, a product a trade name. Those live in custom
fields, which the keyword leg indexes as prose but nothing treated as a
*name*. Flag a field **Names the record** in the field editor
(`names_record` on `KilnCMS.CMS.FieldDefinition`) and the **alias leg** runs
the title leg's phrase match over it — a query containing the value finds the
record, at the title leg's weight, reported as `alias` in `legs` — and the
per-type `semantic-search` routes exempt a record so named from the relevance
floor, as they do for its title. Per-site, cached with the type registry
(`KilnCMS.CMS.NameFields`), and free for every type with nothing flagged.
Text fields only in practice: the value is matched as text.

## Tag leg (2026-09-11)

A tag is an editor's statement of what a document is *about*. The **tag leg**
embeds nothing new: the tag-name vectors `KilnCMS.Search.TagEmbedding` holds
(now written on every tag create and rename by
`KilnCMS.Search.TagEmbeddingWorker`, and backfilled by `mix kiln.embed_all`)
are searched for the tags within `tag_leg_threshold` of the query (default:
the measured `suggest_tags_threshold`), at most `tag_leg_limit` (5) of them,
and every document carrying one joins fusion at half weight — a topic match,
reported as `tag` in `legs`, never enough to outrank a lexical or semantic hit
on its own. The relevance floor judges a tag-only hit by its tag's distance.
On wherever semantic search is on (`tag_leg: false` switches it off); sits
out under facet filters.

## Phase 3 — Hybrid fusion (+ optional rerank)
- `KilnCMS.Search.hybrid(type, query, opts)` runs both legs (top-N each), fuses
  by **Reciprocal Rank Fusion** in Elixir, returns merged records; falls back to
  keyword-only when semantic is disabled.
- Optional `Reranker` behaviour (cross-encoder via Bumblebee, hosted rerank, or
  LLM) over the top-k. Deferred until hybrid quality is proven insufficient.
- **Two scopes (2026-09-04).** `config :kiln_cms, KilnCMS.Search, rerank: true`
  reranks every surface on every query; `config :kiln_cms, KilnCMS.Ask, rerank:
  true` (`ASK_RERANK=true`) reranks only `/api/ask`'s bounded, per-question
  candidate set — at most `limit` per content type — and its cross-type sort
  then *is* a rerank of the union, every section scored by the same model for
  the same question. `Search.global/2` takes `rerank: true | false` to carry a
  caller's verdict down, and `hybrid/3`'s `rerank: true` is the whole gate; the
  model loads at boot when either switch is on. Reranking fixes ordering, not
  recall, and is CPU inference — see [rag.md](rag.md#reranking-ask-sources)
  for the report's two caveats before turning either on.

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
  `""`; e5 needs `"query: "` / `"passage: "`. Every content-side vector takes
  `document_prefix` — document, tag name, and block (as
  `document_prefix <> title <> "\n\n" <> block text`, the context line after
  the prefix) — and every query takes `query_prefix`, including the block
  leg's and `BlockSearch`'s (#1939).
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

### Re-embedding after a swap: documents, tags **and blocks**

`mix kiln.embed_all` re-embeds document vectors and tag names. It does not
touch **block** vectors (`block_embeddings`, the block leg): those are written
only by firing, so they are re-indexed by a firing sweep —
`mix kiln.refire_all`, or `bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"` on a
release. A swap needs both.

A block is re-embedded only when its `content_hash` changes. That hash covers
the block text, its ancestor context and, when set, `document_prefix`, so a
swap that changes `document_prefix` (any e5 model) re-embeds every block on
the sweep. A swap that keeps the prefixes (bge-small → MiniLM above) leaves
the hashes equal, and the sweep skips every block as unchanged — clear the
block rows first (`DELETE FROM block_embeddings`) so the sweep rebuilds them.
Changing only `query_prefix` needs no re-embed: queries are embedded when
they are asked.

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
3. EXLA build size in the default image — **resolved (#1321): gated**. The
   deps are opt-in behind `KILN_ML`; the Bumblebee adapter remains the only
   built-in embedder, and a lean build reports semantic search unavailable
   rather than losing the adapter.
4. Meilisearch (already in compose) is the consciously-not-taken alternative.

## Cut line
Ship **Phases 0–2** first (semantic search working + maintained), validate on
real content, **then** add Phase 3 hybrid. Rerank stays on the roadmap.
