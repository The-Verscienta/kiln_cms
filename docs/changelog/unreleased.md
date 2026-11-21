# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="plugin-list-field-types-upgrade"></a>

- **Plugin field types can hold lists from this release; rolling back past it needs preparation (#2680).** Upgrading needs nothing: no migration, no configuration. Rolling back is where the care goes. v1.11 and earlier treat a list field of a plugin type as a single value that happens to store an array. Their editor renders the list run together in one input, and saving such a record there can replace the list with one value or be refused. Restore, publishing a working copy and duplicate fail for a record holding one when the type's `cast/2` refuses a list. Saving or reordering the field in the fields admin clears its `multiple` flag (the arrays stay). Before rolling back, find those fields with the query in [docs/releasing.md → Rolling back past plugin list fields](../releasing.md#rolling-back-past-plugin-list-fields), then leave their records alone until you roll forward, or make each field single-valued (keeping the first item) or delete it on this release, after a backup.
  - **Rolling deploys:** don't make a plugin field a list until every node runs this release.
  - **Rollbacks after this one:** this release holds any `multiple` field whose type it can't list (see [Added](#plugin-list-field-types)), so a later release can make a type list-capable without this preparation for a rollback to this one or later.

<a id="backup-s3-same-bucket-overlap-upgrade"></a>

- **Two S3 destinations on one bucket name stop pruning (#3088).** After the upgrade, an installation with two S3 destinations that name the same bucket, one prefix inside the other, on different hosts skips retention on both. Each pass leaves a "Retention on … skipped" notice, and the storage grows until you act. Give the two destinations prefixes side by side, or untick "Delete its old backups (retention)" on one of them if they really are separate stores.

<a id="backup-sftp-destination-upgrade"></a>

- **The `sftp` destination kind is now Kiln's own (#2222).** `sftp` joins `local`, `rclone` and `s3` as a kind no plugin can register. Rows a plugin made under that kind no longer match Kiln's fields, so saves and backups to them fail until you delete them and add the destination again under **SFTP server**.
  - **Enabling:** a new SFTP destination starts disabled until a platform admin confirms the host key.
  - **Private hosts:** list LAN SFTP servers in `BACKUP_SFTP_PRIVATE_HOSTS`; hosts in `BACKUP_S3_PRIVATE_HOSTS` don't count for SFTP.
  - **Migration:** apply `add_backup_destination_host_key`, which adds one nullable column.

<a id="public-js-bundle-upgrade"></a>

- **A custom asset build or overlay `Dockerfile` that does not run `mix assets.deploy` must also run `mix esbuild kiln_public --minify` before `phx.digest` (#2402).**
  Signed-out content pages now load `public.js`, built by the new
  `kiln_public` esbuild profile (see [Changed](#public-js-bundle)).
  `mix assets.deploy`, which the stock `Dockerfile` runs, already includes
  it, as does `mix assets.build`. A build that runs the esbuild profiles
  itself and skips this one loses nothing but the saving: when
  `priv/static/assets/js/public.js` is missing, every page loads `app.js`
  as before, and public forms' human-verification widgets still mount.
  Outside dev, whether `public.js` exists is checked once per VM, so a
  release that gains it later picks it up only after a restart. No
  migration and no configuration; rolling back is safe.

## Breaking

<a id="ws-gql-bearer-scheme-any-case"></a>

- **`/ws/gql` reads an `authorization` connect param under a `Bearer` scheme in any case, so lowercase garbage and a bare `Bearer` are now refused instead of connecting anonymously (#2632).**
  The GraphQL socket used to read an `Authorization` (or `authorization`)
  connect param only when it started with exactly `Bearer `; any other
  spelling was ignored and the socket connected as anonymous. It now reads
  the scheme case-insensitively, as every HTTP surface does (see
  [Fixed](#bearer-scheme-any-case)), which changes three answers:
  - `bearer <valid jwt>` and `BEARER <valid jwt>` connect as the token's user
    (they used to connect anonymously).
  - `bearer <garbage>`, or an expired or revoked JWT under a lowercase
    scheme, is refused like any token that does not verify: `connect/3`
    answers `:error` and the handshake is a `403` (#2634). It used to connect
    anonymously and read published content.
  - A bare `Bearer` with no token, in any case, is refused too, matching the
    `401` `/api` and `/gql` give it over HTTP. `Bearer` with no trailing space
    used to connect anonymously.

  The `token` connect param, which carries the JWT with no scheme, is
  unchanged, as is a param under another scheme (`Basic …`), which still
  connects anonymously. A client that sends a lowercase or empty bearer
  should send a valid JWT or leave the param out.
  `KILN_API_REJECT_INVALID_BEARER=false` still restores the anonymous connect
  for a token that does not verify, and each refusal still emits
  `[:kiln_cms, :api, :invalid_bearer]` with `surface: :graphql`. No migration;
  rolling back restores the old reading.

## Known issues

<a id="plugin-health-tail-packages-unknown"></a>

- **With many Hex plugins and a hex.pm that stays slow, the same plugins at the end of the list read Unknown on every plugin check.**
  A plugin check now stops at 75 seconds and does not ask about packages it hasn't reached ([plugin check single-flight](#plugin-check-single-flight)). Packages are asked in a fixed order, so the ones at the end are the ones left out each round, while the rest are re-checked every 15 minutes. Affects platform administrators reading System or Security posture on a deployment with enough Hex plugins that a round doesn't finish in time (roughly 13 or more at hex.pm's slowest). Workaround: none needed for the plugins that answered; for the rest, check the package on hex.pm by hand until hex.pm answers in time. Unknown is never shown as OK.
  ([#3165](https://github.com/The-Verscienta/kiln_cms/issues/3165))

## Added

<a id="plugin-list-field-types"></a>

- **A plugin field type can hold a list of values (#2680, `kiln_plugin` 1.6).** A `Kiln.FieldType` that defines the new optional `multiple?/0` to return `true` gets what the core scalar types have had since #2289: the fields admin offers **A list** with item bounds, and a list field stores a JSON array. Guide: [Let a plugin field type take a list](../extending-content.md#let-a-plugin-field-type-take-a-list).
  - **Write rules:** `cast/2` runs once per item with `multiple: false`. Blank items drop out, and a string item splits on line breaks on every write, as for core lists. An item whose cast is not one string or number refuses the write, and the host logs it once per type. Repeats are kept unless the new optional `unique_items?/0` returns `true`. The type must be a scalar (`input_parts/1` returns `[]`). A single field of such a type sent a list keeps its first item, and is refused `[]`.
  - **Everywhere else:** the editor's list input uses the type's `input_type/0` and `input_attrs/1`, without its `input_hook/1` or `widgets/1`. `custom_filter` takes the list operators with operands cast by the type's `cast/2`. GraphQL serves a `ListValue` of the `graphql_kind/1` kind, and `customWhere` refuses a type without one ("use customFilter"). The schema export wraps `json_schema/1` in an array, with `uniqueItems` only when the type drops repeats. The content list's columns don't offer plugin types yet.
  - **Built-in types:** `email`, `telephone`, `color`, `slug` and `time` now declare their list support through the same callbacks; nothing changes for them.
  - **A list whose type stops taking lists is held, not dropped.** `FieldDefinition.held_list?/1` names it. Its lists are kept, served, searched and carried by restore, promote and duplicate. A write that changes one (an empty list or `null` included) is refused, and a content import drops it with the dropped-keys warning. It is never required, the editor shows it read-only, and the fields admin badges it **list (held)**. Filtering or sorting on it is a `400` on JSON:API, GraphQL and MCP. The schema export describes it as `{"type": ["array", "null"], "items": {}, "readOnly": true}`. Only the fields admin's save narrows it to each record's first item, after a warning; it passes the new `narrow_held_list?` argument of the field definition's update. A reorder, a rename elsewhere, a field sync or any other update keeps it a list, and a field sync file that narrows it is blocked as data loss without `--allow-data-loss`. See [Narrow a list field whose type stopped taking lists](../extending-content.md#narrow-a-list-field-whose-type-stopped-taking-lists).
  - **`mix kiln.plugins.doctor`** fails on a `multiple?/0` or `unique_items?/0` answer that isn't a boolean, or that raises; on a list type whose `input_parts/1` isn't `[]` under any editor input it offers; on a sample `cast/2` that answers a non-scalar; and on a type the host's compile-time check leaves single-valued. It notes `unique_items?/0` without `multiple?/0`, and a list type with an `input_hook/1`.
  - **Compile time:** the capability is read when Kiln compiles, and an edit to a plugin field type now recompiles the registries that bake it.

<a id="backup-sftp-destination"></a>

- **SFTP backup destination (#2222).** Backups → Destinations offers **SFTP server**, built on OTP's `:ssh`/`:ssh_sftp` with no new dependency.
  - **Settings and credentials:** host, port, username and an absolute path. Authentication is by password, by private key, or both. Keys are Ed25519, ECDSA or RSA of 2048 bits or more, and a passphrase-protected key must have its passphrase removed. The key sits in the encrypted vault.
  - **Host key:** a new destination is saved disabled. A platform admin checks the server's host key from its row, compares the fingerprint (or pastes the expected one) and trusts it. The scan sends no credential. Every call pins that key and its algorithm.
  - **Changed key:** a changed key fails the destination permanently. It writes an instance security event and a platform alert, at most one per destination per hour. Trusting a new key is audited with the previous fingerprint.
  - **Host policy:** the same as S3's (ADR 0069). Private and LAN hosts are refused unless listed in `BACKUP_SFTP_PRIVATE_HOSTS`, metadata addresses are always refused, and DNS is pinned on every call.
  - **Uploads:** they resume after an interruption, in 128 KiB writes within OpenSSH's message limit, checked by size plus a read-back of the tail. The final rename uses `posix-rename` when the server offers it.
  - **Retention, rescan and safety:** list, get and delete work for retention and rescan. Symlinks are refused in the `db`/`media` folders and for backup files.
  - **More:** see ADR 0079 and the "Back up to an SFTP server" section of docs/backups.md.

<a id="mcp-content-link-tools"></a>

- **Content link tools on `/mcp` (#3191).** `read_content_links` (`ContentLink :read`), `create_content_link` (`:create_link`) and `update_content_link` (`:update_link`) let an LLM author link records with any `kind`, not only the `related_*_ids` the update tools already take. They follow the payload-link route's rules from R8 (#2014): a write is authorized as an edit of the link's source, `kind: reference` is refused, and a link is visible only when the key may read both ends. There is no destroy tool, as for every other `/mcp` tool.
  AshAi lists a tool only if `Ash.can?` passes on a blank changeset, which `Checks.SourceUpdatable` could never pass without a source, so a source-less tool probe now passes that check, the same rule as `DraftWriteKey`'s. The write-key and editor policies still decide whether the tools are listed.
  A project that replaces `config :kiln_cms, :mcp_tools` must add the three names to serve them.

<a id="backup-schedule-disk-warning"></a>

- **Schedule preview warns about runaway disk use (#2984).** A sub-daily schedule with a long `keep_days` can keep thousands of full backups. For example, every 2 hours for 60 days keeps 721 of each component. The preview now warns, without blocking the save, in two cases:
  - when it would keep more than about 500 backups of each component;
  - when the newest backup of each component it covers, times that count, is more than `BACKUP_DIR` has room for. Room is the free space, read with the same bounded `df` as the backup preflight, plus the finished backups already in `db/` and `media/`, which this schedule's retention can reuse. This check is skipped when `BACKUP_FREE_SPACE_CHECK=false`.

  The size warning gives the estimated total, the free space and the space held by existing backups. Backups kept by something else also count as room, so a nearly full disk can still go unwarned. `keep_days` has no cap, and media stays allowed in sub-daily schedules.

<a id="site-defaults-api"></a>

- **A headless front end can read the site's link-preview defaults at
  `GET /api/site` (#2577): its name, its X (Twitter) handle and its default
  share image, with no credential.** A fired artifact's `social` object
  carries only the document's own values
  ([ADR 0061](../decisions/0061-site-level-values-stay-out-of-per-document-artifacts.md)),
  so until now a front end had to copy the site's X handle and fallback image
  into its own config by hand. Guides:
  [Site defaults](../api.md#site-defaults) and
  [Add the site-level tags](../headless-consumer-guide.md#add-the-site-level-tags).
  - **The answer.** Exactly three keys, every one always present:
    `site_name` (the site's name as its `<title>` carries it: Branding, else
    `SITE_NAME`, else `KilnCMS`; a site nobody has branded answers the
    deployment's default name), `twitter_site` (`@handle` or `null`, per
    site only, with no operator default) and `social_image_url` (an absolute
    URL on the site's own host, or a full URL passed through, or `null`;
    the operator's branding config applies as it does on the pages). Each is
    a value the site's public `<head>` already shows. Logo, favicon, colors,
    theme and menus are left out on purpose.
  - **Whose site.** The one the request's host names, as on every other
    delivery surface; under strict host matching an unknown host is a `404`.
  - **Caching.** Anonymous reads are `public, max-age=60,
    stale-while-revalidate=60` with a weak `ETag` and `304`, like
    `/api/search`; a valid credential gets the same body as
    `private, no-store`, and an invalid one is a `401`. If the site's
    Branding can't be read the answer is a `503` with `Retry-After: 2`,
    never cached, rather than Kiln's stock defaults.
  - **CDN purge on a Branding save.** With `KILN_CDN_PURGE_URL` set, the
    first Branding save, **Reset to defaults**, and a save that changes the
    site name, the X username or the default social image now purge the
    site's CDN key, which drops every cached response for that site, not
    just this one. A save that changes only the logo, favicon, color, theme
    or menus doesn't, nor does the nightly app-icon re-check. A change of
    `SITE_NAME`, the operator's branding config, or the site's domain or slug
    is not purged and shows within two minutes.
  - **The contract.** Listed as covered in the 1.x stability table; new keys
    are additive only. REST only: no JSON:API resource, GraphQL field or MCP
    tool. `site()` methods for `kiln_client` and `@kiln-cms/client` will
    follow separately. In the OpenAPI document as `getSite`.
  - **Upgrading.** No migration and no setting. On a deployment with
    `KILN_CDN_PURGE_URL` set, expect a site-wide purge after a Branding save
    that changes one of the three values.

<a id="plugin-health-api"></a>

- **Each installed plugin's health is available as JSON for monitoring, at
  `GET /api/security/plugin-health` (#2571).** The Security posture's
  **Installed plugins** line, and `GET /api/security/posture`, give one
  verdict for all plugins together; a monitor can now see which plugin
  failed and why (a changed package on Hex, a security notice, a retirement,
  no recent release, an SDK it doesn't accept). Guides:
  [Plugin health (monitoring)](../api.md#plugin-health-monitoring) and
  [Monitor each plugin from a script](../security-posture.md#monitor-each-plugin-from-a-script).
  - **Who may call it.** A platform administrator, with a bearer JWT or an
    API key they own (`read` is enough, and is the one to use). A live
    temporary admin grant counts; an expired one doesn't. A site
    administrator is refused even on their own site's host, as on
    **System → Plugins**, because the report describes the whole
    installation. A `draft_write` key is refused whoever owns it. The
    policy is on a new `KilnCMS.Security.PluginHealthReport` resource
    (`forbid_if DraftWriteKey`, then `authorize_if PlatformAdmin`).
  - **Behind the admin allowlist of the host's site**, then the `api` rate
    limit: `403` `network_not_allowed`, `503` `temporarily_unavailable`
    (`retry-after: 30`) when the list can't be read, `429` when the bucket is
    spent, `401` `invalid_token` or `unauthenticated`, `403` `forbidden`.
    The body is the same on every site's host and has no site id; the host
    decides only whose allowlist applies. The allowlist page's note now says
    both monitoring endpoints under `/api/security` answer only to listed
    networks. Every answer, refusals included, is
    `cache-control: private, no-store`.
  - **It never asks anything.** It reads the node's cached check and starts
    no check, not even in the background. A node with nothing cached answers
    `200` with `state: "not_checked"` and an empty `plugins`, without a
    `retry-after`. Opening System or Security posture, or a platform
    administrator's `GET /api/security/posture`, on that node still fills
    the cache as before. The cache is per node, so `state` and `checked_at`
    describe the node that answered.
  - **The answer.** `version` (1), `state` (`fresh`, `partial`, `disabled`,
    `nothing_to_check`, `not_checked`), `checked_at`, `notices`, `counts`
    per `overall`, and `plugins`, each with `id` (the plugin's module),
    `name`, `source`, `package`, `version`, `latest_version`, `overall`,
    `integrity`, `notices` (ids, aliases, severity, source, link) and
    `abandonment` (structured reasons). Never a Hex retirement message, a
    notice's title or ranges, the checksums, a git ref, a sentence written
    for a person, a site id or the node's name.
  - **The contract.** Additive only, with its own `version`; open value sets
    (read a value you don't know as unknown, never OK); key plugins on `id`,
    since `name` may repeat; read `state` before trusting an empty
    `plugins`. Listed as covered in the 1.x stability table. Not on
    JSON:API, GraphQL or MCP.
  - **Upgrading.** No migration and no setting. A monitor already on
    `GET /api/security/posture` is unaffected.

## Changed

<a id="search-budget-cut-grace"></a>

- **A search the budget cuts now gives its running sections 100 ms to stop on their own before killing them, so a query that finishes in time keeps its database connection (#2614).**
  When `query_budget` ran out, every content section still running was killed at once. A section killed mid-query costs its connection: Postgrex cancels the query in Postgres (so, contrary to what #2614 suspected, nothing keeps running there), but DBConnection drops the connection and opens a new one, a TLS handshake and authentication against a remote database. Now, at `section_concurrency` above 1 (the default is 2), nothing new starts at the deadline and the running sections get `cut_grace` more milliseconds (`config :kiln_cms, KilnCMS.Search, cut_grace: 100` by default) to return. A section checks the deadline between its legs, so most return within one query; those are kept with every leg they finished, and only the ones still running after the grace are killed. The grace does not remove every reconnect: a query longer than the grace is still killed, and a section that was waiting for a connection at the deadline may get one during the grace. Two things readers see: a cut search may now answer up to `cut_grace` later than before (100 ms at the defaults), and a leg that finishes inside the grace is no longer listed under `incomplete`. The response shape and the meaning of `partial` and `incomplete` are unchanged. A new event, `[:kiln_cms, :search, :budget, :cut]` with `returned` and `killed`, is exported as `kiln_cms_search_budget_cut_returned` and `kiln_cms_search_budget_cut_killed` (see [observability.md](../observability.md#search-budget-cuts)). Set `cut_grace: 0` to kill at the deadline as before. A per-query `statement_timeout` was considered and rejected: it needs a transaction or a session `SET`/`RESET` on every checkout, round trips on every search to save a reconnect on the rare one the budget cuts. No migration; rolling back is safe.

<a id="public-js-bundle"></a>

- **Signed-out content pages load a small `public.js` instead of `app.js` (#2402).**
  Every page used to load `app.js`: LiveView, the Phoenix socket, the
  console's hooks, Sortable and topbar, 257,647 B minified and 80,526 B
  gzipped across three requests, none of which a visitor reading a page
  uses. Those pages now load `public.js`: 6,433 B minified and 2,505 B
  gzipped in one request. It carries the human-verification mount for
  public forms, the `data-method`/`data-confirm` helpers from
  `phoenix_html`, and the ⌘K / Ctrl-K shortcut to the console's search
  (now shared with `app.js` through `assets/js/search_shortcut.js`).
  - **Which pages.** Those rendered by `ContentController` (delivered
    pages and posts, the blog and event indexes, `/search`, the passphrase
    lock page, the delivery 404 and the stock home page), `FormController`
    (`/forms/<slug>`, its thank-you page and its refused re-render) and
    `NewsletterController`. Each opts in with the new
    `KilnCMSWeb.Plugs.PublicJsBundle`; `KilnCMSWeb.Layouts.js_bundle_path/1`
    still answers `app.js` for any LiveView, for a page with a flash (its
    close button needs LiveView), and when `public.js` was not built. The
    console, sign-in and every other LiveView keep `app.js`.
  - **Code-injection snippets.** A head or footer snippet on a page that
    now loads `public.js` no longer runs alongside `app.js`, so one that
    used `window.liveSocket` or another `app.js` global finds nothing.
    That was never supported.
  - **A budget gate.** `mix kiln.assets.budget [--only public|app]` builds
    the bundles minified into `_build/asset_budget/` and fails when
    `public.js` passes 12,000 B minified or 5,000 B gzipped, carries
    LiveView, Phoenix, the colocated hooks, Sortable, topbar, the rich-text
    editor, TipTap or Yjs, or loses `js/challenge.js`; and when `app.js`
    loads TipTap, Yjs or the rich-text editor outside `import()`. `app.js`
    sizes are printed, not gated. CI's required `build` job runs
    `--only public`, which needs no npm.
  - **Dev.** A third esbuild watcher builds `public.js`, and the dev
    assets banner names it when it is missing.

  See [Which script a page loads](../frontend-assets.md#which-script-a-page-loads).

<a id="referrer-suppression-sweep"></a>

- **The wide search behind the referrer-suppression rule is now a test you can re-run (#3123).**
  The "no all-hidden breakdown leaves a category a single value" rule (#2981) was found by a search run outside the suite, so a change to `referrer_sources/0` or to `KilnCMS.Analytics.suppress_referrer_group/1` had nothing wide to re-check against. The search is now in `test/kiln_cms/analytics/referrer_suppression_test.exs` behind the `slow_sweep` tag, which the default suite excludes. Run it with `mix test --only slow_sweep test/kiln_cms/analytics/referrer_suppression_test.exs` after touching either. It covers thresholds 2 to 20 with four, five and six categories, bounded at view totals of 40, 30 and 20; the original hand search went to 50, and the committed one does not re-run totals above these bounds. A second test in the sweep checks that the criterion can fail (three categories at a threshold of 3 still do). To let the sweep vary the number of categories, `suppress_referrer_group/2` takes an explicit category list; `/1` is `/2` over `referrer_sources/0`, and a default-suite test pins that. Nothing published changes: the dashboard and the export still call `/1`, and no setting or output differs. Operators have nothing to do. The decision record for the rule (ADR 0075) is on a separate open pull request.

## Fixed

<a id="automation-job-payload-sealed"></a>

- **Automation jobs store the event payload sealed (#2992).**
  `Automation.handle_event/3` and the rule fan-out used to queue
  `DispatchWorker` and `RuleWorker` with the event's payload, the serialized
  document with its drafts, in the clear: it sat in the `oban_jobs` row while
  the job waited and appeared in Oban's `job:start`/`job:stop` log lines. Both
  writers now put it under `"sealed"` (`KilnCMS.Jobs.PrivateArgs.seal/1`), as
  form mail jobs already do; `event`, `org_id`, `rule_id` and `document_id`
  stay readable, which is what the rule job's uniqueness compares, and the
  payload is still dropped from the row once the job finishes. Readers keep
  accepting the clear `"payload"`, so jobs a 1.11 node queued during a rolling
  deploy still run, and a rollback to 1.11 runs the sealed ones. Before rolling
  back past 1.11, let the automation jobs on the `default` queue finish
  ([docs/releasing.md](../releasing.md)). No migration.
  ([#2992](https://github.com/The-Verscienta/kiln_cms/issues/2992))

<a id="public-html-etag-render-inputs"></a>

- **A public page's `ETag` now covers everything the page is rendered from, so a revalidation can no longer get a `304` for a page that has changed (#2765).**
  The HTML `ETag` hashed the record's own columns, its resolved SEO title and description, the site's head generation, the forms it renders, the chrome locale and the build. Much of what a page shows is not on its row: a republished fragment, an edited image's alt text, a newly published translation (the hreflang links and the language switcher), a field inherited along a locale fallback chain, a byline's person, the author's display name, a category named by an SEO pattern, and a menu link to another page. When one of those changed, the server rendered the new page but a browser or CDN sending `If-None-Match` still got a `304` and kept the old one.

  The tag now also includes:
  - **A hash of the whole cached delivery payload**: blocks with fragments, media and forms resolved, sibling translations (now sorted by locale, so two builds of the same data hash the same), inherited `:fallback` fields, bylines and the author. It is computed once when the payload is built and stored with it, so a cache hit does no extra work.
  - **A hash of the header and footer menu trees** as the page renders them (two cache hits).

  New writes that move the tag:
  - Any write to a content type or one of its fields, and any save of the site's locale fallback settings, now moves the site's head generation, and with it every page's tag on that site. Feed and calendar links and the type's label come from the type registry, and the language switcher from the fallback chains. The type-registry move was added in #1208 and lost in #1227.
  - Renaming a category drops that site's cached payloads, because the `[category]` SEO token puts its name in the `<title>`. Renaming a tag or tag group drops nothing, because no delivered page shows a tag.
  - Changing a user's display name drops every site's cached payloads, because the name is the byline fallback and the JSON-LD `author` on any site the user wrote for. This covers a profile save, accepting an invitation over an unconfirmed account, and an erasure.
  - Neither rename drop fires when a save leaves the name unchanged.

  A menu link follows its target page's current published path, and drops out when the page is unpublished. Menu trees are cached for 5 minutes, so after a linked page is renamed or unpublished, pages carrying that menu revalidate to a `200` once the cache entry expires.

  For operators: every public HTML `ETag` changes once on upgrade, as with any deploy that changes the build fingerprint, so clients and CDNs fetch each page once in full. There is no migration and no new configuration, and rolling back is safe. Still open: a page served at its path alias renders without its reference bylines and inherited `:fallback` fields (#3193). See [How the targets are met](../performance.md#how-the-targets-are-met).

<a id="federation-shared-inbox-dedup"></a>

- **A publish now sends one signed POST per remote inbox instead of one per follower, and a fan-out that fails part-way can be retried without re-sending (#2753).**
  The fan-out wrote a ledger row and a delivery job for every follower, to the
  follower's delivery inbox, which is the instance's `sharedInbox` when it
  publishes one. 2,000 followers on one instance meant 2,000 identical signed
  POSTs there per publish, which invites rate limiting, and the 429s that
  followed counted against every one of those followers toward the drop
  ceiling. The loop was not transactional either, so when it failed part-way
  `AnnounceWorker` re-ran it and re-sent to everyone already queued.
  - **One delivery per distinct inbox.** Followers are grouped by
    `Follower.delivery_inbox/1` and each group gets one ledger row and one
    POST. Everything the fan-out sends is addressed to the public and
    followers collections, which is what a shared inbox fans out on, so the one
    POST reaches every follower there. On `/editor/federation`, **Recent
    deliveries** now shows one row per inbox.
  - **Whose outcome it is.** A row's `follower_id` set means exactly that
    follower (an inbox with one follower when the row was written, and every
    `Accept`); `nil` means every follower whose deliveries go to the row's
    `inbox_uri` when the delivery settles, including followers who arrived
    after the row was written. A success resets all of them; a delivery that
    exhausts its 12 attempts charges each one failure, in one atomic `UPDATE`,
    and drops those it takes to `drop_follower_after`. Each follower is still
    charged once per failed delivery, so a dead instance's followers are
    dropped after the same number of publishes as before. A failed credit or
    charge is now logged at warning.
  - **All or nothing.** The ledger rows and delivery jobs are written in one
    transaction (job inserts chunked at 500). A failure leaves nothing behind
    and the calling worker retries from a clean start;
    `KilnCMS.Federation.deliver_to_followers/5` returns `{:error, reason}`
    instead of crashing on a `MatchError`. Residual window: a worker that dies
    after the commit and before Oban records the job done fans out a second
    time, one extra POST per inbox, carrying an activity id the receiver
    already saw for a document activity. An `Accept`'s ledger row and job are
    now written in one transaction as well; where it is sent is unchanged
    (sending it to the follower's personal inbox is #3186).
  - **For developers.** New `Follower` read action `:at_inbox` (code interface
    `KilnCMS.Federation.followers_at_inbox/2`, argument `inbox_uri`), the
    inverse of `delivery_inbox/1`, under the existing read policy (the
    `:federation` and `:operator` system actors). `deliver_to_followers` gains
    an `opts` argument (`:batch_size`, default 500) and its return type is now
    `:ok | {:error, term()}`. `Follower`'s `:record_failure` and
    `:record_success` are now atomic.
  - **Known cost.** Settling a shared row reads the site's followers by inbox
    with no index on the shared inbox column (#3187).
  - **Upgrade and rollback.** No migration and no config. Rolling back is
    possible, with one effect: the previous release's delivery worker does
    nothing with a row whose `follower_id` is `nil`, so shared rows still queued
    at rollback are delivered but credit or charge no follower. See
    [One POST per inbox](../federation.md#one-post-per-inbox-2753).

<a id="release-refusal-text-abandon-log"></a>

- **Release refusals are translated in the content editor, and an admin's *Release a stuck claim* that wins against a running go-live or rollback no longer logs an error (#3074, #3075).**
  The four refusals an add to a release can hit (*release is no longer open
  for changes*, *release was not found*, *release is full (N items); ship or
  split it*, *release size could not be checked*) now go through gettext, with
  Spanish and French catalogs, so the content editor's flash shows them in the
  editor's language. Callers with no viewer locale (JSON:API, GraphQL, the
  release worker) get the process's default locale and so English; we did not
  check whether any API plug sets another locale. Separately, when an admin
  abandons a release while its go-live or rollback is still running, the
  worker's outcome write loses to the abandon by design, and that used to log
  an error from the release and another from the worker. It now logs at info
  only; error-level alerting no longer fires on it. Every other abort still logs
  at error, and `release.failed` still fires once. Developers:
  `KilnCMS.CMS.Releases.publish/1` and `roll_back/1` can now return
  `{:error, :abandoned}` (nothing shipped, the abandon recorded the outcome).
  The release worker is their only caller in core; a plugin calling them
  directly should treat it as "stopped by an admin", not as a failure. No
  migration; rolling back is safe. Follow-ups, separate PRs: #3073 (item-cap
  serialization) and #3072 (cleanup of stranded pending items).

<a id="bearer-scheme-any-case"></a>

- **A valid JWT under `bearer` or `BEARER` now authenticates on `/api/*`, `/gql` and `/api/feed`, reversing the 1.9.0 note that made it a `401` (#2632).**
  An HTTP authentication scheme is case-insensitive (RFC 7235). Since 1.9.0
  the bearer check matched it that way, but AshAuthentication's JWT loader
  reads only the exact `Bearer ` spelling, so a valid `bearer <jwt>` loaded
  no user and was refused as an invalid token. The
  [1.9.0 Breaking note](v1.9.0.md#bearer-401-hardening) documented that
  refusal as intended; it no longer applies. A new plug,
  `KilnCMSWeb.Plugs.LoadFromBearer`, replaces `:load_from_bearer` on the
  `:api`, `:graphql` and `:feed` pipelines: it hands the loader a copy of the
  request with each bearer value rewritten to `Bearer <token>` and puts the
  caller's `authorization` headers back afterwards, so nothing downstream sees
  a rewrite. The same reading, `KilnCMSWeb.BearerAuth.parse/1` (scheme in any
  case, surrounding whitespace and any run of whitespace after the scheme
  tolerated), now serves every surface that takes a bearer:
  - **`/api/*`, `/gql`, `/api/feed`.** `bearer <jwt>`, `BEARER <jwt>` and
    `  bearer   <jwt>` authenticate as the token's user. A token that does not
    verify (garbage, expired, revoked) and a bare `Bearer` are still a `401`
    in any case, and API keys were already accepted under any case.
  - **Held accounts.** Because a lowercase JWT now loads its user, an account
    its site holds for a second factor gets the specific
    `403 second_factor_required` answer (and the `second_factor_required`
    telemetry event) instead of the generic `401 invalid_token`, or an
    anonymous read with `KILN_API_REJECT_INVALID_BEARER=false`.
  - **`/mcp`.** A `kiln_` key under a lowercase scheme, or in a later
    `Authorization` value (after a proxy's own), now authenticates; both were
    a `401`. The key is found as on `/api`: the first `kiln_` key in any value
    decides. The pipeline's new `KilnCMSWeb.Plugs.RequireApiKey` does this; a
    JWT, garbage or a bare `bearer` is still a `401`. A key accepted this way
    is also remembered for the rate-limit alert
    (`KilnCMSWeb.Plugs.RememberApiKey`).
  - **`POST /api/keys/rotate`.** Same as `/mcp`: `bearer kiln_…`, or the key
    in a second `Authorization` value, now rotates; both were a `401`.
  - **`/metrics`.** With `KILN_METRICS_TOKEN` set, the token is accepted under
    any case of the scheme, with surrounding whitespace trimmed. It must still
    be the only `Authorization` value, and is still compared in constant time.
  - **`/ws/gql`.** See [Breaking](#ws-gql-bearer-scheme-any-case): lowercase
    garbage there is now refused rather than anonymous.

  A client that sent `bearer <jwt>` and handled the `401` by
  re-authenticating will now simply succeed. No migration and no
  configuration; rolling back restores the 1.11.0 answers.

<a id="plugin-check-single-flight"></a>

- **The plugin health check runs one round per server at a time, and a round that runs out of time still caches what it got (#2565).** System started its own check on a cold cache, apart from the background check Security posture starts, so two administrators opening System, or System and Security posture together, each sent hex.pm a full round of requests, each disclosing the installed plugins' names and versions. And with about 13 or more Hex plugins and a slow hex.pm, System's check outran its 90-second wait and was killed before it stored anything, so the 15-minute failure cache never applied: every later visit asked hex.pm again and showed Unknown.
  - **One round per server.** Every round now runs in one supervised process per node. System, Security posture and **Check plugins now** all start it or join the one already running, and wait for its answer; hex.pm is asked once. Closing the page no longer stops the round. A press of **Check plugins now** while another round is in flight joins it instead of asking again; if that round wasn't a forced one, its security notices are the cached ones. A forced check right after a non-forced round still asks; the once-a-minute floor applies to back-to-back forced checks.
  - **One time limit per round, 75 seconds.** It covers Hex and the notices feed together (before, System effectively allowed 90 s and Security posture's background check had no overall limit). A package not started by then is not asked at all, so fewer names reach hex.pm, and one still in flight is cut off; either reads Unknown, never OK. A page waits up to 90 seconds for the round; one that still has no answer reads every plugin Unknown.
  - **A partial answer is cached for 15 minutes**, so the next page load doesn't ask again. That includes a forced check that replaces a complete 24-hour answer: its Unknowns stand for 15 minutes, as a failed request's always have. When the round cut off a notices request that never stored anything (it was waiting behind another request for the feed), the feed's timeout is cached for it too, so the Hex half is served.
  - `mix kiln.plugins.list --health` runs its check inline, as before, through the new `inline: true` option of `Kiln.Plugins.Health.check/1`. `Kiln.Plugins.Health.warm/0` is now `warm/1` (an `:installed` option; `warm()` still works), and `Kiln.SecurityNotices.put_cache/1` is documented.

  No migration and no config; rolling back is safe. See [Check your installed plugins](../security-posture.md#check-your-installed-plugins).

<a id="invitation-keeps-legacy-tier"></a>

- **Accepting an invitation to the default site at a lower tier no longer demotes an account that has no membership but a legacy editor or admin role (#2574).**
  Such an account (created before site memberships; it shows as *legacy* on the
  default site) was joined at the invited tier, so an editor invited as a
  viewer became a viewer. Now its legacy tier is written to a default-site
  membership first, with the audit event `role_granted` (`via: "legacy_carry"`),
  its audiences, and a live temporary role with the same expiry, and the accept
  reports the account as already a member (`:already_member`; the invitation is
  used up and the page says nothing changed). An invitation at the same or a
  higher tier is an ordinary join at the invited tier, with no carry row. Only
  the standing role is protected: the comparison uses the account as re-read
  under its lock, and a live temporary role is not counted. A custom role on a
  swallowed lower-tier invitation is not applied (the account is reported as
  already a member and `role_id` stays unset). New accounts created by an
  invitation are unaffected. An admin's explicit **Add or invite** is unchanged
  and still writes the tier picked, even below a legacy role. For operators: if
  an editor or admin account was demoted this way before the fix, raise it
  again on Team; nothing is migrated and rolling back is safe. Still open, as
  #3178, #3179 and #3180: the console Add can still demote an unaffiliated legacy account,
  approving a registration queued through site single sign-on can demote one
  too, and a custom role on a swallowed invitation is not applied. See
  [If the invitee is already a member](../account-administration.md#if-the-invitee-is-already-a-member).

<a id="webhook-ordering-identity"></a>

- **A late, retried or foreign provider webhook can no longer overwrite a membership with the wrong subscription's state (#2749).** Metadata resolves an event to a membership row, not to a subscription, so a delayed event could undo newer state and an event for an abandoned subscription could rewrite a paying row. Events are now checked before they are applied, and one that fails is acknowledged, writes nothing and ends `ignored` in `/editor/billing` with a reason. `other_subscription`: the membership is `active` or `past_due`, holds a subscription id, and the event is about a different one (logged at warning); a cancellation for a subscription other than the stored one is ignored on any row, so it never overwrites the stored id. `out_of_order`: the event's `created` is older than the last one applied for the same subscription; an equal stamp applies, except that an event that would not cancel never revives a `canceled` row. `comped_not_provider_managed`: a `comped` membership ignores every provider event, and comping a paying member does not cancel their provider subscription (#3156), so cancel it in the provider's dashboard. An event with no subscription id, or an entitling row with no stored one, is still applied. A row that does not entitle accepts a different subscription only when it is `incomplete`, when the state was fetched live at checkout, or when the event is strictly newer than the last one applied, so a late non-cancelling event for a canceled row's old subscription cannot revive it. Checkout completion applies state fetched live, is exempt from the ordering check, and is stamped with the checkout event's own `created`. `invoice.payment_failed` now also has its subscription id read from the newer Stripe shape (`parent.subscription_details.subscription`). The check repeats inside the write transaction under the row lock; a row that moved and an event now superseded settles as `ignored`, and if the row moved but the event still applies the write errors and Oban retries it. Residual window: Stripe's `created` has one-second resolution, so two different events in the same second delivered in the wrong order are not caught. Replaying an applied event still appends a second `reconciled` audit row (status unchanged). Operators: ignored events show in `/editor/billing` with the reason; a burst of `other_subscription` is worth a look. A new nullable column, `billing_memberships.last_provider_event_at` (expand-only, not exposed in the API), and no config. A node on the previous release does not stamp it, which only makes ordering more permissive, so rolling back is safe. See [Late, repeated and foreign events](../memberships.md#late-repeated-and-foreign-events).

<a id="backup-history-cron-keep-days"></a>

- **Imported cron rows judged by the prunes after them (#3113).** On a host where both `scripts/backup.sh` and the app back up, the latest `manifest.json` is often the app's. Cron's `keep_days` was then unknown, so every imported History row whose files were gone read "probably expired".
  - Each imported run now records `keep_days` when a successful cron manifest covers it. A manifest without `components` is cron's; the trigger is not used. This adds one nullable column, through a migration that only adds.
  - The History reads such a row as "expired" only when a cron run imported after it recorded a window that would have removed it. If later cron runs recorded windows and none would have removed it, the row reads "missing". If later runs exist but none recorded its window, the row reads "probably expired", and only once it is older than the keep days.
  - `backup.sh` prunes with the `BACKUP_KEEP_DAYS` in force when the prune runs, so a changed setting is judged correctly.
  - A cron run records its window only if an import runs while cron's manifest is still the latest. Imports run at an app backup's start, during marker sync and when History opens. Cron's separate `db` and `media` entries write no manifest, so they never record one.
  - Rows imported before this change stay as they were.

<a id="scoping-bare-org-id"></a>

- **A member of a non-default site now sees that site's content-type scope on the content list's "New" buttons and the translations dashboard (#2599).** For a member whose membership on a non-default site lists `editable_types`, the content list's New buttons, the translations dashboard's Missing chips and its translation actions were decided by the default site's scope, so they could offer a type the member may not create on their own site, or hide one they may. They now follow the scope of the site being viewed. This was a display error only: the create and update policies already judged the right site, so nothing was allowed that should not have been, and a refused create still failed with the same error. No action is needed.

  For developers, `KilnCMS.Accounts.Scoping.permitted?/4` and `explicitly_permits?/4` take their second argument as a bare org id, an `%Organization{}`, or any query, changeset, action input or plain map carrying `:tenant` or `:to_tenant`. `nil` or a tenant-less subject still means the default site. Any other shape (an integer, an atom, a list, a tuple) now raises `ArgumentError` instead of silently judging the default site. A bare id used to take that silent path, which is how this went unnoticed. Still open: `subject_org_id/1` (used by `effective_tier/2` and `field_grant/3`) and `audience_org_id/1` fall back to the default org for odd shapes; a follow-up will make those resolvers strict too.

<a id="billing-webhook-lost-events"></a>

- **A provider webhook can no longer be recorded without a job to process it (#2748).** The receiver inserted the event row and then enqueued its job as a second step, so a crash or enqueue failure between the two left a `received` row nothing would ever process, and the provider's redelivery was acked as a duplicate. Now `WebhookEvent`'s `:receive` inserts the row and the `WebhookWorker` job in one transaction: a `500` means nothing was recorded and the retry starts clean. A redelivery of a `received`, `failed` or stale `processing` event (claimed more than 10 minutes ago) re-enqueues its job and is then acked; a redelivery of a `processed` or `ignored` event, or of a freshly claimed one, is only acked. The worker has a 3-minute run timeout and rescues exceptions, exits and throws, so the event settles as `failed` and Oban retries. `:claim` can take over a `processing` event older than 10 minutes, in one atomic update. The job is unique on the event id while `available`, `scheduled` or `retryable`, but not `executing`: `Oban.Lifeline` rescues an orphaned executing job only after 180 minutes, and a redelivery must be able to enqueue meanwhile. A crash after the `200` is never redelivered by the provider; recovery there is the rescue, Oban's retry and the takeover. A taken-over event whose membership change had already committed appends a second `MembershipEvent` audit row; access is not granted twice, and ordering is #2749's. Still open, for the sweeper in #3159: a job that exhausts `max_attempts` leaves the event `failed`, a `processed` stamp that fails to save leaves it `processing`, and `received` rows recorded before this deploy have no job. No migration and no config. A rolling deploy is safe (an old node enqueues a non-unique job, which the claim catches), and rolling back is safe. See [Webhook delivery and recovery](../memberships.md#webhook-delivery-and-recovery).

<a id="backup-s3-same-bucket-overlap"></a>

- **S3 destinations naming one bucket through different hosts (#3088).** Overlap between S3 destinations was compared by host, port and bucket. Two destinations reaching one bucket through different endpoint names each pruned it by their own keep rules, so one could delete a backup the other still counted on. Examples: `s3.amazonaws.com` and `s3.us-east-1.amazonaws.com`, R2 account and jurisdiction hosts, or a MinIO by name and by IP. Now two S3 destinations with the same bucket name and nested prefixes block pruning on both, whatever their host. Each row's badge reads "Not pruned: another S3 destination uses a bucket of the same name; the app can't tell whether it is the same store". Saving such a pair is still allowed; only an exact overlap is refused.

<a id="webhook-resolve-ladder-errors"></a>

- **A provider webhook whose membership could not be looked up because of a database fault is now retried instead of dropped (#2754).** While resolving which membership an event concerns, any failed read other than a refusal was treated as "nothing we hold": the event ended `:ignored`, which is final and purgeable, so a transient fault could lose a payment event for good. Now such a failure ends the event `:failed` and Oban retries it (8 attempts, with backoff). Only a malformed identifier in the payload (a `membership_id` or `org_id` that is not a UUID) is still ignored, because a retry cannot change it. Separately, a metadata mismatch (the event's `user_id` differs from the owner of the membership its `membership_id` names) now halts the lookup: the event row is `:ignored` with the reason `metadata_mismatch` and nothing is written. Before, the lookup went on to the subscription and customer ids, which could write the very row the mismatch check had just refused. An org mismatch cannot occur, since the metadata lookup is filtered by that org. Also fixed: with strict tenancy on (the production default), the customer-id lookup raised `TenantRequired` while loading the tier and was swallowed as "no membership", so an event with no usable `membership_id` or subscription id never resolved by customer; it does now, and a customer holding several tiers is told apart by price id within each membership's own site. Operators: you may now see `failed` events in `/editor/billing` during a database incident, and they settle once the retry succeeds; `metadata_mismatch` is worth a look if it recurs. No migration and no config; rolling back is safe. See [Organizations](../memberships.md#organizations).

<a id="billing-recheckout-keeps-live-membership"></a>

- **Choosing "join" again on a tier you already hold no longer demotes the membership (#2747).** The `:start` action upserted the membership row and set its status to `incomplete` unconditionally, so a member whose membership was `active`, `past_due` or `comped` lost their audience and bypassed the audit trail by clicking join a second time, until a webhook restored it (a `comped` one has no webhook to do so). `:start` now carries an `upsert_condition` so only an `incomplete` or `canceled` row restarts; the condition is in the `ON CONFLICT ... DO UPDATE ... WHERE`, so a second tab racing the first is covered. On a live row `Billing.start_membership/2` returns the existing row unchanged with `upsert_skipped` metadata instead of an error. `POST /billing/checkout` then makes no provider call for an entitled member: the member is sent to `/account` with the new notice "You already have this membership." (its "Manage billing" button opens the portal) (translated in the en, es and fr catalogs). No migration and no config; rolling back is safe. See [Choosing a tier you already hold](../memberships.md#choosing-a-tier-you-already-hold).

<a id="experiment-transition-compare-and-swap"></a>

- **A second Start, Conclude or Archive on an experiment from a stale page is now refused (#3122).** The state machine only checked the copy of the experiment the caller held, so two people (or a console tab and `mix kiln.experiment`) acting on the same experiment could both succeed: a second Conclude overwrote `winner_variant_id` and sent `experiment.concluded` again. `:start` now requires the stored state to be `draft`, `:conclude` requires `running`, and `:archive` requires `draft`, `running` or `concluded`, checked in the same UPDATE that writes the change, so the loser gets a stale-record error and nothing is written. In the console (Experiments), the losing click shows "This experiment changed since you opened it. It's been reloaded." and the page refreshes to the current state. `mix kiln.experiment conclude` now stops with "Could not conclude: …" and the reason instead of a `MatchError`. A new test fails when any AshStateMachine transition action in the app has no filter, so the next state machine gets the same guard. ADR 0074 records the rule. No migration and no config; rolling back is safe.

<a id="backup-destination-retention-gaps"></a>

- **Destination retention gaps (#2950).** Three changes:
  - **Opt-in pruning of `BACKUP_RCLONE_REMOTE`.** Set `BACKUP_RCLONE_REMOTE_PRUNE=true` and in-app backups prune the env remote by the same keep rules as `BACKUP_DIR`. They delete only backups that an in-app run of this backup directory sent there (`origin: app`, same `.kiln-dir-id`). Files from cron, from another directory and from other installations stay put. Pruning is refused, with a notice, while any stored destination could overlap the remote: one that overlaps it, an S3 destination, or a plugin destination whose location the app can't tell. Disabled rows count too. Cron never prunes the remote, so the flag does nothing on cron-only installs. ADR 0064 is amended.
  - **A time limit on each call.** Each retention list call (10 min) and delete call (60 s) has its own limit, as does each abort in the upload sweep (60 s). A slow store no longer uses up the whole step's deadline. A listing that times out skips retention for that destination; a delete that times out stops the pass and keeps the rest. A delete cut off at its limit may already have removed the file. The next pass sees it gone.
  - **One rule for the badge and the pass.** The Destinations tab shows "Prunes its old backups" only when pruning can actually run. Otherwise it shows "Not pruned: <reason>". The env card says whether pruning is on, or why it is blocked.

<a id="idna-punycode-length-advisory"></a>

- **idna 8.0.0 fixes EEF-CVE-2026-117678: a long `xn--` label in an email address's domain no longer costs super-linear CPU when Swoosh encodes it to send mail.**
  idna 7.1.0 and earlier decoded a punycode (`xn--`) label before checking
  it against the 63-octet label limit, so one long label takes
  super-linear CPU to reject. Kiln reaches idna through Swoosh, which
  encodes the domain of every recipient address when it renders an email.
  Some of those addresses come from people who aren't signed in (a
  public form's autoresponder writes to the address the visitor typed),
  so treat it as reachable. JSV also depends on idna, but only for its
  `hostname` format check, and Kiln's field schemas treat `format` as an
  annotation, so that path never runs. The advisory was published
  2026-11-19 and affects idna 0.5.0 up to 7.1.0. Lock-only: idna 7.1.0 →
  8.0.0, with jsv 0.26.2 → 0.28.0 and swoosh 1.26.3 → 1.30.0, the first
  releases of each that accept idna 8. No other lock file carries idna.

<a id="backup-local-retention-gaps"></a>

- **Two local retention gaps (#3003, #3004).**
  `scripts/backup.sh prune` printed a skipped or partial prune to stderr
  only, so it reached the cron log and nowhere else. It now writes
  `$BACKUP_DIR/.kiln-prune-status.json` (when, outcome `ok`, `skipped` or
  `partial`, and a short reason) at the end of every prune, and the app's
  marker sync turns a skip into a retention notice on the Backups page and
  Home ("The host's backup.sh prune was skipped on …"); the next clean
  cron prune clears it. Cron's notice and the app's own prune notice are
  kept apart, so neither clears the other. And the app deleted a local
  backup even when it couldn't remove that backup's stale `.hold` marker
  (for example a directory or a read-only file in its place), then later
  reported its own delete as "deleted outside the app"; it now keeps the
  backup, logs why, and shows a "Retention stopped part-way" notice until
  the marker is fixed.
  ([#3003](https://github.com/The-Verscienta/kiln_cms/issues/3003), [#3004](https://github.com/The-Verscienta/kiln_cms/issues/3004))

<a id="backup-heartbeat-lock-gaps"></a>

- **Heartbeat and lock gaps (#3078, #3091, #3095).**
  - **Recording an interrupted backup no longer holds up the heartbeat.**
    When the heartbeat (or a backup request) took over a stopped node's
    backup, it recorded the failure and cleaned the backup's work files in
    the heartbeat process; on a hung `BACKUP_DIR` that stopped this node
    beating. The lock is still released and the waiting request promoted at
    once, and the run is failed at once in the database; the file work (the
    failure `manifest.json`, removing the work directory) follows in a
    background task, one at a time, and only while no newer backup has used
    the lock or written a later manifest. A node whose file work is stuck
    stops taking over other nodes' backups until it recovers.
  - **A restarted node keeps its last backup-directory id** from its own
    beat for up to 180 seconds, so a node holding a copy of a backup's
    files no longer resumes it beside a source host whose first read after
    a restart hangs.
  - **A resume waiting because its backup record can't be read** shows
    "Waiting: this backup's record couldn't be read" on the Backups page.
  - **A queue the heartbeat paused stays its own** across a heartbeat
    restart, so it is resumed when its directory id returns; and log lines
    about a resume's start name the backup being resumed.
  ([#3078](https://github.com/The-Verscienta/kiln_cms/issues/3078), [#3091](https://github.com/The-Verscienta/kiln_cms/issues/3091), [#3095](https://github.com/The-Verscienta/kiln_cms/issues/3095))

<a id="backup-history-home-polish"></a>

- **History and Home wording (#2940, #2942, #3005).**
  The **couldn't check** and **couldn't check in time** chips on a History
  row now have a **?** tip saying the app couldn't read the backup
  directory (or a file in it, or its read failed or timed out) and so
  claims nothing about those files. A media set with some parts on disk and
  the rest only off-site still reads missing, but a separate chip now says
  "2 parts missing here, copied off-site: 02, 03", and "N parts missing"
  lists only the parts with no copy anywhere. On Home, the red backup strip
  showed "Scheduled backups run from the server's cron job…" even when its
  only cause was a retention notice or a partly off-site backup; the
  schedule and cron lines now appear only when a backup is failed or
  overdue. ADR 0072 records how History judges what is on disk,
  superseding ADR 0033's list of states.
  ([#2940](https://github.com/The-Verscienta/kiln_cms/issues/2940), [#2942](https://github.com/The-Verscienta/kiln_cms/issues/2942), [#3005](https://github.com/The-Verscienta/kiln_cms/issues/3005))

<a id="backup-schedule-tab-followups"></a>

- **Three Schedule tab fixes (#2983, #2985, #2986).**
  - **A scheduler that ticks less often than a schedule** (for example
    `KILN_BACKUP_SCHEDULER_CRON=0 */6 * * *` with an every-2-hours schedule)
    skipped windows silently. The schedule's card and the form preview now
    warn. The gap is worked out from the expression's minutes, hours and
    weekdays (so `*/5 * * * 1-5` or a weekly cron warns on a daily
    schedule); a day-of-month or month restriction counts as at least a
    day; the default `* * * * *` never warns.
  - **A keep-days change made while an in-app backup holds the backup lock**
    reached the `.hold` markers only if that backup finished successfully,
    so a host `backup.sh prune` could delete units the schedule now keeps.
    The change's marker sync, and the syncs it routes to other hosts, now
    wait (checking every two minutes) until the backup releases the lock,
    then write the markers whatever its outcome; they give up with a warning
    after three hours.
  - **The Schedule tab read the backup status (`manifest.json`) on the page
    process**, so a hung network mount froze it. It now reads it in the
    background with a 5-second limit, as the Backups page does, and says
    when it couldn't check in time.
  ([#2983](https://github.com/The-Verscienta/kiln_cms/issues/2983), [#2985](https://github.com/The-Verscienta/kiln_cms/issues/2985), [#2986](https://github.com/The-Verscienta/kiln_cms/issues/2986))

## Security

<a id="liveview-url-less-join"></a>

- **phoenix_live_view 1.2.14 fixes EEF-CVE-2026-126334 (GHSA-v4p7-3pm2-wq6c,
  medium).** In earlier releases a signed-in user could open a websocket by
  hand and join a router-mounted LiveView without the `"url"` key. The
  channel then matched no route and skipped the `live_session`'s `on_mount`
  hooks, which is where Kiln's sign-in, tenant and editor/admin role checks
  run. Kiln was not exposed: since #688 every Kiln LiveView carries
  `KilnCMSWeb.LiveRouteGuard`, a module-level hook that refuses such a join,
  and a test checks every `live` route in the router carries it. 1.2.14
  refuses the join in the channel itself, before mount, so the reply is now
  `"unauthorized"` instead of the guard's 404 reload. The guard stays as a
  second line. `mix.exs` now requires `~> 1.2.14`, so a lock cannot resolve
  back to an affected release. `examples/phoenix_showcase`, which has its
  own lock, moves from 1.2.12 to 1.2.14 with the same floor. No migration
  and no configuration; the
  JavaScript client is built from the same Hex package, so there is no
  separate npm bump.
  ([#3190](https://github.com/The-Verscienta/kiln_cms/issues/3190))
