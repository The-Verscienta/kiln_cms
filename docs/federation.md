# ActivityPub federation

A Kiln site can be a fediverse actor: followable from Mastodon, with published
content arriving in followers' timelines as it is published (#491).

This is **phase 1** — a read-only actor. A site publishes, followers receive.
Replies, likes and boosts are accepted and ignored; inbound moderation is a
later phase and deliberately intersects the visitor-comments non-goal.

## Turning it on

Federation is off unless an operator says so **twice**.

**1. The deployment.** `KILN_FEDERATION_ENABLED=true`, then restart. Off means
every federation route 404s regardless of what any tenant admin has done.

This switch exists because federation is an egress decision, not an editorial
one: it makes the server sign and POST to hosts chosen by strangers who
followed the site, indefinitely, with nobody watching. An operator whose egress
policy forbids that must be able to say so once, centrally.

**2. The site.**

```bash
mix kiln.federation enable
```

which prints the handle to announce:

```
Federation enabled for this site.
Handle: @acme@acme.example.com
Actor:  https://acme.example.com/actor
```

`mix kiln.federation status` shows both halves of the gate and the follower
count; `mix kiln.federation disable` turns the site half off. There is no admin
screen yet — the settings UI and follower management are phase 2.

## The identity is permanent

`enable` captures the site's **origin** once and never recomputes it. An actor
id is its permanent name in the fediverse: remote servers store it, deduplicate
on it, and address deliveries to it.

So the origin is *not* derived from the request or from the site's current base
URL. If it were, adding a `custom_domain` later would silently rename the actor
and leave every follower on every remote instance holding an id that 404s, with
no mechanism to learn the new one.

Two consequences worth knowing before you enable:

- **Enable under the hostname you intend to keep.** Moving a federating site to
  a new domain is a migration with a redirect story, not a settings edit.
- **Disabling keeps the identity.** Re-enabling restores the same handle and the
  same key, so existing followers keep working.

## What federates

| | |
|---|---|
| Publish | `Create` |
| Edit a published record | `Update` |
| Unpublish | `Delete` (a `Tombstone` — the body is not re-sent) |

Only content that is **published**, **`:public`** audience, in the **default
locale**, and of a type that already **syndicates a feed**.

Each of those is a deliberate narrowing, not an oversight:

- an audience-gated record is published *and paywalled*, and an outbox is the
  most public surface there is;
- a record in three languages is three rows — federating all three would
  notify every follower three times for one article;
- an operator who chose not to put a type in the site's feed did not choose to
  broadcast it to the fediverse either.

Workflow transitions (in-review, returned-to-draft) federate nothing. A follower
has no business learning that a draft moved between editorial columns.

## Endpoints

| URL | |
|-----|---|
| `GET /.well-known/webfinger?resource=acct:<user>@<host>` | Resolves the handle to the actor |
| `GET /actor` | The actor document, including the public key |
| `GET /actor/outbox` | Recent published content as `Create` activities |
| `GET /actor/followers` | A **count** — never the list |
| `GET /ap/object/:id` | The AS2 object for one published document |
| `POST /actor/inbox` | `Follow` and `Undo{Follow}` |

Every activity this site delivers carries an object id under `/ap/object/`, and
that id dereferences — Mastodon re-resolves objects on refresh, on thread
expansion, and to confirm a `Delete`. Ids are built from the record id rather
than the slug, so a rename does not re-announce an article as a new one.

A single fixed `/actor` rather than Mastodon's `/users/:name`: a Kiln site is one
publication, not a user directory, and a fixed path cannot be shadowed by a
content type whose plural happens to collide.

The actor is typed **`Service`**, not `Person`. It is a publication that posts
automatically, Mastodon renders `Service` actors with a bot marker, and saying
so is more honest than the extra reach `Person` would buy — mislabelling
automated accounts is what instance moderators block for.

The followers collection publishes a count and no items. Who follows a
publication is not the publication's information to publish.

## Security

**Every inbound activity must carry a valid HTTP Signature.** A `Follow` is a
request to subscribe somebody else's server to this site's firehose; accepting
an unsigned one would let anyone sign up any instance for traffic it never asked
for, with this site's name on it.

Verification checks, in order:

- the signature **covers** `(request-target)`, `host`, `date` and `digest`.
  Requiring the set is the whole property: without `digest` in it, a signature
  is not bound to a body at all, so a captured request could be replayed with a
  substituted activity and a recomputed `Digest`;
