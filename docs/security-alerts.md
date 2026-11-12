# Security alerts

The [security log](security-events.md) records what happened. Security alerts
tell someone while it still matters: a new admin, a lockout, two-factor turned
off, a changed single sign-on provider, a stolen API key used again (#2245).
Each alert arrives as a bell notification and an email, and a site can also
send its alerts to a webhook.

Alerts are built on the security log. Nothing records an alert on its own: an
event is written to the log, and if it is one of the kinds below it raises an
alert in the same database transaction. An event that rolls back raises
nothing.

## What raises an alert

There are two channels. A **site** alert is about one site and goes to that
site's own admins, who can turn each kind off. A **platform** alert is about
the whole installation and goes to every platform admin. Nobody can turn a
platform alert off or mute it.

Site alerts (each one can be turned off on the site's
[Security alerts](#choose-which-alerts-your-site-sends) page):

| Kind | Label on the page | Raised when | On by default |
|---|---|---|---|
| `new_admin` | New admin | Someone becomes an admin of the site: a membership created or raised to admin (by a platform admin on Team, or by accepting an invitation), a temporary admin grant on the membership, or a registration approved as admin | Yes |
| `role_elevation` | Role raised | A member's role is raised below admin (viewer to editor), or a member is given a temporary role below admin | Yes |
| `failed_sign_ins` | Failed sign-ins | The site reaches **10 failed sign-ins in one 15-minute window** (see [Failed sign-ins](#failed-sign-ins-are-counted-per-site)) | **No** |
| `lockout` | Account locked out | A sign-in throttle locks an account or an address out: too many wrong passwords or second-factor codes | Yes |
| `two_factor_disabled` | Two-factor authentication turned off | Someone removes the second factor from their account | Yes |
| `sso_config_changed` | Single sign-on changed | The site's identity provider or a single sign-on domain is saved, verified or removed | Yes |

Platform alerts (always on):

| Kind | Raised when |
|---|---|
| `new_admin` | An account's own role is set or raised to admin (a platform admin), standing or by a temporary grant |
| `platform_role_changed` | A platform admin's admin role is taken away: lowered, or a temporary admin grant ended early or replaced by a lower one |
| `new_api_key` | An API key is minted. Rotating a key into its successor is not an alert |
| `api_key_abuse` | A rotated-away API key is presented to `POST /api/keys/rotate` again more than 120 seconds after its rotation: two parties held the key, and Kiln revoked the whole chain ([self-rotation](headless-consumer-guide.md#keeping-the-key-alive-self-rotation)) |

### What does not raise an alert

- **A platform role raised short of admin.** It is no site's business, and
  the platform kinds have no role elevation of their own.
- **An invitee taking over an unconfirmed account.** Accepting an invitation
  over an account someone registered but never confirmed removes that first
  registrant's second factor (#2453). It is recorded in the security log as
  `second_factor_removed` with `via` `invitation`, but it is not the owner
  turning their protection off, so it raises no `two_factor_disabled`.
- **A legacy account keeping its tier.** When an account from before
  multi-site memberships gets its first membership, its standing role is
  copied onto it (`via` `legacy_carry`). It gains nothing, so it is not a new
  admin.
- **Erasing a site admin.** Erasure writes no role event, so it raises
  nothing.
- **Every other security event**: sign-ins, invitations, passkeys, recovery
  codes, API key revocations, the admin allowlist, other site settings,
  automatic address blocks. They stay in the log.

## Who hears about it

| | Bell | Email | Webhook |
|---|---|---|---|
| Site alert | Each **member admin** of the site (the platform admins when it has none), unless the site switched admin notifications off | The same people, except those who muted the email | The site's endpoints subscribed to `security.<kind>` |
| Platform alert | Every platform admin, in the **default site's** bell; other sites' consoles show only how many are unread | Every platform admin; no mute applies | None in this release |
| Silencing notice | Each member admin of the site (the platform admins when it has none) | The same people; no setting or mute applies | The site's endpoints subscribed to `security.alerts_silenced` |

A **member admin** is an account with an active membership on the site whose
role there is admin, standing or by a live temporary grant, that is not a
platform admin and has not been erased. Editors, viewers, admins of other
sites and anonymous visitors never get an alert.

Platform admins get platform alerts, not site alerts, even on a site where
they also hold an admin membership: on an installation with many sites they
would otherwise hear about every site's lockouts.

**A site with no member admins sends its alerts and notices to the platform
admins.** On a single-site installation the operator is often a platform admin
with no membership on the site; they are then the only admins the site has, so
its site alerts and silencing notices go to them, in that site's bell, and its
alert email follows their **Your settings** mute like a member admin's. The
Security alerts page says so: "This site has no admins of its own." As soon as
the site has a member admin, alerts go to its member admins only.

A platform alert's bell row lives in the default site, because the bell is per
site. A platform admin sees it in the bell and inbox while working in the
default site's console. In any other site's console, the bell and the inbox
show one entry instead, "3 unread platform alerts", with the line "Open them
in the default site's console". The entry links to the default site's unread
inbox, on that site's console host, where the alerts can be read and marked
read. The count is included in the bell's badge.

The entry is a number and nothing else: no site name, headline or address,
and no way to open or mark an alert from there. Another site's console is
that site's origin, where its own admin may be able to run script when no
console host is set (threat model residual risk 16, decision record 0011),
and platform alerts are about every site. The count is worked out from your
account as it is now, so a platform admin demoted while the page is open
sees no count at the next refresh, and an admin of the site who is not a
platform admin never sees one. Platform alerts raised before this release
are not counted: they are only in the default site's bell.

## How an alert arrives

- **Within about a minute.** The alert is claimed when the event is written,
  and a job that runs every minute delivers it.
- **The bell.** Headline "Security alert" (or "Security alerts were turned
  down" for a notice), titled with the site's name. It
  links to **Security log** (`/editor/security-log`); a notice links to
  **Security alerts** (`/editor/security-alerts`).
- **The inbox** (`/editor/inbox`) shows the same row with a one-line
  description such as "An account was locked out (from 203.0.113.0/24)", in
  the language of the console you read it in. A row written before this
  wording was translated shows its English line.
- **The email.** Subject "Security alert on (site): (what happened)". It says
  when (UTC), links to the security log on the site's own console host (a
  notice links to the Security alerts page), and says why you got it. Emails
  are in English, whatever language the console is in: an account stores no
  preferred language, and one admin can hold sites in several. They go through the
  installation's own mail relay, never a site's (see
  [For operators](#for-operators)).
- **Never a name or address of a person.** Neither the bell, the email nor the
  webhook carries an email address, a user agent, a secret or a webhook URL.
  The client's IP address is shown only as its network unless the site opted
  in (see [IP addresses in alerts](#ip-addresses-in-alerts)).

### One alert per kind every 15 minutes

Alerts are grouped into 15-minute windows aligned to the database clock (on
the quarter hour, UTC). The first event of a kind in a window raises the
alert. Later events of the same kind in the same window raise nothing more on
their own; about a minute after the window closes, a **summary** says how many
there were ("A new administrator: 4 in this alert window"). The summary is sent
only when there was more than the alert already said: more than one event,
or for failed sign-ins more than the 10 that crossed the threshold.

Windows are per site for site alerts, and one for the whole installation for
platform alerts. Silencing notices are never grouped: each one is sent.

### Failed sign-ins are counted per site

When `failed_sign_ins` is on, every failed sign-in on the site is counted:
a wrong password, a wrong second-factor code, a sign-in refused by
[human verification](human-verification.md). The count is per site, not per
address or account, which an attacker chooses: 40 attempts from 40 addresses
count the same as 40 from one.

The 10th failed sign-in in a window raises the alert, which names that
attempt's address. The window's total arrives in the summary. Because the
windows are fixed, 10 failures that straddle a quarter hour can stay under
the threshold in both windows.

A site with the kind off counts nothing. Turning it on takes effect at once on
every node.

The [security log samples failed sign-ins](security-events.md#failed-sign-ins-allowlist-and-unlock-refusals-are-sampled-lockouts-are-not)
(5 per address per 15 minutes). The attempt that crosses the threshold is
written to the log even past that cap, so the alert always has its event.

## Choose which alerts your site sends

You need the admin role on the site (a platform admin has it on every site).
Editors and viewers do not see the page and are refused if they open its
address.

1. Open **Security alerts** under **Organization** in the console sidebar,
   or go to `/editor/security-alerts`. You see three parts: **Alerts**,
   **Delivery** and **Not set here**.
2. Under **Alerts**, tick the kinds you want and untick the ones you don't.
   Each has a line saying what raises it. **Failed sign-ins** reads "10 failed
   sign-ins in 15 minutes on this site. Off by default."
3. Under **Delivery**:
   - **Notify this site's admins by bell and email**: untick it and the site's
     admins get no bell row and no email for site alerts. Webhooks subscribed
     to security events still receive them.
   - **Show the full IP address in alerts**: tick it to show the whole
     address instead of its network. A warning appears under it: full
     addresses are personal data, copied into every admin's inbox and every
     subscribed webhook, out of reach of the site's retention setting.
4. Select **Save**. You see "Security alert settings saved." If the save
   turned an alert off or switched off admin notifications, it says "Security
   alert settings saved. Every admin of this site has been sent a notice."
   (see [Silencing notices](#silencing-notices)).

The banner above the form says the same before you save: "Turning an alert off
or switching off admin notifications sends every admin of this site a notice.
That notice can't be turned off or muted."

Platform alerts are not on this page. The **Not set here** section lists them
and links to **Webhooks**, where an endpoint can subscribe to the site's
alerts (see [Send alerts to a webhook](#send-alerts-to-a-webhook)).

Saving the page is itself recorded in the security log, as
`org_setting_changed` with `setting` `site_security_alerts`.

## Mute the alert emails for yourself

Each member admin can stop the emails for site alerts without turning
anything off for the other admins.

1. Open **Your settings** (`/editor/settings`) and go to **Email
   notifications**.
2. Untick **Security alerts — email me about security events on sites I
   administer**. The line under it says what it does not mute.
3. Select **Save preferences**.

The mute is one switch for every site you administer, and it mutes only the
**email** of **site** alerts: the bell row is still written. It does not mute platform alerts or silencing notices, which are always
emailed. The switch is shown only to member admins of some site; a platform
admin, whose alerts are the platform's, does not see it. Only the account
holder can change it: a platform admin editing another account's preferences
is refused ("can only be changed by the account holder").

## Silencing notices

Some changes make alerts quieter, and an intruder with an admin's access would
make them first. Each of these sends the site's member admins an
`alerts_silenced` notice by bell and email, and to the site's webhooks
subscribed to `security.alerts_silenced`. No setting turns a notice off and no
mute silences it.

| Change | `change` in the notice | What triggers it |
|---|---|---|
| An alert kind turned off | `kind_disabled` | A save of Security alerts that turns off a kind that was on. The notice lists the kinds. Resetting the settings to their defaults (`CMS.reset_site_security_alerts/1`; the page has no reset button) while **Failed sign-ins** was on counts too |
| Admin notifications switched off | `admin_notifications_off` | A save that unticks **Notify this site's admins by bell and email** |
| A security webhook changed | `webhook_changed` | Editing an endpoint subscribed to any `security.*` event: its URL changed, **Active** unticked, or a `security.*` event unticked |
| A security webhook deleted | `webhook_removed` | Deleting such an endpoint |
| A security webhook's secret rotated | `webhook_secret_rotated` | **Rotate secret** on such an endpoint. The receiver stops verifying deliveries until it has the new secret |
| A security webhook auto-disabled | `webhook_auto_disabled` | Delivery switching such an endpoint off after repeated failures ([Auto-disable](webhooks.md#auto-disable)) |
| An admin removed | `admin_removed` | Someone removes another person's admin membership from the site |
| An admin demoted | `admin_demoted` | Someone lowers another person's admin role on the site |
| A temporary admin role ended | `admin_grant_revoked` | Someone ends another person's temporary admin grant on the site early, or replaces it with a lower one |
| The site's mail relay changed | `mail_relay_changed` | A person saves or removes the site's own mail relay. Security alert email does not use it, but every other mail of the site does |

The admin changes notify only when one person changes another: demoting
yourself, or a change made by the system with nobody behind it, sends no
notice. Turning a kind back on, switching admin notifications back on,
showing full addresses, subscribing an endpoint to more events and switching
one back on raise nothing.

A notice is written in the same transaction as the change. If the notice
cannot be written, the change is refused and rolls back: alerts are never
turned down without a word.

## IP addresses in alerts

The security log keeps every event's full address. An alert shows less:

- **By default**, an IPv4 address as its `/24` (`203.0.113.7` becomes
  `203.0.113.0/24`) and an IPv6 address as its `/48` (`2001:db8:1:2::7`
  becomes `2001:db8:1::/48`). An IPv4-mapped IPv6 address is shown as IPv4.
- **With Show the full IP address in alerts ticked**, the full address, in the
  bell, the email and the webhook payload of that site's alerts.
- **Platform alerts always show the network only.** No site chose to show
  the address.

## Send alerts to a webhook

A webhook endpoint of the site can receive the site's alerts and its silencing
notices, signed like every other delivery. Platform alerts are not sent to any
webhook in this release.

1. Open **Webhooks** (`/editor/webhooks`). You need the admin role on the site.
2. Create an endpoint, or edit one.
3. In the event list, find the **`security`** group and tick the events you
   want: `security.new_admin`, `security.role_elevation`,
   `security.failed_sign_ins`, `security.lockout`,
   `security.two_factor_disabled`, `security.sso_config_changed` and
   `security.alerts_silenced`. **Select all** in the group ticks them all.
   None of them is in the defaults, so an existing endpoint receives nothing
   until you tick them. The **Select all** above the whole list leaves them
   out, so an endpoint never picks them up by accident.
4. Save. The next alert of a ticked kind is delivered to the endpoint within
   about a minute, and is listed in its delivery history.

A site alert still goes to the site's webhooks when **Notify this site's
admins by bell and email** is off, but not when its kind is off.

Deliveries are retried, count toward [auto-disable](webhooks.md#auto-disable),
and can be redelivered like any other event. Changing, deleting, rotating or
auto-disabling an endpoint subscribed to any `security.*` event sends a
[silencing notice](#silencing-notices).

### Payload

The body is the usual `{"event", "delivery_id", "data"}` envelope, signed with
`x-kilncms-webhook-signature` (see
[Verifying the signature](webhooks.md#verifying-the-signature)). `data` has
one of three shapes, told apart by `phase`.

Every phase carries:

| Key | Value |
|---|---|
| `phase` | `"alert"`, `"summary"` or `"notice"` |
| `kind` | The alert kind (`"lockout"`, …), or `"alerts_silenced"` for a notice |
| `channel` | `"site"` for an alert or summary, `"notice"` for a notice |
| `site_id`, `site_name` | The site the alert is about |
| `occurred_at` | ISO 8601, UTC. The event's time for an alert, the window's end for a summary, the change's time for a notice |
| `console_url` | The site's **Security log** (alert, summary) or **Security alerts** page (notice) on its console host |

An **alert** adds `window` (`started_at`, `ends_at`), `count` (`1`, or for
`failed_sign_ins` the count that crossed the threshold, `10`) and `event`,
the security log event that raised it:

```jsonc
// POST to your endpoint, security.lockout
{
  "event": "security.lockout",
  "delivery_id": "6f1c…",
  "data": {
    "phase": "alert",
    "kind": "lockout",
    "channel": "site",
    "site_id": "0d6e…",
    "site_name": "Example",
    "occurred_at": "2026-11-10T14:03:12.418204Z",
    "window": { "started_at": "2026-11-10T14:00:00.000000Z", "ends_at": "2026-11-10T14:15:00.000000Z" },
    "count": 1,
    "console_url": "https://example.org/editor/security-log",
    "event": {
      "id": "9a40…",
      "type": "sign_in_locked",
      "actor_id": "c2b7…",
      "target_type": null,
      "target_id": null,
      "ip": "203.0.113.0/24",
      "metadata": { "method": "password", "scope": "account" }
    }
  }
}
```

`event.metadata` holds the event's allowlisted keys, the same as the security
log's ([What is recorded](security-events.md#what-is-recorded)). `event` is
absent when the event was already removed by the log's retention before the
alert was delivered.

A **summary** adds `window` and `count` (the window's total) and has no
`event`:

```json
{
  "phase": "summary",
  "kind": "failed_sign_ins",
  "channel": "site",
  "site_id": "0d6e…",
  "site_name": "Example",
  "occurred_at": "2026-11-10T14:15:00.000000Z",
  "window": { "started_at": "2026-11-10T14:00:00.000000Z", "ends_at": "2026-11-10T14:15:00.000000Z" },
  "count": 41,
  "console_url": "https://example.org/editor/security-log"
}
```

A **notice** (`security.alerts_silenced`) adds `change` (one of the values in
[Silencing notices](#silencing-notices)), `kinds` (the kinds turned off, for
`kind_disabled`; otherwise `[]`), `endpoint_id` (for the webhook changes) and
`actor_id` (the person who made the change, or `null`):

```json
{
  "phase": "notice",
  "kind": "alerts_silenced",
  "channel": "notice",
  "site_id": "0d6e…",
  "site_name": "Example",
  "occurred_at": "2026-11-10T14:20:41.002113Z",
  "change": "kind_disabled",
  "kinds": ["lockout"],
  "endpoint_id": null,
  "actor_id": "5e3a…",
  "console_url": "https://example.org/editor/security-alerts"
}
```

`delivery_id` is the dedupe key, as for every event. An alert and its summary
are two deliveries.

## Send alerts to Slack

A Slack-format endpoint posts the site's alerts and silencing notices into a
channel as a readable message. It also works with Mattermost, Rocket.Chat
and Discord's `/slack` URL, which accept the same body. You need the admin
role on the site, and an incoming-webhook URL for the channel from your chat
tool (in Slack, an app with **Incoming Webhooks** turned on, then **Add New
Webhook** for the channel).

1. Open **Webhooks** (`/editor/webhooks`) and go to **Add a webhook**.
2. Set **Format** to **Slack (incoming webhook)**. Under it you see "Slack
   endpoints receive security alerts only.", and the event list narrows to
   the `security` group with every event ticked.
3. Paste the channel's URL into **Endpoint URL**. A warning under it reads
   "Slack doesn't check signatures: the URL is the credential. After saving,
   Kiln shows only its host."
4. Untick any events the channel should not get. **Select all** and
   **Reset to defaults** both tick every security event again.
5. Click **Add webhook**. The page says "Slack webhook added." The new row
   shows the URL masked (`https://hooks.slack.com/…/9xQz`) and a **Slack**
   badge. It has no signing secret and no **Rotate secret**: Slack checks no
   signature.
6. Click **Ping** on the row. The page says "Test ping queued — see
   deliveries below.", and the channel shows "KilnCMS
   webhook test for `Example`", with your site's name.

From then on each alert of a ticked kind is posted within about a minute.
A lockout on a site named Example arrives as this body:

```json
{
  "text": "Security alert on `Example`: An account was locked out (from `203.0.113.0/24`) · Open the security log: https://example.org/editor/security-log",
  "blocks": [
    {"type": "section", "text": {"type": "mrkdwn", "text": "*An account was locked out (from `203.0.113.0/24`)* on `Example`\n2026-11-10 14:03 UTC"}},
    {"type": "context", "elements": [{"type": "mrkdwn", "text": "<https://example.org/editor/security-log|Open the security log> · `security.lockout`"}]}
  ],
  "unfurl_links": false,
  "unfurl_media": false
}
```

A summary's second line says "From (start) to (end)" of the window, and a
notice links to the security alerts settings instead of the log and, when
alert kinds were turned off, lists them after "Turned off:". The message is
in English, like the email. It carries the address only as the site's
[IP setting](#ip-addresses-in-alerts) allows, and no user id. The full
rules for the body are in
[Slack-format endpoints](webhooks.md#slack-format-endpoints).

The format can't be changed after the endpoint is added. To move a channel
to the signed JSON format, or the other way, add a new endpoint and delete
the old one.

What can go wrong:

- **"Slack endpoints can only receive security events"** under the events:
  a non-security event is ticked, for example on an endpoint saved through
  code. Untick it.
- **The ping's delivery says `endpoint returned HTTP 404` or `410`**: the
  channel or the webhook is gone in Slack (`channel_not_found`,
  `channel_is_archived`). `403` means the app lost access. Make a new
  incoming webhook, add it as a new endpoint, and delete this one.
- **`endpoint returned HTTP 400`**: the receiver did not accept the body
  (`invalid_payload`). During a rolling upgrade or after a rollback a node
  running 1.9 sends the Kiln envelope instead; see the upgrade notes in
  [For operators](#for-operators).
- **The URL leaked** (pasted into a ticket, a screenshot): anyone with it can
  post to the channel. Regenerate it in Slack and put the new URL in
  **Edit** → **Endpoint URL** (which sends the site's admins a
  [silencing notice](#silencing-notices), as any URL change does), then
  delete the old webhook in Slack.

## For operators

- **Upgrade.** One additive migration: new tables `security_alert_dispatches`
  and `site_security_alerts`, and `users.notify_on_security_alert` (`NOT NULL
  DEFAULT true`). From the deploy on, every site's member admins get every
  site kind but failed sign-ins, and platform admins get platform alerts. The
  release's upgrade note in the changelog covers rolling deploys and
  rollback: an older release without #2509 cannot load the new
  `security_alert` and `security_notice` notifications or the
  `api_key_reuse_detected` event.
- **Upgrade to the Slack format.** One additive migration:
  `webhook_endpoints.format` (`NOT NULL DEFAULT 'kiln'`) and
  `notifications.details` (nullable). Existing endpoints stay Kiln-format.
  During a rolling deploy a node still on 1.9 may post the Kiln envelope to
  a Slack endpoint (Slack answers 400 and the delivery is retried, usually on
  a new node), and a 1.9 console can tick content events on a Slack endpoint
  (they are posted as a neutral line). **Before rolling back to 1.9**,
  deactivate or delete every Slack-format endpoint: 1.9 sends them the Kiln
  envelope, Slack refuses it, and after 10 exhausted deliveries the endpoint
  is auto-disabled with a silencing notice to the site's admins. The new
  columns can stay; 1.9 ignores them.
- **Mail goes through the instance relay** (the `KilnCMS.Mailer`
  configuration), never a site's own SMTP relay: a site admin can change that
  relay, and an alert about the site must not depend on it. Alert mail is
  queued on the `mail` queue like any other.
- **Jobs.** No new queue. Three AshOban jobs on `default`: delivering alerts
  and summaries (each every minute) and an hourly prune at minute 17. A
  delivery is retried up to 10 times; one that still fails is marked failed
  and not tried again. Rows are deleted a day after their window ends, and an
  alert older than a day is never sent.
- **Watch** `[:kiln_cms, :security, :alert_failed]`. It is emitted in two
  cases, each with an `error` log line:
  - an alert could not be claimed (metadata `scope`, `kind`, `reason`), with
    "Security alert … could not be claimed and will not be sent". The event
    and the change that raised it still commit; only the alert is lost.
  - a delivery used its 10 attempts and was stamped failed (metadata
    `scope`, `kind`, `reason: :delivery_exhausted` and `phase`: `:alert`
    when the alert itself was never sent, `:summary` when its window's
    summary was not), with "Security alert (id) ((kind), (phase)) was not
    delivered after its last attempt; it is stamped failed and will not be
    retried." It fires once per dispatch.
- **A reused API key** is recorded as `api_key_reuse_detected` in the key
  owner's site when the owner has exactly one active membership, else in the
  default site; the request's host never chooses. If the event cannot be
  recorded, the platform admins get the plain email this check sent before
  alerts existed, and the log says "API key reuse event for key … not
  recorded (…); mailing the platform admins directly."
- **Staging.** `mix kiln.staging.scrub` deletes every row of
  `security_alert_dispatches` (`security_alert_dispatches_purged`), so a clone
  never mails production's admins about production's events.
- **Data.** [data-flows.md](data-flows.md) lists what each part stores.

## For developers

- `KilnCMS.Security.Alerts`: the kinds, `classify/2` (an event to the alerts
  it raises; pure), the recipients, the IP display rule and the failed sign-in
  tally.
- `KilnCMS.Security.Changes.RaiseAlert`: the last change on
  `KilnCMS.Security.Event`'s `:record`; claims windows through
  `KilnCMS.Security.AlertGate` and writes derived notices.
- `KilnCMS.Security.AlertDispatch`: one row per alert window or notice, and
  the AshOban triggers that deliver it through
  `KilnCMS.Security.Changes.DeliverAlert` and `KilnCMS.Security.AlertMail`.
- `KilnCMS.CMS.SiteSecurityAlerts`: the settings row, through
  `CMS.list_site_security_alerts/1`, `CMS.save_site_security_alerts/2`,
  `CMS.update_site_security_alerts/2` and `CMS.reset_site_security_alerts/1`
  (admin only). `:save` writes every field it is not given back to its
  default, so pass all three.
- `KilnCMS.Security.AlertText`: the kind and change labels and the
  one-line headline, gettext'd. The inbox renders it in the reader's locale
  from `Notification.details` (the values `AlertText.details/1` keeps: phase,
  kind, channel, change, kinds, count, display IP, event type);
  `KilnCMS.Security.AlertMail` and `KilnCMS.Webhooks.SlackFormat` pin English.
  `KilnCMSWeb.NotificationText.excerpt/1` picks the line for a row.
- `KilnCMS.Notifications.unread_platform_alert_count/2`: the number behind
  the "unread platform alerts" entry. Platform alert rows carry
  `content_type` `"platform_security_alert"`
  (`KilnCMS.Notifications.platform_alert_content_type/0`); site alert rows
  keep `"security_alert_dispatch"`.
- `KilnCMS.Webhooks.SlackFormat.render/2` builds a Slack-format endpoint's
  body; `KilnCMS.Webhooks.display_url/1` masks a webhook URL for display.
- `KilnCMS.Webhooks.enqueue_security!/4` delivers one `security.*` event to
  one endpoint; `KilnCMS.Webhooks.dispatch/4` never sends them, so they do
  not reach automation, federation, the CDN purge or the change feed.
- `security` is a reserved webhook namespace
  (`KilnCMS.CMS.WebhookEndpoint.reserved_namespaces/0`): a new content type
  cannot be named `security`.
- The test suite runs with `config :kiln_cms, KilnCMS.Security.Alerts,
  enabled: false`, so recording an event claims no window. A test about
  alerts turns it on in an `async: false` module. It is a test seam, not a
  production setting.
- Authorization: see *Security alerts* in [policy-matrix.md](policy-matrix.md).

## Troubleshooting

| You see | Meaning |
|---|---|
| No alerts at all on a site | **Notify this site's admins by bell and email** is off, or the kind is off. (A site with no member admins sends its alerts to the platform admins.) |
| An alert email is missing, the bell row is there | You muted the email in **Your settings**. Platform alerts and notices ignore the mute. |
| A platform alert is not in the bell | Platform alerts are listed in the default site's bell and inbox. In another site's console the bell shows only "N unread platform alerts": select it to open the default site's inbox. Alerts raised before this release are not counted there. |
| "Couldn't reveal that URL." on Webhooks | The endpoint was deleted after the page loaded, or you are no longer an admin of the site. Reload. |
| A Slack endpoint was auto-disabled after an upgrade or rollback | A node running 1.9 sent it the Kiln envelope and Slack refused it. Once every node runs this release, tick **Active** on the endpoint. |
| Several events, one alert | They fell in one 15-minute window. The summary follows about a minute after the window closes. |
| "You don't have permission to change this site's security alerts." | Your role on the site was lowered while the page was open. Reload. |
| "The security alert settings could not be saved." | The save failed, for example because its notice could not be written; nothing changed. Try again, and check the application log. |
| "can only be changed by the account holder" | Someone other than the account holder tried to change its security alert email setting. |
| A notice you did not expect | Someone turned a kind off, switched admin notifications off, changed a security webhook, removed or demoted an admin, or changed the mail relay. `actor_id` in the webhook payload, and the security log, say who. |
