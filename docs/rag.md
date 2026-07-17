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

## Phase 2

- A reference **no-egress generator** wired to a local model.
- The same retrieved-context plumbing powers the rest of #339: **related
  content**, near-duplicate detection, auto-tagging, and content-gap analysis.
