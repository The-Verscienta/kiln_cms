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
storage shape with fresh stable block ids), excerpt, SEO fields, audience,
custom fields, category, and tags. Workflow state, schedules, and published
artifacts start fresh; `canonical_url` is locale-specific and intentionally
not carried over. Creating a variant that already exists fails on the
`[slug, locale]` identity.
