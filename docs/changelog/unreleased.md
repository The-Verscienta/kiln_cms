# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.


## Fixed

<a id="erasure-overlay-content"></a>

- **Rejecting a registration with erasure now keeps an account that authored content of a project overlay's own types (or their versions).**
  `Registrations.Erasure.blocking/0` named `entries`, `pages` and `posts`
  (and their `_versions`) by hand, so on an install whose overlay adds
  content types, an applicant who had authored one of those records, or
  appeared as the user on one of its versions, was not kept by that check.
  Every content type gets `author_id`, and its versions `user_id`, from
  `KilnCMS.CMS.Content`, so the two columns are now read off
  `ContentTypes.blocks_resources/0` for every compiled type and the `Entry`
  tier. The rest of the list stays written out and pinned to the database by
  `RegistrationErasureTest`, which also checks the derived part now.

<a id="overlay-safe-suite"></a>

- **The core suite passes under a project overlay.**
  Found by bumping Verscienta's overlay (17 content types, its own plugin) to
  1.9.1. Eight tests assumed the core registry:
  `ReportingRole.leaks/2` walked a map of views, which stops iterating in key
  order past 32 keys; the field-sync assertion read `inspect/1` output that
  a larger document truncates; the team-picker test expected `Page` at index
  0; and the content export's query bound allowed 12 per page, though label
  lookups read each content resource once per page. Each now holds under an
  overlay with the same bound in core. The schema goldens (`DriftTest` and
  the golden formats in `kiln.export.schema`'s test) describe every compiled
  block, so they cannot match an overlay's: they carry a new `:core_registry`
  tag, excluded with a note only when a non-fixture plugin or content domain
  is compiled in.
