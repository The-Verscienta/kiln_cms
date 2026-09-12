# Changelog

Notable changes to the KilnCMS core, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), interpreted for a
CMS core that downstream projects overlay:

- **major** — the overlay contract breaks. A `projects/<name>/` subproject that
  compiled against the previous version needs code changes: a renamed or
  removed `KilnCMS.CMS.Content` extension point, a changed `Kiln.Plugin`
  callback, a block schema version that isn't upcast automatically.
- **minor** — new capability, overlays keep compiling. May add migrations.
- **patch** — fixes only.

## How downstream projects read this file

Each release entry is a **summary**: one line per change, under
**Upgrade notes**, **Breaking**, **Added**, **Changed**, **Fixed**,
**Security** and **Removed**, in that order. Every line links to the pull
request that shipped it, and — where the entry was shortened — to its own
long-form entry under [`docs/changelog/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/changelog), which holds the
reasoning as it was written when the change merged. A handful of entries argue
a choice that outlives their release; those live in
[`docs/decisions/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/decisions) instead.

The two sections that decide whether you can upgrade today are the first two:

- **Upgrade notes** — steps to perform against a *deployed* instance, and
  anything not reversible by rolling the pin back (a destructive migration, a
  rewritten column, a dropped config key).
- **Breaking** — an observable contract changed, or your overlay or deployment
  has to change to keep working.

`mix kiln.update` prints **only those two**, for every release between your
current pin and the target. A release with neither is "bump the pin, rebuild,
redeploy" and nothing else.

<!--
  Releases are cut from `main`; see docs/releasing.md.

  Entries accrete one per pull request and are condensed by script — write the
  entry however long it needs to be, then run:

      mix kiln.changelog --condense

  which moves the long form to docs/changelog/ and leaves the summary here.
  `mix kiln.changelog --check` runs in precommit and CI; it holds Unreleased
  entries to three lines and fails on an entry with nowhere to link.
-->

## [Unreleased]

Long form: [docs/changelog/unreleased.md](docs/changelog/unreleased.md) —
the Unreleased entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Changed

