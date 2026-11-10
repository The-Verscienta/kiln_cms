# Moving JSON-in-text fields to a group

Before the `:group` field type existed, a list — the dosages of an herb, its
safety warnings — could only be kept as a JSON string in a `:text` custom
field. Every client then parsed that string itself, and whatever shape an
importer had left behind broke them: an object where a list was expected, a
list encoded twice, or plain prose where JSON was expected.

`mix kiln.fields.convert` moves those values into a `:group` field, whose
rows Kiln validates on every write
([group fields](extending-content.md)), or into a select holding several
terms or a list field ([below](#into-a-select-holding-several-terms)). It changes the field's type, so it
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
| `--map OLD=NEW` | Rename a key in every row before coercion. Repeatable. `NEW` must be a sub-field. Groups only. |
| `--lines` | A list or multiple select target only: read a source that is not JSON as one item per line ([below](#into-a-list-of-values)). |
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
written while any live record is invalid**, unless you pass `--skip-invalid`.
With that flag the valid records are written, and the invalid ones keep only
their old string until you fix them and run the task again.

A record in the trash never blocks the run. If it does not fit, the report
lists it with `(trashed)` after its id and slug, and it keeps its string:

```text
3f2c…  (ashwagandha) (trashed) — unparseable:
    is not JSON: "Take 2 g twice daily with food"
1 trashed record(s) keep their string; they do not block --apply.
```

The site serves only live content, so only live content decides whether a
run writes. Fix a trashed record you mean to restore, or restore it, fix it
and run the task again.

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
back a map without the group.

Records in the trash are converted too, after the live ones, so a record
restored after the contract release still holds the group (#2533). A trashed
record's write fires nothing: its artifacts were removed when it was
trashed, and restoring a published one rebuilds them. The report counts these writes
as `trashed`.

The live records and the trashed ones are two separate reads, so a record
trashed or restored while the task runs can be missed by both. **Run the
task once more right before the release that deletes the source field.** A
second run is cheap: records already converted count as `kept` and are not
written.

### What it costs

Each converted record costs the same as `mix kiln.media.resnapshot`:

- one versioned update, which the sync delta API sees as a change;
- for a published record that is not in the trash, one artifact re-fire job
  on the `:firing` queue.

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
herb: western_properties → properties: scanned 412, would convert 398 (391 published, 2 trashed), …
20 distinct term(s), 2 not in the options:
  nervine (14)
  anti-spasmodic (3)
```

That list is what an admin reviews before deciding: add the terms to
`options`, or open the vocabulary with `allow_custom`. The JSON report
(`--report`) carries the same `terms` and `new_terms`. Both include the terms
of records in the trash: a trashed record can be restored, and its terms
need to be options too.

Every report also counts the **published** records a run converts: each of
those writes re-fires the record's artifact. Records in the trash are not
among them; `trashed` counts those, and their writes fire nothing.

## Into a list of values

A list field (`multiple: true` on a `:string`, `:integer`, `:float`, `:date`,
`:datetime`, `:time`, `:url`, `:email`, `:telephone`, `:color` or `:slug`
field, see
[Make a field hold a list of values](extending-content.md#make-a-field-hold-a-list-of-values))
takes a JSON array of its items, or that array encoded again. A list of
phrases takes strings (`["fatigue","insomnia"]`); a typed list takes its own
values (`[3, 5]`, `["2026-03-01","2026-03-08"]`). Each item is checked and
tidied exactly as the field's own save would, so a list of colors stores
`#FFF` as `#ffffff`, repeats drop out except in a number list, and
`min_items` / `max_items` apply. An item that does not fit makes the record
invalid, and the report names it by its position from 1: `item 2 must be a
date (YYYY-MM-DD)`.

There is no vocabulary to check, so the report lists no terms, and `--map`
does not apply: items have no keys. The target must already be a list: a
single typed field is refused before anything is read (`event_dates is a
single date field — make it a list first`), as is a single `:string` (`… is a
string field that holds one line — make it a list first`).

```bash
mix kiln.fields.convert event dates_json --to event_dates
```

Some importers kept a list as plain text, one item per line ("One service per
line"); pass `--lines` to read a source that is not JSON that way. It works
for any list target, a multiple select included, and each line is then
checked as an item:

```bash
mix kiln.fields.convert clinic services_text --to services --lines
```

Without `--lines`, such a value is reported as unparseable, as for any other
target: prose would otherwise become a one-item list without a word.

Use a **new** field, as for a group. Retyping the old `:text` field into a
multiple select or a list in place leaves its JSON strings untouched — they are not
wrapped as one-item lists — and the next save of each record refuses them.
The same holds when you retype one list into another (a list of strings into
a list of dates): the stored items stay as they were, the fields admin says
so, and the next save of a record refuses an item the new type cannot hold.
To convert them, run this task from that field into a new list field; the
source and the target cannot be the same field.

## Recipe: Verscienta's herb lists

Verscienta stores `dosages`, `safety_warnings`, `drug_interactions` and
`use_cases` as JSON strings in `:text` fields. Here are the steps for
`dosages`. The other three follow the same pattern.

**Release N — expand and migrate.**

1. Create the group under a **new** name. A group cannot take the old
   field's name while that field exists. In the fields admin, create a
   repeating group and add its sub-fields under "Fields in each row". Or
   create them through the code interface:

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
   it, or enter the rows in the group in the content editor (or through
   the API), so later runs skip the record. Values the sub-fields refuse can be fixed at either
   end. Correct the record, or widen the sub-field (add `"tsp"` to `unit`'s
   options).

3. Apply. Add `--skip-invalid` only if you accept that the remaining records
   keep only their string for now:

   ```bash
   mix kiln.fields.convert herb dosages --to dosage_rows --map dose=amount --apply
   ```

4. Ship the clients reading `custom_fields.dosage_rows`. Until every client
   has moved, they can fall back to parsing `dosages`.

**Release N+1 — contract.** Right before it, run step 3 once more, to
catch a record trashed or restored during the first run. Once no client
reads `dosages`, delete the
`dosages` field definition. Deleting it scrubs its stored values from every
record (`Changes.SyncFieldValues`). If the clients should keep the old key,
you can then rename `dosage_rows` to `dosages`. A rename moves the stored
values, but clients see the key change again, so treat it as another
expand/contract step.
