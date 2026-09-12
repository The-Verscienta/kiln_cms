# Releasing Kiln

Downstream projects pin this repo as a submodule and update between **tagged
releases** (`mix kiln.update`). That only works if tags exist and carry honest
upgrade notes — this is the checklist for cutting one.

## Why tag at all

`main` moves fast. A project that fast-forwards to whatever `main` is today
takes an unbounded, undocumented jump: new migrations against its live
database, possibly a changed overlay contract, and no place to have written
down "set this env var first". A tag is the unit that can carry that note.

## Versioning

Semver, interpreted for a CMS core that projects overlay (the full definition
lives at the top of [`CHANGELOG.md`](../CHANGELOG.md)):

| Bump | Means |
|---|---|
| **major** | the overlay contract broke — a `projects/<name>/` subproject needs code changes to compile |
| **minor** | new capability, overlays keep compiling; may add migrations |
| **patch** | fixes only |

The major rule is the one to be strict about. `mix kiln.update` refuses a major
jump without `--allow-major` precisely because it's promised to mean "your
subproject needs work" — bumping major for a merely large release trains
people to pass the flag reflexively.

## Cutting a release

1. **Confirm CI is green on `main`.** The `overlay_drift` job is the one that
   matters most here: it builds the in-tree `example` overlay against the
   core, so a green run is evidence the overlay contract still holds.

2. **Write the changelog entry.** Move `## [Unreleased]` items into a new
   `## [X.Y.Z]` section. Add an `### Upgrading` subsection if — and only if —
   moving to this release needs more than a rebuild:

   - a new required env var or config key;
   - a migration that rewrites or drops data (say so, and say it's not
     reversible by rolling the pin back);
   - anything a subproject must change to keep compiling;
   - a manual backfill or reindex step, and whether it can run after deploy.

   Write them as imperative steps against a *deployed* instance. `mix
   kiln.update` prints this section verbatim before it moves anyone's pin, so
   it's the last chance to warn an operator.

3. **Bump the version** in [`mix.exs`](../mix.exs). This is what a running
   instance reports (`Kiln.Version`) and what the update check compares
   against, so it must match the tag.

4. **Commit, tag, push.**

   ```bash
   git commit -am "chore: release vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```

5. **Watch the release image publish.** Pushing the tag starts
   [`.github/workflows/release.yml`](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/workflows/release.yml),
   which builds the release image and pushes it to
   `ghcr.io/the-verscienta/kiln_cms` as both `X.Y.Z` and `latest`, stamped with
   the commit and build date. Nothing to run by hand; it authenticates as
   `GITHUB_TOKEN`.

   The tag build is usually cold — the version bump in `mix.exs` invalidates
   the dep layer — so budget most of an hour, and check the run before
   announcing the release.

   **One-time, the first time this ever runs:** a new GHCR package is created
   **private**. Open the package (repository → Packages → `kiln_cms`) →
   *Package settings* → **Change visibility → Public**, and link it to this
   repository while you are there. Until that is done `docker pull` fails with
   a 403 for everyone but the maintainer, and the workflow itself reports
   success — it pushed fine.

   Only `vX.Y.Z` tags trigger it. A scratch or rescue tag publishes nothing,
   which is the same rule `mix kiln.update` applies to tags it cannot parse.

6. **Publish a GitHub release** for the tag. This is not optional: `mix
   kiln.update` reads git tags, but the admin update page (`Kiln.Updates`)
   reads the *releases* API, because a running container has no checkout. A
   tag with no release leaves every deployed instance reporting "up to date"
   while a newer version exists.

   Paste the changelog section in as the release body.

7. **Verify** from a project checkout:

   ```bash
   cd <your kiln checkout> && git fetch --tags && mix kiln.update --check
   ```

## Updating a project to a release

From inside the project's pinned Kiln checkout — `kiln/upstream`, `upstream/`,
wherever that project puts it (see [`projects/README.md`](../projects/README.md)
for the overlay layout). The task refuses to run outside a Kiln checkout, so
pointing it at the project repo itself is an error, not a wrong answer:

```bash
cd <your kiln checkout>
mix kiln.update --check     # what's new, new migrations, upgrade notes
mix kiln.update             # move the pin to the newest release
```

Then commit the moved pin, rebuild the image, and redeploy. Migrations run on
boot (see the `CMD` in the [`Dockerfile`](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile)), so deploying applies
them — **take a backup first** (`scripts/backup.sh`) if the report listed any.

Useful flags: `--to vX.Y.Z` to land on a specific release rather than the
newest, `--ref main` to deliberately track bleeding edge, `--allow-major` after
reading the upgrade notes, and `--check --exit-code` to fail a CI job when a
project has drifted behind upstream.

## Build stamping

The release workflow already does this for the published core image — this is
the recipe for building one yourself: locally, or for an overlay (which is the
only way to get a `PROJECT=` image, since the published one is deliberately
project-agnostic).

Build with the commit and date recorded, so a deployed instance can say exactly
what it is on `/editor/system`:

```bash
docker build \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t kiln:vX.Y.Z .
```

Without them the image still boots and reports its version; it just can't name
the commit, which is the first thing you want when a deploy misbehaves.
