# Right, everywhere, provably

<!-- seo-description: What Kiln is for: content that has to be right. A
correction reaches every connected site in seconds, with a signed record of who
changed it, who approved it and what readers saw. Start here. -->

Kiln is a CMS for content that has to be right. When you publish a
correction, every site, app and cache you connect is told within seconds. Kiln
also keeps a record of who changed it, who approved it and exactly what
readers were served at any moment, signed so someone outside the project can
check it.

This page is the entry point to that story. Six guides cover it in detail,
and each one is complete on its own; this page puts them in order and adds
what shipped in 1.3 to 1.7, so you can follow one correction from the editor
to the last reader. [path-forward.md](path-forward.md) explains why Kiln is
built around this, and what comes next.

> **What a correction looks like, in four steps.** An editor publishes a fix.
> Every page that shows it, including the pages that embed it, is refreshed
> within seconds. If the entry is retracted instead, every consumer drops it
> and no retraction is silently lost. Later, the governance view shows who
> approved each step, when each consumer updated, and what any reader was
> served at any instant in between, with a signature you can verify.

## The six guides, in reading order

Read them in this order. Each step builds on the one before it.

| # | Guide | What it answers |
|---|---|---|
| 1 | [Webhooks](webhooks.md) | How the sites and apps that read your content hear about a change, including the other pages it touched, and why a retraction cannot be lost |
| 2 | [Resilient delivery](resilient-delivery.md) | Why public delivery keeps answering through a database outage, for content that is warm in cache |
| 3 | [Static export](static-export.md) | How to copy the same pre-rendered pages to a CDN, an edge cache or an offline host |
| 4 | [Point-in-time content](point-in-time.md) | How `?as_of=` serves a document exactly as it was published at a past moment, and says `withdrawn` when it was not live |
| 5 | [Provenance](provenance.md) | How every published page carries a signed manifest, and how anyone checks it with one request |
| 6 | [Governance dashboard](governance-dashboard.md) | Where it all comes together: one trail per document, with approvers, delivery times, `?as_of=` links and the history chain's verdict |

Guides 1 to 3 are the **everywhere** half: getting the right version out
fast, and keeping it served. Guides 4 to 6 are the **provably** half: a
record you can hand to a reviewer.

## Everywhere, in seconds

### Pages are built once, when you publish

Kiln does not render a page from the database on every request. Publishing
**fires** a document: Kiln renders it once to each delivery surface (web
HTML, JSON, JSON-LD) and stores the result as an immutable artifact. Delivery
serves those artifacts from an in-memory cache. A dependency graph records
which documents embed which, so when a herb entry changes, the formula pages
that list it fire again too.

Two things follow from that. Delivery keeps working when Postgres does not,
for content that is warm in cache
([resilient delivery](resilient-delivery.md)). And the artifacts can be
copied out as a static site without rendering anything again
([static export](static-export.md)).

### Every consumer is told, including about the pages a change touched

