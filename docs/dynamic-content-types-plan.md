# Dynamic content types (admin-defined) — design & phased plan

**Status:** design proposal (no code yet).
**Goal:** a non-developer defines a new content type — "Recipe", with its own
fields — from the admin UI and starts publishing immediately, with no code
deploy. This is the single biggest capability gap versus Directus and Drupal,
whose admin-defined collections/content types are *the* reason non-developer
teams pick them.

**Relationship to D4:** this plan **amends, not reverses, D4** ("content
types: compile-time, not a runtime meta-model"). Proposed as decision **D17**:

> **D17. Two-tier content types: compiled (first-class) + dynamic (data).**
> Compiled types (`use KilnCMS.CMS.Content`) remain the strongly-modeled,
> compile-time-safe path with per-type tables, typed GraphQL/JSON:API, and
> Dialyzer coverage. **Dynamic types are rows**, backed by one generic `Entry`
> resource over a single table — the Directus model — reusing the existing
> `FieldDefinition`/custom-fields machinery for their schema. Dynamic types
> never create atoms or modules at runtime; they are **strings end-to-end**.
> A generator (`mix kiln.gen.content --from <name>`) *promotes* a dynamic type
> to a compiled one when a project outgrows the generic tier.

The two tiers are also the honest answer to the trade-off D4 was protecting:
you get Directus-style agility *and* keep the "harder, better-typed than
Strapi" story — with a graduation path between them instead of a fork.

---

## 1. What already works at runtime (why this is cheaper than it looks)

The June/July work left the codebase far more runtime-type-friendly than D4's
wording suggests. Confirmed by code inspection:

| Subsystem | Status | Where |
|---|---|---|
| Type discovery & descriptors | Registry with label/plural/path_segment per type | `KilnCMS.CMS.ContentTypes.all/0` |
| Public delivery dispatch | String-driven `/:type/:slug` route → descriptor lookup → 404 on unknown | `ContentController.show_content/2`, `ContentTypes.get_by_path/1` |
| Editor | One generic `ContentEditorLive` keyed by `kind`; renders custom-field inputs from `field_definitions_for!/1` | `content_editor_live.ex:95` |
| Field schema as data | `FieldDefinition` (9 field types, required/options/default/position, per-type scope) + `ApplyCustomFields` coercion/validation on write | `field_definition.ex`, `changes/apply_custom_fields.ex` |
| Tags & relations | Polymorphic single-table joins (`Tagging`, `ContentLink`) — any UUID can be tagged/linked, no per-type schema | `tagging.ex`, `content_link.ex` |
| Fired artifacts | `PublishedArtifact` keyed by `(document_type, document_id, surface)`; `Firing.Engine.read/3` is data-driven | `firing/published_artifact.ex` |

What is genuinely compile-time today: the resource module per type (and its
table, migrations, code interfaces), the atom-based type key
(`String.to_existing_atom` guards), and the per-type JSON:API/GraphQL
surfaces.

## 2. Architecture

```
Admin UI                     Storage                        Consumers
─────────                    ───────                        ─────────
TypeDefinitionLive  ──────►  TypeDefinition (rows)
  name/label/plural/           │ 1:N
  path_segment/options       FieldDefinition (extended:
FieldDefinitionLive ──────►    scope = compiled atom XOR
                               type_definition_id)
                               │ validates
ContentEditorLive   ──────►  Entry (ONE table)  ──fire──►  PublishedArtifact
  (existing, kind =            title/slug/locale/blocks/     (document_type
   dynamic descriptor)         custom_fields/state/…          = :entry)
                               unique (type_definition_id,
                                       slug, locale)
                                        │
        ContentTypes.all/get_by_path — merged registry:
        compiled module scan  ∪  TypeDefinition rows (cached)
                                        │
        /:type/:slug   /api/content/:type/:slug   sitemap   search
```

### 2.1 `TypeDefinition` resource (new)

Rows define dynamic types. Attributes:

- `name` — machine key, string, same charset rule as `FieldDefinition.name`
  (`^[a-z][a-z0-9_]*$`). Immutable after creation (it keys entries, URLs,
  artifacts).
- `label`, `plural_label` — human names for the editor/nav.
- `path_segment` — URL segment for delivery (default: pluralized name).
- `excerpt?`, `published_feed?` — mirror the Content macro's `:excerpt?` /
  `:published?` options.
- `icon`, `description` — admin nav niceties.
- Soft-delete via AshArchival (a type with entries must be archived, not
  destroyed; entries of an archived type stop resolving publicly but remain
  editable/exportable).

Validations (all against the **merged** registry, so collisions with compiled
types are impossible): unique `name`, unique `path_segment`, and both must not
collide with any compiled type's `type`/`path_segment` or reserved router
segments (`blog`, `search`, `editor`, `admin`, `api`, locale prefixes, …) —
maintain the reserved list next to the router.

Policies: admin-only CUD (schema design is an admin act, like
`FieldDefinition` today); editors read.

### 2.2 `Entry` resource (new) — one table, the full content behaviour

`Entry` is a real compiled Ash resource (D4-compliant!) that all dynamic
entries share:

- **Reuse the `Content` macro** with a new `dynamic?: true` option rather than
  hand-writing ~900 lines: `use KilnCMS.CMS.Content, type: :entry, dynamic?: true`.
  The option adjusts what the macro emits:
  - adds `belongs_to :type_definition` (`allow_nil?: false`) and accepts it on create;
  - identity becomes `[:type_definition_id, :slug, :locale]`;
  - `public_by_slug` / `published_translations` / `search` / `autocomplete`
    gain a required `type_definition_id` argument in their filters;
  - **omits** the `json_api`/`graphql` blocks (dynamic types get their own
    generic surface, §2.6, not the per-type one);
  - `__kiln_content_type__` is **not** emitted (Entry must not be discovered
    as a content type itself — discovery of dynamic types is DB-driven).
- Everything else comes free and identical to Page/Post: blocks (BlockUnion),
  PaperTrail versioning, the draft → in_review → published → archived state
  machine, optimistic locking, AshOban scheduled publish + trash purge (one
  trigger pair for the whole table), archival, policies, custom_fields,
  author/category/featured_image/tags/links, word_count.
- Migration adds the `entries` table **plus** the two custom pieces every
  content table carries: the trigger-maintained `search_vector` column with
  its GIN index (copy the `add_locale_weighted_search` pattern) and the
  HNSW/trigram indexes the macro's `custom_indexes` already declare.

Why one table (Directus model), not table-per-dynamic-type: runtime DDL is
the failure mode D4 was right about — migrations generated and executed by a
web request are operationally scary (locks, rollback, multi-node races) and
would still not buy typed API surfaces (Absinthe schemas are compile-time).
JSONB `custom_fields` + expression indexes (Phase 6, if needed) cover the
realistic query load for the tier; heavy types graduate via promotion.

### 2.3 `FieldDefinition` extension

Today: `content_type :atom` validated against compiled types. Change to a
**two-scope model**: add nullable `type_definition_id` FK; exactly one of
`content_type` / `type_definition_id` is set (validation). Identity becomes
two partial identities (`[:content_type, :name]` where type_definition_id is
nil, `[:type_definition_id, :name]` otherwise). `for_type` gains a
`for_definition` sibling; `ApplyCustomFields` picks the scope from the
changeset's resource (Entry → definition scope). Editor code path is shared —
it already renders from a list of definitions.

Field types stay the current nine (`string/text/integer/float/boolean/date/
datetime/url/select`) in Phase 1–3; `media` (MediaItem reference) and
`reference` (content reference via ContentLink) are Phase 5 — they're the two
that make "Recipe" feel real (hero photo, related recipes) and both have
existing storage to lean on.

### 2.4 Discovery & dispatch — the merged registry

`ContentTypes.all/0` returns compiled descriptors ∪ dynamic descriptors
(mapped from live `TypeDefinition` rows). The descriptor grows a
`source: :compiled | :dynamic` field (and `type_definition_id` when dynamic).
Consumers — admin nav, editor index, sitemap, delivery controller, search
palette, webhooks — already iterate descriptors, so they pick dynamic types
up mostly for free; the convention-dispatch helper (`call/3` →
`domain.list_<plural>!`) grows a dynamic branch that calls the Entry code
interfaces with a `type_definition_id` filter instead.

Two hard rules:

1. **Dynamic type names are strings end-to-end.** No `String.to_atom` on any
   request-derived value, ever. Where an atom is structurally required
   (`PublishedArtifact.document_type`), the constant `:entry` is used and the
   dynamic type is recoverable from the entry row.
2. **The registry read is cached** (Cachex, keyed bump on any TypeDefinition
   write — same invalidation style as `BustContentCache`) so `/:type/:slug`
   delivery doesn't add a DB round-trip per request. Compiled wins name
   collisions by construction (validated at TypeDefinition create).

### 2.5 Editor & admin UI

- **`TypeDefinitionLive`** (new, `/editor/types`): CRUD for dynamic types +
  inline management of their field definitions (reusing the
  `FieldDefinitionLive` form components), drag-to-reorder positions.
- **`ContentEditorLive`**: accept a dynamic descriptor as `kind`. Mount
  builds the form over `Entry` (create sets `type_definition_id`), loads
  definitions by scope. Blocks, autosave, conflict banner, presence, preview,
  version history all apply unchanged — they hang off the record, not the
  type.
- **Editor nav / dashboard**: descriptor-driven lists get dynamic types
  automatically; add a "＋ New content type" affordance for admins.

### 2.6 Headless APIs

- **Fired delivery (`GET /api/content/:type/:slug`)** — works via the merged
  registry; the artifact is read as `(:entry, entry_id, surface)`. The `json`
  surface's `type` field carries the dynamic type name string.
- **JSON:API / GraphQL** — one *generic* surface: an `entries` query/route
  with a required `type` (name string) filter, exposing the shared shape
  (title/slug/locale/custom_fields/blocks-fired/…). Per-type typed schemas
  (`recipe { … }`) are **deliberately not** generated at runtime — that is
  the promotion pitch: graduate to a compiled type and the macro gives you
  the typed surface. Documented in `headless-consumer-guide.md`.
- **Webhooks / sitemap / feeds** — descriptor-driven; entries participate
  like any content.

### 2.7 Search

Entries get the same three search modalities with a type facet:

- Full-text: `search_vector` trigger on `entries` + the macro's `:search`
  action (type-filtered).
- Semantic: `embedding` column + `EnqueueEmbedding` already ride along via
  the macro.
- On-site `/search` and the editor palette: descriptor iteration picks
  entries up; results label with the dynamic type's `label`.

### 2.8 Promotion path (`mix kiln.gen.content --from recipe`)

Igniter task, dev-time: reads the TypeDefinition + its FieldDefinitions,
generates a compiled content module (custom fields become real attributes
where types map cleanly, else stay in `custom_fields`), the migration for its
table, **and a data migration** moving entry rows (+ PaperTrail versions,
taggings, content links, artifacts) into it, then archives the
TypeDefinition. This keeps the two-tier story honest: dynamic for speed,
compiled for depth, no dead end. (Last phase; design detail deferred until
the tiers exist.)

## 3. What stays compile-time (unchanged decisions)

- **Block types** (D10/D11): `Kiln.Block` Spark DSL, typed unions. Dynamic
  *block* types are out of scope — blocks are too entangled with rendering,
  firing, and upcasting (D15). Dynamic types compose the existing block
  palette plus custom fields; that matches Directus (fields) + a fixed block
  editor, which is already ahead of it.
- **Page/Post and project compiled types**: untouched; same macro, same
  behaviour.
- **Firing (D9)**: publish still compiles immutable artifacts; entries fire
  exactly like pages.

## 4. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Registry cache staleness across nodes | Same PubSub-bust pattern as content cache; TTL backstop |
| `custom_fields` query performance at scale | JSONB GIN/expression indexes (Phase 6); promotion path is the real answer |
| Name/segment collisions with compiled types or routes | Merged-registry validation + reserved-segment list at TypeDefinition create; compiled always wins |
| Type deletion orphans entries | Archive-only when entries exist; public resolution stops, editing/export continues |
| `Content` macro option creep | `dynamic?` is the second option axis (after `excerpt?`/`published?`); if a third tier appears, split the macro |
| PaperTrail/Oban volume in one table | Same coalescing + purge machinery; single-table triggers are *simpler* than per-type |

## 5. Phases

Each phase lands independently green (precommit + tests) and is useful on its own.

1. **Meta-model & admin.** ✅ **Done.** `TypeDefinition` resource + policies +
   registry (`ContentTypes.dynamic_all/get_dynamic/reserved_path_segments`;
   caching deferred to Phase 3 when the registry hits the request path) +
   `FieldDefinition` two-scope extension + `TypeDefinitionLive` at
   `/editor/types` (fields managed via the extended `/editor/fields`).
   *Acceptance met: admin creates "Recipe" and attaches typed fields in the
   UI; no entries yet.*
2. **Entries & editor.** ✅ **Done.** `Content` macro `dynamic?` option,
   `Entry` resource + migrations (incl. search_vector trigger), merged
   `ContentTypes.get/get_by_path` + dynamic dispatch to the entry
   interfaces, two-scope `ApplyCustomFields`/`BustContentCache`, editor
   index + `ContentEditorLive` + trash on dynamic kinds. Notes vs the
   original sketch: the type facet on `search`/`autocomplete` moved to
   Phase 4 (with the rest of search), and instead of omitting
   `__kiln_content_type__` Entry exports a `__kiln_dynamic_entry__` marker
   the shared changes branch on. *Acceptance met — covered by
   `dynamic_entry_editor_test.exs`: create → edit + custom fields →
   publish a Recipe end-to-end in the editor.*
3. **Delivery.** ✅ **Done.** Public `/:type/:slug` (needed zero controller
   changes — the merged registry + dispatch carried it), firing on publish
   (`:entry` in the References whitelist/edge/artifact constraints; the
   `json` surface's `type` carries the dynamic name via
   `Engine.public_type/1`), fired-artifact API (storage key from the record
   struct, not the requested name), sitemap, and the registry cache
   (`Cache.fetch` + `BustTypeRegistry` on every TypeDefinition write; off in
   tests — global key vs per-test sandboxes). Iteration call sites now pass
   descriptors into dispatch, closing an archive-mid-request race.
   *Acceptance met — `dynamic_delivery_test.exs`: published Recipe served
   on-site, via `GET /api/content/<name>/<slug>` (`json`/`web`), in the
   sitemap; archiving the type 404s immediately.*
4. **Search & headless.** ✅ **Done.** `Search.global` gained an `entries`
   section (labeled by the new public `type_name` expr calculation, which
   skips TypeDefinition's editor-only read policy); on-site `/search` and
   the editor palette list dynamic hits; generic JSON:API `/entries`
   collection + search/semantic/autocomplete routes (scoped by
   `filter[type_name]`) and curated GraphQL queries (`entryBySlug`,
   `searchEntries` + `typeName` filter, translations, autocomplete);
   webhook events named by the dynamic type (`"recipe.published"`), with
   dynamic types in the subscribable event list. Consumer docs updated in
   `headless-consumer-guide.md`. Note: the per-action `type_definition_id`
   facet sketched in §2 wasn't needed — query-composed filters and the
   `type_name` calc cover scoping without macro surgery. *Acceptance met —
   `dynamic_headless_test.exs` + delivery tests: Recipe findable everywhere
   Page is.*
5. **Field types v2.** `media` and `reference` field types (storage via
   MediaItem FK-in-map + ContentLink), editor pickers, delivery expansion.
6. **Promotion generator + JSONB indexes** (as needed).

## 6. Open questions (defaults chosen, flag to change)

1. **Workflow always-on for dynamic types?** Default **yes** — same state
   machine as compiled types; a "simple mode" (draft/published only) could be
   a TypeDefinition flag later.
2. **GraphQL in Phase 4 or cut?** Default **in** (generic `entries` query is
   cheap once JSON:API shape exists).
3. **Naming.** `TypeDefinition` + `Entry` (`type_definitions` / `entries`
   tables). Alternatives considered: `ContentTypeDef`, `DynamicContent`.
