# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="every-surface-carries-one-label-covered-internal-or-experimental"></a>

- **Every surface carries one label: covered, internal or experimental.**
  The README's stability table and `docs/overlay-contract.md` now hold the
  same table, word for word, and `test/kiln_cms/docs/surface_labels_test.exs`
  fails when the copies differ, when a row of the contract's *Covered surfaces*
  table or an entry of its *Not covered* list is missing from the matching
  row, when an endpoint in the API guide's surfaces table has no label, or
  when one surface carries two. The README had been missing five of the
  contract's internal entries. Features that ship switched off — AI assist,
  the SEO generator, provenance, experiments, oEmbed, demo mode, compliance,
  referrer analytics, SSO, two-factor auth and the per-site integrations — are
  now labelled *supported when enabled* rather than lumped in with the
  experimental ones. Three promises move. **Newly covered:** the documented
  environment variables, and `mix kiln.update` (with its documented flags),
  `mix kiln.plugins.doctor` and `mix kiln.search.check`, the tasks the
  contract tells an overlay's CI to run. **Newly internal**, closing two of the
  contract's known soft spots: `to_markdown/1` on a block module, which is
  probed rather than declared on `Kiln.Block.Renderer` and has no test for an
  overlay's implementation, and a hand-rolled `@behaviour` when a callback is
  added — the `use` form is what the additions promise covers. Every other
  `mix kiln.*` task is labelled internal too; a release that needs you to run
  one names it in its upgrade notes. (#1542)

## Fixed

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
