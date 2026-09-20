# Webhooks

An operator guide to Kiln's outbound webhooks: signed HTTP push on content
lifecycle events, with SSRF-safe delivery, retry/backoff, and a delivery
ledger. Split out of [#53](https://github.com/The-Verscienta/kiln_cms/issues/53)
as [#570](https://github.com/The-Verscienta/kiln_cms/issues/570) — the feature
(`lib/kiln_cms/webhooks/`) had never had a guide of its own; see
[Automation](automation.md) for the complementary in-app reactions
(email/broadcast/cache/reindex) that don't need a receiver at all.

## Registering an endpoint

Admins manage endpoints at **`/editor/webhooks`**. Adding one takes a URL and a
set of events to subscribe to; Kiln generates a signing secret at creation time
(shown on the endpoint's row — it never changes, even across edits). The secret
is stored encrypted with the app's vault key, which is derived from
`SECRET_KEY_BASE`. Rotating that key leaves every endpoint's secret unreadable:
the row says so, and deliveries are refused rather than sent unsigned.
Re-create the endpoints after a rotation ([secrets rotation](secrets-rotation.md)). Toggling
**Active** or editing an endpoint gives it a clean slate: its failure count
resets (see [Auto-disable](#auto-disable) below).

Deleting an endpoint takes its delivery history with it.

## Event names & payload

An event name is `<type>.<verb>`. Every registered content type — built-in and
admin-defined dynamic types alike (D17) — gets one event per lifecycle verb it
can emit, so a new content type has webhook events for free:

| Verb | Fires when | Subscribed by default? |
| --- | --- | --- |
| `published` | A document goes live | Yes |
| `unpublished` | A live document is taken down | Yes |
| `updated` | A **published** document is edited (draft edits/autosaves stay silent) | Yes |
| `in_review` | A document is submitted for review ([#375](https://github.com/The-Verscienta/kiln_cms/issues/375)) | **No — opt in** |
| `returned_to_draft` | A review is sent back to draft | **No — opt in** |
| `created` | A document is created (API, editor, or import) | **No — opt in** |
| `archived` | A document is archived, from any state | Yes |
| `deleted` | A document is moved to the trash (`DELETE` over the API is this too) | Yes |
| `restored` | A document comes back from the trash, or is unarchived to draft | Yes |

A mirror needs `archived`, `deleted` and `restored`, or it keeps serving
documents the site no longer has. They are on by default for that reason, and
they are safe defaults because of what they carry (see the payload
shapes below): `archived` and `deleted` send a
**tombstone**, the document's identity and nothing else, since they fire for
drafts as readily as for live documents. `restored` sends the full body only
when the document is published again (it is back on the delivery path and a
mirror must re-ingest it); otherwise it sends the tombstone too.

The trash is a soft delete. A hard purge from the trash, or the nightly
auto-purge, sends nothing more: the receiver already heard `deleted`.

`unpublished` fires for both an explicit unpublish **and** archiving a
published document (#914) — both remove it from delivery, and a receiver
watching for content leaving delivery should not have to subscribe to two
events to hear about it. The payload's `data.state` reflects which happened:
`"draft"` for an unpublish, `"archived"` for an archive.

`in_review`, `returned_to_draft` and `created` are opt-in only. Their payload is
the full serialized body of a document that has **never been published**, and a
receiver built for publish-mirroring must not be sent draft or embargoed content
it didn't ask for. `created` fires for every create path, bulk
[import](content-portability.md) included, so expect one per imported record.

More event names exist outside the `<type>.<verb>` pattern:

- **`form.submitted`** — a public form submission ([Forms](forms.md)); every
  endpoint is subscribed by default.
- **`membership.activated`** / **`membership.canceled`** — a paid membership
  started or stopped granting access ([Paid memberships](memberships.md#webhook-events));
  opt in.
- **`task.assigned`** / **`task.overdue`**, **`release.published`** /
  **`release.rolled_back`** / **`release.failed`**, and
  **`experiment.concluded`** — editorial tasks, content releases and A/B
  experiments; opt in.
- **`ping`** — a manual test delivery (see [Ping](#ping-and-redeliver) below);
  never subscribed to, and delivered on demand regardless of an endpoint's
  active state or event list.

The request body is always
`{"event": "<name>", "delivery_id": "<uuid>", "data": {...}}`. `delivery_id` is
the ledger row's id: the same on every retry of one delivery, and new for a
redelivery. It is inside the signed body, so a receiver can trust it as a
dedupe key. `data` shape depends on the event:

- **Tombstones** (`archived`, `deleted`, and `restored` for a document that is
  not published) — `{"id", "slug", "locale", "state", "updated_at"}`. `state`
  is the document's workflow state: `"archived"` after an archive, and the state
  it was trashed in for `deleted` (`"published"` tells you it was live).
- **Other content lifecycle events** (`published`/`unpublished`/`updated`/
  `in_review`/`returned_to_draft`/`created`, and `restored` for a published
  document) — the document's public fields (`id`, `title`, `slug`,
  `excerpt`, `blocks`, `seo_*`, `canonical_url`, `locale`, `state`, `audience`,
  `locked`, `published_at`, `scheduled_at`, `inserted_at`, `updated_at`); each block
  trimmed to `type`, `content`, `data`, `order`, `children`. Internal-only
  fields (e.g. search text) are never included.
- **`form.submitted`** — `{"form": "<slug>", "data": {...submitted fields...}}`.
- **`membership.activated`** / **`membership.canceled`** — the member (`user_id`,
  `email`), the tier (`id`, `slug`, `name`, `audience`), the transition
  (`status`, `previous_status`, `occurred_at`) and `event_id` to dedupe on; see
  [Paid memberships](memberships.md#webhook-events).
- **`ping`** — `{"message": "KilnCMS webhook test", "endpoint_url": "...", "sent_at": "<ISO 8601>"}`.

```jsonc
// POST to your endpoint, page.published
{
  "event": "page.published",
  "delivery_id": "0b9c…",
  "data": {
    "id": "…", "title": "Launch", "slug": "launch", "state": "published",
    "audience": "public", "locked": false,
    "blocks": [{ "type": "paragraph", "content": "…", "data": {}, "order": 0, "children": [] }],
    "published_at": "2026-08-04T12:00:00Z", "…": "…"
  }
}
```

### Gated content is delivered too — check `audience`

A webhook fires for an **audience-gated** document exactly as it does for a
public one, and the payload carries the full block tree. That is deliberate: an
endpoint is somewhere you chose to send content, the request is HMAC-signed and
the URL is SSRF-guarded, so this is not the anonymously-queryable surface the
Meilisearch index is (which *does* exclude gated content, [#1006](https://github.com/The-Verscienta/kiln_cms/issues/1006)).

But it means **your receiver decides**, and the payload carries both halves of
the decision Kiln makes for its own surfaces:

| Field | Value when open | Filter if your sink is public |
| --- | --- | --- |
| `audience` | `"public"` | anything else (`"member"`, or whatever your deployment configures) is content a reader was supposed to pay for or be granted |
| `locked` | `false` | `true` means a shared passphrase stands between the reader and this body ([#496](https://github.com/The-Verscienta/kiln_cms/issues/496)) |

Both, not either. Kiln's own rule is three-part — published **and** `public`
**and** unlocked — so a receiver checking only `audience` mirrors a document
that was published openly and locked afterwards, which still arrives as
`"audience": "public"`. `locked` is derived; the hash and the
`password_fingerprint` never leave.

**A narrowing `updated` event is a retraction.** Gating or locking a live
document fires `<type>.updated` with the new values, so a receiver that filters
only at ingest keeps serving the body it already mirrored. Treat an `updated`
whose `audience` moved away from `"public"`, or whose `locked` became `true`, as
an instruction to withdraw it.

## Verifying the signature

Every request carries these headers:

| Header | Value |
| --- | --- |
| `x-kilncms-webhook-signature` | `t=<unix seconds>,v1=<hex>` where `v1` is the lowercase hex HMAC-SHA256 of `"<t>.<raw body>"`, keyed by the endpoint's secret |
| `x-kilncms-delivery-id` | The delivery's id, the same value as the body's `delivery_id`. Stable across retries |
| `x-kilncms-event` | The event name (redundant with the body's `event` field, for routing without a parse) |
| `x-kilncms-signature` | **Deprecated.** Hex HMAC-SHA256 of the raw body alone, with no timestamp. Still sent so existing receivers keep working; it will be removed in a later release |

To verify a delivery:

1. Split the header on `,` into `t` and one or more `v1` values.
2. Reject it if `t` is more than **300 seconds** (five minutes) from your own
   clock, in either direction. This is what stops a captured request from
   being replayed later. Kiln signs each attempt when it sends it, so a retry
   carries a fresh `t`. Keep your clock NTP-synced.
3. Compute the HMAC of the string `t`, then `.`, then the **raw request body**,
   using the exact bytes you received. Do not re-serialize the parsed JSON: key
   order and whitespace aren't guaranteed to round-trip.
4. Accept if any `v1` matches, compared in constant time.
5. Optionally, remember each `delivery_id` for the length of your window and
   drop a repeat. That makes delivery exactly-once inside the window as well
   as outside it.

The official clients do all of this: `verifyWebhook` in the
[JS client](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/js/README.md) and `KilnClient.Webhook.verify/4` in the
[Elixir client](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/elixir/kiln_client/README.md). By hand:

```js
// Node
const crypto = require("crypto");
function verify(secret, rawBody, header, toleranceSeconds = 300) {
  const pairs = header.split(",").map((p) => p.trim().split(/=(.*)/s));
  const ts = pairs.filter(([k]) => k === "t").map(([, v]) => v);
  if (ts.length !== 1 || !/^\d+$/.test(ts[0])) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts[0])) > toleranceSeconds) return false;
  const expected = Buffer.from(
    crypto.createHmac("sha256", secret).update(`${ts[0]}.`).update(rawBody).digest("hex"),
  );
  return pairs.some(([k, v]) => {
    if (k !== "v1") return false;
    const given = Buffer.from(v);
    return given.length === expected.length && crypto.timingSafeEqual(given, expected);
  });
}
```

```python
# Python
import hmac, hashlib, time

def verify(secret: str, raw_body: bytes, header: str, tolerance: int = 300) -> bool:
    pairs = [p.split("=", 1) for p in header.split(",") if "=" in p]
    ts = [v for k, v in pairs if k == "t"]
    if len(ts) != 1 or not ts[0].isdigit() or abs(time.time() - int(ts[0])) > tolerance:
        return False
    expected = hmac.new(secret.encode(), ts[0].encode() + b"." + raw_body, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, v) for k, v in pairs if k == "v1")
```

**Migrating from `x-kilncms-signature`.** The old header is the HMAC of the body
alone. It proves a delivery came from Kiln unmodified, but not when it was sent,
so a captured request can be replayed to a receiver that checks only that
header, indefinitely (see the [threat model](threat-model.md#residual-risks)). Both
headers are sent on every delivery, so a receiver can switch at any time, with
no coordination.

An admin **redelivery** is a new delivery: a new `delivery_id` and a fresh `t`.
It is meant to be accepted.

## Egress protections (SSRF)

Endpoint URLs are validated on every create/edit, and re-resolved (not just
re-checked) on every delivery attempt, by `KilnCMS.Webhooks.SafeUrl`:

- **Blocked hosts**: `localhost`, `metadata.google.internal`, `metadata.goog`,
  and any `.local` / `.internal` hostname.
- **Blocked addresses**: loopback (`127.0.0.0/8`, `::1`), unspecified
  (`0.0.0.0`, `::`), link-local (`169.254.0.0/16`, `fe80::/10`), private
  ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7` ULA),
  carrier-grade NAT (`100.64.0.0/10`), and the broadcast address — checked
  against IPv4-mapped/-compatible IPv6 addresses too, so `::ffff:10.0.0.1`
  doesn't slip through.
- **DNS resolution is checked, then pinned.** A hostname is resolved once
  before delivery, every answer is checked against the same blocklist, and the
  HTTP client connects to *that* resolved address (not the hostname) with the
  original `Host` header and TLS SNI restored separately. Re-resolving at
  connect time would reopen a DNS-rebinding window — an attacker's DNS could
  answer safely during validation and privately at connect time — so the
  pinned address is what the request actually dials. Resolution has a 3-second
  timeout so a stalled/firewalled name can't hang a delivery worker.
- **Redirects are not followed.** A 3xx response is treated as the delivery
  outcome (and retried like any other non-2xx), not a new destination — an
  endpoint can't hop to a blocked address after passing validation.
- **HTTPS is required in production** (`require_https: true`); HTTP is
  accepted in dev/test.

## Delivery, retries, and failure handling

A publish/unpublish/update/form-submit enqueues one Oban job per active,
subscribed endpoint, plus one ledger row (`WebhookDelivery`) per job — the row
is updated on every attempt, not just the outcome. The row's id is the
`delivery_id` the receiver sees.

- Delivery is a `POST` with a 5-second connect timeout and a 15-second
  response timeout.
- A non-2xx response or a transport error fails the job, and Oban retries with
  exponential backoff up to **5 attempts**.
- Once retries are exhausted, the delivery is marked `:failed` — permanently;
  nothing retries it further unless an admin redelivers it.
- A delivery whose endpoint secret can no longer be decrypted (see
  [Registering an endpoint](#registering-an-endpoint)) fails with
  `delivery failed: signing secret unreadable` and is never sent.

### Auto-disable

Every exhausted delivery counts against the endpoint's `consecutive_failures`.
After **10** exhausted deliveries in a row, the endpoint is auto-disabled
(`auto_disabled_at` stamped, shown in the UI) and stops receiving new
deliveries — a dead receiver doesn't burn the delivery queue forever. Any
successful delivery, or any admin edit to the endpoint, resets the counter to
zero and clears `auto_disabled_at`.

### Ping and redeliver

- **Ping** sends a one-off `"ping"` test event to a single endpoint — it
  delivers even while the endpoint is inactive or auto-disabled, so you can
  verify a receiver before flipping it on (or diagnose one that's already
  off).
- **Redeliver** replays a recorded delivery — same endpoint, event, and
  payload — as a **new** ledger row. History is immutable; a redelivery never
  overwrites the original failed attempt.

## Delivery history

`/editor/webhooks` shows the 25 most recent deliveries across all of an
org's endpoints: timestamp, event, target endpoint, status
(delivered/retrying/failed), attempt count, last HTTP status, and last error.
Delivery rows are retained for **30 days**, then pruned by a nightly job (per
org, so one site's retention sweep never touches another's history).

## Configuration

```elixir
# Exhausted deliveries in a row before auto-disable (default 10)
config :kiln_cms, KilnCMS.Webhooks, auto_disable_after: 10

# Delivery ledger retention, in days (default 30)
config :kiln_cms, :webhooks, delivery_retention_days: 30

# SSRF guard (see config/prod.exs for the production defaults)
config :kiln_cms, KilnCMS.Webhooks.SafeUrl,
  require_https: true,
  resolve_dns: true
```

## Multi-tenancy

Endpoints and deliveries belong to one organization ([epic #336](https://github.com/The-Verscienta/kiln_cms/issues/336)): a publish only fans out to
its own site's subscribed endpoints, and the admin panel only ever shows the
current org's endpoints and history.
