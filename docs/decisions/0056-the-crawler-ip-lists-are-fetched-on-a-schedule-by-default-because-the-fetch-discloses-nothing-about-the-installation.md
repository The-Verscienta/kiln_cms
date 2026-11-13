# 0056. The crawler IP lists are fetched on a schedule by default, because the fetch discloses nothing about the installation

- **Status** — accepted (2026-11-13), recording the choice #2851 shipped for
  #2586. It does not decide the general rule for scheduled calls, which
  [#2866](https://github.com/The-Verscienta/kiln_cms/issues/2866) leaves to
  the project owner.
- **References** — [#2586](https://github.com/The-Verscienta/kiln_cms/issues/2586)
  and [#2851](https://github.com/The-Verscienta/kiln_cms/pull/2851), which
  built it; [#2853](https://github.com/The-Verscienta/kiln_cms/issues/2853),
  which asked for this record and found the switch gap fixed with it;
  [ADR 0032](0032-a-default-on-check-that-tells-a-third-party-about-the-installation-follows-the-update-check-switch.md)
  for the default-on check that tells a third party about the installation,
  and its "Not decided here";
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)
  for what a list decides, and
  [ADR 0057](0057-one-node-fetches-the-crawler-ip-lists-and-the-others-re-check-what-it-sends.md)
  for how one fetch reaches every node.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md) (quoted from its long form in `docs/changelog/unreleased.md`):
  the upgrade note "Kiln now fetches Google's, Bing's, Apple's and
  DuckDuckGo's published crawler IP lists over HTTPS every 6 hours, on by
  default", and the Added entry it points to.

## The problem

Every outbound call a default install made before #2586 answered something:
an admin opened a page (the update check, the security notices, the plugin
health check), someone set a password (the breached-password check), or a
client claimed to be a search engine (crawler verification's DNS lookups).
The opt-in link checker runs nightly, but only for a site that turned it on.

A published crawler list is worth something only while it is fresh
(24 hours, [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)),
and nobody asks for it: no person opens a page that needs it, and the
request that needs it is a crawler's, which must never wait on an HTTPS
fetch. Keeping it fresh means fetching it on a timetable, which would make it
the first default-on call nobody asked for.

[ADR 0032](0032-a-default-on-check-that-tells-a-third-party-about-the-installation-follows-the-update-check-switch.md)
rejected "a request on a schedule or at boot" for the plugin health check:
it would tell hex.pm about the installation on a timetable, with nobody
having asked.

## Decision

**On by default, on a schedule, with one switch that stops every request.**

- **What is sent.** `KilnCMS.CrawlerVerification.RangesWorker` makes an
  unauthenticated HTTPS `GET` of four fixed URLs (one per vendor, in
  `KilnCMS.CrawlerVerification.Engines`) through `KilnCMS.SafeFetch`: a bare
  `KilnCMS` user agent, no query, cookie, version or identifier, no redirect
  followed, at most 512 KB read. Each vendor sees the fetching node's IP
  address and that it runs Kiln, and nothing about the sites, their
  visitors or the installation's configuration.
- **When.** An Oban cron job every 6 hours (`17 */6 * * *`,
  `KILN_CRAWLER_RANGES_CRON`), which runs on one node per cluster. A node
  with no fresh list also queues a fetch of just the stale engines about
  20 seconds after it boots and at its 10-minute checks
  (`KilnCMS.CrawlerVerification.RangesSync`). The job is unique for 10
  minutes across the cluster whatever ended the last run, so each vendor is
  asked at most about once per 10 minutes however many nodes ask or fail.
- **One switch.** `KILN_CRAWLER_RANGES=false`, or
  `KILN_CRAWLER_VERIFICATION=false`, stops every request: the cron job, the
  boot and stale-list fetches, and a job an operator queues by hand.
  `RangesWorker.refresh/2` checks the switch itself, from the application
  environment, and answers `:disabled` with no request, no telemetry and no
  broadcast. Until #2853 only `perform/1` checked it, so a direct call to
  `refresh/2` still reached the vendors.
- **A second switch for the timetable only.** `KILN_CRAWLER_RANGES_CRON=false`
  removes the cron job and every fetch a node would queue on its own; lists
  then come from a peer or a job the operator queues.
- **Off where nobody asked.** Dev starts with the lists off, unless
  `KILN_CRAWLER_RANGES=true`; the test and end-to-end environments never
  fetch.
- **Announced as an egress change.** The release that turns it on says so
  under Upgrade notes, naming the four hosts and the switch, and the
  [data flows](../data-flows.md#optional-subprocessors) row marks it as the
  one call made on a schedule.

**Why ADR 0032's rejection does not carry over.** 0032 rejected a schedule
because of what the request disclosed: which plugins this server runs. A
list fetch discloses what the update check's bare request does, that the
address runs Kiln, and 0032 already holds that a call disclosing nothing
about the installation is outside its terms (its "How this applies to calls
already made by default", on the GitHub fallback). The schedule adds a
timetable to a request that carries no information, not a timetable of
information.

**What this does not decide.** #2866's first question asks whether a future
check that *does* disclose installation details may run on a schedule with
other safeguards. This record does not answer it: the lists disclose none,
so the question does not arise here.

## Rejected

- **Opt-in.** DuckDuckBot would stay unverifiable on almost every install,
  and every Google, Bing and Apple claim would keep costing a DNS lookup that
  sends the visitor's address to the resolver
  ([ADR 0058](0058-crawler-verification-sends-a-visitors-address-to-the-dns-resolver-by-default.md)).
- **Fetch when the first claim arrives.** It would put an outbound HTTPS
  request behind visitor traffic, so anyone could set it off by sending a
  user agent, and the first claims would still find no list.
- **Fetch when an admin asks,** as the plugin health check does. A list goes
  stale in a day; on most installs nobody would ask that often.
- **Ship the lists in the release.** They would be stale within a day of
  the release, so a release-bundled list would need its own, looser,
  freshness rule, and an install that upgrades rarely would trust an old
  list for months.

## When to revisit

- The owner answers #2866: a rule for scheduled calls, or one switch for
  every default-on outbound call (question 4).
- A vendor asks for authentication, rate limits the URL, or changes its terms.
- The fetch starts sending anything beyond the fixed URL and user agent.
