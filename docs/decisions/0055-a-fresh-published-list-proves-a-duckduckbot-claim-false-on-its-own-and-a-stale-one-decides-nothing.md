# 0055. A fresh published list proves a DuckDuckBot claim false on its own, and a stale one decides nothing

- **Status** — accepted (2026-11-13), recording the rule #2851 shipped for
  #2586. It covers what a published crawler list decides when a claim is
  classified and charged. What the smart 404 guard does with a claim the list
  alone proved false is open (#2852).
- **References** — [#2586](https://github.com/The-Verscienta/kiln_cms/issues/2586)
  and [#2851](https://github.com/The-Verscienta/kiln_cms/pull/2851), which
  built it; [#2853](https://github.com/The-Verscienta/kiln_cms/issues/2853),
  which asked for this record;
  [#2852](https://github.com/The-Verscienta/kiln_cms/issues/2852) for the
  404 guard;
  [ADR 0056](0056-the-crawler-ip-lists-are-fetched-on-a-schedule-by-default-because-the-fetch-discloses-nothing-about-the-installation.md)
  and
  [ADR 0057](0057-one-node-fetches-the-crawler-ip-lists-and-the-others-re-check-what-it-sends.md)
  for how the lists are fetched and shared.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md) (quoted from its long form in `docs/changelog/unreleased.md`):
  "Search-engine claims are checked against the engines' published crawler
  IP lists before DNS" (Added), and its upgrade note.

## The problem

Google, Bing, Apple and DuckDuckGo each publish a list of their crawlers'
addresses (`KilnCMS.CrawlerVerification.Engines`). A list can say an address
is in it, that it is not, or nothing at all, and each answer could mean
something different for each engine:

- Google, Bing and Apple can also be checked by DNS (reverse, then forward).
  DuckDuckGo publishes no reverse-DNS domain, so for DuckDuckBot the list is
  the only evidence there is. Before #2586 every DuckDuckBot claim was "not
  proven", for anyone who typed the name.
- A list lags the vendor. An address the vendor started crawling from an
  hour ago is not in a list fetched six hours ago.
- A list can stop being refreshed (the vendor moves it, the node loses
  egress), and an address in an old list may no longer be the vendor's.

## Decision

`KilnCMS.CrawlerVerification.Ranges.lookup/3` answers `:in`, `:out` or
`:unknown`, and `CrawlerVerification.check/3` reads it before DNS:

- **`:in` verifies, for every engine.** No DNS query, no lookup charged
  against the rate caps, nothing cached. The rate limiter gives the
  search-engine ceiling.
- **`:out` falls back to DNS for an engine DNS can check.** For Google, Bing
  and Apple a lagging list never makes a real crawler a failure: DNS
  verifies it, or proves it false, as before.
- **`:out` proves a DuckDuckBot claim false on its own.** `check/3` answers
  `{:unverified, :failed}`, and the rate limiter charges it as no user agent
  (60 a minute with the defaults). Nothing else can check the claim, and
  the list is the vendor's own statement of where DuckDuckBot crawls from.
- **`:out` needs a range of the address's family.** DuckDuckGo lists IPv4
  only, so a DuckDuckBot claim over IPv6 is `:unknown`, never `:out`.
- **A list is fresh for 24 hours (`:max_age_ms`), and a stale or missing
  list decides nothing.** It is `:unknown`: Google, Bing and Apple go to DNS,
  and DuckDuckBot is "not proven" (`{:unverified, :unverifiable}`), held to
  the browser ceiling, as before #2586. A stale list never verifies an
  address and never proves a claim false.
- **Age is this node's knowledge, not the vendor's date.** A list is dated
  from when a node fetched it (by the fetching node's carried age, for a
  list a peer sent), never from the `creationTime` it states. A fetch that
  fails, or a list Kiln refuses, keeps the list held before with its old age,
  so it ages toward stale rather than being replaced.

24 hours is four missed 6-hourly fetches: long enough that a vendor outage
or a firewall change is noticed (a warning is logged per engine at the
10-minute checks) before the list stops deciding, and short enough that a
list nobody can refresh stops vouching for addresses within a day.

## Rejected

- **Keep a DuckDuckBot claim outside the list "not proven".** That was the
  behavior before #2586, and the issue required the opposite: anyone could
  claim to be DuckDuckBot and keep the search-engine class forever.
- **Let `:out` fail Google, Bing and Apple too.** It would save a DNS lookup
  per spoof, and turn every lag in the vendor's list into a real crawler
  charged as no user agent, when DNS can settle it.
- **Trust a list of any age.** A list that can no longer be fetched would
  keep verifying addresses the vendor gave up (Bing's list names `/28`s in
  Azure space, which change hands) and keep failing DuckDuckBot's new
  addresses, with nothing to end it.
- **Date a list by its `creationTime`.** The question is how current this
  node's copy is. A vendor's date says when the vendor wrote it, and depends
  on the vendor's clock and on any cache in front of the URL.

## Consequences

- **DuckDuckBot list lag.** A real DuckDuckBot on an address DuckDuckGo added
  since this node's last successful fetch is charged as no user agent until
  the next fetch (normally within 6 hours; at most 24, after which the list
  is stale and its claims are "not proven" again). With the smart 404 guard
  on, its misses count and its address can be blocked. This is the
  [threat model](../threat-model.md#bot-budgets)'s "DuckDuckBot list lag"
  residual. [#2852](https://github.com/The-Verscienta/kiln_cms/issues/2852)
  decides whether the guard should exempt a claim the list alone proved
  false, and may also give `:out` a shorter freshness window than `:in`,
  which would change this record's single 24-hour rule; this record decides
  neither.
- A list verifies whatever the vendor put in it. Kiln refuses a list whole
  when it would verify too much (a range wider than IPv4 `/20` or IPv6 `/48`,
  non-public space, too many entries), but an address the vendor listed is
  trusted with no other check.
