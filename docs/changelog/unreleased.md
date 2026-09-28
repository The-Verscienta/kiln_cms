# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="mix-kilnmigrationscheck-gates-expand-contract"></a>

- **`mix kiln.migrations.check` fails a PR whose new migration breaks the
  release still serving mid-deploy.** From 1.0 schema changes follow an
  expand → migrate → contract policy across releases, written out in
  [`docs/releasing.md`](../releasing.md#migrations-expand-migrate-contract):
  add nullable or defaulted, backfill outside the migration, and drop, rename
  or tighten only in a later release. The task reads each migration a PR adds
  (core and overlay directories, forward direction only) and flags dropped or
  renamed tables and columns, type changes (resolved from `from:` or the
  migration history), `NOT NULL` without a default or a backfill release,
  destructive raw SQL, non-concurrent indexes on large tables, and a
  concurrent index inside a transaction. A deliberate contract step carries a
  `# kiln:contract-ok since vX.Y.Z — <reason>` marker naming the shipped
  release that stopped reading the old shape. It runs in the `build` CI job on
  pull requests. The existing history is exempt; judged whole, it would have
  flagged 106 statements, among them
  `20260919191545_drop_webhook_plaintext_secret`. The same section of
  `docs/releasing.md` says what zero-downtime does and does not cover.
  Operators are unaffected.
  ([#1716](https://github.com/The-Verscienta/kiln_cms/issues/1716))
