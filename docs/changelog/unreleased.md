# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="field-role-weights-upgrade"></a>

- **Run the re-fire sweep after deploying; overlays first run `mix ash.codegen`
  (#2175, A3).** Every content table gains a nullable `search_weighted` column:
  `pages`, `posts` and `entries` in core, and each overlay content table through
  the overlay's own codegen. An overlay's reads fail until that column exists.
  No overlay needs a trigger migration, because the one shared
  `kiln_search_vector_refresh()` function looks for the column on each table it
  runs for. The column's values are computed in Elixir, so the migration cannot
  backfill them. Until a row is re-saved or re-fired it keeps the old vector, with
  the title at `A` and all its other text at `B`, and a corpus that is half old
  and half new ranks unevenly. `mix kiln.refire_all` fills every published
  document (`/app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"` on a release).
  A draft is filled on its next save.

## Changed

<a id="field-role-weights"></a>

- **Keyword search weights a record's text by role and scores phrase proximity
  (#2175, A3).** `search_vector` used to hold the title at `A` and everything
  else at `B`, and `ts_rank` saturated near 1 on any long document that repeated
  the query's words. A monograph that scattered "clears", "heat", "dries" and
  "dampness" therefore outranked the record whose own field says "clears heat
  and dries dampness" (0.97 against 0.95).

  The vector is now built from `search_weighted`, which
  `KilnCMS.CMS.Changes.SetSearchText` writes beside `search_text`:

  - `A`: the title, and every `names_record` field, searchable or not;
  - `B`: the summary fields (`seo_title`, `seo_description`, `seo_keywords`,
    `excerpt`) and the first 48 words of the searchable custom fields, in
    extractor order;
  - `C`: the rest of those fields;
  - `D`: the body.

  `search_rank` and `search_rank_any` use `ts_rank_cd`. A query of two or more
  words adds the score of its phrase (`phraseto_tsquery`, last word as a
  prefix). Cover density alone still let repetition win inside one field
  ("Intensely bitter and cold." scored 0.20 against 0.28 for a field that
  repeats "bitter" and "cold" apart); the phrase score settles it. Every content
  table ranks with the same expression over the same weights, so `global/2` can
  still compare keyword ranks across sections. A field definition reports the
  weight its text gets as the `search_weight` calculation (`"A"`, `"B"` or nil).

  The trigger keeps the old vector for a row whose `search_weighted` is nil. It
  does the same when an update changes `title` or `search_text` and leaves
  `search_weighted` alone, which is what the previous release writes during a
  rolling deploy; the stale buckets are cleared. `RankingStabilityTest` moved on
  one query. On "pad thai tom yum", Pad Thai and Tom Yum, whose titles carry the
  words, now lead the any-term leg over Thai Street Food, which names all four
  in its body. Fused scores moved by one or two reciprocal ranks in that leg, and
  no result changed position.

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
