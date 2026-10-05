# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="search-now-needs-postgresqls-unaccent-extension"></a>

- **Search now needs PostgreSQL's `unaccent` extension; the upgrade migration
  installs it, refolds non-ASCII search rows and rebuilds the title indexes.**
  `unaccent` ships in PostgreSQL's contrib package (the official and pgvector
  images carry it) and is a *trusted* extension, so the database owner can
  create it without superuser; the migration runs `CREATE EXTENSION IF NOT
  EXISTS unaccent` itself. A managed database that does not offer it fails the
  migration at boot — enable it there first.

  The same migration (`*_accent_folding_extensions_1`, generated from the
  `KilnCMS.Search.AccentFolding` custom extension) then, inside its
  transaction:

  - rebuilds every index whose expression calls `kiln_regconfig`
    (`<table>_title_lexemes_index` on each content table) with `REINDEX`,
    which blocks writes to that table while it runs — seconds on a large
    table, milliseconds on a typical site;
  - rewrites `search_vector` on every content row whose title or
    `search_text` holds a non-ASCII character. A pure-ASCII row yields the
    same vector either way and is not touched.

  Nothing to run by hand, and it is expand-safe: the release before this one
  reads the same columns and calls the same function, and simply gets folded
  answers from it once the migration has run. Rolling the pin back leaves the
  folding in place (the down migration restores the stock configurations, but
  the stored vectors stay folded until each row is next saved).
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628))

<a id="reference-edges-backfill"></a>

- **The upgrade writes a link edge for every stored `:reference` custom field
  value; after restoring a pre-1.1 backup, run `mix kiln.links.backfill`.**
  A data migration (`BackfillReferenceLinks`) inserts one `content_links` row
  per `:reference` value already stored, in one `INSERT … SELECT` per content
  table, so it needs no step from you. It is idempotent: a backup restored
  from before the upgrade, or `custom_fields` rewritten outside the
  application (a raw SQL import), is brought back in line by
  `mix kiln.links.backfill`
  (`bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'` in a
  release), which also deletes edges no stored value implies.

  The schema migration before it replaces `content_links`' unique index with
  one that includes the new `field` column, built `CONCURRENTLY`. If that
  build is interrupted, drop the invalid
  `content_links_unique_field_link_index` and migrate again.
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

## Added

<a id="a-documents-url-can-follow-the-content-tree"></a>

