# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="run-mix-kilnorgslugs-to-find-organizations-whose-slug-cant-be-a-hostname"></a>

- **Run `mix kiln.org_slugs` to find organizations whose slug can't be a hostname.**
  A slug stored before this release may hold uppercase letters, underscores or
  dots, and such an org has never been reachable at `<slug>.<base host>`. The
  task lists every one and exits non-zero while any is left; in a release, run
  `bin/kiln_cms eval 'KilnCMS.Release.org_slugs()'`. `--fix`
  (`KilnCMS.Release.org_slugs(fix: true)`) downcases each slug where that
  alone makes a valid label that no other org's slug downcases to, and logs
  each rename. Nothing that worked stops working, because the subdomain was
  unreachable before the fix. Every other row is listed for you to give a new
  slug, and to move its DNS with it. The application also warns at boot while
  any such slug is left
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710)).

## Fixed

<a id="an-organizations-slug-must-be-a-hostname-label-and-is-stored-lowercase"></a>

- **An organization's slug must be a hostname label, and is stored lowercase.**
  Tenant resolution downcases the request host and then matches the slug
  exactly, but the slug had no format rule, so an org created as `Acme` or
  `my_site` could never be reached at its subdomain. It could not be reached at
  its console host `<slug>.<console host>` either. Creating or changing a
  slug now trims and downcases it, then refuses anything that is not a DNS
  label: 1 to 63 of `a-z`, `0-9` and `-`, not starting or ending with `-`. It
  also refuses `www`, `console`, `api` and `mail`, and the first label of
  `KILN_CONSOLE_HOST` when that host sits directly under the base host. An
  existing slug is only checked when it is changed, so an org stored before
  this rule can still be renamed or suspended
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710)).
