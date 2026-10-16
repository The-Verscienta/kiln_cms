# Relationships — reaching Directus / Hygraph parity

**Status:** proposed, 2026-10-16. Nothing here is built yet. Every workstream is
**additive** under the 1.0 overlay contract (`docs/overlay-contract.md`): new
field options, new API fields, new operators, new screens. Nothing reshapes a
covered surface, so the whole plan ships in **1.5**, a minor release. The one change
that would reshape something — making the edge the source of truth for a
reference (D20 in its original form) — stays on 2.0, as
[content-organization-plan.md](content-organization-plan.md) §4 already says.

**Goal:** an editor can model a many-to-many relationship from the admin UI —
many targets, more than one target type, data on the link, visible from both
ends — and a headless consumer can read, filter and write it as cleanly as in
Directus or Hygraph. The developer path (a typed Ash join resource in code)
stays what it is, and gains a generator so the UI path can graduate into it.

**The finding in one line:** the data layer is already most of the way there —
`ContentLink` has `kind`, `position`, `label`, `metadata`, both directions and
both-ends read checks, and `ContentLinks.desired/2` already turns a *list*
value into ordered edges. What is missing is the field type, the editor, the
query surface and the write surface on top of it.

---

## 1. Where Kiln stands today

What exists, read from the code on 2026-10-16:

