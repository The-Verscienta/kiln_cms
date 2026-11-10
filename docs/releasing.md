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

### The plugin SDK (`kiln_plugin`)

The plugin contract ships in its own package,
[`sdk/kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md) (#1909), released from its
own `kiln_plugin-vX.Y.Z` tags by `release-clients.yml`, not by a core release.
The core always builds against the copy in this repository, so a core release
needs nothing from Hex. Two things tie the two together:

- **A core release that changed `sdk/kiln_plugin` publishes the package too**:
  bump its `@version` and CHANGELOG in the same release PR, and tag
  `kiln_plugin-vX.Y.Z` after the core tag — **on a later commit, never the
  core release commit itself**. A pinned site's `mix kiln.update` reads the
  pin's version from the tags on its commit, and before 1.7.0 it read only
  the one `git describe --exact-match` names: `kiln_plugin-v1.3.0` on v1.6.0's
  commit made every 1.6.0 pin read as untagged. Third-party plugins resolve the
  contract from Hex, and `mix kiln.plugins.doctor` checks their requirement
  against the bundled version, so a core that bundles an unpublished
  `kiln_plugin` version can't be targeted by anyone else.
- **Publish `kiln_plugin` before the core's docs are next published.** The
  core's reference no longer contains the contract modules: every
  `Kiln.Plugin`/`Kiln.Block`/`Kiln.FieldType` reference in it links to
  hexdocs.pm/kiln_plugin, which 404s until the first publish.

SemVer for the package mirrors the core's contract: a minor adds (a callback
with a default, a DSL option), a major only alongside a core major.

## Cutting a release

1. **Confirm CI is green on `main`.** The `overlay_drift` job is the one that
   matters most here: it builds the in-tree `example` overlay against the
   core, so a green run is evidence the overlay contract still holds.

   It is not evidence the *upgrade* works. Run the **Upgrade rehearsal**
   workflow (Actions → Upgrade rehearsal → Run workflow; it also runs weekly)
   on `main` too. For each of the last few releases it pins a scratch project
   at that tag, seeds it, and runs that release's own `mix kiln.update` to
   `main`, tagged locally as the next `-rc.0`. Then it rebuilds with the
   project's unchanged overlay, migrates, runs `mix kiln.blocks.backfill` and
   reads every row back. It also checks that each old release prints the
   Upgrade notes `upgrade_notes/3` expects for its range. A release from an
   older major (0.12.1 → 1.x, picked with the workflow's `tags` input) is
   rehearsed with `--allow-major`, as a downstream would pass it once it has
   read the notes; the major-version guard itself is covered by
   `kiln.update`'s own tests. To run one
   locally (it uses its own `kiln_cms_test_rehearse_*` database and drops it
   afterwards):

   ```bash
   CANDIDATE_REF=origin/main scripts/upgrade_rehearsal/rehearse.sh v0.11.0
   ```

   If the release had candidates, the last one must also have passed its
   canary on kilncms.dev (step 5 of
   [Cutting a release candidate](#cutting-a-release-candidate)). If `main`
   has moved since that candidate in anything but the changelog, the
   version and the deploy templates, the change was never canaried: cut
   another candidate, or say in the release commit why it needs none.

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

   and the `Stable (vX.Y.Z)` line (and the exact-pin example below it) in
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
   `ghcr.io/the-verscienta/kiln_cms` as `X.Y.Z` and `latest`, and from 1.0.0
   also as the floating major `X` (`1`). It is stamped with the commit and
   build date. A release candidate gets only its exact tag (see
   [below](#cutting-a-release-candidate)), and so does a patch on an older
   line (see [Patch releases and backports](#patch-releases-and-backports)).
   Nothing to run by hand; it authenticates as `GITHUB_TOKEN`.

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
   while a newer version exists. (The page asks kilncms.dev's release feed
   first and the releases API only as a fallback (#1877), but the feed is
   itself published from the GitHub release, so the release is still the
   step that makes a version visible.)

   Paste the changelog section in as the release body.

   Publishing it also runs `.github/workflows/publish-releases.yml`, which
   posts the release's notes (`docs/changelog/vX.Y.Z.md`) to kilncms.dev at
   `/releases/<version>` and relists `/releases` (#1870). Publish the release
   yourself, with `gh` or the web UI: a release created by a workflow's
   `GITHUB_TOKEN` starts no other workflow, so this one would not run. The
   job reads `main`, so the tag must be on it. A pre-release is skipped.
   If it fails, fix the cause and re-run it from the Actions tab with the
   version as input.

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

   The task that runs is the one in the checkout being *moved*, though, and
   only 0.12 and later read `[Unreleased]` that way. A project on 0.11 or
   older moving to a 0.12 candidate is shown **no** notes for it: its task
   prints the earlier releases' notes, and then moves the pin anyway. The
   upgrade rehearsal (#1540) caught this for every release from 0.5.0 to
   0.11.0. So for a 0.12 candidate, paste its `### Upgrade notes` and
   `### Breaking` into the pre-release's notes (step 4) and say so where the
   candidate is announced. From 0.12 on, the notes print as described.

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

5. **Canary it on kilncms.dev** (#1869). kilncms.dev is the one Kiln
   instance the project runs with real editors and real traffic, so it is
   where a candidate first meets a live database. Beta testers exercise the
   features. The canary catches what only an upgrade shows: an
   expand/contract mistake, a new boot warning, the cache under real load.

   First check the migrations over the whole range, from the release
   kilncms.dev runs now:

   ```bash
   mix kiln.migrations.check --base vA.B.C   # the release kilncms.dev runs
   ```

   CI judged each pull request's migrations on their own. This judges them
   together, and it must pass, because it is what makes the rollback below
   safe. Then take a backup (`scripts/backup.sh`), point the kilncms.dev app
   at `ghcr.io/the-verscienta/kiln_cms:X.Y.Z-rc.N` (or, where the platform
   builds from source, at the `vX.Y.Z-rc.N` tag), and redeploy. Migrations
   run on boot.

   Let it soak for about **48 hours**, including a working day of editing
   and a docs publish (`publish-docs.yml` writes every guide through the
   API). Then compare it with the previous release over the same hours of
   the week:

   - the boot log: `bin/migrate` finished, and no boot warning is new
     (they go to stderr only, so read the container log);
   - Sentry, when `SENTRY_DSN` is set, and the log's `[error]` lines;
   - headless API and editor save p95, from the panels in
     [`observability.md`](observability.md) (which need
     `KILN_METRICS_ENABLED`);
   - Oban failures.

   **What blocks the final:**

   - a migration that fails on boot, or has to be finished by hand;
   - a new error class: an exception, Sentry issue or `[error]` line the
     previous release did not produce, however rare;
   - a p95 regression on the headless API or editor save against the
     previous release, and any p95 over its target in
     [`performance.md`](performance.md#slo-targets).

   Fix it on `main`, cut `-rc.N+1`, and canary that one from the start. A
   blocker found on hour 47 restarts the 48.

   **Rolling back** is pointing the app at the previous release's image
   and redeploying. Do not run the down migrations. The range passed
   `mix kiln.migrations.check`, so the previous release runs against the
   migrated schema, as the old nodes of a rolling deploy do (see
   [Migrations: expand, migrate, contract](#migrations-expand-migrate-contract)).
   Two things do not go back with the image: rows a migration rewrote (the
   candidate's Upgrade notes name them), and Oban jobs queued for a worker
   only the candidate has, which fail on the previous release until their
   attempts run out.

   `demo.kilncms.dev` does not take candidates. It resets to a golden
   snapshot ([`demo-mode.md`](demo-mode.md)) that would need recapturing for
   each one, so it moves to the final release once that is published.

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

## Patch releases and backports

[`.github/SECURITY.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/SECURITY.md#supported-versions)
sets the policy: the latest minor gets every fix, and the previous minor gets
security fixes for 90 days from the release date of the minor that replaced
it. The window applies within a major, from 1.0.0 on: `0.x` gets nothing
after 1.0.0's release date, so there is no `0.12.x` backport once 1.0.0 is
out. There are no long-lived maintenance branches. Each patch is cut from a
short-lived branch off the line's newest tag, and the branch is deleted
afterwards. v0.9.1 was the first patch cut this way.

**When `main` will do.** A patch carries fixes only. If everything on `main`
since the line's newest tag is a fix, cut the patch from `main` as in
[Cutting a release](#cutting-a-release) and stop here. Otherwise, and always
for the previous minor, use a branch:

1. **Fix it on `main` first**, through a normal PR with its changelog entry.
   A backport is a copy of a fix that has already been reviewed, never the
   first place it lands.

2. **Branch from the line's newest tag.** Name the branch after the version
   you are cutting:

   ```bash
   git fetch --tags origin
   git checkout -b release/v1.0.3 v1.0.2
   git cherry-pick -x <fix commit>        # -m 1 if it is a merge commit
   ```

   `-x` records the source commit in the message. Expect conflicts in
   `CHANGELOG.md` and `docs/changelog/unreleased.md` only: take the tag's
   version of each, then add just this patch's entries and long-form blocks.

3. **Get CI on the exact tree.** `ci.yml` runs on pushes to `main` and on pull
   requests to any base, so push a base branch at the tag and open the release
   branch as a PR against it. Title it "don't merge": it exists only for the
   CI run.

   ```bash
   git push origin v1.0.2:refs/heads/release/v1.0.x
   git push -u origin release/v1.0.3
   gh pr create --base release/v1.0.x --title "v1.0.3 (CI only, don't merge)" --body "…"
   ```

4. **Cut it on the branch**: steps 2 to 4 of
   [Cutting a release](#cutting-a-release), with a `## [1.0.3]` section,
   `--condense`, and the `mix.exs` and API spec bump. For a patch on the
   previous minor, leave the deploy templates and the README's version line
   alone: they follow the latest line, and `main` owns them.

5. **Tag the branch and push only the tag.**

   ```bash
   git tag v1.0.3
   git push origin v1.0.3
   ```

   `release.yml` publishes the image as `1.0.3`. `latest` and the major tag
   `1` move only if this is the highest final release overall (for `latest`)
   or on its major (for `1`), so `1.0.3` pushed after `1.1.0` moves neither.
   The run log's "Decide which floating tags move" step says why.
   `scripts/release/floating_tags.sh` makes the call, and
   `test/scripts/release_floating_tags_test.exs` covers it.

6. **Publish the GitHub release without making it "latest"** if a newer line
   exists:

   ```bash
   gh release create v1.0.3 --latest=false --title "v1.0.3" --notes "…"
   ```

   Say `--latest=false` explicitly. The releases API's default for a new
   release is to make it latest, and `gh`'s own default is an automatic choice
   that weighs creation date as well as version. Neither is safe to rely on
   for an older line. Every deployed instance's update page (`Kiln.Updates`) asks
   `releases/latest`, so a 1.1 instance would compare itself against `1.0.3`,
   read itself as ahead, and report "up to date" while a `1.1.x` patch
   existed. If that happens, run `gh release edit v1.1.1 --latest` on the
   highest release.

   Its notes reach kilncms.dev only once they are on `main`: after step 7,
   run "Publish release notes" from the Actions tab with `v1.0.3` as the
   version.

7. **Merge the branch back into `main` with a merge commit.** Open
   `release/v1.0.3 → main` and merge it with **Create a merge commit**, never
   squash or rebase. `mix kiln.update` refuses to move a pin to a release
   that is missing commits the pin already has (it reads them as local
   patches to the core). The cherry-picked commit has its own SHA, so until
   the patch's tag is an ancestor of the newer release, a site on `v1.0.3` is
   refused an update to `1.1.x`. On the merge-back, move the patch's changelog
   entries into a `## [1.0.3]` section below the newer releases.

   If the latest minor needs the same fix as a patch and `main` is not
   releasable, cut `release/v1.1.1` from `v1.1.0` in the same way, and merge
   `release/v1.0.3` into it **before** you tag `v1.1.1`. Then merge
   `release/v1.1.1` back into `main`. `v1.0.3` is then an ancestor of
   `v1.1.1`, and a site on `v1.0.3` can move straight to it.

8. **Delete the branches**, `release/v1.0.3` and the CI base
   `release/v1.0.x`. The tag keeps the history reachable.

**A security fix's notice.** Fill in the private advisory's affected and
patched versions per line (`>= 1.0.0, < 1.0.3` and `1.0.3`; `>= 1.1.0, <
1.1.1` and `1.1.1`), and publish it before you publish the GitHub release.
Deployed instances decide from the affected range alone; `patched_versions`
is display text ("fixed in 1.0.3"). So the affected range must end before
each fixed release, or instances already on the fix read as covered
([Security notices for Kiln](security-posture.md#security-notices-for-kiln)).
Publishing a release runs `.github/workflows/publish-security.yml`, which
turns every published advisory into a notice at
`kilncms.dev/security-notices/<ghsa-id>`, lists it on `/security`, and puts
it in the notices feed (#1873). An advisory published after the release
reaches the site on the workflow's daily run, or straight away from "Publish
security page" in the Actions tab. The workflow never unpublishes a notice:
withdraw a withdrawn advisory's notice in the editor too.

**What `mix kiln.update` does with a patch tag.** A plain update targets the
highest final release, not the newest tag and not the newest on the pin's own
line. A project pinned at `v1.0.2` after `v1.1.1` and `v1.0.3` exist is
offered `v1.1.1`. A minor move needs no flag, and the Breaking and Upgrade
notes print for every release in between. To take the backport and stay on
the line:

```bash
mix kiln.update --to v1.0.3
```

A pin at `v1.0.3` is refused a move to `v1.1.0`, if `v1.1.0` was released
before the fix: it does not have the fix, and the task reports the patch's
commits as ones the target is missing. Move to the `1.1.x` patch that has
the fix instead. `--force` skips the check, but only use it if the release
notes say `1.1` was never affected.

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

### Re-render published content after an upgrade

A release that changes what firing produces (new markup on the `web`
surface, a new key in `json_ld`) reaches a published document only when it is
next published, edited or re-fired; reading it does not re-fire it. The
release's upgrade notes say when a re-fire is worth running. To re-fire every
published document on every site at once:

1. **Wait until every node runs the new release.** A firing job picked up by
   a node still on the old release writes the old markup again.
2. **Decide who has to be told.** A fired artifact's `ETag` is a digest of
   the body it serves, so a CDN, browser or app that revalidates with
   `If-None-Match` gets the new body on its next revalidation, whether or not
   anything is announced. A consumer that keeps its copy until a webhook says
   otherwise (a static build, an ISR page, a mirror fed by webhooks) does not
   hear about a plain re-fire. If you have one, add `notify: true` below.
3. **With `notify: true`, check that the receivers can take the volume.** It
   sends one `<type>.updated` per published document to every endpoint
   subscribed to that event, with `"reason": "refire"` in `data`, and puts
   the same `updated` on the public change feed. Nothing else hears it:
   automation rules, federation and the CDN purge do not run. The deliveries
   share the `webhooks` queue (3 at a time per node) with your editors'
   publishes, which wait behind them. A receiver that answers `429` or `5xx`
   until a delivery runs out of retries counts toward auto-disable, and 10
   exhausted deliveries in a row turn the endpoint off
   ([Auto-disable](webhooks.md#auto-disable)). Run it off-peak, and tell the
   receivers' owners first.
4. **Start the sweep** on the running node:

   ```bash
   /app/bin/kiln_cms rpc "IO.inspect(KilnCMS.Firing.Sweep.run(notify: true))"
   ```

   It prints how many documents it queued, per type (`%{entry: …, page: …,
   post: …}`), and the node logs `Re-fire sweep enqueued <n> documents`. For
   a silent sweep, call `KilnCMS.Firing.Sweep.run()` instead. In a checkout
   the same sweep is `mix kiln.refire_all --notify` (or without the flag);
   don't run the `mix` task against production, because it boots a second
   node.
5. **Watch it drain** until this prints `0`:

   ```bash
   /app/bin/kiln_cms rpc "IO.inspect(KilnCMS.Firing.Sweep.pending())"
   ```

   It counts every pending `:firing` job, your editors' publishes included.
6. **Purge the CDN once**, if you run one in front of Kiln and don't want to
   wait for cached copies to expire (300 seconds for a fired artifact). With
   `KILN_CDN_PURGE_URL` set, queue a purge of every site:

   ```bash
   /app/bin/kiln_cms rpc "Enum.each(KilnCMS.Accounts.list_org_ids(), &KilnCMS.CDN.purge_site/1)"
   ```

   Without it, purge the `kiln` surrogate key (every Kiln API response
   carries it) in your CDN's own console. The sweep does not purge per
   document, which would empty the cache every few seconds for as long as it
   ran.

What can go wrong:

- **`--notfy : Unknown option. Did you mean --notify?`** from
  `mix kiln.refire_all`: the flag is misspelled. Nothing was queued.
- **An endpoint shows as auto-disabled** after the sweep: its receiver
  refused 10 deliveries in a row, and gets nothing more until you tick
  **Active** on it again ([Auto-disable](webhooks.md#auto-disable)).
  `/editor/webhooks` lists only the 25 newest deliveries, too few to
  redeliver a sweep's worth by hand. Fix the receiver, turn the endpoint back
  on, and either have the receiver refetch everything once or run the sweep
  again with `notify: true` (re-firing is idempotent, but every endpoint
  hears the whole round again).
- **A receiver gets an `updated` with `"reason": "refire"` right after a
  `published`** for the same document. An editor published it while the
  sweep's job for it was still pending, and the publish's fire was merged
  into that job, so it was announced as a re-fire too. It is the same
  document; refetching it twice is harmless.
- **`/api/sync` clients do not see the re-render**: sync reports a document
  when its `updated_at` moves, and a re-fire does not move it. They pick up
  the new body on their next full resync (`initial=true`).

## Migrations: expand, migrate, contract

A rolling deploy runs two releases at once. The first new node migrates the
database on boot, and the old release's nodes keep serving against the
**new** schema until the load balancer has moved every request over. A
migration is only safe if the release before it keeps working against it.
From 1.0 every schema change follows this policy (#1716):

1. **Expand.** Add tables and columns. A new column is nullable or has a
   default, so the old release's inserts, which do not know it exists, still
   succeed. Keep the old table or column in place.
2. **Migrate.** Backfill in an Oban job or a release task, not in the
   migration. From this release on, the code writes both shapes (or the new
   one only) and reads the new one.
3. **Contract.** Drop, rename or tighten only in a **later** release, once no
   release that could still be running reads the old shape. That is at least
   the release after the one that stopped reading it.

The cases that come up:

- **Renaming a column or table** takes two releases: add the new one and
  backfill it (release N, which stops reading the old one), then drop the old
  one (release N+1). A plain `rename` is a drop as far as the old release is
  concerned.
- **Changing a column's type** is a rename in disguise. Add a column of the
  new type, backfill it, and drop the old one a release later.
- **`NOT NULL`** needs either a default, which Postgres 11+ applies without
  rewriting the table as long as the default is not volatile, or a backfill
  release first. Tighten a column to `null: false` in the release after the
  one whose code always sets it. The old release may still insert `NULL`
  until then.
- **Dropping a column** waits until the release that stopped reading it has
  shipped. Ash selects every attribute, so the old release breaks the moment
  the column is gone (`20260919191545_drop_webhook_plaintext_secret` is the
  example that prompted this policy). Remove the attribute from the resource
  in release N, then run `mix ash.codegen` for the drop in release N+1.
- **An index on a large table** is built concurrently. A plain
  `CREATE INDEX` takes a lock that blocks writes to the table for the whole
  build. In a resource, use `custom_indexes do index [...], concurrently: true
  end`. For the unique index behind an identity, run
  `mix ash.codegen <name> --concurrent-indexes`. Either way codegen puts the
  index in its own migration with `@disable_ddl_transaction true` and
  `@disable_migration_lock true`, because Postgres refuses
  `CREATE INDEX CONCURRENTLY` inside a transaction. An index on a table the
  same migration creates needs none of this.

  A concurrent build that fails or is cancelled leaves an `INVALID` index:
  Postgres keeps updating it on every write and never reads it, and a retry
  of the same migration fails on the name. List them with
  `SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;`, drop the
  one that belongs to the migration with `DROP INDEX CONCURRENTLY <name>;`,
  and run the migration again. The `custom_fields` GIN indexes (#2291) are an
  example: they are large on `entries`, so the build can take a while.
- **A custom field's stored shape** changes with a task rather than a
  migration: `mix kiln.fields.convert` moves a field's values into a new
  field ([field-conversion.md](field-conversion.md)), and
  `mix kiln.media.resnapshot --apply` rewrites stored media snapshots. Both
  write records in the trash as well as live ones, so a document restored
  after the contract release has the new shape (#2533). They read the live
  records and the trashed ones separately, and a record trashed or restored
  in between can be missed by both, so **run the task again right before
  the contract release**. Records already converted or current are not
  rewritten.

### The check

`mix kiln.migrations.check` runs on every pull request (the `build` job in
`ci.yml`). It reads each migration the PR **adds**, under
`priv/repo/migrations` and every overlay's `projects/*/priv/repo/migrations`,
and only its forward direction (`up`/`change`). It fails on:

| Flagged | Why |
|---|---|
| `drop table`, `rename table` (or a column) | the old release still reads the table or column |
| `remove :col` | the old release still selects the column |
| `modify` that changes the type | the old release reads the old type. The previous type comes from `from:` or the migration history. If it is unknown, the change is flagged too. |
| `modify ... null: false`, or `add ... null: false` without `default:` on an existing table | the old release may still write `NULL`, or omit the column |
| `execute` SQL containing `DROP TABLE/COLUMN/VIEW/SCHEMA/TYPE`, `RENAME`, `ALTER COLUMN ... TYPE` or `SET NOT NULL` | a heuristic that flags the statement for review. Dropping and re-creating a function or trigger is not flagged. |
| removing, renaming or retyping a column a `kiln_reporting_v1` view reads, without dropping both views of the pair first | Postgres refuses it while the views exist (see below). A `kiln:contract-ok` marker does not excuse it. |
| a non-concurrent index on a table listed in `Mix.Tasks.Kiln.Migrations.Check.large_tables/0` | the build blocks writes |
| `concurrently: true` without `@disable_ddl_transaction true` | the migration would fail at boot |

The history is exempt. Only the diff against the base is judged, so
`mix kiln.migrations.check --all` over today's history reports what the
policy would have caught. On 0.12.0 that was 106 findings: 65 non-concurrent
indexes on large tables, 34 `SET NOT NULL`s (most of them the #336
multi-tenancy `org_id` backfill-then-tighten migrations), 4 dropped tables,
2 `NOT NULL` columns added without a default, and the dropped webhook
secret. Run it locally before pushing. It is stdlib-only, so it runs in a
checkout with no `deps/`:

```bash
mix kiln.migrations.check                  # vs origin/main
mix kiln.migrations.check --base v0.12.0   # vs another ref
```

**When the contract step is the point**, say so in the migration, on the
line above the statement (or at the end of its first line):

```elixir
# kiln:contract-ok since v0.12.0 — 0.12.0 stopped reading webhook_endpoints.secret
alter table(:webhook_endpoints) do
  remove :secret
end
```

The version names the **shipped** release that stopped reading the old
shape, so it may not be newer than the version in `mix.exs`. The reason is
required, and `--` works in place of the em dash. The marker covers the one
statement it sits on. An `alter table` block counts as one statement, so a
marker above it covers every op inside. For an index build that is safe for
another reason, such as a table that is small everywhere, use
`# kiln:lock-ok — <reason>`. A malformed marker is itself a failure. So is
a marker that names an unshipped release, or one that excuses nothing.

### Columns the reporting views pin

The SQL reporting views (`kiln_reporting_v1`, [reporting.md](reporting.md))
are a public contract, and Postgres will not alter or drop a column a view
reads. So the views **pin** their columns, and a migration that touches one
fails at deploy even if the old release no longer reads it. The pinned
columns are the ones in `KilnCMS.Reporting.ViewSql.pinned_columns/0` (the core
columns plus `custom_fields`, `archived_at`, `access_password_hash`,
`type_definition_id`) on every content table that has a view, and the
`field_definitions` and `type_definitions` columns in
`KilnCMS.Reporting.ViewSql.pinned_other_columns/0`.

A migration that removes, renames or retypes one of them must, **in the same
`up` or `down` function and before the change**, `DROP VIEW IF EXISTS
kiln_reporting_v1.<table>` **and** `kiln_reporting_v1.<table>_field_values`
(both views of the pair), then re-create the views after it. For a
definition-table column that means every viewed table's pair. A drop in `up`
does nothing for `down`, which runs on its own. The check applies to `up`,
`down` and `change`, to the `alter table` DSL and to raw `ALTER TABLE ...
DROP COLUMN / RENAME COLUMN / ALTER COLUMN ... TYPE` in an `execute`. The
change is still a contract change, so it also needs the usual
`kiln:contract-ok` marker, but the marker alone does not satisfy this rule;
only dropping the views does. Re-creating the views with changed columns is
a breaking change to the SQL contract: ship it as `kiln_reporting_v2`.

### New values in an atom column

An Ash `:atom` attribute is stored as text, and adding a value to its
`one_of` list needs no migration, so `mix kiln.migrations.check` has nothing
to flag. The older release is still the problem. Plain `:atom` loads stored
text with `String.to_existing_atom/1`, and when the release has no such atom
the read fails, and with it every list, export or bulk update that meets the
row. A new value written by release N therefore breaks release N-1's reads of
that table during a rolling deploy, and again after a rollback, for as long as
the row exists (#2509).

`KilnCMS.Types.KnownAtom` is the fix. Used in place of `:atom` on a table
column, it loads a stored value outside `one_of` (or one that names no atom
at all) as `%KilnCMS.Types.UnknownAtom{value: "the_text"}` instead of failing,
and creates no atom from database text. Writes stay strict: input is cast as
`:atom` casts it and `one_of` still applies. Switching costs no migration,
because the storage stays text.

So the rule for a column, or an embedded attribute, that will grow:

1. **Release N:** change the attribute from `:atom` to `KilnCMS.Types.KnownAtom`
   (keep `one_of`), and give every reader of the column a clause for
   `%UnknownAtom{}`. A `case` on the known values falls through to its
   catch-all, since the struct equals no atom. `mix ash.codegen --check`
   stays clean.
2. **Release N+1 or later:** add the new value. N is now the oldest release
   that can run beside it, and N reads the row.

The switch has to ship **at least one release before** the first new value,
for the same reason a contract step waits a release. `Security.Event.type`
and `Notification.event` are already `KnownAtom`.

The same hazard, and the same two-step rule, covers:

- **`{:array, :atom}` columns.** `{:array, KilnCMS.Types.KnownAtom}` loads an
  unknown item as `UnknownAtom` and the rest as atoms.
- **An `:atom` attribute inside an embedded resource** (a block, a group
  field: one JSON tree per record, D3). With plain `:atom`, an unknown value
  fails the cast of the whole tree, so the record does not load at all.
  `KnownAtom` (and `{:array, KnownAtom}`) loads it as `UnknownAtom` there
  too, and dumps it back to its stored text unchanged. Switch the
  embedded attribute a release before adding a value, as for a column.
- **An `:atom` column without `one_of`.** It fails the same way on a value the
  older release has no atom for. `FieldDefinition.field_type` was one: the
  `key_value` and `telephone` types added since v1.8.0 break v1.8.0's
  field-definition reads
  ([#2605](https://github.com/The-Verscienta/kiln_cms/issues/2605)).

An **open set**, whose values follow a registry rather than a list in the
attribute (field types, which plugins add to), cannot take `one_of`. Make it
a `KilnCMS.Types.KnownAtom` without `one_of`, and check membership in the
registry yourself:

- **On write,** a validation refuses a value the registry doesn't list
  (`Validations.KnownFieldType`).
- **On read,** decide what a row of an unregistered value means. For
  `FieldDefinition`, a resource-level preparation
  (`Preparations.RegisteredFieldTypes`) filters such rows out in SQL, so
  nothing downstream meets one. The few readers that must see them (the
  value-keeping write, private-field masking, the Fields screen's delete)
  pass `FieldDefinition.all_types_context/0` and handle
  `FieldDefinition.unknown_type?/1` themselves.

With that in place, a value can join the registry in any release, and a
rollback, or removing the plugin that supplied it, only hides the rows.

`test/kiln_cms/atom_columns_test.exs` holds the line: it walks the core
domains (as `config/config.exs` lists them) and the core's embedded resources,
and fails on any `:atom` or `{:array, :atom}` attribute without `one_of` that
is not on its reviewed list. Use `KnownAtom`, add `one_of`, or add the
attribute to the list with the reason an unknown value can't reach it. A
downstream project's own domains are not checked.

Two widenings need the same two-release treatment although they add no
atom:

- **`FieldDefinition.link_field_types/0`.** Link fields and group sub-fields
  may only have these types. A sub-field row of a type the older release
  filters out is missing from its parent's definition there, so a save of
  the parent's value from the editor drops that key from each row: the
  value-keeping write covers top-level fields only.
- **The types that may be `multiple`** (`KilnCMS.CMS.ScalarLists.types/0`,
  `Changes.ClearMultiple.list_types/0`). An older release treats the field
  as single-valued, so a record holding a list in it can fail to save or to
  open in the editor there.

#### Rolling back to v1.8.0

v1.8.0 predates `KnownAtom`, so rows the current code wrote with a value
v1.8.0 does not know break its reads. Before rolling back to v1.8.0, run this
once against the database:

```sql
DELETE FROM notifications
WHERE event IN ('registration_pending', 'security_alert', 'security_notice');
DELETE FROM api_keys WHERE access = 'draft_write';
```

- **Notifications.** A registration notice or a security alert breaks the
  bell, the inbox and "mark all read" for its recipients on v1.8.0. The
  registration notices are reminders about the registration queue, which
  itself is untouched.
- **API keys.** Draft-write keys stop working on v1.8.0 whatever you do,
  because it has no `draft_write` scope. Left in place, the key's own lookup
  and the site's list on the API keys page fail; deleted, the page loads.
  Mint the keys again after rolling forward. Never `UPDATE` them to
  `'read'` instead: that silently changes what a key someone already holds
  can do.
- **Security events** need nothing: v1.8.0 has no security log, so it never
  reads `security_events`.

**Custom fields** of a type added since v1.8.0 need a decision per field,
because deleting a field deletes the values every record holds in it:

1. **Find the `key_value` and `telephone` fields.** v1.8.0 has no atom for
   either, so while one exists every field-definition read fails there: the
   Fields screen, the content editor, every save of a record with custom
   fields, and delivery.

   ```sql
   SELECT org_id, content_type, type_definition_id, name, field_type
   FROM field_definitions WHERE field_type IN ('key_value', 'telephone');
   ```

2. **Back up.** A database backup keeps the values. A field export
   (`GET /editor/fields/export.json` or `KilnCMS.CMS.FieldSync.export/1`)
   keeps only the definitions.
3. **Delete them on the current release,** from a remote console
   (`bin/kiln_cms remote`), so their values are removed from every record
   and the caches are cleared:

   ```elixir
   for org <- KilnCMS.Accounts.list_organizations!(authorize?: false),
       field <-
         KilnCMS.CMS.list_field_definitions!(
           authorize?: false,
           tenant: org.id,
           query: [filter: [field_type: [in: [:key_value, :telephone]]]]
         ) do
     KilnCMS.CMS.destroy_field_definition!(field, authorize?: false, tenant: org.id)
   end
   ```

   A field that another field's condition reads is refused ("is used in the
   conditions of …; remove those conditions first"): remove the condition
   and run the loop again. A plain
   `DELETE FROM field_definitions WHERE field_type IN ('key_value', 'telephone');`
   also unblocks v1.8.0, but leaves the values in each record's
   `custom_fields` until v1.8.0 next saves it, and running nodes keep the
   rows cached until they restart.
4. **Decide on the other new types.** v1.8.0 loads `email`, `color`, `slug`,
   `time`, `json`, `range` and `link` fields, but refuses to save a record
   with a value in one ("has an unregistered field type"), and a map value
   (`range`, `link`, a `json` object) can stop its editor opening the
   record. The same goes for a `multiple` field of type `integer`, `float`,
   `date`, `datetime` or `url` (scalar lists, #2289). Delete those fields as
   in step 3, or leave the records that use them alone until you roll
   forward. To find them:

   ```sql
   SELECT org_id, content_type, type_definition_id, name, field_type, multiple
   FROM field_definitions
   WHERE field_type IN ('email', 'color', 'slug', 'time', 'json', 'range', 'link')
      OR (multiple AND field_type IN ('integer', 'float', 'date', 'datetime', 'url'));
   ```

The steps were run against the current release; what v1.8.0 does with what
is left is read from its code, not tried on a v1.8.0 deployment.

A rollback to a release that already has `KnownAtom` on a column needs none
of this for that column: the older release shows the row as unrecognized.
For field definitions that is every release from the one that fixed #2605:
it hides a field of a type it doesn't know and keeps the field's values
(see [Delete a field of an unknown type](extending-content.md#delete-a-field-of-an-unknown-type)).

### What zero-downtime does and does not cover

The policy makes the **schema** safe for two releases at once. Kiln's boot
and probes already handle the rest of an ordinary rolling deploy
([`deploy.md`](deploy.md), "What happens at boot" and "Health endpoints"):

- **Migrate on boot, serialised.** Every node runs `bin/migrate` before it
  serves. `Ecto.Migrator` holds a lock on `schema_migrations`, so the first
  new node migrates and the rest wait. The lock does not block the old
  release's queries.
- **Readiness.** `/live` only answers once `bin/migrate` has finished and
  the endpoint is up, and `/up` also requires the database. Pointing the
  load balancer's readiness check at `/up` keeps a new node out of rotation
  until it can serve.
- **Graceful drain on `SIGTERM`.** The release stops its listener and gives
  in-flight HTTP requests up to 15 s to finish (Bandit/Thousand Island's
  `shutdown_timeout` default). Running Oban jobs get Oban's 15 s
  `shutdown_grace_period`.

It does **not** cover:

- **LiveView and WebSocket sessions.** They are disconnected when their node
  stops, and the client reconnects to a new node, which remounts the view.
  LiveView's form recovery re-sends a form that has `phx-change`, and an open
  GraphQL subscription must resubscribe.
- **A job that outlives the grace period, until it is rescued.** Oban kills
  it and leaves the row in `executing`. `Oban.Lifeline` moves it back to
  `available` (or `discarded` once its attempts are spent) after
  `KILN_OBAN_RESCUE_AFTER_MINUTES`, 180 by default, so the job runs again
  from the start, not where it stopped. Which jobs are safe to re-run is in
  [Jobs interrupted by a deploy](deploy.md#jobs-interrupted-by-a-deploy).
- **Readiness does not flip before shutdown.** `/up` keeps answering 200
  until the listener closes, so the load balancer should stop routing on
  its own deregistration (Kubernetes removes the pod from the Service
  endpoints on termination, but in parallel with the `SIGTERM`). A short
  `preStop` sleep closes that race.
- **Lock waits.** Kiln sets no `lock_timeout`, so a migration's
  `ALTER TABLE` waits behind a long-running query, and every query on that
  table queues behind the waiting migration. Deploy outside a heavy
  export or report.
- **A release that skips one.** Expand/contract assumes each release is
  deployed in turn. Jumping from N-1 to N+1 runs N's expand and N+1's
  contract in one boot while N-1 nodes are still serving. Deploy each
  minor in sequence, or accept a short outage and stop the old nodes first.
- **New values in an atom column.** No migration, so the check passes, but
  the old release's nodes fail to read a row the new ones wrote with a value
  they do not know, unless the column was already `KilnCMS.Types.KnownAtom`
  in the old release. See
  [New values in an atom column](#new-values-in-an-atom-column).
- **Single-instance deployments.** One container on one host (the Compose
  reference deployment, or a platform with a disk attached) has no second
  node to serve while the new one boots, so it drops traffic for the length
  of the boot however compatible the migration is.

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
the commit, which is the first thing you want when a deploy misbehaves. When
`GIT_SHA` is unset the Dockerfile falls back to a `SOURCE_COMMIT` build arg,
which Coolify passes when its **Include Source Commit in Build** setting is on.
