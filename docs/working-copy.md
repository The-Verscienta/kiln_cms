# The working copy of a live document

A **published** page, post or entry keeps two texts. The one in the editor is
the *working copy*; the one readers get is the version you last published.
Typing into a live document moves the working copy alone. As soon as it runs
ahead of the published text, the state pill reads **Live · draft** and the
button beside it turns into **Publish changes**; the menu next to it offers
**Discard the changes**, which puts the published text back and keeps what you
threw away as a version.

Only the **title** and the **body** (the block tree) split. Tags, the slug, the
path alias, SEO fields, scheduling, the audience, custom fields and every
other setting have one state and go live on Save, which is what a version has
always held. Modelled on texttile's *Live · draft* behaviour.

## Using it

- **Type.** On a live document the title and the body autosave into the
  working copy, exactly as a draft autosaves into its row. The save line reads
  *Saved to the working copy*; readers see nothing.
- **Publish changes** hands the working copy over: same URL, same
  `published_at`, no workflow email. The subscriber mail belongs to the entry
  going out, not to a correction inside it. Everything derived from the text
  moves — search, embedding, fired artifacts, the `updated` webhook — and the
  version history marks this write as the one readers have.
- **Discard the changes** restores the published text in the editor. The
  discarded words stay in history as the last `save_working_copy` version;
  restoring that version brings the working copy back.
- **Save** on a live document writes the settings live, at once. It first
  flushes any text still waiting for the debounce into the working copy, so
  the settings write never carries the draft's title or body.
- The **signed-in preview** (`/editor/preview/…`) shows the working copy with a
  strip saying so. Signed out, the site shows what was published.
- The **content list** marks a live record whose copy has run ahead with
  *edited since publishing*.
- A **release** whose `:publish` item points at a live document with pending
  changes publishes those changes on go-live (it used to skip the item as
  "already in that state"); rolling the release back restores the text that was
  live before.

## Data model

Three columns on the published row itself — no shadow row, no `draft_of`:

| Column | Type | Meaning |
| --- | --- | --- |
| `working_title` | text | the draft title, `NULL` when nothing is pending |
| `working_blocks` | block union array, `[]` default | the draft body |
| `working_copy_at` | timestamp | **the sentinel**: set exactly while a copy is pending |

Why a pair of typed columns rather than one JSONB map: the block union's cast
sanitizes the working body on write exactly as it does the live one, and the
signed-in preview renders it. Why not a shadow row: every delivery read — the
JSON:API, the public site, search, feeds, sitemaps, the artifacts — already
reads `title` / `blocks` off the published row, and none of them had to change.
The columns are `public? false`, so no API surface can serve the draft.

`working_blocks` defaults to `[]` and is `NOT NULL`. `Ash.Type.Union`'s array
`prepare_change` walks the old value, so a nullable union array can never be
force-changed once it is `NULL`; `working_copy_at` carries the "is there one"
question instead.

