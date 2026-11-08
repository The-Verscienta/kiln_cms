# Syncing field definitions between environments

Custom fields are rows an admin sets up in the console, so moving a model from
staging to production used to mean clicking it through again. `mix
kiln.fields.export` and `mix kiln.fields.import` move the **definitions** — the
fields, their link fields and group sub-fields, and the admin-defined content
types that own some of them — as one JSON file. They never move content.

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

In the console, admins can also download the same file from
`/editor/fields/export.json`. On a release:

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
2 to create, 1 to update, 0 to delete, 14 unchanged
```

`+` creates, `~` lists the attributes that differ, `-` deletes (only with
`--prune`), `?` is a field the target has that the file does not list.

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
| `--prune` | Also delete fields the file does not list (in the owners it does list). |
| `--allow-data-loss` | Proceed with a change that would drop stored values (below). |
| `--actor EMAIL` | Act as this admin (default: the first admin). |
| `--org SLUG` | The organization (default: the default one). |

### What is never done without being asked

- **Fields absent from the file are kept.** They are listed as `?`; `--prune`
  deletes them.
- **Types are never deleted or archived** by an import. A dynamic type in the
  file is created, or has its settings updated; the type's `name` never changes.
- **Dropping stored values is blocked.** A field is *blocked* when records hold
  a value under its name and the import would delete it, change its type, or
  turn a list (`multiple`) into a single value. Nothing is written until you
  pass `--allow-data-loss`, which then behaves exactly as the same edit in the
  console (a delete purges the key from every record). A link or group
  sub-field is judged by its parent's key.
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
    { "kind": "compiled", "type": "post", "fields": [ { "name": "rating", "label": "Rating", "field_type": "integer", "validation": {"min": 1, "max": 5}, "…": "…" } ] },
    { "kind": "dynamic", "type": "recipe", "definition": { "name": "recipe", "label": "Recipe", "…": "…" }, "fields": [ ] }
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
- A key you leave out of a hand-written file takes the attribute's default; an
  unknown key is refused (a typo would otherwise be silently ignored).
- A dynamic type's `definition` is optional on import if the type exists in
  the target already.
- `version` is bumped only for a change old readers cannot understand; a file
  with a newer version is refused rather than half-read.

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
