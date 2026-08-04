# Advanced Content Analytics — Design

**Status: design only (issue #62, *[Stretch]*).** Per-phase status lives in one
place — the [phase table](#phased-plan) — so this document does not go stale the
first time a slice ships.

It plans the extension of the shipped privacy-first analytics — currently *view
counts and search queries* — with **referrer attribution**, **content funnels**,
and **export**, in slices that are independently mergeable and default to off.

Companion reading: [`data-flows.md`](./data-flows.md) (what is stored and for
how long, operator-facing), [`observability.md`](./observability.md) (the
telemetry conventions this builds on), and
[`governance-dashboard.md`](./governance-dashboard.md) (the export precedent
this reuses).

---

## Current state (baseline)

Everything in this section is on `main` today; the design starts from it.

**Domain — `KilnCMS.Analytics` (`lib/kiln_cms/analytics.ex`), three resources:**

| Resource | Table | Grain | Written by | Retention |
|---|---|---|---|---|
| `ContentView` | `content_views` | one row per `(org, type, id)`, all-time | content delivery | never purged |
| `ContentViewDay` | `content_view_days` | one row per `(org, type, id, UTC day)` | content delivery | 400 days (#45) |
| `SearchQuery` | `search_queries` | one row per `(org, query, locale)` | the editor search palette | 90 days (#213) |

Shared shape — the parts every resource proposed below should copy, with the
differences that already exist between the three spelled out so nothing is
copied blind:

- **Upsert-a-counter, never an event log.** `create :record` with
  `upsert?: true` + `change atomic_update(<counter>, expr(<counter> + 1))`. The
  counter is `views` on the two view resources and `count` on `SearchQuery`.
  There is no row that represents one request, so there is nothing per-visitor
  to leak.
- **Policies:** `bypass OrgAdmin` → allow; `policy action_type(:read)` →
  `OrgEditor`; `policy action_type(:create)` → `forbid_if always()`, because
  writes arrive only from trusted in-app paths with `authorize?: false` (content
  delivery for views, `KilnCMS.Search` for queries). The two resources that have
  a retention job add a `bypass AshOban.Checks.AshObanInteraction` on top;
  `ContentView` has neither, since it is never purged.
- **Multitenancy** by `org_id` attribute, `global?` driven by `:strict_tenancy`,
  with `org_id` folded into every identity so counters can't collide across
  sites.

**Ingestion — `ContentController.track_view/3`**
([`content_controller.ex:810`](../lib/kiln_cms_web/controllers/content_controller.ex)):

1. Emits `[:kiln_cms, :analytics, :view]` **synchronously** (in-process, no IO,
   stays in the request's OTel span).
2. Dispatches **both** DB upserts into **one** `KilnCMS.TaskSupervisor` child —
   unlinked and best-effort, so a slow pool can't queue page delivery, and a
   spike sheds the whole task (`{:error, :max_children}`, cap 100) instead of
   exhausting the pool. One task for both writes is deliberate: overload drops
   them together, so the counters under-count consistently instead of drifting
   apart.
3. `:async_analytics` is `false` in test only, so the upsert stays on the
   sandbox-owned connection.

**Dashboard — `KilnCMSWeb.AnalyticsLive`** at `/editor/analytics`, inside the
`:editor_routes` live session: total views (DB-side `Ash.sum`), a 7d/30d trend
held in the URL (`?range=`), an inline-SVG `bar_chart/1`, and the top 50 items
with a window column. The window read (`ContentViewDay.:in_window`) is folded
into a series **in Elixir** — Ash 3.x read actions have no `group_by`. Rows are
made legible by a separate id-batched title lookup per content type that
tolerates since-deleted content.

### What the baseline cannot answer

- *Where did readers come from?* — nothing is recorded about arrival.
- *Did readers move from A to B to C?* — no ordering, no path data.
- *Can I get this out of the browser?* — no export; the numbers are
  screen-only.

Those three gaps are exactly this document's scope.

---

## Privacy constraints (hard requirements)

Non-negotiable, and the reason this is not "add Google Analytics". Every schema
choice below follows from them.

- **No visitor PII, ever.** No IP addresses, user agents, user ids, session ids,
  or device data. (Note the one existing exception to "no PII at all": free-text
  `search_queries` can incidentally contain names or confidential titles, which
  is why they have their own 90-day clock. Nothing proposed here adds free text,
  and [Export](#3-export) deliberately excludes that table.)
- **No per-visitor rows.** Counters and bucketed aggregates only. Nothing
  correlates two requests as coming from the same person.
- **No cookies, no local storage, no fingerprinting, no client beacon.**
  Ingestion is server-side. Nothing is written to the visitor's browser.
- **No raw referrer URLs.** The `referer` header is reduced to a small
  allow-listed category *in the web layer*; scheme, path, query and fragment are
  discarded before anything crosses into `KilnCMS.Analytics`.
- **Aggregate funnels only.** Step counts, not followed journeys — see
  [Funnels](#2-funnels).

Consequence, stated honestly: KilnCMS **cannot** report unique visitors, bounce
rate, session duration, or an individual's path. Those metrics require visitor
identity that this design refuses to collect. What is offered instead is
*population* trend, *coarse* attribution, and *ratio* funnels.

### Where "aggregate" gets thin: low counts

"Aggregate" is a property of volume, not of schema. A `(content_id, :other,
day, hits: 1)` row *is* a single request with a coarse referrer attached, and on
a page with one view that day it describes one person's arrival. The same holds
for a `count: 1` step in a funnel. This does not make the data personal — there
is still no identifier, and nothing links that row to any other — but it does
mean the guarantee is "nothing identifying is stored", not "nothing about an
individual can be inferred".

Two mitigations, both cheap, both required of any phase that ships a breakdown:

- **Suppress low counts in the UI and in export.** Render (and export) a
  category or step below a small threshold as `< n` rather than an exact count.
  The threshold is config, defaulting to something like 5.
- **Never combine a breakdown with a time grain finer than a day.** Hourly
  buckets would make thin cells the norm rather than the exception; day grain is
  the finest this design goes, for that reason as well as for storage.

### Accuracy caveats (true of the baseline, inherited by everything below)

These are not defects to fix later; they are properties of server-side,
privacy-first counting, and the dashboard should say so where it matters.

| Cause | Effect |
|---|---|
| Public pages ship `cache-control: public, max-age=60, stale-while-revalidate=300` | A CDN or proxy absorbs repeat hits — counts undercount edge-served traffic |
| The write task sheds at `max_children` under load | Counts undercount exactly when traffic is highest; the telemetry event still fires, so **event count vs. stored count is the backpressure signal** |
| `mix kiln.export.static` output | Statically exported sites are not served by the app at all — zero tracking |
| Buckets purge at 400 days, totals never | `sum(buckets) ≠ total` by design — never derive the headline total from buckets |
| Days are UTC calendar days | A site far from UTC sees late-evening traffic in the next day's bucket |
| Bots/crawlers are not filtered | Counts are "requests served", not "humans" |

---

## Proposed

### 1. Referrer attribution — `Analytics.ReferrerDay`

Counts arrivals by **coarse source category**, per content item per UTC day.
Same table shape and policy block as `ContentViewDay`.

```elixir
# table "referrer_days"
# identity :unique_referrer_day, [:content_type, :content_id, :source, :day]
#   (org_id is folded in automatically, as on the existing identities)
attribute :content_type, :string, allow_nil?: false
attribute :content_id,   :uuid,   allow_nil?: false
attribute :source, :atom,
  constraints: [one_of: [:direct, :internal, :search, :social, :other]],
  allow_nil?: false
attribute :day,  :date,    allow_nil?: false, writable?: false, default: &Date.utc_today/0
attribute :hits, :integer, allow_nil?: false, default: 1
```

The `one_of` constraint bounds the **source column**, not the table: five
categories, enforced by the type system, so no future caller can widen the row
into a host list. Row count is still driven by content — worst case `distinct
items viewed × distinct sources seen × days`, bounded above by 5×
`content_view_days` and in practice far below it, since most items see one or
two sources a day.

**`KilnCMSWeb.ReferrerSource.classify/2`** — pure, unit-testable, and
deliberately in the **web** namespace rather than under `KilnCMS.Analytics`:
the raw header exists only in the web layer and must not travel further. It
takes the header value plus the request host:

1. Header absent or empty → `:direct`.
2. `URI.parse/1`, **keep the host, drop everything else immediately** — scheme,
   port, path, query, fragment. UTM/campaign parameters and any PII hiding in a
   query string die here, before the value is ever passed on.
3. Host equals the request host → `:internal`. **Shipped without the operator-
   configured alias floated here** — #619's actual scope is `classify/2`,
   comparing against exactly one host (the request's own); a multi-domain
   site (e.g. a bare and `www.` pair, or mid domain-migration) currently sees
   the other spelling misclassify as `:other`. See open question 6.
4. Host equals, or is a subdomain of, an entry in the built-in search-engine
   or social allowlist → `:search` / `:social`. Matching is exact-or-subdomain
   (`news.google.com` matches `google.com`; `google.com.attacker.net` does
   not), so a handful of Google's higher-traffic country-code domains are
   listed explicitly as their own entries — a genuinely different registrable
   domain, not a subdomain.
5. Anything else → `:other`. **The unmatched host is not stored.** A long-tail
   host is itself identifying (a private intranet, a niche forum, a shared
   document URL), so only the *fact* of an unrecognized referrer survives.

**Boundary claim worth keeping:** `Analytics.record_referrer/4` accepts the
classified atom, never a URL. Classification happens where the header exists;
the domain's public API makes persisting a raw referrer impossible rather than
merely discouraged.

**Ingestion joins the existing task, it does not add one.** The referrer upsert
goes inside the same `record_view/3` body that already performs the two view
upserts, so all three shed together under `max_children` and keep reconciling.
A second `start_child` per counter would both triple pressure on the 100-child
cap and let the referrer breakdown's numerator and denominator shed at
different rates.

**Availability, honestly.** Whether a referrer arrives at all is the *referring*
site's choice. Browsers now default to `strict-origin-when-cross-origin`, so
cross-site referrers usually arrive as a bare origin (no path, no query) and
some arrive not at all. That default works in our favour — most of what step 2
strips has already been stripped upstream — but it means `:direct` is a
catch-all that includes "referrer suppressed", not just "typed the URL". Say so
in the UI.

**Gated off by default — and the gate must be readable at runtime.**
`config :kiln_cms, :view_analytics, retention_days: …` is read with
`Application.compile_env`, which is right for a value baked into an AshOban
`where` expression and wrong for an operator switch: on a prebuilt release it
cannot be changed without a rebuild (the defect open as #608 against
`KilnCMS.Provenance`). The referrer gate must therefore be read with
`Application.get_env/3` **and** be settable from `config/runtime.exs` via an
env var (`KILN_ANALYTICS_REFERRERS=1`), documented in
[`environment-variables.md`](./environment-variables.md). The same applies to
the low-count suppression threshold and to any later phase's gate.

**Retention:** same 400-day AshOban `:purge_expired` trigger shape as
`ContentViewDay`, on its own cron minute so the nightly purges don't contend
(`SearchQuery` runs `0 3`, `ContentViewDay` `15 3`; `30 3` is free).

### 2. Funnels — definitions only, counts derived

A funnel is an **operator-defined ordered list of content items** (landing →
pricing → signup). "How many views did step *i* get on day *d*" is a question
`content_view_days` **already answers** — a funnel step is a content item, and
every view of it is already bucketed. So this phase adds *definitions and a
read*, and **no counter table, no ingestion change, and no hot-path work at
all**.

```elixir
# Analytics.Funnel — admin-authored definition, org-scoped
# identity :unique_slug, [:slug]   (org_id folded in, as everywhere else)
attribute :name,   :string,  allow_nil?: false
attribute :slug,   :string,  allow_nil?: false
attribute :active, :boolean, default: true
has_many :steps, Analytics.FunnelStep   # position, content_type, content_id
```

The read loads a funnel's steps, then sums `ContentViewDay` buckets in the
requested window per `(content_type, content_id)` — the same windowed read and
Elixir fold `AnalyticsLive` already does, grouped by step instead of by day.
Conversion is `count[i] / count[i-1]`, computed at read time.

Why this beats a `FunnelStepDay` counter table (the obvious first design):

- **Retroactive.** Define a funnel today and it reports on the last 400 days.
  A counter table starts empty at creation time.
- **Nothing new on the delivery path.** A counter table would need a cached
  `%{{type, id} => [step]}` membership map consulted on every view. That cache
  would live in `KilnCMS.Cache`, which is a single Cachex instance capped at
  10,000 entries with LRW eviction shared with published content — so a flood of
  distinct slugs evicts the funnel map and every subsequent view pays a DB query
  on the hot path, which is precisely what the cache was there to avoid.
- **No second retention story, no second table to purge, no divergence** between
  a step's count and the same item's view bucket.

Cost of the derived design: funnel history is bounded by the 400-day bucket
retention (acceptable — nothing here is a financial record), and a step whose
content has been deleted resolves to zero, which the UI must render as
"deleted" rather than as a real drop-off (the same case `AnalyticsLive`'s title
lookup already handles).

**Definitions are a resource, not config**, because funnels are editorial — they
change when a campaign changes, and a deploy-gated config file puts them out of
reach of the people who need them. That means `Funnel`/`FunnelStep` are the
first *writable* resources in this domain and need a real policy block, not the
counter resources' `forbid_if always()`: admin-only create/update/destroy,
`OrgEditor` read, org-tenanted like everything else.

**What this is not.** Because steps are counted independently, there is no
stored notion of "the same visitor reached step 2 then step 3". Step 2's count
includes traffic that arrived directly and never saw step 1, so the ratio is a
*population statistic*, not a cohort conversion — it can exceed 100%. That is
the honest cost of not identifying visitors, and the funnel view must label it
rather than let it read as a GA-style conversion rate.

### 3. Export

Export of the aggregates — the numbers already on screen, in a file.

- **Gate it at the tier that can already read the data: editor.** The governance
  export is admin-only because `GovernanceLive` itself sits in the
  `:admin_routes` live session; `AnalyticsLive` sits in `:editor_routes`, so
  copying that gate verbatim would ship editors a download button that 403s.
  Export the dashboard's own data at the dashboard's own tier, and check the
  tier explicitly in the controller — the route has to be declared **outside**
  the live session (as `router.ex:325-326` does for governance), so it does not
  inherit the session's gate.
- **`search_queries` are out of scope for this export.** They are the one table
  here holding free text that can incidentally carry PII. If a search-query
  export is ever wanted it is a separate, admin-only door with its own
  justification — not a column in the analytics CSV.
- **Reuse the governance CSV writer — after extracting it.** It is currently
  private to
  [`governance_controller.ex`](../lib/kiln_cms_web/controllers/governance_controller.ex)
  and does two things that must not be re-derived: RFC 4180 quoting, and
  prefixing `=+-@` cells so a spreadsheet never executes an exported value (CSV
  injection). Lift it to a shared `KilnCMSWeb.CSV` and switch governance to it
  **before** adding the second consumer.
- **A two-sided, paginated read is part of this phase.** `ContentViewDay`'s
  `:in_window` takes a single `since` date and has no `pagination` block, so it
  materializes the whole window; chunking a response built from an
  already-materialized list bounds nothing. Phase 1 adds an `:in_range` read
  (`from`/`to` dates, `pagination keyset?: true`) and streams it with
  `Ash.stream!` into `send_chunked`. Cap the span at the retention ceiling so an
  export cannot ask for an unbounded scan.
- **Resolve titles, or ship a spreadsheet of UUIDs.** `:in_window` selects only
  `[:day, :content_type, :content_id, :views]`; the dashboard is legible because
  it does a separate id-batched title read per content type. Export needs the
  same lookup (and the same "(deleted)" fallback), which means policy-gated CMS
  reads on the export path — budget them.
- **Everything runs through Ash**, so policies and tenancy apply. No raw SQL, no
  `authorize?: false`.
- **`mix kiln.analytics.export --format=json --from=… --to=… --org=…`**,
  following the existing `lib/mix/tasks/kiln.*.ex` conventions, for ops and
  backups. It passes an explicit actor — never `authorize?: false`.

### 4. Roll-up (optional, only if history is wanted past retention)

`content_view_days` is purged at 400 days, so history simply ends there — and,
with funnels derived from those buckets, so does funnel history. If a deployment
wants multi-year trend without unbounded rows, add a nightly job that sums day
buckets older than N months into a `:month` grain and deletes the day rows.
Deliberately last: it is the only piece here that *loses* data, and the 400-day
window already answers year-over-year.

---

## Implementation notes (things that will bite)

Collected from the resources already on `main` and from prior CI rounds.

- **Ash 3.x read actions have no `group_by`;** `Ash.sum/aggregate` return a
  single scalar. "Sum per day" is an Elixir fold (what `AnalyticsLive` does) or
  a raw Ecto query. If folding stops scaling, put a grouped query behind a
  function in `KilnCMS.Analytics` (precedent: `KilnCMS.Mail`) with an explicit
  `where org_id == ^org_id` — a grouped Ecto query **bypasses resource
  policies**, so the tenant scope has to be written by hand.
- **`ago/2` returns `:utc_datetime_usec`, and `Date` only compares to `Date`.**
  `filter expr(day >= ago(30, :day))` does not type-check. Take a `:date`
  argument (as `:in_window` does) or filter `inserted_at` (as `:expired` does).
- **The upsert conflict key must not appear in `upsert_fields`.** Rewriting
  `day` on conflict would defeat the increment. Set it from a default with
  `writable?: false` so a caller cannot backdate a bucket either.
- **`custom_indexes` prepends the tenant attribute** unless `all_tenants?:
  true`, so `index [:day]` generates `(org_id, day)`. Confirm against the
  generated migration, not the DSL docs — and every new table here needs both
  the identity index and an `(org_id, day)` companion for the windowed read and
  the purge.
- **Do not index the counter column.** `content_view_days` deliberately has no
  index on `views` (and no `include:`), which keeps the second and later
  increments of a row heap-only-tuple updates. Any new counter table inherits
  that rule.
- **Adding an Ash hook to a hot-path action opens a transaction.**
  `KilnCMS.Repo.prefer_transaction?` is `false`, and Ash only opens one when a
  changeset has hooks — which is why telemetry is emitted from the controller
  and not from an `after_action`.
- **Operator-facing settings must be `Application.get_env` + `runtime.exs`,**
  not `compile_env` (see the referrer gate above, and #608).
- **Migrations are generated, not written:** `mix ash.codegen <name>` under the
  strict build, then `mix format` — in that order.
- **Gettext will fail CI before your code does.** Any new UI string means
  running `mix gettext.extract --merge` and committing `priv/gettext`;
  `mix precommit` does not do it, and line-reference drift alone turns the
  gettext job red.
- **Analytics counter resources have no generic `:destroy`** (`ContentView` has
  none at all; the other two have only `:purge_expired`), so `Ash.destroy!`
  fails in tests — clean up with `Repo.delete_all`. The new writable `Funnel`
  resource is the exception and does need a real destroy.
- **Tests:** `:async_analytics` is `false` under test so the write stays on the
  sandbox connection; assert relative changes, never exact full-table counts
  (the sandbox is shared). Each phase needs its own resource test plus a
  LiveView test for the surface it adds; the classifier deserves a table-driven
  unit test over the allowlist.
- **`docs/data-flows.md` is part of the definition of done.** Its per-table
  inventory and retention table (with cron minute and config key) are what an
  operator's privacy notice and records of processing are built from — a new
  analytics table that isn't listed there publishes a wrong inventory.
- **New guides must be added to *both* `extras:` and `groups_for_extras:`** in
  `mix.exs`. A Markdown link from an extra to a `.md` file that is not itself an
  extra fails `mix docs --warnings-as-errors`; links to non-Markdown repo files
  (`../lib/**.ex`, `../config/*.exs`) are not checked and are fine.

---

## Phased plan

Each phase is independently mergeable, and each ships behind a runtime-readable
config gate. **This table is the status of record.**

| Phase | Issue | Status | Scope | Depends on |
|---|---|---|---|---|
| **1** | #618 | done | `KilnCMSWeb.CSV` extraction (+ governance switched to it), `ContentViewDay.:in_range` paginated read, streamed CSV/JSON export with title resolution, `mix kiln.analytics.export` | — |
| **2** | #619 | done | `ReferrerSource.classify/2` + `ReferrerDay` + retention trigger + runtime config gate; write joins the existing view task | — |
| **3** | #620 | done | Referrer breakdown UI on `AnalyticsLive` (with low-count suppression); export gains referrer columns | 2, and 1 for the export half |
| **4** | #621 | done | `Funnel`/`FunnelStep` definitions + admin CRUD | — |
| **5** | #622 | done | Funnel report derived from `ContentViewDay` + labelled ratios; export gains a funnel sheet | 4, and 1 for the export half |
| **6** | #623 | not started | Month roll-up job (only if multi-year history is wanted) | — |

**Cut line:** Phase 1 alone is worth shipping — it makes the existing numbers
portable and lands the shared CSV writer. Phases 2–3 are the highest
value-per-risk of the new data. Funnels (4–5) are now cheap (definitions plus a
read), but they are the weakest privacy-preserving analogue of the commercial
feature; ship them last, or not at all if the labelled-ratio caveat proves too
confusing in practice.

## Open questions

1. **Referrer allowlist maintenance — resolved, built-in only, no config merge.**
   `KilnCMSWeb.ReferrerSource` ships a curated, compile-time list with
   exact-or-subdomain matching (#619) and explicitly does **not** take a config
   merge: an operator-added host would be a classifier output added without a
   code review, and the built-in/config split precedent in this codebase
   (`KilnCMS.OEmbed.Provider`) is the same — config may narrow a built-in list,
   never extend it with a new host. A missing host falls through to `:other`
   (the accepted long-tail cost) rather than staying unclassifiable; the list
   is maintained the same way any other compiled allowlist in this codebase is,
   by a PR.
2. **Is `content_id` in the referrer key worth the rows?** The schema above
   commits to per-content referrers (up to 5× the view buckets); a site-wide
   variant would be ~5 rows/day total but could not answer "where does *this
   post* get read from". If the row count proves unacceptable in practice the
   fallback is to drop `content_id` — a migration, not a redesign.
3. **Is the referrer gate per-org or global?** It is written above as
   application config, which is global; every resource here is `org_id`-tenanted,
   so a multi-tenant operator will ask. Per-org would mean a settings row
   (precedent: `SiteBranding`), which is a heavier phase 2.
4. **Bot filtering.** A UA-based crawler filter would make counts truer, but
   reading the UA at all — even without storing it — cuts against the current
   "the header is never inspected" simplicity. Is a `robots`-style opt-in list
   worth it?
5. **Funnel definition scope** — org-wide only, or per-locale? A translated
   funnel is a different set of content ids.
6. **The `:internal` alias cut from #619's `classify/2`.** A site reachable at
   more than one hostname (bare + `www.`, or mid domain-migration) sees
   navigation from the "other" spelling misclassify as `:other` today. The
   cheapest fix, if this proves to matter in practice, is comparing against
   the same host set `CHECK_ORIGINS` already derives (it already means "other
   hostnames this same app is served from") rather than adding a second,
   separately-configured alias list.

## Non-goals

- **Unique visitors, sessions, bounce rate, individual paths.** Out by design;
  they require identity we refuse to collect.
- **Client-side JS beacon, cookies, local storage, fingerprinting.**
- **Raw referrer URLs, UTM/campaign capture, geolocation.**
- **Exporting `search_queries`** as part of analytics export — see
  [Export](#3-export).
- **Third-party analytics sync** (GA, Plausible Cloud, …). Data stays in the
  self-hosted Postgres.
- **A real-time firehose.** This is aggregate trend reporting; LiveDashboard
  already covers live request-level observation.
