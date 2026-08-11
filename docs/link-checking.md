# Broken link checking

Kiln checks links in two places, because the two halves of the problem have
almost nothing in common.

| | Internal links | Outbound links |
|---|---|---|
| Where | The editor's advisory panel, on the document being edited | `/editor/links`, site-wide |
| When | As you type | A nightly sweep |
| How | A database query | An HTTP request |
| Switch | None — it costs nothing | **Off by default, per site** |

The internal half is documented in [Advisories](advisories.md). This page is the
outbound half (#474).

## Turning it on

`/editor/links` → **Turn on outbound checking** (org admin). Nothing happens on
any deployment until somebody does that: the sweep is scheduled everywhere, and
with no site opted in it reads one settings row per org and stops.

The switch is admin-only because it is the decision that makes this server issue
requests to third parties. Some deployments cannot do that at all, and none
should find out from a firewall log.

Once on, the sweep runs nightly (`KILN_LINK_CHECK_CRON`). **Check now** on the
report page queues one immediately.

## What a broken link means here

Very little qualifies, on purpose. The web answers a checker differently from a
browser: bot walls return 403, paywalls 401, CDNs 429, and a great many hosts
refuse `HEAD` outright. None of that is evidence a reader would hit a dead link.

| Outcome | What produced it | Reported? |
|---|---|---|
| `:ok` | 2xx, possibly after redirects | — |
| `:broken` | 404, 410, or a redirect chain that never lands | **Yes** |
| `:transient` | 5xx, timeout, refused connection, unresolvable name | Only after 3 in a row |
| `:undetermined` | 401/403/429 and every other 4xx; any address the SSRF guard refuses | Never |

A dead *domain* arrives as `:transient` — nothing resolved it — rather than
`:broken`. That is deliberate: DNS fails for a minute far more often than
forever, so the consecutive-failure counter is what tells a lapsed domain from a
bad afternoon. It is also the most common genuinely-broken external link, and
therefore the one most worth being patient about.

Any `:ok` resets the counter. It measures the *current* run of failures, not
lifetime unreliability.

`HEAD` goes first because it costs the far end nothing. A 403, 404, 405, 406 or
501 to `HEAD` is re-asked with `GET` rather than believed — some servers really
do serve one to `HEAD` and the page to `GET`. That doubles the traffic for some
broken links, which is the right way round: a false "broken" sends an author
hunting for a fault that does not exist.

## Manners

Every request:

- identifies itself — `KilnCMS-LinkCheck (+https://…)`, with no version number.
  A link checker announces itself to every site an author has ever cited, so a
  build number there is a permanent broadcast of what to try. Set your own
  contact URL with `KILN_LINK_CHECK_USER_AGENT`.
- is paced **per remote host**, not per site or per job (`KilnCMS.Links.Throttle`,
  one request per host every two seconds by default). The thing being protected
  is somebody else's server, and it does not care which tenant is pointing at it.
- goes through `KilnCMS.SafeFetch`: the address is resolved once and connected to
  as a literal, so a hostname cannot answer with a public IP during validation
  and `169.254.169.254` at connect time. Redirects are followed **by hand**, each
  hop re-validated and re-pinned — handing the chain to the HTTP client would
  resolve hops 2..n past every check, and one open redirect on a trusted host
  would be a straight path back to the metadata service.

Healthy links are re-checked weekly, not nightly. They are the overwhelming
majority, and a checker that asks every host about every working link every
night is a checker sites start blocking.

## What gets scanned

Published records only, across every content type. Within a document:

- rich-text link annotations, including inside table cells;
- an `embed` block's URL — a taken-down video is exactly this case;
- a `claim` block's `source_url` — a citation whose source vanished is worse than
  a broken link in prose.

Image and gallery URLs are **not** scanned: they point at Kiln's own storage or
CDN, so checking them would be this deployment asking itself whether its own
files exist, over the network, on a schedule.

Drafts are not scanned. A draft's links are not yet anyone's problem.

## Reconciliation

Every occurrence the sweep sees is stamped `last_seen_at`; rows older than the
run are deleted when it finishes. One rule covers "the author removed that
link", "the document was unpublished", "the document was deleted" and "the type
was archived" — four hooks would be four places to forget.

The delete only runs after a scan that reached the end, so a sweep that dies
partway leaves stale rows in the report rather than deleting everything it had
not got to.

## Operating it

```bash
# One site, now, from a running node
bin/kiln_cms rpc 'KilnCMS.Links.Sweep.run_org("<org-uuid>")'

# Every opted-in site
bin/kiln_cms rpc 'KilnCMS.Links.Sweep.run()'
```

| Variable | Default | Meaning |
|---|---|---|
| `KILN_LINK_CHECK_CRON` | `20 4 * * *` | When the sweep runs. `false` disables the schedule. |
| `KILN_LINK_CHECK_USER_AGENT` | `KilnCMS-LinkCheck (+…)` | What the checker calls itself. |

Checks run on the `:link_check` Oban queue (concurrency 3). It is deliberately
the narrowest queue in the system: every job is a request to somebody else's
server, and a wider queue would mostly produce more jobs waiting on the same
per-host buckets.

## Where things live

| | |
|---|---|
| `KilnCMS.Links.External` | checks one URL, and decides what an answer means |
| `KilnCMS.Links.Throttle` | per-host pacing |
| `KilnCMS.Links.Extract` | outbound URLs in a block tree, with block indexes |
| `KilnCMS.Links.Sweep` | scan, reconcile, queue |
| `KilnCMS.Links.CheckWorker` | one URL, throttled, with retry-before-flagging |
| `KilnCMS.Links.SweepWorker` | the scheduled entry point |
| `KilnCMS.Links.Settings` | the per-site opt-in |
| `KilnCMS.Links.Report` | what `/editor/links` renders |
| `KilnCMS.CMS.ExternalLink` | one URL in one document, and its last verdict |
| `KilnCMS.SafeFetch` | pinned, size-capped, hand-followed HTTP |
