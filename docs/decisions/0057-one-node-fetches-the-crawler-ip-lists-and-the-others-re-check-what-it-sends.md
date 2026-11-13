# 0057. One node fetches the crawler IP lists, and the others re-check what it sends

- **Status** — accepted (2026-11-13), recording the design #2851 shipped for
  #2586.
- **References** — [#2586](https://github.com/The-Verscienta/kiln_cms/issues/2586)
  and [#2851](https://github.com/The-Verscienta/kiln_cms/pull/2851), which
  built it; [#2853](https://github.com/The-Verscienta/kiln_cms/issues/2853),
  which asked for this record;
  [ADR 0056](0056-the-crawler-ip-lists-are-fetched-on-a-schedule-by-default-because-the-fetch-discloses-nothing-about-the-installation.md)
  for why the lists are fetched on a schedule, and
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)
  for what a fresh list decides.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md) (quoted from its long form in `docs/changelog/unreleased.md`):
  "Search-engine claims are checked against the engines' published crawler
  IP lists before DNS" (Added).

## The problem

Every node checks claims, so every node needs the four lists, and needs to
know how old each one is: a list over 24 hours old decides nothing. The
lists are a few kilobytes to a few tens of kilobytes each and change a few
times a day at most. Three questions follow:

- Which node fetches, and how often are the vendors asked?
- How does a list reach the other nodes, and what does a receiving node
  trust about it? A peer may be on another release, with other parsing
  rules, and its clock may disagree.
- What happens to a node that misses a list?

## Decision

**One node fetches; every node installs what it receives only after
checking it again, and dates it by its own clock.**

- **One fetch per cluster.** `KilnCMS.CrawlerVerification.RangesWorker` is
  an Oban cron job, so one node runs it per schedule. It installs each list
  it accepts and sends it on `KilnCMS.CrawlerVerification.Ranges.topic/0`
  over Phoenix PubSub, which travels over Erlang distribution between peers
  that are already trusted.
- **The payload carries an age, not a time.**
  `{:crawler_ranges, 1, engine, cidrs, age_ms}`: the ranges as CIDR strings,
  and how long ago the list was fetched, measured by the sender as it sends.
  `KilnCMS.CrawlerVerification.RangesSync` dates the list from its own
  monotonic clock (receipt minus `age_ms`), so nodes whose wall clocks
  disagree still agree on how fresh a list is.
- **Receivers re-parse under their own rules.** `RangesSync.install/2` runs
  every range through `Ranges.Parser.parse_strings/2` again, so a peer on
  another release, or a bad payload, cannot install a list this node's own
  fetch would refuse. It also ignores a payload of another version
  (`Ranges.version/0`, for mixed releases during a rolling deploy), one
  for an engine this node has no source for, one already older than 24
  hours, one older than the list it holds, and anything malformed.
- **Installs are serialized.** Every `Ranges.put/3` runs in `RangesSync`'s
  process, one at a time, so a node's own fetch and a peer's list cannot
  interleave and leave an older list under a newer fetch time.
- **Delivery is best effort, and a miss heals itself.** A node asks its
  peers for every fresh list at boot, on each `:nodeup`, and at each
  10-minute check while a list is not fresh, and queues a fetch of the stale
  engines itself (the job is unique for 10 minutes cluster-wide). A node
  that still has no fresh list falls back to DNS (DuckDuckBot to "not
  proven") once its own list goes stale, which is the same answer as no
  list, and logs a warning once per engine.
- **Memory only.** A list lives in `:persistent_term` (rewritten only when
  its content changes) with its fetch time in `:atomics`. Nothing is
  written to the database.

## Rejected

- **Every node fetches its own lists.** Each vendor would be asked N times
  per run for the same file, and nodes would disagree about who is verified
  for up to a run's interval. A unique job and a broadcast cost one fetch.
- **A Postgres table of lists.** It would survive a full cluster restart and
  serve a node that cannot reach its peers. It would also cost a migration,
  a schema held to expand/contract across releases, and a read path, for
  tens of kilobytes that change every few hours. A restarted cluster queues
  its own fetch about 20 seconds after boot, unless the schedule is off.
- **Send the sender's wall-clock fetch time.** Clock skew between nodes
  would make a fresh list look stale, or a stale one fresh.
- **Install the sender's parsed result as is.** The checks that refuse a
  list (width, non-public space, size) are this release's; a peer on another
  release may check less.

## Consequences

- A release that changes the payload's shape must bump its version. Until
  every node runs the same release, a node ignores lists from peers on the
  other version, and gets its lists from a fetch it queues (which any node
  may run) or falls back to DNS.
- A node cut off from its peers keeps its own lists until they go stale,
  then falls back to DNS. The fetch its 10-minute check queues may run on
  another node, whose broadcast it would miss.
