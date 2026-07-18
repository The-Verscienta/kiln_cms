# "Stays up when the database doesn't" delivery

A reliability guarantee competitors structurally can't match: **public delivery
keeps answering through a full Postgres outage**, for any content whose fired
artifact is warm in cache
([#341](https://github.com/The-Verscienta/kiln_cms/issues/341); see also #353
static/edge export, which snapshots the same immutable artifacts).

## The asymmetry

Kiln's delivery reads **immutable, pre-fired artifacts** from in-BEAM caches, not
the live block tree. A request-per-query CMS (Node/PHP) must reach the database
on every request; Kiln doesn't have to. The BEAM keeps the cache and the web
layer running independently of the database connection, so a DB outage degrades
gracefully instead of taking the site down.

## The guarantee (and its edge)

For a given piece of content, delivery answers with **zero database access** when
both of these are warm in the in-BEAM cache:

1. the **slug → record** resolution (`KilnCMS.Cache`, invalidated precisely on
   content writes), and
2. the **fired artifact body** (`KilnCMS.Firing.Cache`, populated on firing).

Under those conditions a full Postgres outage is invisible to the reader. Content
that is *not* warm during an outage returns a retryable **503
`temporarily_unavailable`** instead of crashing the request — an honest "try
again shortly," not a 500.

Point-in-time delivery (`?as_of=`, #338) reconstructs from PaperTrail history and
therefore *does* need the database; it is not covered by this guarantee.

## How it works

`KilnCMS.Firing.Delivery` is the resilient read path used by
`KilnCMSWeb.ArtifactController`:

- **Resolution is cache-first** through `KilnCMS.Cache.fetch_published/4` — the
  headless artifact API previously resolved the slug straight from Postgres on
  every request, so even a fully-warmed artifact couldn't be served with the DB
  down. Routing it through the (already-invalidated) content cache closes that
  gap.
- **The body read is cache-first** (`KilnCMS.Firing.Cache` → artifact table).
- **Every database touch is wrapped.** A DB failure is classified
  (`db_unavailable?/1` — a raw `DBConnection`/`Postgrex` error, or Ash's wrapped
  form) and turned into `:unavailable`; a genuine bug is never swallowed
  (re-raised). A warm request never reaches this wrapping because it never
  reaches the database.

## Verification

The guarantee is tested by dispatching real delivery requests from a **bare
spawned process** that, in the async test sandbox, has no database allowance — so
any query raises exactly as an outage would:

- `KilnCMSWeb.ArtifactControllerResilienceTest` — warm content (all surfaces) is
  served `200` through the simulated outage; cold content degrades to `503`.
- `KilnCMS.Firing.DeliveryTest` — cache-hit resolution/body reads return without
  touching the DB; cold reads return `:unavailable`; error classification.

## Operating notes

- The guarantee depends on `KilnCMS.Cache` being enabled (the default). Disabling
  it (`config :kiln_cms, KilnCMS.Cache, enabled: false`) removes the resolution
  cache and hence the resolution-side resilience.
- Warming: content is warm after it's been fired (body) and requested once
  (resolution). A cache eviction (TTL, LRW cap, or an invalidating write) means
  the next request re-warms from the DB — so the guarantee covers a *hot* working
  set, which is exactly the traffic that matters during an incident.
- A shared multi-node cache (Redis/Dragonfly) behind the existing tier-2 seam
  would extend warmth across a rolling restart; deferred until measured (D2).
