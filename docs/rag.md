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
  "generation": "disabled",
  "retry_after": null,
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

### Why there is no generated answer

The endpoint **always answers 200**: when generation does not run you still get
the cited sources, which are a useful answer on their own, and a 429 for a
partial result would be worse. `generated: false` therefore covers several
situations that a client should treat differently, so `generation` names which
one it was:

| `generation` | Meaning | Recovery |
| --- | --- | --- |
| `null` | An answer was generated. | — |
| `"disabled"` | No generator configured — the default install. | None. Stop offering generated answers. |
| `"rate_limited"` | A generation budget is exhausted. | Retry after `retry_after` seconds. |
| `"failed"` | The generator errored, timed out, or returned nothing usable. | Retry, but no deadline is known. |
| `"no_question"` | `q` was blank, so nothing ran. | Send a question. |

`retry_after` is a whole number of **seconds**, rounded up (never 0), and is set
only for `"rate_limited"`. It is a body field rather than a `Retry-After` header
because a header describes the **whole response**, and this response succeeded —
only the generation part of it was throttled. Telling a client to retry the
request would throw away the sources it just got. Kiln reserves `Retry-After`
for genuine refusals (see [`api.md`](api.md)), where retrying *is* the
instruction.

These fields are **additive**. `question`, `answer`, `generated` and `sources`
are unchanged, so a client reading only those needs no update. `generated` stays
for compatibility and is exactly `generation == null`; new clients should branch
on `generation`, which says *why*, rather than on `generated`, which only says
whether.

Anonymous callers are told about `"rate_limited"` too, and that is a decision
rather than an oversight. The per-caller budget keys on the caller's address —
mostly their own traffic reflected back, though everyone behind one NAT or proxy
egress shares a key. The per-org budget is shared by construction, and
`retry_after` gives away which of the two it was: the windows differ (a minute
per caller, an hour per org by default), so a value above the per-caller window
can only have come from the shared one.

Reported anyway, because the pipeline's own per-IP limiter already answers 429
to the same anonymous caller and discloses more, and because withholding it
would leave an operator unable to tell "off by configuration" from "off because
the shared bucket is spent" — the case they most need to diagnose. Clamping
`retry_after` to the per-caller window would hide the distinction at the cost of
telling a client to retry in a minute when the real wait is most of an hour,
which is worse than the disclosure.

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
- **Generation is off by default.** With no model configured `/api/ask` returns
  retrieval-only (`answer: null`, `generated: false`, `generation: "disabled"`)
  and nothing leaves the deployment.

## Turning on generated answers

Set one environment variable to a `req_llm` model spec:

```
ASK_MODEL=ollama:llama3.1
```

or configure it directly:

```elixir
config :kiln_cms, KilnCMS.Ask,
  generator: KilnCMS.Ask.Generator.ReqLLM,
  model: "ollama:llama3.1"
```

`KilnCMS.Ask.enabled?()` tells you whether it is on.

### On-prem (strongly recommended here)

`req_llm` carries `ollama` and `vllm` providers, and every provider's
`base_url` is overridable, so pointing Kiln at a model running inside your own
network needs no Kiln code. `KilnCMS.Ask.egress?/0` reports whether content
actually leaves the deployment, resolved from the **endpoint host** rather than
the provider name — naming a provider `ollama` while pointing its `base_url` at
a rented GPU box is egress, and reporting it as local would be a lie. The same
classifier (`KilnCMS.LLM`) backs SEO drafting and block assist.

### A hosted provider

```
ASK_MODEL=anthropic:claude-sonnet-5
ANTHROPIC_API_KEY=...
```

Kiln never reads or stores provider API keys; `req_llm` resolves them from its
own environment. A hosted provider logs a warning at boot.

`ASK_GENERATOR` overrides the adapter module if you have written your own.

## Why this switch deserves more thought than the other two

`SEO_MODEL` and `ASSIST_MODEL` are triggered by an authenticated editor
clicking a control. **`ASK_MODEL` is triggered by strangers**: `/api/ask` is
public and anonymous, so enabling it against a hosted provider means anyone on
the internet can cause published passages to be sent there. Two things bound
that:

