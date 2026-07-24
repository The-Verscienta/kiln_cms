# Content Editor Reliability Audit — 2026-07-24

Scope: the structured content authoring surface — `KilnCMSWeb.ContentEditorLive`
(`lib/kiln_cms_web/live/content_editor_live.ex`, ~3050 lines) and the machinery it
depends on: the block serialization round-trip (`KilnCMS.CMS.TypedBlocks`,
`KilnCMS.Blocks.Upcaster`, the block modules), the save/autosave actions and
optimistic locking (`KilnCMS.CMS` content actions), the collab CRDT checkpoint,
and the in-context / presentation / headless write paths that mutate the same
records.

Method: six independent reliability finders (autosave/save flow, socket-state ↔
form-params divergence, LiveView lifecycle/connection, block serialization
round-trip, concurrency/version conflicts, pickers/indices), deduped, with the
load-bearing claims verified against the code. Findings are marked **confirmed**
(traced in code) or **plausible** (mechanism real, trigger depends on config or a
path not fully traced). No fixes were applied while auditing.

## Root cause

Authored state lives in **three stores that drift apart**:

1. socket assigns — `block_children` holds every `columns` block's children as
   raw maps, rendered through **nameless inputs**;
2. the `AshPhoenix.Form` params — the rest of the document;
3. the persisted DB record.

The children in (1) are re-merged into (2) via `inject_children/2` only on the
code paths that remember to call it, and they are re-seeded from (3) on every
mount and every post-save reload. Anything in (1) or (2) that hasn't reached (3)
is lost when the process dies, and any handler that rebuilds (2) without (1)
drops the children. Compounding this, **there is no draft-recovery layer** (no
client-side cache, no replay) and the **concurrency model has gaps** (optimistic
lock covers only two of the write actions and none of the headless path). The
sections below are ordered by how much they contribute to the day-to-day
"unreliable" feeling.

---

## Theme 1 — the block editor silently loses in-progress work

**T1.1 — Nested/columns child inputs are nameless and commit only on blur; any
interim re-render discards uncommitted keystrokes.** *(confirmed)*
`content_editor_live.ex` (~line 2235). Children of a `columns` block are bound to
`value={@child[field]}` with no `name`, committing to `block_children` on
`phx-blur`. An autosave reload, a presence/cursor diff, or any other `handle_info`
that re-renders before blur resets the input to its socket/DB value.
*Failure:* type into a column's heading child, the 2 s autosave fires (or a
co-editor's cursor arrives) before you blur → the input snaps back to the
last-saved value and your text is gone.

**T1.2 — `clear_featured`, `pick_image`, and geo add/remove re-validate the form
without re-injecting children, wiping every columns block's children.**
*(confirmed)* Those handlers (lines ~466, ~489, ~514, `update_geo_items` ~1044)
build params from `AshPhoenix.Form.params()` and call
`AshPhoenix.Form.validate/2` **without** the `inject_children(params,
block_children)` step that `validate` (line 437) and the save path (687, 1113)
use. Because a columns block's children are socket-managed and absent from the
form's param projection, validating without injecting drops them.
*Failure:* on a page with a populated columns block, click "remove featured
image" (or pick a featured image, or add an FAQ row) → the columns children are
wiped from the form, and the ensuing autosave persists the empty block.

**T1.3 — Legacy nil-id columns blocks collide in the seed map and are skipped on
inject.** *(confirmed)* `seed_block_children` (~218) does `Map.new(fn c -> {c.id,
…} end)`; two columns blocks stored before ids were backfilled (both `id: nil`)
collapse to a single `nil` key, so the second's children overwrite the first's in
the editor. On save, `inject_block` guards on `block["id"] &&`, so a nil-id block
is returned unchanged and — since its children are socket-managed — saved without
them. *Failure:* open a page with two pre-backfill columns blocks → one shows the
other's children, and saving drops both sets.

**T1.4 — `col_reorder`/`rebuild_columns` trust the client `cols` payload for
column count and child membership, so a drag against a stale DOM can drop a
column or children.** *(plausible)* `rebuild_columns` builds `by_id` from current
children and maps over the client-supplied `cols`; any child id absent from the
payload is not re-picked (dropped), and the column count collapses to
`length(cols)`. A drag fired before the DOM reflects a just-added child can
therefore lose it.

