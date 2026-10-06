# Localization workflows

KilnCMS models multilingual content **one record per locale**: variants share
a slug (`unique [slug, locale]`), each with its own blocks, SEO fields,
custom fields, and workflow state. Configure locales in
`config :kiln_cms, :i18n` (`default_locale` + `locales`); non-default locales
are served under a `/<locale>/…` URL prefix, delivery emits hreflang
alternates from the `published_translations` read, and search stems each
locale with its own text-search config.

On top of that model, the **workflow layer** (`KilnCMS.CMS.Translations`)
answers the editorial questions it raises. Everything below works identically
for compiled content types and admin-defined dynamic types (D17).

## Fallback chains — what a missing translation serves

Because a translation is a separate record, a locale nobody has translated yet
is a *missing document*. Each site decides what readers get instead, at
**`/editor/locales`** (admins): per locale, one of

- **the default locale** — no chain configured; what the built-in site has
  always done;
- **these locales, in order** — e.g. `fr-CA → fr → en`, tried as written, with
  no silent last hop to the default;
- **never** — a missing translation is a 404.

The operator default sits underneath, for sites that have not saved their own:

```elixir
config :kiln_cms, :i18n,
  default_locale: "en",
  locales: ["en", "fr", "fr-CA"],
  fallbacks: %{"fr-CA" => ["fr", "en"]}
```

