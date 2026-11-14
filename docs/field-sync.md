# Syncing field definitions between environments

Custom fields are rows an admin sets up in the console, so moving a model from
staging to production used to mean clicking it through again. `mix
kiln.fields.export` and `mix kiln.fields.import` move the **definitions** — the
fields, their link fields and group sub-fields, how each type's sections are
laid out in the editor, and the admin-defined content types that own some of
them — as one JSON file. They never move content.

The import goes through the same actions an admin's click does, so every rule
applies (value constraints, conditional rules, private-field limits, name
checks), and it issues **no DDL**: fields are rows; schema changes of a release
stay migrations.

Both directions need an **admin** (the import and export check that the user can
define fields).

## Export

```bash
mix kiln.fields.export --out fields.json            # or: > fields.json
mix kiln.fields.export --org other-site --actor admin@example.com
```

A signed-in admin can also download the same file from the browser by opening
`/editor/fields/export.json` (the Fields screen has no button for it yet). It
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
  deletes them. Deleting the last field of a section also deletes that
  section's layout, as deleting it in the console does.
- **Section layouts are left alone by a file that does not mention them.** An
  owner with no `"sections"` key (a file written before layouts existed)
  changes none of that type's layouts, even with `--prune`. An owner with the
  key, `[]` included, declares all of them: a layout it does not list is `?`,
  or deleted with `--prune`. A layout holds no values, so its delete is never
  blocked.
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

## The file

```json
{
  "format": "kiln-field-definitions",
  "version": 1,
  "owners": [
    { "kind": "compiled", "type": "post",
      "fields": [ { "name": "rating", "label": "Rating", "field_type": "integer", "section": "Clinical", "width": "half", "validation": {"min": 1, "max": 5}, "…": "…" } ],
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
  its sub-fields under `group_fields`.
- An owner's `sections` lists how its sections are laid out in the editor
  (`KilnCMS.CMS.FieldSection`): `name` (the `section` its fields carry),
  `display` (`accordion`, `fieldset` or `tab`) and `initially` (`auto`,
  `expanded` or `collapsed`). The export writes only the layouts that are
  stored and that some field of the owner still carries; a section with no
  entry is a default accordion. On import, a section name may appear once per
  owner, and the same unknown-key rule applies as for fields. See
  [Lay out custom fields as tabs, fieldsets or columns](extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns),
  and [ADR 0046](decisions/0046-a-sections-layout-is-its-own-row-keyed-by-the-section-name-not-a-setting-on-each-field.md)
  for why a layout is keyed by the section name and when it is pruned.
- A key you leave out of a hand-written file takes the attribute's default; an
  unknown key is refused (a typo would otherwise be silently ignored).
- A dynamic type's `definition` is optional on import if the type exists in
  the target already.
- `version` is bumped only for a change old readers cannot understand; a file
  with a newer version is refused rather than half-read. A new field
  attribute does not bump it, so an older build refuses such a file by the
  unknown key instead (below). Every release with field sync, 1.9.0 onward,
  reads and writes the same version-1 keys, `width`, `widget` and `sections`
  included; [ADR 0047](decisions/0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  records why the file is still version 1.

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

### What it does not carry

- **Per-field role grants.** "Role X may read/write field Y" lives on roles and
  memberships (see [granular-rbac.md](granular-rbac.md)); export and re-apply
  those with the roles.
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
