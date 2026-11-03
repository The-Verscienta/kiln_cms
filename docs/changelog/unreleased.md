# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



<a id="html-tls-jsv-advisories"></a>

- **phoenix_html 4.4.0, ssl_verify_fun 1.1.9 and jsv 0.26.2 fix three of
  the advisories published 2026-10-30 and 2026-10-31; the fourth (assent,
  Sign in with Apple only) is acknowledged as not reachable.** phoenix_html 4.3.0
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
  The fourth, assent 0.2.13 (EEF-CVE-2026-117656, critical), merged the
  Sign in with Apple callback's unsigned `user` parameter over the verified
  ID token's claims. Its only fix is assent 0.3.2, which ash_authentication
  4.x cannot take (it pins assent below 0.3.0; only the 5.0 release
  candidates lift that). Kiln never configures the Apple strategy: SSO is
  the generic OIDC strategy, which reads no `user` parameter. The advisory
  is listed in `mix.exs`'s `hex: [ignore_advisories: ...]` with that reason,
  and comes out when ash_authentication allows assent 0.3.
  ([#PRNUM](https://github.com/The-Verscienta/kiln_cms/pull/PRNUM))
