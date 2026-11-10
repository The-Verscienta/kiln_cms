# Reference selection: filtered pickers and create-on-type — plan

Status: proposed. Tracking issue: #2285. Nothing is built.
Builds on the relationship workstreams in
[relationships-plan.md](../relationships-plan.md) (R1b `max_sources`, R2
`target_types`, R9 picker and "Add new"), the dropdown widget (#2284) and
per-field grants (#2281).

## Why

Drupal's entity-reference *selection handlers* let each field narrow its
candidates (by bundle, status, term, field value, author), sort them, and
auto-create a missing target when the editor types a new name (the tags
pattern). Payload's `filterOptions` is the same idea. Kiln's reference picker
(`KilnCMSWeb.ContentEditor.ReferencePicker`) searches every readable record of
the allowed target types, newest first. A site with 4,000 ingredients cannot
say "this field takes only published ingredients tagged *vegan*", and a tag-like
field cannot grow by typing.

What already exists and must not be rebuilt:

| Mechanism | Where | Consequence for this plan |
|---|---|---|
| Picker reads **as the actor, in the editor's tenant**, paginated | `ReferencePicker.read_type/6` via `ContentTypes.list!` | Read policies already decide what can be found; filters only narrow. |
| "Add new *Type*" creates a draft through the type's create action, authorized as the editor, offered only where `can_create?` holds | `ReferencePicker.creatable/1`, `create_and_connect/3` (#2005) | Create-on-type is a *shortcut into this flow* from the search box, not a new create path. |
| Save-time coercion reads each target as the writer and refuses what does not resolve | `ApplyCustomFields.coerce_reference/3`, `coerce_reference_list/3` | The filter is enforced here, so every write path (editor, R4b reverse writes, JSON:API, GraphQL, MCP, import) gets it. |
| Target-side rule enforced on *adds only*, under a lock | `max_sources` in `ContentLinks.reconcile/1` | Same stance for the filter: tightening it never breaks existing connections. |
| `custom_filter` grammar over custom fields, privacy- and tenant-aware, plus `has`/`has_all`/`has_none` over `tags` | `Preparations.CustomFieldQuery` (+ `Relations`) | Reused as the evaluator for field-value and tag conditions. No second filter language. |

## Decisions

**S1. One new option, `selection`, a map on `FieldDefinition`.** Not a set of
columns, and not extra keys in `validation`. `validation` is the value-shape
constraint map (`FieldConstraints`, flat scalar keys, applicable per field type);
a target filter is a different thing with nested structure. `selection` follows
the `visible_when` / `required_when` precedent: a nullable `:map` attribute,
`public?: true`, validated by a dedicated validation, cleared on anything but a
top-level `:reference` (`Changes.ClearReferenceOptions` gets one line). This is
the only data change: one additive column via `mix ash.codegen
reference_selection`, expand-only (a new nullable column nothing reads yet), so
`mix kiln.migrations.check` passes and the `kiln_reporting_v1` views do not
read it. No new table, no change to `content_links`.

**S2. A closed, validated vocabulary — never raw `_native`/Ash filters.** The
admin picks from conditions the server knows how to evaluate and authorize:

```json
{
  "states": ["published"],
  "owner": "self",
  "sort": "title",
  "by_type": {
    "ingredient": {
      "tags_any": ["<tag id>", "<tag id>"],
      "category": "<category id>",
      "fields": {"diet": "vegan", "region": {"in": ["eu", "uk"]}}
    }
  },
  "create": {"type": "ingredient"}
}
```

* `states` (any type): subset of the content states. Blank = no state filter
  (today's behavior: whatever the actor can read).
* `owner`: `"self"` = records whose author is the writing actor; blank = anyone.
  Evaluated server-side from the *actor*, never from a client value, and only
when the actor is a `User` (compared on `author_id`; an API-key actor with no
user matches nothing). `author_id` can be reassigned or nil on API/system
creates; under S4 that never disturbs existing connections.
* `sort`: `"recent"` (default when the search box is empty) or `"title"`.
  Applied after the filter, same keyset-safe order the picker uses now
  (`updated_at desc, id` / `title, id`).
* `by_type`: conditions that need the target type's shape, keyed by target type
  name so a polymorphic field (R2) can filter each type differently; a type with
  no entry is unfiltered. Inside: `tags_any` (built-in tags), `category`, and
  `fields`, a map of custom-field name → value or `{"in": [...]}`/`{"not_eq": v}`
  — the `custom_filter` grammar's equality-shaped operators only.
* `create`: see S5.

Conditions AND together. Refused at definition save (`Validations.ReferenceSelection`):
unknown keys; a `by_type` key that is not one of the field's target types; a
`fields` name that is not a custom field of that type, is `private`, or is of a
type with no equality semantic (media, reference, group, geolocation, link);
tag/category ids that do not exist in the org; `owner`/`states` on a non-reference.
Drift afterwards is handled too: flipping a field to `private` is refused while
a selection names it (mirroring the deletion guard), and the evaluator and
`SchemaExport` ignore an entry whose field, type, tag or category no longer
exists. A dead tag/category condition is **dropped**, not "match nothing": the
other conditions and the actor's read policy still bound the picker, and a stale
filter cannot silently lock editors out. The admin flags such an entry
"(not found)". The `private` refusal is deliberate: a filter on a value the picking editor
cannot read lets them infer it from which candidates appear (and #2281's read
grants only ever hide `private` fields, so this covers hidden ones too).

**S3. One evaluator, two callers.** `KilnCMS.CMS.ReferenceSelection` (new module,
pure over the definition plus an `actor`) turns the config for one target type
into the read-action filter and arguments: `owner` → `author_id == ^actor.id`,
`states` → `state in ^states`, `tags_any` → the existing `custom_filter` `tags`
`has` condition, `category` → equality, `fields` → `custom_filter` conditions.
Two callers use it and nothing else does:

1. **The picker**, in `read_type/6` and the dropdown's `read_candidates/3`,
   applied as the read's filter plus action *arguments* (`custom_filter` is a read
argument, not a `query: [filter:]` clause; `ContentTypes.list!` takes both, and
a dynamic type also needs its `type_definition_id` scoping so
`CustomFieldQuery` can resolve the definitions), an AND ( so it can only narrow what
   the actor's read policy already allows). `with_capacity/2` (`max_sources`
   "Full" rows) is unchanged and runs on the filtered page.
2. **Save**, in `ApplyCustomFields`, hung on the existing constraint
   machinery rather than a separate pass: next to `constrain/4` in `accumulate`
   (per item, like `new_items/3`), gated by the same `check?` flag and the same
   "equal to the stored value, so grandfathered" rule. For each target the
   write **adds**, one read of that target type, as the writer, with the id
   restricted to the added ids plus the same filter. Any added id the read does not return
   fails the field: *"“Basil” isn't one of the records this field accepts."*
   Because both callers go through the same module and the same read action, the
   picker cannot offer what save refuses or the reverse.

**S4. Enforce on add, not on every save.** Same rule as `max_sources` and the
bounds: a target already connected is never re-checked, so tightening a filter,
or a target changing state/tags afterwards, does not make every unrelated edit
of the source fail. Consequence, stated in the docs: the filter governs *who can
be connected*, not an invariant over everything connected. "Added" means *not in the baseline `ApplyCustomFields` already uses*:
`changeset.data.custom_fields` on an update, so a single field is added when
its id differs from the stored one and a `multiple` field per id. (This is
**not** the `content_links` diff `max_sources` uses; that one runs after the
write, this one must run during coercion, where the reader's error belongs.)
The check runs only when `check?` is true. Duplicate, translation, import-copy,
restore-version and publish-changes already pass `custom_fields_constraints:
:skip` (`ContentCopy`, `apply_restored`), whose baseline is `%{}`; they must
not re-judge every reference, so they skip it. A plain **create** has the `%{}`
baseline and is checked: every target is new. Reference sub-fields inside a
`group` row are grandfathered by row (`row_unchecked?`); if references are
allowed there, they are checked only for a new or edited row, and the plan's PR 1
confirms which before building (it excludes selection from group sub-fields if
that is simpler). Removing and reordering are never refused.

**Working copies.** `:save_working_copy` does not run `ApplyCustomFields`;
`StageWorkingFields` builds an `:update` probe on the working view of the row,
whose baseline is the held values. The filter is therefore enforced once, when a
target is added to a published page's working copy, and **not** again at
*Publish changes*, which re-runs `apply_restored` with `:skip`. That is
deliberate (S4) and must stay: a test pins it so nobody "fixes" promotion. A system actor and `authorize?: false` writes
skip it exactly as they skip the reference-snapshot masking
(`ApplyTargetDeleteRules`, bookkeeping writes), but still resolve each target.
Import runs under the operator actor and is treated as a normal create, so it is
checked unless it uses the copy-style `:skip`; the PR 1 test states which.
Not a race-safe guarantee: unlike `max_sources` (a count that must hold under
concurrency) this is an editorial rule, so there is no advisory lock; a target
losing a tag between the check and the commit is accepted and documented.

**S5. Create-on-type is a shortcut into the existing "Add new" flow, opt-in
per field.** `selection.create = {"type": "<one of the field's target types>"}`
turns it on. When the search box holds text and no result's title matches it
case-insensitively, the result list ends with a row *Create “text” as a new
Ingredient*. Choosing it:

* requires everything "Add new" requires: the field is not locked, the picker is
  `searchable?`, and `creatable/1` lists that type (so `ContentTypes.can_create?/4`
  as the actor held, plus the target type's field grants under #2281). Otherwise
  the row is not rendered. The server re-checks via `creatable_type/2` when the
  event arrives; a hand-crafted event for a type that is not listed is a no-op.
* calls the same `create_and_connect/3`, title = the trimmed query, as the actor,
  through `ContentTypes.create!/3`, so it is a draft, validations and slug
  uniqueness apply, and a refusal stays visible. If the target type has required
  fields without a default, the row opens the existing "Add new" form with the
  title prefilled instead of creating blind.
* then connects through the same `:add`/`:put` message as a pick, so the
  source's lock, dirty state and working copy are untouched, and the new draft
  passes the save-time filter because creation is constrained to make it do so:
  `Validations.ReferenceSelection` refuses `create` unless `states` is blank or
  includes `draft`, `owner` is blank or `self` (the creator is the author), and
  the type's `by_type` entry has no `tags_any`/`category`. Equality `fields` are
  written onto the new record's `custom_fields` at creation, so they hold.
* is narrow by construction: most filtered fields (published-only) cannot enable
  it. The admin refuses `create` with a reason (*"This field only accepts
  published Ingredients, so a new draft could not be connected"*) rather than
  hiding it. Equality `fields` are prefilled only if the field is plain
  (not computed, unique or defaulted dynamically) and writable by the actor under
  #2281 grants; `creatable/1` checks those specific fields, and omits the type
  otherwise. In PR 1 the validator refuses `create` outright until PR 4.
* The exact-title check runs over the *filtered* results, so a readable record
  that fails the filter would not suppress the row. Because compatibility already
  requires drafts to be accepted, the only unseen duplicates are unreadable ones
  or ones excluded by `owner`/field filters; this is documented, not solved.
* never creates through the API. Headless clients create the target through its
  own create endpoint and then connect it; a PATCH naming an unknown title is a
  validation error, not an implicit create. This keeps every create an explicit,
  separately authorized and audited action.

**S6. No new authority.** The selection config is not an access-control
mechanism and is documented as such: it narrows what the *picker offers* and
what a *write may add*, always intersected with the actor's read policy. It
cannot reveal a record the actor cannot read, because the filter is an extra AND
on a read the policy already gates. It cannot create a record the actor cannot
create, because create-on-type is `create_and_connect/3`. The definition itself
is written by admins only (existing `FieldDefinition` policies; no change).

## The reverse side (R4b)

The reverse field builds a synthetic definition for its add control
(`reverse_field.ex`), whose candidates are *sources* while the forward field's
filter is about the *target* (the record being viewed). So the synthetic
definition never carries `selection` or `create` (a create there would make a
source from the target's page), and the real rule applies at the source's write
(`ReverseFields.connect` → update or `save_working_copy`). Decision: when the
viewed target fails the field's filter for the actor, the reverse add control is
disabled with a reason instead of offering candidates that would all be refused;
`connect` also maps the field error to a clean message. Tests: reverse connect
with a target that fails the filter, and `owner: self` where the reverse editor
is not the source's author.

## Picker UX

* Fields admin (`/editor/fields`), under the relationship steps from #2025, a new
  step **"Which records can be picked"**: states (checkboxes), "only records I
  created", and, per allowed target type, tags, category and "field equals" rows
  (the field list is the target type's non-private, equality-capable custom
  fields), then a sort choice. A sentence reads the setting back: *"Published
  Ingredients tagged vegan or raw, newest first."* A second step, **"Let editors
  create what they type"**, shows only when the filter is compatible (S5), with
  the compatibility reason when it is not.
* Picker: results and the dropdown widget show only matches. An empty state under
  an active filter says why: *"No published Ingredients match. This field only
  accepts published Ingredients."* (so the missing record is explained, as "Full —
  3 of 3" is for `max_sources`). The footer lists the active conditions.
* The create row is last in the list, uses the `btn`/list kit from
  `docs/design-language.md`, is announced through the picker's existing
  `announcement` live region, and keyboard-reachable like a result row.
* Existing connections that no longer match are shown as today and carry no
  warning; only adding is gated (S4).
* All new strings go through gettext; American English.

## API, GraphQL, MCP

* **Enforcement** needs no API change: JSON:API `PATCH`, GraphQL
  `add…References`/mutations and MCP all end in `ApplyCustomFields` (S3.2), so a
  refused target returns the same field error shape they return for an
  unresolvable one.
* **Description**: `SchemaExport` / `GET /api/schema` report the config as
  `selection` on a reference field, next to `max_sources`. Tag and category are
  reported as ids only (nothing the schema does not already expose); `private`
  fields cannot appear in it (S2). TypeScript/Swift/Kotlin exporters get the
  field as a comment/doc only, not a type change. Additive under the 1.0 overlay
  contract.
* **Other surfaces that serialize `FieldDefinition`** (admin GraphQL/JSON:API
  domains) emit `selection` since it is `public?`; PR 1 audits them and either
  restricts the attribute to admins or documents it. `JoinGraduation` copies
  `max_sources` into the graduated join; `selection` is **not** carried, and the
  graduation docs say the filter is dropped with the field.
* **Not in this plan**: a "candidates" endpoint that applies the filter for a
  headless admin UI. It is a new public surface and deserves its own issue once
  the semantics are proven in the editor.

## Authorization matrix (what each test must prove)

| Actor / situation | Picker | Save |
|---|---|---|
| Anonymous / viewer | no picker | n/a |
| Editor, target readable and matches | listed | added |
| Editor, target readable but fails filter | not listed | refused (even with a hand-posted id) |
| Editor, target matches but unreadable (policy, tenant, trashed) | not listed | refused as today |
| `owner: self`, record by another author | not listed | refused |
| Editor lacking create on target type | no create row | server no-ops the event; API cannot create |
| Field locked (#2281, no write grant) | no create row, no connect | refused as today |
| Admin | filter still applies (it is field config, not policy) | filter still applies |
| System actor / `authorize?: false` | n/a | skips filter, still resolves target |
| Connection already present, no longer matches | shown | unchanged on unrelated edit |

## Tests

* `ReferenceSelectionTest` (unit): config → filter for each condition, per type,
  actor-relative `owner`, AND composition, polymorphic `by_type`.
* `Validations.ReferenceSelection` table: every refusal in S2, plus `create`
  compatibility (S5).
* Save enforcement through `ApplyCustomFields` for single and `multiple` fields:
  add a non-matching target refused; unchanged non-matching kept; reorder and
  remove allowed; hand-posted id of a filtered-out record refused (the "UI-only
  enforcement" regression).
* Picker LiveView tests: filtered results, dropdown widget parity, the empty
  state, the create row (shown / hidden for no-create-rights / locked / exact
  match), a forged `ref_new` event for an unlisted type, a draft created by the
  actor with the title, a validation error left in the form.
* Authorization: `Forbidden` on create becomes a form error, not a crash;
  unreadable-target and cross-tenant targets are never listed (reuse the R-series
  fixtures).
* API: JSON:API `PATCH` and GraphQL mutation refuse a filtered-out target with
  the field error; `/api/schema` reports `selection`.
* Write paths: duplicate, translate, restore-version and publish-changes with a
  non-matching held target all succeed; plain create with one is refused; a
  working copy adds a target, the filter changes, publish succeeds; single-valued
  and `multiple` fields both named; a dynamic-type (Entry) fixture, including
  whether `tags`/`category` conditions are supported there (else refused at
  definition save for dynamic types).
* Drift: making a field `private` while a selection names it is refused; a
  deleted tag/category is dropped and flagged.
* Field-equality on a `private` field refused at save of the definition.
* Migration: `mix kiln.migrations.check` clean; resource snapshot regenerated.
* e2e: one Playwright flow — type a name, create, see the row with a Draft
  badge, save.

## Docs

`docs/relationships-plan.md` gains a pointer under R9; `docs/json-api.md` and
`docs/headless-graphql-api.md` the refused-target error and the `selection`
schema key; `docs/extending-content.md` / the fields admin guide a "Limit what
can be picked" how-to; `docs/design-language.md` only if a new component class
appears. `CHANGELOG.md` one line per PR plus the long-form entry in the next
release's `docs/changelog/` file.

## Risks

* **Filter drift between picker and save.** Mitigated by one module and one
  read action (S3); a test asserts the two agree on a fixture matrix.
* **Perf of the equality filter.** `fields` conditions are jsonb comparisons;
  the same cost as `custom_filter` today. A site that filters a large type on a
  hot field is pointed at the range/sort indexes config (#2370-era ADR 0025).
  Add the filtered picker read to `scripts/benchmarks/` only if the CI numbers
  warrant it.
* **Duplicate creates.** Typing a name an actor cannot read creates a second
  record. Unavoidable without leaking existence; the exact-match check uses the
  results the actor can see. Documented.
* **Draft spam.** Each create row click makes a draft that stays if the source
  change is abandoned (the R9 stance). Mitigated by an exact-match check and the
  existing per-actor write budgets; no new limiter.
* **Admins surprised that a filter binds them.** Stated in the docs and the
  fields-admin copy.
* **Interaction with #2281.** If read grants land first, nothing changes
  (private fields are refused in filters). If grants on the *target* type's
  required fields refuse the actor's create, `creatable/1` already omits the
  type.
* **Plugin and dynamic types.** `by_type` is validated against the merged
  registry like `ReferenceTarget`; a type removed later makes its entry inert
  (ignored, flagged "(not found)" in the admin), never an error on every save.

## Recommended split (4 PRs, in order)

1. **Foundation + server filter.** `selection` attribute and migration,
   `Validations.ReferenceSelection`, `ClearReferenceOptions`, `ReferenceSelection`
   evaluator, save-time enforcement in `ApplyCustomFields`, `SchemaExport`
   key, unit/API tests. Usable through the API and `mix` seeds; no UI yet.
2. **Picker uses the filter.** Search and dropdown candidates filtered, empty
   state, active-conditions footer, picker tests.
3. **Fields-admin editor for `selection`.** The step, read-back sentence,
   compatibility message; admin LiveView tests; docs how-to.
4. **Create-on-type.** `create` option and its validation, the create row,
   prefill into the existing form, e2e. Last because it depends on both the
   filter compatibility rules and the picker.

Between PR 1 and PR 2 a selection set by seed or API makes the picker offer
targets that save refuses, so PR 1's docs say to configure it only with PR 2.
PR 1 is the biggest: if review wants it smaller, peel off `SchemaExport` and the
`ClearReferenceOptions` line. PR 2 also carries the reverse-control decision.

PRs 1 and 2 are the core of the issue; 3 and 4 can follow in either order after
2. Each is additive and independently releasable.

## Decided by the maintainer (2026-11-10)

1. `selection` is its own nullable column (S1), not nested under `validation`.
2. `states` stays blank by default for new reference fields.
3. `owner: self` is in v1.
4. Create-on-type always creates drafts.
