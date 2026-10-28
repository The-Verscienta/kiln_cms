# Moving JSON-in-text fields to a group

Before the `:group` field type existed, a list — the dosages of an herb, its
safety warnings — could only be kept as a JSON string in a `:text` custom
field. Every client then parsed that string itself, and whatever shape an
importer had left behind broke them: an object where a list was expected, a
list encoded twice, or plain prose where JSON was expected.

`mix kiln.fields.convert` moves those values into a `:group` field, whose
rows Kiln validates on every write
([group fields](extending-content.md)). It changes the field's type, so it
follows **expand / migrate / contract** (`docs/releasing.md`, "Migrations:
expand, migrate, contract"):

1. **Expand:** add the group next to the old field.
2. **Migrate:** convert the values. Clients move to the group.
3. **Contract:** a release later, delete the old field.

## The task

```bash
mix kiln.fields.convert <content_type> <source_field> --to <group_field> [options]
```

| Option | Effect |
| --- | --- |
| `--apply` | Write. Without it the run is a **dry run** that writes nothing. |
| `--org SLUG` | The organization to convert (default: the default org). |
| `--map OLD=NEW` | Rename a key in every row before coercion. Repeatable. `NEW` must be a sub-field. |
| `--skip-invalid` | Write the valid records even if some are invalid. The invalid ones keep only their string. |
| `--overwrite` | Also rewrite records whose group already holds rows. |
| `--report PATH` | Also write the report as JSON. |
| `--batch N` | Records read per page (default 100). |

In a release, run the same conversion against the running node:

```bash
bin/kiln_cms rpc 'KilnCMS.Release.convert_field("herb", "dosages", "dosage_rows")'
bin/kiln_cms rpc 'KilnCMS.Release.convert_field("herb", "dosages", "dosage_rows", apply: true, map: %{"dose" => "amount"})'
```

### What it reads

The task reads each record's source value and accepts:

- a JSON array of objects, where each object becomes a row;
- a single JSON object, which becomes one row;
- either of these encoded as a JSON string again (`"[{\"amount\":2}]"`),
  up to three levels deep.

Blank values, `null`, `[]` and `{}` count as **empty** and are not written.
Anything else is **unparseable**, and the report says what it found:

```text
is not JSON: "Take 2 g twice daily with food"
```

The task then applies the `--map` renames and coerces the rows through the
same write path an editor's save uses (`Changes.ApplyCustomFields`). The
group's own rules apply exactly: sub-field types, `required`, `:select`
options, `min_items`/`max_items`, and refusal of unknown keys. A row that
fails is reported with its path:

```text
3f2c…  (ashwagandha) — invalid:
    Unit (dosage_rows[2].unit) is not one of the allowed options
```

A group that is not `multiple` holds one row. A source holding several rows is
reported as invalid for such a group, not cut down to the first row. Make the
group repeating first.

### All or nothing

The task checks every record before it writes anything. **Nothing is
written while any record is invalid**, unless you pass `--skip-invalid`. With
that flag the valid records are written, and the invalid ones keep only their
old string until you fix them and run the task again.

The source field is never modified.

### Re-running

A record whose group already holds rows counts as **already converted** and
is skipped, so running the task twice writes nothing the second time. After
you fix the invalid records, running it again converts just those.
`--overwrite` rewrites every record, which is useful after changing `--map`.

### Which records it visits

The task visits drafts as well as published records. A live record with a
pending working copy (its unpublished edits) gets two conversions: the live
value, and the held copy's own value. Otherwise "Publish changes" would bring
back a map without the group. Trashed records are skipped: if you restore one
later, run the task again.

### What it costs

Each converted record costs the same as `mix kiln.media.resnapshot`:

- one versioned update, which the sync delta API sees as a change;
- for a published record, one artifact re-fire job on the `:firing` queue.

There is **no webhook and no notification**. `updated_at` and
`lock_version` stay unchanged, so an open editor does not hit a stale-record
error. A write that races an editor's save loses, is reported as
`not_written`, and is picked up by the next run.

The task reads records in pages (`--batch`) and writes them one at a time, so
converting 5,000 published herbs enqueues 5,000 fire jobs. That is the same
re-fire wave as editing each herb once. On a large site, run it at a quiet
hour, or keep an eye on the `:firing` queue.

## Into a select holding several terms

The task can also target a `:select` field with `multiple: true`. A source
value is then a JSON array of **terms** (`["adaptogen","tonic"]`), or that
array encoded again, and each term is coerced as an editor's save of the
field would be: trimmed, repeats dropped, and each one of the field's
`options` unless the field takes terms of its own (`allow_custom`). `--map`
does not apply, since terms have no keys.

Every report — a dry run included — lists the **distinct terms** with their
counts, and the ones not yet in `options`, most used first:

```text
herb: western_properties → properties: scanned 412, would convert 398 (391 published), …
20 distinct term(s), 2 not in the options:
  nervine (14)
  anti-spasmodic (3)
```

That list is what an admin reviews before deciding: add the terms to
`options`, or open the vocabulary with `allow_custom`. The JSON report
(`--report`) carries the same `terms` and `new_terms`.

Every report also counts the **published** records a run converts: each of
those writes re-fires the record's artifact.

Use a **new** field, as for a group. Retyping the old `:text` field into a
multiple select in place leaves its JSON strings untouched — they are not
wrapped as one-term lists — and the next save of each record refuses them.

## Recipe: Verscienta's herb lists

Verscienta stores `dosages`, `safety_warnings`, `drug_interactions` and
`use_cases` as JSON strings in `:text` fields. Here are the steps for
`dosages`. The other three follow the same pattern.

**Release N — expand and migrate.**

1. Create the group under a **new** name. A group cannot take the old
   field's name while that field exists. Add its sub-fields through the
   code interface or the API:

   ```elixir
   group =
     KilnCMS.CMS.create_field_definition!(
       %{content_type: :herb, name: "dosage_rows", label: "Dosages",
         field_type: :group, multiple: true},
       actor: admin
     )

   for {name, type, extra} <- [
         {"amount", :float, %{}},
         {"unit", :select, %{options: ["mg", "g", "ml", "drops"], required: true}},
         {"form", :string, %{}}
       ] do
     KilnCMS.CMS.create_field_definition!(
       Map.merge(%{group_of_id: group.id, name: name, label: String.capitalize(name),
                   field_type: type}, extra),
       actor: admin
     )
   end
   ```

2. Dry-run, then read the report:

   ```bash
   mix kiln.fields.convert herb dosages --to dosage_rows --map dose=amount --report dosages.json
   ```

   Fix the records it lists. Prose in `dosages` needs a person to turn it
   into rows. Either rewrite the source as JSON, so the next run converts
   it, or write the rows to the group directly, so later runs skip the
   record. Values the sub-fields refuse can be fixed at either
   end. Correct the record, or widen the sub-field (add `"tsp"` to `unit`'s
   options).

3. Apply. Add `--skip-invalid` only if you accept that the remaining records
   keep only their string for now:

   ```bash
   mix kiln.fields.convert herb dosages --to dosage_rows --map dose=amount --apply
   ```

4. Ship the clients reading `custom_fields.dosage_rows`. Until every client
   has moved, they can fall back to parsing `dosages`.

**Release N+1 — contract.** Once no client reads `dosages`, delete the
`dosages` field definition. Deleting it scrubs its stored values from every
record (`Changes.SyncFieldValues`). If the clients should keep the old key,
you can then rename `dosage_rows` to `dosages`. A rename moves the stored
values, but clients see the key change again, so treat it as another
expand/contract step.
