# Kiln vs. Other CMSs — Competitive Comparison

How Kiln positions against the platforms teams evaluate it alongside. Grounded
in Kiln's actual feature surface (Elixir/Phoenix/Ash, headless + self-hosted,
read-only headless APIs by design, firing-engine delivery). Companion docs:
[competitive-gaps-todo.md](competitive-gaps-todo.md) (what we lack) and
[differentiator-opportunities.md](differentiator-opportunities.md) (what only we
can do).

## The field at a glance

| CMS | Stack | Model | Headless writes | Hosting | Closest to Kiln on… |
|---|---|---|---|---|---|
| **Kiln** | Elixir/Phoenix/Ash | headless **+** own site | **read-only (by design)** | self-hosted | — |
| Strapi | Node/JS | admin-UI modeling | read + write | self + Cloud | plugin story |
| Payload | TypeScript | code-first config | read + write | self + hosted | code-first types |
| Craft | PHP/Yii | UI modeling, polished CP | read (write via CP) | self + Cloud | editorial workflow |
| Directus | Node, wraps SQL | DB-first | read + write | self + Cloud | granular perms, Flows |
| **Sanity** | JS + hosted "Content Lake" | structured content | read + write (GROQ) | SaaS | **collab + structured content** |
| **Ghost** | Node | publishing-focused | read + write | self + Pro | **built-in email / newsletters** |

## The original four (summary)

Full write-up lives in the gaps doc; in brief:

- **Strapi / Payload / Directus** — the open-source headless cohort. All three
  expose **write** APIs, have runtime-installable extensions, offer managed
  cloud, and (Directus especially) ship far more granular RBAC. Kiln beats them
  on BEAM concurrency/real-time, security posture, built-in semantic search,
  and batteries-included infra (MTA, MCP authoring).
- **Craft** — the polished editorial/agency incumbent: multi-site, excellent
  Live Preview, commercial plugin store. Kiln lacks the visual polish and
  multi-site; wins on stack and headless breadth.

## Sanity — the structured-content & collaboration rival

**What it is:** Hosted "Content Lake" with a customizable React admin (Studio),
the GROQ query language, Portable Text (structured rich text), and real-time
collaborative editing as a first-class, GA feature.

**Why it's the most important benchmark for Kiln:** Sanity bets on exactly what
Kiln bets on — *structured* content, *real-time collaboration*, and treating
content as queryable data. It is the bar for the things Kiln currently treats as
prototypes.

**Where Kiln wins:**
- Self-hosted and Postgres-owned — no proprietary Content Lake lock-in, no
  per-API-request SaaS billing.
- Serves its own site (LiveView); Sanity is headless-only.
- Built-in semantic/hybrid search, MTA, and MCP authoring; Sanity leans on
  external services.
- BEAM real-time needs no third-party infra.

**Where Sanity wins (study these):**
- **Collaborative editing is GA and excellent** — Kiln's CRDT collab is a
  documented spike. Sanity is the target quality bar.
- **Portable Text** — a portable, richly-structured rich-text standard vs.
  Kiln's TipTap JSON. Worth studying for interoperability.
- **GROQ** — a genuinely ergonomic content query language. Kiln's read APIs
  (JSON:API/GraphQL) are more rigid.
- **Live Content API** — subscribe-and-get-updates delivery. Kiln is
  *architecturally better positioned* for this (BEAM) but hasn't productized it.
- Mature Studio customization + a real ecosystem.

## Ghost — the publishing / newsletter model

**What it is:** An opinionated publishing platform: posts + newsletters + paid
memberships/subscriptions, with native outbound email at its core.

