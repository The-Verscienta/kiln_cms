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
| `type`         | `page` / `post`         | filterable                    |
| `record_id`    | record id               | hydrate back to Ash           |
| `title`        | `title`                 | searchable                    |
| `excerpt`      | `excerpt` (if present)  | searchable                    |
| `body`         | denormalized `search_text` | searchable                 |
| `slug`,`locale`| record                  | `locale` filterable           |
| `published_at` | unix timestamp          | sortable                      |

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
{:ok, hits} = KilnCMS.Search.Meilisearch.search("otters", type: :page, locale: "en", limit: 20)
```

Returns the raw Meilisearch hits (the indexed fields). Each hit's `record_id`
hydrates back to an Ash record through the normal read actions when you need a
policy-checked struct.
