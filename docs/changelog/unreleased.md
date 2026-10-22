# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

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
