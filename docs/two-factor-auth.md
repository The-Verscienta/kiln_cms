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
- **Sign-in gate (browser):** `KilnCMSWeb.AuthController.success/4` diverts a
  2FA-enabled account to `/sign-in/verify` instead of establishing a session. A
  short-lived (5-minute), signed pending token carries the user id + the
  already-minted first-factor token across the redirect — the user is **not**
  signed in until a valid code is entered. The blob only needs signing because
  it lives in the (encrypted) session, where the client never sees it.
- **Sign-in gate (headless):** `POST /api/auth/sign_in` answers a 2FA account
  with `200 {"two_factor_required": true, "pending_token": …}` rather than the
  `201` + JWT a single-factor account gets, and `POST /api/auth/sign_in/verify`
  redeems that plus a code
  ([#726](https://github.com/The-Verscienta/kiln_cms/issues/726)). Same five
  minutes and the same budget as the browser prompt. This blob *is* handed to
  the client, so it is **encrypted** rather than signed and is single-use; see
  `KilnCMS.Accounts.PendingSignIn` and `docs/api.md`.

  Until #726 this endpoint asked for no second factor at all, which is why the
  sentence at the top of this page — "a valid code is required at every sign-in"
  — is only now true. API keys remain the recommended credential for unattended
  server-to-server use, and carry no second factor by design.
- **Where the code is checked:** `KilnCMS.Accounts.SecondFactor.check/2`, for
  both gates, so neither can drift on what counts as a valid submission.
  Whitespace normalization sits one level lower still, in
  `KilnCMS.Accounts.Totp.valid?/3`, because the enrolment and disable forms
  check a code too and used to reject the `123 456` an authenticator app copies.

## "Remember me" and the second factor

Ticking "Remember me" on the sign-in page issues a 30-day cookie that signs the
browser in on its own. For a 2FA account that cookie is only issued **after a
code verifies** ([#699](https://github.com/The-Verscienta/kiln_cms/issues/699)):
AshAuthentication writes it at the first factor by default, which would let
someone tick the box, close the code prompt, and keep a credential that never
asks for a code again. `KilnCMSWeb.AuthController` withholds it there and
`KilnCMSWeb.TwoFactorController` issues it on success instead.

Once issued it *does* skip the code prompt on later visits, deliberately — it
represents a device that completed every factor. Signing out deletes it. Note
that changing the password does **not** currently revoke it (nor any other
stored token — see [#730](https://github.com/The-Verscienta/kiln_cms/issues/734)),
so signing out is the reliable way to withdraw a device today.

## Why a wrong code can say "too many attempts"

Six digits and a ±1-step tolerance are guessable in a way a password is not, and
whoever is at that prompt has already got past the first factor. So beyond the
per-IP `:auth` limit — which an attacker escapes by rotating addresses — every
submitted code is charged a **per-account** budget: five per fifteen minutes,
keyed on the account the pending token names, cleared the moment a valid code is
accepted ([#714](https://github.com/The-Verscienta/kiln_cms/issues/714)).

What an operator should know when a user reports it:

- **It is per account, not per browser or per address.** Signing in from another
  device or network does not reset it, and neither does re-entering the password
  — a fresh pending token does not refill the budget, which is the point.
- **It is per account, not per *surface*.** The browser prompt and the headless
  `POST /api/auth/sign_in/verify` charge the same bucket (#726), so a user whose
  correct code is refused in the browser may have spent it in a script — a CI
  job or a mobile client retrying a stale code will do it silently. Check for a
  headless client before concluding the browser attempts don't add up.
- **All three settings forms share it too.** *Enabling*, *disabling* and
  *regenerating recovery codes* on `/editor/settings` each charge the same
  bucket ([#727](https://github.com/The-Verscienta/kiln_cms/issues/727)) — they
  verify the same six digits, and a separate budget would just be this one
  twice as large. So a user who mistyped at a settings prompt can find the
  sign-in prompt refusing them, and the reverse. Those forms say "too many
  attempts — try again in N seconds" rather than "that code isn't valid", for
  the same reason the sign-in prompt does.

  Enrolment is on that list, which is not obvious. `confirm_totp` is not
  scoped to an enrolment in progress: run against an account that is *already*
  enrolled it checks the live secret and mints a fresh recovery-code set, which
  is `regenerate_totp_recovery_codes`' prize through a different door. The cost
  is that a user enrolling with a skewed device clock can spend the budget that
  gates their next sign-in — a correct code clears it.
- **TOTP codes and recovery codes share it.** Someone who has spent the budget
  guessing codes cannot fall back to recovery codes until the window rolls.
- **A completed password reset clears it.** That is the remedy to offer: it is
  also what stops an attacker minting the pending tokens they were spending the
  budget with.
- **A lockout at the *sign-in* prompt mails the owner**
  ([#728](https://github.com/The-Verscienta/kiln_cms/issues/728)). Reaching that
  prompt needs a pending token, and a pending token is only minted once a **first
  factor has already succeeded** — so a lockout there means someone got in far
  enough to be asked for a code, which is a much stronger signal than the
  password alert's "someone is guessing".

  Two things the mail deliberately does *not* say, both of which the obvious
  wording would get wrong:

  - **It does not say "someone has your password".** `AuthController.success/4`
    is the callback for every strategy, so a magic link and an SSO assertion
    reach the code prompt exactly as a password does. For those users the
    compromised thing is their mailbox or their identity provider, and telling
    them to change their Kiln password would leave the actual hole open. The
    mail lists all three.
  - **It does not assume an attacker.** The budget is shared with the settings
    forms (#727), so an owner who fumbles five codes regenerating their recovery
    set and then signs in normally trips it with nobody attacking them — the
    likeliest trigger in practice. "If that was you" comes second in the mail,
    before the intrusion paragraph, not buried at the end.

  Separate copy and a separate once-per-six-hours budget from the password
  alert, so the weaker signal cannot suppress the stronger one. The refusal is
  logged when the mail goes and when it is suppressed; if delivery then fails,
  the window is handed back so the next refusal can try again.

  Note the password alert (#478) used to be structurally unable to fire in this
  scenario: to keep grinding codes an attacker must keep re-running the first
  factor, and that step succeeds, which forgave the sign-in counter every time.
  Before #728, the one case where a primary credential was provably in someone
  else's hands produced no notification at all. #742 closed that reset, so both
  alerts can now fire on the same attack — this one first, because the
  second-factor budget is the tighter of the two.

  A lockout that happens *entirely* at `/editor/settings` — with no sign-in
  attempt afterwards — still sends nothing, because the person there holds a
  session rather than a first factor and that is different news (see #757).
- **Whitespace is not a wasted attempt.** `123 456` pasted from an authenticator
  is normalized before it is checked; recovery codes are already case- and
  separator-insensitive.
- **It answers 429 with `Retry-After`,** rather than the generic "that code
  isn't valid" a wrong code gets. Unlike the rest of the auth flow there is
  nothing to hide here — whoever is asking already holds a signed token naming
  the account — and telling a user their correct code was wrong is worse.

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

Shipped since, and no longer out of scope:

- **Passkeys/WebAuthn** — `KilnCMS.Accounts.WebAuthn`,
  `KilnCMSWeb.PasskeyController`, `/auth/passkey/*`. A verified passkey
  completes sign-in **without** a TOTP prompt, on purpose: every Kiln passkey is
  registered *and* asserted with user verification required, so the ceremony
  already proves possession + PIN/biometric. That is policy, and
  `docs/threat-model.md` records it as such. Passkeys are browser-only — there
  is no headless ceremony.
- **SSO (OAuth2/OIDC)** — built on `assent` (bundled with
  `ash_authentication`), compile-gated off by default: set
  `config :kiln_cms, :sso_oidc, enabled: true` plus the `OIDC_*` env and
  recompile. An SSO sign-in completes through `AuthController.success/4` like
  any other, so a 2FA account is diverted to the code prompt from there too.

Still out of scope (the other half of #331):

- **SAML.**
