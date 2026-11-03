# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



<a id="html-tls-jsv-advisories"></a>

- **phoenix_html 4.4.0, ssl_verify_fun 1.1.9 and jsv 0.26.2 fix three of
  the advisories published 2026-10-30 and 2026-10-31.** phoenix_html 4.3.0
  passed attribute *names* to `attributes_escape/1` unvalidated, so a name
  built from untrusted input could inject further attributes
  (EEF-CVE-2026-117645, medium). Kiln builds attribute names from its own
  code, not from content. ssl_verify_fun 1.1.7 let a partial-label wildcard
  certificate (`f*.example.com`) match a hostname across a label boundary
  (EEF-CVE-2026-117666, critical). It reaches Kiln through
  `tls_certificate_check`, which the OpenTelemetry exporter uses for its
  TLS connection, and as an optional dependency of assent. Kiln's own HTTP
  calls go through Req and Mint, which verify hostnames without it. jsv
  0.23.0 treated an exhausted regex budget as a non-match, so a
  `patternProperties` or `pattern` check could pass input it should refuse
  (EEF-CVE-2026-117680, low). Only `req_llm` uses jsv. jsv 0.26.2 also
  moves its `texture` dependency from 1.2.1 to 2.0.0.
  `examples/phoenix_showcase` gets phoenix_html 4.4.0 in its own lock.
  ([#2174](https://github.com/The-Verscienta/kiln_cms/pull/2174))

<a id="ash-authentication-5-assent"></a>

- **ash_authentication 5.0.0-rc.15 and ash_authentication_phoenix 3.0.0-rc.11
  bring assent 0.3.2, fixing EEF-CVE-2026-117656.** In assent 0.2.13 an
  unverified `user` parameter on a Sign in with Apple callback could override
  the claims of the verified ID token (critical). The only fix is assent 0.3.2,
  and every ash_authentication 4.x release requires assent below 0.3.0, so this
  moves both auth libraries to their 5.0 and 3.0 release candidates. Kiln was
  not exposed: the fix is confined to `Assent.Strategy.Apple`, and Kiln's two
  sign-on paths use the generic OIDC strategy (the `:sso` strategy and a site's
  own identity provider). It needs no migration and no configuration.

  Two things a deployment can notice. Signing in on the sign-in page now hands
  the short-lived sign-in token to the server in a POST body, never in a
  redirect URL, so
  it no longer appears in proxy, CDN or browser-history logs (3.0 made the
  POST hand-off the only one). And a reset link is now single-use by the
  library's own check, which locks the token's row and refuses one already
  revoked; Kiln's sweep of the account's tokens on a reset spares that one
  token so the library can make it (`RevokeAllTokens`, `spare: :reset_token`).

  Inside Kiln, the magic-link request is now a generic action, as 5.0
  requires, and its per-address budget wraps the run the way the password-reset
  request's
  already did (`KilnCMS.Accounts.ThrottledMagicLinkRequest`). 5.0 also makes a
  failing auth-mail sender fail its action; Kiln's senders enqueue through
  `KilnCMS.Mail.enqueue!/2`, which answers `:ok` or raises, so their behaviour
  is unchanged. Kiln does not turn on 5.0's new identity-keyed brute-force
  protection, which would add an audit-log table; its own per-account and
  per-address throttles stay as they were.
  ([#2185](https://github.com/The-Verscienta/kiln_cms/pull/2185))
