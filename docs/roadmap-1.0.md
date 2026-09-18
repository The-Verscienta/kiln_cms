# Roadmap: 0.9 → 1.0

Written on 2026-09-18, against v0.9.0. This page says **what 1.0 means**
and **the order of work to get there**. It does not track status. The
[issue tracker](https://github.com/The-Verscienta/kiln_cms/issues) and the
milestones hold that, because a checklist in a doc drifts and an issue does
not. When this page and an issue disagree, the issue wins, and this page
needs editing.

## 1.0 is a promise, not a feature list

The [project plan](../KilnCMS_Project_Plan.md) defined v1.0 as a feature set,
the "World-Class Core". That list has shipped: every box is checked except
the beta rounds (#59), and the rest of what is left is marked partial on
purpose. So nothing on this page is "build feature X before 1.0" for its own
sake. 1.0 is the point where Kiln starts **promising** things it
currently only intends:

1. **The overlay contract is frozen.** [`docs/overlay-contract.md`](overlay-contract.md)
   already says so: until 1.0 its covered list may gain and lose entries, and
   "at 1.0 this page becomes the definition of what a major bump means". After
   1.0, removing a covered surface costs a 2.0.
2. **Deprecation works, and has been used.** The policy exists (overlay
   contract, *Deprecation*): the old surface keeps working for at least one
   minor, carries a compiler-visible marker, and is removed only in a major.
   It has never been exercised. No `@deprecated` exists in `lib/`, and no
   release has had a `### Deprecated` section. The first deprecation should
   happen before 1.0, not under 1.0's rules.
3. **Every surface is labelled.** Each one is *covered*, *internal*, or
   *experimental*. The README's stability table and the overlay contract
   agree, and nothing is left unlabelled.
4. **Release lines are named.** [`.github/SECURITY.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/SECURITY.md)
   says "once 1.0 ships this table will name the release lines that receive
   backports". So 1.0 needs a decision on what is supported, and for how long.
5. **Real authors have used it.** The beta rounds in
   [`docs/beta-testing.md`](beta-testing.md) have run, and they cleared a bar
   that is written down *before* the first round.
6. **Nothing security-shaped is open**, and the threat model's accepted
   residuals have been re-read and still accepted, one by one.

### What moving to 1.0 costs a downstream project

`mix kiln.update` refuses any jump where the major version rises unless it
is given `--allow-major`. That includes 0.x → 1.0, even if nothing breaks.
The 1.0 upgrade note has to say this in its first line. It should also say
whether the flag is a formality or not: whether 1.0 removed anything (see
"Retiring legacy shapes" below).

## Milestones

Four releases, each with one job. The code work is modest. The critical path
is the beta rounds, which take calendar time with people rather than PRs, so
begin preparing for them in 0.10, not after it.

### 0.10: operator hardening

The things an operator would hit in their first months of running Kiln.

- **Secret rotation (#1487).** Rotating `SECRET_KEY_BASE` permanently orphans
  the vault-encrypted columns, and the ActivityPub actor key cannot be rotated
  safely at all ([`docs/secrets-rotation.md`](secrets-rotation.md) documents the
  hazard, not a fix). A 1.0 install will eventually rotate its secrets.
- **Integration settings in the UI (#1322, the remaining half).** Move storage,
  SMTP, Meilisearch, SSO, AI endpoints and push keys into per-organization
  settings, with environment variables kept as bootstrap. The runtime.exs split
  and the environment-variable docs are already done.
- **Metrics that someone actually receives (#1362).** `metrics/0` has no
  production consumer, and yet [`docs/performance.md`](performance.md) calls
  them scrapeable. Pick a reporter, or say plainly there is none, and make
  both docs agree. Without this, 1.0's performance targets cannot be measured.
- **The two half-done usability issues.** #1323: the Overview still ships as
  a bagua, with a "taiji · centre" tile. #1321: the "space-free, non-iCloud
  path" warnings in `CONTRIBUTING.md` and `AGENTS.md` still need verifying,
  then either fixing or reporting upstream.
- **Docs accuracy pass.** Fix the claims found stale while writing this page:
  - the README status section names `v0.8.0` and calls #1453 "in flight"
  - it says there are no external contributors (#1445 merged one)
  - its experimental row leaves out the Bumblebee reranker and GraphQL
    subscriptions
  - `KilnCMS.CMS.BlockUnion`'s moduledoc predates the storage flip
  - the threat model still says a password change doesn't revoke tokens
    (#734 fixed that)
  - `docs/observability.md` calls referrers and funnels unbuilt
  - `docs/beta-testing.md` has an unchecked box for a label that exists
- **Prepare beta round 1.** Write the exit criteria as numbers (below), and
  line up the testers.

### 0.11: first beta round

- **Run round 1 (#59)** against the published image, using the round shapes
  and scenarios A–G in `docs/beta-testing.md`. Every S1/S2 finding is fixed in
  this milestone.
- **Re-review the accepted security risks.** Go through the threat model's
  accepted residual risks one at a time and record, for each, whether it is
  still accepted at 1.0. The ones most worth deciding explicitly:
  - `TENANT_STRICT_HOST` ships off
  - `/live` events and `/ws/gql` subscription documents are not rate-limited
  - webhooks have no replay protection
  - `/api/ask` lets an anonymous caller drive LLM cost
- **External review of the authentication surface.** This is the one
  #1328 item that needs someone other than the maintainer, and it is the
  cheapest way to answer "bus factor one" for the parts that matter most.
- **Settle #1336** with the production telemetry #1364 added. Settling it
  may just mean closing it.

### 0.12: contract freeze (release candidate)

After 0.12, the covered list changes only by deprecation.

- **Retire the legacy block shape.** The column type has been `BlockUnion`
  since the storage flip, but conversion is lazy: legacy rows stay legacy at
  rest, and the editor and delivery still go through the legacy shape at the
  boundary. Backfill the rows, and run the block upcast path for real. The
  overlay contract calls it untested ("has never run in anger"), so it should
  run before a major version depends on it. Then deprecate the bridge:
  `TypedBlocks.to_legacy/1`, `RichText.legacy_html` and the editor's legacy
  sub-forms.
- **Deprecate what 1.0 will remove.** Candidates:
  - the ignored `published?:` option on `KilnCMS.CMS.Content`
  - the `:page`/`:post` editor route aliases
  - the legacy `User.audiences` fallback
  - old Oban job argument shapes

  Mark them with `@deprecated`, and put them under the project's first
  `### Deprecated` changelog section.
- **Decide HTTP API versioning.** [`docs/api.md`](api.md) says paths are
  unversioned, and that a breaking change would go under `/api/v1/…`. Decide
  now whether 1.0 ships `/api/v1` as the canonical prefix, rather than
  inventing it later under a deprecation window.
- **Decide field-level localization (#1327).** Content is currently one
  document per locale. Field-level localization touches the data model, so
  it either lands before the freeze or gets a design that can land after 1.0
  as an addition.
- **Rehearse an upgrade from every release so far.** On the example overlay,
  run `mix kiln.update` from each of v0.5.0 through v0.12.0 up to the
  candidate. The overlay-drift CI job proves the overlay compiles. It does
  not prove the upgrade path.
- **Run beta round 2.** Its result is the go/no-go for 1.0.
- **Make release candidates safe to tag.** Today, `kiln.update` picks the
  highest parseable tag, so a `v1.0.0-rc.1` tag would become every
  downstream project's default target. `release.yml` tags every push
  `latest`. Teach both to skip pre-releases before pushing the first RC tag.

### 1.0.0

- Remove what 0.12 deprecated. That is permitted here, because 1.0 is a
  major.
- `.github/SECURITY.md` names the supported release lines and the backport
  policy. Once a line is supported, `release.yml` can publish a floating
  `1.0` tag, which it deliberately does not do today.
- `docs/overlay-contract.md` drops its "Until 1.0" paragraph. The README
  stops saying "pre-1.0".
- Measure the project plan's own v1.0 success metrics and write the results
  down, including any that were missed:

  | Metric | Status today |
  |---|---|
  | An editor builds a page in under 5 minutes | Measured in beta |
  | Headless API p95 under 50 ms | No baseline recorded yet |
  | Test coverage over 80% | The CI floor is 85.8 |
  | Zero-downtime releases | Not yet shown |
  | Positive beta feedback | Measured in beta |

## Beta exit criteria (fill in before round 1)

`docs/beta-testing.md` says "no new S1/S2 on core flows and NPS trending
positive". That is right, but it is not yet a bar you can check. Pin it down
before round 1, so the rounds can't talk themselves past it:

- zero open S1 findings, and zero S2 findings on scenarios A–G;
- NPS at or above a number chosen now;
- at least N testers who are non-technical authors, across at least two
  rounds.

## Not needed for 1.0

Worth doing, but none of it changes what 1.0 promises, and all of it can
land in a 1.x minor as an addition:

- agentic editorial automation (#377)
- the plugin registry (#1447) and the runtime sandbox it defers to (#333)
- managed hosting (#334). Its first track, one-click deploy templates
  (#1529), doesn't depend on anything here and can ship in any release.
  Integration settings in the UI (#1322, in 0.10) are also something the
  hosted plan needs.
- graduating CRDT co-editing out of `:collab_prototype` (#1324)
- semantic search on by default, or an `-ml` image variant
- SSO with more than one identity provider
- the untracked editor polish in
  [`docs/competitive-gaps-todo.md`](competitive-gaps-todo.md): palette
  drag-to-place, and layout presets

## Decisions only the maintainer can make

These block milestones above. Each one is a question, not an engineering
task:

1. **The beta bar.** The NPS number and the tester count (0.10).
2. **Field-level localization:** before the freeze, or additive after 1.0
   (0.12).
3. **`/api/v1`:** at 1.0, or not until the first breaking change (0.12).
4. **The `TENANT_STRICT_HOST` default at 1.0.** It ships off today (0.11).
5. **Supported release lines, and their length** (1.0).
6. **Hex.** Stay submodule-only at 1.0, or publish the core. The README says
   it is not published, and nothing plans otherwise.
7. **Bus factor.** The README says "if that bus factor is a blocker for you,
   it should be". Decide whether 1.0 needs a second maintainer, or only the
   external review from 0.11.
