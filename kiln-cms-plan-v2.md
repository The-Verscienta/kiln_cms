# Kiln
## A Typed, Addressable Content Tree for Elixir/Phoenix

*One declarative definition. Recursive structure. Kiln-fired performance, correctness, and leverage.*

*Original design & architecture plan — since realized. All six roadmap phases have shipped (several exceeded, e.g. CRDT collaboration and runtime-defined content types), and three of the four v1 non-goals were later built deliberately (visual page building, multi-tenancy, rich-text CRDT). Kept as design history; see the README for the current feature set.*

---

### Executive Summary

Kiln is a content management architecture built on a single powerful idea: **content is a typed, addressable tree of structured data — not an HTML blob**.

By modeling every piece of content as a recursive, discriminated union of typed blocks (with Portable Text–style rich prose inside text blocks), Kiln delivers capabilities that are difficult or impossible to achieve cleanly in traditional or loosely structured CMSs:

- Section-level composition **and** paragraph-level rich structure in one system
- Extremely high leverage from a single block definition (schema, validation, editor UI, renderers, search, embeddings)
- A clean "firing" model that separates cheap mutable drafts from high-performance immutable published artifacts
- Native block-granular collaboration, history, versioning, and AI retrieval
- First-class schema evolution with safe upcasting
- Structured data (JSON-LD) and multi-surface output that fall out naturally
- Deep integration with the Ash Framework for policies, actions, APIs, and domain modeling

Kiln is designed for teams that need **deep, structured, long-lived content** — especially technical, educational, medical, or research-oriented domains such as East Asian Medicine, clinical education, research platforms, and complex marketing sites.

---

### The Central Bet

**Content is a typed, addressable tree, not an HTML blob.**

Almost every advantage in this proposal flows from that single decision.

---

### The Bar to Match

Two existing systems define what "deep" field handling looks like. Kiln should meet or exceed both.

**Payload blocks** — structure at the section level
- Each block has its own typed schema with fields, validation, and editor UI
- Blocks are nestable and reorderable
- Stored as structured JSON (intent, not rendered HTML)
- Block definitions generate types for the frontend

**Sanity Portable Text** — structure at the paragraph level
- Rich text stored as a structured array of blocks and spans
- Formatting and annotations carried as data (not tags)
- Embeddable typed objects inside prose
- Open spec with serializer-driven rendering

**Kiln's goal**: deliver both levels natively in one recursive, type-generating system, built for Elixir/Phoenix/Ash.

---

### Field System

A deep field system is defined by reference handling, nesting, conditional logic, and type generation — not raw count.

**Target inventory:**

- **Primitives**: text, rich text (Portable Text–shaped), number, boolean, date/datetime, slug, URL, email, color
- **Structured**: reference (see below), array/list, object/group, blocks
- **Media**: image (focal point + alt + accessibility metadata), file, video embed, asset library picker
- **Specialized**: geolocation, JSON escape hatch, markdown, select/enum (single + multi), tags, computed/derived
- **Editorial**: conditional fields, validation rules, field-level localization, live-preview bindings

**First-class References**
In addition to embedded blocks, Kiln supports `reference` fields that point to other Documents or specific blocks within them. Essential for relational content (e.g., a Formula referencing multiple Herb documents, an Article referencing ResearchHighlight blocks or external studies).

> **Note — references and firing interact.** A reference edge means a fired artifact may embed data owned by another document. When the referenced document changes, every artifact that referred to it is now stale. This makes the firing dependency a *graph*, not just the block tree — see the firing section.

---

### Architecture for Elixir/Phoenix + Ash

The innovation is not merely porting existing editors. It is that **Elixir + Ash + Spark** lets one declarative definition fan out across the entire vertical slice of a block type, while the addressable tree makes realtime, retrieval, and compilation problems dramatically simpler.

#### 1. Block Type as Spark + Ash DSL Entry

Define block types through a combined Spark/Ash DSL:

```elixir
defmodule Kiln.Blocks.Hero do
  use Kiln.Block

  block :hero do
    field :headline, :string, required: true
    field :subheadline, :rich_text
    field :background_image, :image
    field :cta, :object do
      field :label, :string
      field :url, :url
    end

    # Ash policy example
    policy :edit do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end
end
```

From this single definition, Kiln derives:
- Ecto embedded schema + changeset/validation
- Ash Resource behavior (where applicable)
- LiveView admin form components
- Render components (HEEx for web, separate modules for email/JSON)
- Search projection + embedding text
- TypeScript/JSON Schema export (optional)

Adding a block type touches primarily one file. The rest cascades.

#### 2. Polymorphic Embeds + Ash Resources for the Tree

Documents are stored as `jsonb` using Ecto's `polymorphic_embed` (or equivalent) with a `_type` discriminator. Each block becomes a real typed struct.

Portable Text spans, marks, and annotations nest as embeds inside text blocks.

Core entities (`Document`, `PublishedArtifact`, etc.) are modeled as **Ash Resources**, giving policies, actions, calculations, and APIs.

#### 3. Serializers as Pattern-Matched Function Components

One HEEx function component per block/mark type for web. A second module pattern-matches the same structs for email, app JSON, or JSON-LD. Multiple dispatch by struct type acts as the serializer registry.

#### 4. Collaboration Model

**Coarse-grained (block level):** block reordering, adding/removing blocks, and editing non-text fields use pure LiveView server state + Phoenix Presence for avatars and simple locking.

