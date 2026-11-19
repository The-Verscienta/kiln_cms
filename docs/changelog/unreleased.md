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

## Changed

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

## Fixed

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
