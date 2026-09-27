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
   `## [X.Y.Z]` section, and rename `docs/changelog/unreleased.md` to
   `docs/changelog/vX.Y.Z.md` — it already holds the long form of everything
   in that section.

   Add an `### Upgrade notes` subsection if — and only if — moving to this
   release needs more than a rebuild:

   - a manual backfill or reindex step, and whether it can run after deploy;
   - a migration that rewrites or drops data (say so, and say it's not
     reversible by rolling the pin back);
   - anything else to do against a *deployed* instance.

   Add a `### Breaking` subsection for anything that changes an observable
   contract or forces a change on the operator:

   - a new required env var or config key, or one whose default flipped;
   - a response shape, status code or route that changed;
   - anything a subproject must change to keep compiling.

   Write both as imperative steps. Those two sections are the **only** thing
   `mix kiln.update` prints before it moves anyone's pin (#1325), so they are
   the last chance to warn an operator — and everything else you want to say
   belongs in the entry itself, which the next step files away.

3. **Condense and check.**

   ```bash
   mix kiln.changelog --condense
   mix kiln.changelog --verify HEAD
   ```

   `--condense` rewrites each entry in `CHANGELOG.md` down to its own opening
   line plus a link to the long form under `docs/changelog/`. `--verify` then
   proves, paragraph by paragraph, that nothing was dropped on the way — run
   it before you commit, not after.

