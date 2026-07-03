# Sending email from KilnCMS — operator guide

KilnCMS sends transactional email — sign-in / magic links, password resets,
email-confirmation, and content-workflow notifications. This guide covers how
to configure delivery and, if you use the built-in MTA, how to get mail
actually landing in inboxes.

> **There is no SMTP *server* to run.** KilnCMS is **send-only**: it never
> listens for inbound SMTP, has no mailbox, and starts no mail daemon. You
> either point it at an external relay, or let it deliver straight to
> recipients. Nothing here opens a port or accepts mail — "direct mode" is an
> outbound client, not a server. Replies and bounces go to your `From`
> address, hosted wherever you already keep that mailbox.

## The three modes

| Mode | Select with | What it does |
|---|---|---|
| **Local** (default) | nothing set | Dev-only in-memory mailbox. In a prod release, requests still succeed but **no mail is delivered** — every send just fails in the background queue. The app logs a warning at boot when this is the case. |
| **Relay** | `MAIL_MODE=smtp` (or just `SMTP_HOST`) | Hands each message to an external SMTP server (Postmark, SES, Mailgun, Gmail, your own Postfix…). The relay handles deliverability. **Recommended for most deployments.** |
| **Direct** | `MAIL_MODE=direct` | Built-in MTA: looks up each recipient domain's MX servers and delivers on port 25, DKIM-signing every message. No third party — but you own deliverability (DNS + IP reputation). |

All three queue delivery through Oban (the `mail` queue) — the triggering web
request never blocks on the SMTP dialog, and transient failures retry with
backoff.

Every variable named here is documented in
[environment-variables.md](environment-variables.md); this guide is the
narrative version.

---

## Relay mode (recommended)

Point KilnCMS at any SMTP relay. Minimum config:

```bash
MAIL_MODE=smtp                 # optional — setting SMTP_HOST alone implies it
SMTP_HOST=smtp.postmarkapp.com
SMTP_USERNAME=<token-or-user>
SMTP_PASSWORD=<token-or-pass>
MAIL_FROM_EMAIL=cms@example.com
MAIL_FROM_NAME=Example CMS     # optional, defaults to "KilnCMS"
```

TLS is on by default (STARTTLS on port 587). Override the port with
`SMTP_PORT`, or set `SMTP_TLS=false` only for a local/dev relay that can't do
TLS.

Provider notes:

- **Postmark** — `SMTP_HOST=smtp.postmarkapp.com`, port 587, and use your
  **Server API token** as both username and password.
- **Amazon SES** — `SMTP_HOST=email-smtp.<region>.amazonaws.com`, port 587,
  with SMTP credentials (not your AWS keys — generate SMTP creds in the SES
  console). Verify your `From` domain/address in SES first.
- **Mailgun** — `SMTP_HOST=smtp.mailgun.org`, port 587, SMTP username/password
  from the domain's settings.
- **Gmail / Google Workspace** — `SMTP_HOST=smtp.gmail.com`, port 587, an
  **app password** (not your account password). Low sending limits; fine for a
  tiny site.

