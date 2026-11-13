# Passkeys (WebAuthn)

Kiln supports **passkey sign-in** ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331),
final phase): a user registers their device's platform authenticator (Touch
ID, Windows Hello, a phone, a security key) and signs in without a password.

## Using it

- **Enroll** at `/editor/settings` → *Passkeys*: optionally fill in "Name this
  passkey" (for example "MacBook Touch ID"), then click "Add a passkey". The
  line under the form says so in advance: "Your browser will prompt you to
  confirm with this device's screen lock. We'll email you each time a passkey
  is added to your account." The browser prompts for the device screen lock
  while the page reads "Waiting for your device…". The credential is then listed with its name, the date it was
  added and the date it was last used. A passkey can't be renamed: remove it
  with the trash button and add it again. Multiple passkeys per account.
  Settings is for editors and admins; anyone signed in, readers included,
  adds and removes passkeys at `/account/two-factor` instead
  ([Remove a passkey](#remove-a-passkey)).
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

Having a passkey does not, by itself, change who is asked for a second
factor: an account with a passkey and no authenticator app signs in with its
password alone, and is not sent to the prompt. The exception is a site that
[requires two-step sign-in](two-factor-auth.md#requiring-two-step-sign-in-on-a-site).
A passkey satisfies that requirement, so a passkey-only account is never held
for setup; but once its deadline has passed, its password alone no longer
signs it in on that site:

- on the main or console host, the password (or a magic link, or single
  sign-on) stops at `/sign-in/verify`, which says "Confirm it's you with your
  passkey." and offers **Use a passkey**;
- on a site's own host, where the passkey cannot run, the password is refused
  with "Your account's second factor is a passkey, which works at (main host).
  Sign in there, or add an authenticator app.";
- a session that signed in with the password before the deadline, or that a
  "Remember me" cookie restores, goes through the same prompt;
- the account's headless sign-in and its JWTs are refused (`403`
  `second_factor_required`, `meta.reason: "passkey_only"` at sign-in), since a
  passkey cannot be used outside a browser.

A passkey has no recovery codes. On such a site, add an authenticator app as
well, so losing the device does not lock the account out
([Passkey-only accounts](two-factor-auth.md#passkey-only-accounts)). Passkeys
can also be added at `/account/two-factor`, the setup page a site's
requirement sends people to; there, a session that signed in with only a
password may first have to confirm a code sent by email.

While a site requires a second factor of the account, its last passkey can't
be removed if it has no authenticator app: on both pages the trash button is
replaced by a note saying so.

### Remove a passkey

Anyone signed in can remove their own passkeys, readers included. Editors and
admins can use either page below; a reader uses `/account/two-factor`, since
`/editor/settings` is editors only.

1. Open the page:
   - **Editors and admins:** `/editor/settings`, the **Passkeys** section.
   - **Anyone:** `/account/two-factor`, the **Passkey** section. The page is
     served on the main host (`PHX_HOST`) and on console hosts; a site's own
     address redirects to the main host's page, where you sign in again.

   Each passkey is listed with its name, "Added (date)" and, once it has been
   used, "last used (date)".
2. Click the trash button (labeled "Remove passkey" for screen readers) on the
   row of the passkey to remove.
3. Confirm the browser's prompt, "Remove this passkey? You can no longer sign
   in with it."

The row disappears and the page says "Passkey removed." On
`/account/two-factor`, the count above the list goes down, and at the limit
the add form comes back (see [Limits on adding passkeys](#limits-on-adding-passkeys)).

The list and the trash buttons are on `/account/two-factor` on every host
that serves the page, since removing a passkey needs no ceremony. On a host
where a passkey can't be registered (a console host where the ceremony can't
run), the section shows the list without the add form, the limit note or the
"We'll email you each time a passkey is added to your account." line. With
no passkeys there, the section is not shown at all.

Removing a passkey asks for no emailed code, even where adding one would: the
code gates adding a factor, not removing one. Removal does not email the
owner; only an added factor is mailed. It is recorded in the security log
like any other removal (below).

What can go wrong:

- **No trash button, and "A site you use requires two-step sign-in, so you
  can't remove your last second factor. Add another one first."** This is
  your only second factor and a site you belong to requires one. Add an
  authenticator app or another passkey first, then remove this one.
- **No passkey list on `/account/two-factor`, and "This is a shared demo
  account, so its password and sign-in methods can't be changed."** You are
  signed in to the instance's shared demo account, whose passkeys can't be
  removed or added ([Demo mode](demo-mode.md)).
- **"Couldn't remove that passkey."** The passkey no longer exists (removed
  in another tab, for example) or isn't yours. Reload the page to see the
  current list.

Adding or removing a passkey is recorded in the site's
[security log](security-events.md) as `passkey_added` / `passkey_removed`,
with the passkey's name. Adding one also emails the account's owner, without
the name ([We email you when a second factor is added](two-factor-auth.md#we-email-you-when-a-second-factor-is-added)).

## Limits on adding passkeys

Because every passkey added emails the owner, an account can hold at most
**20** passkeys and add at most **5 in an hour** (#2247). Without the limits, a
stolen session could flood the owner's inbox and the instance's mail quota.

- At 20, the *Passkeys* section of `/editor/settings` and the *Passkey*
  section of `/account/two-factor` show "You have 20 passkeys, the most an
  account can hold. Remove one to add another." in place of the add form.
  Remove one with its trash button on the same page and the form comes back.
  (On `/account/two-factor`, the note and the form appear only on a host where
  a passkey can be added.) An account that already had more than 20 keeps
  them all.
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
- **Enrolment** runs over the LiveView socket of `/editor/settings` or
  `/account/two-factor` (`PasskeyEnroll` JS hook): the server parks the challenge in LiveView state, the browser runs
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
  `:destroy`. Both pages remove through `KilnCMSWeb.TotpEnrolment.remove_passkey/3`,
  which passes the page's security context so the `passkey_removed` event
  is recorded for the site. See
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