**Fine-grained (inside text blocks):** a thin client hook wraps a modern rich-text editor (TipTap, Lexical, or custom contenteditable) that syncs Portable Text–shaped JSON patches over the socket.

Full simultaneous character-level editing inside rich text can use a lightweight patch strategy initially, with CRDT or OT available for v2 if needed.

This hybrid approach is pragmatic and keeps most logic on the server.

#### 5. Block-Granular pgvector + Meilisearch

Each block is a natural unit for embedding and indexing.

- Hierarchical embeddings (block content + ancestor context such as section title or parent block type)
- Hybrid search (Meilisearch keyword + filters + pgvector semantic)
- Faceted filtering by block type and metadata

"Find the relevant section" becomes a first-class, high-precision query.

#### 6. The Hybrid Editor

- Section-level composition (add/reorder/configure blocks) → pure LiveView, tree as server state
- Inline prose inside a text block → thin client hook syncing structured JSON

Everything except the caret lives server-side.

---

### What Makes It Better — The Tier Above Mechanics

#### Firing: The Core Performance & Correctness Primitive

- **Draft** = "wet clay": mutable LiveView server state. Cheap to edit, fully validated.
- **Publish** = "firing": compile the tree **once** into pre-serialized, immutable artifacts per surface (web output, JSON API, email, JSON-LD) and push them into the ETS → Redis two-tier cache.
- Reads **never** touch the live document tree — they hit kiln-fired artifacts and are nearly free.

**Capabilities:**
- Incremental/partial firing (only changed blocks + dependents)
- **Reference-aware invalidation:** firing tracks a dependency graph across reference edges, so changing a referenced document re-fires its downstream referrers, not just its own tree
- Explicit artifact format and versioning
- Invalidation + re-firing strategy when block schemas evolve
- Preview firing mode for live editor previews

This cleanly separates editing from serving and makes "published" a meaningful, auditable event.

#### One Event Substrate for Collaboration + Versioning + Audit

Block-level patches broadcast over PubSub are the same events persisted to an append-only log. Document state is a fold over that log. From one mechanism:
- Realtime collaboration
- Full per-block history
- Time-travel preview
- Branching drafts
- Complete audit trail

#### First-Class Block Schema Evolution

- Version block schemas in the DSL
- Declare upcast functions: `migrate :hero, from: 1, to: 2`
- Run them lazily on read or eagerly via Oban backfill
- Clear strategy for already-published artifacts (re-fire, keep old version, or lazy migration)
- Upcast functions are testable and composable

A genuine competitive advantage.

#### Structured Data Falls Out of the Types

Because every block is typed, schema.org / JSON-LD output is just another serializer target. A `Recipe` block emits `Recipe`, an `FAQ` block emits `FAQPage`, an `Article` emits the full graph. No hand-maintained markup.

#### Property-Test Every Serializer

Typed structs + StreamData let you generate arbitrary valid content trees and assert that every serializer handles every block and mark without crashing. Round-trip guarantees across web, email, and app — correctness that is extremely hard to achieve in HTML-blob CMSs.

#### Permissions via Ash Policies

Field-level (and block-level) access control declared in the DSL and enforced by Ash policies. An editor can edit a Quote's text but not its `featured` flag. Access control lives next to the schema.

---

### Additional Capabilities

- **References** — first-class cross-document and block-to-block links
- **Media Pipeline** — upload handling, focal points, responsive variants, accessibility metadata, usage tracking
- **API Layer** — Ash JSON API (and/or GraphQL) exposure of both the editable tree and fired artifacts
- **i18n** — field-level localization with clear interaction rules for the recursive tree and Portable Text

---

### Non-Goals & Scope (v1)

- Full simultaneous rich-text CRDT/OT inside every text block (pragmatic patch sync first)
- Visual page builder / drag-and-drop layout engine (focus on structured data first)
- Multi-tenancy / workspace isolation (can be added via Ash later)
- Headless-only with zero server rendering (Kiln is hybrid by design)

---

### Phased Implementation Roadmap

| Phase | Focus               | Key Deliverables                                    |
|-------|---------------------|-----------------------------------------------------|
| 0     | Foundation          | Firing model + artifact format + basic typed blocks |
| 1     | Core Editing        | One rich text block + LiveView block composition    |
| 2     | Collaboration       | Presence + block locking + patch sync for text      |
| 3     | History & Evolution | Event log, versioning, upcasting, time-travel       |
| 4     | Search & AI         | Hierarchical embeddings + hybrid search             |
| 5     | Production Polish   | Ash policies, references, media pipeline, APIs      |

---

### Suggested First Move

Pressure-test the **firing / compilation model** first — it shapes cache strategy, what "published" means, how serializers are invoked, and where reads land. The reference-aware invalidation question (above) is the part most worth resolving early, since it determines whether firing is a tree walk or a graph walk.

If that holds up, the next natural steps are:
1. Spark + Ash DSL surface for 2–3 representative block types (including one rich text block)
2. Polymorphic embed schemas + basic LiveView form
3. Simple firing implementation for one output surface

---

### Through-line

The structured tree is not just a storage format — it is the central leverage point. Firing, history, migrations, structured data, property testing, permissions, and block-granular AI retrieval all reduce to operations on one addressable, typed tree. One declarative definition per block type fans out to schema, validation, editor, renderers, search, embeddings, and APIs.

**Kiln turns content modeling into a compounding advantage instead of a recurring source of technical debt.**
