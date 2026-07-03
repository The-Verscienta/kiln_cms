# Direct email delivery — operator guide

KilnCMS can send email **without an external SMTP provider**: with
`MAIL_MODE=direct` it delivers straight to each recipient domain's mail
servers on port 25 and DKIM-signs every message. Your side of the deal is a
handful of DNS records and a hosting environment that allows outbound SMTP.

Everything on this page is driven from **`/editor/mail`** (admin-only): DKIM
key management, the exact DNS records to publish, live verification, and a
port-25 preflight.

(Design/implementation background: [direct-email-delivery-plan.md](direct-email-delivery-plan.md).
Relay mode and all variables: [environment-variables.md](environment-variables.md).)

## Should you use direct mode?

Use **relay mode** (`MAIL_MODE=smtp`, or just `SMTP_HOST`) if any of these
apply:

- Your host blocks outbound port 25 — **Fly.io always; AWS, GCP,
  DigitalOcean, and Hetzner by default** (some unblock on request). The
  preflight button on `/editor/mail` tells you definitively.
- You can't set reverse DNS (PTR) for your server's IP.
- You need high deliverability from day one: a fresh IP with no sending
  history often lands in spam at Gmail/Outlook until it warms up, no matter
  how correct your DNS is.

Direct mode fits KilnCMS's minimal-ops goal for transactional volume
(password resets, magic links, workflow notifications) from a stable IP —
typically a VPS or bare metal where you control the PTR record.

## Setup

1. **Environment** — set `MAIL_MODE=direct` and `MAIL_FROM_EMAIL`
   (e.g. `cms@example.com`; its domain becomes the sending and DKIM domain).
   Optionally `MAIL_HELO_HOST` (defaults to `PHX_HOST`) — it must match the
   PTR record below. Boot the release.
2. **DKIM key** — on `/editor/mail`, pick a key provider and set up the key:
   - **Environment variable** or **file** (recommended for production): point
     the page at a var like `DKIM_PRIVATE_KEY` or a mounted secret like
     `/run/secrets/dkim.pem` holding a PKCS#1 RSA PEM
     (`openssl genrsa -out dkim.pem 2048`; convert PKCS#8 with
     `openssl rsa -in key.pem -traditional -out dkim.pem`). The page checks
     the source and derives the public key from it.
   - **Database** (zero-ops default): click *Generate key*. The private key
     is stored AES-256-GCM-encrypted with a key derived from
     `SECRET_KEY_BASE` — which means rotating `SECRET_KEY_BASE` orphans the
     key (the page will tell you; regenerate and republish DNS). Env/file
     providers are immune to this.
3. **Server IP** — enter your server's public IPv4 address (it drives the
   SPF suggestion and the PTR check).
4. **DNS records** — publish the four records the page lists, copy-paste:
   - `TXT` at the domain: `v=spf1 ip4:<your-ip> -all`
   - `TXT` at `<selector>._domainkey.<domain>`: the DKIM public key
   - `TXT` at `_dmarc.<domain>`: e.g. `v=DMARC1; p=quarantine; rua=mailto:<from>`
   - **PTR** for your IP → your HELO host — set in your **hosting
     provider's panel** (not your DNS zone)
5. **Verify** — click *Verify now* until everything is green, run the
   port-25 preflight, then send a test email. For an outside opinion
   (SPF/DKIM/DMARC scoring), send a test to a service like
   [mail-tester.com](https://www.mail-tester.com).

## Key rotation

*Rotate key* (database provider) generates a new key **and a new selector**,
so the old DNS record can stay published while already-sent mail still
verifies; publish the new record, and remove the old one after a few days.
For env/file providers, swap the key material at the source and re-save —
the selector rotates automatically whenever the key actually changes.

## Operational notes

- **Delivery is queued** (Oban `mail` queue) with backoff tuned for
  greylisting — a receiver's deliberate first-attempt rejection. A first
  email to a greylisting server can arrive minutes late; that's normal.
  Hard bounces (5xx) cancel the job and emit a
  `[:kiln_cms, :mail, :bounced]` telemetry event.
- **Asynchronous bounces** (sent after acceptance) go to the `From` mailbox,
  wherever it's hosted — KilnCMS receives no email.
- **IP warm-up**: expect some spam-foldering from a fresh IP for the first
  days/weeks even with all-green DNS. Transactional volume warms up quickly.
- **Unblocking port 25**: OVH and Hetzner unblock on support request;
  AWS via the "Request to remove email sending limitations" form. Fly.io
  does not unblock — use a relay there.
- If DKIM is configured but the key becomes unresolvable at send time
  (deleted secret, rotated `SECRET_KEY_BASE`), mail goes out **unsigned**
  with a logged warning rather than failing — losing a signature hurts
  deliverability; losing a password reset is worse.
