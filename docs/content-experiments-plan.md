# Content Experiments (A/B testing) — design

Goal: let an editor test two or more versions of *part* of a published document —
a headline, a hero block, a CTA — measure which converts better, and promote the
winner. Issue #499.

The differentiator case: most headless CMSs don't have this (Strapi, Payload and
Directus don't), it is enterprise-DXP territory, and Kiln can do it **with no
third-party script and no visitor tracking** — which is the marketing story as
much as the feature is.

This document is the architecture. It exists because the shape of the answer is
decided by four constraints that are not obvious until you go looking, and each
one rules out the design you would otherwise reach for first.

## The four constraints

### 1. The two delivery surfaces do not share a data shape

The headless path serves a **fired artifact** — `Firing.Engine.read/4` returns a
`%{"title" =>, "blocks" => [...]}` map.

The HTML path does **not**. `ContentController` renders live from the record's
block tree (`content_controller.ex:688`), because fragment expansion and media
enrichment happen per request against the live record.

So "apply the patch at delivery time" is two different operations against two
different shapes, and any design that assumes one patcher is wrong. The patch
format therefore has to be expressed in terms both can resolve — document
scalars by field name, blocks by their stable `_id` — rather than as a diff
against either representation.

### 2. A shared cache destroys the split, cookie or no cookie

A public page carries `public, max-age=60, stale-while-revalidate=300`
(`content_controller.ex:987`). Put a CDN in front of an experimented page and it
caches **one** variant and serves it to everyone for 60 seconds. The experiment
silently becomes a 100/0 split with a noisy conversion rate.

The ETag makes it worse: `etag/1` hashes `{id, updated_at, published_version_id}`
with no variant dimension, so a conditional request would 304 a visitor into
whichever variant the cache happens to hold.

**A page under a running experiment must not be shared-cached.** That is a real,
permanent cost of doing this server-side, and it is the reason experiments should
be scoped to the pages that need them rather than left running site-wide. The
precedent and the mechanism already exist — the paywall path sets
`private, no-store` and skips ETag for the same class of reason
(`content_controller.ex:505-509`, `:981`).

### 3. There is no visitor identity, and the project promises there won't be

`docs/data-flows.md` states plainly that **no cookie is recorded for visitors**;
`KilnCMS.Analytics` and `KilnCMSWeb.ViewTracking` repeat it. There is no visitor
cookie on the delivery path today — the only `put_resp_cookie` calls are auth.

A/B testing conventionally wants a sticky per-visitor key, and there is no way to
have one without storing something on the visitor. Rather than quietly break a
documented promise, v1 splits the difference along the grain of the two surfaces:

- **Built-in site: stateless.** A variant is chosen per request. Nothing is
  stored, nothing is tracked, the promise holds unchanged.
- **Headless: the caller's key.** `?variant_key=` in, chosen variant out. The
  caller already has a session, a user id, or an edge-assigned bucket; they own
  stickiness and Kiln stores nothing.

The cost is stated rather than hidden: **on the built-in site a visitor may see a
different variant on reload**, so goals that span a navigation cannot be
attributed there. A same-page goal — a form submission, which is the classic CTA
test — is unaffected, because the variant is baked into the page that carries the
form and travels with the submission.

A sticky first-party cookie is a reasonable thing to want and is deliberately
deferred to its own issue, where it gets its own privacy review, its own row in
`docs/data-flows.md`, and an explicit operator opt-in.

### 4. Nothing about a variant may reach an index

The issue's hardest requirement. Mapped against where each surface actually
reads:

| Surface | Reads | Variant-safe because |
|---|---|---|
| Sitemap | live record, `select: [:slug, :locale, :updated_at]` | never touches a body |
| Feeds | **fired `:web` artifact** | variants are never fired |
| llms.txt | live record metadata | never touches a body |
| tsvector | `search_text` column | variants never write it |
| Embeddings | live block tree | variants never merge into `record.blocks` |
| Meilisearch | live record fields, pushed on fire | variants are never fired |
| JSON-LD | **`record.title`, `seo_description`, …** | see below |

Two of those are only safe by construction, and both dictate implementation:

