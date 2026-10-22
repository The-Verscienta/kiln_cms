# Plan: what native apps need from Kiln's delivery

Written 2026-10-22 against Kiln v1.5.0, from the Verscienta iOS/Android work.
Like [path-forward.md](../path-forward.md), this page is a plan, not a status
board: issues win when the two disagree.

## Summary

The Verscienta apps read Phoenix, and Phoenix reads Kiln. Three of the gaps the
app work turned up start in Kiln. All three are additive, so they fit the
1.x contract.

| # | Gap | Fix in Kiln | Size | Target |
|---|-----|-------------|------|--------|
| 1 | No repeating-rows field, so lists are stored as JSON inside a `:text` field | A `:group` field type that owns typed sub-fields, with `multiple` for repeating rows | L (3 PRs) | 1.6 |
| 2 | Prose custom fields are HTML fragments | A `plain` rendition delivered next to the HTML, then a real `:rich_text` field type | S, then M | 1.6 / 1.7 |
| 3 | No Swift client or types | `mix kiln.export.schema --format swift` (Codable), alongside the `.d.ts` emitter; Kotlin next | M | 1.7 |
| 4 | Media custom fields deliver `{id, url, alt}` only | Add dimensions, an explicit variant list and the focal point to the snapshot; placeholder (blurhash) later | M | 1.7 |
| 5 | No sparse fields on the artifact endpoint, no mobile sync guide | `?fields=` on `GET /api/content/:type/:slug`; a docs page on sync for apps | S each | 1.7 |
| 6 | No native starter | A SwiftUI example in `examples/` | M | 1.8 |

