# The working copy of a live document

A **published** page, post or entry keeps two versions of its content. The one
in the editor is the *working copy*; the one readers get is the version you
last published. Typing into a live document, and saving it, moves the working
copy alone. As soon as it runs
ahead of the published text, the state pill reads **Live · draft** and the
button beside it turns into **Publish changes**; the menu next to it offers
**Discard the changes**, which puts the published text back and keeps what you
threw away as a version.

Modelled on texttile's *Live · draft* behaviour.

## What the working copy holds

Everything a reader sees on, or about, the entry (#1815). Until 1.0 only the
title and the body split, and **Save draft** put every other field live at
once — so a release found nothing left to publish.

| Held until published | Why |
| --- | --- |
| title, body | the text |
| excerpt, SEO title / description / keywords, social image, canonical URL | the listing and search-result text |
| custom fields | a dynamic type's whole schema lives there. A held `:reference` value has no link edge until it is published, so *Linked from* and `incoming_links` show live references only (#1594) |
| category, featured image, tags, related content | what the page shows beside the body |
| slug, path alias, locale | the address; a held rename leaves its 301 when it goes live, so the old URL keeps working until the new one exists |

| Applied on Save | Why |
| --- | --- |
| audience, access passphrase | who may read the entry. A lock is a security decision; holding it back until someone also publishes text would leave the page open in the meantime |
| publish date, unpublish date, expiry action, review cadence | when the live entry changes state, not what it says; the schedulers read them off the row |
| an entry's content type | which type it is, not its content |

`KilnCMS.CMS.WorkingCopy` carries the same list, and is where it changes.

## Using it

- **Type.** On a live document the title and the body autosave into the
  working copy, exactly as a draft autosaves into its row. The save line reads
  *Saved to the working copy*; readers see nothing.
- **Publish changes** hands the whole working copy over: the text, the held
  settings, the tags and related content, at once. Same `published_at`, no
  workflow email. The subscriber mail belongs to the entry
  going out, not to a correction inside it. Everything derived from the text
  moves — search, embedding, fired artifacts, the `updated` webhook — and the
  version history marks this write as the one readers have.
- **Discard the changes** restores the published text in the editor. The
  discarded words stay in history as the last `save_working_copy` version;
  restoring that version brings the working copy back.
- **Save draft** on a live document never changes what readers see. It
  flushes any text still waiting for the debounce into the working copy, saves
  the held settings into it too, and applies the operational ones (audience,
  passphrase, schedule, lifecycle) — those only when one of them changed.
- **Publish changes** wants the settings saved first: with unsaved settings on
  screen it asks for a Save rather than publishing without them.
- The **signed-in preview** (`/editor/preview/…`) shows the working copy with a
  strip saying so. Signed out, the site shows what was published.
- The **content list** marks a live record whose copy has run ahead with
  *edited since publishing*.
- A **release** whose `:publish` item points at a live document with pending
  changes publishes those changes on go-live; the release page says
  *Live — publishes the saved changes*, or *Live, no unpublished changes —
  nothing to publish* when there are none. Rolling the release back restores
  the version that was live before (tags and related content are not in
  version history, so a rollback leaves them as the release set them).

## When the live page changes under a draft

An API `PATCH` or in-context editing still edits a live entry directly. If it
changes a field the saved draft also changed, *Publish changes* used to put
the draft's value over it without a word. It no longer does (#1815):

- When a field joins the draft, the draft records a fingerprint of the
  **live value it was based on** (`working_base`). The title and body are
  recorded when the draft starts.
- At publish time each held field is one of three things
  (`WorkingCopy.reconcile/1`):
  - the live value has not moved → the draft's value goes live, as before;
  - the draft never changed it (the title, carried along while only the body
    was edited) → whatever is live now stays;
  - **both moved** → a conflict.
- **In the editor**, *Publish changes* with a conflict opens a panel —
  *Someone changed the live page after you saved your draft* — listing the
  fields, each with *Keep the live version* / *Use mine* (or one choice for
  all). Nothing is published until every field has a choice. Custom fields
  are one row, *Custom fields*, with one choice for the whole map (see below).
  The editor
  needs to be looking at the current page: one opened before the API edit
  gets the usual "changed elsewhere, reload" banner first.
- **Custom fields: one conflict, per-key detail (#2294).** Custom fields are
  held, fingerprinted and resolved as a single whole-map key,
  `custom_fields`. That did not change: if both the draft and the live page
  moved *any* custom field, the panel shows one *Custom fields* row, and
  *Keep the live version* / *Use mine* applies to the entire map. There is
  no per-key merge, and a `resolve` map names `"custom_fields"`, never one
  custom key. What is new is display: beneath that row the panel lists each
  key whose draft value differs from live, with the field's label, an
  *Added* / *Removed* / *Changed* pill and the live and draft values (select
  labels, media filenames, reference titles). `WorkingCopy.custom_field_changes/1`
  computes it, draft against live only. Computed fields are left out, since the
  system writes them, not the editor, and when nothing is left (for example
  only computed values differ) no detail is drawn. Values are shown as stored,
  not masked, so an editor sees private keys here as they do in the form.
- **`:publish_changes`** takes the decisions as `resolve`
  (`%{"seo_title" => "theirs", "*" => "mine"}`); undecided conflicts refuse
  the publish with an error naming the fields.
- **A release** cannot ask anyone, so the item is **blocked**: the release
  page says *Live page changed since the draft — review before releasing*,
  counts it with the other blockers and withholds go-live. A scheduled
  go-live fails as a whole and changes nothing, the same contract as any
  other unpublishable item — it never skips the item (that would ship the
  release without the draft) and never promotes it (that would overwrite the
  newer live value). Resolve it with *Publish changes* in the editor, or
  remove the item.
- **Unpublishing or archiving** cannot ask either; a conflicting field keeps
  the live value, and the draft's value stays in history as the version that
  saved it.
- A draft saved before 1.0 recorded no bases; its fields promote as they
  always did. The fingerprint is a SHA-256 over the stored value; if it ever
  read differently after an upgrade, the result is a reported conflict, never
  a silent overwrite.

## Data model

Four columns on the published row itself — no shadow row, no `draft_of`:

| Column | Type | Meaning |
| --- | --- | --- |
| `working_title` | text | the draft title, `NULL` when nothing is pending |
| `working_blocks` | block union array, `[]` default | the draft body |
| `working_fields` | map, `{}` default | every other held field that differs from the live row, keyed by attribute name (`tag_ids` / `related_<type>_ids` for the links) |
| `working_base` | map, `{}` default | for each held key (`title`, `blocks`, a held field), a fingerprint of the live value the draft was based on — the lost-update guard |
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

**Migration and upcast.** `add_working_copy` adds the three columns;
`working_copy_every_field` (1.0) adds `working_fields` and `working_copy_base`
adds `working_base`, both `NOT NULL DEFAULT '{}'`, so a row with a pending text
copy keeps it, holds no fields, and has no recorded base (it promotes as it
always did). Existing
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
| `save_working_copy` | published | accepts `working_title` / `working_blocks`, and a `fields` map of held params in `:update`'s shape. `StageWorkingFields` judges `fields` with an unsubmitted `:update` changeset on the working view (custom-field coercion, slug derivation and the slug / alias / URL checks, field grants, tag merge verbs all run) plus a slug-uniqueness probe, and stores what differs from the live row; an absent key keeps what the copy held. `StampWorkingCopy` stamps `working_copy_at`, **or clears the copy when nothing in it differs from the live row** — a copy exists only while it runs ahead. Operational keys are refused. Coalesced with the draft autosave (`CoalesceAutosaveVersions`), `optimistic_lock`. |
| `publish_changes` | published + pending | `PromoteWorkingCopy` moves the whole copy into the live columns and links at changeset-build time (so the alt-text and claim gates judge it, as on `:update`; held custom fields go back through the field registry), then the slug redirect, the slug / alias / URL checks again, search text, embedding, oEmbed, `RecordPublishedVersion`, artifacts, `updated` webhook. No `published_at` change, no workflow email. `optimistic_lock` first: a stale struct fails rather than publishing yesterday's draft. A document trashed since the struct was loaded is refused too (`Changes.RefuseTrashed`, #2332): nothing goes live, nothing is fired, no `updated` follows the `deleted`. |
| `discard_changes` | published + pending | clears the four columns; its own version row marks the discard. |
| `unpublish`, `unpublish_scheduled`, `archive`, `archive_scheduled` | published | `FoldWorkingCopy` folds a pending copy — text, fields, links — into the row under a row lock, then `SetSearchText`. The author's latest version becomes the draft; what was live is still the version `published_version_id` pointed at. A held slug or alias claimed since is left at the live value rather than failing the transition. |

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
- `RestoreVersion` restores the four columns — that is how a discarded copy
  comes back — but only onto a published record; onto a draft they restore as
  empty.
- `VersionFields` reports `working_title` as a diff row, hides
  `working_blocks`, `working_fields` and the stamp from the field rows, and
  restores all four.
- `BustContentCache` skips `save_working_copy` and `discard_changes`: they
  write nothing a delivery read serves.
- The release console's batched readiness read selects `working_copy_at`; it
  used to select it out, so every live item read as "nothing to publish" on
  the console even with changes saved.

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
- Save on a live document flushes pending text into the copy, then splits the
  params (`WorkingCopy.split_params/2`): the held ones go to
  `:save_working_copy` as `fields`, the operational ones to `:update`, each
  **through a throwaway form on the row** and the second only when an
  operational value changed. Not through `@form`: its data is the working
  view, and `:update`'s pipeline reads what it does not receive off
  `changeset.data` — `SetSearchText` would index the draft's words on the live
  row and the fired artifacts would carry them.
- `@record` keeps the row's attributes (the lock version and live values
  every save is judged against), but its loaded tags and related content are
  the copy's (`WorkingCopy.with_held_relationships/2`), so the pickers show
  what the copy holds.
- *Publish changes* flushes first too, so what goes live is what is on screen.
- *Publish changes* is also where the **change severity** is asked
  ([json-api.md](json-api.md#change-severity-how-much-an-edit-matters)): saving
  a working copy and autosave write no live text and never prompt, but if the
  promotion would change a field the site lists as safety-relevant, the editor
  asks how much the change matters (critical / notable / routine) before it goes
  live, and the answer is stored on that publish's version.

## Comparing and restoring versions

Custom fields are first-class in the version panel (#2294). No API, migration
or setting changed; this is the editor only.

1. Open a document, open the history panel, tick two versions (or one against
   the current document) and choose *Compare selected*.
2. Under *Fields*, *Custom fields* lists each key on its own: the field's
   label (the raw key if its definition has been retired), an *Added* /
   *Removed* / *Changed* pill, and the value on each side as an editor would
   read it. A select shows its option labels, media shows the filename,
   a reference shows the target's title, rich text has its tags stripped and a
   group shows `Label: value` pairs (bounded). If you cannot read a media item
   or referenced record, the stored id is shown instead of a title.
3. Choose *Restore* on a version, either from the compare modal or from the
   history list. A **Restore this version?** dialog opens and nothing has been
   written yet. It shows what the document will look like against what is
   there now. This replaces the old browser "Restore content to this
   version?" prompt.
4. If the version stored custom keys that no definition declares any more, the
   dialog lists them under *These custom fields will be discarded*. A restore
   re-validates against today's definitions, so those values are dropped, not
   brought back. Blank values are not listed.
5. Choose *Restore this version* to apply it, or *Cancel*. If the restore
   would change nothing the dialog says *Restoring this version would not
   change anything.*

What can go wrong:

- *You can't restore versions of this content.* The role cannot run
  `:restore_version`.
- *Restoring a version requires full field access for this content type.* An
  editor with a field grant is refused restore outright (a restore rewrites
  every field), so no preview is offered.
- *That version changed since the preview. Review it again.* The document or
  the field definitions moved between the preview and the confirm; the dialog
  is redrawn with the fresh result and nothing was restored.
- A version that cannot be restored (a category or media item since deleted)
  opens the dialog with the reason and no confirm button.
- *Couldn't restore that version.* The history read failed.
- *This content changed elsewhere. Reload to get the latest before saving.*
  Someone saved, published, unpublished or archived the document after you
  opened it, so the restore was refused and nothing was written (#2532). The
  banner above the form pauses saving; your unsaved text stays in the form.
  Copy anything you need, choose **Reload latest**, then restore again from
  the reloaded history. If the document was moved to the trash meanwhile, the
  message is *This content was moved to the trash or deleted.* and the banner
  offers **Back to content** instead.

A restore also counts as a save for every other open editor: a tab that
loaded the document before the restore gets the same banner on its next save
instead of writing the old text back over it.

The preview and the restore run the same `KilnCMS.CMS.Changes.RestoreVersion.plan/3`,
so the preview cannot promise something the restore does not do. The preview
reads as the signed-in user and writes, notifies and records a severity for
nothing; only the confirm does.

## Shared fields across locales

With field-level localization (#1327, [localization workflows](localization-workflows.md)),
a translation's `:shared` fields are copied from the default-locale variant
when that variant publishes. The source's working copy is content like any
other, so a shared value saved there is held until *Publish changes*. A
translation's own pending copy is kept in step: the shared value is written
into `working_blocks` / `working_fields` as well as the live columns, and the
recorded base moves with it, so the copy is neither reverted by the next
*Publish changes* nor reported as a conflict.

## Not in this change

- **In-context editing** (`InContextEditLive`) and the write API's `PATCH`
  still edit a live document directly through `:update` — kept on purpose: an
  integration writing through the API has no *Publish changes* step to wait
  for. A pending working copy survives such an edit; the lost-update guard
  above stops *Publish changes* from overwriting it silently.
- **Restoring an older version onto a live document** still goes live at once
  (and clears the copy, since the fold has none). Landing a restore in the
  working copy instead is a product decision this change does not make.
- **Comparing the working copy with the published text** — "what will Publish
  changes ship" — would be one more pick in the compare modal.
- **`AutoCompleteTasks`** runs on the first publish only.
