# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

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

## Added

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

## Fixed

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
