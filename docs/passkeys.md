# Passkeys (WebAuthn)

Kiln supports **passkey sign-in** ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331),
final phase): a user registers their device's platform authenticator (Touch
ID, Windows Hello, a phone, a security key) and signs in without a password.

## Using it

- **Enrol** at `/editor/settings` → *Passkeys* → "Add a passkey". The browser
  prompts for the device screen lock; the credential is stored and listed
  (rename by re-adding, remove any time). Multiple passkeys per account.
- **Sign in** at `/sign-in` → "Sign in with a passkey" (the button appears
  only in WebAuthn-capable browsers). The browser offers your saved passkeys —
  no email or password typed.

Passkey sign-in **does not** divert to the TOTP prompt: every Kiln passkey is
registered and asserted with *user verification required* (screen lock /
biometric), so the single ceremony already proves possession **and**
knowledge/biometric — the same bar the password+TOTP flow reaches in two
steps.

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
  progressive-enhancement JS on `/sign-in` (the page itself is rendered by
  ash_authentication_phoenix, so the affordance is attached outside the
  LiveView root). Challenges park in the encrypted session, single-use; both
  endpoints sit behind the same per-IP `:auth` rate limit and CSRF protection
  as every credential endpoint. On success the account's session token is
  minted through a dedicated `sign_in_with_passkey` action (system-only;
  hard-forbidden to authorized callers) and the session is established
  exactly like the built-in strategies.
- **Clone detection**: a signature counter that fails to advance (when either
  side is non-zero) rejects the assertion (`:sign_count_regression`).

## Scope notes

- Passkeys are scoped to the endpoint's canonical host (`rp_id`). On
  multi-site (#336) deployments, sign-in happens on the main host as usual.
- **SAML** is deliberately out of scope: enterprise IdPs (Okta, Entra,
  Google Workspace, Keycloak, Authentik, …) all speak OpenID Connect, which
  Kiln ships (docs/sso.md). A SAML-only IdP can federate through any
  OIDC-brokering proxy (e.g. Keycloak, Dex).