- **Only published, world-readable content is ever retrieved**, so no draft can
  reach the model whatever the setting — the policy scoping above is upstream of
  the generator, not a check the generator performs.

  This holds for **every** caller. Unlike the other headless read surfaces,
  `/api/ask` does not widen for a bearer token: retrieval runs with no actor at
  all, so an editor's or admin's credential retrieves exactly what a stranger
  retrieves. It used to forward the caller as the `:actor`, and because
  `Content`'s read policy sits behind an `OrgAdmin` bypass, that shipped drafts
  and member-gated records to the provider (#916). Searching drafts is what
  `/editor/search` and the editor palette are for.
- **Generation carries its own budget** (`KilnCMS.LLM.Budget`) on top of the
  pipeline's per-IP limiter, which allows 120 requests a minute — a fine ceiling
  for a search query and an absurd one for model inference. The per-caller
  bucket keys on the signed-in user when there is one and on the client address
  otherwise — a rate-limiting identity only, which never widens what is
  retrieved. Exhausting a bucket **degrades to retrieval-only**; it never fails
  the request, because the cited sources are still a useful answer.

Every other failure degrades the same way: an unset model, an unreachable
endpoint, a generator that raises or exits, an empty or unparsable response. The
*shape* of the response is identical to a default install's — same 200, same
`answer: null`, same sources — but it is no longer indistinguishable: a
configured-but-broken generator reports `generation: "failed"` where a default
install reports `"disabled"`. That difference is the point of the field, and it
is what tells an operator a transient outage from a switch they never flipped.

## Writing your own generator

Implement `KilnCMS.Ask.Generator` and point `generator:` at it.
`c:KilnCMS.Ask.Generator.generate/2` is the required callback and receives the
question plus the retrieved sources; the optional
`c:KilnCMS.Ask.Generator.generate/3` is preferred when exported and
additionally carries `:locale` — the *content* locale the answer should be
written in. Whatever it
returns is trimmed and length-capped by `KilnCMS.Ask` before it reaches a
caller.

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
  to the document's centroid, minus the ones already applied, and minus
  anything past a cosine-distance ceiling (`:suggest_tags_threshold`, default
  0.35). The ceiling is not optional decoration: the candidate set is the
  site's whole tag list, so ranking alone meant a five-tag site suggested all
  five tags for every document (#851). Returning nothing is the right answer
  when nothing is close. Tune it for your embedder — measure with
  `suggest_tags(record, threshold: 2.0)` (the ceiling of cosine distance, so
  nothing is filtered) and read the distances off the result.
- **Content gaps** — `content_gaps/2`: recorded zero-result search queries
  (the search-analytics log), most-searched first — what readers looked for
  and didn't get. The one function here that needs no embeddings, so it works
  on a keyword-only deployment too.

The vector primitive behind them is `BlockEmbedding`'s `:nearest_to_vector`
read (nearest neighbours of an already-computed vector, self-excluded).

### Where an editor sees them

- **"Similar content"** — a section in the content editor's Settings rail.
  Loaded on an explicit click, never on mount: it costs a pgvector query, a
  record read per neighbour, and one embedding per unapplied tag name. It shows
  near-duplicates (each linking to the other document, in a new tab, so unsaved
  edits survive) and suggested tags, which attach on one click. A suggested tag
  is *ticked in the tag picker*, not written to the record — it saves with
  everything else the author is editing, and unticking the checkbox undoes it.
- **"Content gaps"** — a section on `/editor/analytics`, above "Most viewed".
  Not windowed by the dashboard's `?range=`: a gap is a standing absence, and
  the counter table keeps a running total per query rather than per-day buckets.
  Its own retention window (`SearchQuery`'s nightly purge) bounds it instead.
- **Automation rules** — the `:flag_duplicates`, `:suggest_tags`,
  `:suggest_links` and `:suggest_metadata` reactions email findings on an event
  such as "moved to in review" (#377). All four suggest and never write; see
  [Editorial automation](automation.md#the-intelligence-reactions-suggest-and-never-write)
  for why that boundary is the point.

Both editor surfaces need this document's own block embeddings, which are
written by firing, and firing runs on publish. A never-published draft
therefore has nothing to compare; the panel says so rather than reporting
"nothing similar".
