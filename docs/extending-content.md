# Extending the content model

KilnCMS is built around editorial content (title/slug/SEO + a rich block tree),
but real projects also carry **structured reference data**, **relations that
carry data**, and **consumer-facing access tiers**. This guide covers the three
mechanisms that close that gap without forking the core model.

These exist because of decision **D4** (content *types* are compile-time Ash
resources, not a runtime meta-model). They make *fields*, *links*, and *access*
data-driven while keeping types — and their strong guarantees — in code.

## 1. Custom fields (admin-UI-defined schema)

Add typed fields to a content type from the admin UI (`/editor/fields`, admin
only) — no migration, no code change. This is the Directus "add a field in the
UI" workflow, scoped to fields.

- **Define**: `KilnCMS.CMS.FieldDefinition` rows describe each field
  (`content_type`, `name`, `label`, `field_type`, `required`, `options`,
  `allow_custom`, `format`, `option_labels`, `section`, `width`, `widget`,
  `target_type`, `target_types`, `multiple`, `min_items`, `max_items`,
  `max_sources`, `on_target_delete`, `inverse_label`, `inverse_name`,
  `schema_org_property`,
  `link_of_id`, `group_of_id`, `help_text`, `position`, `default`, `compute`,
  `private`, `validation`). Field types: `:string`,
  `:text`, `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`,
  `:select`, `:media`, `:reference`, `:group`, `:user`, `:geolocation`,
  `:datetime_range`, `:recurrence`, `:computed`, the six format types
  `:email`, `:telephone`, `:color`, `:slug`, `:time` and `:json` (see
  "Built-in format types" below) and the composite `:range`, `:key_value` and
  `:link` (see "Range and key-value and link fields") — plus
  anything a plugin registers (see
  [plugin-extensibility.md](plugin-extensibility.md)).
- **Required fields (`required: true`)**: every create or save that sends
  `custom_fields` refuses a blank value. The one exception is the row the
  content editor creates when a writer starts a new document. It is created
  before the writer has seen the fields, so a required field with no `default`
  starts out blank. The editor's first save asks for the value, and
  `:publish` and `:publish_scheduled` refuse a document while a required
  field is blank ("Role (role) is required before publishing").
