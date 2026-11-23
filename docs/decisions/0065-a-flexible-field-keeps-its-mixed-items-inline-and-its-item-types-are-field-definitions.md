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
  migration ([long form](../changelog/v1.11.0.md#flexible-item-types-upgrade)).

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

Media and reference sub-fields inside items came with PR 3 (below).

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
| `Changes.EnforceCustomFieldGrants` | Judges a flexible field item by item, by `_id`; `custom_fields.sections.hero` grants the items of one type (PR 4, below). |
| `Validations.FieldConstraints`, `Validations.PrivateField` | `nested?` is "not top level", so a unique or private option on an item type or its sub-field is refused. |
| `Validations.FieldCondition` | A `:flexible` field carries no condition of its own (as a group); item sub-fields' conditions see the item's own fields, content and settings together. |
| `Preparations.CustomFieldQuery`, `IndexedCustomFields`, `ListFields` | `:flexible` is not a filter leaf, an index, or a list column. |
| `Media.Resnapshot` | The query for top-level media fields also requires `group_of_id` and `flex_of_id` to be null. |
| `Graphql.CustomFields` | The top-level map uses `top_level?/1`; the field is served as generic JSON per item until the typed `FlexibleValue`. |
| `SchemaExport` | The field is `["array", "null"]` of generic objects, with the item bounds; item types are not listed as fields. |
| `ScopePickers` | Grant and hide pickers list top-level fields; a flexible field's item types are offered beneath it as write entries (PR 4). The read picker never offers them. |
| `FieldSync` | `flex_of_id` is an owner key; item types travel as an `"item_types"` child list and `item_setting` as an attribute; see "Export and import" below. |
| `FieldDefinitionLive` | The new-field picker offers `:flexible`; an existing flexible field's type select is disabled. Item types and their sub-fields are edited in the field's own panels, not listed as top-level rows. |
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
in which case `SyncFieldValues` removes the items in the destroy's own transaction (an `after_action`), so the type and its items go together or not at all.

- An item type is the one definition whose destroy loses content an editor
  wrote without the admin naming it, hence the guard. Deleting a sub-field
  purges its key as a group's sub-field does; deleting a whole flexible field
  or a nested one is a group's behavior too (the key and everything below go).
  Neither is guarded.
- If the check cannot be made (the read failed, the chain is deeper than the
  cap, the table does not resolve), the destroy is refused with a message
  saying so. `purge_items?: true` skips the check entirely. A destroy whose
  owner is already gone is let through, since the items went with it.
- **Check-then-act window.** The check runs in the validation and the purge
  in the same transaction, but the window is not closed: a save that commits
  after the purge statement and before the destroy commits can still add an
  item of the type, which is then an orphan. This is accepted: the type is
  gone either way, and an item of a type that no longer exists is refused by
  `ApplyCustomFields` on the next write that names the field (the editor shows
  it as a locked card and drops it on save, see below). A purge that fails
  rolls the destroy back.

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

### Export and import

The field-sync file carries a flexible field's item types as an
`"item_types"` child list: each an ordinary `:group` entry with its own
`"group_fields"`, nested to the depth cap, and `item_setting` as an attribute.
`item_setting` is left out of the file when it is `false`, so a site with no
flexible fields exports the same file as before and an older reader (which
refuses unknown keys) still reads it. A file with `item_types` or
`item_setting: true` does not import on 1.10.

An import cannot delete an item type that holds items, even with
`allow_data_loss?`: it cannot pass `purge_items?`, so the resource refuses with
a message naming it. Data-loss detection for an item type or one of its
sub-fields asks `FlexiblePath.items_exist?`, failing closed when the read
fails. Deleting a whole flexible field that holds items is a data-loss change
like a group's. A retype to or from `:flexible` is refused (below).

### The editor edits items as cards

The content editor renders each item as a card under its field: add (appended
at the end), duplicate, remove, move, drag, collapse, and a collapsed
**Settings** section whose inputs are always rendered, because a save replaces
an item's `_settings` rather than merging them. Events address an item by its
`_id` path, never by position, so a stale client cannot act on the wrong item.
The editor posts `_id`, `_type` and `_settings` for each item. An **orphan**
(an item whose `_type` is no longer an item type of the field) is shown as a
locked card with only **Remove**; the editor posts only inert `_id` and
`_type` markers for it, no content, so a save drops it.

### Retyping to or from flexible is refused

`Validations.FlexibleRetype` refuses an update that changes `field_type` to or
from `:flexible`, on the resource, so the admin form, a field-sync import and
the code interface are refused alike. A retype in either direction would
leave values in the wrong shape or item types attached to a non-flexible
field; to change one into the other, add a new field and delete the old one.
The admin form disables the type select on a flexible field.

### What is not done yet

No search of items, no per-item diff, no typed GraphQL
or client export (PR 5 to PR 7 of the plan; per-item-type grants are PR 4, below). The values are served as generic
JSON objects until then.

## Media and reference inside items (PR 3, #2282)

An item type's sub-field may now be a `:media` or a `:reference`
(`FieldDefinition.item_field_types/0`). What it decides, and what it does not:

- **One value, never a list.** A media or reference sub-field holds a single
  snapshot. `Changes.ClearMultiple` clears `multiple` (and `min_items` /
  `max_items`) on a media or reference that is a sub-field, so there is no
  gallery and no list of references inside an item. A multiple one stays a
  record-level field.
- **Written as the caller, rebuilt from the database.** `ApplyCustomFields`
  resolves an item's sub-value exactly as it does a top-level one: as the
  actor and under the write's tenant, never as a system actor, with the same
  by-id rule (`"select/…"`, a bare id or a snapshot map all resolve through the
  id). A snapshot a client sends is never trusted: it is rebuilt from the
  record, so a forged title, slug or url is replaced. An id the caller cannot
  read, from another site, trashed or unknown is refused at the item's path
  (`sections[0].rows[1].cta`).
- **Edges are keyed by definition path.** `ContentLink.field` for an item
  reference is the dotted path of definitions, not of values or positions:
  `sections.hero.cta`, a nested one `sections.columns.cells.cell.link`, a group
  row `visits.doctor`. It needs no migration, no column and no identity change
  (the key was already a string). Two items pointing at one target make one
  edge; reordering or removing items follows the values; renaming a field, item
  type or sub-field rewrites the edges by prefix, and destroying one deletes
  them (the prefix match escapes `_` and `%`, so `hero_a` never matches
  `heroxa`). A working copy makes edges only when it is published.
- **A reference inside an item is `on_target_delete: :keep` and uncapped.** No
  `max_sources`, no inverse (reverse list), no `selection`, no link fields (the
  "details on each connection" of a top-level reference) and no schema.org
  property: `ClearReferenceOptions` and `ClearInverse` clear them on every
  non-top-level reference, and `FieldDefinition.link_fields/1` answers `[]` for
  one. Deleting a target therefore leaves the snapshot in place, as `:keep`
  does at the top level, and a later write naming it is refused. The
  GraphQL/JSON:API add/remove edits (`ReferenceEdits`) stay top-level only.
- **Masking recurses.** A snapshot of a record the reader cannot read is
  masked (the key is `nil`) wherever it sits: `ReferenceSnapshots` walks lists
  and maps to the depth cap plus one, skipping an item (a map with `_id` or
  `_type`), so a snapshot is recognised by shape. The same walk runs in the
  read-side preparation, in `Firing.CustomFields` (the fired `:json` artifact,
  with one batched read per type) and for a point-in-time read. A fired
  artifact refreshes a media item's variants and a renamed target's title
  inside items, and the re-fire graph (`Firing.References`) sees item media and
  references, so renaming a target or re-processing an image re-fires the
  documents that show it only through an item.
- **The SQL reporting views cut nested snapshots (#3057).** A reference
  snapshot inside an item or a group row is cut to `{id, type}` by the views
  (`docs/reporting.md`); the strip depth is pinned to the snapshot walks'
  depth by a test.
- **Walks are by shape, so they also see a `:json` field.** `ids/1` and
  `mask/2` never consult a definition: a snapshot-shaped object a writer
  typed into a `:json` value is masked and counted like a real one. That fails
  closed and is accepted (`Firing.CustomFields` relabels only the
  reference, flexible and group fields' values).
- **The media re-snapshot is media-only.** `mix kiln.media.resnapshot` walks
  a group's rows and an item's sub-fields and re-takes only the media
  snapshots; every other value, an item of a retired type, a stray key and a
  sub-field required since the record was saved are kept as stored and never
  refuse the record.
- **An edge path is capped.** `ContentLink.field` holds 1,000 characters; a
  reference whose definition path is longer implies no edge (the value stays
  in `custom_fields`).
- **No private sub-fields.** `private` is top-level only
  (`Validations.PrivateField`), so a hidden value never sits inside an item.
- **The editor addresses an item, not a field.** The pickers inside an item
  card send the item's `_id` address (`sections/<id>/cells/<id>`) and the
  sub-field name, nothing else: not the type, not a value, not a field name to
  trust. The server resolves both against the live form parameters at event
  time (`FlexibleItems.put_value/6`), checks the top-level field is editable
  (write grant, localization lock), and does nothing when the address no longer
  names an item or the sub-field is not a single media or reference of its
  item type. A reorder between opening a drawer and picking cannot misdirect
  the pick. A reference that allows several types posts a `type:id` token that
  is turned into the `%{"id", "type"}` map before it reaches the form.
- **Groups are not lifted yet.** The write path handles a group row's media
  and reference sub-fields (the code is shared), but
  `Validations.GroupField` keeps a plain group on `link_field_types/0` until
  the editor has row pickers; a group is a follow-up to PR 3. The GraphQL
  `GroupValue` shape does not change, and `SchemaExport`'s query fragment for
  a repeating group's rows still selects only scalar values (see the plan).

### Rollback

No migration. The previous release does not know that an item sub-field may
be a media or a reference: its `sub_value` refuses any map or list, so
**re-saving a record that holds an item media or reference in release N-1 fails
validation** at that sub-field. Reads work: the stored snapshots are returned
as stored, and the fired artifacts keep what was fired. The definitions of
those sub-fields load (`field_type` is a known atom there). Roll forward, or
delete the sub-field first (which purges its values).

## Item-type grants (PR 4, #2282)

The grammar did not change: `custom_fields.<field>.<x>` already parsed, and
`FieldAccess.writable?/2` is plain membership of the entry or the field's own
entry. What changed is that `<x>` may now be an item type, and that the write
check judges a flexible value by item.

- **Matched by `_id`, not by position.** `EnforceCustomFieldGrants` compares
  the coerced list with the stored one: an `_id` only in the new list is an
  *added* item, only in the old one a *removed* item, in both and different a
  *changed* item. Each needs `[field, item type]` (an item whose `_type`
  changes needs both). Matching by position, as groups do, would turn one
  inserted hero into a change to every item after it.
- **Reordering needs the whole field.** If the surviving ids come in a
  different order the path is `[field]`. Letting a `hero` editor move `hero`
  items among others would need the grant inside the path check and a judgment
  of whether the other items kept their relative order; the plan's "may not
  reorder others" is met in the strict form, and a later PR can relax it.
  Rejected: treating every reorder as free (it lets an editor move a `quote`
  item).
- **Snapshots are not changes.** Before comparing, an item's media and
  reference sub-values (and its settings', and those of nested items) are cut
  to their ids, so a refreshed title in an item type the editor cannot write
  does not refuse their save.
- **No third segment.** A grant per sub-field of an item type stays out of
  scope: the grammar has two segments, and a sub-field name in the second
  position grants nothing (it is not an item type, so no path matches it).
- **A list that cannot be matched is judged whole.** If any item lacks a
  string `_id` or `_type`, or an id repeats, the path is `[field]`.
- **Read grants are untouched.** A flexible field cannot be private, so an item
  type is not a read entry; `valid_read_entry?/2` still refuses it.
- **Copies carry the granted items.** `ContentCopy.filter_custom_fields/3`
  keeps the items of the granted types of a flexible value
  (`FieldAccess.writable_items/3`), and lists the field as withheld when it
  left any out. The result is exactly what the editor could have written to a
  new record.
- **The console is unchanged.** `HiddenFields.console_access/4` marks a field
  read-only unless `writable?(write, [name])`, so a partly granted flexible
  field renders disabled, as a group with only sub-field entries does.
  Editing the permitted items there is a follow-up.
- **Rollback.** No migration and no new data. The previous release stores an
  item-type entry and never matches it, so a role that holds one grants
  nothing there. Rolling back only restores the refusal.

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
