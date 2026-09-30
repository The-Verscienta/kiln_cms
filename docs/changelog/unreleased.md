# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="upgrade-to-1-0-with-allow-major-from-0-12"></a>

- **1.0 is a major version: move to it with `mix kiln.update --allow-major`,
  from 0.12.0, after 0.12's own upgrade steps.** `mix kiln.update` refuses a
  move across a major version unless you pass `--allow-major`, and a plain
  update never targets a release candidate, so try one with
  `mix kiln.update --to v1.0.0-rc.1 --allow-major`. Go through 0.12.0 first,
  not straight from an older release: 1.0 removes what 0.12 deprecated, and
  0.12 is the release that migrates it. On 0.12, run
  `mix kiln.blocks.backfill` and `mix kiln.deprecations --migrate-audiences`,
  and let webhook and newsletter jobs queued before 0.12 drain; the notes
  below say what each removal needs. A project pinned to 0.11 or older runs a
  `mix kiln.update` that shows none of these notes (0.8.0 and older show none
  at all), which is another reason to stop at 0.12.0 on the way
  ([#1545](https://github.com/The-Verscienta/kiln_cms/issues/1545)).

<a id="set-deployment-specific-session-salts"></a>

- **Set this deployment's own session salts if you still use the shipped
  defaults; changing them signs everyone out once.** The session cookie's
  signing and encryption keys are derived from `secret_key_base` and two
  salts, `:session_signing_salt` and `:session_encryption_salt`. Their
  defaults are public constants in this open-source tree. They are not
  secrets by themselves (`secret_key_base` carries the real entropy), but a
  deployment is better off with its own. Set them at compile time in
  `config/project.exs`
  (`config :kiln_cms, session_signing_salt: "…", session_encryption_salt: "…"`),
  pick a quiet moment, and expect every user to sign in again once. Found by
  the 1.0 external authentication review
  ([#1536](https://github.com/The-Verscienta/kiln_cms/issues/1536); see
  `docs/environment-variables.md`).

<a id="password-rotation-upgrade-revokes-nothing-retroactively"></a>

- **Upgrading revokes nothing by itself: if an account changed or reset its
  password on an earlier release because it may have leaked, do it again (or
  use *Sign out everywhere*).** The fix above applies to password changes made
  after the upgrade. A session or remember-me cookie issued before a password
  change on an earlier release was never revoked, and stays valid until it
  expires, which is up to 30 days for a remember-me cookie. For an account
  whose credential you think leaked, change or reset its password again on
  this release. An administrator can also use *Sign out everywhere* on the
  account's page under `/editor/accounts`, which has always revoked every
  token. Users who change their password in settings are now signed out on
  that device too, and asked to sign in again
  ([#734](https://github.com/The-Verscienta/kiln_cms/issues/734)).

<a id="a-new-index-on-every-content-tables-titles-is-built-concurrently-by-the"></a>

- **A new index on every content table's titles is built `CONCURRENTLY` by
  the migration; if it is interrupted, drop the invalid index and migrate
  again.** The migration (`search_title_lexemes_index`) adds a GIN index,
  `<table>_title_lexemes_index`, to `pages`, `posts`, `entries` and — when
  their own migrations are next generated — every project content type. It
  runs outside a transaction so the table keeps taking writes while it
  builds; it measured about 20 µs a row (35 ms for 1,700 posts), so a
  million-row table is a matter of seconds, not a maintenance window. The
  cost of `CONCURRENTLY` is that a build killed half-way leaves an `INVALID`
  index behind under the same name, and the next `mix ash.migrate` fails on
  it: `DROP INDEX CONCURRENTLY <table>_title_lexemes_index;` and run it again
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712)).

<a id="jobs-already-stuck-executing-from-earlier-deploys-run-again-or-are-discarded"></a>

- **Jobs already stuck `executing` from earlier deploys run again (or are
  discarded) within a minute of upgrading.** The new Lifeline rescue (below)
  does not know how old a row is beyond its `attempted_at`, so every
  `executing` row older than three hours that a past deploy stranded is put
  back to `available`, or `discarded` if it had used its last attempt, on the
  first sweep after the upgrade. For most workers that is the point: a
  stranded publish, variant or delivery finally happens. To see what will be
  picked up, run `SELECT id, worker, attempted_at FROM oban_jobs WHERE state =
  'executing' AND attempted_at < now() - interval '3 hours'` before
  upgrading, and cancel any you do not want re-run
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718)).

<a id="run-mix-kilnorgslugs-to-find-organizations-whose-slug-cant-be-a-hostname"></a>

- **Run `mix kiln.org_slugs` to find organizations whose slug can't be a hostname.**
  A slug stored before this release may hold uppercase letters, underscores or
  dots, and such an org has never been reachable at `<slug>.<base host>`. The
  task lists every one and exits non-zero while any is left; in a release, run
  `bin/kiln_cms eval 'KilnCMS.Release.org_slugs()'`. `--fix`
  (`KilnCMS.Release.org_slugs(fix: true)`) downcases each slug where that
  alone makes a valid label that no other org's slug downcases to, and logs
  each rename. Nothing that worked stops working, because the subdomain was
  unreachable before the fix. Every other row is listed for you to give a new
  slug, and to move its DNS with it. The application also warns at boot while
  any such slug is left
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710)).

## Breaking

<a id="on-a-multi-org-install-with-kiln_console_host-set-each-non-default-orgs-console"></a>

- **On a multi-org install with `KILN_CONSOLE_HOST` set, each non-default
  org's console moves to `<slug>.<console host>`: add wildcard DNS and a
  wildcard TLS certificate for `*.<console host>` before upgrading.** The documented meaning of `KILN_CONSOLE_HOST` changes for
  this one configuration. Before, a console route on a non-default
  organization's site redirected to the bare console host, which is the
  default organization's console. Now it redirects to that organization's own
  console host, `<slug>.<console host>` (for example
  `acme.console.example.com`). Unless that name resolves to Kiln and is covered
  by the certificate, those editors reach no console at all after the upgrade.
  A certificate for `*.example.com` does not cover `acme.console.example.com`.
  Editors signed in on the bare console host sign in again on their
  organization's console host. Single-org installs, and installs without
  `KILN_CONSOLE_HOST`, are unaffected
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).

<a id="remove-the-legacy-block-bridge-functions"></a>

- **Remove `TypedBlocks.to_legacy/1`, `TypedBlocks.from_legacy/1` and
  `KilnCMS.CMS.Block`; use `to_typed/1` and render from typed blocks.** 0.12
  deprecated all three (#1537). `KilnCMS.CMS.TypedBlocks.to_typed/1` accepts
  everything `from_legacy/1` did; delivery, the previews and the in-context
  editor already render from typed blocks
  (`KilnCMSWeb.BlockComponents.view_blocks/1`). The legacy mapping survives
  privately in `TypedBlocks`, for reading stored rows and for the backfill's
  loss check (`legacy_loss/1`).
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="refuse-the-legacy-block-write-shape"></a>

- **Refuse a block written in the legacy `type`/`content`/`data` shape; stored
  rows in that shape are still read.** `KilnCMS.CMS.BlockUnion`'s input cast
  raises `KilnCMS.CMS.TypedBlocks.LegacyInputError` for such a block and returns
  it as an ordinary cast error naming the block and the typed shape to use —
  on every write path: the actions, JSON:API, GraphQL, seeds. Reading stays
  tolerant: a row the backfill refused and every version in (hash-chained,
  never rewritten) history keep being converted on read. Restoring a version
  from before the storage flip converts its block tree through that same read
  conversion before writing it back.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="remove-the-published-option"></a>

- **Remove the `published?:` option on `use KilnCMS.CMS.Content`; passing it now
  warns as an unknown option.** It had been ignored since every content type
  gained the `:published` read, and 0.12 deprecated it. An overlay that still
  passes it gets the same compile-time warning as any other unknown option at
  its `use` line — not an error. Unknown options stay warnings until 2.0, which
  makes them compile errors; an overlay built with `--warnings-as-errors` fails
  on it now. Delete the option.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="remove-the-editor-route-aliases"></a>

- **Remove the `/editor/pages/:id` and `/editor/posts/:id` editor routes; each
  now answers with a `301` to `/editor/content/page|post/:id`.** They were
  aliases from before the generic editor route, deprecated in 0.12. They no
  longer mount the editor, so the per-visit deprecation warning is gone too.
  The redirect exists for bookmarks and for review-request mail older releases
  sent, and costs one plain route each; it does not touch the record — the
  editor route it points at does the sign-in, the gate and the lookup. It is a
  courtesy rather than a covered surface, and a later major may drop it.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="remove-the-user-audiences-fallback"></a>

- **Remove the `User.audiences` fallback for accounts with no membership; a job
  on every boot moves such accounts onto a default-organization membership.**
  An account holding no `OrgMembership` anywhere used to read gated content
  through the global `User.audiences` column, on every site.
  `KilnCMS.Accounts.Scoping.audiences/2` now gives it `[]`, like every other
  account without a membership on the site. So that no paying or granted reader
  silently loses access on upgrade, `KilnCMS.Accounts.LegacyAudiencesWorker` is
  queued on every boot (deduplicated for a day across nodes) and gives each such
  account a default-organization membership carrying its audiences, standing
  role and any live temporary role — through
  `KilnCMS.Accounts.LegacyAffiliation`, the step billing and the console's
  audience checkboxes already take. It is a job rather than a migration because
  the step is an Ash action and migrations run without the application; until
  it has run, an unmigrated account reads only public content, never more. A
  site-provider sign-in no longer refuses a membership-less account for its
  `User.audiences`, since they grant nothing anywhere. The column is kept,
  unread: it is the only record of what a legacy account held, billing still
  writes the cross-organization union there, and 2.0 may drop it.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="stop-running-pre-012-job-shapes"></a>

- **Stop running webhook and newsletter jobs queued in a pre-0.12 argument
  shape; each is cancelled with an error in the log.** A
  `KilnCMS.Webhooks.DeliveryWorker`, `KilnCMS.Newsletter.SendWorker` or
  `KilnCMS.Newsletter.MailWorker` job without `org_id`, and the pre-ledger
  webhook job (`endpoint_id`/`event`/`payload`), ran against the default
  organization with a deprecation warning in 0.12. 1.0 cancels them instead:
  running one would mean guessing its organization, and crashing would retry a
  job that can never succeed. The error names the worker and the arguments'
  keys, not their values. Jobs 0.12 or later enqueued always carry `org_id` and
  are unaffected.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))
