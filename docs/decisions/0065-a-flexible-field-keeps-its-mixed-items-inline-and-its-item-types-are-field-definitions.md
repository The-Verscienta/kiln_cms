# 0065. A flexible field keeps its mixed items inline, and its item types are field definitions

- **Status** — accepted (2026-11-16).
- **References** — [#2282](https://github.com/The-Verscienta/kiln_cms/issues/2282)
  (PR 1 of `docs/flexible-content-plan.md`, section 9: the model and the
  write path, API level only) and the maintainer's decisions of 2026-11-10
  recorded in that plan (parity with `:group`, nesting allowed and capped).
  Builds on the group model of
  [extending-content.md](../extending-content.md) (structured rows) and on the
  unknown-field-type rule of
  [Delete a field of an unknown type](../extending-content.md#delete-a-field-of-an-unknown-type).
- **Changelog** — held. The plan keeps the feature entry until the admin and
  editor PR (PR 2); this change is in the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md) only as an upgrade note for its
  migration ([long form](../changelog/unreleased.md#flexible-item-types-upgrade)).

## The problem

An editor wants one custom field that holds an **ordered list of items of
different kinds** (a hero, a quote, a feature grid), each kind with its own
sub-fields and its own settings, and an admin wants to define those kinds in
the UI with no code and no DDL. Drupal Paragraphs, ACF Flexible Content,
Strapi dynamic zones and Payload blocks are the benchmark.

Two cheap answers looked right and were wrong.

**Put core blocks inside a field.** The storage and the cast would work. The
rest does not: blocks are compile-time embedded resources
(`KilnCMS.Blocks.union_types/0`), so an admin cannot define a new kind; the
editor, `EnforceBlockFieldPolicy` (`editable_by`), `Fragments.expand`,
`BlockIndexer`, the diff and the firing engine all assume one tree at
`document.blocks`, so a second tree would silently bypass the first's
policies. What blocks do give is a naming convention, copied here: `_type`
and `_id`.

**Reuse `:group`.** A group has one row shape. A flexible field needs one
shape per item, chosen by a discriminator, so a group cannot carry it as is,
but its machinery (sub-fields as rows, `group_fields/1`, `Conditions`,
`FieldConstraints.check_row`, the `SyncFieldValues` sub-field SQL) is exactly
what an item type needs.

## The decision

### A new core type, item types as definition rows

`:flexible` is a core field type (`KilnCMS.CMS.FieldTypes.core/0`), so a
plugin cannot register the name. Its value is a list of items, each tagged
with its type:

    "sections": [
      {"_id": "6f1c…", "_type": "hero", "headline": "Hello",
       "_settings": {"background": "dark"}},
      {"_id": "a02d…", "_type": "quote", "text": "…", "cite": "…"}
    ]

An **item type** is a `FieldDefinition` of type `:group` with a new owner
column, `flex_of_id`, pointing at its `:flexible` field. It is a fifth owner
beside `content_type`, `type_definition_id`, `link_of_id` and `group_of_id`
(`Validations.OneFieldScope` allows exactly one). Its sub-fields are ordinary
`group_of_id` children. A sub-field with the new boolean `item_setting` is one
of the item's **settings**: its value is stored under the item's `_settings`
and never mixed into the content, so delivery and search can ignore it.

Because an item type has neither `content_type` nor `type_definition_id`,
`for_type` and `for_definition` never list it; they load it into the flexible
field's `item_types` instead, down to the nesting cap.

### Storage: inline, `_`-prefixed meta keys, stable ids

Items are stored inline in the record's `custom_fields` JSON, as a group's
rows are (D3: one JSON tree per record, one read, one revision, atomic with
the parent, no second table). `_id`, `_type` and `_settings` begin with an
underscore, and a definition name must begin with a letter, so a meta key
cannot collide with a sub-field.

`_id` is a UUID. A write keeps the one a client sends when it is a valid UUID
not yet used in the same write, and mints a new one otherwise (absent,
malformed, or a repeat). That identity is what later per-item merge, diff,
grants and translation alignment need and what group rows lack today. A
flexible field is implicitly `multiple`: `Changes.ClearMultiple` forces it on.

### Nesting is allowed, capped at 3 by a constant

An item type's sub-field may itself be a `:flexible` field
(`FieldDefinition.item_field_types/0` is the plain sub-field types plus
`:flexible`; a plain `:group` keeps `link_field_types/0`, so a flexible field
is allowed only under an item type). The depth is bounded by
`FieldDefinition.max_flexible_depth/0`, **3 levels**, a top-level flexible
field being level 1.

It is a compile-time constant, not a setting. Every recursion over an item
tree (coercion, owner walks, the SQL that renames and purges, and later the
display, diff and GraphQL readers) has to stop at the same number, and the
loader that builds `item_types` has a fixed shape for it. Two settings
disagreeing would make a definition one reader accepts and another cannot
load. `Validations.FlexibleField` and `Validations.GroupField` enforce it when
an item type or a nested flexible sub-field is created; tests run a
three-level fixture and the cap and cap + 1.

Media and reference sub-fields inside items are not yet allowed
(`item_field_types/0` is the plain types and `:flexible`); that is PR 3 of the
plan.

### The item-count cap

A value is one JSONB tree that every write re-coerces, so an unbounded list is
a cost the admin did not choose. A flexible field with no `max_items` holds at
most **100 items**. `config :kiln_cms, :flexible, max_items: n` changes the
default; it is read with `Application.compile_env/3`, so it takes effect when
the application is recompiled, not at boot. A definition's own `max_items`
(and an item type's, which bounds items of that type) wins.

### Exclusions

A flexible field takes none of the options that only fit a plain value, and
each is refused with a message rather than ignored: `searchable` and
`names_record` (until search skips `_id` and `_type`, it would index them),
`private`, a `default`, `item_setting`, `unique` (no constraint applies), and
its own `visible_when` / `required_when` (as for a group). It is not a list
column, an indexed field or a `custom_filter` leaf (a filter on it answers
only `null`). The reporting views are unchanged: item types have no
`content_type` or `type_definition_id`, and a test pins that they never join.

### Reading it back: the `top_level?` audit

About a dozen readers decided "a field of a type" with their own copy of
`is_nil(link_of_id) and is_nil(group_of_id)`. An item-type row has neither, so
each copy would have taken it for a top-level field of the type (and, say,
hidden or exported a real field of the same name). They all call
`FieldDefinition.top_level?/1` now, which checks all three parent columns, and
`FieldDefinition.parent_id/1` includes `flex_of_id`. A new parent column is
added in those two functions and nowhere else.

| Reader | Treatment |
|---|---|
| `PlainFields`, `PortableFields` | Delivery names: top-level only. An item type's sub-fields are not delivered as fields. |
| `HiddenFields`, `FieldAccess` | Hidden names and `valid_read_entry?/2` skip item types, so a "ghost" item type cannot make a real field look private. |
| `PrivateFields` | The SQL filter now also requires `flex_of_id IS NULL`; masking never looks inside a flexible value (a flexible field cannot be private). |
| `FieldWidgets` | An item type is a sub-field: no choice of editor input. |
| `ReferenceSelection`, `Validations.ReferenceSelection` | A selection may not filter on an item-type row. |
| `Changes.ClearDefaultSource`, `ClearDeliverPlain`, `ClearDeliverPortable`, `ClearLinkFieldOptions` | An item type and its sub-fields are treated as nested: record-level options are cleared. |
| `Changes.ClearMultiple` | `:flexible` and item types are forced `multiple: true`. |
| `Changes.EnforceCustomFieldGrants` | Top-level only. A `:flexible` field falls under the whole-value clause: `custom_fields.sections` works, an item-type segment (`custom_fields.sections.hero`) is not valid until the grants PR. |
| `Validations.FieldConstraints`, `Validations.PrivateField` | `nested?` is "not top level", so a unique or private option on an item type or its sub-field is refused. |
| `Validations.FieldCondition` | A `:flexible` field carries no condition of its own (as a group); item sub-fields' conditions see the item's own fields, content and settings together. |
| `Preparations.CustomFieldQuery`, `IndexedCustomFields`, `ListFields` | `:flexible` is not a filter leaf, an index, or a list column. |
| `Media.Resnapshot` | The query for top-level media fields also requires `group_of_id` and `flex_of_id` to be null. |
| `Graphql.CustomFields` | The top-level map uses `top_level?/1`; the field is served as generic JSON per item until the typed `FlexibleValue`. |
| `SchemaExport` | The field is `["array", "null"]` of generic objects, with the item bounds; item types are not listed as fields. |
| `ScopePickers` | Grant and hide pickers list top-level fields only. |
| `FieldSync` | `flex_of_id` is an owner key and `item_setting` is not synced yet; see "Export and import are lossy" below. |
| `FieldDefinitionLive` | The type picker leaves `:flexible` out, and the list leaves item types and their sub-fields out, so the Fields screen shows no row it cannot edit. |
| `BustTypeRegistry`, `SyncFieldValues`, `FlexiblePath` | Walk the owner chain up to the cap; see below. |

### Owner walks and SQL go through one module

A sub-field of an item type is up to six hops from the content type that owns
its values: sub-field, item type, flexible field, then (nested) the item type
and sub-field above it. `BustTypeRegistry` walks the chain
(`FlexiblePath.owner/2`) so a rename at any depth re-fires the owning type;
before this a single-hop read resolved nil and left stale fired output with no
error. `SyncFieldValues` renames and purges inside the items through
`KilnCMS.CMS.FlexiblePath`, which builds one statement qualified by every
`{field, item_type}` step. Item type names are unique only within one
flexible field, so no statement ever matches a name by position-blind descent;
all names and values are bound parameters.

### Deleting an item type is refused while items exist

`reference :flex_of, on_delete: :delete` cascades from a field to its item
types and their sub-fields in the database, **bypassing `SyncFieldValues`**
(true of groups too). So the guard is a validation, not the foreign key:
`Validations.ItemTypeInUse` refuses `destroy` of an item type while any
document holds an item of it, unless the destroy passes `purge_items?: true`,
in which case `SyncFieldValues` removes the items after the commit.

- An item type is the one definition whose destroy loses content an editor
  wrote without the admin naming it, hence the guard. Deleting a sub-field
  purges its key as a group's sub-field does; deleting a whole flexible field
  or a nested one is a group's behavior too (the key and everything below go).
  Neither is guarded.
- If the check cannot be made (the read failed, the chain is deeper than the
  cap, the table does not resolve), the destroy is refused with a message
  saying so. `purge_items?: true` skips the check entirely. A destroy whose
  owner is already gone is let through, since the items went with it.
- **Check-then-act window.** The check runs in the validation, the purge runs
  after the transaction commits. An item of that type saved between the two is
  removed by the purge along with the type. This is accepted: the type is gone
  either way, and an item of a type that no longer exists is refused by
  `ApplyCustomFields` on the next write that names the field.

### Write strictness: strict, drop, import

`ApplyCustomFields` has two modes already: `:strict` (an API write refuses
what the definitions do not declare) and `:drop` (a machine copy discards it,
with a warning). An item whose `_type` the field does not declare is:

- refused in `:strict`, with the path: `sections[2]._type "teaser" is not an
  item type of this field (item types: hero, quote)`;
- dropped in `:drop`, which is what a version restore and a content copy use,
  since the type may simply be gone;
- refused for the **row** in a JSON import, which passes
  `custom_fields_items: :strict` beside `custom_fields: :drop`. Everything else
  an import carries still drops silently (an unknown key), but silently
  dropping a whole item would lose content the importer cannot see.

An item is never silently retyped.

## Consequences

### Rollback

The migration is expand-only: two additions to `field_definitions`
(`flex_of_id uuid NULL`, FK to the same table with `on_delete: delete_all`,
unique with `name` per site; `item_setting boolean NOT NULL DEFAULT false`).
`mix kiln.migrations.check` needs no marker for it. The previous release
keeps working against the new schema. What it sees, read from its code and
`docs/releasing.md`, not run on a previous deployment:

- A **`:flexible` field** has a `field_type` the previous release does not
  register. `field_type` is a `KnownAtom` there (since the #2605 fix), so the row loads as an unknown type: left out of every ordinary read,
  hidden from the editor, delivery and schema export, listed under **Fields of
  an unknown type** with only a delete, and its stored items kept by every
  write. Rolling forward shows it again.
- An **item type** is a `:group` row. The previous release does not know
  `flex_of_id`, so to it the row has no owner at all: no `content_type`, no
  `type_definition_id`, no `link_of_id`, no `group_of_id`. `for_type` and
  `for_definition` filter on an owner, so it is never loaded as a field of a
  type and nothing coerces against it. The Fields screen reads every row and
  groups them by owner, so it may list these under an empty owner; I did not
  run that screen on the previous release. A save of such a row there would be
  refused by `OneFieldScope`. Their sub-fields (`group_of_id` set) are
  likewise hidden under the item type.
- The **stored values** are not touched by the rollback. After it, an admin
  who wants a tidy Fields screen can delete the flexible field first; that
  deletes its item types and sub-fields with it.

Rolling the database back (`down`) drops the two columns. Item-type rows that
exist then are ownerless groups, as above; delete them first if you want the
table clean.

### Export and import are lossy until PR 2

The field-sync file format (`docs/field-sync.md`) has no `item_types` child
list yet; it arrives with the admin UI in PR 2. Until then:

- `mix kiln.fields.export` writes a `:flexible` field and **no** item types or
  their sub-fields, and `import` would create a flexible field with no item types,
  so every item write to it is refused until an admin defines some. An import
  of a file into a site that already has the field leaves its item types
  alone, and `--prune` does not plan or delete an item type (it is not in the
  list the prune walks). Deleting the flexible field in an import deletes its
  item types by the database cascade.
- `item_setting` is not in the synced attribute list, so it cannot travel
  either.

### The editor shows a read-only note

Until PR 2, the content editor renders a `:flexible` field as its label, an
item count and the line "Edited through the API; item editing arrives with the
next release.", with no input, so a save posts nothing for the key and keeps
the stored items. The Fields screen does not offer `:flexible` in its type
picker; an admin defines the field and its item types through the code
interface (`KilnCMS.CMS.create_field_definition/2`), not the console.

### Retyping is not guarded

`field_type` is accepted by the update action, and nothing in this change
blocks changing an existing field to or from `:flexible`. Retyping a field to
`:flexible` re-validates its options (a private field is refused), but its
stored values stay in the old shape, and (read from `resolve_flexible`, not
tested) a write that names the field refuses a non-list as "must be a list of
items". Retyping a flexible field away leaves its item types attached to a
field that is no longer flexible. It is left open deliberately: a guard that
refuses a retype while the field has values belongs with the admin UI, which
is the only place an admin does it.

### What the first release does not do

No admin panel, no editor cards, no per-item-type grants, no search of items,
no per-item diff, no typed GraphQL or client export (PR 2 to PR 7 of the
plan). The values are served as generic JSON objects until then.

## What was rejected

- **Core blocks inside a field**, for the reasons above.
- **A table of items**, which brings Paragraphs' N+1 and revision drift.
  Items are part of the record's JSON, so they version with it.
- **One level of nesting only.** The maintainer decided nesting is wanted; the
  cost is bounded by the constant.
- **A configurable depth cap.** See above.
- **Relying on the foreign key to protect items.** It cascades in the database
  and does not pass through any Ash change.
- **Silently re-typing or keeping an item whose type is gone.** An orphan is
  refused on a strict write and dropped on a copy, never kept under a type
  that cannot validate it.