4. **Bump the version** in [`mix.exs`](../mix.exs). This is what a running
   instance reports (`Kiln.Version`) and what the update check compares
   against, so it must match the tag.

   Then regenerate the committed API specs, whose OpenAPI document states the
   version as `info.version`:

   ```bash
   mix kiln.api.specs
   ```

   CI's documentation job fails the release PR if you forget.

   Then bump the image tag in the one-click deploy templates, which pin an
   exact version so a stranger's first deploy is reproducible (#1529). Nothing
   gates these — a missed one silently keeps handing new users the previous
   release:

   - [`render.yaml`](../render.yaml)
   - [`fly.toml`](../fly.toml)
   - [`.do/app.yaml`](../.do/app.yaml)
   - the Railway recipe in [`docs/deploy-platforms.md`](deploy-platforms.md)

   and the `Pre-1.0 (vX.Y.Z)` line in
   [`README.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/README.md).
   The
   `:latest` references in `README.md` and `docs/getting-started.md` float on
   purpose — leave them.

   ```bash
   git grep -nE '(^|[^0-9.])v?0\.9\.0([^0-9.]|$)'   # the version you just left
   ```

5. **Commit, tag, push.**

   ```bash
   git commit -am "chore: release vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```

6. **Watch the release image publish.** Pushing the tag starts
   [`.github/workflows/release.yml`](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/workflows/release.yml),
   which builds the release image and pushes it to
   `ghcr.io/the-verscienta/kiln_cms` as both `X.Y.Z` and `latest` (a release
   candidate gets only its exact tag — see
   [below](#cutting-a-release-candidate)), stamped with the commit and build
   date. Nothing to run by hand; it authenticates as
   `GITHUB_TOKEN`.

   The version bump in `mix.exs` invalidates the dep layer, but the build
   reads `main`'s cache for the rest: v0.9.0's took about nine minutes. Check
   the run before announcing the release.

   **Then check that a stranger can pull it.** A private image fails
   `docker pull` with a 403 for everyone but the maintainer, while the workflow
   reports success, because it pushed fine. This asks the registry as an
   anonymous client, with nothing to log out of first:

   ```bash
   tok=$(curl -s "https://ghcr.io/token?scope=repository:the-verscienta/kiln_cms:pull" \
     | python3 -c 'import sys, json; print(json.load(sys.stdin).get("token", ""))')
   curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $tok" \
     -H "Accept: application/vnd.oci.image.index.v1+json" \
     https://ghcr.io/v2/the-verscienta/kiln_cms/manifests/X.Y.Z
   ```

   `200` means it is public. If it is `401` or `403`, open the package
   (repository → Packages → `kiln_cms`) → *Package settings* → **Change
   visibility → Public**.

   GitHub's documentation says a new package starts **private** and does not
   take its repository's visibility. The first publish here did not work that
   way: v0.9.0's image, pushed by this workflow from this public repository,
   answered `200` straight after the build, with nobody having changed its
   settings. Run the check anyway rather than rely on either behaviour.

   Only `vX.Y.Z` tags trigger it. A scratch or rescue tag publishes nothing,
   which is the same rule `mix kiln.update` applies to tags it cannot parse.

7. **Publish a GitHub release** for the tag. This is not optional: `mix
   kiln.update` reads git tags, but the admin update page (`Kiln.Updates`)
   reads the *releases* API, because a running container has no checkout. A
   tag with no release leaves every deployed instance reporting "up to date"
   while a newer version exists.

   Paste the changelog section in as the release body.

8. **Verify** from a project checkout:

   ```bash
   cd <your kiln checkout> && git fetch --tags && mix kiln.update --check
   ```

## Cutting a release candidate

A release candidate lets downstreams rehearse a release — the 1.0 upgrade in
particular — before anyone's default update lands on it. Nothing floats onto a
candidate by accident (#1541): each place that picks "the newest release"
skips pre-releases, and each one has an explicit way in.

1. **Tag it `vX.Y.Z-rc.N`** — the version it is a candidate *for*, then
   `-rc.1`, `-rc.2`, …. By semver `1.0.0-rc.1` sorts below `1.0.0` and above
   every earlier release, which is exactly why the tools below must be told
   about it. The `-` is what every one of them looks for, so do not spell a
   candidate any other way (`v1.0.0rc1` does not parse as a version at all).

2. **Leave the changelog under `## [Unreleased]`.** Do not condense, do not
   rename `docs/changelog/unreleased.md`, do not add a `## [X.Y.Z-rc.N]`
   section — the final release does all of that, once. `mix kiln.update` reads
   `[Unreleased]` as the candidate's own notes when the target is a
   pre-release, so its Breaking and Upgrade notes still print before a pin
   moves. Do bump `mix.exs` to `X.Y.Z-rc.N`, so an instance on the candidate
   reports what it is running.

3. **Tag and push** as in [step 5](#cutting-a-release), with the candidate's
   name. `release.yml` publishes the image as `X.Y.Z-rc.N` only: `latest`
   stays on the previous final release, so `docker pull …:latest` and the
   `:latest` references in the README are unaffected.

4. **Publish the GitHub release as a pre-release:**

   ```bash
   gh release create vX.Y.Z-rc.N --prerelease --title "vX.Y.Z-rc.N" --notes "…"
   ```

   `--prerelease` is what keeps it off every deployed instance's admin update
   page: `Kiln.Updates` asks `releases/latest`, which GitHub defines as the
   newest release that is *not* a pre-release. A candidate published without
   the flag would become "latest"; the update check then refuses it
   (`{:error, :prerelease}`) rather than telling anyone to install it, but the
   page can no longer report on the final release either — fix it with
   `gh release edit vX.Y.Z-rc.N --prerelease`.

**How a downstream opts in.** A plain `mix kiln.update` never targets a
candidate. To try one:

```bash
mix kiln.update --to vX.Y.Z-rc.N    # exactly that candidate
mix kiln.update --pre               # the newest release, candidates included
```

The major-version guard still applies — `0.12.0 → 1.0.0-rc.1` needs
`--allow-major` like the final would. A pin left on a candidate stays there
under a plain update until the final release overtakes it (the task reports
the pin as ahead rather than downgrading it), and then moves to the final as
usual.

The client SDKs follow the same rule: a `client-js-vX.Y.Z-rc.N` tag publishes
to npm under the `next` dist-tag rather than `latest`, and Hex never resolves
a `kiln_client` pre-release unless a requirement names one.

## Updating a project to a release

From inside the project's pinned Kiln checkout — `kiln/upstream`, `upstream/`,
wherever that project puts it (see
[`projects/README.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/projects/README.md)
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
newest, `--pre` to let a release candidate count as the newest, `--ref main`
to deliberately track bleeding edge, `--allow-major` after
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
