# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

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

## Added

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

## Upgrade notes

<a id="backup-s3-same-bucket-overlap-upgrade"></a>

- **Two S3 destinations on one bucket name stop pruning (#3088).** After the upgrade, an installation with two S3 destinations that name the same bucket, one prefix inside the other, on different hosts skips retention on both. Each pass leaves a "Retention on … skipped" notice, and the storage grows until you act. Give the two destinations prefixes side by side, or untick "Delete its old backups (retention)" on one of them if they really are separate stores.

