# Content Editor Modernization — Scope

> **Track:** UX overhaul of `KilnCMSWeb.ContentEditorLive` (the primary content
> authoring surface). Sibling to, but distinct from, the reliability audit
> (`docs/audit-content-editor.md`, all 5 themes shipped). Reliability made the
> editor *trustworthy*; this track makes it feel *current*.
>
> **Ambition:** UX overhaul — rework the interaction model to a Storyblok/
> Contentful-class experience **on the existing Ash + LiveView backend**. No
> client-side editor rewrite; no new persistence model. We polish, re-compose, and
> promote capabilities we already have.
>
> **North star:** Storyblok (visual side-by-side editing, nestable blocks,
> real-time preview) + Contentful (clean field-based entry editor, a persistent
> inspector sidebar, structured Rich Text with embedded references).

---

## The core finding

The gap is **not** missing features. Kiln already ships the hard parts that define
Storyblok/Contentful:

| Storyblok/Contentful hallmark | Kiln today | Where |
| --- | --- | --- |
| Side-by-side live preview | ✅ Right column renders through the real firing pipeline — "what you preview is exactly what publishes" | `content_editor_live.ex:3144`, `preview_html/1:2082` |
| Visual / click-to-edit-on-page | ✅ In-context bridge exists (`/editor/site/...`) | `in_context_edit_live.ex`, visual-editing bridge (#355/#388/#390) |
| Component/block schema | ✅ Auto-discovering block registry with icons + descriptions | `blocks.ex:67`, `block_types/0:2122` |
| Structured Rich Text | ✅ Portable Text + TipTap interchange | `portable_text.ex`, `rich_text.js` |
| Real-time collaboration | ✅ Presence + soft locks in prod; Yjs CRDT co-editing in dev | `presence.ex`, `collab.ex`, `crdt.ex:28` |
| Command palette | ✅ ⌘K launcher | `layouts.ex:213` |

What makes it **feel dated** is that these live in a surface whose *interaction model
and information architecture* predate them:

1. **The primary editor is a plain two-column form** with metadata buried in a stack
   of collapsed `<details>` accordions (SEO, scheduling, custom fields, relationships,
   translations, version history) — `content_editor_live.ex:2699`. Contentful's entry
   editor puts these in a clean, always-visible **right inspector**.
2. **Visual editing is a secondary "Edit on page" link**, not the primary mode —
   `:2676`. Storyblok's whole identity is that visual editing *is* the editor.
3. **Block insertion only appends** — no inline "+" between blocks, no drag-to-insert
   (`add_block:585`). Two separate `/` systems the UI has to verbally disambiguate
   (`:2829`).
4. **Positional addressing + nameless socket-committed inputs** for GEO rows and
   column children (`:2290`, `:2471`) — a parallel, non-form-bound editing path.
5. **Edit UI and preview are two code paths** — hand-written per-type edit forms vs.
   the firing renderer — so the authoring surface never resembles the output.
6. **Modal-heavy media** — one overloaded full-screen picker (`image_picker:1925`).
7. **Mid-migration prose** — saving still leans on `legacy_html` mirroring; Portable
   Text conversion is lossy for lists and embedded objects (`portable_text.ex` moduledoc).

---

## Themes

Each theme is PR-sized and independently shippable, ordered so early themes de-risk
later ones. Effort is rough (S/M/L); risk flags where we touch the block-state model.

### Theme A — Entry editor information architecture *(Contentful-class)* · **M · low risk**

> **Status: IN PROGRESS.** Sticky action bar + tabbed right inspector landed.
> The loose header is now a slim breadcrumb (back link + live title `<h1>`) above a
> `sticky top-14` action bar carrying the state pill, schedule chips, presence
> roster, autosave status, workflow buttons, and Save — always reachable. The old
> stack of collapsed `<details>` (Organization, Custom fields, SEO & scheduling,
> Translations, Version history) moved into a persistent right rail with a
> **Preview / Settings / History** tab strip; the preview is now the default tab.
> **Key invariant:** panels are toggled by CSS `hidden`, never `:if`, so Settings
> fields stay mounted and survive submit even when their tab isn't active; a red
> dot on the Settings tab surfaces validation errors hiding in an inactive panel.
> `switch_inspector_tab` is guarded + no-ops on garbled input. Remaining for A:
> full "side-by-side" preview toggle, empty states, and design-token calibration.

Re-compose the screen from "two-column form + accordion pile" into three coherent
regions:
- **Content column** — title, slug, and the block canvas, with generous rhythm.
- **Right inspector** (persistent, tabbed — *not* collapsed accordions): Status &
  publish, Schedule, SEO, Custom fields, Organization/relationships, Translations,
  Version history. Sticky, scannable, always one click away.
- **Preview** — retained; togglable between inspector and full side-by-side.
- **Sticky action bar** — save/publish/workflow state, autosave indicator, presence
  roster. Replaces the loose header flex row (`:2622`).

Purely a re-layout + component extraction. No state-model changes. Highest
perceived-modernity-per-effort. Do this first — it's the frame everything else sits in.

### Theme B — Block canvas & insertion *(Storyblok/Notion-class)* · **L · medium risk**
- **Inline "+" insertion points** between every block and at the ends, so authors add
  where the cursor is, not only at the tail.
- **Unify the two `/` menus** — one slash affordance: `/` in an empty block position
  offers block types; `/` inside prose offers formatting (the existing in-prose menu
  becomes the "inside a rich_text block" case of one system).
- **Hover block toolbar** — move / duplicate / settings / delete on hover, replacing
  the always-visible chrome cluster (`:2746`); block **settings in a popover** instead
  of inline field sprawl.
- **Stable-id addressing throughout** — finishes the reliability track's T5.1/T5.2
  residual: blocks, GEO rows, and column children all addressed by id, not position.
  (Reliability guarded the crashes; this removes the wrong-target class entirely.)
- **Drag between containers** — top-level list ↔ columns.

This is the theme that touches the block-state model, so it depends on Theme A landing
first and carries the most test surface. The reliability work (revalidate/inject
discipline, prune-on-remove) is the foundation that makes it safe.

### Theme C — Visual editing as a first-class mode *(Storyblok Visual Editor)* · **M · medium risk**
Promote the existing in-context bridge from a secondary link to a **primary toggle** in
the editor: a "Visual" view where clicking an element in the live preview selects and
edits it in place, form and preview staying in sync. The plumbing exists
(`in_context_edit_live.ex`, the `/bridge.js` push channel, `FocusBlock`/`FocusField`
deep-link hooks); this is about making it the default center of gravity rather than a
detour, and reconciling the two editing entry points into one coherent mode switch.

### Theme D — Field & media polish · **M · low risk**
- Replace nameless/socket-committed nested inputs (column children `:2471`, GEO rows
  `:2288`) with a **coherent bound field-component system** — consistent labels, help
  text, required markers, inline validation (Contentful field chrome).
- Replace the overloaded full-screen media modal with an **inline media picker / side
  drawer** that doesn't blank the editor; keep featured/insert/replace as clear modes.
- Empty states, loading skeletons, and motion/transitions across the surface.

### Theme E — Prose model completion · **M · medium risk**
Finish the Portable Text migration so Rich Text reaches Contentful parity:
- Make PT `body` canonical; retire `legacy_html` mirroring as the save path.
- Cover the lossy cases — ordered/bullet lists and **embedded typed objects**
  (images, references, callouts) inside prose.
- Embedded-reference chips in Rich Text (link to other entries/assets).

### Theme F — Real-time collaboration to production · **L · high risk**
Graduate the Yjs CRDT co-editing prototype (`:collab_prototype`, dev-only today) to
prod behind an ops-controlled flag. This is the enterprise-polish differentiator and
also **closes the reliability audit's documented T3.1/T3.2 residuals** (single-saver
election, two-tab self-conflict) — the reliability doc explicitly names "graduate the
collab prototype" as the real fix. Highest risk (correctness of a CRDT in prod), so it
ships last and independently; presence + soft locks + conflict banner remain the floor
until it's proven.

