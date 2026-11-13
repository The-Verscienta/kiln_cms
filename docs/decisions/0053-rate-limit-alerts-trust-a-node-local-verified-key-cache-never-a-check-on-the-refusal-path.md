# 0053. Rate-limit alerts trust a node-local verified-key cache, never a check on the refusal path

- **Status** — accepted (2026-11-13), recording the design #2808 shipped. It
  refines [ADR 0027](0027-security-alerts-derive-from-the-audit-log-and-turning-a-sites-alerts-down-is-never-silent.md),
  which states the cache; this record argues why the check is not made
  where the refusal happens, and why the cache is not shared between nodes.
- **References** — [#2812](https://github.com/The-Verscienta/kiln_cms/issues/2812)
  and [#2813](https://github.com/The-Verscienta/kiln_cms/issues/2813), which
  asked for this record and the multi-node caveats;
  [#2245](https://github.com/The-Verscienta/kiln_cms/issues/2245) (the owner
  decision of 2026-11-12 on rate-limit-trip alerts) and
  [#2808](https://github.com/The-Verscienta/kiln_cms/pull/2808), which built
  it; [ADR 0027](0027-security-alerts-derive-from-the-audit-log-and-turning-a-sites-alerts-down-is-never-silent.md),
  the parent record.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md)
  (#2808).

## The problem

`api_key_rate_limited` tells the platform admins that a **verified** API key
went over a rate limit (`KilnCMS.Security.ApiKeyTrip`). "Verified" matters:
anyone can send `Authorization: Bearer kiln_…` with a made-up string, and an
alert on that would let a stranger fill the platform's bell, or use up the
real key's alert for the window.

But `KilnCMSWeb.Plugs.RateLimit` runs first in every pipeline it guards
(`:api`, `:graphql`, `:mcp`, `:media_transform`, `:plugin_endpoint`, the
ActivityPub inbox), ahead of `KilnCMSWeb.Plugs.ApiKeyAuth`. At a `429` the
bearer is only a string someone sent. Something has to decide, at that
moment, whether it is a real key, and the obvious ways of deciding each cost
something on the one path that has to stay cheap.

## Decision

**A refusal trusts only what this node has already verified.**
`ApiKeyTrip.remember/2` is called by `ApiKeyAuth` (and by
`KilnCMSWeb.Plugs.RememberApiKey` on `/mcp`) after the key strategy
authenticated a request. It checks the plaintext against the key the actor
carries (decode, then the SHA-256 of the token against `api_key_hash`) and
only then stores the SHA-256 of the plaintext and the key's id in a named ETS
table owned by `ApiKeyTrip`. An entry lives 5 minutes (`ttl_ms/0`), is
rewritten at most once per half of that, and the table holds at most 10,000
entries, swept every minute.

At a refusal, `ApiKeyTrip.note/2` takes the key from the actor when one is
already authenticated (`:media_upload` runs after `:api`), otherwise from the
cache: one hash and one ETS read. A miss is a telemetry count and nothing
else. A hit is gated on the **verified key id**, in memory, and only what
passes reaches the database, off the request path, where the key is reloaded
and must still be valid.

Why that is enough on one node: the flood-ceiling buckets are counted per
client address in this node's ETS (`KilnCMSWeb.RateLimit`), so a trip here
means this node let the address's earlier requests through. When those
requests carried the key, `ApiKeyAuth` remembered it, and the refusal finds
it.

**The cache is per node, and that is documented rather than fixed.** The
cases where it misses on a cluster are written down for operators in
[Security alerts, "Running more than one server"](../security-alerts.md#running-more-than-one-server).

## Rejected

- **Verify the presented key at the refusal.** It is one database read per
  refused request (`Accounts.actor_from_api_key/1`, or a lookup by the key id
  the string decodes to). A refusal is the answer to a flood, and a client
  that sends a fresh string each time turns every refused request into a
  read: the amplification `KilnCMSWeb.RateLimit` keeps these buckets out of
  the database to avoid ("a database round trip per request would be the
  flood's own amplifier"). ADR 0027 rejects gating on the presented string;
  this is the step before it, checking the string at all.
- **Trust the key id the string decodes to.** The id is part of the
  plaintext (`KilnCMS.Accounts.ApiKeyReuse.decode/1`), so it costs nothing to
  read, but anyone who learns a key's id could raise alerts in its name, or
  use up its window, without the secret. Only an id that came out of a
  successful verification is used.
- **A cluster-wide cache in Postgres** (`KilnCMS.Accounts.ThrottleStore` or
  a table like it). The write side could be bounded the way `remember/2`
  already bounds it, but the read moves to the refusal: every refused request
  that carries a key-shaped string, forged ones first, becomes a database
  lookup. That is the first rejected option under another name.
- **Broadcast remembered entries over `Phoenix.PubSub`.** Cheap on the write
  side (`remember/2` writes at most once per 2.5 minutes per key and node),
  and the refusal stays one ETS read. It was not taken for now:
  - every node would hold, and the cluster's distribution channel would
    carry, a hash of every live key. A hash does not authenticate, but it is
    still a table of the installation's keys in every node's memory;
  - a node that starts or restarts still begins empty, so it narrows the gap
    rather than closing it, at the cost of a subscriber and a message format
    that must work across a rolling deploy;
  - no multi-node installation has reported a missing alert, and on the
    routes that authenticate a key the per-node cache already holds (see
    above).

## Consequences

- Behind a load balancer, a trip on `/api`, `/gql` or `/mcp` normally
  alerts whichever node refuses it, with or without session affinity, for
  the reason given under Decision.
- A trip alerts only if the refusing node verified the key in the last 5
  minutes, so it raises nothing when:
  - the route never authenticates a key (`:media_transform`,
    `:plugin_endpoint`, and the ActivityPub inbox, which charges `:api`) and
    the key's earlier `/api` use landed on another node;
  - the requests that spent the address's budget did not carry the key (a
    shared egress address whose other clients filled the counter);
  - the cache restarted on its own (`ApiKeyTrip` crashed) while the
    rate-limit counters kept their counts, or the node runs a release that
    does not remember keys (a rolling deploy from 1.9).
- The flood-ceiling limits themselves are per node: on N nodes an address
  can make up to N times the configured number of requests before a refusal,
  so trips, and their alerts, are rarer than the numbers suggest.
- Revisit this record if multi-node installations report trips with no
  alert (the `kiln_cms.security.api_key_trip.count` counter's `unverified`
  result is the signal), or if key-authenticated traffic moves to routes that
  do not run `ApiKeyAuth`, such as transforms or plugin endpoints. The
  PubSub broadcast is the first alternative to reach for.
