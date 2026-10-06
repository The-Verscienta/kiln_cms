# Field-level localization: design check

**Status:** built in 1.1 as Design A, as an addition — see *How 1.1 built it*
at the end, and [localization workflows](localization-workflows.md)
for how to use it. The rest of this note is the v0.12 design check for
[#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327), kept as it
was written. The feature was scheduled on 2026-09-18 (roadmap decision 2) to
land **after 1.0, as an addition**. That schedule holds only if the feature can be added without
changing anything on the covered list in the
[overlay contract](overlay-contract.md). This note checks whether it can.

**Conclusion: it can be added without changing a covered surface.** Design A
below is additive on every covered surface. Nothing has to be reserved or
changed before the 0.12 freeze. The other shape (Design B, one row holding
every locale) would break several covered surfaces. It is recorded here so a
later reader can see why it was rejected. Three guardrails keep Design A open.
None of them is a covered-surface decision, and they are listed at the end.

## What exists today

Kiln stores **one record per locale**, and every locale-aware surface is built
on that:

- **Identity.** A content row carries a public `locale` attribute (default
  `"en"`). Its slug identity is `[slug, locale]`, or
  `[type_definition_id, slug, locale]` on the dynamic entry tier.
  `KilnCMS.CMS.Content` injects both. Each variant has its own `id`, its own
  blocks, SEO fields, `custom_fields`, workflow state and version history.
- **Delivery.** `:public_by_slug` takes `slug` + `locale` (plus
  `fallback`/`fallback_locale`). `Preparations.LocaleFallback` walks the
  site's chain in one query and returns the first **row** that qualifies
  ([#1579](https://github.com/The-Verscienta/kiln_cms/pull/1579)). The
  chain comes from `KilnCMS.I18n.Fallback.chain/4`, which resolves *locales*,
  not rows. `:published_translations` lists every published variant of a slug.
  It backs hreflang and the GraphQL `*Translations` queries
  (`postTranslations`, `entryTranslations`, …). JSON:API `/by-slug/:slug`
  and GraphQL `*BySlug` return one row and state the served locale in
  `x-kiln-locale` / `Content-Language`.
- **Blocks (D3).** `blocks` is an `{:array, KilnCMS.CMS.BlockUnion}` of
  embedded resources: one JSON tree per row. It is **not** `public?`. The HTTP
  surface is the fired artifact, and the raw tree is never serialized.
  `KilnCMS.CMS.ContentCopy` copies the tree into a new translation with
  `keep_ids?: true`, so **block `_id`s are shared across locale variants of a
  document**. XLIFF units (`b:<id>.<field>`) depend on this. Design A does too.
- **The `translatable:` field option.** `Kiln.Block`'s `field` entity accepts
  `translatable: true | false | :unsupported | [keys]`, and
  `Kiln.Block.Transformer` checks it against the field type. The issue
  suggested it as possible groundwork. **It is not groundwork for this
  feature.** It answers *"is this prose a translation vendor should see?"*,
  which is what `Kiln.Block.Info.translatable/1` feeds to `KilnCMS.CMS.Xliff`.
  Field-level localization asks a different question: *"does this value differ
  between locales?"* The two answers diverge in both directions. A
  locale-specific hero image is localized but not prose. A product name
  kept in English everywhere is prose but shared. The option is covered
  (`Kiln.Block` DSL options), and the contract forbids repurposing a name, so
  the new behaviour needs its **own** option.
- **Custom fields.** `custom_fields` is a public `:map` keyed by
  `FieldDefinition.name`, written per row by `Changes.ApplyCustomFields`, and
  copied into the `:json` artifact as `"custom_fields"`.
- **Search.** `search_text` is denormalized per row by `Changes.SetSearchText`.
  The `search_vector` trigger (installed by `KilnCMS.Migrations`'
  `add_search_vector/1`) stems it with the **row's** locale config.
- **Fired artifacts.** `KilnCMS.Firing.PublishedArtifact` has the identity
  `(document_type, document_id, surface)`, so there is one artifact per
  variant. The `:json` body carries `id`, `type`, `title`, `slug`, `locale`,
  `custom_fields` and `blocks`. `KilnCMS.SchemaExport` describes that body.
- **Sync delta API.** `KilnCMS.Firing.Sync` emits
  `upsert {type, id, slug, locale, published_at, updated_at, artifact}` and
  `delete {type, id}`, and derives "what changed" from PaperTrail version
  rows. Its moduledoc names the blind spot: a re-fire that writes no version,
  such as a fragment change, is not reported.

The consequence: every variant is already a complete, independently
publishable document. What Kiln lacks is a way to say **"this field is the same
in every locale"** and **"if this field is empty here, use the next locale's
value"**. Field-level localization means those two things in a
document-per-locale CMS.

## Design A: localization modes over locale variants (recommended)

Keep one row per locale. Give each field a **localization mode**:

| Mode | Meaning | Today's equivalent |
|---|---|---|
| `:localized` (default) | Each variant holds its own value | Every field, today |
| `:shared` | One value for the document, owned by the **source variant** (the default-locale row) and copied into every sibling | None; editors copy by hand |
| `:fallback` | Each variant may hold its own value; an **empty** one is filled along the site's fallback chain when the variant is fired | None |

The default is today's behaviour, so nothing changes until a type opts in.

### Where the modes are declared

- **Block fields:** a new `field` option, e.g.
  `field :media_id, :string, translatable: false, localized: :shared`.
  (`localized:` is a working name. Any name other than `translatable:` works.)
  Spark rejects unknown entity options, so no overlay can already be passing
  it. `Kiln.Block.Field` gains a struct key, and `Kiln.Block.Info` gains
  `localization/1`. Both are additions.
- **Custom fields:** a `localization` attribute on `FieldDefinition` (default
  `:localized`). This is a core-table column generated through
  `mix ash.codegen`. It adds no migration to overlay tables.
- **Record attributes** (`seo_image`, `category_id`, `canonical_url`, …): a
  new `KilnCMS.CMS.Content` option such as
  `localization: [shared: [:seo_image, :category_id], fallback: [:excerpt]]`.
  This is additive. See guardrail 3 about how unknown options are handled.

### Where the values live

On the rows, exactly as today. A shared value is **copied** into each sibling,
not resolved at read time. Each variant row therefore stays self-contained,
and search, firing, the sync API and the version history see correct data
without learning that siblings exist.

- The copy is made when the **source publishes**. It runs through a new
  internal write action on each sibling, e.g. `:sync_shared_fields`. The
  contract already leaves room for this: internal write actions outside the
  workflow set are "not covered", like `:reindex_search_text`. The copy
  addresses block fields by the shared `_id` (the same addressing XLIFF
  uses). It skips a block that the sibling no longer holds, or whose `_type`
  differs, and it upcasts both sides before copying, because
  `KilnCMS.Blocks.Upcaster` is lazy.
- A published sibling is re-fired. A sibling with an open working copy gets
  the value in `working_blocks` too, so the next publish does not revert it.
- The copy writes a version, so the sync delta reports each sibling as an
  upsert without any change to `KilnCMS.Firing.Sync`.

### How the editor shows it

(Not covered: this is `KilnCMSWeb.*`.) On a non-source variant, a shared
field is read-only, labelled *"Shared, edited in English"*, and links to the
source. On the source, it is labelled *"Shared with N locales"*. An empty
`:fallback` field shows the value it will inherit as placeholder text, with
the locale it comes from. The Translations panel and `/editor/translations`
report staleness only for `:localized` and `:fallback` fields.

The write path holds the same line (#1860,
`KilnCMS.I18n.Validations.SharedFieldsReadOnly`): on a translation, `:update`,
`:autosave` and the working copy refuse a value for a shared field that the
next copy would overwrite — one that differs from both the translation's
current value and the source's — with a validation error naming the field and
the source locale. So a JSON:API or GraphQL client hears about it when it
writes, rather than losing the value at the source's next publish.

### How delivery chooses a locale

Unchanged at document level: the chain picks the **row**. For `:fallback`
fields, the firing engine fills each empty value from the first variant along
`Fallback.chain(org, row.locale, :site)` that has one, **before** the block
reaches its renderer. `chain/4` already resolves locales, not rows, and
`docs/localization-workflows.md` already promises per-field resolution along
the same chain. Renderers still receive a normal typed block with a string
where a string was declared.

### Walking the covered surfaces

| Covered surface | Design A |
|---|---|
| `KilnCMS.CMS.Content` options (`:type` … `:seo_description_pattern`) | **Unchanged.** A new option is an addition. |
| The two `*_pattern` token vocabularies | **Unchanged.** |
| `__kiln_*__/0` functions | **Unchanged.** A new `__kiln_localization__/0` would be an addition. |
| Workflow action names (`:read` … `:destroy`, `:public_by_slug`) | **Unchanged.** Same names, arguments and meaning. The copy is a new internal action outside the workflow set. |
| Merge-argument convention (`tag_ids` / `add_` / `remove_`) | **Unchanged.** A shared `category_id`/tag set is copied through the existing complete-set arguments. |
| `Kiln.Plugin` callbacks | **Unchanged.** |
| `Kiln.Block` DSL: entities, options, field-type vocabulary, Kiln-to-Ash mapping | **Additive only.** One new `field` option. `translatable:` keeps its meaning. No field type or mapping changes, because a shared field stores the same type it always did. |
| `_type` / `_version` attributes | **Unchanged.** No attribute is injected on blocks. |
| `Kiln.Block.Renderer` (`:web`, `:json`, `:json_ld`, `nil` for unhandled) | **Unchanged.** Fallback values are filled before render, and the renderer sees the declared shape. |
| `Kiln.Block.Info` | **Additive only.** A new `localization/1`. |
| `Kiln.FieldType` | **Unchanged.** The mode belongs to the field *definition*, not the type. |
| `Kiln.Advisory`, `Kiln.Forms.SpamCheck` | **Unchanged.** |
| `Kiln.Plugins`, `Kiln.Version`, `Kiln.Updates`, `Kiln.Tokens` | **Unchanged.** |
| `KilnCMS.Blocks`, `KilnCMS.Blocks.Upcaster`, `KilnCMS.CMS.ContentTypes` | **Unchanged.** The copy *calls* the upcaster and does not change it. |
| `KilnCMS.Migrations` search-vector helpers | **Unchanged.** One row, one locale, one vector. Shared values are in the row's `search_text` like any other. |
| `KilnCMS.SchemaExport` shape, `KilnCMS.Branding` | **Unchanged.** The `:json` artifact keeps its shape. An `x-kiln-localization` annotation would be additive. |
| `KilnCMSWeb.PluginRouter`, `KilnCMSWeb.AshJsonApiRouter` | **Unchanged.** |
| Config keys, build conventions | **Unchanged.** No overlay migration is needed: the mode is declared in code or in a core table. |
| `public-*` CSS hooks | **Unchanged.** |

The HTTP contract (*Versioning & stability* in the [API guide](api.md))
is governed separately, and it passes too:

| HTTP surface | Design A |
|---|---|
| JSON:API / GraphQL `public?` attribute names and types (`title`, `locale`, `custom_fields`, …) | **Unchanged.** Every value keeps its type. A shared custom field is the same key with the same value shape on every variant. |
| Resource identity: one `id` per (document, locale) | **Unchanged.** |
| `*BySlug`, `/by-slug/:slug`, `*Translations`, `?locale=` / `?fallback=` / `?fallback_locale=`, `x-kiln-locale` | **Unchanged.** The document-level chain is untouched. |
| Fired artifacts (`json` / `json_ld` / `web`) | **Unchanged** in shape. For `:fallback` fields, a field that was empty now carries the next locale's text. That only happens on fields a type opted in, and the `:json` body may gain an additive key saying which fields were filled from which locale. |
| Sync delta API | **Unchanged.** Shared-field copies write versions, so they are reported. A `:fallback` re-fire caused by a *sibling's* edit writes no version, and falls into the blind spot `KilnCMS.Firing.Sync` already documents for fragments. Closing it (e.g. reporting re-fired documents) would add upserts, and upserts are idempotent, so that is additive. |

### What Design A costs (implementation work, not contract)

These are internal, and the contract lets a minor change them:

- **Staleness.** `Translations.coverage/3` flags a variant as *Outdated* when
  `source.updated_at > variant.updated_at`. A shared-field copy bumps the
  sibling's `updated_at` after the source's, which would wrongly clear the
  flag. The copy has to leave a marker that the heuristic ignores, or the
  heuristic has to move to "last translator edit".
- **Re-fire fan-out.** A `:fallback` variant depends on its siblings, so a
  source publish re-fires each sibling that inherits, and a saved fallback
  chain (`/editor/locales`) has to re-fire every artifact with an inherited
  value. Today a chain save only busts caches by prefix. `RefireWorker`
  already dedups per `{org, type, id}`.
- **Structure stays per locale.** The block list and its order remain
  localized, and a mode applies to a block's *fields*. Sharing whole blocks,
  or the tree's shape, is a different feature, and Design A does not need it.
- **Optimistic locking.** A copy bumps the sibling's `lock_version`, so a
  client writing from an older version is refused. That is correct: the
  document changed.

## Design B: one row per document with per-field locale maps (rejected)

This is the Contentful/Strapi shape: one record per document, where a
localized field stores `%{"en" => …, "fr" => …}`, either inline or in a
sparse `(document_id, locale, field path)` overlay table. It has the same
identity problems either way.

| Covered surface | Design B |
|---|---|
| Resource identity `[slug, locale]` / public `locale` attribute | **Would change.** Variants collapse into one row, and `locale` stops meaning "the language of this record". Merging the existing variant rows deletes `id`s that clients, webhooks, `ContentLink` edges and `:reference` snapshots already hold. |
| Workflow actions (`:publish`, `:unpublish`, …) | **Would change meaning.** State is per row, so publishing French alone needs per-locale state, which means `:publish` either publishes every locale or gains a required `locale` argument. |
| JSON:API / GraphQL `public?` attributes | **Would change** (`title: String` becomes a map), unless every read projects one locale. Then `id` names several documents, which breaks `*Translations`: it would return the same `id` once per locale. |
| Sync delta API | **Would change.** A tombstone is `{type, id}` with no locale, so "French was unpublished, English is still live" cannot be expressed without a new tombstone shape. |
| `KilnCMS.Migrations` search-vector helpers | **Would change.** One row stemmed under one config cannot hold several languages. It needs a per-locale vector and a new migration on every overlay table. |
| `Kiln.Block` Kiln-to-Ash mapping, `Kiln.Block.Renderer` | **Would change** for any localized field (`:string` stored as `:map`), unless the engine projects before render. Every overlay renderer that reads the field would otherwise break. |
| `PublishedArtifact` identity | Internal, but it gains a locale dimension, and every delivery cache key changes with it. |

Design B could only be the 2.0 story. It is not needed, because Design A
delivers the feature on the model Kiln already has.

## Guardrails until the feature lands

None of these changes a covered surface, so none needs a pre-freeze
decision. Each one keeps Design A additive, and a change that breaks one
should say so in review.

1. **Keep block `_id`s shared across locale variants.** `ContentCopy`'s
   `keep_ids?: true` on the translation path is what lets a shared field find
   its counterpart. XLIFF depends on it too.
2. **Do not give `translatable:` a second meaning**, and do not make a
   `public?` value locale-shaped (`title`, `custom_fields` values). Either
   change would push the feature towards Design B.
3. **`use KilnCMS.CMS.Content` ignores unknown options.** It reads
   the keys it knows with `Keyword.get/3` and never validates the rest, so an
   overlay passing a misspelled or speculative key compiles today. The
   contract already treats a new option as an addition, so Design A's
   `localization:` option is allowed. But a key an overlay already passes
   would silently start to mean something when a later minor names it. Making
   unknown options a compile error closes this for **every** future option,
   not just this one. That is worth its own issue. It would be a breaking
   change for anyone already passing a junk key, so it is cheaper before the
   freeze than after, but it is not a precondition for this feature.

## How 1.1 built it

Design A, with no covered surface changed. Each part of the note maps to code:

| The note says | 1.1 |
|---|---|
| A new `field` option, not `translatable:` | `localized: :localized \| :shared \| :fallback` on `Kiln.Block`'s `field`; `Kiln.Block.Info.localization/1`. `translatable:` keeps its meaning. |
| A `localization` attribute on `FieldDefinition` | `FieldDefinition.localization` (`:localized` default), one expand-only core column; not `public?`, so the JSON:API and GraphQL field schemas are unchanged. Set on the Fields screen. |
| A `KilnCMS.CMS.Content` option | `localization: [shared: [...], fallback: [...]]`, validated at build time, read back through a new `__kiln_localization__/0`. Core types opt in through `config :kiln_cms, :i18n, field_localization:`. |
| Shared values copied when the source publishes, through a new internal write action | `:sync_shared_fields` (internal, unrouted, versioned, `optimistic_lock`), run by `KilnCMS.I18n.SharedFieldsWorker` as the `:localization` system actor after `:publish`, `:publish_scheduled`, `:publish_changes`, `:update` on a live row and `:restore_version`. Addressed by shared block `_id`; both trees are upcast by the union's `cast_stored`. |
| A sibling's open working copy gets the value too | `working_blocks` / `working_fields` are patched and each matching `working_base` fingerprint moves with the live value (`KilnCMS.I18n.SharedFields`). |
| `:fallback` filled at fire time, before render | `KilnCMS.I18n.FieldFallback.fill/2` in `Firing.Engine.fire/2`; the `:json` body gains `inherited_fields` only when something was inherited. The public page, which renders the record live, fills the same way. |
| Staleness must not be cleared by a copy | `Translations.edited_at/2` judges a variant by its newest version not written by `:sync_shared_fields`. |
| Re-fire fan-out | A publish re-fires the published siblings; a chain save queues `KilnCMS.I18n.RefireInheritingWorker`. |
| An additive `x-kiln-localization` annotation | On block fields and custom fields in `KilnCMS.SchemaExport`; types that can inherit declare the optional `inherited_fields` key. |

Beyond the note: JSON:API and GraphQL get the inherited values through a
public `inherited_fields` calculation that neither serves unless asked for,
and XLIFF leaves shared fields out.