The same chain applies on the built-in site (`/fr-CA/about` served in French
says `lang="fr"` and `Content-Language: fr`), the artifact API, `/api/resolve`,
JSON:API `by-slug`, GraphQL `*BySlug`, and — for configured chains only —
navigation menus. Headless callers can narrow it per request
(`?fallback=false`, `?fallback_locale=`) and always get told which locale was
served; the API side is documented in [api.md → Locale fallback](api.md#locale-fallback).

A variant a reader may not open (audience-gated, passphrase-locked) is skipped
along the chain like a missing one. The chain is resolved per *locale*, not
per document, so field-level localization (below) resolves each `:fallback`
field along the same chain.

## Field-level localization — shared and inherited fields

Every variant is a whole document, which is right for pages that differ
between languages and wasteful for the fields that do not: one product
photo, one price, one category, copied by hand into every translation until
the copies drift. Since 1.1 (#1327) a field can say how it relates to the
other locales:

| Mode | What it means |
|---|---|
| `:localized` (the default) | Each variant holds its own value, as every field always has. |
| `:shared` | One value for the document. The default-locale variant owns it; when that variant publishes, the value is copied into every other variant. On a translation the field is read-only in the editor. |
| `:fallback` | A variant may leave it empty. Readers then get the value from the first variant along the site's fallback chain that has one. The editor shows that value as the field's placeholder. |

Nothing is shared or inherited until a site opts a field in, so a site that
does not see no change. Where each kind of field opts in:

- **Custom fields** — *Across locales* on the Fields screen (`/editor/fields`),
  stored as `FieldDefinition.localization`.
- **Block fields** — a block module declares it on the field, independently of
  `translatable:` (which says whether a translator sees the text):

  ```elixir
  block :product_card do
    field :name, :string
    field :image_url, :string, translatable: false, localized: :shared
    field :caption, :string, localized: :fallback
  end
  ```

- **Record attributes** of an overlay content type — the `localization:`
  option:

  ```elixir
  use KilnCMS.CMS.Content,
    type: :product,
    excerpt?: true,
    localization: [shared: [:featured_image_id, :category_id], fallback: [:excerpt]]
  ```

  `shared:` may name `excerpt`, `seo_title`, `seo_description`,
  `seo_keywords`, `seo_image`, `category_id` and `featured_image_id`;
  `fallback:` the text fields and `seo_image`. The title, slug, locale and
  canonical URL are always per locale.
- **Record attributes of the core types** — a site cannot edit `page` or
  `post`'s `use` line, so the operator config takes the same list per type:

  ```elixir
  config :kiln_cms, :i18n,
    field_localization: [page: [shared: [:seo_image], fallback: [:seo_description]]]
  ```

### What happens, and when

- **Shared values are copied when the default-locale variant publishes** —
  *Publish*, a scheduled publish, *Publish changes*, or a live edit through the
  API. Its pending working copy is not shared: the copy is held until
  *Publish changes*, like everything else in it
  ([working copy](working-copy.md)). A translation that publishes later takes
  the source's current values then. A source that is not published shares
  nothing.
- The copy is an ordinary versioned write on each translation
  (`:sync_shared_fields`), so its history shows it, `/api/sync` reports it,
  a published translation is re-fired and sends its `updated` webhook. Block
  fields are matched by the block id a translation shares with its source;
  a block the translation deleted is skipped.
- A translation with a **pending working copy** gets the value in the copy
  too, so its next *Publish changes* does not put the old value back, and the
  lost-update guard does not count the copy as a conflict.
- **Inherited values are filled where a variant is turned into something a
  reader sees**: the fired artifacts (whose `:json` body names what was filled
  under `inherited_fields`), the public page, and the search text. The row
  itself keeps what the translator saved. JSON:API and GraphQL serve the
  inherited values through the `inherited_fields` / `inheritedFields` field,
  only when a client asks for it. Only a published, unlocked variant that is
  at least as public as the one being filled is inherited from.
- A publish re-fires the published translations that might inherit from it,
  and saving the chain at `/editor/locales` re-fires every published
  translation of a type that declares a `:fallback` field.
- **Coverage** ignores the copy: a shared value landing on a translation is
  not someone translating it, so an outdated translation stays *Outdated*.
- **XLIFF** leaves shared fields out of the file, both ways.

### Limits

- Blocks nested inside a `columns` block are not walked; only top-level block
  fields are shared or inherited.
- Tags and curated related content are not shareable.
- On a translation, a write that changes a shared field — a JSON:API
  `PATCH`, a GraphQL mutation, `:autosave`, the working copy — is refused
  with a validation error naming the field and the source locale (#1860).
  Only a value the source's next publish would overwrite is refused: one that
  differs from both the translation's current value and the source's.
  Re-sending the stored value passes, as does setting the source's, so a
  translation that kept its own value from before the field became shared
  stays editable. With no source variant, nothing is refused.
- A **create** is not checked: a new translation (an API `POST`, an import)
  may carry its own value for a shared field, and the next shared-value copy
  replaces it. *Translate* copies the source's values, so it never differs.

The design — and why one record per locale stays — is in
[field-level localization](field-level-localization.md).

## Coverage & staleness

`Translations.coverage(kind, record, actor: user)` reports, per configured
locale: the variant (or `:missing`), its workflow state, and whether it is
**outdated** — a non-default-locale variant whose default-locale source was
updated after the translation's last edit. This is the standard lightweight
heuristic (any edit of the translation clears it); it deliberately does not
try to diff field-level changes.

Two UIs surface it:

- **`/editor/translations`** — the coverage dashboard: content grouped by
  `(type, slug)`, one chip per locale (published / draft / in review /
  missing, with an *Outdated* marker). Chips link to each variant's editor; a
  missing chip creates the draft translation in place. The nav link only
  appears when more than one locale is configured.
- **The content editor's Translations panel** — the same per-locale view for
  the record being edited, with edit links and create buttons.

## One-click translations

`Translations.create_translation!(kind, record, "fr", actor: user)` (the
"Create translation" buttons) duplicates the source's content into a new
**draft** in the target locale: title, slug, blocks (copied through their
storage shape, **keeping the source's stable block ids**), excerpt, SEO
fields, audience, custom fields, category, and tags. Workflow state,
schedules, and published artifacts start fresh; `canonical_url` is
locale-specific and intentionally not carried over. Creating a variant that
already exists fails on the `[slug, locale]` identity.

Block ids are shared across locale variants on purpose: a variant is the
*same document in another language*, every consumer of a block id is already
scoped to one record, and shared identity is what lets an XLIFF trans-unit
address a paragraph across the pair (see below).

The payload mechanics live in `KilnCMS.CMS.ContentCopy`, shared with the
**Duplicate** action (`KilnCMS.CMS.Duplication`, #471) — the same clone the
other way round: a duplicate keeps the locale and regenerates the slug, where
a translation keeps the slug and changes the locale. A duplicate *is* a
different document, so it still mints fresh block ids.

## Translation vendors — XLIFF 2.0 export/import

Everything above is in-house translation. To send content to Smartling,
Lokalise, Crowdin, Phrase, or a freelancer with a CAT tool, the coverage
dashboard also speaks **XLIFF 2.0** (`KilnCMS.CMS.Xliff`, #502) — the
interchange format all of them read. A direct vendor-API connector is then a
thin plugin on top of this seam rather than a second content pipeline.

On `/editor/translations`: pick a target locale, tick the rows to send, and
**Export** downloads one XLIFF document with a `<file>` per record. Upload the
returned file with **Import XLIFF** and it is applied to the target-locale
draft — created through the same one-click path if it does not exist yet.

    {:ok, %{xliff: xml}} = Xliff.export("post", post, "fr", actor: user, tenant: org)
    {:ok, [report]}      = Xliff.import(xml, actor: user, tenant: org)

### What becomes a trans-unit

Title, excerpt and the SEO fields, plus every block field a block declares as
prose. Translatability is a property of the **field**, declared in the block
DSL, so a plugin block (D18) gets the same round trip as a core one:

```elixir
block :callout do
  field :heading, :string                                  # prose by default
  field :body, :rich_text                                  # prose by default
  field :media_id, :string, translatable: false            # an identifier
  field :items, {:array, :map}, translatable: [:label]     # named map keys
  field :legacy_html, :string, translatable: :unsupported  # reported, not sent
end
```

`:string` and `:rich_text` are prose unless a field says otherwise;
`{:array, :map}` fields opt in by naming their keys; `:unsupported` marks text
this exporter cannot round-trip safely (an opaque legacy payload) and makes
the export **report** it rather than drop it silently. Rich text is segmented
per Portable Text block, with tables segmented per cell.

A `rich_text` block whose prose still lives in the transitional `legacy_html`
(stored TipTap HTML, pre-Portable-Text content) **is** exported (#1106): the
HTML is converted through `KilnCMS.Blocks.PortableText.from_html/1` and cut
into the same `….body.k:b0` units the editor's own body would give, inline
markup becoming the same `<pc>` codes — never raw tags a vendor could break.
On import the translation lands in `body` as Portable Text (and the target's
stale HTML is cleared, as any save does once `body` is authoritative): the
source keeps its HTML, the translation is born migrated, and only the blocks
the file actually addressed are touched. What is still reported rather than
sent is a `custom` block's `content`/`data` — an untyped map has no
defensible extraction rule, so the operator sees the block and field named
in `warnings` and translates it by hand.

### Unit ids

A unit id is a path built on identity, not position, so a file that comes back
after the source has been edited still lands:

    title                          a record field
    b:9f3c….text                   a block field, by the block's stable id
    b:9f3c….body.k:b2              one Portable Text block, by its _key
    b:9f3c….body.k:b2.r0c1         one table cell
    b:9f3c….items.i-0.question     one key of one map-array item
    b:9f3c….columns.i-0.b-0.text   a nested `columns` child

Every character is an XML `NameChar`, because XLIFF 2.0 types `unit/@id` as
`xsd:NMTOKEN` — a tool that validates on ingest rejects the whole document, not
the offending unit, so `/` and `#` are not available as separators.

Three segments are positional rather than identity-based: map-array items
(`i-0`), table cells (`r0c1`), and nested `columns` children (`b-0`, because
they are raw maps and only the content editor stamps them an id — #865/#954).
A unit whose path contains one is reported under `by_position` even when it
matched exactly, because the match was only as good as the ordering having
held. Their *parents* are still addressed by identity, so reordering top-level
blocks is safe either way.

Formatting travels as XLIFF inline codes (`<pc>`) carrying the Portable Text
mark name. A link's href goes into `<originalData>` as context only: the
importer restores links from the `markDefs` the record already holds, so a
returned file can reword an anchor but **cannot retarget a link**.

### What an import tells you

Every unit id in the file lands in exactly one of `applied`, `unchanged` or
`unknown`, and the dashboard renders all of them. `untranslated` counts the
units the vendor left empty — an empty `<target>` never clears a field,
because a partial delivery is normal while a job is in progress.
`by_position` flags units whose match depended on ordering rather than
identity — a positional path segment, or the whole-record fallback used for a
translation created before block ids were shared across locales. Those are
worth a look, because position is right only while the two trees are shaped the
same.

That fallback is **all or nothing per record**: it applies only when not one
unit id in the file matches a block in the target. Mixing the two per unit is
what puts a paragraph in the wrong place — a block the target no longer holds
frees its index for its neighbour, whose slot then matches an address belonging
to something else.

Formatting is protected but not free: a returned file can move an inline code
around a sentence, and a code it drops takes its mark with it. Marks the file
invents are filtered out rather than stored dangling.

Applying a file moves the target's `updated_at`, so the document stops
reporting as *Outdated*. Staleness is document-level here by design — Kiln
does not track it per unit, and an import cannot invent that.
