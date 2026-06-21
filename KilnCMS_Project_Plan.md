# KilnCMS: A World-Class CMS on the STAPLE Ecosystem

**Project Goal:** Build a modern, high-performance, developer- and editor-friendly Content Management System (headless + traditional) that rivals or exceeds Strapi, Sanity, and even parts of enterprise DXPs like Sitecore/AEM — but built natively on Elixir/Phoenix with the **STAPLE stack** (Phoenix + Elixir + Tailwind + Alpine.js + LiveView + **Ash Framework**).

**Why this exists:** Strapi is flexible but Node.js-based and limited in real-time/typing/performance. Beacon is great but lighter on modeling. Sitecore/AEM are bloated and expensive. KilnCMS leverages Ash's declarative power for the best content models, LiveView for instant real-time editing/preview, PostgreSQL + Ecto (via Ash) for reliability, and a deliberately minimal ops footprint — **native BEAM `Phoenix.PubSub`** for real-time, **Oban** (Postgres) for jobs, and in-process caching/rate-limiting — with **DragonflyDB** available as an *optional* multi-node shared cache rather than a hard dependency (see **Architectural Decisions** below).

**Vision:** A self-hostable, privacy-first, blazing-fast CMS with:
- Best-in-class content modeling (structured + flexible blocks)
- LiveView-powered visual block editor + rich text (TipTap)
- Instant previews, workflows, versioning
- Powerful headless APIs (JSON:API + GraphQL)
- Minimal ops (Postgres-centric; optional Dragonfly + Meilisearch only when scale demands)
- Built for teams, agencies, and products like Verscienta Health

**Status:** Skeleton Bootstrapped (June 2026) — Phoenix 1.8 + Ash 3 core (ash, ash_postgres, ash_phoenix), CMS domain with **Page/Post** (embedded `Block` tree per D3) + **MediaItem**, **AshPaperTrail** versioning, **AshStateMachine** publishing workflow, **AshJsonApi + AshGraphql + AshAdmin** wired and serving, Postgres via Docker Compose (Dragonfly/Meilisearch/MinIO behind optional profiles), multi-stage Dockerfile with libvips. **AshAuthentication** (Accounts domain, User/Token, password strategy, `/sign-in` + `/register`, `role` attribute for RBAC) and **Oban + AshOban** (Postgres-backed) are wired and verified booting. **RBAC policies** enforced via `Ash.Policy.Authorizer` on Page/Post/MediaItem (published-public reads, editor authoring, admin-only deletes) + User (admin-managed, self-read), covered by tests. Verified compiling, migrating, and serving (home/sign-in/register/admin/GraphQL/JSON:API all 200). Repo lives at a **spaceless path** (`~/Github/kiln_cms`) — native deps (bcrypt, libvips) build via `make`, which fails on spaced/iCloud paths. **Not yet wired:** magic-link strategy, RBAC on PaperTrail version resources + AshAdmin actor wiring, media upload pipeline, TipTap editor + live preview, DaisyUI removal.

---

## Tech Stack (World-Class Edition)

### Core STAPLE + Required
| Layer              | Technology                          | Why / Notes |
|--------------------|-------------------------------------|-------------|
| Language           | Elixir 1.19+ / OTP                  | Concurrency, fault-tolerance, DX |
| Web Framework      | Phoenix 1.8+ + LiveView (latest)    | Real-time UIs, channels, PubSub, HEEx components |
| Styling            | Tailwind CSS (latest) + custom HEEx components / design system | Full control, lightweight, consistent with STAPLE philosophy. No DaisyUI by default. |
| Light JS           | Alpine.js + Phoenix JS hooks        | Minimal client JS |
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

### D4. Content types: compile-time, not a runtime meta-model
Core types and block types are **compile-time Ash resources**. Avoid a runtime/dynamic meta-model — it forfeits the compile-time safety that is the core advantage over Strapi. Extensibility comes from *registered* embedded block types and the plugin system, not dynamic schemas.

### D5. Collaboration: locked editing + Presence for v1.0
Ship single-active-editor with Phoenix Presence "who's editing" indicators. CRDT/Yjs collaborative editing fights LiveView's server-authoritative model and is firmly **post-v1** research.

### D6. Multitenancy: decided day 0, even if unbuilt
Choose Ash's tenancy strategy (attribute- or schema-based) **before** modeling, because retrofitting tenant scoping into policies later is painful. v1.0 may run effectively single-tenant, but the data model assumes a tenant boundary from the start.

### D7. APIs exposed deliberately, not blanket-on
Do **not** auto-enable AshJsonApi + AshGraphQL on every resource. Expose per resource intentionally to limit attack surface and serialization maintenance.

### D8. i18n content is a modeling decision, not just Gettext
Gettext covers **UI** strings. Translating **content** (per-locale field values + locale fallbacks) is built explicitly and interacts with the block model (D3). Decide the approach early if i18n is in scope — not in a late polish phase.

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

