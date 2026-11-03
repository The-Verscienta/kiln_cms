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
  Explain mode (#2177) reports the keyword legs' raw score as `measure:
  "ts_rank_cd"` accordingly.

  The trigger keeps the old vector for a row whose `search_weighted` is nil. It
  does the same when an update changes `title` or `search_text` and leaves
  `search_weighted` alone, which is what the previous release writes during a
  rolling deploy; the stale buckets are cleared. `RankingStabilityTest` moved on
  one query. On "pad thai tom yum", Pad Thai and Tom Yum, whose titles carry the
  words, now lead the any-term leg over Thai Street Food, which names all four
  in its body. Fused scores moved by one or two reciprocal ranks in that leg, and
  no result changed position.

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
  "glycyrrhiza"). That now returns nothing, unless a site synonym rule
  rewords it: a `:synonym` hit vouches for itself under a junk verdict, as a
  keyword, title or alias hit does. `SEARCH_TERM_GATE=false` (or
  `term_gate: false`) turns the gate off; `SEARCH_TERM_GATE_MIN_SHARE` or
  `term_gate: [min_share: …]` retunes it. `KilnCMS.Search.term_evidence/3`
  shows the verdict for a query. The migration adds the extension only.


<a id="wedge-positioning"></a>

- **Kiln says what it is for, first (#1930).** The README's first sentence,
  the stock home page served at `/` until a site publishes its own, and the
  kilncms.dev `/docs` index now lead with the wedge from
  [path-forward.md](../path-forward.md): content that has to be right,
  everywhere in seconds, provably. This is release 1.8 of that plan, and it
  changes no code path.

  - **One entry point.** The new guide
    [Right, everywhere, provably](../right-everywhere-provably.md) puts the six
    delivery and governance guides in reading order (webhooks, resilient
    delivery, static export, point in time, provenance, governance dashboard)
    and adds what shipped between them in 1.3 to 1.7: `data.affected`, the
    retraction guarantee, propagation records and the first p95, the change
    feed's server side, the "what readers saw" trail, headless draft mode and
    provenance on by default. It ends with what is not built yet. The six
    guides stay where they are. It sits in the docs sidebar under Getting
    started, and `scripts/publish_docs.exs` puts a "Start here" pointer to it
    above the section list on kilncms.dev's `/docs`.
  - **README.** The opening paragraph states the wedge; a short "Run it" block
    (three commands and the dev sign-in) comes before the maturity notes; and
    "Status & maturity" opens with what each 1.x minor has shipped toward the
    wedge and what has not. The maturity content itself is unchanged.
  - **Home page hero.** Editors in the 2026-10-29 usability walkthrough found
    it heavy on jargon. It now says the same thing in plain words, with a
    "How it works" link to the guide. The strings are new, so es and fr carry
    new translations.
  - **`docs/cms-comparison.md`** gains a wedge table for Sanity, Contentful,
    Payload and Directus (live delivery, point in time, signed content,
    governance), each claim linked to the vendor's own docs and checked on
    2026-11-03. "Not documented" is written where nothing was found.

## Fixed

<a id="global-search-ranks"></a>

- **`global/2` ranks its legs across sections, so fused scores compare (#2175).**
  Each section used to fuse over its own records, so `weight / (k + rank)` used
  a rank within the section. A section with one published record put it at rank
  1 in every leg that returned it, and on `/api/search?q=heat interior` the only
  post (0.0410 = 2.5 / 61) outscored records that matched both terms. A sweep
  now collects every requested content section's legs first. It then ranks the
  keyword, any-term, semantic, block, tag and fuzzy legs over all of them at
  once, by `ts_rank`, cosine distance or trigram similarity, and fuses each
  section at those ranks. Records that tie on that measure keep their leg's own
  order within a section, and share a rank only with another section's record
  at the same position. That matters most for the tag leg: every document
  carrying the matched tag has the tag's distance, and ranked by distance alone
  they would all have taken rank 1. A sweep of one section therefore ranks
  exactly as `hybrid/3` does. The title and alias legs still rank per section:
  a title or alias hit is a record the query names outright. Scores from
  `global/2` move, and so does the order within a section where semantic-only
  neighbours were spaced differently. `KilnCMS.Search.RankingStabilityTest` is
  re-pinned for this reason. A sweep that reranks each section under
  `rerank_mode: {:rrf, k}` still scores per section, since the blend is built
  from ranks within the section; `hit_score/1` says so. Only a sweep, or
  `explain: true`, now loads the `ts_rank` and trigram similarity its legs rank
  by; a plain `hybrid/3` call skips that per-row cost.

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

<a id="ash-authentication-rc16"></a>

- **ash_authentication 5.0.0-rc.16 fixes EEF-CVE-2026-119215 and
  EEF-CVE-2026-118505.** The first (high) let a signed-in user install their own
  authenticator secret on another account through the TOTP strategy's `setup`
  and `confirm_setup` actions, where an application exposed them on a record the
  caller picks. The second (medium) left `brute_force_strategy` applying no limit
  to a sign-in or request action the resource defines itself. Kiln was exposed
  to neither: its two-factor enrolment is its own (`:setup_totp`,
  `:confirm_totp` on the signed-in user's record), not the library's TOTP
  strategy, and it sets no `brute_force_strategy`; its per-account and
  per-address throttles are its own. No migration, no configuration.

  rc.16 also makes `log_out_everywhere`'s `apply_on_password_change?` fire on
  password actions that hash in a `before_action`, which it never did before.
  Kiln had declared it, but the control on a password change or reset has been
  `KilnCMS.Accounts.Changes.RevokeAllTokens` since #734. Firing, the flag's
  resource-wide sweep ran after the reset minted its new session and revoked
  it, so Kiln now leaves the flag off. A change or reset revokes exactly what
  it did before.
  ([#2193](https://github.com/The-Verscienta/kiln_cms/pull/2193))

<a id="compound-names"></a>

- **Search matches names written spaced or joined (proposal A5).** A
  downstream TCM catalogue measured `huangqi` reaching Huang Qi at rank 30,
  and `xiaoyaosan` and `He Gu` not reaching their records at all:
  `to_tsvector` splits at spaces and never inside a word, so the title and
  alias legs could not see either spelling as the other. `hybrid/3` gains a
  `compound` leg (`:search_compound`) that rewrites the query one span at a
  time — two or three adjacent words joined, or one word split into two or
  three — and matches the rewrites against titles and `names_record` fields
  at the title leg's weight. A rewrite is made only from the site's name
  terms (`KilnCMS.Search.NameTerms`: the words of published titles and
  flagged names, per organization, cached five minutes), so body text never
  produces one; and a split names a record only when the record's name
  holds the whole split, so `carpet` → `car pet` never finds "Car". A query
  with nothing to rewrite does not run the leg: on a 2,000-record catalogue
  the added work is ~0.07 ms of a 11–18 ms query, and a query that does
  rewrite pays one more index-guarded leg query. `legs` on `/api/search` and
  `/api/ask` hits may now include `compound`.