A signed webhook goes out on every publish, edit of live content,
unpublish, archive and delete ([webhooks](webhooks.md)). Since 1.3 a content
webhook also carries `data.affected`: the published documents whose pages
embed this one, so a consumer can refresh those pages straight away instead
of waiting for a cache to expire
([`affected`](webhooks.md#affected-the-other-pages-this-change-touched),
[changelog](changelog/v1.3.0.md#webhook-affected)).

If you put a CDN in front of the API, `KILN_CDN_PURGE_URL` makes every
publish, unpublish and update purge the site's cache tag (Cloudflare
purge-by-tag, Fastly purge-by-key). Without it, cached responses age out on
`KILN_API_CACHE_MAX_AGE`
([environment variables](environment-variables.md#api-caching-and-cdn-purge)).

### A retraction cannot be silently lost

Since 1.4, the three webhooks that take a document off a consumer
(`unpublished`, `archived` and `deleted`) are exempt from endpoint
auto-disable. They retry for about a day instead of five attempts. When one
still fails, every admin of the site is told, and the document's governance
trail shows it with a Redeliver button
([retractions are exempt](webhooks.md#retractions-are-exempt),
[changelog](changelog/v1.4.0.md#retraction-guarantee)).

### How long it takes is measured, not claimed

Since 1.5, every publish and withdrawal opens one **propagation record**: when
the transition happened, when the CDN purge was acknowledged, and when each
webhook endpoint answered. `mix kiln.propagation` prints p50 and p95 from
those records ([changelog](changelog/v1.5.0.md#propagation-records)).

The first published number: on a staging copy of Verscienta.com, with its
production endpoint set (one self-hosted endpoint), 56 withdrawals over 24
hours reached the last endpoint at **p50 0.14 s, p95 0.58 s, none lost**
(measured 2026-10-26 on Kiln 1.5.1). The method and the caveats are in
[benchmarks](benchmarks.md#live-delivery-unpublish-to-last-endpoint).

### What else 1.6 added on this side

- **A change feed, server side.** `KilnCMS.Delivery.Feed` announces
  `published`, `updated` and `withdrawn` for each site over Phoenix PubSub,
  from the same transitions the webhooks use. Events carry identifiers, never
  content ([changelog](changelog/v1.6.0.md#change-feed-server)). Since 1.9
  the public SSE transport serves it at `GET /api/feed`
  ([API](api.md#change-feed-sse)); the Phoenix Channel transport is still
  planned.
- **Re-fire from an overlay.** `KilnCMS.Firing.refire/3` lets an overlay fire
  named documents again, with their dependents, webhooks and CDN purge, as an
  edit of live content would ([changelog](changelog/v1.6.0.md#overlay-refire)).

## Provably

### What a reader saw on any date

Add `?as_of=<date>` to `GET /api/content/:type/:slug` and Kiln rebuilds the
document from its version history and renders it with the same engine as
live delivery. The answer is what was published at that moment, with nothing
edited since leaking in. If the document had been taken down by then, the
answer is `404 withdrawn`, not the last version that was live. A collection
read answers "what was published on this site on that date". See
[point-in-time content](point-in-time.md).

### Every published page is signed

Since 1.7, provenance is on by default. A new install gets a signing key at
`/setup`, and every fired artifact is stored with a signed manifest: a hash of
the page, the version it came from, who signed it and an AI-use disclosure.
Anyone can ask whether what they are served is still what was signed:

```
GET /api/provenance/verify/post/my-post?surface=json
→ { "status": "verified", … }      ← or "tampered", "unsigned", "unverifiable"
```

The public key is at `/api/provenance/public-key`, so a reviewer can verify a
copy without trusting the server. An install upgraded without a key keeps
working and serves its pages `unsigned`; nothing is refused.
`KILN_PROVENANCE_ENABLED=false` switches it off. See
[provenance](provenance.md) and
[the 1.7 changelog](changelog/v1.7.0.md#provenance-on-by-default).

### One trail per document

The governance dashboard at `/editor/governance` (admin only) gathers the
record for each document ([governance dashboard](governance-dashboard.md)):

- **What readers saw** (since 1.6): one row per publish or withdrawal, with
  the account that made it, the CDN purge, each webhook endpoint's delivery
  time or failure, the `?as_of=` link for that instant, and the history
  chain's verdict on that version
  ([changelog](changelog/v1.6.0.md#governance-what-readers-saw)).
- **Version timeline**: every change, who made it and which fields it touched.
- **Retractions not delivered** (since 1.4), when there are any.
- **Export** as JSON or CSV, carrying the same rows.

The history behind the trail is tamper-evident. Signed anchors chain each
document's versions together, and scheduled checkpoints publish a signed
commitment outside the database, so rewriting or removing history reads
`TAMPERED`. The dashboard guide says plainly which attacks that catches and
which it does not, and what an operator has to set up for it to count as
evidence.

### Before it goes out

The publishing workflow runs draft, in review, published, archived. Claim
checking can be set to **refuse a publish** that contains a phrase you have
marked as blocking ([claim checking](compliance.md)). Since 1.6, a preview
token also opens a draft on JSON:API and the fired-artifact read, so a front
end can show the draft side of the same timeline (headless draft mode,
[changelog](changelog/v1.6.0.md#headless-draft-mode)).

## What is not built yet

These are planned, not shipped. The order is in
[path-forward.md](path-forward.md).

- **The change feed over Phoenix Channels**, and `kiln.subscribe()` /
  `KilnClient.subscribe/2` so a front end updates its open pages in one call
  (2.2, 2.3). Today a front end follows `GET /api/feed` (Server-Sent Events,
  since 1.9; [how](headless-consumer-guide.md#live-updates-follow-the-change-feed)),
  your webhook receiver, or the experimental GraphQL subscriptions over
  `/ws/gql`.
- **Fan-out numbers**: open connections per node and propagation p95 at 1k,
  10k and 50k subscribers (2.4). The in-process feed has been measured at up
  to 10,000 subscribers ([benchmarks](benchmarks.md)); the network transports
  have not.
- **A signed compliance bundle** that a reviewer verifies offline, without a
  Kiln install (3.1).
- **Approval policies** such as "needs two approvers from this role before
  publish" (3.3). Today the trail records who published; it does not require
  more than one person.
- **A recorded demo** of one correction traced end to end. It needs a real
  correction on staging, and is part of the 2.0 exit criteria.
