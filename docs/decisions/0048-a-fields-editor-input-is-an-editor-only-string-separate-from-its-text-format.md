# 0048. A field's editor input is an editor-only string, separate from its text format

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2284 in 1.9.0.
- **References** — [#2284](https://github.com/The-Verscienta/kiln_cms/issues/2284)
  and [#2495](https://github.com/The-Verscienta/kiln_cms/pull/2495), which
  built it; [#2674](https://github.com/The-Verscienta/kiln_cms/issues/2674),
  which asked for this record;
  [ADR 0049](0049-a-write-that-names-an-editor-input-the-field-does-not-offer-is-refused.md)
  for what happens when a field stops offering the stored input.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#field-widgets).

## The problem

An admin can pick how editors fill in a custom field: a single select as a
dropdown, radio buttons or a row of buttons; several terms as tags or
checkboxes; plain text on several lines or one; a single reference by search
or from a dropdown list; or a plugin type's own inputs
(`c:Kiln.FieldType.widgets/1`). Three questions decide what that choice is:

- **Is it the same setting as `format`?** A `:text` field already has a
  choice between rich and plain (`FieldDefinition.format`), and from the
  fields admin both look like "how this field is edited".
- **May it change the stored value?** If picking radio buttons over a
  dropdown could change what a record holds or how it is delivered, switching
  inputs on a field that already holds data becomes a migration.
- **How is it stored?** Core inputs are a fixed list, but a plugin's are
  whatever the installed plugin declares today.

## Decision

- **The input is its own attribute, `FieldDefinition.widget`, not a value of
  `format`.** `format` changes what is stored and delivered: a `:rich` field
  is sanitized to the rich-text allow-list on write and can be delivered as
  Portable Text (`deliver_portable`), while a `:plain` one is stored as typed.
  The widget changes neither. It also applies to types `format` never
  touches (selects, references, plugin types), and `format` decides which
  widgets a text field offers: only `:plain` text has a choice
  (`KilnCMS.CMS.FieldWidgets.allowed/1`).
- **It is editor-only.** Storing a record's value, coercing it, validating
  it and delivering it never read the widget. Its readers are the content
  editor's inputs (`KilnCMSWeb.ContentEditor.InspectorComponents`,
  `CustomFieldsPanel`, `ReferencePicker`), the fields admin, and the schema
  export's `x-kiln-widget` annotation, each through `FieldWidgets.resolve/1`
  or `FieldWidgets.effective/1` rather than the attribute, so a stored input
  the field no longer offers renders as the default and is not advertised.
  Field sync and the field definition's JSON:API attribute carry the stored
  string as it is.
- **The inputs that could lose data protect the value.** A one-line input
  opens as a textarea when the value already holds a line break, so a save
  keeps the breaks. Radio buttons and checkboxes show a stored value that is
  no longer among the options as its own checked input, so a save keeps it.
  The reference dropdown always lists the current pick, as *Unavailable* when
  the editor cannot read it. Radio buttons, buttons and checkboxes fall back
  to the default past `FieldWidgets.option_cap/0` options.
- **One exception, accepted knowingly: checkboxes reorder.** They post in the
  order they are drawn, so saving a record whose field uses checkboxes
  stores its terms in the field's option order, with terms outside the
  options after them. The set of terms is unchanged; the order tags gave
  them is not kept. Switching a field to checkboxes therefore changes the
  stored order of each record the next time it is saved.
- **It is a string, not an atom** (`attribute :widget, :string`, at most 64
  characters). A plugin's input names come from the plugin installed today.
  An `:atom` attribute reads a stored name back with
  `String.to_existing_atom/1`, which fails once the plugin that declared the
  name is removed, and would fail every read of each definition that stored
  it. A string reads back whatever happened to the plugin, and
  `FieldWidgets.resolve/1` answers the default for a name nobody offers.
  `Kiln.FieldType.widget/2` gives a plugin the same answer, as a string.

## Rejected

- **A third `format` value, or folding the input into `format`.** `format`
  would then mean two things, one of which changes storage and one of which
  doesn't, and every select, reference and plugin type would gain a
  `format` with no storage meaning at all.
- **Letting an input store its own shape** (a single-line field rejecting
  line breaks on write, checkboxes storing a set). Switching inputs on a
  field with data would then need a conversion, and an API client would see
  different validation depending on an editor setting.
- **An `:atom` attribute with a `one_of` constraint.** The list would have to
  include every plugin's names at compile time, and removing a plugin would
  turn reads of its fields into errors.

## Consequences

- An admin can switch inputs on a field that already holds data, and switch
  back, without touching a record. Only checkboxes change anything, and only
  the order of terms on the records saved afterwards.
- A stored input outlives the plugin that offered it. Its definitions still
  read, render the type's default, and carry no `x-kiln-widget`.
- Code that wants the input a field uses calls `FieldWidgets.resolve/1` (the
  stored choice while offered) or `FieldWidgets.effective/1` (what the editor
  draws, the option cap included), not the attribute.
