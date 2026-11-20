# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="backup-schedule-disk-warning"></a>

- **Schedule preview warns about runaway disk use (#2984).** A sub-daily schedule with a long `keep_days` can keep thousands of full backups. For example, every 2 hours for 60 days keeps 721 of each component. The preview now warns, without blocking the save, in two cases:
  - when it would keep more than about 500 backups of each component;
  - when the newest backup of each component it covers, times that count, is more than `BACKUP_DIR` has room for. Room is the free space, read with the same bounded `df` as the backup preflight, plus the finished backups already in `db/` and `media/`, which this schedule's retention can reuse. This check is skipped when `BACKUP_FREE_SPACE_CHECK=false`.

  The size warning gives the estimated total, the free space and the space held by existing backups. Backups kept by something else also count as room, so a nearly full disk can still go unwarned. `keep_days` has no cap, and media stays allowed in sub-daily schedules.

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

<a id="referrer-suppression-sweep"></a>

- **The wide search behind the referrer-suppression rule is now a test you can re-run (#3123).**
  The "no all-hidden breakdown leaves a category a single value" rule (#2981) was found by a search run outside the suite, so a change to `referrer_sources/0` or to `KilnCMS.Analytics.suppress_referrer_group/1` had nothing wide to re-check against. The search is now in `test/kiln_cms/analytics/referrer_suppression_test.exs` behind the `slow_sweep` tag, which the default suite excludes. Run it with `mix test --only slow_sweep test/kiln_cms/analytics/referrer_suppression_test.exs` after touching either. It covers thresholds 2 to 20 with four, five and six categories, bounded at view totals of 40, 30 and 20; the original hand search went to 50, and the committed one does not re-run totals above these bounds. A second test in the sweep checks that the criterion can fail (three categories at a threshold of 3 still do). To let the sweep vary the number of categories, `suppress_referrer_group/2` takes an explicit category list; `/1` is `/2` over `referrer_sources/0`, and a default-suite test pins that. Nothing published changes: the dashboard and the export still call `/1`, and no setting or output differs. Operators have nothing to do. The decision record for the rule (ADR 0075) is on a separate open pull request.

## Fixed

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
