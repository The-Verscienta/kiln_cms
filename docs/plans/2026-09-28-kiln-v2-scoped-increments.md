# Plan: Close Kiln v2 Scoped Increments (remaining browser + cross-cutting work)

## Goal
Finish the six deferred increments that `docs/kiln-v2-implementation-guide.md` marks **Scoped** after otherwise shipping Phases A–J. When done, Kiln v2's "typed, addressable content tree" is fully end-to-end — legacy `Block` bridge retired, collab presence/prose-sync wired into the live editor, event emission connected, upcasting fully hooked, block-granular search hybrid, and production UX polish landed — without revisiting the locked decisions D1–D16 / A1–A4 / C1–C2 / H1.

> **Assumption about your `/plan` intent:** you ran `/plan` with no prompt. This plan assumes you want the next shippable path for Kiln v2 (the natural successor to the 2026-09-27 security/usability audit remediations that just shipped on `cursor/2026-09-27-security-usability-audits`). If you meant a different target (new capability, audit follow-through, or a specific issue), treat the **Open Questions** as the fork — reply "Request changes: plan X instead" and this file will be rewritten.

## Success Criteria
- [#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537)-class backfill is green: every `pages.blocks`/`posts.blocks` row round-trips as `KilnCMS.CMS.BlockUnion` (typed, tagged `_type`/`_version`) and the `TypedBlocks.to_legacy/1` boundary in delivery/preview is removed. Legacy `KilnCMS.CMS.Block` no longer read on any path.
- Presence + block-lock UX is browser-verified in `ContentEditorLive`: "who's editing" avatars, soft lock rejects concurrent block edits with a friendly message, and TipTap prose sync via `assets/js/hooks/prose_sync.js` over the `content:<type>:<id>` PubSub topic.
- Every block mutation emits a `KilnCMS.History.DocumentEvent` (the `History.record/5` fold engine) and `replay/3` / `preview_at/3` time-travel renders via typed serializers.
- Upcasting is fully hooked: `KilnCMS.Blocks.Upcaster.upcast_block_map/1` runs lazily in the `BlockUnion` cast/load path, and the eager `upcast_all/1` is wrapped in an Oban backfill worker (idempotent, resumable). Artifact lazy-migrate (H1) is exercised on a bumped `@format_version`.
- Block search is hybrid: Postgres `tsvector` per block fuses with pgvector NN via RRF (existing `BlockSearch` extended), plus deeper ancestor context (parent block type/section title).
- Field/block policy enforcement is wired into the editor, reference-picker lands for `:reference` fields, media usage (Phase E edges) surfaces in `media_live.ex`, and the fired-artifact headless API is the documented v2 surface.
- Full suite green (`mix precommit` clean) at each PR; no hand-written migrations; domain code interfaces only.

## Context And Current Facts
- **v2 implementation guide status (read 2026-09-28):** Phases A–J are all marked `✅ DONE` or `✅ CORE DONE`, but each of C, F, G, H, I, J carries a **Scoped (remaining increments)** box:
  - **C** — column type flipped to `BlockUnion` (jsonb↔jsonb, migration-free via tolerant `cast_input`/`cast_stored`), but old rows still legacy at rest, `TypedBlocks.to_legacy/1` remains at `content_controller.ex`/`preview_live.ex`, no corpus backfill, no run of upcast path (#1537).
  - **F** — server primitives ship (`KilnCMS.Collab.Locks` GenServer, `apply_op/4` + `DocumentEvent` persist + PubSub broadcast, `Patch.apply_prose/2` LWW seam). Browser pieces deferred: Presence avatars, JS prose-sync hook wrapping TipTap, wiring into `ContentEditorLive`.
  - **G** — `DocumentEvent` resource + fold engine ships (own domain `KilnCMS.History`, unique `{document, seq}`, `record/5` monotonic, `replay/3`, `preview_at/3`). Emission from editor ops and PubSub wiring deferred to overlap with F; branching drafts deferred by design.
  - **H** — DSL `version`/`migrate` + `Upcaster` ships (`upcast/2`, `upcast_block_map/1`, `upcast_all/1`, Heading v1→v2 example, StreamData property). Lazy hook not yet centralized in `BlockUnion` cast path (since legacy rows carry no `_version`); Oban backfill worker is a "trivial wrap" once union column is canonical.
  - **I** — `BlockEmbedding` (domain `KilnCMS.SearchIndex`, HNSW cosine, `{document, block_key}` unique, `content_hash` dedupe), `BlockIndexer.reindex/1`, `BlockEmbeddingWorker`, `BlockSearch.search/2` faceted by `:block_type` ship (deterministic stub embedder, no model). Hybrid keyword/vector RRF over block tsvector + deeper ancestor context deferred.
  - **J** — `Kiln.Block.Policy` (`editable_by`), JSON-LD `@graph`, serializer property tests ship. Reference-picker UX, media usage UI, fired-artifact API surface as primary headless docs, and editor policy-enforcement wiring deferred.
- **Recent trunk:** `98d8a13eb Ship 2026-09-27 security and usability audit remediations` (branch `cursor/2026-09-27-security-usability-audits` now gone); `v0.11.0` (2026-09-26) introduced `EMBED_ORIGINS` + `TENANT_STRICT_HOST` breakages; `CHANGELOG.md` Unreleased holds one fix (429 retry-after ceil). `AGENTS.md` D1–D8 remain locked: native `Phoenix.PubSub`, no Redis on hot path, embedded blocks (now `Ash.Type.Union` per C1), compile-time block types via `Kiln.Block` Spark DSL, `Ash.Policy.Authorizer` on every resource, no DaisyUI, domain `define` interfaces.
- **Conventions that constrain delivery:** `Ash` is the modeling layer — `mix ash.codegen <name>` → `mix ash.migrate` (never hand-edit `priv/repo/migrations` or `priv/resource_snapshots`); every action gets a domain `define`; `mix format` then `mix precommit` before each PR; shared-sandbox test guidance (scope to seeded records, `can_*?` optimistic for reads); `AshOban` `drain_queues?: true` in tests.

## Constraints And Non-goals
- **Do not revisit locked architecture:** D1 (PubSub), D2 (no required Redis), D3 (embedded), D10 (Spark DSL), D11 (`Ash.Type.Union`), D12 (Portable Text canonical, TipTap interchange), D13 (graph walk), D14 (event substrate coexists with PaperTrail), D15 (versioned upcasts), A1–A4, C1–C2, H1 (lazy-migrate). Changing any is out of scope.
- **Do not add new deps speculatively:** Meilisearch, Redis/Dragonfly second tier, `y_ex`/CRDT, `polymorphic_embed` remain opt-in/behind behaviour. This plan stays Postgres-centric.
- **No WASM / out-of-process sandbox work:** [#333](https://github.com/The-Verscienta/kiln_cms/issues/333) runtime-code isolation is deliberately parked (see `docs/p3-plan.md`); not part of this plan.
- **Non-goals:** branching drafts (noted deferral in G), CRDT/OT inside prose (post-v1), visual page-building beyond the reference picker, multi-org SaaS control plane ([#334](https://github.com/The-Verscienta/kiln_cms/issues/334) half).

## Key Decisions
| Decision | Recommendation | Why | Alternative rejected |
|---|---|---|---|
| **C backfill strategy** | Eager Oban backfill + lazy read upcast (same split as H): `Upcaster.upcast_block_map/1` in `BlockUnion` cast path for old rows; `mix kiln.refire_all` / backfill worker for corpus at once. | Reuses the shipped H1 / `Upcaster` split; no deploy step on `@format_version` bump; keeps reads safe while corpus migrates. | "Rewrite column via SQL migration" — would hand-write SQL against jsonb outside Ash's cast path and bypass upcast composition/property tests. |
| **Presence vs. separate service** | `Phoenix.Presence` over native PubSub (already in deps) for F avatars + lock metadata. | Zero new infra, matches D1; the guide explicitly names it. | External presence (e.g., Redis) — contradicts D1/D2 minimal-ops goal. |
| **Prose sync hook** | Thin `assets/js/hooks/prose_sync.js` wrapping existing TipTap that sends `PortableText` JSON patches over the LiveView socket; server applies via `KilnCMS.Collab.Patch.apply_prose/2` (LWW) then `History.record/5` + PubSub. | Keeps "everything except the caret" server-side (hybrid editor tenet); LWW is the guide's v1 choice; seam left for CRDT later. | Full CRDT in v1 — fights LiveView server authority and is explicitly deferred. |
| **Event emission wiring** | Editor block ops (`apply_op/4` path) and prose patches both call `KilnCMS.History.record/5`; state remains fold-over-log with PaperTrail snapshots as publish/restore anchors. | Unifies D14's "one substrate" — same events broadcast + persisted. | Dual-write to separate audit table — duplicates the log. |
| **Hybrid search** | Block-level `tsvector` column + existing `BlockEmbedding` HNSW; fuse via RRF in `BlockSearch`. | Reuses document-level RRF pattern already shipped; stays Postgres-FTS by default. | Meilisearch now — adds a required service without measured need (deferred per I). |
| **Reference picker** | LiveView picker backed by `KilnCMS.Firing.ReferenceEdge` edges (E) and CMS search; writes a `:reference` field that `Firing.References` walks. | Edges already rebuild per fire; picker is just UX over them. | Generic JSON picker — bypasses typed `:reference` and breaks the graph walk. |

## Recommended Approach
Land the six scoped increments as **six sequential PRs (C → F → G → H → I → J)**, each green under `mix precommit`. Ordering respects dependencies: C must canonicalize storage before H's lazy cast hook makes sense; F before G (events are the blocks F mutates); H after C; I after H (embed on fired blocks after format_version semantics are firm); J last (policy wiring + reference UX need the editor to be on native union forms, which C finishes).

Each PR:
1. Edits the resource/DSL → `mix ash.codegen <descriptive_name>` → inspect snapshot/migration → `mix ash.migrate` (only C/G/I/J-H touch schema).
2. Adds domain `define` → calls via `Domain.name!(…)`; generates `can_*?/2` where policies change.
3. Adds tests scoped to seeded records; `Oban.drain_queues?` where jobs involved.
4. `mix format` → `mix precommit`.

## Work Plan
### PR1 — C remainder: retire the legacy bridge & backfill (issue #1537)
- **Goal:** legacy rows become typed at rest; `TypedBlocks.to_legacy/1` removed from public delivery/preview.
- **Files:** `lib/kiln_cms/cms/block_union.ex`, `lib/kiln_cms/cms/typed_blocks.ex`, `lib/kiln_cms/cms/content.ex`, `lib/kiln_cms_web/controllers/content_controller.ex`, `lib/kiln_cms_web/live/preview_live.ex`, `lib/kiln_cms/blocks/upcaster.ex` (lazy hook), new `lib/kiln_cms/blocks/backfill_worker.ex` (Oban), `lib/kiln_cms/history` no-op here.
- **Steps:**
  1. Centralize lazy upcast in `BlockUnion` cast/load (call `Upcaster.upcast_block_map/1` when `_version` < head).
  2. Oban backfill worker: scan `Page`/`Post` (cursor), `to_typed` → `upcast_all` → persist if changed (idempotent, resumable; reuse `#615` lazy-migrate decision for artifacts — bump `@format_version` triggers `Engine.read` lazy re-fire, so corpus re-fire is via `mix kiln.refire_all`).
  3. Remove the `union→legacy` conversion at delivery/preview boundaries; delivery renders directly from `Blocks.render(:web)` / `Engine.read` path.
  4. Data movement is via the worker, not SQL — no hand-written migration against `blocks` jsonb.
- **Codegen:** `mix ash.codegen backfill_typed_blocks` only if a worker bookkeeping resource is added; otherwise none (jsonb↔jsonb).
- **Tests:** existing corpus with legacy fixture → after `Upcaster`/`BlockUnion` read, blocks are typed with correct `_type`/`_version`; worker is idempotent; legacy→typed bridge removed assertion.
- **Acceptance:** seeded + any migrated fixture row reads as typed without `to_legacy`; browser edit→reload still renders `<h3>` (or whichever level) from union storage; public delivery serves same HTML as preview.

### PR2 — F browser increments: Presence + locks + prose sync in `ContentEditorLive`
- **Goal:** browser-verified collab UX over the shipped server primitives.
- **Files:** `lib/kiln_cms_web/live/content_editor_live.ex`, `lib/kiln_cms_web/presence.ex` (if not present), `lib/kiln_cms/collab.ex` (wire), `assets/js/hooks/prose_sync.js`, `assets/js/app.js` (hook registration).
- **Steps:**
  1. `Phoenix.Presence` track on `content:<type>:<id>`; render avatars / "who's editing" (reuse `KilnCMS.Collab.Locks` holder for friendly `{:locked, holder}` messages).
  2. Wire `Locks.acquire/3` per block focus; follow primary field from `Kiln.Block.Info`.
  3. `prose_sync` hook: TipTap → `PortableText.from_tiptap/1` diff → `pushEvent("prose_patch")` → `Patch.apply_prose/2` → `History.record/5` → PubSub `{:block_op, …}` to peers.
  4. Broadcast add/remove/reorder to peers via existing `apply_op/4` broadcast.
- **Tests:** two LiveView sessions: both visible via presence; second acquire of same block gets `{:locked, holder}`; prose patch from one appears in other (use `Phoenix.LiveViewTest` + PubSub, not full browser).
- **Acceptance:** manual browser: two windows editing same doc see each other, block lock message, typing in one appears in other after debounce.

### PR3 — G wiring: emit events from the editor
- **Goal:** every mutation that F broadcasts is also persisted as `DocumentEvent`.
- **Files:** `lib/kiln_cms/history.ex`, `lib/kiln_cms/collab.ex`, `lib/kiln_cms_web/live/content_editor_live.ex`.
- **Steps:** call `History.record/5` (monotonic `seq`) from each block op + prose patch path; document `PaperTrail` vs event log division (snapshots = publish/restore anchor; events = inter-snapshot history — guide §G).
- **Tests:** sequence of editor ops → `History.replay/3` reconstructs exact tree; `preview_at/3` renders past state; properties hold.
- **Acceptance:** time-travel preview in the editor renders a prior `seq`.

### PR4 — H completion: lazy hook + Oban upcast worker
- **Goal:** fully hook the shipped `Upcaster` (much overlaps PR1's lazy hook; this PR does what remains).
- **Files:** `lib/kiln/block/{dsl,transformer,info}.ex` (if version bump needed), `lib/kiln_cms/blocks/upcast_backfill_worker.ex`, `lib/kiln_cms/firing/engine.ex` (artifact lazy-migrate path already shipped — verify).
- **Steps:** if PR1 already centralized the cast hook, this PR adds the Oban wrapper around `upcast_all/1` (retry, cursor pagination, telemetry) + exercises H1: bump `@format_version` → old artifact served once + re-fire enqueued via `Engine.read/4`.
- **Tests:** StreamData over v1→v2→v3 chains; old row lazy path; worker idempotent/resumable; artifact re-fire on format_version mismatch.
- **Acceptance:** no `_version` stored → read returns head version; `mix kiln.refire_all` migrates corpus.

### PR5 — I hybrid: block tsvector + RRF + ancestor context
- **Goal:** precise "find the relevant section" over blocks.
- **Files:** `lib/kiln_cms/search/block_embedding.ex`, `lib/kiln_cms/search/block_search.ex`, `lib/kiln/block/renderer.ex` (`search_text/1`), `lib/kiln_cms/cms/content.ex` (tsvector trigger), new `lib/kiln_cms/search/block_indexer.ex` additions.
- **Steps:** compute block `search_text` + ancestor title/section context; store per-block tsvector (migration via `ash.codegen add_block_tsvector`); fuse keyword + vector NN via RRF in `BlockSearch.search/2`; keep Meilisearch behind behaviour (no new dep).
- **Codegen:** `mix ash.codegen add_block_tsvector` → `mix ash.migrate`.
- **Tests:** needle block returns correct `block_key`; faceting by `block_type`; hash dedupe; hybrid beats keyword-only on fixture.
- **Acceptance:** `BlockSearch.search("…", top_k: 5)` returns the containing block, not just the document.

### PR6 — J polish: policy wiring, reference picker, media usage
- **Goal:** architecture-completing UX.
- **Files:** `lib/kiln/block/policy.ex`, `lib/kiln_cms_web/live/content_editor_live.ex`, `lib/kiln_cms_web/live/media_live.ex`, `lib/kiln_cms/firing/references.ex` (picker queries), `docs/policy-matrix.md`, headless API docs.
- **Steps:**
  1. Enforce `Kiln.Block.Policy` in editor forms (hide/disable `editable_by`-restricted fields; server-side `authorize_changes/3`).
  2. Reference picker: search documents/blocks, write `:reference`, reuse `ReferenceEdge` rebuild on fire.
  3. Media usage: show referrers (via `ReferenceEdge` edges) in `media_live.ex`.
  4. Document fired-artifact headless API (`GET /api/content/:type/:slug?surface=`) as the v2 surface; verify `Engine.read/3` path.
  5. Update `docs/policy-matrix.md` with field matrix.
- **Tests:** editor cannot set `Quote.featured` (property from guide); picker creates edge after fire; media page shows referrers; API serves `Engine.read` artifact.
- **Acceptance:** docs + browser checks; full suite remains green.

## Validation Plan
- **Per-PR:** `mix format` → `mix ash.codegen <name>` (inspect) → `mix ash.migrate` → `mix test` (full suite; scoped assertions, `drain_queues?: true` for Oban) → `mix precommit` (strict; runs Credo, Dialyzer subset, Sobelow, `kiln.changelog --check`). For browser PRs (F/J): `npm install` in `assets/` then manual check in two windows (presence + lock + prose sync + picker).
- **PR1 smoke:** edit heading level → save → reload → preview `<h3>` from union storage; public `GET /:slug` renders same; worker idempotency.
- **PR5 smoke:** seed two docs, one block contains needle phrase; `BlockSearch.search(needle)` returns that block; `EXPLAIN` shows HNSW + GIN usage.
- **Full E2E (after PR6):** `mix test` 450+ green; `mix precommit` clean; `docker compose` boots `example` overlay via `overlay_drift`-like check.

## Risks / Rollback
- **Corpus backfill storm:** PR1/PR4 workers scanning all `Page`/`Post` could generate many `PublishedArtifact` writes via re-fire. Mitigate: cursor pagination, Oban `unique` per document, fan-out caps; H1 lazy path already keeps stale artifacts readable (served once + enqueued) so a paused worker doesn't break reads.
- **Lock UX contention:** soft locks are advisory (LiveView server state). If presence partitions, two editors could race. Mitigate: server `authorize_changes/3` is the arbiter; lock rejection is friendliness, not security.
- **Search migration weight:** adding a per-block tsvector is a write-amplifying migration on large corpora. Mitigate: do it in a dedicated PR (5) with a backfill job, not a blocking DDL on the hot path.
- **Rollback:** each PR is independent and additive. Reverting PR1's delivery boundary restores `to_legacy/1`; reverting search (PR5) drops back to document-level FTS. No destructive column rewrites — downgrades are safe because `BlockUnion` cast is legacy-tolerant.

## Open Questions
1. **Is this the right plan target?** You called `/plan` with no prompt — this file assumes "finish Kiln v2's scoped increments." If you meant a specific issue, audit item, or new feature, say "Request changes: plan <X> instead" and this file will be replaced.
2. **Does PR1 need an operator flag to force eager re-fire of all fired artifacts?** `mix kiln.refire_all` already exists for corpus-wide eager migration (guide H4). Should PR1/PR4 add `--since` / `--type` flags, or is bare `refire_all` enough?
3. **Block tsvector shape (PR5):** store as a generated column on `block_embeddings` vs. recompute per query? Generated column is faster but couples to PG version — confirm target PG.
4. **Reference picker scope:** document-to-document only first (as shipped in E), or block-within-document refs in this increment? Guide question #3 leaves this open.

---
*Evidence:* `AGENTS.md` (D1–D8, Ash codegen/domain/policy/ETS-precommit rules), `KilnCMS_Project_Plan.md` (D1–D16 + v2 north star), `kiln-cms-plan-v2.md`, `docs/kiln-v2-implementation-guide.md` Phases A–J scoped boxes + decisions A1–A4/C1–C2/H1, `CHANGELOG.md` Unreleased + `v0.11.0`, `docs/competitive-gaps-todo.md`, `docs/releasing.md`, `priv/repo/migrations` (codegen pattern), current branch `cursor/… [gone]` at `98d8a13eb`.
