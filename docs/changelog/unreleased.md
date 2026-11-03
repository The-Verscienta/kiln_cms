# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="han-bigrams-upgrade"></a>

- **The upgrade migration rewrites `search_vector` on every content row whose
  title or `search_text` holds a Han (Chinese) character.** The migration
  (`*_install_kiln_han_grams_v1_extension`, generated from the
  `KilnCMS.Search.HanGrams` custom extension) creates four SQL functions
  (`kiln_han_runs`, `kiln_han_grams`, `kiln_han_tsquery`,
  `kiln_search_vector`), points the shared `kiln_search_vector_refresh()`
  trigger at `kiln_search_vector`, and recomputes the vector of every row
  with Han text in every table that has a `search_vector` — overlay tables
  included, so an overlay runs nothing extra and needs no `mix ash.codegen`.
  A row with no Han yields exactly the vector it had and is not touched.

  The rewrite runs inside the migration's transaction and locks the rows it
  updates: seconds on a large Chinese catalogue, nothing on a site without
  Chinese text. It is expand-safe: the release before this one reads the
  same column with queries that only name whole-run lexemes, which are still
  there. Rolling the pin back restores the old trigger body; the stored
  bigrams stay until each row is next saved, and nothing reads them.
  `KilnCMS.Migrations.add_search_vector/1` computes the new vector for a
  table added after this release.

## Added

<a id="han-bigrams"></a>

- **Chinese text is searchable at the grain it is written in (A8).**
  Postgres has no Chinese segmenter: it reads an unbroken run of ideographs
  as one word, so `本方以吴茱萸为君药` was a single lexeme that neither
  `吴茱萸` nor `茱萸` matched, and a name was findable only where punctuation
  happened to cut it out (`黄连、黄芩`) or where it began a run (the keyword
  leg's prefix match: `黄连` finds `黄连解毒汤`). Verscienta measured both
  engines on their TCM catalogue: `黄连` put Huang Lian at rank 3 among
  formulas containing 黄连, and `吴茱萸` put Wu Zhu Yu at rank 11 —
  Meilisearch did worse (rank 13).

  Two changes:

  - **Bigrams.** `search_vector` now also carries every Han run as
    overlapping character bigrams (`吴茱萸汤` → `吴茱 茱萸 萸汤`; a lone
    character stays a unigram), at the weight of the text it came from,
    after the existing lexemes so no other lexeme's position moves. A new
    leg of `KilnCMS.Search.hybrid/3`, `:han` (`:search_han`), matches the
    query's runs as bigram phrases (`'吴茱' <-> '茱萸'`) at the keyword leg's
    weight, ranked by `ts_rank` over them. It runs only for a query holding
    a Han character; `hit_legs/1` reports it as `:han`, and like `:keyword`
    it vouches for a hit against the semantic floor.
  - **Exactness.** A Han query now also *names* a record whose title, or
    whose `names_record` field, has exactly the query's Han text — the same
    runs, in order, whatever else surrounds them. `黄连` names "Huang Lian
    黄连" and a name field holding `黄连 (huáng lián)`, and not
    `黄连解毒汤`, which merely contains it. Such a record is a `:title` or
    `:alias` hit, at the title leg's weight, so it ranks above records whose
    names contain the query; `ts_rank` cannot say this, since every one of
    them holds the query's lexeme. A query without Han runs the title and
    alias legs exactly as before.

  Non-Chinese search is unchanged: a text without Han stores the same vector,
  and a query without Han runs no new SQL (`RankingStabilityTest` is
  untouched). A Chinese name kept in a custom field that is `searchable` but
  not flagged `names_record` is body text to search, as before: flag it to
  have the query name the record. Simplified and traditional forms (`黄连` /
  `黃連`) are still different text.


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