The fourth item on the app's list, **offline sync**, is a Phoenix change and not
a Kiln gap. `/api/sync` already exists (#1581). Phoenix has to mirror it or pass
it through. It is out of scope here.

Some things a mobile team might expect to be missing already exist. They need
documenting rather than building:

- **Conditional requests.** `ContentETag` and `PublicCache` already send ETags
  and honour `If-None-Match` on content and artifacts.
- **Change notification.** Signed outbound webhooks exist
  ([webhooks.md](../webhooks.md)). An app's backend can use them instead of
  polling `/api/sync`.
- **Structured rich text in blocks.** The `rich_text` block body is a Portable
  Text array. Only custom fields lack structure (§2).
- **Type generation from one source.** `GET /api/schema` returns JSON Schema
  2020-12. GraphQL SDL and OpenAPI are also published, so quicktype or
  openapi-generator work today. §3 makes Swift and Kotlin first-class.

## 1. Repeating rows: the `:group` field

### What goes wrong today

`FieldTypes` has eleven core types and four built-in ones, and none of them
holds a list of records. Verscienta therefore keeps `dosages`,
`safety_warnings`, `drug_interactions` and `use_cases` as JSON strings inside
`:text` fields. `ApplyCustomFields.coerce/2` only trims a `:text` value, so
Kiln accepts any string. `SchemaExport` then describes the field as
`["string", "null"]`. That means every consumer parses the field on its own,
and each one copes with whatever mix of shapes the importers left. The
prose-in-`dosages` 500 on 2026-10-12 came from this. So did the app's
`use_cases` and `safety_warnings` bugs.

### Design

Kiln already has nearly all of this as **link fields** (R3). Link fields are
`FieldDefinition` rows owned by a parent definition through `link_of_id`. They
are restricted to the scalar `link_field_types/0`. Nesting stops at one level.
They are coerced by the same `ApplyCustomFields` rules as any other field, and
they load into the parent's `link_fields`. A group field reuses that model:

- **Type.** `:group` is a new **core** type. It is not a `Kiln.FieldType`
  plugin type, because coercing it means recursing into `ApplyCustomFields`
  for each sub-field, and only the host can do that.
- **Sub-fields.** These are `FieldDefinition` rows with a parent. Their types
  are the same scalar set as link fields (string, text, integer, float,
  boolean, date, datetime, url, select). Nesting stops at one level, so a
  group cannot hold a group, a media field or a reference. Kiln can loosen
  this later; tightening it after release would break the contract.
- **Multiplicity.** `multiple: false` holds one object (`{"dose": …,
  "unit": …}`). `multiple: true` holds a list of objects, which is the
  repeating rows. `min_items` and `max_items` work as they already do for
  media galleries. `ClearMultiple` must allow `:group`.
- **Storage.** Values are stored in place in the `custom_fields` jsonb, as an
  object or as an array of objects. Unknown keys inside a row are rejected,
  just as a closed custom-field map rejects them. Each row is coerced per
  sub-field, and errors carry the path (`dosages[2].unit`).
- **Schema export.** A group exports as `{"type":"object","properties":…,
  "additionalProperties":false}`, wrapped in `{"type":"array","items":…}` when
  `multiple` is set. The `.d.ts` emitter follows without changes because it
  reads the document, and so does the Swift emitter in §3.
- **Editor.** The field gets a row list with add, remove and reorder. It can
  reuse the sortable list that galleries and reference lists already use.
  Each row renders its sub-fields with the existing scalar inputs.

**Open question: which column owns the sub-fields.** One option is to reuse
`link_of_id` and widen its meaning to "parent field". `LinkField`,
`ClearLinkFieldOptions` and the `link_fields` load then work unchanged, but
the name stops fitting. The other is a new nullable `group_of_id` column,
which is expand-only and safe under `mix kiln.migrations.check`, but it means
`OneFieldScope` becomes a four-way check. **Recommendation: add
`group_of_id`.** The two parents store values in different places (a link
field's value sits in the snapshot's `"link"` map, a group sub-field's value
sits inside the group's own value), and one column for both would hide that
from every reader.

### Migrating existing JSON-in-text data

Add `mix kiln.fields.convert <type> <field> --to group`, which defaults to a
dry run. It parses each record's string, coerces it against the new
definition, and reports every record that does not fit. Prose in `dosages`
is the known case. Nothing is written until the report is clean, or until the
operator passes `--skip-invalid` and accepts that the skipped records stay as
strings. Because the field changes type, this runs as a new field plus a
backfill, and the old field is dropped one release later
(expand/migrate/contract).

### PRs

1. `:group` type, `group_of_id`, coercion, schema export, API round-trip tests.
2. Editor row UI and the fields-admin sub-field editor.
3. `kiln.fields.convert` plus a docs page on moving JSON-in-text fields over.

## 2. Prose fields delivered as HTML

### What goes wrong today

Kiln has no rich-text **custom field**. `:text` is a plain `<textarea>`.
Verscienta's importers put HTML fragments into it, and delivery passes them
through untouched. The app then has to parse them with WebKit on the main
thread. Rich text inside **blocks** is already structured. Only custom fields
have this problem.

### Fix, in two steps

1. **Plain rendition (S, 1.6).** Add an opt-in per definition,
   `deliver_plain: true` on `:text` fields. Delivery then adds
   `custom_fields_plain.<name>`, computed with the existing
   `KilnCMS.PlainText.from_html/1`, which already decodes entities and strips
   tags. Store it as a sibling key, not by changing the value, so current
   readers see no difference. This covers today's data without asking anyone
   to re-enter it.
2. **`:rich_text` field type (M, 1.7).** A custom field edited in the same
   TipTap editor the `rich_text` block uses and stored in the block's
   structured form (the Portable Text array the `rich_text` block body already
   uses). Delivery offers `html`, `plain`, and the structured tree
   that native renderers walk. Sanitizing reuses
   `HTMLSanitizer.sanitize_rich_text/1`. Existing `:text` fields that hold
   HTML move over with `kiln.fields.convert --to rich_text` from §1.

Step 1 does the most for the apps right away. Step 2 removes the cause.

## 3. Swift types

`KilnCMS.SchemaExport.TypeScript` (231 lines) emits a `.d.ts` from the
exported JSON Schema document, not from the registries, so the two emitters
cannot disagree. A Swift emitter can do the same:

- `mix kiln.export.schema --format swift --out Kiln.swift` writes `Codable`
  structs, one per content type and per block. Fields whose type includes
  `"null"` become optionals. `enum`s become `String` enums with an `unknown`
  case, so a new select option cannot break decoding in an app version that
  has already shipped.
- The **block union** becomes an `indirect enum Block: Codable` with a
  hand-written `init(from:)` that switches on `_type`. Unknown block types
  decode to `.unknown`. Because apps update slowly, this case is required.
- Like the TypeScript emitter, it drops what it cannot express (`format`,
  `minimum`).
- Types only, with no Swift HTTP client in-tree. A client is a separate
  package with its own release train. The Verscienta app doesn't need one
  because it reads Phoenix.

**Kotlin** (`--format kotlin`, kotlinx.serialization data classes plus a
sealed `Block` class with an `Unknown` subclass) uses the same structure and
comes second. Dart comes only if a Flutter consumer appears. Put the
JSON-Schema walk the three emitters share into one module, so each language
file only formats output.

**Do §1 first.** Before groups exist, the emitter would type `dosages` as
`String?` and fix the wrong shape into every app build.

## 4. Media payload for apps

A `:media` custom field's write-time snapshot is `%{"id", "url", "alt"}`
(`ApplyCustomFields`, around line 736). An app gets no dimensions, so it cannot
lay out before the image loads. It gets no variant list, so it cannot choose a
size. It gets no focal point, so it crops blind. The data exists already:
`MediaItem` has `focal_x`/`focal_y`, and `Media.Presentation` knows every
variant and its encoding. Only the shape delivered to apps is missing it.

- Add `width`, `height`, `mime_type`, `focal: {x, y}` and
  `variants: [%{label, width, height, format, url, bytes}]` to the snapshot.
  Keep `url` and `alt`, so existing readers are unaffected. Exclude cropped
  labels (`Presentation.excluded_labels/0`) or mark them `cropped: true`.
  The width descriptors in a `srcset` are only valid for uncropped variants.
- Snapshots are taken when a record is saved, so existing records only get
  the new keys when they are next saved. Add a `mix kiln.media.resnapshot`
  backfill, or resolve the extra keys at delivery time. **Recommendation:**
  write the keys into the snapshot (the fired artifacts stay self-contained)
  and ship the backfill task with the change.
- Apply the same shape to the `image` block's JSON surface, so an app has one
  media decoder.
- **Later:** a blurhash or dominant colour computed in `VariantWorker` when the
  variants are made. This needs a new column on `MediaItem`.

## 5. Payload size and sync guidance

- **`?fields=`** on the artifact and content JSON endpoints. It takes a
  comma-separated list of top-level keys and custom-field names. GraphQL
  already covers selective fetches, so this is for clients that won't run a
  GraphQL stack. Missing names are ignored, and the ETag is computed over the
  filtered body.
- **A "Kiln in a native app" docs page.** It covers how to store the
  `/api/sync` cursor, when to restart with `initial=true` (a refused cursor), backoff, iOS
  background-refresh limits, using ETags for single-record refresh, and webhooks
  as the push path for apps that have their own backend.

## 6. A SwiftUI example

`examples/swiftui-reader`: a list and a detail view over
`GET /api/content/:type/:slug?surface=json`. It uses types generated by §3 and
a file cache kept fresh by `/api/sync`. It is smaller than a client SDK, and
mobile teams evaluating Kiln look for one. Write it after §1 and §3 land, so it
shows rows and generated types rather than workarounds.

## Order

1. §2 step 1 (plain rendition): small, helps the apps right away.
2. §1 PR 1 → PR 2 → PR 3.
3. §3 Swift emitter, once groups export real shapes.
4. §4 media snapshot, in parallel with §3.
5. §5 `?fields=` and the sync guide, in any order.
6. §2 step 2 (`:rich_text`), then §6 the SwiftUI example.

§2 step 1 and §1 PR 1 touch different files and can run at the same time.
