# 0058. Crawler verification sends a visitor's address to the DNS resolver by default

- **Status** — accepted (2026-11-13), recorded after the fact. #2254 shipped
  the call on by default in 1.9.0
  ([#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591)). That pull
  request argued the functional case: only a claim DNS proves false is
  penalized, demoting every unverified claim was rejected, and a higher
  ceiling for verified crawlers was left to #2587, which builds on the
  check. It documented what
  leaves the server, in the data flows, but never argued the privacy side of
  sending a visitor's address out by default. This record writes that case
  down as the code stands, for the project owner to confirm or overturn
  (see "When to revisit").
- **References** — [#2254](https://github.com/The-Verscienta/kiln_cms/issues/2254)
  and [#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591), which
  built it; [#2867](https://github.com/The-Verscienta/kiln_cms/issues/2867),
  which asked for this record;
  [#2866](https://github.com/The-Verscienta/kiln_cms/issues/2866) for the
  open rule on calls that send data about people;
  [ADR 0032](0032-a-default-on-check-that-tells-a-third-party-about-the-installation-follows-the-update-check-switch.md),
  whose "How this applies to calls already made by default" names this call
  as unargued; [ADR 0031](0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md)
  for the other default-on call that sends something derived from a person;
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)
  for the list-only check DuckDuckBot gets.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#verified-search-bots)
  (Added), with its [upgrade note](../changelog/v1.9.0.md#verified-search-bots-upgrade).

## The problem

A user agent is whatever the client typed, so anyone can claim to be
Googlebot. The check every engine documents is DNS: look up the address's
PTR name, require it under the engine's domain, and look that name up
forward to see that it contains the address again
(`KilnCMS.CrawlerVerification`). Those queries carry the client's address.
They go to the node's resolver, and from there to the operator of the
address's reverse zone. Making them by default means a default install sends
some visitors' addresses to parties the site's owner may never have heard
of. It is the most privacy-relevant call Kiln makes by default.

## Decision

**On by default, for search-engine claims only, with one switch,
`KILN_CRAWLER_VERIFICATION=false`.**

### What leaves the server, and who sees it

- **To the node's resolver,** the nameservers in its `/etc/resolv.conf`
  (`KilnCMS.CrawlerVerification.InetResolver`, over OTP's `:inet_res`): a PTR
  query for the client's `in-addr.arpa` or `ip6.arpa` name, then an A or
  AAAA query for up to two of the first three PTR names that fall under a
  search engine's domain. At most three queries per lookup. They are plain
  DNS from the node; whether they are encrypted beyond the resolver depends
  on the resolver the operator chose (the host's, the cloud's, or a public
  one). The resolver's operator sees the node's address and the client's.
- **To the operator of the address's reverse zone** (usually its ISP or
  hosting provider): the PTR query, as the resolver sends it. That operator
  learns that something looked its address up, and when.
- **To the engine's own nameservers:** the forward query, for a name the
  reverse zone gave, which usually encodes the address
  (`crawl-66-249-66-1.googlebot.com`). Only names under an engine's domain
  are ever queried forward, so an attacker's PTR name is never resolved.
- **Nothing else.** No user agent, path, site, cookie or other request data,
  and no address, hostname or user agent in any telemetry event or log
  line. The resolver-health canary of
  [ADR 0054](0054-in-crawler-verification-a-silence-the-claimant-controls-counts-against-it-and-one-the-vendor-controls-does-not.md)
  carries no visitor data.

### Whose address, and when

The scope is the real case for default-on. A lookup happens only for a
public delivery request (a page, `/search`, a media download or stream)
whose user agent names Googlebot, Google-InspectionTool, bingbot, Applebot,
YandexBot or Baiduspider (`KilnCMS.BotClass.search_engine/1`), and only:

- from a public address that is not a trusted proxy and did not arrive
  through a forwarding header nothing trusts;
- when the address is not in the claimed engine's fresh published list
  (since #2586; an address in it is verified with no query);
- when the address has no cached result on that node (6 hours verified,
  1 hour proven false, 5 minutes after a DNS error);
- within the per-network and per-node lookup caps.

A DuckDuckBot claim never reaches DNS. A browser's own user agent names no
search engine, so a person browsing the site is not looked up. The address
that leaves is that of a client claiming to be a crawler: either the
engine's own crawler, whose address the engine publishes as its own, or
someone pretending to be one.

### Why on by default

- Without it a spoofed claim cannot be told from a real one, so the search
  engine class's ceiling goes to anyone who types the name. The default
  above the browser ceiling for verified crawlers (200%, #2587) is safe only
  because an unverified claim is held to the browser ceiling.
- The smart 404 guard's search-engine exemption is only worth having if a
  scanner cannot buy it with a user agent.
- An install that cannot or will not make the queries turns them off with
  one variable, and the
  [data flows](../data-flows.md#optional-subprocessors) list it among the
  calls a no-egress deployment must switch off.

### The switch

`KILN_CRAWLER_VERIFICATION=false` stops every query, the canary, and the
published-list fetches. Every search-engine claim is then believed for rate
limiting, as in 1.8, the search-engine default drops to 100%, and the 404
guard exempts the engines by name.

## Rejected

- **Opt-in.** Few installs would turn it on. On the rest, the search-engine
  ceiling would be open to any spoofer, and the higher default for verified
  crawlers could not ship.
- **Published lists only, as DuckDuckBot is checked.** Yandex and Baidu
  publish no list, so their claims could never be checked. For Google, Bing
  and Apple, an address outside a lagging list would have to be a failure
  (as it is for DuckDuckBot), so every lag in a vendor's list would charge a
  real crawler as no user agent; DNS is what settles those addresses. Since
  #2586 the lists already answer most real crawler traffic with no query.

## When to revisit

- **The owner's answer to #2866, question 3:** whether a call that sends data
  about people needs a rule of its own, and where this one sits under it.
  That answer comes first and may overturn this record.
- #2866, question 4: one switch for every default-on outbound call.
- The engines without a list (Yandex, Baidu) publish one, or every engine's
  list covers all its crawlers: DNS could then be left for the addresses a
  list does not name.
- Anything widens who is looked up: another class of user agent, or a
  non-public or proxied address.
