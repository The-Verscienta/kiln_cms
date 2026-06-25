# Kiln v2 — Step-by-Step Implementation Guide

> Companion to `kiln-cms-plan-v2.md` (the architecture/vision doc). That doc says
> **what** Kiln v2 is and **why**. This doc says **how** to get there from the
> codebase as it stands today, in shippable increments, without a big-bang rewrite.

---

## 0. Read this first — where we are vs. where v2 points

Kiln CMS already ships a substantial, production-shaped CMS. Several v2 ideas are
**already partly built**; others are **genuinely new** and reshape the core. The
guide's job is to evolve the former and introduce the latter behind seams, so the
app stays green the whole way.

### Gap analysis

| v2 concept | Today | Gap to close |
|---|---|---|
| **Typed, addressable block tree** | One `KilnCMS.CMS.Block` embedded resource with a `type` atom + free-form `data` map (`lib/kiln_cms/cms/block.ex`) | Move from "one struct, many types via a map" → **per-type typed structs** generated from a DSL |
| **Block Type as Spark + Ash DSL** | No DSL; block variants are enum values | Build `Kiln.Block` Spark DSL that fans out to schema/validation/editor/renderer/search |
| **Portable Text inside text blocks** | TipTap HTML/JSON string in `Block.content` | Introduce a structured Portable Text–shaped representation for prose |
| **Polymorphic embeds w/ `_type`** | Single embedded resource; type is an attribute, not a discriminator over distinct structs | Adopt `polymorphic_embed` (or Ash union types) keyed on `_type` |
| **Firing → immutable artifacts** | Publish = AshStateMachine transition + PaperTrail snapshot + Cachex (`Content` macro) | Add a **`PublishedArtifact`** resource + compile step + ETS/Redis two-tier cache |
| **Reference-aware invalidation** | `ContentLink` polymorphic relation exists; no firing dependency graph | Build a dependency graph + re-fire on referenced-doc change |
| **Serializers as pattern-matched components** | Block rendering in editor/preview LiveViews, ad hoc | One function-component-per-block-type registry (web/email/JSON/JSON-LD) |
| **Event-log substrate** | AshPaperTrail versions (snapshots, not events) | Append-only per-block event log; state = fold over log (additive) |
| **Block schema evolution / upcasting** | None (single schema) | `migrate :hero, from: 1, to: 2` upcast functions + lazy/eager run |
| **Block-granular embeddings** | Document-level `embedding` on Page/Post (`pgvector`, Bumblebee) | Embed per block + ancestor context; block-level search projection |
| **Ash policies (field/block level)** | Resource-level + role policies (`docs/policy-matrix.md`) | Extend to block-/field-level authorization declared in the DSL |
| **Structured data (JSON-LD)** | SEO fields only | JSON-LD serializer target derived from block types |

### Locked constraints to respect (from `AGENTS.md`)

- **Ash is the modeling layer.** Never hand-write Ecto schemas or migrations. Edit
  resource → `mix ash.codegen <name>` → `mix ash.migrate`.
- **Domain code interfaces everywhere.** Add `define :action` on the domain; call
  `CMS.action!(...)`, never `Ash.create!/2` directly. Use generated `can_*?/2` for UI.
- **Authorization on every resource.** `Ash.Policy.Authorizer`, role model admin/editor/viewer.
- **No DaisyUI.** Custom Tailwind/HEEx; wrap LiveViews in `<Layouts.app>`, pass `current_scope`.
- **Postgres-centric, native PubSub, Oban (no Redis required).** Redis in v2 is an
  *optional* second cache tier behind a behaviour — ETS is the default.
