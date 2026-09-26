# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="run-mix-kilnblocksbackfill-once-after-deploying"></a>

- **Run `mix kiln.blocks.backfill` once after deploying. It is safe on the live
  site, and it rewrites stored blocks — rolling the pin back does not undo
  it.** In a release image: `bin/kiln_cms eval
  'KilnCMS.Release.backfill_blocks()'`. It rewrites every block tree still stored in a pre-typed shape — rows nobody has
  saved since the typed-block storage flip, on every content type and in
  working copies — to the typed shape at rest, and converts rich text still
  held only in `legacy_html` to Portable Text where that is faithful. **It can
  run after deploy, against the live site**: each row is a compare-and-swap
  that skips a row an editor saves meanwhile, and it touches no `updated_at`,
  version history or cache. It is idempotent and resumable (run it again to
  finish an interrupted pass), and `--dry-run` shows what it would do. **It
  rewrites data, and rolling the pin back does not undo it**: older releases
  read the typed shape fine, but the legacy maps are gone, so take the backup
  you would before any data migration. A row it cannot convert without losing
  something is listed by table, id and block path and left untouched, and the
  task exits non-zero; so does a rich-text block it had to leave in
  `legacy_html`. Those rows keep reading exactly as they do today — fix them
  in the editor before 1.0, which drops the legacy read path. Then run
  `mix kiln.refire_all`: a converted rich-text block's fired `:json` artifact
  carries its prose in `body` and no longer in `legacy_html`.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

## Added

<a id="mix-kilnblocksbackfill-rewrites-legacy-shaped-stored-blocks-to-the-typed-shape"></a>

- **`mix kiln.blocks.backfill` rewrites legacy-shaped stored blocks to the
  typed shape.** `KilnCMS.CMS.BlockBackfill` finds every table with a
  `{:array, BlockUnion}` column from the attribute type — pages, posts, dynamic
  entries and every overlay type, `blocks` and `working_blocks` — and walks it
  in keyset batches. Per stored element it recognises the pre-flip
  `KilnCMS.CMS.Block` map, a bare `_type` map outside the union envelope, a
  block behind its head `_version` (the declared `migrate` chain runs, the
  same one the lazy read uses), legacy children inside a `columns` block, and
  rich text held only in `legacy_html`. It refuses — reports, does not write —
  a row that would lose data on conversion (a legacy `data` key, `content` or
  `children` the typed block has nowhere to keep, decided by running the
  legacy mapping both ways rather than by a second table of keys), a block
  type this build does not have, or a value that fails the union's stored
  cast. `legacy_html` is converted only when a reader could not tell: same
  words with the same breaks, and the same text under every mark, link,
  heading, list item, quote, code block and table cell; otherwise the block
  keeps it and is reported. It writes through Ecto, not an Ash action, for the
  reason `KilnCMS.Keys.Reencrypt` does, and because Ash elides a write whose
  new value compares equal to the loaded one — and a legacy row loads as the
  typed tree it would be rewritten to. Version history is not rewritten: its
  rows are folded into the governance hash chain. The conversion was run over
  a corpus of every stored shape (`test/support/legacy_block_corpus.ex`),
  checking each rewritten tree renders on `:web` and `:json` as the stored one
  did; the fixes it found are under Fixed.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

## Fixed

<a id="a-hard-line-break-in-a-paragraph-heading-quote-or-list-item-is-delivered-as-br"></a>

- **A hard line break in a paragraph, heading, quote or list item is
  delivered as `<br/>`.** `KilnCMS.Blocks.PortableText.to_html/1` rendered the
  editor's hardBreak as a bare newline everywhere but table cells, and a
  browser collapses a newline to a space — so Shift+Enter in the editor showed
  as one run-on line on the site and in every fired `:web` artifact. Found by
  the #1537 backfill corpus: it was the one thing a `<br>` in stored
  `legacy_html` could not survive conversion with.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

<a id="paragraphs-inside-a-quote-or-a-list-item-no-longer-run-together-when-saved-as"></a>

- **Paragraphs inside a quote or a list item no longer run together when saved
  as Portable Text.** A Portable Text block is one run of spans, and the
  TipTap conversion concatenated a blockquote's or list item's paragraphs with
  nothing between them — "one" and "two" became "onetwo". They are joined with
  a line break now, as table cells already were; a list or heading inside a
  quote keeps its text too, a line each, instead of being dropped. Found by
  the #1537 backfill corpus.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

<a id="a-legacy-columns-block-reads-as-a-typed-columns-block-and-an-unmapped-legacy"></a>

- **A legacy `columns` block reads as a typed `Columns` block, and an unmapped
  legacy block keeps the type name it was stored under.** The legacy→typed
  mapping had no `columns` clause, so a pre-flip columns block was an opaque
  `Custom` to search, references and the fired artifacts, and rendered as
  columns only because delivery converted it straight back. And a legacy type
  whose name was never an atom in the running build came back as
  `legacy_type: "custom"`, its real name gone from every typed read — and,
  once rewritten, from the row. Both found by the #1537 backfill corpus.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

<a id="a-429s-retry-after-is-rounded-up-never-0"></a>

- **A 429's `retry-after` is rounded up, never 0.** The per-IP rate limiter
  truncated the time left in its fixed window to whole seconds, so a client
  refused in the window's last second was told `retry-after: 0` and retried
  straight back into the closed window. The docs publisher honours the header:
  it spent all three retries within a few milliseconds and failed the v0.11.0
  docs sync a moment before the window reopened. The plug now rounds the same
  way `AccountThrottle.retry_after_seconds/1` already did for the second-factor
  budget — up, and never below one. `scripts/publish_docs.exs` also waits at
  least a second on any 429 and retries up to five times, since a full sync
  (~3 requests a guide) is larger than the `:api` bucket and keeps talking to
  sites that haven't picked this fix up.

