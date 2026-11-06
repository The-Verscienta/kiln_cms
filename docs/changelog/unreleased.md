# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="search-name-lexemes-upgrade"></a>

- **Content tables gain `name_lexemes`, a generated column; overlays run
  `mix ash.codegen` to add it to their own content types.** The column is
  `GENERATED ALWAYS … STORED` from `search_weighted`, so the migration
  fills it for every existing row and Postgres keeps it current on every
  write. Adding a stored generated column rewrites the table under an
  exclusive lock: seconds for a catalogue of a few thousand rows, longer for
  a very large table. Until an overlay's own types have the column, their
  alias and compound legs answer empty and log why, so generate and migrate
  before deploying. No re-fire is needed: a row written before 1.8, with no
  `search_weighted`, still takes the full match.

<a id="reporting-views-upgrade"></a>

- **Overlays: run `mix ash.codegen` and commit the migration; existing content
  types gain the reporting views.** The reporting views (below) are created
  by `use KilnCMS.CMS.Content`, so a project's own `mix kiln.gen.content` types
  show codegen drift on the first release that has them. Run `mix ash.codegen`,
  review and commit the migration it writes, and deploy it with the update.
  Until then those types have no views; nothing else is affected. The
  migration is additive (a schema, and two views per content table) and
  rolling the pin back leaves them in place, unused. Core's own views arrive
  by core's migration with nothing to do. A BI role made earlier does not exist
  yet; when you create one (`mix kiln.reporting.sql`), re-run its `GRANT` lines
  after every upgrade that adds views, and after a demo reset.


## Added

<a id="change-severity"></a>

- **Change severity: how much a published edit matters, stored per edit.**
  A site lists the fields it treats as safety-relevant, per content type, at
  `/editor/safety-fields` ("every field" is one switch; computed fields should
  not be listed). An edit that changes a listed field of published content, or
  first publishes one with a non-empty listed field, is recorded with a
  severity — `critical`, `notable` or `routine` — in a new nullable
  `change_severity` column of the content `*_versions` tables, so it belongs to
  that edit and the next edit starts clean. Versions written before this read
  as no severity.
  - **Admin editor.** "Publish changes" and a first publish ask "How much does
    this change matter?" when the edit touches a listed field; nothing is
    preselected and the publish does not go through until one is chosen. Saving
    a working copy and autosave never ask. The content list, calendar and bulk
    publish refuse such an edit with a pointer to the editor.
  - **API, MCP, GraphQL and automated writers.** `update` and
    `publish` take an optional `change_severity` (`publish_changes` and
    `restore_version` have no public route and default to `notable`); omitted, the edit is recorded `notable` — never routine, never empty.
    There is no batch endpoint, so it is per request.
  - **Read back.** `latest_edit_severity` and `latest_edit_at` are public
    calculated fields on JSON:API and GraphQL (readable with a viewer key) and
    sibling fields on every `/api/sync` upsert item. They describe the latest
    *safety* edit (a later edit of an unlisted field does not move them) and
    are `null` when the document is unpublished or has none. No artifact
    `format_version` change. Webhooks and the change feed do not carry the
    severity yet.
  - **Upgrade.** Additive: a nullable column on each `*_versions` table and one
    new settings table. Overlays run `mix ash.codegen` for their own content
    types. Until a site lists a field, nothing changes.

<a id="reporting-views"></a>

- **Read-only SQL views of published content, for BI tools.** Custom fields
  live in one JSONB map, so Metabase or Superset could not select a field as
  a column. The new `kiln_reporting_v1` schema has, per content table, a wide
  view (core columns plus an allowlisted `custom_fields`) and a
  `<table>_field_values` view with one row per record and field
  (`value_text`, `value_json`). `mix kiln.reporting.sql` prints a script that
  creates a read-only role with `SELECT` on those views only. Guide:
  [docs/reporting.md](../reporting.md); the reasoning is
  [decision 0012](../decisions/0012-reporting-views-are-a-versioned-additive-only-sql-contract.md).
  - **What is exposed.** Published, unarchived, public-audience rows without an
    access password. A field appears only while a live definition names it and
    it is not private or a `user` field; the list is read live, so a flip to
    private applies on the next query. Reference values are `{id, type}` only.
    Media snapshots pass through as stored.
  - **Limits.** No typed columns (cast `value_text` / `value_json`; the guide
    has a recipe). Every site's rows are visible to the role, so it must not
    go to a tenant. Role settings (read-only, 60s timeout) are advisory; use a
    read replica to enforce.
  - **Developers.** The views are a versioned, additive-only contract; a
    breaking change would be `kiln_reporting_v2`. They pin the columns they
    read, so `mix kiln.migrations.check` now fails a migration that removes,
    renames or retypes one without dropping both views of the pair first
    (`kiln:contract-ok` does not excuse it); see `docs/releasing.md`. The
    demo reset now drops the schema before restoring, and
    the promotion column lookup filters on the current schema, so a view of the same name cannot add columns.
  - **Upgrade.** Additive, no environment variable. Overlays: see the upgrade
    note above.