| Mechanism | What it does | Limits |
|---|---|---|
| `many_to_many :tags` through `Tagging` | Every type, both directions (`Tag.pages`, `Tag.posts`, …) | Taxonomy only |
| `related_<type>s` through `ContentLink` | Editor-curated related content | **Same type only**; no UI for link data |
| `ContentLink` (`kind`, `position`, `label`, `metadata`) | Links any two records, with a payload; `content_links` / `incoming_links` on every type; reads gated by `Checks.LinkEndsReadable` | `metadata` is an untyped map; no write API (`CMS.create_content_link!` in code only); no UI |
| `:reference` custom field | Admin-defined in `/editor/fields`; stores a `{id, type, slug, title}` snapshot **and** a `kind: :reference` edge (#1594) | **One target** (`extract_id/1`); **one target type** (`target_type` is a string); editor input is a `<select>` capped at 500 options |
| Typed Ash join resource | Full typed, indexed link attributes (e.g. `Newsletter.Segment` ↔ `Subscriber`) | Code only; no path from a UI-defined relation |

Two gaps found while reading, beyond the feature list:

- **Custom-field references are invisible to the re-fire wave (D13).**
  `Firing.References.rebuild/4` records block references and media
  (`document_media_refs/1`), but not `:reference` custom fields. Renaming a
  referenced record leaves the referrer's fired artifact — and its snapshot
  `title`/`slug` — stale until the referrer is next saved. This is a
  correctness bug today and gets worse with many-valued references, so it is
  workstream **R0**.
- **No delete rule.** A purge leaves inbound edges as "broken references"
  (by design, §4 of the organization plan). Directus lets the field choose
  (nullify / cascade / restrict); Kiln has one fixed behaviour.

## 2. The parity checklist

| Capability | Directus | Hygraph | Kiln today | After this plan |
|---|---|---|---|---|
| Many targets per field | ✅ | ✅ | ❌ | ✅ R1 |
| Ordered targets | ✅ (sort field) | ✅ | edges have `position` | ✅ R1 |
| Several target types in one field | M2A | union types | ❌ | ✅ R2 |
| Data on the link | junction fields | ❌ (intermediate model) | untyped `metadata` | ✅ typed, R3 |
| Reverse field on the other side | ✅ (O2M alias) | ✅ two-way refs | "Linked from" panel only | ✅ R4 |
| Edit from the other side | ✅ | ✅ | ❌ | ⚠️ R4b (decision) |
| On-delete rule per field | ✅ | partial | fixed | ✅ R5 |
| Filter through a relation | `_some`/`_none` on deep filters | `_some`/`_every`/`_none` | `eq`/`in` on one reference id | ✅ R6 |
| Nested reads through the link | `fields=tags.tags_id.*` | native GraphQL | one `include` level, edges by id | ✅ R7 |
| Connect / disconnect / reorder writes | ✅ | ✅ with position | tags, related ids only | ✅ R8 |
| Editor UI for all of the above | ✅ | ✅ | `<select>` | ✅ R9 |
| A real junction table when you need one | auto-created | ❌ | hand-written resource | ✅ generator, R10 |
| Remote / federated sources | ❌ | Remote Sources | ❌ | out of scope, §6 |

Kiln already leads both on: link payloads (vs Hygraph), the both-ends read
gate, re-fire on reference change (once R0 lands), and owning the database
(vs Hygraph).

## 3. Decisions this plan asks for

> **Proposed D22. A relationship is a field; its storage is the shared edge
> table.** A UI-defined relationship is a `:reference` `FieldDefinition`,
> however many targets or types it allows. Its edges live in `content_links`;
> no table is created per relationship. The snapshot in `custom_fields` stays
> the covered value through 1.x. A project that needs a per-relationship
> table **graduates** it to a typed Ash join resource with a generator (R10),
> the same promotion path D17 gives dynamic types.

Why not create a junction table per relationship, as Directus does: D4/D17
keep runtime-defined things as rows, never as modules, atoms or DDL issued at
runtime, and migrations are generated, reviewed and expand/contract-checked
(`mix kiln.migrations.check`). A runtime `CREATE TABLE` breaks all three. One
indexed edge table with a typed payload schema gives the same editor and API
capability; the generator gives the same SQL control when it is needed.

> **Proposed D23. Editing a relationship from the target side writes the
> source record.** If R4b is built, adding a link from the reverse side is an
> edit of the *source* record — authorized, versioned and optimistic-locked as
> that record's write, and held in its working copy when the source is
> published. It is never a bare edge insert. (If that is too heavy, R4b is
> dropped and the reverse side stays read-only — still Hygraph parity on
> reads.)

## 4. Workstreams

Each is one issue and, unless noted, one PR. Order is §5.

### R0 — References join the re-fire graph (bug fix)

- `Firing.References.rebuild/4` adds `{target_type, id}` for every live
  `:reference` custom-field value (single or list), next to
  `document_media_refs/1`. The snapshot carries `"type"`; map it through
  `ContentTypes` to the edge's `to_type` vocabulary.
- Re-fire resolves the snapshot's `slug`/`title` fresh at fire time, so the
  fired artifact is right even when the stored snapshot lags. The stored
  snapshot is left alone (covered shape).
- Tests: rename a target → the referrer re-fires and its JSON artifact shows
  the new title; a reference cycle terminates (existing `visited` set).

### R1 — Many-valued references

- Allow `multiple: true` on `:reference` (today `Changes.ClearMultiple` clears
  it for anything but `:media`). Stored value: an ordered list of snapshots —
  the gallery shape from #1992, so consumers already parse it.
- `ApplyCustomFields.coerce/3`: a `multiple` reference casts each element via
  `coerce_reference/3`, rejects duplicates, and enforces new optional
  `min_items` / `max_items` options. Blank = empty list, same rule as galleries.
- Flipping single ↔ multiple reshapes stored values exactly as `:media` does
  (one → one-element list; list → first element), with the same warning in
  the fields admin.
- Edges: `ContentLinks.desired/2` already emits one edge per element with its
  `position`; add the reconcile test that reordering rewrites positions.
- `SchemaExport` (`/api/schema`, `mix kiln.export.schema --format ts`) reports
  `multiple`, `min_items`, `max_items`.

### R2 — References to several types (polymorphic)

- New `target_types` (list of type names) beside `target_type`. Exactly one
  of the two is set; `target_type` keeps its meaning and stays the documented
  option for one type. `Validations.ReferenceTarget` checks every name.
- The snapshot already carries `"type"`, so a value is self-describing. Input
  must name the type when more than one is allowed: `%{"id", "type"}`; a bare
  id is accepted only when `target_types` has one entry.
- GraphQL: R7's typed `references` field returns a union/interface over the
  allowed types (see R7). JSON:API: unchanged — the edge already has
  `target_type`.

### R3 — Typed link data ("link fields")

- A `:reference` definition may declare **link fields**: `FieldDefinition` rows
  whose owner is the relationship (new nullable `link_of_id` → the parent
  definition) instead of a content type. Same field types, same
  `ApplyCustomFields` coercion, same `required`/`default`/`select` rules.
- Values are stored on the edge's `metadata` and mirrored into the snapshot as
  an added `"link"` key (`%{"id", "type", "slug", "title", "link" => %{...}}`),
  an addition to the documented shape, not a change.
- `ContentLink.metadata` stays a free map for curated and code-created links
  with no declared fields, so nothing that writes it today breaks.
- Filtering on link fields comes with R6 (`custom_filter` on
  `field.link.quantity`), backed by the edge table, not the jsonb snapshot.

### R4 — Reverse fields (read)

- A `:reference` definition may name an `inverse_label` / `inverse_name`.
  The target type then shows a read-only **reverse field** in the editor
  ("Recipes using this ingredient"), listing the sources with their link
  data, ordered, paginated — built on `incoming_links` filtered by
  `field` + `source_type`.
- API: JSON:API `?include=incoming_links` already carries it; R7 adds a typed
  GraphQL field. The both-ends read gate applies unchanged, so a reader never
  sees a draft source.

### R4b — Reverse fields (write) — gated on D23

- Add/remove/reorder from the target side issues `update` on each affected
  source record (array append/remove in its `custom_fields`), as the editor's
  actor, through the normal action — so policies, versioning, the lock and
  working copies all apply. A source the actor may not update is shown, not
  editable.
- Separate PR; can be dropped without affecting anything else.

### R5 — On-delete rule per field

- New option `on_target_delete`: `:keep` (today's behaviour, default),
  `:clear` (purging a target removes it from every referrer's value, as a
  system write per referrer), `:restrict` (purge refused while inbound edges
  of this field exist; trash still allowed).
- `:clear` and `:restrict` act on **purge** only; trash keeps edges so restore
  needs nothing, as today.

### R6 — Filter through relationships

- `custom_filter` on a reference field gains `has` (any of), `has_all`,
  `has_none`, and `count` (with `gt`/`lt`/…), compiled to `exists` over
  `content_links` (`kind: :reference`, `field`, `target_id`) — indexed, not a
  jsonb scan. `eq`/`in` keep their current meaning for single references.
- The same operators on the built-ins: `tags`, `related_<type>s`
  (`filter[tags][has]=…` / `filter: {tags: {has: [...]}}`), so Hygraph's
  `tags_some` has a direct equivalent.
- Link-field filters from R3: `custom_filter[ingredients.link.role]=main`.
- Read-side authz: the `exists` runs under the reader's both-ends policy, so a
  filter cannot be used to probe for draft targets (add the test that a
  draft-only match returns nothing to an anonymous reader).

### R7 — Typed nested reads

- **GraphQL.** Every content type gets `references(field: String!, limit,
  offset)` returning `[ContentReference!]` — `{ position, link: JSON, target:
  ContentRecord }` — and `referencedBy(field:, sourceType:, limit, offset)`.
  `ContentRecord` is an interface implemented by every compiled type and by
  `Entry` (dynamic types share one GraphQL type, D17, so they cannot each get a
  union member). Targets resolve in one batched read per type. Query cost:
  the field counts like any to-many relationship (5 without `limit`).
- **JSON:API.** `?include=content_links.target` is not expressible through
  AshJsonApi's relationship includes (the target is polymorphic). Add a
  polymorphic `target` calculation on `ContentLink` that the serializer emits
  as a heterogeneous `included` member, or — if that fights AshJsonApi —
  answer it on the delivery API instead: `/api/content/:type/:slug?expand=field`.
  Decide in the PR; both are additive.
- Depth: one hop through a reference is a first-class shape; deeper nesting
  goes through the existing GraphQL depth/complexity limits, not new ones.

### R8 — Relationship writes

- GraphQL: `addReferences(id:, field:, targets:, position:)`,
  `removeReferences`, `moveReference` on every content type — sugar over the
  record's update, so versioning and the lock apply. Position takes
  `start | end | before: id | after: id`, matching Hygraph's connect.
- JSON:API: the same as relationship-endpoint-style writes on `custom_fields`
  values, or documented PATCH of the array (already works once R1 lands).
- Payload links (`ContentLink` without a field): routes to create/update/
  delete a link, authorized as an update of the **source** record. This also
  closes the "managed only via `manage_relationship`" gap noted in
  [content-organization-plan.md](content-organization-plan.md).

### R9 — Editor UI

- Replace the reference `<select>` with a picker component: search-as-you-type
  across the allowed target types (server-side, no 500 cap), type badges,
  drag-to-reorder (the gallery's sortable), inline link-field inputs per row,
  remove, and "open target". Built in the house kit (`docs/design-language.md`),
  no DaisyUI.
- Related content: the same picker, so `related_<type>s` can finally choose
  across types (new `related_any` many-to-many would be a covered addition —
  or reuse a multi-type reference field; decide in the PR).
- Reverse fields (R4) render as a read-only list with the same row component.
- Fields admin: `multiple`, `min/max`, target types (multi-select), link
  fields (nested list), inverse name, on-delete rule.

### R10 — Graduation generator

- `mix kiln.gen.join <field>`: generates a typed Ash join resource with two
  `belongs_to`s, the link fields as attributes, identities and indexes, a
  data migration copying the field's edges into it, and policies matching
  the content read rules. Igniter task, like `kiln.gen.content --from`.
- After graduation the field definition is retired with its values moved, so
  there is never two sources of truth.

## 5. Build order — all in 1.5

Every workstream ships in **1.5**. The order below is the build and merge
order inside that release, so each PR lands on the ones it depends on.

| # | Workstream | Depends on |
|---|---|---|
| 1 | **R0** references in the re-fire graph (bug) | — |
| 2 | **R1** many-valued references | — |
| 3 | **R9** picker (multi, reorder, search) | R1 |
| 4 | **R6** relationship filters | R1 |
| 5 | **R2** several target types | R1 |
| 6 | **R7** typed nested reads (GraphQL interface) | R2 |
| 7 | **R3** link fields | R1, R9 |
| 8 | **R4** reverse fields (read) | R3 |
| 9 | **R8** relationship writes | R1, R3 |
| 10 | **R5** on-delete rule | R1 |
| 11 | **R4b** reverse writes | D23, R4 |
| 12 | **R10** graduation generator | R3 |

R9 grows with the release: its first PR is the multi-value picker on R1, and
R2, R3 and R4 each add their part of the picker (type badges, link-field
inputs, the reverse list) in their own PR.

**What has to be decided before work starts, not during it:** D22 and D23
(§3), and open questions 1 and 2 (§7). R4b depends on D23. Without D23 decided
early, R4b is the item most likely to slip out of 1.5.

**Parallel tracks.** After R1 merges, three tracks can run at once on separate
files: R6 (query preparation), R2 → R7 (field validation, GraphQL schema), and
R9 (editor). R3 → R4 → R4b, R8, R5 and R10 follow R3. R0 is independent of
everything else.

With 1.5, Kiln matches Directus and Hygraph on every row of §2 except
federation, goes beyond Hygraph on link data, and offers a graduation path
to a real join table that neither of them has.

## 6. Out of scope

- **Content federation (Hygraph Remote Sources).** A remote reference is a
  plausible `Kiln.FieldType` plugin (fetched through `KilnCMS.SafeFetch`,
  cached, fired as a snapshot), but it is a separate plan with its own
  threat model. Not needed for M2M parity.
- **Per-relationship tables created at runtime.** Ruled out by D22.
- **Tags and related content shared across locales** — tracked separately in
  [#1859](https://github.com/The-Verscienta/kiln_cms/issues/1859). R1's lists
  should be designed so a shared reference copies cleanly, but the sharing
  itself is #1859's.
- **The taxonomy collapse** (`Category` + `Tag` → `Term`, #1595) stays on 2.0.
  R6's `has` operators apply to whatever taxonomy relationship exists.

## 7. Open questions

1. R7 JSON:API: heterogeneous `included` from a calculation, or `?expand=` on
   the delivery API? Spike before committing.
2. R3 storage: link values on the edge only (snapshot carries ids) or mirrored
   into the snapshot as proposed? Mirroring keeps one-request delivery from
   `custom_fields`; it costs a second copy to keep in step.
3. R4b: is source-record write semantics (D23) acceptable in the editor when
   a reverse add touches a published source and lands in its working copy
   rather than going live?
4. R6 cost: `count` over edges on large lists — measure at scale (see
   `docs/benchmarks.md`) before exposing it unpaginated.