### Phase 0: Project Bootstrap & Environment (P0)
- [x] Create GitHub repo + initial `mix phx.new kiln_cms --live --database postgres` (generated in-place)
- [x] Add core Ash dependencies (`ash`, `ash_postgres`, `ash_phoenix`, `ash_admin`, `ash_paper_trail`, `ash_state_machine`, `ash_json_api`, `ash_graphql`, `ash_authentication`, `ash_authentication_phoenix`, `ash_oban`/`oban`) via Igniter
- [ ] Add Image/Mogrify, ex_aws (or similar), TipTap assets or CDN strategy, SortableJS
- [x] Set up Docker Compose: Postgres + **Dragonfly** + (optional Meilisearch + MinIO). See `docker-compose.yml` with health checks.
- [x] Configure native `Phoenix.PubSub` (PG2, Phoenix default). Dragonfly kept as an *optional* Compose profile only (D1/D2). In-BEAM caching: TODO when needed
- [x] Set up `.env.example` / config for local dev
- [x] Add Credo, Dialyxir, Sobelow, ExDoc — `credo --strict` + `sobelow` wired into `mix precommit` and CI; `.credo.exs`/`.sobelow-conf` configured; dialyzer PLT config in `mix.exs`
- [x] Create basic README, this plan file, CONTRIBUTING.md, LICENSE — `CONTRIBUTING.md` added (workflow, Ash conventions, quality gate); README/LICENSE present
- [ ] Set up Tailwind with custom component library (HEEx + Tailwind) for admin/editor UI. Start with clean, professional design system.

### Phase 1: Core Modeling & Auth (P0)
- [x] Define core Ash Resources: `MediaItem`, `Page`, `Post`, with **embedded `Block` resources** (D3) + version resources (via PaperTrail). **Still to add:** `Account`, `User` (with auth). Tenancy strategy (D6): TODO before auth lands
- [x] Database migrations via Ash (`mix ash.codegen` → `mix ash.migrate`); verified against Postgres
- [ ] Implement relationships, calculations (e.g., published version, word count), aggregates
- [x] Set up AshAuthentication (email/password + registration/sign-in LiveViews at `/register`, `/sign-in`). **Still to add:** magic-link strategy
- [x] Ash Policies for RBAC — `role` attribute (`:admin`/`:editor`/`:viewer`, defaults `:viewer`) enforced by `Ash.Policy.Authorizer` on Page/Post/MediaItem: published content world-readable, unpublished editors-only, authoring/workflow editor+admin, hard-delete admin-only; User policies let admins manage users and users self-read/change-password. Covered by `test/kiln_cms/cms/policies_test.exs`. **Still TODO:** policies on PaperTrail `Version` resources; AshAdmin actor wiring
- [x] Basic seeds for demo content + admin user — idempotent `priv/repo/seeds.exs` (run by `setup`/`ecto.setup`): seeds a pre-confirmed admin + editor user (creds via `ADMIN_*`/`EDITOR_*` env, dev defaults) and demo Page/Post content created through the real Ash actions + publish workflow as the admin actor
- [x] AshAdmin wired (domain + resources exposed at `/admin`); custom content-focused overrides still TODO

### Phase 2: Media Library & Uploads (P0/P1)
- [ ] Phoenix LiveView upload handling with progress, preview, validation
- [ ] `MediaItem` resource with metadata (alt, caption, focal point, variants)
- [ ] Image processing pipeline (`Image` lib or Mogrify + Oban job for variants)
- [ ] Storage backend (local dev + S3/MinIO production) — consider `waffle` or simple custom
- [ ] Media browser modal/picker usable from editor
- [ ] Bulk upload, search, filtering, deletion with soft-delete (AshArchival)

### Phase 3: Content Editor & Blocks (P1 — Hardest)
- [ ] Research & implement **TipTap** LiveView integration (use existing community examples as base)
- [ ] Define **embedded `Block` resources** (D3) with typed variants (text, heading, image, quote, embed, custom component, etc.)
- [ ] Build drag-and-drop sortable interface (SortableJS hook + LiveView streams or assigns)
- [ ] **Real-time Visual Preview** (implement full architecture: Editor LiveView → native `Phoenix.PubSub` → Preview LiveView/iframe with signed tokens, optimistic updates, Presence foundation) — P1 core differentiator (D1)
- [ ] Block library / inserter UI
- [ ] Rich text formatting toolbar, keyboard shortcuts, slash commands (TipTap extensions)
- [ ] Save/publish actions with optimistic UI + error handling
- [ ] Content listing page with filters, search, bulk actions, status badges

### Phase 4: Workflows, Versioning & Publishing (P1)
- [x] Integrate **AshPaperTrail** on Page/Post for full history (embedded Blocks are versioned with the parent — D3). Restore action still TODO
- [x] Implement `AshStateMachine` for content states (draft → in_review → published → archived) with transition actions
- [ ] Publishing action that creates immutable published version + updates live version
- [ ] Approval workflow (simple: editor submits → admin approves)
- [ ] Restore previous version from history
- [ ] Scheduled publishing (Oban + cron)
- [ ] Draft autosave (debounced LiveView save)

