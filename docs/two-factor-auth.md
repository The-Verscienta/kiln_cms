# Two-factor authentication (TOTP)

Kiln supports time-based one-time password (TOTP) two-factor authentication —
the "richer auth" Phase 1 ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331)).
Any account can add a second factor from a standard authenticator app (Google
Authenticator, 1Password, Authy, …); once enabled, a valid code is required at
every sign-in, after the first factor.

## How it works

- **Self-service enrolment** at `/editor/settings` → "Two-factor authentication":
  1. *Enable* generates a fresh secret (`setup_totp`) into a **pending** slot
     (`totp_pending_secret`) and shows a setup key + an `otpauth://`
     provisioning URI. The live secret and enforcement state are untouched by
     this step, so starting (or restarting) enrolment can never by itself
     weaken an already-confirmed account (#754).
  2. The user adds it to their authenticator app and enters a current code to
     confirm (`confirm_totp`), which is checked against the *pending* secret.
     Only on success is it promoted to the live secret and 2FA enforced —
     `setup_totp` alone never flips that switch. `confirm_totp` re-reads the
     pending secret from the database, so if a second settings tab started a
     newer enrolment in the meantime, **the last `setup_totp` wins**: a code
     from the older tab's now-superseded secret is rejected as invalid rather
     than silently promoting a secret the database no longer holds (#787).
  3. *Disable* (`disable_totp`) requires a current *live* code, so a walk-up
     attacker on an open session still can't remove the factor — and clears any
     abandoned pending secret along with it.

  Re-enrolling on an account that already has a confirmed factor works the same
  way, which is also what makes it self-service for someone who lost their
  device: a recovery-code sign-in gets them a session but no live code to
  prove, and re-enrolment asks for none — only a code from the *new* device.
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
- **The first-factor token is held for the length of the step**
  ([#742](https://github.com/The-Verscienta/kiln_cms/issues/742)). `User` sets
  `store_all_tokens?`, so the first-factor JWT is minted *and inserted into
  `tokens`* before either gate has looked at `totp_enabled?`. Withholding the
  caller's access to it is not the same as withholding the token: an exchange
  abandoned at the prompt used to leave a live, usable row that nobody held, for
  the JWT's full lifetime.

  `PendingSignIn.mint_and_hold/4` therefore moves that row to the `pending_second_factor`
  purpose and shortens its expiry to the length of this step, and
  `PendingSignIn.claim/1` puts it back once a code verifies. AshAuthentication
  requires a row under the `user` purpose to authenticate a JWT
  (`require_token_presence_for_authentication?`), so in between the token
  authenticates nothing, wherever it is. Both gates, one code path — which is
  why the browser prompt calls `claim/1` at all, when the single use a session
  blob needs is the deleted session key.

  That dependency on AshAuthentication is pinned rather than assumed
  ([#1172](https://github.com/The-Verscienta/kiln_cms/issues/1172)).
  `KilnCMS.Accounts.SecondFactorHoldExtension` fails the compile if `User`
  ever turns off `require_token_presence_for_authentication?` or
  `store_all_tokens?`, or points `token_resource` away from
  `KilnCMS.Accounts.Token` — any of which would leave the hold a silent no-op
  with every test green. And
  `test/kiln_cms/accounts/second_factor_hold_contract_test.exs` drives a held
  token through the dep's *own* bearer and session round trips, so a future
  AshAuthentication that quietly widened its purpose filter would go red on
  the `mix.lock` bump rather than re-opening #742 unnoticed.

  Held rather than revoked, because the exchange may still complete — and the
  release is filtered on the hold purpose **in the UPDATE's own WHERE**, so a
  token revoked mid-window is not resurrected by a late redemption even if the
  revocation lands after the release has read the row. The revokers are
  `log_out_everywhere` (a password change) and account erasure, which sweep
  every row a subject owns, held ones included. Sign-out revokes too, but only
  the token in *that* session — a browser sitting at the code prompt is not
  signed in and carries none, so signing out elsewhere does not reach a held
  row.
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
  attempt afterwards — sends its **own** mail (#757), not this one. The person
  there holds a live session rather than a first factor, so the news is
  different and so is the advice: "someone signed in with your password" is not
  what happened, and changing the password matters here because it signs every
  other session out, not because the password itself is suspect. It carries a
  third alert budget for the same reason the second-factor one is separate from
  the sign-in one — the three signals are strictly ordered, and the weaker must
  never suppress the stronger.

  It is also the lockout with no other symptom: a stolen session produces no
  failed sign-ins for the owner to notice.
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
`totp_confirmed_at` is set. `users.totp_pending_secret` holds an in-progress,
not-yet-proven enrolment in the same shape — `setup_totp` writes only this
one, `confirm_totp` is the only action that ever copies it into `totp_secret`,
and it is what a code is checked against while an enrolment is in progress
(#754).

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
