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
  `target_type`, `target_types`, `multiple`, `min_items`, `max_items`,
  `help_text`, `position`, `default`, `compute`). Field types: `:string`,
  `:text`, `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`,
  `:select`, `:media`, `:reference`, `:geolocation`, `:datetime_range`,
  `:recurrence`, `:computed` — plus
  anything a plugin registers (see
  [plugin-extensibility.md](plugin-extensibility.md)).
- **Single image or gallery**: a `:media` field holds one image by default
  (stored as an `%{"id", "url", "alt"}` snapshot). With `multiple: true` it
  is a **gallery**: an ordered list of those snapshots, filled in the editor
  from the library drawer's multi-select and reordered tile by tile. Flipping
  the setting reshapes stored values: a single image becomes a one-image
  gallery, and a gallery keeps only its first image.
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
- **Reverse fields (the other side)**: a `:reference` field may name what
  its targets call it — `inverse_label` ("Recipes using this ingredient")
  and `inverse_name` (`used_in_recipes`, suggested from the label when left
  blank). Every record of each type the field may point at then shows a
  read-only **reverse field** in its editor: the records connecting to it
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
- **Item bounds**: on either kind of list (`multiple: true`), optional
  `min_items` / `max_items` bound how many items a value holds once it holds
  any — an empty optional field is still allowed; `required` asks for at
  least one. They are checked when a record's field is written, so tightening
  one leaves stored values alone until then. Both clear when `multiple` does.
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
- **Deliver**: `custom_fields` is public, so headless clients get the values.
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
  holds nothing. `sum`, `min` and `max` skip non-numbers, but `product` is
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
on the resource (with a `mix ash.codegen` migration). Custom fields are jsonb —
queryable via `custom_filter`/`custom_sort`, but never index-backed.

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
- **Free-form, in code** — a curated link (any other `kind`) created with
  `CMS.create_content_link!/2`. Its `metadata` is whatever map you give it;
  nothing declares or checks its keys.

```elixir
CMS.create_content_link!(%{
  source_id: recipe.id, target_id: ingredient.id,
  kind: :ingredient, label: "Main ingredient",
  metadata: %{"quantity_g" => 200, "role" => "main"}
}, actor: editor)
```

Read the payload from either end via the `content_links` (outgoing) and
`incoming_links` (reverse) relationships on any content record:

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

**When to use a dedicated join resource instead.** ContentLink covers the common
case with one table. If the link attributes are numerous, strongly typed, or
queried independently, write a typed Ash join resource (a normal resource with
two `belongs_to`s plus its own attributes) — the same way the codebase models any
first-class entity.

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
