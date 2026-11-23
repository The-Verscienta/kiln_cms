# Inline editing of related records: plan

Status: PR 1 built (the `edit_inline` option, fields-admin checkbox, schema export and a read-only card); PR 2a built (Card Save, mock in [inline-reference-card-mock.html](inline-reference-card-mock.html)); PRs 2b and 3 not built. Tracking issue: #2283. Written 2026-11-16 against
`main` after #2285 (reference selection and create-on-type, all four PRs) and
the #2282 plan ([flexible-content-plan.md](../flexible-content-plan.md)). Nothing
here is a decision until the PR that carries it merges; the questions for the
maintainer are at the end.

Builds on [relationships-plan.md](../relationships-plan.md) (D22, D23, R3, R9),
[reference-selection-plan.md](reference-selection-plan.md) (S5, "Add new"),
per-field grants (#2281) and the working copy ([working-copy.md](../working-copy.md)).

## Why

Drupal's Inline Entity Form, Craft's nested entries, Toolset's intermediary
posts and JetEngine let an editor change the *related* record from the page of
the record that points at it. Kiln's reference picker searches, connects, and
creates a new target through a small form (title and required plain fields),
but changing an existing target means leaving the parent: open its editor,
save, come back, and lose the parent's unsaved edits or save first. Editors
who maintain a recipe and its ingredients, or an article and its sources, feel
this every day.

The issue's own constraints, which this plan keeps verbatim: the child is saved
as its own record under its own authorization, versioning and lock; the parent
form never writes the child's data directly (D23 stance); cardinality,
`max_sources` and `on_target_delete` keep applying; depth is 1 and failures
close.

## What exists and must not be rebuilt

| Mechanism | Where | Consequence |
|---|---|---|
| "Add new" creates the child **immediately** on its own *Create* click, as the actor, through `ContentTypes.create!/3`, then connects it with the same `:add`/`:put` message a pick sends. Abandoning the parent leaves the draft. | `ReferencePicker.create_and_connect/3` | Create-and-connect already has "child saved on its own, parent later" semantics. Inline editing extends that model; it does not need a new transactional one. |
| The "Add new" form renders only plain field types, named under `_kiln_ref_new` with its own `phx-change`, because it sits inside the editor's `<form>` and HTML forbids nesting. | `new_record_form/1`, `@creatable_field_types` | The inline form uses the same trick and the same field-type limit. |
| `ReverseFields.connect/disconnect/move` is the precedent for a component writing **another record** as the actor: `can_write?` gates it, the write is the record's own `:update` (or `:save_working_copy` when published) on the struct the caller last read, so the optimistic lock catches a change in between. | `reverse_fields.ex` (`editable?/4`, `edit/4`, `save/4`) | The inline card is the same shape: one record, its own write, its own lock. |
| `ContentTypes.can_write?/4` returns the generated `can_*?` of the exact action the write runs (working copy for a published row). | `content_types.ex` | Per-child authorization needs no new policy code. |
| Per-field grants: `Scoping.field_grant(actor, tenant, type)` + `FieldAccess.writable?/2`; `EnforceCustomFieldGrants` refuses a write that touches a field the actor may not write, on any path. | `reference_picker.ex` (`prefill_writable?`), `enforce_custom_field_grants.ex` | Enforcement is automatic on the child's own update. The form only has to *not offer* what would be refused. |
| `ApplyCustomFields` merges a partial update per key; the supplied map is merged over the stored one. | `apply_custom_fields.ex` moduledoc | A form that sends only the fields it shows cannot clobber fields it cannot render. |
| `FieldDefinition.widget` (ADR 0048/0049) is an editor-only string the server never reads. | `field_widgets.ex` | The precedent for an option that changes only the editor. Compared in the decision below. |
| Reference values are snapshots (`id`, `type`, `slug`, `title`) built at the parent's write; re-fire resolves slug/title fresh (R0), and reads mask targets the reader cannot read (R0 follow-up). | `apply_custom_fields.ex` (`reference_snapshot/2`), `reference_snapshots.ex` | A child's title change reaches published output through re-fire; the parent's *stored* snapshot lags until the parent next saves. Order of saves matters (I5). |

## Decisions

**I1. A per-field option, `edit_inline`; the picker keeps searching, connecting
and "Add new"; each connected row gains an expandable editor.** Not a widget
value. `FieldDefinition.widget` is how a value is *chosen* (autocomplete or
dropdown) and is mutually exclusive by construction; "edit the record I
already chose" composes with both, so it is orthogonal and gets its own
nullable boolean, `public?: true`, validated and cleared on anything but a
top-level `:reference` in `Changes.ClearReferenceOptions` (the `selection`
precedent, one more line). One additive nullable column via `mix ash.codegen`,
expand-only: the previous release never reads it, the `kiln_reporting_v1`
views do not read it, `mix kiln.migrations.check` passes. The field sync file
stays version 1 (ADR 0047). Rejected: a new `widget` value (a zero-migration
shortcut, but it would make "dropdown" and "inline" exclusive and would bend
ADR 0048's "widgets never change what the editor can do to *other* records").

**I2. The card is a real, separate write; there is no shared transaction.**
This is the central decision. Three shapes were weighed against the code:

| Shape | Verdict |
|---|---|
| **A. Child Save button on the card.** Writes the child at once with its own action; the parent is untouched. | **Chosen for v1** (PR 2). Same semantics as "Add new" and `ReverseFields`; failures stay on one record. |
| **B. Parent Save cascades.** Dirty cards are saved first, in order, one at a time, each its own commit; the parent is written only if every child succeeded. No shared transaction. | **Chosen as PR 3**, on top of A: the single-Save UX without the atomicity cost. |
| **C. One database transaction for parent plus children.** | **Rejected.** See below. |

Why not C, from this repo: the parent's own Save is already up to three
independent writes (working-copy flush, `:save_working_copy`, `:update`;
`save_live/2`), so there is no single parent changeset to put in a transaction.
Wrapping Ash actions in your own transaction drops their notifications (the
Releases fix needed `return_notifications?` plus a replay, #500), and the
inner actions' own `after_transaction` hooks (publish, re-fire, webhooks) still
escape it. Row locks taken in the order the user happened to open cards can
deadlock against a co-editor saving in the other order. A long transaction
spanning N records holds a connection while firing and indexing run. And it
buys little: with B each commit is a valid record on its own, so a failure
midway leaves *consistent* data (children saved, parent not), never a corrupt
pair. The cost of B is that "all or nothing" is not offered; the card status
says exactly which records were saved.

**I3. Cascade order and failure rule (PR 3).** On parent Save: collect dirty
cards, save each child (by card order; the `:update`/`:save_working_copy` the
card already runs), stop at the **first** failure, show that child's errors on
its card, and **do not run the parent write**. The parent form keeps its
unsaved edits. Children already saved stay saved and show *Saved*. Children
first, because the parent's `ApplyCustomFields` reads each target (the **live
row**) as the writer and stores a snapshot (title, slug). That is fresh for
**draft** children only: a published child's card edit lands in its working
copy (I7), so its live title does not move and the parent's snapshot keeps the
live title until the child is published (re-fire serves the right value then,
R0). PR 3 also confirms the editor always supplies the reference field on the
parent write, or forces it. A card's dirty flag resets when that card saves, so
a re-click of Save after a parent failure re-runs only the still-dirty cards.
When children commit and the parent then fails or is stale (`flag_conflict`),
saved cards stay *Saved* and the parent's conflict reload must not discard
them. The cascade also runs before a workflow transition or publish of the
parent (`settle_before_workflow`), so "publish" never leaves unsaved child
edits behind. A stale child (lock mismatch) is a
failure like any other and offers *Reload this record*. Never a retry loop and
never a silent partial overwrite.

**I4. Scope of the inline form is deliberately narrow, and depth is 1 by
construction.** The card edits the child's `title` (gated by
`FieldAccess.writable?(grant, ["title"])`, since `EnforceFieldGrants` governs
whole attributes) and its custom fields of the
types the "Add new" form already renders (`@creatable_field_types`: string,
text, integer, float, boolean, date, datetime, url, select), minus fields the
actor's grant for the child's type does not allow (`Scoping.field_grant` +
`FieldAccess.writable?`), minus computed fields and fields with a dynamic default. `unique` fields are
**allowed**: the child's `:update` validates uniqueness and the error shows on
the card (`plain_field?/1` was written for create-time prefill; the card does
not inherit its `unique` exclusion). **Read grants apply first:** a field
hidden by the actor's read grant (`FieldAccess.readable?/3`, `hidden_names/3`)
is not rendered at all, editable or not, so the read-only fallback never leaks
a private value. Every other field (media,
reference, group, rich text, plugin types, flexible items once #2282 lands) is
shown read-only with *Edit in full editor*. The child's blocks, SEO, taxonomy
and schedule are not offered. Consequences: no nested reference pickers inside
a card, so no recursion, no cycles (A edits B inline; B's reference back to A
renders read-only), and nothing here needs the "pickers addressed by path"
work that #2282 PR 3 owns. The form sends only the fields it shows, relying on
per-key merge (table above). **Conditions:** the card re-evaluates
`visible_when`/`required_when` (`KilnCMS.CMS.Conditions`) on `phx-change` over
the child's values; a field whose condition depends on a field the card does
not render is decided by the server on save (the child's own validation) and
shown as an error, not guessed client-side. The shared input renderer extracted
from "Add new" does not do conditions today, so this is new work in PR 2a.
**Locale:** a `:shared` custom field on a non-source locale variant is
read-only in the card (`SharedFieldsReadOnly` would refuse it); the card edits
exactly the row the reference points at, never a sibling locale. **Multiple
target types (R2):** the row's `type` picks the child's content type per row. This is fail-closed: an unrenderable type is a
link out, never an attempt.

**I5. Authorization follows the record written (D23), and creates no new
authority.** Invariant, each clause a test: every inline write is exactly a
write the actor could make from the child's own editor, because it runs the
same action on the same struct.

* The card opens an editor only if `ContentTypes.can_write?/4` holds for the
  child as the actor in the parent's tenant (`ReverseFields.editable?/4`
  pattern). Otherwise the row is read-only. A connected child the actor cannot
  read already shows as *Unavailable* and has no card.
* The server re-checks on every event (`can_write?`, child read in tenant),
  so a forged `inline_save` for an unreadable, trashed (ADR 0052), cross-tenant
  or non-connected record is a no-op. The card event carries the row key, not a
  free record id: the server resolves it from the field's current value.
* The parent field's grant (#2281) governs the **connection** (which records
  the parent field holds), not the child's content. A viewer-grant parent field
  therefore still shows cards for children the actor may write (no new
  authority, since the child's own editor allows the same); the picker's
  connect, "Add new" and remove controls stay locked as today. Stated in the
  docs; Q3.
* The child's own `EnforceCustomFieldGrants`, validations, `:update` policies
  and the takedown rule (ADR 0051) run unchanged. A refusal is an error on the
  card, never a crash.

**I6. Concurrency: the child's `lock_version` is the guard; no advisory field
locks in v1.** The card holds the struct it read (the working view for a
published child, like `ReverseFields.edit/4`), submits through the child's own
`:update`/`:save_working_copy`, and the optimistic lock refuses a stale write
(`StaleRecord`). After **every** successful save the card replaces its struct
with the re-read result (as `saved/2` does for the parent), or its next save
would fail against its own write. A published child's working copy and live row
share one `lock_version` counter, so a co-editor's autosave on that child also
stales the card; the copy says "someone changed this record". The card then shows *Changed by someone else. Reload this
record*, discards the card's draft on click, and re-reads. The parent's own
conflict banner is separate. The advisory `Collab.FieldLock` is keyed by the
child's editing topic and acquired per focused field; inline cards neither
acquire nor honor it in v1 (lock_version still prevents lost updates; the cost
is a co-editor sees a conflict instead of a lock). Reading the child's lock map
to disable fields another person holds is a cheap follow-up (Q4).

**I7. Publish workflow is the child's own.** A draft child saves as a draft. A
**published** child's inline Save goes to its working copy
(`ContentTypes.save_working_copy/4`, `can_write?` already chooses it) and is
live only after that child's own *Publish changes*. **Title is different from
custom fields here:** `:save_working_copy`'s `fields` argument holds only
`WorkingCopy.held_param_keys/1`, which excludes `title` and `blocks`; the title
travels as `working_title` (the action's `accept`), and `ReverseFields` never
writes it. The card therefore submits `working_title` beside `fields`, and
displays `WorkingCopy.view/1` (held title and fields). Test: renaming a
published child through a card sets `working_title` and leaves the live
`title` unchanged. The parent's publish does
not publish children. The card says so, per state, with the badge the picker
rows already carry: *Draft: readers do not see this record, so the parent's
page omits it until it is published* (R0 masking), and *Saved to the working
copy. Readers see this once you publish it.* The card links to the child's
editor for transitions and approvals; v1 has no inline publish button
(approvals and takedowns (ADR 0051) are record-level decisions). Q5.

**I8. Validation errors stay on the card.** Each open card holds its own
`AshPhoenix.Form` for the child (`for_update(child, action, actor:, tenant:)`)
in a new `ReferenceInline` live component, keyed by field and row key. Errors
from the child's changeset render under the child's inputs; they are never
merged into the parent form's errors, and the parent's error styling for the
reference field is unchanged. A summary line on the card header
(`role="alert"`) names the count; focus moves to the first invalid input on a
failed save. The parent's Save-time errors that concern the connection
(`max_sources`, selection, a missing target) stay on the parent field as today.

**I9. Link fields (R3) stay the parent's.** Per-connection values (quantity of
each ingredient) live in the parent's value and are saved by the parent. The
card has two visibly separate groups: *On this connection* (saved with the
parent, today's row inputs) and *The <Type> record* (saved on its own, with its
own Save and status chip). The split is the main design risk (see Risks) and is
settled with a mock before PR 2 builds the card.

**I10. Connection rules are untouched.** Inline editing never connects,
disconnects or reorders. "Add new" from inside the card area still goes through
`create_and_connect/3` and the `:add`/`:put` message, so `max_sources`,
`on_target_delete`, `selection`, create-on-type and `max_items` apply exactly as
today. There is no inline delete: *Remove* disconnects only, and destroying a
record stays in its own editor (policy-gated, `on_target_delete` aware).

**I11. Inline create uses the card, not a second form.** "Add new" keeps its
immediate-create behavior (draft on *Create*). After PR 2, when `edit_inline`
is on, a created child opens its card expanded so the editor can fill the
remaining fields without leaving; the small "Add new" form still asks only for
title and required plain fields. No change to when the draft is created. A
draft nobody saves is the same orphan the R9 plan already accepts.

**I12. API, GraphQL, MCP: no write surface in v1, by design.** The option is
editor-only (the ADR 0048 stance) and the server never reads it on a write.
Headless clients already compose it from two authorized calls: write the child
at its endpoint, then connect it (`PATCH` relationship, `add<Type>References`,
`ReferenceEdits`). A nested "write the child through the parent's mutation"
input is *not* offered: it would re-introduce the shared-transaction question
(I2), merge two resources' errors into one path, and need per-child
`expected_lock_version` inside one request. If demand appears it is its own
issue and ADR. Surfaces that do change, all additive: the `edit_inline`
attribute on the field definition (JSON:API attribute, admin GraphQL, field sync
file), and `SchemaExport` reporting it beside `x-kiln-widget` as
`x-kiln-edit-inline` (annotation only; no type change in the TS/Swift/Kotlin
emitters). `JoinGraduation` does not carry it.

**I13. Revisions and history.** Each card save cuts **one version of the
child** (PaperTrail, as any edit), attributed to the actor, with the child's
`<type>.updated` webhook and re-fire of its referrers. The parent's version
history is unaffected unless the parent also saves. Restoring a parent version
does not roll children back, and the history copy says so. A cascade (I3) of N
children is N child versions plus the parent's, by design.

## UX

* On a row of a field with `edit_inline`: a disclosure button *Edit <title>*
  (`aria-expanded`, `aria-controls`), collapsed by default. Opening reads the
  child (and its field definitions) lazily; a field with 50 rows costs nothing
  until a card opens. A cap of 10 open cards per field keeps LiveView memory
  bounded; opening an 11th asks to close one.
* Card: title and plain custom fields as inputs named
  `_kiln_inline[<field>][<row key>][...]` with their own `phx-change` (outside
  the parent's params, like `_kiln_ref_new`), a state badge, *Save <Type>*,
  *Discard changes*, *Open in full editor* (new tab), and a status chip:
  *Unsaved changes*, *Saving*, *Saved*, *Saved to working copy*, *Error*.
* The parent editor learns a card is dirty by message
  (`{ReferenceInline, {:dirty, key, bool}}`) into its **own** assign
  (`inline_dirty`), OR-ed into `data-dirty` for the unsaved-changes guard and
  counted by PR 3's cascade. It must **not** call `mark_dirty/1`, which would
  schedule the parent's draft autosave or flip its save state whenever a card
  is edited.
* The card's inputs sit inside the parent `<form>`, so Enter in a card input
  would submit the parent (`save_live`, PR 3's cascade). The card carries the
  same Enter/Escape hook "Add new" uses (Enter saves the card, Escape closes
  it), `_kiln_inline[...]` keys are stripped before the parent's
  `AshPhoenix.Form.validate/submit`, and a test pins that Enter in a card does
  not submit the parent.
* Cards work on an unsaved parent (`/new`): the child already exists, and its
  write does not involve the parent. The open-card cap (10) is per parent form
  across all its `edit_inline` fields. A closed card with unsaved edits stays dirty and
  keeps its draft until saved or discarded; leaving the page warns once.
* Fields admin: one checkbox on a reference field, *Let editors edit the
  related record here*, with a sentence that says it is saved separately and
  separately authorized. Shown only for a top-level reference.
* Components follow `docs/design-language.md` (no new class names expected);
  all strings through gettext, American English; keyboard and screen-reader
  paths covered by the e2e flow.

## Interaction with #2282 (flexible content), stated so neither plan drifts

* `edit_inline` is valid only on a **top-level** `:reference`. It is refused on
  a reference sub-field of a group or a flexible item (validation plus the
  `ClearReferenceOptions` clause), the way #2285's `selection` is. That keeps
  this feature off the "pickers addressed by `_id`" problem that
  [#2282 PR 3](../flexible-content-plan.md) owns and avoids two plans editing
  `group_rows_input` or `FieldDisplay`.
* A reference *inside* an item can later gain inline editing as a separate
  issue once #2282 PR 3 lands path-addressed pickers; this plan's card is keyed
  by row key and is reusable then.
* Shared items per #2282 §7 ("a `:reference` sub-field to an entry is the
  reuse of Fragments") will be edited **at the entry**. Inline editing of that
  entry from inside an item is exactly the follow-up above; nothing here blocks
  or pre-empts it.
* Files this plan touches that #2282 also touches: `field_sync.ex` (attribute
  lists) and the schema export. Both are one-line additive changes; whichever
  PR lands second rebases.

## Authorization matrix (what each test must prove)

| Actor / situation | Card | Save |
|---|---|---|
| Viewer, or any actor without `can_write?` on the child | row, no card | refused if forged |
| Editor, child writable, draft | card | `:update`, version cut |
| Editor, child writable, published | card, "saved to working copy" | `:save_working_copy` only |
| Child unreadable (policy, tenant, trashed) | *Unavailable*, no card | forged event is a no-op |
| Grant on the child's type withholds a field | field read-only | refused by `EnforceCustomFieldGrants` even if posted |
| Parent field locked (#2281, no write grant) | cards still shown; connect/create/remove stay locked | child write allowed only if child policy allows |
| Another editor saved the child first | stale notice | `StaleRecord`, nothing overwritten |
| Takedown rule (ADR 0051) on the child | refused with the reason | same error as the child's own editor |
| Forged row key not in the field's value | no-op | no-op |
| Child field hidden by the actor's read grant | not rendered at all | n/a, and a posted value is refused |
| Child trashed after the card opened | card shows the refusal | `update` refused (ADR 0052), same error as its editor |
| `edit_inline` on a sub-field or non-reference | admin refuses | n/a |
| Admin | as editor; policies unchanged | same |

## Risks

* **Two saving domains in one card.** Editors may assume the parent's Save
  covers the card, or the reverse. Mitigated by the visual split (I9), the
  status chip, the unsaved guard, and the cascade in PR 3; the highest UX risk
  and the reason PR 2 starts with a mock.
* **Silent data loss on navigation.** A dirty card is state the parent
  editor must know about; getting the dirty message wrong loses edits. Test:
  edit a card, trigger every way out (navigate, reload, switch version,
  restore, conflict reload, and every workflow transition or publish via
  `run_workflow`/`settle_before_workflow`, plus `{:shutdown, :left}`).
* **Conflict banner confusion.** Two lock domains can both be stale. The card
  notice and the parent banner are separate components with different copy.
* **Partial cascade (I3).** Children saved, parent not, is consistent but may
  surprise. The cascade result is shown per card; the flash names how many
  were saved.
* **Webhook and re-fire volume.** N child saves are N `updated` webhooks and
  N referrer re-fires. Same as editing them elsewhere; documented.
* **Stored snapshot lag.** A standalone card save (PR 2) updates the child but
  the parent's stored snapshot (title/slug) stays until the parent saves, and
  for a **published** child stays until that child is published, because the
  snapshot reads the live row. Re-fire already serves fresh values (R0), so
  only the raw `custom_fields` read differs; documented. PR 3's cascade removes
  the lag for draft children only.
* **LiveView memory.** One card component per open card, holding a params map
  (no `AshPhoenix.Form`, see Deviations); capped at 10 per field.
* **Plugin and dynamic types.** The child's field list comes from the same
  `field_definitions` call as "Add new" (dynamic or compiled); a plugin field
  type is read-only (I4). A removed type makes its row read-only, as the picker
  does.
* **Drupal's pitfall list** (nested validation, revisions): handled by
  *not nesting*: one form per record, one write per record, errors per card.

## Tests

* Authorization matrix above, as LiveView tests with forged events and the
  R-series fixtures (cross-tenant, trashed, unreadable).
* Save paths: draft child writes `:update` and cuts a version; published child
  writes a working copy only and its live row is unchanged; stale child
  refuses and the card offers reload; `max_sources`/selection untouched by an
  inline save.
* Partial merge: a child with a media field and a group keeps both after an
  inline save of its title.
* Grants: field not writable is read-only and a hand-posted value is refused;
  a read-hidden field is not rendered; `title` follows the title grant.
* Conditions, shared-locale fields, `unique` field error on the card,
  multi-type (R2) field, trashed-after-open, Enter not submitting the parent,
  card edits not triggering the parent's autosave.
* Schema goldens, `DriftTest` and the OpenAPI `--check` (#2695) regenerated for
  `x-kiln-edit-inline`.
* Cascade (PR 3): order, stop-at-first-failure leaves the parent unsaved and
  its form intact; children-first yields a fresh snapshot for a draft child
  and the unchanged live title for a published one; a parent conflict after
  the children committed keeps them *Saved*; unrelated parent edit with no dirty cards is unchanged
  behavior.
* Dirty tracking: every exit path with a dirty card.
* Definition: `edit_inline` refused on a sub-field/non-reference, cleared on a
  type change, round-trips through field sync, appears in `/api/schema`.
* API: no behavior change; a regression test that `PATCH` of the parent never
  writes a child.
* e2e (Playwright): open a card, edit a field, save, see the chip; make a
  conflict from a second session; keyboard-only open/save/close.
* `mix kiln.migrations.check`, snapshot regenerated, gettext check, dialyzer.

## Docs

`docs/relationships-plan.md` gains a pointer under R9; `docs/extending-content.md`
a "Edit related records in place" how-to that states the separate-save model;
`docs/json-api.md` and `docs/headless-graphql-api.md` one paragraph that
inline editing is editor-only and how a headless client composes it; a new
ADR (next free number at PR time) recording I1, I2 and I12; CHANGELOG one line
per PR plus the long-form entry in the next release's `docs/changelog/` file.

## Recommended split (4 PRs plus a refactor, each releasable alone)

0. **Refactor (optional, can merge any time):** extract the plain-field input
   renderer out of `ReferencePicker.new_field/1` (an 1,800-line file #2285
   follow-ups still touch) into a shared module, no behavior change. Done
   first so the later PRs do not bury it.
1. **Option and admin.** `edit_inline` attribute and migration, validation and
   `ClearReferenceOptions` line, field sync, schema export annotation
   (goldens, OpenAPI check), the fields-admin checkbox. The checkbox is
   user-visible, so it ships with a read-only card (disclosure, per-child
   authorization and read grants, lazy load, row-type resolution) so the
   option is not a dead switch; the changelog line says "read-only preview of
   related records" until PR 2a.
2. **2a. Card Save.** The child form, `:update` / `:save_working_copy`
   (`working_title` for a published child), lock handling and struct refresh,
   conditions, errors, status chip, Enter/Escape hook, e2e.
   **2b. Dirty tracking and expand-on-create.** `inline_dirty` assign,
   unsaved-changes guard across every exit path, I11.
3. **Cascade on parent Save and workflow.** I3, including
   `settle_before_workflow`, result copy, snapshot test. Can be dropped or
   deferred if the maintainer prefers explicit per-card saves (Q1).

Order: (0) → 1 → 2a → 2b → 3. At PR time run `gh pr list` and rebase against
any open #2282 PR touching `field_sync.ex` or the schema export (only
one-line additive overlaps are expected; none are open today).

## Decided by the maintainer (2026-11-16)

1. Build the cascade on parent Save (PR 3), as in I3.
2. `edit_inline` is its own nullable column (I1), not a `widget` value.
3. Cards still show when the parent field is not writable under #2281 grants;
   the child's own policy decides (I5).
4. v1 scope as planned: `lock_version` only with no advisory field locks (I6),
   no inline publish button (I7), plain field types only (I4), and no nested
   write API (I12). Richer field types and a nested API are separate issues.

## Deviations

PR 1 differs from the plan in these places:

- **The cap of 10 open cards per field is enforced per picker, not per parent
  form.** `ReferencePicker` counts the cards open in its own field
  (`ReferenceInline.max_open/0`); the parent form has no state to count across
  fields until PR 2b adds `inline_dirty` and parent-level state.
- **The card is a function component inside the picker** (`ReferenceInline.toggle/1`,
  `card/1`, `refused/1`, with the open/closed state kept in the picker's
  `inline_open` assign), not yet a `ReferenceInline` live component.
- **The fields-admin checkbox is step 7**, "Editing the linked records", after
  step 6 "Which records can be picked".
- **The decision record is [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).**

PR 2a (Card Save) differs from the plan in these places. The mock it was built
from is [inline-reference-card-mock.html](inline-reference-card-mock.html).

1. **No `AshPhoenix.Form` per card.** The card (now the `ReferenceInline` live
   component) keeps a params map of the editable fields and calls
   `ContentTypes.update/4` or `ContentTypes.save_working_copy/4`; Ash errors
   are mapped to inputs by the card. The Risks line "one `AshPhoenix.Form` per
   open card" no longer applies.
2. **The title grant check is `nil grant or "title" in grant`.**
   `FieldAccess.writable?(grant, ["title"])`, as I4 writes it, looks for
   `custom_fields.title`, not the title.
3. **Q3: a card under a disabled parent field is disabled, not hidden.** When
   the parent field is read-only (a read-only grant, a held list, a
   localization lock) the picker sits in a disabled `<fieldset>`, so the card
   renders with disabled inputs and Save. The server would still accept the
   child write under the child's own policy.
4. **A draft `:update` also passes `kiln_if_match`** `[{lock_version, state}]`,
   because workflow writes keep `lock_version`. Both `StaleRecord` and
   `PreconditionFailed` map to the stale state (**Changed by someone else**,
   **Reload this record**).
5. **A blank title is refused on the card** (*Give it a title.*): a blank
   working title would otherwise poison that record's Publish.
6. **The title is read-only for a type with a `title_template`.**
7. **The record being edited never gets a card on its own field.**
8. **Closing a card with unsaved edits is refused, not kept hidden.** The card
   reports dirty state to the picker by `send_update`; the picker refuses the
   toggle (*Save or discard the changes to this record before closing it.*).
   The parent-level `inline_dirty` and the unsaved-changes guard on leaving
   stay in PR 2b, so navigating away still loses unsaved card edits.
   Inline create and expand-on-create (I11) are also 2b.
9. **The optional refactor step 0 was done in this PR:** the plain-field input
   renderer is `KilnCMSWeb.ContentEditor.PlainField`, shared by "Add new" and
   the card.
10. **The mock is `docs/plans/inline-reference-card-mock.html`.**
11. **The disclosure label is now "Edit the record"** (was "Show the record").
