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
| custom fields | a dynamic type's whole schema lives there |
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

## Data model

Four columns on the published row itself — no shadow row, no `draft_of`:

| Column | Type | Meaning |
| --- | --- | --- |
| `working_title` | text | the draft title, `NULL` when nothing is pending |
| `working_blocks` | block union array, `[]` default | the draft body |
| `working_fields` | map, `{}` default | every other held field that differs from the live row, keyed by attribute name (`tag_ids` / `related_<type>_ids` for the links) |
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
`working_copy_every_field` (1.0) adds `working_fields`, `NOT NULL DEFAULT '{}'`,
so a row with a pending text copy keeps it and holds no fields. Existing
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
| `publish_changes` | published + pending | `PromoteWorkingCopy` moves the whole copy into the live columns and links at changeset-build time (so the alt-text and claim gates judge it, as on `:update`; held custom fields go back through the field registry), then the slug redirect, the slug / alias / URL checks again, search text, embedding, oEmbed, `RecordPublishedVersion`, artifacts, `updated` webhook. No `published_at` change, no workflow email. `optimistic_lock` first: a stale struct fails rather than publishing yesterday's draft. |
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

## Not in this change

- **In-context editing** (`InContextEditLive`) and the write API's `PATCH`
  still edit a live document directly through `:update` — kept on purpose: an
  integration writing through the API has no *Publish changes* step to wait
  for. A pending working copy survives such an edit, and *Publish changes*
  would then overwrite the fields the copy holds.
- **Restoring an older version onto a live document** still goes live at once
  (and clears the copy, since the fold has none). Landing a restore in the
  working copy instead is a product decision this change does not make.
- **Comparing the working copy with the published text** — "what will Publish
  changes ship" — would be one more pick in the compare modal.
- **`AutoCompleteTasks`** runs on the first publish only.