- the date is within five minutes. Phase 1 has no nonce store, so the window is
  what bounds a replay;
- `host` is checked against the site's **pinned origin**, not against the
  request. `conn.host` is the caller's own `Host` header, so verifying against
  it would bind a signature to nothing — the same signed request would replay
  against any other Kiln deployment;
- the `Digest` header matches the **raw** body bytes. A signature over a digest
  of different bytes than the ones acted on is the classic way this is
  implemented wrong;
- the signing key belongs to the actor named in the activity, and that actor's
  document was **served from the URL it claims as its `id`** (actor fetches
  follow no redirects, so there is exactly one URL to bind to). Without that,
  an attacker serves a document claiming a popular account's id, signs with
  their own key, and the follower upsert overwrites the real account's row —
  redirecting every future delivery to them.

A `Follow` is additionally refused when the actor's inbox lives on a different
host than the actor (otherwise one actor could name a victim's server as its
inbox and turn the site's publishing schedule into a signed flood aimed at a
third party), and when the site is at its follower ceiling (50,000 by default —
`one_per_actor` dedups an exact URI, so one attacker domain serving many actor
URLs would otherwise become many permanent delivery targets).

An `Undo` is honoured only when it names a `Follow` **addressed to this site**.
`Undo{Like}` and `Undo{Announce}` are far more common and carry `object` as a
bare URI, so a looser check would silently delete a follower for un-liking a
post.

The `Accept` sent back is rebuilt from four known fields rather than echoing the
inbound activity, so a caller cannot choose the size of what this server stores
for 30 days and POSTs back.

### Nothing is fetched for an activity that changes nothing

Verifying a signature needs the sender's key, and that key lives in the sender's
actor document — so authenticating *anything* costs an outbound HTTPS GET to a
host the unauthenticated caller named. A ~200-byte POST would otherwise buy a
fetch of up to 128 KB, aimed wherever the caller likes, holding a web-tier
process open for the length of the fetch.

So the fetch happens only for an activity whose outcome the document could
change: a `Follow` or an `Undo{Follow}` **addressed to this site's actor**.
Every `Like`, every `Announce`, every misdelivered `Follow` is accepted with a
202 and dropped without a byte leaving the server. The trade is that which
activity types this software acts on becomes observable before authentication —
a property of the release, documented here, not of any site.

Actor documents that *are* fetched are cached for ten minutes, capped, and
evicted least-recently-written, so a burst from one actor costs one fetch and a
flood of invented actor URLs costs a fixed table. Failures are never cached. The
cost of the cache is that an actor rotating its signing key is unrecognised
until the entry expires — its activities 401 and its server retries, which is
the mild direction for this to fail in.

Outbound requests — actor fetches and inbox deliveries — go through
`KilnCMS.SafeFetch`, which pins the resolved address and refuses private ranges.
The URLs come from inbound requests written by strangers, which is exactly the
shape SSRF protection exists for: without it, sending a `Follow` with a crafted
`keyId` would make this server fetch its own cloud metadata endpoint.

Activities are signed against the request's **real** host, which is also what
`SafeFetch` restores after connecting to the pinned IP.

## Delivery

One ledger row per activity per follower, with attempts, status and error
recorded — the same shape outbound webhooks use, with two differences the
fediverse forces:

- **more retries** (12, with backoff to six hours). A webhook receiver that is
  down is usually a bug someone is fixing; a fediverse instance that is down is
  often just restarting. Mastodon retries for days.
- **dead followers are dropped, not disabled.** A webhook endpoint belongs to
  the site's own admin, who can re-enable it. A follower belongs to a stranger
  on another server; there is nobody here to notice a disabled row, so after 12
  consecutive failures it is deleted — and that instance is free to follow again
  if it comes back.

Ledger rows are pruned after 30 days.

## What phase 1 does not do

- No admin UI (phase 2).
- No key rotation. Peers cache `publicKeyPem` from the actor document at follow
  time, so rotation means re-signing under a new key and letting them re-fetch.
- No inbound replies, likes or boosts — accepted with a 202 and dropped. A 4xx
  would make the sending server retry for days over something not built yet,
  which is a way to get an instance blocked.
- No `sharedInbox` on our side. We *use* a remote server's when it publishes
  one, so one POST reaches every follower there.
