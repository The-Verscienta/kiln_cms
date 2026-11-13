# Passkeys (WebAuthn)

Kiln supports **passkey sign-in** ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331),
final phase): a user registers their device's platform authenticator (Touch
ID, Windows Hello, a phone, a security key) and signs in without a password.

## Using it

- **Enroll** at `/editor/settings` → *Passkeys*: optionally fill in "Name this
  passkey" (for example "MacBook Touch ID"), then click "Add a passkey". The
  browser prompts for the device screen lock while the page reads "Waiting for
  your device…". The credential is then listed with its name, the date it was
  added and the date it was last used. A passkey can't be renamed: remove it
  with the trash button and add it again. Multiple passkeys per account.
- **Sign in** at `/sign-in` → "Use a passkey" (the button appears only in
  WebAuthn-capable browsers). The browser offers your saved passkeys, with no
  email or password typed. If the ceremony fails, the page says "Passkey
  sign-in failed. Use another method."
- **Finish a two-step sign-in** at `/sign-in/verify` → "Use a passkey": an
  account that has an authenticator app *and* a passkey, signing in with its
  password (or a sign-in link, or single sign-on), can answer the code prompt
  with the passkey instead of a code (#2247). See
  [Using a passkey at the code prompt](two-factor-auth.md#using-a-passkey-at-the-code-prompt).

Passkey sign-in **does not** divert to the TOTP prompt: every Kiln passkey is
registered and asserted with *user verification required* (screen lock /
biometric), so the single ceremony already proves possession **and**
knowledge/biometric — the same bar the password+TOTP flow reaches in two
steps. That is also why a passkey can stand in for the code at the prompt.

Having a passkey does not change who is asked for a second factor: an account
with a passkey and no authenticator app still signs in with its password
alone, and is not sent to the prompt.

Adding or removing a passkey is recorded in the site's
[security log](security-events.md) as `passkey_added` / `passkey_removed`,
with the passkey's name. Adding one also emails the account's owner, without
the name ([We email you when a second factor is added](two-factor-auth.md#we-email-you-when-a-second-factor-is-added)).

## Limits on adding passkeys

Because every passkey added emails the owner, an account can hold at most
**20** passkeys and add at most **5 in an hour** (#2247). Without the limits, a
stolen session could flood the owner's inbox and the instance's mail quota.

- At 20, the *Passkeys* section of `/editor/settings` shows "You have 20
  passkeys, the most an account can hold. Remove one to add another." in
  place of the add form. Remove one with its trash button and the form comes
  back. An account that already had more than 20 keeps them all.
- Over the hourly budget, adding one fails with "You've added several passkeys
  in a short time. Try again in N minutes." The budget counts every
  registration the browser completed and the server verified, including one
  that then failed (a passkey already registered); a registration refused by
  the 20 cap is not counted.

The cap is fixed (`KilnCMS.Accounts.Passkey.max_per_account/0`). An operator
can change the hourly budget, which is per account and shared by every node:

```elixir
# config/runtime.exs
config :kiln_cms, KilnCMS.Accounts.AccountThrottle,
  passkey_registration_budget: 5,
  passkey_registration_window: :timer.hours(1)
```

The window is in milliseconds. Both limits are checked by the `Passkey`
`:register` action itself (`Validations.PasskeyCap`,
`Changes.ThrottlePasskeyRegistration`), so any caller of the ceremony gets
them, and refuse with `KilnCMS.Accounts.Errors.PasskeyLimitReached` and
`KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled`.

## How it's built

- **Verification** is [`wax_`](https://hex.pm/packages/wax_) (`Wax.register/3`,
  `Wax.authenticate/6`) behind a seam in `KilnCMS.Accounts.WebAuthn`
  (tests stub the seam and exercise everything around it — storage,
  uniqueness, base64url plumbing, counter checks, token minting).
- **Storage** is `KilnCMS.Accounts.Passkey`: credential id (base64url,
  globally unique), COSE public key, signature counter, usage timestamps.
  Registered credentials are **discoverable** (resident keys), which is what
  makes usernameless sign-in possible.
- **Enrolment** runs over the settings LiveView socket (`PasskeyEnroll` JS
  hook): the server parks the challenge in LiveView state, the browser runs
  `navigator.credentials.create()`, and the attestation comes back as an
  event for server-side verification.
- **Sign-in** is a two-step JSON ceremony (`POST /auth/passkey/options` →
  `POST /auth/passkey/verify`, `KilnCMSWeb.PasskeyController`) driven by
  progressive-enhancement JS on `/sign-in`: `KilnCMSWeb.SignInLive` renders
  the "Use a passkey" block hidden, and the `PasskeySignIn` hook
  (`assets/js/passkeys.js`) reveals it only where `PublicKeyCredential`
  exists. Challenges park **server-side** and are
  consumed atomically — the session carries only an opaque nonce, so a
  captured request/cookie pair cannot be replayed. Both endpoints sit behind
  the same per-IP `:auth` rate limit and CSRF protection as every credential
  endpoint. On success the account's session token is minted through a
  dedicated `sign_in_with_passkey` action (system-only: policy-forbidden to
  ordinary callers, and its preparation refuses *any* actor-carrying call —
  admin bypass included — while a token-minting failure errors the ceremony
  rather than producing a token-less "success").
- **Step-up at the code prompt** (#2247) is a third ceremony, separate from
  sign-in (`POST /sign-in/verify/passkey/options` →
  `POST /sign-in/verify/passkey`, `KilnCMSWeb.TwoFactorController`, the
  `initPasskeyStepUp` script in `assets/js/passkeys.js`). Its challenge lists
  the waiting account's own credentials (`WebAuthn.step_up_challenge/1`), so
  the browser offers only those and Wax refuses any other; it is parked under
  its own session key, bound to that account, and never accepted by the
  sign-in ceremony, nor the reverse. `WebAuthn.verify_step_up/3` also checks
  the credential's owner, the user-verification flag and the counter, and
  mints **no** token: it releases the first-factor token the prompt was
  holding. `KilnCMS.Accounts.SecondFactor.check_passkey/3` charges the
  second-factor budget it shares with codes before verifying. It is offered
  only on a host where a ceremony can run (`WebAuthn.ceremony_host?/1`).
- **Limits**: `:register` refuses a 21st passkey and more than 5
  registrations an hour; see [Limits on adding passkeys](#limits-on-adding-passkeys).
- **Clone detection**: a signature counter that fails to advance (when either
  side is non-zero) rejects the assertion (`:sign_count_regression`).
- **Erasure**: GDPR anonymization (#212) deletes the account's passkeys — a
  surviving credential would let the erased account sign straight back in.
- **Invitation takeover**: accepting a site invitation with a password over an
  unconfirmed account deletes its passkeys (`Passkey` `:forget_on_takeover`,
  #2453), since whoever registered the address first may have enrolled them.
  Only the invitations system actor may call that action, never a person, a
  platform admin included; an owner or admin removes a passkey with
  `:destroy`. See
  [What taking over an account removes](account-administration.md#what-taking-over-an-account-removes).
  A registration already under way when the takeover starts cannot outlive
  it: `:register` takes the account's row first (`Changes.GuardAccountTakeover`)
  and either commits before the takeover, which then deletes it, or waits and
  is refused with `KilnCMS.Accounts.Errors.AccountTakenOver`. The settings
  page shows its usual "Couldn't verify that passkey — try again."

## Scope notes

- Passkeys are scoped to the endpoint's canonical host (`rp_id`). On
  multi-site (#336) deployments, sign-in happens on the main host as usual,
  or on a console host under it (`KILN_CONSOLE_HOST`). A passkey ceremony
  cannot run on a site's own host, so the code prompt there does not offer
  one.
- **SAML** is deliberately out of scope: enterprise IdPs (Okta, Entra,
  Google Workspace, Keycloak, Authentik, …) all speak OpenID Connect, which
  Kiln ships (docs/sso.md). A SAML-only IdP can federate through any
  OIDC-brokering proxy (e.g. Keycloak, Dex).
