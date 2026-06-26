# Spike: Real-time collaborative editing (CRDT research)

**Issue:** #61 ([Stretch] Real-time collaborative editing — CRDT research).
**Status:** research spike / feasibility doc. **No code change proposed for v1.**
**Decision context:** D5 in `KilnCMS_Project_Plan.md` — *"Ship single-active-editor
with Phoenix Presence indicators. CRDT/Yjs collaborative editing fights LiveView's
server-authoritative model and is firmly post-v1 research."* This document is that
research.

## TL;DR

- **Is true multi-user editing feasible on this stack? Yes** — via Yjs CRDTs,
  with the BEAM as a first-class Yjs node (`y_ex`) over a Phoenix Channel, and
  TipTap's official Yjs binding (`@tiptap/extension-collaboration` +
  `y-prosemirror`) on the client. No Node sidecar strictly required.
- **But it's a real subsystem, not a feature** — it changes who owns the editor
  state (client/CRDT, not the LiveView server loop), adds a CRDT⇄Ash persistence
  boundary, and creates a second history alongside AshPaperTrail. That's exactly
  the LiveView tension D5 flagged.
- **Recommendation:** keep **locked single-editor for v1**, but **harden it now**
  with optimistic-concurrency conflict detection (cheap, removes today's silent
  last-write-wins). Pursue full CRDT **post-v1, phased**: first rich-text-within-a-block
  (lower risk), then the block tree.
- **Smallest next step:** a throwaway prototype of one rich-text block synced
  between two browsers via `y_ex` over a Channel — to de-risk `y_ex` maturity and
  the CRDT⇄Ash persistence boundary before committing.

---

## 1. Where we are today

KilnCMS already has the *scaffolding* for collaboration but **no sync protocol or
conflict resolution**.

| Capability | Status | Where |
|---|---|---|
| "Who's editing" presence | ✅ | `KilnCMSWeb.Presence` (`editing:{kind}:{id}`) |
| Remote cursor / field-focus badges | ✅ (coarse, field-level) | `ContentEditorLive` `broadcast_cursor/2` |
| Live preview (editor → preview window) | ✅ one-way | `content_preview:{kind}:{id}` PubSub |
| Advisory field locks | ⚠️ advisory only | lowest-user-id "owns" a field; inputs go readonly **but still submit** |
| Debounced autosave (drafts) | ✅ | 2 s debounce → `AshPhoenix.Form.submit` |
| Version history | ✅ | AshPaperTrail, full `blocks` snapshot per save |
| **Concurrency control** | ❌ **none** | whole-document `:update`, **last-write-wins**, no version check |
| **Edit merging** | ❌ **none** | the entire `blocks` array is replaced on save |

**The crux for CRDT feasibility is the save/sync mechanism:**

- Rich text lives in a TipTap editor (`@tiptap/core@^2.11`, StarterKit) whose
  `onUpdate` mirrors `editor.getHTML()` into a hidden input, debounced 300 ms,
  which triggers `phx-change="validate"`. **TipTap state never leaves the
  browser** except as final HTML.
- A document is `attribute :blocks, {:array, KilnCMS.CMS.Block}` — an **embedded
  JSON tree** (D3): each `Block` has `type`, `content` (TipTap HTML or string),
  `data`, `order`, `children`. Saved **wholesale** on each `:update`.
- Two editors on the same draft both submit full form state; the second save
  silently overwrites the first. Field locks are UI hints, not enforcement.

So today's model is **co-presence without co-editing**.

## 2. Why this is genuinely hard here

Two independent conflict layers, plus a framework-fit problem:

1. **Block-tree structure** — insert/delete/reorder/nest blocks. Needs a
   list/array CRDT (Yjs `Y.Array`) or OT on the tree.
2. **Rich text inside a block** — concurrent character edits within one
   `rich_text` block. Needs a sequence CRDT for ProseMirror (`Y.XmlFragment` via
   `y-prosemirror`).
