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

<a id="section-layout-sweep-upgrade"></a>

- **About 10 minutes after boot, a job deletes the section layouts no field carries, the rows 1.9.x and 1.10.x left behind (#3060). Nothing to do; rolling back is safe, and what it deleted stays deleted.**
  A section's layout (its tab, fieldset or accordion setting, a
  `KilnCMS.CMS.FieldSection` row) is meant to go with the section's last
  field, and since 1.11.0 every field write deletes it. Rows an older
  release left behind stayed, and a field later filed under the same section
  name took the old layout on. `KilnCMS.CMS.SectionLayoutSweep` deletes them:
  - **When.** Each boot queues it on the `default` queue, 10 minutes out,
    deduplicated for a day. It is idempotent: a second run finds nothing.
  - **What.** On every site, each layout whose section name no top-level
    field of its type is filed under. A field of a type this release does not
    register (a removed plugin's) still counts as carrying its section, and
    the layouts of a compiled type this release does not register are left
    alone and counted as `skipped`.
  - **Logged.** Each deleted layout is logged at info, with its site, type,
    name, `display` and `initially`, so you can recreate one in the fields
    admin's **Sections of** panel. A run that deleted something logs a
    summary line, `section layout sweep: 2 pruned, 0 skipped (unknown type), 0 failed`.
  - **Safe against a concurrent edit.** Each layout is checked again for a
    field, under a lock, just before it is deleted, so a field an admin files
    under that section meanwhile keeps its layout. A layout someone else
    deleted first is not a failure.
  - **Failures.** A type whose fields or layouts can't be read, or one of
    whose layouts can't be deleted, is logged at warning and counted under
    `failed`; the sweep goes on to the next type, and the job ends in error so
    Oban retries it, up to 3 attempts. A layout row this release cannot load
    (one a newer release wrote, after a rollback) fails its type on every
    run, by design: the sweep can't tell what it would delete.
  - **By hand,** for example after restoring an older backup. On the running
    node, list first, then delete; `org_id: "<uuid>"` limits it to one site:

    ```bash
    bin/kiln_cms rpc 'KilnCMS.Release.prune_section_layouts(dry_run: true)'
    bin/kiln_cms rpc 'KilnCMS.Release.prune_section_layouts()'
    ```

    Each layout is printed (`Would delete "Clinical" of {:compiled, :post} in org … (display: tab, initially: auto)`),
    then `Section layouts: 1 pruned, 0 skipped (unknown type), 0 failed`.
    Use `rpc`, not `eval`: each delete clears the type registry and delivery
    schema caches of the serving node, and under `eval` the call refuses.
  - **Turn it off** with `config :kiln_cms, :section_layout_sweep_on_boot, false`.
  - **Rolling back** is safe: the job only deletes rows nothing used. They
    are not restored.
  The job can be removed in the next major release, once no supported
  upgrade starts at 1.10.x or earlier.
  See [Remove section layouts older releases left behind](../extending-content.md#remove-section-layouts-older-releases-left-behind).

## Added

<a id="reference-picker-thumbnails"></a>

- **The reference picker shows each record's featured image as a thumbnail (#3223).** Every search result, every picked row and every row of a reverse field now shows a small (32 px) thumbnail of the record's **Featured image**, so records with similar titles are easy to tell apart. It is always on; there is no setting per field.
  - **Which image.** The image's generated `thumb` variant, or a video's poster frame. An image 400 px wide or narrower has no `thumb` (variants never upscale), so the picker shows the original, which is already that small. It never loads a larger original, so a record shows no thumbnail when a wider featured image has no `thumb` variant (uploaded or processed without variants). An admin's **Regenerate variants** on `/media` writes the missing ones. A featured image in the trash shows none.
  - **Layout.** When some rows of a list have a thumbnail, the rows without one keep an empty square of the same size so the titles line up. A list where no row has one, as on a site that uses no featured images, looks as it did before.
  - **Accessibility.** The thumbnail is decorative (`alt=""`, `aria-hidden`): the options' and rows' accessible names, roles and keyboard behavior are unchanged.
  - **Cost.** The featured image is loaded with the read that lists the records, as the editor: one more query per type the picker reads, not one per record.
  - **For developers.** The media library's thumbnail rule is now public as `KilnCMSWeb.MediaComponents.thumb_src/2` (pass `fallback: false` to skip the fallback to an original wider than the `thumb` variant; `KilnCMS.ImageProcessor.thumb_width/0` is that width), and `KilnCMS.CMS.ReverseFields.rows/3` takes a `:load` option, loaded on each source record as the caller. No migration, no configuration, nothing to do to upgrade.
  - Guide: **Thumbnails in the picker** under the reference field in [Extending content](../extending-content.md).

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
  - **What the card shows.** The title is read-only for a type with a title template. A field the editor's grant does not allow is read-only, a private field their read grant hides is not shown, and a field a condition hides is not shown. If the parent field itself is read-only (a read-only grant, a held list or a localization lock), the card still opens but its inputs and Save are disabled. The record being edited never gets a card on its own field.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place) and [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).


<a id="edit-inline-dirty-guard"></a>

- **Unsaved record-card edits now count as unsaved changes, and the parent's Save saves them first (#2283, part 2b).** A card with unsaved edits turns on the editor's unsaved-changes guard, so closing the tab, reloading, or following a link such as **← All content** asks first (*You have unsaved changes. Leave without saving?*). Saving or discarding the last dirty card turns the guard off again. The parent's own save indicator and autosave are not touched: editing another record is not an edit of this one. After a Save that saved cards first, the message says how many (*Saved. Also saved 2 related records.*).
  - **A dirty row stays put.** **Remove**, replacing a single reference by picking another record, and choosing another option in the dropdown are refused while the row's card has unsaved edits (*Save or discard the changes to this record before removing it.*), because the card, and what was typed in it, would go with the row. Save or discard first.
  - **Add new opens the card.** On a field with **Let editors edit the related record here** ticked, a record made with **Add new** (or by typing a title and choosing **Create**) opens its card at once, so the rest of its fields can be filled without leaving. The draft is created at the same moment as before, by the same click; only the card is new. If the editor may not change the new record, or ten cards are already open on the field, it stays a plain row.
  - **Save saves the cards first.** When the parent is saved (the Save button or a workflow step such as publish), every card with unsaved edits is saved before it, one at a time, in the order they are on screen. Each is its own save, with its own authorization, version and webhooks; there is no one transaction. The first card that fails stops the run: that card shows its errors, the parent is **not** saved and keeps what you typed, and a message says how many cards were saved (*Saved 1 related record, but couldn't save “Title”, so this record was not saved.*). Cards already saved stay saved. Fix the card and save again: only the cards still unsaved run. A card that does not answer within 20 seconds counts as a failure.
  - **Not yet.** The limit of 10 open cards is still counted per field, not across the whole form. The draft autosave and *Move to trash* do not save cards.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place).

<a id="reference-add-new-off"></a>

- **A reference field can turn off the picker's "Add new" (#3222).** In the fields admin, step 6 (**Which records can be picked**) has a new checkbox, **Offer “Add new” in the picker**, ticked by default. Untick it and the field's picker offers no **Add new *Type*** and no create-on-type row: editors connect only records that already exist. Use it where a record made from a picker would be a thin draft, such as a catalogue whose records need their own fields filled in before they mean anything.
  - **Both sides.** The reverse field on each target turns its **Add new** off too, so the relationship makes no new records from either side.
  - **Stored as** `"add_new": false` in the field's `selection` (#2285); only the off value is stored, so a field that never changes it keeps the selection it had. `"add_new"` must be `true` or `false`, and `false` beside `"create"` is refused (*create needs add_new*); unticking the box in the admin clears create-on-type for you.
  - **Not a filter, not access control.** It narrows no read: the search lists what it did before. An editor who may create the type can still create the record from its own screen. The server checks it too, so a forged create event from the picker creates nothing.
  - **Outside the editor.** `GET /api/schema` reports it in `x-kiln-selection` when off; field sync carries it with the rest of `selection`. No migration.

<a id="reference-picker-filters"></a>

- **Editors can narrow a reference field's search by type, category or tag while picking (#3224).** A row of selects now sits above the picker's search box. **Type** (*All types*, then each linked type) shows on its own on any field that links to more than one content type. **Category** (*Any category*) and **Tag** (*Any tag*, grouped by tag group) show on a field whose admin turns them on: in the fields admin, step 6 (**Which records can be picked**) has a new **Let editors narrow the search by** with **Category** and **Tag** checkboxes, and the step's closing sentence adds *Editors can narrow the search by category and tag.* A screen reader announces a filtered count as *N results (filtered)*, and an empty list says *No matches with these filters.* with a **Clear filters** button.
  - **A filter only narrows.** The choice is AND-ed onto the field's own selection and the search still runs as the editor, so it never offers a record the field would refuse or the editor can't read. A posted value the picker did not offer (another site's category, a type the field doesn't link to) is ignored. Changing a select does not mark the document as changed.
  - **What is left out.** When every linked type pins a category, there is no category select; when every linked type lists tags, only those tags are offered. Past 500 categories or tags, that select is not shown (*Too many tags to list — search by title instead.*), and the fields admin warns when the box is ticked. Create-on-type is not offered while a filter is set; **Add new** is. The dropdown widget has no filters.
  - **Stored as** `"filters": ["category", "tag"]` (either or both) in the field's `selection` (#2285). It is a picker setting like `sort`, not a condition: it never refuses a write. A bad value is refused with *filters is empty*, *lists a filter twice* or *filters must be a list among category, tag*. `GET /api/schema` reports it in `x-kiln-selection`. Field sync does not carry it, as it carries no part of `selection`. No migration.
  - See [Narrow a reference search by type, category or tag](../extending-content.md#narrow-a-reference-search-by-type-category-or-tag).

<a id="change-note"></a>

- **An edit can say why, and the editor can ask (#3255).** Versions recorded what changed and who changed it; now they can record why.
  - **Everywhere a note can be given.** `:update`, `:publish`, `:publish_changes` and `:restore_version` take an optional `change_note` (plain text, up to 2000 characters, trimmed; blank is none): over JSON:API (`change_note` attribute on `PATCH` and the publish route), GraphQL (`update*` / `publish*` mutations), MCP (`update_page` / `update_post` / `update_entry`) and in code. It lands on that edit's version row (`change_note`), and the editor's History shows *Why: …* under the version.
  - **Asking for one.** The Safety fields page (`/editor/safety-fields`) has an **Ask why on every change** checkbox per content type (stored as `change_note_types` on the site's editorial settings). For a listed type the editor shows **Why this change?** under the action bar; a draft's **Save** and **Publish changes** are refused until it is filled in (*Say why you made this change, then save again.*), and the note is cleared once the write lands. A published record's working-copy saves (and autosaves) take no note: the change readers see is Publish changes, which does.
  - **Only the editor asks.** The API, MCP, the reverse field, inline record cards, scheduled publishes and internal jobs are never refused for leaving a note out, the same posture change severity takes: a surface that cannot ask must not fail for it.
  - **In code.** `KilnCMS.CMS.ChangeNotes` (`required?/2`, `normalize/1`), `Changes.RecordChangeNote` (into `paper_trail_metadata`, before `RecordChangeSeverity`), and the `require_change_note` context marker for a caller that does ask.

<a id="reverse-link-edit"></a>

- **A connection's link fields can be edited from the reverse field (#3243).** On a record's reverse field (R4, "Recipes using this ingredient") whose reference has link fields (R3), each row the editor may change offers **Edit details**. It opens the connection's link-field inputs under the row, filled from the source's working copy, so a pending change is what the edit starts from, with **Save details** and **Cancel**. One row edits at a time.
  - **An edit of the source.** Save is the same write as connecting or disconnecting from this side (R4b, D23): the source's own update as the editor, or a save of its working copy when it is published (the row then says *Saved to the working copy of “Source”*). Its policies, validations, history and optimistic lock apply, and a failure stays on that row.
  - **What is written.** Only the reference's own link fields. A value left out keeps what the connection stored; an emptied input clears it. Nothing is written when nothing changed. If the source no longer connects to this record, the save is refused (*“Source” no longer connects to this record.*).
  - **Who.** A row whose source the editor may not change shows its lock and no **Edit details**; the server checks again, so a forged event writes nothing.
  - **In code.** `KilnCMS.CMS.ReverseFields.set_link/5` and `link_values/3`. The inputs are named under `_kiln_reverse_link`, outside the editor form's params, so typing in them never changes the record being edited. No migration.

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

<a id="flexible-typed-export"></a>

- **A Flexible content field is typed end to end: in GraphQL as `FlexibleItemValue`, and in the schema export as a `oneOf` union of closed item types for JSON Schema, OpenAPI, TypeScript, Swift, Kotlin and `kiln-types` (#2282).**
  - **GraphQL.** A flexible field stays a `ListValue`; each element is one `FlexibleItemValue { name id type settings fields }` (a `CustomFieldValue`, as `GroupValue` is). `type` is the item type's name, `settings` holds the item type's setting sub-fields and `fields` the rest, each a `CustomFieldValue`. An item whose `_type` the site no longer defines (an orphan, left in an older revision) is left out of the list. Nesting follows the definitions' own cap of three flexible levels. A flexible item's `settings` and `fields` are priced as unlimited lists, like a group's rows, under `max_complexity`.
  - **The schema export (`GET /api/schema`, `mix kiln.export.schema`).** Each flexible field's `items` is a `$ref` to a union def named `flex_<type>_<field>` in `$defs`, whose members are `flex_*` defs, one per item type, told apart by `_type` (a `discriminator` with an explicit `mapping` in OpenAPI). A member is closed (`additionalProperties: false`), requires only `_id` and `_type`, and carries `_settings` only when the item type has settings. A per-type item cap is the annotation `x-kiln-max-items` on the member. The union def carries `x-kiln-flexible` (`content_type`, `field`, `path`): a def name is a label that gets a `_2` suffix when two paths collide, so read that annotation, never the name. The `flex_` prefix is reserved in `$defs`. A field with no item types yet stays `{"type": "object"}`.
  - **Generated types.** TypeScript and `kiln-types` emit an interface per item type and a union alias per field; Swift an enum with an `.unknown` case and Kotlin a sealed interface with an `Unknown` class, so an item type added after you generated still decodes. The typed GraphQL formats select a flexible item one level deep (`... on FlexibleItemValue { id type settings { … } fields { … } }`), not through a nested flexible field or group, and a `FlexibleItemValue` case joins the Swift and Kotlin `CustomFieldValue` types. The generated fragment selects scalar parts only: an image or reference inside an item is not fetched by it.
  - **Type definitions over JSON:API.** `?include=field_definitions.item_types` now works, with `.group_fields` after it, down to the three flexible levels a definition may nest; a deeper path is a `400` (`invalid_includes`).
  - **Upgrade for validating consumers.** The schema is tighter: a flexible field's `items` was `{"type": "object"}` and is now a `$ref` to the union, so a validator or generated client that checked items as any object now checks `_type` and the item type's keys, and refuses an unknown key. Regenerate generated clients and commit the diff. Flexible content is still unreleased as a feature (its admin and editor entry is held until the plan's last PR; 1.11 shipped only the API-level model), so this is not counted as a break of a 1.x contract. There is no migration and no data change, and the `kiln_reporting_v1` views are untouched.
  - **Known gap.** `fields(names:)` prices every name at the whole selection, and that selection was already over the default `max_complexity` of 200 before flexible items: one `multiple` string field in a generated fragment costs 631, and a flexible field 1241. The generated fragments therefore only run against a raised cap. This predates the change and is left as a follow-up; no test pins the generated fragment's complexity.
  Record: [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md#the-typed-export-pr-5-2282);
  guides: [GraphQL: generate types and fragments](../headless-graphql-api.md#generate-types-and-fragments-for-your-site), [api.md: schema discovery](../api.md#schema-discovery-typed-clients).


## Changed

<a id="form-field-locale-reserved"></a>

- **A form field can no longer be named `locale`: it is the param a submission's language is recorded from, so a visitor's answer to such a field was also recorded as the submission's language (#2716).**
  - **What changed.** `locale` joins the honeypot's `website` as a reserved machine name, refused on every field type when a field is added, renamed or has its type changed, with *is reserved for the submission's language* on `name`. A duplicated field never takes it either (`email_2`-style naming skips reserved names).
  - **A field that already has the name keeps working.** The form renders it, the answer is stored with the entry, and `GET /api/forms/<slug>` lists it; until the field is renamed, the answer is also recorded as the submission's `locale`, as before. Label, order, **Required** and other edits still save, but the builder shows **Reserved name** under the field on the preview and a note under **Machine name**, and its **Type** can't be changed until it is renamed. **Admins:** open each form in the builder and rename any flagged field ([Fix a field named locale](../forms.md#fix-a-field-named-locale)).
  - **Form duplicate.** The copy of such a field is named `locale_2` (or the next free name), the copy's `[field:locale]` autoresponder tokens follow, and the message says why. The original is not changed.
  - **Headless clients and the SDKs are unchanged.** A body `locale` still means the submission's language, so `submitForm` / `submit_form`'s `locale` option keeps working. `FormField` has no JSON:API, GraphQL or MCP write surface; only code that calls `KilnCMS.CMS.create_form_field` / `update_form_field` with that name (a seed, an overlay, Ash Admin in development) sees the new refusal.
  - **For developers.** `KilnCMS.Forms.reserved_field_names/0` now returns `["website", "locale"]`, and the new `KilnCMS.Forms.reserved_field_reason/1` says which reason applies (`:honeypot`, `:locale` or `nil`). No migration.

<a id="field-section-create-needs-a-carrier"></a>

- **A section layout can only be created for a section some top-level field of its type is in (#3061).**
  - **What changed.** `KilnCMS.CMS.FieldSection`'s `:create` (the
    `KilnCMS.CMS.create_field_section/2` code interface) now refuses a
    `name` no top-level field of the same content type or type definition,
    in the same site, is filed under. A link field, a group sub-field or a
    flexible item type's field does not count; a field of a type this
    release does not register does. The check runs after the action's
    policy, inside its transaction, so a caller the policy refuses still gets
    `Ash.Error.Forbidden` and reads nothing.
  - **Why.** A layout with no field is not harmless: the next field filed
    under that name inherits it. Every field write already deletes the
    layouts it leaves empty; this closes the other way in.
  - **Who sees it.** Only code that calls `create_field_section` directly (a
    seed, an overlay, iex, Ash Admin in development). The fields admin only
    offers sections that fields carry, and `FieldSection` has no JSON:API,
    GraphQL or MCP surface. Create the field first, then its section's
    layout. The refusal is `{:error, %Ash.Error.Invalid{}}` holding an
    `Ash.Error.Changes.InvalidAttribute` on `:name`: *is not a section any
    top-level field of this type is in*, or *could not be checked against
    the type's fields* when the field read failed. `:update` still accepts
    only `display` and `initially`, so an existing row's name and type can't
    be changed.
  - **Field sync.** An import now writes an owner's fields before its
    sections, so a file that adds a section's first field and its layout
    together still imports. An entry for a section no field carries was
    already refused at plan time.
  No migration, no configuration.

## Fixed

<a id="theme-script-everywhere"></a>

- **The light/dark theme now applies on form answers and newsletter pages, and survives blocked browser storage (#2715, #2773).**
  - **Form and newsletter pages (#2715).** The on-site answers to a form
    submission (the thank-you page, the 404 for an unknown or inactive form,
    and the 422 re-render of a refused submission) and the `/newsletter`
    sign-up answer and unsubscribe pages render the site's layout, whose
    inline script sets the theme before first paint. Their pipeline,
    `:public_form`, sent a static Content-Security-Policy with no nonce, so
    the browser refused that script and these pages always rendered light,
    whatever the visitor's system setting or chosen theme. The pipeline now
    sends the same per-request nonce policy as the rest of the site
    (`script-src 'self' 'nonce-…'`). A form that shows a human-verification
    widget still widens `script-src` with the provider on the re-render, and
    keeps the nonce. An embedded form's iframe still gets its own embed
    policy, and `POST /api/forms/:slug` still answers JSON; only its CSP
    header value changes. None of these pages is cached by a shared cache,
    so a nonce is never replayed. The newsletter confirm page already ran
    under the browser pipeline and was not affected.
  - **Blocked storage (#2773).** With site data blocked (Chrome's
    `localStorage` getter throws), storage turned off (Firefox's is `null`),
    or a full store, the layout's theme script stopped part-way and LiveView
    never started, because its constructor reads both stores: the console
    did not load. Every storage call in the theme script is now guarded, and
    `app.js` hands LiveView a store that falls back to memory for the page
    view (`assets/js/safe_storage.js`). The page takes the system theme, the
    theme switch and the sidebar and nav-section toggles work, and none of
    those choices is remembered on the next page load.
  No migration, no configuration.
  ([#2715](https://github.com/The-Verscienta/kiln_cms/issues/2715), [#2773](https://github.com/The-Verscienta/kiln_cms/issues/2773))

<a id="form-reorder-duplicate-all-or-nothing"></a>

- **Reordering a form's fields in the builder, and duplicating a form, are now all-or-nothing: a refused write rolls everything back, and the message names the field to fix (#2717).**
  - **Reorder.** Dragging a field wrote one position per moved field and threw the results away, so a refused write left half the new order saved, the preview showing an order that wasn't, and no message. Now every position is saved in one transaction. If one is refused, none is: the preview goes back to the saved order, and the message reads *Couldn't save the new order, so nothing was moved. Fix the field “topic” and try again: …* with the field's error.
  - **Duplicate.** The copy and each of its fields were separate saves, so a field that failed was dropped from a copy that was kept, with its autoresponder sometimes left off. Now the copy, its fields, its renamed tokens and its autoresponder switch are one transaction: a refused field leaves no copy at all, and the message reads *Couldn't duplicate “Contact”, so nothing was created. Fix the field “topic” in this form and try again: …*.
  - **Behavior change.** A field an older release let through with a setting Kiln now refuses (a dropdown saved with no options, say) now blocks every reorder that moves it, and refuses the whole duplicate where it used to be left out of the copy. Fix the named field in the original's builder and try again ([Reorder fields and copy a field](../forms.md#reorder-fields-and-copy-a-field), [Duplicate a form](../forms.md#duplicate-a-form)).
  - **The copy's autoresponder.** It still follows the original's. When the original's is on but its template names a field the original no longer has, the copy is made with its autoresponder off and the message lists the unknown tokens; when the subject or body is blank, the message says to fill both in.
  - **Clearer messages.** The Forms page's flashes no longer show a raw `%{value}` placeholder, `field message` pairs such as `autoresponder_body …`, or Splode's "Bread Crumbs" call path. The bread-crumb fix is in the console's shared error formatting (`ash_error_message/2`), so it applies wherever the console shows an Ash error. The **Duplicate** tooltip now adds *copies its settings and fields; its entries stay with the original.*
  - **Duplicating a field in the builder** now gives the copy its own place right after its original; it used to share the original's position.
  - **For developers.** The logic moved out of the LiveViews into `KilnCMS.Forms.Duplicate.run/2` and `KilnCMS.Forms.FieldOrder.reorder/3`, which run as the acting user (admin-only, as before) and return `{:error, {:field, name_or_field, error}}` for a refused field. `KilnCMS.CMS.Changes.BustFormCache` now busts through `KilnCMS.AfterCommit.run/1`, so a form write inside an outer transaction busts the delivery cache only once it commits. No migration.


<a id="content-list-saved-view-matching"></a>

- **A saved view that lost something it named is current only when you open it, so its message and its Rename / Delete bar no longer follow you to other lists, and the field-filter builder never drops a repeated condition (#2785, #2741).**
  - **Saved views (#2785).** A view is re-read under today's fields, types,
    locales and sorts. When that re-read dropped something (a field condition
    or field sort on a field since deleted, made private or retyped, a locale
    no longer configured, a content type that is gone, or a built-in sort or
    consent kind no longer offered), what was left could equal another list:
    the plain list for a view whose only condition was lost, or the list any
    editor filtered by hand to the conditions it still had. Every load of that
    list then showed *The view "…" named a field that no longer applies, so
    that condition was left out.*, marked the view as current and showed its
    Rename / Delete bar. A shared view did this for every editor on the site.
    Such a view now links to the params it was saved with (cleaned the way a
    saved view's params are), and is the view on screen only when the URL
    carries exactly those; the list still applies only what exists. Opened
    that way it is current even when a built-in view or another saved view
    would match what is left, so its bar shows and **Save view** stays
    hidden. The message still shows only for a lost field condition or field
    sort. A view that lost nothing matches as before, by what it applies, and
    a deleted category or tag is not a loss (the view keeps its id). Stored
    views are not rewritten.
  - **Field-filter builder (#2741).** `KilnCMS.CMS.ListFieldQuery.arguments/3`
    put two conditions with the same field and API operator in one map key,
    so the second silently replaced the first. The content list never sends
    two: it keeps one condition per field and condition (adding the same
    field and condition again replaces the earlier one, and a hand-edited
    `cf` keeps the first), so nothing changes on screen. The builder now
    keeps the first in the field's map and puts each later one in a
    top-level `_and` group, so every condition it is given applies whoever
    calls it; an exact repeat is dropped. Whether the list itself should AND
    two values of one field and condition is an open question (#3277).
  No migration, no configuration.
  ([#2785](https://github.com/The-Verscienta/kiln_cms/issues/2785), [#2741](https://github.com/The-Verscienta/kiln_cms/issues/2741))


<a id="collab-writeback-corrupt-state"></a>

- **Collaborative editing: prose typed after a quick rejoin now reaches the record, and a stored room state that won't decode no longer breaks the document (#2756).**
  - **Who is affected.** Only deployments that turned the `:collab_prototype` flag on. A production build pins it off (`config/prod.exs`), so a default install is not affected.
  - **The write-back.** When the last editor leaves a room, or the server shuts down, the room writes its converged prose back into the draft's rich-text blocks. Whether that write was pending was decided by the same check that schedules the 15-second checkpoint to `collab_doc_states`, so a client who rejoined before the previous checkpoint had run, typed, and then left (or was still attached at a deploy) left that prose in `collab_doc_states` and never in the record's blocks. Every update now marks the write-back pending on its own. While editors are present, the elected client persister still saves as before.
  - **A corrupt stored state.** A `collab_doc_states` row that won't decode made every attach to that document fail: the editor got `unavailable`, and the room's next checkpoint would have overwritten bytes that may hold prose no record has. Now the row is applied to a fresh document and, if that fails, renamed to `corrupt:<key>:<unix_ms>:<random>` instead of being applied or overwritten. The rename only takes the bytes that were read, and if another server has written a row under the real key in the meantime, that row is restored instead. Otherwise the room starts empty, the record's blocks are untouched, and the first editor to join seeds the room from the record.
  - **For operators.** Each quarantine is logged at error: `Collab doc state for <key> is corrupt and was not restored (<n> bytes: <reason>). The bytes were moved to corrupt:…`. When another server got there first, a warning says so. Quarantined rows stay for 30 days from the quarantine and are then removed by the existing prune. To list them: `SELECT doc_key, octet_length(state), updated_at FROM collab_doc_states WHERE doc_key LIKE 'corrupt:%'` (see [the collaborative editing spike](../collaborative-editing-spike.md), finding 7).
  No migration, no configuration. Rolling back is safe: an older release never reads the `corrupt:` rows, and its prune removes them after 30 days.
  ([#2756](https://github.com/The-Verscienta/kiln_cms/issues/2756))


<a id="public-page-weak-etag"></a>

- **Public pages carry a weak `ETag`, so they leave Kiln compressed and revalidate however a CDN or browser sends the tag back; a change to a site's slug or custom domain now moves its pages' `ETag`s and drops what was cached under its old URLs (#2766, #3194).**
  - **Compression (#2766).** A published page sent a strong `ETag` (`"…"`), and Bandit does not compress a response with a strong validator, so every shared-cacheable page went out uncompressed whatever the client's `Accept-Encoding`. The tag is now weak (`W/"…"`), which is also what it always was in fact: a digest of what the page is built from, not of its bytes. Pages are now gzipped (or `deflate`d) like the rest of the site's responses. Private responses (an experiment variant, a passphrase lock) still carry no `ETag`, and image variants keep their strong one.
  - **Revalidation (#2766).** `If-None-Match` was matched against the exact header value, so a tag sent back with a `W/` a compressing CDN had added, a tag inside a comma-separated list, or `*` never got a `304`. It now uses the weak comparison RFC 9110 requires, as the JSON APIs and fired artifacts already did: each of those forms gets a bodyless `304`, and any other tag gets the page.
  - **Slug or custom domain (#3194).** Canonical, hreflang and Open Graph URLs are built from the site's base URL, which was not part of the page's `ETag`, so after a site's custom domain or slug changed, a browser or CDN revalidating a page kept getting `304`s for the copy that named the old host. The `ETag` now names the base URL the page was rendered with. When an org's `slug` or `custom_domain` changes, Kiln also, once the save commits, drops the org's cached host lookups and its sitemaps and `llms.txt` on every node, moves its head generation, drops its feeds, and purges its CDN key when `KILN_CDN_PURGE_URL` is set. A save that changes neither field does none of this. Fired artifacts are not re-fired: a byline linking to another record keeps the old host until the document is next fired ([Change the slug or custom domain](../multi-tenancy.md#change-the-slug-or-custom-domain)).
  - **On upgrade.** Every page's `ETag` changes once, so each client or CDN holding a page gets one `200` in place of a `304` on its next revalidation. Nothing to do, and rolling the pin back costs the same one round of `200`s.
  - **For developers.** `KilnCMSWeb.Tenant.host_cache_keys/1` lists the host-cache keys an org can be cached under, and `KilnCMS.Accounts.Changes.BustSiteUrls` runs on `Organization :update`.
  No migration, no configuration.
  ([#2766](https://github.com/The-Verscienta/kiln_cms/issues/2766), [#3194](https://github.com/The-Verscienta/kiln_cms/issues/3194))



<a id="editor-unsaved-settings-kept"></a>

- **Content editor: unsaved Settings edits on a live page are no longer thrown away by the text autosave or by a button that reloads the form (#2776, #2777).**
  - **Who is affected.** Editors of a published page, post or entry. Its
    title and body autosave into the working copy, but every other field
    (the Settings tab, the category, tags, the featured image) waits for
    **Save draft**, and the save line reads *Unsaved changes* meanwhile.
  - **The text autosave (#2776).** Each autosave rebuilt the form from the
    saved record, so two seconds after you typed in the body, the settings
    you had changed reverted on screen while the editor still said they were
    unsaved, and a later **Save draft** posted the reverted values. Now the
    settings you changed are put back on the rebuilt form, stay on screen
    and unsaved, and **Save draft** saves them.
  - **Buttons that reload the form (#2777).** With unsaved settings,
    **Unpublish** and the other workflow buttons, **Move to trash**, **Mark
    reviewed** and choosing a new **Parent** rebuilt the form and dropped
    them without a word. Now they refuse, change nothing, and leave the
    edits on screen. Workflow buttons and the trash say *Save your changes
    before changing this content's state.*; Mark reviewed and Parent,
    which don't change the state, say the new *Save your changes first.*
    Mark reviewed and Parent now also save text still waiting for
    autosave first, as the workflow buttons already did, and are refused by
    what refuses those: unsaved edits on an in-review or archived document,
    or a save conflict. **Publish changes** already refused with
    *Save draft first, then publish your changes.*; the **Publish** in the
    lost-update panel and the change-severity question now refuse too.
    **Discard the changes** still discards, and now clears the unsaved
    marker with the edits, so a later **Publish changes** is no longer
    refused for edits that are gone.
  - The trash half of [#2336](https://github.com/The-Verscienta/kiln_cms/issues/2336) is
    this refusal; its link from the Trash section to the Trash page is still open.
  - See [The working copy](../working-copy.md#using-it), [Trash and
    restore](../trash.md#from-the-editor) and [Take content
    down](../take-content-down.md#unpublish-a-page-from-its-editor).
  No migration, no configuration. One new message, *Save your changes first.*,
  translated in `es` and `fr`.
  ([#2776](https://github.com/The-Verscienta/kiln_cms/issues/2776), [#2777](https://github.com/The-Verscienta/kiln_cms/issues/2777))

<a id="editor-peer-save-rebuild"></a>

- **Content editor: a co-editor's save is shown to an idle editor in place, and raised as a conflict at once for one with unsaved edits, instead of being overwritten later (#2775).**
  - **What went wrong.** With the collaboration prototype off (the
    default), two people with a document open are two independent writers,
    held apart by the optimistic lock. When one saved, the other's idle
    editor took the new lock version but kept its old form. Its next edit
    posted that whole old form, passed the lock, and wrote over the first
    person's title, body and settings, with no conflict shown.
  - **Now**, what an editor does with a co-editor's save depends on what it
    holds that is not saved:
    - nothing: the form, body and settings are rebuilt from the save, so
      you see it in place and your next edit builds on it;
    - unsaved text (or any edit on an in-review or archived document): the
      *Someone else saved changes to this content* banner at once, rather
      than at your next save;
    - unsaved settings over a co-editor's text-only save: their text is
      shown and your settings are kept, still unsaved; if they changed a
      setting too, the banner instead, so your next Save can't revert it;
    - something open that was worked out from the saved document (the
      Markdown view, the Publish-changes or severity question, an AI
      proposal, the internal-links or content-intelligence panel, an inline
      record card being edited or saved, a version-restore preview):
      nothing, so it is not closed under you, and your next save meets the
      lock as before.
    A write that does not move the lock (a transition, a parent move, Mark
    reviewed) raises no banner. Under the collaboration prototype, an editor
    whose text another editor persists gets no banner, and a rebuild does
    not remount the rich-text editors.
  - **Known limits.** A field the cursor is in keeps its on-screen value
    across a rebuild (LiveView does not overwrite a focused input), and a
    body keystroke still in the rich-text editor's short delay lands on the
    rebuilt body. Mark reviewed and a parent move still don't tell other
    open editors.
  - **For operators.** A rebuild that fails to read the record logs a
    warning, `Editor could not take in a peer's save of <kind> <id>: …`, and
    leaves that editor as it was.
  - See [When a co-editor saves while you have the document open](../working-copy.md#when-a-co-editor-saves-while-you-have-the-document-open).
  No migration, no configuration.
  ([#2775](https://github.com/The-Verscienta/kiln_cms/issues/2775))

<a id="section-layouts-swept"></a>

- **Section layouts left without a field are deleted, a new layout can't be created for an empty section, and a field delete refused because of its section's layout now says so (#3060, #3061, #3062).**
  - **Old rows (#3060).** Since 1.11.0 a section's layout goes with its last
    field, but a layout 1.9.x or 1.10.x left behind stayed, and a field later
    filed under that name took the old tab or fieldset. When no field of the
    type had a section any more, the **Sections of** panel (whose save
    deletes such rows) was not shown, so nothing in the console removed them.
    A job now deletes them after each boot; see the
    [upgrade note](#section-layout-sweep-upgrade).
  - **A layout created as its section empties (#3061).** The new check on
    `FieldSection`'s create (see [Changed](#field-section-create-needs-a-carrier))
    reads the carrying field `FOR SHARE` and holds it until the create
    commits. A field save that moves that field out of the section waits for
    it, then deletes the new layout with the section, instead of running its
    cleanup before the layout existed and leaving it behind.
  - **The fields admin names the layout when a delete fails on it (#3062).**
    When the layout row could not be loaded (one a newer release wrote,
    after a rollback), the failure aborted the field write untagged, so a
    field **Delete** said only *Couldn't delete that field.*, and a flexible
    field's delete dialog said *Couldn't delete that. Check the count and try
    again.* and asked for the count again, which failed the same way. Such a
    failure is now a `KilnCMS.CMS.Errors.SectionLayoutNotKept`, like a
    refused layout write: the delete says *Couldn't delete that field: its
    section's layout could not be removed with it.*, the flexible field's
    dialog closes with the same message, and a field **Save** says
    *Couldn't save the section layout.* A field another admin deleted since
    the page loaded is not reported as a layout failure.
  - **For developers.** `KilnCMS.CMS.Changes.KeepSectionLayouts` keeps the
    layouts inside a nested transaction, so a layout read the database
    fails is returned as `SectionLayoutNotKept` and the field write rolls
    back with it; a field gone since it was loaded fails with
    `Ash.Error.Query.NotFound`, untagged. `KilnCMS.CMS.SectionLayouts` adds
    `carrier?/3`, `uncarried/2`, `prune_uncarried/2` and
    `prune_if_uncarried/3`.
  No migration. One configuration key, `:section_layout_sweep_on_boot`
  (default `true`).
