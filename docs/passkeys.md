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

Passkey sign-in **does not** divert to the TOTP prompt: every Kiln passkey is
registered and asserted with *user verification required* (screen lock /
biometric), so the single ceremony already proves possession **and**
knowledge/biometric — the same bar the password+TOTP flow reaches in two
steps.

Adding or removing a passkey is recorded in the site's
[security log](security-events.md) as `passkey_added` / `passkey_removed`,
with the passkey's name.

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
  multi-site (#336) deployments, sign-in happens on the main host as usual.
- **SAML** is deliberately out of scope: enterprise IdPs (Okta, Entra,
  Google Workspace, Keycloak, Authentik, …) all speak OpenID Connect, which
  Kiln ships (docs/sso.md). A SAML-only IdP can federate through any
  OIDC-brokering proxy (e.g. Keycloak, Dex).
