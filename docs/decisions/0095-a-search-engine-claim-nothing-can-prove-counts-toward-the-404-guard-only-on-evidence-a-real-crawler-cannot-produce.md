# 0095. A search-engine claim nothing can prove counts toward the 404 guard only on evidence a real crawler cannot produce

- **Status** — accepted (2026-11-28). Amends
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md):
  an address outside DuckDuckGo's fresh list no longer *proves* a DuckDuckBot
  claim false; it is evidence, which the rate limiter still charges as no
  user agent and the smart 404 guard counts only after a day's grace. Partly
  supersedes
  [ADR 0086](0086-an-ipv6-64-that-produced-claimant-controlled-negative-evidence-loses-the-404-exemption-for-unproven-claims.md):
  DuckDuckBot over IPv6 in an unmarked `/64` is no longer exempt from the miss
  threshold without limit. Its other rules (marks, what writes and reads
  them, `:forward_error`) are unchanged.
- **References** — [#2852](https://github.com/The-Verscienta/kiln_cms/issues/2852)
  (DuckDuckBot outside its published list) and
  [#3450](https://github.com/The-Verscienta/kiln_cms/issues/3450) (DuckDuckBot
  rotating through an IPv6 `/64`), which this closes;
  [#3451](https://github.com/The-Verscienta/kiln_cms/issues/3451) (an
  unanswered forward query under a broad engine suffix), which it does not;
  [#3501](https://github.com/The-Verscienta/kiln_cms/issues/3501) for keying
  the stored sighting by an HMAC;
  [ADR 0054](0054-in-crawler-verification-a-silence-the-claimant-controls-counts-against-it-and-one-the-vendor-controls-does-not.md)
  for whose silence counts.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Security
  ([long form](../changelog/unreleased.md#crawler-claim-evidence)) and Upgrade
  notes ([long form](../changelog/unreleased.md#crawler-claim-evidence-upgrade)).

## The problem

With `KILN_SCANNER_BLOCKING` on, `KilnCMS.Security.ScannerGuard` exempts a
client whose user agent names a search engine from the miss threshold until
`KilnCMS.CrawlerVerification` has evidence against the claim. DuckDuckBot is
the one engine with no reverse-DNS domain, so the only evidence there can be
is DuckDuckGo's published list (IPv4 only), and the guard read it two ways
that were both wrong:

- **Over IPv4, a list's silence was a proof.** Since #2586 an address outside
  DuckDuckGo's fresh list was `{:unverified, :failed}`, and the guard counted
  it at once. But a list lags the vendor: a real DuckDuckBot crawling from an
  address DuckDuckGo added since this node's last fetch was counted, and
  could be blocked, until the next fetch (ADR 0055's "DuckDuckBot list lag").
- **Over IPv6, there was no evidence at all.** DuckDuckBot over IPv6 is
  `{:unverified, :unverifiable}`: no list range of its family, no DNS check,
  and no lookup that could ever mark its `/64` (ADR 0086). So a scanner
  typing "DuckDuckBot" from an IPv6 `/64` that no other claim had marked was
  exempt from the miss threshold without end.

The owner chose, on #2852, that a list-only miss be counted only once the
list has had time to name the address, and on #3450, that a `/64` of
unverifiable claims "count toward the miss threshold once their `/64`
reaches N misses" in the window, with no new setting.

## Decision

**Neither claim is counted on the strength of a single moment's evidence. A
list-only claim is counted once the list has had a day to name the client and
still does not; an unverifiable IPv6 claim is counted once its own `/64` has
made `threshold` of them in the window.**

### A list's silence is evidence, not proof (#2852)

- **A new reason, `{:unverified, :not_listed}`.** `CrawlerVerification.check/3`
  answers it for an engine DNS cannot check (only DuckDuckBot today) when the
  address is outside the engine's fresh list. No lookup is made, nothing is
  cached and no `/64` is marked. `{:unverified, :failed}` now means DNS
  proved the claim false, nothing else.
- **The rate limiter is unchanged in effect.** `KilnCMSWeb.Plugs.RateLimit`
  charges `:not_listed` as `:empty`, exactly as it charged `:failed`, so a
  DuckDuckBot spoofer outside the list still gets no more than a client with
  no user agent (60 a minute with the defaults). A real crawler on a lagging
  list pays only that budget for the lag, never a block. The telemetry
  `reason` tag splits: DuckDuckBot's series move from `failed` to
  `not_listed`.
- **The guard waits a day.** `ScannerGuard` counts a `:not_listed` claim when
  its `/64` is marked (ADR 0086), or when
  `CrawlerVerification.listing_overdue?/3` is true: the counted client (an
  IPv4 address; an IPv6 address's `/64`; an IPv4-mapped address is its IPv4
  address) is still outside a list that was fetched at least
  `:listing_grace_ms` (24 hours) after the instance first saw the client
  miss. Until then the claim keeps the exemption. A vendor that starts
  crawling from an address publishes it within a day; a spoofer's address
  never appears. Bait paths count throughout, as for every client.
- **The first sighting is the instance's, in the database.** A row of
  `KilnCMS.Security.CrawlerSighting` (table `crawler_sightings`) per hashed
  client and engine, dated by the database's clock, written and read by
  `KilnCMS.Security.CrawlerSightingStore` in one upsert that keeps the
  earliest live sighting. Each question moves the row's expiry to
  `:listing_ttl_ms` (48 hours) on; a client idle longer, or a row the hourly
  prune removed, starts a new grace. Each node keeps a read-through copy
  (`:max_listing_entries`, 100,000 clients; `:listing_refresh_ms`, 5 minutes),
  so a busy client costs one statement per refresh, not one per 404.
- **Failure errs toward not counting.** When the database cannot answer, a
  node's copy decides if it has one, and otherwise the claim is not overdue;
  the node asks again after `:listing_retry_ms` (30 seconds), logs an error
  at most once a minute, and emits
  `[:kiln_cms, :crawler_verification, :sighting_unavailable]`.

### A `/64`'s own misses are the evidence for an unverifiable claim (#3450)

- **A claim tally.** An IPv6 `{:unverified, :unverifiable}` claim (not
  IPv4-mapped) from an unmarked `/64` is first charged to a ThrottleStore
  bucket of its own, `scanner_404_claim`, with the same key (site and `/64`),
  `threshold` and `window_ms` as the miss counter. While the tally allows,
  the miss is exempt.
- **Past the tally, the miss counts.** Once the tally denies, the miss also
  charges the ordinary miss counter, `scanner_404`, and trips it like any
  other miss, with the reason `miss_threshold`. This is how the owner's
  words are read: the `/64`'s claims start counting toward the threshold once
  the `/64` has made `threshold` of them. A `/64` making only such claims
  therefore trips on miss `2 × threshold + 1` of a window (121 with the
  defaults); one that mixes them with counted misses trips once its counted
  misses plus its claims beyond the first `threshold` pass `threshold`.
- **Unchanged.** A marked `/64` counts the claim at once (ADR 0086). Over
  IPv4 an unverifiable DuckDuckBot claim (no fresh list, or ranges off) keeps
  the exemption, since it is counted per address and has no rotation to
  close. The trip's reason, event and metadata are what they were.

## Rejected

- **Exempting `:not_listed` outright.** It would reverse 1.10.0's #2586 and
  give any spoofer typing "DuckDuckBot" from outside the list an exemption
  for good.
- **Keeping `:failed` and branching on `engine == :duckduckgo` in the
  guard.** The rate limiter, the telemetry and the guard would each have to
  know that one engine's "proven false" is not a proof. A reason of its own
  says it once.
- **A shorter freshness window for `:out`** (ADR 0055's open question). It
  changes the rate limiter for every DuckDuckBot claim, and still counts a
  real crawler on lag, only for less time.
- **Marking the `/64` on a list miss.** DuckDuckGo lists no IPv6 range, so it
  never happens over IPv6, and over IPv4 there is no `/64`.
- **Tallying `:not_listed` during the grace.** It would count a real
  crawler on a lagging list after `threshold` misses, which is the false
  block the grace is there to prevent.
- **Always counting IPv6 `:unverifiable`, or raising the threshold for it.**
  The owner rejected both on #3450: the first counts a real DuckDuckBot's
  every miss, the second is a setting nobody would tune.
- **Charging tallied misses to `scanner_404` from the first one.** That is
  the first rejected option under another name.
- **Keying the tally or the sighting by engine or user agent.** The claimant
  chooses both.
- **Keeping the first sighting per node, in memory.** This branch first did,
  and it was wrong: every deploy, restart and autoscale started each client's
  grace again, so an install that rolled more often than daily never counted
  a list-only spoofer at all, and two nodes counted the same client from
  different moments. The database's clock is the one every node shares.
- **Keeping the sighting in `throttle_counters`.** Its windows are
  epoch-aligned and short; a sighting needs a first moment that outlives
  them, and an expiry that moves on.
- **Writing the sighting in `check/3`.** It would put a write on every
  search-engine request's path, with the guard off too. Only the guard asks.

## Consequences

- With the 404 guard on, a real DuckDuckBot on an address DuckDuckGo has
  just added is no longer blocked for the list's lag; it is still charged as
  no user agent until a fetch names it.
- **Residual: an IPv4 spoofer gets about a day of exemption per address.** A
  DuckDuckBot spoofer outside the list keeps the miss exemption until a list
  fetched a full grace after its first miss, so 24 hours plus up to one fetch
  interval (6 hours): about 24 to 30 hours per address, at the no-user-agent
  rate, with bait paths counted. Moving to a new address starts again.
- **Residual: a database outage leaves new list-only spoofers exempt** for
  its length; a node's existing copies still count the clients they hold.
- **Residual: the table has no cap.** One row per distinct client outside the
  list, for at least 48 hours; a holder of an IPv4 `/16` could write 65,536
  rows, and so could a `/48` holder if a list ever carried IPv6 ranges for the
  engine. The hourly prune deletes lapsed rows in batches.
- **Residual: the stored key is pseudonymous, not anonymous.** `key_hash` is
  an unsalted SHA-256 of the client's address (or `/64`), as in
  `throttle_counters`, so anyone holding the table can test a guessed address
  against it. An HMAC is [#3501](https://github.com/The-Verscienta/kiln_cms/issues/3501).
- **Residual: mixing claims with counted misses.** A `/64` that sends
  `threshold` unverifiable claims and `threshold` counted misses in one window
  trips nothing, so it makes up to `2 × threshold` misses a window unblocked.
- **Residual: IPv4 `:unverifiable` DuckDuckBot stays exempt**, while the list
  is missing or stale, or ranges are off.
- **Residual: `:forward_error` stays exempt in any `/64`**, including a PTR
  name under a lame sub-delegation of a broad engine suffix; that is
  [#3451](https://github.com/The-Verscienta/kiln_cms/issues/3451), held for an
  owner decision.
- One additive migration and an hourly prune. Rolling the pin back is safe:
  the previous release ignores the table and goes back to counting list-only
  claims at once and exempting IPv6 DuckDuckBot.
