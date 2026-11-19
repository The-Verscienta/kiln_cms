# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

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

## Fixed

<a id="backup-destination-retention-gaps"></a>

- **Destination retention gaps (#2950).** Three changes:
  - **Opt-in pruning of `BACKUP_RCLONE_REMOTE`.** Set `BACKUP_RCLONE_REMOTE_PRUNE=true` and in-app backups prune the env remote by the same keep rules as `BACKUP_DIR`. They delete only backups that an in-app run of this backup directory sent there (`origin: app`, same `.kiln-dir-id`). Files from cron, from another directory and from other installations stay put. Pruning is refused, with a notice, while any stored destination could overlap the remote: one that overlaps it, an S3 destination, or a plugin destination whose location the app can't tell. Disabled rows count too. Cron never prunes the remote, so the flag does nothing on cron-only installs. ADR 0064 is amended.
  - **A time limit on each call.** Each retention list call (10 min) and delete call (60 s) has its own limit, as does each abort in the upload sweep (60 s). A slow store no longer uses up the whole step's deadline. A listing that times out skips retention for that destination; a delete that times out stops the pass and keeps the rest. A delete cut off at its limit may already have removed the file. The next pass sees it gone.
  - **One rule for the badge and the pass.** The Destinations tab shows "Prunes its old backups" only when pruning can actually run. Otherwise it shows "Not pruned: <reason>". The env card says whether pruning is on, or why it is blocked.

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
