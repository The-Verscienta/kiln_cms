# Syncing field definitions between environments

Custom fields are rows an admin sets up in the console, so moving a model from
staging to production used to mean clicking it through again. `mix
kiln.fields.export` and `mix kiln.fields.import` move the **definitions** — the
fields, their link fields, group sub-fields and flexible item types, how each type's sections are
laid out in the editor, and the admin-defined content types that own some of
them — as one JSON file. They never move content.

The import goes through the same actions an admin's click does, so every rule
applies (value constraints, conditional rules, private-field limits, name
checks), and it issues **no DDL**: fields are rows; schema changes of a release
stay migrations.

Both directions need an **admin** (the import and export check that the user can
define fields).

A **flexible field** (`:flexible`, #2282) travels with its item types and
their sub-fields: see [Flexible fields](#flexible-fields) below.

## Export

```bash
mix kiln.fields.export --out fields.json            # or: > fields.json
mix kiln.fields.export --org other-site --actor admin@example.com
```

A signed-in admin can also download the same file from the browser by opening
`/editor/fields/export.json`, or from the **Sync definitions** screen below. It
saves as `field-definitions.json`; anyone below admin gets a `403` with
`{"error": "admin_required"}`. On a release:

```bash
bin/kiln_cms rpc 'KilnCMS.Release.export_field_definitions("/data/fields.json")'
```

## Import: diff first, then apply

```bash
mix kiln.fields.import fields.json            # prints the diff; writes nothing
mix kiln.fields.import fields.json --apply
```

```text
── DRY RUN — nothing was written ──
+ post.rating (integer)
~ post.kind: options, help_text
+ recipe.serves (integer)
~ post/section/Clinical: display
2 to create, 2 to update, 0 to delete, 14 unchanged
```

`+` creates, `~` lists the attributes that differ, `-` deletes (only with
`--prune`), `?` is a field the target has that the file does not list. A
section layout is listed as `type/section/Name`, with its display in brackets
when it is created (`+ post/section/Clinical (tab)`).

A dry run is more than a diff: it runs the whole import inside a transaction
and rolls it back, so a write the real run would refuse — a bad regex, a
condition naming a field that is not there, a name clash — is reported now,
with the field's path. `--apply` is one transaction as well: if any field is
refused, **nothing** is written.

Importing the same file again changes nothing (`14 unchanged`).

On a release:

```bash
bin/kiln_cms rpc 'KilnCMS.Release.import_field_definitions("/data/fields.json")'
bin/kiln_cms rpc '{:ok, _} = KilnCMS.Release.import_field_definitions("/data/fields.json", apply: true)'
```

`rpc` exits 0 whatever the call returns; match `{:ok, _}` as shown when a script
must fail on a refused import.

### Options

| Flag | Effect |
| --- | --- |
| `--apply` | Write. Without it the run is a dry run. |
| `--prune` | Also delete fields the file does not list (in the owners it does list), and section layouts the file does not list (in the owners that carry a `"sections"` key). |
| `--allow-data-loss` | Proceed with a change that would drop stored values (below). |
| `--actor EMAIL` | Act as this admin (default: the first admin). |
| `--org SLUG` | The organization (default: the default one). |

### What is never done without being asked

- **Fields absent from the file are kept.** They are listed as `?`; `--prune`
  deletes them.
- **A section's layout goes with its last field.** When the import deletes
  the last field of a section, or moves it to another section, that
  section's layout is deleted too, as the same edit in the console does. The
  diff lists it as `- type/section/Name`. This happens without `--prune`,
  and also for an owner with no `"sections"` key. A layout is kept while any
  top-level field still carries the name after the import, including a
  field the file does not list, unless `--prune` deletes it.
- **Other section layouts are left alone by a file that does not mention
  them.** An owner with no `"sections"` key (a file written before layouts
  existed) changes no other layout of that type, even with `--prune`. An
  owner with the key, `[]` included, declares all of them: a layout it does
  not list is `?`, or deleted with `--prune`. A layout holds no values, so
  its delete is never blocked.
- **Types are never deleted or archived** by an import. A dynamic type in the
  file is created, or has its settings updated; the type's `name` never changes.
- **Dropping stored values is blocked.** A field is *blocked* when records hold
  a value under its name and the import would delete it, change its type, or
  turn a list (`multiple`) into a single value. Nothing is written until you
  pass `--allow-data-loss`, which then behaves exactly as the same edit in the
  console (a delete purges the key from every record). A link or group
  sub-field is judged by its parent's key.
- **A field of an unknown type is invisible to both directions.** A field
  whose type this release doesn't know (after a rollback, or once its plugin
  is removed) is left out of the export, and an import neither updates nor
  prunes it. If the file defines a field of the same name on that type,
  delete the hidden one first
  ([Delete a field of an unknown type](extending-content.md#delete-a-field-of-an-unknown-type)).
- **A rename is a delete plus a create.** Names are the key between
  environments, so a file that renames `dosage` to `dose` blocks on the old
  field if it holds data. Rename it in the target's console first (that moves
  the values), then export again.

## Import from the console

An admin with no shell on the environment can import from the console: open
**Fields** (`/editor/fields`, the page headed *Custom fields*) and follow
**Sync definitions from a file** (`/editor/fields/sync`). It is a screen over the
same import as `mix kiln.fields.import`: nothing is diffed or validated by the
screen itself.

1. **Choose a file.** One `.json` file of up to 2 MB, made by Export. It is
   checked by content: anything that is not a JSON object is refused whatever
   its name, and a JSON object that is not a `kiln-field-definitions` document
   is reported by the import with its path.
2. **Review the changes.** *Preview changes* runs a dry run: the `+` create,
   `~` update, `-` delete and `?` kept lines (also spelled out as words, not
   only signs), the counts, any write the real run would refuse, and the
   changes that are **refused because records hold values** (a delete, a type
   change, a list made single). Nothing is written.
3. **Confirmations.** Two separate checkboxes, both off for every new file:
   *Delete fields this file does not list* (`--prune`) and *Allow changes that
   drop values records already hold* (`--allow-data-loss`). Changing either
   re-runs the preview. While a refusal is listed and data loss is not allowed,
   **Apply** stays disabled and the remaining writes are not checked yet.
4. **Apply.** *Apply…* shows a summary, including which confirmations you
   gave; only *Yes, apply these changes* writes. The apply sends the plan you
   saw: if another admin or an import changed the site's definitions in the
   meantime so that the plan differs, nothing is written, the page says so and
   shows the updated changes. The import is still one transaction. The window
   between that check and the write is milliseconds, and the check does not
   lock another admin's edit of the same field in that instant.

Only an admin reaches the screen, and each step re-checks it. A successful
apply is recorded in the security log as **Site setting changed**
(`setting` `field_definitions`, with the created / updated / deleted counts and
whether pruning or data loss was confirmed;
[security events](security-events.md)). An import from the command line or the
release `rpc` is **not** recorded there.

## The file

```json
{
  "format": "kiln-field-definitions",
  "version": 1,
  "owners": [
    { "kind": "compiled", "type": "post",
      "fields": [ { "name": "rating", "label": "Rating", "field_type": "integer", "section": "Clinical", "width": "half", "step": null, "prefix": null, "suffix": null, "validation": {"min": 1, "max": 5}, "…": "…" } ],
      "sections": [ { "name": "Clinical", "display": "tab", "initially": "auto" } ] },
    { "kind": "dynamic", "type": "recipe", "definition": { "name": "recipe", "label": "Recipe", "…": "…" }, "fields": [ ], "sections": [ ] }
  ]
}
```

- A field carries **every** attribute the field-definition create action
  accepts — type, options, constraints (`validation`), conditions
  (`visible_when`, `required_when`), `private`, `localization`, delivery and
  search flags, reference rules, and so on. The list is read from the action, so
  a field attribute added in a later release is exported without a change here.
- A `:reference` field holds its link fields under `link_fields`; a `:group`
  its sub-fields under `group_fields`; a `:flexible` field its item types
  under `item_types` ([Flexible fields](#flexible-fields)).
- `validation` carries a color field's `palette` and a JSON field's
  `json_schema` as they are stored
  ([Constrain the values of a field](extending-content.md#constrain-the-values-of-a-field)).
- An owner's `sections` lists how its sections are laid out in the editor
  (`KilnCMS.CMS.FieldSection`): `name` (the `section` its fields carry),
  `display` (`accordion`, `fieldset` or `tab`) and `initially` (`auto`,
  `expanded` or `collapsed`). The export writes only the layouts that are
  stored, differ from the default (`accordion` opening `auto`), and that
  some field of the owner still carries; a section with no entry is a
  default accordion. On import, a section name may appear once per owner,
  and the same unknown-key rule applies as for fields. An entry at the
  default stores nothing: it deletes the section's stored layout, if there
  is one, with or without `--prune`, as setting it back in the console does.
  An entry for a section that no top-level field of the owner carries once
  the import is done (no field in the file, nor a stored one the import
  keeps) is refused, and nothing is written; see below. See
  [Lay out custom fields as tabs, fieldsets or columns](extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns),
  and [ADR 0046](decisions/0046-a-sections-layout-is-its-own-row-keyed-by-the-section-name-not-a-setting-on-each-field.md)
  for why a layout is keyed by the section name and when it is pruned.
- A key you leave out of a hand-written file takes the attribute's default; an
  unknown key is refused (a typo would otherwise be silently ignored).
- A dynamic type's `definition` is optional on import if the type exists in
  the target already.
- A dynamic type's `definition` carries `title_template` (computed titles, see
  [Build record titles from fields](extending-content.md#build-record-titles-from-fields)).
  Unlike other keys it is **not** reset to its default when absent: a
  definition that leaves it out, as every file written before it existed does,
  keeps the target's stored template. To clear one, send `"title_template":
  null`.
- `version` is bumped only for a change old readers cannot understand; a file
  with a newer version is refused rather than half-read. A new field
  attribute does not bump it, so an older build refuses such a file by the
  unknown key instead (below). Every release with field sync, 1.9.0 onward,
  reads and writes `width`, `widget` and `sections`; 1.11.0 adds the keys
  listed under [What an older build refuses in a new export](#what-an-older-build-refuses-in-a-new-export).
  [ADR 0047](decisions/0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  records why the file is still version 1.

### A section entry no field carries

The export never writes a layout for a section with no field, so such an
entry comes from a file edited by hand: a section added before its fields, a
typo in a name, or a field moved out of a section whose entry was left in.
The import refuses it, with one error per entry, rather than storing a layout
that would lie unused until a later field of that name took it on:

```text
ERROR post/section/Clinical: no field of post is in this section, so its layout lays nothing out
```

Nothing is written, in a dry run or with `--apply`; the console's preview
lists the same line under *This file cannot be imported*. To fix the file,
put a field in the section (`"section": "Clinical"` on one of the owner's
fields), correct the name, or remove the entry. A stored field the file does
not list counts as a carrier, unless `--prune` would delete it. An entry at
the default layout is never refused: it stores nothing.

Releases up to 1.10.1 accepted such a file and stored the layout.

### Moving a file to an older build

Field sync, `width`, `widget` and `sections` all first shipped in 1.9.0, so
any 1.9.x build reads a file from any other. What follows is the rule for a
field attribute a **later** release adds.

A file is read by the build that wrote it and by any later one. Going the
other way can fail, because every field in an export carries every attribute
the writing build knows, and an older build refuses a key it does not know.
For example, if a later release added a field attribute `hint`, a 1.9.x
build would refuse a file exported by that release, with one error per field:

```text
ERROR document: owners[0].post.rating: unknown key(s) hint
```

Nothing is written. Export from the older build instead, or, if you must use
the newer file, remove the key first and accept that the target keeps its own
value for it:

```bash
jq 'walk(if type == "object" and has("field_type") then del(.hint) else . end)' \
  fields.json > fields-for-older.json
```

An owner key a build doesn't know is not refused the same way: a build reads
an owner's `kind`, `type`, `definition`, `fields` and `sections` and ignores
any other key, along with what it describes.

A file from an older build imports into a newer one as it is: a key the file
leaves out takes the attribute's default, normally what every field had
before the attribute existed. The import then sets that attribute back to the
default on every field that holds something else, and the dry run lists it
as `~`.

### What an older build refuses in a new export

An export from 1.11.0 does not import into 1.10.x or older as it is. Nothing
is written; the older build lists one error per problem:

| In the 1.11.0 file | When | What 1.10.x says |
| --- | --- | --- |
| `step`, `prefix`, `suffix` on a field | every field (`null` when unset) | `unknown key(s) prefix, step, suffix` |
| `title_template` in a dynamic type's `definition` | every dynamic type (`null` when unset) | `owners[N].definition: unknown key(s) title_template` |
| `item_types`, `item_setting` | only on a flexible field | `unknown key(s) …` |
| `validation` with `palette` or `json_schema` | only when a color or JSON field sets one | `has unknown constraints: palette` |
| `"field_type": "address"` or `"flexible"` | only when the site has such a field | the field fails with its path |

Export from the older build if you can. Otherwise strip the keys that are
always there, and remove the rest by hand:

```bash
jq 'walk(if type == "object" and has("field_type") then del(.step, .prefix, .suffix) else . end)
  | .owners[] |= (if .definition then .definition |= del(.title_template) else . end)' \
  fields.json > fields-for-1.10.json
```

The older build then leaves its own values for those keys alone; it has no
number options or title templates to set.

### Number options (`step`, `prefix`, `suffix`)

A number field's export carries `"step"` (a number), `"prefix"` and
`"suffix"` (text), each `null` when unset. See
[Show a number as a slider or with a unit](extending-content.md#show-a-number-as-a-slider-or-with-a-unit).

- **1.10.x and older refuse the file.** These keys first ship in 1.11.0, and
  every field carries them, so an older build reads any 1.11.0 export as
  unknown keys, one error per field (`unknown key(s) prefix, step, suffix`).
  Export from the older build, or remove the keys with `jq` (see
  [What an older build refuses in a new export](#what-an-older-build-refuses-in-a-new-export)).
- **An older file still imports, and clears the options.** A file without
  the keys is read with all three as `null`, so importing it into this
  release sets them back to `null` on every field that has them, and the dry
  run lists each as `~`. Keep them in the file if you want to keep them.
- **`step` follows the field's rules.** A fractional step on an integer
  field, or one wider than its min-to-max span, fails that field with the
  field's path and nothing is written.

### Editor inputs (`widget`)

Each field carries `"widget"`, the editor input an admin chose for it
(`"radios"`, `"single_line"`, a plugin's own), or `null` for the type's
default. See
[Choose how editors fill in a field](extending-content.md#choose-how-editors-fill-in-a-field).

- **A widget that doesn't fit is refused, not corrected.** The import sends
  the file's widget with every update of its field, so a file whose other
  settings no longer suit it — `"multiple": true` on a select still marked
  `"radios"`, `"format": "rich"` with `"single_line"` — fails the field with
  the field's path and a message such as `radios is not an editor input for
  this field (use one of: tags, checkboxes)`, and nothing is written. Set `"widget"` to `null` or to one of the names the
  message lists. The fields admin behaves differently on purpose: there, a
  retype just drops the card that no longer applies.
- **Every release with field sync carries the key.** `widget` shipped with
  field sync itself, in 1.9.0, so no released build writes a file without it
  or refuses one with it. A hand-written file that leaves it out follows the
  general rule: the key takes the default, so the import shows
  `~ post.kind: widget` for every field with a chosen input and sets it back
  to the default. See
  [Moving a file to an older build](#moving-a-file-to-an-older-build) and
  [ADR 0047](decisions/0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md).

### Flexible fields

A flexible field's item types sit under it as an `"item_types"` list. Each is
an ordinary `:group` entry with its own `"group_fields"`, and a sub-field that
is itself flexible nests its own `"item_types"`, down to the depth cap of 3.
Item types and sub-fields are matched by path (`post.sections.hero.headline`),
so a rename is a delete plus a create, as for any field.

```json
{
  "name": "sections", "field_type": "flexible", "label": "Sections",
  "item_types": [
    {
      "name": "hero", "label": "Hero",
      "group_fields": [
        {"name": "headline", "field_type": "string", "required": true},
        {"name": "background", "field_type": "select",
         "options": ["dark", "light"], "item_setting": true}
      ]
    }
  ]
}
```

A hand-written entry may leave out `field_type` and `multiple` on an item type
(they import as `group` and `true`); an item type that names another
`field_type` is refused.

- **`item_setting` is written only when it is `true`.** A sub-field that is
  not a setting has no such key, so a site with no flexible fields exports the
  same file as before, and a missing key imports as `false`.
- **1.10.x and older refuse a file that has `item_types` or an
  `item_setting: true`**, as an unknown key (see
  [What an older build refuses in a new export](#what-an-older-build-refuses-in-a-new-export)),
  and do not know the `flexible` type either. Export from the older build, or
  remove the flexible field from the file.
- **Flipping `item_setting` over stored items is blocked** without
  `--allow-data-loss`, because the stored values stay where they were.
- **Deleting a whole flexible field that holds items needs `--prune` and
  `--allow-data-loss`**, like a group.
- **An import cannot delete an item type that holds items, even with
  `--allow-data-loss`.** Without the flag the dry run lists it as blocked; with
  it the delete is refused with a message naming `purge_items?`, and nothing
  of that type is removed. An import can't pass `purge_items?`, so remove the
  items first, or delete the item type in the fields admin, which counts the
  items and removes them with it on confirmation. An item type that no item
  uses is deleted normally.
- **A retype to or from `flexible` is refused** by the resource, with or
  without `--allow-data-loss`: add the new field and delete the old one.

### What it does not carry

- **Per-field role grants.** "Role X may read/write field Y" lives on roles and
  memberships (see [granular-rbac.md](granular-rbac.md)); export and re-apply
  those with the roles.
- **A reference field's `selection`** (which records it accepts and
  create-on-type, [Limit what can be picked](extending-content.md#limit-what-can-be-picked)).
  It names tag and category ids, which differ per site, and fields of its
  target types an import may not have created yet. An export leaves it out,
  and an import neither sets, changes nor clears it, so each environment
  keeps its own; set it in each one's fields admin. A hand-written file with
  a `"selection"` key is refused like any unknown key.
- **Content, taxonomies, media** — see [content-portability.md](content-portability.md).
- **Compiled content types and plugins.** A field of a compiled type needs that
  type (and any plugin field type it uses) installed in the target; otherwise the
  import reports the field with the reason and writes nothing.

## Caveat: definitions are not migrations

Config sync is only as safe as the change is data-free. Adding fields, relabeling,
tightening or loosening constraints, adding options and reordering are safe to
move. Changes that need existing values reshaped are exactly the *blocked* ones
above: do them in the target with the console or `mix kiln.fields.convert`
([field-conversion.md](field-conversion.md)), then sync the result.
