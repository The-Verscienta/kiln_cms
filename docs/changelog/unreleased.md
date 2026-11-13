# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="slack-webhooks-upgrade"></a>

- **Run `mix ash.migrate`; before rolling back to 1.9, deactivate every Slack-format webhook endpoint.**
  One additive migration: `webhook_endpoints.format` (`text NOT NULL DEFAULT
  'kiln'`, so every existing endpoint stays Kiln-format) and
  `notifications.details` (a nullable map on the bell rows of security
  alerts). Neither is read by 1.9, so the columns can stay after a rollback.
  What a mixed or rolled-back cluster does with a Slack-format endpoint:
  - **During a rolling deploy**, a node still on 1.9 that runs a delivery to a
    Slack endpoint posts Kiln's JSON envelope; Slack answers 400 and the job
    is retried, normally by a node on the new release. A 1.9 console can also
    tick content events on a Slack endpoint, which the new release refuses;
    the new release never queues content events for it, and one queued by a
    1.9 node is posted as a neutral line naming the event.
  - **After rolling back to 1.9**, every Slack endpoint is sent the Kiln
    envelope, Slack refuses each delivery, and after 10 exhausted deliveries
    the endpoint is auto-disabled with a `webhook_auto_disabled` silencing
    notice to the site's admins. Untick **Active** on (or delete) each Slack
    endpoint first.
  - **Rolling forward again** after a newer release added a format this one
    doesn't know, such an endpoint's deliveries fail with "endpoint format
    not supported by this release" rather than being sent.
  Platform security alerts raised after the upgrade carry `content_type`
  `platform_security_alert`; 1.9 shows them in the default site's bell as
  before. (Part of #2245.)

<a id="backup-schedules-upgrade"></a>

- **Run `mix ash.migrate` (new table `backup_schedules`). Nothing is scheduled until a platform admin creates a schedule; rolling the pin back is safe, and an older release ignores the table.**
  The `add_backup_schedules` migration is expand-only: it creates one table
  and touches nothing else. A new scheduler job (`KilnCMS.Backups.Scheduler`,
  `KILN_BACKUP_SCHEDULER_CRON`, every minute by default on the `scheduling`
  queue) starts with the release; with no schedules it reads an empty table
  and does nothing. About 10 000 completed job rows a week, pruned after 7
  days; `*/5 * * * *` is fine, and `false` turns every schedule off.
  - **During a rolling deploy**, a node still on the previous release that
    picks up a scheduler job discards it as an unknown worker. A window stays
    due, so a newer node's next tick fires it.
  - **After rolling back**, the older release has no scheduler: no schedule
    fires, and backups come only from host cron and **Back up now**. The table
    and its rows stay and fire again when you roll forward. Rolling the
    migration itself back (`mix ecto.rollback`) drops the schedules.
  - **Once you create a schedule**, the alarm threshold of each component it
    covers follows the schedule (a weekly one raises it from 36 h to 252 h),
    and host cron *and* a schedule on the same component take two backups
    per window. See the Added entry below. (Part of #2219.)

<a id="backup-run-dir-id-upgrade"></a>

- **Run `mix ash.migrate` (new nullable `backup_runs.dir_id`); a backup resumed during a rolling deploy may run unpinned.**
  One additive migration: `backup_runs.dir_id` (`uuid`, nullable, no index),
  the id of the backup directory a run's files are in, which decides where a
  resume runs (next entries). The release's boot migration applies it as
  usual. What a mixed or rolled-back cluster does:
  - **During a rolling deploy**, an older node can still pick up a resume's
    start step. It runs it wherever it lands and records no `dir_id`, and
    on a cluster with a `BACKUP_DIR` per host it can fail there as it did
    in 1.9 (click **Resume** again once every node is upgraded).
  - **Runs from before the upgrade** have no `dir_id`, so their first resume
    runs on whichever node has their files or picks them up, and records the
    id then.
  - **Rolling back** is safe: older releases don't read the column, and it
    can stay. Their resumes are unpinned again.
  (Part of #2539.)

<a id="blocked-ip-alerts-upgrade"></a>

- **Run `mix ash.migrate` (new table `platform_security_alerts`). Sites with block rules now alert their admins when a blocked address is refused, on by default; existing webhook endpoints don't receive `security.blocked_ip` until it is ticked.**
  One additive migration: `platform_security_alerts`, one row holding the
  platform alert kinds a platform admin turned off. It stays empty until
  someone saves, and an older release ignores it, so it can stay after a
  rollback. What changes from the deploy on:
  - **Blocked-address alerts are on for every site.** A blocked client that
    keeps trying raises one alert every 15 minutes, by bell and email, to
    each of the site's admins (96 a day); when several networks are refused
    in a window a summary follows each alert, up to 192 a day. Rules the
    scanner guard adds for a while alert like any other. To stop them,
    untick **Security alerts** → **Blocked addresses** on the site.
  - **Webhooks need ticking.** Existing endpoints, Slack-format ones
    included, don't receive `security.blocked_ip` until an admin ticks it
    in the endpoint's `security` group. On a site whose alerts go only by
    webhook (admin notifications off, or no admins at all), the existing
    posture line **Security alerts reach someone**
    (`core.security_alerts_reach_someone`) turns **Review** ("Some security
    alerts on this site reach nobody…") until the event is ticked or the
    kind is turned off.
  - **Platform admins get a new alert,** `api_key_rate_limited`, when a
    verified API key goes over a rate limit. A platform admin can turn it
    off on the Security alerts page.

  During a rolling deploy, a `blocked_ip` or `api_key_rate_limited` alert
  picked up by a node still on 1.9.x is logged as "names an unknown kind;
  not sent" and stamped, so it is lost; and a key going over a limit on a
  1.9.x node raises nothing, because those nodes don't remember verified
  keys. After rolling back to 1.9.x, the new security log rows read as
  "Unrecognized event (ip_block_refused)" and "Unrecognized event
  (api_key_rate_limited)", and a site that turned **Blocked addresses** off
  keeps that and can still save its settings. **On 1.9.x, saving an
  endpoint subscribed to `security.blocked_ip` drops the event**: the 1.9
  form only lists the events it knows, and the save counts as unticking a
  security event, so the site's admins get a `webhook_changed` silencing
  notice. Tick it again after rolling forward. (Part of #2245.)

<a id="crawler-verification-silent-ptr-upgrade"></a>

- **With the smart 404 guard on, a search-engine claim whose reverse DNS gets no answer now counts toward the miss threshold, unless the node's resolver is itself failing.**
  Only matters with `KILN_SCANNER_BLOCKING` on (it is off by default). Until
  now, a claim to be Googlebot, bingbot, Applebot, YandexBot or Baiduspider
  whose PTR query timed out or failed (SERVFAIL, refused) kept the guard's
  miss-threshold exemption, so a scanner on addresses whose reverse zone it
  leaves silent was never counted (#2588). Now the silence is read as the
  address's own zone, and its misses count, while the node's resolver is
  otherwise answering. The exemption is kept, as before, when the resolver
  itself is failing: no lookup got an answer in the last minute and a
  *canary* PTR query also went unanswered. The guard starts the canary only
  while that is the case. It is one PTR query for a fixed address, `8.8.8.8`
  (`dns.google`), never a visitor's, at most once a minute per node, and it
  goes to the same resolvers as every other verification query. Nothing to
  configure; no migration and no new environment variable.
  - **Watch for real crawlers being blocked.** A crawler whose reverse zone
    is slow or flaky (Baidu's and Yandex's are the likeliest) can now pass
    the miss threshold and have its address blocked for
    `KILN_SCANNER_BLOCKING_BLOCK_MINUTES`. Remove such a block on
    `/editor/ip-blocks`. Bait paths counted for everyone already.
  - **A forward query is different.** When the PTR names a host under the
    engine's own domain and *that* host's A/AAAA query gets no answer, the
    claim keeps the exemption: the silence is in the engine's zone, which
    the address's owner does not control. It is reported with the new
    `unverified_crawler` reason `forward_error`
    ([below](#crawler-verification-hardening)).
  - **Firewalls.** The canary is an ordinary PTR query to the nameservers in
    `/etc/resolv.conf`. A node that can verify crawlers can send it; one that
    cannot gets no canary answer either, so the exemption stays as before.
  - **Rolling back** is safe: nothing is stored outside each node's memory,
    and the previous release exempts every unanswered claim again.

<a id="backup-keep-days-upgrade"></a>

- **If your host's cron sets `BACKUP_KEEP_DAYS`, check its value: `backup.sh` now refuses anything but a whole number of days from 1 to 2147483647, keeps 14 instead, and warns.**
  Until now the script used the value unchecked in `find -mtime +N`, so
  its effect depended on what you wrote (see the Fixed entry
  [below](#backup-keep-days-validated)). Two settings change what the
  next `backup.sh all` or `backup.sh prune` deletes:
  - **`BACKUP_KEEP_DAYS=0`** pruned every backup older than one day. It now
    keeps 14 days, so the backup directory grows to about 14 days of
    backups. Check the disk has room, or set the number of days you want.
  - **`BACKUP_KEEP_DAYS=14d`** (or another value with a unit) pruned
    nothing at all on Linux, where GNU `find` refuses `+14d`. It now means
    14, so the first prune after the upgrade deletes every backup older
    than 14 days that the [keep rules](../backups.md#what-retention-deletes-and-what-it-keeps)
    don't protect. Copy off anything older you want to keep before the
    upgrade, or mark it as a [recovery point](../backups.md#keep-a-backup-as-a-recovery-point).
  Each refused value writes
  `BACKUP_KEEP_DAYS=<value> is not a whole number of days from 1 to 2147483647; using 14`
  to stderr, which lands in the cron log. Rolling the pin back restores the
  old reading, but backups the new prune has already deleted are gone. The
  in-app backup already read the variable this way and is unchanged. (#2727)

<a id="cron-killed-run-recovery-upgrade"></a>

- **Replace `scripts/backup.sh` on every host with this release's copy. A cron run killed outright is now recorded as a failed "Interrupted" run after 3 hours, and `backup.sh prune` now deletes its `.partial` files after 12 hours.**
  What changes on a deployed instance (the Fixed entry
  [below](#cron-killed-run-recovery) has the whole mechanism):
  - **Old leftovers show up once.** A `kiln-media-<stamp>.sha256.partial`
    left by a run killed before the upgrade (the 1.9 known issue: a stamp
    "pending" in History forever) is imported at the first import after the
    deploy as a **Failed** run, "Interrupted: the backup stopped before it
    finished and left .partial files behind". Its stamp is older than the
    backups taken since, so the status panel's last attempt is unchanged.
    You no longer need to delete the marker by hand.
  - **`backup.sh prune` now deletes `.partial` files**, which the guide
    used to say it never does: those of a stamp whose every file, in `db/`
    and `media/`, is 12 hours old, unless `.work/<stamp>/` exists. A
    recovery point (`.keep`) does not protect them. With the nightly cron
    line that is the run after the kill; with an hourly cron, about the
    twelfth. Deploy the app before replacing the script, so it reads old
    leftovers first; if prune gets there first, the stamp still imports,
    as what is left of it (parts with no sidecar import as failed).
  - **An older `backup.sh` can be mislabeled.** This release's script
    touches its `.partial` files every 5 minutes while it runs; an older
    copy does not. Against this release's app, a live run on an older
    script with a phase in which nothing is written for 3 hours (planning a
    very large media tree on NFS, or `pg_dump` waiting for a lock) can be
    recorded as Interrupted, and that row is never rewritten.
  - **Rolling back** the app is safe: there is no migration. The
    Interrupted rows stay as failed runs, and an older release's in-app
    backup again removes any `.partial` older than an hour. Keep the new
    `backup.sh` or put the old one back; both read the same files.
  (#2478)

<a id="crawler-ip-ranges-upgrade"></a>

- **Kiln now fetches Google's, Bing's, Apple's and DuckDuckGo's published crawler IP lists over HTTPS every 6 hours, on by default: allow the four hosts, or set `KILN_CRAWLER_RANGES=false`. DuckDuckBot claims from outside DuckDuckGo's list are now charged as no user agent.**
  This is the first outbound call a default install makes **on a schedule**;
  every other default call answers something a person did (#2586, see
  [Added](#crawler-ip-ranges)).
  - **Egress.** One node fetches
    `https://developers.google.com/static/crawling/ipranges/common-crawlers.json`,
    `https://www.bing.com/toolbox/bingbot.json`,
    `https://search.developer.apple.com/applebot.json` and
    `https://duckduckgo.com/duckduckbot.json` every 6 hours (Oban cron
    `17 */6 * * *`, `KILN_CRAWLER_RANGES_CRON`), and shares them with the
    other nodes over PubSub. A node with no fresh list also queues a fetch
    about 20 seconds after it starts, and again at its 10-minute checks while
    a list is stale; at most one fetch job runs per 10 minutes across the
    cluster. Any node may be the one that fetches, so a firewall that lists
    allowed hosts must allow all four on every node, port 443. The requests
    carry a bare `KilnCMS` user agent and nothing about the instance or its
    visitors. Add the four vendors to your DPA's list if you keep one
    ([data-flows.md](../data-flows.md#optional-subprocessors)).
  - **If you do nothing on a closed network**, nothing breaks: each list
    stays missing, claims are checked by DNS as before, DuckDuckBot stays
    unverified as before, and each node logs "Crawler verification:
    <engine>'s published crawler IP ranges are missing or stale ..." once
    per engine. Set `KILN_CRAWLER_RANGES=false` to stop the attempts and the
    warnings.
  - **DuckDuckBot changes.** An address in DuckDuckGo's list now gets the
    verified search-engine ceiling (600 a minute with the defaults, was 300).
    An IPv4 address outside it is proven false: charged as no user agent (60
    a minute) and, with the smart 404 guard on (`KILN_SCANNER_BLOCKING`, off
    by default), counted toward the miss threshold. **A real DuckDuckBot on an
    address DuckDuckGo has just added can be throttled, and blocked by the
    guard, until the next successful fetch**: normally within 6 hours, at most
    24 if fetches keep failing, after which the list is stale and DuckDuckBot
    claims are unproven again. Remove such a block on `/editor/ip-blocks`.
    DuckDuckGo publishes IPv4 only, so DuckDuckBot over IPv6 is unchanged.
  - **Google, Bing and Apple** gain: an address in their list is verified
    with no DNS query. One outside it goes to DNS exactly as before.
  - **Staging and dev.** Dev has the lists off (`KILN_CRAWLER_RANGES=true`
    turns them on); a staging env built for production fetches them unless
    you set `KILN_CRAWLER_RANGES=false`
    ([staging-environments.md](../staging-environments.md)).
  - **Rolling back** is safe: nothing is stored outside each node's memory
    and there is no migration. In a cluster upgraded node by node, older
    nodes ignore the lists the new ones send.

<a id="second-factor-policy-upgrade"></a>

- **Run `mix ash.migrate` (new table `site_second_factor_policy`, and a `users.inserted_at` column). Nothing is enforced until a site requires it.**
  The `require_second_factor` migration is expand-only. It creates
  `site_second_factor_policy`, one row per site that saves a two-step sign-in
  requirement (none does until an administrator saves one at
  `/editor/two-factor`; see the [next note](#second-factor-enforcement-upgrade)), and adds
  `users.inserted_at` (`NOT NULL`, default `now()`), so every existing
  account gets the time the migration ran. An account's grace period never
  starts before its `inserted_at`, so when a site later turns the requirement
  on, no account from before this upgrade starts out overdue. Run the release
  migration as usual. **Rolling back** is safe for the schema: an older release
  ignores the table and the column, and reads the two new security log types as
  unrecognized events ("Unrecognized event (…)"). It also drops any
  requirement a site has turned on, without a warning (next note). (Part of
  #2247.)

<a id="second-factor-enforcement-upgrade"></a>

- **Sites can now require two-step sign-in. Nothing changes for any site until an administrator saves a requirement; from then on, the JWTs and headless sign-ins of the people it holds are refused with `403`. Rolling back drops the requirement silently.**
  What an operator should know before a site turns it on (guide:
  [Requiring two-step sign-in on a site](../two-factor-auth.md#requiring-two-step-sign-in-on-a-site)):
  - **On upgrade, nothing is enforced.** No site has a requirement until an
    administrator saves one at `/editor/two-factor`, and accounts that
    existed before the upgrade start their grace period no earlier than the
    migration.
  - **Headless clients that sign in as a person.** Once a site holds a
    person (past the grace period, no second factor),
    `POST /api/auth/sign_in` answers them `403` `second_factor_required` and
    issues no token, and a JWT they already hold is refused with the same
    `403` on every `/api/*`, `/gql` and `/api/feed` request, public reads
    included, and at the `/ws/gql` and `/ws/collab` connect. During the grace
    period the sign-in's `201` carries `second_factor.deadline`. Move scripts
    and apps that sign in with a person's password to an API key: **API keys
    are never held.** Count the refusals with the
    `[:kiln_cms, :api, :second_factor_required]` telemetry event.
  - **Passkey-only accounts** past their deadline can no longer sign in with
    the password alone: on a site's own host (not the main or console host)
    they are refused and told to sign in on the main host or add an
    authenticator app.
  - **The main host must answer every member.** The setup page,
    `/account/two-factor`, is served only on the main host (the endpoint URL
    from `PHX_HOST`) and console hosts. A person a site holds on its own
    address is redirected to the main host's page and signs in again there,
    readers of a site that requires everyone included, and the headless
    `meta.setup_url` names the same URL.
  - **Mail.** The email code a password-only session confirms before adding a
    factor goes through the relay of the site the setup page is opened for
    (on the main host, the default site's). With no outgoing mail server at all
    (`:mailer_not_configured`), or a site relay whose password can no longer
    be decrypted, the step is skipped and recorded as
    `proof: "email_skipped_no_relay"`.
  - **Rolling back** to a release without this drops every site's
    requirement silently: nobody is held and refused tokens work again. The
    table stays; upgrading again restores it as it was.
  - **Locked out:** if no administrator of a site can pass its requirement,
    `bin/kiln_cms rpc 'KilnCMS.Release.second_factor_requirement_off(org: "<slug>")'`
    turns it off.

<a id="event-recurrence-rfc-upgrade"></a>

- **Some recurrence rules now expand per RFC 5545, as subscribed calendars already showed them; Kiln recomputes every event's next date about ten minutes after the first boot. A deployment that builds Oban's `queues:` itself must add `occurrence_backfill: 1`.**
  Kiln's own expansion (the "what's on" listing at `/<plural>`, its JSON,
  `next_occurrence_at`, the sort) read some rules differently from the
  calendar clients that receive the same rule text in `.ics` feeds (#2750).
  It now reads them as the clients do. The rule text a subscriber receives
  is unchanged (apart from a timed `UNTIL`, see
  [Fixed](#ics-until-end-of-local-day)), so only Kiln's own dates move. Rules affected:
  - **Yearly rules with `BYMONTH`, `BYMONTHDAY` or `BYDAY`.** They used to
    look only at the start date's month. Now:
    - `FREQ=YEARLY;BYMONTH=3,9` from March is March **and** September (was
      March only); `BYMONTH=6` from January is June (was nothing at all).
    - `FREQ=YEARLY;BYDAY=2TU` without `BYMONTH` is the second Tuesday of
      **January**, counted within the year (was the start month's). Add
      `BYMONTH=` to keep a month: `FREQ=YEARLY;BYMONTH=5;BYDAY=2TU`.
    - `FREQ=YEARLY;BYMONTHDAY=15` without `BYMONTH` is the 15th of **every
      month**; `FREQ=YEARLY;BYDAY=TU` is every Tuesday of the year. Add
      `BYMONTH=` for once a year.
  - **Monthly rules with both `BYDAY` and `BYMONTHDAY`** are now the dates
    that match both: `FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13` is Friday the
    13th, where it was every Friday plus every 13th.
  - **Daily and weekly rules with `BYMONTH`** now honor it:
    `FREQ=DAILY;BYMONTH=6` is June only, where it was every day.
  - **Weekly rules naming a weekday twice** (`BYDAY=MO,MO`) count it once,
    so `COUNT=4` is four Mondays, not four occurrences on two.

  Unchanged, and worth knowing: an event whose start date doesn't match its
  rule (`FREQ=MONTHLY;BYMONTHDAY=15` starting on the 2nd) is not listed on
  its start date by Kiln, while some clients, Google Calendar among them,
  show it. [Events](../events.md) has the full rules and the known
  divergences.

  **Nothing to do on a standard deployment.** Each node's boot queues a
  recompute (`KilnCMS.Events.BackfillWorker`) on a new Oban queue,
  `occurrence_backfill` (concurrency 1), to run ten minutes later, once the
  previous release's nodes have left. The job is keyed to the recurrence
  engine's version (`KilnCMS.Events.Recurrence.engine_version/0`, now 2), so
  it runs once for this release even if a backfill already ran today. What
  to check:
  - **A deployment that builds Oban's `queues:` list itself** must add
    `occurrence_backfill: 1`, or the recompute is queued and never runs.
    If you size `POOL_SIZE` as the sum of queue limits plus web traffic,
    add one. A plugin that declares a queue of that name turns
    `mix kiln.plugins.doctor` red.
  - **With `KILN_OCCURRENCE_BACKFILL_ON_BOOT=false`**, nothing is queued:
    once every node runs the new release, run
    `bin/kiln_cms rpc 'KilnCMS.Events.Backfill.run()'` (`rpc`, not `eval`,
    which starts no application) or `mix kiln.occurrences.backfill`.
  - **Events whose next date changes are written once**, and get a new
    `updated_at`, as any save does: expect a sitemap `lastmod` change, JSON:API
    clients that poll on `updated_at` to fetch them again, and their cached
    pages to be refreshed.
  - **The pass logs one line** when it writes anything: "occurrence backfill
    recomputed N record(s) of M scanned (recurrence engine 2)", how many
    moved to a different date and how many now have no upcoming date, with
    up to 50 ids of each. The second group has left the what's-on listings;
    the line is a warning when there are any.
  - **An event saved on a node of the previous release after the pass ran**
    keeps that release's date until a boot more than a day later, or a manual
    run.

  Rolling back is safe: there is no migration, and an older release
  recomputes an event's date the old way whenever it next saves or sweeps
  it.

## Breaking

<a id="ws-gql-refuses-unverified-bearer"></a>

- **`/ws/gql` refuses a connect whose token does not verify, where it used to connect as anonymous (#2634).**
  The GraphQL websocket reads a user JWT from its `token` connect param (or
  `Authorization: "Bearer …"`). A token that failed verification (expired,
  revoked, malformed, from another instance) connected as anonymous and read
  published content, so a client with a broken credential could not tell; so
  did a `kiln_` API key, which this socket has never accepted. `/api/*` and
  `/gql` have answered such a token `401` since #2161. The socket now refuses
  the connect, and the websocket handshake answers `403` with an empty body.
  **Who breaks:** a client that keeps a stored token and opens the socket with
  it after it expires, or that passes an API key to `/ws/gql`. **What to do:**
  connect with no `token` to read as the public, sign in again for a fresh
  JWT, or use `POST /gql` with the API key. A connect with no token is
  unchanged. Each refused connect emits `[:kiln_cms, :api, :invalid_bearer]`
  (`surface: :graphql`, `read?: true`), and `KILN_API_REJECT_INVALID_BEARER=false`
  restores the anonymous connect, as it does over HTTP, for as long as that
  escape hatch lasts. `/mcp`, the other surface #2634 audited, accepts API keys
  only and already answered any JWT or garbage bearer `401`; it is unchanged.
  Why this is a minor:
  [ADR 0017, amendment of 2026-11-13](../decisions/0017-an-unverifiable-bearer-flips-on-a-minor-with-a-breaking-note-and-is-counted-first.md#amendment-2026-11-13-the-graphql-socket-refuses-too-and-mcp-is-key-only).
  Closes #2634.

<a id="media-purge-quarantined"></a>

- **Overlay and plugin code: `purge_media_item` takes only a trashed item, the media system actor purges through the new `purge_quarantined_media_item`, and `restore_media_item` refuses an item no longer in the trash (#2610, #2611).**
  1.9 let `KilnCMS.CMS.MediaItem`'s `:purge` hard-delete a trashed item *or*
  a quarantined one, the second for the media pipeline's purge of an upload
  it refused or that never finished processing. That branch applied to the
  admin trash too, so an item trashed while still quarantined and restored
  since could be hard-deleted from a stale trash list (see
  [Fixed](#media-trash-stale-actions)). Now:
  - **`CMS.purge_media_item` (`:purge`)** takes only a trashed item. An
    untrashed one, quarantined or not, returns `Ash.Error.Invalid` holding
    `Ash.Error.Changes.StaleRecord` and changes nothing. Trash it first with
    `destroy_media_item`.
  - **`KilnCMS.Media.system/0` can no longer run `:purge`** (`Ash.Error.Forbidden`).
    The pipeline's purge is the new `CMS.purge_quarantined_media_item`
    (`:purge_quarantined`), which `AVStripWorker` and `QuarantineReaper` now
    call. It deletes only a row that is still quarantined, and only the media
    system actor may run it: an editor, an admin of the site and a platform
    admin are all refused (`Forbidden`), and so is the system actor on an
    item whose quarantine has been released. Overlay code that purged a
    quarantined upload as `Media.system()` through `purge_media_item` must
    switch to `purge_quarantined_media_item`.
  - **`CMS.restore_media_item` (`:restore`)** takes only a trashed item. On
    an item someone already restored or permanently deleted it returns the
    same `StaleRecord` error, where before it succeeded (or, for a deleted
    item, failed with whatever error the missing row produced).

  The API never exposed either action, so no JSON:API, GraphQL or MCP
  response changes. The AshAdmin delete actions for media are unchanged
  (`:purge_quarantined` is not offered there). No migration and no config;
  rolling back is safe (nothing is stored differently). Guide:
  [Trash and restore](../trash.md#for-developers).

<a id="custom-field-api-stricter-shapes"></a>

- **Custom-field API: a few requests that used to succeed by accident are now a `400`, and `not_eq` on a tidied field can exclude more records (#2739, #2743, #2677).**
  The fixes below ([value shapes](#custom-field-value-shapes),
  [operand shapes](#custom-filter-operand-shapes),
  [tidied operands](#custom-filter-operands-tidied)) mostly turn a 500 into
  a 400, but these requests answered `200` before and are refused now. Each
  one was read in a way the client is unlikely to have meant:

  | Request | Before | Now |
  |---|---|---|
  | `[]` sent for a single (not `multiple`) `string`, `url`, `select`, `integer`, `float`, `date` or `datetime` field | the field was cleared (or took its default) | `400` `invalid_attribute`: `<Label> (<name>) must be a single value, not an object or a list`. Send `null` or `""` to clear |
  | `[]` sent for a single `text` field | `""` was stored | the same `400` |
  | a non-empty list on a single `text` field | its items joined into one string | the same `400` |
  | a list operand beside `ilike` (`custom_filter[x][ilike][]=a%`) | joined into one pattern | `400` `invalid_argument`: `ilike on custom field "x" takes one value, not a list` |
  | a list operand beside `eq` / `not_eq` on a media or reference field (`custom_filter[cover][eq][]=<id>`) | joined into one id | the same `400`; use `[in][]=<id>` |
  | a `null` `ilike` operand (JSON, from GraphQL `customFilter` or MCP) | read as an empty pattern | `400`: `invalid value for custom field "x"` |
  | an Ecto-style date object (`custom_filter[dates][eq][year]=2026&…[month]=3&…[day]=1`) on a date or date-time list, as an item of `in` on a date or date-time field, or as the operand of a date or date-time link field | read as that date | `400`: `eq on custom field "dates" takes a value, not a nested filter`. Send `2026-03-01` |

  `not_eq` on a single string, URL, select, email, color, telephone, time or
  slug field (or a string, URL or select link field) now leaves out the
  operand's stored spelling as well as the spelling sent, so
  `custom_filter[accent][not_eq]=#FFF` drops a record holding `#ffffff`,
  which it used to return. `eq` and `in` only find more.

  What to do: send one value where a field takes one, `null` or `""` to
  clear, an ISO-8601 string for a date, and `in` for a list. No migration,
  no config; rolling back restores the old readings. Docs:
  [json-api.md](../json-api.md) → "Custom fields" and "A single custom field
  takes one value".

## Added

<a id="backup-schedules"></a>

- **In-app backup schedules: a platform admin can schedule database and media backups daily, weekly, fortnightly or monthly at a local time in a time zone, from a release console; the Backups page lists them.**
  The alternative to the host's cron job (part of #2219). Created, changed
  and deleted from a release console in this release, as a platform admin:

  ```bash
  bin/kiln_cms rpc '
  admin = KilnCMS.Accounts.get_user_by_email!("you@example.com", authorize?: false)
  {:ok, s} = KilnCMS.Backups.create_backup_schedule(%{components: [:db], interval: :daily,
    time_of_day: ~T[03:00:00], starts_on: Date.utc_today(), time_zone: "Europe/Paris"}, actor: admin)
  IO.inspect(s.id)'
  ```

  `update_backup_schedule/3` edits, pauses (`enabled: false`) and resumes
  one, `destroy_backup_schedule/2` deletes it, and each is recorded in the
  instance security log (`backup_schedule_created`, `_changed`, `_deleted`).
  The **Backups** page gains a read-only **Schedules** section: each
  schedule's cadence and components, "Paused", "Next run" (only when it can
  fire here), the last window's outcome, and each component's alarm threshold
  and where it came from, with a warning when `KILN_BACKUP_SCHEDULER_CRON` is
  off or this node can't run backups. Scheduled runs read **Scheduled** in
  History, and the Overview's backup strips mention the in-app schedules once
  one is enabled.

  How it behaves:
  - A window fires once across every node: it is claimed in the transaction
    that starts, queues or folds the backup. Schedules due together make one
    backup. Only the latest window fires after downtime (missed ones are
    logged), and a failed backup is not retried within its window.
  - Editing a schedule's timing or components, or resuming it, rebaselines
    it, so no window from before the edit fires. Pausing doesn't.
  - A scheduled backup never folds into a queued Resume (#2540): the window
    stays due and is retried every minute. A node with no `pg_dump`,
    `pg_restore` or database URL defers the window the same way, so another
    node can take it; each wait is logged once per window.
    `BACKUP_ENABLED=false` refuses the window (claimed, not retried). A
    database and media schedule ticked on a node with no media directory backs
    up the database only, with a warning; a media-only one is refused.
  - **Sub-daily intervals are refused** until keep-N retention ships (a later
    part of #2219). Retention is unchanged and age-only, and every run is a
    full set, so the sets on disk per component are about runs per day ×
    `BACKUP_KEEP_DAYS`: a two-hourly schedule would keep 168 with the default
    14 days.
  - A schedule sets the alarm threshold of the components it covers
    (interval plus half, at least 6 h: daily 36 h, weekly 252 h) only while it
    can actually run here and has fired at least once since its baseline;
    otherwise `BACKUP_STALE_AFTER_HOURS` applies. If host cron also backed the
    component up in the last eight days, the lower of the two wins.
  - Restoring a database dump brings back the schedules as they were,
    deleted ones included, and each enabled one fires its latest window
    within a minute. The staging scrub pauses every schedule
    (`backup_schedules_disabled`).
  - Telemetry: `[:kiln_cms, :backups, :schedule, :fired | :deferred |
    :refused | :narrowed | :missed | :invalid | :unreadable]` and
    `[:kiln_cms, :backups, :status, :schedules_unreadable]`.

  See [Schedule backups in the app](../backups.md#schedule-backups-in-the-app).

<a id="slack-webhook-format"></a>

- **A webhook endpoint can be Slack-format: it posts the site's security alerts and silencing notices into a chat channel as a readable message.**
  Choose **Format** → **Slack (incoming webhook)** under **Add a webhook**
  on `/editor/webhooks`; the event list narrows to the `security` group with
  every event ticked. The body is an incoming-webhook message (`text`,
  `blocks`, unfurling off), so Mattermost, Rocket.Chat and Discord's `/slack`
  URL take it too. It says the alert's English headline, the site, when, and
  links to the security log, with the site name, address and event name in
  code spans and Slack's control characters escaped, so a site name cannot
  `@channel` or add a link. A ping says "KilnCMS webhook test for (site)" and
  carries no URL; a Kiln-format ping is unchanged and still carries
  `endpoint_url`. The format is set when the endpoint is added and can't be
  changed (`format` is accepted by `:create` only). A Slack endpoint takes
  `security.*` events only (refused otherwise with "Slack endpoints can only
  receive security events") and never receives content events or
  retractions. Deliveries are still signed over the body sent, but Slack
  checks no signature, so the URL is the credential: the row shows no signing
  secret and no **Rotate secret**, and URLs are now masked (next entry).
  `WebhookEndpoint` gains a public `format` attribute (`:kiln` | `:slack`),
  and `url` and `WebhookDelivery.endpoint_url` are now `sensitive?`. See
  [Send alerts to Slack](../security-alerts.md#send-alerts-to-slack). (Part
  of #2245.)

<a id="image-picker-upload"></a>

- **The editor's image picker has its own Upload button and drop zone.**
  The picker could only choose an image already in the media library, or
  import one from Unsplash. To use a new photo as a featured image, an editor
  had to leave the document for **Media**, upload it, come back, open the
  picker again and find it. The Library tab now starts with an upload area:
  click it to choose a file, or drop one on it. The finished upload is used
  the same way a library pick is. For the featured image, the social image,
  an image block or a media field, it is set and the picker closes. For a
  gallery, the input takes several files, each joins the selection in upload
  order, and the picker stays open until **Add to gallery**. Every upload is
  also added to the media library. Uploads use the same pipeline as the
  media library's own (`Ingest`: size cap, metadata strip, derivatives), with
  the same image types and size limit as pasting into a text block. The file
  is checked as an image on the server before anything is stored, so a PDF
  renamed `.png` is refused rather than becoming a featured image. Closing
  the picker cancels an upload that hasn't finished. Only editors who can
  edit the document see the upload area. The Branding page's image drawer is
  unchanged. (#2791)

<a id="posture-security-alerts-reach-someone"></a>

- **Security posture has a new site line, "Security alerts reach someone" (`core.security_alerts_reach_someone`).**
  A site could have security alerts that went nowhere: every kind unticked,
  admin notifications off with no webhook, or webhooks covering only some
  kinds, and nothing said so. The line reads what delivery reads (the site's
  alert settings, its recipients, who muted the email, and the active
  endpoints subscribed to an alert kind it has on) and is **Review** when
  alerts are off for the deployment (`config :kiln_cms,
  KilnCMS.Security.Alerts, enabled: false`), when every kind is off, when no
  bell, email or webhook would carry an alert, or when no admin gets them
  and some kind on has no endpoint. It is **OK**, saying how, for
  webhook-only delivery that covers every kind, for a site with no admins
  of its own (alerts go to the platform admins), and for admins who all
  muted the email (the bell still rings); **Unknown** when the settings or
  endpoints can't be read. Its `facts` in `/api/security/posture` are counts
  and flags only (`deployment_enabled`, `enabled_kinds`, `notify_admins`,
  `member_admins`, `fallback`, `bell_recipients`, `email_recipients`,
  `subscribed_endpoints`, `uncovered_kinds`), never who the recipients are.
  New `KilnCMS.Security.Alerts.read_settings/1` returns `:error` instead of
  the fallback settings when the row can't be read. See
  [Security alerts](../security-posture.md#security-alerts) in the posture
  guide. (#2640)

<a id="blocked-ip-alerts"></a>

- **Security alerts have a new site kind, `blocked_ip`: a request refused by the site's block list alerts the site's admins, naming the rule that matched and never the address.**
  Until now a blocked address left no trace but a counter, so an admin
  learned of a client still knocking only by looking at metrics. Every
  refusal (HTTP, the LiveView socket, `/ws/gql`, `/ws/collab`,
  `/ws/bridge`) is noted; in-memory gates on each server let through the
  first refusal of each client network (an IPv4 address, an IPv6 `/64`)
  per site per 15-minute window, at most 20 networks per site per window,
  so a flood costs no database write per request. What passes is written
  to the security log as `ip_block_refused` (metadata `rule`, `surface`),
  with **no IP address and no user agent**, so "nothing logs the address"
  (ADR 0026) still holds, and raises the alert: "A blocked address was
  refused (rule 203.0.113.0/24)", then a summary counting the client
  networks. A rule narrower than a `/24` or `/48` is shown as that network
  unless the site shows full addresses. The event is written even when the
  kind is off; only the alert is dropped. It is on by default (see the
  upgrade note), labeled **Blocked addresses** on `/editor/security-alerts`,
  and sent to webhooks as `security.blocked_ip`, whose `event.ip` is
  `null`. New: `KilnCMS.Security.BlockedIpAlert`,
  `KilnCMS.Security.IpBlocklist.match/2` (the rule that matched;
  `blocked?/2` stays side-effect-free) and
  `KilnCMS.Security.Cidr.truncate_range/1`. See
  [Blocked addresses raise one alert per window](../security-alerts.md#blocked-addresses-raise-one-alert-per-window).
  (Part of #2245.)

<a id="api-key-rate-limited-alerts"></a>

- **Platform admins are alerted when a verified API key goes over a rate limit (`api_key_rate_limited`), and can turn that one platform alert off.**
  A key hitting its limits can be a stolen key in heavy use, or a client
  gone wrong. The alert covers the limits an API key reaches: `api`
  (JSON:API, `/api/*`, `/api/feed`, `/mcp`, the ActivityPub inbox), `gql`
  (`/gql`, its batch limit included), `media_upload`, `media_transform` and
  `plugin_endpoint`. A limit refuses before the key is checked, so each
  server remembers, in memory, the SHA-256 of every key that authenticated
  on it in the last 5 minutes; only a refusal carrying one of those keys
  counts, which costs no database read and lets no forged key use up the
  real key's alert. It is recorded as `api_key_rate_limited` (no person;
  target the key; metadata `name`, `bucket`), once per key and limit per
  15 minutes, in the key owner's site when the owner has exactly one
  active membership, otherwise the default site. It goes to every platform
  admin by bell and email (no mute, no webhook), with its own alert window,
  so it never delays a stolen-key `api_key_abuse` alert. Known gaps: `/ws/gql`
  can't carry an API key; image transforms and plugin routes never check a
  key, so they alert only for a key used on an authenticated API on the
  same server within 5 minutes; and limits are per address, so a
  legitimate key behind a NAT someone else floods alerts too. It is the one
  platform kind that can be turned off: platform admins see a new
  **Platform alerts** part on `/editor/security-alerts` with **API keys over
  a rate limit**, stored in the new `KilnCMS.Security.PlatformAlertSettings`
  (`Security.list_platform_alert_settings/1`,
  `Security.save_platform_alert_settings/2`, platform admins only), and each
  save is recorded in the instance security log as `platform_alerts_changed`.
  New telemetry: `kiln_cms.security.api_key_trip.count`, tagged `result`
  (`unverified`, `debounced`, `noted`) and `bucket`. See
  [API keys over a rate limit](../security-alerts.md#api-keys-over-a-rate-limit).
  (The last part of #2245.)

<a id="second-factor-requirement"></a>

- **A site can require two-step sign-in of its administrators, its editors and administrators, or everyone, with a grace period; past it, an account with no second factor is held until it sets one up. Closes the #2247 series.**
  The last of three parts of #2247 (the passkey at the code prompt and the
  "factor added" email were the first; the setting itself the second).
  - **The setting, `/editor/two-factor`.** A site administrator chooses
    **Require two-step sign-in for** (Off, Administrators, Editors and
    administrators, Everyone) and a **Grace period** (none, 7, 14, 30 or 90
    days). Before saving, the page previews how many people would be asked to
    set it up and how many at once; after, it shows per role how many people
    are covered, have a factor, are still in grace (with the first deadline)
    and are held, and who changed it last, from what. Counts only, no names.
    Every save needs the administrator's own second factor, verified at
    sign-in in the last 15 minutes or a code typed on the page. The page has
    no console menu entry yet (it comes with the posture check of #2252):
    open it by its address. A save that holds people at once sends their open
    pages to the setup page and drops their GraphQL and collaboration sockets.
  - **The grace period** runs per account from the latest of its creation,
    its joining the site and its role becoming covered; a promotion does not
    restart it. During it, console pages and `/account` show "This site
    requires two-step sign-in. N days left to set it up.", each sign-in on
    the main or console host first lands on the setup page with **Not now**
    (a sign-in on a site's own address goes where it was going; the banner
    links to the main host's page), and the headless sign-in's `201` carries
    `second_factor: {required: true, deadline}`.
  - **Held accounts** are sent to the setup page from every browser
    page of the site (a `302`, `private, no-store`, writing no session or
    cookie), every console LiveView (also one left open across the deadline
    or a policy change), `/membership` and plugin pages, and every sign-in.
    They keep the setup page, sign-out, the sign-in pages, billing
    (`POST /billing/portal`), the export of their own data, `/locale`,
    `/developers`, preview and newsletter links; images are served to them as
    to an anonymous visitor. Their JWTs get `403 second_factor_required` on
    `/api/*`, `/gql` and `/api/feed` (public reads included), and at the
    `/ws/gql` and `/ws/collab` connect; a `/ws/gql` socket opened in the
    grace period closes at the deadline and refuses each document after it.
    **API keys are never held.**
  - **The setup page, `/account/two-factor`,** is open to every signed-in
    account, readers included (`/editor/settings` is editors only), and is
    served only on the main host (`PHX_HOST`) and console hosts: a site's
    own address is where a site administrator's injected code runs, and
    cannot register a passkey. There, the page and every redirect that holds
    an account go to the main host's page, with no `return_to`, and the
    person signs in once more on the main host. `/account` gains a
    **Two-step sign-in** card with **Set up two-step sign-in**, which says
    "This opens on (main host), where you sign in again." on a site's own
    address. The page adds an authenticator app (with recovery codes) or a
    passkey, and continues to where the person was going. It judges the
    site it is opened for (on the main host, the default site): a reader
    held by a site that requires everyone gets **Manage billing** and
    **Export my data** where the page is opened for that site, so not on the
    main host when another site holds them.
  - **The email proof.** A session that signed in with only a password (or a
    remember-me cookie) at or after the deadline of any site holding the
    account must confirm a six-digit code mailed to the account before it can
    add a factor, so someone with only the password cannot enroll their own.
    Skipped for magic-link, password-reset, account-confirmation, single
    sign-on and passkey sessions, for accounts no site holds, for a password
    session from before the deadline, and when the site has no working mail
    relay (`proof: "email_skipped_no_relay"`); a relay that fails this time
    never skips it. The code lasts 10 minutes, works only in the session that
    asked, is never stored, and each try uses the account's shared
    second-factor attempts (five per 15 minutes); at most three codes an hour
    go to an address (code config `config :kiln_cms,
    KilnCMS.Accounts.AccountThrottle, enrolment_proof_mail_budget: 3`).
    The check is on the enrollment actions (`User :confirm_totp`,
    `Passkey :register`, `KilnCMS.Accounts.Changes.RequireEnrolmentProof`),
    which fail closed when called without the page's context.
  - **Passkey-only accounts** satisfy the requirement, but past the deadline
    their password alone is not enough: it stops at the passkey prompt on the
    main or console host and is refused on a site's own host; a password
    session from before the deadline and a remember-me restore go through
    the same prompt; their headless sign-in is `403` with
    `meta.reason: "passkey_only"`, and their JWTs are refused.
  - **The last factor stays.** While any site the account uses requires a
    second factor, its owner cannot disable its authenticator app with no
    passkey left, or remove its only passkey with no app; `/editor/settings`
    says why. Replacing the app still works.
  - **Recorded:** `second_factor_required` ("Held for two-step sign-in
    setup"), once per sign-in held or refused (`surface` `browser` or `api`,
    `reason` `not_enrolled`, `passkey_host` or `headless_passkey`), and
    `proof` (`email`, `email_skipped_no_relay`, `magic_link_session`,
    `not_required`) on `second_factor_enrolled` and `passkey_added`. Refused
    API requests emit `[:kiln_cms, :api, :second_factor_required]`
    (`surface`) and write no event.
  - **For developers:** `KilnCMSWeb.SecondFactorGate` (`held?/3`,
    `bearer_refused?/3`, `passkey_step_up_owed?/3`, `sign_in_destination/3`,
    `attach/2`, `screen/2`, and for the setup page's host `setup_host?/1`,
    `setup_location/3`, `setup_href/1`, `main_setup_url/0`,
    `redirect_opts/1`, `setup_host/1` and `socket_host/1`), the
    `KilnCMSWeb.LiveUserAuth` hook `:second_factor_setup_host`, the
    `setup_url` attribute of `Layouts.second_factor_banner/1`, `KilnCMSWeb.Plugs.SecondFactorGate`,
    `KilnCMSWeb.Plugs.SecondFactorBearer`, `KilnCMSWeb.Plugs.PasskeyStepUp`,
    `KilnCMSWeb.GraphqlLimits.SocketSecondFactor`,
    `KilnCMS.Accounts.EnrolmentProof`, `KilnCMS.Accounts.SecondFactorEviction`,
    `KilnCMS.Accounts.Validations.KeepsRequiredSecondFactor`, the errors
    `EnrolmentProofRequired` and `LastSecondFactorRequired`,
    `KilnCMS.Mail.relay_available?/1` and `no_relay?/1`, and
    `TwoFactorRequirement.enforced_somewhere?/1`, `enforced_deadlines/2` and
    `overdue_user_ids/3`. `KilnCMSWeb.SecondFactorStepUp.decide/3` (was
    `decide/2`) can also answer `{:refuse, :passkey_host | :headless_passkey}`,
    and the sign-in budget follows it. The collab token now carries whether
    its session passed a second factor (`KilnCMSWeb.CollabSocket.token/2`); a
    token from before the upgrade reads as not. The OpenAPI document gains
    the sign-in's `403` and `second_factor` field.
  No migration beyond the one in the [upgrade note](#second-factor-policy-upgrade).
  Guide: [Requiring two-step sign-in on a site](../two-factor-auth.md#requiring-two-step-sign-in-on-a-site);
  operators, read the [upgrade note](#second-factor-enforcement-upgrade).
  Closes #2247.

<a id="passkey-at-code-prompt"></a>

- **At the two-step sign-in prompt, an account that also has a passkey can finish with it instead of a code.**
  After the first factor (a password, a magic link or single sign-on), an
  account with an authenticator app is sent to `/sign-in/verify` for a code.
  If the account also has a passkey, the page now shows **Use a passkey**
  below the code form. The browser offers only that account's own passkeys
  and asks for the device's screen lock, and the sign-in then completes as a
  code would. The button appears only in a browser with WebAuthn, and only
  where a passkey ceremony can run: the main host (`PHX_HOST`) or a console
  host that sits under it (`KILN_CONSOLE_HOST`), never a site's own host.
  This entry did not change who is asked for a second factor: accounts with
  an authenticator app reach the prompt, and a passkey sign-in from `/sign-in`
  is still a complete sign-in on its own. (A site that requires two-step
  sign-in also sends a passkey-only account there past its deadline; see
  [the third part](#second-factor-requirement).) A passkey refused at the prompt
  counts against the same per-account budget as a wrong code (5 per 15
  minutes), is recorded the same way (`sign_in_failed`, `method:
  "second_factor"`, `reason: "invalid_code"`), and at the limit gets the
  same "Too many attempts" refusal, lockout event and owner email. A verified
  passkey clears the sign-in throttle as a code does. "Remember me" is issued
  only after the passkey verifies. If the five-minute pending sign-in has
  run out, the button sends the browser back to `/sign-in`. The completed
  `sign_in` event's `method` is the first factor's (`password`,
  `magic_link`, `sso`, …), as after a code.
  For developers: two JSON routes on the prompt's pipeline, `POST
  /sign-in/verify/passkey/options` and `POST /sign-in/verify/passkey`
  (`KilnCMSWeb.TwoFactorController`), with their own session key and
  challenges, so a nonce from the anonymous `/auth/passkey/*` ceremony is
  never accepted there, nor the reverse. New:
  `KilnCMS.Accounts.WebAuthn.step_up_challenge/1`,
  `KilnCMS.Accounts.WebAuthn.verify_step_up/3`,
  `KilnCMS.Accounts.WebAuthn.ceremony_host?/1`,
  `KilnCMS.Accounts.SecondFactor.check_passkey/3`,
  `KilnCMS.Accounts.second_factors/1`,
  `KilnCMS.Accounts.has_second_factor?/1`, and
  `KilnCMSWeb.SecondFactorStepUp.decide/2`, the one place the browser and
  headless sign-in doors decide who is prompted.
  `KilnCMS.Accounts.PendingSignIn.resolve/4` replaces `resolve/3`: the new
  last argument names the factor the caller is about to check (`:totp`,
  `:passkey` or `:any`), so a passkey-only account cannot spend the code
  budget on the code form. Each browser session now also records how it
  signed in (`KilnCMSWeb.SignInMarker`): session key `"sign_in"`, holding
  the method and, when one was verified, when the second factor was. It is
  keyed to the session token's `jti`, so a marker left over from an earlier
  token (after an idle timeout, say) reads as `nil` and is never inherited;
  a remember-me sign-in writes `method` `"remember_me"`. The third part of
  #2247 reads it (the policy page, the email proof and the passkey-only
  gates). No migration, no
  API change and no new setting; rolling back removes the button, and an
  older release ignores the session key. See
  [Using a passkey at the code prompt](../two-factor-auth.md#using-a-passkey-at-the-code-prompt).
  (Part of #2247.)

<a id="second-factor-added-email"></a>

- **Account owners are emailed whenever a second factor is added: an authenticator app set up or replaced, or a passkey registered.**
  Adding a factor needs a signed-in session, so whoever holds a stolen
  session could add one and use it to sign in again after the owner's
  session ends, and nothing told the owner. Now confirming an authenticator
  app on `/editor/settings` (a first one or a new one replacing the old) and
  every passkey registration mail the owner, after the change commits. A
  wrong code or a refused registration mails nobody. Regenerating recovery
  codes adds no factor and mails nobody. The subject is "A second factor was
  added to your (instance name) account"; the body says which kind ("An
  authenticator app was set up…", "A new authenticator app replaced the
  one…", "A passkey was added…"), when (UTC), the browser and platform
  family it was added from (for example "Firefox on macOS"), and the site,
  when known. It never contains the secret, recovery codes, the passkey's
  name or its credential id: the name was typed by whoever added it. "If it
  wasn't you": reset your password, which signs out every session, then ask
  an administrator of your site to check the account's sign-in methods. Not
  "sign in and remove it": the new factor may now be the only one the
  account has. Like the other account mail it goes through the instance
  relay (`KilnCMS.Mailer`), never a site's own, in English, and cannot be
  muted. An erased account gets nothing. A mail that cannot be queued is
  logged ("Second-factor notice for user … not sent") and does not undo the
  enrollment. New: `KilnCMS.Accounts.SecondFactorNotice` and the change
  `KilnCMS.Accounts.Changes.NotifyFactorAdded` on `User` `:confirm_totp`
  and `Passkey` `:register`. See
  [We email you when a second factor is added](../two-factor-auth.md#we-email-you-when-a-second-factor-is-added).
  (Part of #2247.)

<a id="crawler-ip-ranges"></a>

- **Search-engine claims are checked against the engines' published crawler IP lists before DNS: an address in Google's, Bing's, Apple's or DuckDuckGo's fresh list is verified with no DNS query, and DuckDuckBot can be verified at last.**
  Until now every claim went to reverse and forward DNS (#2254), and
  DuckDuckBot, which publishes addresses rather than a reverse-DNS domain,
  could never be verified or proven false (#2586).
  - **What a list decides.** An address inside the claimed engine's list is
    verified, with no lookup charged against the per-network limits and
    nothing cached. Outside it, Google, Bing and Apple fall back to DNS, so
    a list that lags the vendor never fails a real crawler; DuckDuckBot,
    with no DNS to fall back on, is proven false (see the
    [upgrade note](#crawler-ip-ranges-upgrade)). A list is fresh for 24
    hours after it was fetched; a missing or stale one decides nothing.
    Yandex and Baidu publish no list and stay DNS-only.
  - **What refuses a list.** A list is refused whole, keeping the one held
    before, when it is not the expected JSON, has no usable range or more
    than 5,000, holds a range wider than IPv4 `/20` or IPv6 `/48` or more
    than 65,536 IPv4 or 2^80 IPv6 addresses in total, or overlaps private,
    loopback, shared, link-local, multicast, documentation, benchmarking,
    6to4, Teredo or NAT64 space (IPv6 must be inside `2000::/3`). A match is
    only as good as the vendor's list: Bing's includes `/28`s in Microsoft
    Azure space.
  - **Operators.** New `KILN_CRAWLER_RANGES` (default on; `false` makes no
    request and reads no list; off whenever `KILN_CRAWLER_VERIFICATION` is
    `false`) and `KILN_CRAWLER_RANGES_CRON` (default `17 */6 * * *`; `false`
    stops every automatic fetch, the boot and stale-list ones included). New
    metric `kiln_cms.crawler_verification.ranges_fetch.count`, tagged
    `engine` and `result` (`ok`, `http_error`, `transport_error`,
    `too_large`, `blocked`, `invalid`, `no_prefixes`, `too_many`,
    `too_broad`, `not_public`, `other`). For a health check,
    `bin/kiln_cms rpc 'IO.inspect(KilnCMS.CrawlerVerification.Ranges.status())'`
    prints each list's source, range count, age in milliseconds and
    `fresh?`. Guide:
    [Published IP ranges](../bot-budgets.md#published-ip-ranges).
  - **Developers.** New `KilnCMS.CrawlerVerification.Ranges` (with
    `lookup/3`, `fresh?/2`, `status/0`), `Ranges.Parser`, `RangesWorker`
    and `RangesSync`; `KilnCMS.CrawlerVerification.Engines` gains
    `known?/1`, `range_source/1`, `range_engines/0` and
    `default_range_sources/0`; `KilnCMS.Security.Cidr` gains
    `global_unicast_range?/1`. Code config
    `config :kiln_cms, KilnCMS.CrawlerVerification.Ranges`: `:enabled`,
    `:sources` (`%{engine => url | false}`, per engine), `:max_age_ms`,
    `:max_bytes`, `:max_prefixes`, `:bootstrap?`, `:bootstrap_after_ms`,
    `:req_options`. `KilnCMS.CrawlerVerification.check/3`'s answers are
    unchanged in shape: `{:unverified, :failed}` now also means DuckDuckBot
    outside its list, and `{:unverified, :unverifiable}` means DuckDuckBot
    with no fresh list or over IPv6.

<a id="second-factor-policy-groundwork"></a>

- **The setting and logic behind requiring two-step sign-in by role, and an operator command to turn a site's requirement off.**
  The second part of #2247: the setting (who must hold a second factor, and
  a grace period of 0 to 90 days, default 14) and the logic that answers who
  it covers and by when. The page, the reminders and the enforcement are the
  [third part](#second-factor-requirement); a site with no saved setting
  requires nothing, and nobody is held.
  For operators: `bin/kiln_cms rpc
  'KilnCMS.Release.second_factor_requirement_off(org: "acme")'` turns a
  site's requirement off (and nothing else) as the server's `:operator`
  actor, for when no administrator can pass it, such as a last administrator
  whose only passkey is lost. It prints what it found and returns
  `{:ok, :off}` or `{:error, message}`; it needs `rpc`, not `eval`. The
  change is recorded as "Two-step sign-in requirement changed" with no
  person. See
  [Turn the requirement off from the server](../two-factor-auth.md#turn-the-requirement-off-from-the-server).
  Security log: new types `second_factor_policy_changed` (`required_for`,
  `grace_days`, `previous_required_for`, `change`, `via`; it replaces
  `org_setting_changed` for this setting) and `second_factor_required`
  (`tier`, `surface`, `reason`), and a `proof` key on
  `second_factor_enrolled` and `passkey_added`, the last two written by the
  third part. For developers: `KilnCMS.CMS.SiteSecondFactorPolicy`
  (not on JSON:API, GraphQL or MCP) and
  `KilnCMS.Accounts.TwoFactorRequirement`: `policy/1` (cached for a
  minute; an unreadable row is logged and read as off, uncached),
  `read_policy/1`, `status/3`, `step_up/3`, `required_somewhere?/1`,
  `promotion_warning/4` and `roster/3`. Every save of the setting by a
  person needs that person's second factor, proved within the last 15
  minutes (`:second_factor_verified_at` in the changeset context) or by a
  `code` argument checked against the account's shared second-factor
  budget; pass `code` only on submit, since every build of the changeset
  charges it. Why it fails open, why API keys are exempt and why every save
  needs a fresh factor:
  [ADR 0030](../decisions/0030-the-second-factor-requirement-fails-open-and-only-a-freshly-verified-admin-changes-it.md).
  (Part of #2247.)

## Changed

<a id="form-field-name-website-reserved"></a>

- **No form field of any type can be named `website` any more, and the form builder flags a field that already is.**
  `website` is the name of the hidden spam-trap input every public form
  carries, and a submission that fills it is discarded with a fake success.
  A field of your own with that machine name is filled by real visitors, so
  every submission that answered it was silently thrown away. 1.9 refused the
  name only on the field types it added; it is now refused on every type,
  when a field is added, renamed or has its type changed. A field that
  already carries the name keeps working as before (label, order,
  **Required** and other edits still save), but the builder shows
  **Reserved name** under it on the preview and a note under **Machine
  name** in its settings until it is renamed; its type can't be changed
  until then, as 1.9 already refused for the new types. Admins: open each
  form in the builder and rename any flagged field
  ([Fix a field named website](../forms.md#fix-a-field-named-website)). The
  spam trap itself is unchanged: `GET /api/forms/<slug>` still reports
  `"honeypot_field": "website"`. `FormField` has no JSON:API or GraphQL
  write surface, so only code that calls `KilnCMS.CMS.create_form_field`
  or `update_form_field` with that name sees the new refusal, *is reserved
  for spam protection* on `name`. (#2267)

<a id="webhook-url-masking"></a>

- **Webhook URLs are shown masked wherever Kiln shows, exports or logs them, and the edit form no longer pre-fills the URL.**
  An incoming-webhook URL (Slack, Teams, Discord, Zapier) carries its own
  token, so the URL itself is a credential. Every endpoint's URL, whatever its
  format, is now shown as `scheme://host[:port]` followed by `/…/` and the last
  four characters of the path and query, or the host alone when those are
  shorter than 16 characters; a user name and password are never shown
  (`KilnCMS.Webhooks.display_url/1`). This covers the Webhooks list, Recent
  deliveries, the secret buttons' accessible labels, the governance trail's
  propagation endpoints and **Retractions not delivered** panel, the trail's
  JSON and CSV exports (same keys, masked values; the JSON now adds
  `endpoint_id` to each propagation endpoint and lost retraction, so two
  endpoints that mask alike can be told apart), the "Retraction not
  delivered" notice and its log line, and URL validation errors. **Reveal
  URL** on a row, or under **Current URL:** in the edit form, re-reads the
  endpoint as the admin and shows the full URL for the open page. The edit
  form's **Endpoint URL** starts blank: leave it blank to keep the URL, or type
  a new one. The database and the delivery ledger keep the full URL, and a
  redelivery is sent to it. A script that read full URLs out of the
  governance exports must now read them from the endpoint itself. Notices
  written before the upgrade keep the full URL in their excerpt.
  (Part of #2245.)

<a id="webhook-select-all-skips-security"></a>

- **Select all in a webhook's event list no longer ticks the `security.*` events.**
  It is there to mirror content, and an endpoint that took every event that
  way also received security alerts (client addresses, user ids) at a
  receiver nobody chose for them, and every later edit of it sent each admin
  a notice that can't be muted. Select all now ticks every other event and
  keeps a security event only if it was already ticked; the `security`
  group's own **Select all** still ticks them all. On a Slack-format form,
  which offers only security events, Select all ticks them all. (#2642)

<a id="ci-required-check-covers-more-jobs"></a>

- **For contributors: the required `Compile, lint, scan & test` check now also waits on the docs, strict-tenancy, overlay drift, client, JS client and ML jobs, and a hung CI job fails within its own time limit.**
  The "Require CI on main" ruleset names that one check, and it only
  aggregates the jobs in `ci.needs`. Those were the build, the test shards,
  coverage, Dialyzer and the plugin SDK, so a PR could merge with a red
  `mix docs`, a pending `mix ash.codegen` (checked only by the
  strict-tenancy job), broken client libraries or a broken `KILN_ML=1`
  build. `ci.needs` now adds `docs`, `strict_tenancy`, `overlay_drift`,
  `client`, `client-js` and `ml`, all reliably green on `main`. Still visible but not required, with the reason
  written above the `ci` job: `e2e` (it failed in about 6 of the last 100
  runs), `deps_audit` (the advisory database changes on its own schedule),
  `image` (it downloads release assets from GitHub; see the image-build entry under Fixed) and the qpdf and ImageMagick script jobs.
  To make a job required, add it to `ci.needs`; the ruleset does not change
  ([Required checks](https://github.com/The-Verscienta/kiln_cms/blob/main/CONTRIBUTING.md#required-checks)).
  Every required job now has a job-level `timeout-minutes` (20 to 90),
  three or more times its longest recent run, instead of GitHub's six-hour
  default. That default is what let one hang hold the docs job for 68
  minutes: the docs publisher dry-run waited on a Mix build lock held inside
  its own VM. The three publisher dry-runs now run with
  `MIX_OS_CONCURRENCY_LOCK=0` (each is one `elixir` process, and they run one
  after another, so the cross-process lock protects nothing there) and a
  5-minute step timeout. The real publish workflows are unchanged.
  (#2729, #2572)

<a id="passkey-limits"></a>

- **An account can hold at most 20 passkeys, and add at most 5 in an hour.**
  Every passkey added now mails the owner (see the entry under Added), so
  the total and the rate are both bounded: a stolen session must not be able
  to turn "an email for every factor added" into a flood of the owner's
  inbox and the instance's mail quota. At 20, the **Passkeys** section of
  `/editor/settings` replaces the add form with "You have 20 passkeys, the
  most an account can hold. Remove one to add another." Over the hourly
  budget a registration is refused with "You've added several passkeys in a
  short time. Try again in N minutes." The budget counts every registration
  that passes the browser's verification and reaches the save, including one
  that then fails (a passkey already registered); one the cap refuses is not
  counted. An account that already holds more than 20 keeps them, and can add
  another once it is below 20 again. The cap is fixed
  (`KilnCMS.Accounts.Passkey.max_per_account/0`). Operators can change the
  hourly budget, per account and shared by every node:
  `config :kiln_cms, KilnCMS.Accounts.AccountThrottle,
  passkey_registration_budget: 5, passkey_registration_window:
  :timer.hours(1)` (the window in milliseconds; read at run time, so
  `config/runtime.exs` works). Both refusals are on the `:register` action,
  so every caller gets them: `KilnCMS.Accounts.Errors.PasskeyLimitReached`
  (forbidden class, `max`) and
  `KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled` (invalid class,
  `retry_after_seconds`). (Part of #2247.)

## Fixed

<a id="backup-resume-safety"></a>

- **Resuming a backup is safe against a double re-open, a step that outlived its Cancel, and a node without the files; a resume that can't run now says why on its History row.**
  Three gaps, all on the path from **Resume** (or `Backups.request(resume:)`)
  to a run that is `Running` again. See
  [Several nodes and the backup lock](../backups.md#several-nodes-and-the-backup-lock)
  and [Cancel a running backup](../backups.md#cancel-a-running-backup).
  - **The re-open is atomic (#2421).** #2537 already stopped two requests
    from resuming the same run through the lock; the Run's own `:resume`
    guard still checked only the struct it had loaded. It is now repeated in
    the UPDATE's WHERE (an in-app run that is `failed`, `canceled`, or
    `running` and stale), so of two callers holding the same stale run one
    re-opens it and the other gets `Ash.Error.Changes.StaleRecord`.
  - **A step that outlives its Cancel is fenced (#2538).** Cancel reaches a
    step's node through the database, so a node that has lost it keeps the
    step running until its heartbeat's 90-second self-fence, and one that
    reconnects sooner never fenced at all. Now:
    - **Resume waits after a Cancel.** For 150 seconds after a run is
      canceled, **Resume** on it is refused with "That backup was canceled
      moments ago. Resume it again in N seconds: a step on a server that
      lost contact with the database may still be stopping." The button
      stays, and the `Canceled` row's tooltip says to wait about two and a
      half minutes. `Backups.request/2` returns
      `{:error, {:canceled_recently, seconds}}`. A resume that starts inside
      the window without a click (queued earlier, or a retried start step)
      waits in its step instead, up to 180 seconds, and logs "Waited N s
      after the Cancel before resuming"; a legacy `Backups.Worker` resume
      job snoozes for the time left.
    - **`state.json` is written under the backup lock**, and only while the
      step's job still holds it, so a canceled step can't overwrite what a
      resume of the same stamp has written.
    - **The step's History writes are filtered by its chain.** `record_progress`,
      `finish` and `fail` land only on a `running` run whose `chain_id` is
      still the writer's (`Run.Changes.OwnChain`).
    - **The heartbeat stops a step whose job was canceled**, after its next
      successful beat: a step whose Oban job is `cancelled`, `completed` or
      `discarded`. A missing job row stops nothing (a failover to a lagging
      standby can lose a live step's row).
    The 150-second window is typically enough, not a guarantee: a heartbeat
    hung on a half-open database connection waits out its query timeouts
    before it stops the step. What the window alone protects is the step's
    own `.partial` files, which are not fenced. The fenced `state.json` write
    holds the cluster-wide advisory lock, so on a backup directory that
    stalls (a hung NFS mount) Cancel, new requests and the heartbeat's sweep
    wait behind it until their query timeout.
  - **A resume runs where its files are (#2539).** On a cluster with a
    `BACKUP_DIR` per host, a resume's start ran on whichever node picked it
    up; elsewhere than the host with the files it was refused, the row kept
    `Running` for over two hours, and the page had said "Backup resumed".
    Each run now records its directory's `.kiln-dir-id` (`Run.dir_id`, set at
    start and rebound on each resume), and a resume's start runs only on a
    node that has `.work/<stamp>/state.json` locally or reads that id. Local
    files win, so a copied directory, or one given a new id, still resumes. On
    any other node the start waits 30 s and is put back, 20 times per attempt
    across the job's four attempts and their 1/5/15-minute backoff (about an
    hour, holding the lock, when no live node has the files), then is given
    up: the lock is released (a queued request starts) and the row reads
    "Resume refused: no server with its backup directory (id …) picked it up;
    every attempt waited about 10 minutes for one". Nothing on the page can
    cancel a resume during that wait or the wait after a Cancel: **Cancel**
    is offered only for a `Running` row.
  - **A refused resume is visible.** The start step now reads `state.json`
    before it re-opens the run, and any refusal after the click (files not
    on that server, no media directory for a media-only run, the wait after
    a Cancel ran out, the start crashed or was interrupted before the
    re-open) writes "Resume refused: `<reason>`" above the run's original
    error, through the new system-only `Run` action `:note_resume_refused`
    (code interface `Backups.note_run_resume_refused`). Refusals don't
    stack. A `failed` or `canceled` run keeps its status and its **Resume**
    button; a stale `running` one is marked `failed`.

<a id="security-alert-gaps-2642"></a>

- **Four gaps in security alerts after 1.9: the inbox's language, exhausted deliveries, platform alerts outside the default console, and IPv6 in the help text.**
  - The inbox showed a translated "Security alert" over an English
    description. Bell rows of security alerts now store the facts behind the
    line (`notifications.details`), and the inbox says it in the reader's
    language; rows from before keep their English line. The email stays
    English by decision: an account stores no preferred language and one
    admin can hold sites in several.
  - An alert that used its 10 delivery attempts was only stamped
    `failed_at`. It now also logs at `error` and emits
    `[:kiln_cms, :security, :alert_failed]` with `reason: :delivery_exhausted`
    and a new `phase` key (`:alert` or `:summary`), once per alert.
  - Platform alerts live in the default site, so a platform admin working in
    another site's console never saw them. The bell and inbox there now show
    one entry, "N unread platform alerts", linking to the default site's
    unread inbox. It is a count and nothing else: another site's console is
    that site's origin (threat model residual risk 16, decision record 0011).
    Platform alerts from before the upgrade are not counted.
  - The **Show the full IP address in alerts** help text now reads "Off, an
    alert shows only the address's network: its /24 for IPv4, its /48 for
    IPv6. The security log keeps the full address either way." (#2642)


<a id="failed-sign-in-tally-sharded"></a>

- **A burst of failed sign-ins on one site no longer queues on one database row, and the failed-sign-in alert can carry a count above 10.**
  Every failed sign-in on a site with the `failed_sign_ins` alert on added
  one to a single `throttle_counters` row, so concurrent attempts waited on
  its row lock. The count is now spread over 8 rows per site, picked at
  random (an attacker can't steer it), and summed by a second statement
  after the increment commits (`ThrottleStore.count_sharded/5`,
  `window_sum/3`). The alert fires when the total is at least 10 rather than
  exactly 10, because attempts that arrive together can each read a total
  past it; its `count` (`threshold_count`) is the total the first of them
  saw, so it can be 11 or more. A node-local memo
  (`KilnCMS.Security.AlertTrips`) lets only the first crossing per site and
  window on each node be recorded unsampled and try to claim the alert, and
  `AlertGate` still keeps it to one alert across nodes. If the sum can't be
  read, the shard's own count is used, which undercounts, so the alert can
  come late during that fault. A crossing counted on a node's local fallback
  (database down) does not use up the window's shared crossing. The
  window's summary reads the sum too (`Alerts.failed_sign_in_total/2`).
  No migration. **Rolling deploy:** the sum includes the old single-row
  key, so counts from a 1.9 node are kept; a 1.9 node reads only that key,
  so in the window of the deploy or a rollback it can raise the alert late
  and, if it sends the summary, show too low a count or skip it ("the
  failed sign-in tally for its window is gone").
  Measured with the new `:benchmark` test (excluded by default; `mix test
  --only benchmark test/kiln_cms/accounts/throttle_store_sharded_benchmark_test.exs`)
  on a loaded development host: with 16 concurrent writers on one site,
  p50/p99 per charge went from about 0.97/5.95 ms (one row) to 0.76/2.69 ms
  (8 shards); with 32 writers p50 improved and p99 was too noisy to call.
  (#2639)

<a id="form-duplicate-autoresponder"></a>

- **Duplicating a form whose autoresponder is on and uses `[field:…]` tokens works again, and a field that can't be copied is named instead of dropped.**
  The copy was created with the autoresponder on before any of its fields
  existed, so the token check found no field and refused the whole
  duplicate. The copy is now created with the autoresponder off, its fields
  are copied, its renamed tokens are written, and then it is switched on in a
  separate write checked against the copy's own fields. A field named `website` is copied as `website_2` (or
  the next free name), and the copy's `[field:website]` tokens follow; the
  message says so. A field the copy refuses is listed in an error message,
  and when the copy's autoresponder can't be switched on (its template names
  a field that wasn't copied) it stays off with the reason shown. (#2267)

<a id="form-errors-translated"></a>

- **Number and rating errors on a public form read as translated sentences, such as "Enter a number of at least 0.5.", and the builder explains what a default value does for dropdowns, radio buttons, checkbox groups and ratings.**
  The bounded refusals (at least, at most, step, rating range) and a hidden
  field's "is too long" reached the HTML form as raw English fragments. The
  HTML form now shows them in the form's language, with the bound as the
  server writes it (`0.5`, which is what a number input takes). The JSON
  endpoint `POST /api/forms/<slug>` returns the same English fragments as
  before (`must be at least 0.5`), because clients match on them. The
  builder's **Default value** input now has a hint for a dropdown or radio
  buttons (an exact option match pre-selects it), a checkbox group (that one
  box starts checked) and a rating (a whole number of stars), joining the
  checkbox's, and the hint is announced with the input. (#2269)

<a id="form-error-summary-focus"></a>

- **A public form's error summary links now move focus to radio buttons, checkbox groups and ratings, landing on the group's first option.**
  The links pointed at the group's `<fieldset>`, which cannot take focus,
  so following one scrolled the page but left focus behind, and a keyboard or
  screen-reader user had to find the field again. The link now targets the
  group's first input, with a scroll margin that keeps the group's question
  in view. A hidden field's error is listed as plain text, since a hidden
  input can never take focus. (#2268)

<a id="form-thank-you-site-layout"></a>

- **The thank-you page after a form submission on the site, and its "Form not found" page, now show the site's header, footer and branding, in the form's language.**
  They were a bare card with none of the site around it, unlike the form
  page and its error re-render. Both now render in the site's public layout
  for the same site and language; the 404 is headed **Form not found** and
  says *This form doesn't exist or no longer takes submissions.* A tripped
  spam trap's fake success gets the same page as a real one. The page inside
  an embed's iframe is unchanged. The **Back** link is also left out when
  the referring path starts with `//` or `/\`, which a browser reads as
  another host. (#2338)

<a id="dynamic-type-site-lookup"></a>

- **Custom content types on a site other than the default one are delivered again.**
  Several read paths resolved a content type by name without saying which
  site was asking, and a custom (admin-defined) type then resolves against
  the default site. On any other site that defines a type the default site
  lacks, `GET /api/content/<type>/<slug>` answered 404 for published
  entries, the headless and HTML passphrase unlock could not find the
  document, `/related` and `/api/provenance` answered 404, the visual-editing
  socket refused the connection, and **Visual** in the content editor said
  *No such content to edit*. Each of those now passes the request's site.
  Built-in and overlay-compiled types were never affected.

<a id="storage-copy-and-backup-verify"></a>

- **A copy from storage that fails partway is an error, and `backup.sh verify` fails on a corrupt dump.**
  `KilnCMS.Storage.copy_to_file/3` answered `:ok` when a read failed after
  the first chunk, and ignored a failed write, leaving a short file on
  disk. The direct-upload completion and the audio/video metadata strip took
  that file as the whole upload. It now returns `{:error, reason}` for a
  failed read or write at any offset. Separately, `scripts/backup.sh verify`
  ran `pg_restore --list … && echo "dump: ok"`, which `set -e` does not
  treat as a failure, so a truncated dump with no checksum sidecar verified
  clean with exit 0; it now stops with an error naming the dump.

<a id="sweep-crash-fixes"></a>

- **Crash fixes in the console and the public API.**
  `ContentTypes.get_record/3` raised for a type that no longer resolves (an
  archived custom type, a removed plugin), which took down the Tasks page,
  the calendar and a menu item's Edit for anything still pointing at such an
  entry; it now returns `{:error, :unknown_content_type}`. A nested value in
  a custom-field filter (`custom_filter[name][eq][x]=1`) answered 500 and
  now answers 400. Creating a redirect from `/` crashed the Redirects form.
  A federation inbox body that is valid JSON but not an object is answered
  400. A `return_to` path containing a backslash, a tab or a newline falls
  back to the default instead of answering 500. Moving a block that is no
  longer on the page in the in-context editor is ignored instead of
  crashing the editor.

<a id="sweep-wrong-results"></a>

- **Wrong results fixed.**
  The Home health panel and its CSV export ordered rows by comparing
  `DateTime` structs field by field, so "most overdue first" could list a
  March deadline ahead of a January one and drop the worst rows from the top
  ten. A mention such as `@josé` was cut at the first non-ASCII letter and
  could notify a different member. A form rating field with a maximum below
  1 rendered a descending range of options. Saving in the Presentation
  console broadcast a block shape the pop-out and token previews cannot
  render, crashing them. Group caps on custom-field filters (`_or`/`_and`
  depth and member count) were skipped when the filter was passed with atom
  keys from Elixir or MCP. Links and rich text refuse a relative path that
  hides a `//host` behind a tab or newline.

<a id="sweep-federation-release"></a>

- **A federation delivery whose ledger row could not be read is retried, and the release schedule confirmation moved to the button.**
  The delivery worker treated every failed read of its ledger row as "the
  row was pruned" and finished successfully, so a database timeout dropped
  the activity and left the row pending. Only a not-found is treated that
  way now. On a release with blocked items, the "Schedule anyway?"
  confirmation was attached to the whole form, so clicking the date field
  asked it and cancelling kept the picker from opening; it now asks when
  **Schedule** is pressed. In the editor, a rich-text block's pending
  autosave is cancelled when the block is rebuilt after a conflict reload or
  a version restore, so it can no longer write the pre-reload text back.

<a id="backup-marker-sync-cron-only"></a>

- **A deployment that backs up only with host cron now gets the last-good marker, so `backup.sh prune` keeps the newest verified backup there too.**
  The app wrote `kiln-<stamp>.good` only at the end of an in-app backup or
  before an in-app prune, so a deployment whose backups all come from
  `scripts/backup.sh` never had one, and its prune kept only the newest
  complete set, even when that set came from a failed run (an off-site copy
  that was refused, say). A scheduled job, `KilnCMS.Backups.MarkerSyncWorker`,
  now imports cron's backups into History and moves the markers to the newest
  verified backup of each component, under the backup lock, every 15 minutes.
  While an in-app backup runs it skips the slot, since that backup moves the
  markers itself. A cron backup is marked at the first run that can import it:
  any run once `manifest.json` names its stamp, otherwise once its newest file
  is 10 minutes old, so allow up to about 25 minutes.

  Operators:

  - **Nothing to set** on a single host or a shared volume, as long as the app
    sees the same `BACKUP_DIR` as cron. A node with no backup directory does
    nothing and logs nothing.
  - **The schedule** is `KILN_BACKUP_MARKER_SYNC_CRON` (default
    `*/15 * * * *`, read in every environment). `false` turns it off; an
    unparseable value warns on stderr at boot and turns it off.
    `BACKUP_ENABLED=false` does not stop it: that switch is for the in-app
    backup path, and the marker is for the cron path.
  - **Several hosts, each with its own `BACKUP_DIR`**: each node's
    heartbeat gives its directory a `.kiln-dir-id` once it holds backups
    (#2789, [below](#backup-marker-sync-every-host)). Each slot syncs the
    directory of the node that picked up the job, and queues one sync for
    every other directory id, which waits for a node that reads it, for up
    to about 10 minutes, then logs "Backup last-good marker sync for backup
    directory `<id>` gave up: no node with that directory picked it up".
  - **Watch it** with the new `[:kiln_cms, :backups, :last_good, :synced]`
    event (`%{count: 1}`; metadata `dir`, `db`, `media`). A failed run emits
    the existing `[:kiln_cms, :backups, :last_good, :failed]` and logs
    "Backup last-good marker not updated: …", writes and removes no marker, and
    is not retried; the next slot runs the same sync.
  - **Rolling back** to 1.9.x is safe: there is no migration. The job stops,
    and on a cron-only deployment the markers it wrote stay until deleted by
    hand, keeping those units past `BACKUP_KEEP_DAYS`.

  Developers: `KilnCMS.Backups.Chain.sync_last_good/2` runs one sync and
  returns `{:ok, %{db: stamp | nil, media: stamp | nil}}`, `:busy` or
  `{:error, reason}`, never raising. `KilnCMS.Backups.Retention.sync_last_good/2`
  takes a new `import: false` option for a caller that already ran the
  importer. See [The last-good marker](../backups.md#the-last-good-marker).
  (#2554)

<a id="backup-marker-sync-every-host"></a>

- **On a cluster with a `BACKUP_DIR` per host and only cron taking backups, the last-good marker sync now reaches every host's directory, not just the node that picked up the job.**
  The sync (`KilnCMS.Backups.MarkerSyncWorker`, #2554) routes by the
  `.kiln-dir-id` each node's heartbeat reports, and until now only an
  in-app backup created that file. A cron-only cluster reported no ids, so
  each 15-minute slot synced one directory, whichever node fetched the job,
  and a host could go any number of slots without a marker; its
  `backup.sh prune` then kept only the newest complete set. Now:
  - **The heartbeat creates the id.** While the sync is scheduled, each
    node's heartbeat (every 30 seconds) gives its `BACKUP_DIR` a
    `.kiln-dir-id` when it has none, but only when the directory already
    holds backups (a `db/` or `media/` subdirectory), so the empty
    `/var/backups/kiln` the image creates on every replica, or the
    mountpoint of a failed mount, never gets one. With
    `KILN_BACKUP_MARKER_SYNC_CRON=false` no id is created; only an in-app
    backup creates one, as before.
  - **Each slot covers every live directory.** The node that fetches the
    job syncs its own directory in place, and queues one sync for every
    other id reported by a beat of the last 10 minutes. Each of those waits
    for a node that reads its id, putting itself back every 30 seconds up
    to 20 times. So a host's directory is synced in a slot as long as its
    node picks up one of the about 21 releases of its job in those
    10 minutes, the same assumption every backup step makes; a host whose
    node is down is synced again once its node beats.
  - **Liveness is judged on the database's clock.** The 10-minute window
    was computed from the node's own clock, so a node whose clock ran ahead
    saw no live beats and fell back to syncing only itself.
  - **The id is published whole.** It is written to a temporary file,
    synced and hard-linked into place, so no reader sees an empty id and
    nodes racing on a shared volume settle on one. A filesystem without
    hard links falls back to an exclusive create. This applies to the id an
    in-app backup creates too.

  Operators:
  - **The app must be able to write `BACKUP_DIR`.** If it can't, the server
    log says, once per boot for each error, "Backup heartbeat: no id for the backup
    directory `<dir>` (`<reason>`)…", and that directory is synced only in
    the slots its own node fetches the job.
  - **A cloned backup directory now always carries an id.** Copying one to
    another host (`rsync`, a volume snapshot) copies `.kiln-dir-id`, and
    the two then look like one directory: the copy is never routed to on its
    own. Leave the file out (`rsync --exclude .kiln-dir-id`) or delete it on
    the copy.
  - **Rolling back** is safe: there is no migration, and an older release
    reads the ids the heartbeat created as an in-app backup would have
    written them.

  Developers: `KilnCMS.Backups.DirId.ensure_existing/1` creates the id
  only in a directory that holds backups;
  `KilnCMS.Backups.MarkerSyncWorker.enabled?/0` says whether the sync is
  scheduled; the `NodeBeat` read action `:live` (code interface
  `Backups.list_live_node_beats/2`) returns the beats of the last
  `within_s` seconds on the database's clock. See
  [The last-good marker](../backups.md#the-last-good-marker). (#2789)

<a id="cron-killed-run-recovery"></a>

- **A cron backup killed outright (`kill -9`, the OOM killer, a power cut) now shows in History as a failed "Interrupted" run, and its `.partial` files are cleared, with no one stepping in.**
  Such a run leaves its `.partial` files behind, among them the media
  marker `kiln-media-<stamp>.sha256.partial`. Only the app's in-app backup
  ever removed them, so on a host where only cron takes backups the stamp
  stayed "pending" in History forever and the marker had to be deleted by
  hand (a 1.9.0 known issue). Now:
  - **A live run keeps its files fresh.** `backup.sh db`, `media` and `all`
    start a background loop that touches every `.partial` of the run's
    stamp every 5 minutes and stops when the script exits, so a slow run is
    never taken for a dead one. A loop orphaned by a kill stops at its next
    pass.
  - **History records it after 3 quiet hours.** The importer
    (`KilnCMS.Backups.Importer`) keeps a stamp with a `.partial` beside it
    pending while any of its files, partial or finished, changed in the
    last 3 hours (`Importer.interrupted_after_s/0`). After that it imports
    a **Failed** run, "Interrupted: the backup stopped before it finished
    and left .partial files behind", with the finished files as artifacts,
    the kinds of all its files as components, and a log line naming up to
    five leftover files. A stamp with only partials (killed in its first
    file) is recorded too. A file dated more than 5 minutes in the future
    keeps the stamp pending, with a warning naming it. The row is never
    rewritten, which is why the wait is long.
  - **`backup.sh prune` clears the partials after 12 quiet hours**, once
    every file of the stamp in `db/` and `media/` is that old, unless
    `.work/<stamp>/` exists; a recovery point does not keep them, since
    `restore.sh` refuses a set with a `.partial` beside it anyway. With the
    nightly cron that is within one prune cycle; with an hourly cron about
    twelve. The stamp's finished files age under `BACKUP_KEEP_DAYS` as
    before.
  - **`backup.sh all` opens the media marker before the dump**, when
    `MEDIA_DIR` is set, so a run killed in its database phase or the dump's
    off-site copy is recognized as interrupted instead of imported as a
    succeeded database-only backup, and `backup.sh verify` skips that
    stamp's media while the dump runs.
  - **The in-app backup reads the stamp before it sweeps.** Its start step
    runs the importer first, then removes the `.partial` files only of a
    stamp that has a History row once every file of the stamp is over an
    hour old. A cron leftover with no row waits for the importer. A
    `.partial` whose name carries no stamp is still removed after an hour.
  - **If the stamp was never read** (the marker sync off and nobody opening
    the Backups page, or the host's app down more than 12 hours after the
    kill), prune removes the marker first and the leftovers import as what
    they are: media parts with no sidecar as failed "incomplete media set:
    parts but no sidecar", a single finished archive or a finished dump
    alone as succeeded.
  Read the [upgrade note](#cron-killed-run-recovery-upgrade): replace
  `backup.sh` on every host. See
  [When a cron run is killed outright](../backups.md#when-a-cron-run-is-killed-outright-2478).
  (#2478)

<a id="resume-behind-queued-resume-already-fixed"></a>

- **The 1.9.0 known issue "Resume on a failed backup says it is queued but never runs" was already fixed in 1.9.0.**
  1.9.0 listed it as open, but #2688 in that release made a Resume asked for
  while a backup runs and another run's resume is queued be refused with
  *A backup is running and a resume of `<stamp>` is queued after it, so this
  resume was not queued. Try again once the queue clears.* It names the
  queued run, and the queue is left as it was. Once the queued resume starts,
  the refused one can be asked for again. Nothing changes on upgrade; a test
  now pins the whole sequence. (#2671)


<a id="release-eval-read-through"></a>

- **`bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'` runs again: release tasks under `eval` read through the content cache instead of crashing.**
  1.9's upgrade note asks operators to run `reserved_paths/0` in a release,
  and the documented `eval` form raised `ArgumentError` (no
  `:cachex_overseer_table`). `eval` starts only the repo
  (`Ecto.Migrator.with_repo/2`), and the audit's slug lookup reads through
  `KilnCMS.Cache`. Every task's `load_app` now turns the cache off when the
  app is not serving (`read_through_unless_serving/1`), so any `eval` task
  reads the database directly. Called over `rpc` on a running node, the live
  cache is untouched. Found on Verscienta's production upgrade to 1.9.2.

<a id="featured-image-older-than-picker-window"></a>

- **The editor's Featured image field shows an image older than the org's 500 most recent uploads, with its Remove link.**
  The Settings tab looked the attached image up only in the media picker's
  window (the 500 newest images), so on a large library an older featured
  image showed **None selected**, with no thumbnail and no **Remove** link,
  though the record, the API and the site all had it. Editors could take the
  record for imageless and pick a duplicate, and could not clear the image
  without first choosing another. The field now resolves the image the way
  the editor's preview already did: the window first, then the database.
  Saving never lost the image; only the display was wrong.

<a id="image-build-retries-downloads"></a>

- **The image build retries a failed release-asset download with backoff, so a few minutes of 504s from GitHub's release CDN no longer fail it.**
  Building the Dockerfile downloads the precompiled NIFs of y_ex, lazy_html
  and vix (and tokenizers in a `KILN_ML=1` build), vix's libvips tarball and
  the tailwind binary from GitHub releases, and the esbuild binary from npm.
  The builder can't build any of them from source, and each tool retries
  for only a few seconds, so a short 504 window failed the build, in CI's
  image jobs, in the release workflow and on an operator's own `docker
  build`. Both `mix deps.compile` steps and the tailwind and esbuild installs
  now run under `rel/docker/retry_download.sh`, which runs the step again
  after 15, 30, 60 and 120 seconds when its output ends in a download error.
  A compile error or any other failure still fails at once.
  - **If you build the image yourself:** nothing to change. An outage longer
    than about 4 minutes still fails the build, and it now takes that long
    to do so, for each wrapped step. A download that can never succeed (a 403,
    a rate limit, a 404 after a dependency bump) also fails about 4 minutes
    later than before, because the fetchers' messages name the URL, not the
    status. To shorten or lengthen the wait, set `KILN_FETCH_ATTEMPTS`
    (attempts in all, default 5) or `KILN_FETCH_BACKOFF` (first wait in
    seconds, doubling, default 15) in the `RUN` step's environment; there is
    no build arg for them.
  - The tailwind and esbuild binaries are now fetched in their own layer
    right after the deps, with `--if-missing`, instead of inside
    `mix assets.deploy`. That layer is cached with the deps, so a build that
    changed only application code no longer downloads them.
  - The script is removed from the builder before `mix release`, and never
    reaches the runtime image. See
    [Building the image](../deploy.md#building-the-image). (#2462)

<a id="backups-page-markers-and-queue-help"></a>

- **The Backups page shows recovery points and last-good markers, explains the backup queue, and no longer offers Cancel on a backup that is finishing.**
  Whether a backup was pinned by a `kiln-<stamp>.keep` recovery point, or
  named by the `kiln-<stamp>.good` marker that `backup.sh prune` keeps, could
  only be seen by listing `BACKUP_DIR` on the host. In **History**, a row now
  carries a **Recovery point** badge when a `.keep` for its stamp is in `db/`
  or `media/`, and **Last good: Database** / **Last good: Media** for each
  component whose `.good` names it. Above the list, **Last-good marker (kept
  by backup.sh prune)** shows the stamp each backed-up component's marker
  names, or "none yet", so the marked backup is visible even when it is on
  another page. The markers are read from this server's backup directory each
  time History loads, never stored; with a directory per host, another server
  may show different ones. A `db/` or `media/` the app cannot list shows no
  markers, and the page still loads. Help text explains both markers and the
  15-minute default marker sync (`KILN_BACKUP_MARKER_SYNC_CRON`).
  **Back up now** now has help saying that a backup asked for while another
  runs waits, only one waits, and a request of a different kind or a resume
  of a different backup is refused until the queue clears (#2540). On a
  History row, **Cancel** disappears once that backup is finishing, as it
  already did on the in-flight strip; clicking it there was refused with "Too
  late to cancel". **Resume**'s tooltip says whether the backup was canceled,
  failed or interrupted, and the trigger reads **Manual**, **Cron** or
  **Console** instead of the raw value. No migration and no configuration.
  See [Backup history](../backups.md#backup-history-2217). (#2542)

<a id="media-trash-stale-actions"></a>

- **The media library's trash no longer permanently deletes a file someone restored after the list loaded, and its Restore and Delete permanently say what happened when someone else got there first (#2610, #2611).**
  Two gaps left by #2531, which gave content's Trash page this handling and
  gave media only part of it.
  - **A restored upload could still be deleted (#2610).** `:purge` deleted
    any row still quarantined as well as any trashed one, for the media
    pipeline. So a file trashed while its upload was still being processed,
    then restored by another admin, was hard-deleted, with its stored
    original, variants and cached transforms, when someone clicked
    **Delete permanently** on the stale row. That click is now refused and
    every file kept. The pipeline purges through its own action (see
    [Breaking](#media-purge-quarantined)).
  - **Restore on a stale row (#2611).** `:restore` took any row, so
    **Restore** on a file another admin had already restored "succeeded" and
    flashed *Restored …*, and on one someone had deleted for good it said
    *You don't have permission to restore media.* It now acts only on a file
    still in the trash.
  - **What admins see** in **Media** → **Trash**: **Restore** or **Delete
    permanently** on a file someone else restored says *Someone else already
    restored that item.*; on one someone permanently deleted it says *That
    item is no longer in the trash — someone permanently deleted it.* These
    are the Trash page's messages, and they replace *That item is no longer
    in the trash — someone else restored or deleted it.* The trash list
    reloads either way. A refusal by the policy keeps *You don't have
    permission to restore media.* / *…to delete media.*; any other failure
    now says *Couldn't restore that item.* / *Couldn't delete that item.*
    instead of the permission message, and the row stays listed.

  No migration and no config. Guide:
  [Trash and restore](../trash.md#what-can-go-wrong).

<a id="database-url-ecto-scheme"></a>

- **The in-app backup, the demo reset and the backup, restore and staging scripts accept an `ecto://` database URL.**
  libpq (`pg_dump`, `pg_restore`, `psql`) reads a string as a connection URI
  only when it starts with `postgres://` or `postgresql://`. `ecto://` is the
  form `DATABASE_URL` is documented in, and the default in
  `docker-compose.prod.yml`, but every `pg_*` call passed it on unchanged, so
  libpq took the whole string as a database name on the local socket and
  every dump failed: each in-app backup and demo reset on a default compose
  deployment, and the cron `backup.sh` given that same `DATABASE_URL`. With
  a query string (`?sslmode=require`) libpq failed differently, with
  `invalid connection option`. Now a leading `ecto://`, in any case, is
  rewritten to `postgres://` and nothing else in the string changes. That
  covers `DATABASE_URL` and `BACKUP_DATABASE_URL` for the in-app backup and
  the demo reset, `DATABASE_URL` for `backup.sh`, `RESTORE_DATABASE_URL`
  for `restore.sh`, and `PROD_DATABASE_URL` and `STAGING_DATABASE_URL` for
  `staging.sh`.

  Ecto-only query parameters are not translated. libpq refuses
  `pool_size=10`, `ssl=false` and the like with
  `invalid URI query parameter: "pool_size"`; it happens to read `ssl=true`
  itself, as `sslmode=require`. If your `DATABASE_URL` carries one, give the
  in-app backup a `BACKUP_DATABASE_URL` without it, and the script a
  `DATABASE_URL` in libpq's form. See
  [Which database URL the backup tools accept](../backups.md#which-database-url-the-backup-tools-accept-2719).

  Developers: `KilnCMS.Backups.PgUrl` holds the rewrite (`normalize/1`) and
  the password split (`split/1`). `KilnCMS.Backups.database_url/0` now always
  returns a URL libpq reads as one. (#2719)

<a id="backup-keep-days-validated"></a>

- **`backup.sh` reads `BACKUP_KEEP_DAYS` the way the app does.**
  The script used the value unchecked. `BACKUP_KEEP_DAYS=14d` made
  `find -mtime +14d` fail on Linux into `/dev/null`, so nothing was ever
  pruned and nothing warned, and wrote `"keep_days": 14d` into
  `manifest.json`, which is not JSON, so the Backups page and the
  importer could not read that run. `0` pruned every backup older than a
  day, where the app refuses 0. The script now reads it like
  `KilnCMS.Config.Env.positive_integer/1`: surrounding whitespace is ignored,
  blank means 14 silently, a whole number from 1 to 2147483647 is used (an
  optional `+` and leading zeros are accepted, and the manifest gets the
  plain number), and anything else (`0`, `-1`, `14d`, `1.5`, `2147483648`)
  keeps 14 and writes
  `BACKUP_KEEP_DAYS=<value> is not a whole number of days from 1 to 2147483647; using 14`
  to stderr. Only `backup.sh all` and `backup.sh prune` read it. The app's
  `KilnCMS.Backups.Manifest` also reads a `keep_days` of 0 or below as
  absent. If you set either `0` or a value with a unit, read the
  [upgrade note](#backup-keep-days-upgrade) first. (#2727)

<a id="cache-fetch-in-transaction"></a>

- **A cached read made while the caller holds a database connection no longer needs a second one.**
  On a cache miss, `KilnCMS.Cache.fetch/3` and the published-content fetches
  (`fetch_published/5`, `fetch_published_payload/5`) ran the fallback on a
  Cachex courier process, which deduplicates concurrent misses on one key.
  The courier has no connection of its own, so a fallback that reads the
  database checked out a second pool connection while the caller still held
  its first. Many write paths do exactly that: an action's `after_action`
  hook, inside the write transaction, reads a cached setting. Examples are the
  site branding in a newsletter confirmation mail or an invitation mail, and
  the content-type registry. Under load, transactions waiting on connections
  that only finishing transactions give back can exhaust the pool or deadlock.

  Now, when the caller holds a connection (inside `Repo.transaction/2` or
  `Repo.checkout/2`, checked with `KilnCMS.Repo.checked_out?/0`):

  - **A cache hit is served as before**, read from the store before anything
    asks the Repo.
  - **A miss runs the fallback in the caller**, on the connection it already
    holds, and the result is **not stored**: it may come from an uncommitted
    transaction that is about to roll back. The next read outside a
    transaction fills the cache.

  Outside a transaction nothing changed: the courier computes the miss and
  stores it. There is no setting; the rule is the same one
  `KilnCMS.CMS.Severity` and
  `KilnCMS.Compliance.Settings.for_org_uncached/1` already followed for their
  own reads.

  The trade-offs:

  - Concurrent misses inside transactions are no longer deduplicated, and a
    write path re-reads the source on each miss until a read outside a
    transaction fills the cache. Only write traffic pays this.
  - **A fallback query that fails at the SQL level now aborts the caller's
    transaction**, where on the courier it failed only the fallback. A
    fallback that rescues the error and degrades still leaves the transaction
    aborted, so the write fails at its next statement or at commit with
    Postgres error `25P02` (`in_failed_sql_transaction`). If you see a log
    line such as `branding lookup failed, serving the fallback for this
    request: …` just before a write's `25P02`, it is the cause.
  - `KilnCMS.Security.AdminAllowlist` no longer records its last-known
    allowlist from a read made inside a transaction, since a rolled-back row
    would otherwise be kept as the newest list and the real one declined.

  No migration and no configuration; rolling back is safe.

  Developers: a fallback passed to `KilnCMS.Cache.fetch/3` may now run in
  the calling process, so it must not depend on running elsewhere. In
  particular, take the actor before `KilnCMS.OrgSettings.resolve/2`, as its
  moduledoc already says: a resolver that read a process-local actor inside
  its fallback would pass inside a transaction and fail everywhere else. In
  tests, the SQL sandbox used to drop the courier's checkout after about a
  second and serve the fallback, so a mail rendered inside a transaction
  carried the fallback site name. That stall is gone (in a full suite run,
  83 "lookup failed, serving the fallback" lines became 0, and the suite
  runs about 74 s faster), and a test that reads a cached setting inside a
  transaction no longer needs the shared sandbox or `async: false` for it.
  `InvitationMailTest` is async now. (#2823)

<a id="custom-field-value-shapes"></a>

- **An object, or a list where one value goes, sent for a single custom field is a field error naming the field, not a 500 (#2743).**
  A write coerced a single `text`, `string`, `url`, `select`, `integer`,
  `float`, `date` or `datetime` field's value with `to_string/1`, so an
  object (`"custom_fields": {"subtitle": {"en": "x"}}`, a map of locales
  sent to a field, which is one value per locale record) raised and the
  JSON:API `PATCH`, the GraphQL mutation and the MCP `update_*` tool all
  answered 500. A list on a single `text` field was joined into one string
  (`["a", "b"]` became `"ab"`). Now an object, an empty list, and any list on
  a single `text` or `boolean` field fail the field with
  `<Label> (<name>) must be a single value, not an object or a list`, the
  message a group's sub-field already gave:

  - **JSON:API**: `400` `invalid_attribute`, `source.pointer`
    `/data/attributes/custom_fields`.
  - **GraphQL**: `result: null` and the message in `errors`.
  - **MCP**: a tool result with `isError: true` (HTTP 200).

  Nothing is written. `null` and `""` still clear a field, and a number or a
  boolean sent to a text-like field is still stored as its text (`42` as
  `"42"`). A non-empty list on a single `string`, `url`, `select`, number or
  date field still keeps its first item (1.9.0's
  [#2497](https://github.com/The-Verscienta/kiln_cms/issues/2497)). A
  reference's link values follow the same rule, and the error names the
  item: `item 1 “Flour”: Role must be a single value, not an object or a
  list`. A copy or a version restore holding such a value is refused with
  the same message instead of crashing. A `float` field now parses text
  with `Kiln.FieldType.parse_float/1`, as filter operands already did, so
  `"1e400"` is `must be a number`. The built-in format types and plugin field types decide in their
  own `cast/2`, as before. Which of these requests used to succeed is under
  [Breaking](#custom-field-api-stricter-shapes).

  Developers: the type-only coercion moved out of
  `KilnCMS.CMS.Changes.ApplyCustomFields` into the new
  `KilnCMS.CMS.FieldValue` (`coerce/2`, `text/1`, `canonical/2`,
  `not_single/0`), which writes and filter operands now share.
  `ApplyCustomFields.coerce_item/2` keeps its signature. `FieldValue` is core
  internals, not part of the overlay contract. Guide:
  [json-api.md](../json-api.md) → "A single custom field takes one value".

<a id="custom-filter-operand-shapes"></a>

- **A custom-field filter operand of the wrong shape is a `400 invalid_argument` naming the operator and the field, not a 500 (#2739).**
  The [crash fixes](#sweep-crash-fixes) earlier in this release made an
  object operand on a single field's comparison a `400`. The other paths still called
  `to_string/1` on what the client sent: `ilike` on a link field
  (`custom_filter[cta.link.label][ilike][x]=1`), a list of objects beside
  `ilike` from GraphQL `customFilter` or an MCP read tool, and a media or
  reference id. Lists of values took a date object through an Ecto cast and
  answered `200`. Now every path checks the shape first, on JSON:API
  `custom_filter`, GraphQL `customFilter` / `customWhere` and the MCP
  `read_pages`, `read_posts` and `read_entries` tools (`custom_filter` and
  `custom_where`):

  - an object operand: `<op> on custom field "x" takes a value, not a nested filter`;
  - a list beside any operator other than `in` (on a list of values, also
    `has`, `has_all` and `has_none`): `<op> on custom field "x" takes one
    value, not a list`;
  - an object or a list as one item of `in`: the same two messages, with `in`;
  - on a link field the subject reads `link field "cta.link.label"`.

  A `null` operand for `ilike`, or for a media or reference `eq` / `not_eq`,
  is `invalid value for custom field "x"`. A number or a boolean is still
  read as its text by `ilike` and `eq`. The requests that answered `200`
  before and are refused now are listed under
  [Breaking](#custom-field-api-stricter-shapes). Guide:
  [json-api.md](../json-api.md) → "Custom fields", "One value per operator".

<a id="custom-filter-operands-tidied"></a>

- **`eq`, `not_eq` and `in` on a field whose save tidies the value also match the operand as the save would store it, which resolves the 1.9.0 known issue "A custom filter on an email, color, telephone or time field misses values written another way" (#2677).**
  A save stores some values tidied: a string or URL trimmed, a select's
  label as its option's value, and the canonical spelling of an email
  (domain lowercased), color (`#ffffff`), telephone (`+442079460958`), time
  (`09:30`) or slug (`hello-world`). A typed list of values already tidied
  its filter operands (#2289); a single field compared them as sent, so
  `custom_filter[accent]=#FFF` missed a stored `#ffffff`. Now, on a single
  string, URL, select, email, color, telephone, time or slug field, and on a
  string, URL or select link field, `eq` (or a bare value), `not_eq` and
  each item of `in` match the operand **both** as sent and as a save would
  store it. On GraphQL that is `customWhere`'s `string: {eq, notEq, in}` and
  `customFilter`. So `#FFF` finds `#ffffff`, `a@Example.com` finds
  `a@example.com`, `+44 20 7946 0958` finds `+442079460958`, `9:30` finds
  `09:30`, and a select option's label (any letter case) finds the option:
  select filters now match by label as well as by value.

  Matching the spelling sent as well keeps every match that worked before:
  a value stored before its field's type changed (a string field holding
  `#FFF`, since made a color field) is still found by `#FFF`. The cost is
  on `not_eq`, which leaves out both spellings and so can exclude records it
  used to return ([Breaking](#custom-field-api-stricter-shapes)).

  Unchanged: range operators (`gt`, `gte`, `lt`, `lte`) and `ilike`,
  `contains` and `starts_with` take the operand as sent (a time's tidy drops
  its seconds, which would move a range bound), `text` fields and plugin
  field types compare the operand as the text sent (the `Kiln.FieldType`
  contract does not promise a deterministic `cast/2`), and an operand the
  field could never hold (`foo` on an email field) matches nothing rather
  than answering `400`. Date-times are not tidied here: the 1.9.0 known
  issue about fractional seconds
  ([#2678](https://github.com/The-Verscienta/kiln_cms/issues/2678)) is still
  open. No migration and no config. Guide: [json-api.md](../json-api.md) → "Custom fields",
  "Equality operands also match the value as a save stores it".

<a id="restored-event-next-occurrence"></a>

- **Restoring an event from the trash recomputes its next occurrence, which resolves the 1.9.0 known issue "A restored event can show a stale next occurrence" (#2621).**
  `next_occurrence_at` depends on the current time, and the recompute pass
  (`mix kiln.occurrences.backfill` and the boot job) reads live rows only,
  so an event trashed before it ran came back with a stale or empty date and
  sat in the wrong place in, or missing from, the what's-on listing until
  someone saved it. The `:restore` action now recomputes the date from the
  event's own schedule, as a save does. The pass still skips the trash: a
  date written into a trashed row would be stale again by the time it came
  back. No migration and no config. Guide: [Trash](../trash.md#restore-a-document).

<a id="ics-until-end-of-local-day"></a>

- **Calendar clients no longer drop or add the last occurrence of a timed repeating event with an end date.**
  A timed event's `.ics` `RRULE` gave `UNTIL` as 23:59:59 **UTC** on the end
  date, while Kiln includes the whole end date in the event's own zone
  (#2751). West of UTC the last occurrence fell after that instant and
  clients dropped it (a 20:00 New York series ending 3 March); east of UTC
  clients could show one more on the next day. `UNTIL` is now the last
  second of the end date in the event's zone, in UTC
  (`UNTIL=20260405T225959Z` for a London event ending 5 April, on summer
  time). All-day events keep the DATE form, and an event whose zone the
  server doesn't know falls back to it rather than failing the feed. Only
  the exported rule changes; stored rules and Kiln's own dates don't.
  Subscribers see the fix at their next refresh. Guide:
  [Events](../events.md#calendars).

## Security

<a id="backup-scripts-password-out-of-argv"></a>

- **`backup.sh`, `restore.sh` and `staging.sh` keep the database password off the command line and out of what they print.**
  A process's arguments are readable by any user on the host
  (`/proc/<pid>/cmdline`, `ps`) for as long as it runs. The scripts passed
  the whole database URL, password included, as an argument to `pg_dump`
  (`backup.sh db` and `all`, `staging.sh up`), `pg_restore` (`restore.sh db`
  and `drill`) and `psql` (the drill's checks, `staging.sh up`). They now
  take the password out of the URL and give it to that one command as
  `PGPASSWORD`, set in a subshell around it, so `rclone`, `tar`, `curl` and
  the rest of the run never see it. `staging.sh up` gives `pg_dump` and
  `psql` each their own URL's password. The in-app backup already did this.

  The URL is read the way libpq reads it: the user and password end at the
  first `@` before the first `/`, so an `@` in the password must be written
  `%40`; percent-escapes in the password are decoded. A `password=` query
  parameter is moved too (even as `pass%77ord=`), and wins over a password in
  the user part, as it does in libpq. A URL with no password is left as
  written, so your own `PGPASSWORD` or `~/.pgpass` still applies. A
  `key=value` connection string (`host=db password=… dbname=kiln`) is passed
  through unchanged, password included: use a URL.

  Nothing prints the password any more either. `restore.sh drill`'s hint
  for scrubbing the drill database, and `staging.sh up`'s closing
  `DATABASE_URL=` line, print the URL without it and say so. Before, a cron
  `backup.sh` given an `ecto://` `DATABASE_URL` failed with a libpq error
  that quoted the whole URL, password included, into the cron log
  (`database "ecto://user:password@host/db" does not exist`); rotate that
  password if such a log was kept or shipped anywhere. See
  [The database password stays out of the pg_dump command line](../backups.md#the-database-password-stays-out-of-the-pg_dump-command-line-2726).

  Developers: `KilnCMS.Backups.Steps.split_credentials/1` keeps its
  signature, and now returns the URL rewritten from `ecto://`, moves a query
  `password=` as well, and no longer raises on a malformed `%` escape (it
  stays literal). The three scripts carry identical copies of
  `pg_conn_split`, tested against the same table of URLs as
  `KilnCMS.Backups.PgUrl.split/1`; the run under macOS's `/bin/bash` 3.2 is
  skipped on Linux CI. (#2726)

<a id="crawler-verification-hardening"></a>

- **Crawler verification holds up better against lookup starvation, cache churn and silent reverse zones (#2588).**
  #2254's verifier was bounded, but an attacker could still keep real
  crawlers unverified for longer, or keep a fake one exempt from the smart
  404 guard. None of this could push a real crawler below the browser
  ceiling; it mattered when an operator set the search-engine value above
  100% (the default is 200%), or had the 404 guard on.
  - **A busy start no longer spends the lookup budgets.** The per-network
    caps (IPv4 `/24`, `/16`; IPv6 `/64`, `/48`, `/32`) and the node's 600 a
    minute are charged before a lookup starts. When it then cannot start
    because all 16 lookup slots are busy, it gives back every charge it made,
    so a flood of turned-away starts no longer uses up a network's or the
    node's budget. A refund only applies in the minute the charge was made;
    a charge that straddled a minute boundary is kept. If a refund cannot be
    made, a warning is logged once per node ("Crawler verification could not
    refund a rate-limit charge ...") and the lookup keeps its charge. A start
    refused by a cap keeps its charges, as before.
  - **Verified crawlers keep their results.** Confirmed names now live in a
    cache of their own (10,000 addresses per node), separate from the 50,000
    rejections and DNS errors. An attacker rotating through IPv6 addresses
    can only write rejections, so it can no longer evict a real crawler's
    result (about 80 minutes of rotation used to be enough). One exception:
    a lookup that confirmed one name but got no answer for another is still
    judged verified, but is kept for 5 minutes, as before, in the larger
    cache, where a flood can evict it.
  - **A silent reverse zone counts toward the 404 guard.** See the
    [upgrade note](#crawler-verification-silent-ptr-upgrade).
  - **New reason `forward_error`.** A claim whose PTR names a host under the
    engine's domain, and whose forward (A/AAAA) query for that host got no
    answer although it had a full per-query budget (1 second), is now
    `{:unverified, :forward_error}` from `KilnCMS.CrawlerVerification.check/3`
    and `reason="forward_error"` on
    `kiln_cms_delivery_unverified_crawler_count`. Rate limiting treats it
    like `error` (search engine, held to the browser limit); the 404 guard
    keeps its exemption. A forward query squeezed by a slow PTR answer is
    still `error`. Dashboards that list reasons should add it; see
    [Observability](../observability.md#crawler-verification).
  - **Developers.** New `KilnCMS.CrawlerVerification.resolver_failing?/1`
    (never waits on DNS), `KilnCMSWeb.RateLimit.window_index/1` and
    `KilnCMSWeb.RateLimit.refund/3` (gives back one fixed-window charge,
    floored at zero, only while that window is current). New config keys on
    `config :kiln_cms, KilnCMS.CrawlerVerification`: `:max_verified_entries`
    (10,000), `:health_window_ms` (60,000) and `:canary_address`
    (`{8, 8, 8, 8}`). No environment variable and no migration.
  - **Still open.** A claim whose lookup is pending or was skipped keeps the
    404 exemption, so a spoofer rotating addresses inside one IPv6 `/64`
    stays exempt once the `/64`'s 30 lookups a minute are spent; several
    rented networks can still spend the node's 600 lookups a minute with
    real lookups; and published IP ranges are not read yet (#2586). See
    [the threat model](../threat-model.md#bot-budgets).

<a id="token-paths-redacted-from-request-log"></a>

- **Credential tokens in sign-in, invitation, preview and newsletter links are redacted from the request log and not recorded as missed paths.**
  A magic sign-in link, password reset, account confirmation, site
  invitation, sign-in unlock, preview link and newsletter confirm or
  unsubscribe link each carry their secret in the URL path. Phoenix's
  request line (`GET <path>`, at `:info`) wrote that path out whole, token
  included, so anyone who could read the request log could follow the link
  while it was still valid; `:filter_parameters` filters params maps, never a
  path. A mangled link (`/magic_link/<token>/x`) also fell through to the 404
  catch-all and was stored in the missed-path list on `/editor/redirects`.

  Now the request line for such a path shows the token as `[FILTERED]`
  (`GET /magic_link/[FILTERED]`, `GET /fr/preview/[FILTERED]/live`), and a
  path that starts with one is never recorded as a missed path. Every other
  request line is unchanged, and the `Sent <status> in <duration>` line is
  still Phoenix's. The redacted start line is written by
  `KilnCMSWeb.RequestLog` from the request process, so it carries the same
  `request_id` metadata as before.

  The set of credential routes is read off the router, not kept as a list: a
  route whose parameter name contains `token` or `secret` is one, so a new
  token route, in the core or a plugin, is covered without a change here. The
  match over-redacts on purpose: it is tried at the first and second path
  segment because the line is written before the locale prefix is stripped,
  so a path that only resembles a token route one segment in
  (`/products/magic_link/old-page`) is logged with its last segment as
  `[FILTERED]`. If the router cannot be read, it fails closed: every request
  line is `<METHOD> /[FILTERED]`, nothing is added to the missed-path list,
  an error is logged, and it retries after 30 seconds. See
  [Request log lines for token links](../observability.md#request-log-lines-for-token-links).

  Operators: nothing to configure, no migration. Request logs written before
  this release still hold the tokens of the links they recorded; most have
  expired, but treat those logs as sensitive until they age out. Missed-path
  rows already stored are not touched: an admin can remove one that holds a
  token with its remove button (the x, "Remove … from the 404 list") on the
  **404s** tab of `/editor/redirects`; otherwise it is purged 30 days (the
  default `retention_days`) after its last hit.

  Plugin authors: name a path parameter that carries a credential with
  `token` or `secret` in it. Routes below a `forward` (a plugin's
  `{:forward, …}` plug route included) are not seen, so a forwarded router
  must keep credentials out of its paths; see "Credentials in the path" under
  Plug routes in [Plugin extensibility](../plugin-extensibility.md).
  New public functions: `KilnCMSWeb.RequestRedaction.redact/2`,
  `redact_path/1`, `secret?/2`, `credential_param?/1`. (#2449)