### Cross-cutting — Design system refresh · **S, threaded through A–D**
Not a separate phase; folded into each theme. Tighten the OKLCH token scale, spacing
and typography rhythm, focus/hover motion, and keyboard-first affordances in
`app.css` + the console shell. The design language already exists (Tailwind v4 +
DaisyUI-compatible shim, warm-orange "kiln" brand); this is calibration, not a rebrand.

---

## Sequencing & rationale

```
A (IA frame) ─┬─▶ B (block canvas) ─┬─▶ C (visual mode)
              └─▶ D (fields/media) ──┘
                                      E (prose)  — parallelizable after A
                                      F (collab to prod) — last, independent
```

1. **A first** — it's the frame; low risk; biggest immediate "this feels modern" win.
2. **B and D** build on A's layout; B is the heavy one (state model) so it wants A's
   stability and the reliability foundation under it.
3. **C** needs B's stable-id addressing to reconcile the two editing entry points.
4. **E** (prose) can run in parallel after A — it's mostly isolated to the rich_text path.
5. **F** (collab) ships last, independently, gated — highest risk, and it doubles as the
   reliability T3.1/T3.2 close-out.

## Non-goals (explicit)
- **No client-side editor rewrite.** We keep LiveView-driven server rendering; TipTap
  stays the prose interchange layer only.
- **No new persistence/schema model.** Blocks remain the Ash typed-union storage.
- **Not a rebrand.** The kiln design language stays; we calibrate it.
- **Form builder is out of scope** — that surface was just modernized (WPForms-style,
  PR #447) and is separate from content authoring.

## What each theme buys
- **A** — the surface *reads* as a modern CMS entry editor (biggest perception delta).
- **B** — authoring *feels* like Notion/Storyblok (insertion, drag, hover, one slash).
- **C** — Storyblok's signature: visual editing as the default.
- **D** — the thousand small cuts (nameless inputs, overloaded modal) stop showing.
- **E** — Rich Text reaches Contentful parity; ends the mid-migration awkwardness.
- **F** — true multiplayer; retires the last reliability residual.
