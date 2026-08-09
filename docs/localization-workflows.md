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
this exporter cannot round-trip safely (raw HTML, an opaque legacy payload)
and makes the export **report** it rather than drop it silently. Rich text is
segmented per Portable Text block, with tables segmented per cell.

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
