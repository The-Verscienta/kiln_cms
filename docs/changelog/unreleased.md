# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="search-synonyms"></a>

- **Search synonyms and aliases, per site (proposal A7).** A site whose
  readers search for "reishi" when its content says "Ling Zhi" had to fix it
  in the consumer: Verscienta's own synonym table was worth +0.058 MRR over
  the backend, and Kiln's own surfaces — `/api/ask`, the editor palette, the
  public `/search` page — got none of it. `KilnCMS.CMS.SearchSynonym` holds the
  rules: a `group` of equivalent terms (`reishi ⇄ ling zhi ⇄ ganoderma`) or a
  `one_way` rule (`tcm → traditional chinese medicine`), multi-word terms
  matched as phrases at word boundaries. `Search.hybrid/3` reads them
  (`KilnCMS.Search.Synonyms`, cached per site and busted on every write) and
  runs each alternate wording of the query through the keyword, title and
  alias legs at half the weight of the same leg on the user's own words — the
  new `synonym` leg — so a record the reader named outranks one a rule named
  for them. The semantic legs do not re-run: the query's one embedding already
  carries its meaning. `global/2` reads the rules once per sweep, and
  `/api/search` reports the alternates it searched as `also_searched`. Editors
  manage rules at `/editor/search-synonyms` (with a "try a query" box); only an
  admin deletes one. A rule write purges the site's CDN key, since it changes
  what a publicly cached `/api/search` URL answers. `/mcp` gains a
  `search_content` tool (`KilnCMS.CMS.ContentSearch`) — the ranked hybrid
  search under the key's own read policies, which MCP clients had no way to
  reach before. The index-time half of the proposal ("index this field's
  values as names") already exists as `names_record` on a field definition
  (`KilnCMS.CMS.NameFields`); a synonym's alternate runs the alias leg too, so
  the two compose.

<a id="search-ranking-fixture"></a>

- **An adversarial ranking fixture gates search ranking in CI (A10).** The
  #2175 lone-record defect was found by a downstream site comparing
  `/api/search` with Meilisearch, not by Kiln's CI.
  `test/kiln_cms/search/ranking_fixture_test.exs` now seeds a synthetic corpus
  and scores it with `KilnCMS.Search.Eval` against
  `test/support/fixtures/search_ranking/adversarial.json`. The corpus covers a
  one-record section next to a large one, an exact phrase against its words
  scattered through a ~10,000-word document, a CJK name that another record's
  name contains, a typo and a junk query, a half-typed last word ("huang l")
  and a joined name ("huangqi"). The file's gates fail the test. Ranked per
  section again, `cross_section` recall@25 drops from 1.000 to 0.960 and the
  test fails. The classes the engine does not pass yet, `cjk_name` (r@1 0.5)
  and `joined_name` (r@1 0.0), are recorded as baselines. A run that moves one
  prints a notice rather than failing. Golden sets accept the new class names
  (`cross_section`, `exact_phrase`, `prefix`, `joined_name`, `cjk_name`), so a
  deployment's own set can use them.

<a id="search-explain"></a>

- **Search explain mode: why a hit ranked where it did (#2177).** A site
  comparing Kiln's `/api/search` against Meilisearch could see a hit's `score`
  and `legs`, but nothing like `_rankingScoreDetails`. It had to guess "matched
  some of the words" from the `keyword_any` leg's name. `GET
  /api/search?explain=1`, and `explain: true` on `KilnCMS.Search.hybrid/3` and
  `global/2`, now attach an `explain` object to every content hit
  (`KilnCMS.Search.hit_explain/1`). For each leg it gives the rank fusion used,
  which in a `global/2` sweep is the rank over every section. It also gives
  that rank's contribution to `score` and the raw number the leg ranked by:
  `ts_rank`, cosine distance or trigram similarity. Alongside these are the
  query's terms, which ones the hit's `search_vector` contains, and `coverage`
  (matched / terms). A consumer can sort by coverage and then score without
  re-deriving coverage from snippets. The leg numbers come from the keys
  fusion already collected. The term match adds one query per section, over
  the kept hits only, and the fuzzy leg loads its similarity only under
  explain. Explain is off by default, so the default payload is unchanged. An
  explained response is `private, no-store` with no `ETag`, so it never
  becomes the cached answer for a search URL.

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

<a id="search-warmup-and-budget"></a>

- **Search stays up across a deploy, and a sweep answers within a budget (#2166).**
  Around the 2026-11-02 deploy one production search took 27.6 s. The
  embedding and reranker servings start after the endpoint, so a fresh node
  answered `/live` with 200, the platform swapped traffic onto it, and its
  first searches waited for the servings to compile. Three changes. First,
  `KilnCMS.Search.Warmup` runs one search through the servings after boot,
  and `/live`, `/up` and `/ready` answer 503 until it has (`/ready` says
  `"search": "warming"`). The latch only ever opens, so `/live` stays a
  startup gate, not a restart trigger (#816). It gives up after 90 s, inside
  the image healthcheck's window, and an install with semantic search and
  reranking off opens it at once. Second, `global/2` runs within
  `query_budget` (1500 ms, `:infinity` for none). The query embedding gets
  half of it, a section still running at the deadline is fused from the legs
  it finished, and a reranker that misses it leaves fused order. Work the
  budget gives up on still runs in its `Nx.Serving`, so budgeted embeddings
  are capped at one batch in flight and reranks at `rerank_slots` (4). Past
  that a search skips the leg instead of queueing behind abandoned work. A
  local restart under four search clients with reranking on showed the cap
  is needed: without it, client latency drifted to 10 s while Kiln's own
  timing read 1.5 s. `global_report/2` returns what was cut, and
  `GET /api/search` sends it as `partial` and `incomplete`, with
  `cache-control: no-store` on a cut answer. Third, every search response
  carries `Server-Timing`, one metric per leg. The Bumblebee embedder now
  turns a serving's exit (not running yet, timed out) into an error, so the
  search keeps its keyword legs rather than answering 500. Measurements are
  in `docs/benchmarks.md`.

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
