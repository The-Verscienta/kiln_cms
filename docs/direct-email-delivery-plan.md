# Direct email delivery (built-in MTA) — implementation plan

Status: planned, not started.

## Goal

Let a KilnCMS instance send email **without an external SMTP relay**: the app
delivers straight to each recipient domain's MX servers on port 25, DKIM-signs
every message, and the admin UI tells the operator exactly which DNS records to
publish and verifies them live. Send-only — no inbound SMTP listener, no new
exposed ports.

This becomes a third mailer mode alongside the existing two:

| Mode | Selected by | Adapter |
|---|---|---|
| `local` (dev) | default | `Swoosh.Adapters.Local` |
| `smtp` (relay) | `SMTP_HOST` set (unchanged) or `MAIL_MODE=smtp` | `Swoosh.Adapters.SMTP` |
| `direct` (new) | `MAIL_MODE=direct` | `KilnCMS.Mailer.DirectMX` (new) |

## Non-goals

- Receiving email (bounces/DSNs arrive at the `From` mailbox, hosted wherever
  the operator already has it — document this).
- Full SPF evaluation, ARC, BIMI, or per-message deliverability analytics.
- Making direct delivery work on hosts that block outbound port 25 (Fly.io,
  default AWS/GCP/DO). We detect and report it; we can't fix it.

## Why the pieces are cheap here

