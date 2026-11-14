# 0054. In crawler verification, a silence the claimant controls counts against it, and one the vendor controls does not

- **Status** — accepted (2026-11-13), recording the rule #2837 shipped for
  #2588. It decides how the smart 404 guard reads a DNS lookup that got no
  answer; what the rate limiter charges for one is unchanged.
- **References** — [#2588](https://github.com/The-Verscienta/kiln_cms/issues/2588)
  and [#2837](https://github.com/The-Verscienta/kiln_cms/pull/2837), which
  built it; [#2841](https://github.com/The-Verscienta/kiln_cms/issues/2841),
  which asked for this record; #2254 and
  [#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591) for the
  verifier itself; the open questions
  [#2840](https://github.com/The-Verscienta/kiln_cms/issues/2840) and
  [#2838](https://github.com/The-Verscienta/kiln_cms/issues/2838) (see the
  last section);
  [ADR 0055](0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md)
  for the claims a published list decides instead.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md) (quoted from its long form in `docs/changelog/unreleased.md`):
  "Crawler verification holds up better against lookup starvation, cache
  churn and silent reverse zones" (Security), and its upgrade note on the
  404 guard.

## The problem

With `KILN_SCANNER_BLOCKING` on, `KilnCMS.Security.ScannerGuard` blocks an
address that racks up 404s, but a client whose user agent names a search
engine skips the miss threshold until `KilnCMS.CrawlerVerification` proves the
claim false. A real crawler's misses must not get its address blocked; a
scanner that types "Googlebot" must not get the same pass.

The DNS check asks two zones. The PTR query goes to the reverse zone of the
client's address, which whoever holds the address controls. The forward
query, for a name the PTR record gave, goes to the engine's own zone
(`googlebot.com`, `search.msn.com`), which only the engine controls. Either
can go unanswered: a timeout, a SERVFAIL, a refused query.

Until #2837 every unanswered lookup kept the exemption, because a DNS error
is not proof of a lie. That let a scanner on a network whose reverse zone it
leaves silent (a tunnel broker's IPv6 space, say) claim to be Googlebot and
never be counted. Counting every silence instead would count real crawlers
whenever DNS itself is down. So the question was whose silence it is, and how
a node tells "this address's zone is silent" from "my resolver is broken".

## Decision

**A silence counts against the claim when the claimant could have caused it,
and never when only the engine could have.** In
`ScannerGuard`'s `exempt_claim?` clauses:

- **A PTR query with no answer counts, while the resolver is healthy.**
  `CrawlerVerification.check/3` answers `{:unverified, :error}`, and the claim
  keeps the exemption only while `CrawlerVerification.resolver_failing?/1` is
  true. Otherwise the silence is the address's own reverse zone, and its
  misses count like anyone's.
- **A forward query with no answer, for a name under the claimed engine's
  domain, keeps the exemption,** whatever the resolver's health. `check/3`
  answers `{:unverified, :forward_error}`. Only Google can make a
  `googlebot.com` name go silent, so a scanner cannot buy the exemption this
  way: it would need a PTR record naming a host under the engine's domain,
  then a silence it does not control.
- **The forward query must have had its full budget.** It is
  `:forward_error` only when it was given at least `:query_timeout_ms`
  (1 second) before the lookup's 3-second deadline. A PTR answer slow enough
  to starve it is the client's zone at work, so that reads as plain `:error`.
  So does a cached result written before the budget was recorded: an unknown
  budget counts toward the client, never toward the exemption.
- **A proven failure counts, and everything else keeps the exemption,** as
  before: verified, pending, skipped, unverifiable and not-public claims.

**"The resolver is failing" is decided by a canary, a PTR query for a fixed
third-party address.** `resolver_failing?/1` is false while some lookup on
this node got an answer within `:health_window_ms` (1 minute). Otherwise it
starts at most one canary per window: the same bounded lookup a claim gets,
for `:canary_address` (`8.8.8.8` by default, configurable), never a visitor's
address. The canary runs on a one-slot supervisor of its own, so it runs
even when every lookup slot is busy, and it charges no rate cap and caches
nothing. An unanswered canary marks the resolver failing; an answered one
marks it healthy and counts as a fresh answer.

As #2837 put it, an attacker can't make a fixed, well-run reverse zone go
silent, so they can't fake "resolver down" with their own silent lookups. A
counter of consecutive errors could be driven by those lookups, which is why
the canary decides instead.

**Until a canary has found otherwise, the resolver is healthy.** While the
window's canary runs, or when it cannot start, the last verdict holds, and
that verdict starts as healthy: misses count. A scanner who sets off the
check gets no free window while the canary is out. While the verifier's own
processes are restarting, `resolver_failing?/1` also answers false.

**The canary is off unless the 404 guard is on.** `ScannerGuard` is the only
caller of `resolver_failing?/1`, and it asks only for an `:error` claim, so
a default install (`KILN_SCANNER_BLOCKING` unset) never sends one.

**A node that cannot reach the canary keeps the exemption.** If a node's
resolver cannot reach `8.8.8.8`'s reverse zone, while also getting no
answers for claims, the canary reads failing, and PTR silences keep the
exemption, as before #2837. A node with no DNS egress at all behaves this
way. Here the guard fails toward exempting, which is toward not blocking.

## Rejected

- **Every silence keeps the exemption (the 1.9.0 rule).** A scanner chooses
  its own reverse zone's behavior, so it could choose silence and never be
  counted.
- **Every silence counts.** A forward silence is in the engine's zone, so a
  DNS problem at Google or Bing would get real crawlers blocked. A PTR
  silence during a resolver outage would do the same to every crawler at
  once.
- **A count of consecutive errors as the health signal.** The node already
  keeps one, for its "20 DNS lookups in a row" warning. As a decision it can
  be driven by the attacker's own silent lookups: enough of them in a row
  would read as "resolver down" and restore the exemption for everyone.
- **A canary chosen from the traffic,** such as the last address that
  answered. The attacker shapes the traffic. A fixed address in a zone run by
  a large operator is outside their reach; the address is configurable for a
  node whose resolver cannot see `8.8.8.8`.
- **Counting a forward silence however little time it had.** A client's
  reverse zone can answer just before the deadline and leave the forward
  query no time, turning its own delay into the engine's silence.

## Consequences

- With the 404 guard on, a real crawler whose reverse zone is slow or flaky
  (Baidu's and Yandex's are the likeliest) is counted like a silent one while
  the resolver answers other lookups, and its address can be blocked. The
  block expires, and an admin can remove it.
- A partial recursion outage can look healthy: an answer the resolver serves
  from its cache (the canary's included) marks it working for a minute while
  the queries it must recurse for fail. Real crawlers' misses are counted
  meanwhile. Both cases are residuals in the
  [threat model](../threat-model.md#scanner-404-blocking-2253).
- The rate limiter is unaffected: `:error` and `:forward_error` are both "not
  proven", held to the browser ceiling.

## Not decided here

- **Whether a PTR answer whose forward query errored is an answer.** For the
  resolver-health signal, a lookup whose PTR query answered but whose forward
  query got no answer counts as unanswered today: it does not refresh the
  last-answer time `resolver_failing?/1` reads, and it advances the
  consecutive-errors warning, though the resolver did answer.
  [#2840](https://github.com/The-Verscienta/kiln_cms/issues/2840), question 1,
  decides it.
- **Rotation inside one IPv6 `/64`.** The guard counts IPv6 per `/64`, but a
  claim is checked per address, and pending and skipped claims keep the
  exemption. A scanner sending each request from a fresh address in its `/64`
  is always judged before its lookup has finished, or with none started, so
  the silence rule above never reaches it.
  [#2838](https://github.com/The-Verscienta/kiln_cms/issues/2838) decides it.
