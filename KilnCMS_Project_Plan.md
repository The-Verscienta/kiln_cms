# KilnCMS: A World-Class CMS on the STAPLE Ecosystem

**Project Goal:** Build a modern, high-performance, developer- and editor-friendly Content Management System (headless + traditional) that rivals or exceeds Strapi, Sanity, and even parts of enterprise DXPs like Sitecore/AEM — but built natively on Elixir/Phoenix with the **STAPLE stack** (Phoenix + Elixir + Tailwind + LiveView + **Ash Framework**; the *A* in STAPLE — Alpine.js — is kept optional and isn't currently wired in, since LiveView + colocated JS hooks have covered all client interactivity so far).

**Why this exists:** Strapi is flexible but Node.js-based and limited in real-time/typing/performance. Beacon is great but lighter on modeling. Sitecore/AEM are bloated and expensive. KilnCMS leverages Ash's declarative power for the best content models, LiveView for instant real-time editing/preview, PostgreSQL + Ecto (via Ash) for reliability, and a deliberately minimal ops footprint — **native BEAM `Phoenix.PubSub`** for real-time, **Oban** (Postgres) for jobs, and in-process caching/rate-limiting — with **DragonflyDB** available as an *optional* multi-node shared cache rather than a hard dependency (see **Architectural Decisions** below).

**Vision:** A self-hostable, privacy-first, blazing-fast CMS with:
- Best-in-class content modeling (structured + flexible blocks)
- LiveView-powered visual block editor + rich text (TipTap)
- Instant previews, workflows, versioning
- Powerful headless APIs (JSON:API + GraphQL)
- Minimal ops (Postgres-centric; optional Dragonfly + Meilisearch only when scale demands)
- Built for teams, agencies, and products like Verscienta Health

**Status:** MVP backend largely complete (June 2026), ~69 tests passing, CI + static-analysis (credo/sobelow/dialyzer) + nonce-based CSP in place. Built on Phoenix 1.8 + Ash 3.

- **Modeling & auth (Phase 1, done):** CMS domain — `Page`/`Post` (embedded `Block` tree, D3) + `MediaItem` + `WebhookEndpoint`; AshPaperTrail versioning, AshStateMachine workflow. AshAuthentication password + **magic-link** sign-in, `role` RBAC enforced by `Ash.Policy.Authorizer` (resource + field + version-resource policies). `author` relationship, `published`/`word_count` calcs, authored-count aggregates. Domain code interfaces throughout.
- **Media (Phase 2):** LiveView upload library at `/media` (editor-gated) + pluggable `KilnCMS.Storage` (local adapter). Image variants (libvips) + S3 adapter remain.
- **Workflow (Phase 4):** publish/unpublish/archive, **scheduled publishing** (AshOban cron trigger), **restore-from-version**, **soft-delete** (AshArchival) on Page/Post and MediaItem (with a media Trash view).
- **Headless (Phase 5):** AshJsonApi + AshGraphql + **signed preview tokens** (`/preview/:token`) + **HMAC-signed outbound webhooks** (Oban-delivered) on publish/unpublish.
- **Search/SEO (Phase 6/7):** Postgres full-text `search` action; `seo_image`/`canonical_url`; dynamic `sitemap.xml` + `robots.txt`; `/up` health probe.

**Biggest remaining piece:** Phase 3 content editor (TipTap + drag-and-drop blocks + real-time live preview). Other TODOs: AshAdmin actor wiring (dev-only), image variants/S3, DaisyUI removal. Repo lives at a **spaceless path** (`~/Github/kiln_cms`) — native deps (bcrypt, libvips) build via `make`, which fails on spaced/iCloud paths.

> **Architecture north star — Kiln v2 (in progress).** Beyond the v1.0 feature list, KilnCMS is evolving toward a **typed, addressable content tree**: every block becomes a typed struct generated from one declarative Spark DSL, content is *fired* into immutable per-surface artifacts on publish, and history/search/migrations/structured-data all reduce to operations on that one tree. This **extends** (does not discard) the locked decisions below — the block model stays embedded + atomically versioned (D3), types stay compile-time (D4) — and is captured in **`kiln-cms-plan-v2.md`** (vision) and **`docs/kiln-v2-implementation-guide.md`** (step-by-step build). New decisions **D9–D16** and the **Kiln v2** section below record the direction. **Phase A (firing spike) is complete** — artifact format + serializer dispatch validated, decisions A1–A4 locked.

---

## Tech Stack (World-Class Edition)

### Core STAPLE + Required
| Layer              | Technology                          | Why / Notes |
|--------------------|-------------------------------------|-------------|
| Language           | Elixir 1.19+ / OTP                  | Concurrency, fault-tolerance, DX |
| Web Framework      | Phoenix 1.8+ + LiveView (latest)    | Real-time UIs, channels, PubSub, HEEx components |
| Styling            | Tailwind CSS (latest) + custom HEEx components / design system | Full control, lightweight, consistent with STAPLE philosophy. No DaisyUI by default. |
| Light JS           | Phoenix LiveView + colocated JS hooks (Sortable, TipTap) | Minimal client JS. **No Alpine.js currently** — LiveView + hooks cover interactivity; add Alpine only for a specific need |
| Domain Modeling    | **Ash Framework** (core + AshPostgres + AshPhoenix) | Declarative resources, actions, policies, calculations — best content models possible |
| Admin UI           | **AshAdmin** + custom LiveView pages | Instant super-admin + tailored content editor |
| Database           | PostgreSQL + Ecto (via AshPostgres) | Reliable, JSONB, full-text, strong consistency |
| PubSub / Real-time | **Native `Phoenix.PubSub`** (PG2 / Erlang distribution) + `libcluster` for multi-node | In-process, no broker hop — lowest latency on the editor↔preview hot path (see D1) |
| Cache / Rate limit | **Cachex** or **Nebulex** (in-BEAM) + **Hammer** (ETS) | No external dependency for v1.0 (see D2) |
| Optional shared infra | **DragonflyDB** (Redis-compatible), *optional* | Add only for a measured multi-node shared-cache need; not foundational (see D2) |
| Auth & RBAC        | AshAuthentication + Ash Policies    | Built-in, policy-driven, seamless with LiveView |
| Background Jobs    | **Oban** (Postgres-backed) + AshOban | No Redis needed; reliable queues, cron, unique jobs |
| Versioning & Audit | **AshPaperTrail**                   | Automatic history, drafts, rollback for any resource |
| Workflows          | AshStateMachine + Reactor           | Draft → Review → Published states, complex sagas |
| File / Media       | Phoenix Live Uploads + `Image` (libvips) or Mogrify + ex_aws (S3/MinIO) | Modern uploads, on-the-fly variants, CDN-ready |
| Rich Text / Blocks | **TipTap** (via custom LiveView hook/component) + SortableJS | Modern block-based editor like Notion/Strapi. Proven Phoenix integrations exist |
| Search             | PostgreSQL tsvector (built-in) + optional **Meilisearch** | Fast, typo-tolerant, faceted search for content |
| i18n               | Gettext + Ash locale support        | Multi-language content & UI |
| Headless APIs      | AshJsonApi + AshGraphQL             | Production-ready REST + GraphQL for any frontend (Astro, Next.js, mobile, etc.) |

### World-Class Additions
- **Observability**: Telemetry + OpenTelemetry + Prometheus + Grafana (or built-in LiveDashboard extended)
- **Security**: Plug.SecureHeaders, rate limiting via Hammer (ETS), CSP, Ash policies everywhere, audit logs
- **Testing**: ExUnit + Ash test helpers + LiveViewTest + Wallaby/Playwright (E2E)
- **CI/CD**: GitHub Actions (test, dialyzer, credo, sobelow security, migration checks)
- **Deployment**: Multi-stage **Dockerfile** (includes libvips for image processing + healthcheck) + **Coolify** (your RackNerd VPS) or Fly.io / Render. Releases with hot code upgrades possible. See `Dockerfile` and `docker-compose.yml` in the skeleton.
- **Docs**: ExDoc + Ash documentation generation
- **Optional but recommended**:
  - `libcluster` for multi-node clustering
  - In-BEAM caching (`Cachex`/`Nebulex`); Dragonfly-backed only if multi-node demands a shared cache
  - Plausible or self-hosted analytics integration
  - LLM integration (via `req` + Grok/OpenAI) for AI-assisted content generation, summarization, SEO
  - Beacon (optional later) for advanced page rendering if you want hybrid

**Why this beats alternatives**:
- **Strapi**: Stronger typing, real-time LiveView editing, better performance, native workflows/versioning, no Node.js tax.
- **Sanity/Contentful**: Self-hostable, no vendor lock-in, dramatically lower cost at scale, full control.
- **Sitecore/AEM**: 10-100x lighter, faster iteration, modern DX, no insane licensing.
- **Beacon**: Much more powerful modeling, policies, APIs, versioning out of the box.

---

## Architecture Overview

1. **Content Model Layer** (Ash): Define `Page`, `Post`, `MediaItem`, `Block` (polymorphic or embedded), `ContentType` (for extensibility), `User`/`Account` with tenants if multi-org.
2. **Admin / Editor Layer** (Phoenix LiveView + AshAdmin + custom): Visual block editor, media library, content list with filters, live preview pane.
3. **Delivery Layer**: 
   - Traditional: LiveView-rendered pages or static generation hooks.
   - Headless: AshJsonApi / AshGraphQL endpoints consumed by any frontend.
4. **Real-time & Background**: Phoenix Channels/PubSub (native PG2 backend; see D1), Oban jobs (image processing, publishing notifications, search indexing).
5. **Data**: Postgres primary. In-BEAM cache (Cachex) + ETS rate limiting; optional Dragonfly only as a multi-node shared cache (see D2). Meilisearch for search if needed.
6. **Extensibility**: 
   - Custom Ash extensions, Reactors for complex flows, hooks for AI.
   - **Plugin / Module System**: Plug-and-play custom modules via Elixir behaviours + Ash resource extensions. Support for:
     - Custom block types (register via config or registry)
     - Additional Ash resources with admin UI auto-generation
     - Custom LiveView components/hooks for editor
     - API extensions
     - Marketplace-style loading (future: dynamic module loading or Git-based)

**Content Modeling Philosophy**: Strongly modeled core types + flexible `Block` system (text, image, embed, custom components). Avoid pure dynamic JSONB schemas where possible for compile-time safety and great DX — but support extensibility via `ContentType` + dynamic field definitions if truly needed.

### Real-time Visual Preview Architecture (Storyblok / Payload / Prismic Inspired)

This is one of KilnCMS’s biggest differentiators: a **live, real-time, in-context preview** that feels like Storyblok’s Visual Editor or Payload’s live preview, but powered by Phoenix LiveView + **native BEAM `Phoenix.PubSub`** for instant synchronization — no page reloads, minimal latency, and no broker hop on the hot path (see D1).

**Core Components**:
- **Editor LiveView** (`ContentEditorLive`): Main editing surface with TipTap + drag-and-drop blocks. On every meaningful change (debounced 300-500ms), it broadcasts a structured payload (`%{block_id, type, attrs, order}`) via a Phoenix Channel topic scoped to the content item (e.g., `content:page:123:preview`).
- **Preview LiveView or iframe target**:
  - **Preferred (for true visual editing)**: Side-by-side pane or separate window using a dedicated `ContentPreviewLive` that subscribes to the same `Phoenix.PubSub` topic (native PG2 backend; see D1).
  - **Alternative (maximum fidelity)**: An iframe pointing to a signed preview URL (`/preview/:token`). The iframe contains a lightweight Phoenix LiveView page that also joins the preview channel and re-renders blocks in real time. Uses `postMessage` for cross-origin coordination if needed.
- **Preview Token System** (P1):
  - Generated on demand via `Ash` action.
  - Signed with `Phoenix.Token` (or JWT) containing `content_id`, `user_id`, `expires_at`, and permission scope.
  - Enforced by Ash Policies + a `Preview` plug or LiveView `on_mount` hook.
  - Supports unpublished/draft content securely.
- **Block-level Rendering**:
  - Every block type implements a `render_preview(assigns)` function (or uses the same `render/1` as public delivery).
  - **Embedded block resources** (JSON tree) + pattern-matched components — see D3.
  - Supports nested blocks / slices (Storyblok-style) with recursive rendering.
- **Synchronization & UX**:
  - Optimistic updates in editor + server confirmation.
  - Scroll sync between editor and preview (optional, via JS hook + channel).
  - “Who’s editing” Presence indicators (Phoenix Presence over native PubSub) — foundation for future real-time collab.
  - Auto-save drafts + conflict resolution hints (last-write-wins with version checks via PaperTrail).
- **Performance & Scale**:
  - Native BEAM PubSub for low-latency, in-process messaging — no broker hop on the editor→preview hot path (see D1).
  - LiveView streams for block lists to avoid re-rendering entire documents.
  - Debouncing + batching of updates.
  - CDN-friendly final rendered output; preview is editor-only concern.
- **Security**:
  - Tokens are short-lived and revocable.
  - All preview renders go through the same Ash Policies as the editor.
  - No direct database exposure to preview frontend.

**Future Evolution**:
- True collaborative editing (operational transforms or Yjs CRDTs layered on LiveView).
- In-context clicking in preview to jump to block in editor (bidirectional).
- AI-assisted live suggestions visible in preview.

This architecture makes the editor feel magical for marketers while staying 100% server-rendered and type-safe.

---

## Architectural Decisions (Resolved)

These were previously "open questions." Resolved here to unblock implementation; revisit only with measured evidence, not speculation.

### D1. PubSub: native BEAM, not Dragonfly
Use `Phoenix.PubSub` with the default PG2 (Erlang-distribution) backend for **all** real-time messaging, including the editor→preview channel. Native PubSub is in-process message passing with no network hop or serialization — lower latency than routing through any external broker. Multi-node is handled by `libcluster`. The right comparison is *native vs. Dragonfly*, **not** *Dragonfly vs. Redis*; native wins on the hot path. The backend stays adapter-swappable if a future shared-broker need is actually measured.

### D2. Dragonfly: deferred, not foundational
With Oban on Postgres, Cachex/Nebulex for in-BEAM caching, Hammer (ETS) for rate limiting, and native PubSub (D1), Dragonfly has **no required role in v1.0** and conflicts with the "minimal ops" goal. Defer it; add only when a multi-node *shared* cache is measured as necessary. Docker Compose keeps it as an optional profile, not a default service.

### D3. Block model: embedded JSONB via Ash embedded resources
Blocks are **embedded resources** stored as a JSON tree on the parent (Page/Post), **not** a separate polymorphic table. Rationale: matches Storyblok/Payload/Prismic storage, makes nesting/ordering trivial, and lets **AshPaperTrail snapshot the whole document as one restorable version** (atomic page+blocks versioning is painful with a separate table). Per-block-type Ash embedded schemas preserve compile-time validation and pattern-matched render components. Cross-block querying (e.g., "images missing alt text") is served by a **derived search/index document**, not by normalizing the editor model.

> **v2 evolution (see D10/D11).** Today's single `Block` embedded resource (a `type` atom + free-form `data` map) becomes **one typed embedded struct per block type**, stored as an `Ash.Type.Union` array tagged by `_type`. Still embedded, still atomically versioned — this *deepens* D3's "per-block-type embedded schemas" intent rather than reversing it.

### D4. Content types: compile-time, not a runtime meta-model
Core types and block types are **compile-time Ash resources**. Avoid a runtime/dynamic meta-model — it forfeits the compile-time safety that is the core advantage over Strapi. Extensibility comes from *registered* embedded block types and the plugin system, not dynamic schemas.

> **v2 evolution (see D10).** Block types are still compile-time, but defined through the **`Kiln.Block` Spark DSL** so one declarative definition fans out to schema, validation, editor form, renderers, search projection, and (D15) version/upcast functions. The plugin "register a custom block type" story becomes "add a `Kiln.Block` module."

### D5. Collaboration: locked editing + Presence for v1.0
Ship single-active-editor with Phoenix Presence "who's editing" indicators. CRDT/Yjs collaborative editing fights LiveView's server-authoritative model and is firmly **post-v1** research.

> **v2 evolution (see D14).** The hybrid collab model (block-level server state + Presence; prose patches over the socket) stays within D5's scope, but the **same block-level patches become append-only events** — so collaboration, per-block history, time-travel, and audit fall out of one substrate. CRDT/OT remains post-v1; the event log does not require it.

### D6. Multitenancy: decided day 0, even if unbuilt
Choose Ash's tenancy strategy (attribute- or schema-based) **before** modeling, because retrofitting tenant scoping into policies later is painful. v1.0 may run effectively single-tenant, but the data model assumes a tenant boundary from the start.

### D7. APIs exposed deliberately, not blanket-on
Do **not** auto-enable AshJsonApi + AshGraphQL on every resource. Expose per resource intentionally to limit attack surface and serialization maintenance.

### D8. i18n content is a modeling decision, not just Gettext
Gettext covers **UI** strings. Translating **content** (per-locale field values + locale fallbacks) is built explicitly and interacts with the block model (D3). Decide the approach early if i18n is in scope — not in a late polish phase.

---

### Kiln v2 decisions (D9–D16) — the typed, addressable content tree

These extend D1–D8 toward the v2 north star. Detail and build order live in `kiln-cms-plan-v2.md` and `docs/kiln-v2-implementation-guide.md`; the guide's decision ledger is the running record (A1–A4, C1–C2 already locked there).

### D9. Firing: publish compiles immutable per-surface artifacts
**Publish = firing.** The document tree is compiled **once** into pre-serialized, immutable artifacts — one per surface (`web` iodata, `json` structured-intent, `json_ld` schema.org; email deferred), each stamped with an integer `format_version`. Artifacts live in a `PublishedArtifact` resource and a **two-tier cache** (ETS default; optional Redis/Dragonfly second tier behind a behaviour — still honoring D2). **Public reads hit fired artifacts via the cache, never the live tree.** Artifact granularity is whole-document composed of per-block fragments (so partial re-fire is possible). This makes "published" an auditable compile event and keeps reads nearly free. *(Validated by the Phase A spike; decisions A1/A2.)*

### D10. Typed blocks via the `Kiln.Block` Spark DSL
One declarative definition per block type (a Spark DSL `block :name do field … end`) fans out at compile time to: the Ash embedded schema + changeset/validation, the LiveView editor form fields, the per-surface renderers, the search/embedding projection, and (D15) the version + upcast functions. Adding a block type touches primarily one file; the rest cascades. Serializer dispatch is **one pattern-matched function per block type per surface**, total over all types (unknown/`:custom` degrades, never raises — the guarantee Phase J property-tests). *(Decision A4.)*

### D11. Block storage: `Ash.Type.Union`, not `polymorphic_embed`
Typed blocks are stored as an **`Ash.Type.Union`** array over the registry's embedded resources, tagged by a `_type` discriminator — staying within Ash idioms (no extra dep), versus the `polymorphic_embed` library named in the vision doc. *(Locked — ledger C1.)*

### D12. Prose: Portable Text canonical, TipTap interchange
Rich text inside text blocks is stored as a **Portable Text–shaped structure (the canonical truth)** — formatting and annotations carried as data, not tags. TipTap JSON is an **interchange layer** converted at the editor boundary (`from_tiptap/1` / `to_html/1`). This unlocks structured marks, JSON-LD, and serializer property tests. *(Locked — ledger C2.)*

### D13. Reference-aware invalidation: firing is a graph walk
A `reference` field means a fired artifact may embed data owned by another document (references resolve **at fire time**, snapshotted). So changing a referenced document makes its referrers stale → firing tracks a **dependency graph** (a `ReferenceEdge` resource, rebuilt per fire) and enqueues bounded, **cycle-safe re-fire waves** (Oban) for downstream referrers. Firing is a graph walk, not just a tree walk. *(Decision A3; the question the vision doc flags as most worth resolving early.)*

### D14. One event substrate: collaboration + history + audit
Block-level patches (D5) are **also persisted to an append-only `DocumentEvent` log**; document state is a fold over the log. From one mechanism: realtime collab, full per-block history, time-travel preview, and a complete audit trail. **Coexists with AshPaperTrail** — PaperTrail snapshots remain the publish/restore anchor (`published_version_id`, `restore_version`); events power fine-grained history between snapshots.

### D15. First-class block schema evolution (upcasting)
Block schemas are **versioned in the DSL** (`version N`) with declared **upcast functions** (`migrate :hero, from: 1, to: 2`). Upcasts run **lazily on read** (centralized in the union cast/load path) and **eagerly via Oban backfill**, are composable and property-tested. For already-fired artifacts on a schema bump the default is **re-fire the affected types** (alternatives: keep old `format_version`, or lazy-migrate).

### D16. Block-granular search & embeddings
Each block is the natural unit for embedding and indexing. v2 moves from document-level to **per-block embeddings with ancestor context** (section title / parent block type — hierarchical embeddings) in a `BlockEmbedding` resource, plus **hybrid block-level search** (Postgres FTS / optional Meilisearch keyword + pgvector semantic + faceting by `block_type`, fused with RRF). "Find the relevant section" becomes a first-class, high-precision query. Builds on the shipped document-level pipeline (pgvector + Bumblebee `bge-small-en-v1.5`, HNSW; `docs/semantic-search-plan.md`).

---

## Kiln v2: The Typed, Addressable Content Tree (Architecture North Star)

> Full vision: **`kiln-cms-plan-v2.md`**. Step-by-step build with file paths, codegen, tests, and acceptance criteria per phase: **`docs/kiln-v2-implementation-guide.md`**.

**The central bet:** *content is a typed, addressable tree, not an HTML blob.* Almost every v2 advantage flows from that one decision. By modeling every piece of content as a recursive, discriminated union of typed blocks (with Portable Text inside text blocks), one block definition fans out across the entire vertical slice (schema → validation → editor → renderers → search → embeddings → APIs), and firing/history/migrations/structured-data all reduce to operations on that single tree.

**How v2 relates to the current build.** v2 is an **evolution**, not a rewrite — it lands behind seams so the app stays shippable. Several v2 ideas are already partly built (embedded blocks D3, TipTap editor, pgvector + Bumblebee search, PaperTrail versioning, Cachex delivery cache, signed previews). v2 deepens these: single `Block` → typed union blocks (D10/D11), TipTap HTML → Portable Text (D12), PaperTrail-only → PaperTrail + event log (D14), document embeddings → block-granular (D16), and adds the genuinely new **firing/artifact** layer (D9) with **reference-aware invalidation** (D13) and **block schema upcasting** (D15).

**Phased build (A–J).** Resequences the vision doc's Phase 0–5 so firing-for-real (which needs typed blocks) comes after the DSL, and the throwaway firing **spike** de-risks the format first:

| Phase | Focus | Status |
|-------|-------|--------|
| **A** | Firing spike (throwaway): artifact format + serializer dispatch | ✅ Done (A1–A4 locked) |
| **B** | `Kiln.Block` Spark DSL + typed blocks + Portable Text shape | ✅ Done |
| **C** | `Ash.Type.Union` storage + legacy↔typed bridge | ✅ Core done¹ |
| **D** | Firing for real: `PublishedArtifact` + two-tier cache + read path | ✅ Done¹ |
| **E** | Reference-aware invalidation (dependency graph + re-fire waves) | ✅ Done |
| **F** | Collaboration: block locking + op broadcast + prose patch sync | ✅ Core done² |
| **G** | Event log + per-block history + time-travel | ✅ Done |
| **H** | Block schema evolution / upcasting | ✅ Done |
| **I** | Block-granular embeddings + faceted semantic search | ✅ Done |
| **J** | Field/block policies + JSON-LD graph + serializer property tests | ✅ Core done² |

Each phase shipped as its own commit, green under `mix precommit` (**454 tests, 2
property tests**), Ash codegen for every migration. The full server-side v2
architecture is in place behind the existing app, which stays shippable throughout.

¹ The typed-block representation is canonical and drives firing/search/history via
the `KilnCMS.CMS.TypedBlocks` bridge; flipping the *stored* `Page.blocks` column to
the union shape + rewriting `ContentEditorLive` to author native union blocks (and
repointing public HTML/JSON/GraphQL delivery onto `Engine.read/3`) is the one
remaining cross-cutting increment — UI/migration work that needs browser iteration.
² Browser-bound layers (Presence avatars, the TipTap prose-sync JS hook, the
reference-picker UX, media-usage UI) and editor policy-enforcement wiring land with
that editor rewrite. Server-side primitives for all of them are built and tested.

See `docs/kiln-v2-implementation-guide.md` for each phase's outcome, files, and the
A1–A4 / C1–C2 / H1 decision ledger.

---

## Strong Patterns from Modern Headless CMSs

We selectively incorporate the best ideas from **Directus, Payload CMS, Storyblok, Prismic, and Contentful** to make KilnCMS feel modern and powerful while staying true to Elixir/Ash strengths (strong typing, declarative modeling, real-time LiveView, self-hostable performance).

### Key Patterns & How We Adopt Them

| Source CMS     | Strong Pattern                          | How KilnCMS Incorporates It |
|----------------|-----------------------------------------|-------------------------------|
| **Directus**   | Database-first + Instant APIs + Granular field-level permissions | AshPostgres as source of truth. **AshJsonApi + AshGraphQL** enabled by default for every resource. Field-level + record-level **Ash Policies** (visualized/enhanced in AshAdmin). Real-time subscriptions via Phoenix Channels + native `Phoenix.PubSub` (D1). |
| **Payload CMS**| Code-first schema + Excellent DX + Lifecycle hooks + Embedded flexibility | **Ash resources are the schema** — even more powerful compile-time safety than TypeScript. Lifecycle via **Ash actions, changes, preparations, and Reactor** sagas. Embedded schemas + polymorphic blocks for flexible page building. Auto-generate TypeScript clients from Ash (future). |
| **Storyblok / Prismic** | Visual / In-context Editing + Composable Blocks & Slices (nestable, reusable components) | **Real-time Visual Preview Architecture** (detailed above). First-class support for **nested, reusable Block types** with drag-and-drop. Component library in admin that feels like Blok/Slice system. Bidirectional editor ↔ preview (future). |
| **Contentful** | Structured, reusable content models + Composable experiences + Strong workflows & localization | “Content from presentation” philosophy reinforced. **Ash relationships + calculations** for reusable components/entries. Advanced publishing workflows via **AshStateMachine + Reactor**. Built-in i18n via Ash locale support + Gettext. |
| **All of them**| Live preview + Real-time collaboration foundations + Granular access control + Performance-first delivery + Emerging AI assistance | **Live preview + Presence** (detailed architecture). **Ash Policies** everywhere for RBAC + field-level control. **Native PubSub** + in-BEAM caching (optional Dragonfly/Meilisearch only at scale). **LLM hooks** (via `req` library) for AI content generation, alt text, SEO optimization, summarization — pluggable. |

### Additional Strong Patterns We’re Adopting
- **Granular, visual permissions** — Make Ash Policies more approachable in the admin UI (inspired by Directus).
- **Lifecycle hooks everywhere** — Before/after create/update/publish actions for side effects (notifications, search indexing, webhooks).
- **Composable & nestable content** — Blocks/Slices as first-class citizens (not an afterthought).
- **Headless + Preview parity** — What you see in preview is exactly what the API returns (same rendering pipeline).
- **Self-hosted performance & cost control** — No vendor lock-in, dramatically better price/performance than Contentful/Storyblok at scale.
- **Extensibility as a core feature** — Our plugin system (behaviours + Ash extensions) draws from Payload’s hooks and Directus’ extensions.

These patterns elevate KilnCMS from “another CMS” to a **modern, delightful, production-grade platform** that editors love and developers respect.

---

## Key Features (Phased)

### MVP (Months 1-3) — deliberately lean; prove the end-to-end loop first
**Goal:** a working **create → publish → consume via API** loop *early*, then iterate on the editor (the real time sink — see Phase 3 and Risks). AshAdmin is a developer/CRUD tool, not the editor UI; the custom editor LiveView *is* the product and is budgeted as a from-scratch build.
- User auth (email/password + magic link) with roles (Admin, Editor, Viewer)
- Core content resources (Page, Post) with **embedded blocks** (D3)
- Plain rich-text + a small set of basic block types (defer TipTap to v1.0)
- Basic AshAdmin for data inspection + a custom content list/create/edit LiveView
- Media library: upload, list, search (defer variants/focal point to v1.0)
- Basic publishing (draft/published)
- JSON:API **read** endpoints for headless consumption (exposed deliberately — D7)

*Deferred out of MVP into v1.0: TipTap rich editor, drag-and-drop blocks, live preview, media variants. These are where the schedule risk lives — don't pull them forward.*

### v1.0 "World-Class Core" (Months 4-6)
- TipTap rich-text editor + real-time live preview (moved from MVP)
- Full drag-and-drop block-based visual editor (Sortable + TipTap + custom blocks)
- Versioning & history (AshPaperTrail) with restore
- Workflows (AshStateMachine): Draft → In Review → Published + approvals
- Advanced media (variants, focal point, alt text, bulk actions)
- Full GraphQL + enhanced JSON:API
- Search (Postgres + Meilisearch)
- SEO fields + auto sitemap generation
- Multi-language content support
- Granular permissions via Ash Policies
- Native PubSub + in-BEAM caching & rate limiting (Dragonfly only if multi-node demands it — D2)
- Basic analytics dashboard (page views via telemetry)

### Future / Stretch
- Real-time collaborative editing (Presence + operational transforms or CRDTs — ambitious)
- AI content assistant (generate blocks, rewrite, SEO optimize, image alt text)
- Advanced workflows & notifications (email via Swoosh + Oban)
- Multi-tenancy / white-label
- Headless + traditional hybrid rendering options
- Integration with Verscienta Health (TCM content, patient education, etc.)
- Robust plugin/extension system (plug-and-play custom modules)
- Mobile admin app (LiveView Native?)

---

## Timeline & Milestones (Realistic Estimate)

**Assumptions**: Part-time to full-time dedication (evenings + focused blocks). Solo or small team. High-quality, production-ready code (tests, docs, security). Adjust based on available hours.

- **Month 0 (Now – Setup Sprint, 1-2 weeks)**: Project bootstrap, core decisions, Docker dev environment.
- **Month 1 (Foundation & Modeling – 4 weeks)**: Core Ash resources, auth, basic admin, Postgres + native PubSub setup. **Milestone**: Running app with auth + simple content CRUD in AshAdmin.
- **Month 2 (Media + Basic Editor – 4 weeks)**: Media library, TipTap integration, simple block editing. **Milestone**: Can create/edit pages with rich text blocks + media.
- **Month 3 (Visual Editor & Polish – 4-5 weeks)**: Drag-and-drop block system, live preview, content listing UX. **Milestone**: Usable visual editor for non-technical users.
- **Month 4 (Workflows, Versioning, APIs – 4 weeks)**: AshPaperTrail, state machines, publishing flows, full headless APIs, preview tokens. **Milestone**: Production-ready content lifecycle + API consumption.
- **Month 5 (Search, Performance, i18n, SEO – 3-4 weeks)**: Meilisearch integration, caching/perf deep-dive, multi-lang, SEO tools. **Milestone**: Fast, internationalized, searchable CMS.
- **Month 6 (Hardening, Testing, Deployment, Docs – 4 weeks)**: Full test coverage, security audit, CI/CD, Coolify deployment, comprehensive docs, beta release. **Milestone**: v1.0 deployed and documented.

**Total to v1.0**: ~6 months realistic for high-quality result.

**Stretch (Post v1.0)**: AI features (1-2 months), real-time collab (research heavy), advanced analytics, Verscienta-specific modules.

**Risk Buffer**: Add 20-30% time for learning curve on Ash/LiveView editor patterns and complex block editor interactions.

---

## Comprehensive TODO List

Use this as living checklist. Mark as you progress. Grouped by phase/category. Priority: **P0** (blocker/MVP), **P1** (v1.0), **P2** (nice-to-have).

**GitHub tracking:** Remaining work is filed as issues labeled `roadmap` (phases `phase-0` … `phase-9`, `stretch`). Master checklist: [#67](https://github.com/The-Verscienta/kiln_cms/issues/67). Project board: [KilnCMS Roadmap](https://github.com/users/The-Verscienta/projects/1). Regenerate with `scripts/create_roadmap_issues.sh` (idempotent only for new items — edit existing issues by hand).

> **Checklist reconciled against main, 2026-07-19.** Caution on issue history: PR #106 ("complete remaining roadmap issues") merged **prematurely with only its first commit** (#46, notification prefs) — the other ~19 issue commits never reached main, though several were independently rebuilt later (plugins #262/#263, static export, a11y audits, localization #272). Issues whose scope is still genuinely missing were **reopened**: #42, #45, #48, #51, #53, #56, #57, #59, #60, #62, #65.

### Phase 0: Project Bootstrap & Environment (P0)
- [x] Create GitHub repo + initial `mix phx.new kiln_cms --live --database postgres` (generated in-place)
- [x] Add core Ash dependencies (`ash`, `ash_postgres`, `ash_phoenix`, `ash_admin`, `ash_paper_trail`, `ash_state_machine`, `ash_json_api`, `ash_graphql`, `ash_authentication`, `ash_authentication_phoenix`, `ash_oban`/`oban`) via Igniter
- [x] Add Image/Mogrify, ex_aws (or similar), TipTap assets or CDN strategy, SortableJS — `:image` (libvips, not Mogrify), `ex_aws`/`ex_aws_s3` + swappable `KilnCMS.Storage` adapter, TipTap bundled via npm/esbuild (no CDN), SortableJS vendored. Strategy documented in `docs/frontend-assets.md`
- [x] Set up Docker Compose: Postgres + **Dragonfly** + (optional Meilisearch + MinIO). See `docker-compose.yml` with health checks.
- [x] Configure native `Phoenix.PubSub` (PG2, Phoenix default). Dragonfly kept as an *optional* Compose profile only (D1/D2). In-BEAM caching: TODO when needed
- [x] Set up `.env.example` / config for local dev
- [x] Add Credo, Dialyxir, Sobelow, ExDoc — `credo --strict` + `sobelow` wired into `mix precommit` and CI; `.credo.exs`/`.sobelow-conf` configured; dialyzer PLT config in `mix.exs`
- [x] Create basic README, this plan file, CONTRIBUTING.md, LICENSE — `CONTRIBUTING.md` added (workflow, Ash conventions, quality gate); README/LICENSE present
- [x] Set up Tailwind with custom component library (HEEx + Tailwind) for admin/editor UI — Kiln's own design language shipped: component kit + `Layouts.console` app shell, all authoring pages migrated (`docs/design-language.md`, `docs/design-system.md`).

### Phase 1: Core Modeling & Auth (P0)
- [x] Define core Ash Resources: `MediaItem`, `Page`, `Post`, with **embedded `Block` resources** (D3) + version resources (via PaperTrail). **Still to add:** `Account`, `User` (with auth). Tenancy strategy (D6): TODO before auth lands
- [x] Database migrations via Ash (`mix ash.codegen` → `mix ash.migrate`); verified against Postgres
- [x] Implement relationships, calculations, aggregates — `author` belongs_to User on Page/Post (stamped from the actor via `relate_actor` on create); `published` + `word_count` (module calc over the embedded block tree) calculations; `authored_page_count`/`authored_post_count` aggregates on User. Covered by `content_model_test.exs`
- [x] Set up AshAuthentication (email/password + registration/sign-in LiveViews at `/register`, `/sign-in`; **magic-link** passwordless sign-in for existing users at `/magic_link/:token`, registration disabled, `require_interaction?` on, covered by `magic_link_test.exs`)
- [x] Ash Policies for RBAC — `role` attribute (`:admin`/`:editor`/`:viewer`, defaults `:viewer`) enforced by `Ash.Policy.Authorizer` on Page/Post/MediaItem: published content world-readable, unpublished editors-only, authoring/workflow editor+admin, hard-delete admin-only; User policies let admins manage users and users self-read/change-password. PaperTrail `Version` resources are editor/admin-only via the shared `KilnCMS.CMS.VersionPolicies` mixin. Covered by `policies_test.exs`, `version_policies_test.exs`, and field-policy/auth coverage in `user_auth_test.exs`. **Still TODO:** AshAdmin actor wiring
- [x] Basic seeds for demo content + admin user — idempotent `priv/repo/seeds.exs` (run by `setup`/`ecto.setup`): seeds a pre-confirmed admin + editor user (creds via `ADMIN_*`/`EDITOR_*` env, dev defaults) and demo Page/Post content created through the real Ash actions + publish workflow as the admin actor
- [x] AshAdmin wired (domain + resources exposed at `/admin`) with custom content-focused overrides (#25): Page/Post/MediaItem grouped under a `content` dropdown, friendly datatable columns (internals like `search_text`/`embedding`/`lock_version` hidden), trimmed action lists (scheduler/embedding writes hidden), title/filename relationship labels, and nil-safe datetime formatting via `KilnCMS.CMS.Admin`. Taxonomy (`Category`/`Tag`) and `WebhookEndpoint` grouped too. Covered by `admin_test.exs`

### Phase 2: Media Library & Uploads (P0/P1)
- [x] Phoenix LiveView upload handling with progress, preview, validation — `KilnCMSWeb.MediaLive` at `/media` (editor/admin only via `:live_editor_required`): drag-and-drop, multi-file, live previews, progress bars, accept/size validation. Covered by `media_live_test.exs` + browser-verified.
- [x] `MediaItem` resource with metadata (alt, caption, focal point, variants)
- [x] Image processing pipeline (`Image`/libvips + **Oban job for variants**) — `KilnCMS.ImageProcessor` (libvips) reads dimensions + builds responsive variants (thumb 400 / medium 1024, never upscales). Generation runs **off the upload request** in `KilnCMS.Media.VariantWorker`: `MediaLive` stores the original + creates the item, then enqueues the worker (by id), which **re-fetches the original from `Storage` (`Storage.fetch/1`)** — so it runs correctly on any node, no temp hand-off (#27) — processes, persists variant blobs, writes `width`/`height`/`variants` back, and **broadcasts on `"media:updated"`** so an open library live-refreshes. Non-raster uploads / deleted items / missing originals degrade gracefully. Covered by `media/variant_worker_test.exs`, `storage_test`/`s3_test` (`fetch`), and `media_live_test` (live refresh).
- [x] Storage backend — pluggable `KilnCMS.Storage` behaviour + `Local` adapter (priv/uploads, served at `/uploads`), traversal-guarded. **`S3` adapter** (`KilnCMS.Storage.S3`) for production: ExAws-backed (`put_object`/`delete_object`, `public-read`, config-driven bucket + `public_base_url`), works with AWS S3 / MinIO / R2 (opt-in via `S3_BUCKET` env in `runtime.exs`; MinIO already in `docker-compose` storage profile). HTTP goes through a Req-backed ExAws client (`Storage.S3.ReqClient`) instead of hackney. Covered by `storage/s3_test.exs` (signing exercised end-to-end via `Req.Test`)
- [x] Media browser modal/picker usable from editor — shipped in `ContentEditorLive` (library picker for image blocks + featured image).
- [x] Bulk upload (**done** — multi-file), deletion (**done** — admin). **Soft-delete (AshArchival)** is wired on **Page/Post** *and* **MediaItem** (destroy → `archived_at`, excluded from reads). On media this preserves referential integrity for content still pointing at an item (`featured_image` FKs, block image URLs): a deleted item is kept along with its storage blobs until an admin restores it or permanently `:purge`s it (purge reclaims the original + variant blobs). Admin-only **Trash** view in the media library (restore / delete-permanently), mirroring the content `/editor/trash`. **Media filename filter** in the library (done). Covered by `media_archival_test.exs` + media LiveView trash tests.

### Phase 3: Content Editor & Blocks (P1 — Hardest)
- [x] **TipTap** LiveView integration — `rich_text` blocks use a TipTap editor via a `RichText` JS hook (StarterKit + a B/I/H2/list/quote toolbar); the editor HTML mirrors into a hidden input bound to the block's `content`, so it saves through the normal form. Requires Node (`npm install` in `assets/`, bundled by esbuild; Dockerfile installs node/npm + `npm ci`). Browser-verified (mounts, toolbar formats, content round-trips).
- [x] Define **embedded `Block` resources** (D3) with typed variants (rich_text, heading, image, quote, embed, divider, columns, custom)
- [x] Build drag-and-drop sortable interface — vendored SortableJS + a `Sortable` LiveView hook in `PageEditorLive`; drop pushes the new order, the server reorders the nested block forms via `AshPhoenix.Form.sort_forms`. Reorder→persist covered by `editor_live_test.exs` + browser-verified (hook mounts, no JS errors).
- [x] **Real-time Visual Preview** (full D1 architecture, #28) — `ContentEditorLive` has a **side-by-side live preview pane** rendered from the form state via the shared `KilnCMSWeb.BlockComponents` (textarea + TipTap edits update it live, debounced). Plus a **PubSub-decoupled pop-out preview window** (`KilnCMSWeb.PreviewLive` at `/editor/preview/:kind/:id`): the editor broadcasts `{:preview_update, …}` over native `Phoenix.PubSub` on every change and the standalone window re-renders with no reload. The pop-out renders with **public-site fidelity** — the same `Layouts.public` shell + `prose` article markup the live site uses (posts show their excerpt), with a "Draft preview" ribbon. **Presence for collaboration** is wired too: `KilnCMSWeb.Presence` powers a live "who's editing" roster + live field-focus cursors. Covered by `editor_live_test.exs` (side-by-side render, broadcast→render path, public-shell fidelity, post excerpt, presence roster, cursors) + browser-verified. Signed-URL JSON preview for headless consumers lives separately (Phase 5, `PreviewController`).
- [x] Block library / inserter UI (#29) — `ContentEditorLive` has a **Notion-style slash-command inserter** replacing the flat per-type button row: an "Add block" trigger (and a global `/` shortcut) opens a filterable, keyboard-navigable menu (`BlockInserter` JS hook — ↑/↓/Enter/Esc, type-to-filter) listing **every registered block type** with an icon + description. The palette stays registry-driven (a new `Kiln.Block` module surfaces automatically). Each option is a real `add_block` button (works without JS, directly testable) wired as an accessible `combobox`→`listbox` with `aria-activedescendant`. Covered by `editor_live_test.exs` (lists all registry types, insert + persist) + browser-verified (open/filter/arrow-nav/Enter-insert/Esc).
- [x] Rich text formatting toolbar, keyboard shortcuts, slash commands — TipTap toolbar + the slash-command block inserter (#29) + a documented shortcut set (`docs/editor-shortcuts.md`).
- [x] Save/publish actions with error handling — `PageEditorLive` saves via `AshPhoenix.Form` (nested block forms) and runs the publish/submit/unpublish workflow; covered by `editor_live_test.exs` + browser-verified
- [x] Content listing page — `EditorLive` at `/editor`: lists **pages and posts** with type label + status badges, create-new (page/post), inline publish/unpublish, edit links, status filter + title search. **Bulk actions shipped** (two-step confirmed bulk verbs in `EditorLive`)
- [x] **Post editor** — the page editor is generalized into `ContentEditorLive`, serving both `/editor/pages/:id` and `/editor/posts/:id` (the `live_action` selects the kind; Page/Post differences dispatch to the per-kind code interfaces). Posts add an excerpt field. Covered by `editor_live_test.exs`.

### Phase 4: Workflows, Versioning & Publishing (P1)
- [x] Integrate **AshPaperTrail** on Page/Post for full history (embedded Blocks are versioned with the parent — D3). Restore action still TODO
- [x] Implement `AshStateMachine` for content states (draft → in_review → published → archived) with transition actions
- [x] Publishing action that creates immutable published version + updates live version — `published_version_id` on Page/Post points at the PaperTrail snapshot taken by `publish`/`publish_scheduled` (`Changes.RecordPublishedVersion`, wired in `after_transaction` so the version row exists first); cleared on `unpublish` (`Changes.ClearPublishedVersion`). Internal `:set_published_version_id` action excluded from PaperTrail. Version history UI shows a **Live published** badge when `version.id == published_version_id`. Covered by `published_version_test.exs`.
- [x] Approval workflow (simple: editor submits → admin approves) — editors `submit_for_review` (draft → in_review) but cannot `publish`; admins `publish`/`publish_scheduled` (including **Approve** from in_review) and `return_to_draft`. Role-aware workflow buttons in `ContentEditorLive` + `EditorLive` (editors see Submit; admins see Publish/Approve/Return). Covered by `approval_workflow_test.exs`, `policies_test.exs`, `editor_live_test.exs`.
- [x] Restore previous version from history — `restore_version` action (Page/Post) reverts content fields to a chosen PaperTrail version, reconstructing the full state by replaying the `changes_only` versions up to it; workflow state is untouched and the restore is itself versioned. Block `:id`s are now accepted so they stay stable across restores. Exposed as `CMS.restore_page_version`/`restore_post_version`; covered by `restore_version_test.exs`.
- [x] Scheduled publishing (Oban + cron) — `scheduled_at` on Page/Post + an **AshOban** trigger (`publish_scheduled`, every-minute cron) that publishes content whose time has passed, authorized as a system job via an `AshOban.Checks.AshObanInteraction` policy bypass. Covered by `scheduled_publishing_test.exs`. First real use of the wired Oban/AshOban infra.
- [x] Draft autosave (debounced LiveView save) — `ContentEditorLive` schedules a debounced timer (`:editor, :autosave_debounce_ms`, default 2s) on each edit and persists the draft via `AshPhoenix.Form.submit` when the editor pauses. **Drafts only** (published/in-review/archived change only via the explicit Save); a "Saved / Unsaved changes" indicator tracks status. Manual save / workflow transitions cancel the pending timer. Covered by `editor_live_test.exs`. **Autosave version coalescing (#32):** autosave goes through a dedicated `:autosave` action (distinct from the explicit Save's `:update`), so its PaperTrail versions are tagged `version_action_name: :autosave`. After each save, `Changes.CoalesceAutosaveVersions` merges the trailing run of autosave versions (since the last manual version) into one — preserving the cumulative `:changes_only` delta so restore/replay stays correct — and prunes the redundant rows via a system-only `:destroy` on the version resource (`VersionPolicies`). A draft therefore keeps a single "latest autosaved draft" version between manual saves; manual saves and workflow transitions stay distinctly versioned. Covered by `editor_live_test.exs` (coalescing + manual-distinct) and `restore_version_test.exs` (restore of a coalesced run).

### Phase 5: Headless APIs & Preview (P1)
- [x] Enable **AshJsonApi** (router at `/api/json` + OpenAPI/Swagger UI) — exposed per resource (D7). **Filtering/sorting/pagination tuned (#33):** Page/Post/MediaItem now expose `index :read` + `get :read` routes (Post also `/posts/published`); the primary `:read` actions are paginated (offset + keyset, `default_limit: 25`, `max_page_size: 100`, `countable`, `required?: false` so internal `CMS.list_*` callers still get plain lists). Filtering (`filter[...]`), sorting (`sort=`) and pagination (`page[...]`) derive from the public fields. Query params documented in `docs/json-api.md`; covered by `json_api_test.exs` (filter combinations, sort asc/desc, offset paging + count/next-link, get-by-id, draft visibility via bearer, media filtering).
- [x] Enable **AshGraphQL** (schema at `/gql` + playground) — types per resource (D7). **Query/mutation surface tuned (#34):** the public schema is now a curated, **read-only delivery surface** — published-content reads per content type (`<type>BySlug` via `:public_by_slug`, `<type>Translations` via `:published_translations`, `publishedPosts` for posts) alongside the existing `search`/`semanticSearch`/`autocomplete` queries, plus world-readable taxonomy (`categories`/`tags` lists + `categoryBySlug`/`tagBySlug`). Authoring/workflow mutations are **deliberately not exposed** (those run through the admin editor + bearer JSON:API), and the media library has no top-level query (resolves only as the nested `featuredImage`). Documented in `docs/headless-graphql-api.md` (curated surface + playground/cURL examples); covered by `delivery_graphql_test.exs` (published reads hide drafts, taxonomy reads, no write mutations, no media listing) + `search_graphql_test.exs`.
- [x] **Outbound webhooks** on publish — `WebhookEndpoint` resource (admin-managed; per-endpoint secret) + a `NotifyWebhooks` change that dispatches `<type>.published` (publish/publish_scheduled), `<type>.unpublished` (unpublish), and `<type>.updated` (edits to already-published content; `only_when: :published` keeps draft edits and autosaves silent) events. Delivered by an Oban `DeliveryWorker` (HMAC-SHA256 signature header, retried with backoff, inactive/unsubscribed endpoints skipped). Selectable events are derived at runtime from every registered content type × verb (so `mix kiln.gen.content` types get events for free). **Admin webhook UI (#35):** `KilnCMSWeb.WebhookLive` (`/editor/webhooks`, admin-only) — create endpoints with per-event checkboxes, enable/disable, edit, delete, and view the signing secret. Covered by `webhooks_test.exs` (signed delivery via Req.Test, `updated` fires only on published edits, inactive/unsubscribed skipping, dynamic event list, admin-only) + `webhook_live_test.exs` (auth, create-with-events, toggle, delete).
- [x] Preview tokens / signed URLs for unpublished content — `KilnCMS.CMS.PreviewToken` (stateless `Phoenix.Token`, 1h expiry) + `GET /preview/:token` (`PreviewController`) returns the referenced draft Page/Post as JSON (curated public fields, no internal leakage). Covered by `preview_controller_test.exs`.
- [x] **Example frontend consumers (#36)** — [`examples/astro-blog/`](examples/astro-blog): a runnable Astro static site that builds a small blog **entirely from the headless API** (no DB/shared code). Discovers content via `GET /sitemap.xml`, fetches each document's structured artifact via `GET /api/content/:type/:slug?surface=json` (the v2 delivery API, D9), renders the typed blocks + Portable Text to HTML client-side (a faithful port of the server renderers), and demonstrates GraphQL search via `POST /gql` (`searchPosts`). Includes a full headless setup walkthrough; [`examples/README.md`](examples/README.md) indexes the public delivery surfaces. Build verified against the seeded `welcome` page + `hello-world` post.
- [x] **API documentation (OpenAPI/Swagger via ash_json_api) (#37)** — the AshJsonApi-generated **OpenAPI 3 spec** (`/api/json/open_api`) and its interactive **Swagger UI** (`/api/json/swaggerui`) are now published in **all environments** (dev + prod), not dev-only. `KilnCMSWeb.OpenApi.modify/3` (wired as `:modify_open_api`) enriches the generated spec with a titled `info` block + auth/usage description (covering bearer auth, pagination/filtering, GraphQL, webhooks, preview), concrete `servers`, and an **optional** bearer requirement (`security: [%{}, %{"bearerAuth" => []}]` — published content is anonymous, a token only widens access to drafts). Swagger UI runs under a dedicated `:swagger_ui` pipeline + CSP (cdnjs bundle allowed, inline boot script nonced). **Headless sign-in:** a new `KilnCMSWeb.ApiAuthController` (`POST /api/auth/sign_in`, `:auth` rate-limit bucket) exchanges email+password for the AshAuthentication user **JWT** as JSON (`{token, user}`) — the server-to-server way to get a bearer token (the browser auth flow is session-based). Invalid creds return a generic 401 (no user enumeration); the endpoint is documented in the OpenAPI spec via `auth_paths/0`. A top-level [`docs/api.md`](docs/api.md) indexes every headless surface (auth/sign-in, JSON:API, GraphQL, fired artifacts, webhooks, preview tokens, rate limits). Covered by `api_explorer_routes_test.exs` (spec + Swagger UI reachable with `dev_routes` false; spec carries the bearer scheme + sign-in + core content paths) and `api_auth_controller_test.exs` (token issuance/usage, generic 401, 422).

### Phase 6: Search & Performance (P1)
- [x] PostgreSQL full-text search on content — a denormalized `search_text` (title + SEO + extracted block text, maintained by `Changes.SetSearchText`) + a `search` read action using `to_tsvector`/`plainto_tsquery`, exposed as `CMS.search_pages`/`search_posts`. Visibility-aware (goes through the read policy). Shared `CMS.BlockText` helper (also powers `word_count`). Covered by `content_search_test.exs`. Backed by a **GIN functional index** (`{pages,posts}_search_text_gin_index`) whose `to_tsvector('english', coalesce(search_text, ''))` expression matches the `search` filter exactly, so the planner uses it instead of scanning. **Relevance-ranked** — results sort by `ts_rank` desc (newest as tiebreak) via an internal `search_rank` calculation threaded the query term. **Phase 6 follow-up (#38) done:** the functional index was replaced by a **stored, trigger-maintained, locale-weighted `search_vector tsvector` column** (`kiln_regconfig/1` + `setweight` title=A/body=B; migrations `drop_old_search_gin` + `add_locale_weighted_search`), and **result highlighting** shipped — a `highlight` calc (`ts_headline`) rendered escape-safely by `KilnCMS.Search.Highlight.to_safe_html/1` and surfaced as snippets in the admin search palette (`/editor/search`). Migration path + rationale: `docs/search-tsvector-migration.md`.
- [x] Optional: Meilisearch integration + indexing jobs (Oban) — `KilnCMS.Search.Meilisearch` + indexing worker shipped (`docs/meilisearch.md`); resolves the "commit to Meilisearch?" open question below.
- [x] Caching strategy — **Cachex (in-BEAM)** caches published content on the delivery hot path: `KilnCMS.Cache.fetch_published/3` caches the delivery payload per `{type, slug, locale}` (60-min safety-net TTL; nils never cached so new content shows immediately), used by `ContentController`. **Phase 6 (#40) done:** the cached payload now carries the **media-enriched blocks** (resolved `srcset`/`alt`/dimensions), so the per-image media lookup runs once at cache-miss time and a cache hit serves resolved media URLs with no extra query. Invalidation is **per record, not a full clear** — `Changes.BustContentCache` calls `Cache.bust/2` to drop only the affected `{type, slug}` keys across all locales (busting both old + new slug on a rename), still only when published content is involved (publish/edit-published/unpublish/archive/delete) and skipping draft-only writes (autosave). Because media is now cached into the payload, a media-item write busts the cache too (`Changes.BustMediaCache`; full clear — a media item has no single-record blast radius). Toggle with `config :kiln_cms, KilnCMS.Cache, enabled: false`. Covered by `cache_test.exs` (per-key `bust/2`) + `content_cache_test.exs` (serves from cache, per-key bust leaves others intact, cache hits carry resolved media). **Rate limiting on APIs (Hammer/ETS)** already wired (`KilnCMSWeb.RateLimit`). Dragonfly stays deferred (D2).
- [x] Performance profiling — two full performance audits with fixes merged (June + July 2026; `docs/audit-2026-07-performance-usability.md`, `docs/performance.md`); Telemetry + OpenTelemetry/Sentry wired (`docs/observability.md`).
- [ ] CDN integration strategy for media — **still open** (#42 reopened; its commit was lost in the #106 premature merge — see note above). API responses got `Cache-Control` via #188, but media uploads/variants have no CDN headers or strategy.

### Phase 7: Polish, i18n, SEO & World-Class Features (P1/P2)
- [x] Gettext + locale switching for UI and content — **done** (D8): content is modelled per-locale (unique `[slug, locale]`), and the public site is now locale-aware. `KilnCMSWeb.Plugs.SetLocale` (endpoint) strips a `/<locale>/…` path prefix and sets the locale (config `:kiln_cms, :i18n` — `default_locale`/`locales`); `ContentController` serves the requested locale by slug with **fallback to the default locale**, emits `<html lang>`, `og:locale`, and `rel="alternate" hreflang` alternates (+ `x-default`) for every published translation, and the sitemap lists each locale variant at its prefixed URL. `KilnCMS.I18n` centralises config; `published_translations` read + `list_*_translations` interfaces back the alternates. The **public site UI is now localized too**: chrome strings (`Blog`, `Powered by KilnCMS.`, `No posts yet.`) are wrapped in `gettext` and translated (`fr`/`es` `.po` shipped; `mix gettext.extract`/`merge` wired), the `SetLocale` plug sets the Gettext locale, and a **language switcher** in the public layout links to each published translation. Covered by `plugs/set_locale_test.exs` + `content_i18n_test.exs` (incl. localized chrome + switcher). **Admin UI localization (started):** LiveViews restore the UI locale from the session via a `:restore_locale` on_mount (`LiveUserAuth`) that sets the Gettext locale; `LocaleController` (`/locale/:locale`) persists the choice and a **language switcher** in `Layouts.app` toggles it. The shared admin nav + `EditorLive` + `AnalyticsLive` strings are wrapped in `gettext` with a full **`fr`** translation (`es` partial). Covered by `admin_i18n_test.exs`. **Done since:** the remaining admin LiveViews are gettext-wrapped (`ContentEditorLive`, `MediaLive`, …), and per-locale authoring shipped with the localization workflows — coverage/staleness dashboard + one-click translation scaffolding (PR #272, `docs/localization-workflows.md`).
- [x] SEO fields — `seo_title`, `seo_description`, **`seo_image` (og:image)**, **`canonical_url`** on Page/Post (exposed via the content serializer to preview/webhooks) + **schema.org JSON-LD**: `KilnCMSWeb.StructuredData` builds a `BlogPosting` (posts) / `WebPage` (everything else) map — title, url (canonical or `public_base_url` + type prefix), description, image, publish/modified dates, `:site_name` publisher — emitted as a `<script type="application/ld+json">` in the delivery `<head>` by `ContentController`. Covered by `structured_data_test.exs` + a `content_controller_test` head assertion. **Extended (#44):** content pages also emit a **`BreadcrumbList`** (Home › [Blog ›] Title) and an **`author`** Person when the content's author has a public `name` (new nullable `User.name` + `update_profile` action; `ContentController` loads `:author`); the **`/blog` index** emits a **`CollectionPage`** + `ItemList`. Covered by the extended `structured_data_test.exs` / `content_controller_test.exs`.
- [x] Auto-generated sitemap.xml and robots.txt — `SitemapController` (`/sitemap.xml`, `/robots.txt`) lists published pages (`<base>/<slug>`) + posts (`<base>/blog/<slug>`) off the `:public_base_url` config; robots is now served dynamically (removed the static file). Covered by `sitemap_controller_test.exs`
- [x] Basic analytics (page view tracking + simple dashboard) — **privacy-first**: a separate `KilnCMS.Analytics` domain with a `ContentView` upsert counter (one row per content item, atomic `views + 1` increment, `last_viewed_at`) — **no IPs/user-agents/cookies/PII**. Public delivery records a view best-effort (`ContentController`, failures never break delivery). Dashboard at `/editor/analytics` (`KilnCMSWeb.AnalyticsLive`, editor/admin only) shows total views + most-viewed content with titles. Covered by `analytics/content_view_test.exs` + `analytics_live_test.exs`. **Follow-up:** time-series/charts (the counter is totals-only); emit a telemetry event for external sinks.
- [x] Email notifications (Swoosh + Oban) for workflow events — `KilnCMS.Notifications` mirrors the webhook pipeline: a `Changes.NotifyWorkflowEmail` change (on `submit_for_review`/`publish`/`publish_scheduled` for Page+Post) resolves recipients as a system read and enqueues `Notifications.WorkflowMailWorker` Oban jobs. **Submit-for-review** emails every admin (minus the submitter); **publish** emails the author (covers scheduled, actor-less publishing). Swoosh via the existing `KilnCMS.Mailer`. Covered by `notifications_test.exs`. **TODO:** approval-granted/changes-requested events; per-user notification prefs.
- [x] Accessibility audit (admin UI) — a11y issue sweep #133–197 fixed (June 2026) + full-surface audit follow-ups (`docs/audit-2026-07-full-surface.md`: focal-point keyboard a11y, form labels).
- [ ] Theming / white-label potential — **still open** (#48 reopened; its `KilnCMS.Branding` commit was lost in the #106 premature merge). With strict multi-tenancy now live, the natural shape is **per-org** branding/theming.

### Phase 8: Testing, Security, CI/CD, Docs (P0 for v1)
- [x] Comprehensive ExUnit tests for resources, policies, actions — the suite is far past the v2-era 454 tests; every feature arc lands with coverage under `mix precommit`.
- [x] LiveView tests for editor flows — `editor_live_test.exs` and siblings cover editing, workflow, presence, preview, media, taxonomy, trash.
- [x] E2E with Playwright (#50) — headless-Chromium suite in `e2e/` driving the editor (TipTap rich text, SortableJS drag-reorder) through the create → edit → publish → view-live journey. Runs in a dedicated `MIX_ENV=e2e` against its own `kiln_cms_e2e` DB via `mix e2e.setup` + `PHX_SERVER=true mix phx.server`; a separate `e2e` CI job runs the headless browser suite. Documented in `CONTRIBUTING.md`.
- [~] Security: Sobelow (**done** — wired into precommit/CI), **nonce-based CSP** on the browser pipeline (**done** — browser-verified), policy coverage (**done** — `docs/policy-matrix.md` + policy tests; three full security audits since June 2026), rate limiting tests (**done**). **Still open:** an automated dependency-audit CI gate (#51 reopened — dep CVEs were fixed manually in #414, but no `mix deps.audit` gate is wired).
- [x] GitHub Actions workflow (test on push/PR, dialyzer, credo, sobelow, format + unused-deps check) — `.github/workflows/ci.yml`. **Migration-drift check (#52):** CI runs `mix ash.codegen --check`, failing the build when the committed migrations/resource snapshots diverge from the Ash resources; documented in `CONTRIBUTING.md`.
- [ ] Full ExDoc documentation + guides — **still open** (#53 reopened; lost in #106). `docs/` has 56 markdown guides, but no ExDoc config/grouping in `mix.exs` to publish them.
- [x] This project plan kept up-to-date as living doc — reconciled 2026-07-19; see also the realized-history note in `kiln-cms-plan-v2.md`.

### Phase 9: Deployment & Operations (P0)
- [x] Production-ready `Dockerfile` (multi-stage, libvips, healthcheck) + `docker-compose.yml` for local dev and Coolify.
- [x] Coolify service configuration — prod runs on Coolify (RackNerd VPS); deploys are a manual Coolify *Redeploy* per `docs/deploy-p3.md` + `docs/environment-variables.md`.
- [x] Database migrations in release — `KilnCMS.Release.migrate` + `rel/overlays/bin/migrate`.
- [~] Monitoring setup — Sentry (errors) + OpenTelemetry (tracing) wired, env-gated no-ops by default (`docs/observability.md`); LiveDashboard available. **Still open:** a `/ready` readiness probe (DB + Oban depth) + alert rules (#56 reopened; only `/up` exists).
- [ ] Backup strategy (Postgres + media) — **still open** (#57 reopened; its runbook was lost in the #106 premature merge). The most consequential gap for the live prod instance.
- [x] Domain + SSL via Coolify — prod is live behind Coolify on the VPS.
- [ ] Beta user testing (internal or friendly clinics/agencies) — **still open** (#59 reopened).

### Stretch / Post-v1.0
- [ ] AI content generation assistant (block-level prompts via LLM) — **still open** (#60 reopened; `KilnCMS.AI` was lost in #106). Adjacent AI surface that *did* ship: MCP server (`docs/mcp.md`), RAG guide (`docs/rag.md`), llms.txt/GEO delivery.
- [x] Real-time collaborative editing — shipped for real, not just researched: Yjs CRDT with server-side checkpoint materialization (#258/#261); the BEAM renders Yjs→HTML with no JS step.
- [~] Advanced reporting / content analytics — governance dashboard shipped (`docs/governance-dashboard.md`); **content analytics remain totals-only** — time-series/trends + telemetry view events still open (#45/#62 reopened).
- [x] Robust **Plugin / Module System** — `Kiln.Plugin` (D18) complete incl. the custom field-type registry (`Kiln.FieldType`, #266); marketplace / runtime discovery tracked in #333.
- [~] Verscienta Health specific modules — largely superseded: **dynamic content types** let TCM types (Herb, Condition, …) be defined at runtime without first-party modules (#64 stays closed with a supersession note).
- [ ] Mobile admin (LiveView Native) — **still open** (#65 reopened; the spike doc was lost in #106).
- [x] Static site generation export — `mix kiln.export.static` rebuilt on the v2 firing layer (`docs/static-export.md`; org-explicit since strict tenancy).

---

## Getting Started (Once Implementation Begins)

1. `git clone ... && cd kiln_cms`
2. `docker compose up -d` (Postgres; add `--profile cache` for optional Dragonfly)
3. For import testing: `docker compose --profile import-test up -d strapi directus`
4. `mix setup` (or manual deps + migrate)
5. `mix phx.server`
6. Visit admin, log in with seeded admin, start creating content.

Full setup guide will live in `/docs/setup.md`.

---

## Risks, Open Questions & Mitigations

**Risks**:
- **Block editor is ~80% of perceived value and the biggest schedule risk.** Mitigate by starting simple (plain block, then a single TipTap block) and iterating; leverage community examples heavily. Do not let it bleed into MVP.
- **TipTap ↔ LiveView DOM ownership.** LiveView diffs the DOM; TipTap/ProseMirror owns its editor subtree. Expect to live in `phx-update="ignore"` + a JS hook bridging editor events ↔ server. It's a solved pattern but fiddly state management — spike it before committing the editor architecture.
- **AshAdmin ≠ editor UI.** It's a developer/CRUD/debug tool; the editor-facing experience is a custom LiveView build. Don't under-budget it.
- Ash learning curve for complex modeling — pair with excellent examples (RealWorld Ash, Tunez book).
- Performance of LiveView for very large documents — use streams, pagination, debouncing, and in-BEAM caching.
- **Timeline optimism**: "rival/exceed Strapi + Sanity + Sitecore/AEM" in ~6 months part-time solo is aggressive even with the 20-30% buffer. Cut MVP hard (see MVP section); the editor is the schedule.

**Resolved (see Architectural Decisions)**:
- Block data model → embedded JSONB via Ash embedded resources (**D3**); evolving to typed union blocks (**D10/D11**).
- Content Type dynamism → compile-time Ash resources, no runtime meta-model (**D4**); block types via the `Kiln.Block` DSL (**D10**).
- Collaboration level → locked editing + Presence for v1.0 (**D5**); block patches become the event substrate (**D14**).
- Primary use case → general-purpose core; Verscienta Health as the *first plugin/consumer*, not a coupling.
- **Preview transport** → shipped as a **side-by-side LiveView pane** in `ContentEditorLive`; a signed-iframe/pop-out for public-site fidelity is the remaining v2 increment (Phase F / D9 preview firing mode).
- **Storage abstraction** → custom **`KilnCMS.Storage` behaviour** (Local + S3/MinIO/R2 adapters), not `waffle`.
- **Firing / "published" semantics** → resolved by **D9** (compile to immutable per-surface artifacts) + **D13** (reference-aware invalidation); Phase A spike validated the format.

**Still open** *(reconciled 2026-07-19 — all four since resolved)*:
- ~~Multitenancy~~ — shipped fully: org-scoped resources (#336), then **strict** tenancy + per-org capability tiers (#419).
- ~~PaperTrail + event log~~ — coexistence stuck, as **D14** assumed.
- ~~References~~ — reference fields are in the block DSL; **D13** graph invalidation shipped.
- ~~Meilisearch~~ — committed and shipped alongside Postgres FTS + pgvector (**D16**).

**Success Metrics (v1.0)**:
- Non-technical editor can create beautiful page with mixed blocks in < 5 minutes without training.
- Headless API response < 50ms p95 for typical queries.
- Full test coverage > 80%.
- Deployed and stable on Coolify with zero-downtime releases.
- Positive internal/ beta feedback on editor UX and modeling power.

---

## Resources & References

- Ash Framework: https://www.ash-hq.org/ + excellent docs + forum
- RealWorld Ash + LiveView example: team-alembic/realworld
- Tunez (Ash book example): sevenseacat/tunez
- TipTap Phoenix examples: Search Elixir Forum / existing demos (tiptap-phoenix.fly.dev)
- DragonflyDB: https://www.dragonflydb.io/ (drop-in Redis replacement)
- Phoenix LiveView block editor talks/examples on YouTube
- AshPaperTrail, AshStateMachine, AshAdmin docs
- Your previous Verscienta / Phoenix explorations

---

**Next Immediate Steps**:
1. ~~Review this plan~~ — done; feedback folded into Architectural Decisions (D1–D8), leaner MVP, and Risks.
2. ~~Decide on project name~~ — **KilnCMS** (repo: `kiln_cms`).
3. ~~Bootstrap the Phoenix + Ash project skeleton~~ — done; MVP backend largely complete (see Status).
4. ~~Set up Docker dev environment~~ — done (Postgres + native PubSub; Dragonfly optional profile — D2).
5. **Kiln v2 build (current focus)** — Phase A (firing spike) ✅ done; **Phase B next** (`Kiln.Block` Spark DSL + typed blocks + Portable Text). Roadmap A–J in `docs/kiln-v2-implementation-guide.md`.

This plan is designed to be actionable, realistic, and ambitious enough to create something genuinely world-class while staying true to the STAPLE philosophy of high productivity and joy in development.

Let's build something exceptional. Ready when you are. 🚀

---

*Document created: June 2026 | Living document — update as we progress.*