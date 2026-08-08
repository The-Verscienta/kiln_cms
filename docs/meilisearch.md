# Meilisearch Backend (optional) — Project Plan Phase 6

**Status:** Implemented, **off by default**. A feature-flagged, typo-tolerant,
faceted keyword search backend over published content, sitting alongside the
built-in Postgres full-text search (`:search` action) and the semantic/hybrid
pipeline (`docs/semantic-search-plan.md`).

Per decision **D2** (minimal ops), Meilisearch is *never* required. With the flag
off, no content write or publish touches it and the lean install pays nothing —
exactly mirroring how semantic search is gated.

## What it does

- **Feature-flagged backend** — `config :kiln_cms, KilnCMS.Search.Meilisearch,
  enabled: …`. Disabled → every entry point is a no-op.
- **Index rebuild on publish/unpublish** — publishing (and scheduled publishing)
  enqueues an upsert; unpublishing enqueues a delete. Both run off the write path
  through `KilnCMS.Search.MeilisearchWorker`, wired from the existing
  `FireArtifacts` / `DeleteArtifacts` changes — so the index tracks the public
  delivery view and never leaks drafts.

## Architecture

```
publish / publish_scheduled
  └─ FireArtifacts (after_transaction)
        └─ if Meilisearch.enabled? → Oban: MeilisearchWorker {op: upsert}
                                          └─ load published record
                                          └─ Meilisearch.index_document/1  ─► PUT /indexes/<idx>/documents

unpublish
  └─ DeleteArtifacts (after_transaction)
        └─ if Meilisearch.enabled? → Oban: MeilisearchWorker {op: delete}
                                          └─ Meilisearch.delete_document/2 ─► DELETE /indexes/<idx>/documents/<id>

query
  └─ Meilisearch.search/2 ─► POST /indexes/<idx>/search
```

HTTP is delegated to a swappable `KilnCMS.Search.Meilisearch.Client` behaviour
(default `…ReqClient`, Req-based). Tests inject a stub, so no server is needed.

## Document shape

One flat document per published Page/Post, keyed `"<type>_<id>"`:

| field          | source                  | role                          |
|----------------|-------------------------|-------------------------------|
| `id`           | `"<type>_<uuid>"`       | primary key                   |
| `org_id`       | record's org            | filterable, forced on every query (#336) |
| `type`         | `page` / `post`         | filterable                    |
| `record_id`    | record id               | hydrate back to Ash           |
| `title`        | `title`                 | searchable                    |
| `excerpt`      | `excerpt` (if present)  | searchable                    |
| `body`         | denormalized `search_text` | searchable                 |
| `slug`,`locale`| record                  | `locale` filterable           |
| `published_at` | unix timestamp          | sortable                      |

## What is in the index — and what is not (#1006)

**Only content that is public to an anonymous visitor.** A document is indexed
when it is `state: :published` **and** `audience: :public` **and** carries no
passphrase (#496). Anything else is not merely skipped: the worker turns it into
a `DELETE`, so gating or locking an already-indexed document *removes* it.

The reason is a property of the index rather than a policy choice. The document
shape above has **no audience, grant or password field**, and `configure/0`
declares only `org_id`, `type` and `locale` as filterable — so there is nothing
to filter on even if a caller wanted to, and Meilisearch queries carry no actor.
Anything in this index is readable by everyone who can reach it.

Note that filtering at query time would not have been an answer even if the facet
existed. The normal way to use this backend is to point something at Meilisearch
**directly** — a front end or an edge worker holding a search-only key — which
never passes through `Meilisearch.search/2` and so never reaches `put_filter/2`
at all. The only thing that protects such a client is what is in the index. In
that configuration an indexed member-only document's full `body` (its
denormalized `search_text`) would be anonymously searchable.

Kiln's own Postgres search has no equivalent exposure **to an anonymous caller**:
`search` / `search_published` are policy-gated, so gated content is excluded by
the same read policy that keeps it out of feeds and the sitemap. (The
`_published` twins pin `state` and not `audience`, so an over-scoped API key is a
separate question — #1013.)

> **If you enabled this backend before this rule landed**, documents that were
> already gated and have not been republished since are still in the index.
> `mix kiln.meili.reindex` re-enqueues every published document, and each gated
> one is removed on the way through — run it once.

Two things that are also *not* in the index, for reasons that have nothing to do
with access control:

- **Dynamic content types (D17).** `MeilisearchWorker.load/3` knows `page` and
  `post` only, and `mix kiln.meili.reindex` enumerates the same two. Publishing a
  dynamic-type entry with the backend on issues a harmless `DELETE` for a
  document that was never there. Tracked as #1012 — if you rely on dynamic types,
  this backend does not cover them yet.
- **Experiment variants**, because a variant is never fired at all (invariant 1,
  [`content-experiments-plan.md`](content-experiments-plan.md)).

## Enabling

1. Start the instance (local dev):

   ```bash
   docker compose --profile search up -d   # getmeili/meilisearch on :7700
   ```

2. Turn the flag on. **Dev:** edit `config/config.exs`. **Prod:** set env vars
   (picked up in `config/runtime.exs`):

   ```bash
   export MEILI_URL=http://localhost:7700
   export MEILI_MASTER_KEY=…        # optional; bearer token
   export MEILI_INDEX=kiln_content  # optional; default shown
   ```

3. Configure the index and backfill all currently-published content:

   ```bash
   mix kiln.meili.reindex
   ```

   (No-op with a notice when the backend is disabled.)

## Querying

```elixir
{:ok, hits} =
  KilnCMS.Search.Meilisearch.search("otters",
    org_id: org_id,
    type: :page,
    locale: "en",
    limit: 20
  )
```

`:org_id` is mandatory and is forced into the filter (#336) — omitting it raises
rather than searching across sites.

Returns the raw Meilisearch hits (the indexed fields). Each hit's `record_id`
hydrates back to an Ash record through the normal read actions when you need a
policy-checked struct.
