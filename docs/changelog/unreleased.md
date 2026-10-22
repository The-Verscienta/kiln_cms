# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-text-custom-field-can-also-be-delivered-as-plain-text"></a>

- **A `:text` custom field can also be delivered as plain text.** A new
  per-field toggle in the fields admin, "Also deliver as plain text"
  (`deliver_plain` on `FieldDefinition`, off by default), adds a
  `custom_fields_plain` map beside `custom_fields`: each flagged field's value
  with HTML tags removed, entities decoded and whitespace collapsed
  (`KilnCMS.PlainText.from_html/1`). It is for clients that cannot render the
  HTML fragments importers put into `:text` fields — a native app no longer
  needs a browser engine's HTML parser to show a paragraph. `custom_fields`
  itself is never rewritten.

  Where it appears: in the fired `:json` artifact, and so in
  `GET /api/content/:type/:slug` and every `/api/sync` item, whenever the
  type flags a field (absent otherwise, so other types' payloads are
  byte-identical); as the `custom_fields_plain` calculation on JSON:API
  (`fields[page]=…,custom_fields_plain`) and GraphQL (`customFieldsPlain`),
  served only on request like `inherited_fields`; and in the delivery schema
  (`GET /api/schema`, the `.d.ts`) as a closed object of nullable strings.
  Flipping the toggle re-fires the type's published documents. Not carried:
  the other fired surfaces (`:web`, `:llm`, `:json_ld` render text already),
  the public HTML page, feeds and CSV export, and a reference's link fields
  (the toggle is cleared on them, as on every non-`:text` type).

<a id="group-custom-field"></a>

- **A `:group` custom field holds structured rows: one object, or a list of
  them, keyed by typed sub-fields, with every bad key reported by its path.**
  Lists of records — an herb's dosages, its drug interactions — used to be
  JSON strings in `:text` fields, which the schema export called strings and
  every client parsed on its own. A group's sub-fields are `FieldDefinition`
  rows owned through the new `group_of_id` (scalar types only, one level
  deep, like R3 link fields), each key is coerced by its sub-field's rules,
  an unknown key is refused, and errors name their path
  (`Unit (dosages[2].unit) is required`). `multiple` makes it repeating rows
  with `min_items`/`max_items`. Renaming or deleting a sub-field moves or
  purges its key in every stored row. The schema export types a group as a
  closed object (an array of them when `multiple`), and
  `/api/json/type-definitions?include=field_definitions.group_fields` lists
  the sub-fields. Groups are defined through the code interface or the API
  for now; the editor shows an existing group read-only, and the row editor
  follows. The migration adds one nullable column.
  ([#2036](https://github.com/The-Verscienta/kiln_cms/pull/2036))
