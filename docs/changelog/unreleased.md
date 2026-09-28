# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="the-release-images-latest-tag-moves-only-to-the-highest-final-release-and-from"></a>

- **The release image's `latest` tag moves only to the highest final release,
  and from 1.0.0 a floating major tag (`1`) follows the highest final release
  of its major.** The previous minor now gets security fixes for 90 days
  from short-lived branches off its tag (`.github/SECURITY.md`), so a patch
  such as `1.0.3` can be pushed after `1.1.0`. Before this change the release
  workflow moved `latest` onto every final tag it built, and the backport
  would have rolled every `docker pull …:latest` back a minor. A step now
  compares the tag against every release tag upstream
  (`scripts/release/floating_tags.sh`, covered by
  `test/scripts/release_floating_tags_test.exs`). `latest` moves only when the
  tag is the highest final release, and `1` only when it is the highest final
  `1.x`. A patch on an older line is published under its exact version only.
  Release candidates still move neither, and before 1.0.0 there is no floating
  major, since every release so far would be `0`. There is no floating minor
  (`1.0`) either: the previous minor stops getting fixes after 90 days, so a
  tag floating on it would go quiet
  ([#1544](https://github.com/The-Verscienta/kiln_cms/issues/1544)).