- Run `mix format` then `mix precommit` before every commit (precommit is strict, won't auto-fix).

---

## 1. Sequencing strategy

The plan's "Suggested First Move" is correct: **pressure-test the firing model
first**, because it decides cache strategy, what "published" means, and where
reads land — and the reference-aware-invalidation question decides whether firing
is a tree walk or a graph walk.

But firing is only meaningful over a tree we can serialize deterministically. So
the real critical path is:

```
Phase A  Firing spike (artifact format + serializer contract)         ← de-risk first
Phase B  Block Type DSL + typed blocks (2–3 types incl. one rich text)
Phase C  Polymorphic embeds + editor composition over typed blocks
Phase D  Firing for real (PublishedArtifact + two-tier cache + read path)
Phase E  Reference-aware invalidation (dependency graph)
Phase F  Collaboration (presence + block locking + patch sync)
Phase G  Event log + history + time-travel
Phase H  Schema evolution / upcasting
Phase I  Block-granular search + embeddings
Phase J  Production polish (field/block policies, media, APIs, JSON-LD)
```

This maps onto the plan's Phase 0–5 table but splits Phase 0 into a throwaway
**spike (A)** and the **real build (D/E)**, with the DSL/typed-block work (B/C) in
between because firing-for-real needs typed blocks to serialize.

Each phase below has: **Goal · Why now · Steps · New/changed files · Codegen ·
Tests · Acceptance**. Land each phase as its own PR.

---

## Phase A — Firing spike (throwaway) — ✅ DONE

> **Outcome.** A throwaway `KilnCMS.Firing.Spike` + test fired a seeded 7-block page
> to `web`/`json`/`json_ld` with all serializers total (custom block included), JSON
> round-tripping, JSON-LD derived from types, and `references/1` proving the graph
> walk. 6/6 tests green. Decisions **A1–A4 locked** (see §3). Spike code deleted —
> only the validated decisions survive, as intended.

**Goal.** Prove the artifact format and serializer dispatch on *today's* `Block`
struct, with no DSL and no DB changes. Answer the open design questions before
committing to schema.

**Why now.** Cheapest possible way to surface the hard questions: what's in an
artifact, how serializers dispatch, how a fired read is shaped, and what a
reference edge does to invalidation.

**Steps.**
1. Write a plain module `KilnCMS.Firing.Spike` (in `lib/`, but mark it `@moduledoc false`
   and delete at end of phase) that takes a `Page` with its `blocks` and produces:
   - `%{web: iodata, json: map, json_ld: map}` — one artifact map per surface.
2. Implement serializers as **pattern-matched functions** over the existing block
   `type` atom (precursor to the real per-struct dispatch): `render_web(%Block{type: :heading} = b)`, etc.
3. Hand-write a `PublishedArtifact` *shape* as a struct (not a resource yet):
   `%{document_id, document_type, surface, format_version, body, fired_at, source_version_id}`.
4. Write a throwaway test that fires a seeded multi-block page and asserts each
   surface renders without crashing and round-trips JSON.
5. **Decide and write down** (append to this doc's §"Design decisions locked in Phase A"):
   - Artifact granularity: whole-document vs per-block artifacts (recommend: whole-document
     artifact composed of per-block fragments, so partial re-fire is possible later).
   - Surfaces in v1: `web`, `json`, `json_ld`. (`email` deferred.)
   - `format_version` integer on every artifact.
   - Reference model: does a fired artifact **embed** referenced data (snapshot) or
     **link** to it (resolve at read)? Recommend **embed at fire time** → that's what
     makes reads free and forces the dependency graph (Phase E).

**Acceptance.** A green throwaway test fires a page to 3 surfaces. The five
decisions above are written down. Delete the spike module; keep the notes.

> ⛳ This phase intentionally produces **no permanent code** — only validated decisions.

---

## Phase B — Block Type DSL + typed blocks — ✅ DONE

> **Outcome.** The `Kiln.Block` Spark DSL ships: one `block :name do field … end`
> definition fans out to an Ash embedded resource (attributes added by a
> transformer that runs before `DefaultAccept`), a `_type`/version introspection
> surface (`Kiln.Block.Info`), and a total render contract (`Kiln.Block.Renderer`:
> `render/2` + `search_text/1`). Three typed blocks land — `Heading`, `Image`,
> `RichText` — discovered + dispatched via `KilnCMS.Blocks` (registry by `_type`,
> `render/2`/`search_text/1` by struct). Portable Text is implemented as canonical
> PT JSON with `KilnCMS.Blocks.PortableText.{from_tiptap,to_html,to_plain_text}/1`
> (paragraph/heading/blockquote + strong/em/code/strike/underline/link; lists +
> embedded objects noted as follow-ups). **20 new tests pass; full suite 404 green;
> `mix precommit` clean.** No change yet to how `Page.blocks` is stored — that's Phase C.
>
> Files: `lib/kiln/block.ex`, `lib/kiln/block/{dsl,transformer,info,renderer}.ex`,
> `lib/kiln_cms/blocks.ex`, `lib/kiln_cms/blocks/{heading,image,rich_text,portable_text}.ex`;
> tests under `test/kiln/block/` and `test/kiln_cms/blocks/`.

**Goal.** Introduce `Kiln.Block` — a Spark DSL where one definition per block type
fans out to: an embedded schema, changeset/validation, a render contract, and
search-projection metadata. Define 2–3 representative types including one rich
text block.

**Why now.** Everything downstream (firing-for-real, editor, search, upcasting)
keys off typed blocks. This is the central leverage point.

**Steps.**
1. **Create the Spark extension** `lib/kiln/block.ex` (`Kiln.Block`) using `Spark.Dsl`.
   Start minimal — model these DSL entities:
   - `block :name do ... end` — top-level entity with `:name`, optional `:version` (default 1).
   - `field :name, :type, opts` — maps to Ash embedded attributes; support the
     primitive set from the plan (`:string`, `:rich_text`, `:integer`, `:boolean`,
     `:date`, `:datetime`, `:slug`, `:url`, `:email`, `:color`) plus `:object`
     (nested), `:array`, `:reference`, `:image`.
   - `policy` (stub for Phase J — parse but no-op for now).
2. **Transformer**: write a `Spark.Dsl.Transformer` that, at compile time, turns each
   `block`/`field` into an Ash embedded resource definition (the same shape as
   today's `Block`, but one module per type, e.g. `KilnCMS.Blocks.Heading`,
   `KilnCMS.Blocks.RichText`, `KilnCMS.Blocks.Image`).
3. **Type registry**: generate `KilnCMS.Blocks.registry/0` returning
   `%{heading: KilnCMS.Blocks.Heading, ...}` via an `Info` module
   (`Kiln.Block.Info`), mirroring the existing `KilnCMS.CMS.ContentTypes`
   auto-discovery pattern. The `_type` discriminator string = the block name.
4. **Render contract**: each block module implements `render(struct, surface)`
   (or a `@behaviour Kiln.Block.Renderer`) returning iodata/map. This is the
   permanent home for the Phase A serializers.
5. **Rich text block**: define `KilnCMS.Blocks.RichText` whose `body` field is the
   Portable Text–shaped structure (see Phase B.1 below). Keep a `legacy_html`
   field temporarily for migration.

**Phase B.1 — Portable Text shape.**
- Define an embedded `KilnCMS.Blocks.PortableText.Block` = `%{_type, _key, style, children: [span], marks: [...]}` and `Span = %{_type: "span", _key, text, marks: [mark_key]}`.
- Keep marks as data (`strong`, `em`, link annotations), not tags.
- Provide `PortableText.from_tiptap/1` and `to_html/1` so the existing TipTap
  editor keeps working while we transition (TipTap JSON → Portable Text on save).

**New/changed files.**
- `lib/kiln/block.ex`, `lib/kiln/block/info.ex`, `lib/kiln/block/transformer.ex`, `lib/kiln/block/renderer.ex`
- `lib/kiln_cms/blocks/heading.ex`, `.../rich_text.ex`, `.../image.ex`
- `lib/kiln_cms/blocks/portable_text/*.ex`
- `test/kiln/block/dsl_test.exs`, `test/kiln_cms/blocks/*_test.exs`

**Codegen.** None yet — these are embedded resources, no table changes. Run
`mix compile --warnings-as-errors` to validate the transformer.

**Tests.**
- DSL: defining a block produces an embedded resource with the expected attributes
  and a changeset that validates required fields.
- Registry returns all defined block types keyed by `_type`.
- `render/2` exists and returns non-crashing output for each surface.
- Portable Text round-trips TipTap JSON ↔ PT ↔ HTML.

**Acceptance.** Three typed block modules exist, discoverable via the registry,
each renderable to web/json/json-ld. No change yet to how `Page.blocks` is stored.

---

## Phase C — Polymorphic embeds + editor composition over typed blocks — ✅ CORE DONE

> **Outcome.** `Ash.Type.Union` storage is implemented (decision D11):
> `KilnCMS.CMS.BlockUnion` is a NewType union over the typed blocks tagged by
> `_type` (a discriminator the transformer now injects into every block, defaulting
> to the block name). `KilnCMS.CMS.TypedBlocks` is the **canonical legacy↔typed
> bridge** — `from_legacy/1` (total: any legacy/unknown block → `Custom`) and
> `to_legacy/1` — which Phases D–J consume to operate on typed blocks. Three more
> typed blocks landed for full legacy coverage: `Quote`, `Embed`, `Custom`. **7 new
> tests; full suite 411 green; precommit clean.**
>
> **Scoped (remaining Phase C increment):** the on-disk `Page.blocks`/`Post.blocks`
> columns still hold the legacy `KilnCMS.CMS.Block` shape, and the editor still
> authors legacy blocks. Flipping the stored column (data migration to union shape)
> and rewriting `ContentEditorLive` to compose native union blocks from the registry
> is UI/migration work deferred behind the bridge — it needs browser iteration and
> is lower architectural risk. Downstream phases run on the typed representation via
> `from_legacy/1`, so nothing is blocked.
>
> Files: `lib/kiln_cms/cms/{block_union,typed_blocks}.ex`,
> `lib/kiln_cms/blocks/{quote,embed,custom}.ex`, `lib/kiln/block/transformer.ex`
> (`_type` injection), `lib/kiln/block.ex` (`default_accept :*`);
> test `test/kiln_cms/cms/typed_blocks_test.exs`.

**Goal.** Change `Page.blocks` / `Post.blocks` from `{:array of single Block}` to a
**polymorphic embed** of the typed block structs, and update the editor to compose
typed blocks.

**Why now.** Storage must hold typed structs before firing-for-real can serialize
them deterministically and before per-block migrations make sense.

**Steps.**
1. **Choose the mechanism.** Two viable options — pick in this phase:
   - **(a) Ash union type** (`Ash.Type.Union`) over the registry's embedded
     resources, tagged by `_type`. Native to Ash, no extra dep. **Recommended.**
   - **(b) `polymorphic_embed`** as named in the plan. Extra dep; more Ecto-flavored.
   Recommend **(a)** to stay within Ash idioms (`AGENTS.md`: Ash is the modeling layer).
2. Replace the `blocks` attribute in the `Content` macro
   (`lib/kiln_cms/cms/content.ex`) with the union/polymorphic array. Derive the
   union members from `KilnCMS.Blocks.registry/0`.
3. **Data migration**: write an Oban-backed one-time migration that reads each
   existing `Block` (`type` + `data` + `content`) and rewrites it as the matching
   typed struct (`heading`→`Heading`, `rich_text`→`RichText` with
   `PortableText.from_tiptap/1`, etc.). Idempotent; guarded by a `format_version`
   stamp on the document.
4. **Editor**: update `content_editor_live.ex` so the block palette is driven by
   `KilnCMS.Blocks.registry/0` and each block's form fields come from its DSL field
   list (generate `<.input>`s from field metadata). Keep SortableJS drag/drop.
5. Update `preview_live.ex` to render via the Phase B render contract instead of
   ad-hoc block rendering.

**New/changed files.**
- `lib/kiln_cms/cms/content.ex` (blocks attribute), `lib/kiln_cms/cms/block.ex` (becomes the union or is removed)
- `lib/kiln_cms_web/live/content_editor_live.ex`, `lib/kiln_cms_web/live/preview_live.ex`
- `lib/kiln_cms/cms/migrations/blocks_to_typed.ex` (Oban worker)
- `priv/repo/migrations/*` if column type/constraints change

**Codegen.** `mix ash.codegen migrate_blocks_to_typed` then `mix ash.migrate`.
Inspect the generated migration before running (AGENTS.md).

**Tests.**
- Round-trip: create a page with each block type via the editor action; reload;
  assert typed structs come back.
- Data migration: seed legacy-shaped blocks, run worker, assert typed result and
  idempotency on re-run.
- `editor_live_test.exs` / `content_model_test.exs` updated and green.

**Acceptance.** Documents store typed polymorphic blocks; editor composes them
from the registry; existing content migrated losslessly; preview renders via the
shared serializers.

---

## Phase D — Firing for real (PublishedArtifact + two-tier cache)

**Goal.** Make "publish" *fire* the document into immutable, pre-serialized
artifacts and make all public reads hit artifacts, never the live tree.

**Why now.** Typed blocks now serialize deterministically; this delivers the
plan's core performance/correctness primitive.

**Steps.**
1. **`PublishedArtifact` Ash resource** (`lib/kiln_cms/firing/published_artifact.ex`),
   data layer `ash_postgres`. Attributes: `document_id`, `document_type`
   (`:page|:post`), `surface` (`:web|:json|:json_ld`), `format_version`,
   `body` (`:map`/`jsonb` or text for web iodata), `source_version_id` (PaperTrail
   link), `fired_at`. Unique index on `{document_id, surface}`.
2. **Firing service** `KilnCMS.Firing` with `fire(document, opts)`:
   - Walk the typed block tree, call each block's `render/2` per surface.
   - Compose per-surface artifacts; bump `format_version`.
   - Upsert `PublishedArtifact` rows in a transaction.
   - Push into cache (step 4). Broadcast `{:fired, document_type, id}` on PubSub.
3. **Hook into publish.** In the `Content` macro's `:publish` action, add an
   `after_action`/`after_transaction` change that calls `KilnCMS.Firing.fire/2`.
   Keep PaperTrail snapshot (it becomes `source_version_id`). `:unpublish` deletes
   artifacts + evicts cache.
4. **Two-tier cache behind a behaviour** `KilnCMS.Firing.Cache`:
   - Tier 1 ETS (via existing `cachex` or a dedicated table) — always on.
   - Tier 2 optional Redis adapter — config-gated, default off (Postgres-centric).
   - API: `get(document_type, id, surface)`, `put/4`, `evict/2`.
5. **Read path.** Repoint `public_by_slug` delivery (and the JSON/GraphQL public
   endpoints) to read artifacts via the cache, falling back to the
   `PublishedArtifact` table on cache miss, never to the live document.
6. **Preview firing mode.** Add `fire(document, mode: :preview)` that renders to
   memory only (no DB upsert) for `preview_live.ex`.

**New/changed files.**
- `lib/kiln_cms/firing/published_artifact.ex`, `lib/kiln_cms/firing/firing.ex`,
  `lib/kiln_cms/firing/cache.ex` (+ `cache/ets.ex`, `cache/redis.ex`)
- `lib/kiln_cms/cms/content.ex` (publish/unpublish hooks)
- Public delivery controllers/LiveViews + `lib/kiln_cms/cms.ex` (new `define`s)
- `config/config.exs` (cache tier config)

**Codegen.** `mix ash.codegen add_published_artifacts` → `mix ash.migrate`.

**Tests.**
- Publishing fires all surfaces; artifact rows exist with correct `format_version`.
- Public read returns artifact content and **does not** query the documents table
  (assert via query log or by mutating the live doc post-publish and seeing the old
  fired output until re-fire).
- Unpublish removes artifacts + cache.
- Cache: ETS hit/miss; Redis adapter behind config flag (skip if not configured —
  honor shared-sandbox test guidance, scope assertions to seeded records).
- Preview mode renders without writing artifacts.

**Acceptance.** Reads are served from fired artifacts via cache; publish is an
auditable compile step; the live tree is never read on the public path.

---

## Phase E — Reference-aware invalidation (the graph walk)

**Goal.** When document B is referenced by document A and B changes, A's fired
artifact is stale → re-fire A. Firing becomes a graph walk, not just a tree walk.

**Why now.** This is the design question the plan flags as most worth resolving
early; do it right after firing exists so the model is exercised.

**Steps.**
1. **Reference extraction.** Add a `references(document)` function that walks the
   typed block tree and collects `reference` field targets (the DSL `:reference`
   field type from Phase B). Returns `[{target_type, target_id, kind}]`.
2. **Dependency edges resource** `KilnCMS.Firing.ReferenceEdge`
   (`from_type, from_id, to_type, to_id`), rebuilt on each fire of the *referrer*.
   (Reuse/relate to existing `ContentLink` where it overlaps, but edges here are
   firing-internal and may include block-to-block references `ContentLink` doesn't.)
3. **Invalidation on fire.** After firing document B, query edges where
   `to = {B.type, B.id}`, collect distinct referrers, and enqueue **re-fire jobs**
   (Oban) for each. Cap fan-out depth and dedupe within a job batch to avoid storms.
4. **Cycle safety.** Detect cycles (A↔B); fire each node at most once per
   invalidation wave (track visited set in the Oban job args / a wave id).
5. **Stale read protection.** Until a referrer re-fires, its artifact is correct as
   of last fire (embedded snapshot from Phase A decision) — acceptable. Optionally
   expose `stale?` by comparing `fired_at` to referenced docs' `published_at`.

**New/changed files.**
- `lib/kiln_cms/firing/reference_edge.ex`, `lib/kiln_cms/firing/references.ex`
- `lib/kiln_cms/firing/refire_worker.ex` (Oban)
- `lib/kiln_cms/firing/firing.ex` (edge rebuild + invalidation enqueue)

**Codegen.** `mix ash.codegen add_reference_edges` → `mix ash.migrate`.

**Tests.**
- A references B; publishing both; changing+re-firing B enqueues a re-fire of A;
  A's artifact reflects B's new data after the wave.
- Cycle A↔B fires each once.
- Fan-out cap + dedupe respected.
- Follow AshOban test guidance: `drain_queues?: true`, don't `mix run` against test DB.

**Acceptance.** Changing a referenced document re-fires its downstream referrers,
bounded and cycle-safe.

---

## Phase F — Collaboration (presence + block locking + patch sync)

**Goal.** The plan's hybrid model: coarse-grained block ops via LiveView server
state + Presence; fine-grained prose via a thin client hook syncing PT patches.

**Why now.** Independent of firing; can land any time after Phase C. Scoped to v1
per `docs/collaborative-editing-spike.md` (single-editor + Presence locked for
v1.0; CRDT is post-v1). **Keep that scope** unless re-decided.

**Steps.**
1. **Presence**: add Phoenix Presence to `content_editor_live.ex` for avatars +
   "who's editing." (Already partly scoped in the spike doc.)
2. **Block-level locking**: soft-lock a block to one editor via Presence metadata;
   reject conflicting writes with a friendly message (optimistic `lock_version`
   already exists on documents — extend to per-block where feasible).
3. **Patch sync for prose**: a client hook wraps the existing TipTap editor and
   sends PT JSON patches over the socket; server applies + rebroadcasts. Start with
   last-write-wins patch application (plan's "lightweight patch strategy"); leave a
   seam for CRDT/OT (`y_ex`) as v2.
4. Broadcast block reorder/add/remove over PubSub to other editors' LiveViews.

**New/changed files.**
- `lib/kiln_cms_web/live/content_editor_live.ex`, `assets/js/hooks/prose_sync.js`
- `lib/kiln_cms_web/presence.ex` (if not present)

**Tests.** Two simulated LiveView sessions: presence shows both; lock prevents
concurrent block edit; a prose patch from one appears in the other.

**Acceptance.** Multiple editors see each other; block locking prevents clobbering;
prose patches sync. No CRDT (explicitly deferred).

---

## Phase G — Event log + history + time-travel

**Goal.** Introduce the append-only event substrate: block-level patches broadcast
over PubSub are *also* persisted to a log; document state = fold over the log.
Adds per-block history and time-travel without removing PaperTrail.

**Why now.** Builds directly on Phase F's patches (same events) and Phase C's typed
blocks. Additive — PaperTrail snapshots remain as the publish anchor.

**Steps.**
1. **`DocumentEvent` resource** (`document_type, document_id, seq, actor_id, kind,
   payload, inserted_at`), append-only, indexed by `{document_id, seq}`.
2. **Emit events** from the editor block ops + prose patches (Phase F) — one event
   per mutation. The same struct is broadcast on PubSub and inserted.
3. **Fold/replay**: `KilnCMS.History.replay(document_id, upto: seq | timestamp)`
   reconstructs the block tree at a point in time.
4. **Time-travel preview**: a read-only editor/preview mode that renders a replayed
   state (reuse Phase D preview firing mode over the replayed tree).
5. **Reconcile with PaperTrail**: keep PaperTrail for published-version snapshots
   and `restore_version`; events power fine-grained history/audit between snapshots.
   Document the division in this file.

**New/changed files.**
- `lib/kiln_cms/history/document_event.ex`, `lib/kiln_cms/history/history.ex`
- Editor + PubSub wiring (extends Phase F)

**Codegen.** `mix ash.codegen add_document_events` → `mix ash.migrate`.

**Tests.** Replaying a sequence of events reconstructs the expected tree;
time-travel preview renders a past state; events captured for each editor op.

**Acceptance.** Every block mutation is logged; document state is reconstructable
at any point; time-travel preview works. (Branching drafts: design noted, build
deferred to a later increment.)

---

## Phase H — Block schema evolution / upcasting

**Goal.** Version block schemas in the DSL and run upcast functions on read
(lazy) or via Oban backfill (eager), with a clear strategy for already-fired
artifacts.

**Why now.** Needs typed, versioned blocks (Phase B) and firing (Phase D) so we
can choose re-fire vs. lazy migrate for published artifacts.

**Steps.**
1. **DSL**: add `version N` to `block` and a `migrate :name, from: x, to: y, fn`
   entity to `Kiln.Block` (Phase B extension).
2. **Lazy upcast on read**: when loading a block whose stored `_version` < current,
   run the chain of upcasts before returning. Centralize in the union type's
   cast/load path so every read path benefits.
3. **Eager backfill**: an Oban worker that scans documents, upcasts stale blocks,
   and persists. Idempotent; resumable.
4. **Artifact strategy** (decide + document): for already-fired artifacts on a
   schema bump — **re-fire** (default, simplest given Phase D), keep old
   `format_version`, or lazy-migrate. Recommend re-fire of affected types.
5. **Property test** upcasts: StreamData generates v1 blocks; assert upcast to v2
   is valid and total.

**New/changed files.**
- `lib/kiln/block.ex` (DSL additions + transformer), block modules' `migrate` defs
- `lib/kiln_cms/blocks/upcast_backfill_worker.ex`

**Tests.** Upcast chain v1→v2→v3 composes; lazy read upcasts; backfill is
idempotent; property test over generated blocks.

**Acceptance.** A block type can evolve safely; old data upcasts on read and via
backfill; fired artifacts have a defined evolution path.

---

## Phase I — Block-granular search + embeddings

**Goal.** Move from document-level embeddings to **per-block** embeddings with
ancestor context, and add hybrid block-level search (keyword + filters + vector).

**Why now.** Needs typed blocks + the render contract (to produce embedding text)
and benefits from firing (embed fired blocks). Builds on the shipped
document-level pipeline (`docs/semantic-search-plan.md`, pgvector + Bumblebee
`bge-small-en-v1.5`, HNSW).

**Steps.**
1. **`BlockEmbedding` resource** (`document_type, document_id, block_key,
   block_type, content_hash, embedding vector, ancestor_context`), HNSW index on
   `embedding` (reuse existing `vector` extension + HNSW pattern from Page/Post).
2. **Embedding text projection**: each block's DSL declares its searchable text
   (a `search_text(struct)` callback in the render contract); compose with ancestor
   context (section title / parent block type) per the plan's hierarchical embeddings.
3. **Embed-on-fire** (or on save): an Oban worker computes embeddings for changed
   blocks (dedupe by `content_hash`), mirroring the existing `EmbeddingWorker`.
4. **Hybrid search action**: block-level `search` combining keyword (existing FTS /
   optional Meilisearch) + vector NN + faceted filter by `block_type`. Fuse with
   RRF (already used at document level).
5. **Meilisearch** (optional, plan names it): introduce behind a behaviour only if
   keyword needs outgrow Postgres FTS; default stays Postgres. Don't add the dep
   speculatively.

**New/changed files.**
- `lib/kiln_cms/search/block_embedding.ex`, `lib/kiln_cms/search/block_search.ex`
- `lib/kiln_cms/search/block_embedding_worker.ex`
- `lib/kiln/block/renderer.ex` (`search_text/1` callback)

**Codegen.** `mix ash.codegen add_block_embeddings` → `mix ash.migrate`.

**Tests.** "Find the relevant section" returns the right block; faceting by
block_type works; embeddings recomputed only on content change (hash); honor
shared-sandbox guidance (scope to seeded records, no full-table equality).

**Acceptance.** Block-granular hybrid search returns precise sections, not just
whole documents.

---

## Phase J — Production polish (field/block policies, references UX, media, APIs, JSON-LD)

**Goal.** Close the remaining v2 capabilities and harden.

**Steps.**
1. **Field/block-level policies.** Implement the `policy` DSL entity stubbed in
   Phase B: declare per-field/per-block authorization in the block definition,
   enforced via Ash policies in the editor and on write. Extend `docs/policy-matrix.md`
   with the block/field matrix (e.g. editor may edit a Quote's text but not its
   `featured` flag).
2. **References UX.** First-class reference picker in the editor for `:reference`
   fields (document + block-within-document), backed by Phase E edges.
3. **Media pipeline.** Extend `MediaItem` per plan: focal point (already has
   `focal_x/y`), responsive variants (have `variants`), accessibility metadata
   (have `alt/caption`), **usage tracking** (which documents reference an asset —
   reuse Phase E edges). Add usage display in `media_live.ex`.
4. **JSON-LD serializer.** Implement the `json_ld` surface fully: `Recipe`→`Recipe`,
   `FAQ`→`FAQPage`, `Article`→full graph, driven by block types. Already a fire
   surface from Phase D — fill in per-type mappings.
5. **API layer.** Expose both the editable tree and fired artifacts via AshJsonApi
   + AshGraphql (both deps present). Public API serves artifacts (Phase D read path).
6. **Property-test every serializer.** StreamData generates arbitrary valid block
   trees; assert every serializer (web/json/json-ld) handles every block + mark
   without crashing and round-trips where defined. (This is a v2 headline guarantee.)

**Tests.** Field policy denies the forbidden field edit; JSON-LD validates against
schema.org shapes for representative types; property tests pass over generated
trees; API returns fired artifacts.

**Acceptance.** v2 capability list from `kiln-cms-plan-v2.md` is fully realized and
property-tested.

---

## 2. Cross-cutting working agreements

- **One phase per PR**, each green under `mix precommit` (strict). `mix format`
  first. Follow Ash usage rules linked from `AGENTS.md`.
- **Never hand-write migrations** — always `mix ash.codegen <name>` then inspect,
  then `mix ash.migrate`.
- **Domain interfaces** for every new action; call via `CMS.*`/domain modules.
- **Keep the app shippable.** New machinery lands behind seams (cache behaviour,
  optional Redis/Meilisearch, preview firing) defaulting to current behavior until
  a phase flips the read path.
- **Tests respect the shared sandbox** (memory: never assert full-table/mailbox
  equality; scope to seeded records; `can_*?` is optimistic for reads).
- **AshOban**: `drain_queues?: true` in tests; never `mix run` against the test DB.

## 3. Design decisions to lock (fill in as we go)

> Append decisions here as each phase resolves them, so this guide stays the
> single source of truth alongside `kiln-cms-plan-v2.md`.

- **A1 — Artifact granularity:** ✅ **LOCKED — whole-document artifact composed of
  per-block fragments.** Validated in the spike: each surface body is `map/join`
  over per-block fragments, so partial re-fire (only changed blocks) is achievable
  later in Phase D without changing the artifact contract.
- **A2 — v1 surfaces:** ✅ **LOCKED — `web` (iodata), `json` (structured-intent map),
  `json_ld` (schema.org map).** `email` deferred. Each artifact carries a per-surface
  integer `format_version` (spike: `1`).
- **A3 — Reference resolution:** ✅ **LOCKED — embed referenced data at fire time
  (snapshot).** Validated by `references/1`: a document with reference edges forces a
  **graph walk** (a referrer goes stale when its target re-fires), while a document
  with no edges needs only a tree walk. This is exactly what Phase E's dependency
  graph + re-fire wave consumes. Reads stay free because data is embedded, not resolved.
- **A4 — Serializer dispatch:** ✅ **LOCKED — one pattern-matched function per block
  type per surface**, and every serializer must total over all block types (unknown/
  `:custom` degrades to a comment, never raises). This is the seam the Phase B render
  contract (`render/2`) and the Phase J serializer property tests build on.
- **C1 — Polymorphic mechanism:** ✅ **LOCKED — `Ash.Type.Union`** over `polymorphic_embed`
  (stay within Ash idioms, no extra dep; union members derived from the block registry, tagged by `_type`).
- **C2 — Prose format:** ✅ **LOCKED — Portable Text is canonical**; TipTap JSON is an
  interchange layer converted at the editor boundary (`PortableText.from_tiptap/1` /
  `to_html/1`). Stored truth is PT; unlocks structured marks, JSON-LD, and serializer property tests.
- **D1 — Cache tiers:** ETS default; Redis optional behind behaviour.
- **H1 — Fired-artifact evolution on schema bump:** _TBD_ (recommend re-fire affected types).

## 4. Open questions for the team

1. Do we keep PaperTrail **and** the event log long-term, or migrate snapshots to
   folds-over-events once Phase G is proven? (Guide assumes both coexist.)
2. Is Portable Text adopted as the canonical prose format (replacing stored TipTap
   HTML), or kept as an interchange layer with TipTap JSON as canonical?
3. Block-to-block references: in scope for v1 references, or document-to-document
   only first?
4. Meilisearch: commit now, or stay Postgres-FTS until a concrete need?
