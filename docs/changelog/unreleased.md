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

<a id="resumable-backup-uploads-upgrade"></a>

- **Run `mix ash.migrate` (new table `backup_uploads`, part of #2223). No environment variable to set; rolling back is safe.**
  The additive migration `add_backup_uploads` creates the table in which an
  in-app backup records the uploads a resumable destination adapter has
  under way (see *Backup uploads can resume* under Added). It has no foreign
  key and starts empty, and stays empty until an S3 destination, or a
  plugin's destination whose adapter declares `:resume`, is used. A
  release before this one ignores the table, so rolling back is safe; an
  upload left open across the rollback is resumed or swept after rolling
  forward. The staging scrub purges the table and reports
  `backup_uploads_purged` in its summary
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

<a id="erasure-backfill-memberships-upgrade"></a>

- **The boot-time erasure backfill now also demotes the site memberships of accounts erased before this release. No migration; rolling back is safe.**
  Erasure now strips an account's site memberships of every grant (see
  *Erasure demotes the account's site memberships* under Fixed). For
  accounts erased earlier, the same job that deletes their newsletter rows,
  `KilnCMS.Accounts.ErasureBackfill`, now first finds every membership of an
  erased account that still grants something (a tier above `:viewer`, a
  temporary tier, or an audience) and demotes it the way erasure does: tier
  `:viewer`, no temporary tier, no audiences. The rows stay. The job is the
  one queued on each boot for the newsletter step above
  (`:erasure_backfill_on_boot`, default on), and its
  result map gains `memberships`, the number of rows demoted:
  `%{memberships: 4, newsletter_accounts: 0, newsletter_subscribers: 0, failed: 0}`.
  An account whose memberships can't be demoted is logged at warning
  (`erasure backfill could not demote the memberships of <id>`) and counted
  under `failed`, and the job retries as for the newsletter step. Until the
  job has run, those rows already decide nothing: an erased account has no
  tier and no audiences anywhere and is on no roster, whatever its rows hold.
  Rolling back is safe: the previous release works with demoted rows, and
  what it demoted stays demoted. See
  [docs/newsletter.md](../newsletter.md#accounts-erased-before-this-release).
  ([#2774](https://github.com/The-Verscienta/kiln_cms/issues/2774))

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

<a id="backup-step-files-fenced-upgrade"></a>

- **In-app backups now name their temporary files `<name>.<job>-<attempt>.partial`. No migration; update the host's `scripts/backup.sh` in the same rollout. Rolling back is safe.**
  An in-app backup step writes each file under a temporary name tagged with
  its Oban job id and attempt, for example
  `db/kiln-db-20261117-031700.dump.48211-2.partial` (see *A backup step
  that outlives its Cancel can no longer replace the backup's files* under
  Fixed). `backup.sh` keeps writing `<name>.partial`, and this release's
  copy of the script recognizes both names in `prune` and `verify`. Copy it
  to every host that runs it, in the same rollout as the app. (`restore.sh`
  already refused a set with either name beside it; only its comments
  changed.) Operators will also see trash
  directories, `db/.kiln-trash/`, `media/.kiln-trash/` and
  `.work/.trash/`. They are normally empty; if you copy `BACKUP_DIR` with
  `rclone sync`, exclude `**/.kiln-trash/**` as well as `.work/**`.

  While nodes or scripts of an older release are still running beside this
  one, an in-app backup stays safe, but the older code does not parse a
  tagged name:

  - an older node's retention and importer don't count it as in flight, and
    its start step removes one older than an hour as an unrecognized
    `.partial`. A backup being written is still protected from retention by
    its `.work/<stamp>/` directory;
  - an older `backup.sh prune` neither counts nor removes it;
  - History on an older node can show a media set as complete while one of
    its parts is being rebuilt under a tagged name (display only);
  - an older node that plans a backup's media removes the tagged file lists
    of an earlier plan, which nothing needs once its own `plan.json` is
    written;
  - after a rollback, an older node reads a `plan.json` that names tagged
    lists, and uses them like any other.

  See
  [Temporary files and the trash directories](../backups.md#temporary-files-and-the-trash-directories).
  ([#2818](https://github.com/The-Verscienta/kiln_cms/issues/2818),
  [#2819](https://github.com/The-Verscienta/kiln_cms/issues/2819))

<a id="workflow-task-mail-ids-upgrade"></a>

- **Workflow and task mail jobs now carry ids. No migration. Drain the `mail` queue before rolling back: those queued by this release fail eight times on the previous one and are discarded. Upgrading straight from 1.9.x, old-shape mail still waiting is not sent.**
  Review requests, published and returned-to-draft mail, comment and
  mention mail, task assignments and task digests now carry the recipient's,
  the content's, the actor's and the comment's or task's ids, and the worker
  reads the rest when it runs (see the Fixed entry *Workflow and task mail
  queued before an erasure is no longer sent*).

  During a rolling deploy, a node of the previous release that picks up a
  job of the new shape fails it, on purpose: the new args have no `to`,
  `title` or task `kind`, so the old code cannot send it anywhere. Oban
  retries it on the mail backoff (eight attempts, the last about 15 hours 21
  minutes after the first) until a node of this release delivers it. A job
  queued by an old node is delivered by a new one, but only to an account
  that existed when the job was queued and still holds its address, and
  only if it passes its event's rule and the suppression lists (see the
  Fixed entry *Workflow and task mail re-checks each event's own rule when
  it sends*). A task
  digest may go out twice across the deploy: the old-shape and new-shape
  digests for one person have different args, so the 20-hour uniqueness
  does not merge them. That takes a digest run that failed part-way and
  was retried on the other release.

  **Rolling back** is safe for the data, but every workflow or task mail job
  this release queued that has not run yet fails all eight attempts and is
  discarded. Each failure reaches Sentry (ids only), and the discarded jobs
  show as delivery failures on `/editor/mail` under the domain "unknown". Let
  the `mail` queue drain first.

  **Skipping a release:** v1.10.0's migration
  `20261113071933_require_second_factor` gave every existing account the
  migration's time as `users.inserted_at`. On an upgrade straight from
  1.9.x, an old-shape job still waiting was queued before that time, so it
  finds its recipient created after the job and sends nothing: mail lost,
  not misdelivered. Drain the `mail` queue first if those mails matter. See
  [Rolling back past workflow and task mail jobs that carry ids](../releasing.md#rolling-back-past-workflow-and-task-mail-jobs-that-carry-ids).
  ([#3019](https://github.com/The-Verscienta/kiln_cms/issues/3019))

<a id="account-mail-names-account-upgrade"></a>

- **Account mail jobs now record the account they are for. No migration, and nothing to drain: during a rolling deploy old nodes send without the new check, and rolling back is safe.**
  Account mail (`KilnCMS.Mail.DeliveryWorker`) gains a `"user_id"` key in
  its args, and keeps the address and the sealed message it carried before,
  so both releases can send it (see the Fixed entry *Account mail queued
  before an erasure is no longer sent to the erased person*).

  - **During a rolling deploy**, a node of the previous release sends a job
    of the new shape without checking the account, as it sent all account
    mail before, and queues jobs with no `"user_id"`, which a new node sends
    unchecked too. So until the last old node stops, an erasure can miss
    account mail: a job an old node runs after the erasure, or one it queues
    from a request that read the address before the erasure committed, can
    still reach the old address.
  - **A job the erasure withheld** has no message left. A node of the
    previous release that picks one up cancels it with "message no longer
    available: the job carries no subject or body". Nothing is delivered;
    it is listed as a delivery failure on `/editor/mail` under the domain
    "unknown" until the Pruner deletes the row.
  - **Rolling back** is safe: new-shape jobs still queued are sent by the
    previous release without the check, and withheld ones are canceled as
    above. The `mail` queue needs no draining.

  See
  [Account mail that names its account](../releasing.md#account-mail-that-names-its-account).
  ([#3035](https://github.com/The-Verscienta/kiln_cms/issues/3035))

<a id="erasure-backfill-2514-steps-upgrade"></a>

- **The boot-time erasure backfill now also clears what accounts erased before #2514 kept: their audiences, push subscriptions, private saved views and notifications. No migration; rolling back is safe.**
  Since #2514, erasure clears the audiences on the account's own row
  (`users.audiences`) in a statement of its own, and deletes its Web Push
  subscriptions, its private saved views and the notifications addressed to
  it. An account erased before then could still hold all four.
  `KilnCMS.Accounts.ErasureBackfill`, the job each boot queues
  (`:erasure_backfill_on_boot`, default on), now finishes those steps for
  every erased account, after the membership and newsletter steps: it clears
  the audiences, deletes the push subscriptions, and deletes the private
  saved views and the notifications on the sites where the account has them.
  Shared saved views are the team's and stay. Its result map gains
  `audiences` (accounts cleared), `push_subscriptions`, `saved_views` and
  `notifications` (rows deleted):
  `%{memberships: 0, newsletter_accounts: 0, newsletter_subscribers: 0, audiences: 1, push_subscriptions: 2, saved_views: 5, notifications: 40, failed: 0}`.
  A step that fails is logged at warning and counted under `failed`, and the
  job retries as before; a second run finds nothing. Rolling back is safe:
  the job only deletes rows and clears a column no access decision reads,
  and the previous release works without them. What it removed is not
  restored. See
  [docs/newsletter.md](../newsletter.md#accounts-erased-before-this-release).
  ([#3010](https://github.com/The-Verscienta/kiln_cms/issues/3010))

<a id="backup-pg-tools-connection-upgrade"></a>

- **In-app backups and demo resets now require TLS whenever the app does, refuse a `key=value` database URL that carries a password, and give up after `BACKUP_LOCK_WAIT_SECONDS` (default 600) waiting for a table lock. Check `BACKUP_DATABASE_URL` and the cron line before upgrading. No migration; rolling back is safe.**
  What can start failing, and what to do:

  - **TLS (#2830).** With `DATABASE_SSL` on (the default), `pg_dump` and
    `psql` now get `PGSSLMODE=require`, or `verify-full` with
    `DATABASE_SSL_CACERTFILE` as `PGSSLROOTCERT` when that is set, instead
    of libpq's `prefer`. A `BACKUP_DATABASE_URL` that points at another
    server without TLS, or (with a CA file) at a host name the certificate
    doesn't list, now fails the backup: add `?sslmode=…` to that URL (an
    explicit `sslmode` wins). Unix sockets are unaffected. A
    `DATABASE_SSL_CACERTFILE` holding only an intermediate CA, which the
    app's own connection accepts, fails the backup: libpq needs the root,
    so add it to the file.
  - **`key=value` strings (#2831).** `BACKUP_DATABASE_URL`, `DATABASE_URL`
    (when the backup uses it), and the scripts' `DATABASE_URL`,
    `RESTORE_DATABASE_URL`, `PROD_DATABASE_URL` and `STAGING_DATABASE_URL`
    are refused, before any tool runs, when they are not a `postgres://`
    URL and carry a `password` or `sslpassword` keyword or a `://`. Rewrite
    them as `postgres://user:password@host/db` (or
    `postgres://user:password@/db?host=/socket/dir`). A passwordless one
    (`host=/run/postgresql dbname=kiln_prod`) still works.
  - **Lock waits (#2844).** `pg_dump` now gives up after
    `BACKUP_LOCK_WAIT_SECONDS` (default 600, range 1 to 3600) waiting for
    each table lock. If your backups overlap long migrations or
    maintenance, raise it, in the app's environment and on the cron line.
  - **`?ssl=false` (#2833).** In the URL the backup tools read, it now
    becomes `sslmode=disable` (how the app itself connects) instead of
    failing with `invalid URI query parameter`.
  - **Cron.** The app's `DATABASE_SSL` never reaches `scripts/backup.sh`,
    and the script derives no TLS setting of its own: put `sslmode=require`
    (or `verify-full` with `sslrootcert=`) in the `DATABASE_URL` on the
    cron line.

  Copy the new `scripts/backup.sh`, `restore.sh` and `staging.sh` to every
  host that runs them. Rolling back the pin restores the old behavior;
  nothing is stored. See
  [How the backup tools choose TLS](../backups.md#how-the-backup-tools-choose-tls-2830),
  [Which database URL the backup tools accept](../backups.md#which-database-url-the-backup-tools-accept-2719)
  and
  [When pg_dump waits for a table lock](../backups.md#when-pg_dump-waits-for-a-table-lock-2844).
  ([#2830](https://github.com/The-Verscienta/kiln_cms/issues/2830),
  [#2831](https://github.com/The-Verscienta/kiln_cms/issues/2831),
  [#2833](https://github.com/The-Verscienta/kiln_cms/issues/2833),
  [#2844](https://github.com/The-Verscienta/kiln_cms/issues/2844))

<a id="backup-script-hardening-upgrade"></a>

- **Copy the new `scripts/backup.sh` and `scripts/restore.sh` to every host that runs them. With `RESTORE_REQUIRE_CHECKSUM=1`, `restore.sh db` and `drill` now refuse a dump with no `kiln-db-<stamp>.sha256` beside it. No migration; rolling back is safe.**
  Three fixes in this release live in the scripts, not the app, so they
  reach a host only when its copies are replaced: unique manifest
  temporary names and their cleanup in `backup.sh prune` (#2832), a
  `pg_dump`, `tar` or `rclone` that stops with the script (#2847), and the
  checksum check in `restore.sh db` and `drill` (#2877). See the entries
  under Fixed and Changed.

  `RESTORE_REQUIRE_CHECKSUM=1` used to govern `restore.sh media` only. It
  now also governs `db` and `drill`, so a scripted restore or drill that
  sets it fails, before touching the database, on a dump from before
  checksums, on a dump fetched without its sidecar, and on one renamed away
  from `kiln-db-<stamp>.dump` (or reached through a symlink under another
  name), with "RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found —
  nothing was restored". Fetch the sidecar next to the dump, keep the
  dump's name, or drop the variable for that run. Without the variable such
  a dump restores as before, after a warning banner.

  An older `backup.sh` still running beside this release keeps writing
  `manifest.json.partial`. Neither the app nor the new `prune` removes that
  name, so after the last older run, delete a leftover by hand. Rolling the
  pin back restores the old scripts' behavior; nothing is stored.
  ([#2832](https://github.com/The-Verscienta/kiln_cms/issues/2832),
  [#2847](https://github.com/The-Verscienta/kiln_cms/issues/2847),
  [#2877](https://github.com/The-Verscienta/kiln_cms/issues/2877))

<a id="webhook-failure-alerts-upgrade"></a>

- **Run `mix ash.migrate` (new `users.notify_on_webhook_failure`, boolean, default `true`).**
  The column backs the new **Webhook failures** email switch. Every existing
  account starts with it on. Rolling back to 1.10 is safe: 1.10 ignores the
  column, and shows a `webhook_failing` or `webhook_disabled` notice in the
  bell as a neutral line rather than failing to load it (#2509).

<a id="backup-resume-source-host-first-upgrade"></a>

- **Run `mix ash.migrate` (new nullable `backup_node_beats.last_dir_id`, #2817). Until every node runs this release, a node on the previous release still resumes a backup from a copy of its files while the source host is alive. Rolling back is safe.**
  The migration `add_node_beat_last_dir_id` adds one nullable `uuid` column
  to `backup_node_beats`, with nothing to backfill: each node writes it on
  its next beat. Every beat of this release writes it, so migrate before the
  new release's nodes start, as with any other column. It carries the last
  backup-directory id the node's heartbeat read, which a resume's start now
  checks before it resumes from a copy of the backup's files (see the
  *Fixed* entry below).

  **During a rolling deploy.** A node still on the previous release keeps the
  old rule: a copy of `.work/<stamp>/` in its backup directory resumes there
  at once, whether or not the source host is alive. Only a deployment with a
  `BACKUP_DIR` per host, and a copy of one host's work files on another, can
  notice. To be sure, don't resume a backup until every node runs this
  release.

  **Rolling back.** The previous release ignores the column and resumes by
  its own files-first rule. The column stays; nothing needs undoing.
  ([#2817](https://github.com/The-Verscienta/kiln_cms/issues/2817))

<a id="backup-dir-queues-upgrade"></a>

- **Run `mix ash.migrate` (new nullable `backup_node_beats.dir_queue` and `dir_queue_boot_id`, #2845). Finish a rolling deploy before you start, cancel or resume a backup. Before rolling back past this release, cancel running backups or let them finish.**
  The migration `add_node_beat_dir_queue` adds two nullable `uuid` columns
  to `backup_node_beats`, with nothing to backfill: each node of this
  release writes them on its beats, to advertise the backup directory queue
  it runs (see the *Changed* entry below). Migrate before the new release's
  nodes start, as with any other column.

  **During a rolling deploy.** A node on the previous release never
  advertises a queue, so its directory's backup steps keep the 30-second
  put-backs in `backup_steps`, as before. Its **Cancel** misses a step that
  waits in a directory queue: the run is still canceled and the lock
  released, and the step cancels itself when it runs; one already running
  there stops at its next fenced call. To be sure, don't start, cancel or
  resume a backup until every node runs this release.

  **Rolling back.** The previous release never runs a `backup_dir_<id>`
  queue, and neither takes back nor fails a step waiting in one, so a
  backup whose step waits there holds the lock, and every backup behind
  it, until a platform admin cancels it. Before rolling back, cancel a
  running backup or let it finish, and check that no job waits in a
  `backup_dir_` queue (the query is in
  [Rolling back past backup directory queues](../backups.md#rolling-back-past-backup-directory-queues)).
  The columns stay; the previous release ignores them.

<a id="backup-cron-app-parity-upgrade"></a>

- **An in-app media backup that skipped a folder it could list but not enter now fails, naming the folder (#2477). Cron now resets `$BACKUP_DIR/media` to 0700 on every run.**
  A media folder that can be listed but not entered (no execute
  permission, for example mode 0644) used to be skipped by the in-app
  backup: its files were counted as unreadable names and the run still
  ended Succeeded. Cron failed the whole run. Both now fail, at once and
  without retries, with the same message:
  `media folder "<folder>" can be listed but not entered (no execute permission): fix its permissions, or leave it out with BACKUP_MEDIA_EXCLUDE`.
  Some runs that were green turn red after the upgrade; fix the folder's
  permissions or exclude it.

  Cron also used to set `$BACKUP_DIR/media` to 0700 only when it created
  it. It now resets an existing directory to 0700 on every run, as the app
  does, and fails with `could not make <dir> private (chmod 700)` when the
  cron user can't (for example a directory it doesn't own). No migration;
  rolling back is safe. See
  [Cron backups in parts](../backups.md#cron-backups-in-parts).
  ([#2477](https://github.com/The-Verscienta/kiln_cms/issues/2477))

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

<a id="field-sync-section-entries-stricter"></a>

- **Field sync import: a non-default `"sections"` entry that no top-level field carries after the import is refused, an entry at the default deletes the stored layout without `--prune`, and a section the import leaves without fields loses its layout even when the owner has no `"sections"` key (#2652, #2881).**
  Before, the import stored a layout for any section the file listed, so a
  hand-edited entry for a section with no field (a typo, a section added
  before its fields, a field moved out with its entry left in) left a row
  that the next field filed under that name took on. Such an entry is now an
  error at plan time, so the dry run, the console preview and `--apply` all
  refuse the whole file and write nothing:

  ```text
  ERROR post/section/Clinical: no field of post is in this section, so its layout lays nothing out
  ```

  The carriers are the file's own fields plus the stored fields the import
  keeps (those it does not list, unless `--prune` deletes them; a field of a
  type this release does not register always counts). A file made by
  `mix kiln.fields.export` never has such an entry, so only a hand-edited
  file or one generated by your own tooling can be refused. A deploy script
  that imports such a file now fails where it used to succeed: fix the file
  (put a field in the section, correct the name, or drop the entry).

  Two quieter changes to what an import writes, both matching what the
  fields admin already did:
  - An entry at the default layout (`accordion`, `initially` `auto`) stores
    nothing and deletes the stored row of that name, with or without
    `--prune`. The export now leaves out stored rows at the default.
  - A field the import deletes or moves to another section takes its
    section's layout with it when no other top-level field carries the name,
    without `--prune` and also for an owner with no `"sections"` key. The
    diff lists it as `- type/section/Name`. Before, only a delete did this.

  No migration; rolling back restores the old import behavior. Guide:
  [A section entry no field carries](../field-sync.md#a-section-entry-no-field-carries).

<a id="scheduled-content-actions-due-only"></a>

- **`:publish_scheduled`, `:unpublish_scheduled` and `:archive_scheduled` now change a record only while it still matches its AshOban trigger's condition. Called on any other record, they return an `Ash.Error.Invalid` holding an `Ash.Error.Changes.StaleRecord` and change nothing.**
  Each action's `UPDATE` now carries its trigger's `where` as a filter:
  - `:publish_scheduled`: a `:draft` or `:in_review` record whose
    `scheduled_at` is set and has passed;
  - `:unpublish_scheduled`: a `:published` record whose `unpublish_at` has
    passed and whose `expiry_action` is `:unpublish`;
  - `:archive_scheduled`: the same, with `expiry_action` `:archive`.

  This is the fix for #2746 (see
  [the Fixed entry](#scheduled-content-on-the-row)). The scheduler only ever
  ran these actions on such records, so a site that leaves them to the cron
  sees no difference.

  Affected: overlay or plugin code, and tests, that call these actions
  directly through a content type's code interface (`CMS.publish_scheduled_page!`,
  `CMS.unpublish_scheduled_post!`, `CMS.archive_scheduled_post!`, or an
  overlay type's own `define`) on a record whose date has not passed. Either
  set the date in the past first (`scheduled_at`, or `unpublish_at` plus
  `expiry_action: :archive` for an archive), as Kiln's own tests now do, or
  call `:publish`, `:unpublish` or `:archive`, the actions for "now". None of
  the three is routed over JSON:API, GraphQL or MCP, so API clients are not
  affected. No migration; rolling back is safe. Refs #2746.

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

<a id="webhook-failure-alerts"></a>

- **Site admins are told when a webhook stops getting through.**
  A webhook endpoint auto-disables after 10 deliveries in a row exhaust their
  retries, and until now nothing said so: the site that the webhook rebuilds
  just stopped showing new content, and the only sign was a **Disabled**
  badge on `/editor/webhooks`. Now `KilnCMS.Webhooks.HealthNotice` tells the
  site's admins at two points: **"A webhook is failing"** on the first
  exhausted delivery in a row, and **"A webhook was switched off"** when it
  auto-disables. Each is a bell notice linking to `/editor/webhooks` and an
  email (`KilnCMS.Accounts.User.Senders.SendWebhookFailure`).
  - **One notice, not one per publish.** Both events collapse per endpoint
    while unread (`:webhook_failing`, `:webhook_disabled`, `content_type`
    `"webhook_endpoint"`, `content_id` the endpoint), and the email goes only
    with a new notice. Opening `/editor/webhooks` marks them read.
  - **Who:** the same admins the registration notice reaches: standing
    platform admins and active site admin members, not temporary platform
    admins or erased accounts.
  - **Mute:** `notify_on_webhook_failure` (**Your settings → Email
    notifications → Webhook failures**) mutes the email only. It is in the
    self-export and reset to on by erasure.
  - **Masked:** the notice and email name the endpoint by its masked URL and
    carry no error text, which can echo the URL back (ADR 0028).
  - Retractions are unchanged: they never count toward auto-disable, and a
    lost one keeps its own "Retraction not delivered" notice.
  See [Failure alerts](../webhooks.md#failure-alerts).

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
  `local`, `rclone`, `s3` nor another module already has. See *Backup
  destinations* in [plugin-extensibility.md](../plugin-extensibility.md).

<a id="resumable-backup-uploads"></a>

- **Backup uploads can resume: on a destination whose adapter opts in, an off-site upload cut off by a timeout, a retry, a node that died or a reclaim continues from its last checkpoint on the next attempt (part of #2223).**
  Kiln's S3 destination resumes (#2221, *S3-compatible storage* below), and
  a plugin's adapter can, from `kiln_plugin` 1.5. Each
  upload under way is a row in the new `backup_uploads` table
  (`KilnCMS.Backups.Upload`, system-only), keyed by the destination and the
  file, owned by the step's Oban job and attempt. Ownership only moves
  forward, so a step that lost its lease can't overwrite the progress of
  the step that took over. A checkpoint is handed back only for a file of
  the same size and SHA-256. Kiln aborts a recorded upload only when it
  failed permanently, its file changed, the file turned out to be on the
  destination already, or it lay unfinished for four days; a timeout or a
  transient failure keeps it for the next attempt. Each time a backup
  reaches a destination, a sweep aborts that destination's abandoned and
  four-day-idle uploads, whether or not retention is on there, and closed
  rows are purged after 30 days. Kiln never lists the store's own pending
  uploads, so with an S3-style resumable adapter, set the bucket's
  lifecycle rule for incomplete multipart uploads as well.

  **Every adapter changes a little.** Every `put/3` now gets
  `opts[:deadline]`, the `System.monotonic_time(:millisecond)` instant the
  call must end by. A `put/3` may answer `{:ok, :already_present}` when the
  destination already holds the file with the same size and SHA-256: the
  file is recorded as sent, and the run's log reads "`<file>` was already
  on `<destination>` with the same checksum; not sent again". Such a file is
  then retention's to delete there like any file this installation sent,
  since the same stamp and checksum are the same backup. A **Directory on
  this server** destination answers this way: it compares the target's size,
  then reads it whole to hash it. A `put/3` may answer `{:error,
  {:permanent, message}}` for a failure no retry fixes, which fails that
  destination on the attempt it happens in, and the backup moves on to the
  next destination. A refused file still fails the whole backup (ADR 0043).
  Any other `{:ok, _}` from a plugin's `put/3` is now that file's error
  ("`<module>.put/3` returned an unexpected value"), where an
  `{:ok, _}` the step didn't expect used to crash it.

  **New on the run's log:** "Resumed `<file>` on `<destination>` at X of Y
  bytes" (or "… from its last checkpoint"), and "Aborted N unfinished
  upload(s) on `<destination>`", with the sweep's
  `[:kiln_cms, :backups, :upload, :swept]` telemetry event. A destination
  whose file was refused now reads "REFUSED for N files: …" on its chip and
  in **Where backups go**; it had shown an inspected Elixir map since
  destinations were added in this release cycle. `mix kiln.plugins.doctor`
  reports an adapter that declares `:resume` without `abort_upload/3`,
  which is never resumed. The reasoning is in
  [ADR 0068](../decisions/0068-a-resumable-backup-upload-is-recorded-by-the-installation-that-started-it-and-only-it-aborts-it.md);
  how it behaves is in
  [Resumable uploads](../backups.md#resumable-uploads), and what a plugin
  implements is in
  [plugin-extensibility.md](../plugin-extensibility.md#resumable-uploads-in-a-backup-destination).

<a id="s3-backup-destination"></a>

- **Backups → Destinations has a new kind, S3-compatible storage: AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO or Garage, with resumable multipart uploads and retention. A store on your own network needs its host in the new `BACKUP_S3_PRIVATE_HOSTS` (#2221; closes the second half of #2223).**
  A platform admin adds it on the **Destinations** tab like any destination:
  **Endpoint**, **Region** (`auto` for R2), **Bucket**, an optional
  **Prefix**, **Path style**, and the key pair, **Access key** and **Secret
  access key**, both stored encrypted under `SECRET_KEY_BASE` and never
  shown again. Save checks the settings and resolves the endpoint without
  contacting the store; **Test** checks the bucket (`HeadBucket`), compares
  the store's clock with this server's, lists one key, and writes, reads
  back and deletes a probe under `<prefix>/.kiln-test/`. Files land as in
  `BACKUP_DIR`, under `<prefix>/db/` and `<prefix>/media/`, and every object
  carries the file's SHA-256 as `x-amz-meta-kiln-sha256`. The key needs
  `s3:ListBucket`, `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`,
  `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts`; without
  `s3:ListBucket` a missing file answers `403`, which reads as refused
  access.

  **Uploads.** A file the bucket already holds with the same size and
  SHA-256 is not sent again. A file under 16 MiB goes in one request; a
  larger one in sequential parts of at least 16 MiB, each with
  `Content-MD5`, recorded as the store acknowledges it, so a cut-off upload
  resumes on the next attempt (see *Backup uploads can resume* above).
  Before trusting its record, a resume lists the parts the store holds and
  checks a digest of their numbers, ETags and sizes; it doesn't assume an
  ETag is an MD5, so a bucket with SSE-KMS or MinIO's encryption resumes as
  well. Before completing, the file's SHA-256 must equal the verified one,
  and after completing a `HEAD` confirms the object's size and SHA-256
  metadata, which also catches a `200` answer that carries an `<Error>`.

  **Failures.** Refused credentials, a missing bucket, the wrong region
  (named, when the store's `301` gives it), a clock more than five minutes
  off, `InvalidPart`, `EntityTooLarge`, and a file over 5 TiB fail the
  destination at once, as a permanent failure, and its recorded upload is
  aborted. A `5xx`, `SlowDown`, a `429`, a timeout and any other `4xx` are
  retried up to six times with full-jitter backoff (1 s base, 30 s cap),
  never into the last 30 seconds before the step's deadline. Kiln writes its
  own sentence for each error and never shows the store's `<Message>`. Each
  request emits `[:kiln_cms, :backups, :s3, :request]`, without a key, URL,
  header or body.

  **Where it may connect.** The endpoint must be `https://` and resolve only
  to public addresses, checked on save and again before every call, and
  each call connects to the address it checked, following no redirect. The
  operator opens a private or loopback store, and `http://`, by listing its
  exact host name in `BACKUP_S3_PRIVATE_HOSTS` (the name connected to:
  the host with **Path style** ticked, else `<bucket>.<host>`). No listing
  opens a link-local or cloud-metadata address, including through NAT64 or
  6to4. A name that doesn't resolve on the node serving the page can't be
  saved, and a host name with only IPv6 addresses reads as not resolving;
  an IPv6 literal works. The request never uses the app's own `:ex_aws`
  configuration, so the media store's credentials can't reach a host an
  admin typed. The reasoning is in
  [ADR 0069](../decisions/0069-an-admin-entered-backup-endpoint-is-pinned-per-call-and-only-the-operator-opens-private-hosts.md).

  **Retention** runs as on any destination, with two limits. While
  `BACKUP_RCLONE_REMOTE` is set it is skipped on an S3 destination ("can't
  confirm it doesn't overlap BACKUP_RCLONE_REMOTE"), since a remote may name
  the same bucket under any name (ADR 0064). Two S3 destinations overlap
  only on the same endpoint host and port, the same bucket and nested
  prefixes, so two names for one store (`s3.amazonaws.com` and
  `s3.us-east-1.amazonaws.com`) aren't caught: don't point two destinations
  at one bucket. On a versioned bucket a delete leaves the old version.

  **Set a lifecycle rule** on the bucket that aborts incomplete multipart
  uploads after a few days (seven, say): Kiln aborts only the uploads it
  recorded, and the form says so under the S3 fields. Storage classes and
  server-side encryption headers (#2224) are not set.

  Nothing to migrate beyond the `backup_uploads` table above;
  `BACKUP_S3_PRIVATE_HOSTS` is needed only for a store on a private network
  or over `http://`, and is read in every environment. `mix
  kiln.plugins.doctor` now reports a plugin kind `s3` as taken, and
  `KilnCMS.Backups.Destination.core_kinds/0` lists Kiln's own kinds. How to
  set it up, with each provider's settings, an IAM policy and the lifecycle
  rule:
  [Back up to S3-compatible storage](../backups.md#back-up-to-s3-compatible-storage).

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

<a id="user-field-erased-person"></a>

- **A document whose `:user` custom field names an erased person is refused on its next save that changes its custom fields, with "must be a person on this site".**
  The field must name someone on the writing site's roster, and an erased
  account is now on none (#2774). This is the rule that already applied to
  someone removed from the site: the stored value stays and is not
  delivered (the field is private), but saving the document again with a
  change to its custom fields fails until an editor picks another person or
  clears the field. The picker no longer offers the erased person. No
  migration. See
  [Account administration](../account-administration.md#remove-an-erased-member-from-a-site).
  ([#2774](https://github.com/The-Verscienta/kiln_cms/issues/2774))

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

<a id="backup-scripts-portability-ci"></a>

- **For contributors: the host backup script tests also run in CI under bash 3.2.57 with GNU tar and under bash 5 with bsdtar, and check that busybox tar is refused (#2479, #2420). The backup docs now say what `backup.sh all` keeps when it refuses a tar.**
  `scripts/backup.sh`, `restore.sh` and `staging.sh` claim bash 3.2 (macOS's
  `/bin/bash`) and bsdtar as well as bash 5 and GNU tar, but the `test` shards
  only ever ran bash 5 and GNU tar, so the other combinations were checked on
  developers' Macs or not at all. The new `backup_scripts_portability` job
  runs the test files tagged `:shell_portability` under each, with bash 3.2.57
  built from a SHA-256-pinned GNU tarball (`scripts/ci/build_bash32.sh`). It is
  not a required check until its pass rate is known. BSD `stat`, BSD `xargs`
  and AppleDouble members stay checked on Macs only: setup-beam has no macOS
  builds. No change to the scripts.

  The docs said a busybox tar is "refused before anything is written". That
  holds for `backup.sh media`. In `backup.sh all` the database dump runs
  first, so it is kept with a verified checksum; the media phase is then
  refused before any part is written, the run exits 1, and `manifest.json`
  records the refusal with the dump as its artifact. See
  [Cron backups in parts](../backups.md#cron-backups-in-parts) and, for
  running the CI legs locally,
  [Contributing](../../CONTRIBUTING.md#run-the-backup-script-tests-under-every-shell-and-tar).

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

<a id="workflow-task-mail-send-time-checks"></a>

- **Workflow and task mail checks again when it sends: an event muted since it was queued is not sent, nor is mail about content trashed or deleted, a comment deleted, or a task completed, deleted or reassigned in the meantime.**
  The mail used to carry everything from the moment of the event and was
  sent whatever had changed while it waited or retried. Now each job reads
  the recipient, the content, the comment or the task back when it runs:

  - A recipient who turned the event off in `/editor/settings` (**Email
    notifications**) after it was queued gets nothing. Task mail has no
    preference, so only erasure stops it.
  - The mail goes to the address the account holds when it is sent.
  - The title, the comment excerpt and the task's note and due date are
    their values then. An actor erased since is "An editor" (or "A
    reviewer"); an actor who renamed themselves appears under the new name.
  - Nothing is sent for content trashed or deleted since, a comment deleted
    since, or a task completed, deleted or reassigned since (the new
    assignee gets their own mail). A digest still lists an item whose content
    is gone, titled by its content type, as before.

  A mail not sent for one of these reasons completes its job and logs one
  `info` line with the job id and the reason, never the address; it is not a
  delivery failure on `/editor/mail`. A read that fails, a refused one
  included, fails the job, which retries. A job queued by the previous
  release is checked against the recipient's erasure and preference, and is
  sent with the title and names it carries. Each mail also re-checks its
  event's own rule and the suppression lists when it sends: see the Fixed
  entry *Workflow and task mail re-checks each event's own rule when it
  sends* and the entry *Workflow and task mail is not sent to an address on
  the instance suppression list* below, which also cover jobs of the
  previous shape.

  No migration.
  ([#3019](https://github.com/The-Verscienta/kiln_cms/issues/3019))

<a id="workflow-task-mail-suppression"></a>

- **Workflow and task mail is not sent to an address on the instance suppression list or on the site's own, checked when it sends.**
  Review requests, published and returned-to-draft mail, comment and
  mention mail, task assignments and task digests build their own message
  when the job runs, so they never passed the suppression check that other
  mail gets when it is queued. An address a relay had hard-bounced kept
  being mailed, and kept bouncing, which is the signal the list exists to
  stop.

  Each job now asks `KilnCMS.Mail.suppressed?/2` with its site just before
  it sends: an address on the instance-wide list (`/editor/mail`) or on that
  site's list (`/editor/site-mail`) is sent nothing, and another site's list
  is not consulted. The job completes and logs one `info` line with the job
  id and the reason `suppressed`, never the address; it is not a delivery
  failure on `/editor/mail`. A list that cannot be read fails the job, which
  retries, as the newsletter worker does. Jobs queued by v1.10.1 are checked
  the same way. To mail a suppressed address again, remove it from the list.

  Suppression rows are kept as before, with no retention, and erasure does
  not remove them. No migration.
  Refs #3036.

<a id="registration-notice-needs-account"></a>

- **The "Someone tried to create a (site) account with your address" notice is not sent if no account holds the address by the time it is queued.**
  The notice goes to the owner of an existing account when someone tries to
  register with its address. It is now queued for that account, read again
  after the registration's transaction (about a millisecond, on the path
  that already queues a job), so it is checked like other account mail when
  it is sent. If the account was erased between the refused registration and
  that read, nothing is sent. The person registering sees the same answer
  either way. See
  [What happens when someone registers](../account-administration.md#what-happens-when-someone-registers).
  ([#3035](https://github.com/The-Verscienta/kiln_cms/issues/3035))

<a id="api-key-reuse-alert-names-owner"></a>

- **The API key reuse email names the key's owner by display name, or "account" and their id, instead of their email address.**
  When a rotated-away drafts-only API key is presented again and the
  platform admins are mailed directly ("A drafts-only API key on (site) was
  used after it was rotated"), the body said "acting as" the owner's email
  address. It now says their display name, or `account <id>` when they have
  none or are erased, so the mail queued to each admin holds nobody else's
  address. Nothing else about the alert changed.
  ([#3035](https://github.com/The-Verscienta/kiln_cms/issues/3035))

<a id="backup-sh-signals-stop-child"></a>

- **`backup.sh` stops at once on `HUP`, `INT` or `TERM`: it stops the running `pg_dump`, `pg_restore --list`, `tar` or `rclone`, then cleans up, instead of waiting for it to finish.**
  bash defers a trap while a foreground command runs, so a `TERM` sent
  during an hour-long dump or upload did nothing until that command ended.
  The script now runs those four programs in the background and waits for
  them, which a trapped signal interrupts. Its cleanup sends the program
  `TERM` (resuming it first if it was stopped), then `KILL` if it still runs
  about 5 seconds later, and then removes the run's `.partial` files and
  writes the failure manifest ("interrupted by SIGTERM"), as before. A second
  signal during the cleanup is ignored, where it used to cut the cleanup
  short and leave `.partial` files and no failure manifest. Ctrl-C at a
  terminal reaches the program through the script's `TERM`. The programs
  keep the script's stdin, so an rclone that prompts for its config
  password still can. One case still waits: a program stuck in the kernel
  on a hung mount ignores both signals until its I/O returns, and the
  cleanup waits with it. See
  [Cron backups in parts](../backups.md#cron-backups-in-parts), "When a run fails".
  ([#2847](https://github.com/The-Verscienta/kiln_cms/issues/2847))

<a id="factor-removed-notice-names-admin"></a>

- **The email telling someone a platform admin removed their passkey or authenticator app names that admin by display name ("an administrator" when they have none) instead of their email address.**
  The "A second factor was removed from your (site) account" email said
  "It was removed by an administrator," followed by the admin's email
  address, so the owner's mail held another person's contact data. It now
  names the admin as invitations name their inviter: by display name,
  escaped, or as "an administrator" alone when the admin has no name or has
  been erased. The admin is still recorded in the security log's
  `two_factor_disabled` event. A notice already queued keeps the wording it
  was written with.
  ([#3044](https://github.com/The-Verscienta/kiln_cms/issues/3044))

<a id="backup-dir-queues"></a>

- **A backup step, a resume's start or a last-good marker sync that must run where a backup directory is now goes to that directory's own Oban queue, `backup_dir_<id>`, which only the nodes with that directory run (#2845).**
  Before this, such a job waited in the shared `backup_steps` (or `default`)
  queue, and every node without the directory that fetched it put it back
  for 30 seconds, up to 20 times per attempt. With a `BACKUP_DIR` per host,
  a host whose node was slow to fetch could see an attempt used up with
  nothing wrong (`:backup_dir_elsewhere`). Now each node's backup heartbeat
  starts its directory's queue at runtime (limit 1, that node only) and
  advertises it in its beat once it runs; a job goes into the queue only
  while a node with a beat in the last 180 seconds advertises it. A node
  without the directory that fetches such a job from the shared queue moves
  it there: the same job id, no attempt spent. On a shared volume every
  node runs the one queue, so any node still takes any step.

  The put-backs remain the fallback, for a directory whose node runs an
  older release, a queue that didn't start because Oban's Postgres notifier
  isn't working (one warning in the log, and
  `[:kiln_cms, :backups, :dir_queue, :start_failed]`), and a resume whose
  directory no running node reports. A job left in a directory queue that
  no node runs is moved back to `backup_steps` after 5 minutes when the
  directory's node is up but not running its queue. When no node has
  reported the directory for 180 seconds and the job has waited 30
  minutes, a backup step fails the backup ("Interrupted: no server with its
  backup directory (id `<id>`) picked up the `<step>` step for 30
  minutes"), releasing the lock; a resume's start goes back to
  `backup_steps`; a marker sync is canceled.

  A queue is paused, never stopped, when its directory's id changes (at
  once) or stops being read (after 180 seconds), and resumed when the id
  returns; one paused by anything else is left paused. Cancel now finds a
  backup's step in any queue. Both workers' uniqueness is over the job's
  args and worker, not its queue. New telemetry:
  `[:kiln_cms, :backups, :dir_queue, :started | :paused | :resumed | :start_failed | :routed]`
  and `[:kiln_cms, :backups, :lock, :stranded]`. The Lock's
  `:reclaim_stale` action now returns a `stranded:` outcome too. Size
  `POOL_SIZE` for one more Oban job per node. Off switch, not needed on a
  working deployment: `config :kiln_cms, KilnCMS.Backups, dir_queues?: false`.
  See [Which node runs a step](../backups.md#which-node-runs-a-step) and
  [ADR 0070](../decisions/0070-a-directory-pinned-backup-job-runs-from-a-queue-named-for-its-directory-which-the-nodes-reporting-it-start.md).
  ([#2845](https://github.com/The-Verscienta/kiln_cms/issues/2845))

## Fixed

<a id="staging-up-stops-on-a-failed-copy"></a>

- **`scripts/staging.sh up` stops when `pg_dump` or `psql` fails, under bash 3.2 on Linux too.**
  The copy is a pipeline of two subshells. bash 3.2 as built on Linux does
  not apply `set -e` to a pipeline that ends in a subshell, so a failed dump
  went on to migrate and scrub an empty staging database and reported
  success. The script now checks the pipeline's status itself and exits with
  "copying production into <db> failed; nothing was migrated or scrubbed".
  Found by the new bash 3.2 CI leg. ([#3020](https://github.com/The-Verscienta/kiln_cms/pull/3020))

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

<a id="section-layouts-kept-in-step"></a>

- **A section's layout no longer outlives its last field: every field update or delete that empties a section deletes the layout in the same transaction, and a section rename in the fields admin decides from the fields as they are at Save (#2652, #2881).**
  A section layout (Tab, Fieldset, how an accordion starts) is stored under
  the section's name. Several paths left it behind when the section's last
  field went, and the next field filed under that name inherited a tab or
  fieldset nobody had set: retiring a field through a join graduation,
  clearing a field's **Section**, renaming the last field onto a section
  that already had a layout, moving a field to another type from code,
  and a field sync import that moved a field (see Breaking). The
  rename also decided from the page as it was loaded, so with a second admin
  editing the same type it could move a layout another field still used, or
  leave one nothing used. This was the 1.10.0 known issue "Renaming a
  field's section can move or leave its layout wrongly".

  Now `KilnCMS.CMS.FieldDefinition`'s `:update` and `:destroy` keep the
  layouts themselves (`KilnCMS.CMS.Changes.KeepSectionLayouts`), from a
  locked read of the field inside the write's transaction, as the write's
  own actor. In the fields admin:
  - Renaming a section's last field onto a section that has its own layout
    now saves without an error; the target keeps its layout and the old one
    is deleted. Before, it said "Couldn't save the section layout." and kept
    both.
  - If the layout cannot be moved or deleted, the field is not saved either:
    **Save** shows "Couldn't save the section layout." with the form still
    open, and **Delete** shows "Couldn't delete that field." Before, the
    field was saved and the layout left behind.

  For code: `:update` accepts `carry_section_layout?` (boolean, default
  `false`); pass `true` to move the old section's layout to the new name
  as the fields admin does. A write whose layouts cannot be kept fails with
  `KilnCMS.CMS.Errors.SectionLayoutNotKept` (class `:invalid`) and rolls
  back. `KilnCMS.CMS.FieldSection.default?/1` tells whether a layout is the
  default, and `KilnCMS.CMS.SectionLayouts` gains `carry/4` and
  `prune_names/2`; its reads now fail closed on a refused read. No migration.

  **Not fixed:** a layout a 1.9.x or 1.10.x release already left behind stays
  until the type's next layout change in the **Sections of** panel. Rationale:
  [ADR 0046](../decisions/0046-a-sections-layout-is-its-own-row-keyed-by-the-section-name-not-a-setting-on-each-field.md#amendment-2026-11-16-2652-and-2881-the-field-write-keeps-its-layouts).

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


<a id="codeql-second-pass"></a>

- **`/embed.js` builds the iframe from the parsed `data-kiln-origin` URL, and resize messages now work when that URL has a path. `kiln-types` can no longer emit code from a hostile schema's format version or type names. Third-party Actions are pinned to commit SHAs.**
  The second pass over the open CodeQL alerts (26 of them).
  - **`js/xss-through-dom`, `priv/static/embed.js`.** The earlier fix checked
    the protocol of the parsed URL but then used the raw attribute. The iframe
    `src` is now built from the parsed URL (`origin` plus the trimmed path), so
    the value that was checked is the value used. Resize messages are matched
    against the URL's real origin. Before, a `data-kiln-origin` with a path
    (`https://cms.example.com/kiln`) was compared whole against
    `event.origin`, so the frame never resized.
  - **`js/http-to-file-access`, `clients/js/src/cli.ts`.** Writing the fetched
    schema's declarations to `--out` is what `kiln-types` is for. What the alert
    pointed at: the emitter put `x-kiln.artifact_format_version` into a `//`
    comment as is, and `$defs` names into type names as is. A server, or
    anyone on the path to an `http://` one, could end the comment with a line
    break, or a name with `;`, and have code written into a `.ts` file that the
    integrator then compiles. Line breaks in the comment become spaces, and type
    names keep only identifier characters. Property keys, string literals and
    doc comments were already escaped.
  - **`actions/unpinned-tag` (24 alerts).** `erlef/setup-beam` and the
    `docker/*` actions are pinned to the commit of the tag they used before,
    with the version in a comment. A new `.github/dependabot.yml` bumps them in
    one grouped PR a month. GitHub's own `actions/*` stay on tags; the rule
    doesn't flag them.

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

<a id="backup-cancel-waiting-resume"></a>

- **A resume waiting to start can now be canceled from the Backups page, so it no longer holds every other backup back for up to an hour.**
  A resume holds the backup lock from its request, but its `start` step can
  wait before it picks the backup up again: up to about an hour for the
  server that has the backup's files, or up to three minutes after the
  backup's own Cancel. New and scheduled backups queued behind it all that
  time, and the page offered no Cancel, because the History row wasn't
  `Running`. The in-flight strip now says what the resume is waiting for
  ("Waiting for the server that has this backup's files", "Waiting for the
  canceled backup's step to stop", or "Starting a resume") and, for a
  platform admin, offers **Cancel**. It cancels the resume's start job,
  releases the lock (a queued backup starts next) and leaves the backup as it
  was: a `Failed` or `Canceled` row keeps its status and its **Resume**
  button, and a row left `Running` by an attempt that stopped becomes
  `Failed`. The row's error and log read "Resume canceled by a platform admin
  before it started". It is the new `Run` action `:cancel_resume`
  (`KilnCMS.Backups.cancel_run_resume/2`, platform admin only; the backup
  system actor is refused), audited as `backup_canceled` with `step` `start`
  and the new metadata key `resume` `true`. If the resume picks the backup up
  before the Cancel lands, nothing changes and the page says "The resume
  started meanwhile. Cancel it again to stop the backup."; if the Cancel lands
  first, the start stops without re-opening the run. `Backups.await/2` on
  the canceled resume's chain returns `{:error, :no_run}`, and
  `Backups.in_flight/1` now reports `resume` (and, with `details: true`,
  `waiting_for`). A fresh backup waiting at its start for a legacy
  `Backups.Worker` job still has no Cancel. During a rolling upgrade, a
  resume start running on a node still on an older release doesn't check its
  lease before re-opening the run. No migration; rolling back removes the
  button. See
  [Cancel a resume that is waiting to start](../backups.md#cancel-a-resume-that-is-waiting-to-start)
  and the amendment to
  [ADR 0045](../decisions/0045-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md).
  ([#2816](https://github.com/The-Verscienta/kiln_cms/issues/2816))

<a id="backup-reclaimed-finish-stays-finishing"></a>

- **A finish step taken back from a stopped node stays past the point of no return, so Cancel is refused until it completes.**
  The heartbeat's take-back moved the lock to the replacement job and reset
  its phase to running until that job marked it finishing again. A Cancel in
  that gap was accepted, and could leave a `Canceled` run next to a manifest
  that already said ok, and a leftover `.work/<stamp>/`. The take-back now
  keeps the finishing phase, so Cancel says "Too late to cancel: the backup
  is finishing." throughout. During a rolling upgrade a node still on an
  older release that takes back a finish step still drops the phase, until
  every node runs this release. No migration; rolling back brings the gap
  back. ([#3012](https://github.com/The-Verscienta/kiln_cms/issues/3012))

<a id="backup-finish-marker-sync-fenced"></a>

- **A backup's finish step syncs the `.good` and `.hold` markers only while it still holds the backup lock.**
  The finish step synced the markers and then released the lock without
  checking that the lock was still its own. A finish that had stalled long
  enough to be taken back, while the step that took over (or the next
  backup) ran, could still move the markers, and two syncs for different
  backups can remove each other's markers. The sync now runs only while the
  step still holds the lock, with cron's backups imported first, outside it.
  A finish that has lost the lock writes no marker, releases nothing and
  leaves completing the backup to the step that took over, as the finish
  that completes after an interruption already did. No migration.
  ([#3013](https://github.com/The-Verscienta/kiln_cms/issues/3013))

<a id="backup-step-files-fenced"></a>

- **A backup step that outlives its Cancel can no longer replace the backup's files, and writing a backup's state no longer holds the backup lock.**
  A step on a node that missed its Cancel or its take-back keeps running
  until its heartbeat stops it. Its `state.json` write was already fenced,
  but it held the cluster-wide backup lock while it wrote: on a backup
  directory that stalls (a hung NFS mount), Cancel, new requests and the
  heartbeat's sweep waited behind it until their database query timed out
  (#2818). Its dump and media parts were not fenced at all: they were
  written to the same `.partial` names a resume of the same backup uses and
  renamed into place unconditionally, so only the 150-second wait after a
  Cancel kept such a step from overwriting the resume's files (#2819).

  Every file a step writes (the dump, each media part, the checksum
  sidecars, `state.json`, the media plan and its file lists, `manifest.json`)
  now goes to a temporary name of its own, `<name>.<job>-<attempt>.partial`,
  and is written, checked and hashed there outside the lock. Only the rename
  into place runs under the lock, and only while the step still holds the
  backup: a superseded step's rename is refused, and it removes its
  temporary file and stops. A step that must delete something of the
  backup's moves it into a trash directory on the same file system with one
  rename under the lock and deletes it after the lock is released; the start
  of every in-app backup empties the trash. The start step also reads the
  backup directory's `.kiln-dir-id` before taking the lock.

  What this does not do: the renames, the moves into the trash and the
  finish step's marker sync are still file-system calls inside the lock's
  transaction, so a mount that stalls between a step's write and its rename
  can still hold Cancel back. The off-site copies and the prune step are not
  fenced yet, and still rely on the wait after a Cancel. A later attempt of
  the same job (an Oban retry or a Lifeline rescue) shares its lease with
  an earlier attempt that is still running, so both attempts' renames are
  admitted. A media part or dump that fails on every attempt now leaves a
  file from an earlier attempt under its final name as it was, possibly
  without a matching sidecar, until retention ages the stamp out; nothing
  trusts it, since a resume reuses a file only on a recorded hash match.
  See
  [What a step that outlives its Cancel can write](../backups.md#what-a-step-that-outlives-its-cancel-can-write)
  and
  [ADR 0067](../decisions/0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md),
  which amends ADR 0039. No migration; see Upgrade notes for the host
  scripts.
  ([#2818](https://github.com/The-Verscienta/kiln_cms/issues/2818),
  [#2819](https://github.com/The-Verscienta/kiln_cms/issues/2819))

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

<a id="erasure-demotes-site-memberships"></a>

- **Erasure now demotes every site membership of the account, so an erased person is no longer a site admin or editor, an assignee, a mail recipient or a reader of gated content.**
  Erasure left the account's site memberships as they were. The tombstone
  kept its site tier, a live temporary tier and its audiences: it was still
  on the admin and editor rosters (the task assignee picker, the `:user`
  custom-field picker, review-request and registration-notice recipients),
  and its membership still granted gated content. Now:
  - each membership row stays, as the record of who belonged where, and is
    demoted (`OrgMembership.:erase`): tier `:viewer`, no temporary tier, no
    audiences. Its status, type scopes, field grants and custom role are
    kept; they only narrow a tier, so clearing them would widen the row. No
    role-change event is written to the security log;
  - an erased account has no tier and no audiences on any site and is on no
    roster, whatever a row still holds (`KilnCMS.Accounts.Scoping`);
  - it gets no workflow mail, no in-app notification, no task-assigned
    notice and no task digest. A task already naming it as assignee still
    fires `task.assigned`, the task's event;
  - editing its membership, granting it a temporary tier or saving its
    audiences on `/editor/accounts/:id` is refused with
    `KilnCMS.Accounts.Errors.AccountErased` ("belongs to an account that was
    erased"). Removing the membership still works;
  - the Team page (`/editor/team`) marks the row with an **Erased** badge and
    a note, and offers no **Edit** for it, only removal.

  Erasure now locks the account's row before any other row it writes, so a
  membership edit or temporary tier racing it either commits first and is
  demoted, or waits and is refused. `OrgMembership.:erase` is refused to
  every actor, platform admins included; erasure and its backfill call it
  with `authorize?: false`. The staging scrub runs the same erasure, so a
  scrubbed clone's site admins hold no tier and the staging admin the scrub
  creates is the one admin. Accounts erased before this release are handled
  by the boot backfill; see the Upgrade notes entry. No migration. See
  [docs/data-flows.md](../data-flows.md#subject-rights-workflows) and
  [docs/account-administration.md](../account-administration.md#removing-an-account).
  ([#2774](https://github.com/The-Verscienta/kiln_cms/issues/2774))

<a id="billing-webhook-erased-account"></a>

- **A payment webhook for an erased member no longer revives their canceled membership, and can no longer deadlock with that member's erasure.**
  Erasure cancels an account's paid memberships and drops their provider
  ids, but does not cancel the subscription at the provider, which keeps
  sending its events. A renewal for an erased member found the membership
  through the subscription's metadata, set it `active` again with the
  provider ids back, recorded an `activated` event and sent
  `membership.activated`. Now a membership transition locks the account's
  row first (`KilnCMS.Billing.Changes.SettleErasedAccount`) and, for an erased
  account, succeeds without changing anything: the provider gets its `200`
  and the event is recorded as processed, the row stays `canceled` with no
  provider ids, and no entitlement event, `membership.*` webhook, audience or
  newsletter segment follows. An admin's uncomp reaching an erased member's
  membership is the same no-op. **You still have to cancel the subscription
  at the provider**; until you do, the person is billed.

  The same lock fixes a deadlock: a transition locked the membership row
  first and the account second (in the entitlement recompute), while an
  erasure of the same person holds the account and cancels that membership.
  Every path now takes the account first. A newsletter tier sync racing an
  erasure was already safe, since it runs inside that transition after the
  account is locked; a test now pins it (#3006). No migration. See
  [docs/memberships.md](../memberships.md#when-the-member-was-erased).
  ([#2774](https://github.com/The-Verscienta/kiln_cms/issues/2774),
  [#3006](https://github.com/The-Verscienta/kiln_cms/issues/3006))

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
    Lifeline) completes without sending, and logs "submission no longer in
    the job, nothing sent" at `info`, instead of crashing. It is not
    canceled, so it is not listed as a delivery failure on `/editor/mail`.

  Not covered yet: this release still writes automation payloads in plain
  text, so they are in pending job rows and Oban's log lines until the next
  release seals them (see Known issues), and a `form.submitted` webhook
  keeps the submission in its delivery row for 30 days
  ([#2994](https://github.com/The-Verscienta/kiln_cms/issues/2994)). No
  migration. See [Job args retention](../data-flows.md#job-args-retention).
  Refs #2992.

<a id="workflow-task-mail-erased-recipient"></a>

- **Workflow and task mail queued before an erasure is no longer sent to the erased person, and their jobs carry ids instead of the address, title, names and excerpt. Erasure also strips the address from finished mail jobs.**
  Review requests, published and returned-to-draft mail, comment and
  mention mail, task assignments and task digests put the recipient's
  address in the job when the event happened. A job still waiting or
  retrying when the person was erased (a mail job can retry for about 15
  hours) was sent to their real address, and the address, the title, the
  actor's name and the comment excerpt or task note sat in `oban_jobs`, in
  Oban's log lines and in Sentry events for as long as the row lived.

  - A workflow mail job now carries `user_id`, `org_id`, the content's
    `kind` and `id`, `actor_id` and, for a comment event, `block_id` and
    `comment_id`; a task assignment `user_id`, `org_id`, `task_id` and
    `actor_id`; a digest `user_id`, `org_id` and its list of task ids,
    content ids and due dates. The worker reads the account when it runs
    (`KilnCMS.Notifications.mail_recipient/2`) and sends nothing to one
    erased since, or with no address left. See the Changed entry for the
    other checks it makes then.
  - A job queued by the previous release still carries the address. It is
    delivered only if an account that existed when the job was queued still
    holds that address (erasure replaces it, so an erased person's job finds
    none, and an address registered again since belongs to somebody else),
    and the address, title, actor name and excerpt or note are dropped from
    its row when it finishes and by `KilnCMS.Jobs.PrivateArgsScrub`. Such a
    job carries the actor's name rather than their id, so it still says the
    name of an actor erased since.
  - `KilnCMS.SentryFilter` drops those keys, and every stack frame's
    variables, from Sentry events of both workers.
  - Erasure now strips `to` from every finished (completed, canceled,
    discarded) job on the `mail` queue addressed to the erased account,
    account mail included (`KilnCMS.Mail.forget_recipient/2`). The delivery
    panels list such a failure under the domain "unknown".

  Account mail (sign-in alerts, second-factor notices, registration mail,
  security alerts) waiting to run when the person is erased is covered by
  the Fixed entry *Account mail queued before an erasure is no longer sent
  to the erased person*
  ([#3035](https://github.com/The-Verscienta/kiln_cms/issues/3035)).
  Whether the recipient is still who the event is for, and whether the
  address is on a suppression list, is checked when the mail is sent too:
  see the Fixed entry *Workflow and task mail re-checks each event's own
  rule when it sends*
  ([#3037](https://github.com/The-Verscienta/kiln_cms/issues/3037)) and the
  Changed entry *Workflow and task mail is not sent to an address on the
  instance suppression list*. See
  [Job args retention](../data-flows.md#job-args-retention) and
  [What erasure does not reach](../data-flows.md#what-erasure-does-not-reach).
  ([#3019](https://github.com/The-Verscienta/kiln_cms/issues/3019))

<a id="account-mail-erased-recipient"></a>

- **Account mail queued before an erasure is no longer sent to the erased person: each job names its account and is sent only while that account still holds the address, and erasure withholds the account's mail still waiting.**
  Account mail (password resets, magic links to an account, confirmations,
  sign-in unlock links, "you were added to a site" notices, registration
  notices and decisions, second-factor notices, sign-in alerts, security
  alerts and API key reuse alerts) carried only the address. A job still
  waiting or retrying when the person was erased (a mail job can retry for
  about 15 hours) was sent to their real address.

  - `KilnCMS.Mail.enqueue!/2` takes `user_id:`, and every job it queues now
    writes a `"user_id"` key: the account's id for account mail, `null` for
    mail to an address with no account behind it (site invitations,
    newsletter confirmations, a magic link to a bare address). `user_id:`
    with more than one `to` raises `ArgumentError`.
  - `KilnCMS.Mail.DeliveryWorker` reads the account when it runs
    (`KilnCMS.Accounts.mail_recipient/1`) and sends only while it exists, is
    not erased, and holds the address the job is addressed to (compared
    case-insensitively), so mail queued to an address the account has
    changed since is not sent either. Otherwise it drops the address and the
    message from the row (`KilnCMS.Mail.forget_message/1`), logs one `info`
    line with the job id and the reason (`erased`, `no_account`,
    `no_address`, `address_mismatch`), never the address, and completes the
    job: it is not a delivery failure on `/editor/mail`. An account that
    cannot be read fails the attempt, which retries; the last one drops the
    message first.
  - Erasure withholds every account mail job for the account that has not
    finished, a running one included (`KilnCMS.Mail.withhold_pending/2`): the
    job loses its address and message, gains `"withheld": "erased"`, and
    completes unsent when it runs. A job queued afterwards from a request
    that read the old address is stopped by the check when it runs. Finished
    jobs lose their `to` by account as well as by address
    (`KilnCMS.Mail.forget_recipient/2`).
  - Jobs queued by v1.10.x have no `"user_id"` key and are sent as before.
    For this release, erasure also withholds those not yet finished that are
    addressed to the erased address, whoever they were for, which includes
    an invitation or newsletter confirmation of the old shape to that
    address.

  Not covered: a job already running when the erasure commits can still
  deliver; during a rolling deploy, nodes of the previous release send
  without the check (see the Upgrade notes entry); and mail to an address
  that is not account mail (an invitation, a newsletter confirmation, a
  magic link to a bare address) is neither checked when it is sent nor
  withheld by erasure, as erasure keeps a newsletter row at the address that
  was never linked to the account. See
  [Account mail still waiting to run](../data-flows.md#account-mail-still-waiting-to-run)
  and
  [What erasure does not reach](../data-flows.md#what-erasure-does-not-reach).
  ([#3035](https://github.com/The-Verscienta/kiln_cms/issues/3035))

<a id="workflow-task-mail-event-rule"></a>

- **Workflow and task mail re-checks each event's own rule when it sends, so mail queued for someone who is no longer who the event is for is not sent, and a task digest lists only the tasks still open and assigned to its reader.**
  The recipients of a workflow mail are chosen when the event happens. The
  job could then wait or retry for up to about 15 hours, and was sent even
  if the reason for choosing that person no longer held. Each job now asks
  the rule that chose its recipient again, through the same function, when
  it runs:

  - **Review requested**: the recipient must still be an admin of the site:
    a member admin, a platform admin, or someone with a live temporary admin
    grant (`KilnCMS.Accounts.Scoping.has_tier?/3`). A grant that has expired,
    a demotion, or removal from the site stops it.
  - **Published**, **Returned to draft**: the recipient must still be the
    content's author. After the content is reassigned, the old author is
    not mailed.
  - **Comment added**, **Comment resolved**: the recipient must still have a
    comment on the comment's thread, or be the content's author
    (`KilnCMS.Notifications.comment_audience_ids/2`).
  - **Mentioned**: the recipient must still be on the site's mention roster
    (an active member, or an account with no site memberships at all;
    `KilnCMS.Notifications.mention_roster_member?/2`), or still on the
    comment's thread or the author, since a mention replaces the thread
    notice they would otherwise have had.
  - **Task assigned**: unchanged since #3019. The task must still be open
    and assigned to the recipient.
  - **Task digest**: each line now names its task (`task_id`), and the
    worker reads the reader's open tasks once when it runs. It lists only
    the lines whose task is still open and still theirs, with each task's
    due date now; the subject and body count the lines it lists. A digest
    with no line left is not sent.

  A mail stopped by its rule completes its job and logs one `info` line
  with the job id and a reason (`not_an_admin`, `not_the_author`,
  `not_on_the_thread`, `not_on_the_roster`, `task_gone`, `no_open_tasks`),
  never the address; it is not a delivery failure on `/editor/mail`. A read
  that fails fails the job, which retries.

  Jobs queued by v1.10.1 carry the recipient's address instead of an id.
  For those, review requests and mentions are checked against the site
  they name, published and returned-to-draft mail against the content's
  author, and a task assignment against its task. A digest of that shape
  lists only the lines on content where an open task of the reader's still
  is. A comment-added or comment-resolved job of that shape is sent
  unchecked: it names the content by the mail's type name, which is not
  always the thread's own, and has no comment id, so its thread cannot be
  found reliably. Jobs of that shape run or are discarded within about a
  day of the upgrade (eight attempts, the last about 15 hours after the
  first).

  The rule checked is each event's own, and no other. Being removed from a
  site stops a review request, but not a comment notice to someone still on
  the thread, a notice to the content's author, or task mail to the
  assignee
  ([#3048](https://github.com/The-Verscienta/kiln_cms/issues/3048)).
  Someone removed from the only site they belonged to has no membership
  left, which the mention roster reads as "on every site", so a mention of
  them is still sent
  ([#3047](https://github.com/The-Verscienta/kiln_cms/issues/3047)).

  The mention roster (who an `@` mention can name, in the editor's
  suggestions and in the notices) no longer lists every account when the
  read of who belongs to which site fails: it is then empty, as on any
  other failed read, so a mention written at that moment notifies nobody.
  No migration.
  ([#3037](https://github.com/The-Verscienta/kiln_cms/issues/3037))

<a id="data-flows-personal-data-rows"></a>

- **Docs: the data-flows guide lists the personal data held outside accounts, with retention and erasure for each, and what erasure does not reach.**
  `docs/data-flows.md` said the only personal data Kiln stores is account
  data and auth tokens, and its table had no row for form submissions, the
  two mail suppression lists, fediverse followers, the fediverse and webhook
  delivery logs or queued jobs, so a records-of-processing or DPIA built
  from it missed them. Each now has a row: what is stored, how long it is
  kept, how it is removed, what erasure does to it and what the staging
  scrub does. The newsletter row gains its retention (none: unsubscribed and
  never-confirmed rows are kept until a site admin deletes them). The
  retention table gains the spam submission prune, the webhook ledger prune
  and its retraction payload scrub, and the fediverse ledger prune, and says
  which personal data is on no schedule. The webhook ledger's 30 days and
  the spam submissions' 30 days are compile-time settings
  (`config :kiln_cms, :webhooks, delivery_retention_days:`,
  `config :kiln_cms, :forms, spam_retention_days:`): changing either needs a
  rebuild, and neither has an environment variable. A new section,
  [What erasure does not reach](../data-flows.md#what-erasure-does-not-reach),
  lists form submissions, suppression entries, webhook payloads, account
  mail already queued and backups. No code change.
  ([#2978](https://github.com/The-Verscienta/kiln_cms/issues/2978))

<a id="erasure-refuses-platform-role"></a>

- **An erased account can no longer be given a platform role, temporary role or audiences, and is left out of the legacy-audiences report and its boot job.**
  `User.:manage_access` (**Save access** on `/editor/accounts/:id`,
  `Accounts.manage_user_access/3`) and `User.:grant_temporary_role`
  (**Grant** and **End it now**, `Accounts.grant_user_temporary_role/3`)
  accepted an erased account, so a platform admin could put a tombstone back
  on the admin and editor rosters erasure took it off. Both now refuse it,
  granting and revoking alike, with `KilnCMS.Accounts.Errors.AccountErased`
  ("belongs to an account that was erased"), which the Accounts console
  shows as the error; nothing is written. Demoting an admin takes the
  bootstrap lock and then the account's row, the order erasing an admin
  takes them in, so a demotion racing that admin's erasure waits rather than
  deadlocking.

  `User.:legacy_audience_accounts` now leaves erased accounts out, so
  `mix kiln.deprecations` no longer lists one and
  `KilnCMS.Accounts.LegacyAudiencesWorker` no longer tries to move one onto a
  membership. That move would be refused, and the job would fail on it
  every boot. No migration. See
  [docs/account-administration.md](../account-administration.md#removing-an-account).
  ([#3010](https://github.com/The-Verscienta/kiln_cms/issues/3010))

<a id="export-lists-site-memberships"></a>

- **Export my data now lists the account's site memberships, in any status, with what each grants.**
  The data-subject export (**Export my data** on `/account` and
  `/editor/settings`, `KilnCMS.Accounts.export_user_data/1`) left out the
  account's site memberships, which are data about the person: which sites
  they belong to, or applied to, and with what access. It gains
  `site_memberships`, one entry per membership on every site, oldest first,
  including pending and rejected registrations: `org_id`, `site` (the site's
  name), `status`, `role`, `granted_role`, `granted_role_expires_at`,
  `audiences`, `editable_types`, `readable_types`, `field_grants`,
  `field_read_grants`, `inserted_at` and `decided_at`. A membership's custom
  role is not included yet. If the memberships can't be read, the section is
  empty and the failure is logged as an error; if only the site names
  can't, the rows go out with `site` as `null`. No migration. See
  [docs/data-flows.md](../data-flows.md#subject-rights-workflows).
  ([#3010](https://github.com/The-Verscienta/kiln_cms/issues/3010))

<a id="backup-url-ecto-query-params"></a>

- **The backup tools accept an `ecto://` URL with Ecto's own query parameters: `ssl=false` becomes `sslmode=disable`, and `pool_size`, `timeout` and `idle_interval` are left out.**
  Since #2719 the URL reached libpq with its query as written, and libpq
  refuses a parameter it doesn't know by name
  (`invalid URI query parameter: "pool_size"`), so an app `DATABASE_URL`
  with any of them failed every in-app backup until `BACKUP_DATABASE_URL`
  was set. `KilnCMS.Backups.PgUrl.normalize/1` and `pg_conn_split` in
  `backup.sh`, `restore.sh` and `staging.sh` now translate the parameters
  Ecto itself defines, matching keys and values after percent-decoding:
  `ssl=false` becomes `sslmode=disable` in place (Ecto reads it as "no
  TLS" for the app's connection, so the tools connect the same way), and
  the three pool options are dropped. Everything else is kept: `ssl=true`
  (libpq reads it as `sslmode=require`), and options libpq still refuses
  by name, such as `ssl=1` and `socket_dir`, which changes which server is
  reached and so can't be dropped safely. Only the URL given to the tools
  changes: the URL `restore.sh drill` and `staging.sh up` print, and the one
  `staging.sh` hands to migrate and scrub, keep the query as written. A
  `POSTGRES://` or `PostgreSQL://` scheme is lower-cased, since libpq
  reads only lower case as a URL. See
  [Which database URL the backup tools accept](../backups.md#which-database-url-the-backup-tools-accept-2719).
  ([#2833](https://github.com/The-Verscienta/kiln_cms/issues/2833))

<a id="backup-pg-dump-lock-wait"></a>

- **A database dump stuck behind a table lock now gives up after `BACKUP_LOCK_WAIT_SECONDS` (default 600) and says so, instead of waiting forever in cron or for two hours in the app.**
  Neither path passed `--lock-wait-timeout`, so a dump that started while a
  migration or `VACUUM FULL` held an `ACCESS EXCLUSIVE` lock waited as long
  as the lock did. The in-app backup, `scripts/backup.sh` and the demo
  golden capture now pass `--lock-wait-timeout=<ms>` from
  `BACKUP_LOCK_WAIT_SECONDS`: a whole number of seconds from 1 to 3600,
  below the backup step's 2-hour job timeout; anything else, `0` included
  (pg_dump reads `0` as "wait forever"), keeps 600 and warns, at boot and
  on the script's stderr. pg_dump applies it to each `LOCK TABLE`, so a
  dump blocked on several tables can wait several times the value.
  `pg_restore`, `psql` and `staging.sh` don't take it. pg_dump reports the
  timeout as a statement timeout on `LOCK TABLE`, so the run or manifest
  error now reads "pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS
  (600 s) for a table lock and gave up: …", followed by pg_dump's own
  lines. A failed `pg_dump` under cron also records its last lines of
  stderr (a URL password of 6 or more characters replaced with `***`, cut
  to 500 characters) in the failure manifest, where it used to record only
  `backup.sh exited <status> - see the backup log`. See
  [When pg_dump waits for a table lock](../backups.md#when-pg_dump-waits-for-a-table-lock-2844).
  ([#2844](https://github.com/The-Verscienta/kiln_cms/issues/2844))

<a id="backup-manifest-temp-names"></a>

- **A cron `backup.sh` and an in-app backup finishing together can no longer publish a mixed `manifest.json`: each writer now writes it through a temporary name of its own.**
  Both used to write `manifest.json.partial` and rename it, so two writers
  could interleave in one file, publish a truncated or mixed manifest, or
  fail a rename the other had already made. Now `backup.sh` writes
  `manifest.json.<pid>-<random>.partial` (random between 100000 and 132767,
  created only if the name is free, another number tried if not), an
  in-app step `manifest.json.<job>-<attempt>.partial` as before, and the
  app's manifest for an interrupted backup recorded from outside its step
  `manifest.json.<random digits>.partial`. `manifest.json` is always the
  complete file of whichever renamed last. A leftover older than 60 minutes
  is removed by the start of the next in-app backup and by `backup.sh
  prune`; the plain `manifest.json.partial` of an older `backup.sh` is
  removed by neither. See
  [Temporary files and the trash directories](../backups.md#temporary-files-and-the-trash-directories)
  and the amendment to
  [ADR 0067](../decisions/0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md).
  ([#2832](https://github.com/The-Verscienta/kiln_cms/issues/2832))

<a id="backup-sh-orphaned-child"></a>

- **A `pg_dump`, `tar` or `rclone` left running by a `backup.sh` killed with `kill -9` (or the OOM killer) is now stopped within 5 minutes, instead of running on and writing to a file `prune` may already have deleted.**
  No trap runs on `SIGKILL`, so the child was adopted by init and kept
  writing a `.partial` that nothing kept fresh; after 12 hours `prune`
  deleted it and the child went on filling disk through the deleted file
  until it ended. The script's heartbeat loop, which already outlives it,
  now records which program the run is running (in a file under `TMPDIR`)
  and, within one 5-minute beat of the script being certainly gone, sends
  it `TERM`, then `KILL` about 5 seconds later. It acts only on a process
  that still runs the same program and has the loop's own parent, so a PID
  reused by an unrelated process is left alone; it reads both with `ps`, or
  from `/proc` where `ps` has no `-p`, and goes by the PID alone where
  neither works. Not covered: a child started in the instant before the
  kill, the untracked `head | gzip` of an empty media part and the
  read-only helpers, and every child when the record in `TMPDIR` could not
  be created (the run warns). See
  [When a cron run is killed outright](../backups.md#when-a-cron-run-is-killed-outright-2478).
  ([#2847](https://github.com/The-Verscienta/kiln_cms/issues/2847))

<a id="restore-db-verifies-checksum"></a>

- **`restore.sh db` and `restore.sh drill` check the dump against its `kiln-db-<stamp>.sha256` sidecar before they touch the database, and refuse a dump that doesn't match.**
  Only `restore.sh media` read its sidecar, so a truncated or altered dump
  was restored unchecked. Now, before the confirmation prompt, `createdb`
  and `pg_restore`, both commands print `==> Verifying checksum from
  kiln-db-<stamp>.sha256` and run `sha256sum -c` (or `shasum -a 256 -c`).
  The sidecar must be well formed and list exactly the dump. A mismatch
  stops with "checksum verification FAILED for kiln-db-<stamp>.dump —
  nothing was restored". A dump with no sidecar, or not named
  `kiln-db-<stamp>.dump` (a symlink is not resolved), restores after a
  warning banner, or is refused under `RESTORE_REQUIRE_CHECKSUM=1` (see
  Upgrade notes). Both scripts also unset `CDPATH`, which made `cd` print
  the directory and corrupt the paths they compute. See
  [What can go wrong when restoring a dump](../backups.md#what-can-go-wrong-when-restoring-a-dump)
  and the amendment to
  [ADR 0035](../decisions/0035-the-per-stamp-sidecar-not-the-manifest-is-the-only-restore-time-checksum-authority.md).
  ([#2877](https://github.com/The-Verscienta/kiln_cms/issues/2877))

<a id="backup-self-fence-watchdog"></a>

- **A node whose heartbeat is stuck on a hung `BACKUP_DIR` now still stops its own backup steps at 90 seconds, and the backup-directory id read can no longer hold up a beat.**
  Since #2789 every beat reads (and with the last-good marker sync on, may
  create) `.kiln-dir-id`. On a hard-mounted NFS export that hangs, that read
  blocked the heartbeat, and with it the self-fence, while the other nodes
  still took the step back at 180 seconds: two nodes could write the same
  backup. Now a watchdog process, `KilnCMS.Backups.Fence`, which does no
  file or database work, checks every 5 seconds and kills this node's
  registered steps once the last successful beat is 90 seconds old. It
  starts with the heartbeat (`heartbeat?: true`). It counts from the end of
  the last successful beat, so a heartbeat round that is only slow (about a
  minute of beat, sweep and prune) also stops this node's steps; a restarted
  watchdog counts from its own start. The id read runs in a supervised task
  (`KilnCMS.Backups.DirIdReaders`, at most four at a time) that the beat
  waits on for 5 seconds (`config :kiln_cms, KilnCMS.Backups,
  dir_id_timeout_ms:`). While it is held up, each beat reports no id, so the
  marker sync stops routing to that node; the log warns once per stall and
  says when it clears, and each held-up beat emits
  `[:kiln_cms, :backups, :heartbeat, :dir_id_timeout]` (measurements
  `count`, `waited_ms`; metadata `node`). A read that crashes is logged and
  the beat still goes out. See
  [The backup-directory id read](../backups.md#the-backup-directory-id-read-2848),
  [Several nodes and the backup lock](../backups.md#several-nodes-and-the-backup-lock)
  and the amendment to
  [ADR 0039](../decisions/0039-a-backup-steps-node-is-judged-by-a-heartbeat-on-the-database-clock-and-a-superseded-step-is-fenced.md).
  ([#2848](https://github.com/The-Verscienta/kiln_cms/issues/2848))

<a id="backup-dir-id-temp-sweep"></a>

- **A `.kiln-dir-id.<uuid>.tmp` left in `BACKUP_DIR` by a node stopped while it published the directory id is now removed once it is an hour old.**
  The app writes the id to that temporary file, links it to `.kiln-dir-id`
  and removes it; a node killed in between left it for good. The start of
  every in-app backup and `backup.sh prune` (which prints each one it
  removes) now remove such files older than 60 minutes, regular files with
  exactly that name only. `prune` covers hosts that back up only with cron
  and still get the file from an app node's heartbeat. See
  [Temporary files and the trash directories](../backups.md#temporary-files-and-the-trash-directories).
  ([#2849](https://github.com/The-Verscienta/kiln_cms/issues/2849))

<a id="av-strip-transient-read-retries"></a>

- **A deferred A/V metadata strip that can't read the private upload because of a passing fault (an object-store timeout or `5xx`, a full temp disk) now retries, instead of leaving a good upload for the quarantine reaper to delete. The reaper and a refused strip now purge the row before deleting its private file.**
  Applies under `KILN_AV_STRIP_MODE=deferred`. `KilnCMS.Media.AVStripWorker`
  treated every failed read of the quarantined upload, other than an
  unresolvable site store, as "the file is not there": it logged
  "private blob unreadable", completed the job, and left the row
  quarantined. Twenty-four hours later (`KILN_MEDIA_QUARANTINE_MAX_AGE_HOURS`)
  `KilnCMS.Media.QuarantineReaper` deleted the file and the row, so one S3
  timeout cost the editor the upload. Now only an answer that means the file
  is definitely missing (`:enoent`, `:not_found`, an HTTP `404`) completes
  the job that way. Any other read error fails the job, which Oban retries
  up to 5 attempts with backoff, logging
  "could not read its private blob (…); will retry." If every attempt fails,
  the reaper removes the row after its window, as before. An S3 bucket that
  answers `403` for a missing key (credentials without `s3:ListBucket`)
  retries too, then ends with the reaper. Uploads already reaped this way
  can't be recovered; upload the file again.

  The reaper and the strip's refusal under `REQUIRE_AV_METADATA_STRIP=true`
  used to delete the private file first and then purge the row. Both now
  purge first and delete the file only when the purge succeeds, as
  **Delete permanently** in the media trash does. A purge that fails keeps the file with
  its row and logs "…; its private blob is kept." For a refusal the job
  also fails, so Oban redoes the refusal within minutes, where before a
  failed purge left a quarantined row with no file until the reaper took
  it. If the file delete fails after a successful purge, nothing sweeps the
  leftover file: the log line "Reaped media <id> left its private blob
  <key> behind" (or "Purged media …" for a refusal) names the key so you
  can remove it from the private bucket.

  This also resolves the 1.10.0 known issue "a quarantined upload released
  while the quarantine reaper sweeps can stay in the library without its
  original file". On a closer reading that state could not occur: only the
  strip job releases a quarantine, after it has stored the stripped copy at
  the public key, and it deletes the private file itself right after. A
  reaper deleting the private file during that release removed a file
  the released item no longer used. No item needs repair. The change in
  order matters for the failure cases above.

  No migration or configuration change; rolling back is safe.
  ([#2723](https://github.com/The-Verscienta/kiln_cms/issues/2723),
  [#2835](https://github.com/The-Verscienta/kiln_cms/issues/2835))

<a id="release-transitions-on-the-row"></a>

- **Every release transition now checks the release's state in its own `UPDATE`, so a release page or calendar held open while the release moved can no longer write over it.**
  `:schedule`, `:unschedule`, `:reopen`, `:archive`, delete, and the
  worker's `:mark_published`, `:mark_failed`, `:mark_rolled_back` and
  `:mark_rollback_failed` judged only the copy of the release the caller had
  read. A release page loaded while the release was scheduled could, after
  the cron had published it, press **Schedule** with a new date: the release
  went back to scheduled, the cron shipped it again, and subscribers got a
  second `release.published`. A stale page could also unschedule or archive
  a release a worker had claimed, reopen one a retry had already restarted,
  or delete a published release, and with it the items rollback restores
  from. Each of these writes now lands only while the row is in a state the
  transition starts from (delete: not `publishing` or `rolling_back`, and
  never published).

  On the release page a refused **Schedule**, **Remove schedule**,
  **Publish now**, **Roll back**, **Reopen for editing**, **Release a stuck
  claim**, **Archive** or **Delete** reloads the release and says "This
  release changed since you opened it. It's been reloaded." instead of
  "That didn't work — try again." Dragging a release's go-live chip on the
  calendar shows the same message instead of the raw state-machine error. A
  release deleted meanwhile shows "That release no longer exists." and
  returns to the list.

  Two races with the go-live itself are closed too:
  - The minute cron claims through a new action, `:start_scheduled` (code
    interface `CMS.start_scheduled_release`), filtered on the `:go_live`
    trigger's `where`. Removing the schedule or moving it to a later date
    while the cron is claiming the release now wins: AshOban cancels the job
    and nothing ships. **Publish now** still claims through `:start`. No
    policy admits a person to `:start_scheduled`, admins included.
  - **Release a stuck claim** pressed while the go-live is in fact still
    running now wins as well: the go-live rolls back, nothing ships, the
    release stays failed, and `release.failed` is sent once. The worker's
    "could not record the publish failure" line, logged at error before, is
    now an info line saying the release was abandoned while the worker ran.

  For overlay and plugin code, `KilnCMS.CMS.Releases.stale?/1` says whether
  a release or item write was refused because someone else moved the
  release: re-read it rather than retry. No migration; rolling back is safe.
  See [When the page is out of date](../content-releases.md#when-the-page-is-out-of-date).
  Fixes #2745.

<a id="release-items-during-go-live"></a>

- **An item added to a release just as its go-live started is refused, instead of being left pending on the published release, where it held its content against every other release.**
  Adding an item checked that the release was still open with an unlocked
  read, and the go-live worker reads its item list once. An add that read
  `open` just before the claim committed inserted an item the worker never
  saw: the release published without it, and the item stayed `pending`,
  keeping its record out of every other release with no button that could
  remove it. Adding, removing and changing an item now read the release
  inside the item write's own transaction, `FOR SHARE`, so they wait for a
  claim in progress. An item that commits before the claim is published with
  the release; one checked after it is refused with "release is no longer
  open for changes". The content editor's **Release** panel shows that
  reason and redraws, the content list's bulk **Add to release** counts the
  record as skipped, and the release page reloads with "This release changed
  since you opened it. It's been reloaded."

  As a backstop, the go-live re-lists the pending items before it marks the
  release published. If one it never read is there, the release fails and
  nothing changes, with the reason "1 item(s) were added after this go-live
  read its list; nothing was changed. Reopen the release and publish it
  again." The worker also applies or skips only an item that is still
  pending. The lock itself is not exercised by the test suite, which shares
  one database connection; the tests cover the re-check.

  An item stranded this way before this release stays `pending` on its
  published release. Archiving that release frees it, but also ends the
  release's group rollback. No migration; rolling back is safe. Fixes #2740.

<a id="scheduled-content-on-the-row"></a>

- **A scheduled publish, unpublish or archive does nothing when the record was archived, published, rescheduled or given a new expiry action as the job fired. It used to overwrite that change.**
  The minute cron's job reads a due record, then runs the publish checks
  (required fields, alt text, consent, the collaborative-editing checkpoint)
  before it writes. Anyone who acted on the record in that window was
  overwritten: an archived page went live, a page published by hand was
  published a second time, a page moved to tomorrow went live today, and a
  page whose embargo end had been extended, or whose expiry action had been
  switched to `:flag`, was taken down anyway. Each scheduled action's
  `UPDATE` now carries its trigger's condition, as the manual `:publish` has
  since #879, so it lands only on a record that is still due. Otherwise
  AshOban cancels the job and nothing fires: no webhooks, artifact renders
  or emails, and the new date or expiry action stays. Calling these actions
  directly on a record that isn't due is now refused; see
  [Breaking](#scheduled-content-actions-due-only). No migration; rolling
  back is safe. See
  [Content lifecycles](../content-lifecycles.md#expiry-one-timestamp-three-outcomes).
  Fixes #2746.

<a id="backup-resume-source-host-first"></a>

- **A resume no longer runs from a copy of the backup's files on another host while the host that holds the run's backup directory is alive. The copy resumes once that host has stopped beating for 180 seconds.**
  Each backup run records the id of its backup directory (`.kiln-dir-id`,
  #2539). A resume's `start` used to run on any node that had
  `.work/<stamp>/state.json` itself, before it looked at that id. So with a
  `BACKUP_DIR` per host, a copy of a host's directory (restored, cloned, or
  rsynced with `--exclude .kiln-dir-id`, as the docs recommend) took the
  resume while the source host was still running, and the two directories
  went on to hold the same backup.

  Now the node that reads the run's recorded id comes first, files or not.
  A node with its own copy resumes only when no live node, one with a
  heartbeat in the last 180 seconds (`Chain.stale_after_s/0`, the backup
  lock's own threshold for a stopped node), reports that id. Otherwise it
  puts the start back, within the usual budget (20 snoozes of 30 seconds per
  attempt, four attempts). A copy that resumes records its own directory as
  the run's `dir_id`, and the backup's later steps run there.

  - **While the source host is alive, the copy waits.** If the source host's
    `.work/<stamp>/` is gone, the resume is refused there, visibly: "Resume
    refused: its work files (.work/`<stamp>`/state.json) are not on the
    server that picked it up". To resume from the copy, stop the app on the
    source host; the copy takes the start 180 seconds after its last beat.
  - **A stuck id read still counts as alive.** While a hung mount holds up a
    host's `.kiln-dir-id` read, its beats report no `dir_id` (#2848). Each
    beat now also reports `last_dir_id`, the id its last answered read gave,
    kept through a held-up, crashed or busy read and cleared by a read that
    finds no id file. A resume's start counts either one; the last-good
    marker sync still routes by `dir_id` only. Known limit: a host that
    restarts and whose first read hangs reports neither, so a copy can resume
    beside it.
  - **It fails closed.** If the heartbeats can't be read, a node with a copy
    puts the start back and logs "Backup resume of `<stamp>`: couldn't read
    the node heartbeats (…); waiting for the server with its backup
    directory (id `<id>`) rather than resuming from the files here". If the
    run itself can't be read, a node with a copy puts the start back too
    ("…couldn't read where its files are (…); waiting rather than resuming
    from the files here"), and each attempt that spends its snoozes fails
    with `:run_unreadable`. Before, both cases resumed from the copy. A node
    with no copy still starts it and refuses on the missing files. A
    `state.json` that can't be parsed counts as no copy.
  - **Why 180 seconds and not the marker sync's 600.** The last-good marker
    sync routes to every directory reported in the last 10 minutes, because
    a host that missed a few beats is still worth a sync job that waits for
    it. A resume asks whether the source host may still write its copy of
    the backup, and the lock already treats a node silent for 180 seconds as
    stopped and takes its step back.

  On a single shared volume, where every node reads the same id, nothing
  changes. See
  [Several nodes and the backup lock](../backups.md#several-nodes-and-the-backup-lock)
  and the amendment to
  [ADR 0040](../decisions/0040-a-backup-chain-runs-where-its-backup-directory-is-routed-by-kiln-dir-id-with-a-bounded-snooze.md).
  ([#2817](https://github.com/The-Verscienta/kiln_cms/issues/2817))

<a id="backup-marker-sync-hung-dir"></a>

- **A last-good marker sync job on a node whose `BACKUP_DIR` hangs gives up after a bounded wait instead of holding an Oban worker for as long as the mount hangs.**
  The job reads the directory's id, then syncs its markers. On a
  hard-mounted NFS export that stopped answering, the read blocked the job,
  and with it one of the `default` queue's workers (10 by default), with no
  job timeout. #2848 stopped routing new jobs to such a node, but jobs
  already routed there, and the node's own scheduled job, still blocked.

  Now each piece of the job's directory I/O runs in a supervised task
  (`KilnCMS.Backups.MarkerSyncIO`) that the job waits on: up to 5 seconds
  for the id read (`dir_id_timeout_ms`, the heartbeat's setting) and up to
  120 seconds for the sync (the new `marker_sync_io_timeout_ms`), both under
  `config :kiln_cms, KilnCMS.Backups`. On a timeout the job logs a warning,
  emits `[:kiln_cms, :backups, :marker_sync, :timeout]` (measurements
  `count`, `waited_ms`; metadata `phase`, `:dir_id` or `:sync`) and fails
  with `{:error, :backup_dir_unresponsive}`. The task is left running, since
  a process blocked on a hung mount can't be killed, and if it finishes
  later a line at info says how long it took.

  - **A routed job whose id read times out snoozes**, as it does for any id
    that isn't its directory's, so another node with that directory can
    still take it.
  - **A scheduled job whose own id read times out** still queues the other
    directories' jobs, then fails without syncing its own.
  - **At most two abandoned tasks.** While two tasks a job gave up on are
    still running, a job starts no more directory I/O and fails with
    `{:error, :backup_dir_io_busy}`, so a mount that stays hung can't use
    up the VM's dirty I/O schedulers. Tasks a job is still waiting on never
    count.
  - **The job's timeout** is both waits plus 60 seconds (185 seconds by
    default).

  Known limit: a sync that blocks inside the backup lock's transaction keeps
  holding the cluster-wide lock and its database connection until the
  directory answers. No migration; rolling back is safe. See
  [The marker sync on a hung backup directory](../backups.md#the-marker-sync-on-a-hung-backup-directory-3079).
  ([#3079](https://github.com/The-Verscienta/kiln_cms/issues/3079))

<a id="backup-cron-app-parity"></a>

- **Cron and in-app backups that start in the same second no longer share a stamp (#2477).**
  Both writers use per-second stamps. An app schedule and a cron line set
  to the same minute could pick the same stamp; cron's cleanup of a failed
  run could then remove the app's files, and the importer folded cron's
  files into the app's Run. Now `backup.sh` claims its stamp with
  `mkdir $BACKUP_DIR/.claims/<stamp>`, which only one run can win, and
  treats a stamp as in use when it has `kiln-db-<stamp>.*` or
  `kiln-media-<stamp>.*` files, the app's `.work/<stamp>`, or a claim; it
  checks again after claiming and steps forward one second (up to 60) when
  the stamp is taken. It removes its claim when it ends. The app's start
  step makes `.work/<stamp>` first, before anything else, and its stamp
  choice skips stamps that have files or a cron claim. When the stamp
  moved, cron prints `Stamp <stamp> is already in use …; this run is
  <stamp>`, and the manifest's `stamp` can then differ from its
  `started_at`. When no stamp is free, the run fails under the stamp 60
  seconds on (or with none), so History still records it. A cron run and
  an app start within the same few milliseconds can still pick the same
  stamp. Separate `db` and `media` cron lines that start in the same second
  now produce two History rows one second apart. A run killed outright
  leaves an empty `.claims/<stamp>`, which only makes later runs skip that
  stamp and can be deleted.

  Also tested now on the cron side: a failed off-site copy of a part set's
  checksum sidecar fails the run, as it already did in the app.
  ([#2477](https://github.com/The-Verscienta/kiln_cms/issues/2477))

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

<a id="backup-pg-tools-tls"></a>

- **In-app backups and demo resets connect to the database with the app's TLS settings, so a dump no longer falls back to cleartext or skips the certificate check the app makes.**
  `pg_dump` and `psql` got only a URL, so libpq used its default
  `sslmode=prefer`: it silently drops to an unencrypted connection when TLS
  fails and never verifies the server, while the app requires TLS by
  default (`DATABASE_SSL`) and verifies against `DATABASE_SSL_CACERTFILE`
  when one is set. They now get `PGSSLMODE` (and `PGSSLROOTCERT`) derived
  from the Repo's effective `:ssl` option, in their own environment:
  nothing when TLS is off, `require` without a CA file, `verify-full` with
  the CA file as `PGSSLROOTCERT` with one, and `verify-full` against the
  system trust store (`PGSSLROOTCERT=system`, libpq 16 or later) for any
  other verifying configuration. An explicit choice wins, even a weaker
  one: `sslmode` or `requiressl` in the URL, or a non-blank `PGSSLMODE` in
  the app's environment. A root certificate alone (`sslrootcert=` or
  `PGSSLROOTCERT`) is kept but doesn't stop the mode being set, and
  Ecto's `ssl=true` in the URL is replaced by the mode when the app
  verifies the server, so it never makes the backup weaker than the app.
  `PGSSLMODE` and `PGSSLROOTCERT` are left out of the error redaction, so
  "SSL was required" stays readable. The scripts derive nothing: cron
  requires TLS with `sslmode` in its `DATABASE_URL`. See Upgrade notes and
  [How the backup tools choose TLS](../backups.md#how-the-backup-tools-choose-tls-2830).
  ([#2830](https://github.com/The-Verscienta/kiln_cms/issues/2830))

<a id="backup-conninfo-password-refused"></a>

- **A `key=value` database connection string that carries a password is refused, instead of putting the password in the command line of `pg_dump`, `pg_restore` or `psql`.**
  #2726 moved the password out of argv for URLs only; a libpq `key=value`
  string (`host=db password=… dbname=kiln`) went through unchanged, its
  password readable by every user on the host through `ps` and
  `/proc/<pid>/cmdline` for the whole dump. libpq's quoting, escapes and a
  `dbname` that expands into a URL make such a string unsafe to rewrite, so
  the app (`KilnCMS.Backups.PgUrl.split/1`, now
  `{:ok, {url, env}} | {:error, :refused_conninfo}`) and the three scripts
  refuse it when one of its keywords is `password` or `sslpassword`, or it
  holds `://` (another scheme, or a `dbname` libpq would expand). The
  error says how to write it as a URL and never contains the string. An
  in-app backup fails at once without retrying, a demo reset or golden
  capture fails with the same message, and each script stops before any
  tool runs. A passwordless `key=value` string and a bare database name
  pass through as before; `PASSWORD=` (libpq keywords are case-sensitive)
  is left to libpq, which refuses it by name without printing the value.
  For the release console, `KilnCMS.Backups.Worker.split_credentials/1`
  keeps its `{url, env}` return and raises `ArgumentError` on a refused
  string. See
  [Which database URL the backup tools accept](../backups.md#which-database-url-the-backup-tools-accept-2719).
  ([#2831](https://github.com/The-Verscienta/kiln_cms/issues/2831))

<a id="plug-multipart-framing-advisory"></a>

- **plug 1.20.4 fixes EEF-CVE-2026-120287: an unauthenticated multipart request made of empty parts or empty header lines no longer slips under the `:length` limit and holds many times its size in memory.**
  `Plug.Parsers.MULTIPART` charged its `:length` limit only with header
  names, header values and part bodies. Part delimiters, header framing
  and line endings cost nothing, and a part without a
  `content-disposition` header was kept until the whole body was read. A
  4.5 MB body of empty parts reached about 92 MiB in the parser process
  on 1.20.3, and with enough such requests at once a node runs out of
  memory. Kiln is exposed: the endpoint runs the multipart parser (through
  `KilnCMSWeb.Plugs.MultipartParser`) before authentication on every route
  except `POST /api/media`, which reads its body after authenticating.
  The advisory was published 2026-11-17 and affects plug 1.13.0 up to
  1.20.3. Lock-only: `mix deps.update plug`, which also moved telemetry
  1.4.2 → 1.4.3, in the core, `clients/elixir/kiln_client`,
  `examples/phoenix_showcase` and `sdk/fixtures/dep_plugin` lock files.
  The same change brings the plugin SDK's development lock files
  (`sdk/kiln_plugin` and `sdk/fixtures/dep_plugin`) to ash 3.37.6 and ecto
  3.14.3, clearing EEF-CVE-2026-96581, EEF-CVE-2026-114214 and
  EEF-CVE-2026-118391 from them; the core was already past all three. A
  library's lock file does not ship to its users, so only the SDK's own CI
  build ran the old versions.
  ([#3092](https://github.com/The-Verscienta/kiln_cms/pull/3092))