- **Private fields (`private: true`)**: a value for the site's editors and
  admins only. It is edited like any other field and stored with the rest,
  but it is left out of every fired artifact (so the delivery API,
  `/api/sync`, `?expand=`, static export and webhooks never carry it) and
  out of every read by anyone below editor — anonymous callers, viewers, API
  keys without editor rights — over JSON:API, GraphQL and MCP. Nothing public
  is derived from it either: a computed field cannot read it, and a slug or
  SEO pattern's `[field:<name>]` reads it as empty. Below editor,
  `custom_filter` and `custom_sort` treat it as an unknown field, so a value
  cannot be probed, and the schema export does not describe it. Only the
  plain top-level types can be private (`KilnCMS.CMS.PrivateFields.types/0`),
  and a private field cannot also be `searchable`, `names_record`,
  `deliver_plain`, `deliver_portable` or `:fallback`-localized: each of those copies the value
  somewhere public, so the combination is refused. Flipping it re-fires the
  type's published documents. A role or member's `field_read_grants` can hide
  a private field from some editors too (admins always see it); see
  [Per-custom-field grants and read restrictions](granular-rbac.md#per-custom-field-grants-and-read-restrictions).
- **A person on the site (`:user`)**: a console account — an admin, or a
  member with any role — stored as the user's id and picked in the editor
  from the site's people. It is always private, as Kiln never delivers a
  console account. A value must name someone on the site when it is written.
- **Single image or gallery**: a `:media` field holds one image by default
  (stored as an `%{"id", "url", "alt"}` snapshot). With `multiple: true` it
  is a **gallery**: an ordered list of those snapshots, filled in the editor
  from the library drawer's multi-select and reordered tile by tile. Flipping
  the setting reshapes stored values: a single image becomes a one-image
  gallery, and a gallery keeps only its first image.
- **Sections**: a field's `section` files it under a heading in the content
  editor's Custom fields panel ("Identity", "TCM properties", "Safety"), so a
  type with many fields reads as a few sections instead of one long scroll.
  Every field naming the same section sits under one heading, at the place of
  the section's first field in `position` order; a field with no section
  renders bare where it falls. By default a section is a collapsible
  **accordion**: it starts open when its fields already hold a stored value
  (on a record with none, the first section does), always when one of its
  fields has an error, and closed otherwise; each heading counts its filled
  fields, and *Expand all* / *Collapse all* act on every accordion. An admin
  can lay a section out instead as an always-open **fieldset** or as one
  **tab** of the type's tab set, and pin when an accordion starts open
  (`KilnCMS.CMS.FieldSection`, see "Lay out custom fields as tabs,
  fieldsets or columns" below). A collapsed section's or unselected tab's
  inputs still submit. Editor-only: the value, its delivery and its
  validation are unchanged, and the schema export reports the section as
  `x-kiln-section` (with `x-kiln-section-display` for a fieldset or a tab).
  Record-level fields only — a link field or group sub-field sits inside its
  parent.
- **Width**: a field's `width` (`:full`, the default, `:half` or `:third`) is
  how much of its section's row its input takes in the content editor, so
  short inputs can sit side by side. Below the small breakpoint every field
  takes the full row. Editor-only like `section`, and record-level fields
  only: a link field or group sub-field is always `:full`. It is not part of
  the JSON:API or GraphQL field-definition shape; the schema export reports a
  narrower field as `x-kiln-width`.
- **Editor input (`widget`)**: some fields can be filled in more than one
  way — a single select as a dropdown, radio buttons or a row of buttons;
  several terms as tags or checkboxes; plain text on several lines or one; one
  reference by searching or from a dropdown list; a plugin type's own. The
  field's `widget` names the admin's choice, `nil` being the type's default
  (the input every field had before). Editor-only: what is stored, validated
  and delivered is the same whichever input is chosen, and the schema export
  reports a chosen one as `x-kiln-widget`. See
  [Choose how editors fill in a field](#choose-how-editors-fill-in-a-field).
- **Option labels**: a `:select` field's `options` are the stored values —
  often codes such as `transforming_phlegm` — and `option_labels` maps any of
  them to what an editor reads (`%{"transforming_phlegm" => "Transforming
  phlegm"}`). The editor's select, tag picker and link and group inputs show
  the label; filters, the delivered value and API clients keep the value. A
  write that names a label (ignoring case) stores its value. An option with
  no label is its own label, a label whose option is removed is dropped, and
  a field that stops being a select keeps none. In the fields admin, write
  `value | Label` on an option's line (a label may hold commas).
- **One choice or several terms**: a `:select` field holds one of its
  `options` by default. With `multiple: true` it holds **several terms**: a
  JSON list of strings, in the order the editor arranges them, picked in a
  tag-style picker (chips, a text box with suggestions, drag to reorder) and
  bounded by `min_items` / `max_items`. Terms are trimmed, blanks and repeats
  drop out, and each must be one of the `options` — unless `allow_custom` is
  set, which makes the vocabulary **open**: editors add new terms, `options`
  become suggestions (and may be empty), and the picker also suggests the
  terms already used on the type (`KilnCMS.CMS.SelectTerms`). A new term
  never joins `options`; that list stays the admin's. A JSON-encoded list
  sent as a string (`"[\"a\",\"b\"]"`) is refused rather than stored as one
  term. `custom_filter[<field>]=<term>` asks whether the list contains the
  term (`in` for any of several, `not_eq` for none; `has`, `has_all`,
  `has_none` and `count` work too, see
  [json-api.md](json-api.md#lists-of-values)); the field is not
  sortable. Flipping the setting reshapes stored values (one choice → a
  one-term list; a list → its first term). Only a record-level select can
  hold several terms — not a link field or a group sub-field. To move terms
  stored as JSON in a `:text` field, see
  [field-conversion.md](field-conversion.md).
- **One line or a list of phrases**: a `:string` field holds one line by
  default. With `multiple: true` it holds a **list of phrases** — symptoms,
  indications, synonyms, services — as a JSON list of strings, in the order
  the editor arranges them, bounded by `min_items` / `max_items`. Each item is
  free text, edited in its own input (add, remove, drag to reorder); pasting
  several lines into the add box adds one item per line, and an item written
  with line breaks (an API client's `"a\nb"`) is stored as one item per line.
  Items are trimmed, blanks and repeats drop out, and a JSON-encoded list sent
  as a string is refused. It filters as every list does (`eq` is "contains",
  plus `has`, `has_all`, `has_none` and `count`; see
  [json-api.md](json-api.md#lists-of-values)), is not sortable, and a
  `names_record` list names the record by each
  of its items (a list of synonyms). Not a `:group` with one sub-field: that
  stores `[{"value": "fatigue"}]`, and every client would have to read it so.
  Record-level fields only, as for a multiple select.
- **One value or a list of values**: an `:integer`, `:float`, `:date`,
  `:datetime`, `:time`, `:url`, `:email`, `:telephone`, `:color` or `:slug`
  field holds one value by default. With `multiple: true` it holds a **list**
  of them — the dates of an event, a product's sizes, a clinic's phone
  numbers — as a JSON array in the order the editor arranges them, bounded by
  `min_items` / `max_items`. Each item is checked and tidied exactly as the
  single field would be, and stored JSON-native: numbers as numbers, dates
  and times as their ISO strings (`[3, 3, 7]`, `["2026-03-01",
  "2026-03-08"]`). Numbers keep repeats; every other type drops an item that
  repeats one already in the list once both are tidied (`#FFF` and `#ffffff`
  are one colour). The full rules, the editor and the filters are in
  [Make a field hold a list of values](#make-a-field-hold-a-list-of-values).
  Record-level fields only. `:boolean`, `:text`, `:json`, `:user`,
  `:computed`, `:recurrence`, the composite types and plugin types cannot be
  lists; for a list of composite values use a repeating `:group`.
- **Rich or plain text**: a `:text` field's `format` is `:rich` by default —
  the editor shows TipTap with a short toolbar (paragraphs, bold, italic,
  links, bulleted and numbered lists), and the HTML is sanitized on write to
  the rich-text block's allow-list (`KilnCMS.CMS.TextFormat`). Text with no
  markup, a value that is JSON data, and markup the sanitizer removes nothing
  from are stored byte for byte; the editor
  keeps the plain textarea for JSON data, and seeds TipTap from plain text by
  paragraph. Opening a record never rewrites a value: only an edit does.
  `format: :plain` keeps the textarea and stores the text as typed, for a
  note or a code. The value is a string either way; the schema export marks a
  rich one `contentMediaType: text/html`. For a client that cannot render
  HTML, two per-field options add a sibling map beside `custom_fields`:
  `deliver_plain` adds `custom_fields_plain.<name>` (tags removed; one line,
  or with its paragraph breaks kept when `plain_breaks` is set), and, on
  a rich field, `deliver_portable` adds `custom_fields_portable.<name>`, the
  value as the Portable Text tree a `rich_text` block's `body` holds
  (`KilnCMS.CMS.PortableFields`). Both are off by default and computed when a
  document fires. The schema export types the Portable Text one by `$ref` to
  `portable_text_block`. `deliver_portable` is cleared on a `:plain` field,
  on any other type, and on a link or group sub-field. See
  [native-apps.md](native-apps.md#rich-text-without-a-web-view).
- **One reference or a list**: a `:reference` field holds one record by
  default (an `%{"id", "type", "slug", "title"}` snapshot). With
  `multiple: true` it holds a **list of references**: an ordered list of
  those snapshots, in the order the editor arranges them — the gallery's
  shape. A record may appear once (a repeat is refused, naming it), and every
  id must resolve to a record of the target type the writer can read. Blank
  items drop out; an emptied list clears the field. Flipping the setting
  reshapes stored values like a gallery's (one → a one-item list; a list →
  its first item, and the other items' edges go with them), and the fields
  admin warns before a narrowing save. Single references keep their 1.0
  shape. Reverse fields and the rest of the many-to-many work follow in 1.5
  — see [relationships-plan.md](relationships-plan.md).
- **One target type or several**: a `:reference` field names the type it
  links to in `target_type` ("page", "recipe", compiled or dynamic). To let
  it link to records of **several** types, set `target_types` instead — a
  list of type names (`["page", "post", "recipe"]`). Exactly one of the two
  is set; every name must be a content type on the site, once. Each stored
  snapshot names its own `"type"`, so a value is self-describing, and a list
  of references may mix types. A write to a field with several types must
  name each item's type, `%{"id" => uuid, "type" => "post"}` (a stored
  snapshot already does); a bare id is refused, because ids alone don't say
  which type to look in. A field with one type keeps accepting a bare id,
  and ignores a `"type"` it is handed, as before. In the fields admin,
  *Links to* is a set of checkboxes: one ticked type is saved as
  `target_type`, several as `target_types`. The editor's reference picker
  searches every allowed type and shows each result's type. Narrowing the list leaves stored values alone until that record's
  field is next written, when an item of a type no longer allowed is refused
  by name. The schema export reports the allowed types of every reference
  field as `x-kiln-target-types`.
- **Bylines (`schema_org_property`)**: a `:reference` field may say what its
  targets are to the page in schema.org terms, `:author` or `:contributor`.
  The fired `:json_ld` main node then carries one `Person` per readable
  target under that property, in the field's order, and Kiln's own pages
  name them in their JSON-LD and "By" line. Setting or clearing it re-fires
  the type's published documents. Nil by default; cleared on any other type.
  See [Author profiles and bylines](author-profiles.md).
- **Details on each connection (link fields)**: a `:reference` field may
  declare **link fields** — data that belongs to the connection rather than
  to either record: the quantity of each ingredient a recipe connects, the
  role of each author on a book. A link field is a `FieldDefinition` whose
  owner is the reference field (`link_of_id`) instead of a content type, and
  it uses the same coercion and the same `required` / `default` / `:select`
  rules as any field. Only the plain types are offered (`:string`, `:text`,
  `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`, `:select` —
  `FieldDefinition.link_field_types/0`), and a link field cannot have link
  fields of its own. The values ride on each snapshot as an added `"link"`
  map, and on the connection's edge as its `metadata`:

  ```elixir
  %{"ingredients" => [
    %{"id" => "…", "type" => "page", "slug" => "flour", "title" => "Flour",
      "link" => %{"quantity" => 500, "role" => "main"}}
  ]}
  ```

  A write names an item's link values under `"link"`
  (`%{"id" => uuid, "link" => %{"quantity" => "500"}}`). They merge per
  connection the way top-level keys merge per record: a supplied value is
  coerced, one the item leaves out keeps what that connection stored, and a
  new connection falls to the defaults — so a bare id for a record already
  in the list keeps its link values. A link key no link field declares is
  refused. A connection with no link value has no `"link"` key, and a
  reference without link fields stores exactly what it did before. Renaming
  a link field moves its values in both copies; deleting one removes them;
  deleting the reference field deletes its link fields. In the fields admin
  they are added under the reference as *Details on each connection*; in the
  editor each connected record's row shows one input per link field. Filter
  on them with `custom_filter[ingredients.link.role]=main` (see
  [json-api.md](json-api.md)). The schema export types the `"link"` object
  and lists the names as `x-kiln-link-fields`.
- **Structured rows (group fields)**: a `:group` field holds an object whose
  keys are its **sub-fields** — `FieldDefinition` rows whose owner is the
  group (`group_of_id`) instead of a content type. With `multiple: true` it
  holds a list of those objects (repeating rows: the dosages of an herb, each
  with an amount and a unit), bounded by `min_items` / `max_items` like a
  gallery; without it, one object. Sub-fields take the plain types only (the
  link-field set, `FieldDefinition.link_field_types/0`), so a group never
  holds a group, a media item or a reference.

  ```elixir
  %{"dosages" => [
    %{"amount" => 1.5, "unit" => "g", "form" => "dried"},
    %{"amount" => 10.0, "unit" => "ml", "form" => "tincture"}
  ]}
  ```

  A list kept as a JSON string in a `:text` field moves into a group with
  `mix kiln.fields.convert` — see
  [Moving JSON-in-text fields to a group](field-conversion.md).

  To move a model's field definitions between environments (staging to
  production) with a diff and dry run, see
  [Syncing field definitions](field-sync.md).

  Each key is coerced by its sub-field with the usual `required` / `default`
  / `:select` rules; a key no sub-field declares is refused, a row whose
  values are all blank is dropped, and a lone object sent to a `multiple`
  group is a one-row list. Errors name their path —
  `Unit (dosages[2].unit) is not one of the allowed options`, rows counted
  from 0. Rows have no identity, so a write that names the group replaces
  all of its rows (leaving the key out keeps them). Renaming a sub-field
  moves its key in every row, deleting one removes it, and deleting the group
  deletes its sub-fields; flipping `multiple` reshapes stored values as it
  does a gallery's. The schema export types a group as a closed object
  (`additionalProperties: false`), in an array when `multiple`, and lists the
  sub-fields as `x-kiln-sub-fields`; `custom_filter` answers only `null` on
  it. In the fields admin a group's sub-fields sit under it, as "Fields in
  each row", added, edited, ordered and deleted in place like a reference's
  link fields; the content editor shows a single group as one set of inputs
  and a repeating one as rows an editor adds, removes and reorders (drag a
  row by its handle, or use its arrows), with each problem shown next to the
  row and sub-field its path names.
- **Reverse fields (the other side)**: a `:reference` field may name what
  its targets call it — `inverse_label` ("Recipes using this ingredient")
  and `inverse_name` (`used_in_recipes`, suggested from the label when left
  blank). Every record of each type the field may point at then shows a
  **reverse field** in its editor: the records connecting to it
  through that field, with each connection's link values, ordered by title,
  ten to a page. Nothing is stored for it; it is read from the reference's
  edges as the editor, so a source the editor could not open is neither
  listed nor counted. The machine name is unique among the reverse fields
  of every type the reference may point at. In the fields admin it is
  *What Ingredient calls this*; GraphQL reads it as
  `referencedBy(inverse: "used_in_recipes")`; the schema export reports
  `x-kiln-inverse` on the reference and `x-kiln-reverse-fields` on each
  target type. `KilnCMS.CMS.ReverseFields` is the reader.
  An editor can also add, remove and reorder connections from the reverse
  field. Each change is an edit of the *source* record (decision D23): its
  own update as that editor, or a save of its working copy when it is
  published, so the source's permissions, validations, history and lock all
  apply. A held change is marked "goes live when *Source* is published", a
  source the editor may not change shows a lock, and a source someone else
  saved in the meantime fails on its own row.
- **Item bounds**: on any list (`multiple: true`), optional
  `min_items` / `max_items` bound how many items a value holds once it holds
  any — an empty optional field is still allowed; `required` asks for at
  least one. They are checked when a record's field is written, so tightening
  one leaves stored values alone until then. Both clear when `multiple` does.
- **A limit on the other end (`max_sources`)**: `min_items` / `max_items`
  bound how many records one *source* connects to. `max_sources` bounds the
  other end: how many records may connect to any **one target** through the
  field — "each Author is on at most 3 Books", a seat, a slot, a featured
  place. Blank means no limit. It is checked inside the source record's own
  write, where the connection's edge is written, so every path that connects
  a record is held to it: the editor, an API write, a reverse edit, and
  *Publish changes* on a working copy (an add staged while the target had
  room is refused when it is published if the target filled up meanwhile).
  Only a target the write **adds** is checked — removing or reordering is
  never refused — and every connection counts whatever its source's state:
  a draft or a trashed source holds its slot, because trash keeps the
  connection for a restore. Concurrent writes are serialized per target by a
  transaction-scoped advisory lock, so two records racing for the last slot
  cannot both get it. The refusal names the target and the count ("“Jane
  Doe” is full: it already has 3 of 3 connected"), never the records already
  connected. Tightening the limit leaves existing connections alone; it
  applies to the next add. In the editor's picker a full target is listed
  but disabled, "Full — 3 of 3 connected"; on the target's own page its
  reverse field shows "3 of 3" beside the heading and offers no add while
  it is full. The schema export reports it as
  `x-kiln-max-sources`.
- **When a target is deleted for good (`on_target_delete`)**: what purging a
  connected record does to this field's connections to it. `:keep` (the
  default, and the behaviour before 1.5) leaves the connection as a broken
  reference until someone edits the referrer. `:clear` removes the purged
  record from every referrer's value — one write per referrer, made by the
  CMS itself inside the purge's transaction, versioned like any edit; the
  other items of a list keep their order and their link data, the edges
  follow, a held working copy loses it too, and a published referrer is
  re-fired, so nothing delivered still names the purged record. `:restrict`
  refuses the purge while any record connects through the field; the trash
  explains why and what to do. All three act on the **permanent** delete
  only: moving a record to the trash keeps every connection, so restoring it
  needs nothing. The nightly purge of old trash leaves a restricted record
  out (the content types' `:purgeable` read), so it stays in the trash,
  without a failed job each night, until it is unlinked. In the fields
  admin the rule is asked as "When a linked *Type* is deleted for good…";
  the schema export reports a non-default rule as
  `x-kiln-on-target-delete`. Both options clear on any field type but
  `:reference`.
- **Several types at once**: tick more than one content type and the form
  creates one definition per type under the same machine name. They are
  separate rows: each is edited, renamed or deleted on its own. The machine
  name fills itself in from the label (`FieldDefinition.name_from_label/1`)
  until you edit it, and a name already defined on any ticked type is refused
  before anything is written.
- **Store**: values live in the `custom_fields` map on each content record.
- **Validate**: `KilnCMS.CMS.Changes.ApplyCustomFields` runs on every write — it
  coerces values to the declared type, enforces `required`, checks `:select`
  membership, and applies defaults. Values are stored JSON-native (dates as
  ISO-8601 strings) so the jsonb column round-trips. A key **no definition
  declares is an error**, not a silent omission: the write fails naming the key
  and listing the fields the type defines. (Copy machinery — restore,
  duplicate, translate, import — passes `context: %{custom_fields: :drop}` and
  drops such keys with a warning instead, since its payload comes from
  elsewhere.)
- **Rename / retire**: renaming a definition moves the stored values to the new
  key; destroying one purges them. Either way no record is left holding a key
  no definition declares — such a key is dropped by whatever writes that record
  next, which is how an unrelated title edit came to be what destroyed an
  editor's prose. (A destroy really does mean the values go: `custom_fields` is
  public, and a deleted definition must stop publishing what was under it. It
  just happens where the admin asked for it.)
- **References are edges too**: a `:reference` value is stored as a snapshot
  (`%{"id", "type", "slug", "title"}`) *and* as a `ContentLink` edge
  (`kind: :reference`, `field` the field's name; a list of references has one
  edge per item, `position` its place in the list; `target_type` the item's
  own type, `metadata` the item's `"link"` map) written with the live value
  (#1594; D20 in [content-organization-plan.md](content-organization-plan.md),
  adopted additively — the snapshot stays the value, the edge is added beside
  it, rather than the edge becoming the source of truth as D20 proposed). The edge is
  what answers "what links here" — the editor lists it under *Linked from*,
  and the API serves it through `incoming_links`. A published record's
  working copy holds draft references without edges until they are published.
  See `KilnCMS.CMS.ContentLinks`.
  **A reader only sees the references they could follow.** The snapshot is
  taken whatever state the target was in, so every read leaves out an item
  whose target the reader could not read directly (a draft, a gated or
  passphrase-locked page): a list loses the item, a single-valued field reads
  as `null`. The fired artifact is masked as an anonymous reader; JSON:API and
  GraphQL as the caller, and editors and admins see the value whole. The
  stored value is never changed, and the item reappears once the target is
  readable. See `KilnCMS.CMS.ReferenceSnapshots`.
- **Edit**: the content editor renders one input per definition automatically,
  in a *Custom fields* panel under the blocks.
- **History**: the editor's version compare shows each custom key on its own
  with its label, a typed value (`KilnCMS.CMS.FieldDisplay`) and an
  added / removed / changed pill, and a restore previews itself first, listing
  stored keys whose definition is gone as discarded. The stored history is
  unchanged: a version's `changes` still carry `custom_fields` as one whole map.
  The single-revision API read adds `changed_custom_fields`, the sorted keys
  that write added, removed or edited (see [api.md](api.md)).
  See [Comparing and restoring versions](working-copy.md#comparing-and-restoring-versions).
- **Deliver**: `custom_fields` is public, so headless clients get the values.
- **Read typed over GraphQL**: `customFloat(name: "price")`,
  `customString`, `customInt`, `customBoolean`, `customDate`,
  `customDateTime` and `fields(names: [...])` return a field with a GraphQL
  type, with no deploy when an admin adds the field (the schema types the
  accessor, not the name). See
  [headless-graphql-api.md](headless-graphql-api.md#read-custom-fields-typed-by-kind).
  A plugin field type chooses its kind with `graphql_kind/1` (below).
- **Query**: list/search reads accept `custom_filter`/`custom_sort` (JSON:API)
  and `customFilter`/`customSort` (GraphQL) — typed, registry-validated
  filtering and sorting on individual custom fields (see
  [json-api.md](json-api.md) → "Custom fields").

```elixir
# Defined once in the UI (or in code/seeds):
CMS.create_field_definition!(%{
  content_type: :page, name: "spice_level", label: "Spice level",
  field_type: :select, options: ~w(none mild medium hot), required: true
}, actor: admin)

# Then editors just fill it; the value is validated on save:
CMS.create_page!(%{title: "Habanero salsa", slug: "habanero-salsa",
  custom_fields: %{"spice_level" => "hot"}}, actor: editor)
```

### Show custom fields on the content list

Editors and admins can put a few custom fields on each row of the content list
(`/editor`), so a catalogue can be scanned without opening every record. The
choice is personal: it is stored on your own user, per site and per content
type, and does not change what anyone else sees.

1. Open **Content** (`/editor`) and, in the type filter ("Filter by type"),
   choose one content type. On a site with several types, "All types" shows
   the hint *Choose a content type to show its fields as columns.* instead,
   because field names can repeat across types. A site with one authorable
   type needs no choice.
2. In the list's header bar (beside the select-all box and count), click
   **Columns**. A panel opens listing the type's fields. If the button is
   missing, the type has no field that can be shown.
3. Tick the fields you want. The panel says *Show fields on each row. Pick up
   to 6; the first 4 show.* The list reloads at once and each row gains a
   strip of `label value` pairs under its date line. Once six are ticked, the
   unticked boxes are disabled.
4. Untick a field to remove it. Your choice is remembered for this site and
   type the next time you open the list, and is not in the URL or in saved
   views.

"First 4" means the first four in the panel's order (the field order of the
type), not the order you ticked them in. Ticks beyond four are kept but not
shown.

Fields offered: string, text, integer, float, boolean, date, datetime, url,
select, reference, user, media, email, telephone, color, slug and time, if
they hold one value. Groups, geolocation, JSON, date ranges, recurrence,
computed fields and multi-valued fields are not offered. Private fields are
offered, as editors already see them in the content editor, except one a read
grant hides from you.

What a cell shows:

| Field | Cell |
| --- | --- |
| reference | the target's current title as you can read it, or "Unavailable" (the title saved in the field is never shown) |
| user | the person's name; "Unnamed user" without one; never the email; "Unavailable" for someone no longer on the site |
| select | the option's label |
| boolean | Yes / No |
| media | alt text, else the file name |
| empty | a dash |

Long values are cut at 80 characters.

**What can go wrong.** *Your choice could not be saved.* means the write was
refused (for example the field was deleted or made unavailable since the panel
loaded); reload the list and pick again. A remembered field that has since been
deleted, or made something the picker does not offer, drops out silently.

For code: the choice is `User.content_list_columns`, a nullable map
`%{org_id => %{type => [field name]}}`, written by
`KilnCMS.Accounts.set_content_list_columns(user, org_id, type, names, actor: user)`
(self only). Names are checked against the site's field definitions, at most 6
per type, and merged into the stored map under a row lock. Which definitions
may be offered is decided by `KilnCMS.CMS.ListFields.readable_fields/4`; cell
text comes from `KilnCMSWeb.EditorLive.FieldCells`.

### Built-in format types

Six field types check and tidy a value so a malformed one cannot be saved.
Pick them in the fields admin like any other type; the editor, the API and an
import all run the same check, and the stored value is the tidied one.

| Type | Editor input | Stored as | Notes |
| --- | --- | --- | --- |
| `:email` | email input | `Ada@example.com` (domain lowercased, local part keeps its case) | Shape check only: one `@`, a dotted domain, at most 254 characters. It cannot tell whether the mailbox exists. |
| `:telephone` | telephone input | E.164, `+442079460958` | A format check only: spaces, dashes, dots and brackets are stripped and a leading `00` becomes `+`; what is left must be `+`, a non-zero digit and 6 to 14 more digits. Kiln has no numbering-plan data, so a real number cannot be told from a plausible one. A domestic number (`020 7946 0958`) or one with an extension is refused: include the country code. |
| `:color` | text input with a pattern | lowercase `#rrggbb` (`#F80` becomes `#ff8800`) | Named colours, `rgb()` and alpha are refused. It is a text input, not `type="color"`, because a colour picker cannot be empty and would fill every optional colour field with `#000000` on save. |
| `:slug` | text input with a pattern | `cafe-menu` | Typed text is slugified (`Café Menu!` becomes `cafe-menu`), at most 128 characters; input with nothing left is refused. Not filled from another field: to derive a slug, use a `:computed` field. Can be made unique (see [Constrain the values of a field](#constrain-the-values-of-a-field)); values are compared once tidied, so `Hello World` and `hello-world` collide. |
| `:time` | time input | `"09:30"` (24-hour, zero-padded, no date or zone) | Accepts `H:MM`, `HH:MM`, `HH:MM:SS`; seconds are dropped. |
| `:json` | monospace textarea, pretty-printed | the object or array itself | See below. |

In the API, `:email`, `:telephone`, `:color`, `:slug` and `:time` are strings;
`:json` is the generic JSON value. The schema export describes the formats
(`format: "email"` or a `pattern`).

**JSON fields.** The value must be an object or an array (a bare number or
string is refused). Limits: 256 KB of input text, 64 KB once re-encoded, 32
levels deep and 5,000 values; a string or key containing a NUL character is
refused (Postgres `jsonb` cannot store it). Filtering answers only "Empty or
not" (`custom_filter` with `null`; any other operator is refused with *custom
field "x" (json) only supports null*), a JSON field cannot be sorted (the
refusal reads *is not sortable*), and it is not in the Columns picker. If an
admin flags it **searchable**, the strings and numbers nested in the value are
indexed (not the keys), so flag only a field whose contents are prose worth
finding.

**Names are reserved.** `email`, `telephone`, `color`, `slug`, `time`,
`json`, `range`, `key_value` and `link` can no longer be used for a type an overlay or plugin registers; rename
it (`mix kiln.plugins.doctor` fails otherwise). A stored field definition
that already used one of these names as its `field_type` is now cast by the
built-in type: values that do not pass its check are refused on the next save.

**Not yet:** number options (step, prefix, suffix, slider), a colour
palette, and JSON Schema validation of a `:json` value.

### Range and key-value and link fields

Three more built-in types hold a small structured value. Each is stored as
JSON, checked identically in the editor, the API and imports, and served
through GraphQL as the generic JSON value. Pick them in `/editor/fields` (an
admin task) like any type; the editor shows the inputs below.

| Type | Editor input | Stored as |
| --- | --- | --- |
| `:range` | two text inputs, "From" and "To" | `{"min": 10, "max": 20}` or `{"min": "2026-01-31", "max": "2026-12-31"}` |
| `:key_value` | textarea, one `key=value` per line | `[{"key": "Weight", "value": "2 kg"}]` |
| `:link` | "Address", "Label", an "Opens in" select (Default / Same tab / New tab) and "Rel" | `{"url": "https://example.com", "label": "Source", "target": "_blank", "rel": "noopener noreferrer"}` |

**Range.** Both bounds are numbers or both are `YYYY-MM-DD` dates (the kind is
read from the values). At least one bound is needed, so a half-open range such
as `{"min": 18}` is valid; with both, `min` may not exceed `max`. A numeric
string becomes a number; `NaN`, `Infinity`, date-times and numbers beyond
±9,007,199,254,740,991 are refused. A range is never indexed for search, even
if flagged `searchable`. The exported JSON schema (`GET /api/schema`) states
the same rule: beside the merged `min`/`max` object, an `anyOf` allows two
number bounds, two date bounds (each with at least one bound present) or
`null`, so a validator refuses a mixed or empty range as a save does. The
generated TypeScript types it as `{ max?: number; min?: number } | { max?:
string; min?: string } | null`; the Swift and Kotlin models keep one struct
whose bounds are any JSON value.

**Key/value.** Order is kept, which is why the value is a list of pairs and not
an object. Split at the first `=`, so a value may contain `=`; blank lines are
skipped. Limits: 100 pairs, a key of 1 to 100 characters, a value of up to
1,000, 64 KB in all. Keys are unique (case-sensitive), single-line, and may not
contain `=`. An API client may send a list of `{key, value}` maps, or a plain
map, which is stored sorted by key. A `searchable` flag indexes the values, not
the keys.

**Link.** The address (at most 2,048 bytes) is stored only if it passes
`KilnCMS.HTMLSanitizer.safe_href/1` unchanged, the policy rich-text links use:
`http(s)`, `mailto:`, a relative path (`/about`) or a `#fragment`. `javascript:`,
`data:`, `tel:` (use a `:telephone` field) and protocol-relative `//host`
addresses are refused rather than stored. The label is up to 200 characters.
`target` is `_blank` or `_self`; `rel` takes any of `noopener`, `noreferrer`,
`nofollow`, `sponsored`, `ugc`, `external`, and a `_blank` target always adds
`noopener noreferrer`. A `searchable` flag indexes the label only. This type
has nothing to do with the "link fields" (edge metadata) of a `:reference`
field.

```elixir
KilnCMS.CMS.FieldTypes.Link.cast(
  %{"url" => "https://example.com", "label" => "Source", "target" => "_blank"},
  nil
)
#=> {:ok, %{"url" => "https://example.com", "label" => "Source",
#=>         "target" => "_blank", "rel" => "noopener noreferrer"}}
```

**Lists.** None of the three can be a Columns picker column, be sorted, or be
a condition source for another field. A `custom_filter` answers only "Empty or
not" (`null`); any other operator is refused with *custom field "x" (range)
only supports null*, and a sort with *is not sortable*. `multiple` is cleared
on these types, and validation constraints (min, max, pattern, unique) are
refused.

**What can go wrong.** *needs a minimum, a maximum, or both* (an empty range);
*bounds must both be numbers or both be dates (YYYY-MM-DD)*; *the minimum must
not be greater than the maximum*; *each line must be key=value*; *every value
needs a key*; *has a repeated key (x)*; *a key may not contain "="*; *address
must be an http(s) URL, a mailto: address, a /path or a #fragment*; *rel must be
one or more of: noopener, noreferrer, nofollow, sponsored, ugc, external*.

### Make a field hold a list of values

A number, date, date-time, time, link, email, phone, colour or slug field can
hold a list instead of one value: the dates an event runs on, the sizes a shoe
comes in. You need the admin role to set it up; any editor who may edit the
record fills it in.

1. Open `/editor/fields`. Under **Add a field**, keep **This field holds** on
   **A value**, tick the content types under **Content types**, and fill in
   **Label** (`Event dates`) and **Machine name** (`event_dates`).
2. Choose the **Field type**, here **Date**. A **Holds** choice appears with
   **One value** and **A list**.
3. Choose **A list**. A **How many items** box appears with **Minimum** and
   **Maximum**; fill in either, both or neither (`10` as the maximum).
4. Click **Add field**. Under **Defined fields** the new field carries a
   **list** badge.
5. Open a record of that type in the content editor. The field shows an add
   box under its items.
   - For a number, link, email address, phone number or slug, type a value
     and press Enter. Pasting several lines adds one item per line.
   - For a date, date-time, time or colour, pick or type a value, then press
     Enter or click **Add** beside the box. Picking a date alone adds nothing,
     so a half-picked date is never added. A colour is typed as a hex value
     (`#ff8800`).

   Each item appears as its own input, with a count above the list. Edit an
   item in place, remove it with ×, or drag it by its handle to reorder. At
   the **Maximum** the add box is replaced by *At the limit of 10 items.*
6. Save. The record stores the items in screen order. A date or other item
   that is already in the list is not added a second time; numbers may repeat.

The same field through the code interface, and a write to it:

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "event_dates", label: "Event dates",
  field_type: :date, multiple: true, max_items: 10
}, actor: admin)

CMS.update_post!(post, %{custom_fields: %{
  "event_dates" => ["2026-03-08", "2026-03-01", "2026-03-08"]
}}, actor: editor).custom_fields["event_dates"]
#=> ["2026-03-08", "2026-03-01"]
```

How a list behaves:

- **Each item is the single field's value.** It is checked and tidied as the
  single field would be: a time `9:30` is stored `09:30`, a colour `#FFF`
  `#ffffff`, an email's domain is lowercased, a date-time `T10:00` becomes
  `T10:00:00`. Numbers are stored as JSON numbers, everything else as a
  string.
- **Repeats.** An integer or float list keeps repeats (`[3, 3, 7]`): a
  quantity may repeat on purpose. Every other list drops an item equal to one
  before it once both are tidied, so `#FFF` after `#ffffff` is dropped.
- **Shapes a write may send.** A JSON array; a bare value (stored as a
  one-item list); a string item with line breaks (one item per line). Blank
  items drop out, and an empty list clears the field. An object or boolean
  item, or a JSON-encoded list sent as one string (`"[1, 2]"`), is refused.
- **Required and bounds.** **Required** asks for at least one item.
  **Minimum** and **Maximum** count items once the field has any; tightening
  them leaves stored lists alone until the field is next written.
- **Value rules apply per item.** A `min`, `max`, length or `pattern` rule
  ([Constrain the values of a field](#constrain-the-values-of-a-field))
  checks each item and names it by its index from 0, `scores[1]` for the
  second. Items the record already stored are not checked again. `unique`
  cannot be set on a list.
- **Turning a list on or off.** Choosing **A list** for a field that already
  has values wraps each one in a one-item list. Going back to **One value**
  keeps the first item of each list; the form warns before you save.
- **Retyping a list.** Changing a list's **Field type** to another type that
  can be a list (a list of strings into a list of dates) keeps every stored
  item as it was, not converted, and the form says so. An item the new type
  cannot hold is reported when that record is next saved. To convert the
  items, add a **new** list field of the type you want and copy them into it
  with [`mix kiln.fields.convert`](field-conversion.md#into-a-list-of-values),
  which refuses to convert a field into itself.
- **Formulas skip a list.** A computed field reads a list as no number and no
  text: `sum`, `min` and `max` leave it out, and interpolation renders it
  blank. The fields admin warns when you make a field a list that a formula
  reads.
- **Conditions.** A **Show when** / **Required when** rule may read a list
  of numbers, dates, date-times or links (the types a rule can read at all).
  **is** then holds when the list contains the value, and **is one of** when
  it contains any of them. **is greater than** / **is less than** are
  refused on a list, which has no single value to order, and making a field
  a list is refused while such a rule reads it.
- **Where it can be.** On a content type or dynamic type only, not on a
  link field or a group sub-field. For a list of composite values (a
  date range with a label), use a repeating `:group`.
- **The content list.** A list field is not offered under **Columns**, so
  it is not among the **Field conditions**, the field sorts or the export's
  columns either.

Reading and filtering it:

- **JSON:API** carries the array as stored under `custom_fields`.
  `custom_filter[event_dates]=2026-03-01` finds records whose list contains
  that date; `has`, `has_all`, `has_none` and `count` work too. Comparing
  items (`gt`, `lt`) and matching text in them are not supported yet, and a
  list is not sortable. See [Lists of values](json-api.md#lists-of-values).
- **GraphQL** serves a `ListValue` of `IntValue`, `DateValue`, … items, and
  `customWhere` takes the item's kind (`int: {eq: 10}`); see
  [headless-graphql-api.md](headless-graphql-api.md#typed-filters-customwhere).
- **The schema export** describes it as an array of the single field's
  schema, with `uniqueItems: true` except on integer and float lists, and
  `x-kiln-min-items` / `x-kiln-max-items` when set:

  ```json
  "event_dates": {
    "type": ["array", "null"],
    "items": {"type": "string", "format": "date"},
    "uniqueItems": true,
    "x-kiln-max-items": 10,
    "description": "The items, in the order the editor arranged them."
  }
  ```

What can go wrong when saving (the field's label and name come first, as
`Event dates (event_dates) …`):

| Message | Meaning |
|---|---|
| `item 2 must be a date (YYYY-MM-DD)` | The second item, counting from 1, is not a value of the field's type. The rest of the message is the single field's own. |
| `must be a list of values (got …)` | An item is an object, a boolean or another list. |
| `holds a JSON-encoded list — send the items as a list instead` | A string such as `"[1, 2]"` was sent; send `[1, 2]`. |
| `needs at least 2 items (has 1)` / `can have at most 10 items (has 11)` | Outside **Minimum** / **Maximum**. |
| `(scores[1]) must be at most 10` | A value rule failed for the item at index 1 (the second). |
| `can't compare … with greater/less than: it holds a list` | In the fields admin: a **Show when** / **Required when** rule orders on a list field, or the field is being made a list while one does. |

### Filter and sort the content list by custom fields

With one content type listed, editors and admins can narrow the content list
(`/editor`) by that type's custom fields ("price at least 10", "colour is red")
and order it by one of them. Both live in the URL, so a link or a saved view
carries them, and "Load more" keeps them.

1. Open **Content** (`/editor`) and choose one content type in "Filter by
   type". With "All types" on a site with several types, the filter panel says
   *Choose a content type to filter by its fields.* instead, because field
   names can repeat across types. A site with one authorable type needs no
   choice.
2. Click **More filters**. Under **Field conditions** pick a **Field**, a
   **Condition** and a **Value**, then click **Add condition**. The list
   narrows at once, a chip such as `Price ≥ 10` joins the others above the
   list, and the count updates.
3. Add up to four conditions. Adding the same field and condition again
   replaces the earlier one; two conditions on one field with different
   operators (a range: "At least" and "At most") both count.
4. Click a chip to remove its condition.
5. To order by a field, open **Sort by** and pick an entry from the **Field**
   group, such as *Field: Price (↑)* or *Field: Price (↓)*. Rows with no value
   in that field come last in both directions.
6. To keep the result, use **Save view**; opening the view restores the
   conditions and the sort.

Changing the content type clears the conditions and the field sort: a field
of the same name on another type is a different field.

What each field type offers (the **Condition** menu):

| Field | Conditions |
| --- | --- |
| string, url | Is, Contains, Empty or not |
| text | Contains, Empty or not |
| integer, float | Is, Greater than, At least, Less than, At most, Empty or not |
| boolean | Is (Yes / No), Empty or not |
| date | Is, From, Until, Empty or not |
| datetime | From, Until, Empty or not (whole days, both ends included) |
| select | Is (one of its options), Empty or not |
| reference, user, media | Is (the target's id, a UUID), Empty or not |
| email, telephone, slug | Is, Contains, Empty or not |
| color | Is, Empty or not |
| time | Is, From, Until, Empty or not |

"Contains" is a case-insensitive substring match; `%` and `_` in the value
mean themselves. "Empty or not" asks *Empty* or *Has a value*. A value is at most
100 characters; longer is refused.

Only single-valued string, text, integer, float, boolean, date, datetime, url,
select, email, telephone, color, slug and time fields can be sorted by; the
**Field** group lists just those. Fields the Columns picker does not offer
(groups, geolocation, JSON, date ranges, recurrence, computed and multi-valued
fields) cannot be filtered either. A value typed into a condition on an email,
telephone, color, slug or time field is cleaned the way the field cleans what
an editor saves (a colour's case, a time's padding), so `#FF8800` finds
`#ff8800`; "Contains" is matched as typed.
Private fields are offered, because editors already see them in the content
editor; the list is editor-only, and a person without read access to a field
cannot filter or sort by it (a link naming it simply ignores that condition).

**The count.** With field conditions, the header reads *1000+ items* once more
than 1000 records match, rather than an exact figure: a field condition scans
the site's records of that type, and the count stops early. Without conditions
the count is exact, and a field sort alone does not change it.

**Saved views.** A view stores its conditions. If a field in a view has since
deleted, made private to you, or retyped so a stored value no longer fits (or
its sort field is gone), the view shows a warning icon (*This view names a field that
no longer applies.*) and opening it says *The view "…" named a field that no
longer applies, so that condition was left out.* The remaining conditions still
apply.

**What can go wrong.** When you click a download in the list, a refusal sends you back
to the list (with the same filters, except what the refusal was about) and shows the
message at the top. A script, or anything that does not ask for HTML, gets the status
code below with a JSON body `{error, message}`; a person without an editor account gets
the JSON 403 either way.

- *That field filter is not valid here.* The field, condition or value is not
  one the type offers (for example text typed into a number, or a select value
  that is not an option).
- *A list holds at most 4 field filters, and they must fit a saved view.* Remove
  a chip first, or shorten a long value.
- *The field filter or sort could no longer be applied, so it was cleared.* The
  field was deleted or changed while the list was open; the list reloads
  without field conditions.

For code and links: two URL parameters carry the state.

| Parameter | Value |
| --- | --- |
| `cf` | up to four conditions, `field:op:value` joined by `;`, field and value URL-encoded, in order by field then op |
| `sort` | `field:<name>` (ascending) or `-field:<name>` (descending) |

```
type=product&cf=color:eq:red;price:gte:10&sort=-field:price
```

(Shown decoded; in the address bar the browser percent-encodes `:` and `;`.
Inside a field name or value a `:` or `;` is itself percent-encoded, so the
separators are unambiguous.) The ops are `eq`, `contains`,
`gt`, `gte`, `lt`, `lte` and `null` (value `true` for empty, `false` for has a
value); `datetime` takes a date (`2026-11-01`). `cf` is stored in saved views
too, with a 600-character limit instead of 200. **This format is a URL and
saved-view contract**: stored views hold it, so changing it later has to keep
reading the old form. Anything that is not valid for the single
type in play (unknown or private field, an op the type does not offer, a value
that does not cast, more than four conditions) reads as absent, never an error.

Parsing and encoding are in `KilnCMSWeb.EditorLive.Filters`
(`conditions/1`, `field_sort/1`, `add_condition/5`, `dropped_conditions/2`).
`KilnCMS.CMS.ListFieldQuery.arguments/3` is the only place that turns the list's
conditions into the read arguments `custom_filter` / `custom_sort` of
`CustomFieldQuery` (see [JSON:API](json-api.md)); `ContentTypes.list!/2` and
`count!/2` pass them through the `arguments:` option, and `count!/2` accepts a
`limit` in `query:` to bound a count.

### Export the content list as CSV or JSON

Editors and admins can download what the content list (`/editor`) shows, for a
spreadsheet or a script, as CSV or JSON. The download holds the rows the list
would show for the same filters, so there is nothing new to learn about which
rows are in it.

1. Open **Content** (`/editor`) and set the list up as you want it: choose a
   content type, a status, a search, field conditions or a field sort. To
   include custom-field columns, choose one content type and tick them under
   **Columns** first (see "Show custom fields on the content list" above).
2. In the header bar click **Export**. The panel reads *Export 214 matching*
   (the number of rows the download will hold) and *Exports the columns shown
   in the list.*
3. Click **Download CSV** or **Download JSON**. The browser saves
   `content-<type>-<date>.csv` (or `.json`; `content-all-…` for all types).
4. To download only some rows, tick them in the list and click **Export
   selected** in the bar that appears. That file is always CSV.

If the panel reads *More than 10,000 rows — narrow the list first*, add a
filter; the download would be refused.

**What is in the file.**

- Always, in this order: `id`, `type`, `title`, `slug`, `status`, `locale`,
  `updated_at` (ISO 8601).
- Then the custom fields you chose under **Columns** for that content type
  (the first four, as the list shows them), headed by the field's name. A
  field named like one of the seven above is headed `fields.<name>`. With
  "All types" on a site with several types there are no field columns.
- In JSON the file is one array; each record is an object with the seven keys
  and a `fields` object holding the field columns.
- Nothing else is exported: no body, blocks or translations.
- The columns are your saved ones, never taken from the link, so a link
  cannot widen what a download holds.

**Which rows.** The types you can author, the same as the list (a type you can
read but not author is not listed and cannot be exported; asking for it gives
*You cannot export that content type.*). Every read runs as you, so a record
you cannot read is absent. With "All types" the types are exported one after
another, a type at a time, not merged into one order as the list does. The
list's status, search, locale and other filters, its field conditions (`cf`)
and its field sort carry over. A `cf` condition on a private field is accepted
for an editor even when that column is not exported, as in the list.

**Export selected** ignores every filter except the type: a selection made
before you changed a filter is not narrowed by it. It takes at most 100 rows
(the ids travel in the address); above that the button is disabled and says
*Select at most 100 rows to export.* Ids that do not exist, or that you
cannot read, are simply missing from the file.

**Private fields.** Private fields, and every user field (a user field is
always private), are left out unless you tick **Include private fields** in
the Export panel. The box appears only when the type has such a field you
could show as a column. Ticking it changes the download links; it does not
change the list. A private field your role hides from you
([granular-rbac.md](granular-rbac.md#per-custom-field-grants-and-read-restrictions))
is never exported, with or without the box, and `private=1` does not bypass it.

**What a cell holds.** The file is data, not a copy of the screen, so some
values differ from the on-screen text:

| Field | CSV | JSON |
| --- | --- | --- |
| number | the number | a number |
| boolean | `true` / `false` (not Yes / No) | `true` / `false` |
| select | the option's stored value, not its label | the same |
| media | the file name (not the alt text) | the file name |
| reference | the target's title as you can read it | `{"id": "…", "label": "…"}` |
| user | the person's name, never the email | the name |
| unreadable or deleted target | `Unavailable` | `{"id": null, "label": "Unavailable"}` for a reference; `Unavailable` otherwise |
| empty | an empty cell | `null` |

The title saved inside a reference field is never written, so a download
cannot show a title the list would hide. Long values are not cut at 80
characters.

**Limits.**

- **10,000 rows.** The rows are counted first; over the limit the answer is
  HTTP 413 with *This export has more than 10,000 rows. Narrow the list with a
  filter and try again.* Nothing is truncated.
- **60 seconds.** A download that runs longer is stopped.
- **10 downloads a minute per account.** Over it the answer is 429 with a
  `Retry-After` header. A refused request (not an editor, an unknown type, a
  too-large export) spends one of the ten as well. The count is kept per
  server node, so a cluster admits ten a minute on each node. A `HEAD` request
  is answered with headers only and is not counted.

**What can go wrong.**

- *Exporting content needs an editor account.* (403) A viewer, or a request
  without a session. Always JSON.
- *You cannot export that content type.* (403) The type is outside the ones
  you can author.
- *The selection is not a list of content ids.* (400) `ids` was empty or held
  something that is not a UUID.
- *Select at most 100 rows to export.* (400)
- *This export has more than 10,000 rows…* (413)
- A download that is cut off. The count and the stream are not one step, so
  the limits are enforced again while streaming. If rows were added past the
  limit, the 60 seconds ran out, or the database failed part-way, the server
  drops the connection **without finishing the response**: a CSV stops
  mid-file and the browser reports a failed download, and a JSON file never
  gets its closing `]`, so it does not parse. A file that parses completely is
  complete. Narrow the list and download again.

**For scripts.** The two URLs take the same query parameters as `/editor`
(`type`, `status`, `q`, `cf`, `sort`, …) plus `ids` (comma-separated UUIDs)
and `private=1`, and authenticate with the signed-in browser session; there is
no API-key access. For example, with a session cookie:

```
GET /editor/content/export.csv?type=product&cf=price:gte:10&sort=-field:price
```

```
HTTP/1.1 200 OK
content-type: text/csv; charset=utf-8
content-disposition: attachment; filename="content-product-2026-11-07.csv"
cache-control: no-store

id,type,title,slug,status,locale,updated_at,price
2d1c…,product,Saffron,saffron,published,en,2026-11-05T09:12:44Z,12.5
```

The response is chunked, so there is no `content-length`. CSV starts with a
UTF-8 byte order mark so Excel opens it as UTF-8 (`KilnCMSWeb.CSV.parse/1`
strips it). A text value that starts with `=`, `+`, `-`, `@`, a tab or a
carriage return is prefixed with `'` so a spreadsheet does not run it as a
formula; real numbers are exempt, so `-5` in a number field stays `-5`, while
the text `-5` or `=1+1` in an integer field is still guarded. The filename is
the type name reduced to letters, digits, `-` and `_`.

**Configuration.** Both limits can be changed; the defaults are the ones above.

```elixir
config :kiln_cms, :content_export,
  max_rows: 10_000,
  time_limit_ms: 60_000
```

**Observing it.** Each download that ends (including one the browser
abandoned) writes one Logger line, `content export`, and emits
`[:kiln_cms, :content_export, :stop]` with measurement `%{rows: n}` and
metadata `user_id`, `org_id`, `type`, `format`, `rows`, `columns` (names) and
`include_private`. Neither carries a cell value, the filter text or the ids. A
download that aborts at a limit raises instead and emits no event. There is no
audit record of who exported what yet (a follow-up), so the Logger line and
the event are all there is today.

**For code.** `KilnCMSWeb.EditorLive.ListScope` holds the list's scope, shared
by the screen and the download: `types/2`, `filter_ctx/4`, `column_type/2`,
`export_count/6` and `export_path/3`. `KilnCMSWeb.ContentExport` reads the pages
(keyset, 100 rows each, an explicit `select`, references looked up once per
page) and `KilnCMSWeb.EditorLive.FieldCells.value/3` resolves a cell once for
the screen, the CSV (`csv_value/1`) and the JSON (`json_value/2`), so they
cannot disagree about who may see a reference's target. The route handler is
`KilnCMSWeb.ContentExportController`.

### Constrain the values of a field

A field can refuse values that are out of range, too long, in the wrong shape
or already taken. The rules live in the field's `validation` map, are checked
on **every** write (the editor, JSON:API, GraphQL, MCP, importers), and an
editor sees the failure as an error under the field, naming it.

| Constraint | Applies to | Meaning |
|---|---|---|
| `min`, `max` | `:integer` (whole numbers), `:float` | Inclusive bounds |
| `min_length`, `max_length` | `:string`, `:url`, plain `:text` (`format: :plain`) | Length in characters (graphemes) |
| `pattern` | the same text types | A regular expression the **whole** value must match |
| `pattern_message` | with `pattern` | The sentence an editor reads when it does not match |
| `unique` | `:string`, `:url`, `:integer`, `:float`, `:date`, `:datetime`, `:slug` | No other document may hold the same value |

A plain `:text` field takes the text rules but not `unique`. A rich `:text`
field takes no constraints (its value is HTML, so its length means nothing),
nor do the other types. Constraints a type does not take are
refused when the definition is saved, as are unknown keys, `min` above `max`,
a default value that breaks the field's own rules, and a pattern that is not a
valid regular expression.

**Set them** in `/editor/fields` (admin only): open or create a field, and the
form shows a **Validation (optional)** group with only the controls its type
takes (*Minimum value*, *Maximum value*, *Minimum length*, *Maximum length*,
*Pattern*, *Message when it doesn't match*, *Unique*). Or send `validation` on
the field definition (it is a public attribute, so it appears in the JSON:API
field-definition payload and the OpenAPI document):

```json
{"field_type": "string", "name": "sku", "label": "SKU",
 "validation": {"pattern": "[A-Z]{3}-[0-9]{4}", "pattern_message": "Use three capitals, a dash and four digits.", "unique": true}}
```

Saving `{"sku": "abc"}` on a record of that type then fails with
`SKU (sku): Use three capitals, a dash and four digits.`. Without a
`pattern_message` it reads `SKU (sku) doesn't match the required format`.
The other messages are `… must be at least 3`, `… must be at most 10`,
`… must be at least 2 characters long`, `… must be at most 5 characters long`.

How the rules behave:

- **Blank values are not checked.** A blank optional field is simply empty;
  `required` is what makes it mandatory.
- **A list is checked per item**, reported by its index from 0 as `tags[1]`
  (a list of strings, numbers, dates, links, …; see
  [Make a field hold a list of values](#make-a-field-hold-a-list-of-values)). A
  `:group` field checks each row's sub-fields against their own `validation`
  (`dosages[2].unit`).
- **A pattern must match the whole value.** `[0-9]+` accepts `123`, not
  `a123`; you do not write `^…$`. A pattern is at most 200 characters (so is
  its message), is unicode-aware, and runs with match limits: a value over
  2,000 characters, or a pattern that backtracks without end, counts as *not
  matching* instead of hanging the save.
- **Stored values are grandfathered.** A value equal to what the record
  already holds is not re-checked, so tightening a rule never blocks an edit
  to some other field; it applies once that field's value changes. Adding a
  tag to a list that holds one now-too-long tag still saves: on a list only
  the items it did not already hold are checked. Existing data is
  not rewritten or reported.
- **Restore, promote and copy skip the value rules.** A version restore, a
  dynamic type's promotion and a content copy carry values that were valid
  when written, so a rule tightened since does not fail them; it applies on
  the next edit. `unique` is the exception: it is still enforced for a
  restore (from versions or from the trash). A duplicated document starts with
  its unique fields **blank**, so the copy does not claim the original's value.

#### Unique values

A custom field has no column of its own, so there is no database index behind
`unique`. The write path enforces it instead (`KilnCMS.CMS.UniqueValues`): a
lookup while the editor validates, then a transaction-scoped advisory lock on
the value and a second lookup in the transaction, so two saves racing for the
same value cannot both win. The loser gets `SKU (sku) is already in use` (the
message never names the other record, which the writer may not be allowed to
read), or `… is being changed by another save at the same time. Try again`.

- The match is **exact and case-sensitive** on the trimmed value, within the
  same organization, content type and **locale**: translations of one document
  may share a value.
- Trashed records are ignored; drafts and archived records count.
- A working copy only stages a value. The check runs when it reaches the live
  `custom_fields` (publish, or the fold on unpublish); the check while staging
  is advisory.
- `unique` is refused on a `multiple` field, a field inside a group or a
  relationship, a field shared between locales, and a field with a default.
- **Turning `unique` on is refused while the data already repeats**: the save
  fails with `can't require unique values yet: 2 values are shared by several
  records (…). Make them distinct first`. Fix the records, then save again.
- **There is no database backstop.** Raw SQL, `update_all` and a database
  restore bypass the check, and a field made unique while an older node was
  still writing can lag. Audit with the read-only task below.

```bash
mix kiln.fields.duplicates                       # every type of the default org
mix kiln.fields.duplicates --org acme --type herb --samples 20
```

It lists, per content type and field, the repeated values (scoped exactly like
the runtime check), writes nothing, and **exits non-zero** when it finds any,
so it can gate a deploy.

The schema export reports a field's rules as annotations, not as JSON Schema
assertions, because a stored value may predate a rule: `x-kiln-minimum`,
`x-kiln-maximum`, `x-kiln-min-length`, `x-kiln-max-length`, `x-kiln-pattern`
and `x-kiln-unique`. `pattern_message` is not exported. On a `multiple`
string field the text rules apply to each item.

### Geolocation fields

A `:geolocation` field stores a structured coordinate — `lat` and `lng`, plus
an optional map `zoom` and a place `label`:

```elixir
CMS.create_field_definition!(%{
  content_type: :page, name: "venue", label: "Venue location",
  field_type: :geolocation
}, actor: admin)

CMS.create_page!(%{title: "Venue", slug: "venue",
  custom_fields: %{"venue" => %{"lat" => "51.5074", "lng" => "-0.1278"}}},
  actor: editor)
#=> %{"venue" => %{"lat" => 51.5074, "lng" => -0.1278}}
```

The editor renders one labelled input per part. Writers may also post a
`"51.5074, -0.1278"` string, which is what a `default` must be (that column is
a plain string). Latitude is bounded to ±90 and longitude to ±180, so a
transposed pair is usually caught rather than silently relocated.

On the fired `:json_ld` surface each populated geolocation field becomes the
document's `contentLocation` — a schema.org `Place` carrying `GeoCoordinates`
— so structured data falls out of the type with no per-type wiring.

### Date-range and recurrence fields

A `:datetime_range` field is what makes a content type an **event**: when
something starts and ends, in a named timezone, optionally all-day. A
`:recurrence` field alongside it makes that event repeat.

```elixir
CMS.create_field_definition!(%{
  type_definition_id: td.id, name: "when", label: "When",
  field_type: :datetime_range
}, actor: admin)
```

Values are stored as **local wall time plus an IANA zone**, not as a UTC
instant, and expansion is wall-clock so a weekly event holds its local time
across a DST change. A type carrying one gets `.ics` calendar routes
automatically; set the type's `schema_org_type` to `Event` (or a subtype) to
also fire a `schema.org/Event` node. See [events.md](events.md).

### Computed fields

A `:computed` field derives its value from the rest of the document instead of
being typed by an editor. The definition carries a `compute` formula
(`KilnCMS.CMS.Computed`):

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "reading_time", label: "Reading time",
  field_type: :computed, compute: "{{ reading_time(body) }} min read"
}, actor: admin)
```

- **Syntax**: literal text plus `{{ … }}` expressions. A template that is
  *only* an expression keeps the native type (`{{ word_count(body) }}` → an
  integer); anything else is string interpolation. When every expression in
  an interpolated template is blank, the value is blank: `{{ size }} EU` on a
  record without a size has no value, not the value "EU".
- **References**: `title`, `slug`, `locale`, `excerpt`, `body` (the block
  tree's plain text), `seo_title`, `seo_description`, `seo_keywords` — then the
  record's other custom fields by name. `field.<name>` always means the custom
  field, for names that collide with a document scalar.
- **Functions**: text (`word_count`, `reading_time`, `char_count`,
  `slugify`, `upcase`, `downcase`, `capitalize`, `trim`, `truncate`,
  `replace`, `concat`, `join`), numbers (`sum`, `subtract`, `product`,
  `divide`, `round`, `min`, `max`), conditions (`if`, `equals`,
  `greater_than`, `less_than`, `contains`, `is_empty`, `and`, `or`, `not`,
  `default`) and dates (`days_between`, `years_between`, `today`, `year`,
  `format_date`). A condition
  holds unless it is blank, `false`, `0`, the text `"false"`, or an empty list
  or map; a list or map value (a gallery, a reference) is empty only when it
  holds nothing. `sum`, `min` and `max` skip non-numbers (a list of numbers
  included: formulas do not read a list's items), but `product` is
  blank unless every factor is a number, and a blank is neither more nor less
  than anything. There is no `eval`: the allowlist *is* the sandbox, and an
  unknown function or wrong arity fails when the **field is defined**, not
  silently per record.
- **Read-only**: the write pass never consults the submitted payload, so a
  computed field cannot be set through the editor, JSON:API, GraphQL or MCP.
- **Evaluated twice**: on write (so the value is stored and participates in
  search, embeddings and `custom_filter`/`custom_sort`) and again on fire (so
  **editing a formula reaches published content on the next fire**, with no
  re-save sweep). A stale stored value therefore never reaches an artifact.
- **Chaining**: a formula may reference another computed field of the type
  (`{{ sum(subtotal, shipping) }}` over a computed `subtotal`). The computed
  fields are evaluated in dependency order, so each sees the values of the
  ones it reads — on write, on the computed-only refresh after a document
  edit, on fire and in a slug or alias pattern's `[field:…]` token alike
  (`KilnCMS.CMS.Computed.derive/3`). A **loop** — a field reading itself,
  directly or through others — has no value, so it is refused when the field
  is defined or edited, naming the loop (`the formula makes a loop: total →
  subtotal → total`). That includes defining the field that would close a
  loop with existing ones.

**Date-relative values: `today()` and the daily refresh.** Ages, countdowns
and "expired?" flags need the current date:

```text
{{ days_between(today(), event_on) }} days     → 3 days (negative once past)
{{ years_between(born, today()) }}             → 36
{{ if(less_than(expires_on, today()), "Expired", "Current") }}
```

A formula runs on write *and* again on fire, so a clock read inside the
engine would let a record's stored value and its artifact disagree. Instead
`today()` answers a date **pinned once per evaluation pass** and handed to
the engine in its context (`KilnCMS.CMS.Computed.Context`):

- "Today" is the **site's** date — the day in the deployment's timezone,
  `config :kiln_cms, KilnCMS.Events, time_zone:` (UTC unless set), the zone
  the events index already counts days in.
- A write pins it on the changeset; the slug, the alias and every computed
  field in that write read the same date, and the fire it enqueues carries it,
  so the artifact matches what was stored even if the fire runs after
  midnight. Publishing re-derives computed fields on the publish day.
- A formula that calls `today()` anywhere is **time-dependent**
  (`Computed.time_dependent?/1`). Once per site day — the first hourly tick
  after the site's midnight — the `:refresh_time_dependent` scheduled action
  on `FieldDefinition` (`KilnCMS.CMS.Computed.DailyRefresh`) re-derives the
  **published** records of every type with such a field, as the
  `:computed_fields` system actor, and re-fires the ones whose value moved.
  The write is versioned (the sync API reports it) but sends no webhook,
  keeps `updated_at`, and never bumps the lock an open editor holds; an
  editor who saved meanwhile wins. Drafts move on their next save or publish.

So a value is right **for the whole day**, not to the second, and moves
overnight. To refresh by hand (after changing the timezone, say):
`CMS.refresh_time_dependent_fields(Date.utc_today(), actor:
KilnCMS.SystemActor.new(:computed_fields))`.

**Building a formula without writing one.** Custom fields → Add a field →
*Computed* opens the formula builder, in two views over the same `compute`
formula:

- **Recipe** — pick a common computation (reading time, word count, a value
  with a label, combine values, URL slug, shortened text, first non-empty
  value, total, multiply, percentage, *if … then …*, days between dates, days
  until a date, age in years) and
  fill its blanks from dropdowns of the document's values and the type's other
  fields, computed ones included (less any that already read this one). The page shows the formula the recipe writes
  (`KilnCMS.CMS.Computed.Recipes`).
- **Formula** — write the template by hand, with buttons that insert a value
  or a function at the caret, and every function listed with its signature and
  what it does. `today()` sits under *Dates*, marked as refreshed daily.

Both preview the result live against the type's most recently edited
documents (or sample text when there are none), through the same evaluator
the save and publish paths use — on today's site date, with a note under the
result when the formula is time-dependent. Nothing extra is stored: editing a field
re-reads its formula, and opens it in the recipe view when it is exactly a
recipe's output, in the formula view otherwise — so a formula changed by hand
is never rewritten by a recipe.

**When to use a real attribute instead.** Custom fields cover the long tail of
editor-owned fields. A field that is core, needs a DB constraint/index, or is
filtered/sorted on every request still belongs as a hand-declared Ash attribute
on the resource (with a `mix ash.codegen` migration). Custom fields are jsonb,
queryable via `custom_filter`/`custom_sort`. Equality, `in` and list
membership use one GIN index over the whole `custom_fields` column; range
filters and sorting read an index only for a field named in
`config :kiln_cms, :indexed_custom_fields`, and scan the type's rows
otherwise. See
[Which custom filters use an index](json-api.md#which-custom-filters-use-an-index).

### Make a field conditional

A field can appear only when another field has a certain value, and be
required only then: a "Reason" that shows up when "Kind" is "Other", a "Venue"
that is required for events. You need the admin role. Rules are per field and
read the fields beside it (the same content type or dynamic type, or, for a
group's sub-field, the same row).

1. Open `/editor/fields`, find the field and choose **Edit** (or fill in the
   **Add a field** form for a new one).
2. Expand **Conditions**. It lists **Show when** and **Required when**. If it
   says there are no other fields to test yet, the type has no text, number,
   date, yes/no or choice field to read.
3. Under **Show when**, choose **Add a condition**. Pick the field, the test
   (**is**, **is not**, **is one of**, **is empty**, **is not empty**, and
   **is greater than** / **is less than** for number and date fields) and the
   value. For **is one of**, type the values separated by commas.
4. Add more tests if you need them. With two or more, a selector appears:
   **All of these are true** or **Any of these is true**.
5. Do the same under **Required when** if the field should be mandatory only
   in some cases.
6. Save (**Add field** or **Save**). The Conditions heading now shows how many
   conditions the field has.
7. Open a document of that type. Change the field the rule reads: the
   conditional field appears or disappears at once, and saving is blocked
   with "is required" while a **Required when** rule holds and the field is
   empty.

The same rule, as a code interface call:

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "reason", label: "Reason",
  field_type: :string,
  visible_when: %{"field" => "kind", "op" => "eq", "value" => "other"},
  required_when: %{"all" => [
    %{"field" => "kind", "op" => "eq", "value" => "other"},
    %{"field" => "reviewed", "op" => "eq", "value" => true}
  ]}
}, actor: admin)
```

A rule is a leaf (`field`, `op`, `value`; `empty` and `not_empty` take no
`value`, `in` takes a list of 1 to 50) or an `all` / `any` list of rules,
nested at most 3 levels with at most 10 tests. The same attributes read back as
`visible_when` / `required_when` on a field definition in
`?include=field_definitions` ([json-api.md](json-api.md)) and in the OpenAPI
document; JSON:API and GraphQL do not create or edit definitions.

What to know before relying on it:

- **Hidden is not private.** A hidden field keeps its stored value, and the
  JSON:API, GraphQL, search and computed fields still see it. Mark the field
  **Private** to keep a value out of public reads.
- **The server enforces it on a normal write.** A hidden field is never
  required. A value sent for a hidden field is still checked and stored. A
  restore and a copy that drops custom fields skip **Required when**, and a
  record saved before the rule existed is not rechecked by an unrelated
  write.
- **No cascade.** A rule reads the stored or submitted value of the field it
  names even if that field is itself hidden.
- **Dates and times.** `is greater than` / `is less than` compare numbers and
  ISO dates or datetimes with seconds, and are false when a value can't be read
  as one. The browser's `datetime-local` input sends no seconds, so on a
  datetime field these two tests never hold; use a date field, or `is empty`
  / `is not empty`.
- **Renaming and removing.** Renaming a field rewrites the rules that read it.

If saving a definition fails, the message appears under **Conditions**:

| Message | Meaning |
|---|---|
| `is not a valid condition: it …` | The rule has a bad shape, an unknown operator, a missing value, or exceeds the depth or size limit. |
| `names X, which is not a field beside this one` | The field was removed or sits in another type or group. |
| `can't depend on the field itself` / `would depend on itself through other conditions` | A self reference or a cycle. |
| `can't depend on X, a private field` | A private value may not steer what a viewer sees. |
| `can't depend on X: a … field has no simple value to test` | Only text, number, date, yes/no and choice fields can be read. |
| `can't compare X with greater/less than: it is not a number or a date` | `gt` / `lt` on another type. |
| `can't compare X with greater/less than: it holds a list` | `gt` / `lt` on a list field (`multiple`). |
| `is not available for a link field` / `… for a computed field` / `… for a group field` | These carry no conditions. |
| `is used in the conditions of …; remove those conditions first` | Deleting a field other rules read. |
| `… reads this field in its condition: …` | Changing the type of, making private, or making a list of a field another rule reads in a way the change would break. |

A rule nested beyond one level (set through the code interface) is shown in
the admin UI with a note and a **Remove condition** button; it is left as it is
until removed.

### Give a field a dynamic default

A field's **Default value** is fixed text. For dates, owners and locales the
useful default is computed when the record is created. In `/editor/fields`
(admins), the **Default comes from** select on a new or existing field offers,
for the field's type:

| Source | Value | Field types |
|---|---|---|
| **Today's date** (`today`) | the site's current day, the same one `today()` answers in a computed formula | date |
| **The current date and time** (`now`) | the moment of creation, UTC, to the second | date and time |
| **The user creating the record** (`current_user`) | the writing person, when they are on the site | person |
| **The site's default language** (`site_locale`) | `KilnCMS.I18n.default_locale/0` (for a choice field, only when it is one of the options) | text line, choice |
| **A copy of another field** (`copy_of`) | the value the same create supplies for the field named under **Field to copy** | any single-valued text, number, date, yes/no, choice or person field, copying a field of the same type |

1. Open **Fields**, add or edit a field of one of those types.
2. Under **Default comes from**, pick a source. For a copy, pick the **Field to
   copy**. The fixed-value input steps aside: a source replaces the fixed
   default.
3. Save. Create a record of that type (in the editor, **New**): the field is
   already filled in.

As a code interface call:

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "opened_on", label: "Opened on",
  field_type: :date, default_source: :today
}, actor: admin)
```

What to know before relying on it:

- **Create only.** A value you type always wins. Clearing the field on a later
  edit leaves it empty (a fixed default would put itself back); a field added
  after a record exists is not back-filled. A copy or a restore of a record
  carries its values and defaults nothing.
- **The editor's New button starts from a title-only draft**, so **copy of**
  has nothing to copy there. It works for creates that carry values (the
  JSON:API, imports, forms).
- **Conditions.** A field hidden by its **Show when** rule on the new record's
  values is not defaulted.
- **Field grants.** The default is the system's value, not the editor's edit:
  an editor whose `field_grants` do not cover the field still gets it on
  create, and the grant check ignores it while the payload left the field
  blank. A value the editor supplies for an uncovered field is refused as
  ever.
- **No fit, no value.** No acting user, a locale that is not one of the
  options, or a blank source leaves the field empty; **Required** then reports
  it like any empty field.
- **Rules.** A source the type cannot take is dropped on save, and a source
  clears the fixed default. A copy must name another top-level, single-valued
  field of the same type that does not itself copy, and a private field can
  only be copied into another private one.

### Lay out custom fields as tabs, fieldsets or columns

A type with thirty fields is easier to fill when its Custom fields panel is
split into a few tabs, with short inputs side by side. You need the admin
role. You start from a content type (compiled or dynamic) that already has
some custom fields; nothing about the stored values changes.

1. Open **Fields** (`/editor/fields`) and choose **Edit** on a field of the
   type. In **Section**, type the heading it belongs under, for example
   `Clinical`, then **Save**. Do the same for every field of that section,
   and for the type's other sections. Fields with the same section name are
   one section; the sections appear in the order of their first field, so
   drag a field (or use its arrow buttons) to move a whole section.
2. Below the type's list of fields, a panel headed **Sections of** *type*
   now lists each section in use, in the order the editor shows them. It
   appears once at least one field of the type has a section.
3. For each section, pick **Shown as**:
   - **Accordion: a heading that opens and closes** — the default, and what
     every section was before.
   - **Fieldset: always open, under its heading** — a bordered group with no
     toggle.
   - **Tab: one tab of the type's tab set** — every tab section of the type
     joins **one** tab set, placed where the first of them would be, with
     the tabs in section order. Fields with no section, and accordion or
     fieldset sections, stay outside the tab set, where they fall.

   The choice is saved as soon as you change the select; there is no Save
   button.
4. For an accordion, pick when it **Starts**: **Automatically (open when it
   holds a value)**, **Open (expanded)** or **Closed (collapsed)**. The select
   is disabled for a fieldset or a tab ("Only an accordion opens and
   closes."), and the choice you made is kept for when the section is an
   accordion again.
5. To put short fields side by side, **Edit** a field and set **Width** to
   **Full row** (the default), **Half a row** or **A third of a row**, then
   **Save**. Two half-width fields, or three third-width ones, share a row
   within their section; on a small screen each takes the full row.
6. Open a document of the type in the editor. The **Custom fields** panel
   shows the layout: the tab set with the first tab selected (or the first
   tab holding an error, after a refused save), fieldsets open, accordions
   opening as you set them, narrow fields side by side. Editors see the same
   layout; they cannot change it.

In the tab set, the keyboard works like any WAI-ARIA tab list: **Tab** moves
onto the selected tab, **Left** and **Right** move to the previous or next
tab and select it (wrapping at the ends), **Home** and **End** go to the first
and last, and **Tab** again moves to the selected tab's panel, then into its
fields.

The same layout as code interface calls (admin actor; for a dynamic type, pass
`type_definition_id:` instead of `content_type:`):

```elixir
CMS.update_field_definition!(dose, %{section: "Clinical", width: :half}, actor: admin)
CMS.update_field_definition!(route, %{section: "Clinical", width: :half}, actor: admin)

CMS.create_field_section!(
  %{content_type: :post, name: "Clinical", display: :tab},
  actor: admin
)
```

`display` is `:accordion` (the default), `:fieldset` or `:tab`; `initially` is
`:auto` (the default), `:expanded` or `:collapsed` and is read only for an
accordion. A section with no `FieldSection` row is an `:auto` accordion, and
the fields admin deletes a row you set back to that default.

`GET /api/schema` (and `mix kiln.export.schema`) reports the layout on each
field, for a client that builds its own form from the schema. Defaults are
left out: `x-kiln-section-display` appears only for a `fieldset` or `tab`
section, and `x-kiln-width` only for a `half` or `third` field. The fields
above export as:

```json
"dose": {
  "type": ["string", "null"],
  "x-kiln-section": "Clinical",
  "x-kiln-section-display": "tab",
  "x-kiln-width": "half"
}
```

A client should gather every field whose section is a `tab` into one tab set,
as the editor does. When an accordion starts open is not exported. Neither
`width` nor the section layouts are part of the JSON:API, GraphQL or MCP
shapes, and they travel between environments with the field definitions
([field-sync.md](field-sync.md)).

What to know before relying on it:

- **Hidden inputs still save.** A field in an unselected tab or a collapsed
  accordion is only hidden: its value submits with the rest of the form.
- **A required field you cannot see is shown on save.** If a required field
  in another tab or a collapsed accordion is empty, saving switches to that
  tab or opens that section so the browser can point at the field.
- **After a refused save the error tab is marked, but may not be selected.**
  Every tab holding an error shows a red exclamation icon, and while you
  have not picked a tab yourself the panel selects the first of them. Once
  you have clicked or arrowed to a tab, a save the server refuses keeps your
  tab selected; look for the icon.
- **Renaming a section.** Rename it on each of its fields. When you rename
  the last field still carrying the old name, the layout moves to the new
  name, unless the new name has one already. Deleting a section's last field
  deletes its layout.
- **Width is per section.** A narrow field shares a row only with the
  fields of its own section, and with neighbours in `position` order. A
  conditional field that is hidden leaves no gap.
- **Promoting a dynamic type keeps its layout.** `mix kiln.promote_data`
  moves the type's fields (with their `section` and `width`) and its section
  layouts to the compiled type together.
- **Two admins at once.** The **Sections of** panel saves the row you
  change, then deletes layouts no field names any more, reading both fresh,
  so a section another admin has just added keeps its layout.

Why a layout is its own row, keyed by the section name: [ADR 0047](decisions/0047-a-sections-layout-is-its-own-row-keyed-by-the-section-name-not-a-setting-on-each-field.md).

If something does not save, the page shows one of these:

| Message | Meaning |
|---|---|
| `You can't change custom fields.` | You are no longer an admin of this site (the role was changed after the page loaded). Nothing was written. |
| `Couldn't save the section layout.` | The layout write failed, typically because another admin saved the same section's layout at the same moment. Reload the page and set it again. The same message after a field **Save** or **Delete** means the field was saved but its section's layout did not follow the rename or the delete. |

The page lists the sections as they were when it loaded. A layout you set for
a section another admin has since emptied (by renaming or deleting its last
field) is not kept; reload to see the current list.

### Choose how editors fill in a field

A short list of choices reads better as radio buttons than as a dropdown, a
code fits on one line, and a reference to one of a dozen records is quicker to
pick from a list than to search for. Each field can say which input the
content editor shows for it. You need the admin role.

1. Open **Fields** (`/editor/fields`). Choose **Edit** on a field, or fill in
   **Add a field** for a new one.
2. Settle the settings the choice depends on first: the **Field type**,
   **One choice** or **Several terms** for a select, **Plain text** under
   **Editing** for a text field, the single-record choice for a relationship.
   An **Editor input** group appears with a card for each input the field can
   use, the default checked. If no such group appears, the field has no
   choice (see the table below).
3. Pick a card:

   | Field | Cards (default first) | Stored `widget` |
   |---|---|---|
   | Select, **One choice** | **Dropdown**, **Radio buttons**, **Buttons** (a row of segments) | `dropdown`, `radios`, `buttons` |
   | Select, **Several terms** | **Tags**, **Checkboxes** | `tags`, `checkboxes` |
   | Text, **Plain text** | **Several lines**, **One line** | `textarea`, `single_line` |
   | A relationship to one record | **Search as you type**, **Dropdown list** | `autocomplete`, `dropdown` |
   | A plugin field type that offers inputs | the plugin's own labels | the plugin's names |

   Formatted (rich) text, a list of references, every other type, a
   relationship's link fields and a group's sub-fields have no choice.
4. Save (**Add field** or **Save**). In the list of fields, the field's row
   now carries a badge naming its input (for example *Radio buttons*). The
   default input has no badge.
5. Open a record of that type in the editor. Under **Custom fields**, the
   field uses the input you chose.

The same field as a code interface call:

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "mood", label: "Mood",
  field_type: :select, options: ~w(calm bright stormy), widget: "radios"
}, actor: admin)
```

`widget` is a string; leave it out (or `nil`) for the type's default. It reads
back as `widget` on a field definition in `?include=field_definitions`
([json-api.md](json-api.md)) and in the field sync file
([field-sync.md](field-sync.md)), and the schema export (`GET /api/schema`)
adds `"x-kiln-widget": "radios"` to a field whose stored input it still offers.
A field with no `widget` stored carries no annotation (the admin's default card
stores none; a code interface call that names the default stores it). In code, read the input a field
actually uses with `KilnCMS.CMS.FieldWidgets.resolve/1`, not the attribute.

What to know before relying on it:

- **Only the editor changes.** The value, its validation, its delivery and
  the API are the same whichever input is chosen, so you can switch inputs on
  a field that already holds data.
- **Checkboxes save in option order.** The editor posts the ticked boxes in
  the order they are drawn, so saving a record stores its terms in the
  field's option order, whatever order they were in before. Tags keep the
  order the editor arranges.
- **Checkboxes and new terms exclude each other.** Checkboxes draw only the
  field's options. While **Editors can add new terms** is ticked, the
  Checkboxes card is disabled (*Not while editors can add new terms.*); while
  Checkboxes is chosen, the new-terms box is disabled (*Checkboxes show only
  the options. Pick Tags as the editor input to allow new terms.*).
- **Over 50 options, the editor keeps the default.** Radio buttons, buttons
  and checkboxes draw one input per option, so on a field with more than 50
  options the editor shows the dropdown (or the tags) instead. The fields admin
  says so on those cards (*Over 50 options — the editor shows a dropdown
  instead.*). The stored choice is kept and applies again if options are
  removed.
- **Values the options no longer hold stay visible.** A stored value that is
  not among the options shows as its own radio or checkbox, already checked,
  so saving without touching the field keeps it. An optional radio group also
  has a *— None —* radio; a required one does not.
- **One line keeps line breaks.** A value that already holds a line break
  opens in the several-lines box, so saving it does not drop the breaks.
- **The reference dropdown lists what you can read.** It lists the target
  records you could find by searching, on this site only, sorted by title and
  grouped by type when the field allows several types; *— None —* clears the
  pick. It lists at most 100 records across all target types: past that the
  editor keeps the search box and says *Too many to list — search instead.* A
  target that already has as many links as the field allows (**Each … can be
  linked from…**, `max_sources`) is listed but disabled. The current pick is always listed, as *Unavailable* when you can't
  read it. The list is read when the editor opens, so a record created
  elsewhere since appears after a reload; one you create with **Add new** is
  picked straight away.
- **Changing the field's settings resets the input.** A new type, switching
  to **Several terms**, **Formatted text**, or allowing new terms changes the
  cards, and a stored input the field no longer offers goes back to the
  default when you save. A write that names an input itself (a code interface
  call, a field sync import) is refused instead, with one of these messages:

| Message | Meaning |
|---|---|
| `<name> is not an editor input for this field (use one of: …)` | The field's type and settings don't offer that input. |
| `this field has no choice of editor input` | The field takes no widget at all (rich text, a list of references, a link field or group sub-field, most types). Send `nil`. |
| `checkboxes can't take terms of their own: use tags, or turn off new terms` | `checkboxes` on a select with `allow_custom: true`. |

### Delete a field of an unknown type

A field can name a field type this version of Kiln doesn't know. That
happens after a rollback, for a type a newer version added, or after a
plugin that provided the type was removed from `config :kiln_cms, :plugins`.
Kiln can't check or render such a value, so it hides the field instead of
failing (#2605):

- the content editor doesn't show it, and saving a record keeps the value
  it holds unchanged;
- delivery (`/api/content`, `/api/sync`, webhooks, static export), the
  JSON:API `type-definitions` include, the schema export and the field sync
  export leave it out;
- a private one stays hidden from readers below editor. A public one is
  still in the raw `custom_fields` of a JSON:API read, as it is in the
  reporting views;
- a computed field, or a slug or SEO pattern, that reads it sees nothing, so
  its value can change the next time the record is saved;
- a condition (**Show when**, **Required when**) that reads it stays as it
  is, and the field carrying it can still be edited and reordered. Its edit
  form shows the condition as a note with **Remove condition**, since the
  field picker can't offer the hidden field;
- a content import doesn't bring a value in under its name: the value came
  from the other site's field, so it is dropped like any field this site
  doesn't define.

You have two ways out: bring the type back (upgrade Kiln again, or reinstall
the plugin), and the field works as before with its values intact; or delete
the field. You need the admin role.

1. Open **Fields** (`/editor/fields`). Below the fields of every content
   type you see **Fields of an unknown type**. Each row shows the field's
   label, its machine name, an *unknown type* badge, and a line such as "On
   *Recipe*, of type *star_rating*." (the content type that owns it, and the
   type name as stored). A group sub-field or link field of an unknown type
   is listed here too, "On" the group or reference field it belongs to.
2. Choose **Delete** on the field. The browser asks *Delete this field and
   the values records hold in it? This can't be undone.*
3. Confirm. You see *Field deleted.*, the row is gone, and the value is
   removed from every record of that type. The section disappears with its
   last field.

The section offers nothing but Delete, and Kiln refuses any other change to
such a field, from any client (except that renaming a field its condition
reads rewrites that condition, as it does for any field). To keep the values, back up the database
first: deleting a field can't be undone, and a field export
(`/editor/fields/export.json`) leaves these fields out.

**What can go wrong**

| You see | Meaning |
|---|---|
| *… reads this field in a condition: remove that condition first.* | Another field's condition (**Show when** or **Required when**) reads this field; the message names that field. Edit it, choose **Remove condition**, and delete again. If the field named is listed under **Fields of an unknown type**, it can't be edited: delete it first (or bring its type back), then delete this one. A field-definition destroy from code says the same: `is used in the conditions of …; remove those conditions first`. |
| *Couldn't delete that field.* | The delete was refused for another reason, or the field is already gone. Reload the page. |
| *That field can't be edited.* | The field was deleted, or its type became unknown, since the page loaded. The list reloads. |
| `is not a field type this release knows, so the field can't be changed: delete it, or upgrade Kiln or reinstall the plugin that provides it` | An update of the field from code. Only a destroy is allowed. |
| `can't be changed: its field type (…) is not one this release knows. …` | A content write (JSON:API, a code interface call) sent the field with a value other than the one stored. Leave the key out, or send back exactly the value you read. |

For developers: a read of field definitions leaves these rows out unless it
passes `context: KilnCMS.CMS.FieldDefinition.all_types_context()`, and
`KilnCMS.CMS.FieldDefinition.unknown_type?/1` tells them apart. Relationship
loads (`link_fields`, `group_fields`) stay filtered either way.

## 2. Relations that carry data

`KilnCMS.CMS.ContentLink` links any two content records by id with a named
`kind`. Each link can also carry a payload — `metadata` (a free map) and an
optional `label` — so a relation can describe *itself* (a quantity and role on a
recipe→ingredient link, substitution notes, an ordered "step N").

There are two ways to fill that payload:

- **Typed, from the admin UI** — a `:reference` custom field with link fields
  (§1, *Details on each connection*). Its edges (`kind: :reference`) carry
  each connection's link values in `metadata`, coerced against the link
  fields and copied from the snapshot's `"link"` map in the same transaction
  as the write, so the two copies cannot disagree. Don't write those edges
  yourself: they are rebuilt from the field's value on every save.
- **Free-form, in code or over the API** — a curated link (any other
  `kind`) created with `CMS.create_content_link!/2`, or through
  `POST /api/json/content-links` by anyone who may update the source record
  (see [json-api.md](json-api.md), *Writing relationships*). Its `metadata`
  is whatever map you give it; nothing declares or checks its keys.

```elixir
CMS.create_content_link!(%{
  source_id: recipe.id, target_id: ingredient.id,
  kind: :ingredient, label: "Main ingredient",
  metadata: %{"quantity_g" => 200, "role" => "main"}
}, actor: editor)
```

A headless client reads a reference field's connections through GraphQL
`references(field:)` / `referencedBy`, or the delivery API's `?expand=`, and
writes them with a `PATCH` of the list or the GraphQL `add…References` /
`remove…References` / `move…Reference` mutations
([headless-graphql-api.md](headless-graphql-api.md), [api.md](api.md)). In
Elixir, read the payload from either end via the `content_links` (outgoing)
and `incoming_links` (reverse) relationships on any content record:

```elixir
recipe = CMS.get_page!(id, load: [:content_links], actor: actor)
Enum.map(recipe.content_links, & &1.metadata)
```

The same table holds the edges of `:reference` custom fields
(`kind: :reference`), so a record's `incoming_links` include the records that
reference it; `CMS.list_backlinks/2` reads them directly. They are kept out of
`related_<type>s`, which stays editor-curated related content only. A link is
readable only by someone who may read both of its ends (editors and admins see
all of their site's).

Payload shape on the wire (JSON:API `?include=content_links`, an
`included` member of type `content_link`):

```json
{
  "type": "content_link",
  "id": "…",
  "attributes": {
    "source_id": "…", "target_id": "…",
    "kind": "reference", "field": "ingredients", "position": 0,
    "source_type": "post", "target_type": "page",
    "label": null,
    "metadata": {"quantity": 500, "role": "main"}
  }
}
```

For a worked example that puts a list of references, a link field and a
reverse field together, see [Author profiles and bylines](author-profiles.md):
an `author` type, several authors per article, and the profile's article
list.

### When to use a dedicated join resource

ContentLink covers the common case with one table. When one relationship needs
a table of its own, **graduate** it to a typed Ash join resource. That is the
case when its link data is numerous or queried on its own, when it needs
indexes of its own, or when SQL should join it directly (decision D22 in
[relationships-plan.md](relationships-plan.md), R10).
`mix kiln.gen.join` turns a `:reference` field into that resource, the same
way `mix kiln.gen.content --from` promotes a dynamic type (§4).

It takes three steps, in this order. Each is its own command, because each
needs the one before it to have run:

```bash
# 1. The resource and its code interfaces, then its table.
mix kiln.gen.join recipe.ingredients
mix ash.codegen graduate_recipe_ingredients && mix ash.migrate

# 2. The copy: a migration moving the field's connections into the table.
#    A second run, so its migration sorts after step 1's.
mix kiln.gen.join recipe.ingredients --data-migration
mix ash.migrate

# 3. After the copy is deployed and checked: delete the field, its stored
#    values and its edges, so there is one source of truth.
mix kiln.join.retire recipe.ingredients --dry-run
mix kiln.join.retire recipe.ingredients
```

Steps 1 and 2 write code only. Like any Igniter task, they show the diff and
apply it when you confirm (`--dry-run` only shows it, `--yes` skips the
prompt). The resource, `KilnCMS.CMS.RecipeIngredientsLink` unless
`--module` names another, has:

- `belongs_to :source` and `belongs_to :target`, to the two content resources
  (`KilnCMS.CMS.Entry` for an admin-defined type), with foreign keys that
  delete a connection when either record is purged, unless the field refused
  its target's purge (below);
- `position`, plus one typed attribute per link field. `:string`, `:text`,
  `:url` and `:select` become `:string`; the others become `:integer`,
  `:float`, `:boolean`, `:date` or `:naive_datetime`. Each is required and
  defaulted as its link field is, and a select keeps its choices as a
  `one_of` validation;
- a `unique_connection` identity on `[:source_id, :target_id]` and an index
  on `target_id`;
- the content read rule as policies. Admins bypass. Editors read and write.
  Anyone else reads a connection only when they may read both records
  (`Checks.LinkEndsReadable`, the rule `content_links` has), and a read-only
  API key cannot write. Removing a connection is an edit of its source, not
  a hard delete of content, so editors may do it;
- code interfaces `list_/get_/create_/update_/destroy_recipe_ingredients_link`,
  plus the ordered `list_recipe_ingredients_links_from` (by source) and
  `list_recipe_ingredients_links_to` (by target).

The field's rules about its targets come with it. Step 1 prints which ones it
carried over, and how, next to the diff (`--dry-run` prints it too):

| The field had | The join resource has |
|---|---|
| `on_target_delete: :restrict` | `on_delete: :restrict` on the target's foreign key. Purging a record that something still connects to is refused first, with the field's own "can't be deleted permanently" error, and the nightly purge of old trash leaves it out, as before. |
| `on_target_delete: :clear` | `on_delete: :delete`. The connections go with the purged record, as clearing it out of each referrer did. |
| `on_target_delete: :keep` (the default) | `on_delete: :delete` as well. **This is a change.** A foreign key cannot point at nothing, so a purge deletes the connections instead of leaving broken references. Set the field to `:restrict` before graduating if purges should stay refused. |
| `max_sources: n` | `change {KilnCMS.CMS.JoinGraduation.SourceCap, max_sources: n}` on the create. It counts the target's other connections under the same advisory lock the field used, in the create's transaction, so two writers cannot both take the last slot. The refusal names the count, never the other records. |

The rules are read from the same organization's definition as the link
fields. Rows of one `bulk_create` are checked against what was committed
before it, not against each other, so connect one at a time where the cap is
tight. The copy in step 2 is not held to the cap: the edges it copies already
were.

The copy carries every connection whose two records still exist: its org,
both ends, its position and its link values. A value of the wrong JSON type
becomes `NULL`, or the link field's default. A connection to a purged record
is a broken reference, and a foreign key cannot point at nothing, so it is not
copied. The migration is safe to run twice.

`mix kiln.join.retire` checks before it deletes anything, in every
organization that defines the field, and refuses unless:

- every connection is in the join table with the same ends, position and link
  values. A connection made after the copy ran is missing; re-run the copy's
  SQL, or make it again in the new table;
- no record holds a value for the field without an edge
  (`mix kiln.links.backfill` writes the edges);
- no working copy holds an unpublished change to the field. Publish or
  discard it first.

The check and the delete run in one transaction that holds `content_links`
still, so a connection made in between waits rather than being lost. On a
release, run it against the live node:
`bin/kiln_cms rpc 'KilnCMS.Release.retire_join_field("recipe.ingredients")'`.

Before you start, know what graduation changes:

- **Readers move too.** Retiring deletes the field's value from
  `custom_fields`, the shape delivery, JSON:API, GraphQL and the fired
  artifacts serve. Point every consumer at the join resource before step 3.
- **It is project-wide.** The link fields are read from one organization's
  definition (`--org`, default the default org), and the copy and the
  retirement cover the field in every organization that defines it.
- **One target type only.** A field that links to several types (R2) is
  refused: a join table has one foreign key per end. Split it into one field
  per target type, then graduate each.
- **Promote types first.** Promoting a dynamic type (§4) moves its entries out
  of the `entries` table, and a join row's foreign key to them would go with
  them. Promote both ends before graduating the relationship.

## 3. Consumer-facing access tiers (audiences)

Editorial `role` (`:admin`/`:editor`/`:viewer`) gates **authoring**. A separate
**audience** axis gates which signed-in end-users may **read** a published
record — independent of role. See `KilnCMS.CMS.Audiences` and
[policy-matrix.md](policy-matrix.md).

- Configure the tiers: `config :kiln_cms, :audiences, [:public, :member, :premium]`
  (`:public` is always implied and must stay first). Compile-time, so the Ash
  `one_of` constraints validate statically.
- Tag content with one `audience` (default `:public`).
- Grant users audiences with the admin-only `:manage_access` action
  (`Accounts.manage_user_access/3`) — never self-service.
- The content read policy: editors/admins see everything; `:public` published
  content stays world-readable; audience-restricted published content is visible
  only to readers who belong to that audience.

Gated content **is** served on the public site (#337 Phase 2), but not by passing
an actor: the delivery reads stay `authorize?: false` with their filter as the
sole boundary, and that filter gained an `audiences` argument the controller
fills from the signed-in user. Omitting it — as every non-delivery caller does —
still yields `:public` content only.

A reader without the audience gets a **paywall teaser** rather than a 404, from a
separate read that requires a non-public audience and never selects the block
tree. Gated URLs are `private, no-store`, and the `audiences` argument is hidden
from the GraphQL schema. See [Paid memberships](memberships.md).

## 4. Dynamic content types, and promoting them (D17)

Admins define whole content types at `/editor/types` with no code deploy —
entries live on the shared generic tier (`KilnCMS.CMS.Entry`), authorable and
deliverable everywhere compiled types are (see
`docs/dynamic-content-types-plan.md`). When a dynamic type outgrows the tier
(you want its own table, typed GraphQL/JSON:API schema, per-field columns),
**promote** it:

```bash
mix kiln.gen.content --from recipe        # generate the compiled resource
mix ash.codegen add_recipes && mix ash.migrate
mix kiln.promote_data recipe              # move entries + versions + fields
```

The data move is transactional and preserves record ids, so taggings and
content links survive untouched; custom-field definitions are re-scoped to the
compiled type (the editor keeps rendering them), and the `TypeDefinition` is
archived. Type definitions are per-site: the generator reads the default
org's `recipe` unless you name another with `--org SLUG`
(`mix kiln.gen.content --from recipe --org acme`). Fields stay data-driven after promotion — promote an individual
field to a real attribute by hand (add the attribute, migrate the JSONB key,
drop the definition) when querying or indexing demands it.

## 5. Plugins (D18)

For everything beyond one project's content model, package your extension as
a **plugin** — compile-time OTP code with one entry module and one config
line, either in a `projects/` directory or, when it needs nothing from the core
but the [`kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md) contract (blocks, field
types, spam checks, image backends), as a Hex, git or `path:` dependency
(#1909). The generator scaffolds the `projects/` shape:

```bash
mix kiln.gen.plugin Ratings --block star_rating --field stars
```

```elixir
config :kiln_cms, :plugins, [Ratings.Plugin]
```

A `Kiln.Plugin` module contributes, per callback (all optional): **block
types** (`Kiln.Block` modules — they join the storage union, editor palette,
firing, search and the XLIFF translation export automatically; see
*Translation vendors — XLIFF 2.0 export/import* in
[localization workflows](localization-workflows.md) for the `translatable:` field option that decides what a translator sees),
**custom field types** (`Kiln.FieldType`
modules — admins pick them in the fields admin like any built-in; the
plugin's `cast/2` coerces + validates every content write to a JSON-native
value, and the editor renders `<input type={input_type()}
{input_attrs(definition)}>`), **admin nav items** and **admin panel
routes** (role-gated, mounted in the admin live session), **supervision
children**, and **Oban queues** (merged at boot). Content types need no
callback: build them on `KilnCMS.CMS.Content` in the plugin's own Ash domain
and register that domain in `:ash_domains`/`:content_domains` — admin CRUD,
webhooks, delivery and workers follow automatically.

**Filters on a plugin field type compare text.** `cast/2` runs on writes
only. A `custom_filter` or `customWhere` operand on a plugin type's field is
compared as the text the client sent, not passed through `cast/2`, because
the `Kiln.FieldType` contract does not promise that `cast/2` is
deterministic. So if `cast/2` tidies a value (lowercases it, say), a client
must filter with the stored spelling. The built-in format types (`email`,
`color`, `telephone`, `time`, `slug`) are the exception: their `eq`,
`not_eq` and `in` operands also match as a save would store them
([json-api.md](json-api.md) → "Custom fields"). A value that is an object or
a list reaches your `cast/2` unchanged, as before: refusing it there, with
`{:error, message}`, is your type's decision.

**Choosing a field type's GraphQL kind.** The GraphQL API serves every custom
field through typed readers ([headless-graphql-api.md](headless-graphql-api.md#read-custom-fields-typed-by-kind)).
A plugin `Kiln.FieldType` whose stored value is a plain scalar can say which
one by implementing the optional `graphql_kind/1` (from `kiln_plugin` 1.4,
`{:kiln_plugin, "~> 1.4"}`):

```elixir
@impl Kiln.FieldType
def graphql_kind(_definition), do: :int   # a star rating stored as an integer
```

The answer is `:string`, `:int`, `:float`, `:boolean`, `:date`, `:datetime` or
`:json`. A plugin cannot add a composite kind (the built-in `geolocation` has
its own `GeolocationValue`). Leave it out for a map, a list or any mixed shape: a type with no
`graphql_kind/1` (or compiled against an older SDK) is served as a
`JsonValue`, and a `multiple` field is always a `ListValue` of its kind. An
unrecognised answer is also treated as `:json`. The kinds are fixed in the
core, so this is a choice among them, not a way to add a GraphQL type.

**Offering a choice of editor input.** A plugin `Kiln.FieldType` that can be
edited in more than one way lists those ways with the optional `widgets/1`
(from `kiln_plugin` 1.4, `{:kiln_plugin, "~> 1.4"}`), the default first. The
fields admin offers them as the field's **Editor input** cards (see
[Choose how editors fill in a field](#choose-how-editors-fill-in-a-field)) and
stores the pick as a string in the definition's `widget`. Only the editor
reads it, so the type renders the difference itself, by asking
`Kiln.FieldType.widget/2` inside `input_attrs/1`, `input_parts/1` or
`input_hook/1`:

```elixir
@impl Kiln.FieldType
def widgets(_definition), do: [:number, {:stars, "Stars"}]

@impl Kiln.FieldType
def input_attrs(definition) do
  case Kiln.FieldType.widget(definition, __MODULE__) do
    "stars" -> %{min: 1, max: 5, "data-widget": "stars"}
    _number -> %{min: 1, max: 5}
  end
end
```

- An entry is a machine-name atom (lowercase letters, digits and
  underscores, starting with a letter) or `{name, "Label"}`. A name without a
  label is shown humanized (`:number` → *Number*). Fewer than two entries
  offer no choice.
- `widgets/1` receives the definition as it is about to be saved, so it can
  answer differently for a `multiple` field.
- `use Kiln.FieldType` does not define it: the host checks whether the module
  exports it, and a default would have every type claim a choice.
- `input_type/0` takes no definition, so a widget cannot change the input's
  HTML `type`; vary its attributes, parts or hook instead.
- The host never lets a plugin fail a save or the editor: a `widgets/1` that
  raises offers no choice, and a malformed or repeated entry is dropped.
  `mix kiln.plugins.doctor` names both.
- `cast/2`, storage and delivery are the same whichever widget is chosen. A
  widget a later version of the plugin stops offering falls back to the
  first, and the stored name is cleared the next time an admin saves the
  field.

**Removing a plugin that provides a field type.** The fields that use its
type stay in the database, and their values stay on every record. Kiln hides
them: the editor, fired delivery and the exports leave them out (the
JSON:API's raw `custom_fields` still returns a public one), and the Fields
screen lists them under **Fields of an unknown type** with only a Delete.
Reinstall the plugin and they work again; delete them (which deletes their
values) if they are gone for good. See
[Delete a field of an unknown type](#delete-a-field-of-an-unknown-type).
Renaming a type's `name/0` has the same effect, since the stored type is the
name.

**Full-text search needs one migration per type.** The `:search` action
filters on a trigger-maintained `search_vector` column that is not an Ash
attribute, so `mix ash.codegen` never creates it. After the migration that
creates the table, add one calling `KilnCMS.Migrations.add_search_vector/1`
(see its moduledoc for the template; `mix kiln.gen.content` prints it too).

Run `mix kiln.search.check` against a migrated database — it is a CI gate, and
it names every content table missing the column, trigger or index along with
the migration that closes the gap. Skipping it is not confined to the new type:
a global search sweeps every registered type, so one missing column used to
take the search page, the editor palette and the search API down for *every*
query (#295). That leg is now contained — the misconfigured type answers from
its fuzzy/semantic legs and logs an error naming the migration — but the gate
is what keeps it from shipping at all.

`mix kiln.plugins.doctor` (also part of precommit) verifies an install:
domains registered, no block/field-type/queue collisions, well-formed paths.
`Example.Plugin` in `projects/example` is the reference — a small catalog
domain, a block and a field type declared on the contract. A real deployment's
plugin lives in its own downstream repo and is overlaid onto `projects/` at
image-build time (see projects/README.md for the overlay pattern).

## 6. Nested layout: columns (#335)

Every core block is a **leaf** except one. [`KilnCMS.Blocks.Columns`](../lib/kiln_cms/blocks/columns.ex)
is a **container**: it holds child blocks, turning the otherwise-flat block list
into a shallow tree — the first-party answer to visual page building's one
genuine gap (drag-reorder and the block palette were already shipped).

**Stored shape** (jsonb, string keys):

```elixir
%{
  "_type"  => "columns",
  "layout" => "1-1",            # width-ratio preset: 1-1 | 1-2 | 2-1 | 1-1-1 | 1-2-1 | 1-1-1-1
  "gap"    => "md",             # none | sm | md | lg (optional)
  "columns" => [
    %{"blocks" => [<child block map>, ...]},   # each child is a normal typed block map
    %{"blocks" => [<child block map>, ...]}
  ]
}
```

Children are stored as **raw block maps**, not as a first-class `Ash.Type.Union`
member — a block whose field is the union that lists it would be a compile-time
cycle. They're typed lazily at render time (via `KilnCMS.CMS.TypedBlocks`), so:

- **Rendering, search text, JSON/JSON-LD, and reference extraction** all recurse
  through the *same* typed serializers a top-level block uses. A nested
  `image`/`rich_text`/`form` behaves exactly as it would at the top level
  (media enrichment, sanitization, schema.org nodes, ref edges — all recurse).
- **Backward compatibility is trivial**: a document with no `columns` block never
  gains a nesting level, so the upcaster leaves flat documents byte-for-byte
  untouched. (A stored block in the old flat, pre-typed shape — a write shape
  1.0 refuses — whose `type` is `columns` is read as a typed `Columns`, children
  and all, since #1537.)
- **Nesting composes** (a column may itself hold a `columns` block); a depth
  guard on cast bounds hostile input, and the admin editor caps nesting well
  below it.

**Editing.** The admin block editor renders a nested per-column drag-and-drop
area (the `NestedBlockSortable` JS hook — children move within *and across* a
block's columns) with a per-column "add block" palette and a layout picker. The
children live in LiveView socket state (a `{:array, :map}` field isn't an
AshPhoenix sub-form) and are re-injected into the form params on every
validate/save, so the live preview and the write stay in sync. The in-context
on-page editor renders columns with their nested children in place (read-only
there — structural nested edits belong to the full editor).

## 7. Reusable content fragments (#479)

*Define once, embed everywhere* — the Regular Labs / WP reusable-block /
Contentful-reference idea. A shared banner, CTA or notice is authored as one
document and embedded on many pages; edit the fragment, every page carrying it
updates.

```elixir
%{
  "_type" => "fragment",
  "ref"   => %{"type" => "page", "id" => "<uuid>"},   # the reference
  "label" => "Newsletter CTA"                          # editor-only, never rendered
}
```

### It is inlined, not rendered

[`KilnCMS.CMS.Fragments.expand/3`](../lib/kiln_cms/cms/fragments.ex) replaces the
block with the target's own block tree **before any surface renderer runs** —
decision A3 ("resolve/embed at fire time") taken literally. That is why one
small module buys the whole feature: all four fired surfaces (`:web`, `:json`,
`:llm`, `:json_ld`) see one flat tree and need no knowledge of fragments at all.

Two callers: `Firing.Engine.fire/2` (so artifacts carry the resolved body) and
`KilnCMSWeb.ContentController` (HTML delivery renders live from the block tree,
not from an artifact).

**Not** reached yet: write-time derivations (the `search_text` column, block
embeddings, `word_count`, `reading_time_minutes`) and the editor's own preview
/ SEO / a11y panels all run over the raw tree, so fragment text is invisible to
search and doesn't count towards reading time. Tracked in #910 — expanding
there means making a write depend on a read.

### The re-fire wave already existed

`ref` is a DSL `:reference` field, which
[`KilnCMS.Firing.References`](../lib/kiln_cms/firing/references.ex) already
extracts into a `ReferenceEdge` — so publishing a fragment re-fires every
document embedding it, with **no new machinery**. That is also the one ordering
constraint in the feature: expansion must run *after* the edge rebuild, which
reads the raw tree. Expand first and the fragment block is gone, the edge with
it, and the feature silently degrades to a one-shot copy.

### Failing closed

A target that is missing, unpublished, archived, trashed, in another org, or
gated to an audience the reader doesn't hold expands to **nothing**. A fragment
is a pointer; a pointer to something the caller may not see has no safe
rendering, and a placeholder would leak its existence.

`:audiences` **widens** on top of `:public`, the same way `public_by_slug`
treats it — an anonymous reader arrives with `[]`, which means "public content
only", not "nothing at all".

A fired artifact is expanded with its **host document's own** audience and
nothing wider. Every artifact consumer — the headless artifact endpoint, the
feeds, static export, the newsletter — resolves the host through a
`:public`-only filter and then serves the body verbatim, so an artifact
carrying content stricter than its host would hand a gated body to anonymous
callers on all four. The rule is: an artifact is never more permissive than the
document carrying it.

Because an HTML payload can now embed another document's body, the re-fire wave
also busts each referrer's **delivery** cache, not just its artifact — that
cache is keyed on the referrer's own slug, which nothing else touches when the
target changes.

### Cycles and depth

Fragments nest, so expansion recurses — and a cycle would not terminate. Two
bounds, both needed:

* an **ancestry set**, so `A → B → A` inlines each body once and stops.
  Ancestry rather than a global seen-set, because the same fragment legitimately
  appearing twice on a page must render twice;
* a **depth cap** (`Fragments.max_depth/0`), so a long non-cyclic chain can't
  fan a page out without limit.

Both live at expansion time rather than at write time: a cycle needs two
documents pointing at each other, and either write is individually fine. The
ancestry is seeded with the *host* document, so a page embedding itself doesn't
inline its own body once before the guard catches the loop a level down.

Depth bounds depth, not breadth — a host with B fragments whose targets each
have B more would cost `B + B² + B³` reads. So targets are **memoized per
expansion** (the same fragment twice is one query) and each expansion has a
**fetch budget** (`Fragments.max_fetches/0`), past which further fragments
expand to nothing. An anonymous page render is not where you discover how many
documents an editor chained together.

Fetches are not the cost that matters, though, and on their own those two
bounds do not hold (#917). The memo returns a cached target *without* spending
a fetch, and inlining re-runs the expansion over that target's whole tree at
every occurrence — so the **emitted** tree still grows as `B^(depth+1)` while
the fetch budget counts only distinct targets. Three chained pages holding 200
fragment blocks each spend 3 of 64 fetches and emit eight million blocks, from
an anonymous `GET`. So the load-bearing bound is `Fragments.max_nodes/0`,
charged against blocks produced by inlining, checked on the way in and charged
as each inline returns. Only inlined blocks count — a legitimately long page is
not what this bounds.

### Withdrawing a fragment

Unpublishing, archiving or deleting a fragment **re-fires everything that
embeds it**. That has to be explicit, because a referrer inlines its target at
fire time: the fragment's body is sitting inside every referrer's `:web`,
`:json`, `:llm` and `:json_ld` artifact, and purging the fragment's own
artifacts does nothing about those. The re-fire wave was originally wired to
the publish path only, so a withdrawn fragment kept being served by every page
embedding it — to anonymous callers, through feeds, static export and the
newsletter (#917). `Changes.DeleteArtifacts` now enqueues the same wave the
publish path does.

### Point-in-time reads

A historical read (`as_of`) resolves each fragment to the body its target
carried **at that instant**, via `PointInTime.snapshot_state/4`, not to its
current published body. Otherwise the one endpoint whose promise is "what did
this say on…" answered with today's fragment — or with an empty body where the
content was, if the target had since been withdrawn. A target that was not
published then expands to nothing, exactly as an unpublished one does live.

A historical read is **no more permissive** than a live one: it re-applies the
audience filter and the dynamic-type scope against the values that were live at
`as_of`. That is not optional — `?as_of=` reaches this path from the
unauthenticated `:api` route, and the response is served
`cache-control: public, max-age=300`, so skipping the audience check would let
anyone append `?as_of=` to a public URL and have a CDN cache the body of a
`:member` fragment embedded in it. A replayed state with no `audience` at all
fails closed. Hard-purged targets are excluded by the same `still_exists?/3`
check `index/4` uses, so erased content is not re-exposed through a referrer.

### Authoring

The editor's fragment block is a single `<select>` of published documents —
published-only, because a fragment pointing at a draft renders nothing, and a
picker whose choices silently don't appear is worse than no picker. Any content
type can be a fragment; a non-routable "Fragment" type is a natural home for
shared banners but is not required.