3. **LiveView is server-authoritative** (D5's point). LiveView's model is
   "client sends events → server computes new DOM → diff down." Collaborative
   text editing wants the **client** to own the editor buffer and exchange ops
   peer-ish/asynchronously. You don't run a CRDT *through* the LiveView render
   loop; you carve the editor out (a `phx-update="ignore"` island) and let
   LiveView orchestrate the *session and persistence*, not the keystrokes.

A naive "broadcast each block's HTML over PubSub and last-write-wins" is **not**
collaboration — it loses data the moment two carets are in the same block.

## 3. Approaches evaluated

### A. Harden locking (single active editor) — *not collab*
Make the advisory lock a real soft-lock: first editor gets write access, others
are read-only with a "request control / take over" affordance. Cheap, honest, no
data loss.
- **Effort:** S. **Risk:** low. **Delivers:** safety, not concurrency.

### B. Optimistic concurrency (conflict *detection*) — *recommended now*
Add a monotonic `lock_version` (or compare `updated_at`) to the content `:update`.
If the record changed since the editor loaded it, reject the save with a
"someone else edited this — reload/merge" prompt instead of silently clobbering.
- **Effort:** S–M. **Risk:** low. **Delivers:** eliminates silent last-write-wins
  (the worst current behavior) without any CRDT. **Good v1 hardening regardless
  of the collab decision.**

### C. Operational Transforms (OT) — *not recommended*
Server transforms concurrent ops against each other (Google-Docs-classic). Correct
OT is notoriously hard to implement and test; the ecosystem has largely moved to
CRDTs. No mature Elixir OT stack. Skip.

### D. CRDT (Yjs) — *the real collaborative path*
Yjs is the de-facto standard; TipTap ships first-class support. Two scoping
sub-variants:

- **D1 — rich text only.** Each `rich_text` block becomes a Yjs-backed TipTap
  instance (`@tiptap/extension-collaboration` + `CollaborationCaret`). The block
  *tree* (add/remove/reorder) stays in LiveView with hardened locking (A/B).
  → Solves the most common real conflict (two people in the same paragraph) with
  the smallest blast radius.
- **D2 — whole document.** Model the entire document in one Yjs doc: a `Y.Array`
  of blocks, each rich block holding a `Y.XmlFragment`. Full Notion/Storyblok-style
  concurrent structural + text editing.
  → Maximum capability, maximum complexity (tree CRDT semantics, nested blocks,
  schema mapping).

**Transport & authority for Yjs (independent of D1/D2):**

| Option | What it is | Fit for KilnCMS |
|---|---|---|
| **`y_ex` on the BEAM** | Elixir Rustler NIF over the Rust `y-crdt`. The BEAM holds the authoritative `Y.Doc`, relays updates over a **Phoenix Channel**, and persists. | **Best fit** — no extra service (D2 minimal-ops), reuses Ash policies at channel join, BEAM clustering scales without Redis. **Risk: `y_ex` is young** ("in development; some APIs unimplemented"). |
| **Hocuspocus (Node sidecar)** | Official TipTap Yjs backend (`@hocuspocus/server`). | Proven and turnkey, but adds a **Node service + its own auth/persistence** — cuts against the Postgres-centric, minimal-ops stance (D2). Good fallback if `y_ex` proves immature. |
| Pure client P2P (WebRTC) | No server authority | Rejected — auth, persistence, and NAT issues; not suitable for a CMS. |

## 4. Recommended architecture (when pursued, post-v1)

Phased **D1 → D2**, with **`y_ex` on the BEAM**:

```mermaid
flowchart LR
  subgraph Browser A
    TA[TipTap + Collaboration\n y-prosemirror] --- YA[Y.Doc]
  end
  subgraph Browser B
    TB[TipTap + Collaboration] --- YB[Y.Doc]
  end
  YA <-- "Yjs updates + awareness\n(binary)" --> CH
  YB <-- "Yjs updates + awareness" --> CH
  subgraph BEAM
    CH[Phoenix Channel\n collab:doc:{id}] --> YDOC[(y_ex authoritative Y.Doc)]
    YDOC -- "debounced checkpoint" --> MAT[Materialize → Ash blocks HTML]
    MAT --> ASH[(Ash :update → AshPaperTrail version)]
    PRES[Awareness ↔ Presence cursors]
  end
```

Key design commitments:

- **Editor island.** The collaborative editor lives in a `phx-update="ignore"`
  region; LiveView owns mount/teardown, the version sidebar, workflow buttons,
  and the **persistence boundary** — not keystrokes.
- **Ash + AshPaperTrail stay the source of truth for durable history.** The Yjs
  doc is the *live session state*. On a **debounced checkpoint** (idle N seconds,
  or explicit "Save"/blur), the server materializes the Yjs doc → block HTML →
  one `:update` → one PaperTrail version. **Do not version per keystroke** (would
  swamp PaperTrail and the existing 2 s autosave path).
- **Awareness replaces the cursor hack.** The Yjs Awareness protocol carries
  cursors/selections/names/colors; fold our existing Presence "who's editing"
  into it (or keep Presence for the roster, Awareness for carets).
- **Authz at the seam.** Reuse Ash policies when a client joins `collab:doc:{id}`
  (must be an editor with access; published-vs-draft rules still apply).
- **Block model mapping.** `Block` (D3 embedded JSON) ⇄ `Y.Array` entries;
  `rich_text` HTML ⇄ `Y.XmlFragment` through the ProseMirror schema. Round-trip
  fidelity of HTML↔ProseMirror is a known sharp edge to validate.

## 5. Tradeoffs, risks, open questions

- **Framework tension (D5).** This permanently changes the editor from
  "LiveView renders everything" to "LiveView orchestrates a client-owned CRDT
  island." Acceptable and well-trodden, but it *is* a philosophical shift for the
  editor surface.
- **Two histories.** Yjs has its own update log; AshPaperTrail has durable
  checkpoints. Define the contract: Yjs = ephemeral live session, PaperTrail =
  named restorable versions. Decide GC of Yjs update history and whether a Yjs
  snapshot is persisted between sessions (for offline/reconnect) or rebuilt from
  the last Ash version on each session.
- **`y_ex` maturity is the #1 technical risk.** It's promising (BEAM-native, no
  Redis) but young. Mitigation: prototype early (§7); fallback is Hocuspocus.
