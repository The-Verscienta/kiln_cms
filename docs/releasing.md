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

   It is not evidence the *upgrade* works. Run the **Upgrade rehearsal**
   workflow (Actions → Upgrade rehearsal → Run workflow; it also runs weekly)
   on `main` too. For each of the last few releases it pins a scratch project
   at that tag, seeds it, and runs that release's own `mix kiln.update` to
   `main`, tagged locally as the next `-rc.0`. Then it rebuilds with the
   project's unchanged overlay, migrates, runs `mix kiln.blocks.backfill` and
   reads every row back. It also checks that each old release prints the
   Upgrade notes `upgrade_notes/3` expects for its range. To run one
   locally (it uses its own `kiln_cms_test_rehearse_*` database and drops it
   afterwards):

   ```bash
   CANDIDATE_REF=origin/main scripts/upgrade_rehearsal/rehearse.sh v0.11.0
   ```

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
the commit, which is the first thing you want when a deploy misbehaves.
