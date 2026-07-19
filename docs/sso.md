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

## The rest of #331

- **SAML** — needs a dependency decision (`esaml`/`samly`); OIDC covers most
  modern IdPs (including Entra/Okta/Google) so SAML is deferred until a
  concrete need.
- **Passkeys / WebAuthn** — a separate, browser-API-heavy effort; deferred.
- **Multiple simultaneous IdPs** — the strategy is singular (`:sso`) today;
  lifting to N providers is config plumbing when needed.