- **Persistence boundary correctness.** Materializing CRDT → HTML → blocks must
  be deterministic and not fight autosave. Likely need to *replace* the current
  per-block autosave with a single session-level checkpoint while collab is active.
- **Schema/round-trip fidelity.** TipTap StarterKit ↔ block `data`/`children`
  (images, embeds, columns, nesting) need a clean ProseMirror schema; custom block
  types complicate the Yjs document shape (D2 especially).
- **Undo/redo** becomes per-user (Yjs `UndoManager`), not global — a UX change.
- **Offline/merge** is a Yjs strength but expands scope (PWA, local persistence).
  Out of scope for first cut.
- **Testing.** Concurrent-edit correctness is hard to unit-test; needs
  multi-client integration harnesses. Budget for it.
- **Scaling.** Single authoritative `Y.Doc` per document lives in one process;
  fine for realistic editor concurrency (handful per doc). BEAM clustering +
  `:global`/Horde for process placement if multi-node.

## 6. Decision matrix

| Approach | Real concurrency | Data-loss safe | Effort | New infra | Fits D2 minimal-ops | Verdict |
|---|---|---|---|---|---|---|
| A. Harden locking | No | Yes | S | none | ✅ | v1 option |
| **B. Optimistic concurrency** | No | **Yes** | S–M | none | ✅ | **Do now** |
| C. OT | Yes | Yes | XL | none | ✅ | Reject (cost) |
| **D1. CRDT rich-text** | Yes (text) | Yes | L | `y_ex` (or Hocuspocus) | ✅ with `y_ex` | **Post-v1, first** |
| D2. CRDT whole-doc | Yes (full) | Yes | XL | `y_ex` (or Hocuspocus) | ✅ with `y_ex` | Post-v1, later |

## 7. Recommended next steps

1. **Now (v1 hardening, independent of collab):** implement **Approach B** —
   `lock_version` on content `:update`, surface a conflict in `ContentEditorLive`
   instead of silent last-write-wins. Keep hardened single-editor locking (A).
2. **De-risk spike (timeboxed, throwaway):** one `rich_text` block, two browsers,
   synced through **`y_ex` over a Phoenix Channel** with TipTap Collaboration +
   awareness carets. Success criteria: concurrent typing converges; a server-side
   **debounced checkpoint** materializes the Yjs doc → block HTML → one Ash
   `:update` → one PaperTrail version. Explicitly evaluate `y_ex` API gaps.
3. **If the spike passes:** productize as **D1** behind a feature flag (collab
   editing per document), Awareness-based cursors replacing the field-focus hack.
4. **Later, if demanded:** extend to **D2** (whole-document `Y.Array`), tackling
   nested/custom blocks and the full ProseMirror schema.

If the `y_ex` spike reveals blocking gaps, fall back to a **Hocuspocus sidecar**
for D1/D2 and accept the extra service — re-weighing against D2's minimal-ops goal.

## Sources

- [satoren/y_ex — Yjs port for Elixir](https://github.com/satoren/y_ex) (Rustler NIF over Rust `y-crdt`)
- [Yrs Elixir bindings — Yjs community](https://discuss.yjs.dev/t/yrs-elixir-bindings/2826)
- [Building collaborative real-time interfaces in Phoenix LiveView with CRDTs](https://dev.to/hexshift/how-to-build-collaborative-real-time-interfaces-in-phoenix-liveview-with-crdts-2iop)
- [TipTap — Collaborative editing (Hocuspocus)](https://tiptap.dev/docs/hocuspocus/guides/collaborative-editing)
- [Yjs ↔ ProseMirror / TipTap bindings (`y-prosemirror`, `y-tiptap`)](https://docs.yjs.dev/ecosystem/editor-bindings/tiptap2)
- [Hocuspocus — self-hosted Yjs collaboration backend](https://tiptap.dev/docs/hocuspocus)
- [Yjs](https://github.com/yjs/yjs)
