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

- Content updates take `add_tag_ids` and `remove_tag_ids` alongside the existing
  `tag_ids` (#521). `tag_ids` has always been the *complete* tag set, so a
  partial write over `PATCH /api/json/<type>/:id`, GraphQL `update<Type>`, or
  the MCP `update_*` tools detached every tag it omitted — the MCP case worst,
  since a model asked to "tag this as Elixir" sends only the id it knows. The
  two merge verbs union and subtract against the current links instead, and both
  are idempotent (re-adding an attached tag and removing an unattached one are
  no-ops). Sending `tag_ids` together with either verb, or the same id in both
  verbs, is rejected rather than resolved by declaration order. The replace
  semantics of `tag_ids` are unchanged, so nothing existing has to move; the
  other relationship arrays (`related_post_ids`, …) still replace.

- `mix docs` now builds a complete manual: the API reference for every module in
  `lib/`, the `mix kiln.*` task reference, and all 63 guides under `docs/`,
  grouped into a sidebar (Getting started, Authoring & editorial, APIs &
  headless, Operations & deployment, Security & access, and two archive groups
  for design records and point-in-time audits). The landing page is a new
  `docs/getting-started.md` onboarding path for contributors. Output goes to the
  gitignored `doc/`; run it under `MIX_ENV=dev`, which is the default. CI builds
  the docs with `--warnings-as-errors` in its own job, so a renamed guide, a
  dead cross-reference, or a moduledoc naming a function that no longer exists
  now fails a check instead of rotting quietly.
- Content analytics now keeps a **daily view bucket** alongside the all-time
  counter, so the analytics dashboard shows a 7-day / 30-day trend chart and a
  per-item view count for the selected range. The range lives in the URL
  (`/editor/analytics?range=7`), so it is shareable and survives the back
  button. The chart is server-rendered SVG with a visually-hidden data table, so
  screen readers get every value rather than a summary. Adds a migration
  (`content_view_days`). History starts at deploy — there is nothing to backfill
  from, since the previous counter stored no dates. Buckets are purged after
  `config :kiln_cms, :view_analytics, retention_days: 400`; the all-time counter
  is never purged, so the two deliberately do not sum to the same number.
- Recording a content view now emits a `[:kiln_cms, :analytics, :view]`
  `:telemetry` event (measurement `count`, metadata `type` and `content_id`),
  with a matching `kiln_cms.analytics.view.count` metric tagged by content type.
  External sinks can graph read traffic without polling the analytics tables.
  See `docs/observability.md`.
- `Kiln.Version` — a running instance can now report its release version, and
  the git SHA and build date baked in by the Dockerfile (`--build-arg GIT_SHA`
  / `BUILD_DATE`). Images built without those args still boot and simply report
  no build stamp.
- `mix kiln.update` — moves a downstream project's pinned Kiln checkout
  (submodule or fetched ref, at whatever path the project uses) to a tagged
  upstream release, reporting the changelog and any new migrations first.
  `--check` reports without changing anything. It must be run from inside the
  Kiln checkout and refuses to run anywhere else, so it cannot mistake a
  project repo's tags, migrations or changelog for Kiln's.
- An admin-only update notice showing the running version against the latest
  upstream release, plus the command to apply it. Set `KILN_PIN_PATH` to have
  that page prefix the command with a `cd` into your pin; left unset it gives
  a layout-agnostic instruction, since an image has no checkout to look in.
- `.tool-versions` is now the single source of truth for the Elixir/OTP
  toolchain. CI's seven `setup-beam` steps read it via `version-file:` instead
  of restating a loose `"1.19"`/`"27"` that resolved to whatever was newest, and
  the new `mix kiln.toolchain.check` (in `precommit` and CI) fails when the
  Dockerfile's ARGs or `mix.exs`'s `elixir:` requirement drift from it. This is
  the gate that would have caught the release image sitting on Elixir 1.18.4
  against a `~> 1.19` requirement — a build that could not succeed, green on
  every CI job because none of them builds that image.
- The update check is no longer nailed to this repo. **Forks should set
  `KILN_UPDATE_REPO=owner/name`**: left on the default they are told about
  upstream's releases, and a fork *ahead* of upstream compares as newer, so the
  page reports "Up to date" indefinitely and the fork's own security releases
  never surface. `KILN_UPDATE_RELEASES_URL` additionally repoints the API
  endpoint for GitHub Enterprise or an internal mirror. A value that isn't
  `owner/name` is rejected rather than silently replaced by the default.
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
