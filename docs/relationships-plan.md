# Relationships — reaching Directus / Hygraph parity

**Status:** decided, 2026-10-16. D22 and D23 are adopted, and open questions
1–3 are answered (§7). On 2026-10-17 the plan took in what Toolset's
relationship admin does that it lacked: R1b, "Add new" in the picker, and a
relationship-first fields admin (R9). R0 shipped in
[#1998](https://github.com/The-Verscienta/kiln_cms/pull/1998); R1, R2, R6, R7
and R9's first parts are built too (their sections say where). Every workstream is
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
| Edit from the other side | ✅ | ✅ | ❌ | ✅ R4b (D23) |
| On-delete rule per field | ✅ | partial | fixed | ✅ R5 |
| Filter through a relation | `_some`/`_none` on deep filters | `_some`/`_every`/`_none` | `eq`/`in` on one reference id | ✅ R6 |
| Nested reads through the link | `fields=tags.tags_id.*` | native GraphQL | one `include` level, edges by id | ✅ R7 |
| Connect / disconnect / reorder writes | ✅ | ✅ with position | tags, related ids only | ✅ R8 |
| Limit on the target side ("each Author on at most 3 Books") † | — | — | ❌ | ✅ R1b |
| Create a new target from the picker and connect it | ✅ | ✅ | ❌ | ✅ R9 |
| Fields admin speaks in relationships, not data types † | partial (relational wizard) | ✅ | type + options, plain wording since R1 | ✅ R9 |
| Editor UI for all of the above | ✅ | ✅ | `<select>` | ✅ R9 |
| A real junction table when you need one | auto-created | ❌ | hand-written resource | ✅ generator, R10 |
| Remote / federated sources | ❌ | Remote Sources | ❌ | out of scope, §6 |

† These rows come from Toolset's relationship admin for WordPress, which the
editor and fields admin take as their model for non-developers: a wizard that
asks "one or many?" for both sides, limits on both sides of a many-to-many,
and a way to add a new related post without leaving the one being edited.
"—" means neither Directus nor Hygraph offers it as a field option.

Kiln already leads both on: link payloads (vs Hygraph), the both-ends read
gate, re-fire on reference change (once R0 lands), and owning the database
(vs Hygraph).

## 3. Decisions

> **D22 (adopted 2026-10-16). A relationship is a field; its storage is the shared edge
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

> **D23 (adopted 2026-10-16). Editing a relationship from the target side
> writes the source record.** Adding, removing or reordering a link from the
> reverse side is an edit of the *source* record — authorized, versioned and
> optimistic-locked as that record's write, and held in its working copy when
> the source is published, so it goes live with *Publish changes*. It is
> never a bare edge insert.

The alternatives were weighed and turned down:

- **A bare edge insert** would be instant, but the source's snapshot, version
  history and lock would no longer agree with its edges. That is the
  stale-snapshot problem R0 just fixed, reopened from the other side.
- **A read-only reverse side** (dropping R4b) would have been the simplest
  path and still matched Hygraph on reads. It was rejected because 1.5 aims
  at full parity, and editing from either side is part of what Directus and
  Hygraph offer.

The cost is accepted: a reverse edit on a published source is not live until
that source's changes are published. The editor says so on the row (R4b).

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
- *Follow-up, found while building R7:* the snapshot is taken whatever state
  the target was in, and every read served it verbatim, so a published
  record's artifact, JSON:API and GraphQL `custom_fields` named a draft
  target's id, slug and title. **Decision:** mask on the way out, never in
  the store. An item whose target the reader could not read directly is
  dropped from a list, and a single-valued field reads as `null`, both shapes
  a 1.x client already handles (an unset field, a shorter list). The artifact
  is masked as an anonymous reader; API reads as the actor, skipping editors,
  admins, system actors and `authorize?: false`, so a masked value never
  feeds a write. Not considered: rewriting stored values on unpublish (loses
  the reference) or replacing the item with a placeholder (a new shape).
  `KilnCMS.CMS.ReferenceSnapshots`.
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

### R1b — Limits on the target side

**Built** in [#2017](https://github.com/The-Verscienta/kiln_cms/pull/2017). What it settled beyond the bullets below:

- **The count is read under the lock, from the edges.** `ContentLinks.reconcile/1`
  works out the targets the write adds, takes `pg_advisory_xact_lock` on
  `kiln:reference_cap:<org>:<source type>:<field>:<target>` for each, sorted
  by target id, then reads the other sources' edges through the new
  `ContentLink` `:references_to` read (`authorize_with: :error`, so a refused
  read fails the write instead of passing the cap). A field is identified by
  its source type as well as its name, since two types may each have a field
  called `authors`.
- **The message counts what is there**, which after a tightened cap may be
  above the cap ("4 of 3").
- **The picker counts as the editor**, in one read for the page of results,
  and leaves the record being edited out, so a record that already holds a
  slot does not see its own target as full.
- **The race test runs outside the sandbox** (`ReferenceCapRaceTest`): in the
  sandbox every test shares one connection, where an advisory lock never
  waits.

R1's `min_items` / `max_items` bound how many records one *source* connects
to. Toolset also bounds the other end of a many-to-many ("a Book has up to 5
Authors; an Author is on at most 3 Books"), and editors ask for it when a
target is a scarce thing — a slot, a seat, a featured position.

- New optional option `max_sources` on a `:reference` definition: how many
  source records may connect to any one target through this field. Blank =
  no limit, today's behaviour. It works for single and `multiple` fields
  alike. There is no `min_sources`: a new target has no sources, and nothing
  on the source side's write could make it gain one, so a lower bound could
  never be enforced at write time.
- **Enforced inside the source record's write**, where the edge is written —
  the same transaction `ContentLinks.reconcile/1` already runs in. For each
  target the write *adds* (one this source does not already link to through
  this field), it counts `content_links` rows with `kind: :reference`, this
  `field` and that `target_id`, from other sources, and refuses the write with
  a field error when the count has reached `max_sources`. Removing or
  reordering targets is never refused.
- **Race-safe.** Two sources connecting to the last free slot at once must not
  both pass the count. Before counting, the write takes
  `pg_advisory_xact_lock` on a key built from org, field and target id (the
  pattern `KilnCMS.Notifications` already uses for its once-only inserts),
  taking several in sorted target-id order so two writes never deadlock on
  each other. The lock is released at commit or rollback, and only writers to
  the same target through the same field wait on it.
- **What counts.** Every edge counts, whatever the source's state: a draft or
  trashed source holds its slot, because trash keeps edges (R5) and restore
  must not overfill the target. A published source's edit staged in its
  working copy is checked when its edges are written — when *Publish changes*
  folds it — and refused there if the target filled up meanwhile, with the
  same message. Tightening `max_sources` below a target's current count leaves
  existing edges alone, as R1's bounds do; the cap applies to the next add.
- Every write path goes through the same check, because every path is the
  source's update: the editor, R4b's reverse writes and R8's API writes. The
  refusal names the count ("*Jane Doe* already has 3 of 3 Books connected"),
  never the sources, so it reveals nothing an actor could not otherwise read.
- **Editor.** In the picker (R9), a full target is listed but disabled with
  "Full — 3 of 3 connected", so an editor sees why it can't be picked rather
  than finding it missing. On the target's own page the reverse field (R4)
  shows "3 of 3" beside its heading, and once R4b lands its add control is
  disabled while the target is full.
- `SchemaExport` reports `max_sources`. Additive: a new option and a new
  validation on a field that did not have it.

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

**Built** in the R3 PR. What it settled beyond the bullets below:

- **Plain types only.** A link field is one of `:string`, `:text`,
  `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`, `:select`
  (`FieldDefinition.link_field_types/0`). They render as one input on a
  connection's row and filter as one jsonb value on the edge. A media
  snapshot, a formula over the document, a composite plugin type — and a
  reference, which would nest link data in link data — have neither.
- **Merges per connection.** An item that leaves out a link value keeps the
  one its connection stored, as a top-level key does on a record; a new
  connection falls to the defaults. A bare id for a record already in the
  list keeps its link values.
- **No empty map.** A connection with no link value stores no `"link"` key
  (its edge's `metadata` is `%{}`), so a field without link fields stores
  exactly the R1/R2 shape.
- **The editor posts link values beside the ids**, as
  `_kiln_ref_link[<field>][<row key>][<link field>]`, and
  `ReferenceValues.normalize/2` folds them into the items before the form
  sees them. The record-level options (`searchable`, `names_record`,
  `localization`) clear on a link field.

- A `:reference` definition may declare **link fields**: `FieldDefinition` rows
  whose owner is the relationship (new nullable `link_of_id` → the parent
  definition) instead of a content type. Same field types, same
  `ApplyCustomFields` coercion, same `required`/`default`/`select` rules.
- Values are stored on the edge's `metadata` and mirrored into the snapshot as
  an added `"link"` key (`%{"id", "type", "slug", "title", "link" => %{...}}`),
  an addition to the documented shape, not a change (decided, §7 Q2). The
  value is written to the snapshot by `ApplyCustomFields` and copied onto the
  edge by `ContentLinks.reconcile/1`, in the same transaction, the same way
  R0's edges follow the stored value. So the two copies cannot disagree, and
  delivery still reads link data from `custom_fields` in one request.
- `ContentLink.metadata` stays a free map for curated and code-created links
  with no declared fields, so nothing that writes it today breaks.
- Filtering on link fields joins R6's operators (`custom_filter` on
  `field.link.quantity`), backed by the edge table, not the jsonb snapshot.
  A record matches when some connection's value matches, under R6's
  both-ends read gate.

### R4 — Reverse fields (read)

- A `:reference` definition may name an `inverse_label` / `inverse_name`.
  The target type then shows a read-only **reverse field** in the editor
  ("Recipes using this ingredient"), listing the sources with their link
  data, ordered, paginated — built on `incoming_links` filtered by
  `field` + `source_type`.
- API: JSON:API `?include=incoming_links` already carries it; R7 adds a typed
  GraphQL field. The both-ends read gate applies unchanged, so a reader never
  sees a draft source.

### R4b — Reverse fields (write) — per D23

- Add/remove/reorder from the target side issues `update` on each affected
  source record (array append/remove in its `custom_fields`), as the editor's
  actor, through the normal action — so policies, versioning, the lock and
  working copies all apply. A source the actor may not update is shown, not
  editable.
- When the source is published, the change lands in its working copy. The row
  shows it as pending ("goes live when *Source title* is published") and links
  to the source, so an editor isn't surprised that the live site hasn't
  changed.
- A lock conflict on one source fails that row only, with the usual
  stale-record message, and the other rows still save.
- Separate PR.

### R5 — On-delete rule per field

**Built** in [#2017](https://github.com/The-Verscienta/kiln_cms/pull/2017). What it settled beyond the bullets below:

- **A change on `:purge`** (`Changes.ApplyTargetDeleteRules`): the
  `:restrict` check runs before the delete, as a
  `KilnCMS.CMS.Errors.TargetStillConnected` naming the field's label and how
  many records connect (not which); the `:clear` writes run after it, in the
  same transaction, so a referrer that cannot be cleared fails the purge.
  Each field's rule is looked up from the edge's `source_type` and `field`; a
  type deleted since keeps the default.
- **The write per referrer is an internal action**, `:clear_reference_target`
  on every content resource, admitted to the `:cms_bookkeeping` system actor
  by name. The target rides in the changeset context, as
  `:sync_shared_fields`'s values do, so no API can reach it. It is versioned,
  takes the optimistic lock, re-fires and announces a published referrer, and
  goes through `SyncReferenceLinks` like any write, so the edges, their link
  data and the re-fire edges follow the value. Referrers are read with
  `authorize?: false` (the purge is already authorized; the system actor would
  read only published content), trashed ones included.
- **A held working copy loses the target too**, and its recorded base moves
  with the live value, so *Publish changes* neither brings it back nor reports
  a conflict.
- **A reference only in a working copy has no edge** and is not found; its
  *Publish changes* is then refused by the usual "not found" check.
- The trash names the field and the count when a purge is refused, and
  "Empty trash" reports the records it kept.

- New option `on_target_delete`: `:keep` (today's behaviour, default),
  `:clear` (purging a target removes it from every referrer's value, as a
  system write per referrer), `:restrict` (purge refused while inbound edges
  of this field exist; trash still allowed).
- `:clear` and `:restrict` act on **purge** only; trash keeps edges so restore
  needs nothing, as today.

### R6 — Filter through relationships

**Built** in [#2003](https://github.com/The-Verscienta/kiln_cms/pull/2003); link-field filters came with R3.

- `custom_filter` on a reference field gains `has` (any of), `has_all`,
  `has_none`, and `count` (with `eq`/`gt`/`gte`/`lt`/`lte`), compiled to
  `exists` over `content_links` (`kind: :reference`, `field`, `target_id`):
  indexed, not a jsonb scan. `eq`/`in` keep their current meaning for single
  references, and R1's list meaning for lists.
- The same set operators on the built-ins `tags` and `related_<type>s`, so
  Hygraph's `tags_some` has a direct equivalent. **Where they live changed:**
  the plan sketched `filter[tags][has]=…`, but the derived `filter[...]`
  grammar belongs to AshJsonApi and AshGraphql, which take operators from the
  destination's fields and have no hook for new ones. So they are
  `custom_filter[tags][has]=…` / `customFilter: {tags: {has: [...]}}`, next to
  the reference operators. A custom field that is itself named `tags` keeps
  the name. The derived `filter[tags][id][in]` (any of) still works.
- Link-field filters from R3: `custom_filter[ingredients.link.role]=main`.
  Built with R3.
- Read-side authz: every edge condition carries `exists(<target resource>,
  id == parent(target_id) and <reader's read filter>)`, the filter being the
  one `Ash.can/3` derives from the target's own read policy for that actor.
  It has the `Checks.LinkEndsReadable` meaning without that check's per-row
  reads, which a filter cannot run. Tested: a draft-only match returns nothing
  to an anonymous reader and the record to an editor; `count` counts only
  readable targets; `has_none` of a draft is true for an anonymous reader.

**Measured (Q4), 2026-10-17.** `scripts/benchmarks/relationship_filters.exs`
seeds 20,000 published posts, 2,000 published pages and 100 draft pages,
and 597,500 reference edges: 25 per post, and 1,000 on each of 100 posts.
It times the `:published` read (`page[limit]=25`) in-process, 20 runs each,
on an Apple M5 Pro with PostgreSQL 17 on the same machine (load average 6–9).

| Filter | p50 ms | p95 ms | In PostgreSQL ms |
|---|---|---|---|
| `has` (one id, rare or common) | 2.3 | 3.3 | 0.7–0.9 |
| `has_all` (two common ids) | 2.6–3.9 | 3.2–4.5 | 0.7 |
| `has_none` (one common id) | 12.6–13.4 | 13.0–13.8 | 11.2 |
| `has` of a draft, anonymous | 1.4 | 1.6 | 0.3 |
| `count` (`gt 500`, `eq 25`, `eq 0`) | 92–102 | 93–127 | 101–110 |

Anonymous and editor readers are within noise of each other.

- **`has`, `has_all`, `has_none` need no cap.** They are index probes on
  `(org_id, source_id, target_id, kind, field)`, and their cost does not
  grow with the number of edges. Each takes at most 100 ids.
- **`count` scales with the records it scans, not with the page size.** It
  is a per-record aggregate, so a filter that has to look at every
  candidate (a selective comparison, or a sort no index serves, as with the
  keyset tiebreak above) costs about 5 µs per record. That is about 100 ms
  for 20,000 records with 600k edges. With an index-served sort and a
  common match it stops at the page: 3 ms. That is acceptable for 1.5 without
  a cap; a site that counts on every request over a much larger type should
  combine `count` with a narrowing filter.
- **One fix came out of the measurement.** The first version took 5.3 s
  (and timed out at 15 s under load) on the full scan: PostgreSQL pulled the
  target gate's `EXISTS` up into a join and re-hashed all 2,000 readable
  pages once per post. Writing the gate as `(EXISTS …) IS TRUE` keeps it a
  subplan, hashed once per query: 135 ms in PostgreSQL for the same scan.
  `has` went from about 5 ms to under 1 ms with it.

### R7 — Typed nested reads

**Built** in the R7 PR. GraphQL as below. JSON:API took the `?expand=`
fallback; the spike's outcome is under the JSON:API bullet and in §7 Q1.

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
  Decided (§7 Q1): the R7 PR opens with a time-boxed spike of the `included`
  route, and falls back to `?expand=` if AshJsonApi can't emit those members
  without patching it. The PR records which route it took and why. Both are
  additive.

  **Outcome: `?expand=`.** The spike stopped at AshJsonApi's include parser.
  AshJsonApi's include parser accepts an include path only when each segment
  is a public relationship (`Ash.Resource.Info.public_relationship/2`), and an
  Ash relationship has one destination resource, so a `target` calculation is
  refused as an invalid include before the serializer is reached. Emitting
  `included` members for it means patching the parser and the serializer. The
  one unpatched shape that works, a relationship per target resource
  (`content_links.target_page`, `.target_post`, `.target_entry`, …), is a
  different URL from the one asked for, and `ContentLink` would have to name
  every content type, a project overlay's too, at compile time. So
  `GET /api/content/:type/:slug?expand=<field>[,…]` answers it on the
  delivery API (`KilnCMSWeb.ReferenceExpansion`): an added `"expanded"` key
  holding, per field, `{position, link, id, type, slug, target}` with the
  target's own fired `json` artifact. Delivery is actorless, so a target is
  expanded only when an anonymous reader could read it; the ETag covers the
  targets; at most 10 fields and 100 targets per field.
- **As built (GraphQL).** `ContentRecord` declares the fields every content
  object has (`id`, `title`, `slug`, `locale`, `state`, `published`,
  `publishedAt`, `insertedAt`, `updatedAt`, `customFields`) plus `references`
  and `referencedBy`, so a client can traverse without a fragment. The
  objects AshGraphql generates gain the interface through Absinthe type
  extensions (`KilnCMSWeb.Graphql.ContentRecord.Notation`), built from the
  schema's `:content_domains`, so an overlay's types join with no core edit.
  `referencedBy` returns `ContentReferrer { field, position, link, source }`.
  Both fields default to, and cap at, 100 rows. Edges are read as the reader
  through `ContentLink`'s read policy (both ends readable), and targets are
  read as the reader too, one read per type with the selected fields loaded.
  `link` is the edge's `metadata`, passed through for R3 to fill.
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
- **Create and connect.** Next to "Connect an existing record…", the picker
  offers "Add new *Type*" (one entry per allowed target type, R2). It opens a
  small form — the target type's title and its required fields, nothing else
  — creates the record as a **draft** through that type's normal create
  action, and connects it to the field in the same step, as if it had been
  picked. The action is shown only for types the editor may create (the
  generated `can_create_*?` helper, or the dynamic-type equivalent), and the
  create is authorized as the editor's own, so the menu never offers what the
  server would refuse.
  The new target stays a draft until someone publishes it: the row carries a
  "Draft" badge with a link to open it, and the both-ends read gate keeps it
  out of public reads until then. It is an ordinary draft — if the editor
  abandons the source's change, the new record stays in the content list as a
  draft and is not deleted behind their back.
- Related content: the same picker, so `related_<type>s` can finally choose
  across types (new `related_any` many-to-many would be a covered addition —
  or reuse a multi-type reference field; decide in the PR).
- Reverse fields (R4) render as a read-only list with the same row component.
- **Fields admin: a relationship, not a data type.** A non-developer sets up
  a relationship the way Toolset's wizard asks for one, not by picking a type
  and filling options. Adding a reference field starts with the two sides
  named in plain words — "*Recipe* links to *Ingredient*" — then asks how many
  on each side: "One *Ingredient*" / "Several *Ingredient* records", and,
  from the other end, how many *Recipes* may connect to one *Ingredient*
  (R1b). The summary line reads as a sentence from both sides ("Each Recipe
  connects several Ingredients; each Ingredient is used by any number of
  Recipes"). This builds on the wording R1 introduced — "Links to", "Connects
  one *Type*" / "Connects several *Type* records", "How many *Type* records
  can be connected" — and every later option joins it in the same voice:
  target types (multi-select, R2), link fields as "Details on each
  connection" (nested list, R3), the reverse field's name as "What *Ingredient*
  calls this" (R4), and the on-delete rule as "When a connected *Ingredient*
  is deleted…" (R5). The stored options (`multiple`, `min_items`,
  `max_items`, `max_sources`, `target_types`, …) stay what the API and
  `SchemaExport` report; only the admin's words change.

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
| 3 | **R9** picker (multi, reorder, search, create and connect) | R1 |
| 4 | **R1b** target-side limit | R1 |
| 5 | **R6** relationship filters | R1 |
| 6 | **R2** several target types | R1 |
| 7 | **R7** typed nested reads (GraphQL interface) | R2 |
| 8 | **R3** link fields | R1, R9 |
| 9 | **R4** reverse fields (read) | R3 |
| 10 | **R8** relationship writes | R1, R3 |
| 11 | **R5** on-delete rule | R1 |
| 12 | **R4b** reverse writes | D23, R4 |
| 13 | **R10** graduation generator | R3 |

R9 grows with the release: its first PR is the multi-value picker on R1, with
"Add new *Type*" and the relationship-first fields admin, and R1b, R2, R3 and
R4 each add their part of the picker and the admin (the "Full" state, type
badges, link-field inputs, the reverse list) in their own PR.

**Decided before work starts:** D22 and D23 (§3) and open questions 1–3
(§7), all on 2026-10-16. Nothing on the build path is waiting on a decision.
The one question that was left, Q4, was answered by measurement in R6.

**Parallel tracks.** After R1 merges, four tracks can run at once on separate
files: R6 (query preparation), R2 → R7 (field validation, GraphQL schema),
R1b (the write-time check in `ContentLinks`), and R9 (editor). R3 → R4 → R4b, R8, R5 and R10 follow R3. R0 is independent of
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
- **References to a single field of another record.** A relationship connects
  whole records — a page or an entry to another page or entry — never one
  field of a record to a field of another (decided 2026-10-17). A consumer
  that wants one value from the target reads it through the connection (R7),
  and link data that belongs to the connection itself is a link field (R3).
- **Tags and related content shared across locales** — tracked separately in
  [#1859](https://github.com/The-Verscienta/kiln_cms/issues/1859). R1's lists
  should be designed so a shared reference copies cleanly, but the sharing
  itself is #1859's.
- **The taxonomy collapse** (`Category` + `Tag` → `Term`, #1595) stays on 2.0.
  R6's `has` operators apply to whatever taxonomy relationship exists.

## 7. Questions

Answered on 2026-10-16:

1. **R7 JSON:API: heterogeneous `included`, or `?expand=` on the delivery
   API?** Spike the `included` route first and fall back to `?expand=` if it
   fights AshJsonApi. The R7 PR decides, and records the outcome.
   **Outcome (R7, 2026-10-17): `?expand=`.** AshJsonApi accepts only public
   relationships as include paths, and a relationship has one destination,
   so a polymorphic `target` cannot be included without patching it (§4, R7).
2. **R3 storage: edge only, or mirrored into the snapshot?** Mirrored. The edge
   is a copy of the stored value, reconciled in the same transaction, and
   delivery keeps reading link data from `custom_fields` in one request.
3. **R4b: is it acceptable that a reverse edit on a published source lands in
   its working copy?** Yes, as part of D23. The editor shows the edit as
   pending until that source's changes are published.

Answered on 2026-10-17:

4. **R6 cost:** `count` over edges on large lists. Measured in R6 (§4, R6):
   `has`/`has_all`/`has_none` are index probes and need no cap; `count` costs
   about 5 µs per record scanned (100 ms for 20,000 records over 600k edges)
   and ships paginated without a further cap.
