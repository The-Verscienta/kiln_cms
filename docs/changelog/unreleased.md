# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="referrer-suppression-sweep"></a>

- **The wide search behind the referrer-suppression rule is now a test you can re-run (#3123).**
  The "no all-hidden breakdown leaves a category a single value" rule (#2981) was found by a search run outside the suite, so a change to `referrer_sources/0` or to `KilnCMS.Analytics.suppress_referrer_group/1` had nothing wide to re-check against. The search is now in `test/kiln_cms/analytics/referrer_suppression_test.exs` behind the `slow_sweep` tag, which the default suite excludes. Run it with `mix test --only slow_sweep test/kiln_cms/analytics/referrer_suppression_test.exs` after touching either. It covers thresholds 2 to 20 with four, five and six categories, bounded at view totals of 40, 30 and 20; the original hand search went to 50, and the committed one does not re-run totals above these bounds. A second test in the sweep checks that the criterion can fail (three categories at a threshold of 3 still do). To let the sweep vary the number of categories, `suppress_referrer_group/2` takes an explicit category list; `/1` is `/2` over `referrer_sources/0`, and a default-suite test pins that. Nothing published changes: the dashboard and the export still call `/1`, and no setting or output differs. Operators have nothing to do. The decision record for the rule (ADR 0075) is on a separate open pull request.

## Fixed

<a id="backup-s3-same-bucket-overlap"></a>

- **S3 destinations naming one bucket through different hosts (#3088).** Overlap between S3 destinations was compared by host, port and bucket. Two destinations reaching one bucket through different endpoint names each pruned it by their own keep rules, so one could delete a backup the other still counted on. Examples: `s3.amazonaws.com` and `s3.us-east-1.amazonaws.com`, R2 account and jurisdiction hosts, or a MinIO by name and by IP. Now two S3 destinations with the same bucket name and nested prefixes block pruning on both, whatever their host. Each row's badge reads "Not pruned: another S3 destination uses a bucket of the same name; the app can't tell whether it is the same store". Saving such a pair is still allowed; only an exact overlap is refused.

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