**Invariant:** the columns are set only while `state == :published`.
`:save_working_copy` refuses any other state at the row (a compare-and-swap,
like `:autosave`'s `state == :draft`), `:publish_changes` and
`:discard_changes` clear them, and the retiring transitions fold them back in
(below). A draft never carries a stale shadow of itself.

**Migration and upcast.** `add_working_copy` adds the three columns. Existing
rows read as *nothing pending* — `NULL` stamp, `[]` body — so no data migration
and no upcast is needed; a deployment can roll the pin back and the columns
sit unused.

### What `published_version_id` becomes

It was "the PaperTrail version of the last publish". It is now **the version
whose fold is the text readers get**: the last `:publish`, `:publish_scheduled`
*or* `:publish_changes`. `Changes.RecordPublishedVersion` re-points it on each
of the three, `Changes.AnchorVersion` leaves those three to it, and the
history panel's *Live published* mark follows.

## Actions

| Action | On | Does |
| --- | --- | --- |
| `save_working_copy` | published | accepts `working_title` / `working_blocks`; `StampWorkingCopy` stamps `working_copy_at`, **or clears all three when the text saved equals the published text** — a copy exists only while it runs ahead. Coalesced with the draft autosave (`CoalesceAutosaveVersions`), `optimistic_lock`. |
| `publish_changes` | published + pending | `PromoteWorkingCopy` moves the copy into `title` / `blocks` at changeset-build time (so the alt-text and claim gates judge it, as on `:update`), then search text, embedding, oEmbed, `RecordPublishedVersion`, artifacts, `updated` webhook. No `published_at` change, no workflow email. `optimistic_lock` first: a stale struct fails rather than publishing yesterday's draft. |
| `discard_changes` | published + pending | clears the three columns; its own version row marks the discard. |
| `unpublish`, `unpublish_scheduled`, `archive`, `archive_scheduled` | published | `FoldWorkingCopy` folds a pending copy into `title` / `blocks` under a row lock, then `SetSearchText`. The author's latest words become the draft; the text that was live is still the version `published_version_id` pointed at. |

Permissions: `publish_changes` and `discard_changes` fall under the ordinary
editor write policy. Editing a live document's text was already an editor's to
do through Save, so this publishes nothing an editor could not already ship
that way; the admin-only gate stays on the first publish.

### Guards that learned about the second tree

- `EnforceFieldGrants` reads `working_title` / `working_blocks` as the `title`
  / `blocks` grant, and judges "changed" against the text the copy runs ahead
  of (`WorkingCopy.basis/1`), not the bare column — the editor posts the whole
  text on every save.
- `EnforceBlockFieldPolicy` and `ValidateFragmentReferences` check the working
  tree too, against the previous copy or the published tree, so
  `publish_changes` (possibly under an admin's actor) never promotes a tree
  nobody checked.
- `RestoreVersion` restores the three columns — that is how a discarded copy
  comes back — but only onto a published record; onto a draft they restore as
  empty.
- `VersionFields` reports `working_title` as a diff row, hides
  `working_blocks` and the stamp from the field rows (a second AST dump), and
  restores all three.

## The editor

`@record` stays the row. The form, the block children and the rich-text bodies
are built from `WorkingCopy.view/1` — the copy laid over the row — so a live
document edits its working copy and the first autosave cannot write the
published text back over it.

- `Session.mark_dirty/2` takes a scope: `:text` (title, blocks, block ops,
  rich-text pushes) schedules the working-copy autosave; `:settings` raises
  `@settings_dirty?` and waits for Save. The scope of a `validate` event comes
  from its `_target`; an unknown target counts as text, the side that
  autosaves.
- `do_autosave/1` submits `:save_working_copy` on a live document through a
  throwaway form whose data already carries the basis text, so the block
  sub-forms bind to existing blocks by index (an update per block, as the
  draft path binds to `blocks`) and an unchanged text registers as no change.
- Save on a live document flushes pending text into the copy, then submits
  `:update` **through a throwaway form on the row** with `title` / `blocks`
  dropped. Not through `@form`: its data is the working view, and `:update`'s
  pipeline reads the text it does not receive off `changeset.data` —
  `SetSearchText` would index the draft's words on the live row and the fired
  artifacts would carry them.
- *Publish changes* flushes first too, so what goes live is what is on screen.

## Not in this change

- **In-context editing** (`InContextEditLive`) and the write API's `PATCH`
  still edit a live document directly through `:update`; a pending working copy
  survives such an edit and *Publish changes* would then overwrite it.
- **Restoring an older version onto a live document** still goes live at once
  (and clears the copy, since the fold has none). Landing a restore in the
  working copy instead is a product decision this change does not make.
- **Comparing the working copy with the published text** — "what will Publish
  changes ship" — would be one more pick in the compare modal.
- **`AutoCompleteTasks`** runs on the first publish only.
