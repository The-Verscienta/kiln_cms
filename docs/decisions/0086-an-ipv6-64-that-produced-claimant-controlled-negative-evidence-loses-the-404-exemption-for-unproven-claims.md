# 0086. An IPv6 `/64` that produced claimant-controlled negative evidence loses the 404 exemption for unproven claims

- **Status** — accepted (2026-11-26). Partly supersedes
  [ADR 0054](0054-in-crawler-verification-a-silence-the-claimant-controls-counts-against-it-and-one-the-vendor-controls-does-not.md):
  its "everything else keeps the exemption" no longer holds for an IPv6
  claim from a marked `/64`. It decides how the smart 404 guard reads an
  unproven search-engine claim; what the rate limiter charges for one is
  unchanged.
- **References** — [#2838](https://github.com/The-Verscienta/kiln_cms/issues/2838),
  which this closes; ADR 0054's "Not decided here", which handed it on;
  #2588 and [#2837](https://github.com/The-Verscienta/kiln_cms/pull/2837) for
  the silence rule it builds on;
  [#2852](https://github.com/The-Verscienta/kiln_cms/issues/2852), still
  open, for DuckDuckBot outside its published list;
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)
  for the claims a published list decides.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Security
  ([long form](../changelog/unreleased.md#scanner-guard-ipv6-rotation)).

## The problem

With `KILN_SCANNER_BLOCKING` on, `KilnCMS.Security.ScannerGuard` counts
delivery 404s per address, and an IPv6 client per `/64`, because a host can
rotate through its whole prefix. A client whose user agent names a search
engine skips the miss threshold until `KilnCMS.CrawlerVerification` proves
the claim false. But a claim is checked per **address**: the first request
from a new address is `{:unverified, :pending}` while its lookup runs, and a
lookup turned away by a cap or a busy slot is `{:unverified, :skipped}`. Both
kept the exemption.

So a scanner typing "Googlebot" and sending each request from a fresh
address in its `/64` was always judged before its own lookup finished, or
with none started. Its lookups failed, one by one, and each failure was
cached against an address it never used again. The counter for the `/64`
never moved. ADR 0054's rule that a silent reverse zone counts against the
claimant never reached it either, for the same reason.

Counting every unproven claim would close that, and would count every real
crawler's first misses from a new address, which is what the exemption is
for.

## Decision

**A finished lookup that produced evidence the claimant controls marks the
address's `/64`, and an unproven claim from a marked `/64` is counted.** A
verified claim stays exempt, always.

- **Two kinds of mark, written only by a finished lookup of the request's
  own address** (`CrawlerVerification`'s `mark_network/3`):
  - `:failed`, when the lookup proved the claim false
    (`{:unverified, :failed}`: no PTR record, a name outside the engine's
    domain, a forward mismatch).
  - `:silent`, when the address's PTR query got no answer
    (`{:unverified, :error}`) **while this node's resolver answers**
    (`resolver_failing?/1` false). It is also read only while the resolver
    answers: during an outage a silence says nothing about the network.
- **What reads a mark.** `ScannerGuard`'s `exempt_claim?/2` asks
  `CrawlerVerification.network_flagged?/2` only for a claim nothing has
  proven either way: `{:unverified, :pending}`, `:skipped`, `:unverifiable`
  (an engine with nothing to check it against, such as DuckDuckBot over
  IPv6), and `:error` while the resolver is failing. A `:failed` mark
  counts all of them; a `:silent` one counts only while the resolver
  answers, which leaves the outage case to a `:failed` mark.
- **What never writes a mark.** A lookup turned away by a network cap, the
  node cap or a busy slot: an attacker can spend those from other networks,
  so a refusal is no evidence about the network refused. A `:forward_error`,
  which is the engine's own zone (ADR 0054). A claim settled by a published
  range list, since no DNS lookup runs. A lookup while the 404 guard is off,
  since nothing else reads marks.
- **What a mark never overrides.** `:verified`, `:disabled`, `:not_public`
  and `:forward_error` keep the exemption whatever the `/64`'s mark. The
  forward-error case keeps ADR 0054's reasoning: only the engine can make its
  own zone go silent.
- **A verified lookup clears a `:silent` mark, never a `:failed` one.** Only
  the engine's own DNS produces a verified result, so one timed-out PTR query
  for a real crawler does not outlive the crawler's next verified address. A
  `:failed` mark is proof that some address in the `/64` lied, and a real
  crawler there loses nothing by it but the exemption of its own unproven
  claims. A `:silent` mark never replaces a `:failed` one (an atomic
  `Cachex.get_and_update/3`).
- **Keyed by the `/64` alone, IPv6 only, per node.** Never by engine, user
  agent or org, so a `/64` that lied as Googlebot cannot switch to a
  DuckDuckBot user agent. IPv4 is counted per address, so an address's own
  verdict already lines up with what is counted; an IPv4-mapped IPv6 address
  is the IPv4 client it carries.
- **Bounded and short-lived.** Marks live in a Cachex instance of their own,
  `:kiln_cms_crawler_verification_networks`, capped at `:max_network_marks`
  (10,000) networks, so a flood of marks cannot evict a verification result,
  and every write refreshes the entry's `:network_mark_ttl_ms` (1 hour).

## Rejected

- **Counting every pending and skipped claim.** It closes the rotation, and
  counts every real crawler's first misses from each new address.
- **Marking on a refused lookup** (an earlier draft's `:capped` mark). The
  `/32` and `/48` lookup caps, the node cap and the 16 slots are shared: an
  attacker spending them from other `/64`s would mark a real crawler's `/64`
  without that network ever producing an answer.
- **Keying the mark by engine or user agent.** The claimant chooses both.
- **Clearing a `:failed` mark on a verified lookup.** A verified address does
  not make another address in the `/64` honest.
- **The guard waiting for the lookup.** A request would hold a lookup slot
  for up to 3 seconds, and a flood of claims would fill the 16 slots and
  fail open anyway.
- **Sharing marks across nodes**, through the throttle table or PubSub. It
  would put a write on the DNS path to close a gap of about one lookup
  deadline per node (below).
- **Keeping marks in the verifier's result cache**, or per address. A mark
  names a network, and a flood of them must not evict a result.
- **Marking IPv4 networks.** The guard counts IPv4 per address, so there is
  no rotation inside one counted client to close.

## Consequences

- With the 404 guard on, a spoofer rotating through its `/64` is counted
  from the moment one of its lookups finishes failed or silent, and blocked
  at the threshold like any client. Bait paths count for everyone, as before.
- A real crawler's unproven claims are counted in a `/64` that has failed a
  lookup in the last hour; its verified addresses are not. A shared `/64`
  (one hosting provider's customers) can therefore count a real crawler's
  first misses there. The block expires, and an admin can remove it.
- Residuals, listed in the
  [threat model](../threat-model.md#bot-budgets): marks are per node; the
  first claims from an unmarked `/64` are exempt until a lookup finishes; a
  `/64` whose lookups are all refused is never marked; the first silent
  lookup of an outage can still write a `:silent` mark; DuckDuckBot in an
  unmarked IPv6 `/64` and a `:forward_error` claim stay exempt; a `/48`
  holder rotating across `/64`s is out of scope.
- No migration and no telemetry change. Rolling the pin back drops the mark
  cache and restores the old rule.

## Not decided here

- **DuckDuckBot outside its published list.** It stays
  `{:unverified, :failed}` and counted, as since 1.10.0;
  [#2852](https://github.com/The-Verscienta/kiln_cms/issues/2852) decides
  whether that changes.
- **Rotation across `/64`s.** The guard counts per `/64`, so a holder of a
  `/48` or wider gets a fresh counter, and a fresh mark, per `/64`.
