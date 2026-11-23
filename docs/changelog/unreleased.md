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

- **A reference field can show a read-only preview of related records (#2283).** In the fields admin, a top-level reference field has a new step 7, **Editing the linked records**, with a checkbox: **Let editors edit the related record here**. With it ticked, each connected record in the editor gets a **Show the record** button under its row (**Hide the record** once open). It opens a card with the record's title and its plain fields (text, number, yes/no, date, URL and select fields), a note when it is a draft or has unpublished changes, and an **Open in the full editor** link. Other fields, such as media and rich text, are edited in the full editor, and the card says so. **Nothing is editable in this release**: editing in the card (its own Save) is the next step of the plan in [docs/plans/inline-reference-editing-plan.md](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/plans/inline-reference-editing-plan.md).
  - **Who sees a card.** Only an editor who may change that record (the same check as the full editor, on its working copy once published) gets the button. A record the editor cannot read stays *Unavailable*; one they can read but not change has its row and no card. The server checks again when a card opens, so a forged request opens nothing, and a private field the editor's read grant hides is not shown.
  - **Limits.** At most 10 cards are open at once on one field (*Close a record before opening another.*). Nothing is read for a closed card.
  - **Stored as** `edit_inline`, a nullable boolean: off is nil, and an unticked box is stored as nil. It is cleared when the field's type changes away from a reference, and refused (*is only for a reference field of the record itself*) on a sub-field of a group, link field or flexible item. A field graduated to a join resource does not carry it.
  - **Outside the editor.** `GET /api/schema` reports `x-kiln-edit-inline: true` on such a field (absent when off), as an annotation for clients that build their own editor; the OpenAPI document in `docs/api/openapi.json` carries it. `mix kiln.fields.export` and `mix kiln.fields.import` (field sync) carry the flag with the field. No API reads or writes related records through the parent: write the related record at its own endpoint, then connect it.
  - See [Edit related records in place](../extending-content.md#edit-related-records-in-place) and [ADR 0081](../decisions/0081-an-inline-edited-related-record-is-saved-on-its-own-and-the-option-is-its-own-column-with-no-write-api.md).
