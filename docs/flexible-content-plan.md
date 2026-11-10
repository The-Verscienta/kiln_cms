# Flexible content — plan for mixed typed items inside a custom field

**Status:** plan, not built. Design record for
[#2282](https://github.com/The-Verscienta/kiln_cms/issues/2282), written from a
read of the model as it stood on 2026-11-10 (after custom-field waves 1–5). Read
the resources for current behavior and this for *why*. Nothing here is a
decision until the PR that carries it merges; the open questions are in §10.

**Goal:** a custom field whose value is an **ordered list of items of different
types** (hero, quote, feature grid, …), each type with its own sub-fields and a
separate set of **settings** (background, width, alignment), defined by an admin
in the UI with no runtime DDL, edited in the content editor by adding,
reordering, collapsing and removing items. Drupal Paragraphs, ACF Flexible
Content, Strapi dynamic zones and Payload blocks are the benchmark.

**The answer in one line:** build a new **`:flexible` core field type** whose
item types are `FieldDefinition` rows (the `:group` machinery, one level up),
stored inline in `custom_fields` as a list of `_type`-tagged objects with stable
`_id`s. Do **not** put core blocks inside a field.

---

## 1. Key question: reuse core blocks, or a new nested-item model?

### Reusing core blocks in a field — rejected

It looks cheap (a field type whose `cast/2` runs `Ash.Type.cast_input({:array,
BlockUnion}, value)`), and storage and cast would in fact work. Everything
around them does not:

| Concern | Evidence | Consequence |
|---|---|---|
| **Admin-defined types** | Blocks are compile-time Ash embedded resources; `BlockUnion` is built from `KilnCMS.Blocks.union_types()` at compile time (`lib/kiln_cms/blocks.ex`, `cms/block_union.ex`). There is no runtime block definition anywhere. | The issue's "defined by admins" cannot be met: an admin can only pick from the 21 core and plugin blocks, none of them a "Hero with these three fields". |
| **Editor** | Every block event, `ensure_block_ids`, the `Sortable`/inserter hooks and `inputs_for @form[:blocks]` assume one tree at `form[:blocks]` (`content_editor/block_ops.ex`, `block_params.ex`); nested columns children live in socket state (`block_children`). | A second tree needs a parameterized form name or a LiveComponent, per-tree ids and a second copy of the socket state. That is a rewrite of the editor, not a field. |
| **Block-only derivations** | `EnforceBlockFieldPolicy` (`editable_by`), `Fragments.expand`, `BlockIndexer`, `Links.Extract`, `VersionDiff` (`"blocks"` key only), `SharedFieldsReadOnly`, `ContentCopy`, `BlockIds`, `word_count` all read `document.blocks`. | `editable_by` would be silently **bypassed** for a block inside a field unless the policy is extended; five more derivations would each need a second walk. |
| **Fired surfaces** | `Firing.Engine` composes the four surfaces from one expanded tree; `custom_fields` ride separately and `:llm`/`:json_ld` take none (`firing/engine.ex`). | A per-field render path would have to be invented for all four surfaces. |
| **GraphQL / typed export** | A plugin field type cannot declare a composite kind; unknown shapes are served as `JsonValue` (`field_kind.ex`). | No typed union without the same core work a new type needs anyway. |

What blocks *do* give us is a naming convention worth copying (`_type`, `_id`
meta keys, §3), not a runtime to share.

### Extending `:group` — chosen, with its limits stated

`:group` already is "admin-defined structured rows, no DDL":

* sub-fields are `FieldDefinition` rows with `group_of_id`
  (`field_definition.ex`), loaded as `group_fields` by `for_type` /
  `for_definition`;
* `ApplyCustomFields` coerces rows per sub-field with the field's own rules,
  paths errors as `dosages[2].unit`, bounds rows with `min_items`/`max_items`,
  evaluates `visible_when`/`required_when` among the sub-fields of the same row
  (`Conditions.apply_to/3`), and checks constraints per row
  (`FieldConstraints.check_row`);
* grants have a `custom_fields.<group>[.<sub>]` grammar (`field_access.ex`);
* the editor has add / remove / move / drag-reorder (`content_editor/group_rows.ex`,
  `inspector_components.ex`), the admin has a "Fields in group" panel, schema
  export / GraphQL / the four typed-client emitters know `GroupValue`, and
  `SyncFieldValues` rewrites stored rows on rename/destroy.

But a group is the wrong shape in four ways, and each is a deliberate work item:

1. **One shape per field.** Rows have no type. → item types (§2).
2. **Scalar sub-fields only** (`@link_field_types`: string, text, integer,
   float, boolean, date, datetime, url, select). No media, no reference, no
   nesting (`validations/group_field.ex`). A flexible field without an image
   picker is useless, so this limit must be lifted for items (§6, PR 3).
3. **Rows carry no identity**, so rows are addressed by position, merged
   wholesale, diffed as one opaque value. Items get an `_id` (§3).
4. **No settings/content split.** → `item_setting` flag on a sub-field (§2).

---

## 2. Definition model (no runtime DDL)

Everything is `FieldDefinition` rows, like a group:

```
FieldDefinition  name: "sections"  field_type: :flexible   (top-level, owned by content type / dynamic type)
 └─ FieldDefinition  name: "hero"  field_type: :group  flex_of_id: <sections.id>      ← an item type
     ├─ FieldDefinition  name: "headline"  group_of_id: <hero.id>                      ← content sub-field
     ├─ FieldDefinition  name: "image"     group_of_id: <hero.id>  (media, PR 3)
     └─ FieldDefinition  name: "background" group_of_id: <hero.id>  item_setting: true ← settings sub-field
```

* **Item type = a `:group`-typed row with a new owner column `flex_of_id`**
  (a fifth owner beside `content_type`, `type_definition_id`, `link_of_id`,
  `group_of_id`). `for_type`/`for_definition` filter on `content_type` /
  `type_definition_id`, which an item type leaves nil, so it stays out of those
  listings. `OneFieldScope` does **not** already allow it: it hard-codes
  `@owners` (`one_field_scope.ex:13`) and would reject a row owned only by
  `flex_of_id`, so PR 1 must add the owner and its conflict messages. Its
  sub-fields are ordinary `group_of_id` children, so `group_fields/1`, loading,
  `Conditions`, `FieldConstraints.check_row`, the admin panel and
  `SyncFieldValues` sub-field SQL are reused as is. `label`, `help_text`,
  `position`, `max_items` (per-type cap) come from existing attributes.
* **Settings** are sub-fields with a new boolean `item_setting` (default
  `false`). They are stored under `_settings` and never mixed into content, so
  a designer can add a "Background" knob without touching the content schema,
  and delivery/search can ignore them. Paragraphs "behaviors" without a second
  table.
* **Nesting is allowed (decided, Q4), capped.** A flexible field may be a
  sub-field of an item type, so an item can hold its own list of mixed items.
  The inline-JSON model keeps Paragraphs' N+1 and revision-drift away, but only
  while the tree is bounded, so: a hard depth cap (default 3 flexible levels,
  `FlexibleField` validation, and the same bound on the GraphQL reader's
  `@max_group_depth`, `FieldDisplay`, schema export and `SyncFieldValues` SQL
  recursion); an item type's owner may therefore itself be an item sub-field
  (`flex_of_id` → a row with `group_of_id`), so every owner walk in §8
  ("two-hop") becomes N-hop up to the cap; item paths are `_id` chains, never
  indexes; per-item-type grants apply at the top level only; per-item diff and
  editor cards recurse. This enlarges PR 1 (validation, recursion in
  `resolve_flexible`, owner walks) and PR 2 (nested cards) and is the main
  reason PR 1's test matrix must include a three-level fixture.
* **Schema change**, via `mix ash.codegen`, expand-only: `flex_of_id uuid NULL`
  (FK to the same table, `on_delete: :delete`, mirrors `group_of_id`), identity
  `[flex_of_id, name]`, and `item_setting boolean NOT NULL DEFAULT false`
  (a new column with a default; nothing the previous release reads changes).
  `mix kiln.migrations.check` should pass with no `kiln:contract-ok` marker.
  `on_delete: :delete` cascades from a field to its item types and their
  sub-fields **in the database, bypassing `SyncFieldValues`** (true of groups
  too), so "refuse deleting an item type while items exist" needs an explicit
  `before_action` / validation, not a reliance on the FK.
* **Rollback and registry.** `field_type` is an Ash `:atom`; a previous release
  that reads a row holding `:flexible` must tolerate it (check how
  `KnownFieldType` and `docs/releasing.md` treat orphaned/plugin types and state
  the behavior in the ADR). `:flexible` is added to `FieldTypes.reserved/0` so
  a plugin cannot register it (`mix kiln.plugins.doctor`).
* **Reporting views** (additive-only contract, `docs/reporting.md`,
  `view_sql.ex`): `allowed_definition` already requires `group_of_id IS NULL`,
  and item types have neither `content_type` nor `type_definition_id`, so they
  should not join; PR 1 must **prove it with a test** and, only if they do join,
  add `AND flex_of_id IS NULL` by recreating the view pair (no column removed).
  The flexible field's own value is raw JSONB in `custom_fields`, exactly as a
  group's is today. No new columns, so no `v2`.

---

## 3. Storage shape in `custom_fields`

```json
"sections": [
  {"_id": "6f1c…", "_type": "hero",
   "headline": "Hello", "image": {…media snapshot…},
   "_settings": {"background": "dark", "width": "wide"}},
  {"_id": "a02d…", "_type": "quote", "text": "…", "cite": "…"}
]
```

* Flat with `_`-prefixed meta keys: `_id`, `_type`, `_settings`. Sub-field names
  must start with a letter (`FieldDefinition` name regex), so a meta key can
  never collide — the same trick `GroupRows` already relies on to carry `_`
  markers. Matches the `_type`/`_id` convention the fired block JSON uses, so
  consumers switch on one discriminator name everywhere.
* Always a list (a flexible field is implicitly `multiple`); `min_items` /
  `max_items` bound it, `max_items` on an item type bounds that type.
* `_id` is a UUID minted on first save if absent and **kept** by every later
  write (the editor posts it back). That is what rows lack today, and it is
  what makes per-item merge, diff, grants-by-item, comments and translation
  alignment possible. Duplicating an item mints a new id.
* Stored inline in the parent's JSON (D3): one read, one revision, atomic with
  the parent. No second table, no N+1.
* Orphans: an item whose `_type` no longer exists is refused in `:strict` mode
  and dropped in `:drop` mode (the two modes `ApplyCustomFields` already has);
  it is never silently re-typed.

---

## 4. Write path: validation, conditions, constraints

`ApplyCustomFields.resolve_field/4` gains a `:flexible` clause beside `:group`
(`apply_custom_fields.ex:928`):

1. Each item: find the item type by `_type` (unknown → error under
   `sections[2]._type`), then run the existing `coerce_row/5` over that type's
   **content** sub-fields, and a second pass over its **settings** sub-fields
   into `_settings`. Same `required`, `default`, `:select`, unknown-key,
   `Conditions.apply_to` (scope = that item's own sub-fields) and
   `FieldConstraints.check_row` behavior, with paths like
   `sections[2].headline`.
2. A blank item (all content blank, ignoring `_id`/`_type`/settings) is dropped,
   as a blank group row is.
3. Bounds: `min_items`/`max_items` on the field, `max_items` per item type.
4. **Per-item merge by `_id`**: an item the write omits is removed (a write that
   names the field sends all of it, as for groups); an item present keeps its
   `_id`; an incoming item with an unknown or absent `_id` gets a new one.
   `row_unchecked?`'s grandfathering (a stored row is not re-checked against
   constraints added later) stays structural equality over the item minus
   `_id`, so items written before an `_id` existed (and any value converted from
   a group) are tolerated without a data backfill; an item without `_id` simply
   gets one on its next save.
5. Conditions on the flexible field *itself* (`visible_when` / `required_when`)
   are excluded for `:group` today (`validations/field_condition.ex:83`); keep
   that exclusion for v1 and list it with the group gap, rather than widening
   it silently.
6. `searchable` is refused on a flexible field in PR 1 (until the walker skips
   meta keys in PR 6, it would index `_id`/`_type` into `search_text`).
   `unique` is refused on a flexible field and on its sub-fields (as for
   groups), and a flexible field cannot be `private`, `computed`, a list
   column, an index target or a `custom_filter` leaf (`PrivateFields.@types`,
   `ListFields`, `IndexedCustomFields`, `CustomFieldQuery` already exclude
   `:group` by type; each gets the same explicit exclusion plus a test).

The `:flexible` type is **core**, not a `Kiln.FieldType` plugin, for the reason
`:group` is (`field_types.ex`): coercion recurses into `ApplyCustomFields`,
which only the host can do. Plugins cannot define item types; item types are
data.

---

## 5. Editor UX

Extend the group-rows UI rather than build a second one
(`inspector_components.ex` `group_rows_input`, `GroupRows`, the
`group_row_*` events, the `Sortable` hook).

* **Item card** per item: type badge + label, a one-line summary (first
  non-blank text value — `FieldDisplay` already summarizes), drag handle,
  move up/down, **collapse/expand**, duplicate, remove. Collapse is new (groups
  have none) and is purely presentational: `Phoenix.LiveView.JS` toggling a
  class/`aria-expanded`, kept in a sticky attribute so a patch does not re-open
  it (`liveSocket.js()` sticky attrs, per the New-menu disclosure, #2145). No
  inline `<script>`, no server round trip, no stored state.
* **Add item**: a disclosure menu ("Add item ▾") listing the item types (label,
  help text), the same pattern as the New menu; respects field and per-type
  `max_items`; inserts after the focused card or at the end.
* **Content vs settings**: the card body shows content sub-fields; settings sit
  in a collapsed "Settings" section of the same card.
* **Wire form**: `custom_fields[<name>][<index>][_id|_type|<sub>]` and
  `[<index>][_settings][<sub>]`; `GroupRows.normalize/2` folds the position map
  into the ordered list (a sibling `FlexibleItems` module with the same
  `_`-marker discipline). Position keys stay a transport detail; identity is
  `_id`.
* **Pickers inside items**: the media and reference pickers address a top-level
  field name today. Items need them to address a path
  (`sections.2.image`) — the largest UX cost, owned by PR 3.
* **Rich text** (`:text` sub-field) reuses the existing rich input for a group
  cell if one exists, else plain `textarea` in v1 with the TipTap hook added in
  PR 2 (to be settled by reading `group_cell_input` first).
* Accessible, keyboard-operable move/collapse controls, like the group ones;
  per-item error markers keyed by path.
* **Admin side**: the fields admin gets an "Item types" panel inside a flexible
  field (create / reorder / delete item types; each opens the existing "Fields
  in group" panel; a checkbox "Setting" per sub-field). Deleting an item type
  shows how many stored items it will purge (`SyncFieldValues` purges on
  destroy today; for a whole item type the admin must see the count first).

---

## 6. What each surface must do

| Surface | Today (groups) | Flexible |
|---|---|---|
| **Fired `:json`** | `custom_fields` emitted verbatim (`engine.ex:640`) | Items ship as stored. `Firing.CustomFields` refresh of `:media`/`:reference` snapshots (`firing/custom_fields.ex`, top level only) must recurse into items (PR 3). |
| **Fired `:web`** | Public HTML renders no custom fields; themes read the map | No default rendering. A documented helper (`KilnCMS.CMS.FlexibleItems`: typed items with definitions) for theme authors. |
| **Fired `:llm`, `:json_ld`** | Take no custom fields except geolocation | The issue says these "must see" items. Groups do not reach them either, so this needs an explicit projection decision (§10 Q2); proposed PR 7. |
| **Re-fire / references** | Reference edges and snapshots are top-level only (`sync_reference_links.ex`, `content_links.ex`, `reference_edits.ex`) | Reference sub-fields inside items need edges that carry a path, a re-fire wave, and `SyncFieldValues` support. This is the "fragment" story in §7. |
| **GraphQL** | `GroupValue {name, fields}` implementing `custom_field_value` | `FlexibleValue {name, items: [FlexibleItem {id, type, fields, settings}]}` on the same interface. Absinthe unions cannot be per-site at compile time (ADR 0016 already settles that the schema types the accessor and the per-org export types the names), so the **union lives in the typed export**. |
| **JSON:API** | Raw `custom_fields` attribute; `/type-definitions?include=field_definitions.group_fields` | Raw attribute; include `item_types` (and nested `group_fields`) on the definitions include. |
| **Typed-client export (#2274)** | `schema_export.ex` + `graphql.ex`, `type_script.ex`, `swift.ex`, `kotlin.ex` emit `GroupValue` | JSON Schema `oneOf` over item types discriminated by `_type`; TS discriminated union, Swift enum with associated values, Kotlin sealed class. Four emitters, goldens (`test/support/fixtures/schema_export`) regenerated. This is where "union type" is truly delivered. |
| **Reporting views** | Top-level group key is raw JSONB; sub-field definitions excluded | Same; prove item-type rows are excluded (§2). |
| **Content export/import** | CSV: raw JSON cell; JSON import re-runs `ApplyCustomFields` | Same; `_id`s are preserved on import so a round trip keeps identity; unknown item types fail the row with a path. |
| **Schema sync (`FieldSync`)** | `@child_lists` has `link_fields` and `group_fields` | Add an `item_types` child list whose children carry `group_fields` (two-level nesting: `@child_lists`, `kid_of?`, `governing`, `owner_ids`). The file format change is additive. |
| **Field conversion** (`mix kiln.fields.convert`) | JSON text → group | Out of scope; documented. |

---

## 7. Reusable Fragments (#479) — what "reuse" can honestly mean

The issue asks to reuse Fragments for a library of shared items. Fragments are
**documents whose block tree is inlined into another block tree at fire time**
(`Fragments.expand/3`, `Blocks.Fragment`); they are not items and expansion is
wired to `document.blocks`. Reuse that does not fight this:

* a shared item is an entry of a (dynamic or compiled) content type and an item
  type holds a **`:reference` sub-field** to it; the existing reference
  snapshot/edge/re-fire machinery is the reuse, not a second mechanism;
* that requires reference sub-fields inside items with path-carrying edges (PR 3);
* inlining a fragment's *block tree* into an item's output is a different,
  larger feature and is **not** in this plan.

---

## 8. Cross-cutting concerns

* **Grants** (`FieldAccess`, `EnforceCustomFieldGrants`, #2281). The grammar
  allows two segments (`custom_fields.<field>[.<sub>]`). For a flexible field
  the second segment is the **item type**: `custom_fields.sections` (whole
  field: add/remove/reorder anything), `custom_fields.sections.hero` (may edit
  `hero` items only, may not add/remove/reorder others). The two-segment
  grammar is syntactically unchanged, but the validators that decide whether an
  entry names a real thing (`valid_read_entry?`, the grant pickers, the "(not
  found)" display) must accept item-type names for a flexible field, and
  `custom_fields.sections.headline` (a sub-field name) is an error there.
  `EnforceCustomFieldGrants.paths/3` compares by `_id` instead of the
  row-aligned zip groups use — a rewrite of that function, so PR 4 is sized
  accordingly. Per-sub-field-in-item grants would need a third
  segment and are out of scope. Hidden fields: a read-restricted flexible field
  is impossible because it cannot be private (`ReadGrantedStaysPrivate`).
* **Localization.** Field-level localization is per top-level key
  (`localized` / `shared` / `fallback`); a flexible field behaves as a group
  does — an opaque whole value, sub-fields forced `:localized`
  (`ClearLinkFieldOptions`). Translations copy the list *with* `_id`s
  (`ContentCopy` already carries a group whole), so identity aligns across
  locale variants, which a later per-item `shared` mode or item-level XLIFF
  could use. XLIFF today covers blocks only, not custom fields; unchanged.
* **Search.** `SearchableFields` walks strings depth-first and would index
  `_type` and `_id` values; its walker must skip `_`-prefixed keys (and
  optionally `_settings`) for flexible values, and sub-fields stay non-searchable
  (their `searchable` is cleared). Flagging the flexible field `searchable` is
  the opt-in. `BlockIndexer`'s "custom-fields" pseudo-block then covers
  embeddings for free.
* **Revisions / diffs.** PaperTrail snapshots `custom_fields`, so history and
  restore work immediately; restore rewrites the whole map (under #2281 this
  stays refused for editors with field grants). `VersionDiff` compares
  `custom_fields` per key as one value; PR 6 adds a per-item diff keyed by
  `_id` (added / removed / changed / **moved**, as the blocks diff does) and
  extends `FieldDisplay`'s summarizing.
* **Computed fields** cannot read inside items (not in `@link_field_types`);
  unchanged and documented. A computed field reading `count(sections)` is a
  natural follow-up, not v1.
* **Multi-hop owner walks (N-hop once nesting is on, §2).** An item sub-field's parent is an item type, whose
  own owner is the flexible field. `BustTypeRegistry` (`:93`, `:117`) reads the
  parent's `type_definition_id`/`content_type` and would resolve **nil**, so no
  `Firing.Sweep.sweep_type` runs after an item sub-field is renamed or purged —
  stale fired output with no error. The same single-hop assumption sits in
  `SyncFieldValues.sync/2` (`:130`), `FieldSync` (`@owner_keys` `:81`, `kid_of?`
  `:655`, `governing` `:748`, `owner_ids` `:984`) and `FieldCondition` scope
  resolution (`:261`, `:280`). PR 1 makes every walk loop up to the nesting cap, with a test
  that renames an item sub-field at depth 1 and depth 3 and asserts the type is swept. Reading
  `item_types` with nested `group_fields` is also another query per type per
  registry fill; measure it with the cache cold.
* **`SyncFieldValues`**: rename of an item sub-field renames the key inside
  every item of that type; destroy purges it; rename of an item type rewrites
  `_type`; destroy of an item type purges its items. New SQL on a doubly-nested
  jsonb path, with the same transactional guarantees as the group SQL.
* **Plugin SDK**: nothing in `Kiln.FieldType` changes; the type is core. The
  `graphql_kind` seam is unaffected.

---

## 9. Recommended PR split

Each PR is releasable alone and additive under the 1.0 overlay contract. PR 1
exposes the type at API level only, so **hold the CHANGELOG "feature" entry
until PR 2**.

| # | PR | Contents | Depends on |
|---|---|---|---|
| 1 | **Model + write path** | `:flexible` core type (reserved name); `flex_of_id`, `item_setting` (codegen, expand-only); `OneFieldScope`/`GroupField`/new `FlexibleField` validations; the §2 top-level-predicate audit table + tests; `resolve_flexible` with `_id`/`_type`/`_settings`, bounds, conditions, constraints; `FieldKind`/`FieldTypes` entries and **minimal handling in the schema emitters** (the exhaustive `field_kind_test` and golden tests force it here: typed as generic JSON until PR 5); exclusions (private, searchable, list column, index, filter, unique); reporting-view exclusion test; N-hop owner walks (to the nesting cap) in `BustTypeRegistry`/`SyncFieldValues`/`FieldCondition`; deletion guard; depth cap (default 3) and a three-level fixture across validation, coercion, owner walks and SQL purge/rename; code interfaces; an ADR (next free number at PR time) covering §1–3 and rollback. API-level tests only. | — |
| 2 | **Admin + editor (one PR)** | "Item types" panel, "Setting" checkbox, per-type `max_items`, purge-count warning; `FieldSync` `item_types` nesting; item cards (recursive for nested flexible sub-fields, each level collapsible), add menu, drag/move/duplicate/remove, collapse, settings section, `_id` wire form, error paths, scalar sub-fields; e2e. Split admin from editor only if size demands, because the admin panel alone is a dead end. Gettext for new strings. | 1 |
| 3 | **Media + reference inside items** | `item_field_types` = link types + `:media` + `:reference` (group parity, Q1); snapshots at write; path pickers addressed by `_id`; `Firing.CustomFields` refresh recursion; edges with path + re-fire; `FieldDisplay.collect`; `SyncFieldValues`. Highest risk; changes the `GroupValue` shape if groups are included. | 2 |
| 4 | **Grants** | Per-item-type grants, validators and pickers, `_id`-based `EnforceCustomFieldGrants` rewrite, copy-path handling. | 1 |
| 5 | **API + typed export** | GraphQL `FlexibleValue`, `SchemaExport` `oneOf`, TS/Swift/Kotlin/GraphQL emitters, goldens, `clients/` (js, elixir) and `kiln_client`, docs. **After 3**, so the emitters and goldens change once. | 1, 3 |
| 6 | **Search + diff + display** | Walker skips meta keys and `searchable` becomes allowed, `VersionDiff` per item, `FieldDisplay` (coordinate with 3, which also edits it), history rendering. | 1 (after 3 for `FieldDisplay`) |
| 7 | **`:llm` / `:json_ld` projection + theme helper** | Per Q2; `FlexibleItems` helper docs. | 1, decision |

Parallelism after 1: 2 and 4 can run together; 6 can run once 3 lands its
`FieldDisplay` change; 5 waits for 3. Docs: every PR updates `docs/` and
`extending-content.md`; the CHANGELOG feature entry waits for 2.
---

## 10. Decisions (maintainer, 2026-11-10) and the open questions behind them

1. **Parity for `:group`: yes.** Media and reference sub-fields are lifted for
   groups and items alike through one `item_field_types` list (PR 3).
2. **`:llm` / `:json_ld`: add projection in v1.** PR 7 delivers items to both
   surfaces (a generic opt-in for custom text, applying to all text fields,
   groups included); the exact option name and format are PR 7's first design
   question.
3. **Shared items: a `:reference` sub-field to an entry** is the reuse of
   Fragments (§7). Inlining a block tree into an item stays out of scope.
4. **Nesting: allowed**, capped (§2). Supersedes the earlier one-level proposal.

## 11. Risks

* **Item-type deletion is data loss at a new scale.** `SyncFieldValues` purges
  on destroy; for an item type that is whole paragraphs of content. Mitigation:
  count shown in the admin, destroy refused while items exist unless confirmed,
  and the existing purge-then-regenerate semantics documented.
* **References/media in items (PR 3)** touch four layers that assume top-level
  names (`firing/custom_fields.ex`, `sync_reference_links.ex`,
  `content_links.ex`, `reference_edits.ex`). Highest regression risk; keep it in
  its own PR with firing and re-fire tests.
* **Editor pickers addressed by field name** need a path; getting this wrong
  writes a snapshot to the wrong item. Address by `_id`, not index.
* **Identity vs positional wire form.** A stale form after a concurrent
  reorder must not attach values to the wrong item; merge strictly by `_id`.
* **Payload size / write cost.** One JSONB value holds the whole tree and every
  write re-coerces it, with `DB` reads for definitions (cached). Bound with
  `max_items` defaults (suggest 100 per field, configurable) and the existing
  per-value size limits; measure with a 50-item, 8-field fixture in PR 1.
* **Hard-coded `:group` sites** (`FieldSync`, schema emitters, `SyncFieldValues`
  SQL, `FieldAccess`) are enumerated in §6/§8; a missed one fails closed
  (item types are never listed as fields) rather than leaking, but an emitter
  that ignores `:flexible` would ship an untyped client — the exhaustive tests
  (`field_kind_test`, golden schema tests) are the net.
* **Private/hidden masking** deliberately does not apply (a flexible field
  cannot be private); a test pins `refute :flexible in PrivateFields.types()`
  like the existing group guard.
* **Nesting multiplies every recursion** (coercion paths, `SyncFieldValues` SQL, display, diff, GraphQL reader, emitters, editor cards). One shared depth constant, enforced at definition time, with tests at the cap and cap+1; the default stays 3 until measured.
* **Scope creep to "page builder".** Items are data with settings, not layout;
  `columns` stays the layout primitive in the body. The doc and the admin copy
  must say so.
* **Competitor claims** in the issue come from recall; none of the design above
  depends on them.
