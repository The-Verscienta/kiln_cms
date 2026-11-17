# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="address-field-type-name-upgrade"></a>

- **The field type name `address` is reserved (#2279).**
  Kiln now ships a built-in `:address` type, and a name can be registered only
  once. An overlay or plugin `Kiln.FieldType` that registers `address` must be
  renamed, in the module's `name/0` and in any stored field definition;
  `mix kiln.plugins.doctor` fails otherwise. A stored definition that already
  used the name is cast by the built-in type. No migration. Rolling back to
  1.8.0 or older needs the `address` fields removed first, like `key_value`
  and `telephone`; see
  [docs/releasing.md](../releasing.md#new-values-in-an-atom-column).


<a id="flexible-item-types-upgrade"></a>

- **Run `mix ash.migrate` (new `field_definitions.flex_of_id`, nullable, and `item_setting`, default `false`; part of #2282). Nothing changes for existing fields; rolling back is safe.**
  Both are additions with a default or null, so the previous release keeps
  working against them. They carry flexible content (a custom
  field holding mixed typed items). A site has none until an admin defines
  one, in the fields admin or from code (see the *Flexible content* entry
  under Added, and `docs/extending-content.md`, "Build flexible content in
  the admin"). After a rollback, such a field reads on the previous release as a
  field of an unknown type (hidden, its items kept; delete it from the
  Fields screen) and its item types as ownerless groups that nothing loads.
  Details in [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md).
  Refs #2282.

<a id="backup-destinations-upgrade"></a>

- **Run `mix ash.migrate` (new table `backup_destinations`; new `backup_runs.destinations` and `backup_runs.offsite_status`). Don't run a backup while a multi-node deployment is part-way through the upgrade. Rolling back to 1.10 is possible, but backups that reached a stored destination then read wrong in History.**
  Two additive migrations: `add_backup_destinations` creates the table
  behind the new **Destinations** tab, and `backup_run_destinations` adds
  `destinations` (an array, default `[]`) and the nullable `offsite_status`
  to `backup_runs`. Existing runs read with no destinations and no off-site
  status. A deployment that only sets `BACKUP_RCLONE_REMOTE` needs nothing
  else: the same `rclone copy` commands, the same failure text, and the same
  `manifest.json` `offsite`.

  **During the upgrade.** The off-site step is now one job per destination.
  A node still on 1.10 that picks up one of these jobs copies to
  `BACKUP_RCLONE_REMOTE` only and moves on to finish. The new finish then
  records every other destination as failed ("not attempted: its off-site
  step never ran"), so the backup reads partly off-site. A 1.10 node that
  writes the run of such a backup is refused (below). Wait until every node
  runs the new release before you start a backup, and pause the in-app
  schedules or the cron entry for the length of the deploy if one could
  fire meanwhile.

  **Rolling back to 1.10.** The new table and columns stay, and 1.10 ignores
  them, so it boots and backs up as before, to `BACKUP_DIR` and
  `BACKUP_RCLONE_REMOTE` only: the stored destinations receive nothing until
  you roll forward again. A run whose files were sent to a stored
  destination carries a `dest:<uuid>` key in its artifacts, which 1.10's
  validation refuses on every Run write (finish, fail, and retention's
  mark-pruned). On 1.10 such a run's files are never marked pruned when
  local retention deletes them, its destination chip reads `dest:<uuid>`
  instead of the destination's name, and a backup whose local files are gone
  and that is only on a stored destination reads "missing" rather than
  "off-site only". Rolling forward
  again shows those runs correctly. This release accepts `dest:` keys and
  stores the new atoms as `KnownAtom`, so the next release can add to them
  without the same limit.
  See [docs/releasing.md](../releasing.md#rolling-back-past-backup-destinations).

<a id="backup-notices-upgrade"></a>

- **Run `mix ash.migrate` (new table `backup_notices`, #2487 and #2931). Nothing to backfill; rolling back is safe.**
  The additive migration `add_backup_notices` creates the table behind the
  backup warnings under Added (retention skipped or stopped, a held backup
  deleted outside the app). It starts empty: the first in-app backup or
  marker sync after the upgrade fills it if there is something to say. A
  release before this one ignores the table. A warning written before a
  rollback is shown again after rolling forward, until the next clean
  in-app backup clears it (retention) or eight days pass (held backup). The
  staging scrub purges the table and reports `backup_notices_purged` in its
  summary
  ([docs/staging-environments.md](../staging-environments.md#the-scrub)).

<a id="erasure-backfill-newsletter-upgrade"></a>

- **About 10 minutes after boot, a job deletes the newsletter subscriptions still linked to accounts erased before this release. No migration; rolling back is safe, and what it deleted stays deleted.**
  Erasure now deletes an account's linked newsletter subscriptions (see
  *Erasure deletes the account's newsletter subscriptions* under Fixed). For
  accounts erased earlier, `KilnCMS.Accounts.ErasureBackfill` does the same:
  it finds every erased account (`anonymized_at` set) that still has a row
  in `newsletter_subscribers` with its `user_id`, and deletes those rows,
  with their segment memberships, on the sites where they are. Each boot
  queues it on the `default` queue, 10 minutes out, deduplicated for a day; it
  is idempotent, so a second run finds nothing. An account whose rows can't be
  deleted is logged at warning and counted under `failed`, and the job ends in
  error so Oban retries it, up to 3 attempts. After the last one, the next
  boot queues a fresh job.
  `config :kiln_cms, :erasure_backfill_on_boot, false` turns the boot enqueue
  off, and `bin/kiln_cms rpc "KilnCMS.Accounts.ErasureBackfill.run()"` runs it
  by hand. Rolling back is safe: the job only deletes rows, and the previous
  release works without them. They are not restored, and they were what the
  erasure should have removed.
  See [docs/newsletter.md](../newsletter.md#accounts-erased-before-this-release).
  ([#2991](https://github.com/The-Verscienta/kiln_cms/issues/2991))

<a id="private-job-args-upgrade"></a>

- **About 10 minutes after boot, and daily at 04:50 UTC, a job drops form submission data and automation payloads from finished jobs. No migration. Drain the `mail` queue before rolling back: a form notification or confirmation queued by this release fails on the previous one and is lost.**
  Form notification and autoresponder jobs now carry the submission's id
  instead of its data (see *Form mail and automation jobs no longer keep
  submission data* under Fixed). `KilnCMS.Jobs.PrivateArgsScrub` drops the
  submitted `data` and the autoresponder's `to` from finished form mail
  jobs, and the `payload` from finished automation jobs, that still hold
  them: rows finished before the upgrade, and jobs killed mid-run that
  `Oban.Lifeline` later discarded. Jobs still waiting to run keep their
  args. It runs on the `default` queue ten minutes after each boot
  (`config :kiln_cms, :private_args_scrub_on_boot, false` turns that off)
  and daily (`KILN_PRIVATE_ARGS_SCRUB_CRON`, default `50 4 * * *`; `false`
  turns it off). It is idempotent. By hand, for instance after restoring a
  backup from before the upgrade:
  `bin/kiln_cms eval 'KilnCMS.Release.scrub_job_args()'`.

  During a rolling deploy, a node of the previous release that picks up a
  form mail job queued by this one fails it, and Oban retries it on the mail
  backoff (five attempts over about 81 minutes); a node of this release
  then sends it, so the mail is delayed, not lost. The boot-time scrub may
  also land on an old node and fail there; that is harmless, as the daily
  run does the same work. **Rolling back** to the previous release is safe
  for the data, but every form mail job this release queued that has not
  run yet fails all its attempts and is discarded: those staff
  notifications and confirmations are never sent. Let the `mail` queue drain
  first, or accept that. See
  [Rolling back past form mail jobs that carry ids](../releasing.md#rolling-back-past-form-mail-jobs-that-carry-ids).
  Refs #2992.

## Breaking

<a id="staging-scrub-refuses-live-node"></a>

- **`KilnCMS.Staging.scrub!/1` refuses to run on a node whose Oban executes jobs, so `bin/kiln_cms rpc 'KilnCMS.Staging.scrub!(…)'` against a serving staging node now raises unless you pass `allow_live?: true`.**
  A serving node's queues could run the clone's copy of production's jobs
  (mail, webhooks, federation deliveries) before the scrub deleted them, so
  scrubbing a fresh clone that way was never safe. The error reads
  "Refusing to scrub from a node whose Oban queues are running." Scrub a new
  clone before it serves, with `mix kiln.staging.scrub` or
  `bin/kiln_cms eval 'KilnCMS.Release.scrub_staging()'` (what
  `scripts/staging.sh` runs). To re-scrub a node that is already a scrubbed
  clone, add `allow_live?: true`: the scrub then pauses every queue on every
  node of the cluster first, and they stay paused until you restart the
  application. A node counts as live in any Oban `testing` mode but
  `:manual`, including `:inline`. No migration; rolling back is safe.
  See [docs/staging-environments.md](../staging-environments.md#running-the-scrub).
  Refs #2721.

<a id="plugin-staging-scrub-refuses-undeclared"></a>

- **`mix kiln.staging.scrub` and `KilnCMS.Release.scrub_staging/0` now refuse to run, changing nothing, while a plugin's or the overlay's Ash domain owns a table that no `staging_scrub/0` entry names.**
  Until now the scrub knew only the core's tables, and an overlay's tables
  reached a staging clone with production's rows in them. Now every table of
  a plugin's `domains/0`, of a domain in `:ash_domains` that is neither the
  core's nor a plugin's, and the AshPaperTrail version table of each of
  them (which counts as a table of its own), must be declared. Content-type
  tables, their version tables and graduated join tables are kept without
  an entry, unless a column looks personal (`email`, `ip`, `phone`,
  `user_agent`, an `inet` column, …). The refusal reads "Refusing to scrub:
  these tables of installed plugins and of the overlay have no
  staging_scrub/0 entry" and lists each plugin, resource and table.

  To fix it, add one entry per listed table to the plugin's
  `staging_scrub/0`: `{:purge, Resource}`, `{:rewrite, Resource, set:
  [attribute: value]}` or `{:keep, Resource, "reason"}`, and require
  `{:kiln_plugin, "~> 1.5"}`. A table listed under `(no plugin)` belongs to a
  domain no plugin claims, and nothing can declare it until you move that
  domain into a plugin's `domains/0`. `mix kiln.plugins.doctor` notes each
  undeclared table (it does not fail on one), and
  `KilnCMS.Staging.PluginScrub.assert_covered!/2` holds a plugin to it in its
  own tests. A site that never clones production into staging is not
  affected. No migration; rolling back is safe. See
  [Plugin tables](../staging-environments.md#plugin-tables) and
  [ADR 0066](../decisions/0066-every-table-reaching-a-staging-clone-is-scrubbed-or-kept-with-a-reason.md).
  Refs #2975.

## Known issues

<a id="referrer-breakdowns-differenced"></a>

- **Two referrer breakdowns of overlapping traffic can be differenced to recover a count both suppressed.** Affects sites with
  referrer attribution on (`KILN_ANALYTICS_REFERRERS`). Each breakdown is protected on its own, but Kiln publishes
  several of the same views: the dashboard's span beside the export's per-day rows, the site-wide chart beside an
  item's bars, the 7-day window beside the 30-day one, and today read twice as it fills. A reader holding two of them
  can subtract one from the other. There is no workaround short of turning referrer attribution off.
  ([#2989](https://github.com/The-Verscienta/kiln_cms/issues/2989))

<a id="automation-payload-plain-in-pending-jobs"></a>

- **An automation event's document snapshot, drafts included, is still in plain text in a pending automation job's row and in Oban's `job:start` / `job:stop` log lines.**
  Affects every site with automation rules. `DispatchWorker` and
  `RuleWorker` jobs carry the event's serialized document, and a reaction
  needs that snapshot, so it can't be replaced by an id. This release drops
  it from the job's row when the job finishes and from Sentry events, and
  its workers read a sealed payload, but it still writes the plain one:
  sealing it in the writers now would make a node of the previous release,
  mid-deploy, fail every automation job. The next release writes it sealed.
  Until then, treat the `info`-level Oban log lines and the `oban_jobs` rows
  of pending automation jobs as holding draft content. The only workaround
  for the log lines is raising `:logger`'s level above `info` in your
  config, which hides every job's lines. See
  [Job args retention](../data-flows.md#job-args-retention).
  ([#2992](https://github.com/The-Verscienta/kiln_cms/issues/2992))

## Added

<a id="flexible-content"></a>

- **A new custom field type, Flexible content: an ordered list of items of different kinds (a hero, a quote), each kind with its own fields and settings, defined in the fields admin and edited as cards in the content editor (#2282).**
  The model and write path came in the *Run `mix ash.migrate`* upgrade note
  above (no new migration here). What this adds:
  - **Admin.** Under `/editor/fields`, **Flexible content** is a field type.
    A flexible field has an **Item types** panel: add, edit, reorder (arrows
    only) and delete item types, each with a label, machine name, help text
    and a per-type maximum. Each item type has **Fields in each item**, with
    a **Setting** checkbox for values that configure the item (stored apart
    from its content) and, to 3 levels deep, nested flexible sub-fields.
    The checkbox is fixed once the field exists. Renaming an item type keeps
    its items. Deleting an item type or a flexible field shows how many stored
    items go with it and recounts on confirm.
  - **Editor.** The field shows its items as cards: **Add item** (appends at
    the end, respects the field's and each type's maximum), drag or move
    up/down, **Duplicate**, **Remove**, collapse, and a collapsed **Settings**
    section. An item whose type was deleted shows as a locked card that only
    **Remove** works on, and saving drops it. This replaces the read-only
    "Edited through the API" note from the first release.
  - **Field sync.** An export carries `"item_types"` (each with its
    `"group_fields"`, nested to the depth cap); `item_setting` is written
    only when `true`. **A file with `item_types` or `item_setting: true` does
    not import on 1.10**; a site with no flexible fields exports the same file
    as before. An import cannot delete an item type that still holds items,
    even with `--allow-data-loss`: it is refused with a message naming
    `purge_items?`.
  - **Retyping.** A field can no longer be changed to or from `flexible`
    (admin, import or code): add a new field and delete the old one.
  - **Purge.** Deleting an item type with `purge_items?: true` removes its
    items in the destroy's own transaction. An item saved between the guard
    and the purge is still removed with the type.
  Guide:
  [Build flexible content in the admin](../extending-content.md#build-flexible-content-in-the-admin);
  record: [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md).
  Not yet: per-item-type grants, search of items, typed GraphQL and client
  export (later PRs of the plan).

<a id="address-field-type"></a>

- **A built-in `:address` custom field type: a postal address stored as one object (country, administrative area, locality, postal code, two address lines), with a country select in the editor (#2279).**
  The country is an ISO 3166-1 alpha-2 code and is required once any other
  part is given; parts are trimmed, single-line and capped, and unknown keys
  are refused. The postal code is upper-cased and given its canonical spacing,
  and its format is checked for US, CA, GB, DE, FR, NL, AU, ES, IT, JP, CH, SE,
  BR and IN; any other country takes free text. No licensed dataset ships: the
  country list is the public ISO assignment and the formats are a small
  hand-written table. Served as generic JSON, never sortable, filterable only
  for "Empty or not"; a `searchable` flag indexes the lines, locality, region
  and postal code. Guide:
  [Address fields](../extending-content.md#address-fields).
  - **Not yet.** Labels and required parts that follow the country,
    administrative-area lists, a schema.org `PostalAddress` in the JSON-LD
    output, and a geocode hand-off to `:geolocation`.




<a id="number-field-options"></a>

- **Number fields can set a step, a prefix and a suffix, and an editor input of Slider. The step, prefix and suffix are new keys in field-sync files, which a release before this one refuses.**
  In the fields admin an Integer or Float field gains **Step**, **Prefix**
  and **Suffix** inputs in the **Validation** fieldset, and its **Editor
  input** group offers **Number box** (the default) or **Slider**, the
  latter only while the field has both a minimum and a maximum. Run
  `mix ash.migrate`: it adds three nullable columns to `field_definitions`
  (`step`, `prefix`, `suffix`), so a rollback reads nothing different.

  All three are editor-only hints. `step` moves the editor's arrows and
  slider and is **not** enforced on save; only `validation.min` and `max`
  bound a value. It must be above 0, a whole number on an integer field, and
  no wider than the span between min and max. `prefix` and `suffix` are up to
  16 characters. A blank slider field shows **Set a value** (stores the
  minimum) rather than a range input, so the slider never fills in a field
  nobody set. Only the core `:integer` and `:float` types read the options;
  they clear on any other type, and a plugin field type never carries them.

  **Field sync.** Exports now carry `"step"`, `"prefix"` and `"suffix"`
  (`null` when unset). Version stays 1, so a 1.10 build refuses such a file
  as unknown keys, as it does for `width`: export from the older build, or
  delete the keys with `jq` first. A file without the keys still imports into
  this release, but missing keys read as `null`, so it clears the options on
  fields that had them (the dry run shows `~`).

  **APIs.** JSON:API field-definition payloads (`?include=field_definitions`)
  gain `step`, `prefix` and `suffix`; the schema export gains `x-kiln-step`,
  `x-kiln-prefix` and `x-kiln-suffix` (absent when unset) and
  `x-kiln-widget: "slider"`. Guide:
  [Show a number as a slider or with a unit](../extending-content.md#show-a-number-as-a-slider-or-with-a-unit).

<a id="graphql-custom-where-groups"></a>

- **GraphQL `customWhere` takes `_or` / `_and` / `_not` groups.**
  A condition in the typed list can now be a group instead of a field
  condition: `_or` and `_and` hold a list of conditions, `_not` holds one.
  They nest and sit beside plain conditions, and they run through the engine
  `customFilter` uses (`CustomFieldQuery`), so the meaning is the same,
  including SQL's `not` (a record lacking the field is kept by `_not`). The
  caps are the ones JSON:API and `customFilter` have: 4 deep, 50 conditions
  in all, with the same error text; the 10-condition cap bounds only the
  top level of the list (a group is one element), so over GraphQL the query's
  complexity cap (200, 5 per condition) is the practical limit on groups,
  well under 50; JSON:API and MCP callers have no pricing and get the full
  50. Kind, operator, private-field and site checks apply inside
  a group as outside one. Each condition at any depth adds 5 to the query's
  complexity.

  The change to the schema is additive for queries: `CustomFieldCondition`
  gains `_or`, `_and` and `_not`, and its `name` is no longer `String!` (a
  group has none). Existing documents and variables stay valid, but a
  condition with neither a name nor a group now passes validation and is
  refused by the read ("every condition needs a name"). A client generated
  from the schema (Apollo Kotlin, Swift, TypeScript codegen) types `name` as
  optional after regenerating, so code that builds the input may need a small
  edit. A second input type behind a second argument would have been strictly
  additive but would leave two arguments for one feature. The same groups
  work in the MCP and JSON:API `custom_where` argument. Guide:
  [headless-graphql-api.md](../headless-graphql-api.md#typed-filters-customwhere).

<a id="field-sync-screen"></a>

- **An admin can import field definitions from the console: Custom fields → Sync definitions from a file uploads a `kiln-field-definitions` file, shows the dry-run diff and the refusals for changes that would drop stored values, and applies it after a confirmation.**
  `--prune` and `--allow-data-loss` are two separate checkboxes, off for every
  new file, each re-running the preview. The apply sends the digest of the plan
  that was shown (`FieldSync.digest/1`, `import_doc(expect_digest:)`) and is
  refused when the site's definitions no longer plan the same changes. A
  successful apply is a `org_setting_changed` security event with the counts.
  See [Import from the console](../field-sync.md#import-from-the-console).

<a id="backup-destinations"></a>

- **In-app backups can go to several destinations: the Backups page has a Destinations tab where a platform admin adds a directory on the server or a named rclone remote, tests it, and turns its retention on or off. A backup that reaches only some of them succeeds as "Partly off-site" and raises the backup alarm.**
  Before this, an in-app backup had one off-site copy, `BACKUP_RCLONE_REMOTE`.
  It still has: the env remote is listed first on the tab, read-only, and a
  destination added there is sent to as well as it, never instead of it.
  Each backup is sent to every enabled destination, one after another, each
  as its own step with its own four attempts. Every file is re-hashed just
  before each destination's copy, as ADR 0043 requires, so a file that
  changed while an earlier destination was being sent to is refused.

  **Partly off-site.** A backup that reached some destinations but not all
  is `Succeeded`, badged **Partly off-site** in History, and the Backups
  page and the home strip say "The last backup reached 1 of 2 off-site
  destinations — NAS failed". It can't be resumed: the next backup tries
  every destination again. A backup that reached none fails, and can be
  resumed, as before. On a resume each stored destination skips the files
  it already holds with the same SHA-256; `BACKUP_RCLONE_REMOTE` copies
  every file again, as it always did. Why a partial run succeeds rather than
  fails is in
  [ADR 0063](../decisions/0063-each-backup-destination-is-its-own-step-and-a-run-that-reaches-only-some-is-partly-off-site.md).

  **Retention on a destination.** A stored destination with **Delete its
  old backups (retention)** ticked (the default) is pruned right after a
  backup reaches it, by the same keep rules as `BACKUP_DIR`. It only ever
  deletes backups this installation recorded sending to that destination,
  so another installation's files in a shared bucket are listed in the run's
  log and left alone. It never runs on `BACKUP_RCLONE_REMOTE`, and it is
  skipped, deleting nothing, when the destination overlaps
  `BACKUP_RCLONE_REMOTE` or another destination. See
  [ADR 0064](../decisions/0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md).

  **Local destinations** need the new `BACKUP_LOCAL_DESTINATION_ROOTS`, a
  comma-separated list of absolute directories a destination may be under.
  Unset, the kind isn't offered. A destination may not be inside, equal to,
  or above `BACKUP_DIR`, `MEDIA_DIR`, `priv/static` or the uploads
  directories, and no component of its path may be a symbolic link.
  **Rclone destinations** name a remote already defined in rclone's
  configuration (checked with `rclone listremotes` on Save) and a path on
  it; no connection string and no credential is stored in the database.
  Where a destination writes can't be changed after it is saved.

  Cron (`scripts/backup.sh`) is unchanged and still copies only to
  `BACKUP_RCLONE_REMOTE`. `manifest.json` gains an additive `destinations`
  list on in-app backups; its `offsite` keeps its meaning. Each destination
  write and Test is in the instance security log
  (`backup_destination_created`, `backup_destination_changed`,
  `backup_destination_deleted`, `backup_destination_tested`). The
  staging scrub deletes every destination (`backup_destinations_purged`).
  A plugin destination's secret fields are encrypted under
  `SECRET_KEY_BASE`: rotate with `PREVIOUS_SECRET_KEY_BASE` and
  `mix kiln.vault.reencrypt`, and re-enter them after restoring the database
  under another key. How to set it up:
  [Send backups to several destinations](../backups.md#send-backups-to-several-destinations).

<a id="backup-destination-plugins"></a>

- **Plugins can add backup destinations: `kiln_plugin` 1.5.0 adds `Kiln.BackupDestination` and `c:Kiln.Plugin.backup_destinations/0`.**
  A destination adapter declares a `kind/0`, a `label/0` and the form fields
  a platform admin fills in (`fields/0`, where a `:secret` field is stored
  vault-encrypted and never shown again), and implements `validate/1`,
  `test/1`, `put/3`, `list/1`, `get/3`, `delete/2` and `describe/1`, each
  handed a `Kiln.BackupDestination.Config` whose `Inspect` hides its
  settings and secrets. Retention runs on it only when its optional
  `supports/0` returns both `:list` and `:delete` (`use
  Kiln.BackupDestination` defaults it to `[]`). Each call runs in a process
  of its own, bounded in time: a raise, an exit or a timeout is that
  destination's failure, never the backup's, and its error text is scrubbed
  of the destination's secrets. `backup_destinations/0` defaults to `[]`,
  so an existing plugin compiles unchanged; one that uses it should require
  `{:kiln_plugin, "~> 1.5"}`. `mix kiln.plugins.list` counts each plugin's
  backup destinations, and `mix kiln.plugins.doctor` checks that each one
  implements the behaviour and has a usable `kind/0` that neither
  `local`, `rclone` nor another module already has. See *Backup
  destinations* in [plugin-extensibility.md](../plugin-extensibility.md).

<a id="plugin-staging-scrub"></a>

- **Plugins declare what the staging scrub does to each table their domains own: `kiln_plugin` 1.5.0 adds `c:Kiln.Plugin.staging_scrub/0`.**
  Each entry names an Ash resource of the plugin's own domains:
  `{:purge, Resource}` deletes every row, `{:rewrite, Resource, set:
  [attribute: value]}` sets each attribute on every row, and
  `{:keep, Resource, "reason"}` keeps the rows. Entries are plain data, and
  `KilnCMS.Staging.PluginScrub.plan!/1` checks every one against the clone
  before the scrub changes anything: a value must cast to the attribute's
  type, and a primary key, an identity's attribute, the tenant attribute, a
  `belongs_to` attribute, a generated column, and a column under a unique
  index (with a non-`nil` value) cannot be rewritten (purge the table
  instead). It also refuses a foreign key with `ON DELETE RESTRICT` or
  `NO ACTION` that would stop a purge part-way. The plugin tables are
  scrubbed first, in one transaction, before any core table, so a
  constraint the checks cannot see (a `CHECK`, a trigger) rolls them back
  with nothing else changed. The printed summary lists each purged or
  rewritten plugin table after the core's counts, as
  `<plugin> plugin, <table>`; `KilnCMS.Staging.Scrub.dispositions/1` includes
  them and `Scrub.plugin_kept/1` lists what is kept and why.
  `mix kiln.plugins.doctor` fails on an unusable declaration; it cannot see
  the database, so unique indexes, generated columns and constraints are
  checked only when the scrub runs. `mix kiln.gen.plugin` writes a
  commented-out example. A dependency plugin owns no tables and is
  unchanged. See *Staging scrub* in
  [plugin-extensibility.md](../plugin-extensibility.md#staging-scrub).
  Refs #2975.

<a id="backup-sub-daily-schedules"></a>

- **Backup schedules can run every 2, 4, 8 or 12 hours. A schedule that runs more often than daily must set its own Keep for (days).**
  On **Backups** → **Schedule** (`/editor/backups/schedules`, platform admins
  only), **How often** now offers **Every 2 hours**, **Every 4 hours**,
  **Every 8 hours** and **Every 12 hours** before **Every day**. Such a
  schedule backs up at **At** and then every N hours around the clock in its
  time zone: 03:00 every 8 hours is 03:00, 11:00 and 19:00. Its card reads
  "Every 8 hours from 03:00 (Europe/Paris)". On a daylight-saving night two
  of its backups can be an hour closer together or further apart.

  **Why Keep for (days) is required.** Every scheduled run is a full set (a
  database dump, and a media archive if the schedule covers media), and
  **Keep the newest** is a minimum, not a cap. Kept for `BACKUP_KEEP_DAYS`
  alone, a two-hourly schedule would keep 12 × 14 = 168 sets of each
  component on the default 14 days. So with a sub-daily **How often**, the
  form marks **Keep for (days)** required ("Required for a schedule that
  runs more often than daily."), and the save is refused without it, "is
  required for a schedule that runs more often than daily" under the field.
  The rule applies when a schedule is created, when it is switched to a
  sub-daily interval, when its keep days are cleared, and on any edit of a
  sub-daily schedule that has none. **Pause**, **Resume** and **Delete**
  always work. A sub-daily schedule stored without keep days (written past
  the form, from a console) keeps firing, its backups kept for
  `BACKUP_KEEP_DAYS`, and its card says "This schedule runs more often than
  daily without Keep for (days), so its backups are kept for
  BACKUP_KEEP_DAYS. Set Keep for (days) to edit it; you can still pause,
  resume or delete it."

  The preview's "Keeps about N backups at a time" now counts in hours: a
  two-hourly schedule keeping 7 days keeps about 85 (7 × 12 + 1). Each
  covered component's alarm threshold follows the schedule as for the
  longer intervals (the interval plus half of it, at least 6 hours), so a
  sub-daily schedule makes the alarm stricter than the default 36 hours:
  8 hours for every 2 hours, 10 for 4, 14 for 8, 18 for 12. A backup still
  running when the next window comes queues that window ("Last window:
  queued behind another backup"), and the window after that joins the
  queued request: never two backups at once, never a pile-up. Mind the disk:
  a sub-daily database schedule and a daily media one usually cost far less
  than backing up media every few hours.

  From a release console, `create_backup_schedule/2` and
  `update_backup_schedule/3` take `interval: :every_2h` (or `:every_4h`,
  `:every_8h`, `:every_12h`) with a `keep_days`; without one, the error is
  on `keep_days`. The previous refusal, "schedules more often than daily
  aren't available yet; choose daily or longer" on `interval`
  (`Schedule.Validations.IntervalAvailable`), is gone, replaced by
  `Schedule.Validations.SubDailyKeepsDays`. `Schedule.Window.interval_hours/1`
  is new.

  No migration. Rolling back to 1.10 is safe: 1.10 fires sub-daily schedules
  and honors their keep days, and its Schedule tab shows them with "Schedules
  more often than daily can't be edited here yet. You can pause, resume or
  delete it." See
  [Back up more often than daily](../backups.md#back-up-more-often-than-daily).
  ([#2219](https://github.com/The-Verscienta/kiln_cms/issues/2219))

<a id="backup-history-held-badge"></a>

- **Backups → History badges each component of a backup that a schedule's keep settings hold: "Kept by a schedule: Database" or "Kept by a schedule: Media".**
  The badge stands for a `kiln-<stamp>.hold` marker in `db/` or `media/`,
  the file that tells `scripts/backup.sh prune` to keep that unit
  ([The hold markers](../backups.md#the-hold-markers)); its tooltip says so.
  Before this, the only way to see what a schedule held was to list the
  directories on the host. The markers come from the same read of this
  server's `BACKUP_DIR` as the **Last good** badges, so no badge shows while
  that read is pending ("checking…"), has timed out, or found a directory it
  couldn't list. The `?run=<id>` link that scrolls History to a run's row is
  now covered by a JavaScript test (`assets/test/reveal_section.test.mjs`).
  ([#2933](https://github.com/The-Verscienta/kiln_cms/issues/2933))

<a id="backup-retention-warnings"></a>

- **Retention that was skipped or stopped part-way now shows on the Backups page and raises Home's red backup strip, locally and on each stored destination, until a clean pass clears it (#2487).**
  Retention fails closed: when it can't read the history, the schedules, a
  directory or a destination's listing, it deletes nothing, and the backup
  still reads **Succeeded**. Until now that was said only in the run's log,
  so backups could pile up until the disk filled. Each place where it
  happened now adds a line in the alarm's red, dated by the backup whose
  prune it was: "Retention was skipped on the backup of 2026-11-16 02:00
  UTC: couldn't read the backup history (…). Nothing was deleted, so local
  backups will build up until this is fixed." (and "Retention stopped
  part-way …", "Retention on NAS was skipped …"), with a **Why retention
  skips** link. A local line clears on the next in-app backup whose
  retention runs cleanly in that directory; a destination's on a clean pass
  there or when retention there is off. A line for a backup directory no
  live node reports, or for a destination that is disabled or deleted, is
  left out. Platform admins only, like the rest of the page. Cron's own
  `backup.sh prune` warnings still show only in the cron log. Four metrics
  are now registered (`kiln_cms_backups_retention_skipped_count`,
  `…_retention_stopped_count`, `…_hold_deleted_outside_count`,
  `…_notice_failed_count`, labeled `scope` or `kind`). Guide:
  [When retention is skipped or stops](../backups.md#when-retention-is-skipped-or-stops);
  record:
  [ADR 0066](../decisions/0066-an-operator-facing-backup-problem-is-a-notice-row-not-a-run-log-line-or-a-security-event.md).

<a id="backup-held-deleted-warning"></a>

- **The Backups page and the Schedule tab warn, for eight days, when a backup a schedule keeps was deleted outside the app, usually by a host `scripts/backup.sh` older than the hold markers (#2931).**
  An older script ignores `kiln-<stamp>.hold` and deletes what a schedule's
  keep settings hold once it passes `BACKUP_KEEP_DAYS`. Each marker sync now
  spots a held backup whose data file is gone (entirely, or leaving only its
  `.sha256`, as the prune of 1.8 and older does) and that the app didn't
  delete, and reports it once: a warning in the server log, the
  `[:kiln_cms, :backups, :hold, :deleted_outside]` event (`%{count: n}`), and
  "On 2026-11-16 03:30 UTC, a backup a schedule keeps was deleted outside the
  app: Database backup of 2026-07-01 03:17 UTC." with what to do. It doesn't
  raise the alarm and isn't on Home. A later detection within the eight days
  joins the same warning. The keep settings in the schedule form now always
  say that host cron's `backup.sh` must be this release's. A unit with only
  its sidecar left no longer gets a `.hold`. Guide:
  [When a backup a schedule keeps is deleted outside the app](../backups.md#when-a-backup-a-schedule-keeps-is-deleted-outside-the-app);
  amends [ADR 0062](../decisions/0062-a-schedules-keep-holds-reach-backup-sh-through-a-third-presence-only-marker.md).

<a id="color-palette-json-schema"></a>

- **A color field can be limited to a palette, and a JSON field can carry a JSON Schema: both are checked when a value changes.**
  Both live in the field's existing `validation` map, so there is no migration, and field-definition export and import carry them.
  - **`validation["palette"]` on a `:color` field** is a list of 1 to 64 hex colors (`#rgb` or `#rrggbb`). Any other color is refused on every write surface that changes the value (editor, JSON:API, GraphQL, MCP, imports), and the editor shows the palette as swatches, plus a **None** choice when the field isn't required. A palette entry and a value are compared after tidying, so `#F80` matches `#ff8800`. A field's default must be in its palette. A color stored before the palette narrowed stays shown and kept until someone changes it.
  - **`validation["json_schema"]` on a `:json` field** is a JSON Schema, draft 2020-12 only (checked with the `jsv` library, now a direct dependency; it was already in the tree through `req_llm`). It is admin input that runs on every write, so it is bounded: at most 16 KB encoded, 16 levels deep and 1,000 values. References must be local (`"$ref": "#/$defs/dose"`); a `$ref` that doesn't start with `#`, and `$id`, `$dynamicRef`, `$recursiveRef` and `$dynamicAnchor`, are refused when the definition is saved, and no remote reference is ever fetched. `format` is an annotation, not asserted. A check runs with a 1-second deadline, so a pathological `pattern` fails the write with a message instead of holding the request. A failure names the offending part, for example *Spec (spec) doesn't match its JSON Schema: /dosage: value 1 is lower than minimum 3* (at most five problems). The value is still held to the existing JSON field limits first. A value already stored, or restored from a version, is not re-judged by a rule set after it; only a changed value is checked.
  - **Set them** in `/editor/fields` (admin only): the **Validation (optional)** group of a color field gains **Palette** (hex colors separated by commas or spaces), and of a JSON field gains **JSON Schema** (JSON text).
  - **Schema export** gains two annotations, `x-kiln-palette` (the normalized hex list) and `x-kiln-json-schema` (the admin's schema, whole). They are annotations, not assertions, because a stored value may predate the rule.
  - **Upgrade:** nothing to run. After rolling back, the previous release ignores a stored palette or schema (any color or JSON passes), and refuses to save a color or JSON field definition that still carries one, because it takes no constraints for those types; remove the key first.

  See [Constrain the values of a field](../extending-content.md#constrain-the-values-of-a-field).

<a id="computed-titles"></a>

- **A content type can build every record's title from its other fields: set a title template such as `{{ field.last_name }}, {{ field.first_name }}` and editors stop typing titles.**
  `TypeDefinition` gains a nullable `title_template` (migration
  `add_title_template`, additive: one `text` column, so rolling back to 1.10
  leaves it unused and titles stay as they were written). A compiled type
  declares it with `use KilnCMS.CMS.Content, title_template: "..."`. The
  template is the computed-field language, so there is one syntax. On a
  dynamic type, admins set it under **Content types** (*Title template
  (optional)*). The rules:

  - The template always wins. On `:create`, `:update` and autosave the title
    is overwritten, and a `title` an API client sends is accepted and ignored
    rather than refused, so clients written before the template keep working.
    The editor shows the Title as read-only, with "Generated from the template
    on save".
  - A template that yields nothing (every field it reads is empty) derives
    nothing: a record keeps the title it has, and a create keeps the one it was
    given (the editor's "Untitled" scaffold).
  - A template may read custom fields and the document scalars other than
    `title` and `slug` (the title is its output, and the slug derives from
    it). It may not read a private field, because a title is public. All
    three are refused when the template is saved, including through a computed
    field that reads `title` or `slug`; for a dynamic type, so is a field the
    type does not define. A result is trimmed and cut to 1,000 characters (the title limit); the
    template itself is at most 500.
  - The slug follows the derived title. The editor's `untitled-…` scaffold
    slug is replaced once the template yields a title. Any other slug, a
    published page's included, never moves when a source field changes.
  - A live document's working copy derives its held title when the draft is
    saved, so the live title does not move until *Publish changes*; promotion
    derives once more from the fields that go live.
  - Existing records: saving a changed template on a dynamic type enqueues a
    re-derive sweep (`KilnCMS.CMS.Workers.TitleRegenerationWorker`, one job
    per 100 records, on the `default` queue). Clearing the template enqueues
    nothing and leaves titles as they are. A compiled type's template changes
    with a deploy, so run `mix kiln.titles.regenerate --type <name>` after it
    (`--org <uuid>` for a site other than the sole one). Each rewrite is a
    normal `:update`, so search, the change feed, webhooks and versions fire;
    a published record is retitled live; a record with a pending working copy
    is skipped and re-derives when it is published; a record already at its
    derived title is not written.
  - Field sync: `title_template` is part of a dynamic type's `definition`. An
    import whose definition leaves the key out leaves the stored template
    unchanged (it does not clear it), so a file from before this release
    cannot wipe templates.

  **Known limits.** Which fields a template reads is checked when the
  template changes, not when a field is later renamed or deleted: a reference
  that no longer resolves reads as empty. The check does not run when a type
  is created (it has no fields yet) or for a compiled type (its fields live in
  the registry), only the syntax and the `title`/`slug` rule do. A computed
  field that reads `title` sees the template's title when the record is saved,
  but is not re-run when a working copy is promoted. Name fields
  (`names_record`) are unrelated: they only add words to search.
  How to set one up:
  [Build record titles from fields](../extending-content.md#build-record-titles-from-fields).

## Changed

<a id="sort-reference-media"></a>

- **`custom_sort` (JSON:API) and `customSort` (GraphQL) now sort a single-valued reference or media field, by its target's current title (a media item's current filename).**
  Before this, both were refused with a `400` (#2354), because the label stored
  in the referrer can lag a rename and an order over targets the caller cannot
  read would reveal where they sit. The key is now read from the target, not
  from the stored label, so a renamed target moves at once. It is `NULL`, which
  sorts last like an unset field, where the caller may not read the target, so
  the order of unreadable targets is never revealed. The target must also be in
  the query's organization, and a preview (shared-draft) grant is not honored:
  such a target sorts as unreadable. An editor's list still shows the stored
  label until the referrer is saved again. A `multiple` reference or media field
  stays refused, now with `custom field "x" (reference) holds a list and is not
  sortable`. Clients that treated the old `400` as the signal can drop it.
  Cost: one primary-key lookup per matching row in each type the field may
  target. Measured at 100,000 referrers: 0.8-1.6 s over the whole table with one
  type, up to 2.7-3.9 s with three, and 10-60 ms once a filter narrows the read
  to 1,000 rows, for an editor and an anonymous reader alike (numbers and
  method in [json-api.md](../json-api.md)). The cost grows linearly with the
  types probed, so a field that would probe more than 8 content types (set by
  `config :kiln_cms, :reference_sort_max_targets`) is refused with a `400`. The
  unresolved-type fallback is not refused as such: it is three types on a
  default build. No index on the source table can serve this order, so on a
  large table narrow the read with a filter. No migration; rolling back only brings the refusal
  back. See [json-api.md](../json-api.md)
  and the amendment in decision 0014.

<a id="list-sort-reference-media"></a>

- **The content list's Sort by → Field menu now offers single-valued reference and media fields.**
  They order by the same key as the API above (the target's current title, or
  a media item's current filename), read as the signed-in editor: a target
  they cannot read sorts with the unset rows, and Load more continues the
  order without repeating or skipping a row. The menu entry reads "Field:
  Mentor by current title (↑)" (or "by current filename"), because the Columns
  cell shows the label stored with the referrer, which lags a rename until
  the referrer is saved again, so the two can disagree without the sort being
  wrong. A list-valued field is still not offered, and a `sort=field:…` URL or
  saved view naming one falls back to the default order. No migration.

<a id="backup-retention-telemetry-scope"></a>

- **`[:kiln_cms, :backups, :retention, :skipped]` and `[…, :stopped]` now also fire for retention on a stored destination, with `scope: :destination` and `destination: "dest:<id>"`; the local events gain `scope: :local` (#2487).**
  Before this they meant local retention only, and a destination's skip or
  stop emitted nothing. A handler or alert that should still count only the
  local directory matches on `scope: :local`. Measurements and the `reason`
  metadata are unchanged. See
  [When retention is skipped or stops](../backups.md#when-retention-is-skipped-or-stops).

<a id="form-mail-reads-stored-submission"></a>

- **Form notifications and confirmations are built from the stored submission when the job runs: a submission deleted or marked spam before then sends nothing, and a confirmation is not sent if its email field was removed or renamed, or the autoresponder switched off, since the submit.**
  The jobs carry ids now (see *Form mail and automation jobs no longer keep
  submission data* under Fixed), so each worker reads the submission back,
  through `FormSubmission`'s new `:for_delivery` read as the form
  pipeline's system actor, and the autoresponder asks
  `KilnCMS.Forms.Autoresponder.eligible?/3` again against the form and its
  fields as they are then. Before, the job carried the data and the
  confirmation address from the moment of the submit and sent them
  whatever had changed. A job normally runs within seconds, so the
  difference shows mostly for mail that is retrying after a failed
  delivery. A job queued by the previous release still sends what it
  carries. See [Side effects](../forms.md#side-effects).
  Refs #2992.

## Fixed

<a id="staging-scrub-personal-data"></a>

- **The staging scrub now removes newsletter subscribers, form submissions, mail suppression lists, federation followers and keys, per-site integrations and every queued job from a production clone, and nothing cloned from production can run before it does.**
  A scrubbed clone still held readers' addresses and form input, and
  production's queued jobs, whose args carry recipients, bodies and outbound
  URLs, could execute on the clone and mail or call out on production's
  behalf. The scrub now:
  - deletes newsletter subscribers and their segment memberships, form
    submissions, the instance and per-site suppression lists, the webhook
    delivery log, federation deliveries, followers and each site's federation
    identity (its signing key), push subscriptions and VAPID keys, per-site
    mail relay, SSO, AI and Meilisearch settings, rate-limit counters,
    idempotency keys, the backup lock and node heartbeats;
  - clears every form's notification address, switches off social accounts
    and drops their credentials (their post history stays), and disables
    every automation rule, removing a `send_email` rule's `to`;
  - deletes `oban_jobs` in every state, first and again last. A canceled job
    keeps its args, so canceling was not enough.

  `mix kiln.staging.scrub` used to start the whole application, Oban queues
  and plugins included, before scrubbing, so a cloned job could run in that
  gap. It now boots with Oban inert (`testing: :manual`) and the backup
  heartbeat off. `scripts/staging.sh up` dumps production with
  `--exclude-table-data=oban_jobs`, so the clone never gets the rows. The
  printed summary now lists every count the scrub returns.

  A test classifies every table in the schema as scrubbed
  (`KilnCMS.Staging.Scrub.dispositions/0`) or kept with a reason, so a new
  table cannot reach a clone unexamined. What a clone still keeps (media
  storage settings, the content-signing key, staff free text in comments and
  tasks, plugin tables) is listed in
  [docs/staging-environments.md](../staging-environments.md#what-the-scrub-keeps).

  If you run the scrub with `KILN_BIN=mix` (the `scripts/staging.sh`
  default), it needs `MIX_ENV=prod`: under any other environment Mix ignores
  `DATABASE_URL`, and in dev the migrate step runs against `kiln_cms_dev`
  (the scrub then refuses that name). This
  was already true; the guide said otherwise. Re-scrub any clone you mean to
  share. No migration. Fixes #2721.

<a id="codeql-embed-origin-hardening"></a>

- **`/embed.js` mounts nothing when `data-kiln-origin` isn't an `http:` or `https:` URL, and it and `@kiln-cms/client` trim trailing slashes without a quadratic regex.**
  Hardening for two CodeQL alerts that the first code-scanning run raised.
  Neither alert is exploitable.
  - **`js/xss-through-dom`, `priv/static/embed.js`.** `data-kiln-origin` became
    part of the iframe's `src`, so a `javascript:` value would have run in the
    host page. The attribute is only read from the `<script>` tag that the host
    page writes, and whoever writes that tag already runs script there. The
    snippet the CMS generates never sets it. The value is now parsed with
    `new URL`, and anything but `http:`/`https:` leaves the tag unmounted.
  - **`js/polynomial-redos`, `clients/js/src/client.ts` (and the same pattern
    in `embed.js`).** `/\/+$/` is quadratic on a long run of `/`. With 100,000
    slashes it took about 4 s in Node. Its input is the integrator's own
    `baseUrl` or attribute. Both now trim in a loop, with the same result.
  ([#2947](https://github.com/The-Verscienta/kiln_cms/pull/2947))

<a id="referrer-suppression-partner-bounds"></a>

- **A referrer breakdown published with `"< n"` and one `"hidden"` category no longer lets a reader recover the suppressed counts exactly; breakdowns that would have done so are now hidden whole.**
  The analytics dashboard and the CSV export both print an item's exact view
  total beside its referrer breakdown, so the categories form one equation. A
  breakdown is published partially (low counts as `"< n"`, plus the largest
  other category as a `"hidden"` partner) only when more than one split fits
  that equation for a reader who knows the rule. That count let the partner be
  `0` when it could not be: it is the largest of the categories that are not
  naturally low, and on a tie it is the first in source order, so a published
  `5` beside it, or a published `0` listed before it, rules `0` out. At the
  default threshold of 5, `direct: 1, search: 1, social: 5, other: 5`
  (12 views) was published as `< 5`, `0`, `< 5`, `hidden`, `5`, and only
  `direct: 1, search: 1` fits that (#2752). The count now models both bounds,
  and breakdowns like this one are published as five `"hidden"` values.

  What you'll see: on low-traffic items and days, some referrer breakdowns that
  used to show a `"< n"` label now show every category as hidden, on the
  dashboard and in the export alike (both use
  `Analytics.suppress_referrer_group/1`). Breakdowns with nothing below the
  threshold, and those of busier items, publish as before. An export file
  written before this release keeps what it published. No configuration or
  migration.

  The all-hidden case is covered by the entry below; two breakdowns read
  together are not, which is listed under Known issues.
  ([#2752](https://github.com/The-Verscienta/kiln_cms/issues/2752))

<a id="referrer-breakdown-all-hidden"></a>

- **A referrer breakdown hidden whole no longer lets a reader who knows the rule recover its counts, taken on its own.**
  Until now, at the default threshold of 5, five views with one from each
  source (direct, internal, search, social, other) was the only 5-view
  breakdown published as five `"hidden"` values. A reader who knew the
  suppression rule and saw the item's exact total of 5 beside an all-hidden
  breakdown could therefore name every count. Now a breakdown of five views
  or fewer, spread over four sources or more, and with every source that
  has any views below the threshold, is also hidden whole. At a total of 5 that adds
  the twenty arrangements of `2, 1, 1, 1, 0`, so each source could be 0, 1
  or 2.

  What you'll see: on the lowest-traffic items and days, a few referrer
  breakdowns that used to show `"< n"` labels now show every category as
  hidden, on the dashboard and in the export alike. Busier items publish as
  before. No configuration or migration; an export file written before this
  release keeps what it published.

  This covers one breakdown read on its own. Two breakdowns of overlapping
  traffic read together are a separate gap, listed under Known issues.
  ([#2981](https://github.com/The-Verscienta/kiln_cms/issues/2981))

<a id="backup-hold-sync-after-change"></a>

- **A backup schedule change made while a marker sync is running now reaches the `.hold` markers right after that sync, not at the next 15-minute slot.**
  Every schedule create, change or delete queues a marker sync so that
  `backup.sh prune` learns the new holds at once. The sync job was unique
  while one was waiting *or running*, so a change committed while a sync ran
  queued nothing, and the running sync might have read the schedules before
  the change. Until the next slot (`KILN_BACKUP_MARKER_SYNC_CRON`, every 15
  minutes by default) or the next in-app backup, cron could delete a backup
  the new settings keep. A running job no longer counts (#2932): the change
  queues one more sync, which waits for the backup lock the running one
  holds and then reads the committed schedules. A sync already waiting still
  absorbs the change, so each backup directory normally has at most one sync
  waiting behind the running one. If an in-app backup holds the lock instead, the sync writes
  nothing and the backup syncs the markers itself when it succeeds; a
  backup that fails leaves them to the next slot. No migration; rolling back
  brings the wait back.
  ([#2932](https://github.com/The-Verscienta/kiln_cms/issues/2932))

<a id="backup-finish-after-interruption"></a>

- **An in-app backup whose finish step was interrupted after it had closed the run now completes, instead of failing with "work state … missing" and leaving the `.good` and `.hold` markers unsynced.**
  The finish step writes the manifest, closes the run, removes
  `.work/<stamp>/` and only then syncs the markers and releases the backup
  lock. A node that stopped in that last gap left a finish whose retry (or
  take-back from the stopped node) found no `state.json`: it logged "Backup
  FAILED: The backup's work state … is missing … nothing more can be done for
  this one", and never synced the markers, so `backup.sh prune` didn't learn of the new backup until the
  next sync. A finish that can't find its state now checks whether it had in
  fact finished: the run reads `Succeeded`, or the manifest is written ok for
  this stamp. If so, it closes a run still `Running` as succeeded (a
  destination it never got to is recorded failed, "not attempted: its
  off-site step never ran"), syncs the markers under the lock, releases the
  lock and logs "Backup complete … (finished after an interruption)". The
  same check runs when the heartbeat takes back a finish with no attempts
  left, and when the lock is released because the finish job ended. If the
  run can't be read, the step is retried; with no retry left the backup is
  recorded as interrupted, as before. Part of the step-chain work in
  [issue 2419](https://github.com/The-Verscienta/kiln_cms/issues/2419); see
  [How an in-app backup runs](../backups.md#how-an-in-app-backup-runs-2218).
  No migration; rolling back brings the failure back.

<a id="backup-retried-step-duplicate-outputs"></a>

- **A backup step run again after it had recorded its work no longer lists its files twice, which made the off-site copy refuse the checksum file and fail the backup.**
  When a step wrote `state.json` and then couldn't hand over to the next step
  (the hand-over failed, or its node stopped right after the write), the
  retry added the same dump, media parts or sidecars to the backup's output
  list a second time. The manifest and the run's artifacts in History listed
  them twice, and the off-site copy refused the sidecar ("the checksum file
  changed after it was written"), failing the backup. A retried step now
  keeps one entry per file, the latest. Tests now cover an interruption at
  every step boundary, both before and after the step's state write, the
  `start` step's wait for a legacy `Backups.Worker` job, a retry that leaves
  the previous good manifest alone, the advisory lock on its own, and the
  heartbeat dropping a backup directory id that is gone
  ([#2543](https://github.com/The-Verscienta/kiln_cms/issues/2543)). Part of
  [issue 2419](https://github.com/The-Verscienta/kiln_cms/issues/2419). No
  migration.

<a id="erasure-deletes-newsletter-subscriptions"></a>

- **Erasure deletes the account's newsletter subscriptions, so the person's address stops receiving newsletters, and the self-service data export lists them.**
  Erasing an account (`:anonymize`, `KilnCMS.Accounts.anonymize_user/2`, or
  rejecting an unconfirmed applicant on a site set to erase) replaced the
  account's email with a tombstone but left its newsletter subscriber rows,
  which hold the real address. A confirmed subscription kept mailing that
  address after the person asked to be forgotten. Erasure now
  (`KilnCMS.Newsletter.forget_member/1`):
  - deletes every subscriber row linked to the account (`user_id`), on every
    site and in any status, with its segment memberships. A newsletter mail
    job already queued to one of them is canceled when it comes to run. If any
    site's delete fails, the whole erasure rolls back and can be retried;
  - keeps a row that was never linked to the account, even at the same
    address. Erasure works on the account, and matching on the address would
    delete a stranger's row wherever an address was reused. A site admin can
    remove such a row on **Newsletter** (`/editor/newsletter`);
  - stops the billing sync from ever linking an erased account to a list
    again, even if a late webhook or the nightly reconcile still finds an
    entitlement for it.

  A linked subscription no longer stops a rejected applicant's account from
  being erased, since the erasure now deletes it.

  The data-subject export (**Export my data** on `/account` and
  `/editor/settings`, `KilnCMS.Accounts.export_user_data/1`) gains
  `newsletter_subscriptions`: one entry per linked row on every site, with
  `org_id`, `email`, `name`, `status`, `confirmed_at`, `unsubscribed_at`,
  `subscribed_at` and the names of its `segments`. The confirm and
  unsubscribe tokens are left out. A site that can't be read is logged as an
  error and left out of the export rather than failing it.

  The subscriber resource's `:for_user` read (`Newsletter.subscribers_for_user`,
  which backs the newsletter card on `/account`) is now the member's own and
  nobody else's. It reads across every site, so it now refuses every caller
  but the member, site and platform admins included. It is not exposed over HTTP;
  the member-facing card is unchanged.

  Accounts erased before this release are handled by a background job; see
  the Upgrade notes entry. No migration. See
  [docs/newsletter.md](../newsletter.md#when-a-member-account-is-erased) and
  [docs/data-flows.md](../data-flows.md#subject-rights-workflows).
  ([#2991](https://github.com/The-Verscienta/kiln_cms/issues/2991))

<a id="form-automation-job-args"></a>

- **Form mail and automation jobs no longer keep submission data after they finish: form notification and autoresponder jobs carry only ids, and automation payloads are dropped from the job's row when it finishes.**
  A job's args are kept in `oban_jobs` for 7 days after it finishes,
  printed by Oban's logger on every run, and attached to a failing job's
  Sentry event. Form notification and autoresponder jobs carried everything
  the visitor submitted, and the confirmation address; automation jobs
  carry the event's serialized document, drafts included.

  - Form notification and autoresponder jobs now carry `form_id`, `org_id`
    and `submission_id`, and the worker reads the submission when it runs
    (see the Changed entry *Form notifications and confirmations are built
    from the stored submission*). The forms system actor is admitted to the
    new `FormSubmission` `:for_delivery` read, a get by the job's id, and
    still cannot list, re-mark or delete a submission
    ([policy matrix](../policy-matrix.md#the-system-actor)).
  - The keys that hold private data (`data` and `to` of a form job queued
    by the previous release, `payload` and `sealed` of an automation job)
    are dropped from the job's row once it finishes: completed, canceled,
    discarded, or failed for the last time (`KilnCMS.Jobs.PrivateArgs`).
    A job with retries left keeps them. A form job queued by the previous
    release is still delivered from what it carries.
  - `KilnCMS.SentryFilter` drops those keys from a Sentry event's
    `extra.args`, and the variables of every stack frame, for these four
    workers.
  - `KilnCMS.Jobs.PrivateArgsScrub` drops them from finished rows that
    still hold them; see the Upgrade notes entry.
  - A form mail job that carries neither the ids nor the data (a previous
    release's job whose data was dropped after it sent, then rescued by
    Lifeline) is canceled with "form submission no longer in the job"
    instead of crashing.

  Not covered yet: this release still writes automation payloads in plain
  text, so they are in pending job rows and Oban's log lines until the next
  release seals them (see Known issues). A `form.submitted` webhook keeps
  the submission in its delivery row for 30 days
  ([#2994](https://github.com/The-Verscienta/kiln_cms/issues/2994)), and
  workflow and task mail jobs keep the recipient's address
  ([#3019](https://github.com/The-Verscienta/kiln_cms/issues/3019)). No
  migration. See [Job args retention](../data-flows.md#job-args-retention).
  Refs #2992.

## Security

<a id="backup-state-json-remote"></a>

- **An in-app backup's `.work/<stamp>/state.json` no longer holds the raw `BACKUP_RCLONE_REMOTE`, which for a connection-string remote included its credentials.**
  The off-site step wrote the remote, as configured, into the backup's
  work state after a successful copy. The work directory is removed when a
  backup succeeds, but a backup that failed after its off-site step kept it
  on disk for Resume, readable by anyone who can read `BACKUP_DIR`. It now
  holds only the redacted label (`key=value` credentials replaced with
  `***`). A `state.json` written by 1.10 or earlier keeps its value until
  that backup is resumed or its `.work/<stamp>/` directory is deleted.
