# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="rollback-to-1-8-0-upgrade"></a>

- **Before rolling back to v1.8.0, delete the rows v1.8.0 cannot read (#2509).**
  Nothing to do when upgrading. v1.8.0 loads an atom column with
  `String.to_existing_atom/1` and fails the whole read on a value it does not
  know, and two columns gained values since:
  ```sql
  DELETE FROM notifications
  WHERE event IN ('registration_pending', 'security_alert', 'security_notice');
  DELETE FROM api_keys WHERE access = 'draft_write';
  ```
  Without the first, the bell, the inbox and "mark all read" fail on v1.8.0
  for everyone holding a registration notice or a
  [security alert](#security-alerts-upgrade). Draft-write keys stop working on
  v1.8.0 whatever you do (it has no such scope); left in place, the key's own
  lookup and the site's API keys page fail, so delete them and mint new ones
  after rolling forward. Never `UPDATE` them to `'read'`: that silently
  changes what a key someone already holds can do. Security events need
  nothing, since v1.8.0 has no security log. Field definitions of type
  `key_value` or `telephone` also break v1.8.0's reads, and deleting them
  loses data: check
  [#2605](https://github.com/The-Verscienta/kiln_cms/issues/2605) before
  rolling back if any site uses them. Details in
  [New values in an atom column](../releasing.md#new-values-in-an-atom-column).

<a id="security-alerts-upgrade"></a>

- **Run `mix ash.migrate` for security alerts (#2245). From the deploy on,
  each site's member admins get a bell notice and an email for every site
  alert kind except failed sign-ins, and every platform admin gets the
  platform's alerts, which can't be muted. Before rolling back past #2509,
  delete the new notifications (and, on a build with the security log, the
  new security event), or roll forward.**
  - **The migration.** `20261110145904_add_security_alerts`, additive: new
    tables `security_alert_dispatches` (the alert queue, pruned hourly) and
    `site_security_alerts` (one settings row per site, created on the first
    save), and `users.notify_on_security_alert` (`boolean NOT NULL DEFAULT
    true`). Nothing is backfilled, and nothing is alerted about events from
    before the deploy.
  - **Who starts getting mail.** A site's **member admins**: accounts whose
    active membership on the site is admin, standing or by a live temporary
    grant, and that are not platform admins. They get `new_admin`,
    `role_elevation`, `lockout`, `two_factor_disabled` and
    `sso_config_changed`; `failed_sign_ins` starts off. A site admin can turn
    any of them off on **Organization** → **Security alerts**, and each person
    can mute the email for themselves under **Your settings** → **Email
    notifications**. Platform admins get `new_admin` (platform level),
    `platform_role_changed`, `new_api_key` and `api_key_abuse`, by bell (in
    the default site) and email, with no setting and no mute: expect one
    email per new API key.
  - **A site with no member admins gets no bell or email for its site
    alerts.** On a single-site install run by a platform admin with no
    membership on the site, that is nobody; the Security alerts page warns
    about it. Give someone an admin membership on the site if you want them.
  - **The stolen-key email is now an alert.** A rotated-away API key
    presented again was a plain email to the platform admins; it is now the
    `api_key_abuse` platform alert and a new security event,
    `api_key_reuse_detected`. When the event can't be recorded, the old email
    is sent instead.
  - **Alert email uses the instance relay** (`KilnCMS.Mailer`), never a
    site's own SMTP relay, so check that the instance mailer delivers. It
    goes through the `mail` queue as usual. No new queue: delivery runs on
    `default`.
  - **`security` is now a reserved webhook namespace.** A new content type
    can't be named `security`. A dynamic content type already called
    `security` keeps working and can still be edited, but its events
    (`security.published`, …) now share the prefix with the alert events and
    are listed in the same `security` group on **Webhooks**: tell them apart
    by the full event name.
  - **During a rolling deploy.** Events handled by an older node raise no
    alert. An older node that has #2509 loads the new notifications as an
    unknown event: the bell shows the generic "Notification" line and links to
    `/editor/inbox`, and its security log shows `api_key_reuse_detected` as
    "Unrecognized event (api_key_reuse_detected)". Both read normally once
    every node runs this release.
  - **Before rolling back** to a build without #2509 (v1.8.0, or an earlier
    `main` pin), run in `psql` against the deployment's database:

    ```sql
    DELETE FROM notifications WHERE event IN ('security_alert', 'security_notice');
    ```

    For v1.8.0 this is part of the [one-time cleanup](#rollback-to-1-8-0-upgrade).
    If the build has the security log (#2441) but not #2509, also export what
    you need (**Download CSV** on `/editor/security-log`) and run:

    ```sql
    DELETE FROM security_events WHERE type = 'api_key_reuse_detected';
    ```

    A build that has #2509 needs neither. The new tables and column are
    ignored by an older release. Alert jobs already queued fail there as
    unknown workers until their attempts run out, which is harmless; alerts still queued
    when you roll forward again are sent if they are less than a day old.
  See also [the Added entry](#security-alerts).

<a id="render-etags-upgrade"></a>

- **Every fired-artifact `ETag` (`/api/content/…`, every surface) and every
  `ETag` on a page Kiln renders itself changes once on this deploy (#2463).**
  No migration and no setting. A CDN, browser or app that revalidates with
  `If-None-Match` gets one full `200` per URL instead of a `304`, then
  revalidates as before. Plan for that much extra origin traffic in the first
  cache window after the deploy (300 seconds for an artifact, 60 for a page).
  - **Artifacts:** the tag is now `W/"<id>-<locale>-<surface>-b<digest>"`
    (`-<variant id>` appended for an A/B arm), where the digest is of the
    body served. It used to end in the document's `updated_at` (and
    `-x<tag>` for an `?expand=` response). From now on it changes only when
    the bytes do, so a republish or re-fire that produced the same body keeps
    it. Treat the tag as opaque: a client that read the timestamp out of the
    old one gets none now.
  - **Pages:** the tag now names the running build as well, so it also
    changes on every later deploy whose code, dependencies or assets differ,
    and a rolling deploy flips it between old and new nodes until it
    finishes.
  - **Rolling back** is safe: the old release goes back to its own tags,
    which costs another one-time round of `200`s.

<a id="twitter-card-upgrade"></a>

- **Run `mix ash.migrate` for the new X (Twitter) username setting, and expect
  fired `json` artifacts to move to `format_version` 4 (#2258). On a large
  site, run `mix kiln.refire_all` after the deploy.**
  - **The migration.** `20261110041039_add_site_branding_twitter_site` adds a
    nullable `site_branding.twitter_site` (`text`). Additive and instant; no
    existing row changes, and nothing is set until a site admin saves one.
  - **Why the version moves.** The `json` artifact gains a `social` object
    that belongs on every published document, not only on ones edited after
    the deploy (the reason `robots` did not need a bump). Only a
    `format_version` bump makes existing artifacts converge.
  - **How existing artifacts converge.** An artifact older than v4 is re-fired
    in the background after the first read that misses the firing cache. That
    read, and cached reads for up to an hour, still serve the old body, and a
    document nobody reads is never re-fired. `mix kiln.refire_all` (on a
    release, `bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"`) re-fires every
    published document through the `firing` queue instead.
  - **What a re-fire doesn't reach.** A re-fire is not an edit, so:
    - an `/api/sync` mirror is not sent the document again; it keeps the body
      without `social` until the document is next edited, or until it runs a
      fresh `?initial=true` sync after the re-fire has finished;
    - a CDN or client that revalidates with `If-None-Match` gets `304` for the
      old artifact body, because the artifact `ETag` names the document's
      last edit, not the body
      ([#2463](https://github.com/The-Verscienta/kiln_cms/issues/2463));
      `?fields=` responses are unaffected (their `ETag` is a body digest);
    - Kiln's own HTML pages render the new tags at once, but their `ETag` also
      ignores the layout until the document is edited or a site setting that
      reaches `<head>` (such as Branding) is saved, so a revalidating CDN may
      hold the old `<head>` until then.
  - **Rolling back.** Safe. The older release ignores the column. It serves
    v4 artifacts as stored, `social` included, rather than downgrading them,
    and logs at most once a minute that an artifact is newer than the build;
    `mix kiln.refire_all` on the older release rewrites them in its own shape.

<a id="invitation-raise-tier-upgrade"></a>

- **After upgrading, check Team → Pending invitations on each site for
  members you demoted or removed while their invitation was still pending
  (#2452).** Accepting an invitation now raises a member who holds a lower
  tier on the site ([below](#invitation-raises-lower-membership)), and
  changing a member's tier or custom role, or removing them, now deletes their
  pending invitation there. A change made before this upgrade deleted
  nothing. So for up to 7 days after deploying (an invitation's lifetime), a
  link left pending for a member you demoted raises them back to the tier it
  names, where before it did nothing; a link left pending for a member you
  removed re-adds them, as it already did. Revoke any such invitation with the
  **×** on its row. Only instances that ran a build with site invitations
  (#2448) are affected; v1.8.0 has no invitations. No migration, and nothing is
  rewritten: an older build ignores the new behavior, and rolling the pin back
  is safe (an accept then leaves a lower membership as it is again; an
  invitation retired meanwhile stays deleted).

<a id="plugin-health-egress-upgrade"></a>

- **A new outbound request is on by default, and it is the first that tells
  a third party something about your installation: with a plugin from Hex
  installed, Kiln asks hex.pm about that plugin's package and version (#2244).
  If your deployment must not, set `KILN_PLUGIN_HEALTH_CHECK=false` before
  deploying.**
  - **What is sent.** When a platform admin opens **Operations → System**,
    opens **Security posture** with nothing cached, or selects **Check plugins
    now**: for each plugin locked from hex.pm, `GET
    https://hex.pm/api/packages/<name>` and
    `GET https://hex.pm/api/packages/<name>/releases/<version>`, with a bare
    `KilnCMS` user-agent. hex.pm sees the package names and versions together
    with your server's IP. One more GET goes to kilncms.dev's security
    notices feed (up to five pages), which carries nothing about the
    installation. The answer is cached on each node for 24 hours (15 minutes
    after a failure).
  - **Who is affected.** Only a deployment with a plugin from Hex, git or a
    path. One whose plugins are all built from `projects/`, or that has none,
    sends nothing new. hex.pm is asked only about plugins locked from hex.pm.
  - **Turning it off.** `KILN_PLUGIN_HEALTH_CHECK=false` turns the check off.
    If you already set `KILN_UPDATE_CHECK=false` for "no outbound requests",
    you need do nothing: the plugin check follows it while
    `KILN_PLUGIN_HEALTH_CHECK` is unset. To keep the Hex comparison but not
    ask kilncms.dev, set `KILN_SECURITY_NOTICES_URL=false`. A fork or a mirror
    (`KILN_UPDATE_REPO`, `KILN_UPDATE_RELEASES_URL`, or
    `KILN_UPDATE_FEED_URL=false`) asks no notices feed unless
    `KILN_SECURITY_NOTICES_URL` names one.
  - **Firewalls.** A server that can't reach `hex.pm` or `kilncms.dev` shows
    its plugins as **Unknown** and the Security posture line as **Unknown**;
    nothing else changes. A notices mirror on a private address is refused
    by Kiln's outbound guard, with the same result.
  - **No migration**, nothing stored. Rolling the pin back is safe.
  See [the Added entry](#plugin-health-checks),
  [data flows](../data-flows.md) and
  [the variables](../environment-variables.md#plugin-health-check-2244).

<a id="backup-step-chain-upgrade"></a>

- **Run `mix ash.migrate` for the backup step chain (#2218, last part). In-app
  backups now run on a new Oban queue, `backup_steps`. Don't start a backup
  from a node still on the older release during the deploy, and before rolling
  back, cancel any running backup and relabel `canceled` runs, or roll
  forward.**
  - **What the migration does.** `20261109234923_backup_step_chain` creates
    `backup_locks` (the cluster-wide backup lock, one row) and
    `backup_node_beats` (one heartbeat row per node), adds a nullable
    `backup_runs.chain_id`, and widens the `backup_runs_status_must_be_known`
    check to admit `canceled`. Additive; no existing row changes.
  - **A new queue.** `backup_steps` runs one step at a time on each node (the
    lock makes it one per cluster). If you size `POOL_SIZE` as the sum of
    queue limits plus web traffic, add one. If your deployment builds Oban's
    `queues:` list itself instead of merging into Kiln's, add
    `backup_steps: 1`: without it a backup request is accepted and its first
    step waits on a queue no node runs.
  - **The `backups` queue stays for this release.** It now only runs jobs an
    older node enqueued, and each one becomes an ordinary backup request
    (it queues behind a running backup, like any other). The queue and
    `KilnCMS.Backups.Worker` are removed in the next minor release: before
    upgrading to it, check that this returns 0:

    ```sql
    SELECT count(*) FROM oban_jobs
    WHERE queue = 'backups' AND state IN ('available', 'scheduled', 'retryable', 'executing');
    ```

  - **Node names must be unique.** Each node's heartbeat is keyed by its Oban
    node name (the Erlang node name when distributed, else `DYNO`, else the
    hostname). Replicas sharing one name can take a running backup step away
    from each other; the log then says "Backup heartbeat: another node is
    beating as …".
  - **A new file in `BACKUP_DIR`.** `.kiln-dir-id` (mode 0600) ties a backup's
    steps to the host whose directory it started in. If you copy a backup
    directory to another host, delete the copy's `.kiln-dir-id`.
  - **During a rolling deploy.**
    - Don't click **Back up now** or **Resume** on a page served by a node
      still on the older release: its worker runs the whole backup at once and
      ignores the lock. A new node's backup waits (up to 3 hours) while such a
      job is running, but the old job does not wait for a new one.
    - Once a backup has been canceled, an older node's **Backups** page fails
      to load while that run is on the page (it cannot read a `canceled`
      run), and its retention deletes nothing (it fails closed on a status it
      doesn't know).
    - The new `backup_canceled` security event cannot be loaded by an older
      build that has the security log: that site's **Security log** page and
      CSV fail there, and erasing the admin named in one fails and retries
      ([#2509](https://github.com/The-Verscienta/kiln_cms/issues/2509)). The
      event always goes to the default site's log.
    All three last only until every node runs this release.
  - **Before rolling back**, on the new release:
    1. Cancel the running backup, if any (**Backups** → **Cancel**). If one
       was queued, it starts next; cancel that one too. The in-flight strip
       is gone when nothing runs.
    2. In `psql` against the deployment's database:

       ```sql
       UPDATE backup_runs SET status = 'failed' WHERE status = 'canceled';
       DELETE FROM security_events WHERE type = 'backup_canceled';
       ```

       The first keeps the canceled runs, as `Failed`; the second removes
       audit history, so export the log first if you need it. The `UPDATE` is also what lets the down migration
       restore the narrower status check, which fails while a `canceled` row
       exists.
    Rolling back to v1.8.0 needs neither statement: it has no backup history
    and no security log. Otherwise rolling the pin back is safe: the older
    release ignores the two new tables and the new column. Or roll forward.
  See also [the Added entry](#backup-step-chain) and
  [the Breaking entry](#backup-request-api).
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="field-layout-upgrade"></a>

- **Run `mix ash.migrate` for custom-field layouts: one new column,
  `field_definitions.width`, and one new table, `field_sections` (#2280).**
  The migration (`20261108231057_add_field_sections_and_field_width`) adds
  `width` as `text NOT NULL DEFAULT 'full'`, so every existing field is full
  width and the editor looks as it did, and creates `field_sections` (one row
  per section an admin lays out, keyed by site, type and section name). It is
  expand-only and copies no data. Rolling the pin back is safe: the previous
  release ignores the table and the column, and its inserts get `'full'`;
  any tabs or fieldsets set up meanwhile show as accordions until you upgrade
  again.
  - **Field sync files.** A file `mix kiln.fields.export` writes from now on
    carries `"width"` on every field and a `"sections"` list per type. A
    build of Kiln from before this change refuses such a file
    (`unknown key(s) width`), so after a rollback export again from the
    rolled-back instance, or strip the key as shown in
    [field-sync.md](../field-sync.md#moving-a-file-to-an-older-build). Files
    from before this change import unchanged: fields are full width and the
    target's layouts are left alone, even with `--prune`.
  - **Overlays.** Nothing to run: core's migration ships the table and the
    column, and `FieldSection` is in the existing `KilnCMS.CMS` domain.
  ([#2280](https://github.com/The-Verscienta/kiln_cms/issues/2280))

<a id="field-widgets-upgrade"></a>

- **Field definitions gain a nullable `widget` column (#2284).** Run
  `mix ash.migrate`. `field_definitions.widget` is `text`, nullable, with no
  backfill: every existing field reads `nil`, which is its type's default and
  the input it had before, so nothing changes in the editor until an admin
  picks an input. Additive, and it does not touch the `kiln_reporting_v1`
  views. Rolling the pin back is safe: the previous release ignores the column,
  and editors see the default inputs again until you upgrade.
  - **Field sync across versions.** A field-sync file exported by this release
    carries `"widget"` on every field, which an older release's
    `mix kiln.fields.import` refuses as `unknown key(s) widget`: upgrade the
    target first. A file exported before this release has no `"widget"`, so
    importing it here sets every chosen input back to the default; export again
    after upgrading. See [field-sync.md](../field-sync.md#editor-inputs-widget).
  - **Plugins.** A plugin field type that implements the new optional
    `widgets/1` needs `{:kiln_plugin, "~> 1.4"}`. Nothing changes for one that
    doesn't.

<a id="registration-approval-upgrade"></a>

- **Run `mix ash.migrate` for registration approval (#2251, first part). Turn
  approval on only once every node runs this release. Before rolling back,
  deal with waiting and rejected registrations and delete the three new
  security events, or roll forward.**
  - **What the migration does.** `20261109103330_registration_approval_status`
    adds `org_memberships.status` (`text NOT NULL DEFAULT 'active'`),
    `org_memberships.decided_at` (nullable) and an index on
    `(organization_id, status)`, and creates `site_registration` (one row per
    site, `approval_required boolean NOT NULL DEFAULT false`). Additive: every
    existing membership reads `active`, and nothing changes until a site admin
    turns approval on.
  - **Mixed versions.** A node still on the previous release has no `status`
    and reads a waiting registration as an ordinary active *Viewer*
    membership: little more than an anonymous visitor gets (no audiences), but
    it can comment where viewers may and start a checkout. Turn approval on
    only after every node runs this release.
  - **Rolling back.** The older release reads every waiting **and rejected**
    registration as an active viewer on its site. Before rolling back, approve
    the ones you would let in and anonymize the accounts you would not
    (**Accounts** → Remove, which leaves nothing that can sign in). Don't
    delete their membership rows instead: an account left with no membership
    becomes a viewer on the default site.
  - **Security events.** Three new types, `registration_queued`,
    `registration_approved` and `registration_rejected`. As for the unlock
    events above, a build with the security log that predates them cannot load
    those rows, which breaks that site's security log and CSV and erasing a
    person named in one
    ([#2509](https://github.com/The-Verscienta/kiln_cms/issues/2509)). Before
    such a rollback, export what you need and run:

    ```sql
    DELETE FROM security_events
    WHERE type IN ('registration_queued', 'registration_approved', 'registration_rejected');
    ```

    v1.8.0 has no security log and is unaffected by this part.
  See also [the Added entry](#registration-approval).

<a id="registration-notifications-upgrade"></a>

- **Run `mix ash.migrate` for registration notices (#2251, second part).
  While any node runs an older release, and after rolling back, an admin's
  bell on that node can break; before rolling back, delete the new
  notifications, or roll forward.**
  - **What the migration does.**
    `20261109122632_registration_notification_pref` adds
    `users.notify_on_registration` (`boolean NOT NULL DEFAULT true`).
    Additive: every existing account gets the email until it mutes it, and an
    older release ignores the column.
  - **Why the bell breaks.** The notifications table stores an event as text,
    and a release loads it back as one of the events it knows. This change
    adds `registration_pending`. A node on an older release cannot load such a
    row, and the failure takes out the whole list read
    ([#2509](https://github.com/The-Verscienta/kiln_cms/issues/2509)): for an
    admin with one of these notices, the bell on that node shows the unread
    count but an empty list, and **Mark all read** fails there.
  - **During a rolling deploy** this lasts until every node runs the new
    release; nothing needs doing.
  - **Before rolling back**, in `psql` against the deployment's database:

    ```sql
    DELETE FROM notifications WHERE event = 'registration_pending';
    ```

    This removes only the "Registrations waiting for approval" notices; the
    queue itself is untouched. Or roll forward instead.
  See also [the Added entry](#registration-notifications).

<a id="registration-invitations-sso-upgrade"></a>

- **Run `mix ash.migrate` for invitations over registrations and the site
  single sign-on switch (#2251, part three, first half). Turn the new
  switch on only once every node runs this release.**
  - **What the migration does.**
    `20261109145052_registration_provenance_and_site_sso` adds
    `org_memberships.created_account` and
    `site_registration.approval_for_site_sso`, both
    `boolean NOT NULL DEFAULT false`. Additive: every existing row reads
    `false`, which is the behaviour before this change, and an older release
    ignores both columns.
  - **Mixed versions.** A node still on an older release does not read
    `approval_for_site_sso`, so a new account from a site's own single sign-on
    that lands on it becomes an active *Viewer*, unreviewed. Turn the switch
    on (**Registrations** → **New accounts from this site's single sign-on
    wait for approval too**) only after every node runs this release.
  - **Rolling back** is safe for the schema. Waiting single sign-on accounts
    are waiting rows like any other, covered by
    [the first part's upgrade note](#registration-approval-upgrade). No new
    security event types: `registration_queued` gains the `method` value
    `site_sso`, and `registration_approved` the `via` values `invitation` and
    `added`, all strings in the event's metadata, which an older build that
    has these event types loads as before.
  See also [the Added entry](#registration-invitations-sso).

<a id="registration-erasure-upgrade"></a>

- **Run `mix ash.migrate` for erasing unconfirmed rejected accounts (#2251,
  part three, second half). Set Registrations → "When you reject someone" to
  erase only once every node runs this release.**
  - **What the migration does.**
    `20261109181713_registration_rejected_accounts` adds
    `site_registration.rejected_accounts`, `text NOT NULL DEFAULT 'keep'`.
    Additive: every existing site reads `keep`, which is the behaviour before
    this change, and an older release ignores the column.
  - **Mixed versions.** An erasure is safe only because every write that
    would attach something to the account (a membership, a paid membership,
    an API key, the entitlement recompute) or confirm it takes the account's
    row lock first. A node still on an older release takes no such lock, so
    during a rolling deploy an erasure can race a write there: a membership
    or key can land on the erased account, or an account confirmed at that
    moment can be erased. Choose **Erase the account if the email address was
    never confirmed** only after every node runs this release.
  - **Rolling back** is safe for the schema: the older release ignores the
    column and keeps every rejected account. Accounts already erased stay
    erased. No new security event type: `registration_rejected` gains the
    `outcome` value `erased`, a string in the event's metadata, which an older
    build that has the event type loads as before.
  See also [the Added entry](#registration-erasure).

<a id="sign-in-unlock-upgrade"></a>

- **Sign-in unlock links (#2250): no migration, and nothing to set. Before
  rolling back to a build that has the security log (#2441) but not this
  change, delete the three new security events, or roll forward instead.**
  - **Why.** The security log stores an event's type as text, and a release
    loads it back as one of the types it knows. This change adds three:
    `sign_in_unlock_requested`, `sign_in_unlocked` and
    `sign_in_unlock_refused`. A build without them cannot load such a row, and
    the failure takes out the whole read, not just the row: that site's
    **Security log** page and its CSV fail, and erasing a person who appears
    in one of those events fails and retries. The daily retention prune is
    unaffected. Tracked in
    [#2509](https://github.com/The-Verscienta/kiln_cms/issues/2509).
  - **Who this affects.** A rollback to v1.8.0 does not: v1.8.0 has no
    security log and never reads the table. It matters for a rollback to a
    later build that has the log, such as a release candidate or a `main` pin
    taken before this change.
  - **What to run before such a rollback**, in `psql` against the
    deployment's database:

    ```sql
    DELETE FROM security_events
    WHERE type IN ('sign_in_unlock_requested', 'sign_in_unlocked', 'sign_in_unlock_refused');
    ```

    This removes audit history, so export the log first if you need it
    (**Download CSV** on `/editor/security-log`, filtered to those events).
  - **Everything else rolls back cleanly.** Unlock links already mailed are
    rows in `tokens` with purpose `sign_in_unlock`; an older build has no
    route for them and the nightly sweep deletes them once expired. The
    `mail:sign_in_unlock` throttle counters expire with their window.
  See also [the Added entry](#sign-in-unlock).

<a id="form-human-verification-upgrade"></a>

- **Run `mix ash.migrate` for human verification on public forms (#2249,
  second part). If you build assets yourself rather than with
  `mix assets.deploy`, add the new `kiln_challenge_embed` esbuild profile.
  Rolling the pin back is safe for data, but a form switched to the check
  stops asking for it on the older release, with nothing to say so.**
  - **What the migration does.** `20261109050524_add_form_challenge` adds
    `forms.challenge` (`text NOT NULL DEFAULT 'off'`) and
    `form_submissions.challenge` (`text`, nullable). Additive; every existing
    form reads `off`, so nothing changes until a site admin switches one on.
  - **A new JavaScript bundle.** The embedded form (`/forms/:slug/embed`) does
    not load `app.js`, so its widget is mounted by a small bundle of its own,
    `priv/static/assets/js/challenge_static.js`, built by the esbuild profile
    `kiln_challenge_embed`. `mix assets.build` and `mix assets.deploy` (and
    so the stock `Dockerfile`) now run it, and `mix phx.server` in
    development watches it. A custom asset pipeline or an overlay
    `Dockerfile` that calls `mix esbuild kiln_cms` directly must also run
    `mix esbuild kiln_challenge_embed --minify` before `mix phx.digest`;
    without it, an embedded form that asks for a check draws no widget, and
    everything sent through it is held in Spam.
  - **Who can switch it on.** Only a site admin, per form, and only while the
    operator has a provider configured
    ([Turn on human verification](../human-verification.md#turn-on-human-verification)).
    A deployment without `CHALLENGE_PROVIDER`, `CHALLENGE_SITE_KEY` and a
    secret sees no change at all. A deployment that already set them up for
    sign-in lets site admins opt their forms in from this release; set
    `CHALLENGE_FORMS=false` and restart if you do not want that.
  - **Rolling back.** An older release ignores both columns: a form set to
    ask for a check accepts and acts on every submission again (mail,
    webhook, autoresponder), and the Entries tab no longer shows Verified or
    Held. Submissions already held stay in Spam. The settings are still
    stored, so rolling forward again restores them.
  Guide: [Public forms](../human-verification.md#public-forms).

<a id="scalar-list-fields-upgrade"></a>

- **Number, date, link and other scalar custom fields can now hold a list
  (#2289). Upgrading needs nothing, but once an admin makes such a field a
  list, rolling the pin back can lose list items.** No migration: the
  `multiple`, `min_items` and `max_items` columns already exist.
  - **What an older release does with a typed list.** A release before this
    one only knows lists on media, reference, group, select and string fields.
    If someone saves the definition of an `:integer`, `:float`, `:date`,
    `:datetime`, `:time`, `:url`, `:email`, `:telephone`, `:color` or `:slug`
    list field in its fields admin, it clears `multiple`, and the reshape that
    follows keeps only the **first item** of every stored list of that field.
    A list written to such a field there (an editor save, an API write) is
    turned into one string or refused, depending on the type: a `:url` list
    becomes the items run together (`"https://ahttps://b"`).
  - **Before rolling back,** if any list fields of these types exist: do not
    edit those field definitions or those records on the older release, or
    first copy the values somewhere safe. Lists of strings and select terms
    are not affected; the older release already knows those.
  Guide: [Make a field hold a list of values](../extending-content.md#make-a-field-hold-a-list-of-values).

<a id="admin-allowlist-upgrade"></a>

- **Run `mix ash.migrate` for the admin allowlist (#2248): one new table,
  `site_admin_allowlist`. Nothing changes until a site admin saves a list.
  Rolling back to an earlier release turns every site's allowlist off without
  a word, and while a list is on, members and apps sign in only from listed
  networks.**
  - **What the migration does.** `20261109005539_add_site_admin_allowlist`
    creates `site_admin_allowlist` (one row per site, `cidrs text[] NOT NULL
    DEFAULT '{}'`, unique on `org_id`). Additive; no existing table changes.
  - **Rolling back is not neutral.** An earlier release has no gate and
    ignores the table: every site that turned the allowlist on is open to
    every network again, with nothing on the page or in the log to say so. Roll
    forward again to restore it; the lists are still stored.
  - **Who is affected when a site turns it on.** Every sign-in route is gated,
    not only the console's: members and readers who sign in on the public site,
    and `POST /api/auth/sign_in`, which single-page apps and native or mobile
    apps call from the user's device. Those sign-ins work only from listed
    networks. Tokens already issued and API keys are not affected.
  - **Behind a proxy, set `TRUSTED_PROXIES` (or `CLIENT_IP_HEADER` on Fly.io,
    Railway and App Platform) first.** The allowlist page refuses to save a
    list while forwarded requests arrive that nothing trusts.
  - **Know the way back in.** `bin/kiln_cms rpc
    'KilnCMS.Release.admin_allowlist(clear: true)'` (or `add: "<address>"`), or
    `KILN_ADMIN_ALLOWLIST_DISABLED=1` and a restart. See
    [Recovering from a lock-out](../admin-allowlist.md#recovering-from-a-lock-out).
  - **The console menu moved.** Single sign-on and Sessions (from
    Integrations) and Password policy, Blocked addresses and Bot budgets (from
    Organization) are now under the new **Sign-in & access** section, with the
    new Admin allowlist page. The addresses are unchanged.
  See also [the Added entry](#admin-allowlist).

<a id="session-idle-timeout-upgrade"></a>

- **Run `mix ash.migrate` for the idle timeout and "sign out everyone" (#2246).
  Two migrations, both additive; one builds an index on `tokens` concurrently.**
  Nothing changes for anyone until a site admin sets a timeout: the setting is
  off by default and there is no environment variable.
  - **What the migrations do.**
    `20261108223445_add_session_org_and_idle_timeout` adds two nullable columns
    to `tokens` (`org_id`, `revoked_reason`) and creates the table
    `site_session_policy` (one row per site, created when an admin first saves
    the setting). `20261108223446_add_session_org_and_idle_timeout_1` builds
    `tokens_org_id_purpose_index` with `CREATE INDEX CONCURRENTLY`, outside a
    transaction, so sign-ins keep working while it builds. On a large `tokens`
    table it takes a while. If the build fails it leaves an `INVALID` index:
    run `DROP INDEX CONCURRENTLY tokens_org_id_purpose_index;` and migrate
    again.
  - **Existing sessions stay signed in.** Their rows have no site yet. Each is
    bound to the site it is next used on, unless that site's admin has since
    used **Sign out everyone**, in which case it is signed out there instead.
  - **One more read per signed-in request.** Every signed-in browser request
    and every signed-in LiveView mount now reads the session's token row by
    primary key, timeout or not: it is how a session cookie copied to another
    site's host is refused there. Signed-in page requests also update
    `last_used_at` at most once every five minutes per session (LiveView
    mounts already did). Anonymous traffic is unaffected.
  - **Rolling back.** Safe: the older release ignores the new columns and
    table. Sites lose their idle timeout and the effect of a later "sign out
    everyone" until you upgrade again; sessions already revoked stay revoked.
  - **Overlays.** Nothing to run unless your overlay carries its own copy of
    `KilnCMS.Accounts.Token`; core ships both migrations.
  See also [the Added entry](#session-idle-timeout).

<a id="backup-offsite-rehash-upgrade"></a>

- **An in-app backup whose off-site copy fails now fails, and every file is
  re-hashed right before its off-site copy, in the app and in
  `scripts/backup.sh` (#2218).** For anyone with `BACKUP_RCLONE_REMOTE` set. No
  migration and no new setting.
  - **Red where it used to be green.** An in-app backup whose `rclone copy`
    failed, for a data file or a `.sha256` sidecar, used to finish `Succeeded`
    with no off-site copy. It now finishes `Failed`: `manifest.json` has
    `"ok": false` and `"offsite": null`, the **Last run failed** box and the
    History row show the error, and the overview shows its backup alarm. After
    upgrading, if your backups turn red, check the remote name and its
    credentials. rclone's own retries (`--retries`, default 3, or
    `RCLONE_RETRIES`) run before the run is failed; since
    [the step chain](#backup-step-chain) the app also retries the off-site
    step itself, four attempts in all. Cron already failed on a failed copy.
  - **A file that changed is refused.** The dump, every media part and every
    sidecar is read again immediately before its own copy and compared with the
    SHA-256 recorded when it verified. A file that changed in between is not
    uploaded, not retried and not rebuilt in that run, and the run fails. The
    app keeps checking and copying the other files and then names every refused
    and failed file ("Off-site copy REFUSED for 1 file: …"); the History row
    reads **Not verified**. `backup.sh` stops at the first refusal
    with `REFUSING off-site copy of <name>: …` and marks that file not verified
    in the failure manifest. The app compares a sidecar's parsed lines with
    what it recorded; cron hashes the sidecar's bytes.
  - **Resume retries the off-site copy.** A run that failed off-site keeps
    `.work/<stamp>/` (it is now removed only when the backup and its off-site
    copy both succeed), so **Resume** on the History row retries the copy,
    reusing every file that still matches and rebuilding only one that changed.
    Copy a suspect file aside first if you want it as evidence. Since
    [the step chain](#backup-step-chain) a database-only run (S3 media
    adapter, or no media directory) keeps a work directory and resumes too.
  - **No `rclone` in the image is a warning, not a failure.** The official
    image does not install it. With `BACKUP_RCLONE_REMOTE` set and no `rclone`,
    an in-app backup succeeds locally, logs a warning, and **Where backups go**
    on the Backups page says nothing is copied off-site. PaaS deployments that
    relied on the variable alone were never getting an off-site copy from the
    app; [deploy-platforms.md](../deploy-platforms.md#backups) now says so.
  - **Cron failure manifests no longer name the remote.** `backup.sh` writes
    `"offsite": null` when a run fails, as the app does, and History no longer
    takes a failed manifest's remote as proof that its files went off-site. A
    stamp already in History keeps its row; an old failure manifest still on
    disk imports without the remote.
  - **Still different between the paths.** The app prunes expired backups
    before its off-site copy, so it prunes even when that copy fails; cron
    prunes only after a run that succeeded.
  - **Cost.** One extra sequential read of each file, only when a remote is
    set; much faster than the upload it precedes.
  - **For developers.** New `KilnCMS.Backups.Checksum.recheck/3` and
    `check_sidecar/2`, `KilnCMS.Backups.Recorder.put_unverified/2`,
    `KilnCMS.Backups.rclone_missing?/0`, and an `rclone_missing?` key in
    `KilnCMS.Backups.status/0`. `KilnCMS.Backups.Worker.copy_offsite/2` returns
    the remote only when every file, sidecars included, was re-verified and
    copied.
  - **Rolling the pin back** is safe: nothing is migrated. The previous
    release goes back to marking a run with a failed off-site copy as
    succeeded, and to uploading without a re-hash.
  Guide: [When an off-site copy is refused](../backups.md#when-an-off-site-copy-is-refused).
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="backup-sh-media-parts-upgrade"></a>

- **`scripts/backup.sh media` and `all` now split media into parts like the app,
  stop archiving empty folders and folder modes, and need GNU tar or bsdtar;
  `restore.sh media` refuses a part set with no sidecar (#2218).** For anyone
  taking backups with cron. No migration; nothing to change in a working cron
  line.
  - **Parts by default.** A media library bigger than `BACKUP_MEDIA_PART_MB`
    (default 400, 16 to 10240; a bad value prints a `warning:` line and uses
    400) is written as `kiln-media-<stamp>.part01.tar.gz` … `.partNN.tar.gz`,
    with a multi-line `kiln-media-<stamp>.sha256` and, for `backup.sh all`, one
    `manifest.json` entry per part with `part` and `parts_total`. One part keeps
    the old `kiln-media-<stamp>.tar.gz` name. The files and names match what the
    app writes for the same directory and settings. There is no off switch.
    Anything of yours that globs `kiln-media-*.tar.gz` must accept the
    `.partNN` names.
  - **`BACKUP_MEDIA_EXCLUDE` now applies to cron too.** If you set it for the
    app, cron archives start leaving those paths out as well. A pattern ending
    in `/` (`cache/`) excludes nothing on either path; write `cache` or
    `cache/**`.
  - **Folders are not archived.** Regular files and symlinks only, as the app
    already did. Empty folders are lost, and a restore recreates folders owned
    by the restoring user with that user's default mode (typically
    `root:root`, `0755`): `chown -R` the media root afterwards.
  - **Tools.** GNU tar or bsdtar is required; busybox tar is refused before
    anything is written. The script also uses `stat`, `xargs`, `mktemp`,
    `head` and `gzip`, and builds its file lists in `TMPDIR` (default `/tmp`).
    Planning in shell is slower than in the app for a library of many files.
  - **Permissions.** Parts and the sidecar are 0600 from the first byte. A
    `media/` directory the script creates is 0700 (an existing one keeps its
    mode), and the app sets it to 0700 on every run, so cron and the app must
    run as the same user to share it.
  - **A failed run removes its own parts.** Cron has no resume: a failed or
    signalled (`HUP`, `INT`, `TERM`) run removes the parts it wrote and keeps a
    finished database dump. A failed off-site copy after the set is complete
    keeps the set. A run killed outright leaves its parts and a
    `kiln-media-<stamp>.sha256.partial` marker: History holds the stamp,
    `backup.sh verify` skips it and says so, and `restore.sh` refuses it. The
    next in-app backup removes a `.partial` older than an hour, after which
    History shows the leftover parts as failed ("incomplete media set: parts
    but no sidecar"); or delete the stamp's files by hand.
  - **`restore.sh media` refuses a `.partNN` set with no sidecar**, where it
    used to warn and continue: such a set is most likely from a killed run and
    would restore with files missing. Set
    `RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1` to restore it anyway. A legacy
    single archive with no sidecar still restores with a warning. `backup.sh
    verify` fails on parts with no sidecar, and when no complete media set
    exists.
  - **Rolling the pin back** restores the old single-archive script. Part sets
    cron already wrote stay readable by hand, one `tar -xzf` per part in
    numeric order; the previous release's History and `restore.sh` handle them
    as described in [the app-parts note](#backup-media-parts-upgrade).
  Guide: [Cron backups in parts](../backups.md#cron-backups-in-parts).
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="bot-budgets-upgrade"></a>

- **Run `mix ash.migrate` for bot budgets (one new table, `site_bot_budgets`),
  and check scripts that fetch public pages: `curl`, Go, Java and Python clients
  now get 150 requests a minute per address instead of 300, and requests with no
  user agent get 60 (#2243).** Browsers, search engines and AI crawlers keep
  300.
  - **Migration.** `20261108120718_add_site_bot_budgets` only creates a table, one
    row per site, written when an admin first saves `/editor/bot-budgets`. It is
    expand-only and changes no existing data. Rolling the pin back is safe: the
    previous release ignores the table, and every client is back to 300 a minute.
    Overlays that restate `:ash_domains` need no change: the resource is in
    `KilnCMS.CMS`.
  - **Who gets less.** On every `:delivery` route (public pages, `/search`,
    `/forms/:slug/embed`, and `/media/:id/download` and `/media/:id/stream`), a
    `User-Agent` that names a scripting tool, a headless browser, a link-preview
    fetcher or a product ending in `bot`, `crawler`, `spider` or `scraper` is
    refused past 50% of the `:delivery` limit, and one that is missing or empty
    past 20%. The full list is in [bot-budgets.md](../bot-budgets.md).
  - **One count per address.** Every class spends the same per-address counter,
    so browsers and scripts behind one address share it. An office uptime check
    sent by `curl` is refused once the office's browsers pass 150 requests in a
    minute. Point load-balancer and uptime checks at `/up`, which is never
    charged by class.
  - **Headless media consumers.** A server or app that fetches
    `/media/:id/stream` or `/media/:id/download` with a library's default user
    agent (`python-requests`, `Go-http-client`, `curl`) now gets 150 a minute.
    Send a user agent of your own, or raise the class with
    `KILN_BOT_BUDGET_DECLARED_BOT_PERCENT`. Native mobile HTTP stacks
    (`okhttp`, `CFNetwork`, `Dalvik`) and media players count as browsers.
  - **Benchmarks.** `Application.put_env/3` of the whole `KilnCMSWeb.RateLimit`
    config drops the `delivery_classes` key the new variables write; see
    [performance.md](../performance.md#running-a-basic-load-check).

<a id="verified-search-bots-upgrade"></a>

- **Each node now sends DNS queries about visitors: an address whose user agent
  names a search engine is looked up by reverse and forward DNS, on by default
  (#2254).** Allow outbound DNS (PTR, A, AAAA) to the resolvers in each node's
  `/etc/resolv.conf`, or set `KILN_CRAWLER_VERIFICATION=false`. No migration;
  rolling the pin back is safe and goes back to believing every claim.
  - **Behind a proxy**, set `TRUSTED_PROXIES` (or `CLIENT_IP_HEADER` on Fly.io,
    Railway or DigitalOcean App Platform). Otherwise every request carries the
    proxy's address, no claim can be checked, and none is proven false: rate
    limits stay as in #2243, and a search-engine value above 100% never applies.
  - **Data flow.** The query names the visitor's address
    (`in-addr.arpa` / `ip6.arpa`), so your resolver, and the operator of that
    address's reverse zone, see it. If your resolver is a third party's, list
    it as a subprocessor; see [data-flows.md](../data-flows.md#optional-subprocessors).
  - **With the smart 404 guard on (`KILN_SCANNER_BLOCKING`),** link-preview
    fetchers (`facebookexternalhit`, `Twitterbot`, `LinkedInBot`) and `Slurp`
    are no longer exempt from the miss threshold, whatever
    `KILN_CRAWLER_VERIFICATION` says ([below](#scanner-guard-exemption-narrowed)).
    A site whose shared links often lead to 404s can see a preview fetcher's
    address blocked for an hour. Remove such a block on `/editor/ip-blocks`.
  - **Dashboards.** `kiln_cms_delivery_client_class_count{class="empty"}` now
    includes search-engine claims proven false
    ([below](#client-class-is-charged-class)).
  - **Check it works**:
    `bin/kiln_cms rpc 'IO.inspect(KilnCMS.CrawlerVerification.verify(:google, {66, 249, 66, 1}))'`
    prints `{:verified, "crawl-66-249-66-1.googlebot.com"}`. Guide:
    [Check that a node can verify crawlers](../bot-budgets.md#check-that-a-node-can-verify-crawlers).

<a id="team-invitations-upgrade"></a>

- **Run `mix ash.migrate` for site invitations: one new table, `invitations`,
  and a new daily prune job (#2135).** The migration
  `20261108053325_add_invitations` only creates a table, so it is expand-only
  and changes no existing data. Rolling the pin back is safe for the data:
  the previous release ignores the table. Any invitation still pending then
  stops working, because the previous release has no `/auth/invite/…` page.
  Its row is untouched, so the link works again once you upgrade again, if it
  has not expired.
  - **The prune job.** The AshOban trigger `Invitation` `:prune_expired` runs
    daily at `35 4 * * *` on the `default` queue and deletes invitations more
    than 30 days past their expiry. It has no setting and no environment
    variable. Overlays that restate `:ash_domains` need no change: the
    resource is in `KilnCMS.Accounts`.
  - **Privacy.** Each row holds an invited email address, so the table is new
    personal data. It holds an address for at most about 37 days (7 days
    usable, then 30 until the prune). The `oban_jobs` row of each invitation
    mail holds the plaintext link until Oban's Pruner deletes the job, 7 days
    after it finishes. [data-flows.md](../data-flows.md) lists both, and the
    staging scrub deletes the table.
  - **Logs.** `invite_token` is added to `:filter_parameters`. That keeps the
    token out of the logged params map. Phoenix still logs the request path,
    and the path contains the token, as it already does for `/magic_link/…`
    and `/password-reset/…` links. If you ship request logs somewhere with
    wider access, treat them as holding live invitation links for up to 7 days.

<a id="security-log-upgrade"></a>

- **Run `mix ash.migrate` for the security log, add `KilnCMS.Security` to an
  overlay's `:ash_domains`, and decide the retention window (#2441).** Two
  migrations, both expand-only, creating two new tables and changing no existing
  data, so rolling the pin back is safe; the tables are simply unused.
  - **Migrations.** `20261108011355_add_security_events` creates
    `security_events` (with four indexes) and `20261108012212_add_security_log_retention`
    creates `site_security_log` (one row per site, created when an admin saves
    the window).
  - **Overlays that restate `:ash_domains`.** `KilnCMS.Security` is a new Ash
    domain. `:ash_domains` replaces rather than merges, so add it to your
    `config/project.exs` list (next to `KilnCMS.Social`), or the resource sits
    outside every configured domain and `mix ash.codegen` offers to drop its
    table. See [the overlay contract](../overlay-contract.md).
  - **A new daily job is on by default.** `KILN_SECURITY_LOG_PRUNE_CRON`
    (default `20 3 * * *`) deletes events older than each site's retention
    window; `false` turns it off. The default window is **365 days**, so the log
    starts empty and does not delete anything for a year. Set the window per site
    on `/editor/security-log`; `0` keeps events forever, which also keeps raw IP
    addresses and user agents indefinitely.
  - **Privacy.** The log is new personal data (raw IP, user agent, email
    snapshot). Add it to your records of processing; [data-flows.md](../data-flows.md)
    lists it, and erasure and the staging scrub already cover it.
  ([#2441](https://github.com/The-Verscienta/kiln_cms/pull/2441))

<a id="backup-media-parts-upgrade"></a>

- **App-made media backups can now be several `kiln-media-<stamp>.partNN.tar.gz`
  files; anything that globs `kiln-media-*.tar.gz` must accept them, and a
  rollback hides them from History (#2218).** No migration and no setting to
  change.
  - **Naming.** A media library bigger than `BACKUP_MEDIA_PART_MB` (default 400)
    is written as `kiln-media-<stamp>.part01.tar.gz`, `.part02.tar.gz`, and so
    on (two digits, widening past 99). A library that fits in one part keeps the
    legacy `kiln-media-<stamp>.tar.gz`. Check any rclone filter, monitoring or
    retention script of your own that matches the old name; `scripts/restore.sh`
    and `scripts/backup.sh verify`/`prune` already understand both.
  - **Rolling the pin back is safe for the data but not for the view.** The
    previous release's Importer and Presence ignore `.partNN` names, so part sets
    do not show in History (and read as missing), while its prune glob
    `kiln-*` would still age them out by file. The files are ordinary
    `tar.gz` and restore by hand, one `tar -xzf` per part in numeric order. Nothing
    is lost, nothing is migrated back.
  - **Copying `$BACKUP_DIR` off-host with `rclone sync`?** Exclude `.work/**`:
    the new resume state in `.work/<stamp>/` holds lists of media file names and
    is removed when a backup succeeds.
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="builtin-field-type-names-upgrade"></a>

- **The field type names `email`, `telephone`, `color`, `slug`, `time`, `json`, `range`, `key_value` and `link` are reserved (#2278).**
  Kiln now ships a built-in type under each name (see
  [Built-in format types](../extending-content.md#built-in-format-types) and
  [Range and key-value and link fields](../extending-content.md#range-and-key-value-and-link-fields)), and
  a name can be registered only once.
  - **Overlays and plugins.** A `Kiln.FieldType` that registers one of these
    names must be renamed, in the module's `name/0` and in any stored
    `FieldDefinition.field_type`. `mix kiln.plugins.doctor` fails with *collides
    with a built-in field type* until you do.
  - **Stored definitions.** A `FieldDefinition` whose `field_type` already
    holds one of these names is now cast by the built-in type, not yours.
    Values that do not pass its check (a malformed address, a domestic phone
    number) are refused the next time that record is saved; stored values are
    not rewritten. If the data matters, rename your type and migrate the
    definitions before upgrading.
  - **Rolling back.** No migration. Rolling the pin back restores the old
    type; values saved meanwhile in the built-in's tidied form (a lowercased
    domain, `+442079460958`) stay as stored.

<a id="backup-history-upgrade"></a>

- **Run `mix ash.migrate` for the backup history, and add `KilnCMS.Backups` to
  an overlay's `:ash_domains` (#2217).** The migration
  (`20261107205448_add_backup_runs`) creates one table, `backup_runs`. It is
  expand-only and changes no existing data, so rolling the pin back is safe;
  the table is simply unused.
  - **Overlays that restate `:ash_domains`.** `KilnCMS.Backups` is now an Ash
    domain (it was a plain module). `:ash_domains` replaces rather than merges,
    so an overlay's `config/project.exs` that lists the core domains must add
    `KilnCMS.Backups` (next to `KilnCMS.Billing`), as
    `projects/example/project.exs` now does. Without it the resource sits
    outside every configured domain and `mix ash.codegen` offers to drop the
    `backup_runs` table. See [the overlay contract](../overlay-contract.md).
  - **Nothing else to set.** No new environment variables; `manifest.json`,
    `Backups.status/0` and the overview strip are unchanged, so cron-based
    deployments keep working untouched.
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217))

<a id="breached-password-upgrade"></a>

- **Run `mix ash.migrate` for the breached-password check, and decide whether
  your deployment may call a third party (#2240).** The migration
  (`20261107194057_add_site_password_policy`) creates one table,
  `site_password_policy` (one row per organization, created lazily when an
  admin saves the setting). It is expand-only and changes no existing data, so
  rolling the pin back is safe; the table is simply unused.
  - **New outbound call, on by default.** Setting a password (register, change,
    reset, first-run setup) now sends the first five characters of the
    password's SHA-1 hash to `api.pwnedpasswords.com`. The password, the full
    hash and the account never leave the server. If the service is slow or
    down, the password is accepted.
  - **Air-gapped or no-egress deployments.** Set `BREACHED_PASSWORD_CHECK=false`
    to make no call at all. Firewalls that allow only listed hosts should allow
    `api.pwnedpasswords.com:443` instead, or the check quietly does nothing
    (it fails open, logging a warning and emitting the telemetry event).
  - **Overlays.** Run `mix ash.codegen` only if your overlay adds its own
    resources; core's migration ships the table. See also the Breaking entry
    for `Bootstrap.create_first_admin/1`.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

<a id="reject-invalid-bearer-default-on"></a>

- **An unverifiable bearer token is a `401` by default (#2161).** The
  previous release added `KILN_API_REJECT_INVALID_BEARER`, off; this one turns
  it on, as [ADR 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  committed to. An `Authorization: Bearer …` header whose JWT does not verify
  (garbled, expired, or signed by another instance) is now answered `401` with
  the standard error envelope (`code: "invalid_token"`) and
  `WWW-Authenticate: Bearer error="invalid_token"` on `/api/json`, `/gql` and
  the other `/api` routes. Before, it was served as anonymous: the client got
  `200` and public content, and took that for success.
  - **Who notices.** Only a consumer that sends a bearer token that does not
    verify. A request with no `Authorization` header, or another scheme, is
    still anonymous. A valid JWT and a valid `kiln_` API key are unchanged, and
    a bad `kiln_` key was already a `401`.
  - **What to do.** Before upgrading, look for clients that send a token they
    never refresh: a static site build or a mobile app holding an old JWT, or
    one built against another instance's secret. Have them sign in again, or
    move them to an API key, or send no `Authorization` header when they mean
    to read as the public. Turning the flag on in the previous release
    (`KILN_API_REJECT_INVALID_BEARER=true`) shows the same `401`s ahead of time.
  - **Opting out, for one release.** `KILN_API_REJECT_INVALID_BEARER=false`
    restores the anonymous fallback. The variable is removed in the next
    release, after which an unverifiable bearer is always a `401`; use it only
    to buy time while you fix the client.
  - Unset now means on. Nothing to migrate and no config to change if your
    clients send valid tokens or none.
  - **Counting them.** Each such request, refused or not, emits
    `[:kiln_cms, :api, :invalid_bearer]` (`count: 1`; metadata `enforced`,
    `surface`, `read?` and `reason: :expired | :malformed | :invalid`, read from
    the unverified token and never sent to the client). Attach a handler to see
    which clients still send a stale token before the escape hatch goes. See
    [ADR 0017](../decisions/0017-an-unverifiable-bearer-flips-on-a-minor-with-a-breaking-note-and-is-counted-first.md).

<a id="search-name-lexemes-upgrade"></a>

- **Content tables gain `name_lexemes`, a generated column; overlays run
  `mix ash.codegen` to add it to their own content types.** The column is
  `GENERATED ALWAYS … STORED` from `search_weighted`, so the migration
  fills it for every existing row and Postgres keeps it current on every
  write. Adding a stored generated column rewrites the table under an
  exclusive lock: seconds for a catalogue of a few thousand rows, longer for
  a very large table. Until an overlay's own types have the column, their
  alias and compound legs answer empty and log why, so generate and migrate
  before deploying. No re-fire is needed: a row written before 1.8, with no
  `search_weighted`, still takes the full match.

<a id="reporting-views-upgrade"></a>

- **Overlays: run `mix ash.codegen` and commit the migration; existing content
  types gain the reporting views.** The reporting views (below) are created
  by `use KilnCMS.CMS.Content`, so a project's own `mix kiln.gen.content` types
  show codegen drift on the first release that has them. Run `mix ash.codegen`,
  review and commit the migration it writes, and deploy it with the update.
  Until then those types have no views; nothing else is affected. The
  migration is additive (a schema, and two views per content table) and
  rolling the pin back leaves them in place, unused. Core's own views arrive
  by core's migration with nothing to do. A BI role made earlier does not exist
  yet; when you create one (`mix kiln.reporting.sql`), re-run its `GRANT` lines
  after every upgrade that adds views, and after a demo reset.

<a id="custom-fields-gin-upgrade"></a>

- **Content tables gain a GIN index on `custom_fields`, built concurrently;
  overlays run `mix ash.codegen` to add it to their own content types.** The
  migration builds `pages_custom_fields_gin_index`,
  `posts_custom_fields_gin_index` and `entries_custom_fields_gin_index` with
  `CREATE INDEX CONCURRENTLY`, so writes continue during the build, but the
  build reads the whole table and can run for a long time on a large
  `entries`. Plan for it as a slow migration, not a hang, and do not kill the
  deploy halfway. If a build fails or is interrupted, Postgres leaves an
  `INVALID` index behind that is maintained on every write but never used.
  Find it with `SELECT indexrelid::regclass FROM pg_index WHERE NOT
  indisvalid;`, drop it with `DROP INDEX CONCURRENTLY <name>;`, and run
  `mix ash.migrate` (or your release's migrate command) again. Each index is
  roughly 26% of its table's size. The change is additive and safe to roll
  back: the previous release ignores the indexes, and the migration's `down`
  drops them. See [Custom fields](../json-api.md#which-custom-filters-use-an-index).

<a id="robots-flags-upgrade"></a>

- **Content tables gain `noindex` and `nofollow`; `type_definitions` gains
  `noindex_default` and `nofollow_default`. Overlays run `mix ash.codegen` for
  their own content types.** All four are `boolean NOT NULL DEFAULT false`, so
  the migrations are expand-only: the previous release ignores the columns and
  gets `false` on insert. No re-fire is needed.

<a id="custom-field-grants-upgrade"></a>

- **Users, memberships and roles gain a `field_read_grants` column; overlays
  run `mix ash.codegen`, commit the migration and run `mix ash.migrate`.** The
  column is `map NOT NULL DEFAULT '{}'` on `users`, `org_memberships` and
  `roles`, so the migration is expand-only and nothing is rewritten in a way
  the previous release trips over. Rolling the pin back is safe, with two
  effects to know first. A role that uses the new `custom_fields.<name>`
  write keys is read by the older release as holding unknown field names, and
  fails closed: those editors can change fewer fields, not more. The older
  release also ignores `field_read_grants`, so a private custom field you had
  hidden from some editors is visible to them again until you upgrade. Core's
  own table is migrated by core's migration; the new column does not touch the
  `kiln_reporting_v1` views.
<a id="field-validation-upgrade"></a>

- **Field definitions gain a `validation` column (#2276).** `field_definitions.validation` is `jsonb NOT NULL DEFAULT '{}'`: additive, instant, and every existing field starts with no constraints, so nothing about stored data or writes changes until an admin sets one. Rolling the pin back is safe (the old release ignores the column). Overlays that carry their own migrations run `mix ash.codegen` and commit the result.
  - **Unique is not a database constraint.** Once an admin marks a field `unique`, the write path enforces it; raw SQL and a database restore bypass it. Run `mix kiln.fields.duplicates` (read-only, exits non-zero on repeats) after bulk imports or restores.

<a id="focusable-code-blocks-upgrade"></a>

- **Optional: run `mix kiln.refire_all` after deploying to put the new
  code-block attributes into fired `:web` artifacts published before the
  upgrade (#2164).** No migration and no setting. Public pages rendered by Kiln
  itself pick the change up as soon as the deploy lands. A fired `:web`
  artifact keeps its old markup until its document is next published or
  edited: `format_version` does not change, so a read does not re-fire it.
  `mix kiln.refire_all` (on a release,
  `/app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"`) rewrites every
  published document's artifacts now. Since the artifact `ETag` became a
  digest of the body ([#2463](#render-etags)), a headless consumer, CDN or
  browser that revalidates with `If-None-Match` gets the new HTML on its next
  revalidation. A consumer that caches until a webhook tells it otherwise
  hears nothing from a plain sweep: run it as `mix kiln.refire_all --notify`
  (`KilnCMS.Firing.Sweep.run(notify: true)`) to send each document as
  `<type>.updated` with `"reason": "refire"`
  ([how](../releasing.md#re-render-published-content-after-an-upgrade)).
  Rolling the pin back is safe: the extra attributes are inert to the
  previous release.

<a id="scrollable-tables-upgrade"></a>

- **Optional: run `mix kiln.refire_all` after deploying to put the new table
  markup into fired `:web` artifacts published before the upgrade (#2464).**
  No migration and no setting. Public pages rendered by Kiln itself pick the
  change up as soon as the deploy lands. A fired `:web` artifact keeps its old
  markup (an unfocusable `.kiln-table-wrap`, or a bare `legacy_html` table with
  no wrapper) until its document is next published, edited or re-fired:
  `format_version` does not change, so a read does not re-fire it. The sweep
  is the same one the [code-block note](#focusable-code-blocks-upgrade)
  describes, and one run covers both: `mix kiln.refire_all` (on a release,
  `/app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"`). Clients that
  revalidate with `If-None-Match` get the new HTML on their next revalidation,
  because the artifact `ETag` is a digest of the body
  ([#2463](#render-etags)); a consumer that waits for a webhook hears about it
  only from `mix kiln.refire_all --notify`
  ([how](../releasing.md#re-render-published-content-after-an-upgrade)).
  Rolling the pin back is safe: the previous release ignores the extra
  attributes and the wrapper.

## Breaking

<a id="purge-trashed-only"></a>

- **Overlay and plugin code: `purge_<type>` (`purge_page`, `purge_post`,
  `purge_entry`, …) and `purge_media_item` now refuse a record that isn't in
  the trash (#2531).** The call returns `Ash.Error.Invalid` containing
  `Ash.Error.Changes.StaleRecord` and changes nothing. Trash the record first
  (`destroy_<type>` / `destroy_media_item`), then purge it. Media still being
  quarantined by the upload pipeline can be purged without trashing. The API
  never exposed `:purge`, so HTTP clients are unaffected; the nightly
  trash purge only ever read trashed rows.

<a id="restore-version-stale-struct"></a>

- **Overlay and plugin code: `restore_<type>_version` (`restore_page_version`,
  `restore_post_version`, …) now refuses a record read before a later write,
  and a restore increments `lock_version` (#2532).** The call returns an
  error containing `Ash.Error.Changes.StaleRecord` and writes nothing when the
  row's `lock_version` or `state` no longer matches the record passed in.
  Before, it could succeed while writing nothing, or restore onto a page
  published since the read without the publish-time gates. Read the record
  again (`get_<type>`) right before restoring, and use the returned record
  afterwards: a record held from before the restore is now stale for
  `update_<type>` and every other action that carries the optimistic lock.
  Over HTTP, the revisions restore route answers a lost race with `409`
  `invalid_state_transition` instead of `422` `restore_failed`, and a
  document trashed meanwhile with `404` (see
  [Fixed](#restore-refuses-stale-copy)).

<a id="backup-request-api"></a>

- **Console and overlay callers: `KilnCMS.Backups.enqueue/1` returns
  `{:ok, %{status: :started | :queued | :folded, chain: chain}}` instead of
  `{:ok, %Oban.Job{}}`, and `KilnCMS.Backups.Worker.run/3` no longer runs a
  backup inline (#2218).** Both are deprecated and go in the next minor
  release; use `KilnCMS.Backups.request/2` with the actor asking.
  - **`enqueue/1`** is `request/2` as `KilnCMS.Backups.system/0`, so code that
    matched the job (`{:ok, %Oban.Job{id: id}}`) must match the map. Its
    `{:error, reason}` values are those of `request/2`.
  - **`Worker.run(trigger, job_id, opts)`** requests a backup and waits for
    its chain to settle (`KilnCMS.Backups.await/2`): `:ok`, or
    `{:error, reason}` with the run's error text for a failed backup
    (including an off-site failure), `:canceled`, `{:skipped, error}`,
    `:no_run` or `:timeout`. When another backup is running it returns
    `{:error, :queued}` or `{:error, :folded}` at once; the request still runs
    later. `job_id` is ignored; `:timeout` (default 3 hours) bounds the wait,
    not the backup. The backup runs on the `backup_steps` queue of whichever
    node picks it up, not in the console's process.
  - **New:** `KilnCMS.Backups.request/2`, `await/2` and `in_flight/0`, and the
    code interfaces `request_backup`, `backup_lock` and `cancel_run` (see
    [Start a backup from a release console](../backups.md#start-a-backup-from-a-release-console)).
    A future scheduler must call `request(trigger: "schedule")` as
    `system/0`.
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="takedown-needs-publish-rights"></a>

- **Unpublishing and archiving content now need the same permission as
  publishing: an admin, or an editor on a site where Team → Publishing lets
  editors publish (#2134).** Before, any editor could take a live page down,
  or archive anything, even on a site where only admins may publish, so the
  approval step guarded putting content up but not taking it down.
  - **Who loses what.** On a site where only admins publish, editors can no
    longer unpublish or archive, including archiving their own drafts (archive
    is gated from every state; the trash was already admin-only). Nor can they
    set, move or clear `unpublish_at`, or change `expiry_action`, on a record
    that is published or has `scheduled_at` set: there the scheduler takes the
    record down on that date with nobody checked, so the date is an unpublish.
    On a draft nobody has scheduled, and on a create, editors may still set
    both. **Unarchive** and **Publish changes** stay open to every editor.
    Content releases are unchanged: editors may still add Unpublish items, and
    only an admin schedules or ships a release.
  - **Upgraded sites are the ones affected.** `editors_can_publish` defaults to
    off on a site that never answered the first-run `/setup` question, which
    is every site upgraded from before the switch existed. To keep the old
    behaviour for editors, an admin opens **Team** (`/editor/team`) and chooses
    **Let editors publish** under **Publishing**. That also lets editors
    publish, which is the point: one switch now decides both directions.
  - **API keys.** A `:read_write` key owned by an editor on such a site gets
    `403` on JSON:API `PATCH /api/json/<type>/:id/unpublish`, an authorization
    error (with `result: null`) on the GraphQL `unpublish<Type>` mutations, and
    a refusal on any `PATCH` or `update<Type>` that changes `unpublish_at` /
    `expiry_action` on a published or scheduled record. Archive has no API
    route, and `/mcp` has no unpublish or archive tool. Mint the key on an
    admin account, or turn the switch on.
  - **In the editor.** Editors who may not publish are no longer offered
    **Unpublish** on the page (nor in the **Live · draft** menu), **Unpublish**
    in a content-list row's menu, or **Unpublish** and **Archive** in the bulk
    bar. **Scheduled unpublish at** is locked on a live or scheduled page, with
    a note saying an admin sets it. When an editor on such a site is refused,
    an unpublish says "Only an admin can unpublish content on this site.", an
    archive "Only an admin can archive content on this site.", and on the
    calendar dragging a live page's unpublish chip says "Only an admin can
    move the unpublish date of a live page on this site." and a publish chip
    "Only an admin can move a publish date on this site." Those sentences go
    only to that editor, judged at the moment of the refusal (so a live
    temporary grant counts); everyone else is told why they were actually
    refused ([refusal wording](#refusal-wording-names-the-reason)).
  - **Rolling back** is safe: there is no migration and no data change, and
    the previous release's policies apply again.
  - **Guides.** [The editorial workflow](../editorial-workflow.md#7-take-it-down),
    the [policy matrix](../policy-matrix.md),
    [content lifecycles](../content-lifecycles.md#authorization),
    [api.md](../api.md), [json-api.md](../json-api.md),
    [headless-graphql-api.md](../headless-graphql-api.md) and
    [beta-testing.md](../beta-testing.md).

<a id="breached-password-bootstrap-return"></a>

- **`KilnCMS.Accounts.Bootstrap.create_first_admin/1` returns `{:ok, user, notices}` (#2240).**
  `notices` is `[:password_breach]` when the typed password is in a known
  breach and the site's policy allowed it, `[]` otherwise. Before it returned
  `{:ok, user}`. The core `/setup` wizard is updated; an overlay or script that
  matches `{:ok, user}` on this call must match the three-tuple. The error
  returns (`{:error, :already_bootstrapped}`, `{:error, changeset_error}`)
  are unchanged. The breach lookup now happens before the advisory-locked
  transaction, so the lock is never held while waiting on the third party.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

<a id="registration-no-enumeration"></a>

- **Registering no longer signs the user in: everyone is told to check their email and sent to `/sign-in`, and an address that already has an account gets no new row (#2255).**
  Registering an address that already had an account failed with "has already
  been taken", while a new address succeeded, so the form answered "does this
  address have an account?" for anyone who asked. Now a new and a known address
  get the same answer, "Check your email - we have sent instructions for what to
  do next.", and the same redirect to `/sign-in`. Neither is signed in.
  - **What happens to a known address.** No row is created. Its owner is mailed
    "Someone tried to create a (site name) account with your address", with
    links to the sign-in and reset pages and nothing else. The mail is budgeted
    per address by `AccountThrottle` (`mail:registration_notice`, 5 per hour,
    like reset and magic-link mail) and dropped silently when spent.
  - **Who notices.** Anyone who relied on registering and landing signed in.
    Code that calls `AshAuthentication.Strategy.action/4` for
    `:register_with_password` directly now gets an error that satisfies
    `KilnCMS.Accounts.Errors.AlreadyRegistered.in?/1` for a known address, not
    the identity's "has already been taken". Show such a caller the same answer
    a success gets; naming the address as taken reopens the oracle.
  - **Rolling back** is safe: there is no migration and no data change.
  - **Rest of the audit.** See the next entry and the matrix in the
    [threat model](../threat-model.md#account-enumeration-by-surface-2255).

## Added

<a id="security-alerts"></a>

- **Security alerts: a site's admins hear about a new admin, a raised role,
  a lockout, two-factor turned off or a single sign-on change as it happens,
  by bell and email, and platform admins about new platform admins, new API
  keys and a stolen API key used again (#2245, first of three parts).** The
  security log (#2241) said what happened only to someone who went and read
  it.
  - **What alerts.** Site kinds `new_admin`, `role_elevation`,
    `failed_sign_ins` (10 failed sign-ins on the site in 15 minutes; off by
    default), `lockout`, `two_factor_disabled` and `sso_config_changed`.
    Platform kinds `new_admin` (an account's own role made admin),
    `platform_role_changed`, `new_api_key` (not a rotation) and
    `api_key_abuse`. Alerts are raised from security log events, in the
    event's own transaction.
  - **Who hears.** A site alert goes to the site's member admins only, not to
    platform admins; a platform alert goes to every platform admin, in the
    default site's bell. Editors, viewers and other sites' admins never do.
  - **How often.** One alert per kind per 15-minute window (per site, or for
    the platform), then one summary with the window's count if more
    followed. Failed sign-ins are counted per site, never per address or
    account an attacker picks.
  - **Organization → Security alerts** (`/editor/security-alerts`, admins):
    tick the site kinds, switch the admins' bell and email off (webhooks still
    go), and choose whether alerts show the full IP address or only its
    `/24` or `/48`, the default. Platform alerts always show the network only.
  - **Your settings → Email notifications → Security alerts** mutes the
    email of site alerts for yourself; the bell row is still written.
    Platform alerts and notices ignore it, and only the account holder can
    change it.
  - **Turning alerts down is never silent.** Switching a kind or the admins'
    notifications off, changing, deleting, re-keying or auto-disabling a
    webhook subscribed to `security.*`, another person removing, demoting or
    ending the temporary grant of a site admin, and changing the site's mail
    relay each send the site's member admins an `alerts_silenced` notice that
    no setting or mute stops. If the notice can't be written, the change is
    refused.
  - **Webhooks.** Opt-in `security.<site kind>` and `security.alerts_silenced`
    events, signed like every other delivery, with `phase` `alert`, `summary`
    or `notice`. Platform alerts are not webhook events yet.
  - **Security log.** New event type `api_key_reuse_detected`. Role events
    gain `level` (`site` or `platform`), `role_revoked` gains `change`
    (`removed`, `demoted`, `grant_revoked`), `role_granted` and
    `elevation_granted` gain `via` (`legacy_carry`), and `api_key_created`
    gains `via: "rotate"`. Replacing a live temporary admin grant with a lower
    one now also records a `role_revoked`.

  Guide: [Security alerts](../security-alerts.md). Upgrade:
  [the upgrade note](#security-alerts-upgrade).

<a id="refire-notify"></a>

- **`mix kiln.refire_all --notify` re-fires every published document and
  tells webhook receivers about each one (#2463).** A plain sweep is silent:
  revalidating clients now see the new body (its `ETag` moves, [below](#render-etags)),
  but a static build, an ISR page or a mirror that waits for a webhook never
  heard that the markup changed after an upgrade.
  - **What it sends:** for each document whose fire completes,
    `<type>.updated` to every endpoint subscribed to it, with
    `"reason": "refire"` in `data`, and the same `updated` on the public
    change feed (which does not carry the reason). On a release:
    `/app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run(notify: true)"`.
  - **What it doesn't:** automation rules, federation and the CDN purge do
    not run. A re-render is not an edit, and every published document at
    once would run every "on updated" rule, announce the whole site to its
    followers, and purge the CDN every few seconds for as long as the sweep
    ran. Purge once when `KilnCMS.Firing.Sweep.pending/0` reaches `0`
    (`KilnCMS.CDN.purge_site/1` per site, or the `kiln` surrogate key at
    your CDN).
  - **Volume:** one delivery per published document per endpoint, on the
    `webhooks` queue your editors' publishes use too. A receiver that answers
    `429` until deliveries run out of retries can trip auto-disable (10 in a
    row by default). Run it off-peak. The walk-through is
    [Re-render published content after an upgrade](../releasing.md#re-render-published-content-after-an-upgrade).
  - **`reason` on other `updated`s:** `KilnCMS.Firing.refire/3` (#2048) now
    marks its `updated` with `"reason": "refire"` too; it still reaches
    automation, federation and the CDN purge as before. An edit's `updated`
    carries no `reason` key, so its payload is unchanged. A receiver that
    drops an `updated` whose `updated_at` it has already seen must not drop
    one with a reason: the body changed and `updated_at` did not.
  - The default sweep and `KilnCMS.Firing.Sweep.sweep_type/2` (an SEO
    pattern change, #1135) stay silent. A publish made while the sweep's job
    for that document is pending is merged into it, so that document also
    gets an `updated` marked `refire` after its own event.
  - `/api/sync` does not report a re-fire, because it reads `updated_at`;
    a mirror picks the new body up on its next full resync (`initial=true`).

<a id="twitter-card-tags"></a>

- **Site admins can set the site's X (Twitter) username, and link previews
  are built from one resolution: no empty tags, absolute images on the site's
  own host, and the same values for Open Graph and X (#2258).** For site
  admins, front-end developers and anyone sharing links.
  - **X (Twitter) username.** A new field in **Delivery → Branding**,
    **Identity** section (site admins only). It accepts `kilncms`, `@kilncms`
    or an `x.com` / `twitter.com` profile URL (with `www.` or `mobile.`, a
    trailing slash, and a `?s=21`-style query or fragment), stores
    `@kilncms`, and refuses anything else, including X's own pages (`home`,
    `i`, `explore`, `search`, `settings` and the like), with "must be an X
    (Twitter) username like @kilncms". Pages then carry
    `<meta name="twitter:site">`. It is per site only: there is no
    environment variable or instance-wide default. A site that added
    `twitter:site` under **Code injection** should remove it, or the tag
    appears twice.
  - **One resolution for both sets of tags.**
    `KilnCMSWeb.Layouts.social_meta/1` feeds `og:title`/`twitter:title`,
    `og:description`/`twitter:description`, `og:image`/`twitter:image`,
    `twitter:card` and `twitter:site`. A tag with no value is left out, never
    sent as `content=""`. The title falls back to the site name, so the stock
    home page now has `og:title` and `twitter:title`. A blank page image falls
    through to Branding's Default social image instead of an empty tag. The
    card is `summary_large_image` when there is an image (the page's or the
    site's), else `summary`.
  - **Absolute images.** `og:image`, `twitter:image` and the JSON-LD `image`
    are now always absolute on the site's own address (custom domain, else
    subdomain, else `PUBLIC_BASE_URL`), including a page's own site-relative
    Social image, which used to go out relative. `KilnCMSWeb.Tenant.absolute_url/2`
    is the one place that decides this; a relative image with no site to
    resolve it against is dropped.
  - **No separate social override fields.** The SEO title, SEO description and
    Social image are the overrides, so a search result and a link preview
    never disagree about a page.
  - **`social` on the `json` artifact.** `{"title", "description", "image"}`:
    the effective SEO title (else the title; `null` only with no title), the
    effective SEO description and the SEO image made absolute, the last two
    omitted when there is none. The image's host is fixed when the document
    is fired, so re-fire after changing a site's domain. It is per document
    only: no card type, no `twitter:site` and no Branding fallback image,
    because those belong to the site, and Branding is not on any API yet, so a
    front end supplies its own handle and default image. `?fields=social`
    returns it alone, and under an experiment `social.title` stays canonical.
    `GET /api/schema` adds `social` as an optional property, and the
    generated TypeScript, Swift and Kotlin models gain it. JSON:API, GraphQL,
    MCP and webhook payloads are unchanged.
  - **Not yet:** `twitter:creator`, and `og:image:alt` / `twitter:image:alt`
    (the Social image stores no alt text).
  - Guides: [Link previews](../seo.md#link-previews-open-graph-and-x-twitter-cards)
    (with the how-to) and, for front ends,
    [the `social` object](../headless-consumer-guide.md#link-previews-the-social-object).

<a id="plugin-health-checks"></a>

- **Platform admins can see whether each installed plugin still checks out:
  whether its package changed on Hex since this build, whether a security
  notice covers the installed version, whether Hex retired it or it has gone
  unreleased for two years, and whether its `kiln_plugin` requirement accepts
  this Kiln (#2244).** For platform admins at **Operations → System →
  Plugins**, in the **Installed plugins** line of Security posture
  (`core.plugin_health`, **This installation**), and from
  `mix kiln.plugins.list --health`. Guide:
  [Check your installed plugins](../security-posture.md#check-your-installed-plugins).
  - **Badges on System.** Each plugin gets one: **OK**, **Changed on Hex
    since this build**, **Security notice**, **Not on Hex**, **Retired**,
    **No recent release**, **Incompatible with this Kiln**, **Can't verify**
    (git, path or private-repo plugins), **Built from this project**
    (`projects/` plugins) or **Unknown**. Under it, one line per problem,
    shortened checksums for a changed package, a link per advisory and the
    latest version on Hex. **Check plugins now** asks again, at most once a
    minute.
  - **Security posture.** **Fix now** for a changed package, a high,
    critical or unrated notice, or a release retired for security; **Review**
    for the other problems. Git and path plugins pass there, with a note
    that only notices and the SDK requirement were checked.
  - **Unknown is never OK.** A source that failed, timed out, answered
    something unreadable or returned a list longer than five pages makes the
    plugins it concerns **Unknown**.
  - **What "Changed on Hex" means.** The checksum recorded from this build's
    lockfile no longer matches the one hex.pm publishes for that version.
    `mix deps.get` already refuses a lockfile that disagrees with Hex, so this
    means Hex's record changed after the build, the build used a mirror or an
    offline cache, or the lockfile was edited by hand. It does not re-hash
    the compiled code in the running release.
  - **Where notices come from.** Hex's advisories on the installed release,
    and kilncms.dev's notices feed (#1873), which lists Kiln's and the Kiln
    project's own plugins only: a third-party plugin's notices come from Hex
    alone. A kilncms.dev notice that names several packages can only clear a
    plugin, or leave it **Unknown**, because its ranges aren't recorded per
    package.
  - **No alert.** A check that finds a failing plugin logs one warning
    ("Plugin health check failed for: …"); alerting is #2245.
  - **Configuration.** `KILN_PLUGIN_HEALTH_CHECK` (unset follows
    `KILN_UPDATE_CHECK`), `KILN_SECURITY_NOTICES_URL` and
    `KILN_PLUGIN_STALE_MONTHS` (default 24); see
    [the variables](../environment-variables.md#plugin-health-check-2244).
    The request and its disclosure are in the
    [upgrade note](#plugin-health-egress-upgrade).
  - **For developers.** `Kiln.Plugins.Health` (`check/1`, `cached/1`,
    `warm/0`), the pure `Kiln.Plugins.Health.Evaluate`, and
    `Kiln.Plugins.LockRecord`, which records the lockfile's coordinates at
    compile time because a release carries no `mix.lock`. Not exposed on any
    API. Design: [Plugin system §7](../plugin-system-plan.md#7-plugin-health-checks-2244).

<a id="backup-step-chain"></a>

- **In-app backups run as a chain of retried steps behind a cluster-wide lock:
  a second backup queues instead of overlapping, a failed step is retried
  rather than failing the backup, a stopped node's backup moves on without it,
  and a platform admin can cancel a running backup (#2218, last part).** For
  platform admins at `/editor/backups` and for operators.
  - **Steps.** `start`, `dump`, then with a media directory `plan`, one
    `archive` job per part and `checksum`, then `prune`, `offsite` and
    `finish`, each its own Oban job on the `backup_steps` queue, handing over
    through `.work/<stamp>/state.json`. Each step has four attempts, 1, 5 and
    15 minutes apart (fixed), and 2 hours per attempt. A failed `rclone copy`
    is now retried this way too, after rclone's own retries.
  - **Failures a retry can't fix fail at once.** A media part that changed on
    disk between being archived and being checksummed fails the backup and
    names the parts; Resume rebuilds them. A file refused before its off-site
    copy fails it as before (#2481). A step that finds its `state.json` gone
    fails the backup without writing a manifest, so a good one is never
    overwritten with nothing.
  - **One backup at a time.** A request while a backup runs queues behind it;
    at most one waits, and later requests fold into that one (logged at
    `info`, telemetry `[:kiln_cms, :backups, :request, :folded]`). The queued
    backup starts, with its own stamp, when the running one ends. **Back up
    now** no longer disables while a backup runs; a strip shows the step
    ("Archiving media: part 2 of 5"), the stamp and the queued request, and
    the page refreshes while it runs.
  - **Cancel.** A **Cancel** button on the strip and on a `Running` History
    row, for platform admins (enforced by the `Backups.Run` `:cancel` policy,
    not only the page). It stops the step jobs and the `pg_dump`, `tar` or
    `rclone` they started, releases the lock (a queued backup starts next),
    marks the run `Canceled`, and records a **Backup canceled** event in the
    default site's security log. It writes no `manifest.json` and keeps every
    file, so **Resume** continues a canceled backup. A backup that has reached
    `finish` can't be canceled.
  - **Nodes that stop.** Every node beats every 30 seconds (database clock).
    A step whose node has not beaten for 180 seconds, or restarted, is
    requeued with the attempts it had left, under the same stamp, reusing
    finished files (telemetry `[:kiln_cms, :backups, :lock, :reclaimed]`); a
    node that cannot beat for 90 seconds stops its own steps first. A step job
    that ended without handing over fails the backup as "Interrupted". A
    chain's end emits `[:kiln_cms, :backups, :chain, :settled]`.
  - **Several hosts.** With a `BACKUP_DIR` per host, every step after `start`
    runs on the host whose directory the backup started in
    (`<BACKUP_DIR>/.kiln-dir-id`); with one shared volume, any node runs any
    step.
  - **Smaller changes.** A database-only backup (S3 media adapter, or no
    media directory) now keeps a work directory and can be resumed. A
    trigger is cut to 64 characters and redacted when the backup is
    requested. External commands (`pg_dump`, `pg_restore`, `rclone`, `tar`)
    are killed when the step running them dies
    (`KilnCMS.ExternalCommand.run/4` gains `:env` and `:tail`).
  - **Not included.** A queued request can't be removed, only canceled once
    it starts. `scripts/backup.sh` does not take the lock.
  Guide: [How an in-app backup runs](../backups.md#how-an-in-app-backup-runs-2218).
  Upgrade: [the upgrade note](#backup-step-chain-upgrade).
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))

<a id="security-posture"></a>

- **A read-only Security posture page says which security settings are on,
  and what to fix first (#2252, first of three parts).** Kiln had governance,
  compliance and advisory pages, but nothing that told an administrator
  "this site is configured safely". The page is **Configure → Organization →
  Security posture** (`/editor/security-posture`). It changes nothing: each
  line links to the screen that does, or names the environment variable.
  Guide: [Security posture](../security-posture.md).
  - **Who sees what.** A site's administrators see **This site**: two-step
    sign-in for the site's administrators and editors, idle sign-out, the
    admin allowlist and the breached-password policy. Platform administrators
    also see **This installation**: their own two-step sign-in, HTTPS and
    secure cookies, exposed endpoints (metrics, API explorer, GraphQL
    introspection), API keys, human verification and the Kiln version.
    Editors and viewers can't open it.
  - **No score.** The summary is the worst line (Fix now, Review or OK) and a
    count of each status. A check that could not read its setting shows
    **Unknown**, and one that crashed, overran its deadline or answered
    nonsense shows **Could not run**; both count as a warning, never a pass.
  - **Same reads as enforcement.** Each core check asks the function the gate
    it reports on uses (`IdleTimeout`, `AdminAllowlist`, `PasswordPolicy`,
    `KilnCMS.Challenge`, the endpoint's compiled configuration). Where that
    function fails open, the check uses a twin that can say "could not read"
    (`IdleTimeout.read_policy/1`, `PasswordPolicy.read/2`,
    `AdminAllowlist.configured/1`). A passkey is not counted as a second
    factor: it does not protect the same account's password sign-in.
  - **A check cannot take the page down.** Every check runs in its own task
    under `KilnCMS.Security.Posture.TaskSupervisor` (at most 50 per node), with
    its own deadline (one second by default, held to 0.1–5 s), enforced by
    the task itself so it holds even when the page has gone. **Run checks
    again** is refused while a run is in flight and for five seconds after
    the last one, and at most three reports of one site run at once per node
    (`KilnCMS.Security.Errors.PostureBusy`).
  - **One more trigger for the update check.** The Kiln version check reads
    only `Kiln.Updates`' cache. On a cold cache it starts one background
    check (`Kiln.Updates.warm/0`, at most one in flight per node) and shows
    "unknown, reopen in a minute". So the request to kilncms.dev (then
    GitHub) can now also be sent when a platform administrator opens this
    page, not only from **System**. Same request, same cache, same opt-out
    (`KILN_UPDATE_CHECK=false`); [data flows](../data-flows.md) is updated.
  - **Plugins (`kiln_plugin` 1.4).** `c:Kiln.Plugin.security_checks/0`
    (default `[]`) lists `Kiln.Security.Check` modules: `id/0`, `title/0`,
    `scope/0` (`:site` or `:deployment`), `run/1` and optional
    `description/0` and `timeout/0`. `run/1` gets a
    `Kiln.Security.Check.Context` (site, build environment, time, reader's
    locale; no actor) and answers a `Kiln.Security.Check.Result`, which the
    core trims to its limits; a `fix_path` outside `/editor/` or a non-`https`
    `docs_url` is dropped. Ids under `core.` are reserved; of two plugins
    sharing an id the first registered wins. `mix kiln.plugins.doctor`
    checks conformance, reserved ids and collisions; `mix kiln.plugins.list`
    counts each plugin's checks. A plugin built against an older SDK adds
    none. Authoring guide:
    [Add a check from a plugin](../security-posture.md#add-a-check-from-a-plugin).
  - **Developers.** `KilnCMS.Security.PostureReport` (action `:run`,
    org-admin policy, code interface `KilnCMS.Security.run_posture/2`, site
    from the tenant) returns a `KilnCMS.Security.Posture.Report`. It is not
    on JSON:API, GraphQL or MCP. Telemetry:
    `[:kiln_cms, :security_posture, :check, :stop]` and `:exception`.
  - **Not yet.** JSON output for monitoring, matching security notices and
    plugin advisories against installed versions, a check that two-factor
    sign-in is required, and API key last-use. No migration.

<a id="field-layout"></a>

- **Admins can lay out a content type's custom fields as tabs, fieldsets or
  accordions, and set a field's width so short inputs sit side by side
  (#2280).** For types with many fields, where one long scroll of inputs is
  hard to fill. Grouping stays what it was, the field's **Section**; this adds
  how each section is shown. Guide:
  [Lay out custom fields as tabs, fieldsets or columns](../extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns).
  - **Admins.** At **Fields** (`/editor/fields`), each type with sections gets
    a **Sections of** *type* panel: **Shown as** accordion (the default),
    fieldset (always open, no toggle) or tab, and, for an accordion, when it
    **Starts** (automatically, open or closed). Each change saves at once.
    The field forms gain **Width**: full row, half or a third.
  - **Editors.** The **Custom fields** panel shows the layout. All the tab
    sections of a type form one tab set, at the place of the first of them,
    using the WAI-ARIA tabs pattern (Left/Right, Home/End). A tab holding an
    error shows an icon; a required empty field in a hidden tab or collapsed
    accordion is brought into view when the browser blocks the save. Hidden
    inputs still submit. Narrow fields share a row within their section and
    stack below the small breakpoint. A type with no layout set renders as
    before.
  - **Known limits.** Once the writer has picked a tab, a save the server
    refuses does not switch to the tab holding the error (its icon marks it).
  - **Promotion.** `mix kiln.promote_data` moves a dynamic type's section
    layouts to the compiled type along with its fields.
  - **Schema export.** `GET /api/schema` and `mix kiln.export.schema` add
    `x-kiln-section-display` (`fieldset` or `tab`; absent for an accordion)
    and `x-kiln-width` (`half` or `third`; absent for full) to each custom
    field. Additive. JSON:API, GraphQL, MCP and the OpenAPI document are
    unchanged: `width` is not a public attribute and the layouts have no
    API route.
  - **Field sync.** Each field carries `width`; each owner carries a
    `sections` list (`name`, `display`, `initially`) of the layouts its fields
    still use. An owner without the key leaves the target's layouts alone; with
    it, `--prune` deletes layouts it does not list. Deleting a section's last
    field, in the console or by a pruning import, deletes its layout. See
    [field-sync.md](../field-sync.md).
  - **Developers.** New resource `KilnCMS.CMS.FieldSection` (admin writes,
    editor and `:schema_export` reads; code interfaces
    `CMS.create_field_section`, `update_field_section`,
    `destroy_field_section`, `list_field_sections`, `field_sections_for`
    and `field_sections_for_definition`), helper module
    `KilnCMS.CMS.SectionLayouts`, and `FieldDefinition.width`
    (`:full | :half | :third`, forced to `:full` on link fields and group
    sub-fields).
  ([#2280](https://github.com/The-Verscienta/kiln_cms/issues/2280))

<a id="field-widgets"></a>

- **Admins can choose the editor input a custom field uses: radio buttons or a row of buttons for a select, checkboxes for several terms, one line for plain text, a dropdown list for a reference, or a plugin type's own (#2284).**
  In `/editor/fields`, a field that has a choice shows an **Editor input** group of cards, its type's default first and checked; the list of fields badges a field that uses anything else. The choice is stored in the field definition's new `widget` attribute (a string; `nil` is the default, today's input). It is editor-only: what is stored, validated and delivered does not change. Guide: [Choose how editors fill in a field](../extending-content.md#choose-how-editors-fill-in-a-field).
  - **What is offered.** A single select: `dropdown` (default), `radios`, `buttons`. Several terms: `tags` (default), `checkboxes`, but not while editors may add new terms (`allow_custom`); the fields admin disables whichever of the two is not in use and says why. Plain text: `textarea` (default), `single_line`. A single reference: `autocomplete` (default), `dropdown`. Rich text, lists of references, link fields, group sub-fields and every other core type offer no choice.
  - **Safe by construction.** Radios and checkboxes show a stored value that is no longer among the options as its own checked input, so a save keeps it. A one-line field whose value already holds a line break opens as a textarea, so a save keeps the breaks. A field with more than 50 options keeps the dropdown or tags in the editor whatever is chosen, and the fields admin warns on those cards. A radio group required by a **Required when** rule is required the way a browser requires one (`required` on its first radio, `aria-required` on the group).
  - **Checkboxes reorder.** Saving a record whose field uses checkboxes stores its terms in the field's option order, with terms outside the options after them.
  - **The reference dropdown** lists the targets the editor could find by searching, in the editor's own site, sorted by title and grouped by type on a field with several target types, at most 100 in all. Past 100 the editor keeps the search box and says *Too many to list — search instead.* A target full under `max_sources` is listed disabled, the current pick is always listed (as *Unavailable* when the editor can't read it), and **Add new** still works. The list is read once when the editor opens.
  - **Changing the field resets, a write that names a widget is refused.** A retype, `multiple`, rich text or `allow_custom` clears a stored widget the field no longer offers, unless the same write names one; then it is refused (`radios is not an editor input for this field (use one of: …)`). Field sync sends the file's widget with every update, so a file whose settings no longer suit its widget is refused rather than silently corrected.
  - **API and export.** Field definitions carry `widget` on JSON:API (`?include=field_definitions`, and in `docs/api/openapi.json`) and in field-sync files. The schema export adds `x-kiln-widget` only to a field whose chosen widget it still offers. GraphQL does not expose field definitions and is unchanged.
  - **Plugins.** `Kiln.FieldType` gains the optional `widgets/1` (not defaulted by `use`) and `Kiln.FieldType.widget/2` to read the pick back inside `input_attrs/1`, `input_parts/1` or `input_hook/1` (`kiln_plugin` 1.4). `input_type/0` takes no definition, so a widget cannot change the input's HTML `type`. `mix kiln.plugins.doctor` reports a `widgets/1` that raises, returns a non-list, or lists a malformed or repeated name.

<a id="registration-approval"></a>

- **A site can make new password sign-ups wait for an administrator's
  approval (#2251, first of three parts).** Open registration let anyone
  become a viewer straight away; a site can now hold them without turning
  registration off.
  - **Turning it on.** A site admin opens **Registrations** under
    **Sign-in & access** (`/editor/registrations`) and ticks **New
    registrations wait for an administrator's approval** under **Settings**.
    Off by default, per site, no environment variable.
  - **What waiting means.** The account is created with a `:pending`
    membership on the site. `KilnCMS.Accounts.Scoping` grants nothing through
    a membership that is not `:active`, so every surface treats the account
    as an anonymous reader, on every site, the default one included: no
    console, no gated content, no drafts, no comments, `"role": "none"` from
    `POST /api/auth/sign_in`. It can sign in, and `/account` says "Waiting for
    approval on (site)".
  - **Deciding.** The page lists confirmed applicants, unconfirmed ones and
    rejected ones, each paged 50 at a time. **Approve** makes the row an
    ordinary *Viewer* membership; **Reject** keeps the account and marks the
    row rejected. An unconfirmed address can be rejected but not approved,
    because anyone can register an address they don't own. A rejection can
    be undone by approving from the **Rejected** tab. Each decision locks the
    row, so two admins can't both decide it. Only an admin of the site the
    row belongs to (or a standing platform admin) may list or decide.
  - **Default site.** A sign-up on a site without approval is queued on the
    default site when that one requires approval, since it would otherwise be
    an unreviewed viewer there.
  - **Never queued.** Invitations, the deployment's single sign-on, and
    existing accounts. A site's own single sign-on can be held with a switch
    of its own, and an invitation or **Add or invite** approves a waiting or
    rejected registration rather than being refused
    ([part three, first half](#registration-invitations-sso)).
  - **Paying is not a way in.** On a site that requires approval, starting a
    paid membership is refused for an account not let in there, and the
    entitlement recompute creates no viewer membership for one.
  - **Fails closed.** If the setting cannot be read, the sign-up is refused
    with a retryable error and nothing is created.
  - **Later parts.** Telling admins and applicants is part two
    ([below](#registration-notifications)). Queueing a site's own SSO and
    invitations over a registration are the first half of part three
    ([below](#registration-invitations-sso)), and erasing unconfirmed
    rejected accounts is its second half ([below](#registration-erasure)).
  - **Security log.** `registration_queued` (`method`),
    `registration_approved` (`role`, `via`) and `registration_rejected`
    (`outcome`); see
    [the security log](../security-events.md#what-is-recorded).
  - **Developers.** `OrgMembership` gains `status` (`:active`, `:pending`,
    `:rejected`) and `decided_at`, set only by the new actions
    `:queue_registration` (system-only), `:approve_registration`,
    `:reject_registration` and the `:registration_queue` read, with code
    interfaces on `KilnCMS.Accounts`. `for_org` now returns active rows only.
    `KilnCMS.Accounts.Registrations` pages the queue;
    `KilnCMS.Accounts.Errors.RegistrationRefused` names refusals. The
    setting is `KilnCMS.CMS.SiteRegistration`.
  The reasoning is in
  [ADR 0024](../decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md);
  the how-to is
  [Approving registrations](../account-administration.md#approving-registrations).

<a id="registration-notifications"></a>

- **A site's admins hear when a registration is waiting for them, and the
  applicant is emailed the decision (#2251, second of three parts).** Part one
  left both to the admin checking the queue and telling people themselves.
  - **When admins hear.** When an applicant confirms their address: by the
    confirmation link, by a password reset, or by accepting an invitation with
    a password. That is when the registration can be approved, so registering
    alone tells nobody. Every site where the applicant waits is told. A
    magic-link sign-in does not confirm an account, so it tells nobody either
    ([#2516](https://github.com/The-Verscienta/kiln_cms/issues/2516)).
  - **What admins get.** One bell notice per admin and site, "Registrations
    waiting for approval", titled with the site's name and linking to
    **Registrations** (`/editor/registrations`), plus an email "Registrations
    are waiting for approval on (site)" with a **Review registrations** link
    on the site's own host. While the notice is unread, further applicants add
    no notice and no email, so a wave of sign-ups is one of each. Opening
    **Registrations** marks your notice read, and the next applicant after that
    is news again. Neither the notice nor the email names the applicant.
  - **Who.** A standing platform admin, or a member whose active membership
    on the site is admin (a site's temporary admin grant counts). A temporary
    platform admin is left out, since it can't decide registrations, and so
    is an erased account.
  - **Muting.** **Your settings** → **Email notifications** → **New
    registrations — email me when someone is waiting for approval on a site I
    administer**. It mutes the email only; the bell notice is always written.
    One switch for every site you administer, shown to anyone who would be
    told on some site.
  - **What the applicant gets.** After the decision commits, approving mails
    "Your registration on (site) was approved" with a **Sign in** link on the
    site's host, including when an admin approves from the **Rejected** tab.
    Rejecting mails "Your registration on (site) wasn't approved." under the
    subject "About your registration on (site)", with no reason, no link and
    no name. A rejected applicant who never confirmed their address gets no
    email, since the address was never proven theirs, and an erased account
    gets none. Both emails, and the admin email, go through the site's own
    mail relay when it has one. The approve message on the page now ends
    "We'll email them.", and the reject prompt for a confirmed applicant adds
    "They'll be emailed that it wasn't approved."
  - **Erased applicants.** A waiting account that was erased shows **Account
    erased** in the queue and has no **Approve**; approving it from code is
    refused with `RegistrationRefused` reason `:erased`. It can still be
    rejected.
  - **Best effort.** Notices and emails run after the commit. A failure is
    logged and never undoes the confirmation or the decision.
  - **Account data.** `export_user_data` now includes `notify_on_comment` and
    `notify_on_registration`, and erasure resets both to on.
  - **Developers.** `Notification.event` gains `:registration_pending`
    (anchored on `content_type: "registration_queue"`, `content_id` = the
    site's id, no actor). `KilnCMS.Notifications.Registrations` holds the
    roster and `announce_org/1` for a path that queues an already-confirmed
    account. `Notifications.record_in_app_result/1` says whether a row was
    written (`:recorded`, `:already_waiting`, `:not_recorded`), and
    `Notifications.mark_read_about/4` marks one subject's unread notices
    read. `NotificationText.headline/1` gains a neutral "Notification" for an
    event it doesn't know, rather than crashing.
  Upgrade steps: [the upgrade note](#registration-notifications-upgrade). The
  reasoning is in
  [ADR 0024](../decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md#who-is-told-part-two);
  the how-to is
  [Approving registrations](../account-administration.md#approving-registrations).

<a id="registration-invitations-sso"></a>

- **An invitation now decides a registration waiting on its site, and a site
  can hold new accounts from its own single sign-on for approval too (#2251,
  part three, first half).** Before, accepting an invitation left the
  invitee's registration waiting behind a membership that never came, Team's
  **Add or invite** refused such an address, and a site's own provider made
  every new account a viewer at once.
  - **Accepting an invitation** (one click for a confirmed account, or
    choosing a password for an unconfirmed one) over a waiting registration
    on the invitation's site approves it with the invited tier and custom
    role. Over a **rejected** registration it does so only when the
    invitation was sent, or last resent, after the rejection; an older
    invitation is "no longer valid" and the registration stays rejected, so
    an invitation can't silently undo a later decision. The applicant gets
    no decision email, since they just accepted.
  - **Add or invite** on Team, for a confirmed account with a registration
    on the site, approves it at once with the chosen tier and mails the
    usual "You were added" notice: "Their registration on this site is
    approved, and they are now a member." For a rejected registration the
    message is "Their registration on this site had been rejected; it's now
    approved, and they are a member.": a platform admin adding someone is a
    decision made now, so it overrides a rejection of any age, and says so.
    An unconfirmed address is invited as before; an erased account's address
    no longer matches it and is simply invited. The refusals "is waiting for
    approval — approve it under Registrations" and "registered on this site
    and was rejected" are gone.
  - **A site's own single sign-on.** A second switch on **Registrations**,
    **New accounts from this site's single sign-on wait for approval too**
    (`approval_for_site_sso`, off by default, independent of the password
    setting), makes a new account the site's provider creates wait as a
    pending registration. It is signed in but has no access anywhere until
    approved, and the site's admins are told straight away, since the
    provider has verified the address. Existing accounts sign in as before
    ([#2515](https://github.com/The-Verscienta/kiln_cms/issues/2515) tracks
    them). If the setting can't be read, the first sign-in is refused with
    "Single sign-on isn't available on this site right now. Sign in another
    way." and nothing is created.
  - **Security log.** `registration_queued` has `method` `site_sso` for a
    held single sign-on account, with the request's client address.
    `registration_approved` has `via` `invitation` (no person: the system
    honours the invitation) or `added` (the platform admin), besides `queue`.
  - **Developers.** New `OrgMembership` action
    `:approve_registration_by_invitation` (code interface
    `Accounts.approve_registration_by_invitation/3`; arguments `role`,
    `role_id`, `invited_at`, `via`), admitted for the `:invitations` system
    actor and a standing platform admin only. `RegistrationRefused` gains
    `:rejected_after_invitation`; `InvitationRefused` loses
    `:pending_registration` and `:rejected_registration`.
    `Invitations.AddOrInvite` returns the outcomes `:approved` and
    `:approved_over_rejection`. `:queue_registration` takes `method`
    (`:password` or `:site_sso`) and `new_account?`, stored as the new
    `OrgMembership.created_account` attribute: whether the registration
    created the account, groundwork for erasing rejected accounts.
    `SiteRegistration` gains `approval_for_site_sso`, and
    `RegistrationPolicy.settings/1` reads both switches.
    `SiteSso.sign_in/5` and `SiteSso.Admission.admit/3` take the request's
    Ash context as an optional last argument, and `admit/3` can refuse with
    `:registration_settings_unavailable`. `Changes.EvictSessions` with
    `after_commit?: true` now sends its eviction through
    `KilnCMS.AfterCommit.run/1`, so an approval nested in another action's
    transaction evicts after the outer commit; a caller nesting it holds the
    effect with `AfterCommit.deferring/1` or `capture/1`.
  Upgrade steps: [the upgrade note](#registration-invitations-sso-upgrade).
  The reasoning is in
  [ADR 0024](../decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)
  (part three);
  the how-to is
  [Invitations and registrations](../account-administration.md#invitations-and-registrations)
  and
  [Hold new single sign-on accounts too](../account-administration.md#hold-new-single-sign-on-accounts-too).

<a id="registration-erasure"></a>

- **A site can erase the account of an applicant it rejects when the email
  address was never confirmed (#2251, part three, second half; #2514).**
  Before, every rejected account was kept, so a wave of bot sign-ups left an
  account per address that nobody proved they owned, and the address stayed
  taken on the site.
  - **The setting.** **Registrations** → **Settings** → **When you reject
    someone**: **Keep the account** (the default) or **Erase the account if
    the email address was never confirmed**
    (`SiteRegistration.rejected_accounts`, `:keep` or `:erase_unconfirmed`).
    The hint under it reads "Erasing can't be undone. Only accounts whose
    address was never confirmed and that are used for nothing besides this
    registration are erased; a rejected applicant who confirmed their address
    is always kept. An erased address can register again, while a kept one
    can't register here again."
  - **When an account is erased.** Only when all of these hold: the setting
    is on; the **Reject** dialog said the account would be erased (it does
    on rows under **Email not confirmed yet**); a **standing** admin of the
    site, or a standing platform admin, rejects (a temporary admin's
    rejection keeps the account); the address was never confirmed; the
    registration created the account; and the account is nothing but this
    application: a *Viewer* with no temporary role, no audiences, no other
    membership on any site, and no paid membership, API key, content,
    comment, task, media, release, invitation sent, consent or logged event.
    Then the account is anonymized, exactly as a platform admin's erasure,
    in the rejection's transaction; a failed erasure undoes the rejection.
    Otherwise the rejection is the usual one and the account is kept.
  - **What the admin sees.** The dialog reads "Reject (address) and erase
    the account? …", and afterwards "Rejected (address) and erased the
    account." or "Rejected (address). The account was kept, because it's
    more than this registration or it can't be erased right now." The row
    stays on the **Rejected** tab with an **Account erased** badge.
  - **Confirmed rejections are always kept**, whatever the setting: the kept
    account holds the address, which is what stops the same person
    registering on the site again. An erased address is free and can
    register again. Nobody is emailed, since an unconfirmed applicant never
    is.
  - **Races.** The rejection locks the account's `users` row `FOR UPDATE`
    before it checks, and every membership create, paid membership `:start`
    and `:comp`, the entitlement recompute, API key `:create` and `:rotate`,
    and the three updates that confirm an account take it `FOR KEY SHARE`
    first (`KilnCMS.Accounts.AccountLock`). So an erasure never misses a
    footprint or a confirmation being written at the same moment: whichever
    locks first goes first, and the other either keeps the account or is
    refused.
  - **Security log.** `registration_rejected` has `outcome` `erased`, with no
    target, besides `kept`.
  - **Known cost.** The check scans several unindexed referencing columns
    while it holds the lock; it runs only on a rejection that will try to
    erase. Indexes are a follow-up.
  - **Developers.** `OrgMembership` `:reject_registration` takes `erase`
    (boolean, default `false`), a request the setting, the actor and the
    check still decide; the returned row's `__metadata__.registration_outcome`
    is `:erased` or `:kept`. `RegistrationPolicy.settings/1` returns
    `rejected_accounts`. New: `Accounts.AccountLock` (`share/1`,
    `exclusive/1`), `Changes.LockAccount`, `Changes.EraseRejectedAccount`,
    `Changes.GuardRegistrationErasure`, `Registrations.Erasure` (`check/1`,
    `standing_admin?/2`, `blocking/0`, `handled/0`), and the errors
    `AccountErased` (a write to an erased account) and `ErasureRefused`. The
    `:registrations` system actor may now run `User` `:anonymize`, held by
    `GuardRegistrationErasure` to the one account the rejection in the same
    transaction names.
  Upgrade steps: [the upgrade note](#registration-erasure-upgrade). The
  reasoning is in
  [ADR 0024](../decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)
  (part three, c2); the how-to is
  [Erase unconfirmed applicants you reject](../account-administration.md#erase-unconfirmed-applicants-you-reject).
  Erasure itself also deletes more now: [below](#erasure-deletes-more).

<a id="sign-in-unlock"></a>

- **Someone whose password sign-in is paused after too many attempts can
  have a link emailed that lifts the pause (#2250).** Until now the only ways
  out were to wait for the 15-minute window to roll or to reset a password
  that did not need changing.
  - **What people see.** The sign-in page now always shows "Paused after too
    many attempts? **Email me an unlock link**". It leads to
    `/sign-in/unlock`, which asks for an email address and answers every
    address with the same sentence: "If an account with that address is paused
    after too many sign-in attempts, we've emailed it a link to lift the pause.
    The link works once, within 15 minutes." The mail ("Lift the sign-in pause
    on your (site) account") opens `/auth/unlock/(token)`, a page with a
    **Lift the pause** button. Pressing it returns to `/sign-in` with "The
    sign-in pause on your account is lifted. You may be asked to complete a
    check, or to wait a minute if your network is busy." It does not sign
    anyone in. The "Unusual sign-in activity" alert mail now links to the
    request page too (never with a link token in it). The pages are
    translated and need no JavaScript; the mail is in English, like the other
    account mail.
  - **The pause stays undisclosed.** A paused account still answers exactly
    like a wrong password, and the sign-in page shows the link to everyone, so
    it says nothing about which accounts are paused. The request answers
    before it looks the address up; the lookup and the mail happen afterwards
    in a background task.
  - **No new trust.** The link goes only to the account's own mailbox, and
    whoever reads that mailbox can already reset the password, which lifts
    the pause as well.
  - **What it lifts.** Only the account's sign-in counter
    (`AccountThrottle.unlock/1`). Not the per-IP limits, not the free attempts
    before a [human-verification](../human-verification.md) check, not the
    two-factor code budget. The next sign-in still needs the password, the
    second factor and, where the operator turned it on, a check.
  - **Who is mailed.** Only a confirmed, not erased account that is paused
    right now and is a member of the site the request was made on (or the
    legacy no-membership account, on the default site). Never the demo's
    shared account. At most 3 links an hour per address. The link is in that
    site's branding, opens on that site's host and is refused on any other.
    It works once, lasts 15 minutes, and stops working when the password is
    changed or reset or the account's address changes. Opening it spends
    nothing, so a mail scanner that follows it does not use it up.
  - **Security log.** Three new types: `sign_in_unlock_requested` (Sign-in
    unlock link sent; `surface`), `sign_in_unlocked` (Sign-in pause lifted by
    email; `was_locked`) and `sign_in_unlock_refused` (Sign-in unlock link
    refused; `reason`). Refusals are sampled like failed sign-ins. See
    [The security log](../security-events.md#what-is-recorded).
  - **Not an API.** There is no JSON endpoint: `POST /api/auth/sign_in` still
    answers a paused account with the same `401` as a wrong password, and
    recovery is browser-only.
  - **Operators.** No migration, no environment variable. The new routes sit
    behind the [admin allowlist](../admin-allowlist.md) with the other sign-in
    pages and pay the per-IP `:auth` limit. A burst of requests beyond what
    the unlock's own task supervisor holds (20 at once) is dropped with a
    warning at most once a minute and the
    `[:kiln_cms, :accounts, :sign_in_unlock_shed]` telemetry event
    ([observability](../observability.md#sign-in-unlock-requests)).
  - **Developers.** Two system-only `User` actions,
    `:request_sign_in_unlock` and `:redeem_sign_in_unlock`
    (`KilnCMS.Accounts.request_sign_in_unlock/2`,
    `redeem_sign_in_unlock/2`), refused to every actor, admins included; the
    site comes from the action context, never from an argument. The work is
    `KilnCMS.Accounts.SignInUnlock`. The link is an AshAuthentication token
    with purpose `sign_in_unlock`, stored in `tokens` with `org` and a keyed
    HMAC of the address (`ed`) in `extra_data`. The mail budget is the new
    `AccountThrottle` purpose `:sign_in_unlock` (`unlock_mail_budget`,
    default 3).
  The reasoning is in
  [ADR 0023](../decisions/0023-an-unlock-link-lifts-only-the-account-pause-and-the-pause-stays-undisclosed.md);
  the how-to is
  [Lift a sign-in pause by email](../account-administration.md#lift-a-sign-in-pause-by-email).

<a id="challenge-provider-plugins"></a>

- **A plugin can contribute a human-verification provider (#2249, third
  part): `c:Kiln.Plugin.challenge_providers/0` and the
  `Kiln.Challenge.Provider` contract, new in `kiln_plugin` 1.4. The operator
  selects one by its id with `CHALLENGE_PROVIDER`, beside the built-in
  `turnstile` and `recaptcha`.** Installing a provider changes nothing until
  it is named. No migration.
  - **Why a contract in the SDK.** The first part kept the provider
    behaviour inside the core, where a plugin shipped as a Mix dependency
    could not implement it (a dependency compiles before the core). Moving
    it to `kiln_plugin` lets any plugin add one, and lets the core check
    what a provider says before any of it reaches a page. Decision:
    [ADR 0022](../decisions/0022-a-challenge-provider-is-a-plugin-contract-and-the-core-enforces-its-claims.md),
    which partly supersedes
    [ADR 0020](../decisions/0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md)'s
    single built-in provider.
  - **Checked once, used as data.** The named provider is resolved once per
    node and checked with `Kiln.Challenge.Provider.conformance/1`: an
    `https://` script covered by its own `script-src` source, CSP sources of
    the form `https://host[:port][/path]` (no wildcards, keywords, quotes,
    `;` or `,`), JSON render options that cannot set the site key or the
    callbacks. Pages read only the memoised result, so a provider's
    `widget/0` or `csp_sources/0` cannot slow or crash a request; only
    `verify/2` runs per attempt, under the existing 3-second deadline. Within
    1.x these rules only loosen.
  - **Off, said loudly, when it can't be used.** An id no installed provider
    answers to, a provider that fails the check, or one whose callbacks raise
    leaves human verification off, exactly as an unset provider does: no
    widget, no wider page policy. The boot log (and Sentry, source
    `CHALLENGE_PROVIDER`) says so and lists the installed ids, and a log line
    repeats it at most once a minute per node. `CHALLENGE_PROVIDER` is now
    trimmed, lowercased and held to the id format (a lowercase letter, then
    up to 31 of `a-z`, `0-9`, `_`) rather than to a fixed list. A built-in
    id always resolves to the built-in.
  - **The core enforces what the provider reports.** `verify/2` answers
    `{:ok, %{hostname: ..., action: ...}}`, and `KilnCMS.Challenge.verify/4`
    applies the hostname rule (a missing or foreign hostname is refused
    while hostnames are checked, the default) and the action rule (present
    and different is refused). A provider answering `:missing`,
    `:malformed`, or any refusal the contract does not name is read as
    `:invalid`, so it can never turn a bad token into one an outage would
    admit; an unknown unavailable reason or an answer outside the contract
    is a crash. Turnstile's own behaviour is unchanged.
  - **Operators.** `mix kiln.plugins.doctor` runs the conformance check on
    every installed provider, flags an id that collides with a built-in or
    another plugin's, and, with `CHALLENGE_PROVIDER` set in its environment,
    fails when no installed provider answers to it. `mix kiln.plugins.list`
    and the System page's Plugins list count each plugin's providers, and
    the System page marks the one in use. If a plugin's provider posts its
    token under its own form field, Sentry's scrubber masks it, but the
    request log cannot (Phoenix compiles `:filter_parameters` before the
    plugins are read): the boot log warns (`challenge_response_fields`) and
    the operator adds the field to `config :phoenix, :filter_parameters`.
  - **Headless clients.** A form schema's `challenge` and a refused API
    sign-in's `meta` gain `global`, `onload_param`, `render_options`,
    `action_option`, `interactive` and `api` (always `"explicit_render"`
    today), so a front end can draw any provider's widget with one piece of
    code ([api.md](../api.md#draw-the-widget-in-your-own-front-end)).
    Additive; the OpenAPI description of the sign-in `401` names them.
    `@kiln-cms/client`'s
    `FormChallenge` type gains the six as optional fields.
  - **Developers.** New: `KilnCMS.Challenge.Registry` (the built-ins, then
    every plugin's providers, then the `providers:` test seam),
    `KilnCMS.Challenge.Siteverify` (the exchange Turnstile and reCAPTCHA
    share), `KilnCMS.Challenge.headless_widget/1`,
    `KilnCMS.Challenge.provider_problem/0` and `parse_provider_id/1`, and a
    `challenge_providers` key in each `Kiln.Plugins.manifests/0` entry. The
    core-internal `KilnCMS.Challenge.Provider` from the first part is gone. The browser
    hook now draws whatever the widget data describes: render options, the
    option the action goes under, a readiness callback (with a 10-second
    timeout), and widgets without `remove`; markup rendered before this
    release still gets Turnstile's behaviour. `sdk/fixtures/dep_plugin`
    ships `KilnDepFixture.ChallengeProvider` as a worked example.
  - Guide: [Use a provider from a plugin](../human-verification.md#use-a-provider-from-a-plugin);
    for authors: *Human-verification providers* in
    [Plugin extensibility](../plugin-extensibility.md).
    Threat model:
    [Human verification](../threat-model.md#human-verification-2249).

<a id="recaptcha-provider"></a>

- **Google reCAPTCHA v2, the "I'm not a robot" checkbox, is a second
  built-in human-verification provider: `CHALLENGE_PROVIDER=recaptcha` with
  a v2 checkbox site key and secret. Cloudflare Turnstile stays the
  recommended one.** It works everywhere Turnstile does: adaptive sign-in
  and registration, `POST /api/auth/sign_in` with `CHALLENGE_API_SIGN_IN`,
  and forms that ask. No migration.
  - **Why Turnstile stays recommended.** reCAPTCHA always asks for a click,
    adds two origins to the page policy instead of one, binds no action to
    its tokens, and reports a wrong secret as a bad token (below).
  - **Page policy and egress.** The script loads from `www.recaptcha.net`,
    never `www.google.com`, whose JSONP endpoints are a known way round a
    strict `script-src`. While a check can be shown, `script-src` gains
    `https://www.recaptcha.net/recaptcha/` and
    `https://www.gstatic.com/recaptcha/`, and `frame-src` gains
    `https://www.recaptcha.net/recaptcha/`; checked in a real browser on
    `/sign-in`, `/register`, a form's page and its embed with no policy
    violation. Tokens are verified at
    `https://www.recaptcha.net/recaptcha/api/siteverify`, so an egress
    allowlist needs that one host.
  - **v2 only.** An answer that carries a `score` (a v3 or Enterprise key)
    is refused, never admitted on a threshold Kiln would have to guess.
  - **No action binding.** v2 tokens carry no action, so a token solved for
    one of this deployment's checks can be spent once on another within its
    two minutes. The hostname is still enforced.
  - **A wrong secret refuses everyone.** Google answers a wrong secret with
    `invalid-input-response`, the code for a bad token, so every check fails
    (`result="invalid"` in `kiln_cms.challenge.verify.stop.count`) and the
    "could not use its secret key" line never appears. That is the safe
    direction, but check `CHALLENGE_SECRET_KEY` first when every reCAPTCHA
    check fails.
  - **On public forms** the checkbox is `interactive`: the first click on
    submit without a token is stopped with "Complete the check above, then
    send again.", and a second click sends (held for review, as before).
    reCAPTCHA's widget adds `g-recaptcha-response` inside the form, which
    `POST /forms/:slug` and `POST /api/forms/:slug` accept when
    `_kiln_challenge` is empty. `g-recaptcha-response` is filtered from
    request logs and scrubbed from error reports.
  - **Testing.** Google's published test secret still verifies, reporting
    the hostname `testkey.google.com`, which must then be in
    `CHALLENGE_HOSTNAMES`. Its published test site key no longer renders
    ("Invalid site key", checked 2026-11-09), so trying the widget needs a
    real v2 key registered for the development hostname.
  - Guide: [Turn on reCAPTCHA](../human-verification.md#turn-on-recaptcha).
    Decision:
    [ADR 0022](../decisions/0022-a-challenge-provider-is-a-plugin-contract-and-the-core-enforces-its-claims.md).

<a id="form-human-verification"></a>

- **A site admin can ask for a human-verification check (Cloudflare
  Turnstile) on each public form (#2249, second part). A submission that
  arrives without a passing check is kept in Spam for an admin to review
  rather than refused: nobody is mailed, no webhook fires, no autoresponder
  is sent and no experiment counts it.** Per form and off by default, in the
  form builder's **General** tab ("Ask visitors to complete a
  human-verification check"). It needs the operator's provider from the
  first part; `CHALLENGE_FORMS=false` (default on) turns every form off in
  effect without touching one, as do the kill switch and a provider that is
  not fully configured.
  - **Why per form, when sign-in is deployment-wide.** A form that leaves the
    check off exposes only its own site's inbox, so by
    [ADR 0018](../decisions/0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)'s
    test it is the site's choice. The operator keeps the ceiling: the setting
    is refused on save while forms cannot ask, and ignored on every read
    while they cannot, so turning `CHALLENGE_FORMS` off takes effect at once.
    A form already on can still be saved and switched off then.
  - **Held, not refused.** What happens to a submission to a form that asks:

    | The check | What happens | Entries badge |
    |---|---|---|
    | Passed | Accepted as usual | **Verified** |
    | No token (the widget did not load, JavaScript off, a script that never ran it) | Stored in Spam, thanked as usual | **Held** |
    | Solved on a host this deployment does not serve | Stored in Spam, logged | **Held** |
    | The provider could not answer (timeout, network error, `5xx`, `429`) | Stored in Spam | **Held** |
    | Refused (invalid, expired, already used, malformed, for another action) | Not stored; the form comes back with "The human-verification check didn't pass. Complete it again, then send the form." (`422`) | — |

    A real visitor whose widget could not load still reaches the inbox; a
    script gets nothing acted on. Unlike sign-in, a provider outage never
    lets a submission through unchecked, because a caller can provoke one
    and holding costs the visitor nothing. Held submissions are pruned with
    the rest of Spam after `spam_retention_days` (30 by default), and marking
    one Reviewed does not send its mail or webhook afterwards. The check runs
    only after the fields validate and never for a tripped honeypot, so a
    typo does not spend the visitor's token. Submissions from pages loaded
    before the check was switched on land in Spam too. Decision:
    [ADR 0021](../decisions/0021-a-form-opts-in-to-human-verification-and-an-unverified-submission-is-held-not-refused.md).
  - **Where the widget appears.** On delivered pages that render the form
    block (including inside a columns block and an experiment variant), on
    the form's own page `/forms/:slug`, in the embed iframe, and on a refused
    re-render, which always draws a fresh widget. A submit waits up to 8
    seconds for the token before posting. Unchanged: fired artifacts (still
    the `data-kiln-form` placeholder), previews (they render no form),
    newsletter sign-up (not challenged; its abuse is #2500) and sign-in.
  - **Content-Security-Policy.** Widened with
    `https://challenges.cloudflare.com` (`script-src`, `frame-src`) only on a
    response that draws the widget; every other page's policy is unchanged
    byte for byte. The embed's policy gains `frame-src 'self'
    https://challenges.cloudflare.com` only for a form that asks.
  - **Caching.** A delivered page that renders a form now carries the
    form's fields, settings and, when it asks for a check, the provider and
    site key in its `ETag`, so a revalidating client sees a form edit. Pages
    without a form keep the `ETag` they had. A form or form-field write now
    drops that site's cached delivery payloads on every node, rather than
    the whole delivery cache on one. A CDN may serve a page for up to 60
    seconds (plus 300 stale) after a change.
  - **Headless sites.** `GET /api/forms/:slug` gains `challenge`: `null`, or
    `{required, provider, site_key, script_url, action: "form", field:
    "_kiln_challenge", without_token: "held"}`. Draw the widget and send its
    token as `_kiln_challenge` (`cf-turnstile-response` is accepted too).
    `POST /api/forms/:slug` adds `challenge: "verified"` or `"held"` to its
    answer when the form asks; a refused token is `422` `{ok: false, errors:
    {_kiln_challenge: "did not pass the human-verification check"},
    challenge: "failed"}`. A headless site's hosts must be in the Turnstile
    widget and in `CHALLENGE_HOSTNAMES`, or everything it sends is held; the
    log then says which host to add. Forms that leave the check off answer
    exactly as before. `@kiln-cms/client` and `kiln_client` document the new
    fields.
  - **Metrics.** `kiln_cms.challenge.decision.count` gains `action="form"`
    with `decision` `passed`, `missing`, `wrong_host`, `unavailable` or
    `failed`; `kiln_cms.challenge.verify.stop.*` gains `action="form"`.
    `_kiln_challenge` is filtered from request logs and scrubbed from error
    reports.
  - **Developers.** `KilnCMS.CMS.Form` gains `challenge` (`:off` |
    `:always`), validated by `KilnCMS.CMS.Validations.ChallengeAvailable`;
    `KilnCMS.CMS.FormSubmission` gains a read-only `challenge` (`:passed`,
    `:missing`, `:wrong_host`, `:unavailable`, or `nil`) and its create a
    `challenge` argument. The decision is `KilnCMS.Challenge.Gate.form/3`;
    `KilnCMS.Challenge` gains `form_required?/2`, `forms_available?/1`,
    `forms_fingerprint/1` and `csp_sources/2`. `Kiln.Forms.SpamCheck` checks
    see the outcome as the `:challenge` fact; holding is not a registry
    check, so a plugin cannot unregister or reweigh it.
  Guide: [Public forms](../human-verification.md#public-forms). Threat model:
  [Human verification](../threat-model.md#human-verification-2249).

<a id="human-verification"></a>

- **Operators can turn on an adaptive human-verification check (Cloudflare
  Turnstile) for password sign-in and registration (#2249, first part).** Off
  until `CHALLENGE_PROVIDER=turnstile`, `CHALLENGE_SITE_KEY` and
  `CHALLENGE_SECRET_KEY` (or `CHALLENGE_SECRET_KEY_FILE`) are all set. No
  migration; nothing changes on an upgrade that does not set them, and rolling
  the pin back simply stops asking.
  - **When it asks.** Password sign-in asks once the submitted email address
    has had 3 attempts in 15 minutes, or the client's IP address 5 failed
    sign-ins in 15 minutes (`CHALLENGE_SIGN_IN`, `off` or `adaptive`, default
    `adaptive`). Registration asks once an IP address has made 2 registration
    attempts in an hour, or always (`CHALLENGE_REGISTRATION`, `off`,
    `adaptive` or `always`, default `adaptive`). Most people never see it.
    Passkeys, magic links, password reset, two-factor codes, single sign-on
    and invitations are never challenged, and the form's fallback line names
    only the ones the site offers.
  - **Deployment-wide, on purpose.** An account signs in on every site it
    belongs to, so a site that could switch sign-in challenges off would be the
    way every other site's accounts are guessed. There is no per-site setting
    and no console page; per-site keys and public forms come in later parts.
  - **A refusal costs the owner nothing.** An attempt refused for want of a
    check does not spend the account's sign-in budget and runs no bcrypt, and
    a known and an unknown address are asked and refused alike.
  - **When Cloudflare is down.** A refused token never passes. A token that
    could not be checked (timeout past 3 s, network error, `5xx`, `429`, an
    unreadable or rejected secret) lets the sign-in through until the
    account's own budget refuses or the IP address reaches 20 failed sign-ins
    in 15 minutes, and then refuses with "The human-verification check is
    unavailable right now." Registration is bounded by its rate limit. For 60
    seconds after a node sees an outage, a missing token is treated the same
    way, since the widget itself may not have loaded.
  - **Headless sign-in is unchanged by default.** With
    `CHALLENGE_API_SIGN_IN=true`, `POST /api/auth/sign_in` accepts
    `challenge_token` and can answer `401` `challenge_required` or
    `challenge_failed` (with the widget's `provider`, `site_key`,
    `script_url` and `action` in the error's `meta`) and `503`
    `challenge_unavailable` with `retry-after: 30`. API error objects may now
    carry `meta`; the OpenAPI document gains the field and the responses.
  - **Hostnames.** A token must have been solved on a host the deployment
    serves (the canonical host, the console host, any site's subdomain, custom
    domain or console host) or one listed in `CHALLENGE_HOSTNAMES`, and for the
    action it is used on. The request's own host never counts. The Turnstile
    widget in Cloudflare must list every one of those hosts.
  - **Privacy.** When the widget shows, the browser loads a script and an
    iframe from `challenges.cloudflare.com`; the auth pages' policy admits
    that origin only while a check can be shown. The visitor's IP address is
    not sent to Cloudflare from the server. Name Cloudflare in your privacy
    policy before turning this on.
  - **Kill switch.** `KILN_CHALLENGE_DISABLED=1` and a restart turn every
    check off and restore the page policy, with the keys still set.
  - **Security log and metrics.** `sign_in_failed` gains the reasons
    `challenge_failed` and `challenge_unavailable` (sampled like wrong
    passwords; a check merely asked for records nothing). New counters
    `kiln_cms.challenge.decision.count` (`action`, `decision`) and
    `kiln_cms.challenge.verify.stop.count` (`provider`, `action`, `result`),
    and the distribution `kiln_cms.challenge.verify.stop.duration`.
    `challenge_token` and `cf-turnstile-response` are filtered from logs and
    error reports.
  - **Developers.** `:sign_in_with_password` and `:register_with_password`
    take an optional, sensitive `challenge_token` argument and may fail with
    `KilnCMS.Accounts.Errors.ChallengeRequired` (`reason` `:required`,
    `:failed` or `:unavailable`). Providers implement
    `Kiln.Challenge.Provider` from `kiln_plugin` 1.4, which a plugin can
    contribute too (see [plugin providers](#challenge-provider-plugins)).
    `KilnCMS.Accounts.ThrottleStore` gains `peek/3` and
    `refund/3`.
  - Guide: [Human verification](../human-verification.md). Threat model:
    [Human verification](../threat-model.md#human-verification-2249).
    Decision: [ADR 0020](../decisions/0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md).

<a id="scalar-list-fields"></a>

- **A number, date, date-time, time, link, email, phone, colour or slug
  custom field can hold a list (#2289).** With `multiple: true`, an
  `:integer`, `:float`, `:date`, `:datetime`, `:time`, `:url`, `:email`,
  `:telephone`, `:color` or `:slug` field holds an ordered JSON array of its
  values, bounded by `min_items` / `max_items`: the dates of an event, a
  product's sizes, a clinic's phone numbers. Before, only strings (a list of
  phrases) and selects could, and anything else needed a `:group` with one
  sub-field, which every client then had to unwrap.
  - **Stored JSON-native.** Each item is checked and tidied exactly as the
    single field would be (`#FFF` becomes `#ffffff`, `9:30` becomes `09:30`,
    an email's domain is lowercased), then stored as a number or an ISO
    string: `{"scores": [3, 3, 7], "event_dates": ["2026-03-01",
    "2026-03-08"]}`. Numbers keep repeats, because a quantity may repeat on
    purpose; every other type drops a repeat once it is tidied. Order is
    kept. A bare value is a one-item list, a string item holding line breaks
    is one item per line, and an emptied list stores nothing.
  - **Refused, not guessed.** An item the type cannot hold fails the save with
    its position from 1 (`item 2 must be a date (YYYY-MM-DD)`); an item that
    is an object or a boolean (`must be a list of values`) and a JSON-encoded
    list sent as a string (`holds a JSON-encoded list`) are refused. `required`
    asks for at least one item. A field's `validation` (`min`, `max`, length,
    `pattern`) applies to each item and names it by its index from 0
    (`scores[1]`); items the record already stored are not checked again, so
    tightening `max` does not block adding a new item. `unique` still cannot
    be combined with a list.
  - **Record-level only.** A link field or a group sub-field holds one value,
    as for lists of strings and selects. Not offered on `:boolean`, `:text`,
    `:json`, `:user`, `:computed`, `:recurrence`, the composite types or plugin
    types.
  - **Fields admin.** The new types get the **Holds** choice: **One value** or
    **A list**, then **Minimum** / **Maximum** items. The field list badges a
    list field "list". Flipping a field to a list wraps each stored value in a
    one-item list; flipping it back keeps the first item, after a warning.
    Retyping one list into another (a list of strings into a list of dates)
    keeps the stored items unconverted, and says so; `mix kiln.fields.convert`
    is the tool that converts them. If a computed field's formula reads the
    field, a warning says formulas skip a list (`sum`, `min`, `max` and text
    leave it out). A field read by a **Show when** / **Required when** rule
    with **is greater than** / **is less than** cannot become a list, and
    such a rule cannot be written on a list field.
  - **Content editor.** One input per item, of the single field's kind (a
    date picker for a date, a number box for a number), edited in place,
    removed with ×, dragged by its handle to reorder. Numbers, links,
    addresses, phone numbers and slugs are added from the add box with Enter,
    and pasting several lines adds one item per line. Dates, date-times, times
    and colours are added with Enter or the **Add** button beside the box,
    never by just picking a value, so a half-picked date is not added. At
    `max_items` the add box goes away.
  - **API.** JSON:API and GraphQL (`ListValue` of `IntValue`, `DateValue`,
    …) carry the array. `custom_filter` takes `eq` (the list contains
    the value), `not_eq`, `in`, `has`, `has_all`, `has_none` and `count` on
    it, with each operand tidied as a stored item is, so `#FFF` finds
    `#ffffff`. GraphQL `customWhere` takes the item's kind (`int: {eq: 10}`)
    with `eq`, `notEq`, `in` and `isNull`. Comparing items (`gt`, `lt`, …)
    and matching text in them (`contains`, `starts_with`, `ilike`) are not
    supported yet and answer `400`, naming the operators a list does take; a
    list is not sortable. `eq`, `in`, `has` and `has_all` can use the
    `custom_fields` GIN index; `not_eq`, `has_none` and `count` cannot. On
    `/entries` without `filter[type_name]`, a field name that is a list on one
    dynamic type and a single value on another answers the same `400` as a
    type mismatch ("has a different type per content type").
  - **Schema export.** A typed list is `{"type": ["array", "null"], "items":
    <the single field's schema>}`, with `uniqueItems: true` except on integer
    and float lists and `x-kiln-min-items` / `x-kiln-max-items` when set. The
    TypeScript, Kotlin and Swift exports follow (`scores?: Array<number> |
    null`).
  - **`mix kiln.fields.convert`** takes a typed list as its target: a JSON
    array of items (`["2026-03-01","2026-03-08"]`, `[3, 5]`), each checked as
    the field's own save would, an invalid item reported by position. A
    single typed field is refused (`… is a single date field — make it a list
    first`), and `--lines` now works for any list target, a multiple select
    included.
  - **For developers.** New `KilnCMS.CMS.ScalarLists` (`types/0`, `typed/0`,
    `distinct?/1`, `ordered?/1`, `text?/1`), the custom-filter builder
    `KilnCMS.CMS.Preparations.CustomFieldQuery.Lists`, and
    `KilnCMS.CMS.Changes.ApplyCustomFields.coerce_item/2`.
    `ClearMultiple.list_types/0` now includes the typed list types. The
    GraphQL SDL changes only in the `CustomFieldCondition` description;
    the OpenAPI document and `clients/` are unchanged.
  Guide: [Make a field hold a list of values](../extending-content.md#make-a-field-hold-a-list-of-values);
  filters: [json-api.md](../json-api.md#lists-of-values).

<a id="admin-allowlist"></a>

- **Site admins can restrict the console and sign-in to listed networks: the
  admin allowlist (#2248).** A new page, **Configure → Sign-in & access →
  Admin allowlist** (`/editor/admin-allowlist`, admins only). Off until an
  admin adds an entry.
  - **What it gates.** From an address not on the list: every `/editor/**`
    page and export, `/media`, `/setup`, and every sign-in route (password,
    registration, reset, magic link, passkeys, single sign-on, the two-factor
    prompt, confirmation and invitations) answer a `403` page "Not available
    from this network" that shows the visitor their own address;
    `POST /api/auth/sign_in` and `/api/auth/sign_in/verify` answer `403`
    `network_not_allowed`. The pages' LiveView joins and `/ws/collab` are
    refused too, and open console and sign-in pages leave as soon as a save
    excludes them. The public site, `/account`, media downloads, previews,
    health checks and every API used with an API key or an already-issued
    token are not affected. A block-list rule still wins.
  - **Entries.** IPv4 and IPv6 addresses and ranges, one per line, at most
    100. Ranges wider than `/8` (IPv4) or `/16` (IPv6) and loopback are
    refused. **Add my address** adds the address Kiln sees (its `/64` for
    IPv6), and both addresses on a dual-stack connection.
  - **Lock-out check.** A save is refused when the list does not admit the
    address the page was loaded from (and the socket's own, when it differs),
    or while a forwarding header arrives that nothing trusts. Turning it off
    is always allowed. There is no "save anyway".
  - **Fails closed.** If the list cannot be read, the gated routes answer `503`
    and joins are refused, uncached; a site the node last read as off stays
    off through a failed read. The public site never reads the list.
  - **Behind Fly.io and App Platform proxies,** a page's socket cannot see the
    client, so it is admitted on the address its HTTP load was admitted from,
    for 5 minutes; after that a reconnect or navigation reloads the page.
    `/ws/collab` is refused there while a list is on.
  - **Recovery.** `KilnCMS.Release.admin_allowlist/1` (through `bin/kiln_cms
    rpc`) lists, adds one entry to a list that is on, or clears it, and records
    it in the security log; it can never lock anyone out. The kill switch
    `KILN_ADMIN_ALLOWLIST_DISABLED=1` stops a node enforcing any site's list
    after a restart, with a boot warning; it is not in any security log.
  - **Security log and metrics.** Three new event types:
    `admin_access_refused` ("Refused outside the admin allowlist"; `surface`;
    sampled at 5 per address per 15 minutes per site, IPv6 per `/64`),
    `admin_allowlist_changed` ("Admin allowlist changed"; `state`, `count`,
    `added`, `removed`, never the entries; replaces `org_setting_changed` for
    this setting) and `admin_allowlist_overridden` ("Admin allowlist changed
    from the server"; `change`, `count`). New counter
    `kiln_cms.admin_allowlist.refused.count`, tagged `surface` and `reason`.
  - **Developers.** `CMS.SiteAdminAllowlist` is a new org-scoped settings
    resource (`CMS.list_site_admin_allowlist/1`, `save_site_admin_allowlist/2`,
    and the operator-only `override_site_admin_allowlist/3`). `:destroy` is
    refused to everyone: off is saving `[]`. Not on JSON:API, GraphQL or MCP.
    A new `:admin_allowlist` system actor reads it for the gates. Router
    pipelines `:admin_allowlist` and `:admin_allowlist_api`, and the
    `{KilnCMSWeb.AdminAllowlist, :gated}` hook in each gated `live_session`; an
    overlay or plugin adding a console or sign-in route should use them.
    `KilnCMS.CMS.OrgSettings` accepts `audit: {:change, module}`.
  - Guide: [Restricting sign-in to your networks](../admin-allowlist.md).
    Threat model: [Admin allowlist](../threat-model.md#admin-allowlist-2248).
    Decision: [ADR 0019](../decisions/0019-the-admin-allowlist-fails-closed-and-only-the-operator-lifts-it-from-outside.md).

<a id="session-idle-timeout"></a>

- **Site admins can sign idle browsers out, and sign everyone out of the site
  at once (#2246).** A new page, **Configure → Integrations → Sessions**
  (`/editor/sessions`, admins only).
  - **Sign out when idle.** Pick a time for **Everyone** (15 minutes to 24
    hours, or **Never**, the default) and, optionally, a shorter one for
    **Administrators**. The resource accepts 10 to 1440 minutes, and the
    administrators' time may not be longer than everyone's. Turning it on or
    shortening it starts the clock from the save. Activity is loading a page of
    this site while signed in (public pages included), clicking or typing on a
    console page, and moving within one; a tab left open, a reconnect and
    automatic replies (`body_flushed`, `push_state`, `push_unsupported`) are
    not. A browser is signed out between 90% and 100% of the timeout after its
    last activity. The timeout wins over "remember me": an idle browser loses
    its remember-me cookie too. Open pages go to `/sign-in` with "You were
    signed out after a period of inactivity." Each person sees the time that
    applies to them under **Active sessions** on **Your settings**.
  - **Sign out everyone.** Ends every browser session, remember-me cookie and
    sign-in waiting for a two-factor code on this site, platform admins'
    sessions on it included, and sends their open pages to sign-in. **Keep me
    signed in on this browser** (ticked by default) spares only the clicking
    admin's current browser. Other sites are not affected. API keys, headless
    app tokens and already-connected `/ws/collab` and `/ws/gql` sockets are not
    ended: for a compromised account, reset its password or use **Sign out
    everywhere** on `/editor/accounts` as well.
  - **Sessions belong to a site.** Each browser session and remember-me cookie
    now records the site it signed in on. One copied to another site's host is
    served signed out there and never refreshed from it.
  - **Fails open.** If the setting cannot be read, no timeout applies for that
    request and a warning is logged. The site decides: there is no operator
    ceiling and no environment variable.
  - **Security log.** Two new event types, `session_idle_expired` ("Signed out
    after inactivity"; `timeout_minutes`, `tier`, `surface`) and
    `all_sessions_revoked` ("Everyone signed out"; `count`, `except_self`).
    Saving the setting is `org_setting_changed` (`site_session_policy`).
  - **Known limits.** A click handled only inside a LiveComponent
    (`phx-target={@myself}`) does not count as activity on its own.
  - **Developers.** `CMS.SiteSessionPolicy` is a new org-scoped settings
    resource (`CMS.list_site_session_policy/1`, `save_site_session_policy/2`,
    and the admin-only generic action `sign_out_all_sessions/2`, which returns
    the number of sessions ended). It has no reset: its row holds the "sign out
    everyone" watermark, so `:destroy` is refused to everyone. It is not
    exposed over JSON:API, GraphQL or MCP. `Token` gains `org_id`,
    `revoked_reason` and five system-only actions; see
    [the policy matrix](../policy-matrix.md).
  - Guide: [Sign people out when idle](../account-administration.md#sign-people-out-when-idle)
    and [Sign everyone out](../account-administration.md#sign-everyone-out).
    Threat model: [Idle timeout and sign out everyone](../threat-model.md#idle-timeout-and-sign-out-everyone-2246).

<a id="scanner-404-blocking"></a>

- **Smart 404 blocking: an address that racks up delivery 404s, or probes bait paths such as `/wp-login.php`, is blocked for a while (#2253).**
  Off by default, so nothing changes until an operator sets `KILN_SCANNER_BLOCKING=1`. No migration; rolling the pin back is safe, and any automatic rules already written simply expire (they are ordinary `ip_block_rules` rows with an expiry).
  - **What trips it.** Delivery 404s from one address (an IPv6 `/64`) past `KILN_SCANNER_BLOCKING_THRESHOLD` (default 60) in `KILN_SCANNER_BLOCKING_WINDOW_MINUTES` (default 10), or past `KILN_SCANNER_BLOCKING_BAIT_THRESHOLD` (default 5) on a bait path. The window is fixed and clock-aligned, not sliding. The address then gets an `IpBlockRule` with the note "Automatic: scanner 404s" for `KILN_SCANNER_BLOCKING_BLOCK_MINUTES` (default 60), visible and removable on `/editor/ip-blocks`. Bait paths are config-only (`config :kiln_cms, :scanner_blocking, bait_paths: [...]`, replacing the built-in list), as is the cap of 300 automatic rules per site (`max_auto_rules`).
  - **What never counts.** Non-`GET`/`HEAD` requests, signed-in visitors, browser-like requests (`Sec-Fetch-*` headers), private, loopback, link-local and CGNAT addresses and `TRUSTED_PROXIES` ranges, and a forwarded request while no proxy is trusted. A claimed search-engine user agent skips the miss threshold but not bait paths, unless DNS proves the claim false (#2254). A successful sign-in from the address in the last 24 hours prevents the block.
  - **Fails open and is not retried.** Counting runs off the request path; a dropped count or database error never changes the 404. A trip is claimed once per block window, so a trip skipped for the rule cap, a recent sign-in or a database error is not retried until the window rolls over. At the cap a new trip is skipped and logged.
  - **Security log, metric, policy.** A new security event type `ip_auto_blocked` ("Address blocked automatically") and a counter `kiln_cms.scanner_guard.blocked.count` (tag `reason`). The guard acts as a new `:scanner_guard` system actor that may only create an `IpBlockRule` and read recent sign-in events.
  - **If it blocks someone it should not,** the block ends by itself after the block time, or an admin selects **Remove** beside it on `/editor/ip-blocks`. Guide: [docs/ip-blocking.md](../ip-blocking.md#block-scanners-automatically); variables: [environment-variables.md](../environment-variables.md#smart-404-blocking-2253).

<a id="bot-budgets"></a>

- **Public delivery throttles requests by what their user agent says they are:
  scripts and clients with no user agent are refused sooner than browsers, and a
  site admin can lower each class at Organization → Bot budgets (#2243).**
  The single per-address `:delivery` rate limit (300 a minute) used to treat a
  browser, Googlebot, a `curl` loop and a request with no user agent alike.
  - **Five classes.** `KilnCMS.BotClass` puts each `:delivery` request in one
    of `browser`, `search_engine`, `ai_crawler`, `declared_bot` or `empty` from
    its `User-Agent`, by curated name lists. An unknown non-empty user agent is a
    browser: media players, native app HTTP stacks and old browsers send strings
    no list keeps up with, and they are usually a person.
  - **One counter, a ceiling per class.** Every class charges the same
    `delivery:<ip>` counter, each refused at its own percentage of the
    `:delivery` limit: search engines and AI crawlers 100%, declared bots 50%,
    no user agent 20%. Browsers are unchanged. Switching user agents earns
    nothing, because the count is shared. A refusal is the same `429` as before
    and does not name the class.
  - **Who sets it.** Built-in defaults, then the operator
    (`KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT`, `_AI_CRAWLER_`, `_DECLARED_BOT_`,
    `_EMPTY_UA_`, each 1-1000), then the site, which can only lower a class.
    A site value above the operator's is refused when it is changed and clamped
    when it is read, following the `EmbedCeiling` precedent (#1133) rather than
    the password policy's "site wins": the operator owns capacity. See
    [ADR 0018](../decisions/0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md).
    There is no 0 and no unlimited: to keep a crawler out use robots.txt or
    Blocked addresses (#2242).
  - **The console page.** `/editor/bot-budgets`, admin only, under Organization
    next to Blocked addresses. Each class shows the percentage in force, what it
    comes to in requests a minute, where it comes from, and the most the site may
    set. Saves and resets are recorded in the security log as
    `org_setting_changed`. The setting is not on JSON:API, GraphQL or MCP.
  - **Not security.** The user agent is spoofable, so this is cost control: a
    higher ceiling for a class is a higher ceiling for anyone who claims it. That
    is why search engines and AI crawlers default to 100%, not more. Since
    #2254 a search-engine claim is checked by DNS, so a search-engine percentage
    above 100 goes only to verified addresses.
  - **Never classified.** robots.txt, llms.txt, sitemaps, feeds and the health
    probes (`/up`, `/ready`, `/live`) are not on `:delivery`.
  - **Telemetry.** `[:kiln_cms, :delivery, :client_class]` with `class` and
    `result`, exported as `kiln_cms_delivery_client_class_count{class,result}`;
    no user agent, address or org. Panel:
    `sum(rate(kiln_cms_delivery_client_class_count[5m])) by (class, result)`.
  - **"Configurable allowlist"** from the issue is delivered as configurable
    budgets: which names belong to each class is curated in code, with a test
    row per name. Known gaps: some browser-shaped crawlers not on the lists
    (`GoogleOther`, `AdsBot-Google`) count as browsers, and `SeznamBot` and
    `Qwantbot` count as declared bots.
  - Guide: [bot-budgets.md](../bot-budgets.md).

<a id="verified-search-bots"></a>

- **A request claiming to be a search engine is checked against DNS, and a
  claim proven false is charged as no user agent (60 requests a minute by
  default) instead of the search-engine budget (#2254).** A user agent naming
  Googlebot, bingbot, Applebot, YandexBot or Baiduspider used to buy the
  search-engine ceiling for anyone who typed it.
  - **The check.** `KilnCMS.CrawlerVerification` looks up the address's PTR
    name, requires it to be under the engine's published domain (Google
    `googlebot.com`; Bing `search.msn.com`; Apple `applebot.apple.com`; Yandex
    `yandex.ru`, `yandex.net`, `yandex.com`; Baidu `baidu.com`, `baidu.jp`),
    matched on a label boundary, and requires that name's A or AAAA lookup to
    contain the address. Google's `google.com` and `googleusercontent.com` names
    are not accepted: they are not its common crawlers, and
    `googleusercontent.com` is any Google Cloud customer. DuckDuckBot publishes
    only IP ranges and cannot be checked.
  - **Only a proven failure costs anything.** No PTR record, a name outside the
    engine's domain, or a forward mismatch is charged as `empty`. A claim not
    proven either way (the lookup is running or could not start, DNS timed out
    or failed, DuckDuckBot, a private or trusted-proxy address, an untrusted
    forwarding header) keeps the search-engine class, held to the `:delivery`
    limit (`KilnCMS.BotBudgets.unverified_search_limit/0`). With the shipped
    defaults that is the same 300 a minute as before; a
    `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT` above 100 is now spent only on
    verified addresses. Higher defaults for verified crawlers are not part of
    this change.
  - **Never on the request path.** A lookup starts in the background and the
    request is judged without it; later requests from that address are judged
    by the result. Cached per node, per address: 6 h verified, 1 h proven
    false, 5 min after a DNS error. At most 3 queries per lookup, a 3-second
    deadline, 16 lookups at a time per node with none queued, and new lookups
    rate limited per network (IPv4 `/24` 30 and `/16` 120 a minute, IPv6 `/64`
    30, `/48` 60, `/32` 120) and per node (600). A verifier that is busy,
    rate limited or restarting answers "not proven", never an error.
  - **Off switch.** `KILN_CRAWLER_VERIFICATION=false` believes every claim, as
    before. **Sign-in & access → Bot budgets** then says so under **Search
    engines (%)**; the class hints now say a claim proven false counts as No
    user agent.
  - **Telemetry.** `kiln_cms.delivery.unverified_crawler.count` (`engine`,
    `reason`), `kiln_cms.crawler_verification.lookup.count` (`engine`,
    `result`), `kiln_cms.crawler_verification.lookup.duration` (ms, `result`)
    and `kiln_cms.crawler_verification.skipped.count` (`reason`). No address,
    hostname, user agent or org in any of them. Two warnings, once per node:
    the first lookup the concurrency limit turns away, and 20 lookups in a row
    with no DNS answer (naming `KILN_CRAWLER_VERIFICATION=false`).
  - **Known limits.** A silent or slow reverse zone the attacker controls holds
    a lookup slot until the deadline, and its claim is never proven false (so
    it keeps the 404 guard's exemption, as every claim did before). Many
    addresses can spend the lookup budgets or churn the cache so new real
    crawlers stay unverified for longer, which matters only when the search
    value is above 100%. No IP-range verification yet.
  - Guide: [Verified search engines](../bot-budgets.md#verified-search-engines).
    Variable: [environment-variables.md](../environment-variables.md#bot-budgets-2243).
    Metrics: [observability.md](../observability.md#crawler-verification).

<a id="team-invitations"></a>

- **Platform admins can invite someone with no account to a site by email,
  from Team (#2135).** On **Team** (`/editor/team`) the member form's button is
  now **Add or invite**. Before this, the form needed an account that already
  existed, and said "invite people via sign-up or SSO first". An invite-only
  site (`:registration_enabled` false) had no way for an admin to bring
  someone in except creating the account from a release shell.
  - **What the form does with an address.** If the address has a *confirmed*
    account that is not on this site, that account is added straight away
    (as before) and its owner gets a "You were added to (site)" mail. Any other
    address gets an invitation by email with the tier and custom role you
    picked, and the flash reads "Invitation sent to (address)." That includes
    an address with an *unconfirmed* account. Before this change, an
    unconfirmed account was added directly. Anyone can register an unconfirmed
    account for any address, so adding it could give a site role to whoever
    registered it. An address already on the site is refused ("That person is
    already on this site."). So is one with a live invitation ("That address is
    already invited — resend it from Pending invitations.").
  - **Pending invitations.** A **Pending invitations (n)** list under the form
    shows each address, its tier, its custom role, who invited it, and
    "Expires (UTC time)" or "Expired". **Resend** mails a new link: the old
    link stops working and the 7 days start again. The **×** button revokes
    the invitation and its link stops working. Inviting an address whose
    invitation has expired resends it with the tier you picked this time.
  - **The invitee.** The link opens `/auth/invite/(token)` on the invited site.
    A viewer's link uses the site's public host. An editor's or admin's link
    uses the console host if `KILN_CONSOLE_HOST` is set, and the site's own
    host if not. Opening the link changes nothing, so a mail scanner that
    follows it does no harm. With no account, the invitee chooses a password
    (and an optional display name) and gets a confirmed account with the
    invited tier on that site. With a confirmed account, they press **Accept
    invitation**, and nothing else about the account changes. With an
    unconfirmed account, they choose a new password. The old password and every
    session the account held stop working, and a display name the first
    registrant chose is cleared unless the invitee enters one. In every case
    the invitee is sent to `/sign-in` and signs in as usual, second factor
    included. A link that is made up, expired, revoked or already used shows
    one page: "This invitation is no longer valid".
  - **Rules.** Invitations last 7 days. Invitation mail is charged to the
    existing per-address mail budget (5 per address per hour by default), in a
    bucket of its own. When it is spent, or the address is on a mail
    suppression list, nothing is sent and the admin is told why. The "added"
    notice has its own bucket of the same size and is dropped silently when it
    is spent: the membership is what the admin asked for, so they still see
    "Member added to this site." Only a *standing* platform admin can invite or
    resend: a temporary admin cannot, because an accepted invitation would
    outlast the grant. An admin-tier invitation is honoured only while the
    admin who sent it is still a standing platform admin. Accepting does not
    depend on open registration, so invite-only sites can use it. Accepting
    *through* single sign-on is not supported: the invitee accepts with a
    password, or with an account they already have.
  - **Audit.** Two new security-log types: `member_invited` (Member invited;
    metadata `role`, `resent`) and `invitation_revoked` (Invitation revoked;
    `role`). Both target the invitation, never the address. Accepting records
    the existing `role_granted` with no acting person.
  - **Developers.** New resource `KilnCMS.Accounts.Invitation` (no JSON:API,
    GraphQL or MCP exposure) with code interfaces `add_or_invite_member`,
    `invite_to_org`, `resend_invitation`, `revoke_invitation` and
    `list_invitations_for_org` (platform admins). The interfaces
    `get_invitation_by_token`, `accept_invitation_for_existing_account`,
    `consume_invitation`, `register_with_invitation` and
    `accept_invitation_with_password` are system-only. The token is 32 random
    bytes; only its SHA-256 is stored. The new mail purposes
    `:invitation` and `:membership_notice` share `AccountThrottle`'s
    mail budget, and `KilnCMS.Mail.valid_address?/1` is now public. No new
    configuration. The how-to is
    [Invite someone to a site](../account-administration.md#invite-someone-to-a-site).

<a id="revisions-changed-custom-fields"></a>

- **`GET /api/content/:type/:id/revisions/:version_id` adds `changed_custom_fields` (#2353).**
  A custom-field edit is one `custom_fields` map, so `changed_fields` could only
  say `custom_fields`. The new sibling lists the keys added, removed or edited,
  diffed against the previous revision that carried `custom_fields` (history is
  changes-only, so not the adjacent row; an empty map before the first).
  Same-transaction revisions have an arbitrary order. The list endpoint is
  unchanged. No migration; existing clients are unaffected.

<a id="custom-field-groups-and-mixed-sort"></a>

- **`custom_filter` takes `_or` / `_and` / `_not` groups, a custom sort may precede a built-in one, and reference/media sorts are refused with a reason (#2355, #2356, #2354).**
  Follow-ups to #2292. All additive; no migration or index.
  - **Groups.** `custom_filter` takes the reserved keys `_or`, `_and` and `_not` (a field name starts with a letter, so none collides; `custom_filter[or]` still means a field named `or`). Each holds conditions of custom field names, nested groups, and `_native`: built-in `filter[...]` conditions parsed by Ash exactly as `filter[...]` is. `filter[or]` / `[and]` / `[not]` that name a custom field anywhere inside are rewritten to this form, so the native spelling works. Visibility, tenant scoping and the private-field rule are the existing resolution: a private field inside a group is the same unknown-field `400`. At most 4 deep and 50 conditions. GraphQL `customFilter` takes the same keys; `customWhere` has no groups.
  - **Mixed order.** `sort=price,title` is no longer a `400`. Built-ins that lead stay in `sort`; from the first custom token on the tokens move to `custom_sort` in order, a built-in one as `_native:<name>` (parsed by `Ash.Sort.parse_input/2`: public, sortable fields only). Same preparation as `custom_sort`, so keyset pagination behaves the same.
  - **Reference and media sorts.** Still refused, now with the reason: the stored label can lag the target's current title, and an order over unreadable targets would leak where they sit. Supporting it needs a readability-aware key joined per target table, which belongs with the JSONB index work ([#2359](https://github.com/The-Verscienta/kiln_cms/issues/2359)).

<a id="security-log"></a>

- **A site's admins get a security log: who signed in, was locked out, changed a
  second factor, passkey, role, API key or sign-in setting, and from where
  (#2441).** For admins at **Security log** in the console sidebar
  (`/editor/security-log`); editors and viewers cannot see it.
  - **What it records.** Fifteen event types: sign-ins, failed sign-ins,
    lockouts, second factor added and removed, recovery code used, passkey added
    and removed, role granted and revoked, temporary elevation, API key created
    and revoked, single sign-on changes, and a change to any other site setting
    or blocked-address rule (the setting is named, never its value). Each row has
    the time, the person, the target, the IP address and the browser. Filter by
    event, person (email), and a UTC date range, and **Download CSV** of the same
    filter. The CSV is capped like the content export (10,000 rows; over it, a
    `413` asks you to narrow the dates) and neutralises spreadsheet formulas.
  - **Failed sign-ins are sampled** (5 per IP address per 15 minutes) and a
    lockout is written once per subject and scope per 15 minutes, so an attack
    cannot fill the log. A failed sign-in for an unknown address stores no email.
    A request to an unknown host records nothing.
  - **Append-only.** No one, an admin included, can create, edit or delete an
    event. Events leave only by the retention prune (default 365 days, per site,
    `0` keeps forever; daily at `20 3 * * *`, `KILN_SECURITY_LOG_PRUNE_CRON`)
    or by erasing a user, which clears the actor, target, email, IP, user agent
    and metadata of every event they touched and keeps the event. The staging
    scrub deletes the table.
  - **Not an API.** Absent from JSON:API, GraphQL and MCP; `kiln_reporting_v1` is
    unchanged. Not recorded: plugin install or enable (plugins are compiled in, no
    runtime path), remember-me sign-ins, failed magic-link, SSO and passkey
    sign-ins, and the lapse of a temporary role.
  - **Developers.** New domain `KilnCMS.Security`, resource
    `KilnCMS.Security.Event`, change `KilnCMS.Security.Changes.Record`. Event
    writes that fail are visible only in the log and on the
    `[:kiln_cms, :security, :event_failed]` and `:event_sampled_out` telemetry
    events. The full event-to-emit-site matrix is in
    [the security log guide](../security-events.md).
  ([#2441](https://github.com/The-Verscienta/kiln_cms/pull/2441))

<a id="field-definition-sync"></a>

- **Custom-field definitions can be exported from one environment and imported
  into another, with a diff and a dry run (#2288).** For admins promoting a model
  from staging to production. No migration.
  - **Commands.** `mix kiln.fields.export [--out FILE]` and `mix kiln.fields.import
    FILE [--apply] [--prune] [--allow-data-loss]`; on a release,
    `KilnCMS.Release.export_field_definitions/2` and
    `import_field_definitions/2` through `rpc`. Admins also get a download at
    `/editor/fields/export.json`. See [field-sync.md](../field-sync.md).
  - **Complete by construction.** A field carries every attribute the create
    action accepts, so validation constraints, conditional rules, privacy,
    localization, delivery and search flags and reference rules travel with it.
    The list is read from the action; a test fails if an exported field is
    missing one. Link fields and group sub-fields nest under their parent;
    dynamic types carry their settings.
  - **Safe by default.** The dry run applies the import inside a transaction it
    rolls back, so validation refusals show up before anything is written.
    `--apply` is one transaction. Re-importing a file changes nothing. A field
    absent from the file is kept unless `--prune`. A delete, a type change or a
    list made single over stored values is blocked until `--allow-data-loss`.
  - **Not included.** Role/membership field grants, content, and the compiled
    types themselves; types are never deleted by an import.

<a id="backup-media-parts"></a>

- **In-app media backups are written as independent `tar.gz` parts with SHA-256
  checksums, and a failed backup can be resumed (#2218).** For platform admins at
  `/editor/backups`, operators and anyone restoring.
  - **Parts.** The media directory is split by file set, not by bytes, so every
    `kiln-media-<stamp>.partNN.tar.gz` is a complete archive of its own that can
    be listed, hashed, copied and restored alone. `BACKUP_MEDIA_PART_MB` (default
    400; 16 to 10240, otherwise the default plus a boot warning) is a ceiling on
    each part's uncompressed input, not an exact size; a file bigger than the cap
    is its own part. `BACKUP_MEDIA_EXCLUDE` (for example `tmp/**,cache/**`) leaves
    paths out. Empty directories and directory timestamps are not preserved; a
    file created after the backup started is in the next one, and one deleted
    meanwhile is dropped with a log line.
  - **Checksums.** A SHA-256 per part and per set is recorded in
    `manifest.json` (additive keys `sha256`, `part`, `parts_total`; `version`
    stays 1), on the History row, and in `kiln-media-<stamp>.sha256` and
    `kiln-db-<stamp>.sha256` sidecars in `sha256sum -c` format. They are copied
    off-site with their artifact and pruned with their component. `Verified` now needs
    `tar -tzf` to pass, the size to match the hash, and a hash to be recorded.
    `scripts/backup.sh` writes the same parts, keys and sidecars ([below](#backup-sh-media-parts-upgrade))
    and `verify` checks every file of the newest stamp.
  - **Resume.** Finished steps and parts are kept in
    `<BACKUP_DIR>/.work/<stamp>/` (0700; removed on success; swept after three
    days). A failed or interrupted run shows **Resume** in History for platform
    admins; it reuses only parts whose recorded hash still verifies, so a resumed
    set can mix times (the Run log says so) and a very large library converges over
    repeated resumes. Console form: `Backups.request([resume: stamp], Backups.system())`
    (see [the step chain](#backup-step-chain); `Backups.enqueue/1` and
    `Worker.run/3` are deprecated there). The one write policy change is
    `:resume` on `Backups.Run`, system actor only. A stuck run is now failed when
    it has been quiet for 2h15m, measured from its last update, not its start.
  - **Restore.** `scripts/restore.sh media` takes a legacy archive, any one part
    (the siblings are found), several paths, or a stamp prefix. Before it
    extracts anything it verifies the sidecar, requires parts `01..N` with no gap
    or duplicate, lists every part, and refuses absolute or `..` member names and
    links that point absolute or upward. No sidecar is a loud warning, or an abort
    with `RESTORE_REQUIRE_CHECKSUM=1`. Importing a part set into History with a gap
    marks it failed ("incomplete media set").
  - **Prune and disk.** Retention deletes a media set whole (all parts, then
    the sidecar), aged by its newest file, in the app and in `backup.sh`; the
    dump of the same stamp is aged on its own
    ([retention by component](#backup-retention-by-component)). There is no
    free-space check: budget for the dump, the finished parts and one in flight.
  - **Since then.** The Oban job-per-step chain followed in a later PR
    ([the step chain](#backup-step-chain)), as did splitting in `backup.sh`
    ([upgrade note](#backup-sh-media-parts-upgrade)). The runbook is in
    [backups.md](../backups.md#media-backups-in-parts-2218).
  ([#2218](https://github.com/The-Verscienta/kiln_cms/issues/2218))


<a id="builtin-format-field-types"></a>

- **Six built-in custom field types check and tidy a value: `:email`, `:telephone`, `:color`, `:slug`, `:time` and `:json` (#2278).**
  An editor can no longer save a malformed address, colour or time, and an
  API client or import gets the same check. Admins pick them in the fields
  admin like any type. Guide: [Built-in format types](../extending-content.md#built-in-format-types).
  - `:email`: shape check, domain lowercased. `:telephone`: a *format* check
    only, stored as E.164; it requires a leading `+` (or `00`) and refuses
    domestic numbers and extensions. `:color`: `#rgb`/`#rrggbb`, stored
    lowercase `#rrggbb`; a text input rather than `type="color"`, so an
    optional field can stay empty. `:slug`: slugified text, with no uniqueness
    check and no auto-fill (use `:computed`; uniqueness waits on #2276).
    `:time`: `HH:MM`, no date or zone.
  - **Lists.** Email, telephone, color, slug and time fields appear in the
    content list's Columns picker, filter (email/telephone/slug: Is, Contains,
    Empty or not; color: Is, Empty or not; time: Is, From, Until, Empty or not)
    and sort. Condition values are tidied the way the field tidies a saved
    value.
  - **`:json`.** An object or array, edited in a monospace textarea. It is
    filterable only for "Empty or not", not sortable, and not in the Columns
    picker, but a `searchable` flag indexes the strings and numbers nested in
    it (not the keys). Limits: 256 KB of input, 64 KB re-encoded, depth 32,
    5,000 values; NUL is refused.
  - **Not yet.** Number options (step, prefix, suffix, slider), a slug
    uniqueness rule, a colour palette, JSON Schema validation.
  - The six names are reserved; see the upgrade note
    [above](#builtin-field-type-names-upgrade).

<a id="builtin-composite-field-types"></a>

- **Three more built-in custom field types: `:range`, `:key_value` and `:link` (#2278).**
  Admins pick them in `/editor/fields` like any type. Each is stored as JSON,
  checked the same way in the editor, the API and imports, and served through
  GraphQL and the client schema export as the generic JSON value. Guide:
  [Range and key-value and link fields](../extending-content.md#range-and-key-value-and-link-fields).
  - `:range`: `{"min": ..., "max": ...}`, both bounds numbers or both
    `YYYY-MM-DD` dates. At least one bound is required (a half-open range is
    allowed) and `min` may not exceed `max`. Edited as two text inputs, "From"
    and "To". Never indexed for search, even if flagged `searchable`. The
    published schema says each bound is a number or a string; the check, not
    the schema, rejects a number paired with a date.
  - `:key_value`: an ordered list of `{"key": ..., "value": ...}` pairs, edited
    as a textarea with one `key=value` per line (split at the first `=`).
    At most 100 pairs, values up to 1,000 characters, 64 KB in all; keys are
    unique (case-sensitive), single-line and contain no `=`. A plain map from
    an API client is accepted and stored sorted by key. A `searchable` flag
    indexes the values, not the keys.
  - `:link`: `{"url": ..., "label": ..., "target": ..., "rel": ...}`. The URL
    (at most 2,048 bytes) must pass the same `safe_href` policy as rich-text
    links unchanged: `http(s)`, `mailto:`, a relative `/path` or a `#fragment`
    are stored; `javascript:`, `data:`, `tel:` and protocol-relative `//host`
    are refused with an error. Label up to 200 characters; target `_blank` or
    `_self`; `rel` from a fixed list, and a `_blank` target always adds
    `noopener noreferrer`. A `searchable` flag indexes the label only. This
    type is unrelated to the "link fields" (edge metadata) of a `:reference`
    field.
  - **Lists and queries.** None of the three is a Columns picker column, a list
    sort, or usable as a condition source. A `custom_filter` on them answers
    only "Empty or not" (`null`); any other operator is refused with *custom
    field "x" (range) only supports null*, and a sort with *is not sortable*.
    `multiple` is cleared and validation constraints (`min`, `pattern`,
    `unique`, ...) are refused on them.
  - **Plugin authors.** `Kiln.FieldType` `input_parts/1` entries may carry an
    optional `options: [{value, label}]` list for a `type: "select"` part
    (additive; the editor renders a `<select>`, put the blank choice first).
  - **Upgrade.** No migration. The names `range`, `key_value` and `link` are
    reserved; see the upgrade note [above](#builtin-field-type-names-upgrade).

<a id="custom-field-grants"></a>

- **Roles and members can be granted individual custom fields, and private
  custom fields can be hidden from some editors (#2281).** Until now
  `custom_fields` was one grant for all of them. A `field_grants` list can now
  hold `custom_fields.<name>`, `custom_fields.<group>` (rows included) and
  `custom_fields.<group>.<sub>`, and a new `field_read_grants` map names the
  private fields an editor may see. On `/editor/team` the field-grant picker
  lists the individual custom fields, indented under their group, and a new
  **Custom fields they can read** picker sets the read axis.
  - **Rules.** A write grant implies reading. Only top-level `private: true`
    fields can be hidden (a public field is world-readable anyway), and a
    field named in a read grant cannot be made public until it is removed from
    the grant. A role holding any `custom_fields.*` key is held to those keys
    on a create too; roles with only the bare `custom_fields` key keep the old
    rule. Admins are exempt.
  - **What a restricted editor sees.** Hidden fields are absent from the
    editor, the content list (columns, filter, sort, CSV/JSON export), version
    history and diffs, JSON:API, GraphQL and MCP responses (mutation results
    too), and filtering on one answers like an unknown field. Hidden values
    survive their saves untouched. Restoring a version is refused for an
    editor with a field grant or a read restriction on the type. Copies,
    translations and imports carry only the fields the actor may write.
  - **Visible change for existing roles.** An editor holding a whole-attribute
    grant that omits `custom_fields` now sees the custom fields read-only in
    the editor instead of editable-looking inputs that the save would refuse.
  - **Limits.** A hidden `required` private field makes that editor's create,
    copy or import of the type fail. Read grants do not apply to actor-less
    surfaces (fired artifacts, webhooks, change feed, RSS, the
    `kiln_reporting_v1` views); those already drop every private field.
  See [Per-custom-field grants and read restrictions](../granular-rbac.md#per-custom-field-grants-and-read-restrictions).

<a id="backup-history"></a>

- **Backups has a History: every backup attempt, app-made and cron-made, with
  its outcome and whether its files are still on disk (#2217).** `/editor/backups`
  (platform admins) lists runs newest first, 25 to a page, each with trigger,
  status (Succeeded, Failed, Running, Skipped), Database and Media badges, size,
  `Verified` / `Not verified` / `unverified (imported)`, destinations and the
  local state of its files: `on disk`, `missing`, `pruned (retention)`,
  `expired` or `off-site only`.
  - **Worker.** Each attempt writes a run; a failed run write never fails the
    backup. A refused attempt (no `pg_dump`) is a `skipped` run and still leaves
    `manifest.json` untouched. A job that was killed mid-run is marked failed
    ("Interrupted") by a sweep once it is 2h15m old.
  - **Cron's backups.** `KilnCMS.Backups.Importer.run/0` records
    `kiln-db-<stamp>` / `kiln-media-<stamp>` files found under `BACKUP_DIR` that
    have no run: when a platform admin opens the page, at the end of each worker
    run, and from `bin/kiln eval "KilnCMS.Backups.Importer.run()"`. It is
    idempotent by stamp, waits until a stamp's newest file is 10 minutes old and
    has no `.partial`, and never hashes or verifies a file, hence "unverified
    (imported)". `backup.sh db` and `backup.sh media` as separate cron entries
    have different stamps and appear as two runs.
  - **Missing is computed on read**, for the visible page only. `BACKUP_DIR` is
    host-local: on a multi-node deployment a run recorded by another node reads
    `missing`. `expired` is a heuristic for imported runs older than the
    retention window plus a day (cron records no prune).
  - **Secrets.** Text stored in a run goes through `KilnCMS.Backups.Redact`
    (URL userinfo, `key=value` credentials, rclone connection-string remotes).
    The status panel's off-site remote and `manifest.json`'s `offsite` are now
    redacted too.
  - **Access.** `KilnCMS.Backups.Run` is read-only for platform admins and
    written only by the `:backups` system actor (worker, importer, stale sweep).
    `Worker.run/1` still works; it is now `run(trigger, job_id \\ nil)`.
    `Staging.Scrub` purges runs (`backup_runs_purged`).
  - **Reserved** for the rest of the epic (#2216): `parts` and `sha256` (#2218),
    `destinations` (#2220), `encrypted?` (#2224).
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217))

<a id="ip-block-rules"></a>

- **Site admins can block an IP address or range from `/editor/ip-blocks`
  ("Blocked addresses") (#2242).** A blocked address gets an empty `403` on
  every dynamic route and is refused on the `/live`, `/ws/gql`, `/ws/collab`
  and `/ws/bridge` sockets. Rules take an IPv4 or IPv6 address or CIDR range,
  an optional note and an optional expiry, and belong to one site. Guard rails:
  loopback is never blocked, `/up` and `/ready` are exempt, ranges wider than
  `/8` (IPv4) or `/16` (IPv6) are refused, and a rule that includes the admin's
  own address asks for confirmation. Rules are cached for a minute per node and
  cleared on every node when one is added or removed; if the list cannot be
  read, requests pass.
  - **Limits.** Static assets and `/uploads/*` are served before the site is
    known and are not covered: refuse those at a CDN or proxy. Behind a reverse
    proxy, set `TRUSTED_PROXIES` (or `CLIENT_IP_HEADER`) first, or a rule
    matches the proxy's address and blocks every visitor.
  - **Operators.** One new table, `ip_block_rules`, additive; rolling back
    leaves it unused. No new environment variables. If an admin locks
    themselves out, `bin/kiln_cms rpc 'KilnCMS.Release.ip_blocks(remove: true)'`
    lists (without `remove: true`) or lifts the site's rules and clears every
    node's cache at once; SQL still works within the one-minute cache. Expired
    rules are not swept, but adding the same range again replaces the expired
    row; an active rule still refuses a duplicate.
  - **Developers.** The resource, `KilnCMS.CMS.IpBlockRule`, is org-admin only
    and deliberately absent from JSON:API, GraphQL and MCP. The request path
    reads it as the `:ip_block` system actor. New counter
    `kiln_cms.ip_block.refused.count`, tagged `surface`, never the address.
  See [ip-blocking.md](../ip-blocking.md).

<a id="dynamic-field-defaults"></a>

- **A custom field can default to today, now, the creating user, the site locale or another field (#2286).**
  A new `default_source` (and, for a copy, `default_field`) on a field
  definition replaces the fixed `default` with one of a closed set — `today`,
  `now`, `current_user`, `site_locale`, `copy_of` — chosen under **Default comes
  from** in `/editor/fields`. It applies on create only, where the payload
  leaves the field blank; a supplied value wins and later edits never re-default.
  `today` is the day a computed formula's `today()` sees. A field hidden by
  its `visible_when` rule is not defaulted; a field the editor's grants do not
  cover still receives its default, and the grant check does not count it as the
  editor's change. Two new nullable columns on `field_definitions`
  (additive migration); `default_source` / `default_field` read back on the
  field-definition JSON:API resource and in the OpenAPI document. See
  [extending-content.md](../extending-content.md#give-a-field-a-dynamic-default).

<a id="conditional-custom-fields"></a>

- **A custom field can be shown only when another field has a given value, and required only then (#2277).**
  Open a field in `/editor/fields` (admins), expand **Conditions**, and set
  **Show when** and/or **Required when**: one or more tests on a field beside
  it ("Kind is one of Event, Talk"), joined by "All of these are true" or "Any
  of these is true". In the content editor the field appears and disappears as
  the editor changes the other value, with no round trip to the server, and
  a **Required when** field blocks the save only while its rule holds. The
  same fields work on a group's sub-fields, where a sub-field reads the other
  sub-fields of the same row. The how-to is in
  [extending-content.md](../extending-content.md#make-a-field-conditional).
  - **For developers.** `field_definition` gains two attributes,
    `visible_when` and `required_when`: plain JSON (`{"field", "op", "value"}`
    leaves under `{"all": [...]}` / `{"any": [...]}`; ops `eq`, `neq`, `in`,
    `empty`, `not_empty`, `gt`, `lt`; at most 3 levels and 10 nodes). They
    show up in `?include=field_definitions`, the OpenAPI document and the
    `read_field_definitions` MCP tool; creating or updating a definition is
    still admin-only and goes through the `CMS.create_field_definition` /
    `CMS.update_field_definition` code interfaces. The rule logic is
    `KilnCMS.CMS.Conditions`; the editor runs a JavaScript twin
    (`assets/js/conditions.js`) held to the same fixture
    (`test/support/fixtures/conditions_cases.json`).
  - **Hidden is an editor concept, not a privacy control.** A hidden field
    keeps its stored value, and that value is still delivered by the JSON:API,
    GraphQL, search and computed fields. Use **Private** for a value that
    must not be public. A value written through the API to a hidden field is
    still checked and stored.
  - **How it is enforced.** On a normal write, a hidden field is never
    required and a **Required when** field is required while its rule
    holds, judged on the merged view (what the request sends over what is
    stored). A restore, and a copy that drops custom fields, skip
    **Required when**, and a record saved before a rule existed is not
    rechecked by an unrelated write. There is no cascade: a field hidden by
    its own rule still counts with its stored value when another rule reads
    it, on the server and in the browser alike.
  - **Keeping rules consistent.** A rule can read only a plain value field
    (text, number, date, yes/no, choice) in the same scope, not itself, not a
    private field, and without a cycle. Deleting a field other rules read is
    refused, naming them; changing its type or making it private is refused
    when a rule would stop being valid; renaming it rewrites the rules that
    read it in the same transaction.
  - **Limits.** `gt` / `lt` compare numbers and ISO dates or datetimes, and
    are false when a side can't be read as one. A datetime needs seconds
    (`2026-11-07T10:00:00`): the browser's `datetime-local` input posts none,
    so a `gt` / `lt` test on such a field never holds, in the editor and on the
    server. A rule nested beyond one level (possible only through the code
    interface) is shown read-only in the admin UI until you remove it.
    Link fields, computed fields and a group as a whole carry no conditions.
  - **Upgrade.** Run migrations: two nullable columns are added to
    `field_definitions`, nothing is backfilled and the `kiln_reporting_v1`
    views are untouched. The change is expand-only, so rolling the pin back is
    safe (the older release ignores the columns). Overlays: run
    `mix ash.codegen` and commit the migration if you carry a copy of the
    resource. CI gains a step, `npm test --prefix assets`, that runs the
    JavaScript evaluator against the shared fixture.

<a id="breached-password-check"></a>

- **Admins choose what happens when a new password is in a known breach (#2240).**
  A new page, **Organization → Password policy** (`/editor/password-policy`, admins
  only), sets one of three stances for the site: **Off** (no warning),
  **Warn** (the default: accept the password and say so) or **Block** (refuse
  it for administrators; editors and viewers are still only warned).
  Passwords are checked when someone registers, changes their password, resets
  it, or when the first-run wizard creates the first admin. Sign-in is not
  checked.
  - **How a password is checked.** Kiln hashes the password with SHA-1 and
    sends only the first five characters to `api.pwnedpasswords.com` (the
    k-anonymity range API, with `Add-Padding`), through `KilnCMS.SafeFetch`.
    The match is made locally. Nothing is cached and no password, hash or
    address is logged.
  - **Fails open.** A timeout (3 s overall), an error status or a malformed
    answer accepts the password, logs a warning and emits
    `[:kiln_cms, :password, :breach_check]` with `result: :error` and a
    `reason`. An outage at a third party never stops anyone setting a password.
  - **Who counts as an administrator.** The stricter of the account's role
    (including a temporary role) and its membership tier on the site being
    used. `Block` is evaluated against the site the request is on.
  - **What people see.** Blocked: a field error on the password, "This password
    has appeared in a known data breach. Choose a different one." Warned after
    a password change or first-run setup: the message appears with the redirect
    to sign-in. Warned after registering or resetting: shown after the next
    password sign-in (a one-time note kept for ten minutes on that node, so on a
    multi-node deployment without sticky routing it can be missed).
  - **Operators.** `BREACHED_PASSWORD_CHECK=false` turns the check off for the
    whole deployment; `BREACHED_PASSWORD_POLICY=off|warn|block` sets the default
    for sites that have not saved a choice. See
    [Environment variables](../environment-variables.md#breached-password-check-2240).
  - **Not covered.** Admin-triggered password resets, magic links, SSO and
    passkey sign-up, account anonymization, seeds, the beta round and the
    staging scrub do not check. See the [threat model](../threat-model.md#breached-passwords).
  - **Developers.** `SitePasswordPolicy` is a new org-scoped resource
    (`CMS.list_site_password_policy/1`, `save_site_password_policy/2`,
    `reset_site_password_policy/2`); the four password actions on `User` carry
    a `:password_breach` metadata key. See `KilnCMS.Accounts.PasswordPolicy`
    and `KilnCMS.Accounts.BreachedPassword`.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

<a id="webhook-rotate-secret"></a>

- **Admins can rotate a webhook endpoint's signing secret (#2347).** Each row
  on `/editor/webhooks` has a **Rotate secret** button (admin only, with a
  confirmation). It replaces the secret and reveals the new one so you can
  copy it into the receiver. Before this, the only way to change a secret was
  to delete the endpoint and add it again, which also lost its settings.
  Rotation takes effect immediately and there is no dual-secret window: it is
  the remedy for a leaked secret, so the old one must stop working. Queued and
  retried deliveries sign at send time and use the new secret; one attempt
  already in flight can fail and is retried. Health counters
  (`consecutive_failures`, `auto_disabled_at`) are not touched, so an endpoint
  near the auto-disable limit can tip over while the receiver still holds the
  old secret. The old ciphertext is never decrypted, so an endpoint whose
  secret is unreadable after `SECRET_KEY_BASE` was lost can be rotated back to
  health; the unreadable-secret message now points at the button. Rotation
  logs `webhook secret rotated endpoint_id=… org_id=… actor_id=…` at info
  level (never the secret) and leaves no other audit trail. Over code it is
  `KilnCMS.CMS.rotate_webhook_secret/2`. No migration, no env var, no upgrade
  step; rolling the pin back is safe. See
  [Rotate a webhook signing secret](../webhooks.md#rotate-a-webhook-signing-secret).

<a id="graphql-custom-where"></a>

- **GraphQL filters custom fields with typed operators (`customWhere`, #2290).**
  Every GraphQL list that takes `customFilter` (published, keyword and semantic
  search, their `…Published` twins, for compiled types and `Entry`) also takes
  `customWhere: [CustomFieldCondition!]`. A condition is `name` plus exactly one
  kind key (`string`, `int`, `float`, `boolean`, `date`, `dateTime`) holding that
  kind's operators, so a wrong operand (`float: {gt: "abc"}`) fails GraphQL
  validation. Conditions are ANDed. `customFilter` and `customSort` are unchanged.
  - **One authority.** The conditions are translated into `customFilter`'s own
    conditions inside `CustomFieldQuery`, so casting, jsonb comparison, tenant and
    Entry scoping, and privacy are the same code. The kind given must be the
    field's (`FieldKind`); a mismatch names the field's actual kind. A private
    field is the same `unknown custom field` error as a missing one below editor.
  - **Not typed in v1.** A `multiple` field takes only `string: {eq | in}` (list
    contains, as before); reference, media, group, geolocation, link fields and the
    relationship operators stay on `customFilter`.
  - **New operators.** `contains` and `startsWith` match text case-insensitively
    and take `%`, `_` and `\` literally. `customFilter` accepts them as
    `contains` / `starts_with` (additive; text-like fields only).
  - **Limits.** At most 10 conditions per query, 50 values in an `in`; each
    condition adds 5 to the query's complexity. Nothing indexes these predicates
    beyond the equality index of #2321.
  - **API surface.** Additive. `docs/api/schema.graphql` and
    `docs/api/openapi.json` gain the argument (the JSON:API routes list
    `custom_where` as an array of objects; the GraphQL mutations that load a
    record list it beside `customFilter`).

<a id="move-to-trash-in-editor"></a>

- **Admins can move one document to the trash from its row menu in the
  content list, or from the content editor's Settings tab.** Until now the
  only way to trash content in the UI was to tick it and use the bulk bar's
  Delete, which nobody found from inside a document
  ([#2137](https://github.com/The-Verscienta/kiln_cms/issues/2137)).
  - **Where.** The row's **⋯** menu ends with **Move to trash**, set apart by
    a divider and in red. The editor's Settings tab ends with a **Trash**
    section: a note on what trashing does, and a **Move to trash** button.
    There is no header button. The bulk bar is unchanged.
  - **Who.** Admins only, whatever the document's state, because it is the
    same `:destroy` policy as the bulk Delete and the API's `DELETE`. Editors
    are not shown either control, and a forged event is refused before the
    write.
  - **What it does.** The same soft delete as before: the document leaves the
    list, the API and the live site, and an admin restores it from Trash
    (`/editor/trash`) within the retention period (30 days by default). The
    confirm prompt names the document and the period; for a published
    document it adds that it comes off the site now and that restoring it puts
    it back.
  - **Unsaved edits.** In the editor, an edit still waiting for autosave is
    saved first, so a restore brings back what was on screen; if that save
    fails, nothing is trashed and the error says why. On a published
    document, Settings-tab changes held for **Save** are not saved first, as
    with the other workflow buttons.
  - **Another session still open on the document** can no longer write into
    the trashed row, and **Publish changes** on a held live page no longer
    publishes it again: fixed by
    [#2332](https://github.com/The-Verscienta/kiln_cms/issues/2332), see
    [the Fixed entry](#trashed-row-updates-refused).
  - **Developers.** New `KilnCMS.CMS.ContentTypes.can_destroy?/4` asks the
    destroy policy for one record (`tenant:` in the options), and
    `KilnCMSWeb.ContentTrash` holds the write and the copy both screens share.
    No migration, no config, nothing to run. Guide:
    [Trash and restore](../trash.md).

<a id="content-list-field-columns"></a>

- **The content list can show custom fields on each row.** Pick one content
  type in the list's type filter and a **Columns** button appears in the list's
  header bar. Tick the fields to show; each row then carries a small strip of
  `label value` pairs under its meta line. The choice is the person's own, kept
  per site and per content type, and is not part of the URL or of saved views.
  - **What it offers.** Fields of type string, text, integer, float, boolean,
    date, datetime, url, select, reference, user and media, single-valued only.
    Groups, geolocation, date ranges, recurrence, computed and multi-valued
    fields are not offered. Up to 6 are remembered per type and the first 4
    (in field order) are shown. Private fields are offered, because editors
    already see them in the content editor; the list is editor-only.
    With "All types" selected on a site with several types, no picker is
    shown (field names collide across types) and a hint says to choose a type.
  - **What a cell shows.** A reference shows the target's current title, read
    afresh as the viewer, or "Unavailable" when it cannot be read or no longer
    exists; the title stored in the field is never shown. A user field shows
    the person's name only ("Unnamed user" without one, never the email). A
    select shows the option's label, a boolean Yes or No, a media field its
    alt text or file name, and an empty value shows a dash. Long values are cut
    at 80 characters. References are looked up once per page of rows, not per
    row.
  - **Developers.** Choices live in a new nullable `users.content_list_columns`
    map (`%{org_id => %{type => [field name]}}`), written only by the new
    `:set_content_list_columns` action (`Accounts.set_content_list_columns/5`,
    self only). It merges one site/type entry into the stored map under a row
    lock, so a stale tab cannot overwrite another site's choice, and checks the
    names against the site's field definitions; a field deleted later drops out
    silently. Which fields may be offered is decided in one place,
    `KilnCMS.CMS.ListFields.readable_fields/4`. The attribute sits behind the same field policy as
    `status_marks`: only the user and platform admins can read it, so it
    reaches no API caller as a byline field.
  - **Upgrade.** Additive: one nullable `users` column with no default, added
    by the migration that runs on deploy. No upgrade step, no environment
    variable, and rolling the pin back leaves an unread column. Filtering,
    sorting and exporting by field are not part of this change.

<a id="content-list-field-filter-sort"></a>

- **The content list can be filtered by custom fields and sorted by one.** Pick
  one content type, open **More filters**, and add up to four conditions under
  **Field conditions** (a field, a condition, a value); each becomes a chip you
  can remove. **Sort by** gains a **Field** group (*Field: Price (↑)* / *(↓)*).
  Both are in the URL and in saved views, and "Load more" keeps them. This is
  the second half of #2293; the first was the Columns picker.
  - **What it offers.** Per field type: string and url (is, contains, empty or
    not), text (contains, empty or not), integer and float (is, greater than,
    at least, less than, at most, empty or not), boolean, date and datetime
    (from, until, by whole days), select, and reference, user and media by id.
    Only single-valued string, text, integer, float, boolean, date, datetime,
    url and select fields can be sorted by; records with no value sort last in
    either direction. Private fields are offered (the list is editor-only); a
    person who cannot read a field cannot filter or sort by it. With "All
    types" the panel says to choose a type, since names repeat across types,
    and changing the type clears the conditions and the field sort.
  - **The count.** With field conditions the count stops past 1000 and the
    header reads "1000+ items", because a field condition scans the site's
    records of that type. Without conditions it is exact.
  - **Saved views.** A view whose field was deleted, made private or retyped
    shows a warning icon, and opening it says the condition was left out; the
    other conditions still apply. If a field changes while the list is open and
    the read can no longer run, the field query is cleared with a notice, not
    left as an error.
  - **Developers: a URL contract.** State travels in two parameters:
    `cf=field:op:value;...` (up to four, field and value URL-encoded, canonical
    order by field then op, at most 600 characters; a saved view allows 600 for
    `cf` and keeps 200 for every other value) and `sort=field:<name>` /
    `-field:<name>`. Saved views store this, so treat the format as a contract.
    Anything invalid for the single type in play reads as absent.
    `KilnCMS.CMS.ListFieldQuery.arguments/3` is the only place that names the
    `custom_filter` / `custom_sort` read arguments; `ContentTypes.list!/2` and
    `count!/2` take an `arguments:` option, and `count!/2` honours a `limit` in
    `query:`. Guide: [Filter and sort the content list by custom fields](../extending-content.md#filter-and-sort-the-content-list-by-custom-fields).
  - **Upgrade.** No migration, no config. `saved_views.params` is an existing
    map, now allowed a `cf` key; rolling the pin back leaves such a view with an
    unknown key an older list ignores.

<a id="content-list-export"></a>

- **The content list can be downloaded as CSV or JSON.** On `/editor`, editors
  and admins get an **Export** menu in the list's header bar with **Download
  CSV** and **Download JSON**, and the bulk bar gains **Export selected** (CSV,
  the ticked rows). This is the third part of #2293, after the Columns picker
  and field filter and sort.
  - **What is exported.** The rows the list shows for the same type, status,
    search, field conditions and field sort, as the person asking (a record
    they cannot read is absent). Columns are `id,type,title,slug,status,locale,updated_at`
    plus the person's saved list columns for the type, nothing else; the panel
    says *Exports the columns shown in the list.* The scope is the types the
    editor can author, as in the list. With "All types" the types come one
    after another, not merged into the list's order. Export selected takes at
    most 100 rows and ignores every filter but the type.
  - **Private fields.** Left out unless **Include private fields** is ticked
    (shown when the type has any); every user field counts as private. A `cf`
    condition on a private field is accepted even when the column is not
    exported, as in the list.
  - **Values.** The file is data, not the screen: booleans are `true` / `false`
    (not Yes / No), media is the file name (not the alt text), select is the
    stored value, long values are not cut. A reference is its readable title
    (JSON `{id, label}`); an unreadable or deleted target is `Unavailable`
    (JSON `{id: null, label: "Unavailable"}`), never the title stored in the
    field. CSV starts with a UTF-8 byte order mark for Excel.
  - **Limits.** More than 10,000 rows is HTTP 413 with a message, never a
    truncated file; a download is stopped after 60 seconds; 10 downloads a
    minute per account, 429 with `Retry-After`. The rate limit is counted per
    node, and a refused request also spends it. A download stopped part-way
    drops the connection unfinished: a CSV ends mid-file and a JSON array is
    never closed, so a file that parses is complete.
  - **Operators and developers.** Optional
    `config :kiln_cms, :content_export, max_rows: 10_000, time_limit_ms: 60_000`.
    Each download logs `content export` and emits
    `[:kiln_cms, :content_export, :stop]` (`%{rows: n}`; metadata `user_id`,
    `org_id`, `type`, `format`, `rows`, `columns`, `include_private`), never a
    value or filter text. There is no audit trail of exports yet. Routes:
    `GET /editor/content/export.csv` and `.json`, editor-only, session auth.
    Guide: [Export the content list as CSV or JSON](../extending-content.md#export-the-content-list-as-csv-or-json).
  - **Upgrade.** No migration, no required config; rolling the pin back
    removes the menu and the routes.

<a id="custom-field-native-filter-sort"></a>

- **A custom field can be named like a column in `filter[...]` and `sort=`, and
  `custom_sort` works on the search routes.** `GET /api/json/posts?filter[price][gt]=10&sort=title,price`
  now means what `custom_filter[price][gt]=10&custom_sort=title,price`
  did, as long as no public attribute, calculation, aggregate or relationship
  has that name (a built-in always wins). The built-in relations take their
  set operators natively too: `filter[tags][has][]=<id>`,
  `filter[related_posts][has_none]=<id>`. `custom_sort` (GraphQL
  `customSort`) is a new argument on `search`, `search/published`,
  `semantic-search` and `semantic-search/published`, with the precedence
  explicit `sort` > `custom_sort` > relevance or distance > recency. A leading
  custom sort on semantic search replaces distance ordering (the vector
  index cannot serve it) and the rule that a name match comes first. The
  null test `is_nil` is accepted as a synonym of `null` on custom fields. See
  [Naming a custom field like a column](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/json-api.md#naming-a-custom-field-like-a-column).

  What to know before relying on it:

  - `custom_filter` / `custom_sort` remain the stable form. They always mean a
    custom field, they are the only way to reach one named like a column,
    and a later built-in with the same name would start shadowing `filter[x]`.
    The official clients keep emitting `custom_*`; new `customSort` /
    `:custom_sort` options on their search calls.
  - A typo such as `filter[ttile]=x` used to get ash_json_api's "No such
    field"; it is now `400` `invalid_argument` with detail
    `unknown custom field "ttile"` and no `source` member. Code that matched
    the old message needs updating. An anonymous typo costs one uncached
    field-registry read before it is refused.
  - Custom sorts must come last in `sort`: `sort=title,price` works,
    `sort=price,title` is `invalid_sort`. Custom sorts are nulls-last; a native
    `-x` is plain `desc`.
  - The OpenAPI `sort` parameter's `format` lists built-in fields only, so a
    client that validates it strictly rejects `sort=price`. Use `custom_sort`.
  - `links.self` echoes the URL as sent.
  - On `/entries` without `filter[type_name]`, a bare name declared with
    different types by different dynamic types is refused ("has a different
    type per content type"), as `custom_filter` already was.
  - Sorting by `media` / `reference` custom fields is still unsupported.

<a id="reject-invalid-bearer"></a>

- **`KILN_API_REJECT_INVALID_BEARER` (#2161).** With it on, an `Authorization: Bearer` token that
  fails verification gets a 401 `invalid_token` envelope instead of silently reading as anonymous.
  Off by default for this release, because a consumer sending a stale token today gets 200;
  the default flips next release, so announce it in that release's upgrade notes.

<a id="change-severity"></a>

- **Change severity: how much a published edit matters, stored per edit.**
  A site lists the fields it treats as safety-relevant, per content type, at
  `/editor/safety-fields` ("every field" is one switch; computed fields should
  not be listed). An edit that changes a listed field of published content, or
  first publishes one with a non-empty listed field, is recorded with a
  severity — `critical`, `notable` or `routine` — in a new nullable
  `change_severity` column of the content `*_versions` tables, so it belongs to
  that edit and the next edit starts clean. Versions written before this read
  as no severity.
  - **Admin editor.** "Publish changes" and a first publish ask "How much does
    this change matter?" when the edit touches a listed field; nothing is
    preselected and the publish does not go through until one is chosen. Saving
    a working copy and autosave never ask. The content list, calendar and bulk
    publish refuse such an edit with a pointer to the editor.
  - **API, MCP, GraphQL and automated writers.** `update` and
    `publish` take an optional `change_severity` (`publish_changes` and
    `restore_version` have no public route and default to `notable`); omitted, the edit is recorded `notable` — never routine, never empty.
    There is no batch endpoint, so it is per request.
  - **Read back.** `latest_edit_severity` and `latest_edit_at` are public
    calculated fields on JSON:API and GraphQL (readable with a viewer key) and
    sibling fields on every `/api/sync` upsert item. They describe the latest
    *safety* edit (a later edit of an unlisted field does not move them) and
    are `null` when the document is unpublished or has none. No artifact
    `format_version` change. Webhooks and the change feed do not carry the
    severity yet.
  - **Upgrade.** Additive: a nullable column on each `*_versions` table and one
    new settings table. Overlays run `mix ash.codegen` for their own content
    types. Until a site lists a field, nothing changes.

<a id="reporting-views"></a>

- **Read-only SQL views of published content, for BI tools.** Custom fields
  live in one JSONB map, so Metabase or Superset could not select a field as
  a column. The new `kiln_reporting_v1` schema has, per content table, a wide
  view (core columns plus an allowlisted `custom_fields`) and a
  `<table>_field_values` view with one row per record and field
  (`value_text`, `value_json`). `mix kiln.reporting.sql` prints a script that
  creates a read-only role with `SELECT` on those views only. Guide:
  [docs/reporting.md](../reporting.md); the reasoning is
  [decision 0015](../decisions/0015-reporting-views-are-a-versioned-additive-only-sql-contract.md).
  - **What is exposed.** Published, unarchived, public-audience rows without an
    access password. A field appears only while a live definition names it and
    it is not private or a `user` field; the list is read live, so a flip to
    private applies on the next query. Reference values are `{id, type}` only.
    Media snapshots pass through as stored.
  - **Limits.** No typed columns (cast `value_text` / `value_json`; the guide
    has a recipe). Every site's rows are visible to the role, so it must not
    go to a tenant. Role settings (read-only, 60s timeout) are advisory; use a
    read replica to enforce.
  - **Developers.** The views are a versioned, additive-only contract; a
    breaking change would be `kiln_reporting_v2`. They pin the columns they
    read, so `mix kiln.migrations.check` now fails a migration that removes,
    renames or retypes one without dropping both views of the pair first
    (`kiln:contract-ok` does not excuse it); see `docs/releasing.md`. The
    demo reset now drops the schema before restoring, and
    the promotion column lookup filters on the current schema, so a view of the same name cannot add columns.
  - **Upgrade.** Additive, no environment variable. Overlays: see the upgrade
    note above.

<a id="custom-field-indexes"></a>

- **`custom_filter` equality, `in` and list membership on custom fields use an
  index, so a selective filter on a large catalogue no longer scans the
  table.** Equality used to compare `(custom_fields -> name) = value`, which no
  index can serve. Positive `eq` and `in` (and the list and single media or
  reference equivalents) now ask `custom_fields @> {name: value}`, which the new
  GIN `jsonb_path_ops` index on `custom_fields` answers; one index covers every
  field name of every dynamic type, because the name is inside the indexed
  value. On 100,000 pages in one tenant, a filter matching one row dropped from
  about 40 ms to about 3 ms. The results are the same rows as before.
  - **Accelerated:** `eq`, `in`, and membership in a multiple select, string,
    media or reference field (`eq`, `in`), and a single media or
    reference field by id.
  - **Not accelerated:** `not_eq`, `gt`/`gte`/`lt`/`lte`, `ilike`, `null` and
    `custom_sort`. `not_eq` keeps the old form on purpose: a record without the
    field must stay excluded from it. For range and sort, the compiled
    attribute remains the answer (see the D4 note in
    [dynamic-content-types-plan.md](../dynamic-content-types-plan.md)), or an
    expression btree per field as described in
    [Custom fields](../json-api.md#which-custom-filters-use-an-index).
  - **Cost.** About 26% of the table's size per index, about 25% slower bulk
    inserts and bulk `custom_fields` updates, and 10-35% slower single saves
    (within the run-to-run noise). `custom_fields` is rewritten on every save,
    so no update is a heap-only tuple once it is indexed. Measured on a loaded
    host: rerun [the benchmark](../benchmarks.md#custom-field-filters-at-100k-rows)
    before quoting absolutes.
  - **Developers.** `KilnCMS.CMS.Preparations.CustomFieldQuery.contains/3`
    builds the containment expression for a column, and `ash_type/1`, now
    public, gives the type a field's input is cast with.

<a id="plugin-plug-routes"></a>

- **A plugin can mount plain-Plug endpoints, such as a webhook receiver, a JSON
  API or a feed variant, with the new `plug_routes/0` callback
  (`kiln_plugin` 1.4.0).** Until now a plugin could only route to a LiveView
  page (`public_routes/0`), so an endpoint with no page had to be an overlay.
  A route is `{verb, path, plug_module, plug_opts}` (a Phoenix controller is a
  Plug whose opts is the action atom) or `{:forward, path, plug_module,
  plug_opts}`. The package needs only `plug`, so it works as a Mix dependency.
  - **What the core does.** Mounts the routes before the content-delivery
    catch-alls, in a scope with no session, no CSRF check and no `accepts`
    (`current_user` is never set; the plugin authenticates its own caller).
    `conn.assigns.current_org` is set, but the plugin passes `tenant:` to Ash
    itself. Requests are limited to 300 a minute per client address in their
    own `:plugin_endpoint` bucket. The body, of any content type
    except `multipart/*`, is also kept byte for byte in `conn.private[:raw_body]`,
    capped at 1 MB (over it, `413`), so an HMAC can be verified.
  - **Checks.** A malformed route stops the build, naming the plugin.
    `mix kiln.plugins.doctor` also reports a path under a root core routes own
    (`/editor`, `/api`, `/gql`, `/mcp`, …) and overlap with another plugin's
    plug or public routes. `mix kiln.plugins.list` and System → Plugins count
    plug routes.
  - **Upgrade.** Additive. A plugin that does not define `plug_routes/0`
    (including one built against `kiln_plugin` older than 1.4) declares none. A
    plugin using it requires `{:kiln_plugin, "~> 1.4"}`. See
    [Plugin extensibility](../plugin-extensibility.md).

<a id="graphql-typed-custom-fields"></a>

- **GraphQL reads admin-defined custom fields typed by kind, with no deploy
  and no schema change (#2290).** `customFields` stays a `JsonString`. Next to
  it every content type (`Page`, `Post`, a project type, `Entry`) and the
  `ContentRecord` interface gain `customString`, `customInt`, `customFloat`,
  `customBoolean`, `customDate` and `customDateTime` (each `(name: String!)`,
  nullable) and `fields(names: [String!]!): [CustomFieldValue!]!`. A field an
  admin adds is readable at once; the GraphQL schema is compiled and the same
  for every site, so what it types is the *accessor*, not the name.
  - **What is and is not checked.** `customFloat(name: "price")` is a `Float`
    or `null`. A typo, a rename, a deleted field, a field of another kind, a
    legacy value that no longer fits, or a private field read below editor is
    `null` (left out of `fields`), never an error. The server cannot catch the
    typo; the exported contract below does.
  - **`fields(names:)`.** `names` is required, at most 50. It returns the
    `CustomFieldValue` interface (`name` plus the kind's members: `StringValue`,
    `IntValue`, `FloatValue`, `BooleanValue`, `DateValue`, `DateTimeValue`,
    `ListValue { items }`, `GroupValue { fields }`, `ReferenceValue { ids }`,
    `MediaValue`, `GeolocationValue { lat lng label zoom }`,
    `JsonValue { value }`). A `multiple` field is a `ListValue`; computed
    fields, `datetime_range` and `recurrence` are `JsonValue`. Groups nest to depth 3. A reference field
    returns ids only: read the records through `references(field:)`. Cost is
    1 plus the selection once per name; an accessor costs 1; the 200 limit is
    unchanged.
  - **Visibility and locale.** Values come from the record as the caller reads
    it, so private fields read as unknown below editor. A
    `localization: :fallback` field does not inherit along the locale chain in
    this layer; name the locale you want. A page of records does one
    definitions read per type, not one per record.
  - **Typed contract per site.** `GET /api/schema?format=typescript` is the
    existing document as a `.d.ts`; `?format=typescript-graphql` is a `.ts`
    module that adds, per content type (and per `typeName` for dynamic types,
    selected on `publishedEntries(filter: {typeName: {eq: "…"}})`), a
    `<Type>CustomFields` interface and a ready `<Type>CustomFieldsFragment`.
    An unknown `format` is a `400` with code `invalid_format`; without
    `format` the response is the same JSON as before. Regenerate after an
    admin changes fields. `filter` and `sort` still use
    `customFilter`/`customSort`, unchanged.
  - **Plugins.** `Kiln.FieldType` gains an optional `graphql_kind/1`
    (`:string`, `:int`, `:float`, `:boolean`, `:date`, `:datetime`, `:json`)
    in `kiln_plugin` 1.4.0. A type without it, or compiled against an older
    SDK, is served as `JsonValue`, so nothing breaks. Publish the SDK to Hex
    before a plugin requires `~> 1.4`.
  - **Swift and Kotlin.** `?format=swift-graphql` and `?format=kotlin-graphql`
    add the same section to the native-app models: per content type a
    `<Type>CustomFields` result type (`Codable` struct / `@Serializable` data
    class) with the fragment as `fragment` / `FRAGMENT`, and a
    `KilnCustomFieldValue` enum / sealed interface for the `fields(names:)`
    kinds, `GeolocationValue` and `MediaValue` included, with an `unknown` case
    for a kind added later. Aliases, collision rules and fragment text are
    shared with the TypeScript emitter (`KilnCMS.SchemaExport.GraphQL`), so the
    three cannot disagree. The Kotlin form uses package `kiln`; call
    `KilnCMS.SchemaExport.Kotlin.emit_graphql/2` for another.
  - **Not yet.** Typed filter operators, a per-site SDL with a regenerate step,
    and typed writes.
  - **Upgrade.** Additive and org-independent: no migration, no config, and
    rolling the pin back removes the new fields only. The new fields
    are added to every content type in the schema's `:content_domains`, so an
    overlay's types get them without code changes.
    See [headless-graphql-api.md](../headless-graphql-api.md#read-custom-fields-typed-by-kind).

<a id="draft-write-api-keys"></a>

- **Drafts-only API keys for headless services (#2273).** A new `draft_write` access
  scope on API keys lets an app service (Verscienta's, for AI drafting) create drafts and edit
  drafts it authored, and nothing else: no publishing, submitting for review, deleting, media,
  tags or related links, and no edits to live or someone else's content. The bound is a policy
  on `Content` that sits above the admin bypass and ignores the owner's role, so promoting the
  owner later widens nothing. Keys are minted by an admin on a viewer-tier service account and
  capped at 30 days (`draft_write_key_max_ttl_days`). Drafts created this way record the key
  and an optional `X-Kiln-On-Behalf-Of` label (stored for display only, never used for
  authorization); the fields appear in the editor (not in version history, which a second key
  on the same owner can read) and, for editors, admins and the creating key only, on JSON:API, GraphQL and `/mcp` (never for anonymous, preview-link or
  viewer-tier callers, webhook payloads or the preview endpoint). A GraphQL query that selects
  those three fields as someone not allowed them gets `null` plus a `forbidden_field` entry in
  `errors`, so a codegen'd query that selects every field should drop them. See [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  and the headless consumer guide.

<a id="draft-write-key-rotation"></a>

- **Self-rotating drafts-only keys.** A `draft_write` key's 30-day cap meant a person re-minted
  the service's key every month. An admin can now give the key a rotation window at mint
  (`rotatable_until`; "Self-rotation" at `/editor/api-keys`, at most
  `draft_write_key_max_rotation_days`, default 365). Until then the service calls
  `POST /api/keys/rotate` with the key and gets a fresh one: same account, scope and name,
  expiring at the 30-day cap or the window's end, whichever is sooner. The old key is revoked in
  the same transaction, under a row lock, so a chain has one live key and never outlives the date
  the admin chose. The action takes no input; `read`/`read_write` keys, signed-in users and admins
  are refused, and an owner promoted to editor since the mint stops the chain. Presenting a
  rotated-away key to the endpoint again more than 120 seconds later revokes the whole chain and
  mails the platform admins. Keys without a window behave as before. New nullable `api_keys`
  columns `rotatable_until`, `lineage_id`, `rotated_from_id` (additive). See
  [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md#rotation)
  and the headless consumer guide.

<a id="block-field-localization-config"></a>

- **A site can make core block fields per-locale from config.**
  `config :kiln_cms, :i18n, block_fields: %{"image" => [shared: [:media_id, :url], fallback: [:alt, :caption]]}`
  gives the core `image`, `video` and `audio` blocks (or any registered block
  except `gallery`, `fragment`, `rich_text`, `columns` and `file`) the same
  `shared:` / `fallback:` modes a block module declares with `localized:`. A
  site cannot edit a core block, so until now it could not share an image
  across locales. On a translation the editor now locks a shared field, with
  the *Shared: edited in the EN version* note and its library buttons
  disabled, and shows a fallback field's inherited value as a placeholder; the
  server refuses a pick into a locked field. Invalid entries are ignored with
  one warning per distinct config. With no `block_fields:` key nothing changes.
  Before enabling `:shared`: the next publish of the source variant overwrites
  each translation's own value of those fields, and edits to them are refused
  afterwards. Share `media_id` with `url`; a `:fallback` `alt` beside an
  unshared `url` can describe the wrong image; an image nested in a `columns`
  block exposes only `url` and `alt`. Removing the key is safe. No migration.
  See [Field-level localization](../field-level-localization.md#making-core-block-fields-per-locale-2270).

<a id="robots-flags"></a>

- **Editors can keep a document out of search engines.** Pages, posts and
  entries gain `noindex` and `nofollow` flags, edited under the canonical URL
  in the SEO panel (and subject to field grants). They render as
  `<meta name="robots">` and an `x-robots-tag` header, both built by one
  helper so they cannot disagree; the password-lock page keeps its
  unconditional `noindex, nofollow`. Noindex documents are left out of
  `sitemap.xml`, the news sitemap, `llms.txt` and every feed. Delivery is
  unaffected: the JSON:API, GraphQL, change feed and fired artifacts still
  carry them, and the `:json` artifact gains an optional `robots` object only
  when a flag is set (no `format_version` bump). Versions, working copies,
  duplicates, translations and export/import carry the flags; restoring a
  version written before the flags existed leaves the current values alone. A type can set
  `noindex_default` / `nofollow_default` (compiled option or Content-type
  setting) for new documents only. An advisory warns when a published page
  linked from an enabled menu item is set to noindex.

<a id="field-validation"></a>

- **Admins can constrain a custom field's values: a range, a length, a pattern, or "unique" (#2276).** In `/editor/fields`, a field's form has a **Validation (optional)** group with the controls its type takes. Numbers get `min`/`max`; `:string`, `:url` and plain `:text` get `min_length`/`max_length` and a whole-value `pattern` with an optional `pattern_message`; `:string`, `:url`, numbers and dates can be `unique`. The rules are stored in the new `validation` attribute of the field definition and checked on every write path (editor, JSON:API, GraphQL, MCP, importers), so an editor and an API client see the same error, naming the field (`SKU (sku) doesn't match the required format`).
  - **Existing data is left alone.** A value equal to the stored one is never re-checked, so tightening a rule does not block unrelated edits. Version restore, type promotion and content copy skip the value rules (they carry values that were valid when written); `unique` is still enforced for restores, and a duplicated document starts with its unique fields blank.
  - **Unique is enforced by the write path, not the database.** An advisory lock plus an in-transaction check makes two racing saves safe; matching is exact and case-sensitive, within the organization, content type and locale, ignoring the trash. A working copy only stages a value: the check runs when it reaches live `custom_fields`. Turning `unique` on is refused while values already repeat. Raw SQL and a database restore bypass it, so `mix kiln.fields.duplicates` audits for repeats.
  - **Patterns are safe to run.** The pattern must match the whole value, is at most 200 characters, and runs with match limits; a value over 2,000 characters or a runaway pattern counts as not matching.
  - **API and export.** Field definitions carry `validation` on JSON:API (and in `docs/api/openapi.json`). The schema export adds `x-kiln-minimum`, `x-kiln-maximum`, `x-kiln-min-length`, `x-kiln-max-length`, `x-kiln-pattern` and `x-kiln-unique` as annotations rather than JSON Schema assertions, since stored values may predate a rule; `pattern_message` is not exported.
  - Guide: [Constrain the values of a field](../extending-content.md#constrain-the-values-of-a-field).

## Changed

<a id="scanner-guard-exemption-narrowed"></a>

- **The smart 404 guard exempts only search engines from its miss threshold,
  and only until DNS proves the claim false; link-preview fetchers and Slurp
  are no longer exempt (#2254).** Since #2253 a user agent containing
  Googlebot, Bingbot, DuckDuckBot, Applebot, YandexBot, Baiduspider, Slurp,
  facebookexternalhit, Twitterbot or LinkedInBot skipped the miss threshold.
  - **With crawler verification on** (the default), the exemption follows
    `KilnCMS.BotClass.search_engine/1` (which also covers
    `Google-InspectionTool`, and not a user agent that names an AI crawler too)
    and holds unless `KilnCMS.CrawlerVerification` has proven the claim false.
    A claim still being checked, skipped or unanswered keeps it, so a real
    crawler's first misses from a new address never count. DuckDuckBot cannot
    be checked and stays exempt.
  - **With `KILN_CRAWLER_VERIFICATION=false`**, the six search-engine names in
    the user agent are enough, as before.
  - **In both modes** `Slurp`, `facebookexternalhit`, `Twitterbot` and
    `LinkedInBot` count like any other client: anyone can claim them, and none
    can be checked by DNS. Bait paths count for everyone, as before. See the
    [upgrade note](#verified-search-bots-upgrade) and
    [ip-blocking.md](../ip-blocking.md#block-scanners-automatically).

<a id="client-class-is-charged-class"></a>

- **`kiln_cms_delivery_client_class_count`'s `class` tag is now the class a
  request was charged as, so `class="empty"` includes search-engine claims
  proven false by DNS (#2254).** Before, it was always the class the user agent
  claimed. A claim not proven either way still counts as `search_engine`.
  Split the proven spoofs out with
  `kiln_cms_delivery_unverified_crawler_count{reason="failed"}`; see
  [observability.md](../observability.md#crawler-verification).

<a id="trashed-row-update-actions-refuse"></a>

- **Every update action on a content resource refuses a trashed row,
  including update actions an overlay adds (#2332).** The new
  `KilnCMS.CMS.Changes.RefuseTrashed` is registered `on: [:update]` in the
  `changes` block that `use KilnCMS.CMS.Content` generates, so it applies to
  every update action on Page, Post, Entry and an overlay's own content
  types, today's and any added later. It adds a filter on the row,
  `is_nil(archived_at)`, rather than checking the struct the caller holds,
  which was loaded before the trash. A refused write raises
  `Ash.Error.Changes.StaleRecord`, and nothing after it runs: no artifacts
  fired, no webhook, no job enqueued.
  - **Exempt** (`KilnCMS.CMS.Changes.RefuseTrashed.exempt_actions/0`):
    `:restore`, which now requires the opposite (the row must still be
    trashed); `:clear_reference_target`, which a purge runs on every
    referrer, trashed ones included; and `:convert_custom_field` and
    `:resnapshot_media`, which `mix kiln.fields.convert` and
    `mix kiln.media.resnapshot` run on trashed rows too
    ([below](#contract-backfills-reach-trash)). `:destroy` now also refuses a
    row that is already trashed.
  - **Overlays.** An update action you defined on a content resource that
    writes trashed rows on purpose now fails with `StaleRecord`. There is no
    opt-out today; if you need one, open an issue. Code that writes
    records it has just read through the ordinary read is unaffected, since
    that read never returns a trashed row; only a trash landing between the
    read and the write now refuses it, which is the point.
  - **A no-op bulk update** (stream strategy, nothing changed) on a trashed
    row returns the record without consulting the filter. It writes nothing.

<a id="erasure-deletes-more"></a>

- **Erasing an account also deletes its Web Push subscriptions, its private
  saved views and the notifications addressed to it, and now always clears
  its audiences (#2514).** This is every erasure: a platform admin's
  (`Accounts.anonymize_user/2`, and account removal), the staging scrub, and
  a rejected registration's.
  - **Push subscriptions** are a browser's endpoint and keys, a way to reach
    the person's device. **Private saved views** are deleted on every site;
    a shared view is the team's filter and stays, like authored content.
    **Notifications addressed to the account** are deleted on every site
    (new `Notification` action `:forget_recipient`, system-only, and
    `Notifications.forget_recipient/1`); rows naming the account as the one
    who acted are still kept and blanked, as before. If a site's delete
    fails, the erasure raises so it can be retried.
  - **Audiences.** The erasure set `audiences: []` on the account, but Ash
    skipped the write when the copy of the account it was given already read
    `[]` while the stored row had audiences (a billing recompute granted them
    after that copy was read). The stored audiences then lasted until the
    next recompute. They are now cleared in their own statement.
  See [Erasure](../data-flows.md#subject-rights-workflows) in the data-flow
  guide.

<a id="scalar-list-filters-changed"></a>

- **Filters on lists of strings and multiple selects take `has`, `has_all`,
  `has_none` and `count`, and read a value stored before the field was a list
  as a one-item list (#2289).** The same filter code now serves every list of
  values, typed lists included.
  - **New operators.** `has` (contains any of up to 100 values), `has_all`
    (contains every one), `has_none` (contains none of them) and `count` (how
    many items, compared with `eq`, `gt`, `gte`, `lt`, `lte`; a bare number
    is `eq`). Before, they were refused on these fields. `has_none` matches a
    record with no value, as it does on a reference; `not_eq` still leaves
    such a record out. On purpose: `has_none` asks "is none of these in the
    list", `not_eq` compares a value. `count` reads no value as 0.
  - **A stale bare value.** A string stored under the key before the field
    became a list (a retype, or a reshape that did not finish) now matches
    `eq` / `in` / `has` as a one-item list, is counted as 1 by `count`, and is
    left out by `not_eq` when it is that value. Before, `eq` missed it and
    `not_eq` matched it.
  - **Error wording.** An unsupported operator on a list now reads `gt is not
    supported on custom field "tags" (a list): it supports
    eq/not_eq/in/has/has_all/has_none/count/null`, instead of `… only
    supports eq/not_eq/in/null`.
  - **GraphQL `customWhere`** takes `notEq` and `isNull` on these lists as
    well as `eq` and `in`, with the `string` kind. Other operators are refused
    with `customWhere supports only eq, notEq, in and isNull on it
    (customFilter also takes has, has_all, has_none and count)`.

<a id="console-sign-in-access-section"></a>

- **The console's Configure menu has a new section, Sign-in & access (#2248).**
  Single sign-on and Sessions moved there from Integrations; Password policy,
  Blocked addresses and Bot budgets from Organization; and the new Admin
  allowlist joined them. Integrations and Organization were both at the
  seven-item cap. Every page keeps its address.

<a id="backup-retention-by-component"></a>

- **Backup retention now keeps the newest good backup, honours recovery points,
  ages a stamp's database and media separately, and deletes nothing when it
  cannot see what it needs, in the app and in `scripts/backup.sh prune`
  (#2219).** For operators. `BACKUP_KEEP_DAYS` keeps its name, default and
  meaning (`find -mtime +N`: at least N + 1 whole days old), but it is now the
  age at which a local backup *may* be deleted. No new setting, no migration.
  - **The unit is one component of one stamp.** The dump with its sidecar is
    one unit, the media archive or parts with the media sidecar another. Each is
    aged by its own newest file and deleted whole, sidecar last. Before, a
    stamp's files were one set. An old dump can now go while the same stamp's
    newer media stays: a resumed backup's dump keeps the first attempt's time,
    so with a very small `BACKUP_KEEP_DAYS` it can age out before its media.
  - **Kept past the window, per component:** the newest complete unit (app and
    cron), the newest verified unit (app only: complete on disk and vouched for
    by a `Succeeded` run), anything in flight (`.work/<stamp>/`, a `.partial`
    younger than an hour, or, in the app, a `Running` row), and every recovery
    point. A stamp that is not a real date and time, or lies more than a day in
    the future, cannot hold a "newest" slot. Before, a deployment whose backups
    stopped lost its last backup once it was `BACKUP_KEEP_DAYS` + 1 days old; it
    now keeps it. Disk use can grow by up to two units per component, plus
    pinned stamps.
  - **Recovery points.** `touch <BACKUP_DIR>/db/kiln-<stamp>.keep` (or in
    `media/`; any kind of entry, only the name counts) pins both components of
    that stamp. Retention never creates or removes a marker; one with a
    malformed name pins nothing and is left alone; one whose backup is gone is
    harmless. The Backups page does not set them yet.
  - **Fails closed, loudly.** If importing cron's backups, resolving the policy,
    listing `db/`, `media/` or `.work/`, reading a file's metadata or reading
    History fails, the app deletes nothing, logs an error, emits
    `[:kiln_cms, :backups, :retention, :skipped]`, and writes "Retention
    skipped: <reason>; nothing was deleted" to the run's log at error level.
    Each unit is checked again right before it goes. A sweep that breaks off
    part-way logs "Retention removed N file(s) from M backup(s), then stopped:
    …", emits `[:kiln_cms, :backups, :retention, :stopped]`, and still marks
    what it removed as `pruned`. The backup's own outcome never changes. The
    app imports cron's backups into History before it decides, and still prunes
    where it did, before the off-site copy.
  - **Cron's prune.** `backup.sh prune` applies the same rules except the two
    that need the database: it keeps the newest complete set, so it can delete
    the newest *verified* one when a newer complete set came from a failed run
    (a known limitation; pin the verified one with a marker if it matters), and
    it cannot see a `Running` in-app backup except through its `.work/<stamp>/`
    and `.partial` files. It never deletes strays (the app ages those under
    `BACKUP_KEEP_DAYS`), so a misnamed part such as `part001` is no longer
    removed with its stamp. It now prints each file it removes, and prints a
    `warning:`, deletes nothing and exits 0 when `db/`, `media/` or `.work`
    cannot be listed, or when `date` supports neither GNU `-d @N` nor BSD
    `-r N`. A unit whose `.partial` files it cannot look for is kept.
  - **History.** A run whose dump was pruned while its media is still on disk
    reads `missing`, not `pruned (retention)`.
  - **For developers.** New `KilnCMS.Backups.Retention` (`run/2` with
    `dry_run:`, `plan/4`, `scan/1`, `complete?/1`, `describe/1`) and
    `KilnCMS.Backups.Retention.Policy`; `KilnCMS.Backups.Artifact.keep_name/1`,
    `parse_keep_name/1` and `parse_sidecar_name/1`. The worker's internal
    `prune/1` (`@doc false`) is gone.
  - **Rolling the pin back** is safe: nothing is migrated. The previous release
    goes back to pruning whole stamps by age alone, ignores markers, and its
    in-app prune deletes a marker file once it is older than
    `BACKUP_KEEP_DAYS`.
  Guide: [What retention deletes and what it keeps](../backups.md#what-retention-deletes-and-what-it-keeps).

<a id="public-image-weight"></a>

- **The signed-out home page and the built-in logo no longer ship oversized
  images (#2165).** The home page loaded about 1,030 KB of images: four 2880x1800
  console screenshots, and a 278x379 PNG logo shown at 20 to 40 pixels. It now
  loads about 102 KB on a browser that takes WebP (about 63 KB on a small
  1x screen), and about 570 KB on the JPEG-only fallback.
  - **Screenshots.** Each is a `<picture>` with a WebP `srcset` and a 1440-wide
    JPEG fallback. The hero (the editor shot) is offered at 720, 1440 and 2880
    pixels wide, loads eagerly and with `fetchpriority="high"`, since it is
    the likely largest paint. The three tour shots are offered at 720 and 1440
    and load lazily.
  - **Logo.** When the brand's logo is the built-in one
    (`KilnCMS.Branding.default_logo_url/0`), the header, footer and
    sign-in brand render it through `KilnCMSWeb.Layouts.brand_mark/1` as a
    `<picture>` of `logo-mark-sm.webp` (6 KB) over `logo-mark-sm.png` (14 KB),
    88x120 with explicit width and height. A custom `logo_url` is rendered
    exactly as given. `logo-mark.png` is unchanged and is still the default
    `logo_url`, so the branding values in the headless and API responses are
    the same as before.
  - **Contributors.** Raw captures from `e2e/screenshots/home.spec.js` now go
    to the gitignored `e2e/screenshots/raw/`. `scripts/optimize_home_images.sh`
    is the only way to produce the files the page serves, and a new test
    (`home_image_weight_test.exs`) fails if the committed files go over a byte
    budget. See *Refreshing the home page screenshots* in `CONTRIBUTING.md`.
  - **Overlays.** An overlay that replaces `home.html.heex`, or renders
    `brand.logo_url` in its own `<img>`, does not get the right-sized images;
    it keeps what it renders today. To get them, call `Layouts.brand_mark/1`.
    Nothing to set, no migration, and rolling the pin back is safe.

<a id="csv-numbers-unguarded"></a>

- **A real number in a CSV export is written as itself.** The CSV writer
  prefixed any value starting with `-` with `'` to stop a spreadsheet running
  it as a formula, which turned the number -5 into the text `'-5`. A value that
  is a number (integer, float, decimal) now skips the guard; text is
  unchanged, so the string `-5` and `=1+1` are still prefixed, even in an
  integer field. Chosen as Changed rather than Fixed because it alters the
  bytes a CSV writes for a negative number, wherever `KilnCMSWeb.CSV.line/1`
  is given one (core exports mostly write counts, which are not negative; an
  overlay's may). `parse/1` reads
  both forms back to `-5`.

<a id="access-denied-page"></a>

- **A console page you lack the role for now lands on a persistent `/access-denied`
  page instead of bouncing you home with a toast (#2143).** Every console role
  guard (editor-only, admin-only and the instance-wide pages such as API keys,
  accounts, team, backups and system) used to flash "You need admin access to
  view that page." and redirect to `/`, so the explanation vanished in seconds
  and you landed somewhere unrelated. They now redirect to
  `/access-denied?needs=editor|admin|platform`, a `403` page that names the role
  the page needs, shows your own role on this site and what it can do, and says
  who to ask (an admin of the site, or whoever administers the installation for
  `platform`). A signed-out visitor gets a **Sign in** button; a signed-in editor
  or admin gets **Back to the console**. `needs` is whitelisted: any other value
  renders generic copy and is never echoed, your role is read from the session
  rather than the URL, and no return path is accepted. The page is sent with
  `x-robots-tag: noindex`. For overlay authors: build the URL with
  `KilnCMSWeb.AccessDenied.path/1` instead of a flash and `redirect(to: ~p"/")`.
  **`access-denied` is now a reserved root slug and path segment.** Content
  whose slug is `access-denied` at the site root is shadowed by the new page;
  the reserved list now refuses it as a content type path segment and a path
  alias, but nothing renames existing records, so change the slug or alias of
  any such page. There are no migrations, environment
  variables or upgrade steps; rolling the pin back restores the redirect and toast.
  ([#2143](https://github.com/The-Verscienta/kiln_cms/issues/2143))

<a id="team-scope-pickers"></a>

- **The scope of a custom role or a member on `/editor/team` is now picked
  instead of typed.** The role and member forms asked for comma-separated type
  names and a JSON object of field grants, which suited a developer but not
  the operator who manages a team (#2141). Each type axis (**Content types
  they may edit**, **Content types they may read in the editor**) is now a
  choice between no restriction (on a member: **Inherit (custom role, then
  account)**) and **Only these types**, with the site's types as checkboxes.
  Custom types are one choice, **Custom content types (all of them)**, stored
  as `entry` as before. **Field grants** has a row per content type with three
  choices: no restriction (key absent), **Only these fields**, or
  **No fields (can't change existing documents)**, which stores `[]`. "Only
  these…" with nothing ticked is refused rather than saved as `[]`, which on a
  type axis would mean every type.

  Saving merges onto the stored value: names this site doesn't recognize are
  shown "(not found)" and kept until unticked, so opening a form and saving it
  writes back exactly what was there. A role saved unchanged isn't written at
  all ("No changes."), so its members' live connections aren't dropped for
  nothing. The member form shows what an inherited axis currently resolves to.
  Who can change scope, the stored shapes, and `Accounts.update_role/3` and
  the membership actions are unchanged; the new
  `KilnCMS.CMS.Changes.EnforceFieldGrants.grantable_fields/1` lists the field
  names a grant can usefully name for a type. No migration, config or API
  change; rolling back the pin is safe. See
  [Scope a custom role](../granular-rbac.md#scope-a-custom-role).

<a id="effective-role-display"></a>

- **Every screen that shows a role now leads with the tier that applies now,
  and says in words when a temporary one ends and what it returns to.** The
  accounts register, an account's page, the team page and the account's
  Sites panel showed the standing role, a live grant and the account's status
  as look-alike badges side by side, with nothing saying which one counts
  (#2142). A platform admin's team row showed their membership tier, which the
  policies ignore.

  Each role now reads as one badge after a scope label: **Platform:** on
  `/editor/accounts` (the list and an account's header), and **On this site:**
  on `/editor/team`, an account's **Sites** panel, and a new **Your access**
  box in **Profile** on **Your settings**. The site tier is decided by the
  same function the policies use, so a platform admin reads as *Admin*, with
  the note "Site tier Viewer, overridden by the platform admin role." when
  their membership holds less. While a grant is live, a line under the badge
  says "Admin is temporary: until 2026-11-14 17:00 UTC (7 days left), then
  Viewer.", or names both steps when a second live grant outlasts the first.
  No line appears when nothing would change. **Your settings** also says
  "Your access to this console ends at …" when your tier will drop to viewer
  or no access. Platform admins who have no membership on a site are listed
  on its team page with **On this site:** *Admin*.

  Account status is now its own group of badges under the role. *unconfirmed*
  is now **Email not confirmed**, and the account page explains it: it doesn't
  affect the role or password sign-in, and only a site's own single sign-on
  waits for it. On the register, the filters read **Standing role** /
  **Any standing role** and **Email not confirmed**; they match the same
  rows as before (the role filter is still the stored role, not the badge).
  Role names are translated wherever they appear, including the owner label
  on API keys.

  For developers, `KilnCMS.Accounts.Scoping.tier_source/2` returns
  `{tier, source, record}`, the tier with the branch that decided it, and
  `effective_tier/2` now returns its first element (same decisions as before).
  `Scoping.tier_changes/2` lists `{expires_at, tier}` changes ahead; the
  `tier_source_for_membership/3` and `tier_changes_for_membership/3` twins take
  an already-read membership. `KilnCMSWeb.RoleDisplay` renders them. A page
  left open past an expiry still shows the old tier until it is reloaded; the
  policies stop honouring the grant on time regardless. No migration, config
  or API change; rolling back the pin is safe. See
  [See which role applies now](../account-administration.md#see-which-role-applies-now).

<a id="webhook-secret-masked"></a>

- **A webhook's signing secret is masked on `/editor/webhooks` until an admin
  reveals it, and a revealed secret has a Copy button.** The list printed
  every endpoint's secret in plain text, so a screen share, a screenshot or a
  saved copy of the page carried all of them (#2140). Each row now shows
  `••••` and the secret's last four characters (the dots alone for a secret
  under 16 characters), and the page holds nothing more until **Reveal** is
  clicked. Reveal reads the endpoint again as that admin on the current site
  before sending the secret, so an id from another site, or one deleted in the
  meantime, reveals nothing and says "Couldn't reveal that signing secret."
  A revealed secret has **Copy**, which puts it on the clipboard and says
  "Signing secret copied.", and **Hide**. A reveal lasts until **Hide** or a
  reload. A newly added endpoint's secret starts revealed, and the notice now
  reads "Webhook added. Copy its signing secret into your receiver." An
  unreadable secret (after a `SECRET_KEY_BASE` rotation) keeps its message,
  with no Reveal or Copy.

  Who can see a secret is unchanged: `/editor/webhooks` and the endpoint
  itself stay admin-only, and the API exposes no secret. Secrets still can't
  be rotated without deleting the endpoint (#2347). No migration, config or
  API change; rolling back the pin is safe. See
  [Copy a webhook signing secret](../webhooks.md#copy-a-webhook-signing-secret).

<a id="custom-field-history"></a>

- **Custom fields are individual fields in version compare, restore and the publish-conflict panel.**
  Until now a changed custom field read as one opaque "Custom fields" blob.
  The compare modal now lists each key with its definition's label, a typed
  value (select option labels, media filename, reference title, rich text
  without tags, group `Label: value` pairs) and an Added / Removed / Changed
  pill. Media and reference titles resolve as the signed-in reader, in one
  batched read; an unreadable target shows its stored id. A retired
  definition shows its raw key.
  *Restore* (from the compare modal and the history list) now opens a
  preview, **Restore this version?**, and writes only on *Restore this
  version*; it replaces the browser confirm. The preview runs the same
  `RestoreVersion.plan/3` as the action and lists stored custom keys no
  definition declares any more as discarded. An editor with a field grant is
  told restore needs full field access instead of being offered a confirm
  that would fail. The publish-conflict panel still shows one *Custom fields*
  row and still resolves the whole map with one choice (no per-key merge), but
  now lists the per-key draft-versus-live difference beneath it.
  No API, migration or config change; nothing to do on upgrade, and rolling
  back the pin is safe. The revisions API still carries `custom_fields` as one
  whole-map change; a per-key `changed_custom_fields` is deferred. See
  [Comparing and restoring versions](../working-copy.md#comparing-and-restoring-versions).

<a id="search-leg-performance"></a>

- **Global search is several times cheaper on a large catalogue.** A
  downstream catalogue of about 4,900 documents (2,047 herbs with three name
  fields) took 1.2–1.6 s per `/api/search` sweep, so 1.8's 1.5 s
  `query_budget` cut most queries short (`partial: true`). Three legs cost
  most of it, and each was a query-shape problem:
  - **Alias and compound legs.** The match runs "the query contains the
    name", so its tsquery is built from the row, and no index can serve it:
    every search unpacked every row's `custom_fields` and built a tsquery
    per name field. Both legs now first check the row's `name_lexemes` (the
    lexemes and Han runs of its title and names, from `search_weighted`'s
    `A` bucket) against the query's, the way the title leg checks its title
    lexemes, and run the phrase match only on the rows that share one. On a
    synthetic 2,047-row table of the same shape, the alias filter went from
    15 ms to 0.3 ms.
  - **Empty names.** A missing or empty name was matched as `''`, and
    `phraseto_tsquery('')` sends a `NOTICE` to the client for every row: about
    2,500 per herbs query on that catalogue. Empty names are now skipped.
  - **Tag leg.** Every section repeated the same nearest-tag vector search,
    then ran one query per tag. A sweep now looks the tags up once. Each
    section reads the documents carrying any of them in one query, and works
    out per tag which ones it carries. When that read hits its cap, the leg
    goes back to one query per tag, so results and distances don't change.

  Flagging a field `names_record` now also re-fires the type's published
  documents, as flagging it `searchable` already did: the flag reaches
  `search_weighted`, which weights `search_vector` and feeds the new
  prefilter. A draft picks it up on its next save. Before, the alias leg
  saw a new flag on the next search, while `search_vector` kept the old
  weights until each document was saved again. Type promotion
  (`mix kiln.promote_data`) no longer copies generated columns.

<a id="quiet-image-build"></a>

- **The release image builds without warnings or notices from Kiln's own
  steps.** The GHCR build log for v1.8.0 carried about 260 warnings and
  notices. Kiln's own steps produced four kinds, each now gone:
  - Tailwind's CSS optimizer warned that `::highlight(kiln-issue)` is not a
    valid pseudo-element. It is one (the CSS Custom Highlight API), but
    Lightning CSS doesn't know it. The rule now lives in `advisory_jump.js`
    as a constructed stylesheet, adopted the first time a highlight is drawn.
  - `npm ci` printed its "new major version" and "looking for funding"
    notices. The image pins its own npm, so the build passes
    `--no-update-notifier --no-fund`.
  - The two-scheduler `mix compile` pushed dozens of files past the
    "taking more than 10s" notice. The image build raises the threshold;
    dev keeps the default.
  - `mix release` printed "skipping elixir.bat/iex.bat for windows". The
    release now sets `include_executables_for: [:unix]`.

  On the dependency side, ash_phoenix 2.3.26, ash_paper_trail 0.8.1,
  ranch 2.3.0, makeup 1.2.3 and phoenix_template 1.1.0 compile cleanly on
  Elixir 1.20, removing about 20 warnings. The OTP 29 deprecation warnings
  in yamerl, gproc, gen_smtp and chatterbox (`catch Expr`, exported
  subexpression variables, `lists:zf/2`) are switched off for the
  `deps.compile` step only, through the compiler's own `nowarn_*` options.
  The app's sources still compile with every warning on. The rest are Elixir
  1.20 warnings inside third-party packages whose latest releases still
  carry them. Fixing those needs upstream releases.

<a id="feed-relay"></a>

- **The change feed's local fan-out no longer runs in the publisher's
  process (#2083).** `KilnCMS.Delivery.Feed.publish/4` used
  `Phoenix.PubSub.broadcast/3`, which sends to every subscriber on the
  calling node before it returns, so the editor's request (or the API call,
  or the Oban job) that published paid for every feed subscriber. It now
  hands this node's half of the event to a relay,
  `KilnCMS.Delivery.Feed.Relay`, with one cast. The relays run one per
  scheduler under a `PartitionSupervisor` (`KilnCMS.Delivery.Feed.Relays`,
  started after PubSub and before the endpoint), keyed by org id, so one
  site's events pass through one relay in the order they reach it. Remote
  nodes still get one `direct_broadcast` each from the publisher, as before.
  - **What improved, and what didn't.** In the live-blog benchmark with
    10,000 in-BEAM feed subscribers, publish p99 went from 1,474 ms to
    143 ms and p95 from 357 ms to 124 ms. The goal in #2083, a 10,000
    subscriber publish p95 within noise of the 0 subscriber one, is **not**
    met: on this branch the two were 124 ms and 33 ms. The publisher no
    longer sends to the subscribers, but once 10,000 of them become runnable
    at once, the rest of the publish waits for a scheduler behind them. The
    branch numbers come from 10-minute legs, against 30 minutes for the
    `main` figures, so treat the comparison as indicative. See
    [Live blog](../benchmarks.md#live-blog-an-update-every-few-seconds).
  - **Delivery is asynchronous.** When `publish/4` returns, local
    subscribers may not have the event yet. The new
    `KilnCMS.Delivery.Feed.sync/1` waits until every event the calling
    process published to a site has reached this node's subscribers. It is
    for tests and benchmarks: a test that asserts a feed event, or its
    absence, right after a publish calls `Feed.sync(org)` first.
  - **Telemetry moved earlier.** `[:kiln_cms, :delivery, :feed, :event]`
    still fires once per event in the publisher, but now at hand-off, before
    any local subscriber has it. A dashboard that read it as "delivered" now
    reads "handed off".
  - **Delivery is at most once, as PubSub's always was.** Events waiting in
    a relay are lost if it crashes or the node shuts down, and an event cast
    to a relay that crashed just then is lost too. If no relay is running,
    the publisher broadcasts locally itself, as before. `publish/4` never
    raises or exits into the caller.
  - **Upgrade.** Nothing to do: no migration, no config, no change to the
    topic, `subscribe/1` or the event shape. Rolling back the pin is safe.

<a id="essentials-hidden-screens-hint"></a>

- **The Essentials sidebar now tells an admin where Forms, Webhooks, API keys
  and Trash went, and how to get them back in the sidebar.** Essentials keeps
  the sidebar to the daily screens plus the Configure hub, so those four
  vanished from it with no clue where to look (issue #2144). Under the
  Configure link there is now one line: "Forms, Webhooks, API keys, Trash are
  under Configure. Use Show all tools to list every screen here." The names
  are read from the nav map for the signed-in user, so a screen they cannot
  open is left out (an organisation admin's line omits API keys). Everything,
  and users without the Configure hub such as editors, see no line. Nothing is
  added to the Essentials link list, no screen moved, and there is no
  migration or setting; the hint is hidden when the sidebar rail is collapsed.
  Nothing to do on upgrade.

<a id="docs-index-role-tracks"></a>

- **The kilncms.dev `/docs` index starts with one "Start here" that sends an
  editor, a developer and an operator to their own first guides, and moves
  the pages for people working on Kiln itself to a last section (#2157).**
  The index was one long column of about 75 guides with no place to begin,
  and it mixed editor guides with maintainer pages such as "Releasing Kiln".
  It changes no code path in the app; what changed is `mix.exs`'s guide
  lists and the publisher, `scripts/publish_docs.exs`.

  - **Start here.** One section at the top of `/docs`: the
    [Right, everywhere, provably](../right-everywhere-provably.md) pointer
    from #1930 first, then three tracks, Editor, Developer and Operator, then
    a "Search kilncms.dev" link to the site's ordinary `/search`. It searches
    every page on the site, not only the guides: a docs-only search would
    need a new public search argument, and kilncms.dev is frozen until 2.0
    (`docs/path-forward.md`).
  - **Reading paths.** The tracks come from a new guide,
    [Reading paths by role](../reading-paths.md), which also publishes as
    `/docs/reading-paths` and sits in the docs sidebar under Getting started.
    It is the one list of which guides each role reads first: the index
    inlines its `##` sections, and the "Find the right guide" table in
    [Getting started](../getting-started.md) now points to it instead of
    keeping a second list.
  - **Contributing to Kiln.** A new docs group, last on the index after a
    rule and the line "For people working on Kiln itself, not using it.":
    `CONTRIBUTING.md` (moved out of Getting started), Releasing, Beta
    testing, Design language, Design system and Frontend assets (moved out of
    Operations & deployment and Modeling & extending). They stay published,
    so links into them keep working, for example
    `/docs/releasing#updating-a-project-to-a-release`.
  - **Off the site.** `docs/chain-fold-order.md` moves to Design notes &
    decision records, so the publisher stops sending it. The publisher never
    unpublishes, so `/docs/chain-fold-order` stays live until an admin on
    kilncms.dev moves it to the trash.
  - **Titles.** Five guides drop internal labels from their titles: "Code
    injection" (was "Code injection (#490)"), "Editorial consent linking",
    "Governance dashboard" and "Point-in-time content API" (each was suffixed
    "(compliance cluster)"), and "Design language" (was "KilnCMS — Design
    Language"). "KilnCMS design system" is now "Design system", and "v1.0
    success metrics" is now "Benchmarks"; Benchmarks stays public, under
    Operations & deployment. The titles are `title:` overrides in `mix.exs`,
    so the slugs, and every `/docs/<slug>` URL, are unchanged.
  - **Sidebar.** The single-guide Search group is gone: "Meilisearch backend"
    is now under Operations & deployment, in the ExDoc sidebar and on the
    index.
  - **For contributors.** Every group in `groups_for_extras/0` must be listed
    in `scripts/publish/docs.exs` as public (`@public_groups`), contributing
    (`@contributing_group`) or internal (`@internal_groups`), or the publish
    run raises and names the group. A new group therefore never reaches
    `/docs` by accident. `test/scripts/publish_docs_test.exs` and CI's
    publisher dry run both fail on an unclassified group, so it shows up on
    the pull request rather than after the merge. The publisher's logic now
    lives in `scripts/publish/docs.exs`, so the tests can load it;
    `scripts/publish_docs.exs` keeps the `Mix.install` and the `main/1`
    call, and a change to either file republishes every guide.
  - **Upgrade.** Nothing to do on a Kiln install. On kilncms.dev, the first
    publish after the merge resends every guide (because `mix.exs` changed),
    which picks up the new titles and the new index; the one manual step is
    trashing `/docs/chain-fold-order`.

<a id="editorial-workflow-guide"></a>

- **A new guide, [The editorial workflow](../editorial-workflow.md), follows
  one page from draft to review to published in about five minutes, with
  eight annotated screenshots and a table of what viewers, editors and admins
  can each do (#2158).** Before this, the workflow was spread across the
  working-copy, releases, lifecycles and policy-matrix guides, and nothing
  showed an editor the screens. The guide leads the Authoring & editorial
  section and the Editor reading track.

  - **The role table is tested.** It sits between
    `<!-- role-matrix:start -->` and `<!-- role-matrix:end -->`, and
    `test/kiln_cms/docs/editorial_workflow_test.exs` runs each row's action
    as a viewer, an editor and an admin, with Team → Publishing off and on,
    and fails when a cell disagrees with the policies. A row the test has no
    check for fails too, so the table cannot gain a claim nobody verifies.
  - **What the guide says about taking content down.** Unpublish and archive
    follow the same Team → Publishing switch as publishing, as
    [#2134](https://github.com/The-Verscienta/kiln_cms/issues/2134) decided
    (see [the Breaking entry](#takedown-needs-publish-rights)); the table has a
    row for each, and one for a live page's unpublish date. **Publish
    changes** by an editor is described as by design, as
    [The working copy](../working-copy.md) records.
  - **API docs corrected to match.** [api.md](../api.md),
    [json-api.md](../json-api.md) and
    [headless-graphql-api.md](../headless-graphql-api.md) disagreed with the
    policies about who may unpublish. They now say that publish and unpublish
    need an admin unless the site lets editors publish.
  - **Editor reading track.** The guide is first; Trash and restore leaves
    the track (deleting and restoring are admin-only) and is still linked
    from the guide and listed on the index.
  - **Home page.** On the stock home page, which ships to every install, the
    "Editorial workflow" card now links "Walk through the workflow" and the
    "Roles and permissions" card "See who can do what", both to the guide on
    GitHub (`main`), the same way the "How it works" button links out. A
    relative `/docs` link would 404 on an install that does not publish the
    guides. The two labels are translated in `es` and `fr`. A site whose home
    page is a published `home` page does not show this page.
  - **Screenshots on kilncms.dev.** The rich-text sanitizer keeps no `<img>`,
    so until now an image in a guide published as nothing. The publisher
    (`scripts/publish_docs.exs`) now sends a paragraph that holds only an
    image of a repo file as an image block, linked to a media-library item.
    It uploads each file once through `POST /api/media`, with the same
    `KILN_DOCS_API_KEY`, named `<basename>-<first 12 hex of its
    sha256>.<ext>`, and finds it by that filename on later runs. A run checks
    every image of the guides it publishes first: a missing file or empty alt
    text raises before any page or media item is written, and so does a
    failed upload. A change to a file under `docs/images/` republishes every
    guide that shows it. A guide with no images publishes exactly the single
    rich-text block it did before.
  - **Other images in guides.** An image inside a paragraph or a link now
    publishes as its alt text, so the "Deploy to Render" button in
    [One-click deploy platforms](../deploy-platforms.md) publishes as a
    labelled link instead of an empty one. A standalone image at an external `http(s)` URL
    publishes as a link to it, labelled with its alt text, because the
    site's `img-src` policy would block it. `--dry-run --out` renders images
    as `<figure>`s loading the files from GitHub and uploads nothing.
  - **ExDoc.** `docs/images/` is copied into the docs build as `images/`
    (`assets:` in `mix.exs`), so the same relative `images/...` path works
    in ExDoc and on GitHub.
  - **For contributors.** The screenshots come from
    `e2e/screenshots/editorial-workflow.spec.js`, with numbered callouts
    drawn by `e2e/screenshots/annotate.js`, and are derived to WebP by
    `scripts/optimize_home_images.sh docs`. The test above holds them to 90
    KB per image, 600 KB for the guide and eight images, each referenced and
    with alt text. CONTRIBUTING.md → "Adding screenshots to a guide" has the
    steps.
  - **Upgrade.** Nothing to do on a Kiln install. On kilncms.dev, the first
    publish after the merge resends every guide (`mix.exs` and the publisher
    changed) and uploads the eight screenshots to the media library, so the
    docs key's account must be allowed to upload media. A screenshot that is
    later replaced leaves its old media item behind, because the new file
    has a new name; delete superseded items in the media library.

## Fixed

<a id="contract-backfills-reach-trash"></a>

- **`mix kiln.fields.convert` and `mix kiln.media.resnapshot` now also
  process documents in the trash, so a document restored after a contract
  release has the new field shape and current media snapshots (#2533).**
  Both read only live records, and since #2332 their writes were refused on
  a trashed row anyway. A document trashed before a conversion and restored
  after the release that deleted the source field came back without its
  values; one restored after a media shape change came back with the old
  snapshot.
  - **What changed.** Each task reads the live records, then the trashed
    ones (`ContentTypes.list_trashed!/2`), and their actions
    (`:convert_custom_field`, `:resnapshot_media`) are now exempt from
    `KilnCMS.CMS.Changes.RefuseTrashed`. A trashed record's write fires no
    artifact: its artifacts were removed when it was trashed, and a restore
    rebuilds them. The check is made on the row the `UPDATE` returned
    (`KilnCMS.CMS.Changes.FireArtifacts`, new option `skip_trashed: true`),
    so a record restored between the task's read and its write is still
    fired with the new shape.
  - **Field conversion.** All or nothing now applies to live records only.
    A trashed record that cannot be converted is listed with `(trashed)`
    after its id, keeps its string and does not block `--apply`; the
    `invalid record(s); nothing written` error counts only live ones. The
    summary line reads `(N published, N trashed)`: `published` no longer
    includes trashed records, and the new `trashed` count is the trashed
    records converted (or, on a dry run, that would be). Each problem in the
    report (and `--report` JSON) gains `trashed?`. For a multiple select
    target, `terms` and `new_terms` include the terms of trashed records,
    since a restored record needs its terms in the options too. New
    `KilnCMS.CMS.FieldConversion.blocking/1` returns the problems that stop
    `--apply`.
  - **Media resnapshot.** The report gains `trashed` (trashed records
    re-snapshotted, or that would be) and `trashed_failed`. A trashed record
    that fails, often because it names an item deleted since, is printed
    with `(trashed)` and does not fail the task. The summary reads
    `re-snapshotted N (N trashed)`.
  - **Operators.** The live and trashed records are two reads, so a record
    trashed or restored during a run can be missed by both. Run either task
    once more right before the release that relies on it; records already
    converted or current are not rewritten. No migration, no config.
  - **Not covered.** The daily refresh of computed fields
    (`:refresh_computed`) and `mix kiln.occurrences.backfill` still skip
    trashed records.

<a id="field-lock-release-mid-flush"></a>

- **Field locks: a field released while a takeover waits on its holder's
  save is never left free (#2557).** In collaborative editing a takeover
  asks the holder to save, then hands the field over. If the holder clicked
  out of the field meanwhile, the field went free: a third editor who
  focused it was given it, and when the takeover's wait ran out it was taken
  from them without asking them to save, so what they had typed was lost.
  - **A click-away during a takeover waits for the save.** The holder keeps
    the field (others are told it is held) until their save answers or the
    wait runs out, then it goes to the taker. The holder is not told it was
    "taken" from them. Clicking back in cancels the click-away.
  - **Where no save can come, the hand-over is immediate:** an idle or
    closed-tab timeout, or the holder leaving the editor.
  - **Only the field's current holder can answer "saved"** (`KilnCMS.Collab.FieldLock.flushed/3`
    takes the holder's pid, defaulting to the caller), so a late answer from
    an earlier holder cannot hand over the next holder's field unsaved.
  - A taker who has left is handed nothing, and leaving the editor withdraws
    your own waiting takeovers, so a field is never locked to a closed tab.
  - No migration or configuration. Collaborative editing is off by default.

<a id="restore-refuses-stale-copy"></a>

- **Restoring a version from a copy of the document that someone has since
  changed is now refused, instead of reporting success and writing nothing or
  skipping the publish-time checks (#2532).** `:restore_version` writes the
  old version's values onto the record the caller holds and judges that
  record: its workflow state decides whether the compliance-claim and
  alt-text gates run, and Ash drops any value equal to it. A copy read before
  a later save therefore restored nothing whenever the old version matched
  the copy (the editor still said *Restored that version.*), and a draft copy
  held across a publish put the old text on the live page without the gates
  a published page gets.
  - **What changed.** The restore now matches only a row whose
    `lock_version` and `state` are still those of the copy it was given
    (`state` too, because publish, unpublish, archive and unarchive keep
    `lock_version`). Anything else is refused with
    `Ash.Error.Changes.StaleRecord` and writes nothing, not even a version
    row. A document moved to the trash meanwhile is refused the same way.
  - **Editors.** Confirming *Restore this version* after someone else saved
    the page shows the conflict banner a stale save shows: *Someone else saved
    changes to this content. Saving is paused so you don't overwrite their
    work.*, with **Reload latest**. Your unsaved text stays in the form until
    you reload. If the page was trashed meanwhile, the banner says so and
    offers **Back to content**.
  - **API.** `POST /api/content/:type/:id/revisions/:version_id/restore`
    answers `409` `invalid_state_transition` when a save lands between the
    route's read and its restore (before: success that might write nothing,
    or `422` `restore_failed`), and `404` `not_found` when the document was
    trashed meanwhile (before: `422`). A credential the content policies
    refuse still gets `403`. On a `409`, read the document again and retry;
    `kiln_client` and the JS client already map `409` to their conflict
    error. Guide: [api.md](../api.md#version-history-revisions).
  - **Still not covered.** Writes that keep both `lock_version` and `state`
    do not make a held copy stale: the computed-field refresh, field
    conversion, `:resnapshot_media`, `:set_oembed_metadata`, `:move` and
    `:reassign_author`. None of them changes the state, slug or text the
    restore judges.
  - No migration and no config. Overlay code that restores from a record
    read before a later write must read it again first
    ([Breaking](#restore-version-stale-struct)).

<a id="restore-bumps-lock-version"></a>

- **A save from a tab opened before a version restore no longer silently
  undoes the restore (#2532).** A restore left `lock_version` alone, so the
  other tab's copy still passed the optimistic lock and its save wrote the
  pre-restore text back over the restored one without a conflict. A restore
  now increments `lock_version`, so that save is refused as stale and the
  other tab shows the conflict banner with **Reload latest**. No migration
  and no config.

<a id="purge-refuses-restored-rows"></a>

- **A permanent delete no longer removes a record someone restored after the
  Trash page loaded (#2531).** The trash is a soft delete, and the content
  and media `:purge` actions were left outside its read filter so they could
  reach trashed rows. They did not check that the row was still trashed,
  though, so the Trash page (or the media library's trash view) acted on the
  row it had listed, whatever had happened to it since. If another admin
  restored a document and someone then clicked **Delete permanently** on the
  stale row, the live document was hard-deleted: its pages and artifacts were
  left in place, and no `deleted` webhook went out. A media file was deleted
  along with its stored original, variants and cached transforms.
  - **What changed.** Content `:purge` (every type built on
    `KilnCMS.CMS.Content`, overlays' included) now deletes only a row whose
    `archived_at` is set, the mirror of the check `:restore` gained in
    #2528. `KilnCMS.CMS.MediaItem`'s `:purge` deletes a trashed item or a
    quarantined one; the second keeps the media pipeline's purge of an upload
    it refused or that never finished processing (#1659) working. Anything
    else is refused with an `Ash.Error.Invalid` holding an
    `Ash.Error.Changes.StaleRecord`, and the purge's hooks roll back with it.
    The media library deletes stored files only after the purge succeeds, so
    a refused one leaves them.
  - **Editors and admins.** On the Trash page, **Restore** or **Delete
    permanently** on an item another admin restored says *Someone else
    already restored that item.*; on one someone permanently deleted it says
    *That item is no longer in the trash — someone permanently deleted it.*
    Either way the list reloads without the row, so the next click can't
    fail the same way. Before this, a second restore said *Couldn't restore
    that item.* and the row stayed listed, failing on every retry. Other
    refusals keep *Couldn't restore that item.* / *Couldn't delete that
    item.* and the row. **Empty trash** counts a row that left the trash
    while it ran as neither deleted nor skipped. In the media library's trash,
    **Delete permanently** on a file someone restored says *That item is no
    longer in the trash — someone else restored or deleted it.*
  - **Restore with a unique field.** Restore on the Trash page now acts on
    the full row rather than on the narrow one the list reads. The
    unique-field re-check on restore (#2276) reads `custom_fields`, which the
    list leaves out, so restoring a document of a type with a `unique` custom
    field failed there; it now restores, or says *Couldn't restore that
    item.* when another document holds the value.
  - **Developers.** Code that calls `purge_<type>` or `purge_media_item` on a
    record that is not in the trash now gets the `StaleRecord` error. Trash
    it first (`destroy_<type>`), then purge. The nightly purge reads only
    trashed rows and is unaffected. New
    `KilnCMS.CMS.ContentTypes.can_restore?/4` and `can_purge?/4` ask the
    `:restore` and `:purge` policies for one record. The API never exposes
    `:purge`, so no API response changes. No migration and no config.
    Guide: [Trash and restore](../trash.md#delete-permanently).

<a id="unconfirmed-applicant-confirm-first"></a>

- **An applicant whose registration waits for approval and who hasn't
  confirmed their address is now told on `/account` to confirm it first, and
  how (#2516).** An administrator can't approve an unconfirmed address, and
  nothing told the applicant that, so they could wait for an approval that
  could never come. Under "Waiting for approval on (site)", **Your account**
  now adds "Confirm your email address first: an administrator can't approve
  your registration until you do.", a **Reset your password to confirm it.**
  link to `/reset`, and "Or use the link in the confirmation email we sent,
  if it's still valid." The reset comes first because it always works: every
  unconfirmed account signed up with a password, and finishing a reset
  confirms the address. The confirmation link lasts 3 days and can't be sent
  again. A confirmed applicant, or an unconfirmed account with no waiting
  registration, sees no change.

  A magic-link sign-in does not confirm an address, and never did. The
  confirmation settings on `User` listed `:sign_in_with_magic_link` among the
  actions that confirm, but with magic-link registration off that action is
  a read, and confirmation runs only on a create or an update, so the entry
  did nothing. It is removed, so the code no longer claims otherwise. Behavior
  is unchanged: the confirmation link, a password reset, single sign-on and
  site single sign-on registration, accepting an invitation, and the
  first-run admin still confirm. Confirming on a magic-link sign-in has to
  settle what happens to credentials an earlier registrant of the address
  set up (forgetting them would also delete a genuine registrant's own
  password), so it is left to #2594.

  No migration and no setting; rolling back is safe.

<a id="unknown-atom-values-load"></a>

- **A security event type or notification event a newer release wrote no
  longer breaks the release reading it (#2509).** `Security.Event.type` and
  `Notification.event` were plain `:atom` columns, and Ash loads one with
  `String.to_existing_atom/1`: a stored value the running release did not
  know failed the whole read, not just its row. During a rolling deploy, or
  after a rollback, one such row took down the security log page, its CSV
  export, `Security.anonymize_actor/1` (and so account erasure), the
  notification bell, the inbox and "mark all read".

  Both columns are now `KilnCMS.Types.KnownAtom`, which loads a value outside
  the column's `one_of` as `%KilnCMS.Types.UnknownAtom{value: "the_name"}`
  and never creates an atom from database text. What readers do with it:
  - **Security log:** the row shows as "Unrecognized event (name)" in a
    neutral badge; the CSV export carries the raw name in `type`; filtering
    by a known type excludes it; erasure still scrubs its actor, IP address,
    user agent and metadata, and the retention prune still deletes it.
  - **Notifications:** the row shows the generic "Notification" headline and
    links to `/editor/inbox`; marking it read or unread works.

  Writes stay strict: recording or notifying with a value outside the list is
  refused, an `UnknownAtom` included. No migration: the storage is still text.
  This protects only from this release on. A release that predates it still
  fails on a newer value, which is why a column has to switch to `KnownAtom`
  at least one release before it gains a value
  ([New values in an atom column](../releasing.md#new-values-in-an-atom-column)),
  and why rolling back to v1.8.0 needs the
  [one-time cleanup](#rollback-to-1-8-0-upgrade). `ApiKey.access` is still
  a plain `:atom` column
  ([#2604](https://github.com/The-Verscienta/kiln_cms/issues/2604)).

<a id="generation-tokens-survive-clears"></a>

- **Clearing or evicting the delivery cache no longer moves a site's
  `<head>` and menus generation tokens back, so a browser holding an old page
  is no longer answered `304` with a stale `<head>` or navigation (#2502).**
  A page's `ETag` folds the site's head-generation token, and cached menu
  trees are keyed on its menus-generation token; a save of branding, code
  injection, feed settings or a menu draws a new one of each on every node.
  Both tokens lived in the delivery cache and fell back to `"0"` when absent,
  so anything that emptied it put every site back on `"0"`, the token its
  pages carried before the first such save on that node. A browser revalidating
  a page from then got `304 Not Modified` and kept the `<head>` (feed links,
  branding, injected code) and navigation the save had replaced. These
  emptied it:
  - editing a media item, a bulk media action and a portability import,
    which drop every published record because any page may reference an
    asset, and promoting a dynamic content type to a compiled one
    (`mix kiln.promote_data`);
  - the **Flush delivery cache** button on System, `mix kiln.cache.flush` and
    `KilnCMS.Cache.flush_delivery/0`;
  - the delivery cache's 10,000-entry cap, whose least-recently-written
    eviction reached the rarely written token keys first.

  The tokens now live in a Cachex instance of their own
  (`KilnCMS.Cache.generation_cache_name/0`) with no size cap, which no clear
  or flush touches. Each site's last-known admin allowlist moves there too,
  so the copy that stops a late read from moving the allowlist backwards
  survives a clear: a site last seen with the allowlist off still stays off
  through a database outage after a media edit or a flush (the copy keeps its
  24-hour expiry).

  **What changes for operators.**
  - A site whose settings and menus have not been saved since a node started
    no longer carries `"0"`: the node draws a random token on first read. On
    a cluster without sticky sessions, two nodes can therefore tag the same
    page differently until the site's next save, which costs a `200` where a
    `304` would have done, never a stale `304`. A restart also moves a site's
    page `ETag`s, as a deploy already did (#2463).
  - Rolling deploys keep bumps cluster-wide in both directions: tokens still
    travel as the message the previous release sends and understands, and
    each node files the keys into the right store on arrival.
  - No migration and no configuration. Rolling the pin back is safe; it
    brings back the old behavior.

  **For overlay and plugin authors.** The keys keep their names
  (`head_generation:<org_id>`, `menus_generation:<org_id>`,
  `admin_allowlist:last_known:<org_id>`) but are no longer in
  `KilnCMS.Cache.cache_name/0`. Code that read them from that instance with
  Cachex directly now sees nothing; call `KilnCMS.Cache.head_generation/1` and
  `KilnCMS.Cache.menus_generation/1` instead. `KilnCMS.Cache.peek/1` and
  `KilnCMS.Cache.put/3` route these keys to the right store.

<a id="refusal-wording-names-the-reason"></a>

- **A refused workflow action now names the reason it was refused, instead
  of saying "Only an admin can …" to people for whom that is not the reason
  (#2473).** A refusal carries no record of which rule refused it, so before,
  every refused publish said "Only an admin can publish. Submit the draft for
  review instead." and every refused return "Only an admin can return content
  to draft.", whoever was refused and on whichever site. The sentence is now
  chosen from the actor's effective tier on the site (a live temporary grant
  counts), their content-type scope, and the site's **Team → Publishing**
  switch, read at the moment of the refusal, in this order:
  1. An admin or a viewer sees "You don't have permission to do that."
  2. An editor refused **Return to draft** sees "Only an admin can return
     content to draft.", whatever the switch and whatever their scope:
     returning is an admin's step.
  3. An editor whose **Content types they may edit** (on **Team**) leave this
     type out sees "You can't edit this content type." for a publish,
     unpublish, archive, submit, unarchive, publish changes or mark reviewed,
     whatever the switch, since letting editors publish would not have
     helped them. Never for the trash: that is admin-only, so a wider scope
     would not help either.
  4. An editor on a site where only admins publish, refused a publish,
     unpublish or archive, sees "Only an admin can publish. Submit the draft
     for review instead.", "Only an admin can unpublish content on this
     site." or "Only an admin can archive content on this site." On the
     calendar the same editor sees "Only an admin can move a publish date on
     this site." or "Only an admin can move the unpublish date of a live page
     on this site."
  5. Anyone else (an editor where editors may publish, or refused the trash
     or another action the switch does not govern) sees "You don't have
     permission to do that."
  - **Calendar.** Dragging a chip whose record was trashed, or fell outside
    what you may read, since the calendar loaded now says "That item is no
    longer on the calendar — reload to see why." Before it showed the raw
    error, or (unreleased) an admin sentence.
  - **Bulk bar.** A refused bulk verb on the content list is judged on the
    tier and the switch alone, because a selection can span content types.
  - **Developers.** `KilnCMSWeb.WorkflowMessages.error/3` and `forbidden/2`
    take a context (`actor:`, `org:`, and `resource:` as a record or
    resource module); `error/2` and `forbidden/1` are gone. `refusal/2`
    returns `:out_of_scope`, `:needs_publisher`, `:needs_admin` or
    `:not_permitted`, and `refusal_message/2` turns that decision and the
    action into the sentence, so a caller with its own wording for one case
    (the calendar) decides once and falls back to the shared copy for the
    rest. No policy changed: the same people are refused as before.

<a id="block-strings-follow-page-locale"></a>

- **The text Kiln writes into a content page's article is in the page's
  language, and a form or newsletter sign-up on the page answers in it
  (#2465).** A page can be served in a language other than the visitor's: a
  French reader sent to an English page with no French translation gets the
  English one, with `<html lang="en">` and `Content-Language: en`. The
  article's blocks were built in English, but Kiln's own strings in them were
  rendered in the request's language, so the page mixed the two: an English
  sign-up heading over French **Nom** and **E-mail** fields.
  - **Inside the article** now follows the page: the byline and its date, a
    form block's labels, hints and error messages, a newsletter sign-up's
    fields, the human-verification widget, and an untitled embed's title. The
    embed title is also translated in fired `web` artifacts, which render in
    the document's locale.
  - **The chrome around the article** (header, search, language switcher,
    footer) still follows the request. Whether it should follow the page is
    an open decision, tracked with a related caching problem in
    [#2595](https://github.com/The-Verscienta/kiln_cms/issues/2595).
  - **Submit paths change on multilingual sites only.** A form block on a
    content page posts to `/<locale>/forms/<slug>` and a sign-up block to
    `/<locale>/newsletter/subscribe`, in the page's language with the default
    language included (`/en/…`): an unprefixed post takes its language from
    the visitor's session. A refused form submission re-renders, and the
    thank-you or "check your inbox" page answers, in the page's language. The
    form embed served at `/fr/forms/<slug>/embed` now posts to
    `/fr/forms/<slug>`, and the form's own page under any language prefix,
    the default's included, posts back under it. Single-language sites,
    editor previews and fired `web` artifacts keep the bare `/forms/<slug>`
    and `/newsletter/subscribe`, as do the sign-up `action` in the `json`
    artifact and `submit_url` in `GET /api/forms/<slug>`. A theme
    stylesheet, script or analytics rule that selects these forms by `action` should select
    `.kiln-form` or `.kiln-newsletter-signup` instead.
  - **Not covered yet:** a plugin block with its own Gettext backend still
    renders in the request's language; the locked-page and members-only
    teaser pages; a locale attribute on the `embed.js` snippet; and the
    language of the newsletter confirmation email.

<a id="render-etags"></a>

- **A change to rendered output that came without an edit no longer leaves
  revalidating clients on the old copy (#2463).** Two validators named the
  content but not what rendered it:
  - **Fired artifacts** (`/api/content/:type/:slug`) were tagged with the
    document's id, locale, surface and `updated_at`. A re-fire rewrites the
    stored body without moving `updated_at`: `mix kiln.refire_all` after an
    upgrade that changed markup, or `KilnCMS.Firing.refire/3`. A CDN or app
    holding the old body went on getting `304`. The `ETag` is now a digest
    of the body served, as `?fields=` responses already had, so it moves
    exactly when the bytes do. `?expand=` responses are digested with their
    expansion, and `surface=llm` by its Markdown. `Last-Modified` stays the
    last edit: Kiln itself answers `304` only on `If-None-Match`, but a cache
    in between that revalidates with `If-Modified-Since` alone can still keep
    a re-rendered body until it expires.
  - **Pages Kiln renders itself** are rendered on every request, but their
    `ETag` named only the record and the site's settings, so a deploy that
    changed a template or a block renderer kept answering `304`. It now also
    names the build (`KilnCMSWeb.BuildFingerprint`): the code of Kiln and of
    any overlay or plugin (each module's MD5, which ignores build paths and
    times), the version of every application they depend on, and the asset
    manifest when `mix phx.digest` wrote one. Every node of one release
    image computes the same value, and rebuilding unchanged source keeps it.
    A markup change made only by runtime configuration (an environment
    variable) is not covered.
  - The firing cache now stores each body as a JSON round trip gives it back
    (string keys, no structs), so a body cached straight from a fire and the
    same body read back from the table digest to the same `ETag`.

<a id="invitation-raises-lower-membership"></a>

- **Accepting an invitation raises a lower membership on the site to the
  invited tier, and says so; a later tier change or removal retires the
  pending invitation (#2452).** Before, an invitee who was already a member
  (they signed in through the site's own single sign-on first, or registered
  and were approved) kept their lower tier, the invitation was used up, and
  the page said "You've joined (site)" as if it had worked. Now:
  - **Lower than invited:** the membership takes the invited tier, and the
    invitation's custom role when it names one. Audiences, content type
    scopes, field grants, and a custom role the invitation doesn't replace
    are kept. The security log records *Role granted* with `previous_role`
    and no person, and the member's sessions are signed out after the commit
    so their next request runs with the new tier. A temporary role at or
    below the new tier is cleared.
  - **The invited tier or higher:** nothing changes; an invitation never
    lowers anyone. The flash reads "You're already a member of (site) as
    (tier); nothing changed." (or, on the password path, "Your account is
    ready. You were already a member of (site) as (tier), and that is
    unchanged."). A raise reads "You're now (tier) on (site) — sign in to
    continue."
  - The comparison is with the member's standing tier, made on the
    membership row as locked by the accept, so a site admin's edit between
    loading the page and clicking is what counts. A temporary role is not
    compared.
  - **Retiring:** `OrgMembership` `:update` (when it changes `role` or
    `role_id`) and `:destroy` delete the pending invitation for the member's
    address on the membership's own site, so a member you demote cannot use
    an older link to raise themselves back. The security log records the
    retirement as *Invitation revoked* (`invitation_revoked`, metadata
    `role`), with the admin who made the membership change as the person.
    Editing only audiences or type scopes, or a temporary role, leaves it
    alone.
  - A `:viewer` or `:editor` invitation whose sender has since lost the admin
    role still raises, as it already created a membership; an `:admin`
    invitation still needs a standing admin sender.

  For code: `OrgMembership` gains the system-only action
  `:raise_role_by_invitation` (code interface
  `Accounts.raise_membership_role_by_invitation`), admitted for
  `SystemActor.new(:invitations)` and a platform admin, and `Invitation`
  gains the destroy action `:retire`, admitted for
  `SystemActor.new(:invitations)` only (declared above the platform-admin
  bypass; an admin withdraws an invitation with `:revoke`).
  `Invitations.grant_membership/4` now returns
  `{:ok, %{outcome: :joined | :raised | :already_member, membership: membership}}`
  instead of `{:ok, membership}` or `{:ok, :already_member}`, and
  `Invitation` `:accept_existing` returns `%{outcome: ..., role: tier}`
  instead of `:accepted`. Both are system-only; only the invitation page
  calls them. See [Account administration](../account-administration.md#if-the-invitee-is-already-a-member).

<a id="field-lock-stale-timers"></a>

- **A field lock's timeout that fires in the same instant it is reset no
  longer acts on the field (#2351).** The issue was a flaky test in
  `test/kiln_cms/collab/field_lock_test.exs`: it gave the idle timeout 120 ms
  and slept 80 ms twice, so under host load the keystroke landed after the
  timer had already fired. The flake came from the test's own sleeps, not
  from the editor. The tests now drive the timeouts by sending the timer's
  message to the lock process, and keep one real-clock test each for the
  grace, idle and flush timeouts that only waits for the eventual result.
  - **Two narrow races in `KilnCMS.Collab.FieldLock`, found while fixing
    it.** A timer that had already fired could not be canceled: its message
    was in the lock process's mailbox, and the old tag still matched.
    - *Idle timeout.* The 15-minute idle timer was tagged with the holder's
      generation, which only changes when the field changes hands. A
      keystroke landing just as that timer fired restarted the clock, and
      then the queued timeout freed the field anyway, from someone who had
      just typed. Each idle timer now carries its own reference, and a
      keystroke replaces it, so a timeout that lost the race is ignored.
    - *Flush timeout.* A takeover's 3-second flush timeout carried no usable
      tag. If the holder's flush answered just as the timeout fired, and a
      second takeover of the same field arrived in between, the stale
      timeout granted the second takeover at once, skipping the flush that
      saves what the current holder had typed but not yet sent. Each pending
      takeover's timeout now carries that takeover's own reference; a
      timeout from one already settled is ignored. A second asker who joins
      a takeover still in flight is granted by that takeover's timeout, as
      before.
  - Both need a timer and a message to arrive within the same moment, so
    they were rare in practice. The grace timeout already tagged correctly
    and is unchanged. No configuration, migration or API change.

<a id="form-export-renamed-field-keys"></a>

- **A form's CSV export keeps the values stored under a renamed or removed
  field's old machine name, in a column headed `<key> (renamed or removed)`
  (#2342).** A submission keeps the keys it was received with, and the export
  had one column per current field, so after a rename the entries received
  before it lost that value from the file without a word, though the Entries
  tab showed it under **From a renamed or removed field** (#2139). Now the
  export adds one column per key the exported entries carry that no current
  field is named, sorted by key, between the current fields' columns and
  `status`, `spam_score`, `submitted_at`. Renaming `email` to `work_email`
  gives the header
  `work_email,email (renamed or removed),status,spam_score,submitted_at`.
  - **Who sees a change.** Only exports whose entries carry an old key. A
    form never renamed, or a `?status=` filter that leaves no entry with an
    old key, exports exactly the columns it did before. A key that a current
    field has taken again (a reused name) is that field's column, as on the
    Entries tab.
  - **The suffix is fixed English.** It is a data header that a spreadsheet
    or import keys on, like the machine names and `status`, so it is not
    translated.
  - **In the builder.** The **Machine name** hint now reads "Entries already
    received keep the old key: the Entries tab and CSV export show it as a
    renamed field; API clients and webhooks use the new name from now on."
  - **Operators.** No migration, no config. Rolling the pin back is safe and
    brings back the old columns.

  Guide: [Read entries after a rename](../forms.md#read-entries-after-a-rename).

<a id="autoresponder-tokens-follow-rename"></a>

- **Renaming a form field rewrites its `[field:<old>]` tokens in the
  autoresponder, and a field the autoresponder uses can no longer be deleted
  while it is on (#2343).** The autoresponder's subject and body name fields by
  machine name, and a rename or delete left the old token in place, where it
  rendered empty in every confirmation email from then on, with no warning.
  - **Rename.** Every exact `[field:<old>]` in the **Confirmations** subject
    and body becomes `[field:<new>]` in the rename's own save, whether the
    autoresponder is on or off; `[field:email2]` is untouched when `email` is
    renamed. The builder's field panel adds "The autoresponder now uses
    [field:new] where it used [field:old]." when the template changed, the
    **Confirmations** tab shows the rewritten text, and the **Machine name**
    hint now ends "The autoresponder's [field:…] tokens follow the rename."
  - **Delete.** While the autoresponder is on and uses the field's token,
    deleting the field is refused with "The autoresponder uses [field:email]:
    remove it from the Confirmations template first." The builder used to
    ignore a refused delete; it now shows the reason. Remove the token, or
    switch the autoresponder off, then delete. Changing a field's `form_id` to
    move it to another form is refused the same way.
  - **Not repaired.** A template already holding a token for a field renamed or
    deleted before this release still renders it empty; fix it in the
    **Confirmations** tab. Such a stale token does not hold up the rename of a
    different field.
  - **Unchanged.** Webhook payloads, `GET /api/forms/<slug>` and stored
    entries still use the new name after a rename, as before.
  - **Operators.** No migration, no config. Rolling the pin back is safe;
    templates already rewritten keep their new tokens, which are correct.

  Guide: [Autoresponder tokens follow a rename](../forms.md#autoresponder-tokens-follow-a-rename).

<a id="composite-field-part-help"></a>

- **Range and link inputs explain themselves, and `Kiln.FieldType` input parts
  may declare `help:` (#2435).** An `input_parts/1` entry now takes an optional
  translatable `help:` string, rendered under its control and tied to it by
  `aria-describedby` (a `placeholder` cannot be translated). Range's two
  inputs say "a number or a date (YYYY-MM-DD)" and "the same kind as From";
  link's `Rel` input lists `noopener, noreferrer, nofollow, sponsored, ugc,
  external`. Additive: a part without `help:` renders as before.
  - **Verified, no change needed.** A hostile link address (`javascript:`,
    `//host`, `data:`, `tel:`) posted over real JSON:API HTTP is refused and
    nothing is stored (`test/kiln_cms_web/link_field_json_api_test.exs`); the
    `:kotlinc` golden compiles and decodes (run locally with kotlinx
    serialization 1.7.3); a Playwright spec
    (`e2e/tests/composite_fields.spec.js`) fills, saves and reloads the range,
    key/value and link widgets in a real browser, including the blank-first
    "Opens in" select and a refused address that keeps the typed text; dialyzer
    is clean.
  - **Left as is.** The range type's JSON Schema still lets each bound be a number or
    a date: saying "both the same kind" needs a `oneOf` of inline objects,
    which the TypeScript, Swift and Kotlin generators only support for `$ref`
    members. The server (`cast/2`) enforces it on write. Noted in the
    module docs.

<a id="trashed-row-updates-refused"></a>

- **Nothing can write into a document after it is moved to the trash (#2332).**
  Trashing is a soft delete: it stamps `archived_at`, and the read filter
  hides the row from every ordinary read. It did nothing for updates, so an
  editor, API client or background job that had loaded the document before
  someone trashed it could still save into the trashed row. An autosave went
  into the trash; a **Publish changes** from an editor still open on a live
  page re-fired its artifacts and sent an `updated` webhook after the
  `deleted` one; a transition or a held oEmbed refresh did the same. Now every
  such write is refused.
  - **Editors.** The content editor, the in-context editor and the
    Presentation console notice on their next write (an autosave, **Save**, a
    workflow button, **Reload latest**), not the moment the document is
    trashed. The flash reads *This content was moved to the trash or
    deleted.* and the banner *This content was moved to the trash or deleted,
    so your changes can't be saved. Copy anything you need before leaving.*
    with **Back to content** in place of **Reload latest**. The unsaved text
    stays on screen; autosave stops and Save stays disabled. **Move to
    trash** in the editor's Settings tab, on a document someone else has
    already trashed or deleted, says *Someone else already moved this to the
    trash or deleted it.* and returns to the content list. Guide:
    [If someone is still editing it](../trash.md#if-someone-is-still-editing-it).
  - **Webhooks.** After `deleted`, a document sends nothing until
    `restored`: no `updated`, `unpublished` or `archived`. Trashing a held
    document a second time is refused, so there is one `deleted`; restoring
    it a second time is refused, so there is one `restored` (on the Trash
    page the second admin sees *Couldn't restore that item.*). When a purge
    clears a reference to the purged document, a referrer that is itself in
    the trash still has the value cleared but is no longer re-fired or
    announced with `updated`.
  - **Scheduled publishing.** A trashed draft is never published by its
    schedule. Restored with a **Scheduled publish at** already past, it
    publishes on the scheduler's next run (every minute).
  - **APIs.** Unchanged for a trashed id: JSON:API, GraphQL and MCP already
    answered not-found. What changed is the race between their read and
    someone else's trash: the write used to land in the trashed row and is now
    refused. JSON:API and GraphQL answer not-found, MCP returns a tool error,
    and a revision restore (`POST /api/content/:type/:id/revisions/:version_id/restore`)
    answers `422 restore_failed`. Not a breaking change: the request was
    already one that could answer not-found.
  - **Background jobs.** The embedding and oEmbed workers, caught in the same
    race, get `Ash.Error.Changes.StaleRecord`, retry, find no record and end
    `:ok`.
  - **Operators.** No migration, no config, nothing to run. Rolling the pin
    back is safe and brings the old behaviour back.
  - **Developers.** See
    [the Changed entry](#trashed-row-update-actions-refuse) for overlay
    update actions.

<a id="redeliver-deleted-endpoint"></a>

- **A delivery whose endpoint was deleted no longer offers a Redeliver button
  that can only fail, and shows the URL it was sent to (#2330).** Deleting an
  endpoint keeps its delivery history, but **Recent deliveries** on
  `/editor/webhooks` showed those rows with an empty endpoint column and a
  Redeliver button whose every click said "Couldn't redeliver that webhook."
  Now each such row shows the URL the delivery was sent to, followed by
  "(deleted endpoint)", and has no button. The **Retractions not delivered**
  panel on a document's governance trail already hid the button; it now shows
  the URL with the same "(deleted endpoint)" mark instead of the label alone.
  If the endpoint is deleted after the page loaded, clicking Redeliver in
  either place says "That delivery's endpoint was deleted, so it can't be
  redelivered." and the row updates; other failures keep the old message.
  A deleted endpoint's deliveries can't be replayed, because the signing
  secret went with it: to reach the same receiver, add its URL as a new
  endpoint ([Delete an endpoint](../webhooks.md#delete-an-endpoint)).

<a id="single-field-handed-a-list"></a>

- **A single number, date, link or other scalar custom field sent a list now
  keeps the list's first item, as a single string or select already did
  (#2289).** Before, a single `:url` field written `["https://a",
  "https://b"]` stored `"https://ahttps://b"`, and other types answered with a
  misleading error or raised on an object item. The same happens when a
  version saved while the field was a list is restored. Blank items are
  skipped before the first is taken; an object item is refused with `must be
  a single value`. An API client that sends an array to a single field now
  gets its first item stored without an error, so send one value.

<a id="read-only-list-events"></a>

- **The content editor ignores list edits on a custom field the editor's
  field grant leaves read-only (#2289).** The field already rendered disabled
  and the save refused it (#2281); now a forged add, remove or reorder event
  for a list, gallery or repeating-group field it cannot edit changes
  nothing in the form either.

<a id="custom-sort-json-null-last"></a>

<a id="auth-pages-landmarks-autocomplete"></a>

- **The sign-in, register and reset pages now have a header landmark, one `h1`,
  and `autocomplete` on their email and password boxes (#2162).** An
  accessibility audit found auth content outside any landmark, no `h1`, and
  fields a password manager had to guess at.
  - **Landmarks and heading.** The environment banner and logo row are a
    `<header>`, and the flash toast sits inside `<main id="main">`. The page
    carries one screen-reader-only `h1` holding the page title (the tab title
    the page already had), so it follows sign-in, register and reset as the
    view changes. Each view keeps its visible heading, which stays an `h2`.
    The two-factor prompt at `/sign-in/verify` follows the same rule: its
    visible "Two-factor authentication" heading is now an `h2`, under the
    hidden `h1`. Nothing looks different.
  - **`autocomplete`.** The email box on sign-in, register and the
    reset-request form has `autocomplete="email"`. The password box has
    `current-password` on sign-in and `new-password` on register and on the
    reset-token form, as do the confirmation boxes, so a password manager
    offers to save a new password and does not fill a saved one into a "choose
    a password" box (WCAG 1.3.5).
  - **Not covered.** The email box on the magic-link request form still has no
    `autocomplete`: it is rendered inside the library's component, and
    changing it would mean copying that whole component.
  - **For overlay authors.** Two more library renders are now Kiln copies:
    `KilnCMSWeb.AuthIdentityInput` (the email box) and
    `KilnCMSWeb.AuthResetRequestForm` (the `/reset` request form), next to
    `AuthSignInForm`, `AuthRegisterForm`, `AuthResetForm` and
    `AuthPasswordInput`. `KilnCMSWeb.AuthOverridesTest` renders the sign-in,
    register and reset-token forms against upstream's and fails if they differ
    by more than the `autocomplete` attribute, so re-run it when bumping
    `ash_authentication_phoenix`; the `/reset` request form is not in that
    comparison, so re-read `AuthResetRequestForm` against upstream's
    `Password.ResetForm` by hand.
    `AuthPasswordInput.password_field/1` and `password_confirmation_field/1`
    now require an `autocomplete` attribute; an overlay that calls them must
    pass one. No configuration, migration or upgrade step.

- **`custom_sort` treats a stored JSON `null`, array or object as no value, and
  page 2 of a keyset-paged `custom_sort` no longer fails on one.** On the
  JSON:API and GraphQL reads, a record whose custom field was stored as a JSON
  `null` used to sort first (Postgres orders a jsonb `null` below everything),
  and one holding an array or object sorted by jsonb order; if such a value
  was the last row of a page, the keyset read for the next page failed because
  the cursor could not be bound back into the filter. Now all three sort
  together with records that lack the key, last in ascending and descending
  order alike, and the next page reads. Callers sorting on a sortable scalar
  field see a change only if some record holds one of those values (for
  example after a field was retyped); everything else is unchanged. Not a
  breaking change, since the documented rule is "records without the field sort
  last".

<a id="form-field-rename"></a>

- **Renaming a form field's machine name saves on Enter, shows on the canvas,
  and the Entries tab no longer passes old keys off as current fields.** The
  field settings panel had no submit button, so Enter in **Machine name** did
  nothing and a reload showed the old name; a refused name snapped back with
  only a flash; the canvas never showed machine names; and the Entries tab
  printed each submission's raw keys, so entries received before a rename
  kept showing the old key (such as `string`) and looked as if the rename had
  not saved (#2139).

  The panel now has a **Save** button, and Enter in any input saves too. As
  you type, each change saves only the input it came from, so one refused
  value no longer blocks edits to the others. A refused value stays in its
  input, marked invalid, with the reason underneath; the panel says
  **Saved.** after a save that changed something. Each field on the canvas
  shows its machine name. Renaming a field on a form that has entries adds
  "Entries already received keep the old key “old”." to the panel, and the
  Machine name hint now says that entries keep the old key while exports and
  API clients use the new one. The Entries tab lists each value under its
  current field's label and machine name, and groups keys no current field
  has under **From a renamed or removed field**.

  Stored submissions are not rewritten. Still open: the CSV export drops an
  old key's values (#2342, since fixed: see
  [above](#form-export-renamed-field-keys)), an autoresponder `[field:old]` token renders
  empty after a rename (#2343, since fixed: see
  [above](#autoresponder-tokens-follow-rename)), and there is no option to rewrite old keys
  (#2344). Nothing to configure or migrate. See
  [Edit and rename form fields](../forms.md#edit-and-rename-form-fields).

<a id="public-form-page"></a>

- **`/forms/<slug>` is the form's own page: an active form, inside the site's
  layout.** The form builder showed `/forms/<slug>` under every form's name,
  and that address answered 404: the only browser page for a form was the
  iframe document at `/forms/<slug>/embed`, which the forms list linked
  instead (#1783) and which looks unfinished outside a frame. A GET there now
  renders the form's name, description and fields in the site's header and
  footer, posting to `POST /forms/<slug>` like a form block. Under a language
  prefix (`/fr/forms/<slug>`) it posts back under the prefix, so a refused
  submission re-renders in the visitor's language. The page is served with
  `Cache-Control: public, max-age=60, stale-while-revalidate=300`,
  `Vary: Accept-Language` and `X-Robots-Tag: noindex`, matching the embed
  document's `noindex`; forms stay out of `sitemap.xml`.

  It is not a new route and `forms` is not a reserved path segment: the page
  is the last fallback of the delivery 404, the slot the event index already
  takes. A site with a content type of its own at `/forms` keeps its entries,
  and a path alias, redirect, lock page or teaser at the address still wins.
  An inactive form, an unknown slug and another site's slug 404 as before and
  are recorded on the 404s list.

  In the console, the builder's header links the page's full address on the
  site's host (or says "Not public while inactive.") and **Preview** opens it;
  the forms list's **Hosted form** address is now the page rather than
  `/embed`. The thank-you page after a submission is still the plain card
  without the site's layout. Nothing to configure or migrate. See
  [Share a form at its own address](../forms.md#share-a-form-at-its-own-address).

<a id="webhook-delete-labelled"></a>

- **A webhook's Delete is a labelled button on its row, and the edit form has
  one too.** Delete on `/editor/webhooks` was an unlabelled grey trash icon
  after three text buttons (Ping, Disable, Edit), easy to miss; an admin
  looking for it concluded an endpoint had to be disabled before it could be
  deleted. It never did, and the row now shows a red **Delete** with its icon
  for every endpoint, active or disabled. The edit form gains **Delete
  webhook** beside Save and Cancel. Both ask the same question, which now says
  what deleting does: "Delete this webhook? Queued deliveries, including
  retractions, won't be sent. Delivery history is kept." The old prompt said
  only that deliveries would stop. Who may delete is unchanged (admins only),
  and the `docs/webhooks.md` line that said deleting an endpoint takes its
  delivery history with it, untrue since deliveries outlive their endpoint,
  is corrected. On a narrow screen the row's actions now wrap below the
  endpoint's details instead of beside them. See
  [Delete an endpoint](../webhooks.md#delete-an-endpoint).

<a id="columns-child-fresh-form"></a>

- **Nested column events work on a freshly opened page.** `AshPhoenix.Form.params/1`
  carries only touched nested forms, so before the first `phx-change` it had no
  `"blocks"` key. `inject_children/2` then inserted `"blocks" => nil` and the next
  `Form.validate/2` crashed in `condense/2` (`Enumerable` not implemented for `nil`).
  Every `apply_children/2` caller (`col_add_child`, `col_remove_child`, `col_reorder`,
  `col_update_child`, …) now starts from `Preview.form_params_with_blocks/1`, which fills
  the list from the form's values, and `inject_children/2` no longer creates a nil key.

<a id="phoenix-1-8-16-subscription-pushes"></a>

- **The Phoenix stack moves to 1.8.16 (phoenix_pubsub 2.4.1, phoenix_live_view
  1.2.13, websock_adapter 0.7.0), together with absinthe_phoenix 2.0.6.** Phoenix
  1.8.16 replaces PubSub's custom dispatchers with per-subscription senders:
  Phoenix's channel server dispatcher now passes broadcasts to the default
  dispatch, which ignores the `metadata: {:fastlane, transport_pid, serializer, _}`
  shape. absinthe_phoenix 2.0.5 still subscribes each GraphQL subscription
  document with that metadata. On 1.8.16, a `subscription:data` broadcast
  therefore went to the channel process instead of the socket's transport.
  absinthe_phoenix's channel then dropped it in its catch-all `handle_info`. The
  result was that every subscription accepted the subscribe call and never
  pushed anything, in production as well as in tests (the six failing
  `assert_receive` cases in `graphql_subscription_test.exs` and
  `graphql_limits_test.exs`). absinthe_phoenix 2.0.6 subscribes with a sender
  instead (absinthe_phoenix#113/#114). `mix.exs` now requires
  `absinthe_phoenix >= 2.0.6` and `phoenix ~> 1.8.16`, so the lock can't pair
  them wrongly again.

<a id="exla-fine-pin"></a>

- **A from-scratch `KILN_ML=1` build compiles EXLA again.** The Phoenix
  1.8.16 bump above also moved the test-only `lazy_html` to 0.1.14, which
  requires `fine ~> 0.2.0`, so the lock took fine 0.2.0. EXLA 1.0.0 allows
  `fine ~> 0.1` but its NIF does not compile against 0.2 (`'try_decode' is
  not a member of 'fine::Decoder<xla::Shape>'`). Lean builds were
  unaffected. The `-ml` image and any overlay building with `KILN_ML` on
  failed, and an overlay could not pin around it, since
  `mix kiln.plugins.doctor` holds core dependencies at core's lock.
  Two guards now hold it, landed in parallel: the KILN_ML dependency list
  requires `fine ~> 0.1.0` (#2212), and `lazy_html` is capped below 0.1.14
  (#2213), so a lean lock refresh, where the KILN_ML list isn't loaded, can't
  pull fine 0.2.0 back in either. Both lock entries are back to their v1.8.0
  versions; lift both guards together once an EXLA release builds against
  fine 0.2. CI's ML leg missed the break because EXLA
  caches `libexla.so` under a key without `fine`, and the leg restored that
  cache on the lock change. It now rebuilds the NIF from source whenever its
  cache isn't an exact hit. Overlays that re-seeded `project.lock` from the
  1.8.16 bump re-seed once more.

<a id="new-menu-button"></a>

- **The content list's "New" menu is a real `<button>` with `aria-expanded`.**
  Past three content types, `/editor` folds its "New …" buttons into one
  menu. Its trigger was a `<summary>` styled as a button, with the marker
  hidden; an accessibility walkthrough found it wasn't announced as a button.
  It is now a disclosure: a `<button aria-expanded aria-controls>` that shows
  and hides the panel of per-type buttons. The shared `data-autoclose`
  handler in `app.js` closes it on a click outside or on Escape, and only
  claims Escape while the menu is open, so Escape in the search box or a
  modal keeps its focus. The old `<details>` also lost its `open` state on
  every LiveView patch, so a list refresh behind an open menu snapped it
  shut; the new one keeps its state across patches it didn't cause.

<a id="public-muted-text-contrast"></a>

- **Secondary text on public pages and in the shared form components moves from 50-60% to 70% opacity, so it clears WCAG 1.4.3 (4.5:1).**
  Muted text is `text-base-content` at reduced opacity, and nothing renders
  wrong when the opacity is too low. Measured against the theme tokens in
  `assets/css/app.css`, `/60` is 4.12:1 on the light theme's page background
  and `/50` is 3.09:1; `/70` is about 5.1:1 or better on every surface in both
  themes. The public templates (blog and event indexes, search, newsletter
  confirmation, the home page), the release preview, the setup wizard, public
  forms, the block components, form field hints, the empty-state text, the
  password show/hide toggle and the flash close icon (`opacity-40` to
  `opacity-70`) now use `/70`. Overlays and plugins that copy these classes
  are unaffected; nothing changes in markup structure or in any API.
  - **A guard keeps it that way.** `test/kiln_cms_web/muted_text_contrast_test.exs`
    scans `lib/kiln_cms_web` for `text-base-content/N` (and bare `opacity-N`)
    below 70. Public paths must be at zero. The console is a ratchet against
    `test/kiln_cms_web/muted_text_console_baseline.txt`: a file may not gain
    offenders, and the count only goes down. A non-text use (an icon glyph, a
    disabled control) is exempted with a `contrast-ok: <why>` comment on the
    same line or the line above.
  - **What the guard does not do.** It reads class names, not rendered
    contrast: it does not run axe (there is none in the repo), and it does not
    see templates authored outside this repo, such as a plugin's. The
    authenticated console still has muted text below the floor; it is counted
    in the baseline and lowered as files are touched.
  - **Contributors.** After lowering a console count, regenerate the baseline
    with `KILN_UPDATE_CONTRAST_BASELINE=1 mix test test/kiln_cms_web/muted_text_contrast_test.exs`
    and commit the file. See [Muted text](../design-language.md#muted-text).
  ([#2163](https://github.com/The-Verscienta/kiln_cms/issues/2163))

<a id="focusable-code-blocks"></a>

- **A code block that scrolls sideways can now be reached and scrolled from
  the keyboard (#2164).** A code block with a line wider than the column
  scrolls horizontally, and a scroll container with nothing focusable in it
  can only be scrolled with a mouse or touch, so a keyboard user could not
  read the end of a long line (axe's `scrollable-region-focusable`, WCAG
  2.1.1). Every code block in a rich-text block now renders as
  `<pre tabindex="0" role="group" aria-label="Code sample">` (a highlighted
  one keeps `class="highlight"` first). Tab stops on it, the arrow keys scroll
  it, and a screen reader announces "Code sample". Whether a block overflows
  depends on the reader's screen, which the server cannot know, so every code
  block is focusable, not only the long ones.
  - **Where.** It is added once, at the end of the rich-text block's `:web`
    render, so it reaches public pages (columns and fragments included), every
    editor preview, fired `:web` artifacts, and through them feeds,
    newsletter email and the static export.
  - **Label language.** The label is translated (French "Exemple de code",
    Spanish "Ejemplo de código") and follows the content's locale, not the
    request's: on a live page, including a cached second hit, and in a fired
    artifact. An English page served under `/fr/` because it has no French
    translation keeps the English label. Editor previews follow the editor's
    interface language.
  - **Focus ring.** `pre[tabindex="0"]:focus-visible` draws a 2px solid
    `--color-primary-ink` outline, inset by 2px so a parent's
    `overflow-x: clip` (the `monograph` preset) cannot cut it off, and in the
    ink shade because plain `primary` on the block's `base-200` fill falls
    under the 3:1 non-text contrast of WCAG 1.4.11 in the light theme. A site's
    custom CSS should leave that outline in place
    ([Custom CSS](../public-theming.md#custom-css)).
  - **Authors cannot set or remove them.** The rich-text sanitizer still
    strips every attribute but `class="highlight"` from a stored `<pre>`, so a
    pasted `tabindex="-1"` cannot take a block out of the Tab order; the
    attributes are added after it. The editor's own copy of the prose and the
    `:json` artifact are unchanged.
  - **The console's own code blocks too.** The update command on System, the
    security.txt preview, the image-backend adopt commands, and the code
    samples on `/developers` and the home page carry the same attributes, each
    with its own label ("Update command", "security.txt as served", "Commands
    for a release", "Commands for Mix", "Code sample").
    `test/kiln_cms_web/scrollable_code_focus_test.exs` fails if a `<pre>` in
    `lib/` with `overflow-x-auto` lacks them; see
    [Scrolling code blocks](../design-language.md#scrolling-code-blocks).
  - **Headless consumers.** The `:web` artifact's HTML gains the three
    attributes; nothing is removed and `format_version` is unchanged. An
    artifact fired before the upgrade keeps the old markup until its document
    is next published or edited (see the
    [upgrade note](#focusable-code-blocks-upgrade) for `mix kiln.refire_all`
    and why revalidating clients may still keep the old HTML). The `:json`
    artifact stays plain: a front end that renders `legacy_html` or Portable
    Text from it adds the attributes and a focus ring itself
    ([Code blocks in rendered HTML](../headless-consumer-guide.md#code-blocks-in-rendered-html)).
  - **One side effect.** A fired `:web` artifact is now rendered in its
    document's locale, so a newsletter signup block's labels ("Email",
    "Subscribe") in that artifact are in the document's language rather than
    in English, the firing worker's default. Live pages render them in the
    reader's language, as before.
  - **Not covered.** Code inside a plugin block's `:web` output, and wide
    tables, which have the same problem (#2464).

<a id="scrollable-tables"></a>

- **A table wider than the column can now be reached and scrolled from the
  keyboard (#2464).** A table scrolls sideways inside its `.kiln-table-wrap`,
  and a scroll container with nothing focusable in it can only be scrolled
  with a mouse or touch, so a keyboard user could not reach the columns past
  the edge of the screen (axe's `scrollable-region-focusable`, WCAG 2.1.1).
  Every table wrapper in a rich-text block now renders as
  `<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Scrollable table">`.
  Tab stops on it, the arrow keys scroll it, and a screen reader announces
  "Scrollable table" before the table itself. Whether a table overflows
  depends on the reader's screen, which the server cannot know, so every
  table is focusable, not only the wide ones. This is the code-block fix
  ([#2164](#focusable-code-blocks)) applied to tables, by
  `KilnCMS.ScrollableTables.focusable/2`.
  - **Old `legacy_html` tables get a wrapper.** A table stored as HTML (the
    old TipTap shape, and imported prose) had no scroll wrapper at all, so a
    wide one pushed past the column. A top-level `<table>` there is now
    wrapped in the same focusable `.kiln-table-wrap` and scrolls inside it. A
    table nested in another table's cell scrolls with its parent and is left
    alone. Prose whose table tags don't balance is left as it was.
  - **Where.** The same place as the code-block attributes, at the end of the
    rich-text block's `:web` render: public pages, editor previews, fired
    `:web` artifacts, and through them feeds, newsletter email and the static
    export.
  - **Label language.** "Scrollable table" is translated (French "Tableau
    défilant", Spanish "Tabla desplazable") and follows the content's locale
    the way the code-block label does, including on a cached second hit and
    in a fired artifact.
  - **Focus ring.** `.kiln-table-wrap[tabindex="0"]:focus-visible` draws a
    2px solid `--color-primary-ink` outline, drawn 2px outside the wrapper
    (`outline-offset: 2px`). Unlike the code block's ring it is not inset: on
    the inside it would sit on the cells' `base-300` borders and the header's
    `base-200` fill; outside, it sits on the page background, where the ink
    shade clears the 3:1 of WCAG 1.4.11 in both themes. A site's custom CSS
    should leave it in place
    ([Keep the focus rings](../public-theming.md#keep-the-focus-rings-on-code-blocks-and-tables)).
  - **Authors cannot set or remove them.** The rich-text sanitizer keeps only
    `class="kiln-table-wrap"` on that `div` and no attribute on a `<table>`,
    so a pasted `tabindex="-1"` cannot take a table out of the Tab order; the
    attributes are added after it. A `div` an author gives the class without a
    table directly inside is not made focusable. The editor's own copy of the
    prose, `KilnCMS.Blocks.PortableText.to_html/1`, and the `:json` artifact
    are unchanged.
  - **Headless consumers.** The `:web` artifact's HTML gains the three
    attributes on every table wrapper, and a `legacy_html` table that used to
    arrive bare now arrives inside a `div.kiln-table-wrap`. A stylesheet that
    targets a table as a direct child (`.kiln-block > table`) no longer
    matches it there; `.kiln-block table` still does. `format_version` is
    unchanged, so an artifact fired before the upgrade keeps the old markup
    until it is re-fired ([upgrade note](#scrollable-tables-upgrade)). The
    `:json` artifact stays plain
    ([Tables in rendered HTML](../headless-consumer-guide.md#tables-in-rendered-html)).
  - **Not covered.** The gallery block's carousel scrolls sideways with
    nothing focusable in it and has the same problem (#2590). Tables in a
    plugin block's own `:web` output carry whatever the plugin renders.

## Security

<a id="invitation-takeover-credentials"></a>

- **Accepting an invitation over an unconfirmed account now removes every credential the first registrant could have set up, not just their password and sessions (#2453).**
  Anyone can register an unconfirmed account for any address, sign in with
  the password they chose, and, once an admin raises the account's role or
  mints it a key, enroll an authenticator app, add passkeys, subscribe a push
  device or hold an API key. The invitee who then accepted with a password
  took over the account but left all of that in place: the stranger could
  still sign in with a passkey or a key, and the invitee was asked for a code
  only the stranger had. `User` `:accept_invitation_with_password` now also
  clears two-step verification (the secret, recovery codes and any pending
  enrollment), deletes passkeys, identity-provider links and push devices,
  and revokes every live API key, draft-write keys included, so they no
  longer authenticate or rotate. It all happens in the accept's transaction
  as `SystemActor.new(:invitations)`; if any removal fails, the whole accept
  rolls back and the invitee can retry. The security log records
  `second_factor_removed` and `passkey_removed` (new metadata key `via`,
  `invitation`) and `api_key_revoked`, each with no person, and the
  invitee's flash adds "Any two-step verification, passkeys or API keys set
  up on this address before were removed; set them up again." when one of
  those was removed. A confirmed account's one-click accept changes none of
  this. A passkey registration, push subscription, two-step confirmation,
  recovery-code regeneration or password change that the stranger's session
  had in flight takes the account's row first
  (`Changes.GuardAccountTakeover`): if it gets there before the takeover, it
  commits first, and the takeover removes or overwrites what it wrote; if
  after, it waits, finds the password changed (or the staged secret
  cleared), and is refused. The
  stranger's sessions are evicted once the takeover commits. The same guard
  makes `:confirm_totp` refuse a secret a second tab's `:setup_totp` replaced
  after the confirmation was built. The threat model records the same wipe on
  confirmation, password reset and magic-link sign-in of an unconfirmed
  account as a follow-up. No migration; rolling the pin back is safe.
  See [What taking over an account removes](../account-administration.md#what-taking-over-an-account-removes).

<a id="account-enumeration-audit"></a>

- **Every surface that takes an email address now answers a known and an unknown address alike, and the threat model has the per-surface matrix (#2255).**
  Sign-in (browser and headless), password reset, magic link, registration,
  confirmation, newsletter, site SSO, passkey, API key, the JSON:API, GraphQL and
  MCP reads, author routes and the admin lookups were each audited; only
  registration differed and was fixed (see Breaking). Each surface has a test
  under `test/**/enumeration_*` that compares the two responses whole. The
  residuals that remain (the owner's inbox, request-time timing on reset and
  magic link, admin-only lookups, a concurrent-registration race) are recorded
  in the matrix, with the reason each is accepted.

<a id="ecto-query-cache-advisory"></a>

- **ecto 3.14.3 fixes EEF-CVE-2026-118391 (unbounded query cache growth), and
  ash_sql 0.8.7 replaces the retired 0.8.4 (query cache returned wrong rows).**
  ecto 3.14.2's query cache grew without bound on queries with
  interpolated JSON paths or splice lists (high). ash_sql 0.8.4 was retired for security the
  same day: an Ecto query cache issue could make a query return
  unpredictable results. Both were published 2026-11-04, after 1.8.0, and
  fail `mix hex.audit` on every branch until taken. Lock-only: `mix
  deps.unlock ecto ash_sql`, nothing else moved.
  ([#2204](https://github.com/The-Verscienta/kiln_cms/pull/2204))

<a id="compound-leg-hoist"></a>

- **Global search's compound leg is about 3× cheaper per candidate name.**
  The leg matches a name written spaced or joined differently from the query
  (`huang qi` for Huangqi, `xiao yao san`). It rebuilt each rewrite's
  `to_tsvector` and each span's `phraseto_tsquery` for every candidate row ×
  variant, though neither depends on the row. Both are now scalar subselects
  Postgres runs once per statement, and a name's own tsvector and tsquery are
  built once per name in a `LATERAL ... OFFSET 0`. Same rows, same order;
  empty names are still skipped before any tsquery is built. On a synthetic
  2,047-row table with 16 variants, `EXPLAIN ANALYZE` went from about 30 ms to
  about 10 ms. Verscienta reported 1.6–4.0 s for the leg on multi-word queries
  after #2205; that figure has not been re-measured on their data.
  ([#2367](https://github.com/The-Verscienta/kiln_cms/pull/2367))
