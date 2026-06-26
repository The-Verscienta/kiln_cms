# Advanced Content Analytics — Design

**Status:** Design only (issue #62, *[Stretch]*). Nothing here is built yet.
This doc extends the shipped privacy-first analytics
(`KilnCMS.Analytics.ContentView`, `KilnCMS.Analytics.SearchQuery`) into three new
capabilities — **time-series view buckets**, **privacy-respecting referrer
aggregation**, and **simple content funnels** — plus an **admin-only export**.
It is specced to land in thin, independently-mergeable slices, gated so the
default install stays lean and stays privacy-first.

**Depends on / cross-links:**
[#45 (Analytics time-series + telemetry)](../README.md) — the `:telemetry`
ingestion path described there is the source of every event consumed here; this
doc assumes #45 ships first (or alongside Phase 1).
[`observability.md`](./observability.md) — the existing
`[:kiln_cms, :editor, …]` telemetry conventions we mirror.

---

## Goal

Give editors and admins richer, *still aggregate-only* insight into how content
is consumed — trends over time, where readers arrive from (coarsely), and how
they move through a small ordered set of pages — and let an admin export the
aggregates. Everything degrades to "off" by default and never collects anything
that could identify a visitor.

## Privacy constraints (hard requirements)

These are non-negotiable and frame every schema decision below. They are the
reason this is *not* "add Google Analytics".

- **No PII, ever.** No IP addresses, user-agent strings, user IDs, session IDs,
  or device data are stored — matching the current `ContentView`/`SearchQuery`
  resources (see their moduledocs: "no actor, IP, or other personal data").
- **No per-visitor records.** We store **counters and bucketed aggregates**,
  never one row per request. There is no row that represents a single human, so
  there is nothing to re-identify, subpoena, or leak.
- **No cookies, no fingerprinting, no cross-site tracking.** Nothing is written
  to the visitor's browser; nothing correlates a visitor across pages, sites, or
  visits. (Funnels are reconstructed from *aggregate* step counts, not from
  following an individual — see [Funnels](#3-funnels).)
- **No raw referrer URLs.** Referrers are reduced to a coarse, allow-listed host
  category at ingestion time and the query string is dropped *before* anything
  is persisted. The raw `Referer` header is never stored.
- **GDPR-friendly by construction.** With no personal data collected there is no
  lawful-basis, consent-banner, DSAR, or retention-of-PII obligation attached to
  analytics. Retention roll-ups (below) further bound how long even *aggregate*
  granularity is kept.

### How this differs from Google Analytics

| | Google Analytics | KilnCMS advanced analytics |
|---|---|---|
| Unit of storage | per-event hit, per-user/session | per-bucket aggregate counter |
| Visitor identity | client-side cookie / signals | none — nothing written to browser |
| Referrer detail | full URL incl. campaign/query | coarse host category only |
| Funnels | reconstructed by following a user | aggregate step counts, no user path |
| Data location | Google | self-hosted Postgres |
| Consent banner | typically required | not required (no PII) |

The cost is honest: we **cannot** report unique visitors, bounce rate per user,
or true individual session paths. That is the trade — we accept lower fidelity
to keep the "nothing to leak" property.

---

## Proposed Ash resources

All new resources live in the existing `KilnCMS.Analytics` domain
(`lib/kiln_cms/analytics.ex`), reuse its **editor/admin read, system-only
write** policy block verbatim, and follow the established **upsert-a-counter**
pattern from `ContentView.record`. Sketches below are illustrative, not final.

### 1. Time-series view buckets — `Analytics.ViewBucket`

Today `ContentView` keeps a *single* lifetime total per content item. To show
trends we add a second resource keyed by `(content_type, content_id, bucket)`,
where `bucket` is a truncated timestamp. `ContentView` stays as the cheap
lifetime total; `ViewBucket` carries the time dimension. (This is the storage
side of issue #45 — #45 owns the telemetry *emit*; this resource owns the
*aggregate persisted*.)

```elixir
# table "view_buckets"
# identity :unique_bucket, [:content_type, :content_id, :granularity, :bucket]
attribute :content_type,  :string,         allow_nil?: false
attribute :content_id,    :uuid,           allow_nil?: false
attribute :granularity,   :atom,           constraints: [one_of: [:hour, :day]]
attribute :bucket,        :utc_datetime,   allow_nil?: false   # truncated to granularity
attribute :views,         :integer,        default: 1, allow_nil?: false

create :record do
  upsert? true
  upsert_identity :unique_bucket
  upsert_fields [:views]
  change atomic_update(:views, expr(views + 1))   # same shape as ContentView.record
end

read :series do            # filter by item + [from, to]; sort :bucket asc
  # arguments: content_type, content_id, granularity, from, to
end
```

Notes:
- `bucket` is truncated to the granularity at write time (e.g. floor to the hour)
  so each upsert lands in exactly one row — no per-request rows accumulate.
- Hour grain is the finest; coarser grains (day) are produced by the roll-up job,
  not written directly. See [Retention](#data-retention--aggregation).
- `record` is driven from the same `track_view/2` best-effort path that already
  calls `Analytics.record_view/3` in
  `content_controller.ex` (or, preferably, from the #45 telemetry handler so the
  controller stays thin). Failures are swallowed — analytics must never break or
  slow delivery.

### 2. Referrer aggregation — `Analytics.ReferrerHit`

Counts arrivals by **coarse referrer category**, never by URL. The reduction
happens in a pure function *before* persistence; the raw header is discarded.

```elixir
# table "referrer_hits"
# identity :unique_referrer, [:content_type, :content_id, :category, :bucket]
attribute :category, :atom, allow_nil?: false
# one_of: [:internal, :search, :social, :other_allowlisted, :direct, :unknown]
attribute :bucket,   :utc_datetime    # day grain, same retention treatment
attribute :hits,     :integer, default: 1, allow_nil?: false
```

`KilnCMS.Analytics.Referrer.classify/2`:
1. If no `Referer` header → `:direct`.
2. Parse host only; **drop scheme, path, query, fragment** immediately. The query
   string (where campaign/UTM/PII most often hide) never survives this step.
3. Same host as the site → `:internal`.
4. Host matches a small built-in **allowlist** of known categories
   (search engines → `:search`, major social → `:social`, plus an operator-
   configurable `extra_allowlist`) → that category, or `:other_allowlisted`.
5. Anything else → `:unknown`. We deliberately **do not** store the unrecognized
   host — only the fact that *an* unrecognized referrer occurred. This caps
   cardinality and guarantees no long-tail host (which can itself be
   identifying, e.g. a private intranet URL) is ever persisted.

Config-gated and **off by default**:
`config :kiln_cms, KilnCMS.Analytics, referrers: false, referrer_allowlist: %{…}`.

### 3. Funnels — `Analytics.FunnelStep`

A funnel is an **operator-defined ordered list of content steps** (e.g.
`landing → pricing → signup`). We store, per funnel + step + time bucket, **how
many views that step received** — an *aggregate* count, never a per-visitor
path. "Conversion" is computed as the ratio of adjacent step counts at read
time. This is intentionally weaker than GA funnels (we are not following anyone),
which is exactly what keeps it privacy-safe.

```elixir
# Funnel definition (admin-authored config or a small resource):
#   %{name: "signup", steps: [{"page", <id1>}, {"page", <id2>}, {"post", <id3>}]}

# table "funnel_steps"
# identity :unique_step, [:funnel, :step_index, :bucket]
attribute :funnel,     :string,  allow_nil?: false
attribute :step_index, :integer, allow_nil?: false      # position in the ordered list
attribute :bucket,     :utc_datetime
attribute :count,      :integer, default: 1, allow_nil?: false

read :funnel do        # returns ordered step counts for a funnel over [from,to]
  # downstream calc: conversion_rate[i] = count[i] / count[i-1]
end
```

Ingestion: when a tracked view matches a `(content_type, content_id)` that
appears in a funnel definition, increment that funnel's step bucket. A view can
feed multiple funnels. Because steps are matched independently and only counted,
there is no stored notion of "the same visitor reached step 2 then step 3" — the
conversion ratio is a population statistic, with the usual caveat that it
approximates rather than tracks. We document that caveat in the dashboard.

---

## Data retention & aggregation

The whole point is to keep *trends* without keeping *granular history forever*.
Strategy mirrors the upsert-counter philosophy already in the codebase — keep
small aggregates, drop detail.

- **No raw rows exist to begin with.** Every write is already an upsert into a
  bucket, so there is no raw event log to purge — only bucket granularity to
  coarsen over time.
- **Roll-up + drop**, run by an Oban job (project already uses AshOban; mirror an
  existing scheduled worker):
  - **hour buckets** older than ~**14 days** → summed into **day** buckets, then
    the hour rows are deleted.
  - **day buckets** older than ~**13 months** → optionally summed into a
    `:month` granularity (or dropped), so storage stays bounded.
  - `ContentView` lifetime totals are never rolled up or dropped — they are one
    row per item and carry no time dimension.
- Referrer and funnel buckets follow the same day-grain retention.
- All windows are config values (`config :kiln_cms, KilnCMS.Analytics,
  retention: %{hour_days: 14, day_months: 13}`) so an operator can shorten them
  to whatever their policy requires; shorter is always allowed.

---

## Export

Admin-only export of the **aggregates** (never anything else, because nothing
else exists).

- **Ash actions, not raw SQL.** Add `read`-backed export actions on the
  resources (e.g. `ViewBucket.series`, `ReferrerHit.summary`, `FunnelStep.funnel`)
  and a thin formatter that streams **CSV** or **JSON**. Reuse Ash for
  filtering/sorting so policies apply automatically.
- **Two front doors:**
  1. A **download button** on the analytics dashboard
     (`KilnCMSWeb.AnalyticsLive`) that streams the current view as CSV/JSON via a
     controller `send_chunked` response.
  2. A **mix task** `mix kiln.analytics.export --format=json --from=… --to=…`
     for ops/backups, mirroring the existing `mix kiln.*` task convention
     (e.g. `mix kiln.embed_all` in the search plan). The task runs the same
     export actions with an admin actor.
- **Policy: admin-only.** Export is **stricter** than the dashboard's
  editor/admin read. Add a dedicated `read :export` action gated by
  `actor_attribute_equals(:role, :admin)` (the `bypass` admin block already
  exists; the new action simply *omits* the editor `authorize_if`). The mix task
  passes an explicit admin actor and must **not** use `authorize?: false`.
- Exports contain only aggregate counts and bucket timestamps — by construction
  there is no PII to redact.

---

## Telemetry integration points

Ingestion is driven by `:telemetry`, reusing issue #45's events as the single
source of truth rather than scattering `Analytics.record_*` calls through
controllers. This mirrors how `observability.md` centralizes editor events in
`EditorTelemetry`.

- **Source events (owned by #45):** a content-view event, e.g.
  `[:kiln_cms, :content, :view]`, with metadata `%{content_type, content_id,
  referrer_category, funnels}` and measurement `%{count: 1}`. The classification
  to `referrer_category` happens in the emitter (the web layer, which is the only
  place the header exists) so the **handler never sees a raw referrer**.
- **Handlers (this work):** an attached `:telemetry` handler (or AshOban-fed
  batcher) translates each event into the relevant `record` upserts —
  `ViewBucket`, `ReferrerHit`, and any matching `FunnelStep`. Handlers are
  best-effort and wrapped so a failure never propagates to request handling.
- **Self-observability:** emit our own counters (e.g. roll-up rows compacted,
  export rows streamed, handler errors) under a `[:kiln_cms, :analytics, …]`
  prefix and register them in `KilnCMSWeb.Telemetry.metrics/0`, so they appear
  in LiveDashboard / Prometheus alongside the editor metrics — same wiring
  described in `observability.md`, no new infrastructure.

---

## Phased implementation plan

Each phase is independently mergeable and shippable behind config.

- **Phase 0 — Telemetry seam.** Land (or align with #45) the
  `[:kiln_cms, :content, :view]` event and move view recording behind a handler.
  No new tables. Proves the ingestion seam without schema risk.
- **Phase 1 — Time-series buckets.** `ViewBucket` resource + `record`/`series`
  actions, hour/day grain, dashboard sparkline on `AnalyticsLive`. Roll-up Oban
  job + retention config.
- **Phase 2 — Referrers.** `Referrer.classify/2` (pure, unit-tested allowlist),
  `ReferrerHit` resource, config gate (off by default), dashboard breakdown.
- **Phase 3 — Funnels.** Funnel definition format, `FunnelStep` resource,
  read-time conversion calc, simple funnel view.
- **Phase 4 — Export.** CSV/JSON export actions, admin-only policy, dashboard
  download button, `mix kiln.analytics.export` task.

**Cut line:** Phases 0–1 deliver the headline value (trends). Referrers and
funnels are additive and each independently optional; export can ship as soon as
there is anything to export (after Phase 1).

---

## Open questions

1. **Bucket grain & roll-up windows** — are hour→day→month and 14d/13m the right
   defaults, or should the finest grain be configurable per deployment?
2. **Funnel definitions** — config file vs. an admin-editable resource? Config is
   simpler and versioned; a resource lets non-deploy edits.
3. **Referrer allowlist maintenance** — ship a curated built-in list (and how
   often refreshed) vs. operator-only? Built-in risks staleness; operator-only
   reduces usefulness out of the box.
4. **#45 ownership boundary** — confirm #45 emits the view telemetry event so
   this work only *consumes* it, avoiding a duplicate emit path in
   `content_controller.ex`.
5. **Batching** — direct per-event upserts (simple, like today) vs. AshOban
   batched aggregation (less write contention at high traffic). Start direct;
   revisit under load.

## Non-goals

- **No unique-visitor / session / individual-path metrics.** Out of scope by
  design — they require visitor identity we refuse to collect.
- **No client-side JS beacon, cookies, or local storage.** Ingestion is
  server-side only.
- **No third-party analytics export/sync** (GA, Plausible cloud, etc.). Data
  stays in the self-hosted Postgres.
- **No raw referrer URLs, UTM/campaign capture, or geolocation.** Coarse category
  only; everything else is dropped at ingestion.
- **No real-time live dashboard** beyond what LiveDashboard already gives; this
  is aggregate trend reporting, not a live firehose.
