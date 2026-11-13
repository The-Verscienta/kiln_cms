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
**Upgrade notes**, **Breaking**, **Known issues**, **Added**, **Changed**,
**Fixed**, **Security** and **Removed**, in that order. A minor or major
release opens with a link to its **What's new** guide under
[`docs/whats-new/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/whats-new),
which walks through the release with examples and migration steps. Every
line links to the pull request that shipped it, and — where the entry was shortened — to its own
long-form entry under [`docs/changelog/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/changelog), which holds the
reasoning as it was written when the change merged. A handful of entries argue
a choice that outlives their release; those live in
[`docs/decisions/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/decisions) instead.

The sections that decide whether you can upgrade today are the first three:

- **Upgrade notes** — steps to perform against a *deployed* instance, and
  anything not reversible by rolling the pin back (a destructive migration, a
  rewritten column, a dropped config key).
- **Breaking** — an observable contract changed, or your overlay or deployment
  has to change to keep working.
- **Known issues** — bugs the release ships with: the symptom, who is
  affected, the workaround and the tracking issue.

`mix kiln.update` prints **only those**: the first two for every release
between your current pin and the target, and the target's known issues. A
release with none of them is "bump the pin, rebuild, redeploy" and nothing
else.

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

### Added

- **The editor's image picker (featured image, social image, image and gallery blocks, media fields) has its own Upload button and drop zone; the uploaded image is used right away.**
  ([long form](docs/changelog/unreleased.md#image-picker-upload))

### Changed

- **No form field of any type can be named `website` (the spam trap's input) on add, rename or type change; a field that already is keeps working and is flagged "Reserved name" in the builder until renamed.**
  ([long form](docs/changelog/unreleased.md#form-field-name-website-reserved))

### Fixed

- **Duplicating a form whose autoresponder is on and uses `[field:…]` tokens works again; a `website` field is copied as `website_2`, and a field that can't be copied is named.**
  ([long form](docs/changelog/unreleased.md#form-duplicate-autoresponder))

- **Public forms show number and rating errors as translated sentences (the JSON API keeps its English), and the builder explains default values for choice fields and ratings.**
  ([long form](docs/changelog/unreleased.md#form-errors-translated))

- **A public form's error summary links move focus to radio buttons, checkbox groups and ratings (their first option); a hidden field's error is listed without a link.**
  ([long form](docs/changelog/unreleased.md#form-error-summary-focus))

- **The on-site thank-you page and "Form not found" page after a form submission render in the site's layout and language; the Back link refuses `//` and `/\` paths.**
  ([long form](docs/changelog/unreleased.md#form-thank-you-site-layout))

- **Custom content types on a site other than the default one are delivered again: `/api/content`, the passphrase unlock, related content, provenance and the visual-editing socket looked the type up on the default site.**
  ([long form](docs/changelog/unreleased.md#dynamic-type-site-lookup))

- **A copy from storage that fails partway is now an error, not a short file treated as complete (direct uploads, audio/video metadata stripping), and `backup.sh verify` fails on a dump `pg_restore` cannot list.**
  ([long form](docs/changelog/unreleased.md#storage-copy-and-backup-verify))

- **Console and API crash fixes: a task, menu item or calendar entry pointing at an archived content type; a nested custom-field filter value; a redirect from `/`; a non-object federation inbox body; a `return_to` with a backslash.**
  ([long form](docs/changelog/unreleased.md#sweep-crash-fixes))

- **Wrong results fixed: the Home health panel's "most overdue" order, `@mentions` of names with accented letters, rating fields with a maximum below 1, and saved Presentation edits crashing an open preview.**
  ([long form](docs/changelog/unreleased.md#sweep-wrong-results))

- **A federation delivery whose ledger row could not be read is retried instead of dropped, and scheduling a release with blocked items asks for confirmation on Schedule, not on a click of the date field.**
  ([long form](docs/changelog/unreleased.md#sweep-federation-release))

- **Cron-only deployments now get the last-good backup marker: the app writes `kiln-<stamp>.good` every 15 minutes (`KILN_BACKUP_MARKER_SYNC_CRON`), so `backup.sh prune` keeps the newest verified backup.**
  ([long form](docs/changelog/unreleased.md#backup-marker-sync-cron-only))

- **The 1.9.0 known issue "Resume on a failed backup says it is queued but never runs" was fixed in 1.9.0 itself (#2688); the resume is refused with a message instead.**
  ([long form](docs/changelog/unreleased.md#resume-behind-queued-resume-already-fixed))

- **`bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'` runs again: release tasks under
  `eval` read through the content cache, which only a serving node starts, instead of crashing.**
  ([long form](docs/changelog/unreleased.md#release-eval-read-through))

- **The content editor's Featured image field shows an image older than the org's 500 most recent uploads, with its Remove link, instead of "None selected".**
  ([long form](docs/changelog/unreleased.md#featured-image-older-than-picker-window))

- **The Backups page shows recovery-point and last-good badges on History rows and a last-good summary, explains the backup queue under Back up now, and hides Cancel on a finishing row.**
  ([long form](docs/changelog/unreleased.md#backups-page-markers-and-queue-help))

## [1.9.2] - 2026-11-12

Long form: [docs/changelog/v1.9.2.md](docs/changelog/v1.9.2.md) —
the 1.9.2 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Fixed

- **Rejecting a registration with erasure now keeps an account that authored content of a
  project overlay's own types (or their versions): those columns are read off the content
  registry, not a list naming entries, pages and posts.**
  ([#2710](https://github.com/The-Verscienta/kiln_cms/issues/2710) · [long form](docs/changelog/v1.9.2.md#erasure-overlay-content))

- **The core suite passes under a project overlay: eight tests no longer assume the core
  registry, and the schema goldens are excluded (`:core_registry`) when one is compiled in.**
  ([#2710](https://github.com/The-Verscienta/kiln_cms/issues/2710) · [long form](docs/changelog/v1.9.2.md#overlay-safe-suite))

## [1.9.1] - 2026-11-11

Long form: [docs/changelog/v1.9.1.md](docs/changelog/v1.9.1.md) —
the 1.9.1 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Security

- **The image's `rclone` is now 1.76.0, which fixes two HIGH vulnerabilities in
  the 1.75.2 binary that 1.9.0 shipped: a denial of service in
  `golang.org/x/net/html` (CVE-2026-78661) and Go's `crypto/x509` accepting
  untrusted intermediate certificates (CVE-2026-111943).**
  ([long form](docs/changelog/v1.9.1.md#the-images-rclone-is-now-1760-which-fixes-two-high-vulnerabilities-in-the-1752))

## [1.9.0] - 2026-11-11

Long form: [docs/changelog/v1.9.0.md](docs/changelog/v1.9.0.md) —
the 1.9.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

What's new, with examples and migration steps: [docs/whats-new/v1.9.md](docs/whats-new/v1.9.md).

### Upgrade notes

- **Confirmation links mailed before the upgrade keep working, but the page now asks for the password chosen at sign-up. A client that posts to `/auth/user/confirm_new_user` itself must send `password` with the token. A magic-link sign-in to an unconfirmed account now replaces its password: the owner sets one by reset.**
  No migration; rolling back is safe.
  ([#2594](https://github.com/The-Verscienta/kiln_cms/issues/2594) · [long form](docs/changelog/v1.9.0.md#pre-hijack-takeover-upgrade))

- **If a CDN caches the site's pages, purge it after deploying (#2630).** Copies cached before the deploy still carry one visitor's CSRF token until they expire (up to about six minutes). No migration; ETags already change on deploy.
  ([#2630](https://github.com/The-Verscienta/kiln_cms/issues/2630) · [long form](docs/changelog/v1.9.0.md#shared-cache-session-free-upgrade))

- **Run `mix ash.migrate` (new table `instance_security_events`; moves existing `backup_canceled` events out of the default site's security log into it). Optional: `KILN_INSTANCE_SECURITY_LOG_RETENTION_DAYS` (default 365).**
  Rolling back moves them back to the default site's log before dropping the table; export the instance log first if you need it.
  ([#2541](https://github.com/The-Verscienta/kiln_cms/issues/2541) · [long form](docs/changelog/v1.9.0.md#instance-security-log-upgrade))

- **If the app's environment sets `BACKUP_RCLONE_REMOTE`, check it before deploying: the official image now ships `rclone` (pinned, checksum-verified), so in-app backups start copying there, and an unreachable or unconfigured remote fails them. On a custom image without `rclone`, the variable now fails every in-app backup: install `rclone` or unset it.**
  No migration; rolling the pin back is safe. The image grows by about 82 MiB.
  ([#2482](https://github.com/The-Verscienta/kiln_cms/issues/2482) · [long form](docs/changelog/v1.9.0.md#rclone-in-image-upgrade))

- **Run `mix kiln.reserved_paths` (in a release, `bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`) to list pages slugged `access-denied` and path aliases under `/access-denied`, which the new access-denied page (#2143) shadows; give each a new slug or alias.** No migration; read-only.
  ([#2374](https://github.com/The-Verscienta/kiln_cms/issues/2374) · [long form](docs/changelog/v1.9.0.md#reserved-paths-upgrade))

- **Run `mix ash.migrate` (new nullable `backup_locks.waiting_*` columns; `backup_runs.scheduled_components` and `schedule_ids`, default empty). While older nodes still run, a database-only or media-only backup request may back up everything (part of #2219). Rolling back is safe.**
  ([#2685](https://github.com/The-Verscienta/kiln_cms/pull/2685) · [long form](docs/changelog/v1.9.0.md#backup-components-upgrade))

- **Update the host's copy of `scripts/backup.sh` so cron's prune honors the new `kiln-<stamp>.good` marker, which the app keeps on the newest verified backup of each component (part of #2219).** No migration; rolling back is safe.
  ([#2552](https://github.com/The-Verscienta/kiln_cms/pull/2552) · [long form](docs/changelog/v1.9.0.md#backup-last-good-marker-upgrade))

- **Before rolling back to v1.8.0, run `DELETE FROM notifications WHERE event IN ('registration_pending', 'security_alert', 'security_notice');` and `DELETE FROM api_keys WHERE access = 'draft_write';` (re-mint those keys after rolling forward; never `UPDATE` them). Back up, then delete every `key_value` and `telephone` custom field (and its values).**
  Fields of the other types added since v1.8.0, and the new scalar lists, load there but can fail to save or open; the long form has the queries and a console loop.
  ([#2606](https://github.com/The-Verscienta/kiln_cms/pull/2606) · [#2670](https://github.com/The-Verscienta/kiln_cms/pull/2670) · [long form](docs/changelog/v1.9.0.md#rollback-to-1-8-0-upgrade))

- **Run `mix ash.migrate` (new tables `security_alert_dispatches`, `site_security_alerts`; `users.notify_on_security_alert`, `NOT NULL DEFAULT true`). Site member admins now get security alert emails for every kind but failed sign-ins; platform admins get platform alerts they can't mute. A site with no member admins sends them to the platform admins.**
  The stolen-key email is now an alert, with the old email as fallback; alert email uses the instance relay. `security` is a reserved webhook namespace. Before rolling back past #2509, delete the new notifications and `api_key_reuse_detected` events.
  ([#2638](https://github.com/The-Verscienta/kiln_cms/pull/2638) · [long form](docs/changelog/v1.9.0.md#security-alerts-upgrade))

- **Every `/api/content` `ETag` and every Kiln-rendered page's `ETag` changes once on this deploy, so revalidating clients and CDNs get one round of `200`s. Page tags now also change on every deploy whose code or assets differ.**
  No migration; rolling the pin back is safe (another one-time round of `200`s).
  ([#2583](https://github.com/The-Verscienta/kiln_cms/pull/2583) · [long form](docs/changelog/v1.9.0.md#render-etags-upgrade))

- **Run `mix ash.migrate` (new nullable `site_branding.twitter_site`). Fired `json` artifacts move to `format_version` 4 (new `social` key) and re-fire on their first uncached read; on a large site, run `mix kiln.refire_all` after the deploy.**
  `/api/sync` mirrors and clients revalidating with `If-None-Match` keep the old body until a document is edited (#2463). Rolling the pin back is safe.
  ([#2582](https://github.com/The-Verscienta/kiln_cms/pull/2582) · [long form](docs/changelog/v1.9.0.md#twitter-card-upgrade))

- **Accepting an invitation now raises a member below the invited tier; before this, demoting or removing a member left their pending invitation live. For 7 days after upgrading, check Team → Pending invitations for such members and revoke those invitations.**
  No migration; rolling the pin back is safe.
  ([#2573](https://github.com/The-Verscienta/kiln_cms/pull/2573) · [long form](docs/changelog/v1.9.0.md#invitation-raise-tier-upgrade))

- **New on by default: with a plugin from Hex installed, opening System or Security posture asks hex.pm about it, which tells hex.pm that plugin's package name and version. Opt out with `KILN_PLUGIN_HEALTH_CHECK=false` (`KILN_UPDATE_CHECK=false` also does, unless the first is set).**
  No migration; rolling the pin back is safe.
  ([#2562](https://github.com/The-Verscienta/kiln_cms/pull/2562) · [long form](docs/changelog/v1.9.0.md#plugin-health-egress-upgrade))

- **Run `mix ash.migrate` (new tables `backup_locks`, `backup_node_beats`; `backup_runs` gains `chain_id` and status `canceled`). Backups run on a new Oban queue `backup_steps` (1 per node; add 1 to `POOL_SIZE`); drain the `backups` queue before the next minor. Node names must be unique.**
  Mid-deploy, don't start backups from an old node. Before rolling back, cancel running backups and relabel `canceled` runs, or roll forward.
  ([#2537](https://github.com/The-Verscienta/kiln_cms/pull/2537) · [long form](docs/changelog/v1.9.0.md#backup-step-chain-upgrade))

- **Run `mix ash.migrate` (new column `field_definitions.width`, new table `field_sections`). Field sync files exported from now on carry `width`, which builds from before this change refuse.** Rolling the pin back is safe.
  ([long form](docs/changelog/v1.9.0.md#field-layout-upgrade))

- **Run `mix ash.migrate` (new nullable `field_definitions.widget`, no backfill). Field-sync files now carry `"widget"`, which an older release's import refuses: upgrade the target first.** Rolling the pin back is safe.
  ([#2495](https://github.com/The-Verscienta/kiln_cms/pull/2495) · [long form](docs/changelog/v1.9.0.md#field-widgets-upgrade))

- **Run `mix ash.migrate` (new table `site_registration`; `org_memberships` gains `status` and `decided_at`). Turn registration approval on only once every node runs this release: an older node reads a waiting registration as an active viewer.**
  Before rolling back, anonymize the waiting and rejected accounts you don't want (don't delete their rows) and delete the three `registration_*` security events (#2509), or roll forward.
  ([#2512](https://github.com/The-Verscienta/kiln_cms/pull/2512) · [long form](docs/changelog/v1.9.0.md#registration-approval-upgrade))

- **Run `mix ash.migrate` (`users.notify_on_registration`, `NOT NULL DEFAULT true`). A node on an older release can't load the new `registration_pending` notification: during a rolling deploy and after a rollback, an admin's bell there shows the count but an empty list and Mark all read fails (#2509).**
  Before rolling back, run `DELETE FROM notifications WHERE event = 'registration_pending'`, or roll forward.
  ([#2517](https://github.com/The-Verscienta/kiln_cms/pull/2517) · [long form](docs/changelog/v1.9.0.md#registration-notifications-upgrade))

- **Run `mix ash.migrate` (`org_memberships.created_account`, `site_registration.approval_for_site_sso`, both `NOT NULL DEFAULT false`). Turn on Registrations → "New accounts from this site's single sign-on wait for approval too" only once every node runs this release: an older node makes those accounts active viewers.**
  ([#2519](https://github.com/The-Verscienta/kiln_cms/pull/2519) · [long form](docs/changelog/v1.9.0.md#registration-invitations-sso-upgrade))

- **Run `mix ash.migrate` (`site_registration.rejected_accounts`, `NOT NULL DEFAULT 'keep'`). Set Registrations → "When you reject someone" to erase only once every node runs this release: an older node takes no account lock, so an erasure can race its membership, billing, key and confirmation writes.**
  Rolling the pin back is safe; accounts already erased stay erased.
  ([#2527](https://github.com/The-Verscienta/kiln_cms/pull/2527) · [long form](docs/changelog/v1.9.0.md#registration-erasure-upgrade))

- **Before rolling back to a build that has the security log but predates sign-in unlock links, delete the `sign_in_unlock_requested`, `sign_in_unlocked` and `sign_in_unlock_refused` security events, or roll forward.**
  No migration. An older build cannot load those rows, which breaks that site's security log and CSV, and erasing a person named in one (#2509). v1.8.0 has no security log and is unaffected.
  ([#2510](https://github.com/The-Verscienta/kiln_cms/pull/2510) · [long form](docs/changelog/v1.9.0.md#sign-in-unlock-upgrade))

- **Run `mix ash.migrate` (`forms` and `form_submissions` each gain a `challenge` column). A custom asset build or overlay Dockerfile that does not run `mix assets.deploy` must also run `esbuild kiln_challenge_embed`.**
  Rolling the pin back is safe, but forms switched to a human-verification check stop asking, without a word, until you upgrade again.
  ([#2501](https://github.com/The-Verscienta/kiln_cms/pull/2501) · [long form](docs/changelog/v1.9.0.md#form-human-verification-upgrade))

- **Lists on number, date, link and other scalar custom fields: no migration, but before rolling back, don't edit those list fields or their records on the older release.**
  It clears `multiple` on such a field's definition when saved, keeping each list's first item, and stringifies a list written there.
  ([long form](docs/changelog/v1.9.0.md#scalar-list-fields-upgrade))

- **Run `mix ash.migrate` (new table `site_admin_allowlist`, then its `restrict_sign_in` column, `NOT NULL DEFAULT true`). Rolling the pin back turns every site's admin allowlist off without a word; while a list is on, members and apps calling `/api/auth/sign_in` sign in only from listed networks unless the site clears "Also restrict sign-in" (#2493).**
  Nothing changes until a site admin saves a list. Lock-out: `bin/kiln_cms rpc 'KilnCMS.Release.admin_allowlist(clear: true)'`.
  ([long form](docs/changelog/v1.9.0.md#admin-allowlist-upgrade))

- **Run `mix ash.migrate` (new table `site_session_policy`; `tokens` gains two nullable columns and an index built concurrently). Every signed-in browser request now reads its session's token row once.**
  Idle timeout is off by default; existing sessions stay signed in. Rolling the pin back is safe.
  ([long form](docs/changelog/v1.9.0.md#session-idle-timeout-upgrade))

- **In-app backups whose off-site copy fails now finish `Failed`, and both paths re-hash each file just before its off-site copy and refuse one that changed; check your rclone remote and credentials if backups turn red.** No migration; rolling back is safe.
  ([long form](docs/changelog/v1.9.0.md#backup-offsite-rehash-upgrade))

- **`scripts/backup.sh` now splits media into `.partNN.tar.gz` parts like the app (400 MB, no off switch), skips empty folders, honours `BACKUP_MEDIA_EXCLUDE` and needs GNU tar or bsdtar; `restore.sh` refuses a part set with no sidecar unless `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1`.** No migration.
  ([long form](docs/changelog/v1.9.0.md#backup-sh-media-parts-upgrade))

- **Run `mix ash.migrate` (new table `site_bot_budgets`). Scripts (`curl`, Go, Java, Python) now get 150 public-page requests a minute per address, not 300, and requests with no user agent 60; one count is shared per address.** Rolling the pin back is safe.
  ([#2470](https://github.com/The-Verscienta/kiln_cms/pull/2470) · [long form](docs/changelog/v1.9.0.md#bot-budgets-upgrade))

- **New on by default: nodes ask their DNS resolver about the address of any visitor claiming to be a search engine. Allow outbound DNS (PTR, A, AAAA), set `TRUSTED_PROXIES` behind a proxy, or set `KILN_CRAWLER_VERIFICATION=false`. With smart 404 blocking on, link-preview fetchers are no longer exempt.**
  No migration; rolling the pin back is safe.
  ([#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591) · [long form](docs/changelog/v1.9.0.md#verified-search-bots-upgrade))

- **Run `mix ash.migrate` (new table `invitations`). A new daily job prunes invitations 30 days past expiry; no setting.** Rolling the pin back is safe; pending invitation links stop working until you upgrade again.
  ([#2448](https://github.com/The-Verscienta/kiln_cms/pull/2448) · [long form](docs/changelog/v1.9.0.md#team-invitations-upgrade))

- **Run `mix ash.migrate` (new tables `security_events` and `site_security_log`); overlays that restate `:ash_domains` must add `KilnCMS.Security`. A new daily prune job is on by default (`KILN_SECURITY_LOG_PRUNE_CRON`, 365-day window).** Rolling the pin back is safe.
  ([#2441](https://github.com/The-Verscienta/kiln_cms/pull/2441) · [long form](docs/changelog/v1.9.0.md#security-log-upgrade))

- **App-made media backups may be several `kiln-media-<stamp>.partNN.tar.gz` files: update any script that globs `kiln-media-*.tar.gz`; after a rollback they do not show in History.** No migration.
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218) · [long form](docs/changelog/v1.9.0.md#backup-media-parts-upgrade))

- **Run `mix ash.migrate` (new table `backup_runs`); overlays that restate `:ash_domains` must add `KilnCMS.Backups`.** Rolling the pin back is safe.
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217) · [long form](docs/changelog/v1.9.0.md#backup-history-upgrade))

- **Run `mix ash.migrate` (new table `site_password_policy`, no data change). Password changes now call the Have I Been Pwned range API by
  default; air-gapped deployments set `BREACHED_PASSWORD_CHECK=false`.** Rolling the pin back is safe.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240) · [long form](docs/changelog/v1.9.0.md#breached-password-upgrade))

- **API consumers: a stale, expired or garbled `Authorization: Bearer` JWT is now a 401 (`invalid_token`), not anonymous
  data. Fix the client; `KILN_API_REJECT_INVALID_BEARER=false` restores the old fallback for this release only.**
  ([#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161) · [long form](docs/changelog/v1.9.0.md#reject-invalid-bearer-default-on))

- **Overlays: run `mix ash.codegen`. Content tables gain a generated `name_lexemes`
  column, filled for every row by the migration (a table rewrite). Nothing else to run.**
  ([long form](docs/changelog/v1.9.0.md#search-name-lexemes-upgrade))

- **Overlays: run `mix ash.codegen` and commit the migration. Existing content types gain the `kiln_reporting_v1` SQL views.**
  Additive; re-run `mix kiln.reporting.sql` grants after upgrading.
  ([long form](docs/changelog/v1.9.0.md#reporting-views-upgrade))

- **Content tables gain a GIN index on `custom_fields`, built concurrently: slow on a large
  `entries`; a failed build leaves an INVALID index to drop. Overlays run `mix ash.codegen`.**
  ([#2321](https://github.com/The-Verscienta/kiln_cms/pull/2321) · [long form](docs/changelog/v1.9.0.md#custom-fields-gin-upgrade))

- **Overlays: run `mix ash.codegen` again for the per-document `noindex` / `nofollow` columns
  on your content types. Both are additive (`NOT NULL DEFAULT false`); `type_definitions` gains two too.**
  ([long form](docs/changelog/v1.9.0.md#robots-flags-upgrade))

- **Overlays and plugins: the field type names `email`, `telephone`, `color`, `slug`, `time`, `json`, `range`, `key_value` and `link` are now built in. Rename a type that uses one; stored definitions with that name get the new strict check.**
  ([long form](docs/changelog/v1.9.0.md#builtin-field-type-names-upgrade))

- **Overlays: run `mix ash.codegen`, commit the migration and run `mix ash.migrate`. Users, memberships and roles gain a `field_read_grants` column.**
  Additive (`NOT NULL DEFAULT '{}'`). Rolling the pin back is safe for data, but an older release ignores read grants, so a private field you restricted shows to editors again.
  ([long form](docs/changelog/v1.9.0.md#custom-field-grants-upgrade))

- **Field definitions gain a `validation` column (`NOT NULL DEFAULT '{}'`, additive, safe to roll back). Overlays: run `mix ash.codegen`.
  `unique` fields have no database backstop; audit with `mix kiln.fields.duplicates`.**
  ([#2406](https://github.com/The-Verscienta/kiln_cms/pull/2406) · [long form](docs/changelog/v1.9.0.md#field-validation-upgrade))

- **Optional: `mix kiln.refire_all` after deploying puts the new code-block focus attributes into `:web` artifacts fired before the upgrade.**
  Revalidating clients get the new HTML; add `--notify` to tell webhook receivers too. No migration.
  ([#2467](https://github.com/The-Verscienta/kiln_cms/pull/2467) · [long form](docs/changelog/v1.9.0.md#focusable-code-blocks-upgrade))

- **Optional: `mix kiln.refire_all` after deploying puts the new table focus attributes, and the wrapper around old bare tables, into `:web` artifacts fired before the upgrade.**
  Same sweep and `--notify` choice as the code-block note above; no migration, safe to roll back.
  ([#2596](https://github.com/The-Verscienta/kiln_cms/pull/2596) · [long form](docs/changelog/v1.9.0.md#scrollable-tables-upgrade))

- **Forms: don't use the new field types until every node runs this release. A node on the
  previous release cannot load a form field with an unknown type, so the public form fails
  to load; rolling the image back breaks any form that uses them.**
  ([long form](docs/changelog/v1.9.0.md#form-field-types-upgrade))

### Breaking

- **Public pages take their language from the URL only. On a fallback page `<html lang>` and `Content-Language` now name the reader's (URL) language; the new `x-kiln-locale` header and `<article lang>` name the record's. Style articles with `.public-article:lang(xx)`, not `html[lang]`.**
  Unprefixed URLs serve only the default locale (a French-only page is a 404 there), and a form page or embed posts under a prefix. Headless APIs unchanged.
  ([#2646](https://github.com/The-Verscienta/kiln_cms/pull/2646) · [long form](docs/changelog/v1.9.0.md#public-chrome-follows-url-locale))

- **Overlay and plugin code: `restore_<type>_version` now refuses a record read before a later write (`StaleRecord`) and increments `lock_version`. Read the record again before restoring, and use the one it returns.**
  The revisions restore route answers a lost race with `409` `invalid_state_transition`, not `422`.
  ([#2616](https://github.com/The-Verscienta/kiln_cms/pull/2616) · [long form](docs/changelog/v1.9.0.md#restore-version-stale-struct))

- **Overlay and plugin code: `purge_<type>` and `purge_media_item` now refuse a record that isn't in the trash (`StaleRecord`). Trash it first (`destroy_<type>`).** The API never exposed `:purge`.
  ([#2609](https://github.com/The-Verscienta/kiln_cms/pull/2609) · [long form](docs/changelog/v1.9.0.md#purge-trashed-only))

- **Console and overlays: `Backups.enqueue/1` returns `{:ok, %{status:, chain:}}`, not an `Oban.Job`, and `Backups.Worker.run/3` requests a backup and waits for it instead of running it inline; both are deprecated for `Backups.request/2`.**
  ([#2537](https://github.com/The-Verscienta/kiln_cms/pull/2537) · [long form](docs/changelog/v1.9.0.md#backup-request-api))

- **Unpublishing and archiving need publish rights (admin, or editor where Team → Publishing allows). Upgraded sites default it off, so editors there lose both, and their `:read_write` keys get 403; an admin can choose Let editors publish.** No migration.
  ([long form](docs/changelog/v1.9.0.md#takedown-needs-publish-rights))

- **Overlays: `Accounts.Bootstrap.create_first_admin/1` returns `{:ok, user, notices}`, not `{:ok, user}`.**
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240) · [long form](docs/changelog/v1.9.0.md#breached-password-bootstrap-return))

- **Registering no longer signs the user in: everyone is told to check their email and sent to `/sign-in`, and an address that already has an account gets no new row.**
  ([long form](docs/changelog/v1.9.0.md#registration-no-enumeration))

### Known issues

- **Resume on a failed backup says it is queued but never runs.**
  ([#2671](https://github.com/The-Verscienta/kiln_cms/issues/2671) · [long form](docs/changelog/v1.9.0.md#resume-on-a-failed-backup-says-it-is-queued-but-never-runs))

- **"Backup resumed", then nothing happens.**
  ([#2539](https://github.com/The-Verscienta/kiln_cms/issues/2539) · [long form](docs/changelog/v1.9.0.md#backup-resumed-then-nothing-happens))

- **Backups History shows an "ok" off-site copy for a cron backup that failed.**
  ([#2485](https://github.com/The-Verscienta/kiln_cms/issues/2485) · [long form](docs/changelog/v1.9.0.md#backups-history-shows-an-ok-off-site-copy-for-a-cron-backup-that-failed))

- **A cron backup stays "pending" in History forever.**
  ([#2478](https://github.com/The-Verscienta/kiln_cms/issues/2478) · [long form](docs/changelog/v1.9.0.md#a-cron-backup-stays-pending-in-history-forever))

- **A custom filter on an email, color, telephone or time field misses values
  written another way (`#FFF` vs `#ffffff`).**
  ([#2677](https://github.com/The-Verscienta/kiln_cms/issues/2677) · [long form](docs/changelog/v1.9.0.md#a-custom-filter-on-an-email-color-telephone-or-time-field-misses-values-written))

- **GraphQL `customWhere` with `dateTime` can miss date-time list items saved
  with fractional seconds.**
  ([#2678](https://github.com/The-Verscienta/kiln_cms/issues/2678) · [long form](docs/changelog/v1.9.0.md#graphql-customwhere-with-datetime-can-miss-date-time-list-items-saved-with))

- **Renaming a field's section can move or leave its layout wrongly when another
  admin changed the same type meanwhile.**
  ([#2652](https://github.com/The-Verscienta/kiln_cms/issues/2652) · [long form](docs/changelog/v1.9.0.md#renaming-a-fields-section-can-move-or-leave-its-layout-wrongly-when-another))

- **On a site other than the default one, New draft and Translations can be
  offered or hidden by the default site's type scope.**
  ([#2599](https://github.com/The-Verscienta/kiln_cms/issues/2599) · [long form](docs/changelog/v1.9.0.md#on-a-site-other-than-the-default-one-new-draft-and-translations-can-be-offered))

- **Lock and teaser pages, embedded forms and newsletter confirmation mail can
  be in the wrong language on a multilingual site.**
  ([#2597](https://github.com/The-Verscienta/kiln_cms/issues/2597) · [long form](docs/changelog/v1.9.0.md#lock-and-teaser-pages-embedded-forms-and-newsletter-confirmation-mail-can-be-in))

- **A gallery carousel can't be scrolled with the keyboard.**
  ([#2590](https://github.com/The-Verscienta/kiln_cms/issues/2590) · [long form](docs/changelog/v1.9.0.md#a-gallery-carousel-cant-be-scrolled-with-the-keyboard))

- **A media item trashed while quarantined, then restored, can still be
  permanently deleted from a media trash page loaded earlier.**
  ([#2610](https://github.com/The-Verscienta/kiln_cms/issues/2610) · [long form](docs/changelog/v1.9.0.md#a-media-item-trashed-while-quarantined-then-restored-can-still-be-permanently))

- **A restored event can show a stale next occurrence.**
  ([#2621](https://github.com/The-Verscienta/kiln_cms/issues/2621) · [long form](docs/changelog/v1.9.0.md#a-restored-event-can-show-a-stale-next-occurrence))

### Added

- **`GET /api/schema?format=openapi` and `mix kiln.export.schema --format openapi` serve the delivery schema as OpenAPI 3.1 components, with explicit discriminator mappings; `mix kiln.export.schema --check PATH` fails CI when committed types are stale.**
  Clients: `kiln.schemaComponents()` (`@kiln-cms/client`), `KilnClient.schema(format: :openapi)`. Guide: [docs/native-apps.md](docs/native-apps.md#generate-from-openapi-components).
  ([#2274](https://github.com/The-Verscienta/kiln_cms/issues/2274) · [long form](docs/changelog/v1.9.0.md#schema-openapi-and-check))

- **`GET /api/schema?format=swift|kotlin` serves the native-app models the Mix task writes, `?package=` sets the Kotlin package (invalid: `400` `invalid_package`), and `mix kiln.export.schema` writes and `--check`s the `typescript-graphql`, `swift-graphql` and `kotlin-graphql` formats.**
  ([#2362](https://github.com/The-Verscienta/kiln_cms/issues/2362) · [#2363](https://github.com/The-Verscienta/kiln_cms/issues/2363) · [long form](docs/changelog/v1.9.0.md#schema-swift-kotlin-formats))

- **Forms: new field types `radio`, `checkboxes`, `phone`, `url`, `hidden`, `number`
  (min/max/step) and `rating`, validated server-side, in the builder, the public form, `GET /api/forms/<slug>`
  (new `min`/`max`/`step` keys), mail, entries, CSV and the `form.submitted` payload.**
  ([#2261](https://github.com/The-Verscienta/kiln_cms/issues/2261) · [long form](docs/changelog/v1.9.0.md#form-field-types))

- **`GET /api/feed` streams the change feed as Server-Sent Events: `published`, `updated` and `withdrawn` with identifiers only, the anonymous view whatever the credential, resumable by `Last-Event-ID` (every id is a `/api/sync` cursor) for 24 hours or 1,000 events.**
  Refusals are a `200` with `event: busy` that `EventSource` retries; caps are per node. A boot job records the documents already public, so `/api/sync` deletes may now name those too. Guide: [docs/headless-consumer-guide.md](docs/headless-consumer-guide.md#live-updates-follow-the-change-feed).
  ([#2275](https://github.com/The-Verscienta/kiln_cms/issues/2275) · [long form](docs/changelog/v1.9.0.md#change-feed-sse))

- **An instance security log, for platform admins only: events about the whole installation rather than one site, starting with canceled backups, which no longer appear in the default site's Security log. Security log → Instance log, or `/editor/instance-security-log`, with filters and CSV.**
  Guide: [docs/security-events.md](docs/security-events.md#the-instance-log).
  ([#2541](https://github.com/The-Verscienta/kiln_cms/issues/2541) · [long form](docs/changelog/v1.9.0.md#instance-security-log))

- **Releases document themselves: a `### Known issues` changelog section, which `mix kiln.update` prints for the target release, and a What's new guide per minor release under `docs/whats-new/`, listed on /docs.**
  Process: [docs/releasing.md](docs/releasing.md#documenting-a-release); `/release-docs` runs it.
  ([#2697](https://github.com/The-Verscienta/kiln_cms/issues/2697) · [long form](docs/changelog/v1.9.0.md#release-documentation))

- **`GET /api/security/posture` returns the Security posture checks as JSON for monitoring: an administrator's JWT or API key (never `draft_write`), behind the site's admin allowlist, no details, cached 30 s per node.**
  The allowlist's JSON refusals now read "Not available from this network" / "Temporarily unavailable" (codes unchanged). Guide: [docs/api.md](docs/api.md#security-posture-monitoring).
  ([#2521](https://github.com/The-Verscienta/kiln_cms/issues/2521) · [#2648](https://github.com/The-Verscienta/kiln_cms/pull/2648) · [long form](docs/changelog/v1.9.0.md#security-posture-json))

- **Back up only the database or only the media from a release console (`KilnCMS.Backups.request([components: [:db]], actor)`); the Backups page and the overview report each component's last backup and alarm when either failed or went stale (part of #2219).**
  Guide: [docs/backups.md](docs/backups.md#back-up-only-the-database-or-only-the-media).
  ([#2685](https://github.com/The-Verscienta/kiln_cms/pull/2685) · [long form](docs/changelog/v1.9.0.md#backup-components))

- **Security alerts: site admins get a bell notice and an email when someone becomes an admin, a role is raised, an account is locked out, two-factor is turned off or single sign-on changes; platform admins when a platform admin or API key is created or a stolen key is reused. Organization → Security alerts picks the kinds.**
  One alert per kind per 15 minutes plus a summary; opt-in `security.*` webhook events; turning alerts down sends the site's member admins a notice nobody can mute. Guide: [docs/security-alerts.md](docs/security-alerts.md).
  ([#2638](https://github.com/The-Verscienta/kiln_cms/pull/2638) · [long form](docs/changelog/v1.9.0.md#security-alerts))

- **Security posture gains a Security notices for Kiln line (`core.security_notices`): Fix now, at any severity, when a published notice's affected range covers the running Kiln. System's Updates card shows the same.**
  Off with `KILN_UPDATE_CHECK=false`; shares the plugin check's notices fetch, which `KILN_PLUGIN_HEALTH_CHECK=false` no longer stops. Guide: [docs/security-posture.md](docs/security-posture.md#security-notices-for-kiln).
  ([#2628](https://github.com/The-Verscienta/kiln_cms/pull/2628) · [long form](docs/changelog/v1.9.0.md#core-security-notices))

- **A site can index custom fields for range filters and `custom_sort`: list the field names in `config :kiln_cms, :indexed_custom_fields`, run `mix ash.codegen`, and `gt`/`gte`/`lt`/`lte` and sort-with-a-limit on them read an index instead of scanning the table.**
  Two btrees per name per content table (ascending and descending), built concurrently; nothing is indexed by default, and `mix kiln.custom_fields.index --check` reports drift. Cost and limits: [docs/json-api.md](docs/json-api.md#which-custom-filters-use-an-index), [ADR 0025](docs/decisions/0025-a-site-declares-which-custom-fields-get-range-and-sort-indexes-in-config.md).
  ([#2359](https://github.com/The-Verscienta/kiln_cms/issues/2359) · [#2551](https://github.com/The-Verscienta/kiln_cms/pull/2551) · [long form](docs/changelog/v1.9.0.md#custom-field-range-index))

- **`mix kiln.refire_all --notify` (`KilnCMS.Firing.Sweep.run(notify: true)`) announces each re-fired document to webhook endpoints and the change feed as `<type>.updated` with `"reason": "refire"`, which `Firing.refire/3`'s `updated` now carries too.**
  Not to automation, federation or the CDN purge. Guide: [docs/releasing.md](docs/releasing.md#re-render-published-content-after-an-upgrade).
  ([#2583](https://github.com/The-Verscienta/kiln_cms/pull/2583) · [long form](docs/changelog/v1.9.0.md#refire-notify))

- **Site admins can set the site's X (Twitter) username under Branding, sent as `twitter:site`. Link-preview tags never go out empty, images are absolute on the site's own host, and the `json` artifact gains `social`.**
  Guide: [docs/seo.md](docs/seo.md#link-previews-open-graph-and-x-twitter-cards). Remove any `twitter:site` added under Code injection, or it appears twice.
  ([#2582](https://github.com/The-Verscienta/kiln_cms/pull/2582) · [long form](docs/changelog/v1.9.0.md#twitter-card-tags))

- **Operations → System → Plugins shows whether each plugin still checks out: changed on Hex since this build, a security notice, retired or unmaintained on Hex, or a `kiln_plugin` requirement this Kiln doesn't meet. Security posture gains an Installed plugins line.**
  Unknown is never OK; git and path plugins can't be verified against Hex. `mix kiln.plugins.list --health` runs it too. Guide: [docs/security-posture.md](docs/security-posture.md#check-your-installed-plugins).
  ([#2562](https://github.com/The-Verscienta/kiln_cms/pull/2562) · [long form](docs/changelog/v1.9.0.md#plugin-health-checks))

- **A Slug field can now be marked unique: no two records of a content type (and
  language) may hold the same slug, on every way of saving.**
  ([#2433](https://github.com/The-Verscienta/kiln_cms/issues/2433) · [long form](docs/changelog/v1.9.0.md#a-slug-field-can-now-be-marked-unique-no-two-records-of-a-content-type-and))

- **In-app backups run as retried steps behind a cluster-wide lock: a second backup queues, a stopped node's step moves on, and platform admins can Cancel a running backup (audited, resumable).**
  Each step retries 4 times (1/5/15 min); database-only backups can now be resumed. Guide: [docs/backups.md](docs/backups.md#how-an-in-app-backup-runs-2218).
  ([#2537](https://github.com/The-Verscienta/kiln_cms/pull/2537) · [long form](docs/changelog/v1.9.0.md#backup-step-chain))

- **Site admins can see which security settings are on, and what to fix first, at Organization → Security posture; platform admins also see the installation's checks.**
  Read-only, ten checks; an unknown or broken check counts as a warning, never a pass. Plugins add checks with `security_checks/0` and `Kiln.Security.Check` (`kiln_plugin` 1.4). Guide: [docs/security-posture.md](docs/security-posture.md).
  ([#2520](https://github.com/The-Verscienta/kiln_cms/pull/2520) · [long form](docs/changelog/v1.9.0.md#security-posture))

- **Admins can lay out a type's custom fields as tabs, fieldsets or accordions, and set a field's width (full, half, a third), at Fields → Sections of.**
  Keyboard-accessible tabs in the editor; `GET /api/schema` adds `x-kiln-section-display` and `x-kiln-width`. Guide: [docs/extending-content.md](docs/extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns).
  ([#2496](https://github.com/The-Verscienta/kiln_cms/issues/2496) · [long form](docs/changelog/v1.9.0.md#field-layout))

- **Admins can choose each custom field's editor input: radios or buttons for a select, checkboxes, one-line text, a reference dropdown, or a plugin type's own (`widget`).**
  Editor-only; nothing stored or delivered changes. Guide: [docs/extending-content.md](docs/extending-content.md#choose-how-editors-fill-in-a-field).
  ([#2495](https://github.com/The-Verscienta/kiln_cms/pull/2495) · [long form](docs/changelog/v1.9.0.md#field-widgets))

- **A site can hold new password sign-ups for an admin's approval: Sign-in & access → Registrations, then Approve or Reject each applicant.**
  Until approved an account can sign in but reads only what's public, on every site, and can't pay its way in. Guide: [docs/account-administration.md](docs/account-administration.md#approving-registrations).
  ([#2512](https://github.com/The-Verscienta/kiln_cms/pull/2512) · [long form](docs/changelog/v1.9.0.md#registration-approval))

- **Site admins get one bell notice and email per site when a confirmed applicant is waiting, and applicants are emailed when they're approved or rejected.**
  The notice collapses while unread, names no applicant, and is read by opening Registrations; mute the email under Your settings → Email notifications. Guide: [docs/account-administration.md](docs/account-administration.md#get-told-when-someone-is-waiting).
  ([#2517](https://github.com/The-Verscienta/kiln_cms/pull/2517) · [long form](docs/changelog/v1.9.0.md#registration-notifications))

- **Accepting an invitation, or Team's Add or invite, now approves the person's waiting or rejected registration on that site (an invitation overrides a rejection only if it is newer), and a site can hold new accounts from its own single sign-on for approval.**
  The SSO switch is on Registrations, separate from password sign-ups. Guide: [docs/account-administration.md](docs/account-administration.md#invitations-and-registrations).
  ([#2519](https://github.com/The-Verscienta/kiln_cms/pull/2519) · [long form](docs/changelog/v1.9.0.md#registration-invitations-sso))

- **A site can erase the account of an applicant it rejects whose email address was never confirmed: Registrations → Settings → "When you reject someone".**
  Off by default; only a standing admin's rejection erases, and only an account that is nothing but that registration. A confirmed rejection is always kept. Guide: [docs/account-administration.md](docs/account-administration.md#erase-unconfirmed-applicants-you-reject).
  ([#2527](https://github.com/The-Verscienta/kiln_cms/pull/2527) · [long form](docs/changelog/v1.9.0.md#registration-erasure))

- **Someone whose sign-in is paused after too many attempts can have a link emailed that lifts the pause: "Email me an unlock link" on the sign-in page.**
  The link lasts 15 minutes, works once and goes only to confirmed members of that site (3 an hour). It clears only the account pause, and the sign-in page still never says an account is paused. Guide: [docs/account-administration.md](docs/account-administration.md#lift-a-sign-in-pause-by-email).
  ([#2510](https://github.com/The-Verscienta/kiln_cms/pull/2510) · [long form](docs/changelog/v1.9.0.md#sign-in-unlock))

- **Plugins can add a human-verification provider (`challenge_providers/0`, `Kiln.Challenge.Provider`, new in `kiln_plugin` 1.4); the operator selects it with `CHALLENGE_PROVIDER=<id>`.**
  Checked once against the contract (and by `mix kiln.plugins.doctor`); an unknown or non-conforming provider leaves checks off with a boot warning. The core enforces the hostname and action a provider reports.
  ([#2507](https://github.com/The-Verscienta/kiln_cms/pull/2507) · [long form](docs/changelog/v1.9.0.md#challenge-provider-plugins))

- **Google reCAPTCHA v2 (the checkbox) is a second built-in human-verification provider, `CHALLENGE_PROVIDER=recaptcha`; Cloudflare Turnstile stays the recommended one.**
  Loaded and verified from `www.recaptcha.net` only, never `www.google.com`; v2 keys only; a wrong secret refuses every check. Guide: [Turn on reCAPTCHA](docs/human-verification.md#turn-on-recaptcha).
  ([#2507](https://github.com/The-Verscienta/kiln_cms/pull/2507) · [long form](docs/changelog/v1.9.0.md#recaptcha-provider))

- **Site admins can ask for a human-verification check (Turnstile) on each public form; a submission without a passing check is kept in Spam for review instead of being acted on.**
  Per form, off by default (Forms → General); `CHALLENGE_FORMS=false` turns every form off. `GET /api/forms/:slug` gains `challenge`; headless sites send `_kiln_challenge`.
  ([#2501](https://github.com/The-Verscienta/kiln_cms/pull/2501) · [long form](docs/changelog/v1.9.0.md#form-human-verification))

- **Operators can turn on an adaptive Cloudflare Turnstile check for password sign-in and registration with `CHALLENGE_PROVIDER`, `CHALLENGE_SITE_KEY` and `CHALLENGE_SECRET_KEY`; `/api/auth/sign_in` is only challenged with `CHALLENGE_API_SIGN_IN=true`.**
  Off until configured; deployment-wide; no migration. Guide: [docs/human-verification.md](docs/human-verification.md).
  ([#2249](https://github.com/The-Verscienta/kiln_cms/issues/2249) · [long form](docs/changelog/v1.9.0.md#human-verification))

- **Integer, float, date, date-time, time, URL, email, telephone, colour and slug custom fields can hold a list (Holds → A list in `/editor/fields`).**
  Stored as a JSON array of tidied values, one typed input per item in the editor; `custom_filter` takes `eq`/`in`/`has`/`has_all`/`has_none`/`count`. Guide: [docs/extending-content.md](docs/extending-content.md#make-a-field-hold-a-list-of-values).
  ([#2497](https://github.com/The-Verscienta/kiln_cms/issues/2497) · [long form](docs/changelog/v1.9.0.md#scalar-list-fields))

- **The admin allowlist has an "Also restrict sign-in" checkbox, on by default: cleared, members, readers and apps sign in from any network, at `/sign-in` and `POST /api/auth/sign_in` alike, while the console, `/setup` and their live pages stay behind the list.**
  Admins only; recorded as `sign_in` on `admin_allowlist_changed`. An admin's password then yields an API token anywhere, so require two-factor sign-in first. Guide: [Let members sign in from anywhere](docs/admin-allowlist.md#let-members-sign-in-from-anywhere).
  ([#2493](https://github.com/The-Verscienta/kiln_cms/issues/2493) · [long form](docs/changelog/v1.9.0.md#admin-allowlist-sign-in-toggle))

- **Site admins can restrict the console and every sign-in route, members' and `/api/auth/sign_in` included, to listed IPv4/IPv6 networks, at Configure → Sign-in & access → Admin allowlist.**
  Off by default; fails closed; API keys and issued tokens are not affected. Guide: [docs/admin-allowlist.md](docs/admin-allowlist.md).
  ([#2248](https://github.com/The-Verscienta/kiln_cms/issues/2248) · [long form](docs/changelog/v1.9.0.md#admin-allowlist))

- **Site admins can sign idle browsers out after 15 minutes to 24 hours (shorter for admins) and sign everyone out of the site at once, at Configure → Sign-in & access → Sessions.**
  Off by default; idle wins over "remember me"; API keys and headless tokens are not affected. Guide: [docs/account-administration.md](docs/account-administration.md#sign-people-out-when-idle).
  ([#2246](https://github.com/The-Verscienta/kiln_cms/issues/2246) · [long form](docs/changelog/v1.9.0.md#session-idle-timeout))

- **Optional smart 404 blocking: an address that racks up delivery 404s or probes `/wp-login.php`-style bait paths is blocked for an hour.**
  Off by default; turn on with `KILN_SCANNER_BLOCKING=1`. Guide: [docs/ip-blocking.md](docs/ip-blocking.md#block-scanners-automatically).
  ([#2471](https://github.com/The-Verscienta/kiln_cms/pull/2471) · [long form](docs/changelog/v1.9.0.md#scanner-404-blocking))

- **Public delivery throttles by user-agent class: scripts and clients with no user agent are refused sooner than browsers; admins can lower each class at Configure → Sign-in & access → Bot budgets.**
  Operators set the ceilings with `KILN_BOT_BUDGET_*_PERCENT`; a site may only lower them. Cost control, not security. Guide: [docs/bot-budgets.md](docs/bot-budgets.md).
  ([#2470](https://github.com/The-Verscienta/kiln_cms/pull/2470) · [long form](docs/changelog/v1.9.0.md#bot-budgets))

- **Search-engine claims are checked by reverse and forward DNS; a claim proven false is charged as no user agent (60 a minute by default), and a search-engine budget above 100% goes only to verified addresses.**
  Never on the request path; unchecked claims keep the browser limit. Guide: [docs/bot-budgets.md](docs/bot-budgets.md#verified-search-engines).
  ([#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591) · [long form](docs/changelog/v1.9.0.md#verified-search-bots))

- **Platform admins can invite someone with no account to a site by email: Team → Add or invite, with Pending invitations to resend or revoke.**
  Links last 7 days and work on invite-only sites; an unconfirmed account is now invited, not added. Guide: [docs/account-administration.md](docs/account-administration.md#invite-someone-to-a-site).
  ([#2448](https://github.com/The-Verscienta/kiln_cms/pull/2448) · [long form](docs/changelog/v1.9.0.md#team-invitations))

- **The single-revision API read carries `changed_custom_fields`, the sorted keys of the custom fields that write changed.**
  Additive: `changed_fields` still says `custom_fields`; no migration.
  ([#2353](https://github.com/The-Verscienta/kiln_cms/issues/2353) · [long form](docs/changelog/v1.9.0.md#revisions-changed-custom-fields))

- **Admins get a security log: who signed in, was locked out, or changed a second factor, passkey, role, API key or sign-in setting, and from where.**
  At `/editor/security-log`, with filters, CSV download and a per-site retention window (default 365 days). Guide: [docs/security-events.md](docs/security-events.md).
  ([#2441](https://github.com/The-Verscienta/kiln_cms/pull/2441) · [long form](docs/changelog/v1.9.0.md#security-log))

- **Export and import custom-field definitions between environments: `mix kiln.fields.export` / `mix kiln.fields.import`, release `rpc` functions and an admin download at `/editor/fields/export.json`.**
  One versioned JSON file carries every field attribute, link fields, group sub-fields and dynamic types; the import prints a diff, dry-runs in a rolled-back transaction, applies all-or-nothing, is idempotent, and blocks changes that drop stored values unless `--allow-data-loss`. Admin only; no migration, no DDL.
  ([#2288](https://github.com/The-Verscienta/kiln_cms/issues/2288) · [long form](docs/changelog/v1.9.0.md#field-definition-sync))

- **In-app media backups are split into independent `tar.gz` parts with SHA-256 sidecars, a Resume button for failed runs, and a multi-part `restore.sh media`.**
  Settings `BACKUP_MEDIA_PART_MB` and `BACKUP_MEDIA_EXCLUDE`; no migration.
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218) · [long form](docs/changelog/v1.9.0.md#backup-media-parts))

- **Roles and members can be granted individual custom fields, and private custom fields can be hidden from some editors.**
  New `custom_fields.<name>` grant keys and a `field_read_grants` axis; set both on `/editor/team`. Guide: [docs/granular-rbac.md](docs/granular-rbac.md#per-custom-field-grants-and-read-restrictions).
  ([#2413](https://github.com/The-Verscienta/kiln_cms/issues/2413) · [long form](docs/changelog/v1.9.0.md#custom-field-grants))

- **Backups gains a History of every attempt, app- and cron-made, with verified state and whether files are still on disk.**
  Platform admins, at `/editor/backups`; no new settings.
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217) · [long form](docs/changelog/v1.9.0.md#backup-history))

- **Site admins can block an IP address or range at `/editor/ip-blocks` ("Blocked addresses"): an empty 403 on dynamic routes and sockets.
  Static assets and `/uploads` are not covered; behind a proxy set `TRUSTED_PROXIES` first.
  If an admin blocks their own network, `bin/kiln_cms rpc 'KilnCMS.Release.ip_blocks(remove: true)'` lifts the blocks.**
  ([#2242](https://github.com/The-Verscienta/kiln_cms/issues/2242) · [long form](docs/changelog/v1.9.0.md#ip-block-rules))

- **Custom fields can be shown or required only when another field has a given value (Conditions in `/editor/fields`).**
  Hidden values are kept and still served by the API; new `visible_when` / `required_when` attributes; additive migration, nothing else to run.
  ([#2405](https://github.com/The-Verscienta/kiln_cms/issues/2405) · [long form](docs/changelog/v1.9.0.md#conditional-custom-fields))

- **A custom field can default to today, now, the creating user, the site locale or another field (Default comes from in `/editor/fields`).**
  Create-only, a supplied value wins; new `default_source` / `default_field` attributes; additive migration, nothing else to run.
  ([#2286](https://github.com/The-Verscienta/kiln_cms/issues/2286) · [long form](docs/changelog/v1.9.0.md#dynamic-field-defaults))

- **Admins choose what happens to a breached password at Configure → Sign-in & access → Password policy: off, warn (default) or block for administrators.**
  Checked on register, change, reset and first-run setup, by k-anonymity.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240) · [long form](docs/changelog/v1.9.0.md#breached-password-check))

- **Admins can constrain a custom field: `min`/`max`, length, a whole-value `pattern`, or `unique`, enforced on every write path.**
  Set in `/editor/fields` or via the `validation` attribute; stored values are grandfathered. Audit with `mix kiln.fields.duplicates`.
  ([#2406](https://github.com/The-Verscienta/kiln_cms/pull/2406) · [long form](docs/changelog/v1.9.0.md#field-validation))

- **Admins can replace a webhook's signing secret with Rotate secret on `/editor/webhooks`; it works even when the old secret is unreadable.**
  ([#2347](https://github.com/The-Verscienta/kiln_cms/issues/2347) · [long form](docs/changelog/v1.9.0.md#webhook-rotate-secret))

- **Six built-in custom field types check and tidy a value: `:email`, `:telephone` (E.164), `:color`, `:slug`, `:time` and `:json`.**
  Those six names are now reserved: rename an overlay or plugin type that uses one (`mix kiln.plugins.doctor` fails).
  ([#2411](https://github.com/The-Verscienta/kiln_cms/issues/2411) · [long form](docs/changelog/v1.9.0.md#builtin-format-field-types))

- **Three more built-in custom field types: `:range` (two numbers or two dates), `:key_value` (ordered `key=value` pairs) and `:link` (URL, label, target, rel).**
  Names reserved; stored as JSON, filterable only for "Empty or not", not sortable. Plugin `input_parts` may now declare a select part.
  ([#2278](https://github.com/The-Verscienta/kiln_cms/issues/2278) · [long form](docs/changelog/v1.9.0.md#builtin-composite-field-types))

- **`custom_filter` takes `_or` / `_and` / `_not` groups, a custom sort may come before a built-in one, and sorting by a reference or media field says why it is refused.**
  `filter[or][0][price][gt]=100&filter[or][1][title]=Sale` now works, and `sort=price,title` is one combined order instead of a `400`. Additive; no migration or index.
  ([#2355](https://github.com/The-Verscienta/kiln_cms/issues/2355) · [#2356](https://github.com/The-Verscienta/kiln_cms/issues/2356) · [#2354](https://github.com/The-Verscienta/kiln_cms/issues/2354) · [long form](docs/changelog/v1.9.0.md#custom-field-groups-and-mixed-sort))

- **GraphQL `customWhere` filters custom fields with typed operators: `customWhere: [{name: "price", float: {gt: 10}}]`.**
  A wrong operand type is a schema error; `contains` and `startsWith` (case-insensitive, literal) also work in `customFilter`.
  ([#2290](https://github.com/The-Verscienta/kiln_cms/issues/2290) · [long form](docs/changelog/v1.9.0.md#graphql-custom-where))

- **Admins can move one document to the trash from the content list's row menu or the editor's Settings tab.**
  Same soft delete as bulk Delete; pending autosave edits are saved first. Guide: [docs/trash.md](docs/trash.md).
  ([#2333](https://github.com/The-Verscienta/kiln_cms/pull/2333) · [long form](docs/changelog/v1.9.0.md#move-to-trash-in-editor))

- **The content list can show up to four custom fields on each row; pick them under Columns once one content type is listed.**
  Remembered per person, site and type; additive migration, nothing to run.
  ([long form](docs/changelog/v1.9.0.md#content-list-field-columns))

- **The content list can be filtered by up to four custom-field conditions and sorted by one field once one content type is listed; the count reads "1000+" past 1000.**
  Saved views keep them and flag a field that no longer applies; no migration.
  ([#2293](https://github.com/The-Verscienta/kiln_cms/issues/2293) · [long form](docs/changelog/v1.9.0.md#content-list-field-filter-sort))

- **Editors can download the content list as CSV or JSON from a new Export menu, or only the ticked rows with Export selected.**
  Up to 10,000 rows, the saved list columns, private fields only if ticked; no migration.
  ([#2376](https://github.com/The-Verscienta/kiln_cms/issues/2376) · [long form](docs/changelog/v1.9.0.md#content-list-export))

- **`custom_filter` equality, `in` and list membership use a new GIN index on `custom_fields`: a selective filter on 100,000 rows drops from about 40 ms to about 3 ms.**
  Range, `not_eq`, `ilike`, `null` and `custom_sort` are unchanged.
  ([#2321](https://github.com/The-Verscienta/kiln_cms/pull/2321) · [long form](docs/changelog/v1.9.0.md#custom-field-indexes))

- **Custom fields can be filtered and sorted by bare name (`filter[price]`, `sort=title,price`), and `custom_sort` now works on search routes.**
  ([#2292](https://github.com/The-Verscienta/kiln_cms/issues/2292) · [long form](docs/changelog/v1.9.0.md#custom-field-native-filter-sort))

- **Opt-in `KILN_API_REJECT_INVALID_BEARER=true` answers 401 for an unverifiable bearer token on the API
  instead of serving anonymous data; the default flips on in the next release.**
  ([#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161) · [long form](docs/changelog/v1.9.0.md#reject-invalid-bearer))

- **Change severity: an edit to a safety-relevant field of published content is recorded as critical, notable or routine on its own version.**
  The editor asks before publishing; API writes default to notable; read back as `latest_edit_severity` / `latest_edit_at`.
  ([long form](docs/changelog/v1.9.0.md#change-severity))

- **Read-only SQL views of published content for BI tools: the `kiln_reporting_v1` schema, with a read-only role from `mix kiln.reporting.sql`.**
  Allowlisted custom fields, wide and one-row-per-field; no typed columns yet. Guide: [docs/reporting.md](docs/reporting.md).
  ([long form](docs/changelog/v1.9.0.md#reporting-views))

- **Plugins can mount plain-Plug endpoints (webhooks, JSON, feeds) with `plug_routes/0`, new in `kiln_plugin` 1.4.**
  No session or CSRF check, raw body kept for HMACs, own 300/min rate limit; `mix kiln.plugins.doctor` checks paths.
  ([#2272](https://github.com/The-Verscienta/kiln_cms/issues/2272) · [long form](docs/changelog/v1.9.0.md#plugin-plug-routes))

- **GraphQL reads admin-defined custom fields typed by kind (`customFloat(name:)`, `fields(names:)`), and `GET /api/schema?format=typescript-graphql` exports ready fragments and types; `swift-graphql` and `kotlin-graphql` do the same for native apps.**
  ([#2361](https://github.com/The-Verscienta/kiln_cms/pull/2361) · [long form](docs/changelog/v1.9.0.md#graphql-typed-custom-fields))

- **Drafts-only API keys (`access: draft_write`): a headless service can create and edit its own drafts
  and never publish, delete or touch live content. Drafts record the key and an optional `X-Kiln-On-Behalf-Of` label.**
  ([#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273) · [long form](docs/changelog/v1.9.0.md#draft-write-api-keys))

- **Drafts-only keys can rotate themselves: an admin sets a window at mint, and until then `POST /api/keys/rotate`
  swaps the key for an identical fresh one and revokes the old. Reusing a rotated-away key burns the chain.**
  ([#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273) · [long form](docs/changelog/v1.9.0.md#draft-write-key-rotation))

- **`config :kiln_cms, :i18n, block_fields:` makes core image/video/audio block fields shared or
  fallback across locales; the editor locks them on translations.**
  ([long form](docs/changelog/v1.9.0.md#block-field-localization-config))

- **Per-document `noindex` / `nofollow` (with per-type defaults for new documents): sent as
  `<meta name="robots">` and `x-robots-tag`, carried in versions, copies and the API, left out
  of sitemap, news sitemap, llms.txt and feeds, with an advisory for a menu-linked noindex page.**
  ([#2256](https://github.com/The-Verscienta/kiln_cms/issues/2256) · [long form](docs/changelog/v1.9.0.md#robots-flags))

### Changed

- **A `:range` field's JSON Schema now refuses mixed and empty ranges, as saves already did, and generated TypeScript (`kiln-types` too) types it `{ max?: number; min?: number } | { max?: string; min?: string } | null`.** Code that writes a mixed-bound value of the regenerated type stops compiling; Swift and Kotlin output is unchanged.
  ([#2548](https://github.com/The-Verscienta/kiln_cms/issues/2548) · [long form](docs/changelog/v1.9.0.md#range-schema-same-kind-bounds))

- **While a backup runs, a request folds into the queued one only when it is the same kind: Back up now into a queued fresh backup, Resume into a queued resume of the same backup. Any other request is refused with "Try again once the queue clears", and the queue is left as it was.**
  ([#2540](https://github.com/The-Verscienta/kiln_cms/issues/2540) · [long form](docs/changelog/v1.9.0.md#backup-fold-like-into-like))

- **An in-app backup with `BACKUP_RCLONE_REMOTE` set and no `rclone` in the
  image now fails (Run log and run error say so) instead of skipping the
  off-site copy; the Backups page's “Where backups go” says so ahead of time.**
  ([#2482](https://github.com/The-Verscienta/kiln_cms/issues/2482))

- **Search engines whose address DNS has verified now get 200% of the `:delivery` limit by default (600 requests a minute per address instead of 300); unverified claims stay at the browser limit, and with `KILN_CRAWLER_VERIFICATION=false` the default stays 100%. Set `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=100` to go back.**
  ([#2587](https://github.com/The-Verscienta/kiln_cms/issues/2587) · [long form](docs/changelog/v1.9.0.md#verified-search-engine-default))

- **Release images no longer ship `priv/static/images/logo-lockup.png` (234 KB),
  which nothing in Kiln referenced. An overlay that linked
  `/images/logo-lockup.png` must ship its own copy.**
  ([#2401](https://github.com/The-Verscienta/kiln_cms/issues/2401))

- **A custom-field range filter (`gt`, `gte`, `lt`, `lte`) no longer matches a record whose stored value is a JSON `null`, array or object.**
  They compare as "no value", as `custom_sort` already read them; before, JSON ordering made an array greater than every number. Only rows whose field was retyped or written off-type are affected.
  ([#2359](https://github.com/The-Verscienta/kiln_cms/issues/2359) · [#2551](https://github.com/The-Verscienta/kiln_cms/pull/2551) · [long form](docs/changelog/v1.9.0.md#custom-field-range-index-changed))

- **The smart 404 guard no longer exempts link-preview fetchers or Slurp from its miss threshold, and exempts a search-engine claim only until DNS proves it false.**
  ([#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591) · [long form](docs/changelog/v1.9.0.md#scanner-guard-exemption-narrowed))

- **`kiln_cms_delivery_client_class_count`'s `class` is now the class charged: `class="empty"` includes search-engine claims proven false by DNS.**
  ([#2591](https://github.com/The-Verscienta/kiln_cms/pull/2591) · [long form](docs/changelog/v1.9.0.md#client-class-is-charged-class))

- **Every update action on a content resource, an overlay's own included, refuses a trashed row with `StaleRecord`; only `:restore`, `:clear_reference_target`, `:convert_custom_field` and `:resnapshot_media` are exempt.**
  ([#2528](https://github.com/The-Verscienta/kiln_cms/pull/2528) · [long form](docs/changelog/v1.9.0.md#trashed-row-update-actions-refuse))

- **Erasing an account also deletes its Web Push subscriptions, its private saved views and the notifications addressed to it, and now always clears its audiences.**
  ([#2527](https://github.com/The-Verscienta/kiln_cms/pull/2527) · [long form](docs/changelog/v1.9.0.md#erasure-deletes-more))

- **Lists of strings and multiple selects now take `has`, `has_all`, `has_none` and `count` in `custom_filter`, and read a bare value stored before the field became a list as a one-item list (`eq` matches it, `not_eq` leaves it out).**
  `has_none` matches a record with no value; `not_eq` does not. An unsupported operator's `400` now lists the supported ones.
  ([#2497](https://github.com/The-Verscienta/kiln_cms/issues/2497) · [long form](docs/changelog/v1.9.0.md#scalar-list-filters-changed))

- **Single sign-on, Sessions, Password policy, Blocked addresses and Bot budgets moved to a new Configure → Sign-in & access section; their addresses are unchanged.**
  ([#2248](https://github.com/The-Verscienta/kiln_cms/issues/2248) · [long form](docs/changelog/v1.9.0.md#console-sign-in-access-section))

- **Backup retention keeps the newest good backup of each component, honours `kiln-<stamp>.keep` recovery points, ages a stamp's dump and media separately, and deletes nothing when it can't read what it needs.**
  `BACKUP_KEEP_DAYS` unchanged; no migration. Local disk use may grow by up to two backups per component, plus pinned ones.
  ([#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219) · [long form](docs/changelog/v1.9.0.md#backup-retention-by-component))

- **The signed-out home page and the default logo ship right-sized images: page image weight drops from about 1,030 KB to about 100 KB (WebP).**
  ([#2165](https://github.com/The-Verscienta/kiln_cms/issues/2165) · [long form](docs/changelog/v1.9.0.md#public-image-weight))

- **The console sidebar and the thin page shell render the built-in logo at its small size too, instead of the 95 KB 278x379 original.**
  A custom `logo_url` is still a plain `<img>`. The `KilnCMSWeb.Layouts.brand_logo` helper is removed; use `Layouts.brand_mark/1`.
  ([#2400](https://github.com/The-Verscienta/kiln_cms/issues/2400) · [long form](docs/changelog/v1.9.0.md#console-brand-mark))

- **CSV exports write a negative number as `-5`, not `'-5`; text starting with `=`, `+`, `-` or `@` is still prefixed.**
  Affects any CSV that passes a negative number to `KilnCMSWeb.CSV`; text is unchanged.
  ([#2376](https://github.com/The-Verscienta/kiln_cms/issues/2376) · [long form](docs/changelog/v1.9.0.md#csv-numbers-unguarded))

- **A console page you lack the role for now lands on a 403 `/access-denied` page naming the role it needs, instead of home with a toast; `access-denied` is now a reserved root slug.**
  ([#2143](https://github.com/The-Verscienta/kiln_cms/issues/2143) · [long form](docs/changelog/v1.9.0.md#access-denied-page))

- **Roles on accounts, team and settings lead with the tier that applies now ("Platform:" / "On this site:"), with
  a line saying when a temporary one ends and what follows; "unconfirmed" is now "Email not confirmed", apart from it.**
  ([#2366](https://github.com/The-Verscienta/kiln_cms/pull/2366) · [long form](docs/changelog/v1.9.0.md#effective-role-display))

- **On `/editor/team`, a custom role's or member's content types and field grants are picked from the site's types
  and fields instead of typed as a list and JSON; "No fields" stores `[]`, and unrecognized stored names are kept.**
  ([#2352](https://github.com/The-Verscienta/kiln_cms/pull/2352) · [long form](docs/changelog/v1.9.0.md#team-scope-pickers))

- **Webhook signing secrets on `/editor/webhooks` are masked to their last four characters until an admin clicks Reveal;
  a revealed secret has Copy and Hide, and a new endpoint's secret starts revealed.**
  ([#2349](https://github.com/The-Verscienta/kiln_cms/pull/2349) · [long form](docs/changelog/v1.9.0.md#webhook-secret-masked))

- **Version compare, restore and the publish-conflict panel show custom fields one by one.**
  Restore now previews before it writes; the conflict stays whole-map.
  ([#2294](https://github.com/The-Verscienta/kiln_cms/issues/2294) · [long form](docs/changelog/v1.9.0.md#custom-field-history))

- **Global search on a large catalogue: the alias and compound legs prefilter on stored
  name lexemes, empty names skip the phrase match, and the tag leg runs once per sweep.**
  ([long form](docs/changelog/v1.9.0.md#search-leg-performance))

- **The release image builds without warnings or notices from Kiln's own steps,
  and with ~60 fewer from third-party deps.**
  ([long form](docs/changelog/v1.9.0.md#quiet-image-build))

- **A publish hands its change-feed event to a per-site relay instead of sending to every local subscriber;
  feed telemetry now fires at hand-off. 10k-subscriber publish p99 1.5 s → 143 ms; p95 still ~4× the 0 leg.**
  ([#2327](https://github.com/The-Verscienta/kiln_cms/pull/2327) · [long form](docs/changelog/v1.9.0.md#feed-relay))

- **The Essentials sidebar now says where Forms, Webhooks, API keys and Trash went and how to list them.**
  ([#2144](https://github.com/The-Verscienta/kiln_cms/issues/2144) · [long form](docs/changelog/v1.9.0.md#essentials-hidden-screens-hint))

- **kilncms.dev `/docs` opens with one "Start here": the wedge guide, Editor/Developer/Operator reading paths, then site search;
  maintainer pages move to a last "Contributing to Kiln" section. chain-fold-order leaves the site; seven guides are retitled.**
  ([#2456](https://github.com/The-Verscienta/kiln_cms/pull/2456) · [long form](docs/changelog/v1.9.0.md#docs-index-role-tracks))

- **New guide "The editorial workflow": draft → review → publish in eight annotated screenshots, with a role table a test checks against the policies.
  It leads the Editor track; two home-page cards link to it; kilncms.dev publishes guide screenshots as media items.**
  ([#2459](https://github.com/The-Verscienta/kiln_cms/pull/2459) · [long form](docs/changelog/v1.9.0.md#editorial-workflow-guide))

### Fixed

- **The public header's brand link keeps the reader's language: `/fr/home` under `/fr/`, which now serves the stock front page in French when the site has no published Home page, instead of `/`, the default language's home.**
  ([#2636](https://github.com/The-Verscienta/kiln_cms/issues/2636) · [long form](docs/changelog/v1.9.0.md#brand-link-keeps-locale))

- **A regional locale with no catalog of its own (`fr-CA` when only `fr` ships) now shows its language's chrome instead of English under `<html lang="fr-CA">`; a missing message falls back `fr-CA` → `fr_CA` → `fr` → English.**
  ([#2637](https://github.com/The-Verscienta/kiln_cms/issues/2637) · [long form](docs/changelog/v1.9.0.md#regional-locale-chrome))

- **A valid `kiln_` API key is accepted when it is not the first `Authorization` value or is sent under a lower- or mixed-case scheme (`bearer kiln_…`); it was answered `401 invalid_token` as if it were a stale JWT. When several values carry a key, the first decides.**
  ([#2633](https://github.com/The-Verscienta/kiln_cms/issues/2633) · [long form](docs/changelog/v1.9.0.md#api-key-any-authorization-value))

- **A failed in-app backup no longer appears twice in Backups History, the second copy a second later: both backup paths write the run's `"stamp"` into `manifest.json` (an additive key), and the importer keys a failure manifest by it.**
  ([#2700](https://github.com/The-Verscienta/kiln_cms/pull/2700) · [long form](docs/changelog/v1.9.0.md#backup-failure-manifest-stamp))

- **A category-scoped `/search?category=<slug>` now stays scoped: the search form, the "did you mean" link and the language links keep the category, and the page says what it searches with a "Search everything" link. kilncms.dev's /docs links to a docs-only search this way.**
  ([#2457](https://github.com/The-Verscienta/kiln_cms/issues/2457) · [long form](docs/changelog/v1.9.0.md#scoped-search-keeps-category))

- **A custom field of a type this release doesn't know (a newer release's, after a rollback, or a removed plugin's) no longer breaks the Fields screen, the editor, saves and delivery: it is hidden, records keep its values, and Fields lists it under "Fields of an unknown type" with a Delete.**
  ([#2670](https://github.com/The-Verscienta/kiln_cms/pull/2670) · [long form](docs/changelog/v1.9.0.md#unknown-field-type-rollback))

- **The `/access-denied` page no longer tells a signed-in account with no role on the site that it is signed in as viewer; it says the account has no role there and offers Sign out.**
  ([#2372](https://github.com/The-Verscienta/kiln_cms/issues/2372) · [long form](docs/changelog/v1.9.0.md#access-denied-no-role))

- **The Essentials sidebar hint now lists the screens it names the way each
  language does: "Forms, Webhooks, API keys and Trash" in English, "… y
  Papelera" in Spanish, "… et Corbeille" in French, instead of a bare comma
  list. A single screen reads "is under Configure".**
  ([#2379](https://github.com/The-Verscienta/kiln_cms/issues/2379))

- **The editor can start a new document of a type with a required custom field
  that has no default; it used to fail with "Couldn't create the draft" and log
  nothing. The field starts blank, the first save asks for it, and the
  refused-create path now logs its error.**
  ([#2651](https://github.com/The-Verscienta/kiln_cms/issues/2651) · [long form](docs/changelog/v1.9.0.md#the-editor-can-start-a-new-document-of-a-type-with-a-required-custom-field-that))

- **The `401` for an unverifiable bearer token now matches the scheme case-insensitively and treats a bare `Bearer` as invalid, on every `Authorization` value; the response is `private, no-store` with `Vary: Authorization`, and `/gql` answers in GraphQL's error shape (`extensions.code: "unauthenticated"`, plus `code: "invalid_token"`) while `/api` keeps `invalid_token`. A lower-case `bearer <jwt>`, which used to be served as anonymous, is now a `401`.**
  ([#2318](https://github.com/The-Verscienta/kiln_cms/issues/2318) · [long form](docs/changelog/v1.9.0.md#bearer-401-hardening))

- **A visitor's session language no longer reaches shared caches: unprefixed public pages, the blog and event indexes, `index.json`, the stock home and form pages and embeds were cached `public` in whichever language the first visitor's session chose.**
  ([#2646](https://github.com/The-Verscienta/kiln_cms/pull/2646) · [long form](docs/changelog/v1.9.0.md#public-delivery-session-locale-leak))

- **`mix kiln.fields.convert` and `mix kiln.media.resnapshot` now also process trashed documents, without firing them, so a document restored after a contract release has the new shape. A trashed record that fails is reported as `(trashed)` and blocks nothing; re-run both right before the contract release.**
  ([#2622](https://github.com/The-Verscienta/kiln_cms/pull/2622) · [long form](docs/changelog/v1.9.0.md#contract-backfills-reach-trash))

- **Field locks (collaborative editing): a field its holder leaves while a takeover waits on their save now stays theirs until that save lands, then goes to the taker, so a third editor can no longer grab it and then lose it, unsaved, when the takeover went through.**
  ([#2619](https://github.com/The-Verscienta/kiln_cms/pull/2619) · [long form](docs/changelog/v1.9.0.md#field-lock-release-mid-flush))

- **Restoring a version from a copy someone has since saved or published is now refused (editor: the conflict banner; API: `409`, or `404` if trashed), instead of reporting success and writing nothing or skipping the claim and alt-text gates.**
  ([#2616](https://github.com/The-Verscienta/kiln_cms/pull/2616) · [long form](docs/changelog/v1.9.0.md#restore-refuses-stale-copy))

- **A save from a tab opened before a version restore no longer silently writes the old text back over it; a restore now increments `lock_version`, so that tab gets the conflict banner.**
  ([#2616](https://github.com/The-Verscienta/kiln_cms/pull/2616) · [long form](docs/changelog/v1.9.0.md#restore-bumps-lock-version))

- **Permanently deleting a trashed page, post, entry or media file that someone else had restored in the meantime no longer hard-deletes the live record, with no `deleted` webhook and no artifact cleanup. `:purge` now takes only a trashed row.**
  The Trash page now says when someone else restored or permanently deleted an item and reloads the list. Code that purges a live record must trash it first.
  ([#2609](https://github.com/The-Verscienta/kiln_cms/pull/2609) · [long form](docs/changelog/v1.9.0.md#purge-refuses-restored-rows))

- **An applicant waiting for approval who hasn't confirmed their address is now told on `/account` to confirm first, by resetting their password or following the confirmation link; a magic-link sign-in never confirmed an address, and the setting that claimed it did is gone.**
  ([#2608](https://github.com/The-Verscienta/kiln_cms/pull/2608) · [long form](docs/changelog/v1.9.0.md#unconfirmed-applicant-confirm-first))

- **A security event type or notification event written by a newer release no longer breaks the security log, its CSV export, account erasure, the notification bell, the inbox or mark-all-read on an older one; the log shows "Unrecognized event (name)".**
  No migration. Columns that will gain values must switch to `KilnCMS.Types.KnownAtom` a release first ([releasing.md](docs/releasing.md#new-values-in-an-atom-column)).
  ([#2606](https://github.com/The-Verscienta/kiln_cms/pull/2606) · [long form](docs/changelog/v1.9.0.md#unknown-atom-values-load))

- **A media edit, a content-type promotion, a portability import, a bulk media action, the delivery-cache flush or the cache's 10k-entry eviction no longer moves a site's `<head>` and menus tokens back, which could answer `304` with an old `<head>` or navigation.**
  An unsaved site's `ETag` now differs per node and per restart until its next settings save: extra `200`s, never a stale `304`.
  ([#2601](https://github.com/The-Verscienta/kiln_cms/pull/2601) · [long form](docs/changelog/v1.9.0.md#generation-tokens-survive-clears))

- **A refused workflow action now says why: "Only an admin …" only to an editor (publish, unpublish, archive: where only admins publish; return: any site), "You can't edit this content type." to an editor scoped away from the type (never for the trash), the plain sentence to everyone else.**
  ([#2600](https://github.com/The-Verscienta/kiln_cms/pull/2600) · [long form](docs/changelog/v1.9.0.md#refusal-wording-names-the-reason))

- **Kiln's own text inside a content page's article (form and sign-up labels and messages, byline and date, the verification widget, an untitled embed's title) now follows the article's `lang`, not the visitor's.**
  On a multilingual site form and sign-up blocks post to `/<locale>/forms/<slug>` and `/<locale>/newsletter/subscribe`, default locale included; select them by class, not `action`.
  ([#2598](https://github.com/The-Verscienta/kiln_cms/pull/2598) · [long form](docs/changelog/v1.9.0.md#block-strings-follow-page-locale))

- **A re-fire or a deploy that changes rendered markup is no longer answered `304` to a client holding the old copy: a fired artifact's `ETag` is now a digest of the body served, and a Kiln-rendered page's names the running build.**
  ([#2583](https://github.com/The-Verscienta/kiln_cms/pull/2583) · [long form](docs/changelog/v1.9.0.md#render-etags))

- **Accepting an invitation raises a lower membership on the site to the invited tier (never lowers one) and the page says which happened; changing a member's tier or removing them retires their pending invitation.**
  ([#2573](https://github.com/The-Verscienta/kiln_cms/pull/2573) · [long form](docs/changelog/v1.9.0.md#invitation-raises-lower-membership))

- **Field locks: an idle or takeover-flush timeout that fires just as it is reset is now ignored. Two narrow races: a keystroke at the idle limit lost the field, and a stale flush timeout granted the next takeover unflushed.**
  ([#2556](https://github.com/The-Verscienta/kiln_cms/pull/2556) · [long form](docs/changelog/v1.9.0.md#field-lock-stale-timers))

- **A form's CSV export keeps values stored under a renamed or removed field's old machine name, in a column headed `<key> (renamed or removed)`; forms never renamed export the same columns as before.**
  ([#2555](https://github.com/The-Verscienta/kiln_cms/pull/2555) · [long form](docs/changelog/v1.9.0.md#form-export-renamed-field-keys))

- **Renaming a form field rewrites its `[field:<old>]` tokens in the autoresponder's subject and body, and a field the enabled autoresponder uses can no longer be deleted until the token is removed.**
  ([#2560](https://github.com/The-Verscienta/kiln_cms/pull/2560) · [long form](docs/changelog/v1.9.0.md#autoresponder-tokens-follow-rename))

- **The range and link editor inputs now carry translatable help lines, and a field type's input part may declare a `help:` string.**
  Range says both bounds are the same kind; link lists the allowed `rel` tokens. A hostile link address over JSON:API HTTP, the Kotlin golden and dialyzer are verified.
  ([#2435](https://github.com/The-Verscienta/kiln_cms/issues/2435) · [long form](docs/changelog/v1.9.0.md#composite-field-part-help))

- **A document in the trash takes no more writes: an editor, API client or job still holding it is refused, so no `updated`, `unpublished` or `archived` follows `deleted`.**
  Open editors keep the unsaved text and say it was trashed; a second trash or restore is refused.
  ([#2528](https://github.com/The-Verscienta/kiln_cms/pull/2528) · [long form](docs/changelog/v1.9.0.md#trashed-row-updates-refused))

- **A webhook delivery whose endpoint was deleted shows its URL marked "(deleted endpoint)" and no Redeliver button, and a stale click says the endpoint was deleted.**
  ([#2524](https://github.com/The-Verscienta/kiln_cms/pull/2524) · [long form](docs/changelog/v1.9.0.md#redeliver-deleted-endpoint))

- **A single scalar custom field sent a list keeps its first item: a single URL field sent two URLs no longer stores them run together.**
  ([#2497](https://github.com/The-Verscienta/kiln_cms/issues/2497) · [long form](docs/changelog/v1.9.0.md#single-field-handed-a-list))

- **The content editor ignores list, gallery and repeating-group edits on a field the editor's field grant leaves read-only.**
  ([#2497](https://github.com/The-Verscienta/kiln_cms/issues/2497) · [long form](docs/changelog/v1.9.0.md#read-only-list-events))

- **Three dead links in the docs now resolve (the `KilnCMS.Keys` link in
  Memberships and Ghost's schema in both comparison pages), and a docs test
  refuses relative `.html` links.**
  ([#2167](https://github.com/The-Verscienta/kiln_cms/issues/2167))

- **The sign-in, register and reset pages now have a header landmark, one `h1`, and `autocomplete` on their email and password boxes.**
  ([#2162](https://github.com/The-Verscienta/kiln_cms/issues/2162) · [long form](docs/changelog/v1.9.0.md#auth-pages-landmarks-autocomplete))

- **The first-run setup page's logo row is now a header landmark, and the invite-only sign-in page is tested for one `h1`, one header and one main.**
  ([#2390](https://github.com/The-Verscienta/kiln_cms/issues/2390) · [long form](docs/changelog/v1.9.0.md#setup-header-invite-only-landmarks))

- **`custom_sort` ranks a stored JSON `null`, array or object as no value (last in either direction), and page 2 of a keyset-paged sort no longer fails on one.**
  ([#2293](https://github.com/The-Verscienta/kiln_cms/issues/2293) · [long form](docs/changelog/v1.9.0.md#custom-sort-json-null-last))

- **Renaming a form field now saves on Enter or Save, keeps a refused name on screen with its error, and shows
  machine names on the canvas; the Entries tab groups old keys under "From a renamed or removed field".**
  ([#2346](https://github.com/The-Verscienta/kiln_cms/pull/2346) · [long form](docs/changelog/v1.9.0.md#form-field-rename))

- **`/forms/<slug>`, the address the form builder shows, now serves the active form as a page in the
  site's layout (it was a 404); the builder and forms list link it. Content at that address still wins.**
  ([#2341](https://github.com/The-Verscienta/kiln_cms/pull/2341) · [long form](docs/changelog/v1.9.0.md#public-form-page))

- **A webhook's Delete is now a labelled button on every endpoint's row (it was an easy-to-miss trash icon),
  and the edit form has Delete webhook too.** The confirm says queued deliveries won't be sent and history is kept.
  ([#2328](https://github.com/The-Verscienta/kiln_cms/pull/2328) · [long form](docs/changelog/v1.9.0.md#webhook-delete-labelled))

- **Editing a nested column block on a freshly opened page no longer crashes the editor.**
  Adding, removing, reordering or editing a column child before the first form change raised
  in `AshPhoenix.Form`; the editor now builds the block list from the form's current values.
  ([long form](docs/changelog/v1.9.0.md#columns-child-fresh-form))

- **Global search's compound leg (`huang qi`, `xiao yao san`) is about 3× cheaper per candidate name: variant
  tsvectors and span tsqueries are built once per statement, not per row.**
  ([#2367](https://github.com/The-Verscienta/kiln_cms/pull/2367) · [long form](docs/changelog/v1.9.0.md#compound-leg-hoist))

- **Phoenix 1.8.16 with absinthe_phoenix 2.0.6: GraphQL subscription pushes still reach
  WebSocket clients after the bump, which silently dropped every push on absinthe_phoenix 2.0.5.**
  ([#2202](https://github.com/The-Verscienta/kiln_cms/pull/2202) · [long form](docs/changelog/v1.9.0.md#phoenix-1-8-16-subscription-pushes))

- **`KILN_ML=1` builds compile EXLA again: `fine` is held at 0.1.x, since EXLA 1.0.0's NIF
  does not build against fine 0.2.0, which lazy_html 0.1.14 had pulled into the lock.**
  ([#2212](https://github.com/The-Verscienta/kiln_cms/pull/2212) · [#2213](https://github.com/The-Verscienta/kiln_cms/pull/2213) · [long form](docs/changelog/v1.9.0.md#exla-fine-pin))

- **The content list's "New" menu (sites with more than three content types) is a real
  button that reports open/closed to assistive tech.**
  ([#2145](https://github.com/The-Verscienta/kiln_cms/issues/2145) · [long form](docs/changelog/v1.9.0.md#new-menu-button))

- **A phrase list (multiple `:string`) holding a character whose UTF-8 contains
  byte 0x85 (`內`, many other CJK characters) saves again: line splitting reads
  Unicode, not bytes, so the character is no longer cut in two and refused.**
  ([#2214](https://github.com/The-Verscienta/kiln_cms/issues/2214))

- **Muted text on public pages and shared form components is now readable: `text-base-content/70`, 4.5:1 or better on every surface.**
  ([#2163](https://github.com/The-Verscienta/kiln_cms/issues/2163) · [long form](docs/changelog/v1.9.0.md#public-muted-text-contrast))

- **Code blocks take keyboard focus and a name ("Code sample", translated), with a visible focus ring, so the arrow keys can scroll a line wider than the column.**
  ([#2467](https://github.com/The-Verscienta/kiln_cms/pull/2467) · [long form](docs/changelog/v1.9.0.md#focusable-code-blocks))

- **Tables in rich text take keyboard focus and a name ("Scrollable table", translated), with a visible focus ring, so the arrow keys can scroll a table wider than the column.**
  ([#2596](https://github.com/The-Verscienta/kiln_cms/pull/2596) · [long form](docs/changelog/v1.9.0.md#scrollable-tables))

### Security

- **A public page a CDN or browser may cache (`cache-control: public`) no longer carries the visitor's CSRF token or anything from their session, and no longer sets a session cookie (#2630).**
  ([#2630](https://github.com/The-Verscienta/kiln_cms/issues/2630) · [long form](docs/changelog/v1.9.0.md#shared-cache-session-free))

- **A connection-string `BACKUP_RCLONE_REMOTE` no longer puts its credentials in `rclone`'s arguments; they go to that `rclone` process as `RCLONE_CONFIG_*` variables (#2690).**
  ([#2690](https://github.com/The-Verscienta/kiln_cms/issues/2690) · [long form](docs/changelog/v1.9.0.md#rclone-remote-argv-credentials))

- **Accepting an invitation over an unconfirmed account now also removes its two-step verification, passkeys, identity-provider links and push devices, and revokes its API keys (#2453).**
  ([#2593](https://github.com/The-Verscienta/kiln_cms/pull/2593) · [long form](docs/changelog/v1.9.0.md#invitation-takeover-credentials))

- **A stranger who registered someone else's address no longer keeps a way in once the owner confirms, resets or signs in by magic link: the confirmation link now asks for the sign-up password, and a reset or magic-link sign-in on an unconfirmed account removes the earlier password, two-step verification, passkeys, keys and sessions. Erasure clears two-step verification too (#2594).**
  ([#2594](https://github.com/The-Verscienta/kiln_cms/issues/2594) · [long form](docs/changelog/v1.9.0.md#pre-hijack-takeover))

- **Sign-in, reset, magic link, registration, newsletter, SSO and passkey answer a known and an unknown address alike; the per-surface matrix is in the threat model.**
  ([#2430](https://github.com/The-Verscienta/kiln_cms/issues/2430) · [long form](docs/changelog/v1.9.0.md#account-enumeration-audit))

- **ecto 3.14.3 fixes EEF-CVE-2026-118391 (unbounded query cache growth), and
  ash_sql 0.8.7 replaces the retired 0.8.4 (query cache returned wrong rows).**
  ([#2204](https://github.com/The-Verscienta/kiln_cms/pull/2204) · [long form](docs/changelog/v1.9.0.md#ecto-query-cache-advisory))

## [1.8.0] - 2026-11-03

Long form: [docs/changelog/v1.8.0.md](docs/changelog/v1.8.0.md) —
the 1.8.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **The upgrade migration rewrites `search_vector` on every content row holding
  Chinese characters, adding their bigrams. Nothing to run, overlays included.**
  ([#2179](https://github.com/The-Verscienta/kiln_cms/pull/2179) · [long form](docs/changelog/v1.8.0.md#han-bigrams-upgrade))

- **Run the re-fire sweep after deploying (`mix kiln.refire_all`); overlays first run
  `mix ash.codegen`. Content tables gain `search_weighted`; old rows keep the old weights.**
  ([#2183](https://github.com/The-Verscienta/kiln_cms/pull/2183) · [long form](docs/changelog/v1.8.0.md#field-role-weights-upgrade))

### Added

- **Chinese is searchable inside longer text: `吴茱萸` finds `本方以吴茱萸为君药`, and a query
  that is exactly a record's Chinese name ranks it first (`:han` leg).**
  ([#2179](https://github.com/The-Verscienta/kiln_cms/pull/2179) · [long form](docs/changelog/v1.8.0.md#han-bigrams))

- **Per-site search synonyms and aliases (`/editor/search-synonyms`): equivalent groups and
  one-way rules, applied by `/api/search` (`also_searched`), `/api/ask`, the new `/mcp`
  `search_content` tool and site search alike.** ([long form](docs/changelog/v1.8.0.md#search-synonyms))

- **Search finds a name written spaced or joined differently from the site:
  `huangqi` finds Huang Qi, `xiao yao san` Xiaoyaosan, `SP 9` SP9.**
  ([long form](docs/changelog/v1.8.0.md#compound-names))

- **Search: `explain=1` on `/api/search` (and `explain: true` on `hybrid/3`/`global/2`)
  reports each hit's leg ranks, raw scores, matched terms and coverage.**
  ([#2177](https://github.com/The-Verscienta/kiln_cms/pull/2177) · [long form](docs/changelog/v1.8.0.md#search-explain))

- **Search: an adversarial ranking fixture gates CI, and golden sets gain the
  classes it uses.** ([long form](docs/changelog/v1.8.0.md#search-ranking-fixture))

### Changed

- **Search: keyword ranking weights a record's text by role (title and names `A`, fields `B`/`C`,
  body `D`) and ranks with `ts_rank_cd` plus a phrase score, so an adjacent phrase wins.**
  ([#2183](https://github.com/The-Verscienta/kiln_cms/pull/2183) · [long form](docs/changelog/v1.8.0.md#field-role-weights))

- **Search returns nothing for a query most of whose words are in no record's text or name;
  a word one edit from a name is a typo, and the fuzzy leg retries corrected. `SEARCH_TERM_GATE=false` reverts.**
  ([long form](docs/changelog/v1.8.0.md#term-evidence-gate))

- **README, home page hero and kilncms.dev `/docs` lead with the wedge: content that has to be
  right, everywhere in seconds, provably. A new guide orders the six delivery and governance docs.**
  ([#2197](https://github.com/The-Verscienta/kiln_cms/pull/2197) · [long form](docs/changelog/v1.8.0.md#wedge-positioning))

- **`/developers` curl examples name the site's own URL instead of `<this-site>`, and the page
  links the committed OpenAPI and GraphQL specs where a production build serves neither.**
  ([#2196](https://github.com/The-Verscienta/kiln_cms/pull/2196) · [long form](docs/changelog/v1.8.0.md#developers-page-real-urls))

### Fixed

- **Search: a section with one or two records no longer ranks them first across a
  `global/2` sweep; ranks are taken over every section's candidates together.**
  ([#2176](https://github.com/The-Verscienta/kiln_cms/pull/2176) · [long form](docs/changelog/v1.8.0.md#global-search-ranks))

- **Search: a deploy no longer stalls searches; probes hold traffic until search is warm, and
  each sweep answers within a budget, flagged `partial`, with per-leg `Server-Timing`.**
  ([#2186](https://github.com/The-Verscienta/kiln_cms/pull/2186) · [long form](docs/changelog/v1.8.0.md#search-warmup-and-budget))

- **A plugin field type no longer breaks page renders in dev or `mix run` (`cannot load "money"`);
  the field-type registry loads at boot. Releases were unaffected.**
  ([#2200](https://github.com/The-Verscienta/kiln_cms/pull/2200) · [long form](docs/changelog/v1.8.0.md#field-type-atoms-at-boot))

### Security

- **phoenix_html 4.4.0, ssl_verify_fun 1.1.9 and jsv 0.26.2 fix three of
  the advisories published 2026-10-30 and 2026-10-31.**
  ([#2174](https://github.com/The-Verscienta/kiln_cms/pull/2174) · [long form](docs/changelog/v1.8.0.md#html-tls-jsv-advisories))

- **ash_authentication 5.0 and ash_authentication_phoenix 3.0 release candidates
  bring assent 0.3.2 (EEF-CVE-2026-117656, Sign in with Apple; Kiln not exposed).**
  ([#2185](https://github.com/The-Verscienta/kiln_cms/pull/2185) · [long form](docs/changelog/v1.8.0.md#ash-authentication-5-assent))

- **ash_authentication 5.0.0-rc.16 fixes EEF-CVE-2026-119215 (TOTP setup) and
  EEF-CVE-2026-118505 (`brute_force_strategy`); Kiln uses neither, so not exposed.**
  ([#2193](https://github.com/The-Verscienta/kiln_cms/pull/2193) · [long form](docs/changelog/v1.8.0.md#ash-authentication-rc16))

## [1.7.0] - 2026-10-29

Long form: [docs/changelog/v1.7.0.md](docs/changelog/v1.7.0.md) —
the 1.7.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Overlays: run `mix ash.codegen` for your content types. Every content table
  gains a nullable `path_alias_derived` column; reads fail until it exists.**
  ([#2118](https://github.com/The-Verscienta/kiln_cms/pull/2118) · [long form](docs/changelog/v1.7.0.md#alias-derivation-overlays))

### Breaking

- **`KILN_PROVENANCE_ENABLED` now defaults to `true`: every fire signs, and `/api/provenance/*`
  answers. Set it to `false` to keep 1.6's behaviour; with no key, nothing is refused.**
  ([#2119](https://github.com/The-Verscienta/kiln_cms/pull/2119) · [long form](docs/changelog/v1.7.0.md#provenance-default-upgrade))

### Added

- **`GET /api/provenance/verify/:type/:slug` says whether a published artifact
  is `verified`, `tampered` or `unsigned`, checked against the manifest stored when it fired.**
  ([#2119](https://github.com/The-Verscienta/kiln_cms/pull/2119) · [long form](docs/changelog/v1.7.0.md#provenance-on-by-default))

- **A plain-text field can keep its paragraph breaks: "Keep paragraph breaks"
  delivers `custom_fields_plain.<name>` with `\n\n` between paragraphs.**
  ([#2110](https://github.com/The-Verscienta/kiln_cms/pull/2110) · [long form](docs/changelog/v1.7.0.md#plain-text-breaks))

- **`mix kiln.export.schema --format swift` writes `Codable` models: a struct per
  type, block and group row, and `Block`/`Document` enums that tolerate unknowns.**
  ([#2105](https://github.com/The-Verscienta/kiln_cms/pull/2105) · [long form](docs/changelog/v1.7.0.md#swift-schema-export))

- **`mix kiln.export.schema --format kotlin` writes kotlinx.serialization models: a data
  class per type, block and group row, and `Block`/`Document` interfaces with `Unknown`.**
  ([#2109](https://github.com/The-Verscienta/kiln_cms/pull/2109) · [long form](docs/changelog/v1.7.0.md#kotlin-schema-export))

- **`examples/swiftui-reader`: a SwiftUI app on generated Swift models and a
  `/api/sync` mirror, with `:group` rows, Portable Text and focal-point crops.**
  ([#2124](https://github.com/The-Verscienta/kiln_cms/pull/2124) · [long form](docs/changelog/v1.7.0.md#swiftui-reader))

- **Sections in the Custom fields panel: a field's `section` files it under a
  collapsible heading; only sections already holding values start open.**
  ([#2116](https://github.com/The-Verscienta/kiln_cms/pull/2116) · [long form](docs/changelog/v1.7.0.md#field-sections))

- **`:select` options can carry labels (`option_labels`): editors see
  "Transforming phlegm" while `transforming_phlegm` stays the stored value.**
  ([#2107](https://github.com/The-Verscienta/kiln_cms/pull/2107) · [long form](docs/changelog/v1.7.0.md#option-labels))

- **A `:string` field can hold a list of phrases: one input per item, pasted
  lines split into items, and a `names_record` list names the record by each.**
  ([#2101](https://github.com/The-Verscienta/kiln_cms/pull/2101) · [long form](docs/changelog/v1.7.0.md#string-lists))

- **A `:select` field can hold several terms, in a tag picker; `allow_custom`
  opens its vocabulary. `mix kiln.fields.convert` moves JSON-string lists in.**
  ([#2099](https://github.com/The-Verscienta/kiln_cms/pull/2099) · [long form](docs/changelog/v1.7.0.md#multiple-select))

- **`:text` custom fields get the TipTap editor (bold, italic, links, lists),
  sanitized on write; `format: :plain` keeps the textarea.**
  ([#2099](https://github.com/The-Verscienta/kiln_cms/pull/2099) · [long form](docs/changelog/v1.7.0.md#rich-text-fields))

- **A rich `:text` custom field can also be delivered as Portable Text (`custom_fields_portable`).**
  ([#2103](https://github.com/The-Verscienta/kiln_cms/pull/2103) · [long form](docs/changelog/v1.7.0.md#rich-text-fields-as-portable-text))

- **Field localization can share tags and related content: `localization: [shared: [:tags, :related]]`
  copies the tag set, and links each related target's same-locale variant along the fallback chain.**
  ([#2131](https://github.com/The-Verscienta/kiln_cms/pull/2131) · [long form](docs/changelog/v1.7.0.md#shared-tags-and-related))

### Changed

- **Shared and fallback block fields work inside `columns`: a nested block is copied,
  filled, refused and shown in the editor by its id, as a top-level block is.**
  ([#2129](https://github.com/The-Verscienta/kiln_cms/pull/2129) · [long form](docs/changelog/v1.7.0.md#field-localization-nested-blocks))

- **Generated Swift and Kotlin models keep Portable Text's text:
  `#/$defs/portable_text_block` now declares `style`, `listItem`, `level`,
  `children` and `markDefs`, all optional, the node still open.**
  ([#2126](https://github.com/The-Verscienta/kiln_cms/pull/2126) · [long form](docs/changelog/v1.7.0.md#portable-text-node-keys))

- **Whether a path alias was derived is recorded when it is written, so a move
  rewrites a stale derived path beneath it instead of mistaking it for a pinned one.**
  ([#2118](https://github.com/The-Verscienta/kiln_cms/pull/2118) · [long form](docs/changelog/v1.7.0.md#alias-derivation-recorded))

- **JSON:API `/by-slug/:slug` and GraphQL `*BySlug` no longer require `locale`:
  left out, the walk starts at the site's default locale, as the delivery API
  did.**
  ([#2115](https://github.com/The-Verscienta/kiln_cms/issues/2115))

- **Moving a section in the content tree reads only its subtree (recursive CTE),
  not the whole type: a 10,000-document move peaks at 27 MB, not 180 MB.**
  ([#2117](https://github.com/The-Verscienta/kiln_cms/issues/2117) · [long form](docs/changelog/v1.7.0.md#moving-a-section-in-the-content-tree-reads-only-its-subtree-recursive-cte-not))

- **A bare `GET /api` redirects (302) to `/developers`, the API summary, instead
  of answering 404; every `/api/*` route is unchanged.**
  ([#2114](https://github.com/The-Verscienta/kiln_cms/issues/2114))

- **The schema export states the media snapshot once, as `$defs.media_snapshot`;
  nullable uses are `anyOf: [$ref, null]`, so generated clients get one type.**
  ([#2106](https://github.com/The-Verscienta/kiln_cms/pull/2106) · [long form](docs/changelog/v1.7.0.md#media-snapshot-def))

- **ash_graphql 1.13.0 defaults an omitted `offset` to `0`, replacing Kiln's
  #1883 workaround and fixing offset-paged relationship lists too.**
  ([#1883](https://github.com/The-Verscienta/kiln_cms/issues/1883) · [long form](docs/changelog/v1.7.0.md#ashgraphql-1130-defaults-an-omitted-offset-to-0-replacing-kilns-1883-workaround))

### Fixed

- **Typing in an inline "Insert block here" filter no longer loses the rest of
  the word when an autosave lands.** ([#2173](https://github.com/The-Verscienta/kiln_cms/pull/2173) · [long form](docs/changelog/v1.7.0.md#inserter-filter-autosave))

- **`mix kiln.update` reads a pin's release tag even when an SDK tag shares its
  commit; v1.6.0 also carries `kiln_plugin-v1.3.0`, and read as untagged.**
  ([#2125](https://github.com/The-Verscienta/kiln_cms/issues/2125))

- **The content editor no longer crashes on a fallback custom field that holds a
  value, and an empty one shows the value it inherits as its placeholder.**
  ([#2130](https://github.com/The-Verscienta/kiln_cms/pull/2130) · [long form](docs/changelog/v1.7.0.md#fallback-custom-field-crash))

- **A block moved in the content editor stays moved: autosave no longer puts it
  back.** ([#2132](https://github.com/The-Verscienta/kiln_cms/issues/2132) · [long form](docs/changelog/v1.7.0.md#reorder-snap-back))

- **A bad `page[limit]` on `/api/json` is a 400 naming the parameter, not a
  500.** ([#2171](https://github.com/The-Verscienta/kiln_cms/pull/2171) · [long form](docs/changelog/v1.7.0.md#page-value-500))

- **`/api/search` reads `?query=` as well as `?q=`; /developers now documents
  `?q=`.** ([#2171](https://github.com/The-Verscienta/kiln_cms/pull/2171) · [long form](docs/changelog/v1.7.0.md#search-query-alias))

## [1.6.0] - 2026-10-28

Long form: [docs/changelog/v1.6.0.md](docs/changelog/v1.6.0.md) —
the 1.6.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **Optional: run `mix kiln.media.resnapshot --apply` once after deploying**
  so stored `:media` field values gain dimensions, focal point and variants;
  fired artifacts converge by themselves.
  ([#2040](https://github.com/The-Verscienta/kiln_cms/pull/2040) · [long form](docs/changelog/v1.6.0.md#media-resnapshot-upgrade))

### Added

- **The governance trail shows what readers saw: each publish and withdrawal
  with its approver, CDN purge, each endpoint's delivery, `?as_of=` and chain.**
  ([#2086](https://github.com/The-Verscienta/kiln_cms/pull/2086) · [long form](docs/changelog/v1.6.0.md#governance-what-readers-saw))

- **Public bylines: a `:reference` field can be the page's schema.org `author`
  or `contributor`, on the fired JSON-LD and Kiln's own pages; `ProfilePage`.**
  ([#2087](https://github.com/The-Verscienta/kiln_cms/pull/2087) · [long form](docs/changelog/v1.6.0.md#bylines))

- **A link-field filter can name the connection it means: `[target]=<id>` beside
  the operators asks whether *that* record has the value.**
  ([#2081](https://github.com/The-Verscienta/kiln_cms/pull/2081) · [long form](docs/changelog/v1.6.0.md#link-filter-target))

- **Private custom fields: a value only the site's editors and admins see; and
  a `:user` field type that names a person on the site, always private.**
  ([#2085](https://github.com/The-Verscienta/kiln_cms/pull/2085) · [long form](docs/changelog/v1.6.0.md#private-fields))

- **A type can fire `LiveBlogPosting`: coverage times plus its published
  updates as `liveBlogUpdate`, newest first and capped.**
  ([#2075](https://github.com/The-Verscienta/kiln_cms/pull/2075) · [long form](docs/changelog/v1.6.0.md#live-blog-posting))

- **A Google News sitemap at `/news-sitemap.xml` for `NewsArticle` types:
  the last 48 hours, at most 1,000 URLs, listed from `robots.txt`.**
  ([#2077](https://github.com/The-Verscienta/kiln_cms/pull/2077) · [long form](docs/changelog/v1.6.0.md#news-sitemap))

- **Headless draft mode: a preview token opens its draft on JSON:API and the fired-artifact read.**
  ([#1887](https://github.com/The-Verscienta/kiln_cms/issues/1887) · [long form](docs/changelog/v1.6.0.md#headless-draft-mode))

- **A public change feed, server side: `KilnCMS.Delivery.Feed` publishes
  `published` / `updated` / `withdrawn` per site over PubSub.**
  ([#2069](https://github.com/The-Verscienta/kiln_cms/pull/2069) · [long form](docs/changelog/v1.6.0.md#change-feed-server))

- **`Kiln.SafeFetch` (`kiln_plugin` 1.3): plugins get a covered, SSRF-safe way to fetch a URL they didn't write.**
  ([#2070](https://github.com/The-Verscienta/kiln_cms/pull/2070) · [long form](docs/changelog/v1.6.0.md#plugin-safe-fetch))

- **`mix kiln.fields.convert` moves JSON-in-text values into a `:group` field.**
  ([#2052](https://github.com/The-Verscienta/kiln_cms/pull/2052) · [long form](docs/changelog/v1.6.0.md#fields-convert))

- **Media in delivered content carries dimensions, MIME type, focal point and variants.**
  ([#2040](https://github.com/The-Verscienta/kiln_cms/pull/2040) · [long form](docs/changelog/v1.6.0.md#media-snapshot-for-apps))

- **A `:text` custom field can also be delivered as plain text.**
  ([#2037](https://github.com/The-Verscienta/kiln_cms/pull/2037) · [long form](docs/changelog/v1.6.0.md#a-text-custom-field-can-also-be-delivered-as-plain-text))

- **`?fields=` trims the fired `json` artifact; a guide to Kiln in a native app.**
  ([#2039](https://github.com/The-Verscienta/kiln_cms/pull/2039) · [long form](docs/changelog/v1.6.0.md#fields-trims-the-fired-json-artifact-a-guide-to-kiln-in-a-native-app))

- **A `:group` custom field holds structured rows: one object, or a list of
  them, keyed by typed sub-fields, with every bad key reported by its path.**
  ([#2036](https://github.com/The-Verscienta/kiln_cms/pull/2036) · [long form](docs/changelog/v1.6.0.md#group-custom-field))

- **Group fields are edited in the fields admin and the content editor: sub-fields under the group, rows added, removed and dragged into order.**
  ([#2053](https://github.com/The-Verscienta/kiln_cms/pull/2053) · [long form](docs/changelog/v1.6.0.md#group-field-editor))

- **`KilnCMS.Firing.refire/3`: a covered way for an overlay to re-fire named records, with their dependents, webhooks and CDN purge.**
  ([#2068](https://github.com/The-Verscienta/kiln_cms/pull/2068) · [long form](docs/changelog/v1.6.0.md#overlay-refire))

### Changed

- **Related content comes back in the order the editor set: JSON:API
  `include=related_<type>s`, GraphQL `related<Type>s` and `related_links`.**
  ([#2061](https://github.com/The-Verscienta/kiln_cms/pull/2061) · [#2064](https://github.com/The-Verscienta/kiln_cms/pull/2064) · [long form](docs/changelog/v1.6.0.md#related-links-ordered))

- **A single media custom field is picked from the library drawer, with a
  thumbnail, instead of a dropdown of filenames.**
  ([#2055](https://github.com/The-Verscienta/kiln_cms/pull/2055) · [long form](docs/changelog/v1.6.0.md#single-media-picker))

- **Fired artifacts are gzipped: their `ETag` is now weak (`W/"…"`) and
  `If-None-Match` is compared weakly.**
  ([#2041](https://github.com/The-Verscienta/kiln_cms/pull/2041) · [long form](docs/changelog/v1.6.0.md#fired-artifacts-are-gzipped))

- **The opt-in ML stack (`KILN_ML=1`) moves to Bumblebee 0.8, Axon 0.9 and
  Nx/EXLA 1.0, clearing Axon's type-checker warnings.**
  ([#2067](https://github.com/The-Verscienta/kiln_cms/pull/2067) · [long form](docs/changelog/v1.6.0.md#ml-stack-nx-1))

### Fixed

- **Similar content (near-duplicates, tag suggestions) reads a page's searchable
  custom fields, not only its blocks; a fields-only page is no longer "empty".**
  ([#2096](https://github.com/The-Verscienta/kiln_cms/pull/2096) · [long form](docs/changelog/v1.6.0.md#similar-content-custom-fields))

- **`mix setup` and `mix assets.build` work on macOS 27.2: tailwind 4.3.3, and
  `mix assets.setup` re-signs the binary ad hoc when its signature is invalid.**
  ([#2082](https://github.com/The-Verscienta/kiln_cms/pull/2082) · [long form](docs/changelog/v1.6.0.md#tailwind-macos-resign))

- **`mix setup`, `mix assets.setup` and `mix deps.compile` work on OTP 29.1.1,
  loading the CI/Docker `httpc` header-limit patch into Mix's VM only.**
  ([#2080](https://github.com/The-Verscienta/kiln_cms/pull/2080) · [long form](docs/changelog/v1.6.0.md#httpc-header-limit-local))

- **A release that rolls back no longer announces or notifies what it undid; post-publish broadcasts, notifications, audit anchors and cache busts wait for the release to commit, and content and type cache busts now always run after the commit.**
  ([#2072](https://github.com/The-Verscienta/kiln_cms/pull/2072) · [long form](docs/changelog/v1.6.0.md#after-commit-effects))

- **`KILN_VECTOR_SEARCH_EXACT` / `KILN_HNSW_EF_SEARCH` no longer crash-loop a
  deployment whose compiled config sets the other `vector_scan:` mode.**
  ([#2060](https://github.com/The-Verscienta/kiln_cms/pull/2060) · [long form](docs/changelog/v1.6.0.md#vector-scan-env-replaces-compiled-mode))

### Security

- **ash 3.37.1 and ash_postgres 2.15.2 fix three tenancy advisories
  (EEF-CVE-2026-115627, -115635, -114214); Kiln was not exposed.**
  ([#2091](https://github.com/The-Verscienta/kiln_cms/pull/2091) · [long form](docs/changelog/v1.6.0.md#ash-tenancy-advisories))

- **bandit 1.14.0, jose 1.11.13 and ash 3.37.2 fix twenty advisories,
  bandit's HTTP/2, HTTP/1 and WebSocket issues among them.**
  ([#2094](https://github.com/The-Verscienta/kiln_cms/pull/2094) · [long form](docs/changelog/v1.6.0.md#bandit-jose-ash-advisories))

- **The release image upgrades its Debian packages and rebuilds them every
  release; v1.6.0-rc.1 had shipped 87 fixable findings from a cached layer.**
  ([#2097](https://github.com/The-Verscienta/kiln_cms/pull/2097) · [long form](docs/changelog/v1.6.0.md#image-debian-packages))

- **bandit 1.14.1 fixes EEF-CVE-2026-116078 (HIGH): HTTP/2 request bodies sent
  as 1-byte DATA frames amplified memory use. Kiln serves HTTP/2, so upgrade.**
  ([#2099](https://github.com/The-Verscienta/kiln_cms/issues/2099), [#2100](https://github.com/The-Verscienta/kiln_cms/issues/2100))

## [1.5.1] - 2026-10-24

Long form: [docs/changelog/v1.5.1.md](docs/changelog/v1.5.1.md) —
the 1.5.1 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Fixed

- **JSON:API and GraphQL serve a `:reference` field's target under its
  current slug and title, not the ones stored when the referrer was saved.**
  ([#2059](https://github.com/The-Verscienta/kiln_cms/pull/2059) · [long form](docs/changelog/v1.5.1.md#fresh-reference-labels))

- **The release image builds again under OTP 29.1.1, whose `:httpc` refused
  GitHub's ~10.7 KB release-redirect headers.**
  ([#2062](https://github.com/The-Verscienta/kiln_cms/pull/2062) · [long form](docs/changelog/v1.5.1.md#httpc-header-limit))

### Security

- **req_llm 1.29.0 (CRITICAL EEF-CVE-2026-107685: WebSocket streaming
  skipped TLS verification) and plug_crypto 2.2.1 (CVE-2026-105963).**
  ([#2057](https://github.com/The-Verscienta/kiln_cms/pull/2057) · [long form](docs/changelog/v1.5.1.md#req-llm-tls-advisory))

## [1.5.0] - 2026-10-18

Long form: [docs/changelog/v1.5.0.md](docs/changelog/v1.5.0.md) —
the 1.5.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **After deploying, run a firing sweep once (`mix kiln.refire_all`, or
  `KilnCMS.Firing.Sweep.run()` over `bin/kiln_cms rpc`), so artifacts fired
  before 1.5 stop naming draft reference targets and join the re-fire graph.**
  ([long form](docs/changelog/v1.5.0.md#refire-after-1-5))

### Added

- **Related content uses the reference picker: search, reorder, remove and
  open, over the record's own type, with the order kept.**
  ([#2030](https://github.com/The-Verscienta/kiln_cms/pull/2030) · [long form](docs/changelog/v1.5.0.md#related-content-uses-the-reference-picker))

- **The fields admin asks for a relationship as one: "A relationship", then both
  sides ("Recipe links to Ingredient"), then how many on each side; the field
  list reads it back from both sides in one sentence.**
  ([#2025](https://github.com/The-Verscienta/kiln_cms/issues/2025))

- **API clients can connect, disconnect and reorder references: GraphQL's
  `add<Type>References`, `remove<Type>References` and `move<Type>Reference`, and
  payload-link routes at `/api/json/content-links`.**
  ([#2014](https://github.com/The-Verscienta/kiln_cms/pull/2014) · [long form](docs/changelog/v1.5.0.md#api-clients-can-connect-disconnect-and-reorder-references-graphqls))

- **Reference fields gain `max_sources`, a limit per target, and
  `on_target_delete`: keep, clear or restrict on a permanent delete.**
  ([#2017](https://github.com/The-Verscienta/kiln_cms/pull/2017) · [long form](docs/changelog/v1.5.0.md#reference-target-limit-and-delete-rule))

- **`mix kiln.gen.join <type>.<field>` graduates a reference field to a typed
  Ash join resource, copies its connections, and retires the field.**
  ([#2016](https://github.com/The-Verscienta/kiln_cms/pull/2016) · [long form](docs/changelog/v1.5.0.md#graduate-a-reference-field-to-a-join-resource))

- **Connections can be added, removed and reordered from the record they point
  at, and each change is saved as an edit of the record that holds it.**
  ([#2018](https://github.com/The-Verscienta/kiln_cms/pull/2018) · [long form](docs/changelog/v1.5.0.md#connections-can-be-added-removed-and-reordered-from-the-record-they-point-at))

- **A reference field can name its other side, and every record it connects
  shows the records connecting to it: "Recipes using this ingredient".**
  ([#2015](https://github.com/The-Verscienta/kiln_cms/pull/2015) · [long form](docs/changelog/v1.5.0.md#a-reference-field-can-name-its-other-side-and-every-record-it-connects-shows))

- **Reads follow reference fields to the records on the other end: GraphQL's
  typed `references` / `referencedBy`, and `?expand=` on `/api/content`.**
  ([#2010](https://github.com/The-Verscienta/kiln_cms/pull/2010) · [long form](docs/changelog/v1.5.0.md#typed-nested-reads-through-references))

- **A reference custom field can carry link fields: typed details on each
  connection, such as the quantity of each ingredient a recipe connects.**
  ([#2011](https://github.com/The-Verscienta/kiln_cms/pull/2011) · [long form](docs/changelog/v1.5.0.md#a-reference-custom-field-can-carry-link-fields-details-on-each-connection))

- **Computed fields can use today's date: `today()`, `years_between`, and "Days
  until a date" and "Age in years" recipes, refreshed once a day.**
  ([#2009](https://github.com/The-Verscienta/kiln_cms/pull/2009) · [long form](docs/changelog/v1.5.0.md#computed-fields-can-use-todays-date-today-yearsbetween-and-days-until-a-date))

- **`custom_filter` filters through relationships: `has`, `has_all`, `has_none`
  and `count` on a reference field, and `has`/`has_all`/`has_none` on `tags`.**
  ([#2003](https://github.com/The-Verscienta/kiln_cms/pull/2003) · [long form](docs/changelog/v1.5.0.md#custom-filter-relationship-operators-has-has-all-has-none-count))

- **A reference custom field can hold a list of references (`multiple: true`),
  with optional `min_items` / `max_items`.**
  ([#2000](https://github.com/The-Verscienta/kiln_cms/pull/2000) · [long form](docs/changelog/v1.5.0.md#a-reference-custom-field-can-hold-a-list-of-references-multiple-true-with))

- **A reference custom field can link to several content types
  (`target_types`).**
  ([#2004](https://github.com/The-Verscienta/kiln_cms/pull/2004) · [long form](docs/changelog/v1.5.0.md#a-reference-custom-field-can-link-to-several-content-types-targettypes))

- **The editor fills a reference custom field from a search picker instead of a
  select of up to 500 records.**
  ([#2002](https://github.com/The-Verscienta/kiln_cms/pull/2002) · [long form](docs/changelog/v1.5.0.md#the-editor-fills-a-reference-custom-field-from-a-search-picker-instead-of-a))

- **The reference picker can create a record and connect it in one step: "Add
  new *Type*" next to the search.**
  ([#2005](https://github.com/The-Verscienta/kiln_cms/pull/2005) · [long form](docs/changelog/v1.5.0.md#the-reference-picker-can-create-a-record-and-connect-it-in-one-step-add-new))

- **Computed fields have a formula builder: pick a recipe and fill in the
  blanks, or write the formula with value and function palettes, and see the
  result live on your own content.**
  ([#2006](https://github.com/The-Verscienta/kiln_cms/pull/2006) · [long form](docs/changelog/v1.5.0.md#computed-field-builder))

- **A computed field can read another computed field: `{{ sum(subtotal,
  shipping) }}` over a computed `subtotal`.**
  ([#2008](https://github.com/The-Verscienta/kiln_cms/pull/2008) · [long form](docs/changelog/v1.5.0.md#a-computed-field-can-read-another-computed-field-sumsubtotal-shipping-over-a))

- **kilncms.dev now publishes Kiln's security policy at `/security`, and a
  security notice per published GitHub advisory at
  `/security-notices/<ghsa-id>`, with a feed.**
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873) · [long form](docs/changelog/v1.5.0.md#kilncmsdev-now-publishes-kilns-security-policy-at-security-and-a-security))

- **Tags, tag groups and categories send webhooks: `tag.created`, `tag.updated`,
  `tag.deleted`, and the same for `tag_group` and `category`.**
  ([#1965](https://github.com/The-Verscienta/kiln_cms/issues/1965) · [long form](docs/changelog/v1.5.0.md#tags-tag-groups-and-categories-send-webhooks-tagcreated-tagupdated-tagdeleted))

- **A release can adopt imported images: `bin/kiln_cms rpc
  'KilnCMS.Release.adopt_image_backend()'`. System → Image backend labels it
  and the Mix task, each with a dry run first.**
  ([#1988](https://github.com/The-Verscienta/kiln_cms/pull/1988) · [long form](docs/changelog/v1.5.0.md#release-adopt-image-backend))

- **A media custom field can hold a gallery: an ordered set of images rather
  than one.**
  ([#1992](https://github.com/The-Verscienta/kiln_cms/pull/1992) · [long form](docs/changelog/v1.5.0.md#media-field-gallery))

- **Every publish and withdrawal is measured end to end: one propagation
  record per transition, `mix kiln.propagation` for p50/p95, and a telemetry
  event to graph it.**
  ([#1927](https://github.com/The-Verscienta/kiln_cms/issues/1927) · [long form](docs/changelog/v1.5.0.md#propagation-records))

### Fixed

- **`mix kiln.gen.join` keeps a reference field's target rules: a graduated
  `on_target_delete: :restrict` still refuses the purge, and `max_sources` still
  caps connections.**
  ([#2024](https://github.com/The-Verscienta/kiln_cms/issues/2024) · [long form](docs/changelog/v1.5.0.md#gen-join-keeps-target-rules))

- **Messages that name a content type no longer put "a" in front of it ("A
  Ingredient can't be deleted…", "Connect a Article…").**
  ([#2023](https://github.com/The-Verscienta/kiln_cms/issues/2023))

- **GraphQL's `referencedBy(inverse:)` lists the connecting records on entries
  of admin-defined types too; it returned an empty list there.**
  ([#2026](https://github.com/The-Verscienta/kiln_cms/pull/2026) · [long form](docs/changelog/v1.5.0.md#graphql-referenced-by-inverse-on-entries))

- **An automation rule for "any content type" no longer fires when a content
  release is published; a rule scoped to `release` still does.**
  ([#1995](https://github.com/The-Verscienta/kiln_cms/issues/1995) · [long form](docs/changelog/v1.5.0.md#automation-any-type-rules-ignore-release-published))

- **Publishing or withdrawing an entry of an archived dynamic type now opens
  a propagation record, and domain events no longer enqueue a federation job
  that only skips.**
  ([#2012](https://github.com/The-Verscienta/kiln_cms/pull/2012) · [long form](docs/changelog/v1.5.0.md#propagation-archived-types-federation-domain-events))

- **A new content type can no longer be named after a built-in webhook event
  namespace (`release`, `task`, `form`, `experiment`, `membership`).**
  ([#1994](https://github.com/The-Verscienta/kiln_cms/issues/1994) · [long form](docs/changelog/v1.5.0.md#reserved-event-namespaces))

- **A variant job no longer takes an image backend's failed or rate-limited
  read for a deleted original.**
  ([#1988](https://github.com/The-Verscienta/kiln_cms/pull/1988) · [long form](docs/changelog/v1.5.0.md#variant-worker-backend-errors))

- **Regenerating variants skips images over the pixel cap instead of
  re-reading each original on every run.**
  ([#1988](https://github.com/The-Verscienta/kiln_cms/pull/1988) · [long form](docs/changelog/v1.5.0.md#regeneration-pixel-cap))

- **GraphQL `published*` queries without `offset` return their page fields
  (`hasNextPage`, `hasPreviousPage`, `pageNumber`, `lastPage`) again: an omitted
  `offset` now means `0`.**
  ([#1883](https://github.com/The-Verscienta/kiln_cms/issues/1883))

- **Renaming a document now re-fires the documents that point at it through a
  `:reference` custom field, and their fired artifacts carry its new slug and
  title.**
  ([#1998](https://github.com/The-Verscienta/kiln_cms/pull/1998) · [long form](docs/changelog/v1.5.0.md#renaming-a-document-now-re-fires-the-documents-that-point-at-it-through-a))

### Security

- **bandit 1.13.0 fixes EEF-CVE-2026-105660 (a client could choose
  `conn.host`/`conn.port` via the HTTP/1 request target) and the HTTP/2 DoS
  EEF-CVE-2026-105659, so the endpoint speaks HTTP/2 again.**
  ([#1991](https://github.com/The-Verscienta/kiln_cms/issues/1991))

- **The `examples/phoenix_showcase` template's lock clears 23 Hex advisories
  (phoenix, phoenix_live_view, bandit, plug, mint, hpax, lazy_html), and CI
  now audits it.**
  ([#1996](https://github.com/The-Verscienta/kiln_cms/pull/1996) · [long form](docs/changelog/v1.5.0.md#phoenix-showcase-advisories))

- **A reference custom field no longer reveals a draft target to a reader who
  cannot read it: the fired artifact, JSON:API and GraphQL leave that item out
  of `custom_fields`.**
  ([#2013](https://github.com/The-Verscienta/kiln_cms/issues/2013) · [long form](docs/changelog/v1.5.0.md#reference-snapshot-hides-unreadable-targets))

## [1.4.0] - 2026-10-14

Long form: [docs/changelog/v1.4.0.md](docs/changelog/v1.4.0.md) —
the 1.4.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Upgrade notes

- **A Dockerfile that runs `mix deps.get` before copying the whole core must
  also copy `config/project_deps_hook.exs`, which `mix.exs` now requires.**
  ([long form](docs/changelog/v1.4.0.md#project-deps-docker))

- **A Dockerfile that runs `mix deps.get` before copying the whole core must
  first `COPY sdk/kiln_plugin sdk/kiln_plugin`; the core's own Dockerfile does.**
  ([long form](docs/changelog/v1.4.0.md#plugin-sdk-docker))

- **A new, empty table — `document_chunk_embeddings` — arrives by migration;
  nothing writes to it until `chunk_long_documents` is turned on.**
  ([long form](docs/changelog/v1.4.0.md#chunked-embeddings-migration))

- **Changing `document_prefix` (as an e5 model swap does) now needs block
  vectors re-embedded too: `mix kiln.embed_all --blocks`, or a firing sweep
  (`mix kiln.refire_all`), as well as documents and tags.**
  ([long form](docs/changelog/v1.4.0.md#block-embedding-prefixes-upgrade))

### Added

- **A retraction webhook (`unpublished`, `archived`, `deleted`) can no longer
  be lost to endpoint auto-disable, and when one exhausts its retries an
  editor is told.** ([#1926](https://github.com/The-Verscienta/kiln_cms/issues/1926) · [long form](docs/changelog/v1.4.0.md#retraction-guarantee))

- **An overlay installs dependency plugins through a git-ignored
  `config/project_deps.exs`, locked in `config/project.lock`, so the core's
  `mix.exs` and `mix.lock` never change.**
  ([#1967](https://github.com/The-Verscienta/kiln_cms/issues/1967) · [long form](docs/changelog/v1.4.0.md#project-deps))

- **Plugins can ship as Hex, git or `path:` dependencies: the plugin contract
  moved, under the same module names, into its own package, `kiln_plugin`.**
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909) · [long form](docs/changelog/v1.4.0.md#plugin-sdk))

- **Advisory checks can ship in a dependency plugin, and `mix kiln.gen.plugin
  --dep` scaffolds one.**
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909) · [long form](docs/changelog/v1.4.0.md#plugin-sdk-advisories))

- **A plugin can contribute an image backend (`Kiln.ImageBackend`) — an
  external service such as Cloudflare Images that takes new image uploads and
  renders their variants and transforms from URLs.**
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955) · [long form](docs/changelog/v1.4.0.md#image-backends))

- **System → Image backend shows the selected backend's state, whether its
  service answers, and how much of the site's library it holds.**
  ([#1980](https://github.com/The-Verscienta/kiln_cms/pull/1980) · [long form](docs/changelog/v1.4.0.md#image-backend-status))

- **`/api/ask` can rerank its merged candidates once instead of each content
  type's, blend the reranker's order with the fused one, and hold a source
  the question names at its fused rank; all off by default.**
  ([#1973](https://github.com/The-Verscienta/kiln_cms/issues/1973) · [long form](docs/changelog/v1.4.0.md#ask-union-rerank))

- **The reranker's compiled shape (`rerank_batch_size`,
  `rerank_sequence_length`) and how it meets the fused order (`rerank_mode`,
  `SEARCH_RERANK_MODE`) are configurable; the defaults are unchanged.**
  ([#1973](https://github.com/The-Verscienta/kiln_cms/issues/1973) · [long form](docs/changelog/v1.4.0.md#rerank-shape-and-mode))

- **Semantic search can see past the first 512 tokens of a long record:
  `chunk_long_documents` embeds the rest of its text in overlapping chunks.**
  ([#1972](https://github.com/The-Verscienta/kiln_cms/issues/1972) · [long form](docs/changelog/v1.4.0.md#chunked-embeddings))

- **Hybrid search's relevance floor can judge the any-term (OR) keyword leg's
  hits too, and the floor is a runtime setting.**
  ([#1970](https://github.com/The-Verscienta/kiln_cms/issues/1970) · [long form](docs/changelog/v1.4.0.md#search-floor-legs))

- **`mix kiln.embed_all --blocks` re-embeds the block index too, so a model,
  pooling or `document_prefix` change reaches every block vector.**
  ([#1971](https://github.com/The-Verscienta/kiln_cms/issues/1971) · [long form](docs/changelog/v1.4.0.md#embed-all-blocks))

- **Search measurement runs can scan vectors at `ef_search` 200 or exactly
  (`KILN_HNSW_EF_SEARCH`, `KILN_VECTOR_SEARCH_EXACT`, `--ef-search`, `--exact`),
  and the search eval reports name the scan mode they ran under.**
  ([#1969](https://github.com/The-Verscienta/kiln_cms/issues/1969) · [long form](docs/changelog/v1.4.0.md#vector-scan-knob))

### Changed

- **The browser suite now drives live co-editing: two peers type into one
  rich-text block and each sees the other's words and caret.**
  ([#1963](https://github.com/The-Verscienta/kiln_cms/pull/1963) · [long form](docs/changelog/v1.4.0.md#collab-e2e))

- **The reranker reads a record's title and its `search_text`, not its title
  and excerpt, so a record with no excerpt is no longer judged on its title
  alone.**
  ([#1973](https://github.com/The-Verscienta/kiln_cms/issues/1973) · [long form](docs/changelog/v1.4.0.md#rerank-search-text))

### Fixed

- **`mix kiln.plugins.doctor`'s image-backend check no longer reports a plugin's
  backend as undeclared when the plugin module isn't loaded yet.**
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

- **Clicking a rich-text block's toolbar button keeps the caret in the text, so
  the first letters typed straight after Bold are no longer lost.**
  ([#1964](https://github.com/The-Verscienta/kiln_cms/pull/1964) · [long form](docs/changelog/v1.4.0.md#toolbar-keeps-editor-focus))

- **Block vectors and the block search query now get `document_prefix` and
  `query_prefix`, so an asymmetric model such as multilingual-e5 embeds the
  block leg to spec.**
  ([#1939](https://github.com/The-Verscienta/kiln_cms/issues/1939) · [long form](docs/changelog/v1.4.0.md#block-embedding-prefixes))

### Security

- **The app server answers HTTP/1.1 only: Bandit's HTTP/2 stack is off until a
  fix for EEF-CVE-2026-105659 (an HTTP/2 flow-control DoS) is released.**
  ([#1985](https://github.com/The-Verscienta/kiln_cms/pull/1985) · [long form](docs/changelog/v1.4.0.md#bandit-http2-off))

- **prosemirror-view 1.42.6 for GHSA-c8x8-7fp4-3x9w: pasting HTML into the
  rich-text editor can no longer run script.**
  ([#1956](https://github.com/The-Verscienta/kiln_cms/pull/1956) · [long form](docs/changelog/v1.4.0.md#prosemirror-view-paste-xss))

- **The rich-text editor moves to TipTap 3 for GHSA-cp6q-959q-f8rh, and keeps
  underlines it used to drop; a co-editing tab still on the old bundle edits
  solo until it reloads.**
  ([#1957](https://github.com/The-Verscienta/kiln_cms/pull/1957) · [long form](docs/changelog/v1.4.0.md#tiptap-3))

## [1.3.0] - 2026-10-12

Long form: [docs/changelog/v1.3.0.md](docs/changelog/v1.3.0.md) —
the 1.3.0 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Added

- **Content webhooks carry `data.affected`: the published documents whose
  fired artifacts embed this one, so a consumer can invalidate those pages
  too instead of waiting out a TTL.**
  ([#1925](https://github.com/The-Verscienta/kiln_cms/issues/1925) · [long form](docs/changelog/v1.3.0.md#webhook-affected))

- **`mix kiln.plugins.doctor` notes a plugin with no `summary/0` (or the
  generator's `TODO:` placeholder) without failing the run.**
  ([#1942](https://github.com/The-Verscienta/kiln_cms/issues/1942))

- **The content list filters on records never reviewed (`?reviewed=never`) and
  on records missing a consent kind (`?consent_missing=<kind>`); the governance
  dashboard links both as work queues.**
  ([#1953](https://github.com/The-Verscienta/kiln_cms/pull/1953) · [long form](docs/changelog/v1.3.0.md#review-work-queues))

### Changed

- **The path forward's wedge minors are 1.3 to 1.8: v1.2.0 shipped the
  toolchain move without them.**
  ([#1945](https://github.com/The-Verscienta/kiln_cms/pull/1945) · [long form](docs/changelog/v1.3.0.md#wedge-minors-renumbered))

- **A `<type>Changed` GraphQL subscription now tells anonymous subscribers
  when a published record is unpublished or archived, as `destroyed`.**
  ([#1925](https://github.com/The-Verscienta/kiln_cms/issues/1925) · [long form](docs/changelog/v1.3.0.md#subscription-retraction))

### Fixed

- **The reranker scores relevance instead of 1.0 for every pair, and a reranker
  model that cannot be loaded no longer stops Kiln from booting.**
  ([#1941](https://github.com/The-Verscienta/kiln_cms/pull/1941) · [long form](docs/changelog/v1.3.0.md#the-reranker-scores-relevance-instead-of-10-for-every-pair-and-a-reranker-model))

## [1.2.1] - 2026-10-11

Long form: [docs/changelog/v1.2.1.md](docs/changelog/v1.2.1.md) —
the 1.2.1 entries as they were written when each change merged.
Every summary line below that was shortened links to its own entry there.

### Fixed

- **A composite custom field no longer blanks every part, and loses what was
  typed, when one part fails validation.**
  ([#1923](https://github.com/The-Verscienta/kiln_cms/pull/1923) · [long form](docs/changelog/v1.2.1.md#composite-field-keeps-typed-parts))

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

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/The-Verscienta/kiln_cms/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/The-Verscienta/kiln_cms/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/The-Verscienta/kiln_cms/compare/v1.2.0...v1.2.1
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
