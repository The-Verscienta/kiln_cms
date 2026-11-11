# 0013. Per-locale core block fields are a per-site config override

- **Status** — accepted; unreleased. The `block_fields:` config, the editor
  support for it and its tests are in
  [#2270](https://github.com/The-Verscienta/kiln_cms/issues/2270)'s change.
- **References** — [#2270](https://github.com/The-Verscienta/kiln_cms/issues/2270);
  follows up [#1861](https://github.com/The-Verscienta/kiln_cms/issues/1861)
  (field-level localization, optional item 3) and
  [#1896](https://github.com/The-Verscienta/kiln_cms/issues/1896) (shared-field
  writes are refused).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A block field can be per-locale: `field :x, :string, localized: :shared` or
`:fallback`. The machinery is complete for blocks at the top level and nested in
`columns` at any depth: `SharedFields` copies shared values on publish,
`FieldFallback` fills empty fallback fields, `SharedFieldsReadOnly` refuses edits
to a shared field on a translation, the block canvas renders those fields
read-only or with a placeholder, and XLIFF skips shared fields.

But no core block declares a `localized:` field. A site cannot edit a core block,
so it could not share one image across locales without writing a plugin block.
The e2e environment had no block to drive either, so the block-canvas half of the
feature had no browser coverage.

`:shared` is a stronger claim than "not translatable": the source's value
**overwrites** the translation's on publish, and the translation may not edit it.

## Decision

**A per-site config override, folded in one place.**

```elixir
config :kiln_cms, :i18n,
  block_fields: %{
    "image" => [shared: [:media_id, :url], fallback: [:alt, :caption]]
  }
```

The key is the block's type string. The value is the same `shared:` /
`fallback:` keyword list a record's `field_localization:` takes.
`KilnCMS.I18n.FieldLocalization.block_fields/1` folds the entry over the block's
own `localized:` declarations (a declaration the block makes wins; the config only
adds fields it leaves per-locale). It is the **single reader**: the publish
copy, the fallback fill, the read-only validation, the XLIFF export and the
editor all already go through `block_fields/1`, so they cannot disagree about a
field's mode. This was the one cost the issue named for the override, "one more
place a field's mode comes from", and the answer is that it is still only one
reader.

Core blocks keep declaring nothing.

## The three options

**(1) Per-site override** (chosen). Additive. A site that sets nothing sees
nothing change. A site that wants a shared hero image says so, in its own config,
for exactly the fields it has checked.

**(2) Declare `localized:` on the core blocks, with a per-site opt-out**
(rejected). It is the better default for a multilingual site, and that is the
whole of its appeal. But it changes behaviour on every existing site the moment
it upgrades. A translation that uses a locale-specific image, such as a
screenshot with French UI text, would be overwritten by the source's image on the
source's next publish, and #1896 would then refuse the translator's edit to put it
back. That is data loss on upgrade, which makes it a **Breaking** entry under 1.x,
and the opt-out would be a flag every affected site had to find *after* the damage.
A default can be flipped later in a major release once sites have the override and
have chosen; the reverse is not available.

**(3) An e2e-only fixture block** (rejected). It unblocks the browser coverage,
as `fixture_plugin` does in the unit tests, and leaves sites exactly where they
were: still nothing for a core block. It also would not test the path a site
really takes. With (1), the e2e spec turns the feature on for `image` through a
dev-only toggle (`/dev/e2e-block-fields`, in the same family as
`/dev/e2e-locales`) and exercises the real config path.

## Consequences

- **No config, no change.** Without a `block_fields:` key, `block_fields/1`
  costs one `Application.get_env/3` and every core block field stays per locale.
  No migration. Removing the key is safe: values already copied stay as ordinary
  translation values.
- **Invalid entries are ignored, not fatal.** `block_fields/1` runs on delivery
  paths and must not raise. An unknown or unconfigurable block type, a field the
  block does not have, a field named both shared and fallback, a key other than
  `shared:` / `fallback:`, or a value that is not a list of atoms drops that
  block's entry (the others still apply). A `block_fields:` that is not a map is
  ignored whole. Each is logged once per distinct config (the validation is
  memoized in `:persistent_term` on the config term), not once per request.
- **Some block types cannot be configured:** `gallery`, `fragment`, `rich_text`,
  `columns` and `file`. The editor cannot lock or placeholder a gallery's items,
  a fragment's reference, rich text, a column grid or a file attachment, so
  accepting an entry for them would claim a mode the UI could not show. Plugin
  blocks and the `image`, `video` and `audio` blocks can be configured.
- **Pair `media_id` with `url`.** The media picker writes both. Sharing only one
  lets the other drift, and a translation could show one image with another's
  media record. Likewise a `:fallback` `alt` beside an unshared `url` can describe
  the wrong image.
- **The editors honor it.** On a translation the `image`, `video` and `audio`
  editors lock a shared field under the *Shared: edited in the EN version* note
  with its library button disabled, and show a fallback field's inherited value as
  a placeholder. The server refuses a pick into a locked field as well, since a
  disabled button is not a boundary.
- **Limits that remain.** An image nested in `columns` exposes only `url` and
  `alt` in the editor, so a shared `media_id` or `caption` there is not shown as
  locked. The setting applies per block type to every document; there is no
  per-document switch.
- **Enabling `:shared` is the site's decision to make, and it overwrites.** The
  next publish of the source copies the shared values over each translation's own,
  and edits to them are refused afterwards. The docs say so where the option is
  introduced ([field-level-localization.md](../field-level-localization.md)).
- Whether core blocks should one day declare these modes by default is left open
  and would be a Breaking change in its own right.
