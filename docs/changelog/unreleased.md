# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-site-can-offer-its-own-single-sign-on-provider"></a>

- **A site can offer its own single sign-on provider.** A site admin sets an
  OpenID Connect issuer, client ID and client secret at `/editor/site-sso`, and
  the site's sign-in page offers "Sign in with …" beside the password form. The
  operator's `OIDC_*` provider is unchanged. Accounts belong to the whole
  deployment, so the site's provider is honoured only for addresses in email
  domains the site verified with a DNS TXT record (`_kiln-sso.<domain>`), looked
  up again on every sign-in, and never for an account with access on another
  site or across the deployment — a platform admin, another site's member, or a
  membership-less global editor. Those people sign in the other ways. The flow is
  deliberately not an AshAuthentication strategy: a per-site strategy would
  share the operator's identity namespace, so a site's provider asserting a
  `sub` the operator's had already linked would sign in as that account. It is
  Assent's OIDC callback (state, nonce, PKCE, `RS256` only) behind two routes,
  with every provider request through `SafeFetch`. The client secret is
  vault-encrypted and write-only; if it can't be decrypted, the site's SSO says
  it is unavailable rather than falling back to the operator's provider. Turning
  password sign-in off per site, SAML, and several providers per site are not
  in this change.

## Security

<a id="two-hex-advisories-closed-and-the-working-copy-survives-the-ash-fix"></a>

- **Two Hex advisories closed, and the working copy survives the `ash` fix.**
  `ash` 3.33.6 carried **EEF-CVE-2026-93477** (MEDIUM — private action arguments
  could be set by user input on the bulk destroy and bulk update paths) and
  `lazy_html` 0.1.12 carried **EEF-CVE-2026-92106** (LOW — SVG and MathML
  `style` and `script` text serialized unescaped, allowing mutation XSS). Both
  are closed by `ash` 3.33.11 and `lazy_html` 0.1.13. `mix deps.audit` reported
  neither — the mirego mirror was behind, as it was on 2026-09-18 — and
  `mix hex.audit` is what caught them, which is why both audits run in CI.
  The `ash` release also ships *"properly compare unions w/ `Ash.Type.equal?`"*,
  and that broke the working copy on the way in. `ContentEditorLive` seeds the
  autosave form on a struct whose `working_blocks` already hold the tree the
  copy is measured against, so the block sub-forms bind to existing blocks by
  index rather than creating new ones. A title-only save therefore submits that
  same tree, and once Ash compared two equal union trees correctly the write
  became a no-op: the copy was stamped with an empty body, and "Publish changes"
  would then have published nothing. It looked correct in memory, because the
  record Ash hands back reflects the seeded struct rather than the row. The
  seeded tree is now for sub-form binding only — the changeset diffs
  `working_blocks` against what the row actually holds, so an unchanged body on
  a document with no working copy yet is a real change again. Where the row
  already holds that tree the write is still elided, which is correct: the
  column already says what the save means to say. Worth recording that
  `force_change_attribute/3` is **not** a way out of this — it bypasses the
  acceptance checks, not the equal-to-data elision.