### Phase 5: Headless APIs & Preview (P1)
- [x] Enable **AshJsonApi** (router at `/api/json` + OpenAPI/Swagger UI) — exposed per resource (D7). Filtering/pagination tuning TODO
- [x] Enable **AshGraphQL** (schema at `/gql` + playground) — types per resource (D7). Query/mutation surface tuning TODO
- [ ] **Outbound webhooks** on publish/update — trigger downstream static rebuilds (Astro/Next); Oban-delivered, signed (HMAC), retried with backoff
- [ ] Preview tokens / signed URLs for unpublished content
- [ ] Example frontend consumers (Astro or simple Phoenix page)
- [ ] API documentation (OpenAPI/Swagger via ash_json_api or manual)

### Phase 6: Search & Performance (P1)
- [ ] PostgreSQL full-text search on content (Ash calculations or custom)
- [ ] Optional: Meilisearch integration + indexing jobs (Oban)
- [ ] Caching strategy (Cachex/Nebulex in-BEAM), rate limiting on APIs (Hammer/ETS); native PubSub for admin real-time updates. Introduce Dragonfly **only** if a multi-node shared cache is measured as necessary (D2)
- [ ] Performance profiling (LiveDashboard, Telemetry metrics for editor actions)
- [ ] CDN integration strategy for media

### Phase 7: Polish, i18n, SEO & World-Class Features (P1/P2)
- [ ] Gettext + locale switching for UI and content
- [ ] SEO fields (title, meta description, og:image, canonical, structured data)
- [ ] Auto-generated sitemap.xml and robots.txt
- [ ] Basic analytics (page view tracking via telemetry + simple dashboard)
- [ ] Email notifications (Swoosh + Oban) for workflow events
- [ ] Accessibility audit (admin UI)
- [ ] Theming / white-label potential

### Phase 8: Testing, Security, CI/CD, Docs (P0 for v1)
- [ ] Comprehensive ExUnit tests for resources, policies, actions (Ash provides excellent support)
- [ ] LiveView tests for editor flows
- [ ] E2E with Wallaby or Playwright (critical for editor UX)
- [ ] Security: Sobelow (**done** — wired into precommit/CI, baseline CSP added), dependency audit, policy coverage, rate limiting tests
- [x] GitHub Actions workflow (test on push/PR, dialyzer, credo, sobelow, format + unused-deps check) — `.github/workflows/ci.yml`. **TODO:** explicit migration-drift check
- [ ] Full ExDoc documentation + guides (modeling, editor usage, API consumption, deployment)
- [ ] This project plan kept up-to-date as living doc

### Phase 9: Deployment & Operations (P0)
- [x] Production-ready `Dockerfile` (multi-stage, libvips, healthcheck) + `docker-compose.yml` for local dev and Coolify.
- [ ] Coolify service configuration (env vars, volumes, healthchecks, auto-deploy from Git)
- [ ] Database migrations in release
- [ ] Monitoring setup (Prometheus + Grafana or LiveDashboard + alerts)
- [ ] Backup strategy (Postgres + media)
- [ ] Domain + SSL via Coolify
- [ ] Beta user testing (internal or friendly clinics/agencies)

### Stretch / Post-v1.0
- [ ] AI content generation assistant (block-level prompts via LLM)
- [ ] Real-time collaborative editing research (Yjs + LiveView or simpler presence)
- [ ] Advanced reporting / content analytics
- [ ] Robust **Plugin / Module System**: Plug-and-play custom modules (Elixir behaviours, Ash resource extensions, registry for blocks/components). Support custom block types, resources, LiveView extensions, and API hooks. Future: marketplace / Git-based discovery.
- [ ] Verscienta Health specific modules (TCM content types, patient resources)
- [ ] Mobile admin (LiveView Native)
- [ ] Static site generation export (for high-traffic blogs)

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
- Block data model → embedded JSONB via Ash embedded resources (**D3**).
- Content Type dynamism → compile-time Ash resources, no runtime meta-model (**D4**).
- Collaboration level → locked editing + Presence for v1.0 (**D5**).
- Primary use case → general-purpose core; Verscienta Health as the *first plugin/consumer*, not a coupling.

**Still open**:
- Preview transport: side-by-side LiveView pane vs. signed-iframe — spike both in Phase 3, pick by fidelity/effort.
- Storage abstraction: custom uploader vs. `waffle` — decide in Phase 2.
- Whether multitenancy ships in v1.0 or stays latent (the *model* is decided regardless — D6).

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
3. Bootstrap the Phoenix + Ash project skeleton (`mix phx.new kiln_cms --live`).
4. Set up Docker dev environment (Postgres + native PubSub; Dragonfly as an optional profile only — D2).

This plan is designed to be actionable, realistic, and ambitious enough to create something genuinely world-class while staying true to the STAPLE philosophy of high productivity and joy in development.

Let's build something exceptional. Ready when you are. 🚀

---

*Document created: June 2026 | Living document — update as we progress.*