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
  `help_text`, `position`, `default`, `compute`). Field types: `:string`,
  `:text`, `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`,
  `:select`, `:media`, `:reference`, `:geolocation`, `:datetime_range`,
  `:recurrence`, `:computed` — plus
  anything a plugin registers (see
  [plugin-extensibility.md](plugin-extensibility.md)).
- **Store**: values live in the `custom_fields` map on each content record.
- **Validate**: `KilnCMS.CMS.Changes.ApplyCustomFields` runs on every write — it
  coerces values to the declared type, enforces `required`, checks `:select`
  membership, applies defaults, and drops keys with no definition. Values are
  stored JSON-native (dates as ISO-8601 strings) so the jsonb column round-trips.
- **Edit**: the content editor renders one input per definition automatically.
- **Deliver**: `custom_fields` is public, so headless clients get the values.
- **Query**: list/search reads accept `custom_filter`/`custom_sort` (JSON:API)
  and `customFilter`/`customSort` (GraphQL) — typed, registry-validated
  filtering and sorting on individual custom fields (see
  [json-api.md](json-api.md) → "Custom fields").

```elixir
# Defined once in the UI (or in code/seeds):
CMS.create_field_definition!(%{
  content_type: :page, name: "toxicity_level", label: "Toxicity level",
  field_type: :select, options: ~w(none low moderate high), required: true
}, actor: admin)

# Then editors just fill it; the value is validated on save:
CMS.create_page!(%{title: "Aconite", slug: "aconite",
  custom_fields: %{"toxicity_level" => "high"}}, actor: editor)
```

### Geolocation fields

A `:geolocation` field stores a structured coordinate — `lat` and `lng`, plus
an optional map `zoom` and a place `label`:

```elixir
CMS.create_field_definition!(%{
  content_type: :page, name: "clinic", label: "Clinic location",
  field_type: :geolocation
}, actor: admin)

CMS.create_page!(%{title: "Clinic", slug: "clinic",
  custom_fields: %{"clinic" => %{"lat" => "51.5074", "lng" => "-0.1278"}}},
  actor: editor)
#=> %{"clinic" => %{"lat" => 51.5074, "lng" => -0.1278}}
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
  integer); anything else is string interpolation.
- **References**: `title`, `slug`, `locale`, `excerpt`, `body` (the block
  tree's plain text), `seo_title`, `seo_description`, `seo_keywords` — then the
  record's other custom fields by name. `field.<name>` always means the custom
  field, for names that collide with a document scalar.
- **Functions**: `word_count`, `reading_time`, `char_count`, `slugify`,
  `upcase`, `downcase`, `capitalize`, `trim`, `truncate`, `concat`, `join`,
  `sum`, `product`, `min`, `max`, `subtract`, `divide`, `round`, `default`.
  There is no `eval`: the allowlist *is* the sandbox, and an unknown function
  or wrong arity fails when the **field is defined**, not silently per record.
- **Read-only**: the write pass never consults the submitted payload, so a
  computed field cannot be set through the editor, JSON:API, GraphQL or MCP.
- **Evaluated twice**: on write (so the value is stored and participates in
  search, embeddings and `custom_filter`/`custom_sort`) and again on fire (so
  **editing a formula reaches published content on the next fire**, with no
  re-save sweep). A stale stored value therefore never reaches an artifact.
- **One pass**: a computed field never feeds another computed field.

**When to use a real attribute instead.** Custom fields cover the long tail of
editor-owned fields. A field that is core, needs a DB constraint/index, or is
filtered/sorted on every request still belongs as a hand-declared Ash attribute
on the resource (with a `mix ash.codegen` migration). Custom fields are jsonb —
queryable via `custom_filter`/`custom_sort`, but never index-backed.

## 2. Relations that carry data

`KilnCMS.CMS.ContentLink` links any two content records by id with a named
`kind`. Each link can also carry a payload — `metadata` (a free map) and an
optional `label` — so a relation can describe *itself* (a dosage and role on a
formula→ingredient link, jia-jian notes, an ordered "step N").

```elixir
CMS.create_content_link!(%{
  source_id: formula.id, target_id: ingredient.id,
  kind: :ingredient, label: "Chief herb",
  metadata: %{"dosage_g" => 9, "role" => "jun"}
}, actor: editor)
```

Read the payload from either end via the `content_links` (outgoing) and
`incoming_links` (reverse) relationships on any content record:

```elixir
formula = CMS.get_page!(id, load: [:content_links], actor: actor)
Enum.map(formula.content_links, & &1.metadata)
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

- Configure the tiers: `config :kiln_cms, :audiences, [:public, :professional, :patient]`
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
archived. Fields stay data-driven after promotion — promote an individual
field to a real attribute by hand (add the attribute, migrate the JSONB key,
drop the definition) when querying or indexing demands it.

## 5. Plugins (D18)

For everything beyond one project's content model, package your extension as
a **plugin** — compile-time OTP code (a `projects/` directory or a hex dep)
with one entry module and one config line:

```bash
mix kiln.gen.plugin Ratings --block star_rating --field stars
```

```elixir
config :kiln_cms, :plugins, [Ratings.Plugin]
```

A `Kiln.Plugin` module contributes, per callback (all optional): **block
types** (`Kiln.Block` modules — they join the storage union, editor palette,
firing and search automatically), **custom field types** (`Kiln.FieldType`
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
attribute, so `mix ash.codegen` never creates it — and until it exists the
type's `/search` route raises `undefined_column`. After the migration that
creates the table, add one calling `KilnCMS.Migrations.add_search_vector/1`
(see its moduledoc for the template; `mix kiln.gen.content` prints it too).

`mix kiln.plugins.doctor` (also part of precommit) verifies an install:
domains registered, no block/field-type/queue collisions, well-formed paths.
`Verscienta.Plugin` is the reference — the project the plan always called
"the first plugin/consumer". It lives downstream in the verscienta-base
repo and is overlaid onto `projects/` at image-build time (see
projects/README.md for the overlay pattern).

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
  untouched. (The legacy `columns` *discriminator* on the old flat
  `KilnCMS.CMS.Block` still maps to `Custom` — only the new typed `_type:
  "columns"` is a real container.)
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
