# Ask your content (RAG)

Kiln serves **`GET /api/ask?q=…`** — a retrieval-augmented "ask your content"
endpoint over published content ([issue #339](https://github.com/The-Verscienta/kiln_cms/issues/339)).
It finds the passages most relevant to a question and returns them as cited
**sources**, and — when a generator is configured — a synthesized **answer**
grounded in those sources.

## Response

```json
{
  "question": "world",
  "answer": null,
  "generated": false,
  "sources": [
    { "type": "page", "title": "Welcome to KilnCMS", "url": "/welcome",
      "excerpt": "Welcome to KilnCMS … A world-class, Elixir-native headless CMS. …" },
    { "type": "post", "title": "Hello, World", "url": "/blog/hello-world",
      "excerpt": "The first post on a KilnCMS-powered site. …" }
  ]
}
```

Parameters: `q` (the question), optional `locale` and `limit` (max sources,
clamped to 12).

## How it works

- **Retrieval** reuses `KilnCMS.Search.global/2` — the same keyword + semantic
  RRF (reranked) hybrid search behind `/api/search`. It **degrades to keyword**
  when semantic search is disabled, so `/api/ask` works with no model stack;
  turning on semantic search (`config :kiln_cms, KilnCMS.Search, semantic: true`)
  improves retrieval quality automatically.
- **Policy-scoped:** an anonymous request only ever sees published,
  world-readable content (the same read policies as every headless surface), so
  **drafts and gated content can never leak** into an answer or a citation. A
  bearer token widens visibility like other headless endpoints.
- **Generation is a config-gated seam.** Kiln ships **no** generator by default,
  so `/api/ask` returns retrieval-only (`answer: null`, `generated: false`). A
  deployment enables synthesis by implementing `KilnCMS.Ask.Generator` and
  pointing config at it:

  ```elixir
  config :kiln_cms, KilnCMS.Ask, generator: MyApp.LocalLlmGenerator
  ```

  A generator receives the question + retrieved sources and returns
  `{:ok, answer}`. If it errors, the endpoint degrades to retrieval-only rather
  than failing.

## Why the generator is left to the deployment

The intended production generator is an **on-prem / no-egress** model (e.g. a
local endpoint via `req_llm`/`ash_ai`) so content never leaves your
infrastructure — a strong fit for regulated/health content. The *choice* of
model (and its hosting) is an operator decision, so the core ships the retrieval
pipeline + the seam, not a bundled model.

## Content intelligence (#339 phase 2, shipped)

`KilnCMS.Search.Related`, built purely on the existing block embeddings
(D16) — no new model, no egress; every function degrades to empty results
when semantic search is off:

- **Related content** — `related_documents/2`, and public delivery at
  `GET /api/content/:type/:slug/related` (published-only on both ends,
  org-scoped, cacheable): nearest foreign block embeddings to the document's
  centroid, aggregated per document by minimum cosine distance.
- **Near-duplicates** — `near_duplicates/2`: documents within a cosine
  distance threshold (default 0.1), any workflow state — catches a draft
  duplicating live content.
- **Tag suggestions** — `suggest_tags/2`: existing tags ranked by similarity
  to the document's centroid, minus the ones already applied.
- **Content gaps** — `content_gaps/2`: recorded zero-result search queries
  (the search-analytics log), most-searched first — what readers looked for
  and didn't get.

The vector primitive behind them is `BlockEmbedding`'s `:nearest_to_vector`
read (nearest neighbours of an already-computed vector, self-excluded).

### In the editor

The content editor's inspector carries a **Similar content** panel over
`near_duplicates/2` and `suggest_tags/2`.

It loads on an explicit click, never on mount — two pgvector queries plus a
read per neighbour is not a cost every editor open should pay. An empty result
says *why* it is empty (semantic search off, or an unindexed draft) rather than
rendering a blank panel that reads as broken.

**It describes the last published version, and the panel says so.** Both
answers come from stored `BlockEmbedding` rows, which the firing worker writes
on publish — so unsaved edits, and indeed saved draft edits, are invisible to
it. That is worth stating outright rather than leaving an author to infer it
from a stale-looking percentage.

`near_duplicates/2` is the one function here that reports documents in **any**
state — catching a draft that duplicates live content is the point — which
makes it the one that can surface a record the caller may not read. It takes an
`:actor`, and the editor passes one, so a neighbour outside the viewer's
`readable_types` (#332) or audience simply doesn't come back. Callers with no
actor (the public related endpoint, the automation reactions) keep the previous
unauthorized read, which is safe for them: the public endpoint filters to
published-and-public, and the reaction has no viewer.

**Read-only**, deliberately, and for two different reasons. A near-duplicate
tells you two documents overlap; it cannot tell you which is the real one, so
there is no safe action to offer. Tag suggestions are shown next to the Tags
picker rather than applied from the panel, so the author ticks what they are
agreeing to — the same call `KilnCMS.Seo.Links` made about link suggestions
(#541), where auto-insertion was ruled out for the same reason plus a harder
one about the block tree.

For unattended use the seam is the automation reaction, not this panel:
`:flag_duplicates` and `:suggest_tags` already exist as `KilnCMS.Automation`
actions (see [Automation](automation.md)) and run the same functions.

## Later

- A reference **no-egress generator** wired to a local model (the
  `KilnCMS.Ask.Generator` seam stands).
- Content gaps (`content_gaps/2`) have no UI at all — the natural home is the
  analytics dashboard rather than the content editor, since the question is
  about the site, not about a document.