- **Variants are never fired.** No `PublishedArtifact` row is ever written for a
  variant. (This also avoids a nasty schema problem: that table's identity is
  `(org, document_type, document_id, surface)` and a nullable `variant_id` would
  either collide variant rows onto the base row's upsert or lose base-row
  uniqueness, since Postgres treats NULLs as distinct.)
- **The patch is applied to the rendered body only.** `render_content_body/6`
  builds SEO assigns and `:json_ld` from `record`, then renders the template with
  `record:` and `blocks:`. The variant is applied to *the last step only*. The
  canonical record still produces `<title>`, the meta description, the canonical
  URL and the schema.org graph.

That last rule is worth stating as a sentence because it is the whole exclusion
guarantee: **a variant changes what a human reads, never what a machine indexes.**

## Model

A new `KilnCMS.Experiments` domain. Three resources, all org-scoped on the
standard `multitenancy do strategy :attribute end` pattern.

### `Experiment`

Targets one document by `(content_type, document_id)` — a string type name and a
uuid, the same pair `ViewTracking` and the webhook payloads already use, so it
works for dynamic types without a foreign key per content resource.

State machine, modelled on `ContentRelease` (`content_release.ex:105`):

```
draft ──start──▶ running ──conclude──▶ concluded ──archive──▶ archived
  │                  │                     │
  └──────archive─────┴─────────────────────┘
```

`draft` is editable; `running` serves variants and accumulates results;
`concluded` records a `winner_variant_id` and stops serving; `archived` is the
audit trail. Concluding emits `experiment.concluded` through
`KilnCMS.Webhooks.dispatch/3` — the one funnel webhooks, automation and
federation already share — so an automation rule can react to it with no
executor change (the `"task"` precedent, `automation/rule.ex:24-30`).

Promotion of a winner is a **separate, explicit act**, not a side effect of
concluding: it writes the winning patch into the document through the ordinary
`:update` action, so it cuts a normal version, fires artifacts, and notifies
webhooks exactly as a human edit would. An experiment that concludes without
promotion has simply been measured.

### `Variant`

Belongs to an experiment. `name`, `weight` (integer, for uneven splits), and
`patch`:

```elixir
%{
  "fields" => %{"title" => "Ship faster with Kiln"},
  "blocks" => %{"3f2a…-uuid" => %{"text" => "Start free"}}
}
```

Sparse and additive. `fields` names document scalars; `blocks` is keyed by a
block's stable `_id` — the same identity the visual-editing bridge addresses and
the block union already carries — so a patch survives block reordering, which a
positional patch would not.

Exactly one variant per experiment is the **control**, whose patch is empty. It
exists as a row so results have something to compare against and so "the control
won" is expressible.

### `VariantDay`

Per-variant, per-day counters: `impressions`, `conversions`. Upserted on
`[:variant_id, :day]`, the same shape as `ContentViewDay` — and, like
`ReferrerDay` before it, an **additional** counter rather than a new dimension on
an existing one, so existing analytics stay comparable to their own history.

No per-visitor rows, no event log. Two integers per variant per day is all a
proportion test needs.

## Assignment

```
weight-proportional bucketing over the experiment's variants
  built-in site:  bucket = :rand.uniform(total_weight)     (stateless)
  headless:       bucket = phash2(variant_key) rem total_weight  (deterministic)
```

Deterministic on the headless path means the same `variant_key` always resolves
to the same variant, which is what makes a caller-side sticky assignment work and
what makes the response CDN-cacheable per variant.

**No key means no variant on the headless surface.** Drawing one at random there
would reintroduce constraint 2 on the one path that keeps its `public` caching:
a keyless request is one URL for every caller, so a CDN would cache whichever
arm the first caller drew. A caller who has not opted in gets the canonical
document.

That is also why headless needs no `Vary`: the key is a query parameter, so
every distinct key is already a distinct URL and a shared cache stores one entry
per arm on its own.

The chosen variant is surfaced either way — a hidden field injected into any
form block on the rendered page, and an `x-kiln-variant` response header on the
headless one.

## Measurement