- `gen_smtp` is already a dependency ([mix.exs:127](../mix.exs)).
- `Swoosh.Adapters.SMTP` already supports `dkim:` (passed through to
  gen_smtp's `mimemail` encoder for rsa-sha256 signing) and `no_mx_lookups:
  false` (gen_smtp resolves MX records for the `relay` domain itself). The
  DirectMX adapter is mostly recipient-grouping + config around a
  `Swoosh.Adapters.SMTP.deliver/2` call.
- Oban already runs a `mail: 3` queue with `WorkflowMailWorker` as precedent.
- Admin-only LiveView routes exist (`ash_authentication_live_session
  :admin_routes` + `:live_admin_required` in the router).

## Architecture overview

```
Ash senders / notifications
        │  KilnCMS.Mail.enqueue(email)        (serialize Swoosh.Email → Oban args)
        ▼
Oban queue :mail — KilnCMS.Mail.DeliveryWorker (retry/backoff, greylist-aware)
        │  Mailer.deliver(email)
        ▼
KilnCMS.Mailer ── adapter per MAIL_MODE
        ├── Swoosh.Adapters.SMTP        (relay, unchanged)
        └── KilnCMS.Mailer.DirectMX     (new)
                │  group recipients by domain
                │  per domain: relay = domain, MX lookup, port 25,
                │  STARTTLS if offered, DKIM-sign via mail settings
                ▼
        recipient MX servers
```

DKIM key + operator-facing state live in a singleton Ash resource
(`KilnCMS.Mail.Settings`); the admin page at `/editor/mail` (admin role only)
generates the key, lists the DNS records to publish, verifies them, runs the
port-25 preflight, and sends test emails.

---

## Phase 1 — queue all outbound mail through Oban

Today the three AshAuthentication senders (`send_magic_link`,
`send_password_reset_email`, `send_new_user_confirmation_email`) call
`Mailer.deliver!/1` synchronously inside the Ash action. Direct MX delivery is
slow (MX lookup + remote SMTP dialog) and greylisting rejects first attempts
by design, so synchronous delivery is a non-starter — and async is an
independent win for relay mode too (registration no longer blocks on the
relay's latency).

New modules:

- `KilnCMS.Mail` — public entry point. `enqueue(%Swoosh.Email{})` serializes
  the email (from/to/cc/bcc/reply-to/subject/html/text/headers — all our
  emails are simple; raise on attachments for now) into Oban args and inserts
  a `DeliveryWorker` job, one job per recipient (mirrors `WorkflowMailWorker`;
  keeps retries per-recipient-domain independent). Also `deliver_now/1` for
  the admin test-email path (synchronous, returns the SMTP receipt or error).
- `KilnCMS.Mail.DeliveryWorker` — `queue: :mail`, `max_attempts: 8`, custom
  `backoff/1` ≈ 1m, 5m, 15m, 1h, 2h, 4h, 8h (greylist windows are minutes;
  the tail covers MX outages). Error classification:
  - permanent (5xx SMTP reply): `{:cancel, reason}` — log + telemetry event
    `[:kiln_cms, :mail, :bounced]`, no retry;
  - transient (4xx, connect/timeout/DNS errors): raise → Oban retries.
- Convert the three senders + `WorkflowMailWorker`'s `Mailer.deliver!` to
  `KilnCMS.Mail.enqueue/1`. `WorkflowMailWorker` keeps building the email but
  delegates delivery (or is folded into `DeliveryWorker` — decide in
  implementation; folding removes one worker but loses its build-at-run-time
  args shape; either fine).

Tests: existing `assert_email_sent` assertions gain a
`DataCase.drain_oban/0` first (established pattern from the queue-split work).
Worker unit tests for serialization round-trip, error classification, backoff
schedule.

## Phase 2 — `KilnCMS.Mailer.DirectMX` adapter + config wiring

`lib/kiln_cms/mailer/direct_mx.ex`, `use Swoosh.Adapter`:

1. Group `to ++ cc ++ bcc` by recipient domain (with one-job-per-recipient
   from Phase 1 this is usually a single domain, but the adapter must be
   correct standalone).
2. Per domain, delegate to `Swoosh.Adapters.SMTP.deliver(email_subset, cfg)`
   with:
   - `relay: domain`, `no_mx_lookups: false` (gen_smtp resolves MX, falls
     back to the A record per RFC 5321), `port: 25`, `auth: :never`,
   - `tls: :if_available` (opportunistic STARTTLS — standard MTA behavior;
     `tls_options` stay permissive like real MTAs, since remote MX certs are
     routinely self-signed),
   - `hostname:` HELO name from `MAIL_HELO_HOST` (default: `PHX_HOST`) — must
     match the PTR record for deliverability,
   - `sockopts: [:inet]` to force IPv4 (IPv6 sending demands stricter
     reputation; opt in later if ever),
   - `dkim:` fetched from `KilnCMS.Mail.dkim_config/0` (Phase 3; `nil` → send
     unsigned, UI warns).
3. Aggregate results: all domains ok → `{:ok, receipts}`; any failure →
   `{:error, ...}` carrying the worst failure (the worker classifies it).

Also ensure a `Message-ID` header on every email built in `KilnCMS.Mail`
(`<uuid@sending_domain>`) — Gmail scores messages without one.

`config/runtime.exs`: introduce `MAIL_MODE` (`smtp` | `direct`; absent →
current behavior, so **no breaking change**: `SMTP_HOST` alone still means
relay mode). `direct` requires `MAIL_FROM_EMAIL` (its domain = sending
domain) — raise at boot with a clear message if missing. Update the config
comment block and `docs/environment-variables.md` (`MAIL_MODE`,
`MAIL_HELO_HOST`, `MAIL_SERVER_IP`, `DKIM_*` overrides).

## Phase 3 — key management via pluggable providers (`KilnCMS.Keys`)

Modeled on Drupal's [Key module](https://www.drupal.org/project/key): the CMS
stores key **metadata** (which provider, provider config, the non-secret
public half), while the secret material lives wherever the provider points.
Consumers resolve a key by name at use time and never store secrets
themselves. Drupal ranks its providers Configuration (DB, dev-only) < File <
Environment < external KMS; we mirror that ranking in the UI.

### `KilnCMS.Keys` subsystem

- `KilnCMS.Keys.Provider` behaviour:
  `fetch(config) :: {:ok, secret} | {:error, reason}` plus
  `writable?/0` (only the database provider can be written from the UI) and
  `check(config)` (readable? well-formed PEM?) for the settings page.
- Built-in providers (one module each, trivially extensible later — an
  external-KMS provider would just be another implementation):
  - `Env` — config: `%{var: "DKIM_PRIVATE_KEY"}`; reads at resolve time.
  - `File` — config: `%{path: "/run/secrets/dkim.pem"}`; the natural fit for
    Docker/K8s mounted secrets; docs recommend a path outside any
    bind-mounted content dir.
  - `Database` — AES-256-GCM in the settings row, key derived from
    `secret_key_base` via `Plug.Crypto.KeyGenerator` (no new dep). The
    zero-ops default so "generate in UI and go" works, labeled in the UI as
    the least-preferred option for production, per the Drupal ranking.
- `KilnCMS.Keys.fetch(:dkim)` — the consumer API. A named-key registry with a
  single entry for now; deliberately minimal (no key-type/input plugins à la
  Drupal) until a second consumer (e.g. SMTP password) wants in. Resolution
  cached in Cachex, invalidated on settings change.

### `KilnCMS.Mail.Settings` resource

Singleton Ash resource, new `mail_settings` table, in a new small
`KilnCMS.Mail` Ash domain (registered in `ash_domains`):

| attribute | type | notes |
|---|---|---|
| `dkim_selector` | string | e.g. `kiln2026a`; new value on each rotation |
| `dkim_key_provider` | atom | `:database` \| `:env` \| `:file` |
| `dkim_key_provider_config` | map | var name / file path; empty for `:database` |
| `dkim_private_key_encrypted` | binary, nullable | populated only when provider = `:database` |
| `dkim_public_key` | string | base64 DER as it appears in the TXT record — always stored (not secret), so DNS display/verify work with any provider |
| `server_ip` | string, nullable | operator-entered public IP; drives SPF suggestion + PTR check |
| `last_verified_at` / `verification_results` | timestamp / map | cached DNS check output |

Actions (all admin-only policies; document in `docs/policy-matrix.md`):

- `generate_dkim` — `:public_key.generate_key({:rsa, 2048, 65537})`,
  PEM-encode, store via the database provider; derive selector. From the
  env/file providers this switches back to `:database` with fresh material;
  with a database key already present it refuses (use `rotate_dkim`).
- `configure_key_source` — set provider + config for env/file; on save,
  `check` the source, derive the public key from the private key found there,
  and store public key + a fresh selector (rotating the selector whenever the
  key material changes).
- `rotate_dkim` — new key **and** new selector (old TXT record can stay
  published while mail signed with the old key is still in transit).
  Database-provider only; for env/file the operator swaps the source and
  re-runs `configure_key_source`.
- `set_server_ip`, `record_verification`.

`KilnCMS.Mail.dkim_config/0` returns
`[s: selector, d: sending_domain, private_key: {:pem_plain, pem}]` with the
PEM resolved through `KilnCMS.Keys.fetch(:dkim)`, so the adapter is
provider-agnostic. Resolve failure (unset var, unreadable file, decrypt
failure) → send unsigned + telemetry warning + banner on the settings page,
never a crashed send.

## Phase 4 — DNS verification + port-25 preflight

`KilnCMS.Mail.DnsCheck` (pure `:inet_res`, no new deps). Each check returns
`{:ok | :warn | :fail, detail}` so the UI can render pass/warn/fail rows:

- **DKIM**: TXT at `<selector>._domainkey.<domain>`; join character chunks,
  parse tags, compare `p=` to stored public key. Fail on mismatch (stale
  record from a previous key is the classic operator error).
- **SPF**: TXT at `<domain>` containing `v=spf1`. Pass if it includes
  `ip4:<server_ip>`; warn if a record exists but we can't confirm coverage
  (includes/redirects — we don't evaluate them, we show the found record for
  eyeballing); fail if absent. Suggested record shown verbatim:
  `v=spf1 ip4:<server_ip> -all`.
- **DMARC**: TXT at `_dmarc.<domain>` starting `v=DMARC1`. Suggested:
  `v=DMARC1; p=quarantine; rua=mailto:<from>`. Warn-level if absent (mail can
  still flow, but Gmail/Yahoo bulk-sender rules increasingly expect it).
- **PTR**: reverse lookup of `server_ip` → hostname → forward lookup must
  round-trip to the IP; warn if the PTR name ≠ HELO hostname. Skipped
  (with explanation) until `server_ip` is set.
- **Port-25 preflight** (`check_port25/0`): resolve MX of 2–3 fixed probe
  domains (e.g. `gmail.com`, `outlook.com`), TCP-connect to one MX on :25
  with a 5s timeout and read the `220` banner, then QUIT. Any success →
  reachable; all fail → "your host blocks outbound port 25 — use SMTP relay
  mode", the single most important message on the page. Fixed probe targets
  only — never an operator-supplied hostname (keeps this away from the
  webhook SSRF guard's threat model; note that direct delivery itself
  inherently connects to arbitrary recipient-domain MXes, which is the
  feature, and the page is admin-only).

Results persisted via `record_verification` so the page shows last-checked
state on mount; "Verify now" re-runs live (in a `Task`, LiveView stays
responsive).

## Phase 5 — admin UI (`/editor/mail`) + docs

New `KilnCMSWeb.MailSettingsLive` inside the existing `:admin_routes` live
session (per-user `/editor/settings` stays as is). Sections:

1. **Status** — active mode (from env, read-only with a pointer to
   `MAIL_MODE`), from address, HELO host, DKIM state (signed/unsigned).
2. **DKIM key** — provider select (database / environment variable / file,
   ranked with a "preferred for production" hint on env/file, mirroring
   Drupal Key's guidance); database → generate / rotate buttons; env/file →
   config input + source check result. Public key shown as the exact TXT
   record with a copy button. Private key is never displayed regardless of
   provider.
3. **DNS records table** — host / type / expected value / live status for
   SPF, DKIM, DMARC, plus PTR instructions ("set in your hosting provider's
   panel, not your DNS zone") and the server-IP input. "Verify now" button.
4. **Preflight & test** — port-25 check result; "send test email" form
   (synchronous via `Mail.deliver_now/1`, renders the SMTP receipt or the
   exact error; suggest mail-tester.com in help text).

All user-facing strings through gettext. Nav entry alongside the other
editor-area links, rendered for admins only.

Docs: new `docs/direct-email-delivery.md` operator guide (DNS records, PTR
how-to per common host, port-25 unblock request links for OVH/Hetzner, IP
warm-up expectations, "when to prefer a relay"), updates to
`docs/environment-variables.md` and `docs/policy-matrix.md`.

## Testing strategy

- **Adapter**: start gen_smtp's bundled `gen_smtp_server` on
  `127.0.0.1:<ephemeral>` in tests as a receiving sink; adapter accepts
  `relay_override`/`port`/`no_mx_lookups: true` in config for tests. Assert
  multi-domain grouping, STARTTLS negotiation flag handling, and that the
  `DKIM-Signature` header carries the right `d=`/`s=` and verifies against
  the stored public key.
- **DKIM signing**: encode → parse header → verify `b=` with `:public_key`
  (relaxed/relaxed canonicalization as produced by mimemail).
- **DnsCheck**: `:inet_res` calls behind a small behaviour so tests inject
  fixture responses (chunked TXT records, NXDOMAIN, mismatched PTR).
- **Settings resource**: encrypt/decrypt round-trip, rotate changes selector,
  policies (non-admin forbidden) — respecting the shared-sandbox rules
  (scope assertions to seeded records, no full-table equality).
- **Worker**: 5xx cancels + emits telemetry, 4xx raises/retries, backoff
  schedule values.
- **LiveView**: mount as admin renders records table; non-admin gets 403
  redirect; verify button updates statuses (with injected DnsCheck stub).
- `mix format` + `mix precommit` per repo rules.

## Risks & accepted limitations

1. **Port 25 blocked at the host** — most common failure; mitigated by the
   preflight being loud and the docs steering those users to relay mode.
2. **IP reputation** — correct DNS is necessary, not sufficient; fresh cloud
   IPs may land in spam at Gmail/Outlook until warmed up. Documented
   expectation, not solvable in code. Transactional volume + correct
   PTR/DKIM/SPF/DMARC is usually fine after warm-up.
3. **No inbound bounce processing** — 5xx at send time is logged/cancelled;
   asynchronous bounces go to the `From` mailbox. Documented.
4. **SPF check is presence-level, not an evaluator** — deliberate; warn
   states make this visible instead of pretending.
5. **`secret_key_base` rotation** invalidates a database-provider DKIM key
   (its encryption key is derived from it) — detect decrypt failure and
   surface "re-generate or switch provider" in the UI rather than crashing
   sends (fall back to unsigned + warning). Env/file providers are immune,
   one more reason they're the recommended production tier.
6. **Greylisting** — handled by Oban backoff; magic links/password resets
   may arrive minutes late on first contact with a greylisting MX. Mention in
   docs.

## Delivery order & rough size

| PR | Content | Size |
|---|---|---|
| 1 | Phase 1 (Oban-routed mail) | S–M, standalone win |
| 2 | Phase 2 (DirectMX adapter + `MAIL_MODE`) | M |
| 3 | Phase 3 (DKIM resource + signing) | M (includes migration) |
| 4 | Phase 4 (DnsCheck + preflight) | S–M |
| 5 | Phase 5 (admin LiveView + docs) | M |

Each PR keeps `mix precommit` green; feature is inert until an operator sets
`MAIL_MODE=direct`.
