# Path forward: right, everywhere, provably

Written on 2026-10-10, against v1.1.0. This page says **what Kiln is for**
from here on, **why that changed**, and **the order of releases** that get
there. Like [roadmap-1.0.md](roadmap-1.0.md), it does not track status: the
[issue tracker](https://github.com/The-Verscienta/kiln_cms/issues) holds that
under the `wedge` label, and when this page and an issue disagree, the issue
wins and this page needs editing.

## Summary

Kiln stops being "a CMS written in Elixir" and becomes **the CMS for content
that must be right: published everywhere in seconds, with proof of who changed
it, who approved it, and what every reader saw at any moment.**

- Two wedges, one story: **live content delivery** and **self-hosted,
  auditable, governed** publishing. Each makes the other credible.
- Most of the governance half is built (signed history anchors, `?as_of=`
  point-in-time reads, the governance dashboard, claim checking). The live
  half is the gap, and it is smaller than it looks.
- Everything is additive under the 1.0 [overlay contract](overlay-contract.md).
  Verscienta.com and holisticacupuncture.net keep working unchanged.
- Breadth stops. Features outside the wedge are frozen (kept, maintained,
  not extended) until the wedge is proven on a real site.
- Three majors as milestones: **2.0 Provable publishing**, **3.0 Live
  delivery**, **4.0 Governed at scale**. Each major also lands the breaking
  changes already queued, so a major still means what the contract says.

## Where Kiln is today

Kiln is at v1.1.0 (shipped 2026-10-06), under a frozen overlay contract, with
two production consumers and one scaffold.

| Area | State |
|---|---|
| Core | Ash + Phoenix 1.8 + LiveView, Postgres-only stack (D1–D8), JSON:API + GraphQL for every resource, embedded block trees |
| Governance, built | Hash-chained signed history anchors (Merkle + witness), `?as_of=` [point-in-time](point-in-time.md) delivery with a distinct `withdrawn` answer, [governance dashboard](governance-dashboard.md) with JSON/CSV trail export, [claim checking](compliance.md) that can refuse a publish, [provenance](provenance.md) signing of fired artifacts (off by default) |
| Delivery, built | Immutable pre-fired artifacts, [delivery that survives a Postgres outage](resilient-delivery.md) for warm content, tag-based CDN purge, [static export](static-export.md), signed [webhooks](webhooks.md) with a delivery ledger |
| Real-time, built | Presence, live field-focus cursors, field locks with takeover, live preview and pop-out preview over PubSub |
| Real-time, not shipped | CRDT co-editing behind `:collab_prototype` (dev/test only); GraphQL subscriptions over `/ws/gql` labelled experimental |
| Measured | Delivery p95 under 7 ms at 50 clients; JSON:API list 40–43 ms; search misses the 50 ms target under load; no WebSocket or fan-out numbers at all ([benchmarks](benchmarks.md)) |
| Beta | 10 testers, all built a page in under 5 minutes, rated about B+ |

**Who runs on it**

- **Verscienta.com**: a separate Phoenix LiveView site over Kiln, plus mobile
  apps. Clinical content: herb–drug interactions, contraindications, dosing.
  Reads through `KilnClient`, caches in ETS for up to 6 hours, and drops
  entries on Kiln's signed webhooks.
- **holisticacupuncture.net**: Astro 5 on Cloudflare Pages, static plus a
  server-rendered blog, reading JSON:API and `/api/content`. A webhook
  triggers rebuilds and IndexNow.
- **verscienta-news**: a SvelteKit scaffold on the v1.0.0 submodule, already
  pulling in Phoenix Channels and Presence. The natural live-delivery
  showcase.

## Why we are changing direction

Kiln has shipped about 1,900 pull requests and a 1.0, and still has no
sentence that tells a buyer why to pick it. That is the problem, not the
language.

**Breadth without a wedge.** The repo covers releases, newsletters,
memberships, forms, federation, compliance reports, a plugin registry, a
marketing site and a hosted-offering plan. Each is reasonable alone. Together
they read as a pile of features, with nothing to point at and say "this is
what it is for."

**"A CMS in Elixir" is a technology claim.** Users don't choose a CMS by its
language. Elixir is the right stack for this product, but it is a reason the
product *can* be good, not a reason to buy it. Switching languages would throw
away the work and compete head-on with Payload and Strapi on their home
ground.

**Co-editing was the obvious wedge and it is the wrong one.** Google-Docs-style
editing is the best case for LiveView and PubSub, but Sanity already owns it,
editorial teams rarely edit the same field at once, and Kiln's CRDT prototype
is still off in production. Making it the centrepiece means a year of risky
work for a feature most buyers don't rank.

**The real sites point somewhere else.** Verscienta.com serves herb–drug
interactions and contraindications. When a safety correction ships, the
questions that matter are: did every page update, who approved it, and can we
prove when readers saw the fix? Both live sites already solve freshness with
webhooks; what they lack is a *guarantee* and a *record*. Kiln has most of
that record built and unmarketed.

**The asymmetry is real and unused.** Immutable fired artifacts, a dependency
graph that re-fires dependents, PaperTrail history, signed anchors, and a BEAM
that holds a very large number of open connections cheaply. A Node or PHP CMS
renders from a mutable database on every request and cannot offer "what was
live at 14:03, provably" or "every open page updated in two seconds" without
heavy custom work. Kiln can, and today says so in six separate docs that
nobody reads together.

## The new direction

**Kiln is the CMS for content that has to be right.** Content updates
everywhere in seconds, with a record of who changed it, who approved it, and
exactly what was live at any moment.

The two halves depend on each other. "Live" without governance is a liability:
a fast way to push a mistake to everyone. Governance without "live" is
paperwork: a trail that proves the wrong version was served for twenty
minutes. Together they answer the question a regulated or
reputation-sensitive publisher actually asks: *when we fix something, is it
fixed everywhere, and can we show that?*

**Who it is for**

- Health, finance and legal publishers whose content carries safety or
  compliance weight (Verscienta.com is the first).
- Newsrooms and public bodies that issue corrections, retractions and notices.
- Teams that cannot use SaaS CMSs and need one container plus Postgres with an
  audit story they can hand to a reviewer.
- Developers building live-updating frontends who want a change feed, not a
  polling budget.

**What we will not claim**: co-editing as a headline (it stays a prototype
until it earns a release), AI features as a differentiator, or feature parity
with WordPress.

### The demo that proves it

The acceptance test for everything below.

1. An editor publishes a safety correction to a herb entry on a staging copy
   of Verscienta.com.
2. A reader's already-open page updates within a stated number of seconds, as
   does the formula page that lists that herb.
3. The editor retracts the entry. Every open page and every cached copy drops
   it, within a stated number of seconds.
4. The governance view shows who approved each step, when each reader surface
   updated, and `?as_of=` serves exactly what a reader saw at any instant in
   between, with a verifiable signature.

If a release does not move one of those four lines, it is not on the wedge.

## What changes and what does not

**Does not change**

- **The 1.0 overlay contract.** Every covered surface keeps working. A major
  still means an overlay needs code changes, never "a big release."
- **The webhook payload shape and signing scheme.** Both production sites
  verify `x-kilncms-webhook-signature` and read `type`, `verb`, `id`, `slug`.
  New fields are added; none are renamed or removed.
- **`/api/content/:type/:slug`, the `/published` JSON:API twins, share-preview
  tokens, `/api/sync`.** These are what the sites read. Changes to cache
  headers on these routes are tested against both sites on staging before
  merge.
- **The architecture decisions D1–D8.** Native PubSub, embedded blocks,
  Postgres-centric. The wedge is an argument *for* them.
- **Self-hosting as the default.** One container plus Postgres stays the
  install story.

**Changes**

- **Positioning.** README tagline, kilncms.dev hero, and the docs index lead
  with the wedge. The six governance and delivery docs are gathered under one
  "Right, everywhere, provably" guide.
- **Prioritisation.** The issue tracker has a `wedge` label. Work carrying it
  goes first; work without it waits for a bug, a security finding, or a
  production site asking. Frozen areas carry `frozen`.
- **Definition of done for releases.** Each minor names which line of the
  demo it moves and the number it changed (seconds, connections, bytes).
- **Measurement becomes a feature.** [benchmarks.md](benchmarks.md) gains a
  live-delivery table: propagation latency, fan-out, connection counts.
  Numbers we cannot show, we do not claim.
- **Co-editing is explicitly deferred.** The prototype stays in the tree
  behind its flag, labelled as now, with no roadmap slot until 4.0 at the
  earliest.

**Effect on the production sites**

| Site | Immediate effect | What it gains |
|---|---|---|
| Verscienta.com | None; additive only | Dependent-page invalidation in the webhook (today a formula page listing an edited herb waits out a 10-minute TTL), a retraction guarantee, and a governance view for clinical corrections |
| holisticacupuncture.net | None; additive only | Fewer full rebuilds: the change feed names exactly what changed, so the Astro build can rebuild one page |
| verscienta-news | Becomes the live showcase | The public change-feed channel and the JS client's subscribe helper are built against it |

## What to look forward to

In order of arrival. Each item is something you can show, not a refactor.

1. **Webhooks that name everything a change touched.** A herb edit tells
   Verscienta.com about the formula pages that list it.
2. **A retraction that cannot be lost.** Auto-disable never silences
   `unpublished` and `archived`; a retraction that fails to deliver is
   escalated, not dropped.
3. **The first number: unpublish to last reader.** Measured end to end, CDN
   purge included, and printed on the benchmarks page.
4. **"What readers saw" in the governance view.** One timeline per document:
   every publish, every approval, every surface's update time, every
   `?as_of=` link, and the anchor's signature verdict.
5. **Provenance on by default.** Every published artifact carries a verifiable
   signature out of the box, with a one-line `verify` endpoint a reviewer can
   curl.
6. **A public change feed.** Anonymous-safe, published-content-only, over SSE
   and Phoenix Channels, carrying `published`, `updated`, `withdrawn`.
7. **`kiln.subscribe()` in the JS client and `KilnClient.subscribe/2` in
   Elixir.** A frontend becomes live in one call.
8. **Fan-out numbers you can quote.** Open connections per node, propagation
   p95 at 1k, 10k and 50k subscribers, with the script that produced them.
9. **A reviewer-ready compliance export.** The governance trail plus the
   signature chain as one signed bundle, verifiable offline.
10. **verscienta-news as the showcase.** A live wellness news site where
    corrections land on open pages while you watch, and every one has its
    trail.

## Release plan overview

The wedge ships in minors. Majors are milestones that also carry the breaking
changes already queued, so a major keeps meaning what the contract says: an
overlay needs code changes.

**Versioning rules, unchanged from [releasing.md](releasing.md)**

- **Major** = the overlay contract broke. Never "a big release."
  `mix kiln.update` refuses a major jump without `--allow-major`, and that
  flag must keep meaning "your subproject needs work."
- **Minor** = new capability, overlays keep compiling, may add migrations.
  All wedge work fits here.
- **Patch** = fixes only.
- Migrations stay expand/contract across releases; `mix kiln.migrations.check`
  enforces it. Every release goes `-rc.1` then final, with the upgrade
  rehearsal green.

**Why three majors, then.** The `v2.0.0` milestone already holds two items
that change a covered surface: #1595 (collapse Category and Tag into one
hierarchical vocabulary) and #1529 (one-click deploy templates, which fix
runtime defaults). 2.0 lands those alongside the first wedge milestone. 3.0
and 4.0 each get a short, explicit list of breaking changes gathered during
the preceding minors; if nothing breaking has accumulated, the milestone
ships as a minor and the name moves.

