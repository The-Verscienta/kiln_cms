# Two-factor authentication (TOTP)

Kiln supports time-based one-time password (TOTP) two-factor authentication —
the "richer auth" Phase 1 ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331)).
Any account can add a second factor from a standard authenticator app (Google
Authenticator, 1Password, Authy, …); once enabled, a valid code is required at
every sign-in, after the first factor.

## How it works

- **Self-service enrolment** at `/editor/settings` → "Two-factor authentication":
  1. *Enable* generates a fresh secret (`setup_totp`) and shows a setup key + an
     `otpauth://` provisioning URI.
  2. The user adds it to their authenticator app and enters a current code to
     confirm (`confirm_totp`). Only then is 2FA enforced.
  3. *Disable* (`disable_totp`) requires a current code, so a walk-up attacker on
     an open session still can't remove the factor.
- **Sign-in gate:** `KilnCMSWeb.AuthController.success/4` diverts a 2FA-enabled
  account to `/sign-in/verify` instead of establishing a session. A short-lived
  (5-minute), signed pending token carries the user id + the already-minted
  first-factor token across the redirect — the user is **not** signed in until a
  valid code is entered. The `:auth` rate limit slows code brute-forcing.

## The TOTP implementation

`KilnCMS.Accounts.Totp` implements RFC 6238 on Erlang's `:crypto` (HMAC-SHA1)
with **no external dependency**. Correctness is pinned to the RFC 6238 published
test vectors (`KilnCMS.Accounts.TotpTest`). Defaults: 6 digits, 30-second period,
±1 step of clock-drift tolerance, constant-time code comparison.

The raw secret is stored as `users.totp_secret` (`bytea`, `sensitive?`,
`public? false`); it is never exposed on any API surface and is read only by the
sign-in gate and the owner's enrolment UI. 2FA is "enabled" iff
`totp_confirmed_at` is set.

## Recovery codes & QR (Phase 2, shipped)

- **Recovery codes.** Confirming enrolment mints 10 one-time codes
  (`XXXX-XXXX`), shown exactly once — only SHA-256 hashes are stored
  (`totp_recovery_hashes`; the codes are 40-bit uniform random, so a fast hash
  is appropriate, matched in constant time). At the sign-in gate a recovery
  code works in place of the 6-digit TOTP and is **burned in the same update**
  (`:consume_totp_recovery_code`), so it can never sign in twice.
  `/editor/settings` shows the unused count and can regenerate the set (needs a
  current authenticator code; regeneration invalidates unused codes). Disabling
  2FA clears the set.
- **QR-code image.** Enrolment renders the `otpauth://` URI as an inline SVG QR
  (`eqrcode`, pure Elixir) alongside the setup key.

## Scope & later phases

Still out of scope (the other half of #331):

- **SSO (OAuth2/OIDC/SAML) and passkeys/WebAuthn**.
  `assent` (bundled with `ash_authentication`) already supports OAuth2/OIDC, so
  SSO needs no new dependency; it was deferred here only because it can't be
  verified without a live identity provider.