## Changed

<a id="search-leg-performance"></a>

- **Global search is several times cheaper on a large catalogue.** A
  downstream catalogue of about 4,900 documents (2,047 herbs with three name
  fields) took 1.2–1.6 s per `/api/search` sweep, so 1.8's 1.5 s
  `query_budget` cut most queries short (`partial: true`). Three legs cost
  most of it, and each was a query-shape problem:
  - **Alias and compound legs.** The match runs "the query contains the
    name", so its tsquery is built from the row, and no index can serve it:
    every search unpacked every row's `custom_fields` and built a tsquery
    per name field. Both legs now first check the row's `name_lexemes` (the
    lexemes and Han runs of its title and names, from `search_weighted`'s
    `A` bucket) against the query's, the way the title leg checks its title
    lexemes, and run the phrase match only on the rows that share one. On a
    synthetic 2,047-row table of the same shape, the alias filter went from
    15 ms to 0.3 ms.
  - **Empty names.** A missing or empty name was matched as `''`, and
    `phraseto_tsquery('')` sends a `NOTICE` to the client for every row: about
    2,500 per herbs query on that catalogue. Empty names are now skipped.
  - **Tag leg.** Every section repeated the same nearest-tag vector search,
    then ran one query per tag. A sweep now looks the tags up once. Each
    section reads the documents carrying any of them in one query, and works
    out per tag which ones it carries. When that read hits its cap, the leg
    goes back to one query per tag, so results and distances don't change.

  Flagging a field `names_record` now also re-fires the type's published
  documents, as flagging it `searchable` already did: the flag reaches
  `search_weighted`, which weights `search_vector` and feeds the new
  prefilter. A draft picks it up on its next save. Before, the alias leg
  saw a new flag on the next search, while `search_vector` kept the old
  weights until each document was saved again. Type promotion
  (`mix kiln.promote_data`) no longer copies generated columns.

<a id="quiet-image-build"></a>

- **The release image builds without warnings or notices from Kiln's own
  steps.** The GHCR build log for v1.8.0 carried about 260 warnings and
  notices. Kiln's own steps produced four kinds, each now gone:
  - Tailwind's CSS optimizer warned that `::highlight(kiln-issue)` is not a
    valid pseudo-element. It is one (the CSS Custom Highlight API), but
    Lightning CSS doesn't know it. The rule now lives in `advisory_jump.js`
    as a constructed stylesheet, adopted the first time a highlight is drawn.
  - `npm ci` printed its "new major version" and "looking for funding"
    notices. The image pins its own npm, so the build passes
    `--no-update-notifier --no-fund`.
  - The two-scheduler `mix compile` pushed dozens of files past the
    "taking more than 10s" notice. The image build raises the threshold;
    dev keeps the default.
  - `mix release` printed "skipping elixir.bat/iex.bat for windows". The
    release now sets `include_executables_for: [:unix]`.

  On the dependency side, ash_phoenix 2.3.26, ash_paper_trail 0.8.1,
  ranch 2.3.0, makeup 1.2.3 and phoenix_template 1.1.0 compile cleanly on
  Elixir 1.20, removing about 20 warnings. The OTP 29 deprecation warnings
  in yamerl, gproc, gen_smtp and chatterbox (`catch Expr`, exported
  subexpression variables, `lists:zf/2`) are switched off for the
  `deps.compile` step only, through the compiler's own `nowarn_*` options.
  The app's sources still compile with every warning on. The rest are Elixir
  1.20 warnings inside third-party packages whose latest releases still
  carry them. Fixing those needs upstream releases.

