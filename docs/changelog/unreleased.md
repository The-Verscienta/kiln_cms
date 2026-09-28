# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="before-upgrading-to-10-run-the-block-backfill"></a>

- **Before upgrading to 1.0, run `mix kiln.blocks.backfill` on 0.12, and move any
  code that writes legacy `type`/`content`/`data` blocks to the typed shape.**
  1.0 still *reads* a block stored in the pre-typed shape, so nothing breaks
  on delivery if you skip the backfill — but every read keeps converting it,
  and the backfill's report is where you learn which rows it could not convert
  (`bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'` in a release). Any
  overlay, plugin, seed or importer that *writes* `%{type: :heading, content:
  …, data: …}` now gets a cast error: write `%{"_type" => "heading", "text" =>
  …}` instead. 0.12's compile warnings on `to_legacy/1` and `from_legacy/1`
  point at the calls that become compile errors.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Breaking

<a id="remove-the-legacy-block-bridge-functions"></a>

- **Remove `TypedBlocks.to_legacy/1`, `TypedBlocks.from_legacy/1` and
  `KilnCMS.CMS.Block`; use `to_typed/1` and render from typed blocks.** 0.12
  deprecated all three (#1537). `KilnCMS.CMS.TypedBlocks.to_typed/1` accepts
  everything `from_legacy/1` did; delivery, the previews and the in-context
  editor already render from typed blocks
  (`KilnCMSWeb.BlockComponents.view_blocks/1`). The legacy mapping survives
  privately in `TypedBlocks`, for reading stored rows and for the backfill's
  loss check (`legacy_loss/1`).
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="refuse-the-legacy-block-write-shape"></a>

- **Refuse a block written in the legacy `type`/`content`/`data` shape; stored
  rows in that shape are still read.** `KilnCMS.CMS.BlockUnion`'s input cast
  raises `KilnCMS.CMS.TypedBlocks.LegacyInputError` for such a block and returns
  it as an ordinary cast error naming the block and the typed shape to use —
  on every write path: the actions, JSON:API, GraphQL, seeds. Reading stays
  tolerant: a row the backfill refused and every version in (hash-chained,
  never rewritten) history keep being converted on read. Restoring a version
  from before the storage flip converts its block tree through that same read
  conversion before writing it back.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Changed

<a id="keep-legacy-html-as-a-read-only-fallback"></a>

- **Keep `RichText.legacy_html` as a read-only fallback instead of removing it;
  the nested column editor now stores Portable Text.** 0.12 marked the field
  for removal at 1.0. It is the only faithful copy of prose Portable Text
  cannot hold — marks inside a code block, a list inside a quote — which is
  exactly what `mix kiln.blocks.backfill` keeps and reports, so removing it
  would have deleted that prose from the rows the backfill protected. It still
  renders, sanitized, when `body` is empty, and the exported block schema now
  marks it `readOnly` as well as `deprecated`. What changes is who writes it:
  the nested column editor edited every rich-text child as raw HTML stored in
  `legacy_html`; it now stores `body`, keeping HTML only where the conversion
  would not be faithful — the rule the inline editor and the backfill already
  follow. A later major can remove the field once a converter holds what it
  keeps.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Fixed

<a id="unreadable-stored-blocks-no-longer-fail-delivery"></a>

- **A stored block of a type the build no longer has, or one that is not a
  block, no longer fails its page's delivery.** Both are rows the backfill
  refuses (`:unknown_type`, typically a block from a removed plugin, and
  `:unrecognized`), so they stay at rest — and until now every read of such a
  row raised, taking the page down with it. They now read as a `custom` block
  carrying the stored payload whole, which renders as a marker comment; the
  row is not rewritten. Every row the backfill corpus says it must refuse is
  now delivered in a test.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))
