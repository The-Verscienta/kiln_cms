# Differentiator Opportunities

Capabilities Kiln is uniquely positioned to ship — each is *near-free because a
component already exists*, and *hard for competitors because of their stack*.
That asymmetry is the point: these are not generic feature requests, they are
moves only Kiln can make cheaply.

Companion docs: [cms-comparison.md](cms-comparison.md),
[competitive-gaps-todo.md](competitive-gaps-todo.md).

Priority reflects value × cheapness-to-build. P1 = strongest / cheapest wins.

---

## 1. Publishing + newsletters + memberships (the "Ghost play") — [#337](https://github.com/The-Verscienta/kiln_cms/issues/337) `P1`

- [ ] Subscriber segments (reuse the `audiences` read-axis)
- [ ] "Send this post as a newsletter to segment X" via the built-in MTA
- [ ] Optional paid-membership gating on content

**The asymmetry:** Kiln already ships a **DKIM-signing, direct-to-MX MTA** — no
other headless CMS has native outbound email. Content → audience → inbox in one
system. This is the single most differentiated product move available.

## 2. Point-in-time / "time-travel" content API — [#338](https://github.com/The-Verscienta/kiln_cms/issues/338) `P1`

- [ ] Expose "content/site as it was on date/version X" over the read API
- [ ] Leverage AshPaperTrail history + immutable fired artifacts

**The asymmetry:** Full version history *and* immutable artifacts + a dependency
graph already exist. For regulated/health content (Verscienta), "what did our
guidance say on this date, provably" is a compliance superpower. Competitors
render live from a mutable DB and can't do this without heavy custom work.

## 3. RAG "ask your content" endpoint + AI content intelligence — [#339](https://github.com/The-Verscienta/kiln_cms/issues/339) `P1`

- [ ] `/api/ask` — RAG over *published* content, policy-scoped (never leaks drafts)
- [ ] Auto "related content", near-duplicate detection, AI auto-tagging
- [ ] Content-gap analysis ("users search for X; you have nothing about it")

**The asymmetry:** Block-level embeddings (pgvector + Bumblebee) and ash_ai are
already in-house. Exposing them is almost free. Most CMSs bolt this on via
Algolia/OpenAI.

## 4. Cryptographically signed / provenance-verified content — [#340](https://github.com/The-Verscienta/kiln_cms/issues/340) `P2`

- [ ] Sign published artifacts (C2PA-style) using existing signing infra
- [ ] Consumer-verifiable "came from us, unaltered, at version N"

**The asymmetry:** Artifact immutability *and* a DKIM signing key already exist.
In the AI-slop era and for medical/regulated content, verifiable provenance is
genuinely novel — no CMS ships it natively.

## 5. "Stays up when the database doesn't" delivery — [#341](https://github.com/The-Verscienta/kiln_cms/issues/341) `P2`

- [ ] Serve valid cached artifacts through a Postgres outage
- [ ] Make it an explicit, tested reliability guarantee

**The asymmetry:** Delivery already reads *immutable cached artifacts*, not the
live tree, and BEAM supervision isolates failures. A reliability story Node/PHP
CMSs structurally cannot match.

## 6. Oban-backed editorial automation (a Directus Flows answer) — [#342](https://github.com/The-Verscienta/kiln_cms/issues/342) `P2`

- [ ] No-code "when X happens, do Y" builder
- [ ] e.g. on `in_review` → notify Slack; on `published` → fire newsletter + re-index

**The asymmetry:** Oban + state machine + webhooks + PubSub + MTA already run in
production. Answers Directus Flows without embedding a new JS automation runtime.

## 7. Multiplayer live preview with presence — [#343](https://github.com/The-Verscienta/kiln_cms/issues/343) `P2`

- [ ] Shared live-preview sessions (editor + stakeholder, same preview)
- [ ] Cursors / presence via Phoenix.Presence

**The asymmetry:** CRDT collab exists; Phoenix.Presence makes shared preview
near-trivial. Even Sanity charges enterprise money for real-time collaboration
features.

## 8. Compliance & governance dashboard — [#352](https://github.com/The-Verscienta/kiln_cms/issues/352) `P1`

- [ ] Editorial audit trail view (who created/edited/approved, when)
- [ ] Side-by-side version diffs per content item
- [ ] Provenance reports (ties into #4 / #340) and point-in-time export (ties into #2 / #338)
- [ ] Exportable trails (CSV/PDF/JSON) for review/regulatory scrutiny

**The asymmetry:** AshPaperTrail history, the `history/` audit trail, and
self-service export already exist — this *packages* them into one governance
surface. Consolidates #2 + #4 + the existing audit trail.

**Framing note:** NOT "HIPAA" — HIPAA governs *protected health information*
(patient data), not *content about* GLP-1/TCM. The real value is editorial /
medical-claim governance (traceable authorship, sourcing, approval), which maps
to FTC health-claim scrutiny and medical-review workflows.

## 9. First-class static / edge export of fired artifacts — [#353](https://github.com/The-Verscienta/kiln_cms/issues/353) `P2`

- [ ] Export immutable `:web`/`:json`/`:json_ld` artifacts to a static host / CDN
- [ ] Support air-gapped / edge-cached deploys from the artifact store
- [ ] Live CMS stays authoritative; static export is an *output surface*, not a fork

**The asymmetry:** The firing engine already produces immutable pre-rendered
artifacts with precise dependency-graph invalidation — that *is* static
generation. Exporting to the edge is the only missing part. Overlaps with #5.

**Not Beacon:** AGENTS.md declines Beacon, and LiveView already server-renders
(SEO handled). This captures only the genuinely-missing kernel of the "hybrid
rendering" idea: static/edge export.

## 10. Front-end (in-context) editing on Kiln's own site — [#354](https://github.com/The-Verscienta/kiln_cms/issues/354) `P1`

Front-end editing is perpetually promised and rarely good because headless CMSs
are *decoupled from the front end* — they must inject an overlay into an app
they don't render and reverse-engineer which DOM element maps to which field
(Sanity stega, Storyblok bridge, Tina component wrapping — all require the front
end to cooperate).

**The asymmetry:** Kiln renders its own front end (LiveView serves the site), so
the decoupling problem largely disappears:
- LiveView holds a stateful socket — `phx-*` hooks send edits straight back →
  Ash write-through → re-render. No iframe bridge, no preview protocol.
- Kiln rendered the block, so it *knows* which field produced each region;
  blocks carry stable IDs. Element→field mapping is free.
- Write-through, policies, and paper-trail versioning are already native.

**Boundary:** editing targets the authenticated live-draft / preview surface
(`mode: :preview`); public delivery stays on immutable fired artifacts.

**The split (was the single "visual editing" gap #335):**
- **#354** — in-context editing on Kiln's own LiveView site (this — uniquely
  feasible, high value).
- **#355** — visual-editing bridge/SDK for *external* headless front ends
  (blocked on #330 write APIs; Kiln can enable but not own it — inherent to
  headless).
- **#335** — drag-and-drop page building (layout composition).

Hard parts (feasible, not free): inline rich text (TipTap in-page), structural
add/reorder/delete, non-content chrome boundaries, concurrency (CRDT helps).

---

**Sequencing take:** #3 and #6 are the cheapest (mostly expose what exists).
#1 and #2 are the biggest strategic differentiators (especially for
health/regulated content). #4 and #5 are the best "put it on the box"
trust/reliability stories.
