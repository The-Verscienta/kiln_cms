# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Security

<a id="two-hex-advisories-closed-and-the-working-copy-survives-the-ash-fix"></a>

- **Two Hex advisories closed, and the working copy survives the `ash` fix.**
  `ash` 3.33.6 carried **EEF-CVE-2026-93477** (MEDIUM — private action arguments
  could be set by user input on the bulk destroy and bulk update paths) and
  `lazy_html` 0.1.12 carried **EEF-CVE-2026-92106** (LOW — SVG and MathML
  `style` and `script` text serialized unescaped, allowing mutation XSS). Both
  are closed by `ash` 3.33.11 and `lazy_html` 0.1.13. `mix deps.audit` reported
  neither — the mirego mirror was behind, as it was on 2026-09-18 — and
  `mix hex.audit` is what caught them, which is why both audits run in CI.
  The `ash` release also ships *"properly compare unions w/ `Ash.Type.equal?`"*,
  and that broke the working copy on the way in. `ContentEditorLive` seeds the
  autosave form on a struct whose `working_blocks` already hold the tree the
  copy is measured against, so the block sub-forms bind to existing blocks by
  index rather than creating new ones. A title-only save therefore submits that
  same tree, and once Ash compared two equal union trees correctly the write
  became a no-op: the copy was stamped with an empty body, and "Publish changes"
  would then have published nothing. It looked correct in memory, because the
  record Ash hands back reflects the seeded struct rather than the row. The
  seeded tree is now for sub-form binding only — the changeset diffs
  `working_blocks` against what the row actually holds, so an unchanged body on
  a document with no working copy yet is a real change again. Where the row
  already holds that tree the write is still elided, which is correct: the
  column already says what the save means to say. Worth recording that
  `force_change_attribute/3` is **not** a way out of this — it bypasses the
  acceptance checks, not the equal-to-data elision.

