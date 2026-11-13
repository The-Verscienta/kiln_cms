# 0050. A write that names an editor input the field does not offer is refused

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2284 in 1.9.0.
- **References** — [#2284](https://github.com/The-Verscienta/kiln_cms/issues/2284)
  and [#2495](https://github.com/The-Verscienta/kiln_cms/pull/2495), which
  built it; [#2674](https://github.com/The-Verscienta/kiln_cms/issues/2674),
  which asked for this record;
  [ADR 0049](0049-a-fields-editor-input-is-an-editor-only-string-separate-from-its-text-format.md)
  for what the editor input is.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#field-widgets).

## The problem

Which editor inputs a field offers follows from its other settings
(`KilnCMS.CMS.FieldWidgets.allowed/1`): radio buttons need a single select,
checkboxes need several terms without an open vocabulary (`allow_custom`),
one line needs plain text. Changing one of those settings can leave a stored
`widget` the field no longer offers: a radios select retyped to text, made
`multiple`, or a plain text field made rich.

The same mismatch reaches the field definition from two kinds of writer:

- **The fields admin** (`/editor/fields`) draws only the inputs the settings
  being edited offer, and redraws them as the settings change. The admin who
  switched a select to several terms never saw the radios card leave; the
  stored choice is a leftover, not a request.
- **An explicit write** (a code interface call such as
  `CMS.update_field_definition/3`, seeds, or a field sync import) names the
  input itself. No HTTP API writes field definitions; JSON:API only reads
  them. A writer that names an input the field cannot use has made a
  mistake, and correcting it silently would hide that.

## Decision

- **A write that does not name `widget` gets a stale one cleared.**
  `KilnCMS.CMS.Changes.ClearWidget` runs on every create and update, after
  `Changes.ClearMultiple` has settled `multiple` and `allow_custom`. It asks
  `FieldWidgets.allowed/1` about the definition as the write will leave it
  (`Ash.Changeset.apply_attributes/2`, so a plugin type sees a whole
  definition) and sets `widget` to `nil` when the stored one is not among
  them. `nil` is the type's default.
- **A write that names `widget` is checked, never tidied.** "Names" means
  the input carries the key, even with the value already stored: Ash drops a
  change equal to the stored value, so `ClearWidget.given?/1` also looks at
  the changeset's params. `KilnCMS.CMS.Validations.FieldWidget` then refuses
  any named input the field does not offer, with one of three messages:
  `<name> is not an editor input for this field (use one of: …)`,
  `this field has no choice of editor input`, or
  `checkboxes can't take terms of their own: use tags, or turn off new terms`.
  `nil` always passes.
- **The fields admin never names a stale input.** Its form always posts the
  **Editor input** cards while they are on the page, so its saves name
  `widget`. Before validating or saving, `unpack_widget/2` in
  `KilnCMSWeb.FieldDefinitionLive` asks the same allow-list about the posted
  settings over the stored definition, and replaces a posted input the
  field no longer offers with `nil`. When no cards are on the page the form
  posts no `widget`, and `ClearWidget` clears a stale one. Either way the
  admin's save goes through with the default input.
- **Field sync names the input on every update.** An import sends the file's
  `widget` with every update of a field (`with_widget/2` in
  `KilnCMS.CMS.FieldSync`), even when it equals the stored value. A file whose
  settings no longer suit its own `widget` is refused, and nothing is
  written, instead of being corrected so that the next import finds the file
  and the site disagreeing again.

## Rejected

- **Refuse in the admin too.** The admin would be shown an error about a
  card that left the page when they changed another setting, and would have
  to pick the default to make it go away.
- **Clear on every write, explicit ones included.** A field sync file or a
  code interface call asking for radios on a multiple select would succeed
  and store something else. The file and the site would then differ on the
  next import, and a caller would learn of it only by reading back.
- **Refuse any write that leaves a stale widget, named or not.** A code
  interface call that only changes `multiple` would fail over a setting the
  caller never mentioned.

## Consequences

- Changing a field's type, `multiple`, `format` or `allow_custom` in the
  fields admin resets its editor input to the default when the new settings
  don't offer it. The admin sees the default card checked before saving.
- A code interface call or a field sync import that names an input must name
  one the field's new settings offer, or `nil`. A caller that wants the old
  "reset it for me" behavior leaves `widget` out of the write.
- A stored input a plugin later stops offering stays stored until a write
  clears it: any write that leaves `widget` out, or a save in the fields
  admin. Until then the editor renders the default (ADR 0049). A write that
  names the dropped input is refused, a field sync import that updates the
  field included.
