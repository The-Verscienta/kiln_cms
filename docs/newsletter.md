# Newsletter (Phase 1)

Send a published post to a segment of opted-in subscribers, using Kiln's
built-in MTA (`KilnCMS.Mail`) — no external email service. This is the first
phase of the "publishing → newsletter → membership" work
([issue #337](https://github.com/The-Verscienta/kiln_cms/issues/337)).

Phase 1 covers subscriber management, segments, double opt-in, manual
"send this post as a newsletter", and unsubscribe. Auto-send-on-publish shipped
alongside it as an automation rule (#376, documented below). Member-only
newsletters — sending gated content to paying members — arrived with Phase 2; see
[Paid memberships](memberships.md).

## What it does

- **Subscribers** (`KilnCMS.Newsletter.Subscriber`) — external email addresses
  with no login, distinct from `Accounts.User`. Double opt-in: `:subscribe`
  creates a `:pending` subscriber and mails them a confirmation link
  (`KilnCMS.Newsletter.Changes.SendConfirmationEmail`, queued on the `:mail`
  queue like every other outbound message); clicking it flips them to
  `:confirmed`. Only confirmed subscribers are mailed.
- **Segments** (`KilnCMS.Newsletter.Segment`) — named groups of subscribers (the
  "send to audience X" axis). A segment may optionally reference a consumer
  `audience` as a label; it is **not** an access boundary. Membership lives in a
  join table, not in `KilnCMS.CMS.Audiences` (which is a compile-time read-axis).
- **Campaign ledger** (`KilnCMS.Newsletter.NewsletterSend`) — one row per send,
  with per-recipient `sent_count` / `failed_count`, viewable in the admin.
- **Delivery** — the email body is the immutable, already-fired `:web` artifact
  of the post (the same output public delivery serves, never the live tree).
  Sending reuses the mail pipeline's DKIM signing, permanent-bounce suppression,
  greylist-aware retry, and per-attempt timeout.

## Gated content is refused — with exactly one exception

`send_as_newsletter/2` sends a document that is **published** and either
world-readable (`audience: :public`), or gated to precisely the audience the
target segment is entitled to by its **paid membership tier** (#337 Phase 2).
Anything else returns `{:error, :gated}` / `{:error, :not_published}` and nothing
is sent.

The exception is deliberately narrow:

| Target | Gated content? |
|---|---|
| A **tier-backed** segment whose tier grants that exact audience | **sent** |
| A tier-backed segment for a *different* audience | refused |
| A **hand-built** segment — even one labelled with that audience | refused |
| No segment (every confirmed subscriber) | refused |

A hand-built segment's `audience` attribute is a **label and not an access
boundary** — it grants nothing, and setting it must never widen a gated blast to
a list an admin curated by hand. Only `managed_by: :tier` segments, whose
membership is maintained from active paid memberships, can receive members-only
content.

The admin post picker lists a gated post only when some tier-backed segment could
legally receive it; the server-side guard is the real boundary.

## Sending

Admin UI: **`/editor/newsletter`** — manage segments and subscribers, pick a
published post + segment, and send. Campaign history shows delivery counts.

Programmatically:

```elixir
{:ok, post} = KilnCMS.CMS.get_post(id)

KilnCMS.Newsletter.send_as_newsletter(post,
  segment_id: segment_id,   # omit to send to every confirmed subscriber
  subject: "This week at Kiln",  # defaults to the post title
  actor: admin
)
```

The call validates, records a `NewsletterSend`, and enqueues the fan-out worker;
delivery happens asynchronously.

## Delivery pipeline

1. `KilnCMS.Newsletter.SendWorker` (queue `:newsletter`) resolves the confirmed
   subscribers for the segment, stamps `total_recipients`, and enqueues one
   `MailWorker` per recipient.
2. `KilnCMS.Newsletter.MailWorker` (queue `:newsletter`) rebuilds the email from
   the fired `:web` artifact, adds the `List-Unsubscribe` / `List-Unsubscribe-Post`
   headers (RFC 8058 one-click) and footer, and delivers via
   `KilnCMS.Mail.deliver_for_worker/2`. It skips a subscriber who unsubscribed —
   or whose address hard-bounced — between fan-out and delivery.

Newsletter delivery runs on a **dedicated `:newsletter` Oban queue** so a large
blast can't starve transactional `:mail` (auth, workflow notices). This raises
total worker concurrency to ~37 — size `POOL_SIZE` accordingly in production
(see `config/runtime.exs`).

## Public endpoints

CSRF-free (`:public_form` pipeline) and rate-limited on the `:form` bucket:

- `POST /newsletter/subscribe` — anonymous sign-up (`email`, optional `name`).
- `GET  /newsletter/confirm/:token` — double-opt-in confirmation.
- `GET  /newsletter/unsubscribe/:token` — unsubscribe (footer link).
- `POST /newsletter/unsubscribe/:token` — RFC 8058 one-click unsubscribe.

Everything but sign-up is authorized by an opaque per-subscriber token rather
than a session. Sign-up needs no authorization because it can only ever produce
a `:pending` row, which receives nothing until the address owner clicks the link
mailed to them.

### Signing up

Post `email` (and optionally `name`) to `/newsletter/subscribe`. Include the
shared honeypot input (`KilnCMS.Forms.honeypot_field/0` — `website`), which
public form submissions already use; filling it yields a fake success.

```html
<form method="post" action="/newsletter/subscribe">
  <input type="email" name="email" required />
  <input type="text" name="website" tabindex="-1" autocomplete="off" hidden />
  <button type="submit">Subscribe</button>
</form>
```

**Every outcome renders the same "check your inbox" page** — new address,
already confirmed, or previously unsubscribed. Otherwise the endpoint would
answer "does this person subscribe to this site?" for any address. Only a
malformed address gets a distinct response, since that leaks nothing.

Sign-up is also **non-resurrecting**: `:subscribe` upserts with
`upsert_fields [:name]`, so an existing row's status and tokens are untouched,
and the confirmation mailer sends only when the resulting row is `:pending`. A
confirmed subscriber is not re-mailed (that would make this a way to mail an
arbitrary address on demand), and an unsubscribed one is neither mailed nor
resurrected.

Unsubscribe tokens are **stored and non-expiring**, so links in old newsletters
keep working. Unsubscribe is treated as *consent* and is deliberately separate
from the mail pipeline's bounce-*suppression* list (a deliverability signal).

## Auto-send on publish (shipped via automation, #376)

Auto-send is an **automation rule**, not a hard-wired publish change: create a
rule "on `<type>.published` → `newsletter`" at `/editor/automation`
(`config`: `segment_id` optional — omit for all confirmed subscribers;
`subject` defaults to the title). The rule flows through the same funnel as
webhooks, reuses `send_as_newsletter/2` (so unpublished/gated/unfired content
is still refused, and the send briefly retries until the `:web` artifact is
fired), and is deduped per **{rule, content, publish revision}** on the
campaign ledger — re-fired events and re-delivered jobs can never double-send;
a genuinely new publish sends again.

## Member-only newsletters (Phase 2)

Each `KilnCMS.Billing.MembershipTier` gets an auto-maintained segment
(`managed_by: :tier`) whose membership tracks active paid memberships. Those
segments are the only ones that may receive gated content, and they can't be
edited by hand — their `audience` is derived from the tier, and the send guard
matches it against the document's.

**Consent and entitlement stay separate bits.** The billing sync writes only the
join rows and the `user_id` link; it never touches `Subscriber.status`. So:

- a member who unsubscribes keeps full content access and simply receives
  nothing (the recipient query requires `status == :confirmed` *and* segment
  membership);
- cancelling a subscription removes the join row and leaves their consent record
  and any hand-built segment memberships untouched.

A brand-new member lands **`:pending`**, not `:confirmed` — paying for access is
not consent to marketing email, and this model is double opt-in throughout. If
your policy and jurisdiction treat purchase as the consent event, that is a
one-line change in `Subscriber`'s `:link_member` action. Only a **confirmed**
email address is ever added to a list.

Activating a membership sends **no** newsletter opt-in email: the person bought
access, they didn't ask for a message. They turn it on themselves from the
**newsletter card on `/account`**, which is the member-facing control for their
own consent (`:resubscribe` / `:unsubscribe`). Those two actions plus `:for_user`
are a **`bypass`** on the resource, not ordinary policies — Ash AND-combines
policies, so as a policy the self-grant was narrowed to nothing by the blanket
admin policy and every member-driven call came back forbidden. A failing bypass
falls through, so admin management is unaffected.

See [Paid memberships](memberships.md).
