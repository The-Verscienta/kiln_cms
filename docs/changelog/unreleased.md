# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="term-evidence-gate"></a>

- **Hybrid search tells a typo from junk by the query's words, not by a score
  (A6).** A downstream deployment benchmarked `/api/search` against
  Meilisearch on a held-out set and found no score threshold, in either
  engine, that separated the two: Meilisearch's floor rejected all the junk
  and every typo with it, and Kiln passed 17–19 of 40 junk queries while
  missing typos. Both kinds arrive with an empty keyword leg and are answered
  by the legs that always answer — the semantic neighbours, the any-term
  relaxation's one shared word, the trigram guesses.

  `KilnCMS.Search.term_gate/0` (on by default) now reads, for a section whose
  keyword leg is empty, each query term against the section's vocabulary:
  its `search_vector`, its records' names (title, `names_record` fields, tag
  names), and words within one edit (two from eight letters) of those names,
  through the new `fuzzystrmatch` extension. When fewer than 60% of the terms
  have any such evidence (50% when one term is a record's name outright), the
  query is junk, and only the keyword, title and alias legs may answer it —
  in practice nothing comes back. A term one edit from a name is a typo, and
  the fuzzy leg also runs on the corrected query: "gui zi tang" finds Gui Zhi
  Tang, "saffon" now finds Saffron Rice, which trigrams alone never reached.

  What it costs is the synonym-only query — a word the corpus never uses that
  the semantic leg would have answered ("licorice" for a corpus that says
  "glycyrrhiza"). That now returns nothing. `SEARCH_TERM_GATE=false` (or
  `term_gate: false`) turns the gate off; `SEARCH_TERM_GATE_MIN_SHARE` or
  `term_gate: [min_share: …]` retunes it. `KilnCMS.Search.term_evidence/3`
  shows the verdict for a query. The migration adds the extension only.

## Fixed

<a id="global-search-ranks"></a>

- **`global/2` ranks its legs across sections, so fused scores compare (#2175).**
  Each section used to fuse over its own records, so `weight / (k + rank)` used
  a rank within the section. A section with one published record put it at rank
  1 in every leg that returned it, and on `/api/search?q=heat interior` the only
  post (0.0410 = 2.5 / 61) outscored records that matched both terms. A sweep
  now collects every requested content section's legs first. It then ranks the
  keyword, any-term, semantic, block and tag legs over all of them at once, by
  `ts_rank` or cosine distance, with ties sharing a rank, and fuses each section
  at those ranks. The title, alias and fuzzy legs still rank per section. A
  title or alias hit is a record the query names outright, and the fuzzy leg is
  a per-section fallback. A direct `hybrid/3` call is unchanged. Scores from
  `global/2` move, and so does the order within a section where semantic-only
  neighbours were spaced differently. `KilnCMS.Search.RankingStabilityTest` is
  re-pinned for this reason.

## Security

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