**Impression** — recorded when a variant is served, on both surfaces, through the
existing async `Task.Supervisor` path `ViewTracking` uses so delivery never waits
on a counter.

**Conversion** — v1 supports two goals:

- `form_submission` — the form block on an experimented page carries the variant
  id as a hidden field, which travels back with the submission. Needs no visitor
  state at all, which is why it is the goal v1 ships.

  That field is **attacker-controlled**: it arrives on a public, CSRF-free POST.
  So a conversion is counted only when the id names a variant of a *running*
  experiment on this site **and** the submitted form is that experiment's goal
  form. Without the first check any uuid mints a `VariantDay` row — there is no
  foreign key on `variant_id` — and another site's id writes into their results.
  Without the second, every form on the site converts every arm: read a
  treatment id off any page and post it with an unrelated newsletter form.

  What remains is a visitor replaying the arm they were legitimately served,
  which is inherent to any client-reported conversion and is bounded by the form
  endpoint's rate limit. The point is that the blast radius stops at "an arm
  someone could see".

- `content_view` — **phase 3 (#984), and only with sticky assignment on.**
  Attributing a view that happens on a later page needs to know the visitor was
  *exposed*, which the stateless built-in site cannot know. `KilnCMS.Experiments.Sticky`
  supplies it: a second cookie recording which arm the visitor saw, cleared the
  moment it converts, so one exposure counts once.

  A bucket alone is **not** enough and this is the trap worth naming — every
  visitor has a bucket, so counting off the bucket would count people who never
  encountered the test.

  `:start` refuses a `content_view` experiment while `sticky` is off, or with no
  target document, or when the target *is* the experimented document (which
  would convert every impression on the view that created it). Rather than
  accept a goal that would silently never convert, it is refused at the only
  moment there is still someone to tell.

  **The cost, stated plainly:** the goal document also loses its shared cache
  while the experiment runs. The conversion is counted at the origin, so a CDN
  holding that page for `max-age=60` would swallow every conversion after the
  first — invariant 4 applied to a second page. A `content_view` experiment
  therefore takes *two* pages out of the CDN, not one.

- `funnel_completion` — **phase 3 (#1010).** The same mechanism one level of
  indirection out: the experiment names a funnel (#621) and converts on that
  funnel's **final step**, resolved at delivery time. So re-ordering the funnel
  moves the goal without anyone editing the experiment, which is the whole
  reason it is not just `content_view` pointed at a document.

  **What "completed" means here, since it is a decision and not an obvious
  one.** It means *reached the last step, having been exposed to the
  experiment*. It does **not** mean "walked every step in order". Kiln keeps no
  per-visitor journey — funnel step traffic is derived from aggregate
  `content_view_days` buckets precisely so that it does not have to — and
  reconstructing an ordered path would need per-visitor step state in the
  cookie, which is exactly the identifying payload #984 was built to avoid. A
  visitor who lands on the last step directly converts. That is a real
  limitation and it is the honest one to take.

  Same costs and same guards as `content_view`: the final step leaves the shared
  cache, and `:start` refuses a missing funnel, a funnel from another site, one
  with no steps, one whose last step is the experimented document, or sticky
  being off. Each of those is also re-checked at read time by
  `Experiments.blocked_reason/1` (#1008), because editing the funnel edits the
  goal and no funnel write knows an experiment depends on it.

  The funnel's final step is read from its own per-site cache
  (`Experiments.funnel_targets/1`) rather than queried per request — this runs
  for every running funnel experiment on **every** content page view, so a query
  here would be a query per page view site-wide. That cache is busted on any
  funnel or funnel-step write, so re-ordering a funnel moves the goal on the
  next request; the TTL is a backstop, not the freshness signal.

  The self-conversion guard is enforced **twice**, and that is a consequence of
  the indirection rather than caution. `:start` refuses a funnel whose last step
  is the experimented document, but editing the funnel afterwards can reach that
  state and no funnel write knows an experiment exists — so delivery refuses it
  too. Unguarded it is not a small error: the exposure is written and read back
  on the same conn, so the impression would convert itself within one request
  and every arm would report 100% forever.

Results are a proportion comparison with a stated confidence, not a dashboard of
knobs. No sequential testing, no peeking correction, no p-hacking surface — a
sample-size floor below which the panel refuses to declare anything is worth more
than another statistic.

## Exclusions, restated as invariants

1. A variant is never fired, so it cannot reach a feed, Meilisearch, or a
   `:json_ld` artifact.
2. A variant never writes `search_text`, `embedding`, or `record.blocks`, so it
   cannot reach tsvector, block embeddings, or related content.
3. A variant is applied after SEO assigns and `:json_ld` are built, so it cannot
   reach `<title>`, the meta description, the canonical URL, or the schema.org
   graph.
4. A page serving a variant is never shared-cached.
5. A variant is stored on its own resource, never as an attribute on the content
   record — so it cannot cut a version, bump `updated_at`, take the optimistic
   lock, notify webhooks, or trigger a re-fire. (`ignore_attributes` would not
   have helped: it removes an attribute from the version's `changes` map but
   still cuts the row. Only `ignore_actions` prevents that, and a separate
   resource is cleaner than a fourth carve-out action.)

Each of these has a test whose name is the invariant, and the exclusions are
asserted against the real surfaces — the sitemap, a feed, `llms.txt`, the fired
`:web` artifact a feed reads, and the artifact row count — rather than argued
for in prose.

Two more guards fall out of the same reasoning, both about keeping a result
readable rather than about leakage:

6. **A running experiment's variants are immutable.** Adding an arm changes the
   weight total and re-buckets every keyed visitor; removing one orphans its
   counters; rebalancing makes counts before and after incomparable. None of
   these announces itself, because the counters are integers that keep going up
   either way.
7. **One running experiment per document**, enforced by a partial unique index
   rather than a read — two concurrent starts would both pass a check-then-act,
   and two overlapping patches make both results uninterpretable.

## Phasing

**Phase 1 — the engine** (this PR)

Resources, lifecycle, patch application on both delivery surfaces, stateless and
keyed assignment, impression/conversion counters, the `form_submission` goal, the
`experiment.concluded` event, and the five invariants above with tests. A mix
task (`mix kiln.experiment`) to create, start and conclude, so the engine is
operable before there is a UI — the alternative is shipping something inert.

**Phase 2 — the editor**

`/editor/experiments`: create an experiment against a document, author variants
against the real block tree, watch results, promote a winner. This is where the
feature becomes usable by the people it is for.

**Phase 3 — measurement depth**

The sticky-assignment cookie and the `content_view` goal on top of it — **done**
(#984) and funnel-completion on top of it (#1010); see
[`data-flows.md`](data-flows.md#sticky-assignment-cookie-984) for what is stored
and why. Surfacing an experiment that can no longer convert is **done** (#1008) — see
below. Still open: a results panel with a sample-size floor (#982) and bounding
conversion abuse on the new GET path (#1007).

### Health: an experiment that can no longer convert (#1008)

`:start` refuses an experiment whose goal can never fire, and that check cannot
be made to hold afterwards. Every premise it rests on is revocable while the
experiment runs: `sticky` is a config flag an operator is *invited* to gate on
their consent mechanism, and the goal form, the goal document and the funnel's
last step are all rows an editor can delete without ever seeing the experiment
that depends on them.

Delivery already refused to serve an arm it could not attribute, so nothing was
being measured wrongly. The gap was that nothing **said so**: the experiment
read `running`, impressions sat where they were, and a flat result is
indistinguishable from a genuine null.

`KilnCMS.Experiments.blocked_reason/1` is the one runtime statement of that rule
— read live, not recorded at `:start` — and it is surfaced on the two places an
operator looks: a `!` line under the row in `mix kiln.experiment list`, a
`Blocked:` line **above the variant counters** in `show` (the numbers below it
are not a result), and an admin-only strip on `/editor/overview`. When #982
lands, the results panel is the third caller, and it should phrase its own
sentence from the reason atom rather than print the terminal one.

**Deliberately not planned:** per-visitor personalization rules, multi-armed
bandits, traffic allocation ramps, and anything that needs a visitor profile.
Those are a different product, and the privacy posture is the reason this one is
interesting.
