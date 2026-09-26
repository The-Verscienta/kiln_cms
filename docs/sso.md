# Enterprise SSO (OpenID Connect)

Sign in to the Kiln console through any OpenID Connect provider — Entra ID,
Google Workspace, Okta, Keycloak, Authentik, … — via AshAuthentication's OIDC
strategy (#331). One provider per install (multi-IdP is a follow-on).

## Enabling it

SSO is **compile-gated and off by default** (like invite-only registration):
the lean install compiles no strategy, shows no SSO button, and exposes no
OAuth routes.

1. Set `config :kiln_cms, :sso_oidc, enabled: true` (config.exs or a deploy
   overlay) and rebuild.
2. Provide at runtime (read in `runtime.exs`):

   | Env | Meaning |
   | --- | --- |
   | `OIDC_CLIENT_ID` | The client id registered at the IdP |
   | `OIDC_CLIENT_SECRET` | Its secret (`client_secret_basic`) |
   | `OIDC_ISSUER` | Provider base URL — discovery at `/.well-known/openid-configuration` |
   | `OIDC_REDIRECT_URI` | This site's callback base, e.g. `https://cms.example.com/auth` |

3. Register the callback URL `<OIDC_REDIRECT_URI>/user/sso/callback` at the IdP.

The sign-in page then offers "Sign in with Sso" alongside password/magic-link.

## Security posture

- **Stable identity linking.** The provider's `iss`/`sub` is persisted in
  `KilnCMS.Accounts.UserIdentity` — after the first link, sign-in matches the
  stored identity, not the email claim, so an email change at the IdP can't
  re-target an account.
- **Verified email only for first-time linking** (`trust_email_verified?`):
  attaching an SSO identity to an *existing* local account requires the IdP's
  `email_verified` claim (`true`, or the string `"true"` from string-typed
  providers) — point Kiln only at a provider that reliably asserts email
  ownership. An unverified match is rejected outright, and our
  `RegisterWithSso` change independently refuses any unverified claim.
  Providers that **omit** the claim entirely (Entra ID does by default) are
  rejected unless you explicitly set
  `config :kiln_cms, :sso_oidc, assume_email_verified: true` — only do this
  for an IdP that exclusively asserts owned addresses.
- **Invite-only + identity linking:** with registration disabled, SSO admits
  accounts known by their **linked provider identity or** their email — an
  identity-linked employee whose corporate email changes stays signed in;
  unknown identities are refused.
- **Unconfirmed password accounts:** an account that self-registered with a
  password but never confirmed its email cannot be silently taken over via
  SSO — the sign-in is refused with guidance to confirm or reset first (the
  library's hijack prevention).
- **Linking, not privilege.** An existing account signs in as-is (role,
  audiences, display name untouched). A new user lands as `:viewer` with no
  audiences — identical to password self-registration; an admin grants access
  afterwards.
- **Invite-only respected.** With `:registration_enabled` false, SSO signs in
  existing accounts only; unknown emails are refused, not auto-provisioned.
- **No password backdoor.** SSO-provisioned accounts store an unguessable
  random hash; password sign-in works only after an explicit password reset.
- **2FA still applies.** SSO completes through the same
  `AuthController.success/4`, so a TOTP-enrolled account still hits the
  second-factor gate (docs/two-factor-auth.md).
- SSO users are auto-confirmed (the IdP verified the email) — no second
  confirmation loop.

## Per-site providers

On a deployment with several sites, a site admin can give their site its own
OpenID Connect provider at **Configure → Integrations → Single sign-on**
(`/editor/site-sso`, #1561). It sits *beside* the operator's provider above —
which is unchanged and still offered where it was — and needs no rebuild and no
environment variables.

1. Register a client at your provider with the callback URL the page shows:
   the site's own address plus `/auth/site-sso/callback`.
2. Enter the provider's **issuer URL** (`https://` only; discovery is at
   `<issuer>/.well-known/openid-configuration`, and its `issuer` must match
   exactly), the **client ID** and the **client secret**. The secret is stored
   encrypted and never shown again; leave it blank to keep it.
3. Add each **email domain** the provider may sign in, publish the TXT record
   the page shows — `_kiln-sso.<domain>` with the value
   `kiln-sso-verification=<token>` — and press **Verify**.

The sign-in page on that site then shows a "Sign in with …" button. Until a
domain is verified it shows nothing, because the provider could admit no one.

### What a site's provider may do

Accounts belong to the whole deployment, so a provider a site admin chose is
not trusted for everything it asserts:

- **Only verified domains.** An address is admitted only if its domain is one
  the site verified, *exactly* (`example.com` does not cover
  `mail.example.com`), and the provider says `email_verified: true`. The TXT
  record is looked up again on **every** sign-in — keep it in place; taking it
  down stops the provider signing anyone in.
- **Never an account with access elsewhere.** The provider cannot sign in a
  platform admin, anyone with a membership on another site (at any tier), or a
  membership-less account whose global editor/admin role or legacy audiences
  reach beyond this site. Those people sign in with a password, an email link,
  a passkey, or the operator's provider instead.
- **No pre-registered accounts.** An account whose address was never confirmed
  is refused rather than handed to the provider's user.
- **New people** get an account (`:viewer`) and a `:viewer` membership on this
  site only — unless open registration is off, in which case only existing
  accounts can sign in.
- **A second factor still applies.**
- **`RS256` ID tokens only**, from the keys at the provider's `jwks_uri`. Every
  request Kiln makes to the provider goes through the same SSRF guard as
  webhooks: `https://`, no private or metadata addresses, no redirects.

If the settings can't be read, or the client secret can't be decrypted (after
a `SECRET_KEY_BASE` rotation — see [secrets-rotation.md](secrets-rotation.md)),
the sign-in page says the site's single sign-on is unavailable. It never sends
people to the operator's provider instead.

Not yet: turning password sign-in off for a site, SAML, and more than one
provider per site.

## The rest of #331

- **SAML** — needs a dependency decision (`esaml`/`samly`); OIDC covers most
  modern IdPs (including Entra/Okta/Google) so SAML is deferred until a
  concrete need.
- **Passkeys / WebAuthn** — a separate, browser-API-heavy effort; deferred.
- **Multiple simultaneous IdPs** — the operator's strategy is singular
  (`:sso`); each site can add one of its own
  ([above](#per-site-providers)).
