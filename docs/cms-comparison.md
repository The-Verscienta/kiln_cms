# Kiln vs. Other CMSs — Competitive Comparison

How Kiln positions against the platforms teams evaluate it alongside. Grounded
in Kiln's actual feature surface (Elixir/Phoenix/Ash, headless + self-hosted,
read **and write** headless APIs, firing-engine delivery). Companion docs:
[competitive-gaps-todo.md](competitive-gaps-todo.md) (what we lack) and
[differentiator-opportunities.md](differentiator-opportunities.md) (what only we
can do).

*Last reconciled against `main`: 2026-09-11.* Claims about Kiln below are
checked against the code; claims about the other products are a summary, not a
benchmark.
The [wedge table](#the-wedge-right-everywhere-provably) is the exception:
it was added on 2026-11-03 with a dated source on every competitor claim.

> **The public, sourced versions live in [docs/compare/](compare/how-kiln-compares.md)**
> (#1876): one "Kiln vs X" page each for WordPress, Ghost, Strapi, Payload and
> Directus, plus migration guides. Those pages date and link every claim about
> another product, and have a named review owner. This note stays the internal
> positioning memo. Where the two disagree on a fact about a competitor, the
> public page is the checked one. One example: Directus moved from BSL 1.1 to
> the source-available MSCL-1.0-GPL in v12, in June 2026
> ([Kiln vs Directus](compare/kiln-vs-directus.md)).

## The field at a glance

| CMS | Stack | Model | Headless writes | Hosting | Closest to Kiln on… |
|---|---|---|---|---|---|
| **Kiln** | Elixir/Phoenix/Ash | headless **+** own site | read + write (JSON:API, GraphQL, MCP; API-key scoped) | self-hosted | — |
| Strapi | Node/JS | admin-UI modeling | read + write | self + Cloud | plugin story |
| Payload | TypeScript | code-first config | read + write | self + hosted | code-first types |
| Craft | PHP/Yii | UI modeling, polished CP | read (write via CP) | self + Cloud | editorial workflow |
| Directus | Node, wraps SQL | DB-first | read + write | self + Cloud | granular perms, Flows |
| **Sanity** | JS + hosted "Content Lake" | structured content | read + write (GROQ) | SaaS | **collab + structured content** |
| **Ghost** | Node | publishing-focused | read + write | self + Pro | **built-in email / newsletters** |

Kiln's headless APIs were read-only by design (decision D7) until #330 reversed
that: create / update / workflow verbs (`publish`, `unpublish`, …) and
soft-delete are exposed over [JSON:API](json-api.md) and
[GraphQL mutations](headless-graphql-api.md#mutations-writing), gated by the same
Ash policies as the editor plus the API key's scope.

## The wedge: right, everywhere, provably

Kiln's position from 1.8 is **content that has to be right: everywhere in
seconds, provably** ([right-everywhere-provably.md](right-everywhere-provably.md)).
This table compares the four rivals a team weighing that claim is most likely
to have open, on the four things the claim rests on.

**Facts checked 2026-11-03**, each against the vendor's own docs or pricing
page, linked in the cell. "Not documented" means we found nothing in the
vendor's docs that day. It is not a claim that the feature cannot be built on
top. Contentful's site rate-limited direct reads that day, so its cells rest
on the excerpts of its pages that a search returned; re-read them at the next
check.

| | Live delivery: is every consumer told? | Point in time: what readers saw | Provenance: signed content | Governance: who changed and approved it |
|---|---|---|---|---|
| **Kiln (1.7)** | Signed webhooks on every publish, edit and withdrawal, naming the other pages a change touched; retractions exempt from auto-disable; optional CDN purge; every transition timed (first p95 0.58 s, unpublish to last endpoint). Public change-feed transports are not shipped (2.2) ([webhooks](webhooks.md), [benchmarks](benchmarks.md#live-delivery-unpublish-to-last-endpoint)) | `?as_of=` on the public delivery API serves a document as published at that moment, or `withdrawn` ([point in time](point-in-time.md)) | On by default: every fired page carries a signed manifest; anonymous `verify` endpoint and public key ([provenance](provenance.md)) | Per-document trail with approver, CDN purge, endpoint delivery times, `?as_of=` link and a tamper-evident history chain, in the free product ([governance dashboard](governance-dashboard.md)) |
| **Sanity** | Live Content API: clients listen for sync tags and refetch on change; all plans; 15-minute event replay on Free and Growth ([Live Content API][sanity-live]). GROQ-powered webhooks signed with `X-Sanity-Signature` ([webhooks][sanity-webhooks]) | History API returns a document "as it was at a point in the past" (`time` parameter), authenticated only ([History API][sanity-history]). History kept 3 days (Free), 90 (Growth), 365 (Enterprise) ([history][sanity-history-ux]); the History API is Enterprise-only on the pricing page ([pricing][sanity-pricing]) | Not documented | "Full audit trail & History API", "Audit log: content changes and events" and Content Releases are Enterprise only ([pricing][sanity-pricing]). Approval workflows are in early access ([Workflows cookbook][sanity-workflows]) |
| **Contentful** | Webhooks with optional request signing (`x-contentful-signature`) ([request verification][contentful-verify]). Publishing purges the CDN, with fresh content "within seconds" ([webhooks FAQ][contentful-webhooks-faq]). No push to open pages for published content is documented | Entry snapshots on each publish, master environment only, over the Management API (`/entries/:id/snapshots`), not the Delivery API ([versions][contentful-versions], [snapshots][contentful-snapshots]) | Not documented | Audit logs of content, model, role and environment changes, streamed to your cloud storage, Enterprise ([enterprise observability][contentful-audit]) |
| **Payload (3.x)** | No webhooks built in: you write an `afterChange` hook to purge caches or call a front end ([collection hooks][payload-hooks]). Live Preview is for drafts ([live preview][payload-preview]) | Versions over REST, GraphQL and the Local API, 100 per document by default (`maxPerDoc`); no as-of-date read documented ([versions][payload-versions]) | Not documented | Enterprise lists "Audit Logs & Version Control" and approval workflows ([enterprise][payload-enterprise]) |
| **Directus** | Realtime over WebSockets and GraphQL subscriptions, under the caller's permissions; off by default when self-hosted (`WEBSOCKETS_ENABLED=false`) ([realtime config][directus-realtime]). Flows can POST to a URL on an event ([triggers][directus-triggers]) | Revisions over `/revisions`, revert via `/utils/revert` ([revisions][directus-revisions]); with retention on, revisions and activity default to 90 days ([logging][directus-logging]). No as-of-date read documented | Not documented | Activity log and revisions record each change ([revisions][directus-revisions], [logging][directus-logging]). No approval workflow found in the docs we read |

What the table says about positioning: every rival has fast change
notification, and Sanity's Live Content API is the most finished push to
clients, ahead of Kiln until 2.2 ships the public feed. None documents signed
content, a public "as it was at this moment" read, or a per-document record
of when each consumer was told. Where they keep an audit trail, it is an
Enterprise tier; Kiln's is in the self-hosted product.

[sanity-live]: https://www.sanity.io/docs/content-lake/live-content-api
[sanity-webhooks]: https://www.sanity.io/docs/compute-and-ai/webhooks
[sanity-history]: https://www.sanity.io/docs/http-reference/history
[sanity-history-ux]: https://www.sanity.io/docs/user-guides/history-experience
[sanity-pricing]: https://www.sanity.io/pricing
[sanity-workflows]: https://www.sanity.io/docs/workflows/cookbook-coordinated-release
[contentful-verify]: https://www.contentful.com/developers/docs/webhooks/request-verification/
[contentful-webhooks-faq]: https://www.contentful.com/help/faq/webhooks/
[contentful-versions]: https://www.contentful.com/help/content-and-entries/versions/
[contentful-snapshots]: https://www.contentful.com/developers/docs/references/content-management-api/snapshots/
[contentful-audit]: https://www.contentful.com/developers/docs/concepts/enterprise-observability/
[payload-hooks]: https://payloadcms.com/docs/hooks/collections
[payload-preview]: https://payloadcms.com/docs/live-preview/overview
[payload-versions]: https://payloadcms.com/docs/versions/overview
[payload-enterprise]: https://payloadcms.com/enterprise
[directus-realtime]: https://directus.com/docs/configuration/realtime
[directus-triggers]: https://directus.com/docs/guides/flows/triggers
[directus-revisions]: https://directus.com/docs/api/revisions
[directus-logging]: https://directus.com/docs/configuration/logging

## The original four (summary)

Full write-up lives in the gaps doc; in brief:

- **Strapi / Payload / Directus** — the open-source headless cohort. All three
  have runtime-installable extensions and offer managed cloud, which Kiln does
  not. Write APIs and granular RBAC are no longer differentiators against them:
  Kiln ships both (#330; [granular-rbac.md](granular-rbac.md) — per-type read
  and write scopes, per-field grants, custom roles). Directus's permission
  model is still broader (arbitrary filter rules per collection). Kiln beats
  them on BEAM concurrency/real-time, security posture, built-in semantic
  search, and batteries-included infra (MTA, MCP authoring).
- **Craft** — the polished editorial/agency incumbent: excellent Live Preview,
  commercial plugin store. Kiln now has multi-site too
  ([multi-tenancy.md](multi-tenancy.md) — one deployment, one org per host),
  but still lacks Craft's visual polish; it wins on stack and headless breadth.

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
- **Portable Text is shared ground, not a gap.** Kiln stores rich prose as
  Portable Text (decision D12, `KilnCMS.Blocks.PortableText`); TipTap is only
  the editor's interchange format. Embedded typed objects inside prose are not
  converted yet.

**Where Sanity wins (study these):**
- **Collaborative editing is GA and excellent.** Kiln's CRDT co-editing
  (`y_ex`, `KilnCMS.Collab.Crdt`) is built and tested but **disabled in
  production** — the `:collab_prototype` flag is on only in dev and test, so a
  production editor gets presence, soft field locks and a conflict banner, not
  simultaneous typing. Whether to finish and enable it is
  [#1324](https://github.com/The-Verscienta/kiln_cms/issues/1324). Sanity is
  the target quality bar.
- **GROQ** — a genuinely ergonomic content query language. Kiln's read APIs
  (JSON:API/GraphQL) are more rigid.
- **Live Content API** — subscribe-and-get-updates delivery as a finished
  product. Kiln has the primitive — every content type exposes a GraphQL
  `<type>Changed` [subscription](headless-graphql-api.md#subscriptions-real-time)
  in production — but not Sanity's client-side live-query layer on top.
- Mature Studio customization + a real ecosystem.

## Ghost — the publishing / newsletter model

**What it is:** An opinionated publishing platform: posts + newsletters + paid
memberships/subscriptions, with native outbound email at its core.

**Why it matters to Kiln specifically:** Kiln already ships a **DKIM-signing,
direct-to-MX MTA** — something no headless CMS has — plus a
[newsletter](newsletter.md) and [paid memberships](memberships.md). Ghost is the
benchmark for how finished that product feels.

**Where Kiln wins:**
- Structured content, multiple content types, headless APIs, semantic search —
  Ghost is deliberately narrow (blog/newsletter).
- Ash policies, audiences, versioning, firing-engine delivery — all far beyond
  Ghost's scope.

**Where Ghost wins (today):**
- **Newsletters + paid memberships as one polished product** — Ghost's
  subscriber management, segmentation and member-gated publishing are its whole
  focus, and years more mature than Kiln's.
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
  Kiln ships cookie-free [content experiments](content-experiments-plan.md) and
  [funnels](advanced-analytics-plan.md), a small slice of that ceiling. Kiln
  does not compete for that ceiling; see
  [Kiln in a composable DXP](#kiln-in-a-composable-dxp).

## The core differentiator: the typed, declarative firing model

Lead with this — it is the umbrella that makes every other differentiator cheap.

Kiln has **one declarative content definition** (the `use KilnCMS.CMS.Content`
macro over the Ash/Spark DSL) from which it derives, automatically:

- the database schema and typed content model,
- the editor UI,
- renderers for every fired surface — web HTML, JSON, JSON-LD and an LLM
  Markdown projection (`KilnCMS.Firing.Surfaces`) — with GraphQL and JSON:API
  derived from the same definition rather than rendered,
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

## Kiln in a composable DXP

*Added 2026-11-12.* A digital experience platform (DXP) joins content with
customer context: profiles, segments, personalization, journeys, marketing
automation, analytics. Kiln does not claim to be one, and the plan is not to
become one by building those layers itself. Identity resolution, journey
orchestration and marketing automation are whole product categories with
their own specialists, and several CMSs that rebranded as suites ended up
bloated. Kiln's comparative advantage is the **content plane**.

**The label.** Use "provable content plane" or "content foundation": *KilnCMS
is the content core a digital experience platform can be built on.* Do not use
"DXP" or "DXP-ready". A buyer who searches for a DXP expects a customer
profile and personalization out of the box, and the comparison then runs on
exactly the features [path-forward.md](path-forward.md#frozen-and-deprecated)
froze.

**What Kiln supplies to the rest of the stack**

| Kiln provides | So the other tools can |
|---|---|
| The [change feed](api.md#change-feed-sse) with `/api/sync` cursors, and signed [webhooks](webhooks.md) that list the affected pages | Re-index, re-segment or re-send when content changes, without polling |
| A guarantee that retractions get through, plus [propagation records](right-everywhere-provably.md) | Trust that a withdrawn offer, claim or notice is withdrawn in every channel |
| [Provenance](provenance.md) manifests and `?as_of=` [point-in-time](point-in-time.md) reads | Show what a customer was sent or shown, and prove it |
| JSON:API, GraphQL and `/api/content` for every type, plus the [draft-write API key scope](decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md) | Read content, and let a personalization or messaging service write drafts back for review |
| The [overlay model](overlay-contract.md) | Ship an integration as project code against a stated contract, not as a fork |

**What Kiln leaves to specialists**: customer profiles and identity
resolution (CDPs), journey orchestration and marketing automation, and
cross-channel attribution. The integration surface is the product here: the
feed, webhooks and APIs above should make wiring Kiln into one of those tools
easy, and documented connectors are where any DXP work starts.

**What Kiln may add later, inside the content plane.** A small audience or
segment API, content variants keyed to it, and a deterministic fallback when no
segment matches. That is enough for useful personalization, and it builds on
the [content experiments](content-experiments-plan.md) and
[referrer analytics](advanced-analytics-plan.md) that already ship (off by
default). The segment comes from the caller or an external CDP, never from
Kiln tracking visitors, so the no-tracking story stays intact. None of this is
scheduled; experiments and analytics are frozen until the 2.0 gate passes.

**Who it suits.** The same readers as the wedge: regulated or high-stakes
content (health, finance, government, legal, safety-critical documentation);
multi-channel or multi-property setups where "we published the correction but
the app still shows the old version" is a real problem; and teams that want
to own their stack with a small operational footprint.

**Naming.** If Kiln ever ships an experience layer, it gets its own product
or suite name ("Kiln Platform", for example), with KilnCMS as its content
core. The kiln metaphor (content fired into a durable, correct, permanent
state) fits a content core and does not stretch to a marketing suite.

The name is already crowded. Kiln's site is **kilncms.dev**; **kilncms.com**
is not Kiln's. As of 2026-11-12 it belongs to an unrelated product, also
called Kiln: a git-based, click-to-edit CMS that publishes static HTML
through the site owner's GitHub repository (AGPL-3.0, with a paid hosted
tier). Always write "KilnCMS" in full on its own, link kilncms.dev, and
check any new suite name against that product first.

## Positioning summary

Kiln is an **opinionated, security-first, self-hosted platform** for teams that
value the BEAM's operational model and batteries-included infra (search, mail,
real-time, AI authoring) in one deployment that is *both* the site and the API.
It trades away a marketplace, managed hosting, and runtime-installable
extensions to get there — and, for now, production co-editing: #1324 resolved
by *labelling* the CRDT prototype as prod-disabled rather than shipping it, and
graduating it is Theme F of
[content-editor-modernization.md](content-editor-modernization.md). Its
most defensible ground is **structured content + real-time (vs. Sanity)** and
**content + native email (vs. everyone)**.

From 1.8 Kiln leads with one of these rather than a list: **content that has
to be right, everywhere in seconds, provably** (see
[the wedge table](#the-wedge-right-everywhere-provably) above and
[path-forward.md](path-forward.md)). The other strengths stay true; they are
no longer the headline.