**T1.5 — `remove_block` never deletes `block_children[id]`; the socket map leaks
orphaned child trees for the session.** *(confirmed, low severity)* Harmless to
current saves (UUIDs don't collide) but unbounded growth, and combined with
stale-index removal a mis-targeted block could resurface orphaned children.

---

## Theme 2 — no draft recovery; a blip or reconnect discards edits

> **Status: mostly fixed.** A server-side crash-recovery snapshot was added: the
> content resource gained `draft_snapshot`/`draft_saved_at`, a side-channel
> `:snapshot_draft` action (touches only those, never live content/state/version/
> artifacts), and the editor writes the working state to it on the debounced
> autosave for non-draft content (live is still only applied via explicit Save).
> On reopen, a "restore unsaved changes?" banner offers Restore / Discard; any
> real save clears the snapshot. This resolves T2.1 (published edits now
> recoverable) and T2.4 (translation flush). **Residual:** T2.2's sub-2s draft
> debounce-window loss and T2.3's connect-race are inherent to the debounced
> server round-trip and would need client-side capture — deferred.

**T2.1 — Published / in-review / archived content never autosaves; edits live
only in memory until manual Save, and a reconnect discards them.** *(confirmed)*
`mark_dirty` (~836) sets `save_state: :unsaved` with **no timer** for non-draft
content. On a socket drop the LiveView remounts and `mount/2` refetches from the
DB with no draft recovery. `UnsavedGuard` only covers `beforeunload` and
`phx-link` clicks — a transport reconnect fires neither. *Failure:* make
substantial edits to a published page, hit a WiFi blip → everything since the
last manual Save is gone, no warning.

**T2.2 — Draft edits inside the autosave debounce window are lost on reconnect.**
*(confirmed)* `mark_dirty` schedules `Process.send_after(self(), :autosave,
2000)`. If the socket drops before it fires, the message dies with the process
and `mount` rebuilds from the DB — no sessionStorage, no client replay.

**T2.3 — The documented connect-race drops events fired before the channel join
ack, so early edits never mark dirty or save.** *(plausible)* This repo has a
known race where `phx` events are dropped until the channel join is acked. The
editor's mutating events (`validate`, `reorder`, `pick_image`, `col_*`) have no
client buffering/replay, so an edit typed in the connect→join window is silently
dropped.

**T2.4 — `create_translation` (server `push_navigate`) bypasses the UnsavedGuard
prompt.** *(confirmed)* `UnsavedGuard.onClick` only intercepts `a[data-phx-link]`
clicks; a server-initiated `push_navigate` from a `phx-click` button
(`create_translation` ~757, and similar) navigates away from unsaved edits with
no confirmation.

---

## Theme 3 — concurrent edits clobber each other silently

**T3.1 — The single-saver election is gated behind `collab_prototype`, which is
OFF in production, so concurrent draft editors both autosave and the loser is
forced to discard.** *(confirmed)* `collab_active?` requires `collab_token != nil`
(`Crdt.enabled?/0`, which is `Application.get_env(:kiln_cms, :collab_prototype,
false)` — true only in `dev.exs`/`test.exs`). In prod it is always false, so the
`persister?` branch never runs; every editor on a draft schedules its own
autosave (line 847). The loser of the optimistic-lock race hits `flag_conflict`
and can only `reload_conflict`, which discards local edits.

**T3.2 — Two browser tabs of the same user self-conflict.** *(confirmed)*
`Presence.editors/2` keys by `user.id`, so two windows collapse to one entry;
`collab_active?` needs `length(editors) > 1`, so it's false → both tabs autosave,
the second gets `StaleRecord` → `flag_conflict` → one tab's work lost on reload.

**T3.3 — Optimistic locking is a no-op on the headless path.** *(confirmed)*
`optimistic_lock(:lock_version)` is on only `:update` (1130) and `:autosave`
(1169), and `lock_version` is `public?: false` (1527) so a stateless JSON:API /
bridge PATCH can never echo it — the server loads the row fresh and the in-memory
`lock_version` always equals the DB, so the check always passes. Combined with
`ApplyBlocksInput` replacing the **entire** block union from the client-supplied
tree, any headless writer silently clobbers concurrent editor saves (whole-
document overwrite, not a per-block diff).

**T3.4 — Workflow and restore actions have no optimistic lock.** *(confirmed)*
`:publish`, `:publish_scheduled`, `:unpublish`, `:submit_for_review`,
`:restore_version`, `:archive` carry no lock. A `restore_version` or `publish`
issued from a stale editor tab force-writes over newer saved blocks with zero
conflict detection; a manual `:publish` racing the AshOban `:publish_scheduled`
trigger can double-transition and double-anchor the governance version chain
(#356).

**T3.5 — Conflict resolution only offers "reload and discard my edits."**
*(confirmed)* `flag_conflict`/`reload_conflict` present no merge, no diff, no
keep-mine — a passive autosave conflict (the user never even clicked Save) throws
away everything since mount.

---

## Theme 4 — crashes that kill the session (and its unsaved work)

**T4.1 — Unguarded `String.to_integer` on client params crashes the LiveView.**
*(confirmed)* `open_picker` (455), `move_block` (591), `put_block` list branch
(1037), and the `sort_by` key (1099) call `String.to_integer` on client-supplied
`index`/`path` values. A stale or tampered value that isn't a base-10 integer
raises `ArgumentError`, the process crashes and remounts, dropping all in-memory
edits.

**T4.2 — Post-save reload uses the bang `fetch!`.** *(confirmed)* If the record is
concurrently hard-deleted or read access is revoked between the write committing
and the reload, `get_record!` raises out of `handle_info(:autosave)` and crashes
the LiveView.

**T4.3 — `move_block` doesn't bounds-check the source index.** *(confirmed)* A
negative index passes the `j >= 0 and j < count` guard for the *target* while the
source `Enum.at(order, -1)` / `List.replace_at(order, -1, …)` addresses the **last**
element — silently swapping the first and last blocks instead of a no-op.

---

## Theme 5 — wrong-target actions & block round-trip edge cases

**T5.1 — Positional addressing survives reorders/removals, so the picker writes
to the wrong block.** *(confirmed)* `open_picker` stores `:picking` = the block's
render position; the pick buttons carry that positional index. If the block list
changes (reorder/remove) between opening and picking, `put_block(N, …)` merges the
image into whatever block now sits at position N. Blocks carry stable ids
precisely so identity survives reorders — the picker just doesn't use them.

**T5.2 — `remove_block`/`move_block`/`geo_item_remove` carry the pre-reorder
positional path.** *(confirmed)* An in-flight client `Sortable` reorder (sent
async/debounced) lets a delete/move click land on the wrong block; the button
still carries the stale `phx-value-path`/`index` from the last server render.

**T5.3 — `geo_item_remove`'s `to_int` falls back to 0.** *(confirmed)* A garbled
`phx-value-item` deletes FAQ/HowTo row 0 instead of the intended row — silent
wrong-target deletion (the guard masks bad input rather than rejecting it).

**T5.4 — `to_legacy` has no catch-all clause.** *(plausible)* Only the 12 core
block structs have `one_to_legacy` clauses. If a plugin can register a block type
whose struct reaches this pipeline, it raises `FunctionClauseError` and 500s
delivery/preview/API (`block_components`, `preview_live`, `token_preview_live`,
`in_context_edit_live`, `content_controller`). *Needs confirmation of whether
plugin block modules join `@block_modules`.*

**T5.5 — An uninstalled/unknown block type collapses to an empty `Custom`.**
*(confirmed)* `struct_from_typed_map`/`block_type_atom` map any unrecognized
`_type` to `:custom` and copy only id/_type/_version/legacy_type/content/data, so
the block's own fields **and its type tag** are dropped; the next save persists
the empty block → permanent silent loss. (Contrast `one_from_legacy`, which
preserves foreign data via `legacy_type`+`data`.)

**T5.6 — Long tail (low severity).** `from_legacy` has no non-map guard →
`BadMapError` on malformed stored JSON (a bare string element, a string `data`);
the upcaster resolves non-core types (faq/how_to/claim/form + plugins) to
`:custom` so their declared version migrations never run on read, and a
version-gap step stamps the version without transforming data; RichText Portable
Text is flattened to HTML across a `to_legacy → from_legacy` round-trip (loses
marks/markDefs); `search_media` runs a full ILIKE scan on a whitespace-only
query.

---

## Recommended fix order

1. **Theme 1** — stop the silent block-content wipes. Route the picker/featured/geo
   handlers through `inject_children`, fix the nil-id seed/inject collision, and
   move nested-block content off nameless/blur-only inputs (or make the children a
   first-class part of the form params). Highest day-to-day impact.
2. **Theme 2** — add a draft-recovery net (autosave non-draft too, or persist to
   `sessionStorage` and offer recovery on remount) and guard the connect-race.
3. **Theme 3** — put `optimistic_lock` on the workflow/restore actions, make the
   lock protect the headless path, and give conflict resolution a keep-mine option.
4. **Themes 4 & 5** — guard the `String.to_integer` call sites, replace `fetch!`
   with a non-raising reload, and move picker/delete/move addressing from
   positional index to the blocks' stable ids (knocks out several T5 items at
   once). Add a `to_legacy` catch-all / unknown-type preservation so an
   uninstalled or plugin block can't 500 delivery or be silently emptied.

Each theme is a PR-sized unit run through the usual gate
(`format`/`credo --strict`/`sobelow`/`dialyzer`/`mix precommit`).
