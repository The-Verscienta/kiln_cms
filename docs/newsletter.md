# Newsletter (Phase 1)

Send a published post to a segment of opted-in subscribers, using Kiln's
built-in MTA (`KilnCMS.Mail`) — no external email service. This is the first
phase of the "publishing → newsletter → membership" work
([issue #337](https://github.com/The-Verscienta/kiln_cms/issues/337)).

Phase 1 covers subscriber management, segments, double opt-in, manual
"send this post as a newsletter", and unsubscribe. Auto-send-on-publish and paid
membership gating are Phase 2 (see the hook points below).

## What it does

- **Subscribers** (`KilnCMS.Newsletter.Subscriber`) — external email addresses
  with no login, distinct from `Accounts.User`. Double opt-in: a public
  `:subscribe` creates a `:pending` subscriber; the confirmation link flips it
  to `:confirmed`. Only confirmed subscribers are mailed.
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

## Gated / embargoed content is refused

`send_as_newsletter/2` only sends a document that is **published and
world-readable** (`audience: :public`). A gated (non-public) or unpublished
document returns `{:error, :gated}` / `{:error, :not_published}` and nothing is
sent — restricted content can't leak to an email list. The admin post picker
lists only sendable posts.

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

Token-authorized (no session), CSRF-free (`:public_form` pipeline):

- `GET  /newsletter/confirm/:token` — double-opt-in confirmation.
- `GET  /newsletter/unsubscribe/:token` — unsubscribe (footer link).
- `POST /newsletter/unsubscribe/:token` — RFC 8058 one-click unsubscribe.

Unsubscribe tokens are **stored and non-expiring**, so links in old newsletters
keep working. Unsubscribe is treated as *consent* and is deliberately separate
from the mail pipeline's bounce-*suppression* list (a deliverability signal).

## Phase 2 hook points

- **Auto-send on publish** — attach a `change {…, event: :published}` alongside
  the existing `NotifyWorkflowEmail` / `NotifyWebhooks` changes in the `:publish`
  action (`lib/kiln_cms/cms/content.ex`), guarded by an opt-in per-post flag.
- **Paid membership gating** — `Subscriber` reserves an `audience` seam; gated
  audiences can map to paid tiers, with content access rules layered on the
  existing audience read-axis.