**Cadence.** The 0.12 to 1.1 run shipped a release every one to two weeks.
Wedge minors each carry a measured number, so plan on two to four weeks per
minor, and a major about every four to six minors.

**Definition of done for every minor**: which demo line it moves, the number
before and after, and a staging run against Verscienta.com for anything
touching delivery routes or cache headers.

| Major | Minors before it | Gate (a passing demo line, not a date) |
|---|---|---|
| 2.0 Provable publishing | 1.2 to 1.7 | Demo lines 1 and 4 pass on Verscienta.com staging |
| 3.0 Live delivery | 2.1 to 2.6 | Demo lines 2 and 3 pass; fan-out numbers published |
| 4.0 Governed at scale | 3.1 to 3.6 | A reviewer outside the project verifies a signed bundle offline |

## v2.0: Provable publishing

**Promise:** a correction reaches every page a production site serves within
a stated number of seconds, a retraction cannot be silently lost, and the
governance view shows what every reader saw and when. Pilot site:
Verscienta.com.

| Release | Ships | Demo line | Number it produces |
|---|---|---|---|
| 1.2 | A failing test for "an anonymous subscriber is told when a record leaves visibility", then the fix. Webhook payloads gain `affected: [{type, id, slug}]` from the firing dependency graph (additive field). `KilnClient` and `@kiln-cms/client` expose it. | 2 | Dependent pages invalidated per publish |
| 1.3 | Retraction guarantee: `unpublished`, `archived` and `deleted` deliveries are exempt from endpoint auto-disable, retried on their own longer schedule, and surfaced in the console and in `/editor/governance` when they exhaust retries. Webhook ledger gains a `delivered_at` per endpoint. | 3 | Retraction deliveries lost: must be 0 |
| 1.4 | End-to-end latency measurement: publish and unpublish timestamps, CDN purge acknowledgement, and each webhook endpoint's `delivered_at`, rolled into one `propagation` record per transition. First number on benchmarks.md. | 2, 3 | Unpublish-to-last-endpoint p95, in seconds |
| 1.5 | "What readers saw" timeline in the governance detail view: every transition, its approver, its propagation record, its `?as_of=` link, and the chain verdict, on one line each. CSV/JSON export carries the same. Headless draft mode (#1887) so a front end can show the draft side of the same timeline. | 4 | Makes 1.4's number visible |
| 1.6 | Provenance on by default: a signing key is generated at `/setup`, every fired artifact carries a manifest, and `GET /api/provenance/verify/:type/:slug` answers `verified`, `tampered` or `unsigned`. Existing installs without a key keep `unsigned` and a console banner. | 4 | Share of published artifacts signed |
| 1.7 | Wedge positioning: README, kilncms.dev hero, docs index, and one combined guide replacing six scattered pages as the entry point. No code. | all | None |
| 2.0 | The 1.x deprecations removed. #1595 taxonomy collapse with its migration and upgrade note. #1529 one-click deploy templates with the runtime defaults they need. `--allow-major` note written first. | gate | Demo lines 1 and 4 pass on staging, recorded |

**Exit criteria for 2.0**

- Demo lines 1 and 4 pass on a staging copy of Verscienta.com, recorded as a
  two-minute screen capture linked from the README.
- benchmarks.md carries unpublish-to-last-endpoint p95 for Verscienta.com's
  endpoint set.
- Zero retraction deliveries lost across the 1.3 to 1.7 soak period on
  Verscienta.com production.
- Both production sites upgraded through every 1.x minor without an overlay
  change.
- #1595 and #1529 shipped with upgrade notes rehearsed by the upgrade
  workflow.

## v3.0: Live delivery

**Promise:** any frontend becomes live in one call. Published content changes
reach open pages in seconds without polling, the numbers are published, and
verscienta-news runs on it in production. Pilot site: verscienta-news, with
Verscienta.com as the second consumer.

| Release | Ships | Demo line | Number it produces |
|---|---|---|---|
| 2.1 | Public change feed, server side: `KilnCMS.Delivery.Feed` publishes `published`, `updated`, `withdrawn` events (type, id, slug, published_at, affected) per site over PubSub, from the same transition the webhooks use. Anonymous-safe by construction: the event carries identifiers, never content; the client fetches through the existing cached delivery routes. | 2 | Feed events per transition |
| 2.2 | Two transports over the one feed: `GET /api/feed` as SSE with `Last-Event-ID` resume, and a `feed:<site>` Phoenix Channel on a new `/ws/feed` socket. Both charged by `SocketJoinBudget`, tenant-resolved from the host like `/ws/gql`. Covered from 2.2, not experimental. | 2 | Resume window, stated |
| 2.3 | `kiln.subscribe({types, onChange})` in `@kiln-cms/client` and `KilnClient.subscribe/2` in Elixir, with reconnect and resume. verscienta-news wired to it. | 2 | Publish-to-open-page p95 on verscienta-news |
| 2.4 | Fan-out benchmark: a script under `scripts/benchmarks/` opens 1k, 10k and 50k feed subscribers on one node and measures propagation p95 and memory per connection. Published with the hardware named. | 2 | Connections per node; propagation p95 per tier |
| 2.5 | Withdrawal on open pages: the clients expose `withdrawn` so a page can blank or redirect, and Verscienta.com's cache invalidation reads the feed as a second source beside webhooks. The 1.4 number now ends at "last open page". | 3 | Unpublish-to-last-open-page p95 |
| 2.6 | Cache contract for live: `/api/content` responses carry a `kiln-feed-cursor` header; the headless consumer guide documents the one pattern (cache aggressively, invalidate from the feed); static export emits the cursor so an Astro build can ask "what changed since". | 2 | Pages rebuilt per change on holisticacupuncture.net |
| 3.0 | Breaking changes gathered during 2.x, if any; GraphQL subscriptions over `/ws/gql` either promoted to covered on the feed's back or withdrawn in favour of it, with a deprecation first. | gate | Demo lines 2 and 3 pass; fan-out table published |

**Exit criteria for 3.0**

- Demo lines 2 and 3 pass on verscienta-news in production and on
  Verscienta.com staging, recorded.
- benchmarks.md shows propagation p95 at 1k, 10k and 50k subscribers on named
  hardware.
- Unpublish-to-last-open-page p95 is a published number, not a claim.
- holisticacupuncture.net rebuilds one page per change instead of the site.
- The feed has been covered for at least two minors with no shape change.

## v4.0: Governed at scale

**Promise:** an outside reviewer can verify Kiln's record without trusting the
Kiln install, the guarantees hold across a multi-node cluster, and approval
rules are policy, not convention. This is the release that turns the wedge
from "works for us" into "a regulated team can adopt it."

| Release | Ships | Demo line | Number it produces |
|---|---|---|---|
| 3.1 | Signed compliance bundle: `mix kiln.governance.export <type> <id>` and the dashboard's export produce one archive holding the trail, the version rows, the anchors, the propagation records and the public key, plus a standalone `kiln-verify` script (no Kiln needed) that checks the chain offline. | 4 | Bundles verified offline, with a published test vector |
| 3.2 | Multi-node feed and propagation: correct under `libcluster` with two or more nodes; resume works across a node restart; the fan-out benchmark re-run on two nodes. | 2, 3 | Propagation p95 on a 2-node cluster |
| 3.3 | Approval policies per content type: "needs N approvers from role R before publish", enforced as an Ash policy on the publish transition, recorded on the trail. Claim checking's `refuse to publish` becomes one such policy. | 4 | Publishes blocked by policy, by reason |
| 3.4 | Witnessing: anchors can be countersigned by an external witness (a second Kiln, or an RFC 3161 timestamp authority). Off by default, one config block to enable. | 4 | Anchors with an external countersignature |
| 3.5 | Reader-side verification: `bridge.js` and the JS client can fetch an artifact's manifest and show a "verified, signed by X at T" mark; the public theme ships an optional badge component. | 4 | Makes 1.6 visible to readers |
| 3.6 | Co-editing decision: decide whether the CRDT prototype gets a release behind a per-site setting or is removed. Either way, the VM-global `:collab_prototype` flag goes. | none | None |
| 4.0 | Breaking changes gathered during 3.x: the flag removal if it means a covered config key, and anything 3.3 forced on the workflow action names. | gate | A reviewer outside the project verifies a bundle offline |

**Exit criteria for 4.0**

- Someone who is not the maintainer verifies a Verscienta.com compliance
  bundle offline using only the published script and public key.
- All 2.x and 3.x numbers hold on a two-node cluster.
- At least one content type on Verscienta.com publishes under an N-approver
  policy in production.
- `:collab_prototype` no longer exists.
- A second organisation outside Verscienta runs Kiln for the wedge, or the
  plan is revisited.

## Frozen and deprecated

Frozen means kept, maintained and documented, but not extended. A frozen area
gets a PR for a bug, a security finding, a dependency advisory, or a
production site asking. It does not get a feature. The freeze lifts per area
when the 2.0 gate passes and a wedge consumer needs it.

| Area | Status | Why |
|---|---|---|
| Newsletters, direct email delivery, memberships and paywall | Frozen | Working and used; the "Ghost play" is a different wedge |
| Forms and form builder | Frozen | Used by holisticacupuncture.net; stable |
| Federation (ActivityPub), social posting, A/B experiments | Frozen | Distribution features with no wedge consumer |
| AI assist, RAG `/api/ask`, semantic search, reranker | Frozen; stays `KILN_ML=1` opt-in | Not a differentiator against funded competitors |
| Plugin registry and marketplace plans | Frozen | Ecosystem work only pays once there are users to serve |
| Hosted offering plan (#334) | Closed, except #1529 | One-click self-hosting is on the wedge; a hosted service is not, yet |
| Mobile admin spike, content experiments plan | Frozen | No wedge line moves |
| Marketing site kilncms.dev | Repositioned in 1.7, then frozen | No further pages until 2.0 |
| CRDT co-editing (`:collab_prototype`) | Experimental, no roadmap slot until 3.6 | The wrong wedge; decided in 3.6, not before |
| GraphQL subscriptions over `/ws/gql` | Experimental until 3.0, then promoted or deprecated | The change feed is the covered real-time surface |

**Deprecations planned**

- Nothing in 1.x. Every covered surface keeps working through 2.0 except what
  the `v2.0.0` milestone already names (#1595).
- The `/ws/gql` subscription DSL may be deprecated in 2.x once the feed is
  covered, removed no earlier than 3.0, with a compiler-visible marker for at
  least one minor, per the overlay contract's policy.

## Risks and open questions

| Risk | Likelihood | What we do |
|---|---|---|
| Retraction events never reach anonymous subscribers because the policy-scoped read drops a record that left visibility | Unverified; plausible from the code | 1.2 starts with the failing test. If it is a design problem, the feed carries identifiers only (2.1 already assumes this) and the fix moves earlier |
| Two half-built things instead of one product | High if the demo is not enforced | Every minor names its demo line and number; a minor that moves none is not cut |
| Fan-out numbers disappoint at 50k subscribers | Low to medium | 2.4 publishes what it finds; the claim is sized to the number |
| The freeze breaks a production site that quietly depends on a frozen area | Low; both sites are read and their dependencies listed | Frozen areas still get bug fixes; the sites are on the upgrade rehearsal |
| Provenance on by default surprises existing installs | Medium | 1.6 keeps unsigned installs working with a banner; no artifact is refused |
| Market is small: few teams know they want "provable" until an incident | Medium | The second organisation in the 4.0 exit criteria is the test; if not found by 3.x, the positioning is revisited before 4.0 |
| Solo-maintainer bandwidth across 21 minors | High | Each minor is one PR-sized change plus a number; majors slip rather than minors growing |

**Open questions**

- Does Verscienta.com need the feed at all, or does the richer webhook (1.2)
  cover it? Decide after 1.4's number.
- How long should `/api/feed` replay on resume: one hour, one day, or until
  the next full publish?
- Which external witness for 3.4: a second Kiln, an RFC 3161 timestamp
  authority, or both?
- Is holisticacupuncture.net's one-page rebuild worth doing in Astro, or does
  it stay on full rebuilds and simply benefit from fewer triggers?
- What does the second organisation look like: another health publisher, a
  public body, a newsroom? This shapes 3.3's approval model.

**How we'll know it's working**

1. Three numbers exist that did not before: unpublish-to-last-endpoint p95,
   publish-to-open-page p95, and connections per node. Each is on
   benchmarks.md with the script that produced it.
2. The README's first sentence can be said in a meeting without explaining
   Elixir.
3. A clinical correction on Verscienta.com has been traced end to end in the
   governance view, and the trace was useful to a human.
4. Someone outside the project has verified a bundle.
5. The maintainer can name, in one sentence, why the next PR matters.
