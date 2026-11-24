# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="change-note-upgrade"></a>

- **Run `mix ash.migrate` for change notes (#3255).** The migration adds a nullable text column, `change_note`, to `posts_versions`, `entries_versions` and `pages_versions`, and `change_note_types` (a text array, default empty) to `site_editorial_settings`. No backfill: every existing version reads as an edit nobody explained. **Overlays** with their own content types run `MIX_ENV=dev mix ash.codegen` after the bump, which adds the column to each of their `*_versions` tables, as `change_severity` needed in 1.9.

<a id="edit-inline-option-upgrade"></a>

- **Run `mix ash.migrate` for the `edit_inline` column (#2283).** The migration adds one nullable boolean, `field_definitions.edit_inline`, with no default and no backfill. Nothing in an older release reads it, so the column can stay after a rollback.

## Added

<a id="edit-inline-option"></a>

- **A reference field can show a record card for each connected record (#2283).** In the fields admin, a top-level reference field has a new step 7, **Editing the linked records**, with a checkbox: **Let editors edit the related record here**. With it ticked, each connected record in the editor gets an **Edit the record** button under its row (**Hide the record** once open). It opens a card with the record's title and its plain fields (text, number, yes/no, date, URL and select fields), a note when it is a draft or has unpublished changes, and an **Open in the full editor** link. Other fields, such as media and rich text, are edited in the full editor, and the card says so. The card edits the record (see the next entry); the plan is in [docs/plans/inline-reference-editing-plan.md](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/plans/inline-reference-editing-plan.md).
  - **Who sees a card.** Only an editor who may change that record (the same check as the full editor, on its working copy once published) gets the button. A record the editor cannot read stays *Unavailable*; one they can read but not change has its row and no card. The server checks again when a card opens, so a forged request opens nothing, and a private field the editor's read grant hides is not shown.
  - **Limits.** At most 10 cards are open at once on one field (*Close a record before opening another.*). Nothing is read for a closed card.
  - **Stored as** `edit_inline`, a nullable boolean: off is nil, and an unticked box is stored as nil. It is cleared when the field's type changes away from a reference, and refused (*is only for a reference field of the record itself*) on a sub-field of a group, link field or flexible item. A field graduated to a join resource does not carry it.
  - **Outside the editor.** `GET /api/schema` reports `x-kiln-edit-inline: true` on such a field (absent when off), as an annotation for clients that build their own editor; the OpenAPI document in `docs/api/openapi.json` carries it. `mix kiln.fields.export` and `mix kiln.fields.import` (field sync) carry the flag with the field. No API reads or writes related records through the parent: write the related record at its own endpoint, then connect it.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place) and [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).

<a id="edit-inline-card-save"></a>

- **The record card edits the record, with its own Save (#2283, part 2a).** On a reference field with **Let editors edit the related record here** ticked, **Edit the record** now opens a card whose title and plain fields (text, number, yes/no, date, URL and select fields) are inputs. The card has its own **Save** button (labeled with the record's type, for example **Save Venue**), **Discard changes**, and a status chip: **Unsaved changes**, **Saved**, **Saved to the working copy**, **Error** or **Changed by someone else**. The related record is saved as its own write, as the signed-in editor, under that record's own permissions; the parent is never written through the card.
  - **Draft or published.** A draft record is updated in place (its row title in the field follows). A published record's edits go to its working copy, with the title as the working title: readers keep seeing the live text until that record's own **Publish changes**, and the chip says **Saved to the working copy**.
  - **Errors stay on the card.** A failed save shows *N problems on this record. Nothing was saved.*, the messages under the inputs they belong to, and moves focus to the first invalid input. A blank title is refused (*Give it a title.*). A record the editor may no longer change says *You can't change this record.* A field a condition hides on the card is not sent.
  - **Someone else changed it.** If the record was changed, published, unpublished or trashed after the card read it, the save writes nothing, the chip says **Changed by someone else**, and **Reload this record** discards the card's edits and reads the record again.
  - **Keyboard.** Enter in a card input saves the card (it does not submit the parent's form); Escape closes the card.
  - **Closing and leaving.** A card with unsaved edits cannot be closed (*Save or discard the changes to this record before closing it.*). Navigating away is guarded, and the parent's Save saves the card first (see the next entry).
  - **What the card shows.** The title is read-only for a type with a title template. A field the editor's grant does not allow is read-only, a private field their read grant hides is not shown, and a field a condition hides is not shown. If the parent field itself is read-only (a read-only grant, a held list or a localization lock), the card still opens but its inputs and Save are disabled. The record being edited never gets a card on its own field. Creating a record and opening its card on create is not part of this release.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place) and [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).


<a id="edit-inline-dirty-guard"></a>

- **Unsaved record-card edits now count as unsaved changes, and the parent's Save saves them first (#2283, part 2b).** A card with unsaved edits turns on the editor's unsaved-changes guard, so closing the tab, reloading, or following a link such as **← All content** asks first (*You have unsaved changes. Leave without saving?*). Saving or discarding the last dirty card turns the guard off again. The parent's own save indicator and autosave are not touched: editing another record is not an edit of this one. After a Save that saved cards first, the message says how many (*Saved. Also saved 2 related records.*).
  - **A dirty row stays put.** **Remove**, replacing a single reference by picking another record, and choosing another option in the dropdown are refused while the row's card has unsaved edits (*Save or discard the changes to this record before removing it.*), because the card, and what was typed in it, would go with the row. Save or discard first.
  - **Add new opens the card.** On a field with **Let editors edit the related record here** ticked, a record made with **Add new** (or by typing a title and choosing **Create**) opens its card at once, so the rest of its fields can be filled without leaving. The draft is created at the same moment as before, by the same click; only the card is new. If the editor may not change the new record, or ten cards are already open on the field, it stays a plain row.
  - **Save saves the cards first.** When the parent is saved (the Save button or a workflow step such as publish), every card with unsaved edits is saved before it, one at a time, in the order they are on screen. Each is its own save, with its own authorization, version and webhooks; there is no one transaction. The first card that fails stops the run: that card shows its errors, the parent is **not** saved and keeps what you typed, and a message says how many cards were saved (*Saved 1 related record, but couldn't save “Title”, so this record was not saved.*). Cards already saved stay saved. Fix the card and save again: only the cards still unsaved run. A card that does not answer within 20 seconds counts as a failure.
  - **Not yet.** The limit of 10 open cards is still counted per field, not across the whole form. The draft autosave and *Move to trash* do not save cards.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place).

<a id="change-note"></a>

- **An edit can say why, and the editor can ask (#3255).** Versions recorded what changed and who changed it; now they can record why.
  - **Everywhere a note can be given.** `:update`, `:publish`, `:publish_changes` and `:restore_version` take an optional `change_note` (plain text, up to 2000 characters, trimmed; blank is none): over JSON:API (`change_note` attribute on `PATCH` and the publish route), GraphQL (`update*` / `publish*` mutations), MCP (`update_page` / `update_post` / `update_entry`) and in code. It lands on that edit's version row (`change_note`), and the editor's History shows *Why: …* under the version.
  - **Asking for one.** The Safety fields page (`/editor/safety-fields`) has an **Ask why on every change** checkbox per content type (stored as `change_note_types` on the site's editorial settings). For a listed type the editor shows **Why this change?** under the action bar; a draft's **Save** and **Publish changes** are refused until it is filled in (*Say why you made this change, then save again.*), and the note is cleared once the write lands. A published record's working-copy saves (and autosaves) take no note: the change readers see is Publish changes, which does.
  - **Only the editor asks.** The API, MCP, the reverse field, inline record cards, scheduled publishes and internal jobs are never refused for leaving a note out, the same posture change severity takes: a surface that cannot ask must not fail for it.
  - **In code.** `KilnCMS.CMS.ChangeNotes` (`required?/2`, `normalize/1`), `Changes.RecordChangeNote` (into `paper_trail_metadata`, before `RecordChangeSeverity`), and the `require_change_note` context marker for a caller that does ask.

<a id="flexible-media-reference"></a>

- **An item of a Flexible content field can hold a single image (Media) or a link to one record (Reference), picked inside the item's card (#2282).**
  - **Admin.** A sub-field under an item type offers the kinds **Media** and
    **Reference**; a reference asks which types it **Links to** and has no
    cap, delete rule, reverse side or details. Plain groups don't take them
    yet.
  - **Editor.** The card shows the image picker and the record search at any
    nesting depth. What is saved is the same snapshot a top-level field keeps,
    rebuilt from the record on every save (a snapshot sent by a client is
    never trusted); a record the editor cannot read is refused at the item's
    path (`sections[0].cta`).
  - **Everywhere else.** A reader who cannot see the record gets `null` where
    its snapshot was, in the API and in the fired `:json` artifact; a renamed
    target, a re-processed image and a duplicate or locale copy all re-resolve
    inside items; `mix kiln.media.resnapshot` re-takes the images inside them.
    A reference inside an item is `on_target_delete: :keep` and uncapped; its
    edge is keyed by the definition path (`sections.hero.cta`), with no
    migration. The SQL reporting views already cut such a reference to
    `{id, type}` (#3057).
  - **Rollback.** The previous release rejects any object in an item's
    sub-field, so re-saving a record that holds an item image or reference
    there fails validation (reads work). Roll forward, or delete the
    sub-field.
  Record: [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md#media-and-reference-inside-items-pr-3-2282);
  guide: [Build flexible content in the admin](../extending-content.md#build-flexible-content-in-the-admin).

<a id="flexible-item-type-grants"></a>

- **A role can be granted single item types of a Flexible content field (#2282).**
  - **The entry.** `custom_fields.<field>.<item type>` in a type's write grants
    (for example `custom_fields.sections.hero`). The editor may edit the items
    of that type (any of their sub-fields, settings and nested items), add
    items of that type and remove them. The whole-field entry
    (`custom_fields.sections`) still covers everything.
  - **What stays refused.** An item of another type is untouched: changing,
    adding or removing one is refused, naming the type
    (`custom_fields.sections.quote cannot be changed: outside your field
    grant…`). An item whose type changes needs both types. Putting the
    surviving items in a different order needs the whole-field entry, because
    it moves items of every type. Items are matched by their `_id`, so
    inserting an item in the middle is not a reorder.
  - **Pickers.** In **Field grants** on the team page, a flexible field lists
    its item types beneath it, indented as a group's sub-fields are. A stored
    entry for a type that no longer exists shows as "(not found)".
  - **Copies and imports.** A duplicate, a translation and an import made by
    such an editor carry the items of the granted types only; the field is
    listed among the withheld keys when any item was left out.
  - **The console.** As for a group with only sub-field entries, the editor
    shows the field read-only unless the whole field is granted. The grant is
    enforced on every write path (API, forms, imports), so a client that
    writes the field works within it; editing the permitted items in the
    console is a follow-up.
  - **No migration.** A grant is an entry in the existing `field_grants` list.
    Before this release the entry was accepted but matched nothing, so an
    editor holding it was refused every write to the field; a role that
    already holds one now writes what it names.
  Record: [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md#item-type-grants-pr-4-2282);
  guide: [Field grants](../granular-rbac.md#write-field_grants-keys).
