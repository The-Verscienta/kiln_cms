# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Fixed

<a id="backup-heartbeat-lock-gaps"></a>

- **Heartbeat and lock gaps (#3078, #3091, #3095).**
  - **Recording an interrupted backup runs in the background.** When the
    heartbeat (or a backup request) took over a stopped node's backup, it
    recorded the failure and cleaned its work files in the heartbeat
    process; on a hung `BACKUP_DIR` that stopped this node beating. The
    lock is still released and the waiting request promoted at once; the
    run's record follows in a background task, one at a time, and the run
    reads Running until it lands.
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
