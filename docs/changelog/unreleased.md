# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="a-block-whose-migrate-steps-skip-a-version-now-warns-at-compile-time"></a>

- **A block whose `migrate` steps skip a version now warns at compile time;
  from Kiln 2.0 it is an error.** ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642))
  `Kiln.Block.MigrationChain`, a Spark verifier on the `Kiln.Block` DSL,
  checks that the `migrate` steps carry every version from 1 to the block's
  declared `version` — and names a step that runs backwards, one that
  overshoots the declared version, and two steps starting at the same version.
  Nothing in the DSL required this before, so it is a warning rather than an
  error: a block module that compiled on 0.11 still compiles. Under
  `mix compile --warnings-as-errors` it does fail the build, which is
  intended — every core block's chain is clean, and an overlay block with a
  gap has stored data that can never reach the shape its renderer reads.
  Declare the missing step. The warning becomes a compile error in Kiln 2.0.

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

<a id="the-block-upcaster-refuses-a-gap-in-the-migrate-chain"></a>

- **The block upcaster refuses a gap in the `migrate` chain instead of
  stamping the block current.** ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642))
  `KilnCMS.Blocks.Upcaster` walked every version from a stored block's
  `_version` to head and, where no `migrate` step existed, bumped `_version`
  anyway. The data was never transformed but was marked current, so no later
  run — lazy or the #1537 backfill — would ever migrate it. The upcaster now
  follows the declared steps and refuses when one is missing: the block comes
  back exactly as stored, `_version` included, with nothing half-applied.
  The new `try_upcast/2` and `try_upcast_block_map/1` return
  `{:error, %{kind: :missing_migration, detail: ...}}` for callers that
  report (the backfill's refusal report is the intended consumer);
  `upcast/2` and `upcast_block_map/1` keep their map-returning contract for
  read and delivery paths, which render the stored shape and log a warning
  rather than crash.