- **`CHANGELOG.md` is a summary, and the reasoning moved to `docs/changelog/`
  and `docs/decisions/`**.
  ([#1325](https://github.com/The-Verscienta/kiln_cms/issues/1325) · [long form](docs/changelog/unreleased.md#changelogmd-is-a-summary-and-the-reasoning-moved-to-docschangelog-and))

### Fixed

- **Both password forms check the confirmation as you type.**
  ([#1446](https://github.com/The-Verscienta/kiln_cms/issues/1446) · [long form](docs/changelog/unreleased.md#both-password-forms-check-the-confirmation-as-you-type))

## [0.8.0] - 2026-09-11

Long form: [docs/changelog/v0.8.0.md](docs/changelog/v0.8.0.md) —
the 0.8.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- Six migrations ship with this release, all additive; they run on boot.
  ([long form](docs/changelog/v0.8.0.md#six-migrations-ship-with-this-release-all-additive-they-run-on-boot))

- **Run `mix kiln.embed_all` once if semantic search is on.**
  ([long form](docs/changelog/v0.8.0.md#run-mix-kilnembedall-once-if-semantic-search-is-on))

- **Demo mode is new, opt-in, and destructive where it is on.**
  ([long form](docs/changelog/v0.8.0.md#demo-mode-is-new-opt-in-and-destructive-where-it-is-on))

### Breaking

- **Editors cannot publish until you say so, and a scheduled date now needs the
  same permission.**
  ([long form](docs/changelog/v0.8.0.md#editors-cannot-publish-until-you-say-so-and-a-scheduled-date-now-needs-the-same))

### Added

- **`docs/multi-tenancy.md`** — the isolation model in one place: host → org
  resolution, the default org, `TENANT_STRICT_HOST`, compile-time strict
  tenancy, and what is and isn't per-org.
  ([#1313](https://github.com/The-Verscienta/kiln_cms/issues/1313) · [long form](docs/changelog/v0.8.0.md#docsmulti-tenancymd-the-isolation-model-in-one-place-host-org-resolution-the))

- **`monograph` public theme preset.**
  ([#1442](https://github.com/The-Verscienta/kiln_cms/issues/1442) · [long form](docs/changelog/v0.8.0.md#monograph-public-theme-preset))

- **`/api/json/type-definitions` — headless discovery of dynamic content
  types.**
  ([#1433](https://github.com/The-Verscienta/kiln_cms/issues/1433) · [long form](docs/changelog/v0.8.0.md#apijsontype-definitions-headless-discovery-of-dynamic-content-types))

- **Markdown becomes structured content: paste it, import a `.md` file, or write
  it through the API.**
  ([#1435](https://github.com/The-Verscienta/kiln_cms/issues/1435) · [long form](docs/changelog/v0.8.0.md#markdown-becomes-structured-content-paste-it-import-a-md-file-or-write-it))

- **The content editor lists the redirects standing under a record's address.**
  ([#1419](https://github.com/The-Verscienta/kiln_cms/issues/1419) · [long form](docs/changelog/v0.8.0.md#the-content-editor-lists-the-redirects-standing-under-a-records-address))

- **A working copy for live content (docs/working-copy.md).**
  ([#1423](https://github.com/The-Verscienta/kiln_cms/issues/1423) · [long form](docs/changelog/v0.8.0.md#a-working-copy-for-live-content-docsworking-copymd))

- **Field-lock takeover in the content editor.**
  ([#1422](https://github.com/The-Verscienta/kiln_cms/issues/1422) · [long form](docs/changelog/v0.8.0.md#field-lock-takeover-in-the-content-editor))

- **Hybrid search fuses a tag leg.**
  ([#1424](https://github.com/The-Verscienta/kiln_cms/issues/1424) · [long form](docs/changelog/v0.8.0.md#hybrid-search-fuses-a-tag-leg))

- **Search finds a record by its other names.**
  ([#1421](https://github.com/The-Verscienta/kiln_cms/issues/1421) · [long form](docs/changelog/v0.8.0.md#search-finds-a-record-by-its-other-names))

- **Hybrid search fuses a block leg.**
  ([#1417](https://github.com/The-Verscienta/kiln_cms/issues/1417) · [long form](docs/changelog/v0.8.0.md#hybrid-search-fuses-a-block-leg))

- **Paste or drop a picture straight into the body.**
  ([#1416](https://github.com/The-Verscienta/kiln_cms/issues/1416) · [long form](docs/changelog/v0.8.0.md#paste-or-drop-a-picture-straight-into-the-body))

- **A quiet-line watchdog for the editor.**
  ([#1416](https://github.com/The-Verscienta/kiln_cms/issues/1416) · [long form](docs/changelog/v0.8.0.md#a-quiet-line-watchdog-for-the-editor))

- **A path from `/setup` to a published home page.**
  ([#1426](https://github.com/The-Verscienta/kiln_cms/issues/1426) · [long form](docs/changelog/v0.8.0.md#a-path-from-setup-to-a-published-home-page))

- **Workflow refusals say why.**
  ([#1426](https://github.com/The-Verscienta/kiln_cms/issues/1426) · [long form](docs/changelog/v0.8.0.md#workflow-refusals-say-why))

- **Editors can publish, if the site allows it.**
  ([#1426](https://github.com/The-Verscienta/kiln_cms/issues/1426) · [long form](docs/changelog/v0.8.0.md#editors-can-publish-if-the-site-allows-it))

- **A scheduled publish date now needs publish permission.**
  ([#1426](https://github.com/The-Verscienta/kiln_cms/issues/1426) · [long form](docs/changelog/v0.8.0.md#a-scheduled-publish-date-now-needs-publish-permission))

- **A first-run setup wizard at `/setup` (#1317).**
  ([#1317](https://github.com/The-Verscienta/kiln_cms/issues/1317) · [long form](docs/changelog/v0.8.0.md#a-first-run-setup-wizard-at-setup-1317))

- **Official JS/TS client: `@kiln-cms/client`** (`clients/js`, #1310).
  ([#1310](https://github.com/The-Verscienta/kiln_cms/issues/1310) · [long form](docs/changelog/v0.8.0.md#official-jsts-client-kiln-cmsclient-clientsjs-1310))

- **A small public theme layer (#1318).**
  ([#1318](https://github.com/The-Verscienta/kiln_cms/issues/1318) · [long form](docs/changelog/v0.8.0.md#a-small-public-theme-layer-1318))

- **The media library is organisable**.
  ([#1316](https://github.com/The-Verscienta/kiln_cms/issues/1316) · [long form](docs/changelog/v0.8.0.md#the-media-library-is-organisable))

- **Reranking can be scoped to `/api/ask`.**
  ([#1400](https://github.com/The-Verscienta/kiln_cms/issues/1400) · [long form](docs/changelog/v0.8.0.md#reranking-can-be-scoped-to-apiask))

- **`mix kiln.search.eval` — a ranking evaluation harness.**
  ([#1398](https://github.com/The-Verscienta/kiln_cms/issues/1398) · [long form](docs/changelog/v0.8.0.md#mix-kilnsearcheval-a-ranking-evaluation-harness))

- **An any-term fallback for the keyword search leg.**
  ([#1401](https://github.com/The-Verscienta/kiln_cms/issues/1401) · [long form](docs/changelog/v0.8.0.md#an-any-term-fallback-for-the-keyword-search-leg))

- **`mix kiln.search.measure_floor` measures the semantic relevance floor on
  your corpus.**
  ([#1399](https://github.com/The-Verscienta/kiln_cms/issues/1399) · [long form](docs/changelog/v0.8.0.md#mix-kilnsearchmeasurefloor-measures-the-semantic-relevance-floor-on-your-corpus))

- **Search hits carry their score and provenance.**
  ([#1394](https://github.com/The-Verscienta/kiln_cms/issues/1394) · [long form](docs/changelog/v0.8.0.md#search-hits-carry-their-score-and-provenance))

- **A `passage` calc for grounding.**
  ([#1394](https://github.com/The-Verscienta/kiln_cms/issues/1394) · [long form](docs/changelog/v0.8.0.md#a-passage-calc-for-grounding))

- **A title leg in hybrid search: a query that names a record finds it.**
  ([#1396](https://github.com/The-Verscienta/kiln_cms/issues/1396) · [long form](docs/changelog/v0.8.0.md#a-title-leg-in-hybrid-search-a-query-that-names-a-record-finds-it))

### Changed

- **The save line says only what it knows.**
  ([#1416](https://github.com/The-Verscienta/kiln_cms/issues/1416) · [long form](docs/changelog/v0.8.0.md#the-save-line-says-only-what-it-knows))

- **Save and the workflow buttons never miss the last keystrokes.**
  ([#1416](https://github.com/The-Verscienta/kiln_cms/issues/1416) · [long form](docs/changelog/v0.8.0.md#save-and-the-workflow-buttons-never-miss-the-last-keystrokes))

- **CI's main gate is five parallel jobs instead of one serial one.**
  ([#1397](https://github.com/The-Verscienta/kiln_cms/issues/1397) · [long form](docs/changelog/v0.8.0.md#cis-main-gate-is-five-parallel-jobs-instead-of-one-serial-one))

- **The CI build cache is trusted again.**
  ([#1397](https://github.com/The-Verscienta/kiln_cms/issues/1397) · [long form](docs/changelog/v0.8.0.md#the-ci-build-cache-is-trusted-again))

### Fixed

- **Links to a section land on it.**
  ([#5](https://github.com/The-Verscienta/kiln_cms/issues/5) · [long form](docs/changelog/v0.8.0.md#links-to-a-section-land-on-it))

- **Clickable things show a pointer again.**
  ([#1420](https://github.com/The-Verscienta/kiln_cms/issues/1420) · [long form](docs/changelog/v0.8.0.md#clickable-things-show-a-pointer-again))

- **The per-type `semantic-search` routes keep a record the query names.**
  ([#1427](https://github.com/The-Verscienta/kiln_cms/issues/1427) · [long form](docs/changelog/v0.8.0.md#the-per-type-semantic-search-routes-keep-a-record-the-query-names))

- **A non-numeric `semantic_max_distance` now raises instead of flooring
  nothing.**
  ([#871](https://github.com/The-Verscienta/kiln_cms/issues/871) · [long form](docs/changelog/v0.8.0.md#a-non-numeric-semanticmaxdistance-now-raises-instead-of-flooring-nothing))

- **The caret stayed put through a new block's first autosave.**
  ([#1418](https://github.com/The-Verscienta/kiln_cms/issues/1418) · [long form](docs/changelog/v0.8.0.md#the-caret-stayed-put-through-a-new-blocks-first-autosave))

- **A query naming two records returned neither.**
  ([#1396](https://github.com/The-Verscienta/kiln_cms/issues/1396) · [long form](docs/changelog/v0.8.0.md#a-query-naming-two-records-returned-neither))

- **The semantic relevance floor deleted the right answers and kept the noise
  for queries that name records.**
  ([#871](https://github.com/The-Verscienta/kiln_cms/issues/871) · [long form](docs/changelog/v0.8.0.md#the-semantic-relevance-floor-deleted-the-right-answers-and-kept-the-noise-for))

- **`/api/ask` cited sources in alphabetical order of content type, not by
  relevance.**
  ([#1394](https://github.com/The-Verscienta/kiln_cms/issues/1394) · [long form](docs/changelog/v0.8.0.md#apiask-cited-sources-in-alphabetical-order-of-content-type-not-by-relevance))

- **`/api/ask` excerpts could be five words long.**
  ([#1394](https://github.com/The-Verscienta/kiln_cms/issues/1394) · [long form](docs/changelog/v0.8.0.md#apiask-excerpts-could-be-five-words-long))

- **Click a finding in the SEO or accessibility panel to be taken to it.**
  ([#1380](https://github.com/The-Verscienta/kiln_cms/issues/1380) · [long form](docs/changelog/v0.8.0.md#click-a-finding-in-the-seo-or-accessibility-panel-to-be-taken-to-it))

- **The A/V workers are tested on a file ffmpeg can actually read** (#1314's
  coverage plan).
  ([#1314](https://github.com/The-Verscienta/kiln_cms/issues/1314) · [long form](docs/changelog/v0.8.0.md#the-av-workers-are-tested-on-a-file-ffmpeg-can-actually-read-1314s-coverage-plan))

- **A long rich-text block's formatting toolbar stays in reach.**
  ([#1379](https://github.com/The-Verscienta/kiln_cms/issues/1379) · [long form](docs/changelog/v0.8.0.md#a-long-rich-text-blocks-formatting-toolbar-stays-in-reach))

- **The billing webhook's resolution ladder is tested below its top rung**
  (#1314's coverage plan).
  ([#1314](https://github.com/The-Verscienta/kiln_cms/issues/1314) · [long form](docs/changelog/v0.8.0.md#the-billing-webhooks-resolution-ladder-is-tested-below-its-top-rung-1314s))

- **Calendar burst coalescing is readable on a running deployment**.
  ([#1336](https://github.com/The-Verscienta/kiln_cms/issues/1336), [#1362](https://github.com/The-Verscienta/kiln_cms/issues/1362) · [long form](docs/changelog/v0.8.0.md#calendar-burst-coalescing-is-readable-on-a-running-deployment))

- **The System page lists the plugins compiled into this instance**.
  ([#333](https://github.com/The-Verscienta/kiln_cms/issues/333) · [long form](docs/changelog/v0.8.0.md#the-system-page-lists-the-plugins-compiled-into-this-instance))

- **The code-injection console screen is tested, and the coverage floor moves to
  82.7.**
  ([#1363](https://github.com/The-Verscienta/kiln_cms/issues/1363) · [long form](docs/changelog/v0.8.0.md#the-code-injection-console-screen-is-tested-and-the-coverage-floor-moves-to-827))

- **`mix kiln.search.check` — a CI gate for the search-vector migration every
  new content type owes**.
  ([#295](https://github.com/The-Verscienta/kiln_cms/issues/295) · [long form](docs/changelog/v0.8.0.md#mix-kilnsearchcheck-a-ci-gate-for-the-search-vector-migration-every-new-content))

- **Coverage is measured, reported and floored; the Playwright suite grows from
  14 journeys to 19**.
  ([#1314](https://github.com/The-Verscienta/kiln_cms/issues/1314) · [long form](docs/changelog/v0.8.0.md#coverage-is-measured-reported-and-floored-the-playwright-suite-grows-from-14))

- **A canonical deploy guide, `docs/deploy.md`**.
  ([#1312](https://github.com/The-Verscienta/kiln_cms/issues/1312) · [long form](docs/changelog/v0.8.0.md#a-canonical-deploy-guide-docsdeploymd))

- **`KilnCMS.Search.Meilisearch.reindex_all/0`** — the full Meilisearch backfill
  as a release-callable function (`bin/kiln_cms rpc
  'KilnCMS.Search.Meilisearch.reindex_all()'`), so a production release, which
  has no Mix, can do what `mix kiln.meili.reindex` does from a checkout; the Mix
  task now wraps it.
  ([long form](docs/changelog/v0.8.0.md#kilncmssearchmeilisearchreindexall0-the-full-meilisearch-backfill-as-a-release))

- **The form mail workers and the Bluesky provider are actually exercised, and
  `docs/test-coverage-plan.md` says what is next.**
  ([#1339](https://github.com/The-Verscienta/kiln_cms/issues/1339) · [long form](docs/changelog/v0.8.0.md#the-form-mail-workers-and-the-bluesky-provider-are-actually-exercised-and))

- **A keystroke that raced "Add block" no longer deletes the block — or crashes
  the editor**.
  ([#1334](https://github.com/The-Verscienta/kiln_cms/issues/1334) · [long form](docs/changelog/v0.8.0.md#a-keystroke-that-raced-add-block-no-longer-deletes-the-block-or-crashes-the))

- **The rich-text toolbar didn't show Bold (or any mark) as pressed until you
  typed.**
  ([#1381](https://github.com/The-Verscienta/kiln_cms/issues/1381) · [long form](docs/changelog/v0.8.0.md#the-rich-text-toolbar-didnt-show-bold-or-any-mark-as-pressed-until-you-typed))

- **Dragging a chip on the editorial calendar did nothing**.
  ([#1314](https://github.com/The-Verscienta/kiln_cms/issues/1314) · [long form](docs/changelog/v0.8.0.md#dragging-a-chip-on-the-editorial-calendar-did-nothing))

- **The three roadmap documents no longer contradict the issue tracker** (#1313,
  partial).
  ([#1313](https://github.com/The-Verscienta/kiln_cms/issues/1313), [#42](https://github.com/The-Verscienta/kiln_cms/issues/42), [#48](https://github.com/The-Verscienta/kiln_cms/issues/48), [#57](https://github.com/The-Verscienta/kiln_cms/issues/57), [#60](https://github.com/The-Verscienta/kiln_cms/issues/60), [#51](https://github.com/The-Verscienta/kiln_cms/issues/51), [#56](https://github.com/The-Verscienta/kiln_cms/issues/56), [#331](https://github.com/The-Verscienta/kiln_cms/issues/331), [#332](https://github.com/The-Verscienta/kiln_cms/issues/332), [#336](https://github.com/The-Verscienta/kiln_cms/issues/336), [#337](https://github.com/The-Verscienta/kiln_cms/issues/337), [#339](https://github.com/The-Verscienta/kiln_cms/issues/339), [#356](https://github.com/The-Verscienta/kiln_cms/issues/356), [#333](https://github.com/The-Verscienta/kiln_cms/issues/333), [#334](https://github.com/The-Verscienta/kiln_cms/issues/334), [#1324](https://github.com/The-Verscienta/kiln_cms/issues/1324), [#623](https://github.com/The-Verscienta/kiln_cms/issues/623) · [long form](docs/changelog/v0.8.0.md#the-three-roadmap-documents-no-longer-contradict-the-issue-tracker-1313-partial))

- **A content release that aborts is no longer silent**.
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.8.0.md#a-content-release-that-aborts-is-no-longer-silent))

- **A release's `transaction_timeout_ms` now bounds what it claimed to bound**.
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.8.0.md#a-releases-transactiontimeoutms-now-bounds-what-it-claimed-to-bound))

- **The release console totals its readiness verdicts and withholds a go-live
  that could only abort**.
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.8.0.md#the-release-console-totals-its-readiness-verdicts-and-withholds-a-go-live-that))

- **A release item's publish/unpublish choice can be corrected in place**.
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.8.0.md#a-release-items-publishunpublish-choice-can-be-corrected-in-place))

- **A `custom_fields` key with no `FieldDefinition` is refused instead of
  vanishing out of a successful write** (#295 family).
  ([#295](https://github.com/The-Verscienta/kiln_cms/issues/295) · [long form](docs/changelog/v0.8.0.md#a-customfields-key-with-no-fielddefinition-is-refused-instead-of-vanishing-out))

- **Renaming a `FieldDefinition` now moves its stored values, and destroying one
  purges them at once instead of leaving them to be destroyed by an unrelated
  later edit** (#710 follow-up).
  ([#710](https://github.com/The-Verscienta/kiln_cms/issues/710), [#329](https://github.com/The-Verscienta/kiln_cms/issues/329) · [long form](docs/changelog/v0.8.0.md#renaming-a-fielddefinition-now-moves-its-stored-values-and-destroying-one))

- **One content type missing its `search_vector` migration no longer 500s the
  whole site's search**.
  ([#295](https://github.com/The-Verscienta/kiln_cms/issues/295) · [long form](docs/changelog/v0.8.0.md#one-content-type-missing-its-searchvector-migration-no-longer-500s-the-whole))

- **The plugin catalog now counts advisories and spam checks too**.
  ([#333](https://github.com/The-Verscienta/kiln_cms/issues/333) · [long form](docs/changelog/v0.8.0.md#the-plugin-catalog-now-counts-advisories-and-spam-checks-too))

- **`mix kiln.plugins.list` now counts every route kind a plugin contributes**.
  ([#333](https://github.com/The-Verscienta/kiln_cms/issues/333) · [long form](docs/changelog/v0.8.0.md#mix-kilnpluginslist-now-counts-every-route-kind-a-plugin-contributes))

- **A media drawer opened straight after an upload now picks up the dimensions
  the variant worker writes**.
  ([#1314](https://github.com/The-Verscienta/kiln_cms/issues/1314) · [long form](docs/changelog/v0.8.0.md#a-media-drawer-opened-straight-after-an-upload-now-picks-up-the-dimensions-the))

- **A collab room closed by periodic re-authorization now recovers when the
  grant comes back.**
  ([#775](https://github.com/The-Verscienta/kiln_cms/issues/775) · [long form](docs/changelog/v0.8.0.md#a-collab-room-closed-by-periodic-re-authorization-now-recovers-when-the-grant))

- **Calendar reschedule: padding days, same-day drops, and hand-pushed lanes.**
  ([#1332](https://github.com/The-Verscienta/kiln_cms/issues/1332) · [long form](docs/changelog/v0.8.0.md#calendar-reschedule-padding-days-same-day-drops-and-hand-pushed-lanes))

### Security

- **`/ws/gql`, `/ws/bridge` and `/ws/collab` connects are now budgeted per
  client address**, closing the `/ws/*` half of `docs/threat-model.md` item 10's
  residual gap (the `/live` half was closed earlier by #1183).
  ([#1183](https://github.com/The-Verscienta/kiln_cms/issues/1183), [#1305](https://github.com/The-Verscienta/kiln_cms/issues/1305) · [long form](docs/changelog/v0.8.0.md#wsgql-wsbridge-and-wscollab-connects-are-now-budgeted-per-client-address))

- **Every policy bypass on a request path now says why it is safe, and a gate
  keeps it that way**.
  ([#1309](https://github.com/The-Verscienta/kiln_cms/issues/1309), [#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/decisions/0001-policy-bypasses-on-request-paths-must-name-their-reason-and-a-gate-enforces-it.md))

- **Frames on an established `/ws/collab` connection are budgeted per account**.
  ([#1305](https://github.com/The-Verscienta/kiln_cms/issues/1305), [#1183](https://github.com/The-Verscienta/kiln_cms/issues/1183) · [long form](docs/decisions/0002-socket-budgets-are-keyed-on-the-actor-not-the-address-or-the-connection.md))

### Removed

- **A dead `blank_to_nil/1` in `KilnCMSWeb.CodeInjectionLive`.**
  ([#1363](https://github.com/The-Verscienta/kiln_cms/issues/1363) · [long form](docs/changelog/v0.8.0.md#a-dead-blanktonil1-in-kilncmswebcodeinjectionlive))

## [0.7.0] - 2026-08-16

Long form: [docs/changelog/v0.7.0.md](docs/changelog/v0.7.0.md) —
the 0.7.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Added

- **Content lifecycles: expiry actions and a freshness axis.**
  ([long form](docs/changelog/v0.7.0.md#content-lifecycles-expiry-actions-and-a-freshness-axis))

- **An unresolved-discussion filter over the block tree.**
  ([long form](docs/changelog/v0.7.0.md#an-unresolved-discussion-filter-over-the-block-tree))

- **A block's discussion can become accountable work.**
  ([long form](docs/changelog/v0.7.0.md#a-blocks-discussion-can-become-accountable-work))

- **Inline block discussions in the content editor** — the surface half.
  ([long form](docs/changelog/v0.7.0.md#inline-block-discussions-in-the-content-editor-the-surface-half))

- **Block-anchored editorial tasks** — the model half of inline block
  discussions.
  ([long form](docs/changelog/v0.7.0.md#block-anchored-editorial-tasks-the-model-half-of-inline-block-discussions))

- **The editorial calendar grew week and list views, filters, and live
  updates.**
  ([long form](docs/changelog/v0.7.0.md#the-editorial-calendar-grew-week-and-list-views-filters-and-live-updates))

- **The editorial calendar became a control surface: drag-to-reschedule and Mark
  reviewed.**
  ([long form](docs/changelog/v0.7.0.md#the-editorial-calendar-became-a-control-surface-drag-to-reschedule-and-mark))

- **Stale content raises real work: a freshness sweep, two automation triggers,
  and a `create_task` reaction.**
  ([#501](https://github.com/The-Verscienta/kiln_cms/issues/501) · [long form](docs/changelog/v0.7.0.md#stale-content-raises-real-work-a-freshness-sweep-two-automation-triggers-and-a))

- **Office documents and zip archives in the document library**.
  ([#808](https://github.com/The-Verscienta/kiln_cms/issues/808), [#481](https://github.com/The-Verscienta/kiln_cms/issues/481), [#807](https://github.com/The-Verscienta/kiln_cms/issues/807) · [long form](docs/changelog/v0.7.0.md#office-documents-and-zip-archives-in-the-document-library))

- **`EMBED_ORIGINS_LOCKED` — an operator ceiling over what a tenant may open to
  framing**.
  ([#1133](https://github.com/The-Verscienta/kiln_cms/issues/1133), [#648](https://github.com/The-Verscienta/kiln_cms/issues/648), [#1131](https://github.com/The-Verscienta/kiln_cms/issues/1131) · [long form](docs/changelog/v0.7.0.md#embedoriginslocked-an-operator-ceiling-over-what-a-tenant-may-open-to-framing))

- **XLIFF export now carries `legacy_html` prose**.
  ([#1106](https://github.com/The-Verscienta/kiln_cms/issues/1106) · [long form](docs/changelog/v0.7.0.md#xliff-export-now-carries-legacyhtml-prose))

- **The A/V metadata strip can be deferred to a worker, behind a quarantine**.
  ([#1122](https://github.com/The-Verscienta/kiln_cms/issues/1122), [#1112](https://github.com/The-Verscienta/kiln_cms/issues/1112) · [long form](docs/changelog/v0.7.0.md#the-av-metadata-strip-can-be-deferred-to-a-worker-behind-a-quarantine))

### Changed

- **`suggest_tags/2` persists tag-name vectors and ranks in one pgvector
  query**.
  ([#1085](https://github.com/The-Verscienta/kiln_cms/issues/1085), [#851](https://github.com/The-Verscienta/kiln_cms/issues/851), [#1076](https://github.com/The-Verscienta/kiln_cms/issues/1076), [#998](https://github.com/The-Verscienta/kiln_cms/issues/998) · [long form](docs/changelog/v0.7.0.md#suggesttags2-persists-tag-name-vectors-and-ranks-in-one-pgvector-query))

- **`PendingSignIn.mint/4` is now `mint_and_hold/4`, and refuses the caller's
  own credential**.
  ([#1171](https://github.com/The-Verscienta/kiln_cms/issues/1171), [#1170](https://github.com/The-Verscienta/kiln_cms/issues/1170), [#742](https://github.com/The-Verscienta/kiln_cms/issues/742) · [long form](docs/changelog/v0.7.0.md#pendingsigninmint4-is-now-mintandhold4-and-refuses-the-callers-own-credential))

- **One shape for the nine per-org settings resources, and one resolver for
  their cached reads**.
  ([#1080](https://github.com/The-Verscienta/kiln_cms/issues/1080), [#1077](https://github.com/The-Verscienta/kiln_cms/issues/1077) · [long form](docs/changelog/v0.7.0.md#one-shape-for-the-nine-per-org-settings-resources-and-one-resolver-for-their))

### Security

- **The editor console can be served from a host no tenant controls** (#740,
  steps 1–2 of the investigation on that issue).
  ([#740](https://github.com/The-Verscienta/kiln_cms/issues/740), [#490](https://github.com/The-Verscienta/kiln_cms/issues/490) · [long form](docs/changelog/v0.7.0.md#the-editor-console-can-be-served-from-a-host-no-tenant-controls-740-steps-12-of))

- **Content experiments: the editor UI** (#982, #499 phase 2; closes #1087).
  ([#982](https://github.com/The-Verscienta/kiln_cms/issues/982), [#499](https://github.com/The-Verscienta/kiln_cms/issues/499), [#1087](https://github.com/The-Verscienta/kiln_cms/issues/1087) · [long form](docs/changelog/v0.7.0.md#content-experiments-the-editor-ui-982-499-phase-2-closes-1087))

- **The two-factor hold's dependency on AshAuthentication is now pinned in both
  directions**.
  ([#1172](https://github.com/The-Verscienta/kiln_cms/issues/1172), [#742](https://github.com/The-Verscienta/kiln_cms/issues/742) · [long form](docs/changelog/v0.7.0.md#the-two-factor-holds-dependency-on-ashauthentication-is-now-pinned-in-both))

- **`/editor/forms/settings` — a production-reachable page for the per-site form
  settings**.
  ([#1232](https://github.com/The-Verscienta/kiln_cms/issues/1232), [#1131](https://github.com/The-Verscienta/kiln_cms/issues/1131), [#477](https://github.com/The-Verscienta/kiln_cms/issues/477) · [long form](docs/changelog/v0.7.0.md#editorformssettings-a-production-reachable-page-for-the-per-site-form-settings))

- **ActivityPub federation, phase 2: the admin page, blocks, and a replay nonce
  store**.
  ([#967](https://github.com/The-Verscienta/kiln_cms/issues/967), [#743](https://github.com/The-Verscienta/kiln_cms/issues/743) · [long form](docs/changelog/v0.7.0.md#activitypub-federation-phase-2-the-admin-page-blocks-and-a-replay-nonce-store))

- **`/live` root joins are budgeted per client address**.
  ([#1183](https://github.com/The-Verscienta/kiln_cms/issues/1183), [#678](https://github.com/The-Verscienta/kiln_cms/issues/678) · [long form](docs/changelog/v0.7.0.md#live-root-joins-are-budgeted-per-client-address))

## [0.6.0] - 2026-08-12

Long form: [docs/changelog/v0.6.0.md](docs/changelog/v0.6.0.md) —
the 0.6.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Added

- **A per-org default for the form embed allowlist**.
  ([#1131](https://github.com/The-Verscienta/kiln_cms/issues/1131), [#648](https://github.com/The-Verscienta/kiln_cms/issues/648), [#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.6.0.md#a-per-org-default-for-the-form-embed-allowlist))

- **Boot warns when the chain cannot detect splices**.
  ([#1056](https://github.com/The-Verscienta/kiln_cms/issues/1056) · [long form](docs/changelog/v0.6.0.md#boot-warns-when-the-chain-cannot-detect-splices))

- **Claim checking is per site, and has a page**.
  ([#857](https://github.com/The-Verscienta/kiln_cms/issues/857) · [long form](docs/changelog/v0.6.0.md#claim-checking-is-per-site-and-has-a-page))

- **The governance dashboard answers "what are we claiming right now"**.
  ([#858](https://github.com/The-Verscienta/kiln_cms/issues/858), [#377](https://github.com/The-Verscienta/kiln_cms/issues/377), [#352](https://github.com/The-Verscienta/kiln_cms/issues/352), [#857](https://github.com/The-Verscienta/kiln_cms/issues/857) · [long form](docs/changelog/v0.6.0.md#the-governance-dashboard-answers-what-are-we-claiming-right-now))

- **Unsplash search in the content editor's image picker.**
  ([long form](docs/changelog/v0.6.0.md#unsplash-search-in-the-content-editors-image-picker))

### Fixed

- **The xmerl name-budget scanner no longer trips OTP 29's dialyzer** (#599
  family).
  ([#599](https://github.com/The-Verscienta/kiln_cms/issues/599), [#1105](https://github.com/The-Verscienta/kiln_cms/issues/1105) · [long form](docs/changelog/v0.6.0.md#the-xmerl-name-budget-scanner-no-longer-trips-otp-29s-dialyzer-599-family))

- **A database outage no longer 404s every request as an unknown host**.
  ([#341](https://github.com/The-Verscienta/kiln_cms/issues/341), [#1124](https://github.com/The-Verscienta/kiln_cms/issues/1124), [#563](https://github.com/The-Verscienta/kiln_cms/issues/563) · [long form](docs/changelog/v0.6.0.md#a-database-outage-no-longer-404s-every-request-as-an-unknown-host))

- **The admin delivery-cache purge reaches every node**.
  ([#1138](https://github.com/The-Verscienta/kiln_cms/issues/1138) · [long form](docs/changelog/v0.6.0.md#the-admin-delivery-cache-purge-reaches-every-node))

- **A delivery page's ETag now moves when `<head>` settings change**.
  ([#1079](https://github.com/The-Verscienta/kiln_cms/issues/1079) · [long form](docs/changelog/v0.6.0.md#a-delivery-pages-etag-now-moves-when-head-settings-change))

- **Visual editing opens the locale variant you clicked**.
  ([#1104](https://github.com/The-Verscienta/kiln_cms/issues/1104), [#502](https://github.com/The-Verscienta/kiln_cms/issues/502) · [long form](docs/changelog/v0.6.0.md#visual-editing-opens-the-locale-variant-you-clicked))

- **Presentation preview iframe is sandboxed when it shares the console's
  origin**.
  ([#1059](https://github.com/The-Verscienta/kiln_cms/issues/1059) · [long form](docs/changelog/v0.6.0.md#presentation-preview-iframe-is-sandboxed-when-it-shares-the-consoles-origin))

- **A dead app-icon URL no longer keeps `apple-touch-icon` pointed at a 404**.
  ([#1147](https://github.com/The-Verscienta/kiln_cms/issues/1147) · [long form](docs/changelog/v0.6.0.md#a-dead-app-icon-url-no-longer-keeps-apple-touch-icon-pointed-at-a-404))

- **`CollabPersisterTest`'s negative assertion now anchors on a confirmed prior
  write instead of an unwritten seed value**.
  ([#1095](https://github.com/The-Verscienta/kiln_cms/issues/1095), [#1067](https://github.com/The-Verscienta/kiln_cms/issues/1067) · [long form](docs/changelog/v0.6.0.md#collabpersistertests-negative-assertion-now-anchors-on-a-confirmed-prior-write))

- **Four tests' copies of the experiments config fixture now bust the cache on
  restore, like the one that already did**.
  ([#1120](https://github.com/The-Verscienta/kiln_cms/issues/1120), [#1110](https://github.com/The-Verscienta/kiln_cms/issues/1110), [#1210](https://github.com/The-Verscienta/kiln_cms/issues/1210) · [long form](docs/changelog/v0.6.0.md#four-tests-copies-of-the-experiments-config-fixture-now-bust-the-cache-on))

- **The content editor no longer loads every tag in the org on mount**.
  ([#1149](https://github.com/The-Verscienta/kiln_cms/issues/1149), [#638](https://github.com/The-Verscienta/kiln_cms/issues/638) · [long form](docs/changelog/v0.6.0.md#the-content-editor-no-longer-loads-every-tag-in-the-org-on-mount))

- **A losing workflow-transition race now returns a 409, not an opaque 400 plus
  a spammed stacktrace**.
  ([#923](https://github.com/The-Verscienta/kiln_cms/issues/923), [#879](https://github.com/The-Verscienta/kiln_cms/issues/879), [#880](https://github.com/The-Verscienta/kiln_cms/issues/880), [#914](https://github.com/The-Verscienta/kiln_cms/issues/914) · [long form](docs/changelog/v0.6.0.md#a-losing-workflow-transition-race-now-returns-a-409-not-an-opaque-400-plus-a))

- **A missing responsive-label image encoder (no AVIF build, a `thumb.avif` past
  a dimension ceiling) re-decoded the source on every regeneration run,
  forever**.
  ([#1036](https://github.com/The-Verscienta/kiln_cms/issues/1036), [#1000](https://github.com/The-Verscienta/kiln_cms/issues/1000) · [long form](docs/changelog/v0.6.0.md#a-missing-responsive-label-image-encoder-no-avif-build-a-thumbavif-past-a))

- **Archiving a published document now tells subscribers it left delivery**.
  ([#914](https://github.com/The-Verscienta/kiln_cms/issues/914), [#879](https://github.com/The-Verscienta/kiln_cms/issues/879), [#1026](https://github.com/The-Verscienta/kiln_cms/issues/1026) · [long form](docs/changelog/v0.6.0.md#archiving-a-published-document-now-tells-subscribers-it-left-delivery))

- **Publishing no longer discards prose a collab room was still holding**.
  ([#1061](https://github.com/The-Verscienta/kiln_cms/issues/1061) · [long form](docs/changelog/v0.6.0.md#publishing-no-longer-discards-prose-a-collab-room-was-still-holding))

- **The in-context and Presentation editors no longer accept edits they cannot
  save**.
  ([#1159](https://github.com/The-Verscienta/kiln_cms/issues/1159), [#550](https://github.com/The-Verscienta/kiln_cms/issues/550) · [long form](docs/changelog/v0.6.0.md#the-in-context-and-presentation-editors-no-longer-accept-edits-they-cannot-save))

- **Six console actions that authorize nothing now re-check who is asking**.
  ([#1166](https://github.com/The-Verscienta/kiln_cms/issues/1166) · [long form](docs/changelog/v0.6.0.md#six-console-actions-that-authorize-nothing-now-re-check-who-is-asking))

- **A one-click translation honours the acting editor's field grants**.
  ([#1157](https://github.com/The-Verscienta/kiln_cms/issues/1157), [#929](https://github.com/The-Verscienta/kiln_cms/issues/929) · [long form](docs/changelog/v0.6.0.md#a-one-click-translation-honours-the-acting-editors-field-grants))

- **The block envelope is no longer mistaken for a restricted field**, which was
  silently costing every non-admin translation its block ids.
  ([#502](https://github.com/The-Verscienta/kiln_cms/issues/502) · [long form](docs/changelog/v0.6.0.md#the-block-envelope-is-no-longer-mistaken-for-a-restricted-field-which-was))

- **Taking a backup now needs a platform admin, and is re-checked when the
  button is pressed**.
  ([#1160](https://github.com/The-Verscienta/kiln_cms/issues/1160) · [long form](docs/changelog/v0.6.0.md#taking-a-backup-now-needs-a-platform-admin-and-is-re-checked-when-the-button-is))

- **404 capture no longer evicts real misses before attacker junk**.
  ([#920](https://github.com/The-Verscienta/kiln_cms/issues/920) · [long form](docs/changelog/v0.6.0.md#404-capture-no-longer-evicts-real-misses-before-attacker-junk))

- **The ActivityPub inbox no longer fetches an actor it has no use for**.
  ([#966](https://github.com/The-Verscienta/kiln_cms/issues/966) · [long form](docs/changelog/v0.6.0.md#the-activitypub-inbox-no-longer-fetches-an-actor-it-has-no-use-for))

- The content editor no longer offers **Duplicate** or **Create translation** to
  an actor who may open a record without being able to write it.
  ([#922](https://github.com/The-Verscienta/kiln_cms/issues/922) · [long form](docs/changelog/v0.6.0.md#the-content-editor-no-longer-offers-duplicate-or-create-translation-to-an-actor))

### Security

- **The three prompt builders' data fence now carries a per-call nonce instead
  of a static, publicly-known delimiter**.
  ([#1065](https://github.com/The-Verscienta/kiln_cms/issues/1065), [#945](https://github.com/The-Verscienta/kiln_cms/issues/945) · [long form](docs/decisions/0007-the-prompt-data-fence-uses-a-per-call-nonce-not-a-static-delimiter.md))

- **A reusable fragment's content is no longer invisible to search, word count,
  and the editor's own preview**.
  ([#910](https://github.com/The-Verscienta/kiln_cms/issues/910), [#479](https://github.com/The-Verscienta/kiln_cms/issues/479), [#1190](https://github.com/The-Verscienta/kiln_cms/issues/1190), [#1191](https://github.com/The-Verscienta/kiln_cms/issues/1191), [#1192](https://github.com/The-Verscienta/kiln_cms/issues/1192) · [long form](docs/changelog/v0.6.0.md#a-reusable-fragments-content-is-no-longer-invisible-to-search-word-count-and))

- **The governance checkpoint chain's link digest now covers `covered_at` and
  `key_id`, closing a gap `link_failures/1` could not see**.
  ([#892](https://github.com/The-Verscienta/kiln_cms/issues/892), [#732](https://github.com/The-Verscienta/kiln_cms/issues/732) · [long form](docs/changelog/v0.6.0.md#the-governance-checkpoint-chains-link-digest-now-covers-coveredat-and-keyid))

- **A flood of unresolvable hosts against the LiveView and socket transports now
  reaches an operator, not just the plug**.
  ([#678](https://github.com/The-Verscienta/kiln_cms/issues/678), [#659](https://github.com/The-Verscienta/kiln_cms/issues/659), [#677](https://github.com/The-Verscienta/kiln_cms/issues/677), [#1183](https://github.com/The-Verscienta/kiln_cms/issues/1183) · [long form](docs/changelog/v0.6.0.md#a-flood-of-unresolvable-hosts-against-the-liveview-and-socket-transports-now))

- **The analytics export is now shown, not asserted, to resist arithmetic
  recovery of a suppressed referrer count**.
  ([#777](https://github.com/The-Verscienta/kiln_cms/issues/777), [#620](https://github.com/The-Verscienta/kiln_cms/issues/620), [#1054](https://github.com/The-Verscienta/kiln_cms/issues/1054), [#1073](https://github.com/The-Verscienta/kiln_cms/issues/1073) · [long form](docs/changelog/v0.6.0.md#the-analytics-export-is-now-shown-not-asserted-to-resist-arithmetic-recovery-of))

- **An abandoned two-factor sign-in no longer leaves a usable token behind**.
  ([#742](https://github.com/The-Verscienta/kiln_cms/issues/742), [#726](https://github.com/The-Verscienta/kiln_cms/issues/726), [#761](https://github.com/The-Verscienta/kiln_cms/issues/761) · [long form](docs/changelog/v0.6.0.md#an-abandoned-two-factor-sign-in-no-longer-leaves-a-usable-token-behind))

## [0.5.0] - 2026-08-09

Long form: [docs/changelog/v0.5.0.md](docs/changelog/v0.5.0.md) —
the 0.5.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **The occurrence backfill runs itself** (#766) — no step to perform, but worth
  knowing it happens.
  ([#766](https://github.com/The-Verscienta/kiln_cms/issues/766) · [long form](docs/changelog/v0.5.0.md#the-occurrence-backfill-runs-itself-766-no-step-to-perform-but-worth-knowing-it))

- **Rolling back past the history-anchor sequence migration is a one-way door
  for the audit surface.**
  ([#666](https://github.com/The-Verscienta/kiln_cms/issues/666) · [long form](docs/changelog/v0.5.0.md#rolling-back-past-the-history-anchor-sequence-migration-is-a-one-way-door-for))

- **It will not stop your deployment coming up.**
  ([#597](https://github.com/The-Verscienta/kiln_cms/issues/597) · [long form](docs/changelog/v0.5.0.md#it-will-not-stop-your-deployment-coming-up))

- **Rolling the release back is not symmetric.**
  ([long form](docs/changelog/v0.5.0.md#rolling-the-release-back-is-not-symmetric))

- **Integer-valued variables are now bounded at 2³¹-1** (#1091), which affects
  `BACKUP_KEEP_DAYS`, `BACKUP_STALE_AFTER_HOURS`, `KILN_READING_TIME_WPM`,
  `KILN_EXPERIMENTS_STICKY_DAYS` and `KILN_ANALYTICS_LOW_COUNT_THRESHOLD`.
  ([#1091](https://github.com/The-Verscienta/kiln_cms/issues/1091) · [long form](docs/changelog/v0.5.0.md#integer-valued-variables-are-now-bounded-at-2³¹-1-1091-which-affects))

### Breaking

- **`POST /api/auth/sign_in` can now answer `200` instead of `201`, and any
  client that branches on the presence of `token` will read that as a failure.**
  ([#726](https://github.com/The-Verscienta/kiln_cms/issues/726) · [long form](docs/changelog/v0.5.0.md#post-apiauthsignin-can-now-answer-200-instead-of-201-and-any-client-that))

- **Everyone is signed out once on deploy.**
  ([#686](https://github.com/The-Verscienta/kiln_cms/issues/686) · [long form](docs/changelog/v0.5.0.md#everyone-is-signed-out-once-on-deploy))

- **Set `EMBED_ORIGINS` before deploying if you embed forms on other sites.**
  ([#562](https://github.com/The-Verscienta/kiln_cms/issues/562), [#648](https://github.com/The-Verscienta/kiln_cms/issues/648) · [long form](docs/changelog/v0.5.0.md#set-embedorigins-before-deploying-if-you-embed-forms-on-other-sites))

- **Overlays that call `KilnCMSWeb.Tenant.current_org_id/1` or `current_org/1`
  outside a request now raise.**
  ([#563](https://github.com/The-Verscienta/kiln_cms/issues/563) · [long form](docs/changelog/v0.5.0.md#overlays-that-call-kilncmswebtenantcurrentorgid1-or-currentorg1-outside-a))

- **Check `DATABASE_SSL` before deploying, if you set it at all.**
  ([#606](https://github.com/The-Verscienta/kiln_cms/issues/606) · [long form](docs/changelog/v0.5.0.md#check-databasessl-before-deploying-if-you-set-it-at-all))

- **Check `PHX_SERVER` too, if you set it to something false-looking.**
  ([long form](docs/changelog/v0.5.0.md#check-phxserver-too-if-you-set-it-to-something-false-looking))

### Added

- **A white-labelled site installs under its own icon, and its offline page
  carries its own name**.
  ([#629](https://github.com/The-Verscienta/kiln_cms/issues/629) · [long form](docs/changelog/v0.5.0.md#a-white-labelled-site-installs-under-its-own-icon-and-its-offline-page-carries))

- **The governance dashboard says whether history is actually being witnessed**.
  ([#731](https://github.com/The-Verscienta/kiln_cms/issues/731) · [long form](docs/changelog/v0.5.0.md#the-governance-dashboard-says-whether-history-is-actually-being-witnessed))

- **XLIFF 2.0 export/import for translation vendors**.
  ([#502](https://github.com/The-Verscienta/kiln_cms/issues/502), [#865](https://github.com/The-Verscienta/kiln_cms/issues/865), [#954](https://github.com/The-Verscienta/kiln_cms/issues/954) · [long form](docs/changelog/v0.5.0.md#xliff-20-exportimport-for-translation-vendors))

- **Events: "what's on, soonest first"**.
  ([#766](https://github.com/The-Verscienta/kiln_cms/issues/766), [#480](https://github.com/The-Verscienta/kiln_cms/issues/480) · [long form](docs/decisions/0009-events-are-a-shape-content-can-take-not-a-resource-of-their-own.md))

- **Feed syndication is a per-site setting**.
  ([#719](https://github.com/The-Verscienta/kiln_cms/issues/719) · [long form](docs/changelog/v0.5.0.md#feed-syndication-is-a-per-site-setting))

- **Content experiments — A/B testing published content** (#499, phase 1).
  ([#499](https://github.com/The-Verscienta/kiln_cms/issues/499) · [long form](docs/changelog/v0.5.0.md#content-experiments-ab-testing-published-content-499-phase-1))

- **ActivityPub federation: a Kiln site as a fediverse actor** (#491, phase 1).
  ([#491](https://github.com/The-Verscienta/kiln_cms/issues/491) · [long form](docs/changelog/v0.5.0.md#activitypub-federation-a-kiln-site-as-a-fediverse-actor-491-phase-1))

- **Reusable content fragments.**
  ([#479](https://github.com/The-Verscienta/kiln_cms/issues/479) · [long form](docs/changelog/v0.5.0.md#reusable-content-fragments))

- **JSON Schema / TypeScript export of block definitions.**
  ([#430](https://github.com/The-Verscienta/kiln_cms/issues/430) · [long form](docs/changelog/v0.5.0.md#json-schema-typescript-export-of-block-definitions))

- **Bulk content import/export, and a WordPress (WXR) importer.**
  ([#487](https://github.com/The-Verscienta/kiln_cms/issues/487), [#472](https://github.com/The-Verscienta/kiln_cms/issues/472) · [long form](docs/changelog/v0.5.0.md#bulk-content-importexport-and-a-wordpress-wxr-importer))

- **`KilnCMS.Blocks.Html`** reads legacy HTML back into Portable Text and typed
  blocks — the direction `Blocks.PortableText` did not go.
  ([#940](https://github.com/The-Verscienta/kiln_cms/issues/940) · [long form](docs/changelog/v0.5.0.md#kilncmsblockshtml-reads-legacy-html-back-into-portable-text-and-typed-blocks))

### Changed

- **A translation now keeps the source's block ids**.
  ([#502](https://github.com/The-Verscienta/kiln_cms/issues/502) · [long form](docs/changelog/v0.5.0.md#a-translation-now-keeps-the-sources-block-ids))

- **The media ingest pipeline is one module.**
  ([#940](https://github.com/The-Verscienta/kiln_cms/issues/940) · [long form](docs/changelog/v0.5.0.md#the-media-ingest-pipeline-is-one-module))

- **WebP/AVIF variants, quality settings, and bulk regeneration.**
  ([#473](https://github.com/The-Verscienta/kiln_cms/issues/473) · [long form](docs/changelog/v0.5.0.md#webpavif-variants-quality-settings-and-bulk-regeneration))

- **Editor-managed navigation menus.**
  ([#466](https://github.com/The-Verscienta/kiln_cms/issues/466) · [long form](docs/changelog/v0.5.0.md#editor-managed-navigation-menus))

### Fixed

- **A field-granted editor is no longer offered a billed AI run the save will
  refuse**.
  ([#868](https://github.com/The-Verscienta/kiln_cms/issues/868) · [long form](docs/changelog/v0.5.0.md#a-field-granted-editor-is-no-longer-offered-a-billed-ai-run-the-save-will-refuse))

- **The editor's tag picker no longer detaches tags it never showed you**.
  ([#638](https://github.com/The-Verscienta/kiln_cms/issues/638), [#636](https://github.com/The-Verscienta/kiln_cms/issues/636) · [long form](docs/changelog/v0.5.0.md#the-editors-tag-picker-no-longer-detaches-tags-it-never-showed-you))

- **A navigation subtree that goes missing can be got back**.
  ([#900](https://github.com/The-Verscienta/kiln_cms/issues/900) · [long form](docs/changelog/v0.5.0.md#a-navigation-subtree-that-goes-missing-can-be-got-back))

- **Changing a nested heading's level in a Columns block now takes effect**.
  ([#893](https://github.com/The-Verscienta/kiln_cms/issues/893) · [long form](docs/changelog/v0.5.0.md#changing-a-nested-headings-level-in-a-columns-block-now-takes-effect))

- **The collab-editor flake is checked for, not just fixed**.
  ([#1067](https://github.com/The-Verscienta/kiln_cms/issues/1067), [#1090](https://github.com/The-Verscienta/kiln_cms/issues/1090) · [long form](docs/changelog/v0.5.0.md#the-collab-editor-flake-is-checked-for-not-just-fixed))

- **Referrer suppression now actually suppresses**.
  ([#1073](https://github.com/The-Verscienta/kiln_cms/issues/1073), [#620](https://github.com/The-Verscienta/kiln_cms/issues/620), [#777](https://github.com/The-Verscienta/kiln_cms/issues/777) · [long form](docs/changelog/v0.5.0.md#referrer-suppression-now-actually-suppresses))

- **Turning off full-content feeds now empties the cached feed bodies on every
  node**.
  ([#1078](https://github.com/The-Verscienta/kiln_cms/issues/1078), [#719](https://github.com/The-Verscienta/kiln_cms/issues/719) · [long form](docs/changelog/v0.5.0.md#turning-off-full-content-feeds-now-empties-the-cached-feed-bodies-on-every-node))

- **The tag-suggestion threshold is measured now, and the old one was inert**.
  ([#1086](https://github.com/The-Verscienta/kiln_cms/issues/1086), [#851](https://github.com/The-Verscienta/kiln_cms/issues/851) · [long form](docs/changelog/v0.5.0.md#the-tag-suggestion-threshold-is-measured-now-and-the-old-one-was-inert))

- **A content type's default SEO description now reaches every surface that
  renders one**.
  ([#1102](https://github.com/The-Verscienta/kiln_cms/issues/1102), [#805](https://github.com/The-Verscienta/kiln_cms/issues/805) · [long form](docs/changelog/v0.5.0.md#a-content-types-default-seo-description-now-reaches-every-surface-that-renders))

- **The form builder showed `%{value}` instead of the value it was refusing.**
  ([#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.5.0.md#the-form-builder-showed-value-instead-of-the-value-it-was-refusing))

- **The embed page now sends `Vary: Accept-Language`.**
  ([#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.5.0.md#the-embed-page-now-sends-vary-accept-language))

- **Two separators in the form builder rendered as nothing.**
  ([#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.5.0.md#two-separators-in-the-form-builder-rendered-as-nothing))

- **The sitemap escaped three characters where the feeds escaped five**.
  ([#502](https://github.com/The-Verscienta/kiln_cms/issues/502) · [long form](docs/changelog/v0.5.0.md#the-sitemap-escaped-three-characters-where-the-feeds-escaped-five))

- **A headless two-factor pending token is now single-use exactly, not
  best-effort**.
  ([#743](https://github.com/The-Verscienta/kiln_cms/issues/743) · [long form](docs/changelog/v0.5.0.md#a-headless-two-factor-pending-token-is-now-single-use-exactly-not-best-effort))

- **A client-chosen payload shape no longer crashes any editor LiveView** (#764,
  completing the sweep #894 started).
  ([#764](https://github.com/The-Verscienta/kiln_cms/issues/764), [#894](https://github.com/The-Verscienta/kiln_cms/issues/894) · [long form](docs/changelog/v0.5.0.md#a-client-chosen-payload-shape-no-longer-crashes-any-editor-liveview-764))

- **The site name rendered twice in the browser tab.**
  ([#559](https://github.com/The-Verscienta/kiln_cms/issues/559) · [long form](docs/changelog/v0.5.0.md#the-site-name-rendered-twice-in-the-browser-tab))

- **`safe_href/1` accepted `/\evil.com`.**
  ([#899](https://github.com/The-Verscienta/kiln_cms/issues/899) · [long form](docs/changelog/v0.5.0.md#safehref1-accepted-evilcom))

- **Duplicate content.**
  ([#471](https://github.com/The-Verscienta/kiln_cms/issues/471) · [long form](docs/changelog/v0.5.0.md#duplicate-content))

- **404 capture, paired with redirects.**
  ([#472](https://github.com/The-Verscienta/kiln_cms/issues/472) · [long form](docs/changelog/v0.5.0.md#404-capture-paired-with-redirects))

- **The editor PWA's web app manifest is localized.**
  ([#630](https://github.com/The-Verscienta/kiln_cms/issues/630) · [long form](docs/changelog/v0.5.0.md#the-editor-pwas-web-app-manifest-is-localized))

- **Auto-complete-on-publish is now configurable.**
  ([#501](https://github.com/The-Verscienta/kiln_cms/issues/501), [#818](https://github.com/The-Verscienta/kiln_cms/issues/818) · [long form](docs/changelog/v0.5.0.md#auto-complete-on-publish-is-now-configurable))

- **`mix kiln.audit.checkpoint --audit` walks the checkpoint run's predecessor
  links, and its structural half now runs without a witness.**
  ([#732](https://github.com/The-Verscienta/kiln_cms/issues/732) · [long form](docs/changelog/v0.5.0.md#mix-kilnauditcheckpoint---audit-walks-the-checkpoint-runs-predecessor-links-and))

- **Editorial claim checking.**
  ([#377](https://github.com/The-Verscienta/kiln_cms/issues/377) · [long form](docs/changelog/v0.5.0.md#editorial-claim-checking))

- **Beta testing program.**
  ([#59](https://github.com/The-Verscienta/kiln_cms/issues/59) · [long form](docs/changelog/v0.5.0.md#beta-testing-program))

- **"Add to release" from the content editor.**
  ([#836](https://github.com/The-Verscienta/kiln_cms/issues/836) · [long form](docs/changelog/v0.5.0.md#add-to-release-from-the-content-editor))

- **Content releases are bounded.**
  ([#837](https://github.com/The-Verscienta/kiln_cms/issues/837) · [long form](docs/changelog/v0.5.0.md#content-releases-are-bounded))

- **Content releases: bundled, atomically published groups of changes.**
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.5.0.md#content-releases-bundled-atomically-published-groups-of-changes))

- **Event content: schedules, recurrence, and calendar output.**
  ([#480](https://github.com/The-Verscienta/kiln_cms/issues/480) · [long form](docs/changelog/v0.5.0.md#event-content-schedules-recurrence-and-calendar-output))

- **Rich embed cards: server-side oEmbed metadata.**
  ([#489](https://github.com/The-Verscienta/kiln_cms/issues/489) · [long form](docs/decisions/0010-embed-metadata-is-resolved-server-side-against-a-curated-provider-list.md))

- **Broken outbound links: a scheduled sweep and a site-wide report** — the
  other half of the link checker (#474), and the half with teeth.
  ([#474](https://github.com/The-Verscienta/kiln_cms/issues/474) · [long form](docs/changelog/v0.5.0.md#broken-outbound-links-a-scheduled-sweep-and-a-site-wide-report-the-other-half))

- **Broken internal links are flagged in the editor** — the deterministic half
  of the link checker.
  ([#474](https://github.com/The-Verscienta/kiln_cms/issues/474) · [long form](docs/changelog/v0.5.0.md#broken-internal-links-are-flagged-in-the-editor-the-deterministic-half-of-the))

- **A `gallery` block, and an `accordion` block that deliberately fires no
  structured data.**
  ([#482](https://github.com/The-Verscienta/kiln_cms/issues/482), [#403](https://github.com/The-Verscienta/kiln_cms/issues/403) · [long form](docs/changelog/v0.5.0.md#a-gallery-block-and-an-accordion-block-that-deliberately-fires-no-structured))

- **`reading_time_minutes` alongside `word_count`** on every content type, in
  the same places: the admin show view, JSON:API and GraphQL
  (`readingTimeMinutes`).
  ([#492](https://github.com/The-Verscienta/kiln_cms/issues/492) · [long form](docs/changelog/v0.5.0.md#readingtimeminutes-alongside-wordcount-on-every-content-type-in-the-same-places))

- **`word_count` now counts Unicode whitespace**, fixing a disagreement the new
  reading time would otherwise have made visible.
  ([#492](https://github.com/The-Verscienta/kiln_cms/issues/492) · [long form](docs/changelog/v0.5.0.md#wordcount-now-counts-unicode-whitespace-fixing-a-disagreement-the-new-reading))

- The `reading_time()` computed-field function now uses the same configured rate
  as `reading_time_minutes`.
  ([#492](https://github.com/The-Verscienta/kiln_cms/issues/492) · [long form](docs/changelog/v0.5.0.md#the-readingtime-computed-field-function-now-uses-the-same-configured-rate-as))

- **A manual delivery-cache purge.**
  ([#483](https://github.com/The-Verscienta/kiln_cms/issues/483) · [long form](docs/changelog/v0.5.0.md#a-manual-delivery-cache-purge))

- **A deployment behind a proxy with `TRUSTED_PROXIES` unset now says so.**
  ([#564](https://github.com/The-Verscienta/kiln_cms/issues/564) · [long form](docs/changelog/v0.5.0.md#a-deployment-behind-a-proxy-with-trustedproxies-unset-now-says-so))

- `TENANT_STRICT_HOST=true` rejects a request whose `Host` matches no
  organization instead of serving it the default org.
  ([#563](https://github.com/The-Verscienta/kiln_cms/issues/563), [#655](https://github.com/The-Verscienta/kiln_cms/issues/655) · [long form](docs/changelog/v0.5.0.md#tenantstricthosttrue-rejects-a-request-whose-host-matches-no-organization))

- Content updates take `add_tag_ids` and `remove_tag_ids` alongside the existing
  `tag_ids`.
  ([#521](https://github.com/The-Verscienta/kiln_cms/issues/521) · [long form](docs/changelog/v0.5.0.md#content-updates-take-addtagids-and-removetagids-alongside-the-existing-tagids))

- `mix docs` now builds a complete manual: the API reference for every module in
  `lib/`, the `mix kiln.*` task reference, and all 63 guides under `docs/`,
  grouped into a sidebar (Getting started, Authoring & editorial, APIs &
  headless, Operations & deployment, Security & access, and two archive groups
  for design records and point-in-time audits).
  ([#569](https://github.com/The-Verscienta/kiln_cms/issues/569) · [long form](docs/changelog/v0.5.0.md#mix-docs-now-builds-a-complete-manual-the-api-reference-for-every-module-in-lib))

- Content analytics now keeps a **daily view bucket** alongside the all-time
  counter, so the analytics dashboard shows a 7-day / 30-day trend chart and a
  per-item view count for the selected range.
  ([#555](https://github.com/The-Verscienta/kiln_cms/issues/555) · [long form](docs/changelog/v0.5.0.md#content-analytics-now-keeps-a-daily-view-bucket-alongside-the-all-time-counter))

- Recording a content view now emits a `[:kiln_cms, :analytics, :view]`
  `:telemetry` event (measurement `count`, metadata `type` and `content_id`),
  with a matching `kiln_cms.analytics.view.count` metric tagged by content type.
  ([#555](https://github.com/The-Verscienta/kiln_cms/issues/555) · [long form](docs/changelog/v0.5.0.md#recording-a-content-view-now-emits-a-kilncms-analytics-view-telemetry-event))

- `Kiln.Version` — a running instance can now report its release version, and
  the git SHA and build date baked in by the Dockerfile (`--build-arg GIT_SHA` /
  `BUILD_DATE`).
  ([#549](https://github.com/The-Verscienta/kiln_cms/issues/549) · [long form](docs/changelog/v0.5.0.md#kilnversion-a-running-instance-can-now-report-its-release-version-and-the-git))

- `mix kiln.update` — moves a downstream project's pinned Kiln checkout
  (submodule or fetched ref, at whatever path the project uses) to a tagged
  upstream release, reporting the changelog and any new migrations first.
  ([#594](https://github.com/The-Verscienta/kiln_cms/issues/594) · [long form](docs/changelog/v0.5.0.md#mix-kilnupdate-moves-a-downstream-projects-pinned-kiln-checkout-submodule-or))

- An admin-only update notice showing the running version against the latest
  upstream release, plus the command to apply it.
  ([#549](https://github.com/The-Verscienta/kiln_cms/issues/549) · [long form](docs/changelog/v0.5.0.md#an-admin-only-update-notice-showing-the-running-version-against-the-latest))

- `.tool-versions` is now the single source of truth for the Elixir/OTP
  toolchain.
  ([#604](https://github.com/The-Verscienta/kiln_cms/issues/604) · [long form](docs/changelog/v0.5.0.md#tool-versions-is-now-the-single-source-of-truth-for-the-elixirotp-toolchain))

- The update check is no longer nailed to this repo.
  ([#545](https://github.com/The-Verscienta/kiln_cms/issues/545) · [long form](docs/changelog/v0.5.0.md#the-update-check-is-no-longer-nailed-to-this-repo))

- Media stored on S3/MinIO is now uploaded with `Cache-Control: public,
  max-age=31536000, immutable`, so a CDN in front of the bucket can cache
  originals and variants indefinitely.
  ([#552](https://github.com/The-Verscienta/kiln_cms/issues/552) · [long form](docs/changelog/v0.5.0.md#media-stored-on-s3minio-is-now-uploaded-with-cache-control-public-max))

- Media stored on S3/MinIO is now uploaded with `Content-Disposition:
  attachment`, closing half the gap against Local-adapter media, which has
  always carried it.
  ([#553](https://github.com/The-Verscienta/kiln_cms/issues/553) · [long form](docs/changelog/v0.5.0.md#media-stored-on-s3minio-is-now-uploaded-with-content-disposition-attachment))

- **The remaining auth pages no longer render another tenant's branding.**
  ([#688](https://github.com/The-Verscienta/kiln_cms/issues/688), [#701](https://github.com/The-Verscienta/kiln_cms/issues/701), [#48](https://github.com/The-Verscienta/kiln_cms/issues/48) · [long form](docs/changelog/v0.5.0.md#the-remaining-auth-pages-no-longer-render-another-tenants-branding))

- **A client-chosen payload shape no longer crashes an editor LiveView.**
  ([#764](https://github.com/The-Verscienta/kiln_cms/issues/764), [#751](https://github.com/The-Verscienta/kiln_cms/issues/751) · [long form](docs/changelog/v0.5.0.md#a-client-chosen-payload-shape-no-longer-crashes-an-editor-liveview))

- **`KILN_STRICT_TEST=true` ran the test suite without strict tenancy, and said
  nothing.**
  ([#646](https://github.com/The-Verscienta/kiln_cms/issues/646), [#336](https://github.com/The-Verscienta/kiln_cms/issues/336) · [long form](docs/changelog/v0.5.0.md#kilnstricttesttrue-ran-the-test-suite-without-strict-tenancy-and-said-nothing))

- **Every `config/runtime.exs` line anchor in `docs/environment-variables.md`
  points at the right line again, and a test keeps it that way.**
  ([#610](https://github.com/The-Verscienta/kiln_cms/issues/610), [#645](https://github.com/The-Verscienta/kiln_cms/issues/645), [#657](https://github.com/The-Verscienta/kiln_cms/issues/657) · [long form](docs/changelog/v0.5.0.md#every-configruntimeexs-line-anchor-in-docsenvironment-variablesmd-points-at-the))

- **A rate-limited request now answers the same error envelope as everything
  else it sits in front of.**
  ([#750](https://github.com/The-Verscienta/kiln_cms/issues/750), [#744](https://github.com/The-Verscienta/kiln_cms/issues/744) · [long form](docs/changelog/v0.5.0.md#a-rate-limited-request-now-answers-the-same-error-envelope-as-everything-else))

- **`audit_anchor_every_write` no longer reports untouched documents as
  tampered.**
  ([#32](https://github.com/The-Verscienta/kiln_cms/issues/32), [#671](https://github.com/The-Verscienta/kiln_cms/issues/671) · [long form](docs/changelog/v0.5.0.md#auditanchoreverywrite-no-longer-reports-untouched-documents-as-tampered))

- **The collaborative-editing doc supervisor is bounded.**
  ([#655](https://github.com/The-Verscienta/kiln_cms/issues/655), [#676](https://github.com/The-Verscienta/kiln_cms/issues/676) · [long form](docs/changelog/v0.5.0.md#the-collaborative-editing-doc-supervisor-is-bounded))

- **`entries_versions` had no index on `version_source_id`.**
  ([#672](https://github.com/The-Verscienta/kiln_cms/issues/672) · [long form](docs/changelog/v0.5.0.md#entriesversions-had-no-index-on-versionsourceid))

- **History anchoring no longer resumes its incremental fold with a SQL
  `OFFSET`.**
  ([#598](https://github.com/The-Verscienta/kiln_cms/issues/598) · [long form](docs/changelog/v0.5.0.md#history-anchoring-no-longer-resumes-its-incremental-fold-with-a-sql-offset))

- **Artifacts fired before a surface-shape change are now migrated instead of
  serving the old shape forever.**
  ([#601](https://github.com/The-Verscienta/kiln_cms/issues/601), [#664](https://github.com/The-Verscienta/kiln_cms/issues/664), [#615](https://github.com/The-Verscienta/kiln_cms/issues/615) · [long form](docs/changelog/v0.5.0.md#artifacts-fired-before-a-surface-shape-change-are-now-migrated-instead-of))

- **`KilnCMSWeb.Tenant.current_org_id/1` raises on a missing `:current_org`
  assign** instead of quietly returning the default org.
  ([#563](https://github.com/The-Verscienta/kiln_cms/issues/563) · [long form](docs/changelog/v0.5.0.md#kilncmswebtenantcurrentorgid1-raises-on-a-missing-currentorg-assign-instead-of))

- **`DATABASE_SSL=True` no longer disables Postgres TLS.**
  ([#606](https://github.com/The-Verscienta/kiln_cms/issues/606) · [long form](docs/changelog/v0.5.0.md#databasessltrue-no-longer-disables-postgres-tls))

- Every on/off environment variable now goes through one parser,
  `KilnCMS.Config.Env` — seven call sites that previously shared no code, in
  five distinct parser shapes and three different unrecognized-value semantics.
  ([#607](https://github.com/The-Verscienta/kiln_cms/issues/607) · [long form](docs/changelog/v0.5.0.md#every-onoff-environment-variable-now-goes-through-one-parser-kilncmsconfigenv))

- **`PHX_SERVER=false` no longer starts the web server.**
  ([#642](https://github.com/The-Verscienta/kiln_cms/issues/642) · [long form](docs/changelog/v0.5.0.md#phxserverfalse-no-longer-starts-the-web-server))

- A blank `DATABASE_SSL_CACERTFILE=` configured `verify_peer` against an empty
  path, so `:ssl` could not read the bundle and **every database connection
  failed at boot** — the opposite of the "encrypt but skip verification"
  fallback that branch exists to provide.
  ([#642](https://github.com/The-Verscienta/kiln_cms/issues/642) · [long form](docs/changelog/v0.5.0.md#a-blank-databasesslcacertfile-configured-verifypeer-against-an-empty-path-so))

- `KILN_STAGING_FORCE` accepted only the literal `1`, so
  `KILN_STAGING_FORCE=true` read as *not* forced.
  ([#642](https://github.com/The-Verscienta/kiln_cms/issues/642) · [long form](docs/changelog/v0.5.0.md#kilnstagingforce-accepted-only-the-literal-1-so-kilnstagingforcetrue-read-as))

- The media library's responsive-variant list previews each variant inline
  instead of linking to it.
  ([#554](https://github.com/The-Verscienta/kiln_cms/issues/554) · [long form](docs/changelog/v0.5.0.md#the-media-librarys-responsive-variant-list-previews-each-variant-inline-instead))

### Security

- **Promoting a dynamic type no longer leaves its documents unwitnessed for a
  checkpoint interval**.
  ([#849](https://github.com/The-Verscienta/kiln_cms/issues/849), [#704](https://github.com/The-Verscienta/kiln_cms/issues/704) · [long form](docs/changelog/v0.5.0.md#promoting-a-dynamic-type-no-longer-leaves-its-documents-unwitnessed-for-a))

- **A form's embed allowlist is now the form's, not the deployment's**.
  ([#648](https://github.com/The-Verscienta/kiln_cms/issues/648), [#562](https://github.com/The-Verscienta/kiln_cms/issues/562) · [long form](docs/decisions/0006-a-forms-embed-allowlist-belongs-to-the-form-not-to-the-deployment.md))

- **A CSP source may no longer wildcard a public suffix.**
  ([#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.5.0.md#a-csp-source-may-no-longer-wildcard-a-public-suffix))

- **A form's embed allowlist survives duplication.**
  ([#1130](https://github.com/The-Verscienta/kiln_cms/issues/1130) · [long form](docs/changelog/v0.5.0.md#a-forms-embed-allowlist-survives-duplication))

- **Webhook delivery now goes through `KilnCMS.SafeFetch`**.
  ([#753](https://github.com/The-Verscienta/kiln_cms/issues/753) · [long form](docs/decisions/0008-outbound-fetches-go-through-kilncmssafefetch-which-pins-the-resolved-address.md))

- **`mix kiln.audit.verify` can now fail a run it previously passed, and no
  longer calls a chain "intact" when its attestation stops short of the head.**
  ([#811](https://github.com/The-Verscienta/kiln_cms/issues/811), [#666](https://github.com/The-Verscienta/kiln_cms/issues/666) · [long form](docs/changelog/v0.5.0.md#mix-kilnauditverify-can-now-fail-a-run-it-previously-passed-and-no-longer-calls))

- **Demoting, offboarding or erasing a user now drops their live sockets.**
  ([#655](https://github.com/The-Verscienta/kiln_cms/issues/655), [#775](https://github.com/The-Verscienta/kiln_cms/issues/775), [#675](https://github.com/The-Verscienta/kiln_cms/issues/675) · [long form](docs/changelog/v0.5.0.md#demoting-offboarding-or-erasing-a-user-now-drops-their-live-sockets))

- **An editor can no longer clear an admin-set block field by omitting it.**
  ([#51](https://github.com/The-Verscienta/kiln_cms/issues/51), [#566](https://github.com/The-Verscienta/kiln_cms/issues/566) · [long form](docs/changelog/v0.5.0.md#an-editor-can-no-longer-clear-an-admin-set-block-field-by-omitting-it))

- **Registration, password-reset and magic-link forms are bounded per client
  address.**
  ([#715](https://github.com/The-Verscienta/kiln_cms/issues/715), [#724](https://github.com/The-Verscienta/kiln_cms/issues/724) · [long form](docs/changelog/v0.5.0.md#registration-password-reset-and-magic-link-forms-are-bounded-per-client-address))

- **The OpenAPI document and Swagger explorer are no longer served in production
  by default.**
  ([#330](https://github.com/The-Verscienta/kiln_cms/issues/330), [#567](https://github.com/The-Verscienta/kiln_cms/issues/567) · [long form](docs/changelog/v0.5.0.md#the-openapi-document-and-swagger-explorer-are-no-longer-served-in-production-by))

- **A bracketed query parameter no longer 500s a public route.**
  ([#700](https://github.com/The-Verscienta/kiln_cms/issues/700), [#744](https://github.com/The-Verscienta/kiln_cms/issues/744), [#751](https://github.com/The-Verscienta/kiln_cms/issues/751) · [long form](docs/changelog/v0.5.0.md#a-bracketed-query-parameter-no-longer-500s-a-public-route))

- **The two sign-in gates no longer carry their own copy of the pending-token
  plumbing.**
  ([#726](https://github.com/The-Verscienta/kiln_cms/issues/726), [#745](https://github.com/The-Verscienta/kiln_cms/issues/745) · [long form](docs/changelog/v0.5.0.md#the-two-sign-in-gates-no-longer-carry-their-own-copy-of-the-pending-token))

- **A password that stops at the code prompt no longer clears the account's
  sign-in budget.**
  ([#478](https://github.com/The-Verscienta/kiln_cms/issues/478), [#742](https://github.com/The-Verscienta/kiln_cms/issues/742) · [long form](docs/changelog/v0.5.0.md#a-password-that-stops-at-the-code-prompt-no-longer-clears-the-accounts-sign-in))

- **A second-factor lockout now tells the owner.**
  ([#478](https://github.com/The-Verscienta/kiln_cms/issues/478), [#714](https://github.com/The-Verscienta/kiln_cms/issues/714), [#742](https://github.com/The-Verscienta/kiln_cms/issues/742), [#726](https://github.com/The-Verscienta/kiln_cms/issues/726), [#727](https://github.com/The-Verscienta/kiln_cms/issues/727), [#757](https://github.com/The-Verscienta/kiln_cms/issues/757), [#728](https://github.com/The-Verscienta/kiln_cms/issues/728) · [long form](docs/changelog/v0.5.0.md#a-second-factor-lockout-now-tells-the-owner))

- **The three TOTP actions on `/editor/settings` are now budgeted, so a stolen
  session can't grind the six digits that gate them.**
  ([#714](https://github.com/The-Verscienta/kiln_cms/issues/714), [#715](https://github.com/The-Verscienta/kiln_cms/issues/715), [#754](https://github.com/The-Verscienta/kiln_cms/issues/754), [#727](https://github.com/The-Verscienta/kiln_cms/issues/727) · [long form](docs/changelog/v0.5.0.md#the-three-totp-actions-on-editorsettings-are-now-budgeted-so-a-stolen-session))

- **`POST /api/auth/sign_in` no longer skips the second factor.**
  ([#714](https://github.com/The-Verscienta/kiln_cms/issues/714), [#726](https://github.com/The-Verscienta/kiln_cms/issues/726) · [long form](docs/changelog/v0.5.0.md#post-apiauthsignin-no-longer-skips-the-second-factor))

- **History anchors verify as a chain, not just at the head.**
  ([#597](https://github.com/The-Verscienta/kiln_cms/issues/597), [#666](https://github.com/The-Verscienta/kiln_cms/issues/666), [#591](https://github.com/The-Verscienta/kiln_cms/issues/591) · [long form](docs/decisions/0003-history-anchors-verify-as-a-chain-and-an-unjudgeable-anchor-floors-the-chain.md))

- **A LiveView join with no URL is refused instead of skipping every router
  gate.**
  ([#688](https://github.com/The-Verscienta/kiln_cms/issues/688) · [long form](docs/decisions/0004-a-liveview-join-that-matches-no-route-is-refused-rather-than-mounted-ungated.md))

- **The session cookie is `__Host-`-prefixed in production.**
  ([#490](https://github.com/The-Verscienta/kiln_cms/issues/490), [#686](https://github.com/The-Verscienta/kiln_cms/issues/686) · [long form](docs/decisions/0005-the-production-session-cookie-is-host--prefixed-with-no-dual-read-window.md))

- **The shared token preview wears the requesting site's branding too.**
  ([#680](https://github.com/The-Verscienta/kiln_cms/issues/680) · [long form](docs/changelog/v0.5.0.md#the-shared-token-preview-wears-the-requesting-sites-branding-too))

- **Error pages now wear the requesting site's branding, not the default
  org's.**
  ([#48](https://github.com/The-Verscienta/kiln_cms/issues/48), [#656](https://github.com/The-Verscienta/kiln_cms/issues/656) · [long form](docs/changelog/v0.5.0.md#error-pages-now-wear-the-requesting-sites-branding-not-the-default-orgs))

- **`TENANT_STRICT_HOST` refusals no longer cost a database lookup every time.**
  ([#659](https://github.com/The-Verscienta/kiln_cms/issues/659) · [long form](docs/changelog/v0.5.0.md#tenantstricthost-refusals-no-longer-cost-a-database-lookup-every-time))

- **The strict-host 404 is documented as the tenant-name oracle it is.**
  ([#659](https://github.com/The-Verscienta/kiln_cms/issues/659) · [long form](docs/changelog/v0.5.0.md#the-strict-host-404-is-documented-as-the-tenant-name-oracle-it-is))

- **The collaborative-editing socket now authorizes every join against the
  document it names.**
  ([#332](https://github.com/The-Verscienta/kiln_cms/issues/332), [#655](https://github.com/The-Verscienta/kiln_cms/issues/655) · [long form](docs/changelog/v0.5.0.md#the-collaborative-editing-socket-now-authorizes-every-join-against-the-document))

- **History anchors chain to each other by id and digest, narrowing the
  laundering route in #597.**
  ([#597](https://github.com/The-Verscienta/kiln_cms/issues/597), [#666](https://github.com/The-Verscienta/kiln_cms/issues/666) · [long form](docs/changelog/v0.5.0.md#history-anchors-chain-to-each-other-by-id-and-digest-narrowing-the-laundering))

- **A malformed `TRUSTED_PROXIES` no longer takes the node down.**
  ([#564](https://github.com/The-Verscienta/kiln_cms/issues/564) · [long form](docs/changelog/v0.5.0.md#a-malformed-trustedproxies-no-longer-takes-the-node-down))

- `TENANT_STRICT_HOST` is read with `Config.Env.fetch/1` rather than `flag/2`,
  so leaving the variable unset no longer overwrites a project overlay's `config
  :kiln_cms, :tenant_strict_host, true` with `false` — which would have turned
  strict host matching off silently, in production, on the multi-org deployment
  most likely to have set it.
  ([#653](https://github.com/The-Verscienta/kiln_cms/issues/653) · [long form](docs/changelog/v0.5.0.md#tenantstricthost-is-read-with-configenvfetch1-rather-than-flag2-so-leaving-the))

- The site header on `/` and `/developers` now renders the requesting
  organization's logo and name.
  ([#563](https://github.com/The-Verscienta/kiln_cms/issues/563), [#662](https://github.com/The-Verscienta/kiln_cms/issues/662), [#656](https://github.com/The-Verscienta/kiln_cms/issues/656) · [long form](docs/changelog/v0.5.0.md#the-site-header-on-and-developers-now-renders-the-requesting-organizations-logo))

- **Embeddable forms no longer default to `frame-ancestors *`.**
  ([#562](https://github.com/The-Verscienta/kiln_cms/issues/562) · [long form](docs/changelog/v0.5.0.md#embeddable-forms-no-longer-default-to-frame-ancestors))

- A malformed `EMBED_ORIGINS` now closes the policy instead of widening it.
  ([#562](https://github.com/The-Verscienta/kiln_cms/issues/562) · [long form](docs/changelog/v0.5.0.md#a-malformed-embedorigins-now-closes-the-policy-instead-of-widening-it))

- An allowlist now keeps `'self'`.
  ([#562](https://github.com/The-Verscienta/kiln_cms/issues/562) · [long form](docs/changelog/v0.5.0.md#an-allowlist-now-keeps-self))

## [0.1.0]

Long form: [docs/changelog/v0.1.0.md](docs/changelog/v0.1.0.md) —
the 0.1.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

First tagged release. Everything before this point shipped untagged on `main`;
downstream projects pinned arbitrary SHAs, and there was no way for a deployed
instance to say which Kiln it was running.

This release adds no features of its own — it establishes the version baseline
that `mix kiln.update` compares against.

### Upgrade notes

- If your project pins a SHA from before this tag, your first update is the only
  one that can't be described by a changelog diff.
  ([long form](docs/changelog/v0.1.0.md#if-your-project-pins-a-sha-from-before-this-tag-your-first-update-is-the-only))

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.5.0
[0.1.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.1.0
