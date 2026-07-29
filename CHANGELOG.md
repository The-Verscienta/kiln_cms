# Changelog

Notable changes to the KilnCMS core, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), interpreted for a
CMS core that downstream projects overlay:

- **major** — the overlay contract breaks. A `projects/<name>/` subproject that
  compiled against the previous version needs code changes: a renamed or
  removed `KilnCMS.CMS.Content` extension point, a changed `Kiln.Plugin`
  callback, a block schema version that isn't upcast automatically.
- **minor** — new capability, overlays keep compiling. May add migrations.
- **patch** — fixes only.

## How downstream projects read this file

Each release carries an **Upgrading** section whenever moving to it needs more
than a rebuild. That section is the contract `mix kiln.update` surfaces before
it moves your submodule pin — if a release has no Upgrading section, the update
is "bump the pin, rebuild, redeploy" and nothing else.

Write upgrade notes as imperative steps against a *deployed* instance, and call
out anything that is not reversible by rolling the pin back (a destructive
migration, a rewritten column, a dropped config key).

<!-- Releases are cut from `main`; see docs/releasing.md. -->

## [Unreleased]

### Added

- `Kiln.Version` — a running instance can now report its release version, and
  the git SHA and build date baked in by the Dockerfile (`--build-arg GIT_SHA`
  / `BUILD_DATE`). Images built without those args still boot and simply report
  no build stamp.
- `mix kiln.update` — moves a downstream project's pinned `kiln/upstream`
  submodule to a tagged upstream release, reporting the changelog and any new
  migrations first. `--check` reports without changing anything.
- An admin-only update notice showing the running version against the latest
  upstream release, plus the command to apply it.
- Media stored on S3/MinIO is now uploaded with `Cache-Control: public,
  max-age=31536000, immutable`, so a CDN in front of the bucket can cache
  originals and variants indefinitely. Safe because storage keys are write-once
  UUIDs. Local-adapter media already sent this header. Existing objects keep
  whatever metadata they were uploaded with — re-upload or set it bucket-side
  if you want them covered. New CDN deployment guide in `docs/media-pipeline.md`.
- Media stored on S3/MinIO is now uploaded with `Content-Disposition:
  attachment`, closing half the gap against Local-adapter media, which has
  always carried it. Rendering is unaffected — disposition is ignored for
  `<img>` and other subresource loads. As above, existing objects keep the
  metadata they were uploaded with. The companion `X-Content-Type-Options:
  nosniff` **cannot** be set as S3 object metadata and remains an operator
  task; `docs/media-pipeline.md` now documents it per CDN.

### Fixed

- The media library's responsive-variant list previews each variant inline
  instead of linking to it. The old per-variant "open" link announced itself as
  opening in a new tab, but media carries `Content-Disposition: attachment` on
  both storage adapters, so it downloaded a UUID-named file — misleading for
  sighted and screen-reader users alike. The copyable media URL now says so too.

## [0.1.0]

First tagged release. Everything before this point shipped untagged on `main`;
downstream projects pinned arbitrary SHAs, and there was no way for a deployed
instance to say which Kiln it was running.

This release adds no features of its own — it establishes the version baseline
that `mix kiln.update` compares against.

### Upgrading

If your project pins a SHA from before this tag, your first update is the only
one that can't be described by a changelog diff. Before moving the pin:

1. Check `git log --oneline <your-pinned-sha>..v0.1.0` in `kiln/upstream` to
   see what you're taking on.
2. Diff the migrations you haven't run:
   `git diff --stat <your-pinned-sha>..v0.1.0 -- priv/repo/migrations`.
3. Take a database backup (`scripts/backup.sh`) — pre-baseline pins predate the
   upgrade-notes contract, so nothing guarantees those migrations are reversible.

After this release, `mix kiln.update --check` does all of the above for you.

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.1.0
