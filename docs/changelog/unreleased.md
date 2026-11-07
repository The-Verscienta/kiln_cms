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

<a id="custom-field-native-filter-sort"></a>

- **A custom field can be named like a column in `filter[...]` and `sort=`, and
  `custom_sort` works on the search routes.** `GET /api/json/posts?filter[price][gt]=10&sort=title,price`
  now means what `custom_filter[price][gt]=10&custom_sort=title,price`
  did, as long as no public attribute, calculation, aggregate or relationship
  has that name (a built-in always wins). The built-in relations take their
  set operators natively too: `filter[tags][has][]=<id>`,
  `filter[related_posts][has_none]=<id>`. `custom_sort` (GraphQL
  `customSort`) is a new argument on `search`, `search/published`,
  `semantic-search` and `semantic-search/published`, with the precedence
  explicit `sort` > `custom_sort` > relevance or distance > recency. A leading
  custom sort on semantic search replaces distance ordering (the vector
  index cannot serve it) and the rule that a name match comes first. The
  null test `is_nil` is accepted as a synonym of `null` on custom fields. See
  [Naming a custom field like a column](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/json-api.md#naming-a-custom-field-like-a-column).

  What to know before relying on it:

  - `custom_filter` / `custom_sort` remain the stable form. They always mean a
    custom field, they are the only way to reach one named like a column,
    and a later built-in with the same name would start shadowing `filter[x]`.
    The official clients keep emitting `custom_*`; new `customSort` /
    `:custom_sort` options on their search calls.
  - A typo such as `filter[ttile]=x` used to get ash_json_api's "No such
    field"; it is now `400` `invalid_argument` with detail
    `unknown custom field "ttile"` and no `source` member. Code that matched
    the old message needs updating. An anonymous typo costs one uncached
    field-registry read before it is refused.
  - Custom sorts must come last in `sort`: `sort=title,price` works,
    `sort=price,title` is `invalid_sort`. Custom sorts are nulls-last; a native
    `-x` is plain `desc`.
  - The OpenAPI `sort` parameter's `format` lists built-in fields only, so a
    client that validates it strictly rejects `sort=price`. Use `custom_sort`.
  - `links.self` echoes the URL as sent.
  - On `/entries` without `filter[type_name]`, a bare name declared with
    different types by different dynamic types is refused ("has a different
    type per content type"), as `custom_filter` already was.
  - Sorting by `media` / `reference` custom fields is still unsupported.

<a id="reject-invalid-bearer"></a>

- **`KILN_API_REJECT_INVALID_BEARER` (#2161).** With it on, an `Authorization: Bearer` token that
  fails verification gets a 401 `invalid_token` envelope instead of silently reading as anonymous.
  Off by default for this release, because a consumer sending a stale token today gets 200;
  the default flips next release, so announce it in that release's upgrade notes.

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
  [decision 0015](../decisions/0015-reporting-views-are-a-versioned-additive-only-sql-contract.md).
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

<a id="plugin-plug-routes"></a>

- **A plugin can mount plain-Plug endpoints, such as a webhook receiver, a JSON
  API or a feed variant, with the new `plug_routes/0` callback
  (`kiln_plugin` 1.4.0).** Until now a plugin could only route to a LiveView
  page (`public_routes/0`), so an endpoint with no page had to be an overlay.
  A route is `{verb, path, plug_module, plug_opts}` (a Phoenix controller is a
  Plug whose opts is the action atom) or `{:forward, path, plug_module,
  plug_opts}`. The package needs only `plug`, so it works as a Mix dependency.
  - **What the core does.** Mounts the routes before the content-delivery
    catch-alls, in a scope with no session, no CSRF check and no `accepts`
    (`current_user` is never set; the plugin authenticates its own caller).
    `conn.assigns.current_org` is set, but the plugin passes `tenant:` to Ash
    itself. Requests are limited to 300 a minute per client address in their
    own `:plugin_endpoint` bucket. A JSON or form body is also kept in
    `conn.private[:raw_body]`, capped at 1 MB, so an HMAC can be verified.
  - **Checks.** A malformed route stops the build, naming the plugin.
    `mix kiln.plugins.doctor` also reports a path under a root core routes own
    (`/editor`, `/api`, `/gql`, `/mcp`, …) and overlap with another plugin's
    plug or public routes. `mix kiln.plugins.list` and System → Plugins count
    plug routes.
  - **Upgrade.** Additive. A plugin that does not define `plug_routes/0`
    (including one built against `kiln_plugin` older than 1.4) declares none. A
    plugin using it requires `{:kiln_plugin, "~> 1.4"}`. See
    [Plugin extensibility](../plugin-extensibility.md).

<a id="graphql-typed-custom-fields"></a>

- **GraphQL reads admin-defined custom fields typed by kind, with no deploy
  and no schema change (#2290).** `customFields` stays a `JsonString`. Next to
  it every content type (`Page`, `Post`, a project type, `Entry`) and the
  `ContentRecord` interface gain `customString`, `customInt`, `customFloat`,
  `customBoolean`, `customDate` and `customDateTime` (each `(name: String!)`,
  nullable) and `fields(names: [String!]!): [CustomFieldValue!]!`. A field an
  admin adds is readable at once; the GraphQL schema is compiled and the same
  for every site, so what it types is the *accessor*, not the name.
  - **What is and is not checked.** `customFloat(name: "price")` is a `Float`
    or `null`. A typo, a rename, a deleted field, a field of another kind, a
    legacy value that no longer fits, or a private field read below editor is
    `null` (left out of `fields`), never an error. The server cannot catch the
    typo; the exported contract below does.
  - **`fields(names:)`.** `names` is required, at most 50. It returns the
    `CustomFieldValue` interface (`name` plus the kind's members: `StringValue`,
    `IntValue`, `FloatValue`, `BooleanValue`, `DateValue`, `DateTimeValue`,
    `ListValue { items }`, `GroupValue { fields }`, `ReferenceValue { ids }`,
    `MediaValue`, `GeolocationValue { lat lng label zoom }`,
    `JsonValue { value }`). A `multiple` field is a `ListValue`; computed
    fields, `datetime_range` and `recurrence` are `JsonValue`. Groups nest to depth 3. A reference field
    returns ids only: read the records through `references(field:)`. Cost is
    1 plus the selection once per name; an accessor costs 1; the 200 limit is
    unchanged.
  - **Visibility and locale.** Values come from the record as the caller reads
    it, so private fields read as unknown below editor. A
    `localization: :fallback` field does not inherit along the locale chain in
    this layer; name the locale you want. A page of records does one
    definitions read per type, not one per record.
  - **Typed contract per site.** `GET /api/schema?format=typescript` is the
    existing document as a `.d.ts`; `?format=typescript-graphql` is a `.ts`
    module that adds, per content type (and per `typeName` for dynamic types,
    selected on `publishedEntries(filter: {typeName: {eq: "…"}})`), a
    `<Type>CustomFields` interface and a ready `<Type>CustomFieldsFragment`.
    An unknown `format` is a `400` with code `invalid_format`; without
    `format` the response is the same JSON as before. Regenerate after an
    admin changes fields. `filter` and `sort` still use
    `customFilter`/`customSort`, unchanged.
  - **Plugins.** `Kiln.FieldType` gains an optional `graphql_kind/1`
    (`:string`, `:int`, `:float`, `:boolean`, `:date`, `:datetime`, `:json`)
    in `kiln_plugin` 1.4.0. A type without it, or compiled against an older
    SDK, is served as `JsonValue`, so nothing breaks. Publish the SDK to Hex
    before a plugin requires `~> 1.4`.
  - **Not yet.** Swift and Kotlin emitters for the GraphQL section, typed
    filter operators, a per-site SDL with a regenerate step, and typed writes.
  - **Upgrade.** Additive and org-independent: no migration, no config, and
    rolling the pin back removes the new fields only. The new fields
    are added to every content type in the schema's `:content_domains`, so an
    overlay's types get them without code changes.
    See [headless-graphql-api.md](../headless-graphql-api.md#read-custom-fields-typed-by-kind).

<a id="draft-write-api-keys"></a>

- **Drafts-only API keys for headless services (#2273).** A new `draft_write` access
  scope on API keys lets an app service (Verscienta's, for AI drafting) create drafts and edit
  drafts it authored, and nothing else: no publishing, submitting for review, deleting, media,
  tags or related links, and no edits to live or someone else's content. The bound is a policy
  on `Content` that sits above the admin bypass and ignores the owner's role, so promoting the
  owner later widens nothing. Keys are minted by an admin on a viewer-tier service account and
  capped at 30 days (`draft_write_key_max_ttl_days`). Drafts created this way record the key
  and an optional `X-Kiln-On-Behalf-Of` label (stored for display only, never used for
  authorization); the fields appear in the editor (not in version history, which a second key
  on the same owner can read) and, for editors, admins and the creating key only, on JSON:API, GraphQL and `/mcp` (never for anonymous, preview-link or
  viewer-tier callers, webhook payloads or the preview endpoint). A GraphQL query that selects
  those three fields as someone not allowed them gets `null` plus a `forbidden_field` entry in
  `errors`, so a codegen'd query that selects every field should drop them. See [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  and the headless consumer guide.

<a id="draft-write-key-rotation"></a>

- **Self-rotating drafts-only keys.** A `draft_write` key's 30-day cap meant a person re-minted
  the service's key every month. An admin can now give the key a rotation window at mint
  (`rotatable_until`; "Self-rotation" at `/editor/api-keys`, at most
  `draft_write_key_max_rotation_days`, default 365). Until then the service calls
  `POST /api/keys/rotate` with the key and gets a fresh one: same account, scope and name,
  expiring at the 30-day cap or the window's end, whichever is sooner. The old key is revoked in
  the same transaction, under a row lock, so a chain has one live key and never outlives the date
  the admin chose. The action takes no input; `read`/`read_write` keys, signed-in users and admins
  are refused, and an owner promoted to editor since the mint stops the chain. Presenting a
  rotated-away key to the endpoint again more than 120 seconds later revokes the whole chain and
  mails the platform admins. Keys without a window behave as before. New nullable `api_keys`
  columns `rotatable_until`, `lineage_id`, `rotated_from_id` (additive). See
  [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md#rotation)
  and the headless consumer guide.

## Changed

<a id="custom-field-history"></a>

- **Custom fields are individual fields in version compare, restore and the publish-conflict panel.**
  Until now a changed custom field read as one opaque "Custom fields" blob.
  The compare modal now lists each key with its definition's label, a typed
  value (select option labels, media filename, reference title, rich text
  without tags, group `Label: value` pairs) and an Added / Removed / Changed
  pill. Media and reference titles resolve as the signed-in reader, in one
  batched read; an unreadable target shows its stored id. A retired
  definition shows its raw key.
  *Restore* (from the compare modal and the history list) now opens a
  preview, **Restore this version?**, and writes only on *Restore this
  version*; it replaces the browser confirm. The preview runs the same
  `RestoreVersion.plan/3` as the action and lists stored custom keys no
  definition declares any more as discarded. An editor with a field grant is
  told restore needs full field access instead of being offered a confirm
  that would fail. The publish-conflict panel still shows one *Custom fields*
  row and still resolves the whole map with one choice (no per-key merge), but
  now lists the per-key draft-versus-live difference beneath it.
  No API, migration or config change; nothing to do on upgrade, and rolling
  back the pin is safe. The revisions API still carries `custom_fields` as one
  whole-map change; a per-key `changed_custom_fields` is deferred. See
  [Comparing and restoring versions](../working-copy.md#comparing-and-restoring-versions).

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