That's the whole setup for relay mode — the relay owns SPF/DKIM/DMARC. Skip to
[Monitoring delivery](#monitoring-delivery). Everything below is for direct
mode.

---

## Direct mode (built-in MTA)

With `MAIL_MODE=direct`, KilnCMS delivers straight to recipients' mail servers
and DKIM-signs each message. Your side of the deal is a handful of DNS records
and a host that allows outbound port 25. Everything is driven from the
admin page at **`/editor/mail`** (admin role only).

### Should you use direct mode?

Prefer **relay mode** if any of these apply:

- **Your host blocks outbound port 25** — Fly.io always; AWS, GCP,
  DigitalOcean, and Hetzner by default (some unblock on request). The
  preflight button on `/editor/mail` tells you definitively.
- You **can't set reverse DNS (PTR)** for your server's IP.
- You need **high deliverability from day one** — a fresh IP with no sending
  history often lands in spam at Gmail/Outlook until it warms up, no matter
  how correct your DNS is.

Direct mode fits KilnCMS's minimal-ops goal for **transactional volume** from a
**stable IP** you control the PTR for — typically a VPS or bare metal. It is
not built for bulk/marketing sending.

### Setup

1. **Environment** — set `MAIL_MODE=direct` and `MAIL_FROM_EMAIL`
   (e.g. `cms@example.com`; its domain becomes the sending and DKIM domain).
   Optionally set `MAIL_HELO_HOST` (defaults to `PHX_HOST`) — it must match
   the PTR record below. Boot the release.
2. **DKIM key** — on `/editor/mail`, pick a key provider:
   - **Environment variable** or **file** *(recommended for production)* —
     point the page at a var like `DKIM_PRIVATE_KEY` or a mounted secret like
     `/run/secrets/dkim.pem` holding a **PKCS#1 RSA PEM**. Generate one with
     `openssl genrsa -out dkim.pem 2048`; if you have a PKCS#8 key
     (`BEGIN PRIVATE KEY`), convert it with
     `openssl rsa -in key.pem -traditional -out dkim.pem`. The page checks the
     source and derives the public key from it.
   - **Database** *(zero-ops default)* — click **Generate key**. The private
     key is stored AES-256-GCM-encrypted with a key derived from
     `SECRET_KEY_BASE`, so **rotating `SECRET_KEY_BASE` orphans the key** (the
     page tells you; regenerate and republish DNS). Env/file providers are
     immune to this.
3. **Server IP** — enter your server's public IPv4 address. It drives the SPF
   suggestion and the PTR check.
4. **DNS records** — publish the four records the page lists (copy-paste). See
   the worked example below for what they look like filled in.
5. **Verify** — click **Verify now** until the checks are green, run the
   **port-25 preflight**, then **send a test email**. For an outside opinion on
   deliverability (SPF/DKIM/DMARC scoring), send one to
   [mail-tester.com](https://www.mail-tester.com).

### Worked example

Sending domain `example.com`, server IP `203.0.113.9`, HELO host
`mail.example.com`, DKIM selector `kiln202607a1b2` (the page generates the
selector for you). The four records:

| Purpose | Type | Host / name | Value |
|---|---|---|---|
| SPF | `TXT` | `example.com` | `v=spf1 ip4:203.0.113.9 -all` |
| DKIM | `TXT` | `kiln202607a1b2._domainkey.example.com` | `v=DKIM1; k=rsa; p=MIIBIjANBgkq…` *(the page's exact value)* |
| DMARC | `TXT` | `_dmarc.example.com` | `v=DMARC1; p=quarantine; rua=mailto:cms@example.com` |
| PTR | `PTR` | `203.0.113.9` | `mail.example.com` |

The first three go in your **DNS zone**. The **PTR record is different** — it
lives in your **hosting provider's control panel** (reverse DNS / rDNS for the
IP), *not* your DNS zone, because you don't control the `in-addr.arpa` zone for
your provider's IP block.

### Key rotation

**Rotate key** (database provider) generates a new key **and a new selector**,
so the old DNS record can stay published while already-sent mail still
verifies. Publish the new record, then remove the old one after a few days.
For env/file providers, swap the key material at the source and re-save — the
selector rotates automatically whenever the key material actually changes.

---

## Understanding the verification checks

Each row on `/editor/mail` reports one of four states. `ok` and `skipped` need
no action; `check` (warn) and `fail` do.

| Check | `ok` | `check` (warn) | `fail` |
|---|---|---|---|
| **SPF** | The record names your IP exactly (`ip4:<your-ip>`). | A record exists but doesn't name your IP *directly* — it uses `include:`/`redirect`/a CIDR range, which this check doesn't evaluate. Confirm coverage yourself. | No `v=spf1` record found. |
| **DKIM** | The TXT at your selector matches the configured key. | *(shown as `skipped`)* No key generated/configured yet. | No record at the selector, **or** a different public key is published (often a stale record after rotation, or DNS still propagating). |
| **DMARC** | A `v=DMARC1` record exists at the domain or its parent org domain. | No DMARC record — mail can still flow, but Gmail/Yahoo bulk-sender rules increasingly expect one. | — |
| **PTR** | Reverse DNS round-trips (IP → name → IP) and matches your HELO host. | It round-trips but the PTR name differs from `MAIL_HELO_HOST` — align them for best deliverability. | No PTR, an invalid IP, or the name doesn't resolve back to the IP. |

The **port-25 preflight** is separate:

- **ok** — a probe MX answered; outbound port 25 works.
- **check** (warn) — KilnCMS *connected* to a probe MX but got a non-`220`
  greeting (e.g. a `554`). The port is open; this is almost always **IP
  reputation** (your IP is on a blocklist), not a blocked port. See
  troubleshooting.
- **fail** — couldn't reach any probe MX. Your host almost certainly **blocks
  outbound port 25**; use relay mode.

---

## Troubleshooting

**Everything is green but test mail lands in spam.**
Deliverability isn't just DNS. A fresh sending IP has no reputation, and
mailbox providers distrust it until it warms up (see the note below). Send a
test to [mail-tester.com](https://www.mail-tester.com) for a scored breakdown,
and check your IP against the [Spamhaus lookup](https://check.spamhaus.org).
Give it days of low, steady, genuinely-wanted mail.

**Port-25 preflight fails.**
Your host blocks outbound port 25. OVH and Hetzner unblock on a support
request; AWS via the "Request to remove email sending limitations" form; Fly.io
does not unblock at all. If you can't unblock it, switch to `MAIL_MODE=smtp`
with a relay — direct mode cannot work on that host.

**Port-25 preflight *warns* ("reachable, but rejected the greeting").**
The port is open but a probe MX greeted you with a `554` — your IP is almost
certainly on a blocklist. Look it up on Spamhaus, request delisting, and warm
the IP up. Switching to a relay also sidesteps this.

**DKIM check fails right after rotating.**
Two usual causes: (1) DNS hasn't propagated yet — wait and re-verify; (2) the
published `p=` value doesn't match — re-copy the exact record the page shows.
Note that rotation uses a *new selector*, so the check queries the new name;
if you republished under the old selector, publish the new one too.

**SPF shows `check` (warn), not `ok`.**
Your record covers the IP through an `include:` or CIDR rather than naming it
directly. That's fine — the check just can't confirm indirect coverage. Verify
manually (e.g. with an SPF checker) or add an explicit `ip4:<your-ip>`.

**PTR shows `check` (warn).**
Reverse DNS resolves but to a name other than your HELO host. Set
`MAIL_HELO_HOST` to the PTR name (or set the PTR to your HELO host in your
provider's panel) so they match.

**Mail is minutes late on first send to a domain.**
Normal — that domain **greylists** (deliberately rejects the first attempt to
deter spam). KilnCMS retries on a backoff tuned for exactly this; the message
arrives on a later attempt.

**Registration/reset succeeds but the user never gets the email.**
Delivery is queued, so the request succeeding doesn't mean mail was sent. Check
[monitoring](#monitoring-delivery): a `cancelled` job means a hard 5xx reject
(look at the logged reason), a `discarded` job means retries were exhausted,
and if you're in **local** mode (no relay/direct configured) *nothing* is
delivered — the app logs a warning about this at boot.

---

## Monitoring delivery

- **Logs** — Oban's default logger is attached, so job failures show up in the
  application logs. A permanent (5xx) reject additionally logs a
  `Mail permanently rejected …` warning with the (address-redacted) SMTP
  reason.
- **The `oban_jobs` table** — the source of truth for delivery state. `state`
  is `completed`, `retryable` (will try again), `cancelled` (a hard 5xx — the
  message won't be retried), or `discarded` (retries exhausted).
- **Telemetry** — hard bounces emit `[:kiln_cms, :mail, :bounced]` with the
  recipient domain(s) and a redacted reason; wire it into your metrics if you
  want bounce alerting.
- **Retention** — finished mail jobs are pruned after **7 days** (mail job
  args contain rendered token URLs, so they aren't kept indefinitely). If you
  need a longer audit window, adjust the `Oban.Plugins.Pruner` `max_age` in
  `config/config.exs`.

## Operational notes

- **Async bounces** (rejected *after* the receiving server accepted the
  message) are delivered to your `From` mailbox, wherever it's hosted — KilnCMS
  receives no email.
- **IP warm-up** — expect some spam-foldering from a fresh IP for the first
  days/weeks even with all-green DNS. Transactional volume warms up quickly.
- **Unsigned fallback** — if DKIM is configured but the key can't be resolved
  at send time (deleted secret, rotated `SECRET_KEY_BASE`), mail goes out
  **unsigned** with a logged warning rather than failing. Losing a signature
  hurts deliverability; losing a password reset is worse. The `/editor/mail`
  page surfaces the unresolvable key so you can fix it.

---

*Implementation/design background: [direct-email-delivery-plan.md](direct-email-delivery-plan.md).
Authorization for the settings resource: [policy-matrix.md](policy-matrix.md).*
