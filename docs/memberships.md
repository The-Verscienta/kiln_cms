# Paid memberships

Sell reader access to gated content. This is the second phase of the
"publishing → newsletter → membership" work (issue #337); the first phase is
[Newsletter](newsletter.md).

> **Status.** This page documents what is in the tree today: provider
> credentials, the tiers on sale, the membership lifecycle (the webhook receiver,
> automatic audience grants, the audit trail), and the member-facing checkout,
> `/account` and join pages. The paywall teaser and member-only newsletters land
> in later slices of #337 Phase 2 — until the teaser ships, gated content still
> 404s for a reader who isn't entitled to it.

## The idea

A paid member is not a new kind of account. It is an ordinary self-registered
user whose active subscription grants them one of the **gated audiences** —
the consumer read axis that already exists (`KilnCMS.CMS.Audiences`, see
[Granular RBAC](granular-rbac.md) for how it differs from editorial roles).

- Content carries one `audience`. `:public` is world-readable; anything else is gated.
- A reader carries a set of `audiences`, and may read a published record whose
  audience is `:public` or is in their set.
- Self-registration lands a user as `:viewer` with **no** audiences — i.e. exactly
  a not-yet-paying member.

So a membership tier is a product that grants an audience, and billing is the
loop that grants and revokes it. Nothing about the access model changes.

## Two scopes, deliberately

| | Scope | Who may change it |
|---|---|---|
| `KilnCMS.Billing.Settings` — provider credentials | **Instance-wide** singleton | Platform admin (global `User.role`) |
| `KilnCMS.Billing.MembershipTier` — the tiers on sale | **Per organization** | Org admin of that site |

One payment-provider account serves the whole instance; each site sells its own
tiers. That asymmetry is load-bearing, and mirrors
`KilnCMS.Mail.Settings` (instance-wide DKIM) versus `KilnCMS.CMS.SiteBranding`
(per-site tokens). A tenant-less resource must **not** gate on an org-admin
check: it would resolve every actor against the *default* org and let one site's
admin rewrite payment credentials for every other site.

> **Known limit.** Because credentials are instance-wide, a multi-org instance
> bills every site into the same provider account. The `KilnCMS.Keys` seam keeps
> per-org credentials (e.g. Stripe Connect) possible later without a data
> migration.

## Setting up

Everything lives at **`/editor/billing`** (platform admin only). Until both
secrets resolve, `KilnCMS.Billing.configured?/0` is false and **no payment
surface exists at all** — no tier is offered and no provider call is made. A
fresh install is inert.

### 1. Credentials

Two secrets, configured independently because they rotate on different cadences:

| Secret | What it is |
|---|---|
| **API secret key** | The account-wide bearer credential used to open checkout and billing-portal sessions. Starts with `sk_` or `rk_`. |
| **Webhook signing secret** | Verifies inbound webhooks. Copy it from the webhook endpoint you create in the provider's dashboard. Starts with `whsec_`. |

There is deliberately **no publishable-key field**: hosted checkout means Kiln
redirects to a provider-hosted page and never mounts the provider's JavaScript,
so the publishable key has no use here.

Each secret follows the key-provider model ([`KilnCMS.Keys`](KilnCMS.Keys.html)),
the same one the DKIM key uses:

- **Environment variable** — recommended for production. You choose the variable
  name; there is no default, and a blank pointer is refused rather than silently
  falling back.
- **File** — recommended for production; the natural fit for Docker/Kubernetes
  mounted secrets. Trailing newlines are trimmed.
- **Database (encrypted)** — the zero-ops default: paste the secret and it is
  stored AES-256-GCM encrypted. The encryption key is derived from
  `SECRET_KEY_BASE`, so **rotating that secret orphans the stored value** and you
  will need to paste it again.

"Test connection" performs a live credential check and records which account the
keys belong to, so a mistyped key fails at setup rather than at a member's first
checkout. "Disconnect" clears both secrets and returns the instance to inert.

### 2. Tiers

Create one tier per thing you sell. Configure the **price in your provider's
dashboard** and paste its price ID into the tier, so there is exactly one source
of truth for money — Kiln stores a pointer, never an amount. `price_config` holds
display copy for the join page and is never used to charge.

Each tier grants exactly one gated audience. Several tiers may grant the same
audience (a monthly and an annual plan, say); a reader keeps the audience while
*any* of their memberships is active.

**A tier's audience cannot be changed after creation.** The entitlement logic
derives "which audiences billing owns" from this table, so changing an audience
would stop the old one being owned while live grants for it remained — stranding
an entitlement nothing would ever revoke. Retire the tier (`active: false`) and
create a new one instead, which also keeps the audit trail honest.

Retiring a tier stops new sign-ups; it does not revoke existing members.

### 3. Gating content

Set a post or page's **audience** to a gated value in the content editor. The
audience selector only appears when more than one audience is configured.

## Configuring audiences

The audience list is **compile-time**:

```elixir
# config/config.exs
config :kiln_cms, :audiences, [:public, :member]
```

Adding a paid audience therefore needs a config change, a recompile, **and**
`mix ash.codegen` + `mix ash.migrate` — the tier table carries a database CHECK
constraint mirroring the list, so that the public join page and paywall can never
be taken down by an out-of-band bad write.

Removing an audience while tiers still reference it leaves those tiers
unreadable; `/editor/billing` warns rather than crashing, but restore the
audience or retire the tiers.

## The provider seam

`KilnCMS.Billing.Provider` is a behaviour with five callbacks — open a checkout
session, open a billing-portal session, retrieve a subscription, retrieve a
checkout session, and verify a webhook signature. One implementation ships,
`KilnCMS.Billing.Providers.Stripe`, selected via:

```elixir
config :kiln_cms, KilnCMS.Billing, provider: KilnCMS.Billing.Providers.Stripe
```

It is a thin `Req` client rather than a third-party dependency. The surface is
five endpoints against a stable API; a client library would add a permanent
advisory surface to the dependency-audit gate and could not be stubbed with
`Req.Test`, which is how every other outbound integration here is tested. The
provider's API version is pinned so a provider-side default bump cannot silently
reshape the subscription object the entitlement logic reads.

Deliberately **not** on the behaviour: creating customers (hosted checkout does
it), creating prices or products (an operator does that in the dashboard), and
cancelling subscriptions (the hosted portal owns cancellation — a local cancel
primitive would create a second, divergent cancellation path).

### Webhook signature verification

Inbound webhooks are authorized by an HMAC-SHA256 signature over the **raw**
request bytes, not by a session — the caller is the payment provider, not a
browser. Verification happens before JSON decoding, so unauthenticated bytes
never reach the decoder, and it enforces a ±300s timestamp tolerance to bound
replay of a captured request. Multiple signatures per request are accepted so a
signing-secret rotation does not drop events.

## How a membership grants access

### The entitlement rule

Audiences are recomputed **from scratch** on every membership transition, never
incrementally:

```
granted   = audiences of every entitling membership (active | past_due | comped)
managed   = audiences claimed by ANY tier, in ANY org, active or retired
preserved = current -- managed          # admin-owned, untouched
new       = preserved ++ granted
```

Recomputing rather than adding and removing is what makes replayed or
out-of-order webhooks safe: the result is a pure function of current state, so
applying it twice changes nothing.

**Division of authority.** For any audience some tier claims, billing is the sole
authority. Audiences no tier claims stay exactly as an admin left them. The
consequence worth knowing: once an audience has *ever* been claimed by a tier,
granting it by hand is transient — the next recompute drops it. **Comping is the
supported lever** (a membership with status `comped`, no provider subscription);
`manage_access` is the wrong tool for a tier-managed audience.

Retiring a tier does **not** un-manage its audience, deliberately. If it did,
retiring a tier would freeze every existing grant of that audience permanently,
with nothing left to revoke it.

### Statuses

| Status | Grants? | Meaning |
|---|---|---|
| `incomplete` | no | created before checkout, so the provider session can carry a stable id |
| `active` | **yes** | paid and current |
| `past_due` | **yes** | a payment failed and the provider is retrying. Access survives dunning — locking a member out for an expiring card would be wrong, and the provider keeps the subscription alive through its retry schedule |
| `canceled` | no | terminal |
| `comped` | **yes** | granted by an admin, no provider subscription |

### Revocation timing

There is **no local timer**. The audience follows the mapped status and the status
follows the provider, which gives the right behaviour for free: with
"cancel at period end", the provider keeps reporting `active` for the whole paid
period and sends the deletion event when it lapses. Immediate cancellation
revokes immediately for the same reason. `current_period_end` is stored only so
the member UI can say "renews on…".

### Webhook setup

Point a webhook endpoint at `POST /billing/webhooks/stripe` and enable exactly
four events:

- `checkout.session.completed`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.payment_failed`

Anything else is acknowledged and ignored. Paste the endpoint's signing secret
into `/editor/billing`.

Processing is asynchronous: the receiver verifies the signature, records the
event, and enqueues it on the `billing` queue. The provider times out in about 20
seconds and treats a timeout as failure, so handling inline would be a latency bet
against an external API on a path whose failure mode is "the provider disables
your endpoint".

**Diagnosing "the member paid but has no access"** starts with the recorded
events: each one carries its status and, on failure, the reason. Every entitlement
change also appears in the governance trail with the audience delta and the
provider event that caused it.

### Organizations

The webhook's organization is resolved from the **event**, never from the request
host — a webhook arrives at whatever host the provider was configured with, and
trusting that would write memberships into the wrong site. Resolution goes:
event metadata (verified against the stored membership), then the subscription id,
then the customer id disambiguated by price. Nothing resolvable is acknowledged
and ignored rather than guessed.

Because credentials are instance-wide, checkout stamps the organization onto both
the checkout session **and** the subscription it creates: session metadata does
not propagate to the subscription, and the subscription is what carries every
later event.

## The member journey

| Page | Who | What |
|---|---|---|
| `/membership` | anyone | The tiers on sale. Where the paywall CTA points. |
| `/account` | any signed-in user | Current membership, status, renewal date, "Manage billing", data export. |

A reader who isn't signed in is sent to register with their chosen tier
remembered, so the intent survives account creation — registration is the
identity step and shouldn't be entangled with payment. After signing in, readers
land on `/account` rather than the site root.

Both money-handling controls are ordinary form posts to
`KilnCMSWeb.BillingController`, not LiveView events: each ends on a
provider-hosted page on another origin, which a LiveView cannot navigate to. They
work with JavaScript disabled and survive a dropped socket.

Return URLs are built from the **request's** host, so a member on a
custom-domain site returns to that domain — otherwise their session cookie
wouldn't be there.

### Coming back from checkout

The member may land on `/account` before the provider's webhook arrives. When the
membership is still incomplete, the checkout session is retrieved server-side and
applied through the same path the webhook uses — but only after verifying the
session's metadata names *that* user. The session id comes from the query string
and is therefore attacker-suppliable; nothing is ever granted from the query
parameters themselves. The webhook remains the durable path; this only removes
the "activating…" wait.

## Security notes

- Card data never touches Kiln. Both money-handling calls return a
  provider-hosted URL that the member is redirected to.
- Secrets are never returned by any API read: the encrypted columns are
  `sensitive?` and not writable from input, and the provider-config column holds
  only a pointer (a variable name or a path), never key material.
- Payment credentials are purged by the staging scrub, so a production clone
  cannot act on a real provider account.

## See also

- [Newsletter](newsletter.md) — subscribers, segments and sending
- [Granular RBAC](granular-rbac.md) — how audiences differ from editorial roles
- [Data flows](data-flows.md) — what personal data is stored, and subprocessors
