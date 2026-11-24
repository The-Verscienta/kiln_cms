# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

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
  - **Closing and leaving.** A card with unsaved edits cannot be closed (*Save or discard the changes to this record before closing it.*). **The parent's Save does not save the card**, and navigating away from the parent loses unsaved card edits: the unsaved-changes guard is the next part (2b), and saving every card with the parent is a later part. Save the card first.
  - **What the card shows.** The title is read-only for a type with a title template. A field the editor's grant does not allow is read-only, a private field their read grant hides is not shown, and a field a condition hides is not shown. If the parent field itself is read-only (a read-only grant, a held list or a localization lock), the card still opens but its inputs and Save are disabled. The record being edited never gets a card on its own field. Creating a record and opening its card on create is not part of this release.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place) and [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).


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