## Fixed

<a id="phoenix-1-8-16-subscription-pushes"></a>

- **The Phoenix stack moves to 1.8.16 (phoenix_pubsub 2.4.1, phoenix_live_view
  1.2.13, websock_adapter 0.7.0), together with absinthe_phoenix 2.0.6.** Phoenix
  1.8.16 replaces PubSub's custom dispatchers with per-subscription senders:
  Phoenix's channel server dispatcher now passes broadcasts to the default
  dispatch, which ignores the `metadata: {:fastlane, transport_pid, serializer, _}`
  shape. absinthe_phoenix 2.0.5 still subscribes each GraphQL subscription
  document with that metadata. On 1.8.16, a `subscription:data` broadcast
  therefore went to the channel process instead of the socket's transport.
  absinthe_phoenix's channel then dropped it in its catch-all `handle_info`. The
  result was that every subscription accepted the subscribe call and never
  pushed anything, in production as well as in tests (the six failing
  `assert_receive` cases in `graphql_subscription_test.exs` and
  `graphql_limits_test.exs`). absinthe_phoenix 2.0.6 subscribes with a sender
  instead (absinthe_phoenix#113/#114). `mix.exs` now requires
  `absinthe_phoenix >= 2.0.6` and `phoenix ~> 1.8.16`, so the lock can't pair
  them wrongly again.

<a id="exla-fine-pin"></a>

- **A from-scratch `KILN_ML=1` build compiles EXLA again.** The Phoenix
  1.8.16 bump above also moved the test-only `lazy_html` to 0.1.14, which
  requires `fine ~> 0.2.0`, so the lock took fine 0.2.0. EXLA 1.0.0 allows
  `fine ~> 0.1` but its NIF does not compile against 0.2 (`'try_decode' is
  not a member of 'fine::Decoder<xla::Shape>'`). Lean builds were
  unaffected. The `-ml` image and any overlay building with `KILN_ML` on
  failed, and an overlay could not pin around it, since
  `mix kiln.plugins.doctor` holds core dependencies at core's lock.
  `mix.exs` now caps `lazy_html` below 0.1.14, which puts both lock entries
  back to their v1.8.0 versions. CI's ML leg missed the break because EXLA
  caches `libexla.so` under a key without `fine`, and the leg restored that
  cache on the lock change. It now rebuilds the NIF from source whenever its
  cache isn't an exact hit. Overlays that re-seeded `project.lock` from the
  1.8.16 bump re-seed once more.

<a id="new-menu-button"></a>

- **The content list's "New" menu is a real `<button>` with `aria-expanded`.**
  Past three content types, `/editor` folds its "New …" buttons into one
  menu. Its trigger was a `<summary>` styled as a button, with the marker
  hidden; an accessibility walkthrough found it wasn't announced as a button.
  It is now a disclosure: a `<button aria-expanded aria-controls>` that shows
  and hides the panel of per-type buttons. The shared `data-autoclose`
  handler in `app.js` closes it on a click outside or on Escape, and only
  claims Escape while the menu is open, so Escape in the search box or a
  modal keeps its focus. The old `<details>` also lost its `open` state on
  every LiveView patch, so a list refresh behind an open menu snapped it
  shut; the new one keeps its state across patches it didn't cause.

## Security

<a id="ecto-query-cache-advisory"></a>

- **ecto 3.14.3 fixes EEF-CVE-2026-118391 (unbounded query cache growth), and
  ash_sql 0.8.7 replaces the retired 0.8.4 (query cache returned wrong rows).**
  ecto 3.14.2's query cache grew without bound on queries with
  interpolated JSON paths or splice lists (high). ash_sql 0.8.4 was retired for security the
  same day: an Ecto query cache issue could make a query return
  unpredictable results. Both were published 2026-11-04, after 1.8.0, and
  fail `mix hex.audit` on every branch until taken. Lock-only: `mix
  deps.unlock ecto ash_sql`, nothing else moved.
  ([#2204](https://github.com/The-Verscienta/kiln_cms/pull/2204))