- **A document's URL can follow the content tree.** A type's alias pattern gains
  an `[ancestors]` token, so `"/[ancestors]/[slug]"` puts a document at
  `/docs/guides/routing` and a root document at `/routing` — the empty chain
  drops its segment rather than leaving a stray separator. Nothing about URL
  *resolution* changes: multi-segment paths were already served by `path_alias`
  (#485), which is what makes this additive.
  Moving a section re-derives the paths of everything beneath it, not just the
  document that moved, because each descendant's path contains its own ancestor
  chain. That runs as a job after the commit
  (`KilnCMS.CMS.Workers.RegenerateSubtreeAliases`): the fan-out is unbounded in
  principle, every rewrite goes through the type's `:update` so a 301 is
  recorded and artifacts re-fire, and reading the subtree inside the move's
  transaction is a hazard. Until it lands a descendant keeps the path it had,
  which still resolves; afterwards the old path 301s to the record, whose
  current URL is resolved per request, so repeated moves never chain.
  The regeneration is `KilnCMS.CMS.SlugRegeneration` extended to aliases rather
  than a second bulk path, so it inherits the streaming, the author-pinned skip
  and the write-through-`:update` guarantees that one already had. A
  hand-written alias is never overwritten: the pinned verdict is made against
  what the pattern would have produced **before** the move, because after one
  every derived alias in the subtree differs from the current derivation and
  would otherwise look hand-written. That inference is a workaround for Kiln
  deciding derivedness by re-deriving; recording it instead is
  [#1890](https://github.com/The-Verscienta/kiln_cms/issues/1890).
  An `[ancestors]` token in a *slug* pattern is refused — a slug is one segment
  — and the chain is spliced into the pattern before segmentation, with every
  ancestor slug slugified first, so no stored value can contribute path
  structure or inject a token.

<a id="documents-can-sit-under-one-another-the-content-tree"></a>

- **Documents can sit under one another — the content tree.** Every content
  type gains `parent_id` (a same-type self-reference) and `position` (sibling
  order), so where a document lives is a property of the document rather than
  something an editor restates in a navigation menu and then keeps in sync by
  hand. Placement is its own action (`:move`) rather than two more attributes on
  an ordinary save: a move is a distinct editorial act, the tree UI's
  drag-and-drop wants one call, and it is where the bound on re-deriving a
  subtree's paths belongs. `KilnCMS.CMS.Validations.ContentPlacement` refuses a
  parent in another site, a document's own subtree, and any move that would push
  the subtree it carries past `KilnCMS.CMS.ContentTree.max_depth/0` (five
  levels) — counting the whole subtree, not just the moved record, because
  checking only the record lets an editor land its leaves too deep and then be
  unable to move them back. It is checked on moves only; an unconditional depth
  check would freeze a too-deep row, since outdenting it is itself a write.
  Purging a parent leaves its children as roots rather than taking a subtree of
  published documents with it. The tree is **not** on the public API surface
  yet, deliberately, and nothing about URL resolution changes: a document with
  no parent resolves exactly as before. Multi-segment paths were already served
  by `path_alias` (#485), which is what makes the tree additive — deriving an
  alias from the ancestor chain is the next slice. This is decision **D21** in
  [content-organization-plan.md](../content-organization-plan.md); the tree is
  a different axis from a document's category or tags, which say what it is
  *about* rather than where it sits.
  The content editor's **Organization & relationships** panel sets the parent,
  showing where the document sits now and offering only placements the write
  would accept — `KilnCMS.CMS.ContentTree.candidate_parents/3` does the same
  arithmetic as the validation, so the picker cannot propose a move that gets
  refused. Choosing writes immediately rather than waiting for Save, because a
  move is its own action, and the panel says so. A refusal shows its reason
  ("would nest deeper than 5 levels", "can't be one of this document's own
  children") rather than a generic failure — those only happen when the tree
  moved under the editor since the options were built.

<a id="the-content-list-filters-and-saves-views"></a>

- **The content list filters by author, category, tag, language, update date
  and review health, sorts by update, publish date or title, and saves a
  filter as a named view.**
  The console's list offered status, type and a title search, sorted by last
  update, while the search API already faceted on author, category and tags
  ([content organization plan](../content-organization-plan.md), §3). The list
  now filters on all of those plus language, an update-date range, review
  health ("review due", "due soon", "expired") and "scheduled to publish", and
  sorts by last update, last publish or title. The everyday facets sit beside
  the search box; the rest open from **More filters**, and each active facet
  shows as a chip with its own remove button.

  All of it stays in the URL, as status and search already did: a link, a
  refresh and the back button keep the filter, and a value that cannot be valid
  (a deleted category, a malformed date) reads as absent rather than failing.

  **Views.** Five built-in views — *All content*, *My drafts*, *Needs review*,
  *Scheduled* and *Review due* — sit above the list, and **Save view** stores
  the current filter under a name (`KilnCMS.CMS.SavedView`). A saved view is
  private to its owner; an admin can share one with every editor on the site,
  and only an admin can rename or delete a shared view. Views are per site.

  **Speed.** Each page of the list used to sort the whole site's content to
  keep 51 rows (about 7 ms at 30,000 posts, growing linearly). Three new
  indexes per content table, on `(org_id, updated_at, id)`, `(org_id, title,
  id)` and `(org_id, published_at DESC NULLS LAST, id DESC)`, serve the three
  orders directly (0.03 ms on the same data), and paging continues from a
  keyset per content type, so *Load more* never repeats or skips a row under
  any sort. The indexes are built `CONCURRENTLY`, so a large table keeps
  taking writes while the migration runs. An overlay's own content types get
  them from `mix ash.codegen` in the overlay, as with any index the content
  macro adds; until then their rows list exactly as before, only sorted in
  memory.
  ([#1854](https://github.com/The-Verscienta/kiln_cms/pull/1854))

<a id="on-fly-io-railway-and-digitalocean-rate-limits-can-be-per-visitor"></a>

- **On Fly.io, Railway and DigitalOcean, rate limits can be per visitor:
  `CLIENT_IP_HEADER` reads the platform proxy's own client-address header.**
  Per-IP rate limits, including the brute-force protection on `/sign-in` and
  `/api/auth/sign_in`, need the client's address. Behind a proxy Kiln takes it
  from `X-Forwarded-For`, but only once `TRUSTED_PROXIES` names the proxy, and
  none of the one-click platforms publishes its proxy's address range. On
  DigitalOcean, `X-Forwarded-For` holds the ingress address anyway. So those
  deployments had one shared bucket for every visitor.

  Each of three platforms writes the client address into a header of its own:
  `Fly-Client-IP`, Railway's `X-Real-IP`, and DigitalOcean's
  `do-connecting-ip`. Set `CLIENT_IP_HEADER` to one of them and Kiln uses it,
  ahead of `TRUSTED_PROXIES`. A header is trusted with no peer check, which is
  only safe where every request comes through the platform's proxy, so Kiln
  also requires that platform's own variables (`FLY_APP_NAME` and
  `FLY_MACHINE_ID`; `RAILWAY_SERVICE_ID` and `RAILWAY_ENVIRONMENT_ID`; `APP_ID`
  bound to `${APP_ID}` on App Platform). Without them, or with any other header
  name, the setting is ignored and one error is logged, so a copy on a server
  the internet reaches directly can't let clients choose their own bucket.

  `fly.toml` and `.do/app.yaml` now set it, and the Railway recipe lists it.
  Render documents no such header and is unchanged. One gap is left: sockets
  only receive `x-` headers, so on Fly and DigitalOcean the `/sign-in` form,
  which submits over the live connection, still shares a bucket per
  deployment. A new test also parses `render.yaml`, `fly.toml` and
  `.do/app.yaml` and checks the pinned tag, secrets, database, health check
  and header wiring (#1529).
  ([#1548](https://github.com/The-Verscienta/kiln_cms/issues/1548))

<a id="reference-fields-are-also-link-edges"></a>

- **`:reference` custom fields are also `ContentLink` edges: *Linked from* in
  the editor, broken-reference warnings, and `incoming_links` on the API.**
  A `:reference` field stored a snapshot of its target
  (`%{"id", "type", "slug", "title"}`) in the `custom_fields` jsonb and
  nothing else, so "what links here" meant scanning every content table, a
  trashed target left the snapshot pointing at nothing, and the graph the
  rest of Kiln reads could not see the relation.

  The snapshot is unchanged — same shape, same meaning, still written on
  every save. Beside it, every **live** reference value now has a
  `ContentLink` row (`kind: :reference`) carrying three new attributes:
  `field`, the custom field it came from, and `source_type` / `target_type`,
  both ends' content type names. The edges are reconciled from the stored
  value after any write that moved it — a save, a version restore,
  *Publish changes*, an unpublish folding a working copy — and renaming or
  deleting a field definition moves or deletes its edges with its values. A
  reference held in a published record's working copy has no edge until it
  is published.

  What uses them:

  - the editor's Settings panel lists **Linked from** — every record whose
    links point here, curated related content and references alike, with a
    link to each — and **Unpublish** asks first when anything does;
  - a referrer whose target was trashed or purged shows **Broken
    references** under its custom fields, where the snapshot alone made the
    field look filled in;
  - the read API serves them through the existing `content_links` and
    `incoming_links` includes, now with `field`, `source_type` and
    `target_type`; `CMS.list_backlinks/2` and `KilnCMS.CMS.ContentLinks`
    answer the same in code.

  Reference edges are kept out of `related_<type>s`, which stays
  editor-curated related content. Array references and retiring the snapshot
  are not part of this; the design record is
  `docs/content-organization-plan.md` §4 (decision D20).
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

<a id="field-level-localization"></a>

- **Field-level localization: a field can be shared across a document's
  locale variants, or inherited along the site's fallback chain when empty.**
  Content stays one record per locale. What is new is a per-field mode, as
  the v0.12 design check (`docs/field-level-localization.md`, Design A)
  proposed: `:localized` (the default, and what every field did before),
  `:shared` (one value for the document, owned by the default-locale variant
  and copied into every translation when that variant publishes) and
  `:fallback` (an empty value is filled from the first variant along the
  site's chain that has one).

  Custom fields opt in on the Fields screen; block fields with a new
  `localized:` option on `Kiln.Block`'s `field`; an overlay type's record
  attributes with a new `localization:` option on `use KilnCMS.CMS.Content`;
  and the core types' record attributes with
  `config :kiln_cms, :i18n, field_localization:`. Nothing changes until one of
  them does.

  The copy is a versioned write on each translation (the internal
  `:sync_shared_fields` action), held until *Publish changes* on the source's
  working copy, and written into a translation's own pending working copy too.
  Inherited values are filled in the fired artifacts, on the public page and
  in the search text, never written back to the row; the `:json` artifact
  names them under `inherited_fields`, and JSON:API and GraphQL serve them
  through a new `inherited_fields` / `inheritedFields` field only when asked
  for. The editor shows a shared field read-only on a translation and an empty
  fallback field's inherited value as its placeholder. Translation coverage
  ignores the copy, XLIFF leaves shared fields out, the schema export
  annotates the modes, and saving the fallback chain re-fires the translations
  that can inherit. Every existing response keeps its shape for a type that
  opts nothing in.
  ([#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327))

<a id="plugin-blocks-get-editor-seams"></a>

- **Plugin blocks get editor seams: their own label, icon and description,
  field hints, a row editor for `item_keys:` list fields, and live rendering.**
  A plugin block (D18) joined storage, firing and the palette with no core
  edit, but the editor listed it under its raw name with the generic icon,
  gave an `{:array, :map}` field no input at all, and live delivery drew an
  empty paragraph where the fired artifact rendered it. `Kiln.Block.Renderer`
  gains optional `label/0`, `icon/0` and `description/0`; a field's
  `description:` becomes its input hint; `field ..., {:array, :map},
  item_keys: [...]` gets a repeatable-row editor (one input per key) and a
  derived item schema; and live delivery renders a plugin block with its own
  `:web` serializer. Editing an installed plugin's `blocks/0` now recompiles
  the registries baked from it (a compile-time edge from `Kiln.Plugins`)
  rather than needing `mix compile --force`. Blocks that define none of this render as
  before. ([#1865](https://github.com/The-Verscienta/kiln_cms/pull/1865))

<a id="each-published-github-release-now-becomes-a-page-on-kilncmsdev-at"></a>

- **Each published GitHub release now becomes a page on kilncms.dev at
  `/releases/<version>`, listed at `/releases`.** A new workflow,
  `publish-releases.yml`, runs `scripts/publish_releases.exs` when a release
  is published. The script writes one entry of a `release` content type per
  release. Its body is the release's long-form notes from
  `docs/changelog/vX.Y.Z.md`. Its custom fields are `version`, `released_on`
  (an ISO date), `release_url` and `highlights`, which holds the bold leads of
  the CHANGELOG.md summary's Upgrade notes, Breaking and Added lines. It then
  rebuilds the index page. Release candidates are skipped unless asked for
  with `--prerelease`. `--all` backfills every release. The workflow reuses
  the docs publisher's `KILN_DOCS_URL` and `KILN_DOCS_API_KEY`, and is skipped
  where they are unset. The site's admin creates the `release` type once, and
  the script names any field it is missing. The Markdown renderer and API
  client that `publish_docs.exs` had to itself now live in
  `scripts/publish/common.exs`, which both scripts load; the docs it
  publishes are byte-for-byte unchanged. Nothing changes in the application
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870)).

<a id="each-site-can-publish-a-well-knownsecuritytxt-rfc-9116-set-by-an-admin-at"></a>

- **Each site can publish a `/.well-known/security.txt` (RFC 9116), set by an
  admin at Configure → Organization → Security contact.**
  Kiln had no route for it, so a researcher who found a vulnerability in a
  Kiln-hosted site had nowhere standard to look. The file is per site, like
  branding: the people who answer for one tenant's security are not the people
  who answer for another's, so there is no deployment-wide default underneath —
  a site with no contact answers 404, which RFC 9116 reads as "no
  security.txt", rather than a file missing its one required field. An admin
  sets the contacts (`mailto:`, `https://` or `tel:`), `Expires`, and
  optionally the disclosure policy, preferred languages, encryption key and
  acknowledgments page; `Canonical` is the site's own host, derived on every
  request. The page shows the file as served and warns when `Expires` has
  passed, is within 30 days, or is more than a year out. `/security.txt`
  redirects to the `.well-known` path.

  The file is `Field: value` lines, so a value carrying a line break would add
  a field the admin never wrote — a `Contact:` routing reports elsewhere. Every
  value is held to one line of printable ASCII when saved, and again when the
  file is rendered, so a row restored around the validation cannot forge one
  either. See [docs/seo.md](../seo.md).
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873))

## Changed

<a id="the-update-check-asks-kilncms-devs-release-feed-first"></a>

- **The update check asks kilncms.dev's release feed first and lists the
  release's highlights; GitHub is the fallback, and forks skip the feed.**
  `Kiln.Updates` now reads the `release` entries kilncms.dev publishes for
  each final release (#1870), through the published-entries JSON:API every
  Kiln serves (`/api/json/entries/published?filter[type_name]=release`),
  picks the highest final semver among them, and shows its highlights on
  `/editor/system`. Any failure of that leg — unreachable, a non-200, an
  unexpected shape, no usable entry (the feed's state until the site has
  published a release) — falls through to the GitHub releases API as before,
  so until then the check behaves exactly as it did. The two legs share the
  24-hour cache and the one-per-minute floor; the 15-minute error entry is
  written only when both failed. The feed is paged at 100 and followed for at
  most five pages, and only on its own origin.

  The request is as anonymous as the GitHub one: a bare `KilnCMS`
  user-agent, no version or instance identifier, and only the fixed query
  the response needs. On the serving side, a read of that route no longer
  attaches the client address or forwarding headers to a Sentry error
  report; Kiln's own request logging never carried it.

  `KILN_UPDATE_FEED_URL` points the leg at another Kiln site, or turns it off
  with an off-spelling (`false`). The default feed describes upstream, so a
  deployment that set `KILN_UPDATE_REPO` (to a fork) or
  `KILN_UPDATE_RELEASES_URL` (a mirror) does not ask it unless it sets
  `KILN_UPDATE_FEED_URL` too. `KILN_UPDATE_CHECK=false` still turns the whole
  check off.
  ([#1877](https://github.com/The-Verscienta/kiln_cms/issues/1877))

<a id="the-sync-apis-first-page-stays-under-15-ms-p95-from-10-concurrent"></a>

- **The sync API's first page stays under 15 ms p95 from 10
  concurrent clients, where it took 31–57 ms.**
  `GET /api/sync?initial=true&limit=100` was the one headless read besides
  search that missed the v1.0 "p95 under 50 ms" metric (#1546). Profiled,
  most of a request was CPU: each page decoded 100 stored artifacts only to
  encode them again for the response. Under concurrency, the page's
  `sync_exposures` bulk upsert locked the same 100 rows for every request,
  so requests queued on each other while holding a pool connection.

  Three changes, none to what a page says. The fired-artifact cache now keeps
  each body's JSON beside it, written in the same ETS insert and evicted with
  it, and a sync page embeds that as a `Jason.Fragment`. A page reads which of
  its documents are already recorded as disclosed and writes only the rest
  (or a row whose dynamic type was renamed), so serving a page again takes no
  row locks; exposure rows are never deleted, so the tombstone guarantee is
  unchanged. A cold page reads its artifacts in one query per content type
  instead of one per document, through a new `PublishedArtifact` read action,
  `:for_documents`, with the same policies as `:get_surface`.

  Re-measured with `scripts/benchmarks/api_latency.sh`: server p95 from 10
  clients went from 34–47 ms to 4–14 ms, and the in-process profile from
  13.6 ms and 4.3 queries a request to 3.3–6.5 ms and 2. A golden test checks
  that a page's bytes are what encoding the stored artifacts gives, cold and
  warm. The artifact cache's entry cap went from 10,000 to 20,000, since each
  artifact is now two entries; it still holds 10,000 artifacts, at up to
  twice the memory. Figures and method in
  [`benchmarks.md`](../benchmarks.md#sync-initial-page-after-1713).
  ([#1713](https://github.com/The-Verscienta/kiln_cms/issues/1713))

<a id="search-ranks-faster-under-load"></a>

- **Search ranks faster under load: the query is parsed once per statement,
  not once per matching row, and `/api/search` skips an empty entries section.**
  Profiling `/api/search` with the `scripts/benchmarks/` harness put most of a
  common-word search in two statements, the keyword leg of `posts` and of
  `pages`, and `EXPLAIN` showed why: Postgres switches a prepared statement to
  a *generic* plan after five executions on a connection, and on a generic
  plan the query text is a parameter, not a constant. Every expression built
  from it — `plainto_tsquery(kiln_regconfig($2), $3)` in the filter's recheck
  and in both `ts_rank` calls of the `ORDER BY` — was evaluated once per
  matching row: a word on 1,500 posts parsed and stemmed the query 4,500
  times. The ranking itself was cheap; rebuilding its input was not.

  Each of those expressions (the keyword and any-term filters, `search_rank`,
  `search_rank_any`, the title and alias legs' query tsvector, `highlight`
  and `passage`) is now a scalar `(SELECT …)`, which Postgres runs once per
  execution as an InitPlan. Same values, so the same results: the fixed-corpus
  ranking test is unchanged. On the benchmark corpus the posts keyword leg
  went from 17–24 ms to 5 ms on a generic plan. A test explains the real
  generic plan of every statement a search issues and fails if a query-side
  expression appears outside an InitPlan.

  `/api/search` also stops running the entries section on a site with no
  dynamic content type. Its hits were always dropped there (an entry whose
  type does not resolve is not rendered), and finding none cost three reads
  per search.

  Measured before and after with the same harness: see
  [`docs/benchmarks.md`](../benchmarks.md#headless-api-p95-under-50-ms).
  ([#1725](https://github.com/The-Verscienta/kiln_cms/issues/1725))

<a id="release-candidates-are-canaried-on-kilncms-dev"></a>

- **Every release candidate is canaried on kilncms.dev before the final, and
  the headless API guides carry examples that run against it anonymously.**
  kilncms.dev is the one Kiln instance the project runs with real editors
  and real traffic, and the 1.0 candidates were exercised only by beta
  testers. [`docs/releasing.md`](../releasing.md#cutting-a-release-candidate)
  gains a fifth candidate step: check the migrations over the whole range
  with `mix kiln.migrations.check --base`, deploy the candidate's image to
  kilncms.dev, and let it soak for about 48 hours. A failed or hand-finished
  migration, a new error class, or a p95 regression on the headless API or
  editor save blocks the final. Rolling back is redeploying the previous
  image, which the range check makes safe. `demo.kilncms.dev` takes only
  final releases.

  The headless consumer guide, the JSON:API and GraphQL references and the
  JS client's README each gain a "Try it live" section with JSON:API,
  artifact, search, resolve, sync and GraphQL reads against kilncms.dev's
  own published guides. Every URL was checked anonymously before it was
  written down. kilncms.dev does not publish its OpenAPI document or answer
  GraphQL introspection, and the sections say so rather than link them.
  ([#1869](https://github.com/The-Verscienta/kiln_cms/issues/1869),
  [#1872](https://github.com/The-Verscienta/kiln_cms/issues/1872))

## Fixed

<a id="search-folds-diacritics"></a>

- **Search folds diacritics: `Zusanli` finds `Zúsānlǐ`, `creme brulee` finds
  `Crème brûlée`, in every full-text leg.**
  `kiln_regconfig/1` resolved a locale to a stock text-search configuration,
  which keeps diacritics, so the two spellings were different lexemes and a
  name was findable only by a reader who typed its marks — pinyin with tone
  marks, Vietnamese, French, Spanish. It now returns `kiln_<language>`
  configurations, copies of the stock ones whose dictionary chain for
  non-ASCII words starts with `unaccent`. Every leg goes through that function
  on both the indexed and the query side, so the keyword, any-term, title,
  alias and prefix legs and the highlight all fold at once, with no call-site
  change. Han text is unaffected, as it was already matched. The trigram legs
  (autocomplete, the fuzzy fallback) compare characters and do not fold.

  The function body is a SQL-standard `BEGIN ATOMIC` body, so each
  configuration is bound by OID when it is created: it resolves under any
  `search_path`, including the empty one `pg_dump` restores with, when the
  expression indexes over it are rebuilt. See the upgrade note for what the
  migration does to existing rows.
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628))

<a id="a-custom-field-flagged-searchable-is-indexed"></a>

- **A custom field flagged `searchable` is indexed with the record's text, so
  search finds a record by a Chinese name or a Latin binomial.**
  `SetSearchText` built `search_text` from the title, SEO fields, excerpt and
  blocks, and never read `custom_fields`, so a record's structured identity
  fields were findable only where its prose repeated them — for a Han name,
  nowhere. `FieldDefinition` gains a `searchable` boolean (default `false`,
  on the Fields screen and in the JSON:API `field_definition` type); a flagged
  field's value is appended after the body as body-weight text. Strings and
  numbers are indexed, and the strings inside a list or map value (a list of
  `{language, name}` pairs); map keys and `id`s are not. Opt-in, because most
  keys are numbers, enums and snapshots that would only add noise.

  `custom_fields` is readable with its record, and search runs under the
  record's read policy, so a flagged value is never shown to a reader who
  could not read the record. Flipping the flag, or deleting a flagged field,
  re-fires the type's published documents, which recomputes their
  `search_text`; a draft catches up on its next save. `names_record` is
  unchanged and separate: it makes a value a *name* (the alias leg).
  ([#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585))

<a id="ci-no-longer-fails-at-random-with-type-oban-job-state-can-not-be"></a>

- **CI no longer fails at random with "type `_oban_job_state` can not be
  handled": the suite loads every database type before its first test.**
  Postgrex keeps one cache of database types per database, shared by the
  whole pool, and loads a type it hasn't seen the first time a query uses
  it. It adds a batch of new types in two steps: first the rows, then how to
  decode each. A query on another connection that lands between the two
  steps fails with "can not be handled", and a moment later the same query
  works. A script that aims at that window reproduces it: 376 failures
  across 6,000 freshly created types with 30 concurrent connections.

  In CI every shard starts from an empty database, and `mix test` runs
  `ash.setup` in the same VM, so the cache is filled before the migrations
  create anything. The types they add were then first loaded by the test
  suite, with eight async tests starting at once. Before 2026-10-01 that
  included Oban's job-state enum, which a publish's unique job insert uses.
  Today it is `citext`, `vector`, `halfvec` and `sparsevec`. Locally the test
  database is usually migrated already, which is why it only failed in CI.

  `test_helper.exs` now loads every such type in one query before ExUnit
  starts, and a new test fails if any is missing from the cache when tests
  run. It failed on all 27 completed fresh-database runs without the
  warm-up and passed on all 30 with it. `KilnCMS.PostgrexTypes` also
  registers pgvector's `halfvec` and `sparsevec` codecs, so every type the
  extension installs can be loaded. Production is unaffected: its migrations
  run in a separate VM before the server starts, so the server's cache is
  filled after them.
  ([#1796](https://github.com/The-Verscienta/kiln_cms/issues/1796))

<a id="concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own"></a>

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  `:conclude` took `winner_variant_id` as a `:uuid` argument and wrote it
  straight to the attribute, so the type was the only gate: a non-uuid was
  refused and any well-formed uuid was accepted and stored — one belonging to no
  variant at all, or to a variant of a different experiment on the same site.

  Nothing mis-read it. `Promotion` looks the winner up among *this* experiment's
  arms and answers `:winner_missing`, so no wrong copy was ever written into a
  document. The cost was the row, and the row could not be corrected:
  `winner_variant_id` is `writable? false`, the state machine has no
  `concluded → concluded` transition, and `:update` refuses anything but a
  draft — so all three remedies were shut and nothing short of SQL took the bad
  id back out.

  What it left behind contradicted itself. The Promote button renders on
  `state == :concluded and winner_variant_id`, so it was offered and could never
  succeed, while `winner?/2` matched no row so no `winner` badge showed. The
  page said both "there is a winner to promote" and "no arm won", and the only
  way out was to archive the experiment. The dangling id also shipped in the
  `experiment.concluded` payload, to webhook endpoints, automation rules and
  federation, where nothing could tell it from a real one.

  Ordinary use never produced one. `mix kiln.experiment conclude --winner NAME`
  resolves the name among the experiment's variants and raises on one that is
  not there, and the editor's `<select>` is built from `@experiment.variants` —
  whose options cannot even go stale, because `RefuseWhenRunning` freezes the
  arms for as long as the conclude form is on screen. The action was the only
  layer without the check, which is the layer a crafted LiveView event and any
  other caller of the `conclude_experiment/3` code interface reach.

  `Validations.WinnerIsAVariant` now refuses it, on `field: :winner_variant_id`.
  Concluding with no winner is unchanged — it is a real choice, and the common
  outcome for a test that found no difference. The check reads the arms as the
  system actor with `authorize_with: :error` so it fails closed: a refused read
  answers `[]` under a filter policy, which would otherwise read as "not an arm"
  and refuse a perfectly good winner.
  ([#1851](https://github.com/The-Verscienta/kiln_cms/pull/1851))

<a id="an-overlays-composed-suite-no-longer-fails-the-session-salt-and-system-actor"></a>

- **An overlay's composed suite no longer fails the session-salt and
  system-actor scope tests on a correct configuration.**
  Two tests new in 1.0 held only for this repository. The session-salt test
  pinned `Dsoh9oKb` / `8fso5iqxDfI` exactly, so an overlay that sets its own
  `:session_signing_salt` / `:session_encryption_salt` in
  `config/project.exs`, as the 1.0 upgrade notes ask, failed it; it now pins
  the defaults only where the keys are unset and otherwise asserts the
  configured value. The system-actor scope test (#1747) read the matrix's
  `(content)` row as `CMS.Page`, `CMS.Post` and `CMS.Entry` only, so every
  content type an overlay builds on `KilnCMS.CMS.Content` was reported as
  admitting `:search`, `:cms_bookkeeping` and `:firing` "which its row does
  not name". The row now covers every resource built on the macro, and the
  per-resource subsystem check in `PolicyCoverageTest` holds those types to
  it as well. Test-only; nothing changes at runtime
  ([#1866](https://github.com/The-Verscienta/kiln_cms/pull/1866)).

<a id="a-plugins-console-panels-no-longer-need-a-copy-of-the-cores-surface-test"></a>

- **A plugin's console panels no longer need a copy of the core's surface test
  in an overlay's composed suite.**
  `SurfaceTest` pinned the console route list exactly, including the fixture
  plugin's `/editor/fixture`, so a downstream plugin that mounts a panel
  through `admin_routes/0` or `editor_routes/0` failed it unless the overlay
  shipped a verbatim copy with its own path added, and re-copied it on every
  core bump. Those routes are mounted inside the admin- and editor-gated live
  sessions, so they are console by the router's own facts: the expected list
  is now the core's routes plus every registered plugin's panel routes, taken
  from `Kiln.Plugins`. Core routes stay pinned exactly, and a plugin panel
  that stopped classifying as console still fails. An overlay can delete its
  shadow. Test-only; nothing changes at runtime
  ([#1864](https://github.com/The-Verscienta/kiln_cms/issues/1864)).

## Security

<a id="content-links-readable-only-when-both-ends-are"></a>

- **A content link is readable only by someone who may read both of its ends;
  `incoming_links` no longer names the drafts that link to a published page.**
  `ContentLink`'s read policy was `authorize_if always()`, so that published
  content could load its links. It also meant
  `GET /api/json/pages/:id?include=incoming_links` returned, to anyone, the
  ids of the unpublished records linking to a published page — a draft's
  existence, which the read API otherwise promises never to reveal (a draft
  answers 404, not 403). With every `:reference` value now an edge too, that
  would have grown with every reference field.

  An edge is now returned only when the reader may read its source **and**
  its target. `Checks.LinkEndsReadable` re-reads both ends under the reader's
  own authorization rather than restating the content read policy, the way
  `Checks.DocumentReadable` already does for fired artifacts. Editors and
  admins see every edge of their site, as before; a published-only reader
  sees the links between published records, as before. The join read behind
  `related_<type>s` is unaffected — the related records were, and are,
  filtered by their own policy.
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