<a id="a-media-job-with-no-org-id-is-cancelled-not-silently-skipped"></a>

- **Edited images get new variants under strict tenancy, and a media job with no
  `org_id` is cancelled with a logged error instead of doing nothing silently.**
  `VariantWorker`, `AVWorker` and `AVStripWorker` read their item with the
  job's `org_id` as the tenant. A job without one used a `nil` tenant, and
  under strict tenancy that read failed, so the job returned `:ok` having done
  nothing. The in-admin image editor enqueued its variant regeneration that
  way, so an edited image kept its old variants. The editor now passes the
  item's `org_id`, as every other enqueue site already did. The workers now
  treat a job with no `org_id` as a bug in whatever enqueued it: they log an
  error naming the worker and the item and return `{:cancel, reason}` to Oban
  (`KilnCMS.Media.Ingest.job_tenant/2`). They do not guess the default
  organization. If such a job was queued before this release, it shows as
  cancelled; `mix kiln.media.regenerate_variants --all` re-derives variants. (#1658)

<a id="an-old-newsletter-confirmation-link-no-longer-re-subscribes"></a>

- **An old newsletter confirmation link no longer re-subscribes a reader who
  unsubscribed.** Confirmation now only moves a subscriber from pending to
  confirmed. When the subscriber has unsubscribed since, both the link's page
  and its button show a neutral "this link is no longer valid, subscribe
  again" page and change nothing. The page names no address and no status. The
  `Subscriber` `:confirm` action enforces the rule itself, so an unsubscribe
  that lands between the lookup and the write still wins. Confirming an
  already-confirmed subscriber again is a no-op that keeps the original
  `confirmed_at`. (#1690)

## Added

<a id="editor-markdown-view"></a>

- **The content editor has a Blocks | Markdown switch.** Markdown shows the
  document's blocks as one Markdown text: prose keeps its headings, lists,
  marks, links, code and tables (`PortableText.to_markdown/1`, the new reverse
  of `KilnCMS.Markdown`), and headings, dividers and plain images become their
  Markdown. A block Markdown can't express (a gallery, a form, columns, a
  media-library image) becomes a placeholder line,
  `<!-- kiln:block gallery <id> -->`, that stands for it unchanged and can be
  moved or deleted like any line. Whatever is pasted or typed is parsed as you
  go, through the same converter as paste, `.md` import and the API's
  `body_markdown`, so the preview, autosave and Save all see it, and switching
  back shows the blocks. Switching back without an edit leaves every block
  exactly as it was. An edit re-parses the text, so prose between placeholders
  becomes one rich-text block.

<a id="on-012-before-upgrading-to-10"></a>

- **On 0.12, before `mix kiln.update --allow-major` to 1.0: run the block
  backfill and `mix kiln.deprecations --migrate-audiences`, and drain the queue.**
  1.0 is a major, so `mix kiln.update` refuses it without `--allow-major`, and
  it removes what 0.12 deprecated (see *Breaking*). Three things to do while
  still on 0.12, in this order:

  1. `mix kiln.blocks.backfill` (in a release,
     `bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'`), if you have not
     since 0.12, so no stored block is still in the legacy shape.
  2. `mix kiln.deprecations --migrate-audiences` (in a release,
     `bin/kiln_cms eval 'KilnCMS.Release.deprecations(migrate_audiences: true)'`).
     It gives every account that still reads gated content through the
     `User.audiences` fallback a default-organization membership carrying the
     same audiences. 1.0 does this on its own after every deploy, but only
     moments after the node starts serving; running it first means no reader
     loses access even for that moment.
  3. Let the webhook and newsletter queues drain. `mix kiln.deprecations` exits
     non-zero while any account or queued job is left, so it can gate the
     upgrade script. A job still queued in a pre-0.12 shape is cancelled by
     1.0, with an error in the log, and its work is not done.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Changed

<a id="keep-legacy-html-as-a-fallback"></a>

- **Keep `RichText.legacy_html` as a fallback instead of removing it;
  the nested column editor now stores Portable Text.** 0.12 marked the field
  for removal at 1.0. It is the only faithful copy of prose Portable Text
  cannot hold — marks inside a code block, a list inside a quote — which is
  exactly what `mix kiln.blocks.backfill` keeps and reports, so removing it
  would have deleted that prose from the rows the backfill protected. It still
  renders, sanitized, when `body` is empty, and the exported block schema keeps
  it `deprecated`. What changes is who writes it:
  the nested column editor edited every rich-text child as raw HTML stored in
  `legacy_html`; it now stores `body`, keeping HTML only where the conversion
  would not be faithful — the rule the inline editor and the backfill already
  follow. A later major can remove the field once a converter holds what it
  keeps.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="the-release-images-latest-tag-moves-only-to-the-highest-final-release-and-from"></a>

- **The release image's `latest` tag moves only to the highest final release,
  and from 1.0.0 a floating major tag (`1`) follows the highest final release
  of its major.** The previous minor now gets security fixes for 90 days
  from short-lived branches off its tag (`.github/SECURITY.md`), so a patch
  such as `1.0.3` can be pushed after `1.1.0`. Before this change the release
  workflow moved `latest` onto every final tag it built, and the backport
  would have rolled every `docker pull …:latest` back a minor. A step now
  compares the tag against every release tag upstream
  (`scripts/release/floating_tags.sh`, covered by
  `test/scripts/release_floating_tags_test.exs`). `latest` moves only when the
  tag is the highest final release, and `1` only when it is the highest final
  `1.x`. A patch on an older line is published under its exact version only.
  Release candidates still move neither, and before 1.0.0 there is no floating
  major, since every release so far would be `0`. There is no floating minor
  (`1.0`) either: the previous minor stops getting fixes after 90 days, so a
  tag floating on it would go quiet
  ([#1544](https://github.com/The-Verscienta/kiln_cms/issues/1544)).

<a id="the-content-editors-chrome-is-on-the-component-kit"></a>

- **The content editor's chrome is on the component kit: the inspector is a
  keyboard-driven tab strip, and block controls show on focus and on touch.**
  The inspector's Preview / Settings / History switch is the kit `.tabs` with
  the ARIA tabs pattern the Form Builder got in #1680: each tab names the
  panel it controls, the panels are `tabpanel`s, only the selected tab is in
  the Tab order, and Left/Right/Home/End move between tabs. The keys come from
  one shared `TabKeys` hook (`assets/js/tab_keys.js`) that both screens use.
  A block's move, duplicate and remove controls are kit ghost buttons with the
  kit focus ring. They still fade in on hover and on keyboard focus, and now
  also while you work inside the block and always on a touch screen, which
  has no hover. The live preview's "Edit" jump was `display: none` until
  hovered, so the keyboard could not reach it. It is now faded out instead,
  which keeps it in the Tab order. The page actions are grouped: Preview,
  Side-by-side and Visual keep their words, and Media library, Copy preview
  link and Duplicate fold to icons below very wide screens, keeping their
  names for screen readers. "Add block", the block filter, gallery fields and
  the column controls use kit classes too. The accessibility chip and grade
  pill use the `*-ink` text tokens; "Needs work" was 1.38:1 in dark mode.
  "Save draft" and "Publish now" keep their names and places. Saving,
  autosave, the working copy and conflict handling are unchanged. The
  design language no longer promises device-width preview modes, which the
  editor never had
  ([#1679](https://github.com/The-Verscienta/kiln_cms/issues/1679)).

<a id="authz-check-requires-a-marker"></a>

- **`mix kiln.authz.check` accepts only an `# authorize?: false — <reason>`
  marker directly above a bypass; prose that mentions "bypass" no longer
  counts.** Internal tooling. The gate used to take any comment matching
  `authorize?` or `bypass` within 12 lines above an `authorize?: false` call
  as that call's justification. Unrelated prose therefore covered real
  bypasses: a note about a `multitenancy :bypass` read, or "the admin bypass
  above". A site is now justified only by a marker, `# authorize?: false —
  <reason>` (an em dash or `--`), whose reason has at least three words. The
  marker goes in the comment block directly above the statement the call is
  part of, with no blank line or code in between, or inside the call itself.
  A marker above a `def ... do` no longer reaches into the body. Each marker
  still justifies exactly one call, and a pipeline that reads and then loads
  now needs two. Every justified site in `lib/` was moved to the marker, and
  each reason was restated where the old comment only pointed elsewhere
  ("see `claim/4`", "(bypass: as above)"). The code itself is unchanged, and
  the `#1402` backlog counts are unchanged. The grammar is documented in the
  task's moduledoc and in `docs/policy-matrix.md`
  ([#1739](https://github.com/The-Verscienta/kiln_cms/issues/1739)).

## Fixed

<a id="a-custom-field-whose-content-type-no-longer-exists-no-longer-crashes-the-fields"></a>

- **A custom field whose content type no longer exists no longer crashes the
  Fields screen; it is listed as orphaned, with a delete.** A field
  definition stores its compiled content type's name as text and read it
  back as an atom, refusing any name with no atom behind it. A write can
  only store a registered type, but an upgraded site can still hold a
  row for a type that is gone (a removed plugin, a renamed or deleted
  type, a row from early dynamic-type testing), and every read that met
  it failed, taking `/editor/fields` down with `cannot load "…" as type
  Ash.Type.Atom`. Such a name now loads as an orphan marker instead,
  without creating an atom. `/editor/fields` lists these fields under
  *Orphaned fields* with a delete button (admins only, as before). Search's
  name-field leg skips them, and they never resolve to a content type, not
  even a dynamic type with the same name, so deleting one purges no stored
  values. The column and its stored values are unchanged, so there is no
  migration.
  ([#1770](https://github.com/The-Verscienta/kiln_cms/issues/1770))

<a id="mix-kiln-gen-content-from-works-under-strict-tenancy"></a>

- **`mix kiln.gen.content --from` works under strict tenancy, and takes
  `--org SLUG`.** The generator read the dynamic type's `TypeDefinition` with
  no tenant. The fail-open test build answered that read, but production
  compiles strict tenancy and refused it, so promoting a dynamic type failed
  there. It now reads in the organization `--org SLUG` names, or the default
  org when the option is left out, still as the operator under
  `TypeDefinition`'s read-only grant. An unknown slug, or a type that org
  does not define, stops the task with a message naming it; any other
  failed read raises as itself rather than posing as a missing type. Type
  definitions are per-site, so `--org` also picks between two sites that
  each define a type of the same name.
  ([#1743](https://github.com/The-Verscienta/kiln_cms/issues/1743))

<a id="per-type-semantic-search-ranks-a-record-the-query-names-first"></a>

- **Per-type semantic search ranks a record the query names first, however
  long the record.** The `semantic-search` JSON:API routes, the GraphQL
  semantic lists and `CMS.semantic_search_*` already exempted a record the
  query names (by title, or by a field flagged as a name) from
  `semantic_max_distance`, but still sorted it at its distance rank. A
  record's one vector is embedded from its whole text, so a long record sits
  far from a bare-name query, below short records whose names merely sound
  alike: Verscienta measured 14 of 602 acupuncture points missing the top 10
  for their own name, the best-documented ones. Named records now come first,
  nearest first among themselves, as the title leg already does in hybrid
  search. No re-embed is needed. A query that names something is no longer
  served by the HNSW index (the distance no longer leads the `ORDER BY`);
  one that names nothing is unchanged.
  ([#1746](https://github.com/The-Verscienta/kiln_cms/pull/1746))

<a id="a-seo-or-accessibility-finding-below-a-fragment-names-and-jumps-to-the-right"></a>

- **An SEO or accessibility finding below a fragment names, and jumps to, the
  right block.** The editor inlines fragments before analysing the body, and
  one fragment becomes any number of blocks — so every finding after it
  carried its position in the expanded list rather than its card's index,
  and its "block N" link named and scrolled to the wrong card. Findings now
  carry the index of the top-level block they came from
  (`Fragments.expand_indexed/3`, `Kiln.Advisory.Body.from_indexed/1`);
  content inlined from a fragment reports against the fragment's own card.
  ([#1731](https://github.com/The-Verscienta/kiln_cms/pull/1731))

<a id="search-holds-at-most-two-pooled-connections-and-answers-503-rather-than-500"></a>

- **Search holds at most two pooled connections, and answers `503` rather
  than `500` when the pool is full.** `GET /api/search` also writes its
  analytics off the request now, and sends `Retry-After` with the `503`.
  Found by the v1.0 latency benchmark: at 50 concurrent clients search's p95 was 0.4–2.2 s,
  and an earlier run answered hundreds of `500`s — `connection not available
  and request was dropped from queue` — while every other API surface stayed
  under 50 ms. `Search.global/2` ran up to four sections at once, each with a
  query in flight, so two and a half searches filled a 10-connection pool;
  `section_concurrency` now defaults to 2 (a lone search is still twice as
  fast as at 1, and a busy node was no slower). Holding one checkout for the
  whole search was tried first and rejected: the benchmark answered nearly
  every request of a ten-client run with a 503, because a held connection
  idles across work that needs the pool too. The title leg built a tsquery
  from every title on every search — a sequential scan, 6–7 ms on 1,700
  posts whether anything matched or not; a GIN index on each title's
  lexemes, and a prefilter on it that the phrase match implies (so it
  returns the same rows), make it 0.04–0.5 ms. Every leg read whole rows —
  block trees, `search_text`, the embedding — to keep ids; the legs now read
  ids, the hits kept are read once with their calculations, and
  `/api/search` reads only the fields it renders (so does its "did you
  mean"). `/api/search` wrote the `search_queries` upsert inline, where
  concurrent searches for one term queued on its row lock holding
  connections; it now goes through the bounded task supervisor like the
  editor palette's (`docs/performance.md` said it already did). And the
  endpoint no longer runs the media section it never returned. Warm p95,
  before → after: 52 → 26 ms for one client and 438 → 314 ms for fifty on a
  rare word; 67 → 36 ms and 2,161 → 574 ms on a word every document
  contains, at three times the throughput. Ranking is unchanged — a new test
  pins the exact ranked output, scores and legs of a fixed corpus,
  keyword-only and hybrid, as recorded before the change. The full table is
  in [`docs/performance.md`](../performance.md#search-and-the-pool)
  ([#1712](https://github.com/The-Verscienta/kiln_cms/issues/1712)).

<a id="a-job-killed-by-a-deploys-shutdown-is-rescued-after-three-hours-instead-of"></a>

- **A job killed by a deploy's shutdown is rescued after three hours instead of
  staying `executing` for ever.** Stopping a node gives running Oban jobs 15 s
  and then kills them. Kiln ran no rescuer, so the row stayed `executing` for
  good: never retried, never discarded, and for a `unique` worker (fire,
  static export, embeddings, link checks, the occurrence backfill) it blocked
  every later enqueue of the same job. `Oban.Lifeline` now runs, appended to
  the plugin list at boot next to the injected crontab. It moves a job `executing` for longer than
  `KILN_OBAN_RESCUE_AFTER_MINUTES` (default 180) back to `available`, or to
  `discarded` once its attempts are spent. The rescue goes by time alone, so
  the window must exceed the longest legitimate job. That is a backup
  (2 h timeout), and a test now fails if any worker's `timeout/1` comes within
  30 minutes of the window. A rescued job starts over, so the newsletter
  fan-out was made safe to repeat: `MailWorker` is now `unique` on
  `{send, subscriber}` across every state, so a second fan-out run (rescued, or
  an ordinary retry after a crash part-way through) enqueues only the
  recipients the first run missed. Before, it mailed everyone again.
  [`deploy.md`](../deploy.md#jobs-interrupted-by-a-deploy) lists what each
  kind of job does when it is rescued
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718)).

<a id="an-organizations-slug-must-be-a-hostname-label-and-is-stored-lowercase"></a>

- **An organization's slug must be a hostname label, and is stored lowercase.**
  Tenant resolution downcases the request host and then matches the slug
  exactly, but the slug had no format rule, so an org created as `Acme` or
  `my_site` could never be reached at its subdomain. It could not be reached at
  its console host `<slug>.<console host>` either. Creating or changing a
  slug now trims and downcases it, then refuses anything that is not a DNS
  label: 1 to 63 of `a-z`, `0-9` and `-`, not starting or ending with `-`. It
  also refuses `www`, `console`, `api` and `mail`, and the first label of
  `KILN_CONSOLE_HOST` when that host sits directly under the base host. An
  existing slug is only checked when it is changed, so an org stored before
  this rule can still be renamed or suspended
  ([#1710](https://github.com/The-Verscienta/kiln_cms/issues/1710)).
<a id="on-a-multi-org-deployment-with-kiln_console_host-set-add-console-host-to-dns"></a>

- **On a multi-org deployment with `KILN_CONSOLE_HOST` set, add
  `*.<console host>` to DNS and TLS before upgrading.** A console route on a
  non-default organization's site now redirects to that organization's own
  console host, `<slug>.<console host>`, instead of to the default
  organization's console, where that organization's admins had no access.
  That host has to resolve to Kiln and be covered by the certificate: a
  certificate for `*.example.com` does not cover `acme.console.example.com`.
  Anyone signed in on the bare console host signs in again on their
  organization's console host. Single-org deployments and deployments without
  `KILN_CONSOLE_HOST` are unaffected. If the console host is not under
  `PHX_HOST`, Kiln now warns at boot that passkeys cannot work there, which was
  already the case
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).

<a id="unreadable-stored-blocks-no-longer-fail-delivery"></a>

- **A stored block of a type the build no longer has, or one that is not a
  block, no longer fails its page's delivery.** Both are rows the backfill
  refuses (`:unknown_type`, typically a block from a removed plugin, and
  `:unrecognized`), so they stay at rest — and until now every read of such a
  row raised, taking the page down with it. They now read as a `custom` block
  carrying the stored payload whole, which renders as a marker comment; the
  row is not rewritten. Every row the backfill corpus says it must refuse is
  now delivered in a test.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Security

<a id="password-rotation-revokes-every-session"></a>

- **Changing or resetting a password now signs out every other session and
  remember-me cookie.** `KilnCMS.Accounts.User` has long declared
  `log_out_everywhere apply_on_password_change? true`, and the docs treated
  that as the control. It never fired. AshAuthentication hangs its change on
  `hashed_password` being *touched*, and checks that when the changeset is
  built. Both password actions, `:change_password` and
  `:reset_password_with_token`, write the hash later, in a `before_action`, so
  the check always saw it untouched. Every session JWT, and the 30-day
  remember-me cookie, of whoever held the old password kept signing them in,
  as the external auth review for #1536 confirmed. Both actions now declare
  `KilnCMS.Accounts.Changes.RevokeAllTokens`. It runs the add-on's own
  `log_out_everywhere` action inside the write's transaction, through
  AshAuthentication's interaction bypass, so it needs neither
  `authorize?: false` nor a system actor. It fails closed: if the revocation
  cannot be written, the password is not changed either. Every stored token
  the account holds is revoked. That covers every session, the remember-me
  cookie, pending confirmation and magic-link tokens, and a sign-in parked at
  the two-factor prompt (#742), because a reset means the old password may be
  someone else's. The reset also signs the resetting browser in, and that
  session is minted after the sweep, so it survives it. The reset now evicts
  the account's live sockets too, as `:change_password` already did
  ([#1637](https://github.com/The-Verscienta/kiln_cms/issues/1637)), so a
  console already open on another device is disconnected, and its reconnect
  finds no token to mount on. Both evictions now broadcast after the commit
  (`EvictSessions`' new `after_commit?: true`), so a fast reconnect cannot
  read the token before its revocation lands. One behaviour change: the
  device that changes its password in settings is signed out too. A
  LiveView cannot write the cookie a re-issued session would need, and after
  a rotation the old password no longer proves who holds a session. The
  settings page now says "Password changed. Sign in again with your new
  password." and goes to `/sign-in`
  ([#734](https://github.com/The-Verscienta/kiln_cms/issues/734)).

<a id="the-editors-link-advisory-no-longer-reveals-content-the-editor-cannot-read"></a>

- **The editor's link advisory no longer reveals content the editor cannot
  read.** To tell an author whether a same-origin link's target is published,
  `KilnCMS.Links.Internal` looked the target up with authorization off. An
  editor whose content-type scope did not cover a type could type a guessed
  path into a link and learn from the advisory that a draft existed there, and
  in which state. The lookup now runs as the editor, under the content read
  policies, so a target they may not read is reported as missing, the same
  answer as no target at all. `resolve/3` and `resolve_all/3` take the actor
  as a fourth argument
  ([#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659)).

<a id="kiln_console_host-now-isolates-every-organizations-console-each-on-its-own"></a>

- **`KILN_CONSOLE_HOST` now isolates every organization's console, each on its
  own `<slug>.<console host>` origin.** Until now the console host was the
  default organization's console only. On a multi-org deployment, setting it
  sent every other organization's editors to a console they could not use.
  Leaving it unset kept each console same-origin with its site's code
  injection, where one tenant's admin could act with other tenants' editors'
  sessions (threat model residual risk 16). Now the bare console host stays
  the default organization's console, and `KilnCMSWeb.Tenant` resolves
  `<slug>.<console host>` to the organization with that slug, the way it
  resolves `<slug>.<base host>`. Org resolution stays host-derived, so every
  socket and LiveView keeps the tenant it connected on. No console host
  serves delivery, no two organizations' consoles share an origin, and the
  host-only session cookie on one console host is never sent to a site or to
  another console. The console host no longer resolves as the organization
  whose slug is its first label. Passkey ceremonies now also accept console
  origins, under the unchanged relying-party ID, so existing passkeys work
  there with no re-enrollment. Before this, every passkey ceremony on a console
  host failed Wax's exact-origin check. Tenant site origins are still refused,
  because code injection runs on them. Console hosts are added to the socket
  origin check automatically. The reasoning, including why the design uses
  one host per organization rather than one shared console host that switches
  organization, is
  [decision record 0011](../decisions/0011-each-organization-gets-its-own-console-origin-under-the-console-host.md)
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).
<a id="before-upgrading-to-10-run-the-block-backfill"></a>

- **Before upgrading to 1.0, run `mix kiln.blocks.backfill` on 0.12, and move any
  code that writes legacy `type`/`content`/`data` blocks to the typed shape.**
  1.0 still *reads* a block stored in the pre-typed shape, so nothing breaks
  on delivery if you skip the backfill — but every read keeps converting it,
  and the backfill's report is where you learn which rows it could not convert
  (`bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'` in a release). Any
  overlay, plugin, seed or importer that *writes* `%{type: :heading, content:
  …, data: …}` now gets a cast error: write `%{"_type" => "heading", "text" =>
  …}` instead. 0.12's compile warnings on `to_legacy/1` and `from_legacy/1`
  point at the calls that become compile errors.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="newsletter-sign-up-honeypot-matches-forms"></a>

- **The newsletter sign-up honeypot and public forms trip on the same rule.**
  The two surfaces render the same hidden `website` input but checked it
  differently: forms trimmed a string value first, so a whitespace-only value
  passed as human, while newsletter sign-up had its own inline test. Both now
  call `KilnCMS.Forms.honeypot_tripped?/1`, and it is the stricter reading:
  only an absent field or the empty string an untouched input submits counts
  as a human. Any other value trips it, including whitespace-only strings and
  non-string values such as a list or a map. A tripped honeypot still reports
  success and stores nothing on both surfaces. (#1657)
<a id="automation-rules-are-set-up-with-ordinary-fields-instead-of-a-json-box"></a>

- **Automation rules are set up with ordinary fields instead of a JSON box.**
  The "Action config (JSON)" textarea on `/editor/automation` is gone. Picking
  a reaction now shows one input per setting it takes, such as an email field
  for "Send to", a network picker for social posts, a person picker for task
  assignees, and a toggle for `allow_egress`, with the required ones marked.
  The intelligence reactions show the fields for the chosen "Send findings as"
  option (email, comment or task) and hide the rest. Template fields have
  chips that insert `{{title}}` and the other placeholders. The inputs are
  generated from `ActionConfig`'s shape table, so the form cannot offer a key
  the save refuses. The validation itself is unchanged and still refuses the
  string `"true"` for `allow_egress` from the API and seeds. Stored rules need
  no migration.

<a id="the-automation-builder-reads-as-steps-and-says-each-rule-back-as-a-sentence"></a>

- **The automation builder reads as steps and says each rule back as a
  sentence.** `/editor/automation` is now four numbered steps: when (content
  type and event, the events grouped as editorial changes, tasks and content
  health), do this, set it up, and name it. The reaction dropdown is a set of
  cards grouped as "Notify people", "Review & follow-up" and "Keep the site
  fresh", each with an icon and a line on what it does. While the rule is
  being built, the form shows it as one sentence, such as "When Post content
  is published, email team@example.com." The rules list shows that sentence
  in place of `post.published → send_email`, and a rule saved with no name is
  named by it — and stays named by it through later edits, until someone types
  a name of their own. A task event scoped to a content type (a rule that
  could never fire) is called out in the builder instead of being worded as if
  it worked.

<a id="the-automation-builder-offers-ready-made-recipes-and-a-preview-on-real-content"></a>

- **The automation builder offers ready-made recipes and a preview on real
  content.** Above the builder,
  "Start from a recipe" lists six common rules, among them "Email me when
  something is published" (addressed to the admin), "Create a task when
  content goes stale" and "Announce new posts on social media". Picking one
  fills in the form without saving anything. The admin reviews it, fills in
  what the recipe can't know (such as which network), and adds the rule as
  usual. The gallery is open while a site has no rules and folded once it has
  some.

  A final "Try it" step picks a recent piece of content and shows what the
  rule would do to it: the email with its subject and body rendered, the
  social post text and how many accounts would post it, the task with its
  assignee, due date and note, or why nothing would happen (an open review
  task already covers it, a newsletter would skip a translation). The preview
  follows the rule as it is edited. It uses the same templating, defaults and
  checks as the real reaction (`RuleWorker.preview/4`) and sends, posts and
  saves nothing. The four AI reactions are described rather than run, since
  running them costs what the rule costs and may send the page off-site.

<a id="console-lists-share-one-empty-state-long-settings-pages-get-a-table-of-contents"></a>

- **Console lists share one empty state; long settings pages get a table of
  contents; screen crumbs point at their real parent.** Trash (content and
  media), Taxonomy, Inbox, the search palette, Governance, Team, Social,
  Experiments, Newsletter, Webhook deliveries, Federation followers and Form
  Builder entries now render the kit `<.empty_state>` — a title, one line on
  what will appear there and, where there is one, the next step (Inbox's
  empty Unread filter offers "Show all notifications") — instead of a bare
  muted sentence. Your settings, Outgoing mail and Mail carry an "On this page"
  contents: plain anchor links to the page's own section ids, sticky in a right
  column on wide screens and a row of chips on narrow ones, no JavaScript. The
  Form Builder's section switcher is the kit `.tabs` with the full ARIA tabs
  pattern (tablist/tab/tabpanel, `aria-selected`, roving `tabindex`,
  Left/Right/Home/End). And the "← All content" crumb that sixteen non-content
  screens (Team, Billing, Mail, Webhooks, …) carried now names the screen's
  parent, read from `KilnCMSWeb.ConsoleNav`: the Configure hub section it is
  listed under, or Home
  ([#1678](https://github.com/The-Verscienta/kiln_cms/issues/1678),
  [#1680](https://github.com/The-Verscienta/kiln_cms/issues/1680)).

<a id="accounts-system-reads-run-under-the-policies"></a>

- **The accounts domain's system reads run under the policies.**
  `Accounts.list_org_ids/0` (the tenant list behind AshOban's per-tenant
  scheduler scans, GDPR erasure, audit verification and the digests),
  `Accounts.default_org/0` and the membership half of a data-subject export
  reached `Organization` and `Billing.Membership` through `authorize?: false`.
  They now run as `KilnCMS.Accounts.system/0`. `Organization` admits it for
  the plain `read` only: not the request path's tenant resolution
  (`by_slug`, `by_custom_domain`), and not create or update. All three reads
  fail closed. A refused tenant list raises instead of answering `[]`, which
  every sweep would have read as "no orgs, nothing to do"; a refused
  default-org read answers `:error`, not the "seed row missing" `nil`; and a
  refused export read is logged as an error. The 20 remaining sites in the
  domain are the pre-auth flows (sign-in, the second factor and its hold,
  passkeys, SSO, `/setup`) and the membership lookup inside the policy checks
  themselves. They keep `authorize?: false`, each with its reason at the call
  site: there is no actor yet, and a bypass cannot be refused into "no such
  token" or "no membership". The `mix kiln.authz.check` backlog drops by 23
  sites and 11 files. No change to any sign-in response. (#1659)

<a id="federation-runs-under-the-policies"></a>

- **Federation runs under the policies.** The inbox, the publish fan-out, the
  delivery worker, the replay-nonce store and its sweeper, and
  `mix kiln.federation` reached `Follower`, `Delivery`, `Block`,
  `SiteFederation` and `SeenSignature` through `authorize?: false`, which skips
  every policy on the resource. They now run as `KilnCMS.SystemActor`, and
  each resource admits it for exactly what it needs: the follower list in full,
  the delivery ledger's `create`/`settle` (not its prune), the block list's
  reads (not its writes), the site settings' read, delivery stamp and the
  operator's `enable`/`disable`/`rekey` (not the settings form), and the nonce
  store's `record`/`expired`/`destroy` (not a plain read). `KilnCMS.CMS.OrgSettings`
  gains a `system_actions:` option that narrows the grant inside the macro's
  policies. The `mix kiln.authz.check` backlog drops by 24 sites and five files.

  Two of those reads used to fail **open**, and now fail closed whatever the
  grants say. The replay-nonce write logged and accepted on the date window
  when the store refused or failed it; the inbox now answers such a delivery
  `503` with `Retry-After: 60`, so an honest sender retries it and a replay is
  never accepted unrecorded. And the inbox's follower-ceiling count, which a
  refused read would have answered with 0, is preceded by a one-row read with
  `authorize_with: :error`; a refusal or a failed count is treated as "at the
  ceiling", and the follow is refused and logged. Honest senders see no
  difference unless the nonce store is down. (#1659)

<a id="notifications-and-web-push-run-under-the-policies"></a>

- **Notifications and Web Push run under the policies.** The notifier and the
  push pipeline reached `CMS.Task`, `CMS.Comment` and
  `Accounts.PushSubscription` through `authorize?: false`. They now run as
  `KilnCMS.Notifications.system/0` and `KilnCMS.Push.system/0`, both
  `KilnCMS.SystemActor`s, and each resource admits them by action name: the
  task digest's reads and its "`task.overdue` already fired" stamp (named
  inside `Task`'s update policy, so the actor still cannot complete or edit a
  task), a comment thread's participants (the existing `Comment` read grant),
  and push delivery's `for_users`, `read`, `touch_delivered` and `destroy`
  (not the settings list or the key-rotation sweep). A browser now registers
  its push subscription as the signed-in user, and `subscribe` admits only a
  row whose `user_id` is the actor's own, where before it was bypassed. Reads
  of `Accounts.User`, `OrgMembership` and content keep their bypass, each with
  a written reason. The `mix kiln.authz.check` backlog drops by 18 sites and
  six files.

  The lookups that decide who hears about something now fail **closed**. A
  refused read filters to `[]`, which here meant "nothing due", "nobody on the
  thread" or "no devices": the notification was dropped and nothing said so.
  They run with `authorize_with: :error`. The digest job fails where Oban
  shows it, the comment notifier logs, the push sender logs the refusal
  (`notify/2` still never raises into the editorial action), and the push
  worker returns an error for Oban to retry instead of treating the device as
  gone. The overdue stamp is the digest's dedupe, so it is now an atomic claim
  (a second run's stamp of the same task is refused) written in one
  transaction with the event's dispatch: both commit or neither does. A stamp
  that cannot be written leaves the task for the next run instead of re-firing
  the event every day. One org's failure no longer stops the others, and a
  retried digest job does not mail the same digest twice. The unread badge still counts a failed read as zero, since
  it is the reader's own inbox under their own actor, but the failure is now
  logged. Apart from `subscribe` and the stamp order, nothing changes while
  the grants are in place. (#1659)

<a id="funnel-lookups-and-the-operator-mix-tasks-run-under-the-policies"></a>

- **Funnel lookups and the operator mix tasks run under the policies.** The
  experiment engine read funnel definitions with `authorize?: false` in three
  places: delivery's cached map of each funnel's last step
  (`Experiments.funnel_targets/1`), the `:start` guard for a
  `:funnel_completion` goal, and `mix kiln.experiment --goal-funnel SLUG`. All
  three now read as `KilnCMS.Analytics.system/1`, which `Funnel` and
  `FunnelStep` admit to their primary `read` and nothing else: not a write,
  not the builder's `:for_funnel` read, and no traffic resource. Each read uses
  `authorize_with: :error`. Before, a refused read on the delivery path would
  have filtered to nothing and been cached as "no funnel targets", so every
  funnel experiment would silently stop converting for the cache TTL. It now
  logs and is not cached. A refused slug lookup now raises instead of
  reporting "No funnel with id or slug" for a funnel that exists.
  `mix kiln.gen.content --from` reads the type definition as the operator,
  under `TypeDefinition`'s existing read-only grant. The other operator mix
  tasks keep `authorize?: false`, each with a comment saying why: whole-corpus
  content reads (`kiln.audit.verify`, `kiln.embed_all`), an every-org tag
  backfill, and organization-registry lookups the operator is not a member of
  (`kiln.federation`, `kiln.search.eval`, `kiln.search.measure_floor`). No
  mix task is left in the `mix kiln.authz.check` backlog except the part of
  `kiln.experiment` that #1659's experiments batch covers. (#1659)

<a id="event-log-and-settings-run-under-the-policies"></a>

- **The event log and the per-site settings run under the policies.**
  `KilnCMS.History` (the block-level event log), the
  `Feeds`, `Compliance.Settings`, `Branding` and `CodeInjection` resolvers, the
  automation rule match, the event helpers, the schema export and search's
  vector legs and query counter reached their resources through
  `authorize?: false`. They now run as `KilnCMS.SystemActor`, admitted by action
  name: `DocumentEvent`'s `append`, `anonymize_actor`, `for_document` and a new
  `by_actor` read (not the plain `read`); `FeedSettings` and `SiteCompliance`
  for `read` only, through `OrgSettings`' `system_actions:`; `SearchQuery` for
  `record` only. `FieldDefinition`, `Automation.Rule` and the two embedding
  tables already admitted the system actor.

  Every migrated read that decides something fails **closed**
  (`authorize_with: :error`); only search's two vector legs, which feed a
  ranked result list, do not. A refused read
  filters to "nothing", and here that answer was never harmless: the event
  log's sequence read would hand out a number already taken, the GDPR erasure
  sweep would redact nothing and report success, a settings resolver would
  cache the operator config for the whole TTL (turning full-content feeds back
  on, or a site's publish gate off), the rule match would drop every automation
  while the job succeeded, and the event helpers and schema export would read a
  type as having no fields. `Automation.dispatch/3` now returns
  `{:error, reason}` when the rules cannot be read, so the dispatch job retries;
  it used to swallow a failed read too.

  `History.record/5` also reads the next sequence number under the document's
  own org. It read with no tenant, which strict tenancy (the production
  default) refuses, so every append raised there. `replay/3` and `preview_at/3`
  take an `:org_id` option for the same reason.

  Eleven sites keep `authorize?: false`, each with its reason at the call site:
  content reads and the collaborative checkpoint's draft write (a system grant
  there would be a standing read or write over every draft), the operator
  CLIs' account and org lookups (they find the actor, so there is none yet),
  and the staging scrub's erasure. The `mix kiln.authz.check` backlog drops by
  28 sites and 15 files. (#1659)

<a id="cms-helpers-run-under-the-policies"></a>

- **Content releases, slugs, menus and the field registry run under the
  policies.** The CMS's helper modules reached their resources through
  `authorize?: false`. They now run as the caller where the caller is
  entitled, as a `KilnCMS.SystemActor` (`KilnCMS.CMS.Housekeeping`) where
  there is no caller, and keep a written justification where neither fits.
  The release go-live worker reads a release and lists its items by status,
  records the outcome (`mark_*` on `ContentRelease` and `ReleaseItem`, which
  no person, admin included, may call) and abandons its own crashed claim;
  it cannot start, schedule or compose a release. The system actor may read
  `SiteEditorialSettings`, not save it. Menus and taxonomy are read with no
  actor under their world-readable policies, the field and type registry as
  the system, and the governance dashboard's content-health panel and CSV
  export as the person looking. The content reads that decide slug and alias
  uniqueness keep their bypass on purpose: a filtered read would report a
  taken slug as free.

  Several reads now fail **closed** instead of answering "nothing": a
  refused release-item read raises rather than publishing (or rolling back)
  an empty release; the release worker records a refused read as an error
  rather than logging the release as vanished; a refused registry read
  raises rather than deriving a slug from the default pattern, dropping a
  dynamic type's URL prefix from the reserved segments, or rejecting a
  `custom_filter` as an unknown field; and `TaskSettings.site_default/1`
  raises rather than applying the shipped default. The `mix kiln.authz.check`
  backlog drops by 37 sites and 17 files. (#1659)

<a id="the-cmss-own-bookkeeping-runs-under-the-policies"></a>

- **The CMS's own bookkeeping runs under the policies.** The changes behind a
  publish, an unpublish, a rename, a restore, an autosave, a comment, a
  release archive and a form submission reached `Task`, the content resources,
  `Redirect`, `FormSpamSettings`, `FieldDefinition`, the version history and
  more through `authorize?: false`. Where the caller is entitled they now run
  as the caller: the comment thread lookup, the release-item cancel, the
  version history a restore folds, the autosave rows it coalesces, and a
  custom field's media or content reference, so an editor can no longer learn
  a draft's title they may not read by referencing its id. Where the write is
  the action's consequence rather than the caller's they run as
  `KilnCMS.CMS.Bookkeeping.system/0`: completing a record's open tasks
  (`Task` admits it to `:complete` only), pointing `published_version_id`
  (content admits it to `:set_published_version_id` only), writing a
  rename's 301 (`Redirect` admits `:create` and `:destroy`), reading the
  field registry, and reading the spam keywords (`FormSpamSettings`, `read`
  only). Six sites keep `authorize?: false` with a written reason: the
  version-row rewrite and prune (no actor may update or delete history), the
  publish-version lookup, and three content reads that never leave the change.
  The `mix kiln.authz.check` backlog drops by 26 sites and 15 files.

  The reads a write depends on now fail closed. A refused field-registry
  read used to filter to "no definitions", and the cleaned map is folded out
  of the definitions: a partial `custom_fields` write would have silently
  stored `{}`. A refused manual-boundary read in autosave coalescing would have
  answered "no manual save" and deleted autosaves on its far side. A refused
  thread read would have started a second root; a refused pending-items read
  would have archived a release with its items still reserving their content;
  a refused spam-keyword read (or a read error) scored a submission as if the
  site had no keywords. Each now raises, fails the write, or keeps the rows. A
  published rename whose 301 cannot be written now fails instead of vacating
  the URL. (#1659)

<a id="cms-validations-look-things-up-under-the-policies"></a>

- **CMS validations look things up under the policies.** Eight CMS validations
  checked a reference with `authorize?: false`: the release item checks
  (release open, content exists, release size cap), tag group ownership, menu
  item placement, slug-pattern tokens, and the required-consent and alt-text
  publish gates. Six of them now read **as the caller**, with the actor and
  authorization mode of the action they guard, so an editor's lookup runs
  under the editor's policies and a trusted caller that bypassed the action
  reads the same way. The two publish gates also run for the AshOban
  scheduler, which has no actor, so they read as a scoped system actor, which
  `CMS.Consent` admits to `for_content` only and `CMS.MediaItem` to the plain
  `read` only. Every lookup passes `authorize_with: :error`, so a refusal is
  an error, never a shorter answer. The release size cap used to count an
  unreadable release as empty and let the add through. It now refuses. A
  refused publish-gate read refuses the publish ("could not be checked"). The
  task assignee check keeps its bypass with a justification: `User` is
  readable only by its owner. The `mix kiln.authz.check` backlog drops by 11
  sites and nine files. (#1659)

<a id="the-media-pipeline-and-public-forms-run-under-the-policies"></a>

- **The media pipeline and public forms run under the policies.** The variant,
  A/V and metadata-strip workers, the quarantine reaper and the variant
  regeneration scan reached `MediaItem` through `authorize?: false`; so did the
  form submission pipeline, its two mail workers, the autoresponder's field
  lookup and the embed route's per-site framing default (`Form`, `FormField`,
  `FormSubmission`, `SiteEmbedSettings`). They now run as `KilnCMS.Media.system/0`
  and `KilnCMS.Forms.system/0`, and each resource admits them by action name.
  The media pipeline writes what it derives through a new `:record_processing`
  action rather than `:update`, so it cannot gate an item or edit its tags or
  alt text, and it may `:purge` an item only while it is still quarantined. The
  form pipeline may create a submission but never read one back. The
  `mix kiln.authz.check` backlog drops by 18 sites and ten files.

  The reads a decision rests on now fail closed. A refused worker re-read used
  to look like "the item was deleted", and the job succeeded having done
  nothing; for the metadata strip that left the upload quarantined until the
  reaper deleted it. A refused form-field read would have validated a
  submission against no fields at all. A refused mail-worker read dropped the
  notification or the visitor's confirmation. Each now raises or fails the job
  so Oban retries it. An embed default that cannot be read resolves to
  same-origin only instead of falling through to `EMBED_ORIGINS`, which could
  be wider than the site's own `[]`.

  **Fixed along the way:** `KilnCMS.Media.QuarantineReaper` read across every
  site without a tenant, which strict tenancy (the production default)
  refuses, so the hourly reaper raised and no stuck quarantine was ever
  removed. It now scans through a `multitenancy :bypass` read,
  `:quarantine_expired`, which only the system actor may run (admins
  included). (#1659)

<a id="billing-webhook-pipeline-runs-under-the-policies"></a>

- **The billing webhook pipeline runs under the policies.** The webhook
  worker, the resolution ladder that finds an event's membership, the
  provider-state write, the membership trail and the entitlement recompute's
  reads reached `WebhookEvent`, `Membership` and `MembershipEvent` through
  `authorize?: false`. They now run as `KilnCMS.Billing.system/0`.
  `WebhookEvent` admits it by name for the plain read, `claim` and the three
  settle stamps, and for nothing else: it may not record, list, look up or
  delete an event. The receiver keeps its bypass, since the provider's
  signature is its grant.

  A refused read answers `[]` or `nil`, and in billing both answers used to be
  acted on. `nil` for the event meant "gone", so the job cancelled. `nil` or
  `[]` for its membership meant "unresolvable", so the event was marked
  ignored. `[]` for a user's entitling memberships meant "entitled to
  nothing", so the recompute stripped a paying member's audiences. Each of
  these reads now uses `authorize_with: :error`. A refusal is an error: the
  event is marked failed and Oban retries it, and the recompute aborts and
  rolls back with its transition, so the member keeps what they had. A refused
  claim retries instead of cancelling as "already claimed", and the settle
  stamps, whose results were discarded, now log when they fail.

  The recompute's own writes are now all or nothing. A failed write of a
  per-org membership used to be dropped: `create_missing` answered `:ok` to
  its own error, and the sync of an existing row ignored its result. That
  could leave a payer's `User.audiences` rewritten while the org membership
  that access actually reads never got the audience. Every write of one
  recompute now runs in one transaction. Any failure rolls the others back,
  is logged with the user and org ids, and fails the membership transition,
  so Oban retries it. A concurrent recompute's row is still not an error:
  the upsert that meets it succeeds and changes nothing.

  The `User` and `OrgMembership` reads and writes in the recompute, and the
  account and content steps in `mix kiln.beta.round`, keep `authorize?: false`
  with a written reason. A system grant over either would be a standing power
  over every account. None of them can be refused, so none can mistake a
  refusal for "no such row". The `mix kiln.authz.check` backlog drops by 23
  sites and six files. (#1659)

<a id="webhooks-social-posting-and-mail-run-under-the-policies"></a>

- **Webhooks, social posting and mail run under the policies.** The webhook
  dispatch and delivery worker, the social announcer and `Social.configured?/1`,
  and the mail pipeline's settings and suppression-list calls reached their
  resources through `authorize?: false`. They now run as
  `KilnCMS.Webhooks.system/0`, `KilnCMS.Social.system/0` and
  `KilnCMS.Mail.system/0`. Each resource admits the system actor by action name
  inside its existing admin policy: webhook endpoints' reads and health
  counters (not create, edit or delete), the delivery ledger's `read`, `create`
  and `record_attempt` (not `destroy`), the social ledger's `claim` and four
  settling updates (not read or `destroy`), the social account's `record_post`
  stamp, the mail settings' `read` and `init` (not the DKIM or server-IP
  writes), and both suppression lists' `read` and `suppress` (not clearing
  one). The account's organization lookup in `Social.canonical_url/1` stays a
  bypass with its reason written down. The `mix kiln.authz.check` backlog drops
  by 17 sites and five files.

  Each read below used to answer a refusal with "nothing", and each "nothing"
  was a decision. They now pass `authorize_with: :error`:
  - the dispatch's endpoint scan ("nobody subscribed", so no webhook and no
    trace) now logs the refusal; it does not raise, because it runs after the
    publish has committed;
  - the delivery worker's ledger read ("row pruned", so the job succeeded
    without sending) and endpoint read ("endpoint deleted", so the row was
    settled as failed) now log and retry. The endpoint is read on its own, not
    through `load:`, because a relationship load filters under its own rules;
  - the mail settings read (`nil`, "not set up", which the DKIM signer takes
    as "no key" and sends unsigned) now raises;
  - the suppression lookups ("not suppressed", which would resume mail to every
    hard-bounced address) now raise. `Mail.enqueue!/2` drops a recipient it
    cannot check and logs it; the newsletter worker's job retries.

  A ledger write that fails after a webhook's `2xx` is logged and no longer
  fails the job, so Oban does not send the webhook a second time. A failed
  social ledger write, or a hard bounce the suppression list refused to
  record, is logged instead of swallowed. (#1659)

<a id="content-experiments-run-under-the-policies"></a>

- **Content experiments run under the policies.** The delivery path (the
  running-set read and the impression and conversion counters), the `:start`
  and variant-write guards, the results panel and `mix kiln.experiment` reached
  `Experiment`, `Variant` and `VariantDay` through `authorize?: false`. All but
  the results panel now run as `KilnCMS.Experiments.system/0` (the mix task labels itself
  `:operator`), and each resource admits it by action name inside its existing
  admin write policy: experiments' reads plus `create`, `start` and `conclude`
  (not `update`, `archive` or `destroy`); variants' reads plus `create` (not
  re-weighting or removal); and the two counters plus a read on `VariantDay`
  (not `destroy`, so a system caller cannot erase a result). Promotion now
  loads the winning variant, and the results panel reads the counters, as the
  editor instead of bypassing.

  Every read behind a decision passes `authorize_with: :error` (and an
  experiment's variants load with `authorize_read_with :error`), because a
  refused read would otherwise answer `[]`, the permissive answer each time:
  "nothing is running" (every experiment silently stops serving and counting),
  "no other experiment on this document" (a second one starts), "0 served, 0
  converted" on every arm, and "No experiments on this site" from the mix task.
  A lost grant is now an error (`:start` returns `Forbidden`). Delivery still
  never fails a page: it serves the canonical document, as it always did when
  the experiment layer could not answer, and now logs why — and no longer
  caches that failure as "nothing is running" for five minutes; a refused
  counter write is logged too, instead of swallowed. Content and form lookups
  in `Health` and `GoalConfigured` stay bypasses with their reason written
  down (the #1402 content-read argument).
  The funnel lookups stay in the backlog for the analytics batch. The
  `mix kiln.authz.check` backlog drops by 19 sites and six files. (#1659)

<a id="the-governance-audit-chain-runs-under-the-policies"></a>

- **The governance audit chain runs under the policies.** The anchor chain,
  the checkpoint worker and the governance dashboard reached `HistoryAnchor`,
  `ChainCheckpoint`, `ChainCheckpointEntry` and `MembershipEvent` through
  `authorize?: false`. They now run as `KilnCMS.Governance.system/0`, a
  `KilnCMS.SystemActor`, and each resource admits it by action name inside its
  existing admin-only policy: an anchor's `create` and per-document
  `for_content` (not the plain read), every checkpoint action by name (so a
  later `destroy` is not admitted by default), and an entry's `create`,
  `for_content` and `for_checkpoint` (not the plain read). The sites that read
  content, `Accounts.User` names, consents or version rows keep their bypass,
  now with a written reason: a standing system grant over any of those would
  be wider than the one dashboard it serves. The `mix kiln.authz.check`
  backlog drops by 24 sites and four files.

  Every one of the migrated reads now fails **closed**. A refused read filters
  to `[]`, and here `[]` always meant the permissive answer: "never anchored",
  "never witnessed" (which is what a truncation wants to look like), "no
  unwitnessed checkpoints" (a witness outage shown as healthy), "no earlier
  checkpoint" (the chain restarting at 1), or an empty entitlement trail. They
  run with `authorize_with: :error`, so a lost grant raises instead: the
  witness lookup reports the document `:unreadable` and the verdict floors to
  `:unverifiable`, and the anchor hook logs and mints nothing rather than a
  chain restarted from scratch. No behaviour changes while the grants are in
  place. (#1659)

<a id="the-link-checker-runs-under-the-policies"></a>

- **The link checker runs under the policies.** The outbound link sweep, the
  per-URL check worker and the reader of the "check outbound links" switch
  reached `ExternalLink` and `SiteLinkCheck` through `authorize?: false`. They
  now run as `KilnCMS.Links.system/0`, a `KilnCMS.SystemActor`, and each
  resource admits it by action name: the occurrence rows' `read`, `observe`,
  `record_check` and `destroy`, and the switch's `read` and `record_sweep` (not
  the settings form's `save`, so turning checking on stays an admin act). The
  broken-link report at `/editor/links` now reads as the editor viewing it.

  The reads that back a decision fail closed. The check worker's
  failure-count read, which drives the retry-before-flagging counter, runs
  with `authorize_with: :error`, and a refusal writes no verdict instead of
  reading as "no rows". The sweep's due-URL read raises instead of queueing
  nothing. A refused `observe` aborts the sweep before its prune, which would
  otherwise delete every row along with its failure count. The switch read
  logs a refusal and resolves it to "off". A viewer the report's policy
  refuses gets an error, not an empty "nothing is broken" page.

  Content reads stay `authorize?: false`, each with a written reason: the
  sweep's scan of published documents, oEmbed's document reads and the
  related-links keyword search. A system-actor grant on content would be a
  standing read over the whole corpus, drafts included. The internal checker's
  target-state lookup reads as the editor instead (see Security). oEmbed's `:set_oembed_metadata` write also stays:
  it writes the block tree, and the content resource admits the system actor
  only to actions that accept no `:blocks`. The `mix kiln.authz.check` backlog
  drops by 16 sites and seven files. (#1659)

<a id="the-newsletter-send-pipeline-runs-under-the-policies-which-empties-the-authz-backlog"></a>

- **The newsletter send pipeline runs under the policies, which empties the
  authz backlog.** The fan-out worker and the per-recipient mail worker
  reached `NewsletterSend` and `Subscriber` through `authorize?: false`. They
  now run as `KilnCMS.Newsletter.system/0`, a `KilnCMS.SystemActor` labelled
  `:newsletter` (the tier sync already ran as one), and each resource admits
  it by action name: the campaign's `read`, `mark_sending`, `mark_sent`,
  `record_sent` and `record_failed` (not `mark_failed` or `destroy`), and the
  subscriber's `read` and `confirmed` (no consent change). The send guard in
  `Newsletter.send_as_newsletter/2` reads the target segment as the sender, the
  same actor the campaign is created under, so an actor who may not see the
  segment gets a Forbidden rather than "that segment no longer exists".

  Each read that decides who is mailed fails closed. Before, a refused
  subscriber list read as "no subscribers": the fan-out stamped zero
  recipients and marked the campaign `:sent` having mailed nobody, with no way
  to send it again. A refused campaign or subscriber read in the mail worker
  cancelled the recipient's job as "not found", and the job's uniqueness meant
  that recipient was never mailed. All three now log and retry. A per-recipient
  counter write that fails after delivery is logged instead of failing the
  job, so Oban does not mail the same person twice to correct a tally.

  The federation announce worker's document load stays `authorize?: false`,
  now with its reason written down: a `Delete` must find a record that is no
  longer published, and a system grant on content would read every draft.
  That was the last of the backlog: `mix kiln.authz.check` now holds every
  file under `lib/` to zero unexplained `authorize?: false`. The backlog map
  stays in place, empty, so a new one fails the check. (#1659)

<a id="mix-kilnmigrationscheck-gates-expand-contract"></a>

- **`mix kiln.migrations.check` fails a PR whose new migration breaks the
  release still serving mid-deploy.** From 1.0 schema changes follow an
  expand → migrate → contract policy across releases, written out in
  [`docs/releasing.md`](../releasing.md#migrations-expand-migrate-contract):
  add nullable or defaulted, backfill outside the migration, and drop, rename
  or tighten only in a later release. The task reads each migration a PR adds
  (core and overlay directories, forward direction only) and flags dropped or
  renamed tables and columns, type changes (resolved from `from:` or the
  migration history), `NOT NULL` without a default or a backfill release,
  destructive raw SQL, non-concurrent indexes on large tables, and a
  concurrent index inside a transaction. A deliberate contract step carries a
  `# kiln:contract-ok since vX.Y.Z — <reason>` marker naming the shipped
  release that stopped reading the old shape. It runs in the `build` CI job on
  pull requests. The existing history is exempt; judged whole, it would have
  flagged 106 statements, among them
  `20260919191545_drop_webhook_plaintext_secret`. The same section of
  `docs/releasing.md` says what zero-downtime does and does not cover.
  Operators are unaffected.
  ([#1716](https://github.com/The-Verscienta/kiln_cms/issues/1716))
<a id="mint-1110-closes-three-advisories-http1-response-smuggling-and-two-http2"></a>

- **`mint` 1.11.0 closes three advisories: HTTP/1 response smuggling and two
  HTTP/2 client memory exhaustions (EEF-CVE-2026-91043 HIGH, -92103, -94194).**
  All three were published against `mint` 1.10.1 on 2026-09-28 and fixed in
  1.11.0. A malicious HTTP/2 server could make the client decode HPACK-indexed
  `cookie` fields far past `max_header_list_size`, which is enforced only on
  the compressed block (EEF-CVE-2026-91043, HIGH). It could also hold up to
  about 16 MiB per connection in a frame larger than `max_frame_size`, which is
  checked only once the whole payload has arrived (EEF-CVE-2026-92103). A
  malicious HTTP/1 server could send `Transfer-Encoding: chunked, gzip`, which
  Mint framed as chunked although RFC 9112 reads such a body to connection
  close. That desynchronizes Mint from a strict intermediary on a pooled
  connection (EEF-CVE-2026-94194). Kiln reaches Mint through Req and Finch on
  every outbound HTTP path, and webhooks, ActivityPub federation and media URL
  import aim at hosts an operator or editor supplies, so a hostile origin is
  reachable. `mint` is transitive only, so this is a one-line `mix.lock`
  change.

<a id="each-system-actor-grant-now-names-the-subsystems-it-admits"></a>

- **Each system-actor grant now names the subsystems it admits.**
  `KilnCMS.Checks.SystemActor` matched any `%KilnCMS.SystemActor{}`, and the
  actor's `subsystem` was a label for logs. Since #1659 moved ~300 internal
  call sites under the policies, each with its own subsystem actor, a grant
  written for one worker was usable by all of them. Admitting publishing to
  `Task :complete` also let the automation worker complete anyone's task, and
  #1659 had to relax the test that said it could not. The check now takes a
  required `subsystem:` option (an atom or a list), and a clause without one
  fails the build. An optional `action:` narrows a clause when two actions in
  it have different callers. `OrgSettings`' `system_actions:` is now a keyword
  list of action to subsystems (`[read: :feeds]`); the old bare list fails the
  build too. Every grant was tagged from its call sites, found both by grep
  and by recording every admission during a full test run: a write goes only
  to the subsystem that calls it, and a read clause names every subsystem that
  reads through it. `docs/policy-matrix.md` gives each row a Subsystems
  column. The new `KilnCMS.SystemActorScopeTest` asks Ash, for every action on
  every granting resource and every subsystem label in the source, whether
  that label is admitted, and fails unless the answer is exactly the row.
  Widening a grant, dropping `action:`, narrowing one or moving a clause above
  its `forbid_unless` each turns it red. `CMS.Bookkeeping` and
  `CMS.Housekeeping` stay separate subsystems, because their grants barely
  overlap. The automation-cannot-complete-tasks refusal is restored.
  `mix kiln.experiment`'s writes, `mix kiln.federation`'s switches and the
  auth-throttle `prune` are the operator's alone. On `NewsletterSend` the
  automation may only open a campaign (and read the segment its rule names),
  and the send pipeline (`:newsletter`) may only read and work one. No
  user-visible behaviour
  changes: every caller keeps exactly the actions it already made
  ([#1747](https://github.com/The-Verscienta/kiln_cms/issues/1747)).
