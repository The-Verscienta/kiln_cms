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

## [1.2.0] - 2026-10-10

Long form: [docs/changelog/v1.2.0.md](docs/changelog/v1.2.0.md) —
the 1.2.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Building from source now needs Elixir 1.20.4 / OTP 29.1.1 (and Node
  22.23.3 for the assets); move your project's `.tool-versions` to match
  before `mix kiln.update`.**
  ([long form](docs/changelog/v1.2.0.md#building-from-source-needs-elixir-1-20))

### Added

- **`docs/system-requirements.md`: what a machine needs to run, build and
  develop Kiln, plus three deployment presets under `deploy/presets/`.**
  ([#1931](https://github.com/The-Verscienta/kiln_cms/issues/1931) · [long form](docs/changelog/v1.2.0.md#system-requirements))

- **`mix kiln.import.ghost` imports a Ghost JSON export: posts, pages, tags,
  images, SEO fields and bylines, members-only posts kept gated, and a
  redirect from every old URL.**
  ([#1876](https://github.com/The-Verscienta/kiln_cms/issues/1876) · [long form](docs/changelog/v1.2.0.md#mix-kiln-import-ghost))

- **The importers run from a release: `bin/kiln_cms rpc
  'KilnCMS.Release.import_wordpress(path, dry_run: true)'`, and likewise
  `import_ghost/2` and `import_content/2`.**
  ([long form](docs/changelog/v1.2.0.md#importers-from-a-release))

- **Public "Kiln vs" pages for WordPress, Ghost, Strapi, Payload and Directus,
  plus WordPress and Ghost migration guides, every competitor claim dated
  and sourced.**
  ([#1876](https://github.com/The-Verscienta/kiln_cms/issues/1876) · [long form](docs/changelog/v1.2.0.md#kiln-vs-pages-and-migration-guides))

- **A *Newsletter sign-up* block puts an email sign-up on any page; it adds
  people to the newsletter list with double opt-in.**
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870) · [long form](docs/changelog/v1.2.0.md#newsletter-signup-block))

### Changed

- **The toolchain moves to Elixir 1.20.4 / OTP 29.1.1 and Node 22.23.3 in CI
  and the release image; building from source now needs Elixir 1.20+.**
  ([#1934](https://github.com/The-Verscienta/kiln_cms/issues/1934) · [long form](docs/changelog/v1.2.0.md#toolchain-elixir-1-20-otp-29))

- **`docs/path-forward.md` sets Kiln's direction from 1.1 (live delivery plus
  provable, governed publishing) and the 2.0, 3.0 and 4.0 milestones.**
  ([#1924](https://github.com/The-Verscienta/kiln_cms/issues/1924) · [long form](docs/changelog/v1.2.0.md#path-forward))

- **Custom fields sit in the editor's main column, under the blocks, instead
  of behind the inspector's Settings tab.**
  ([#1916](https://github.com/The-Verscienta/kiln_cms/pull/1916) · [long form](docs/changelog/v1.2.0.md#custom-fields-under-the-blocks))

- **The newsletter's sign-up and unsubscribe pages render in the site's own
  layout instead of as bare unstyled pages.**
  ([long form](docs/changelog/v1.2.0.md#newsletter-pages-in-site-chrome))

### Fixed

- **The plugin docs no longer promise Hex or git-dependency plugins: a plugin
  compiles only as a `projects/<name>/` directory, and is shared as a git
  repository a site vendors there.**
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909))

### Security

- **decimal 3.2.0 for EEF-CVE-2026-97853: `Decimal.round/3` no longer
  allocates without bound on a caller-chosen `places`.**
  ([#1933](https://github.com/The-Verscienta/kiln_cms/issues/1933) · [long form](docs/changelog/v1.2.0.md#decimal-3-2-0-round-allocation))

- **Ash 3.34.6: an MCP read tool's `count`/`exists`/`aggregate` result no
  longer skips related resources' read policies in its filter.**
  ([long form](docs/changelog/v1.2.0.md#ash-3-34-6-aggregate-policies))

## [1.1.0] - 2026-10-06

Long form: [docs/changelog/v1.1.0.md](docs/changelog/v1.1.0.md) —
the 1.1.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Search now needs PostgreSQL's `unaccent` extension; the upgrade migration
  installs it, refolds non-ASCII search rows and rebuilds the title indexes.**
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628) · [long form](docs/changelog/v1.1.0.md#search-now-needs-postgresqls-unaccent-extension))

- **The upgrade writes a link edge for every stored `:reference` custom field
  value; after restoring a pre-1.1 backup, run `mix kiln.links.backfill`.**
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594) · [long form](docs/changelog/v1.1.0.md#reference-edges-backfill))

### Added

- **`/editor/organize`: semantic clusters, bulk tag review, an under-organized
  queue, taxonomy health and search gaps — only with semantic search on.**
  ([#1596](https://github.com/The-Verscienta/kiln_cms/issues/1596) · [long form](docs/changelog/v1.1.0.md#derived-organization-at-editororganize))

- **The structure view flags published documents that no menu links to.**
  ([#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597) · [long form](docs/changelog/v1.1.0.md#the-structure-view-flags-published-documents-no-menu-links-to))

- **A structure view for arranging a content tree: drag to reorder, indent to
  nest, reachable from the content list for one type at a time.**
  ([#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597) · [long form](docs/changelog/v1.1.0.md#a-structure-view-for-arranging-a-content-tree))

- **A document's URL can follow the content tree: an `[ancestors]` alias token,
  and moving a section re-derives the paths beneath it without overwriting
  hand-written ones.**
  ([#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597) · [long form](docs/changelog/v1.1.0.md#a-documents-url-can-follow-the-content-tree))

- **Documents can sit under one another: set a parent from the content editor,
  with cycles, cross-site parents and anything nesting past five levels
  refused.**
  ([#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597) · [long form](docs/changelog/v1.1.0.md#documents-can-sit-under-one-another-the-content-tree))

- **System → Plugins says what each plugin adds — its blocks, field types, pages
  and content types by name — and flags a plugin with no summary.**
  ([#1888](https://github.com/The-Verscienta/kiln_cms/issues/1888))

- **The content list filters by author, category, tag, language, update date
  and review health, sorts by update, publish date or title, and saves a
  filter as a named view.**
  ([#1854](https://github.com/The-Verscienta/kiln_cms/issues/1854) · [long form](docs/changelog/v1.1.0.md#the-content-list-filters-and-saves-views))

- **On Fly.io, Railway and DigitalOcean, rate limits can be per visitor:
  `CLIENT_IP_HEADER` reads the platform proxy's own client-address header.**
  ([#1548](https://github.com/The-Verscienta/kiln_cms/issues/1548) · [long form](docs/changelog/v1.1.0.md#on-fly-io-railway-and-digitalocean-rate-limits-can-be-per-visitor))

- **`:reference` custom fields are also `ContentLink` edges: *Linked from* in
  the editor, broken-reference warnings, and `incoming_links` on the API.**
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594) · [long form](docs/changelog/v1.1.0.md#reference-fields-are-also-link-edges))

- **Field-level localization: a field can be shared across a document's
  locale variants, or inherited along the site's fallback chain when empty.**
  ([#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327) · [#1860](https://github.com/The-Verscienta/kiln_cms/issues/1860) · [long form](docs/changelog/v1.1.0.md#field-level-localization))

- **Plugin blocks get editor seams: their own label, icon and description,
  field hints, a row editor for `item_keys:` list fields, and live rendering.**
  ([#1865](https://github.com/The-Verscienta/kiln_cms/pull/1865) · [long form](docs/changelog/v1.1.0.md#plugin-blocks-get-editor-seams))

- **Each published GitHub release now becomes a page on kilncms.dev at
  `/releases/<version>`, listed at `/releases`.**
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870) · [long form](docs/changelog/v1.1.0.md#each-published-github-release-now-becomes-a-page-on-kilncmsdev-at))

- **Each site can publish a `/.well-known/security.txt` (RFC 9116), set by an
  admin at Configure → Organization → Security contact.**
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873) · [long form](docs/changelog/v1.1.0.md#each-site-can-publish-a-well-knownsecuritytxt-rfc-9116-set-by-an-admin-at))

### Changed

- **The content list opens on a count per stage, rows show author, type and last
  update with one next step up front, and bulk actions appear on selection.**
  ([#1904](https://github.com/The-Verscienta/kiln_cms/issues/1904))

- **Searchable custom fields are indexed as text: HTML stripped, entities
  decoded, and a project extractor can decode JSON, pick keys and set order.**
  ([#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585) · [long form](docs/changelog/v1.1.0.md#searchable-custom-fields-are-indexed-as-text))

- **Re-indexing search text and storing an embedding no longer move a
  document's `updated_at`.**
  ([#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585) · [long form](docs/changelog/v1.1.0.md#re-indexing-no-longer-moves-updated-at))

- **The update check asks kilncms.dev's release feed first and lists the
  release's highlights; GitHub is the fallback, and forks skip the feed.**
  ([#1877](https://github.com/The-Verscienta/kiln_cms/issues/1877) · [long form](docs/changelog/v1.1.0.md#the-update-check-asks-kilncms-devs-release-feed-first))

- **The sync API's first page stays under 15 ms p95 from 10
  concurrent clients, where it took 31–57 ms.** Same response, byte for
  byte.
  ([#1713](https://github.com/The-Verscienta/kiln_cms/issues/1713) · [long form](docs/changelog/v1.1.0.md#the-sync-apis-first-page-stays-under-15-ms-p95-from-10-concurrent))

- **Search ranks faster under load: the query is parsed once per statement,
  not once per matching row, and `/api/search` skips an empty entries section.**
  ([#1725](https://github.com/The-Verscienta/kiln_cms/issues/1725) · [long form](docs/changelog/v1.1.0.md#search-ranks-faster-under-load))

- **Every release candidate is canaried on kilncms.dev before the final, and
  the headless API guides carry examples that run against it anonymously.**
  ([#1869](https://github.com/The-Verscienta/kiln_cms/issues/1869) · [#1872](https://github.com/The-Verscienta/kiln_cms/issues/1872) · [long form](docs/changelog/v1.1.0.md#release-candidates-are-canaried-on-kilncms-dev))

### Fixed

- **The editor's tag suggestions no longer fail on an org with more unindexed
  tags than the editor's embedding window, or use up that window on refusals.**
  ([#1596](https://github.com/The-Verscienta/kiln_cms/issues/1596) · [long form](docs/changelog/v1.1.0.md#tag-suggestions-on-a-large-unindexed-taxonomy))

- **Search folds diacritics: `Zusanli` finds `Zúsānlǐ`, `creme brulee` finds
  `Crème brûlée`, in every full-text leg.**
  ([#1628](https://github.com/The-Verscienta/kiln_cms/issues/1628) · [long form](docs/changelog/v1.1.0.md#search-folds-diacritics))

- **A custom field flagged `searchable` is indexed with the record's text, so
  search finds a record by a Chinese name or a Latin binomial.**
  ([#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585) · [long form](docs/changelog/v1.1.0.md#a-custom-field-flagged-searchable-is-indexed))

- **CI no longer fails at random with "type `_oban_job_state` can not be
  handled": the suite loads every database type before its first test.**
  ([#1796](https://github.com/The-Verscienta/kiln_cms/issues/1796) · [long form](docs/changelog/v1.1.0.md#ci-no-longer-fails-at-random-with-type-oban-job-state-can-not-be))

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  ([#1851](https://github.com/The-Verscienta/kiln_cms/issues/1851) · [long form](docs/changelog/v1.1.0.md#concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own))

- **An overlay's composed suite no longer fails the session-salt and
  system-actor scope tests on a correct configuration.**
  ([#1866](https://github.com/The-Verscienta/kiln_cms/pull/1866) · [long form](docs/changelog/v1.1.0.md#an-overlays-composed-suite-no-longer-fails-the-session-salt-and-system-actor))

- **A plugin's console panels no longer need a copy of the core's surface test
  in an overlay's composed suite.**
  ([#1864](https://github.com/The-Verscienta/kiln_cms/issues/1864) · [long form](docs/changelog/v1.1.0.md#a-plugins-console-panels-no-longer-need-a-copy-of-the-cores-surface-test))

### Security

- **`ash` 3.34.4 closes an atom-table exhaustion advisory (EEF-CVE-2026-94201,
  HIGH); no untrusted filter path onto the affected attribute was found in
  Kiln.**
  ([long form](docs/changelog/v1.1.0.md#ash-3344-closes-an-atom-table-exhaustion-advisory))

- **A content link is readable only by someone who may read both of its ends;
  `incoming_links` no longer names the drafts that link to a published page.**
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594) · [long form](docs/changelog/v1.1.0.md#content-links-readable-only-when-both-ends-are))

## [1.0.0] - 2026-10-02

Long form: [docs/changelog/v1.0.0.md](docs/changelog/v1.0.0.md) —
the 1.0.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **1.0 is a major version: move to it with `mix kiln.update --allow-major`,
  from 0.12.1, after 0.12's own upgrade steps.**
  ([#1545](https://github.com/The-Verscienta/kiln_cms/issues/1545) · [long form](docs/changelog/v1.0.0.md#upgrade-to-1-0-with-allow-major-from-0-12))

- **Set this deployment's own session salts if you still use the shipped
  defaults; changing them signs everyone out once.**
  ([#1536](https://github.com/The-Verscienta/kiln_cms/issues/1536) · [long form](docs/changelog/v1.0.0.md#set-deployment-specific-session-salts))

- **Upgrading revokes nothing by itself: if an account changed or reset its
  password on an earlier release because it may have leaked, do it again (or
  use *Sign out everywhere*).**
  ([#734](https://github.com/The-Verscienta/kiln_cms/issues/734) · [long form](docs/changelog/v1.0.0.md#password-rotation-upgrade-revokes-nothing-retroactively))

- **A new index on every content table's titles is built `CONCURRENTLY` by the
  migration; if it is interrupted, drop the invalid index and migrate again.**
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712) · [long form](docs/changelog/v1.0.0.md#a-new-index-on-every-content-tables-titles-is-built-concurrently-by-the))

- **Jobs already stuck `executing` from earlier deploys run again (or are
  discarded) within a minute of upgrading.**
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718) · [long form](docs/changelog/v1.0.0.md#jobs-already-stuck-executing-from-earlier-deploys-run-again-or-are-discarded))

- **Run `mix kiln.org_slugs` to find organizations whose slug can't be a hostname.**
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710) · [long form](docs/changelog/v1.0.0.md#run-mix-kilnorgslugs-to-find-organizations-whose-slug-cant-be-a-hostname))

- **On a multi-org deployment with `KILN_CONSOLE_HOST` set, add
  `*.<console host>` to DNS and TLS before upgrading.**
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688) · [long form](docs/changelog/v1.0.0.md#on-a-multi-org-deployment-with-kiln_console_host-set-add-console-host-to-dns))

- **Before upgrading to 1.0, run `mix kiln.blocks.backfill` on 0.12, and move any
  code that writes legacy `type`/`content`/`data` blocks to the typed shape.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#before-upgrading-to-10-run-the-block-backfill))

- **On 0.12, before `mix kiln.update --allow-major` to 1.0: run the block
  backfill and `mix kiln.deprecations --migrate-audiences`, and drain the queue.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#on-012-before-upgrading-to-10))

- **Review webhook endpoints marked *Receives unpublished content* under
  `/editor/webhooks`; untick the draft events on any that shouldn't get drafts.**
  ([#1776](https://github.com/The-Verscienta/kiln_cms/issues/1776) · [long form](docs/changelog/v1.0.0.md#review-webhook-endpoints-that-receive-unpublished-content))

- **Public links now use `https://<PHX_HOST>`; set `PUBLIC_BASE_URL` if your
  public site is served from a different origin.**
  ([#1833](https://github.com/The-Verscienta/kiln_cms/issues/1833) · [long form](docs/changelog/v1.0.0.md#public-links-now-use-phx-host))

- **Tell authors that Save draft on a published entry now holds every content
  field until *Publish changes*; a webhook receiver hears `<type>.updated`
  when the changes are published, not when they are saved.**
  ([#1815](https://github.com/The-Verscienta/kiln_cms/issues/1815) · [long form](docs/changelog/v1.0.0.md#save-draft-holds-content-fields-until-publish-changes))

- **Treat sign-in links shown in mail delivery errors from an earlier release
  as exposed.** The upgrade scrubs them from stored jobs, but not from logs or
  Sentry.
  ([#1843](https://github.com/The-Verscienta/kiln_cms/issues/1843) · [long form](docs/changelog/v1.0.0.md#treat-sign-in-links-in-old-mail-errors-as-exposed))

### Breaking

- **On a multi-org install with `KILN_CONSOLE_HOST` set, each non-default
  org's console moves to `<slug>.<console host>`: add wildcard DNS and a
  wildcard TLS certificate for `*.<console host>` before upgrading.**
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688) · [long form](docs/changelog/v1.0.0.md#on-a-multi-org-install-with-kiln_console_host-set-each-non-default-orgs-console))

- **Remove `TypedBlocks.to_legacy/1`, `TypedBlocks.from_legacy/1` and
  `KilnCMS.CMS.Block`; use `to_typed/1` and render from typed blocks.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#remove-the-legacy-block-bridge-functions))

- **Refuse a block written in the legacy `type`/`content`/`data` shape; stored
  rows in that shape are still read.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#refuse-the-legacy-block-write-shape))

- **Remove the `published?:` option on `use KilnCMS.CMS.Content`; passing it now
  warns as an unknown option.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#remove-the-published-option))

- **Remove the `/editor/pages/:id` and `/editor/posts/:id` editor routes; each
  now answers with a `301` to `/editor/content/page|post/:id`.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#remove-the-editor-route-aliases))

- **Remove the `User.audiences` fallback for accounts with no membership; a job
  on every boot moves such accounts onto a default-organization membership.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#remove-the-user-audiences-fallback))

- **Stop running webhook and newsletter jobs queued in a pre-0.12 argument
  shape; each is cancelled with an error in the log.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#stop-running-pre-012-job-shapes))

### Added

- **A keyboard shortcut list opens from the account menu or with "?", and
  the calendar's colour key has a "?" that explains every lane and health
  pill.**
  ([#1839](https://github.com/The-Verscienta/kiln_cms/issues/1839) · [long form](docs/changelog/v1.0.0.md#keyboard-shortcuts-and-calendar-key))

- **The calendar's Lane and Health filters and the Tasks page's Anchored to
  filter each have a "?" button that explains them in a sentence or two.**
  ([#1822](https://github.com/The-Verscienta/kiln_cms/issues/1822) · [long form](docs/changelog/v1.0.0.md#console-help-tips))

- **Reorder a content type's custom fields by dragging them, or with the
  arrow buttons, on `/editor/fields`; the editor shows them in that order.**
  ([#1818](https://github.com/The-Verscienta/kiln_cms/issues/1818) · [long form](docs/changelog/v1.0.0.md#reorder-custom-fields-by-dragging-them))

- **The logo, favicon, social image and app icon on the Branding page can be
  chosen from the media library or uploaded there, with a thumbnail.**
  ([#1811](https://github.com/The-Verscienta/kiln_cms/issues/1811) · [long form](docs/changelog/v1.0.0.md#branding-images-from-the-media-library))

- **Every password box on the sign-in, register, reset-password, setup and
  change-password forms has an eye button that shows what you typed.**
  ([#1806](https://github.com/The-Verscienta/kiln_cms/issues/1806) · [long form](docs/changelog/v1.0.0.md#password-reveal-toggle))

- **The content editor has a Blocks | Markdown switch: edit the body as
  Markdown, and it comes back as blocks.**
  ([#1734](https://github.com/The-Verscienta/kiln_cms/issues/1734) · [long form](docs/changelog/v1.0.0.md#editor-markdown-view))

- **`mix kiln.migrations.check` fails a PR whose new migration breaks the
  release still serving mid-deploy.**
  ([#1716](https://github.com/The-Verscienta/kiln_cms/issues/1716) · [long form](docs/changelog/v1.0.0.md#mix-kilnmigrationscheck-gates-expand-contract))

- **Rich-text blocks turn lists into real lists: typed with "•" or "1)", pasted
  as bullet characters (a PDF, an email), or pasted from Word with nesting
  kept.**
  ([#1729](https://github.com/The-Verscienta/kiln_cms/issues/1729))

- **Editing in place can add a paragraph, heading or quote between blocks or at
  the end of the page.**
  ([#1801](https://github.com/The-Verscienta/kiln_cms/issues/1801) · [long form](docs/changelog/v1.0.0.md#editing-in-place-can-add-blocks))

- **Add a new tag or category without leaving the content editor.**
  ([#1805](https://github.com/The-Verscienta/kiln_cms/issues/1805) · [long form](docs/changelog/v1.0.0.md#add-tags-and-categories-from-the-editor))

- **Settings lists where you are signed in, and signs out one session or every
  other one.**
  ([#1823](https://github.com/The-Verscienta/kiln_cms/issues/1823) · [long form](docs/changelog/v1.0.0.md#settings-lists-your-active-sessions))

- **Start new content from a day on the calendar: press its "+", choose a type,
  and the editor opens with that day as the publish date (a proposed date, for
  editors who may not publish, that an admin confirms).**
  ([#1812](https://github.com/The-Verscienta/kiln_cms/issues/1812) · [long form](docs/changelog/v1.0.0.md#new-content-on-a-calendar-day))

### Changed

- **The console points the way when something is empty or unset: Tasks,
  the overview's Structure card, the account menu's API links and the
  governance witness panel each say what to do next.**
  ([#1840](https://github.com/The-Verscienta/kiln_cms/issues/1840), [#1841](https://github.com/The-Verscienta/kiln_cms/issues/1841), [#1842](https://github.com/The-Verscienta/kiln_cms/issues/1842), [#1845](https://github.com/The-Verscienta/kiln_cms/issues/1845) · [long form](docs/changelog/v1.0.0.md#console-next-steps))

- **Creating a content type goes straight on to its fields, with the new type
  ticked; the fields form shows Options and Default value only for the field
  types that use them.**
  ([#1817](https://github.com/The-Verscienta/kiln_cms/issues/1817), [#1819](https://github.com/The-Verscienta/kiln_cms/issues/1819), [#1820](https://github.com/The-Verscienta/kiln_cms/issues/1820) · [long form](docs/changelog/v1.0.0.md#a-new-content-type-goes-straight-on-to-its-fields))

- **Keep `RichText.legacy_html` as a fallback instead of removing it;
  the nested column editor now stores Portable Text.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#keep-legacy-html-as-a-fallback))

- **Automation rules are set up with ordinary fields instead of a JSON box.**
  ([long form](docs/changelog/v1.0.0.md#automation-rules-are-set-up-with-ordinary-fields-instead-of-a-json-box))

- **The automation builder reads as steps and says each rule back as a
  sentence.**
  ([long form](docs/changelog/v1.0.0.md#the-automation-builder-reads-as-steps-and-says-each-rule-back-as-a-sentence))

- **The automation builder offers ready-made recipes and a preview on real
  content.**
  ([long form](docs/changelog/v1.0.0.md#the-automation-builder-offers-ready-made-recipes-and-a-preview-on-real-content))

- **Console lists share one empty state; long settings pages get a table of
  contents; screen crumbs point at their real parent.**
  ([#1678](https://github.com/The-Verscienta/kiln_cms/issues/1678) · [#1680](https://github.com/The-Verscienta/kiln_cms/issues/1680) · [long form](docs/changelog/v1.0.0.md#console-lists-share-one-empty-state-long-settings-pages-get-a-table-of-contents))

- **The release image's `latest` tag moves only to the highest final release,
  and from 1.0.0 a floating major tag (`1`) follows the highest final release of
  its major.**
  ([#1544](https://github.com/The-Verscienta/kiln_cms/issues/1544) · [long form](docs/changelog/v1.0.0.md#the-release-images-latest-tag-moves-only-to-the-highest-final-release-and-from))

- **The content editor's chrome is on the component kit: the inspector is a
  keyboard-driven tab strip, and block controls show on focus and on touch.**
  ([#1679](https://github.com/The-Verscienta/kiln_cms/issues/1679) · [long form](docs/changelog/v1.0.0.md#the-content-editors-chrome-is-on-the-component-kit))

- **`mix kiln.authz.check` accepts only an `# authorize?: false — <reason>`
  marker directly above a bypass; prose that mentions "bypass" no longer
  counts.**
  ([#1739](https://github.com/The-Verscienta/kiln_cms/issues/1739) · [long form](docs/changelog/v1.0.0.md#authz-check-requires-a-marker))

- **The ⌘K search palette leads with a *Best match* row when a title is
  exactly what was typed.**
  ([#1781](https://github.com/The-Verscienta/kiln_cms/issues/1781) · [long form](docs/changelog/v1.0.0.md#the-search-palette-leads-with-an-exact-title-match))

- **In development, a stale or missing asset build is reported at boot and on
  the console, with the command that rebuilds it.**
  ([#1761](https://github.com/The-Verscienta/kiln_cms/issues/1761) · [long form](docs/changelog/v1.0.0.md#a-stale-local-asset-build-is-reported-in-development))

- **A Coolify build records the commit it deployed: turn on *Include Source
  Commit in Build* and the Dockerfile uses Coolify's `SOURCE_COMMIT`.**
  ([#1799](https://github.com/The-Verscienta/kiln_cms/issues/1799) · [long form](docs/changelog/v1.0.0.md#coolify-build-records-its-commit))

### Fixed

- **The overview's Forms and Webhooks cards say what each feature is, and
  show a count, a first step, or that an admin runs it, instead of a blank
  "—".**
  ([#1825](https://github.com/The-Verscienta/kiln_cms/issues/1825) · [long form](docs/changelog/v1.0.0.md#overview-cards-explain-themselves))

- **"View site" opens the public site in a new tab and says so, including
  on a deployment with its own console host.**
  ([#1827](https://github.com/The-Verscienta/kiln_cms/issues/1827) · [long form](docs/changelog/v1.0.0.md#view-site-opens-the-site))

- **Settings says what the display name is for and confirms a save beside the
  button; Passkeys says whether any are set up and shows the browser prompt.**
  ([#1828](https://github.com/The-Verscienta/kiln_cms/issues/1828), [#1829](https://github.com/The-Verscienta/kiln_cms/issues/1829) · [long form](docs/changelog/v1.0.0.md#settings-profile-and-passkey-feedback))

- **A content type's URL segment keeps following its machine name until you
  edit the segment yourself.**
  ([#1816](https://github.com/The-Verscienta/kiln_cms/issues/1816) · [long form](docs/changelog/v1.0.0.md#the-url-segment-follows-the-machine-name))

- **Production sitemaps, feeds, canonical links, preview links and newsletter
  confirmation emails link to `https://<PHX_HOST>`, not `http://localhost:4000`.**
  ([#1833](https://github.com/The-Verscienta/kiln_cms/issues/1833) · [long form](docs/changelog/v1.0.0.md#production-public-links-use-phx-host))

- **"We can't find the internet" and "Something went wrong!" no longer flash on
  a first page load; they wait until a connection problem has lasted a few
  seconds, and offer *Try again*.**
  ([#1821](https://github.com/The-Verscienta/kiln_cms/issues/1821) · [long form](docs/changelog/v1.0.0.md#connection-notices-wait-out-a-slow-first-connection))

- **Save draft on a published entry no longer puts any field live; *Publish
  changes* or a release publishes every saved change at once.**
  ([#1815](https://github.com/The-Verscienta/kiln_cms/issues/1815) · [long form](docs/changelog/v1.0.0.md#save-draft-on-a-published-entry-holds-every-content-field))

- **A new brand colour shows as soon as Branding is saved, with a button and
  link preview in light and dark mode and help text that says where it is used.**
  ([#1810](https://github.com/The-Verscienta/kiln_cms/issues/1810) · [long form](docs/changelog/v1.0.0.md#brand-colour-shows-on-save))

- **Markdown switched back to Blocks, or imported from a `.md` file, becomes
  heading, divider and one text block per section, not one long text block.**
  ([#1800](https://github.com/The-Verscienta/kiln_cms/issues/1800) · [long form](docs/changelog/v1.0.0.md#markdown-becomes-heading-divider-and-text-blocks))

- **The media library says how many files one upload takes, shows that
  uploaded files are still being processed, and ties its URL field to its
  label.**
  ([#1802](https://github.com/The-Verscienta/kiln_cms/issues/1802), [#1803](https://github.com/The-Verscienta/kiln_cms/issues/1803), [#1804](https://github.com/The-Verscienta/kiln_cms/issues/1804) · [long form](docs/changelog/v1.0.0.md#media-uploads-state-their-limit-and-show-processing))

- **Accessibility: repeated row actions in the console name the record they act
  on, the Translations table names each control's content and locale, and the
  calendar filters are announced by their label alone.**
  ([#1774](https://github.com/The-Verscienta/kiln_cms/issues/1774) · [long form](docs/changelog/v1.0.0.md#repeated-row-actions-name-the-record-they-act-on))

- **On a multi-locale site, `/fr/blog` lists the posts `/fr/blog/<slug>`
  serves, and every article keeps its language switcher.**
  ([#1765](https://github.com/The-Verscienta/kiln_cms/issues/1765) · [long form](docs/changelog/v1.0.0.md#the-blog-index-follows-the-locale-fallback-chain))

- **The seeded demo page and post, and the beta-round sandbox posts, no longer
  print their title twice.**
  ([#1767](https://github.com/The-Verscienta/kiln_cms/issues/1767) · [long form](docs/changelog/v1.0.0.md#seeded-content-no-longer-prints-its-title-twice))

- **Submitting the same piece for review twice no longer leaves the reviewer
  two identical inbox rows.**
  ([#1785](https://github.com/The-Verscienta/kiln_cms/issues/1785) · [long form](docs/changelog/v1.0.0.md#a-repeated-review-request-is-one-inbox-row-while-unread))

- **A newsletter with no confirmed subscriber to send to is refused, and the
  Send button says so.**
  ([#1775](https://github.com/The-Verscienta/kiln_cms/issues/1775) · [long form](docs/changelog/v1.0.0.md#a-newsletter-with-no-confirmed-subscriber-is-refused))

- **A custom field whose content type no longer exists no longer crashes the
  Fields screen; it is listed as orphaned, with a delete.**
  ([#1770](https://github.com/The-Verscienta/kiln_cms/issues/1770) · [long form](docs/changelog/v1.0.0.md#a-custom-field-whose-content-type-no-longer-exists-no-longer-crashes-the-fields))

- **A new API key acts as the signed-in admin unless another owner is picked;
  it no longer defaults to whichever account is listed first.**
  ([#1771](https://github.com/The-Verscienta/kiln_cms/issues/1771) · [long form](docs/changelog/v1.0.0.md#a-new-api-key-acts-as-the-signed-in-admin-by-default))

- **The Forms list shows each form's addresses that actually answer — the
  hosted page, a copyable embed snippet and the JSON API — instead of a
  `/forms/:slug` that 404s.**
  ([#1783](https://github.com/The-Verscienta/kiln_cms/issues/1783) · [long form](docs/changelog/v1.0.0.md#the-forms-list-shows-addresses-that-answer))

- **A site integration with no saved settings (storage, mail, SSO, search, AI)
  shows its enable toggle off, matching its status.**
  ([#1780](https://github.com/The-Verscienta/kiln_cms/issues/1780) · [long form](docs/changelog/v1.0.0.md#unconfigured-integrations-show-their-enable-toggle-off))

- **Sending a test email from Mail says "Test email sent to …" or why it failed,
  instead of printing the delivery adapter's raw result.**
  ([#1779](https://github.com/The-Verscienta/kiln_cms/issues/1779) · [long form](docs/changelog/v1.0.0.md#the-mail-test-send-reports-in-a-sentence))

- **Admin console wording: Home's backup notice says schedules are set by the
  operator, Content types has a browser title, Funnels' back link goes to
  Capture, and form row buttons name their form.**
  ([#1772](https://github.com/The-Verscienta/kiln_cms/issues/1772) · [long form](docs/changelog/v1.0.0.md#admin-console-wording-fixes-from-beta-round-2))

- **`mix kiln.gen.content --from` works under strict tenancy, and takes
  `--org SLUG`.**
  ([#1743](https://github.com/The-Verscienta/kiln_cms/issues/1743) · [long form](docs/changelog/v1.0.0.md#mix-kiln-gen-content-from-works-under-strict-tenancy))

- **Per-type semantic search ranks a record the query names first, however long
  the record.**
  ([#1746](https://github.com/The-Verscienta/kiln_cms/pull/1746) · [long form](docs/changelog/v1.0.0.md#per-type-semantic-search-ranks-a-record-the-query-names-first))

- **An empty heading line in a rich-text block is now visible in the editor —
  dashed, labelled with its level — so the "heading has no text" finding has
  something on screen to point at.**
  ([#1728](https://github.com/The-Verscienta/kiln_cms/issues/1728))

- **An SEO or accessibility finding below a fragment names, and jumps to, the
  right block.**
  ([#1731](https://github.com/The-Verscienta/kiln_cms/pull/1731) · [long form](docs/changelog/v1.0.0.md#a-seo-or-accessibility-finding-below-a-fragment-names-and-jumps-to-the-right))

- **Search holds at most two pooled connections, and answers `503` rather than
  `500` when the pool is full.**
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712) · [long form](docs/changelog/v1.0.0.md#search-holds-at-most-two-pooled-connections-and-answers-503-rather-than-500))

- **A job killed by a deploy's shutdown is rescued after three hours instead of
  staying `executing` for ever.**
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718) · [long form](docs/changelog/v1.0.0.md#a-job-killed-by-a-deploys-shutdown-is-rescued-after-three-hours-instead-of))

- **An organization's slug must be a hostname label, and is stored lowercase.**
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710) · [long form](docs/changelog/v1.0.0.md#an-organizations-slug-must-be-a-hostname-label-and-is-stored-lowercase))

- **A stored block of a type the build no longer has, or one that is not a
  block, no longer fails its page's delivery.**
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543) · [long form](docs/changelog/v1.0.0.md#unreadable-stored-blocks-no-longer-fail-delivery))

- **Edited images get new variants under strict tenancy, and a media job with no
  `org_id` is cancelled with a logged error instead of doing nothing silently.**
  ([#1658](https://github.com/The-Verscienta/kiln_cms/issues/1658) · [long form](docs/changelog/v1.0.0.md#a-media-job-with-no-org-id-is-cancelled-not-silently-skipped))

- **An old newsletter confirmation link no longer re-subscribes a reader who
  unsubscribed.**
  ([#1690](https://github.com/The-Verscienta/kiln_cms/issues/1690) · [long form](docs/changelog/v1.0.0.md#an-old-newsletter-confirmation-link-no-longer-re-subscribes))

- **Picking an image from the media library keeps the alt text written on it.**
  ([#1782](https://github.com/The-Verscienta/kiln_cms/issues/1782) · [long form](docs/changelog/v1.0.0.md#picking-a-library-image-keeps-its-alt-text))

- **The Form and Fragment blocks say what they are in the block picker.**
  ([#1760](https://github.com/The-Verscienta/kiln_cms/issues/1760) · [long form](docs/changelog/v1.0.0.md#form-and-fragment-blocks-say-what-they-are-in-the-block-picker))

- **A search highlight names the title once, not two or three times before
  the body.**
  ([#1758](https://github.com/The-Verscienta/kiln_cms/issues/1758) · [long form](docs/changelog/v1.0.0.md#a-search-highlight-names-the-title-once))

- **A page in the public search results shows why it matched.**
  ([#1766](https://github.com/The-Verscienta/kiln_cms/issues/1766) · [long form](docs/changelog/v1.0.0.md#a-page-in-public-search-results-shows-why-it-matched))

- **The reconnect toasts come down with the error they report; "We can't find
  the internet" no longer stays up beside "Something went wrong!".**
  ([#1784](https://github.com/The-Verscienta/kiln_cms/issues/1784) · [long form](docs/changelog/v1.0.0.md#the-reconnect-toasts-come-down-with-the-error-they-report))

- **The console keeps its two columns when the stylesheet lacks the sidebar
  width token.**
  ([#1755](https://github.com/The-Verscienta/kiln_cms/issues/1755) · [long form](docs/changelog/v1.0.0.md#the-console-keeps-its-two-columns-without-the-sidebar-width-token))

- **The database connection no longer logs `:ssl_opts is deprecated` on every
  boot and every `bin/kiln_cms eval`.**
  ([long form](docs/changelog/v1.0.0.md#the-database-connection-no-longer-logs-ssl-opts-deprecated))

### Security

- **Changing or resetting a password now signs out every other session and
  remember-me cookie.** Before, both kept working for up to 30 days.
  ([#734](https://github.com/The-Verscienta/kiln_cms/issues/734) · [#1637](https://github.com/The-Verscienta/kiln_cms/issues/1637) · [long form](docs/changelog/v1.0.0.md#password-rotation-revokes-every-session))

- **The editor's link advisory no longer reveals content the editor cannot read.**
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-editors-link-advisory-no-longer-reveals-content-the-editor-cannot-read))

- **`KILN_CONSOLE_HOST` now isolates every organization's console, each on its
  own `<slug>.<console host>` origin.**
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688) · [long form](docs/changelog/v1.0.0.md#kiln_console_host-now-isolates-every-organizations-console-each-on-its-own))

- **The newsletter sign-up honeypot and public forms trip on the same rule.**
  ([#1657](https://github.com/The-Verscienta/kiln_cms/issues/1657) · [long form](docs/changelog/v1.0.0.md#newsletter-sign-up-honeypot-matches-forms))

- **The accounts domain's system reads run under the policies.** The tenant
  list behind every all-orgs sweep can no longer be refused into a silent no-op.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#accounts-system-reads-run-under-the-policies))

- **Federation runs under the policies.** 24 more internal writes and reads run
  as scoped system actors; the replay check and follower ceiling fail closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#federation-runs-under-the-policies))

- **Notifications and Web Push run under the policies.** The task digest, a
  comment thread's recipients and push delivery run as scoped system actors;
  their lookups fail closed and a lost grant is logged, never a silent drop.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#notifications-and-web-push-run-under-the-policies))

- **Funnel lookups and the operator mix tasks run under the policies.** Funnel
  reads fail closed; the remaining mix-task bypasses each say why.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#funnel-lookups-and-the-operator-mix-tasks-run-under-the-policies))

- **The event log and the per-site settings run under the policies.** 17 more
  internal reads and writes run as system actors; those that decide fail closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#event-log-and-settings-run-under-the-policies))

- **Content releases, slugs, menus and the field registry run under the
  policies.** 37 CMS helper sites move to scoped system actors or the caller;
  a release's item read fails closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#cms-helpers-run-under-the-policies))

- **The CMS's own bookkeeping runs under the policies.** 26 sites in the
  content, comment, release and form changes move under the policies or say
  why not; the reads a write depends on fail closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-cmss-own-bookkeeping-runs-under-the-policies))

- **CMS validations look things up under the policies.** Eight reference
  checks read as the caller or a scoped system actor; a refused read rejects.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#cms-validations-look-things-up-under-the-policies))

- **The media pipeline and public forms run under the policies.** 18 more
  internal sites run as scoped system actors; the worker re-reads and field
  reads fail closed, and the quarantine reaper works under strict tenancy.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-media-pipeline-and-public-forms-run-under-the-policies))

- **The billing webhook pipeline runs under the policies.** A refused read no
  longer drops a payment event or recomputes a paying member to no access.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#billing-webhook-pipeline-runs-under-the-policies))

- **Webhooks, social posting and mail run under the policies.** Each uses a
  scoped system actor; the endpoint scan, the ledger re-read, the mail
  settings and the suppression lookups fail closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#webhooks-social-posting-and-mail-run-under-the-policies))

- **Content experiments run under the policies.** Delivery, the start guards
  and `mix kiln.experiment` use a scoped system actor, and
  every read behind an assignment or a result fails closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#content-experiments-run-under-the-policies))

- **The governance audit chain runs under the policies.** Anchors, checkpoints
  and the entitlement trail are read and written as a scoped system actor, and
  every one of those reads fails closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-governance-audit-chain-runs-under-the-policies))

- **The link checker runs under the policies.** 16 more internal sites run as
  a scoped system actor or carry a written reason; the counter reads fail closed.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-link-checker-runs-under-the-policies))

- **The newsletter send pipeline runs under the policies, which empties the
  authz backlog.** A refused subscriber or campaign read now retries instead
  of mailing nobody and marking the campaign sent.
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) · [long form](docs/changelog/v1.0.0.md#the-newsletter-send-pipeline-runs-under-the-policies-which-empties-the-authz-backlog))

- **Each system-actor grant now names the subsystems it admits.** One worker's
  grant is no longer every worker's; no behaviour changes for users.
  ([#1747](https://github.com/The-Verscienta/kiln_cms/issues/1747) · [long form](docs/changelog/v1.0.0.md#each-system-actor-grant-now-names-the-subsystems-it-admits))

- **A webhook added in the console no longer receives unpublished drafts
  unless an admin selects those events.** The form ticked every event.
  ([#1776](https://github.com/The-Verscienta/kiln_cms/issues/1776) · [long form](docs/changelog/v1.0.0.md#a-webhook-added-in-the-console-no-longer-receives-unpublished-drafts))

- **Sign-in links no longer leak into stored mail job errors, logs or
  Sentry.** A crashing mailer recorded the whole email, link included.
  ([#1843](https://github.com/The-Verscienta/kiln_cms/issues/1843) · [long form](docs/changelog/v1.0.0.md#sign-in-links-no-longer-leak-into-mail-job-errors))

## [0.12.1] - 2026-09-30

Long form: [docs/changelog/v0.12.1.md](docs/changelog/v0.12.1.md) —
the 0.12.1 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Fixed

- **An overlay that registers its own domain through its plugin no longer fails
  the core's "configured domains" test in its composed suite.**
  ([#1786](https://github.com/The-Verscienta/kiln_cms/pull/1786) · [long form](docs/changelog/v0.12.1.md#an-overlays-composed-suite-no-longer-fails-the-configured-domains-test))

### Security

- **`mint` 1.11.0 closes three advisories: HTTP/1 response smuggling and two
  HTTP/2 client memory exhaustions (EEF-CVE-2026-91043 HIGH, -92103, -94194).**
  ([#1722](https://github.com/The-Verscienta/kiln_cms/pull/1722) · [long form](docs/changelog/v0.12.1.md#mint-1110-closes-three-advisories-http1-response-smuggling-and-two-http2))

## [0.12.0] - 2026-09-27

Long form: [docs/changelog/v0.12.0.md](docs/changelog/v0.12.0.md) —
the 0.12.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Before upgrading to 1.0, let queued webhook and newsletter jobs from before
  0.12 drain, and move accounts off the legacy audiences fallback;
  `mix kiln.deprecations` says what is left.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#before-upgrading-to-10-let-queued-webhook-and-newsletter-jobs-from-before-012))

- **Run `mix kiln.blocks.backfill` once after deploying. It is safe on the live
  site, and it rewrites stored blocks — rolling the pin back does not undo
  it.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#run-mix-kilnblocksbackfill-once-after-deploying))

- **If your overlay compiles with `--warnings-as-errors`, check its blocks'
  `migrate` chains first.**
  ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642) · [long form](docs/changelog/v0.12.0.md#if-your-overlay-compiles-with-warnings-as-errors-check-its-block-migrate-chains-first))

- **A new `throttle_counters` table holds the auth budgets; run migrations as usual.**
  ([#1619](https://github.com/The-Verscienta/kiln_cms/issues/1619) · [long form](docs/changelog/v0.12.0.md#a-new-throttlecounters-table-holds-the-auth-budgets-run-migrations-as))

- **A site whose code-injection snippet opens a websocket to its vendor must
  now list that `wss://` origin under Connections.**
  ([long form](docs/changelog/v0.12.0.md#a-site-whose-code-injection-snippet-opens-a-websocket-to-its-vendor-must))

- **Before upgrading, make every webhook receiver verify
  `x-kilncms-webhook-signature`.**
  ([#1616](https://github.com/The-Verscienta/kiln_cms/issues/1616) · [long form](docs/changelog/v0.12.0.md#before-upgrading-make-every-webhook-receiver-verify-x-kilncms-webhook-signature))

- **If your `config/project.exs` restates `:ash_domains`, add
  `KilnCMS.Notifications`.**
  ([#1540](https://github.com/The-Verscienta/kiln_cms/issues/1540) · [long form](docs/changelog/v0.12.0.md#if-your-configprojectexs-restates-ash_domains-add-kilncmsnotifications))

- **On 0.8.0 or older, `mix kiln.update` shows you none of these notes.
  Read them here before moving the pin.**
  ([#1540](https://github.com/The-Verscienta/kiln_cms/issues/1540) · [long form](docs/changelog/v0.12.0.md#on-080-or-older-mix-kilnupdate-shows-you-none-of-these-notes))

- **If you set `TENANT_STRICT_HOST=false` on a multi-org deployment, give every
  host that must keep working an organization first.**
  ([#1662](https://github.com/The-Verscienta/kiln_cms/issues/1662) · [long form](docs/changelog/v0.12.0.md#tenant-strict-host-false-multi-org-upgrade))

### Breaking

- **Webhook deliveries no longer send `x-kilncms-signature`.**
  ([#1616](https://github.com/The-Verscienta/kiln_cms/issues/1616) · [long form](docs/changelog/v0.12.0.md#webhook-deliveries-no-longer-send-x-kilncms-signature))

- **`TENANT_STRICT_HOST=false` is no longer honoured once a second
  organization exists.**
  ([#1662](https://github.com/The-Verscienta/kiln_cms/issues/1662) · [long form](docs/changelog/v0.12.0.md#tenant-strict-host-false-no-longer-honoured))

### Added

- **`mix kiln.blocks.backfill` rewrites legacy-shaped stored blocks to the typed
  shape.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#mix-kilnblocksbackfill-rewrites-legacy-shaped-stored-blocks-to-the-typed-shape))

- **Release candidates are opt-in everywhere: `mix kiln.update --pre`.**
  ([long form](docs/changelog/v0.12.0.md#release-candidates-are-opt-in-everywhere-mix-kilnupdate-pre))

- **An upgrade rehearsal runs a past release's `mix kiln.update` against the
  candidate, with a seeded database.**
  ([#1540](https://github.com/The-Verscienta/kiln_cms/issues/1540) · [long form](docs/changelog/v0.12.0.md#an-upgrade-rehearsal-runs-every-past-releases-mix-kilnupdate-against-the))

- **`mix kiln.plugins.doctor` flags a core domain missing from
  `:ash_domains`.**
  ([#1540](https://github.com/The-Verscienta/kiln_cms/issues/1540) · [long form](docs/changelog/v0.12.0.md#mix-kilnpluginsdoctor-flags-a-core-domain-missing-from-ash_domains))

### Changed

- **An unknown option to `use KilnCMS.CMS.Content` now warns at compile time
  instead of being silently ignored.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#an-unknown-option-to-use-kilncmscmscontent-now-warns-at-compile-time-instead-of))

- **Public delivery, the previews and the in-context editor render from the
  typed blocks, not through the legacy block shape.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#public-delivery-the-previews-and-the-in-context-editor-render-from-the-typed))

- **A block whose `migrate` steps skip a version now warns at compile time;
  from Kiln 2.0 it is an error.**
  ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642) · [long form](docs/changelog/v0.12.0.md#a-block-whose-migrate-steps-skip-a-version-now-warns-at-compile-time))

- **Every surface carries one label: covered, internal or experimental.**
  ([#1542](https://github.com/The-Verscienta/kiln_cms/issues/1542) · [long form](docs/changelog/v0.12.0.md#every-surface-carries-one-label-covered-internal-or-experimental))

- **The content editor says Save draft and Publish now, and Visual is a
  secondary button.**
  ([#1671](https://github.com/The-Verscienta/kiln_cms/issues/1671) · [long form](docs/changelog/v0.12.0.md#the-content-editor-says-save-draft-and-publish-now))

### Fixed

- **The two-factor prompt has a labelled code field, the page's language and
  light and dark themes.**
  ([#1676](https://github.com/The-Verscienta/kiln_cms/issues/1676) · [long form](docs/changelog/v0.12.0.md#the-two-factor-prompt-has-a-labelled-code-field-the-pages-language-and-light-and))

- **The sign-in pages use the design kit, the setup wizard carries the brand,
  and the passkey button is in the page's markup.**
  ([#1681](https://github.com/The-Verscienta/kiln_cms/issues/1681) · [long form](docs/changelog/v0.12.0.md#the-sign-in-pages-use-the-design-kit-the-setup-wizard-carries-the-brand-and-the))

- **A hard line break in a paragraph, heading, quote or list item is delivered
  as `<br/>`.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#a-hard-line-break-in-a-paragraph-heading-quote-or-list-item-is-delivered-as-br))

- **Paragraphs inside a quote or a list item no longer run together when saved
  as Portable Text.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#paragraphs-inside-a-quote-or-a-list-item-no-longer-run-together-when-saved-as))

- **A legacy `columns` block reads as a typed `Columns` block, and an unmapped
  legacy block keeps the type name it was stored under.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#a-legacy-columns-block-reads-as-a-typed-columns-block-and-an-unmapped-legacy))

- **A 429's `retry-after` is rounded up, never 0.**
  ([long form](docs/changelog/v0.12.0.md#a-429s-retry-after-is-rounded-up-never-0))

- **The audience checkboxes on `/editor/accounts` edit the site membership, not the deprecated global column.**
  ([#1646](https://github.com/The-Verscienta/kiln_cms/issues/1646) · [long form](docs/changelog/v0.12.0.md#the-audience-checkboxes-on-editor-accounts-edit-the-site-membership))

- **Paying for a membership no longer demotes a legacy editor.**
  ([#1649](https://github.com/The-Verscienta/kiln_cms/issues/1649) · [long form](docs/changelog/v0.12.0.md#paying-for-a-membership-no-longer-demotes-a-legacy-editor))

- **The block upcaster refuses a gap in the `migrate` chain instead of
  stamping the block current.**
  ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642) · [long form](docs/changelog/v0.12.0.md#the-block-upcaster-refuses-a-gap-in-the-migrate-chain))

- **After signing in with a recovery code, you can set up a new
  authenticator.**
  ([#1675](https://github.com/The-Verscienta/kiln_cms/issues/1675) · [long form](docs/changelog/v0.12.0.md#after-signing-in-with-a-recovery-code-you-can-set-up-a-new-authenticator))

- **Public form labels are tied to their inputs, and a refused embedded
  submission offers Try again.**
  ([#1673](https://github.com/The-Verscienta/kiln_cms/issues/1673) · [long form](docs/changelog/v0.12.0.md#public-form-labels-are-tied-to-their-inputs-and-a-refused-embedded-submission))

- **A refused public form submission shows the form again, with your input
  kept and each error next to its field.**
  ([#1683](https://github.com/The-Verscienta/kiln_cms/issues/1683) · [long form](docs/changelog/v0.12.0.md#a-refused-public-form-submission-shows-the-form-again))

- **Console pages show their title, and an empty calendar or task list says
  so.**
  ([#1670](https://github.com/The-Verscienta/kiln_cms/issues/1670) · [#1672](https://github.com/The-Verscienta/kiln_cms/issues/1672) · [long form](docs/changelog/v0.12.0.md#console-pages-show-their-title-and-an-empty-calendar-or-task-list-says-so))

- **The account and membership pages show who is signed in; the sign-in
  pages have a skip target.**
  ([#1674](https://github.com/The-Verscienta/kiln_cms/issues/1674) · [long form](docs/changelog/v0.12.0.md#the-account-and-membership-pages-show-who-is-signed-in))

- **The example overlay's migrations run beside the core's.**
  ([#1540](https://github.com/The-Verscienta/kiln_cms/issues/1540) · [long form](docs/changelog/v0.12.0.md#the-example-overlays-migrations-run-beside-the-cores))

- **Ember links and labels in the console meet AA contrast; the previews wear
  the site's theme, and the public header nav is named and wraps on a phone.**
  ([#1677](https://github.com/The-Verscienta/kiln_cms/issues/1677) · [#1682](https://github.com/The-Verscienta/kiln_cms/issues/1682) · [long form](docs/changelog/v0.12.0.md#ember-links-and-labels-in-the-console-meet-aa-contrast-the-previews-wear-the))

- **A sign-in or console page opened under a locale prefix connects, and
  renders in that language.**
  ([#1699](https://github.com/The-Verscienta/kiln_cms/issues/1699) · [long form](docs/changelog/v0.12.0.md#a-sign-in-or-console-page-opened-under-a-locale-prefix-connects-and-renders))

### Security

- **Auth budgets now hold across nodes and restarts.**
  ([#1619](https://github.com/The-Verscienta/kiln_cms/issues/1619) · [long form](docs/changelog/v0.12.0.md#auth-budgets-now-hold-across-nodes-and-restarts))

- **The browser CSP's `connect-src` is `'self'` alone — no websocket to any
  other host.**
  ([#1615](https://github.com/The-Verscienta/kiln_cms/issues/1615) · [long form](docs/changelog/v0.12.0.md#the-browser-csps-connect-src-is-self-alone-no-websocket-to-any))

- **The seed script refuses a production database.**
  ([#1651](https://github.com/The-Verscienta/kiln_cms/issues/1651) · [long form](docs/changelog/v0.12.0.md#the-seed-script-refuses-a-production-database))

- **Changing your password signs out your open console tabs.**
  ([#1652](https://github.com/The-Verscienta/kiln_cms/issues/1652) · [long form](docs/changelog/v0.12.0.md#changing-your-password-signs-out-your-open-console-tabs))

- **Unsplash imports go through `SafeFetch`.**
  ([#1653](https://github.com/The-Verscienta/kiln_cms/issues/1653) · [long form](docs/changelog/v0.12.0.md#unsplash-imports-go-through-safefetch))

- **A node that missed the second organization's broadcast turns strict
  within 30 seconds, not five minutes.**
  ([#1654](https://github.com/The-Verscienta/kiln_cms/issues/1654) · [long form](docs/changelog/v0.12.0.md#org-count-recount-30-seconds))

- **Kiln warns when a multi-org deployment has no `KILN_CONSOLE_HOST`.**
  ([#1661](https://github.com/The-Verscienta/kiln_cms/issues/1661) · [long form](docs/changelog/v0.12.0.md#multi-org-without-console-host-warns))

- **A newsletter campaign is created under the sender's own authorization.**
  ([#1655](https://github.com/The-Verscienta/kiln_cms/issues/1655) · [long form](docs/changelog/v0.12.0.md#a-newsletter-campaign-is-created-under-the-senders-own-authorization))

- **The newsletter confirmation link no longer confirms on a GET.**
  ([#1664](https://github.com/The-Verscienta/kiln_cms/issues/1664) · [long form](docs/changelog/v0.12.0.md#the-newsletter-confirmation-link-no-longer-confirms-on-a-get))

- **The ActivityPub inbox checks a signature offline before it fetches the
  sender's key.**
  ([#1665](https://github.com/The-Verscienta/kiln_cms/issues/1665) · [long form](docs/changelog/v0.12.0.md#the-activitypub-inbox-checks-a-signature-offline-before-it-fetches))

### Deprecated

- **`published?:` on `use KilnCMS.CMS.Content` is deprecated, and removed at
  1.0.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#published-on-use-kilncmscmscontent-is-deprecated-and-removed-at-10))

- **The `/editor/pages/:id` and `/editor/posts/:id` editor routes are
  deprecated, and removed at 1.0; use `/editor/content/page/:id` and
  `/editor/content/post/:id`.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#the-editorpagesid-and-editorpostsid-editor-routes-are-deprecated-and-removed-at))

- **The `User.audiences` fallback for an account with no organization membership
  is deprecated, and removed at 1.0.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#the-useraudiences-fallback-for-an-account-with-no-organization-membership-is))

- **Webhook and newsletter jobs enqueued without `org_id`, and pre-ledger
  webhook jobs, are deprecated, and not run by 1.0.**
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) · [long form](docs/changelog/v0.12.0.md#webhook-and-newsletter-jobs-enqueued-without-orgid-and-pre-ledger-webhook-jobs))

- **The legacy block bridge is deprecated for removal at 1.0:
  `KilnCMS.CMS.TypedBlocks.to_legacy/1`, `from_legacy/1`, `RichText.legacy_html`
  and the legacy `KilnCMS.CMS.Block` write shape.**
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537) · [long form](docs/changelog/v0.12.0.md#the-legacy-block-bridge-is-deprecated-for-removal-at-10))

## [0.11.0] - 2026-09-26

Long form: [docs/changelog/v0.11.0.md](docs/changelog/v0.11.0.md) —
the 0.11.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **On a multi-org deployment with `EMBED_ORIGINS` unset, every cross-site form
  embed stops working on upgrade — set `EMBED_ORIGINS` first.**
  ([#1618](https://github.com/The-Verscienta/kiln_cms/issues/1618) · [long form](docs/changelog/v0.11.0.md#on-a-multi-org-deployment-with-embedorigins-unset-every-cross-site-form-embed))

### Breaking

- **Multi-org installs now cap form embeds at `EMBED_ORIGINS` unless
  `EMBED_ORIGINS_LOCKED=false`.**
  ([#1618](https://github.com/The-Verscienta/kiln_cms/issues/1618) · [long form](docs/changelog/v0.11.0.md#multi-org-installs-now-cap-form-embeds-at-embedorigins-unless))

- **Multi-org installs now refuse unknown hosts unless `TENANT_STRICT_HOST=false`.**
  ([#1547](https://github.com/The-Verscienta/kiln_cms/issues/1547) · [long form](docs/changelog/v0.11.0.md#multi-org-installs-now-refuse-unknown-hosts-unless-tenantstricthostfalse))

### Added

- **A site can offer its own single sign-on provider, honoured only for email
  domains it has verified by DNS.**
  ([#1561](https://github.com/The-Verscienta/kiln_cms/issues/1561) · [long form](docs/changelog/v0.11.0.md#a-site-can-offer-its-own-single-sign-on-provider))

- **A site can sign its push notifications with its own key, generated in the
  console.**
  ([#1560](https://github.com/The-Verscienta/kiln_cms/issues/1560) · [long form](docs/changelog/v0.11.0.md#a-site-can-sign-its-push-notifications-with-its-own-key-generated-in-the-console))

- **A site can index its content into its own Meilisearch, set from the console.**
  ([#1558](https://github.com/The-Verscienta/kiln_cms/issues/1558) · [long form](docs/changelog/v0.11.0.md#a-site-can-index-its-content-into-its-own-meilisearch-set-from-the-console))

- **A site can keep its uploads in its own object storage bucket, set from the
  console.**
  ([#1559](https://github.com/The-Verscienta/kiln_cms/issues/1559) · [long form](docs/changelog/v0.11.0.md#a-site-can-keep-its-uploads-in-its-own-object-storage-bucket-set-from-the-console))

- **A site on its own SMTP relay keeps its own bounce list.**
  ([#1562](https://github.com/The-Verscienta/kiln_cms/issues/1562) · [long form](docs/changelog/v0.11.0.md#a-site-on-its-own-smtp-relay-keeps-its-own-bounce-list))

- **A site can use its own AI provider key and models, set from the console.**
  ([#1557](https://github.com/The-Verscienta/kiln_cms/issues/1557) · [long form](docs/changelog/v0.11.0.md#a-site-can-use-its-own-ai-provider-key-and-models-set-from-the-console))

### Fixed

- **The sidebar's collapse and expand buttons name the panel they fold.**
  ([long form](docs/changelog/v0.11.0.md#the-sidebars-collapse-and-expand-buttons-name-the-panel-they-fold))

- **An open calendar no longer re-queries once per write during a bulk import.**
  ([#1336](https://github.com/The-Verscienta/kiln_cms/issues/1336) · [long form](docs/changelog/v0.11.0.md#an-open-calendar-no-longer-re-queries-once-per-write-during-a-bulk-import))

- **Sign-in and the other account pages show the site's own name and logo.**
  ([#1613](https://github.com/The-Verscienta/kiln_cms/pull/1613) · [long form](docs/changelog/v0.11.0.md#sign-in-and-the-other-account-pages-show-the-sites-own-name-and-logo))

- **A site's relay refusing its password no longer pages the operator.**
  ([#1562](https://github.com/The-Verscienta/kiln_cms/issues/1562) · [long form](docs/changelog/v0.11.0.md#a-sites-relay-refusing-its-password-no-longer-pages-the-operator))

- **A first sync of a site with never-fired content no longer fails.**
  ([#1621](https://github.com/The-Verscienta/kiln_cms/issues/1621) · [long form](docs/changelog/v0.11.0.md#a-first-sync-of-a-site-with-never-fired-content-no-longer-fails))

### Security

- **Two Hex advisories closed (`ash` 3.33.11, `lazy_html` 0.1.13); the working
  copy keeps its body through the `ash` union-comparison fix.**
  ([#1600](https://github.com/The-Verscienta/kiln_cms/issues/1600) · [long form](docs/changelog/v0.11.0.md#two-hex-advisories-closed-and-the-working-copy-survives-the-ash-fix))

## [0.10.0] - 2026-09-19

Long form: [docs/changelog/v0.10.0.md](docs/changelog/v0.10.0.md) —
the 0.10.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Webhook signing secrets move to an encrypted column.**
  ([long form](docs/changelog/v0.10.0.md#webhook-signing-secrets-move-to-an-encrypted-column))

- **Webhook receivers should move to `x-kilncms-webhook-signature`.**
  ([long form](docs/changelog/v0.10.0.md#webhook-receivers-should-move-to-x-kilncms-webhook-signature))

- **A CDN in front of the headless API now caches anonymous JSON:API, GraphQL
  `GET` and `/api/search` responses for up to 60 seconds.**
  ([#1571](https://github.com/The-Verscienta/kiln_cms/issues/1571) · [long form](docs/changelog/v0.10.0.md#a-cdn-in-front-of-the-headless-api-now-caches-anonymous-jsonapi-graphql-get-and))

- **Rotating `SECRET_KEY_BASE` keeps stored keys now, if the steps run in
  order.**
  ([#1487](https://github.com/The-Verscienta/kiln_cms/issues/1487) · [long form](docs/changelog/v0.10.0.md#rotating-secretkeybase-keeps-stored-keys-now-if-the-steps-run-in-order))

### Breaking

- **Headless slug lookups now answer a missing translation from the site's
  fallback chain, and an unsupported locale is a `400`.**
  ([#1579](https://github.com/The-Verscienta/kiln_cms/pull/1579) · [long form](docs/changelog/v0.10.0.md#headless-slug-lookups-now-answer-a-missing-translation-from-the-sites-fallback))

- **Some GraphQL queries that ran before are now refused as too costly, and a
  refused introspection query gets a GraphQL error instead of a 403.**
  ([long form](docs/changelog/v0.10.0.md#some-graphql-queries-that-ran-before-are-now-refused-as-too-costly-and-a))

### Added

- **`GET /api/sync`: a delta API that sees deletions.**
  ([#1581](https://github.com/The-Verscienta/kiln_cms/pull/1581) · [long form](docs/changelog/v0.10.0.md#get-apisync-a-delta-api-that-sees-deletions))

- **Locale fallback chains (`fr-CA → fr → en`), per site, on every delivery
  surface.**
  ([#1579](https://github.com/The-Verscienta/kiln_cms/pull/1579) · [long form](docs/changelog/v0.10.0.md#locale-fallback-chains-fr-ca-fr-en-per-site-on-every-delivery-surface))

- **Webhooks announce a document's whole lifecycle: `created`, `archived`,
  `deleted` and `restored`.**
  ([long form](docs/changelog/v0.10.0.md#webhooks-announce-a-documents-whole-lifecycle-created-archived-deleted-and))

- **Timestamped webhook signatures and a stable delivery id.**
  ([long form](docs/changelog/v0.10.0.md#timestamped-webhook-signatures-and-a-stable-delivery-id))

- **Conditional writes on the headless API: `ETag`, `If-Match` and
  `expectedLockVersion`.**
  ([long form](docs/changelog/v0.10.0.md#conditional-writes-on-the-headless-api-etag-if-match-and-expectedlockversion))

- **Anonymous JSON:API, GraphQL and search reads are CDN-cacheable, with a body
  ETag and 304s.**
  ([#1571](https://github.com/The-Verscienta/kiln_cms/issues/1571) · [long form](docs/changelog/v0.10.0.md#anonymous-jsonapi-graphql-and-search-reads-are-cdn-cacheable-with-a-body-etag))

- **Optional CDN purge on publish (`KILN_CDN_PURGE_URL`).**
  ([#1571](https://github.com/The-Verscienta/kiln_cms/issues/1571) · [long form](docs/changelog/v0.10.0.md#optional-cdn-purge-on-publish-kilncdnpurgeurl))

- **The official SDKs write, speak GraphQL, and are ready to publish.**
  ([#330](https://github.com/The-Verscienta/kiln_cms/issues/330) · [long form](docs/changelog/v0.10.0.md#the-official-sdks-write-speak-graphql-and-are-ready-to-publish))

- **Rotating `SECRET_KEY_BASE` no longer loses database-stored keys.**
  ([#1487](https://github.com/The-Verscienta/kiln_cms/issues/1487) · [long form](docs/changelog/v0.10.0.md#rotating-secretkeybase-no-longer-loses-database-stored-keys))

- **A site's ActivityPub actor can be re-keyed.**
  ([#1487](https://github.com/The-Verscienta/kiln_cms/issues/1487) · [long form](docs/changelog/v0.10.0.md#a-sites-activitypub-actor-can-be-re-keyed))

- **A site can send its mail through its own SMTP relay, set from the console.**
  ([#1322](https://github.com/The-Verscienta/kiln_cms/issues/1322) · [long form](docs/changelog/v0.10.0.md#a-site-can-send-its-mail-through-its-own-smtp-relay-set-from-the-console))

- **`Idempotency-Key` on the headless writes.**
  ([long form](docs/changelog/v0.10.0.md#idempotency-key-on-the-headless-writes))

- **Memberships can notify other systems: `membership.activated` and
  `membership.canceled` webhook events.**
  ([#334](https://github.com/The-Verscienta/kiln_cms/issues/334) · [long form](docs/changelog/v0.10.0.md#memberships-can-notify-other-systems-membershipactivated-and-membershipcanceled))

- **On-the-fly image transforms: `GET /media/:id/t/:ops`.**
  ([#1584](https://github.com/The-Verscienta/kiln_cms/pull/1584) · [long form](docs/changelog/v0.10.0.md#on-the-fly-image-transforms-get-mediaidtops))

- **One-click deploy templates for Render, Railway, Fly.io and DigitalOcean.**
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529) · [long form](docs/changelog/v0.10.0.md#one-click-deploy-templates-for-render-railway-flyio-and-digitalocean))

- **`KILN_MEDIA_ROOT`: a stable directory for local media.**
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529) · [long form](docs/changelog/v0.10.0.md#kilnmediaroot-a-stable-directory-for-local-media))

- **Share a draft: *Copy preview link* in the editor, and a preview-token API.**
  ([long form](docs/changelog/v0.10.0.md#share-a-draft-copy-preview-link-in-the-editor-and-a-preview-token-api))

- **The visual-editing bridge takes a preview token instead of an API key.**
  ([long form](docs/changelog/v0.10.0.md#the-visual-editing-bridge-takes-a-preview-token-instead-of-an-api-key))

- **Upload media over the API: `POST /api/media`, URL imports, presigned direct
  uploads, metadata `PATCH`, and SDK support.**
  ([#1576](https://github.com/The-Verscienta/kiln_cms/pull/1576) · [long form](docs/changelog/v0.10.0.md#upload-media-over-the-api))

- **Version history over the API.**
  ([#1574](https://github.com/The-Verscienta/kiln_cms/pull/1574) · [long form](docs/changelog/v0.10.0.md#version-history-over-the-api))

- **Content releases are readable over JSON:API.**
  ([#500](https://github.com/The-Verscienta/kiln_cms/issues/500) · [long form](docs/changelog/v0.10.0.md#content-releases-are-readable-over-jsonapi))

- **The GraphQL schema and the OpenAPI document are committed, and a production
  site hands its own to an API key.**
  ([#567](https://github.com/The-Verscienta/kiln_cms/issues/567), [#1567](https://github.com/The-Verscienta/kiln_cms/issues/1567) · [long form](docs/changelog/v0.10.0.md#the-graphql-schema-and-the-openapi-document-are-committed-and-a-production-site))

- **An opt-in Prometheus endpoint for the app's metrics.**
  ([#1362](https://github.com/The-Verscienta/kiln_cms/issues/1362) · [long form](docs/changelog/v0.10.0.md#an-opt-in-prometheus-endpoint-for-the-apps-metrics))

### Changed

- **The content list says an item's status in words; the trigram glyph is
  opt-in.**
  ([#1323](https://github.com/The-Verscienta/kiln_cms/issues/1323) · [long form](docs/changelog/v0.10.0.md#the-content-list-says-an-items-status-in-words-the-trigram-glyph-is-opt-in))

- **The dependency audit also reads Hex's own advisory feed.**
  ([#1553](https://github.com/The-Verscienta/kiln_cms/issues/1553) · [long form](docs/changelog/v0.10.0.md#the-dependency-audit-also-reads-hexs-own-advisory-feed))

- **String lengths are counted in codepoints, as Postgres counts them.**
  ([#1553](https://github.com/The-Verscienta/kiln_cms/issues/1553) · [long form](docs/changelog/v0.10.0.md#string-lengths-are-counted-in-codepoints-as-postgres-counts-them))

### Fixed

- **A preview link shows a live document's unpublished edits, and works for
  admin-defined types.**
  ([long form](docs/changelog/v0.10.0.md#a-preview-link-shows-the-working-copy-and-works-for-admin-defined-types))

- **A delivery that fails on an unreadable signing key now says so.**
  ([#1487](https://github.com/The-Verscienta/kiln_cms/issues/1487) · [long form](docs/changelog/v0.10.0.md#a-delivery-that-fails-on-an-unreadable-signing-key-now-says-so))

- **A relay refusing the operator's password no longer suppresses every
  recipient.**
  ([long form](docs/changelog/v0.10.0.md#a-relay-refusing-the-operators-password-no-longer-suppresses-every-recipient))

- **`mix setup` stops early, with the real reason, when the checkout's path has
  a space.**
  ([#1321](https://github.com/The-Verscienta/kiln_cms/issues/1321) · [long form](docs/changelog/v0.10.0.md#mix-setup-stops-early-with-the-real-reason-when-the-checkouts-path-has-a-space))

- **Buttons, links, badges and fields that rendered unstyled now look like what
  they are.**
  ([#1531](https://github.com/The-Verscienta/kiln_cms/issues/1531) · [long form](docs/changelog/v0.10.0.md#buttons-links-badges-and-fields-that-rendered-unstyled-now-look-like-what-they))

- **A PaaS health check no longer gets a redirect, and `PHX_HOST` falls back to
  the platform's hostname.**
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529) · [long form](docs/changelog/v0.10.0.md#a-paas-health-check-no-longer-gets-a-redirect-and-phxhost-falls-back-to-the))

### Security

- **Point-in-time reads (`?as_of=`) apply the passphrase lock and the audience
  as live delivery does.**
  ([#496](https://github.com/The-Verscienta/kiln_cms/issues/496), [#1032](https://github.com/The-Verscienta/kiln_cms/issues/1032) · [long form](docs/changelog/v0.10.0.md#point-in-time-reads-asof-apply-the-passphrase-lock-and-the-audience-as-live))

- **A request on a host that names no site no longer reads the database for the
  default site every time.**
  ([#1580](https://github.com/The-Verscienta/kiln_cms/pull/1580) · [long form](docs/changelog/v0.10.0.md#a-request-on-a-host-that-names-no-site-no-longer-reads-the-database-for-the))

- **Webhook signing secrets are encrypted at rest.**
  ([long form](docs/changelog/v0.10.0.md#webhook-signing-secrets-are-encrypted-at-rest))

- **Every advisory published against the 0.9.0 dependency set is fixed,
  including six CRITICAL in `ash_authentication`.**
  ([#1553](https://github.com/The-Verscienta/kiln_cms/issues/1553) · [long form](docs/changelog/v0.10.0.md#every-advisory-published-against-the-090-dependency-set-is-fixed-including-six))

- **`mint` 1.10.1 closes a response-smuggling advisory in its HTTP/1 chunked
  parser (EEF-CVE-2026-82672, MEDIUM).**
  ([#1586](https://github.com/The-Verscienta/kiln_cms/pull/1586) · [long form](docs/changelog/v0.10.0.md#mint-1101-closes-a-response-smuggling-advisory-in-its-http1-chunked-parser-eef))

- **`/ws/gql` runs under the same cost limits as `/gql`, batches are counted per
  operation, and introspection is refused however a document arrives.**
  ([long form](docs/changelog/v0.10.0.md#wsgql-runs-under-the-same-cost-limits-as-gql-batches-are-counted-per-operation))

- **Each document sent over `/ws/gql` now counts against the `:gql` rate limit,
  and a malformed document no longer strips a GraphQL socket of its tenant and
  actor.**
  ([long form](docs/changelog/v0.10.0.md#each-document-sent-over-wsgql-now-counts-against-the-gql-rate-limit-and-a))

## [0.9.0] - 2026-09-18

Long form: [docs/changelog/v0.9.0.md](docs/changelog/v0.9.0.md) —
the 0.9.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Semantic search now needs an image built with `KILN_ML=1`.**
  ([#1474](https://github.com/The-Verscienta/kiln_cms/issues/1474) · [long form](docs/changelog/v0.9.0.md#semantic-search-now-needs-an-image-built-with-kilnml1-upgrading))

- **Existing accounts keep the full sidebar; new ones start on Essentials.**
  ([long form](docs/changelog/v0.9.0.md#sidebar-presets-essentials-and-everything-upgrading))

### Added

- **The sidebar's "Tasks" item shows how many of your tasks are open.**
  ([#1525](https://github.com/The-Verscienta/kiln_cms/issues/1525) · [long form](docs/changelog/v0.9.0.md#the-sidebars-tasks-item-shows-how-many-of-your-tasks-are-open))

- **The fields admin explains each field type under its picker.**
  ([#1512](https://github.com/The-Verscienta/kiln_cms/issues/1512) · [long form](docs/changelog/v0.9.0.md#the-fields-admin-explains-each-field-type-under-its-picker))

- **A custom field can be added to several content types at once, and its
  machine name fills itself in.**
  ([#1511](https://github.com/The-Verscienta/kiln_cms/issues/1511) · [long form](docs/changelog/v0.9.0.md#a-custom-field-can-be-added-to-several-content-types-at-once-and-its-machine))

- **Media sideloading can be tested without the network.**
  ([#487](https://github.com/The-Verscienta/kiln_cms/issues/487) · [long form](docs/changelog/v0.9.0.md#media-sideloading-can-be-tested-without-the-network))

- **Sidebar presets: Essentials and Everything.**
  ([#1496](https://github.com/The-Verscienta/kiln_cms/issues/1496) · [long form](docs/changelog/v0.9.0.md#sidebar-presets-essentials-and-everything))

- **A Configure hub at `/editor/configure`.**
  ([#1319](https://github.com/The-Verscienta/kiln_cms/issues/1319) · [long form](docs/changelog/v0.9.0.md#a-configure-hub-at-editorconfigure))

- **Notifications are persisted, not only mailed.**
  ([#1472](https://github.com/The-Verscienta/kiln_cms/issues/1472) · [long form](docs/changelog/v0.9.0.md#notifications-are-persisted-not-only-mailed))

- **The editor says when a heading's `#link` gets a number.**
  ([#1439](https://github.com/The-Verscienta/kiln_cms/pull/1439) · [long form](docs/changelog/v0.9.0.md#the-editor-says-when-a-headings-link-gets-a-number))

- **`/editor/inbox`.**
  ([#1472](https://github.com/The-Verscienta/kiln_cms/issues/1472) · [long form](docs/changelog/v0.9.0.md#editorinbox))

- **A notification bell in the console top bar**, on every `/editor/*` page.
  ([#1478](https://github.com/The-Verscienta/kiln_cms/issues/1478) · [long form](docs/changelog/v0.9.0.md#a-notification-bell-in-the-console-top-bar-on-every-editor-page-an-unread-badge))

### Changed

- **Keyword search matches the last word as a prefix.** "huang lia" finds
  Huang Lian; finished words still rank first.
  ([#1509](https://github.com/The-Verscienta/kiln_cms/issues/1509) · [long form](docs/changelog/v0.9.0.md#keyword-search-matches-the-last-word-as-a-prefix))

- **"New page" no longer writes a row until you start writing.** The draft is
  created on the first title keystroke or Save.
  ([#1497](https://github.com/The-Verscienta/kiln_cms/issues/1497) · [long form](docs/changelog/v0.9.0.md#new-page-no-longer-writes-a-row-until-you-start-writing))

- **The editor opens on the title and the canvas.** Slug, path alias and
  redirects moved to Settings → URL; "Edit URL" under the title jumps there.
  ([#1495](https://github.com/The-Verscienta/kiln_cms/issues/1495) · [long form](docs/changelog/v0.9.0.md#the-editor-opens-on-the-title-and-the-canvas))

- **Home says what the site holds, asks how you publish, and doesn't alarm on day one.**
  ([#1493](https://github.com/The-Verscienta/kiln_cms/issues/1493) · [long form](docs/changelog/v0.9.0.md#home-says-what-the-site-holds-asks-how-you-publish-and-doesnt-alarm-on-day-one))

- **The ML stack behind semantic search is now opt-in (`KILN_ML=1`).**
  ([#1474](https://github.com/The-Verscienta/kiln_cms/issues/1474) · [long form](docs/changelog/v0.9.0.md#the-ml-stack-behind-semantic-search-is-now-opt-in-kilnml1))

- **A temporary role is applied where a tier is decided; `role` on a read is
  always the standing tier.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#a-temporary-role-is-applied-where-a-tier-is-decided-role-on-a-read-is-always))

- **Account removal no longer scans every admin-defined entry per type** —
  `entries.author_id` is indexed.
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462))

- **`config/runtime.exs` is now an index, not a 1,523-line file.**
  ([#1476](https://github.com/The-Verscienta/kiln_cms/issues/1476) · [long form](docs/changelog/v0.9.0.md#configruntimeexs-is-now-an-index-not-a-1523-line-file))

- **`docs/environment-variables.md` and `.env.example` lead with the short
  list.**
  ([#1476](https://github.com/The-Verscienta/kiln_cms/issues/1476) · [long form](docs/changelog/v0.9.0.md#docsenvironment-variablesmd-and-envexample-lead-with-the-short-list))

- **The stock front page now renders in the public delivery chrome.**
  ([#1461](https://github.com/The-Verscienta/kiln_cms/issues/1461) · [long form](docs/changelog/v0.9.0.md#the-stock-front-page-now-renders-in-the-public-delivery-chrome))

- **The public search form has a submit button.**
  ([#1461](https://github.com/The-Verscienta/kiln_cms/issues/1461) · [long form](docs/changelog/v0.9.0.md#the-public-search-form-has-a-submit-button))

- **The product name is spelled `KilnCMS` everywhere.**
  ([#1461](https://github.com/The-Verscienta/kiln_cms/issues/1461) · [long form](docs/changelog/v0.9.0.md#the-product-name-is-spelled-kilncms-everywhere))

- **The docs publisher no longer installs `earmark`.**
  ([#1452](https://github.com/The-Verscienta/kiln_cms/issues/1452) · [long form](docs/changelog/v0.9.0.md#the-docs-publisher-no-longer-installs-earmark))

- **Workflow and task notifications now dispatch after the write commits.**
  ([#1472](https://github.com/The-Verscienta/kiln_cms/issues/1472) · [long form](docs/changelog/v0.9.0.md#workflow-and-task-notifications-now-dispatch-after-the-write-commits))

- **A secrets-rotation runbook**,
  [`docs/secrets-rotation.md`](docs/secrets-rotation.md), closing residual risk
  12 in `docs/threat-model.md`.
  ([#1304](https://github.com/The-Verscienta/kiln_cms/issues/1304) · [long form](docs/changelog/v0.9.0.md#a-secrets-rotation-runbook-docssecrets-rotationmddocssecrets-rotationmd-closing))

- **`/editor/accounts` — the instance-wide account register.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#editoraccounts-the-instance-wide-account-register))

- **Temporary roles that expire on their own.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#temporary-roles-that-expire-on-their-own))

- **Admin-initiated password resets.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#admin-initiated-password-resets))

- **Account removal with a content disposition.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#account-removal-with-a-content-disposition))

- **A guard on the last admin.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#a-guard-on-the-last-admin))

- **`KilnCMS.Accounts.Checks.PlatformAdmin` replaces
  `actor_attribute_equals(:role, :admin)`** on every platform resource.
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#kilncmsaccountschecksplatformadmin-replaces-actorattributeequalsrole-admin-on))

- **Erasure revokes API keys.**
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462) · [long form](docs/changelog/v0.9.0.md#erasure-revokes-api-keys))

- **`ContentTypes.count!/2`** — the count `list!/2` would return rows for,
  without the rows, for compiled and dynamic types alike.
  ([#1462](https://github.com/The-Verscienta/kiln_cms/issues/1462))

- **The release image is published to GHCR on every version tag.**
  ([#1328](https://github.com/The-Verscienta/kiln_cms/issues/1328) · [long form](docs/changelog/v0.9.0.md#the-release-image-is-published-to-ghcr-on-every-version-tag))

- **`.github/SUPPORT.md`, and a "Status & maturity" section at the top of the
  README.**
  ([#1328](https://github.com/The-Verscienta/kiln_cms/issues/1328) · [long form](docs/changelog/v0.9.0.md#githubsupportmd-and-a-status-maturity-section-at-the-top-of-the-readme))

- **`docs/overlay-contract.md` — what a downstream overlay may rely on across
  releases.**
  ([#452](https://github.com/The-Verscienta/kiln_cms/issues/452), [#459](https://github.com/The-Verscienta/kiln_cms/issues/459), [#488](https://github.com/The-Verscienta/kiln_cms/issues/488), [#504](https://github.com/The-Verscienta/kiln_cms/issues/504), [#1328](https://github.com/The-Verscienta/kiln_cms/issues/1328) · [long form](docs/changelog/v0.9.0.md#docsoverlay-contractmd-what-a-downstream-overlay-may-rely-on-across-releases))

- **`Kiln.FieldType.parse_float/1` — a covered numeric parse for a custom field
  type's `cast/2`.**
  ([#1456](https://github.com/The-Verscienta/kiln_cms/issues/1456) · [long form](docs/changelog/v0.9.0.md#kilnfieldtypeparsefloat1-a-covered-numeric-parse-for-a-custom-field-types-cast2))

- **The in-tree example overlay no longer reaches past the overlay contract.**
  ([#1456](https://github.com/The-Verscienta/kiln_cms/issues/1456) · [long form](docs/changelog/v0.9.0.md#the-in-tree-example-overlay-no-longer-reaches-past-the-overlay-contract))

- **`docs/overlay-contract.md` says why the example's `:test` plugin list names
  a core fixture.**
  ([#1328](https://github.com/The-Verscienta/kiln_cms/issues/1328) · [long form](docs/changelog/v0.9.0.md#docsoverlay-contractmd-says-why-the-examples-test-plugin-list-names-a-core))

- **The Configure sidebar is sections, and ⌘K finds settings screens.**
  ([#1319](https://github.com/The-Verscienta/kiln_cms/issues/1319) · [long form](docs/changelog/v0.9.0.md#the-configure-sidebar-is-sections-and-k-finds-settings-screens))

- **`CHANGELOG.md` is a summary, and the reasoning moved to `docs/changelog/`
  and `docs/decisions/`**.
  ([#1325](https://github.com/The-Verscienta/kiln_cms/issues/1325) · [long form](docs/changelog/v0.9.0.md#changelogmd-is-a-summary-and-the-reasoning-moved-to-docschangelog-and))

- **The coverage floor moves 82.7 → 85.8.**
  ([#1526](https://github.com/The-Verscienta/kiln_cms/issues/1526) · [long form](docs/changelog/v0.9.0.md#the-coverage-floor-moves-827-to-858))

### Fixed

- **The console's mobile nav drawer announces itself, takes the keyboard, and
  closes when it takes you somewhere.**
  ([#1523](https://github.com/The-Verscienta/kiln_cms/issues/1523) · [long form](docs/changelog/v0.9.0.md#the-consoles-mobile-nav-drawer-announces-itself-takes-the-keyboard-and-closes))

- **A failed S3 multipart upload is aborted instead of left on the bucket.**
  ([#494](https://github.com/The-Verscienta/kiln_cms/issues/494) · [long form](docs/changelog/v0.9.0.md#a-failed-s3-multipart-upload-is-aborted-instead-of-left-on-the-bucket))

- **The kilncms.dev docs publisher works again, and CI proves it.**
  ([#1515](https://github.com/The-Verscienta/kiln_cms/issues/1515) · [long form](docs/changelog/v0.9.0.md#the-kilncmsdev-docs-publisher-works-again-and-ci-proves-it))

- **Task emails for content of a deleted content type are sent instead of
  crashing the mail job.**
  ([#1320](https://github.com/The-Verscienta/kiln_cms/issues/1320))

- **`mix kiln.changelog --verify` no longer reports a loss for a pull request
  `--condense` credited.**
  ([#1504](https://github.com/The-Verscienta/kiln_cms/issues/1504) · [long form](docs/changelog/v0.9.0.md#mix-kiln-changelog-verify-no-longer-reports-a-loss-for-a-credited-pull-request))

- **`mix kiln.changelog --condense` no longer breaks on a release where two
  summaries link one long form.**
  ([#1503](https://github.com/The-Verscienta/kiln_cms/issues/1503) · [long form](docs/changelog/v0.9.0.md#mix-kiln-changelog-condense-no-longer-breaks-on-a-shared-long-form))

- **A menu item's Edit form no longer shares input ids with the Add form.**
  ([#1501](https://github.com/The-Verscienta/kiln_cms/issues/1501) · [long form](docs/changelog/v0.9.0.md#a-menu-items-edit-form-no-longer-shares-input-ids-with-the-add-form))

- **Editing a live page's body no longer blanks its title or strands the change in the working copy.**
  ([#1506](https://github.com/The-Verscienta/kiln_cms/issues/1506) · [long form](docs/changelog/v0.9.0.md#editing-a-live-pages-body-no-longer-blanks-its-title))

- **Notification bell and inbox fixes from review: items mark read, entry links resolve, erasure reaches inboxes.**
  ([#1498](https://github.com/The-Verscienta/kiln_cms/issues/1498) · [long form](docs/changelog/v0.9.0.md#notification-bell-and-inbox-fixes-from-review))

- **Five editor-console rough edges a first-time user hit.**
  ([#1494](https://github.com/The-Verscienta/kiln_cms/issues/1494) · [long form](docs/changelog/v0.9.0.md#five-editor-console-rough-edges-a-first-time-user-hit))

- **`mix docs` "View Source" links point at the release tag, not `main`.**
  ([#1450](https://github.com/The-Verscienta/kiln_cms/issues/1450) · [long form](docs/changelog/v0.9.0.md#mix-docs-view-source-links-point-at-the-release-tag-not-main))

- **A `.md` file that opens with an HTML comment keeps its title.**
  ([#1455](https://github.com/The-Verscienta/kiln_cms/issues/1455) · [long form](docs/changelog/v0.9.0.md#a-md-file-that-opens-with-an-html-comment-keeps-its-title))

- **The content-cache metric no longer inverts during a stampede, and a Courier
  failure no longer amplifies one.**
  ([#1475](https://github.com/The-Verscienta/kiln_cms/issues/1475) · [long form](docs/changelog/v0.9.0.md#the-content-cache-metric-no-longer-inverts-during-a-stampede-and-a-courier))

- **An arrow key can no longer walk a calendar chip off the grid it is drawn
  on.**
  ([#1384](https://github.com/The-Verscienta/kiln_cms/issues/1384) · [long form](docs/changelog/v0.9.0.md#an-arrow-key-can-no-longer-walk-a-calendar-chip-off-the-grid-it-is-drawn-on))

- **An HTML comment in imported Markdown is no longer published as prose.**
  ([#1454](https://github.com/The-Verscienta/kiln_cms/issues/1454) · [long form](docs/changelog/v0.9.0.md#an-html-comment-in-imported-markdown-is-no-longer-published-as-prose))

- **Links to a `README.md` from a guide pointed at the wrong README.**
  ([#1464](https://github.com/The-Verscienta/kiln_cms/issues/1464) · [long form](docs/changelog/v0.9.0.md#links-to-a-readmemd-from-a-guide-pointed-at-the-wrong-readme))

- **Both password forms check the confirmation as you type.**
  ([#1446](https://github.com/The-Verscienta/kiln_cms/issues/1446) · [long form](docs/changelog/v0.9.0.md#both-password-forms-check-the-confirmation-as-you-type))

- **The new-password button says "Change password".**
  ([#1451](https://github.com/The-Verscienta/kiln_cms/issues/1451) · [long form](docs/changelog/v0.9.0.md#the-new-password-button-says-change-password))

- **With every-write anchoring on, a system-actor write no longer crashes in
  `AnchorVersion`; its anchor is attributed to `actor_id: nil`.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402), [#910](https://github.com/The-Verscienta/kiln_cms/issues/910))

- **A system-actor publish or membership transition no longer crashes on the
  actor's missing `:id`; it is attributed to `actor_id: nil`.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402), [#1486](https://github.com/The-Verscienta/kiln_cms/issues/1486))

- **The console sidebar no longer slides in with its labels cropped, and wide
  content no longer scrolls the whole console sideways.**
  ([#1499](https://github.com/The-Verscienta/kiln_cms/issues/1499) · [long form](docs/changelog/v0.9.0.md#the-console-sidebar-no-longer-slides-in-with-its-labels-cropped))

- **`/developers` no longer links to a Swagger UI and OpenAPI spec that 404,
  and the GraphiQL playground is reachable in dev again.**
  ([#1492](https://github.com/The-Verscienta/kiln_cms/issues/1492) · [long form](docs/changelog/v0.9.0.md#developers-no-longer-links-to-a-swagger-ui-and-openapi-spec-that-404))

- **`mix kiln.export.content` refuses a `--state` it does not know.**
  ([#1510](https://github.com/The-Verscienta/kiln_cms/issues/1510) · [long form](docs/changelog/v0.9.0.md#mix-kiln-export-content-refuses-a-state-it-does-not-know))

- **A content export holds every record, and an import restores each in its
  own state.**
  ([#1510](https://github.com/The-Verscienta/kiln_cms/issues/1510) · [long form](docs/changelog/v0.9.0.md#a-content-export-holds-every-record-and-restores-each-in-its-own-state))

- **An import report says when a record landed but not as the source had it.**
  ([#1514](https://github.com/The-Verscienta/kiln_cms/issues/1514) · [long form](docs/changelog/v0.9.0.md#an-import-report-says-when-a-record-landed-but-not-as-the-source-had-it))

### Security

- **The session cookie's signing and encryption salts can be set per
  deployment.**
  ([#1326](https://github.com/The-Verscienta/kiln_cms/issues/1326) · [long form](docs/changelog/v0.9.0.md#the-session-cookies-signing-and-encryption-salts-can-be-set-per-deployment))

- **A system actor, so internal callers run under the policies instead of around
  them.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#a-system-actor-so-internal-callers-run-under-the-policies-instead-of-around-them))

- **The firing path runs under the policies.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#the-firing-path-runs-under-the-policies))

- **The semantic index runs under its policies.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#the-semantic-index-runs-under-its-policies))

- **Editorial automation runs under the policies.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#editorial-automation-runs-under-the-policies))

- **Billing and the newsletter tier sync run under the policies.**
  ([#1329](https://github.com/The-Verscienta/kiln_cms/issues/1329), [#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#billing-and-the-newsletter-tier-sync-run-under-the-policies))

- **`mix kiln.authz.check` now gates all of `lib/`.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402) · [long form](docs/changelog/v0.9.0.md#mix-kilnauthzcheck-now-gates-all-of-lib))

- **Firing no longer fails, or mints an unattributed anchor, with every-write
  anchoring on.**
  ([#910](https://github.com/The-Verscienta/kiln_cms/issues/910) · [long form](docs/changelog/v0.9.0.md#firing-no-longer-fails-or-mints-an-unattributed-anchor-with-every-write))

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
  ([#1313](https://github.com/The-Verscienta/kiln_cms/issues/1313))

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
  ([#1392](https://github.com/The-Verscienta/kiln_cms/issues/1392) · [long form](docs/changelog/v0.8.0.md#cis-main-gate-is-five-parallel-jobs-instead-of-one-serial-one))

- **The CI build cache is trusted again.**
  ([#1397](https://github.com/The-Verscienta/kiln_cms/issues/1397) · [long form](docs/changelog/v0.8.0.md#the-ci-build-cache-is-trusted-again))

### Fixed

- **Links to a section land on it.**
  ([#1439](https://github.com/The-Verscienta/kiln_cms/issues/1439) · [long form](docs/changelog/v0.8.0.md#links-to-a-section-land-on-it))

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
  ([#808](https://github.com/The-Verscienta/kiln_cms/issues/808), [#481](https://github.com/The-Verscienta/kiln_cms/issues/481) · [long form](docs/changelog/v0.7.0.md#office-documents-and-zip-archives-in-the-document-library))

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
  ([#599](https://github.com/The-Verscienta/kiln_cms/issues/599) · [long form](docs/changelog/v0.6.0.md#the-xmerl-name-budget-scanner-no-longer-trips-otp-29s-dialyzer-599-family))

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

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.12.1...v1.0.0
[0.12.1]: https://github.com/The-Verscienta/kiln_cms/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/The-Verscienta/kiln_cms/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.5.0
[0.1.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.1.0
