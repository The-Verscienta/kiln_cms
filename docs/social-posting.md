# Social auto-posting

Announce published content on Bluesky or Mastodon (#497). It is an **automation
reaction**, not a separate system: the trigger, the queue and the admin surface
are the ones editorial automation already uses.

## Setup

1. **Connect an account** at `/editor/social` (admin only).

   * **Bluesky** — your full handle (`example.bsky.social`) and an **app
     password** from Settings → Privacy and security → App Passwords. Never your
     account password: an app password can be revoked on its own and cannot
     change the account's password.
   * **Mastodon** — your instance URL (`https://mastodon.social`) and an access
     token with the `write:statuses` scope, from the instance's Development →
     Applications page.

   Hit **Test connection** before you rely on it. A wrong credential otherwise
   surfaces as an announcement that silently did not happen, hours later, in a
   ledger nobody has open.

2. **Add a rule** at `/editor/automation`:

   * **When** `published` (optionally scoped to one content type)
   * **Do** `social_post`
   * Config: `{"provider": "bluesky"}` or `{"provider": "mastodon"}`, plus an
     optional `"template"`.

## What gets posted

By default: the title, a blank line, then the canonical URL — with the excerpt
(or SEO description) included when there is room for a useful amount of it. A
template overrides it:

```json
{"provider": "mastodon", "template": "New {{type}}: {{title}} {{url}}"}
```

Tokens are `{{title}}`, `{{excerpt}}`, `{{type}}` and `{{url}}` — the same
double-brace syntax the `send_email` reaction uses.

**The URL is protected from truncation** in the default shape. Bluesky caps a
post at 300 characters and a default Mastodon at 500, so a long title has to
give somewhere; an announcement truncated into a link-less sentence is worse
than no announcement, because it reads as a post someone meant to finish. If you
write your own template and put the URL last, that protection is yours to keep —
the template is rendered as you wrote it and trimmed from the end.

## What is never posted

Three refusals, each recorded in the ledger as `skipped` with a reason rather
than silently dropped:

| Not announced | Why |
|---|---|
| Audience-gated content | An announcement pushes the title and a link to strangers' timelines. A members-only document is not for strangers. |
| [Passphrase-locked content](api.md#password-protected-content) | The point of the lock is that the URL alone is not enough. Broadcasting the URL is the loudest way to ignore that. |
| Non-default locale variants | Every locale variant's publish emits its own event, so without this one article published in three languages posts three times. |

## At most once — and what that costs

**A duplicate announcement is worse than a missing one.** A missing post is
invisible; a duplicate is on your public timeline, in front of your audience, and
cannot be quietly taken back. Every decision below follows from that asymmetry:

* The ledger row is written **before** the request, and is unique on
  `{account, document, publish}`. Two concurrent workers race the insert and
  Postgres picks one, so a re-delivered job or a re-fire wave cannot post twice.
  Two *different rules* pointed at the same account also cannot.
* An ambiguous outcome — a timeout, a 5xx, a connection reset — is recorded as
  **`unknown`** and **never retried automatically**. Kiln does not know whether
  it posted, and guessing wrong in one direction is invisible while guessing
  wrong in the other is permanent.
* The announce job runs with no Oban retries, for the same reason.

The cost is real and is not hidden: **a genuinely lost post stays lost until
someone looks at the ledger.** If you need the announcement, check
`/editor/social` after publishing.

Re-announcing on purpose means deleting the ledger row — the claim *is* the
record of "this has been announced", so there is nothing else to clear. That is
deliberately a manual act: every automatic path to it is a path to a duplicate.

A genuinely new publish (a fresh `published_at`, e.g. an unpublish/republish
cycle) is a different claim and does announce again.

## Outbound requests are SSRF-guarded

The Mastodon instance URL is operator-supplied and stored in a database column,
so every request to it goes through `KilnCMS.SafeFetch`, which pins the resolved
address and refuses private ranges. **A Mastodon instance on a private network
cannot be posted to.** That is the correct default; if you self-host one on a
LAN, put it behind a public hostname.

## X, LinkedIn, Facebook

Deliberately **not** in core. Their APIs are volatile, paid, and gated behind
app review — a core module for one is a maintenance burden every deployment
inherits whether or not it uses it. They are plugin territory through the
`KilnCMS.Social.Provider` behaviour, which is four callbacks:

```elixir
@callback post(account, announcement) :: {:ok, result} | {:error, {:failed, String.t()} | :unknown}
@callback verify(account) :: :ok | {:error, String.t()}
@callback max_length() :: pos_integer()
```

If you implement one, the important contract is the error split: return
`{:failed, reason}` only when you know nothing was posted, and `:unknown`
whenever the request might have landed. Guessing `:failed` on a timeout is what
turns one ambiguous request into two posts.

## Not the same as federation

[Federation](federation.md) (#491) makes Kiln *itself* a fediverse actor that
people follow, with its own posts and followers. This posts to accounts you
already have, on networks you already use. They complement each other, and both
refuse gated and locked content in their own guard.

## Credentials at rest

Encrypted with AES-256-GCM via `KilnCMS.Keys.Vault`, the same treatment the DKIM
private key and the federation signing key get. Never rendered back into the
settings page, never public on any API, and excluded from logs. Rotating
`SECRET_KEY_BASE` makes stored credentials unreadable — accounts stop posting and
must be reconnected, which is a stop rather than a crash.