**Why it matters to Kiln specifically:** Kiln already ships a **DKIM-signing,
direct-to-MX MTA** — something no headless CMS has. That makes Kiln
*architecturally one product decision away* from doing what Ghost does. Ghost is
less a competitor than a **blueprint for a capability Kiln can uniquely unlock**
(see differentiator #1).

**Where Kiln wins:**
- Structured content, multiple content types, headless APIs, semantic search —
  Ghost is deliberately narrow (blog/newsletter).
- Ash policies, audiences, versioning, firing-engine delivery — all far beyond
  Ghost's scope.

**Where Ghost wins (today):**
- **Newsletters + paid memberships as a finished product** — subscriber
  management, segmentation, billing, member-gated content. Kiln has the *plumbing*
  (MTA + audiences) but not the *product*.
- Turnkey, focused authoring UX for publishers.

## Also worth a look (context, not head-to-head)

- **Contentful** — SaaS headless leader; study its **content environments /
  aliases** (branch-and-merge staging for content), a table-stakes enterprise
  feature none of the above ship, and one that maps interestingly onto Kiln's
  artifact model.
- **Storyblok** — the visual-editing benchmark; its "bloks" model inspired
  Kiln's block tree. Reference for gap #335 (visual editing).
- **Drupal** — the structured-content + taxonomy + JSON:API-in-core incumbent;
  Kiln's closest philosophical relative in the traditional world.
- **WordPress** — unavoidable (40%+ of the web); benchmark for the block editor
  (Gutenberg) and the headless-WP trend.
- **TinaCMS / Keystatic** — a different editing axis: git-backed visual editing.
- **Beacon** — the direct Elixir-native peer; worth a note on why Kiln diverges
  (AGENTS.md declines to pull it in).
- **Adobe AEM / Sitecore / Optimizely** — the enterprise DXP ceiling
  (personalization, experimentation, DAM) — where the market's high end sits.

## The core differentiator: the typed, declarative firing model

Lead with this — it is the umbrella that makes every other differentiator cheap.

Kiln has **one declarative content definition** (the `use KilnCMS.CMS.Content`
macro over the Ash/Spark DSL) from which it derives, automatically:

- the database schema and typed content model,
- the editor UI,
- renderers for every surface (web HTML, email, JSON-LD, JSON, GraphQL),
- search projections (full-text + embeddings), and
- **pre-computed immutable "fired" artifacts per surface**, with a reference
  graph that re-fires dependents precisely when referenced content changes.

Most CMSs are either fully dynamic (render live from a mutable store on every
request) or require manual wiring of each output surface. Kiln's model gives
leverage *and* correctness: structured data "just works," reads hit immutable
artifacts (fast + resilient), and content evolves safely.

**Why it matters competitively:** nearly every differentiator below falls out of
this one model — signed provenance (#340) and tamper-evident history (#356)
because artifacts are immutable; point-in-time delivery (#338) because history +
artifacts are addressable; DB-outage resilience (#341) because delivery reads
artifacts not the live tree; multi-surface GEO output (#357) because firing is
already multi-surface. Competitors would have to re-architect delivery to match
any one of these; Kiln gets them as extensions of its core.

## Structural advantages (why the differentiators are cheap for Kiln)

These are not features to build — they are inherent properties of the stack, and
they are *the reason* the differentiators in
[differentiator-opportunities.md](differentiator-opportunities.md) are near-free
for Kiln but expensive for others.

- **Compile-time safety + declarative power via Ash** — content types, policies,
  and APIs are declared and checked at compile time, vs. the more dynamic,
  runtime schemas common elsewhere. Fewer whole classes of runtime error.
- **Minimal external dependencies / true low-ops self-hosting** — Postgres-centric
  by design; cache, search, and object storage are optional add-ons, not
  required infra. One database to run, not a fleet.
- **Hybrid delivery in one app** — serves a traditional site (LiveView) *and*
  headless APIs from the same deployment; no separate frontend to build/deploy.
- **BEAM concurrency + fault tolerance** — native real-time (PubSub, presence,
  subscriptions) with no external broker, and supervision that isolates failures
  — the foundation under the reliability and collaboration differentiators.

## Positioning summary

Kiln is an **opinionated, security-first, self-hosted platform** for teams that
value the BEAM's operational model and batteries-included infra (search, mail,
real-time, AI authoring) in one deployment that is *both* the site and the API.
It trades away write-APIs, a marketplace, managed hosting, and granular RBAC to
get there. Its most defensible ground is **structured content + real-time
(vs. Sanity)** and **content + native email (vs. everyone)**.
