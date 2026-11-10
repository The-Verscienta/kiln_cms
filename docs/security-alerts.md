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
| Site alert | Each **member admin** of the site, unless the site switched admin notifications off | The same people, except those who muted the email | The site's endpoints subscribed to `security.<kind>` |
| Platform alert | Every platform admin, in the **default site's** bell | Every platform admin; no mute applies | None in this release |
| Silencing notice | Each member admin of the site | Each member admin; no setting or mute applies | The site's endpoints subscribed to `security.alerts_silenced` |

A **member admin** is an account with an active membership on the site whose
role there is admin, standing or by a live temporary grant, that is not a
platform admin and has not been erased. Editors, viewers, admins of other
sites and anonymous visitors never get an alert.

Platform admins get platform alerts, not site alerts, even on a site where
they also hold an admin membership: on an installation with many sites they
would otherwise hear about every site's lockouts.

**A site with no member admins gets no bell or email for its site alerts.**
On a single-site installation the operator is often a platform admin with no
membership on the site, and then nobody is told by bell or email. Webhooks
still go. The Security alerts page warns when this is the case: "This site has
no admins of its own." To fix it, give at least one person an admin
membership on the site (Team).

A platform alert's bell row lives in the default site, because the bell is per
site. A platform admin sees it in the bell while working in the default site's
console.

## How an alert arrives

- **Within about a minute.** The alert is claimed when the event is written,
  and a job that runs every minute delivers it.
- **The bell.** Headline "Security alert" (or "Security alerts were turned
  down" for a notice), titled with the site's name, with a one-line
  description such as "An account was locked out (from 203.0.113.0/24)". It
  links to **Security log** (`/editor/security-log`); a notice links to
  **Security alerts** (`/editor/security-alerts`).
- **The email.** Subject "Security alert on (site): (what happened)". It says
  when (UTC), links to the security log on the site's own console host (a
  notice links to the Security alerts page), and says why you got it. Emails are in English and go through the
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
   until you tick them.
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

## For operators

- **Upgrade.** One additive migration: new tables `security_alert_dispatches`
  and `site_security_alerts`, and `users.notify_on_security_alert` (`NOT NULL
  DEFAULT true`). From the deploy on, every site's member admins get every
  site kind but failed sign-ins, and platform admins get platform alerts. The
  release's upgrade note in the changelog covers rolling deploys and
  rollback: an older release without #2509 cannot load the new
  `security_alert` and `security_notice` notifications or the
  `api_key_reuse_detected` event.
- **Mail goes through the instance relay** (the `KilnCMS.Mailer`
  configuration), never a site's own SMTP relay: a site admin can change that
  relay, and an alert about the site must not depend on it. Alert mail is
  queued on the `mail` queue like any other.
- **Jobs.** No new queue. Three AshOban jobs on `default`: delivering alerts
  and summaries (each every minute) and an hourly prune at minute 17. A
  delivery is retried up to 10 times; one that still fails is marked failed
  and not tried again. Rows are deleted a day after their window ends, and an
  alert older than a day is never sent.
- **Watch** `[:kiln_cms, :security, :alert_failed]`, emitted when an alert
  could not be claimed (metadata `scope`, `kind`, `reason`), with the log
  line "Security alert … could not be claimed and will not be sent". The
  event and the change that raised it still commit; only the alert is lost.
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
| No alerts at all on a site | The site has no member admins (the page says "This site has no admins of its own."), or **Notify this site's admins by bell and email** is off, or the kind is off. |
| An alert email is missing, the bell row is there | You muted the email in **Your settings**. Platform alerts and notices ignore the mute. |
| A platform alert is not in the bell | Platform alerts are in the default site's bell. Switch to the default site. |
| Several events, one alert | They fell in one 15-minute window. The summary follows about a minute after the window closes. |
| "You don't have permission to change this site's security alerts." | Your role on the site was lowered while the page was open. Reload. |
| "The security alert settings could not be saved." | The save failed, for example because its notice could not be written; nothing changed. Try again, and check the application log. |
| "can only be changed by the account holder" | Someone other than the account holder tried to change its security alert email setting. |
| A notice you did not expect | Someone turned a kind off, switched admin notifications off, changed a security webhook, removed or demoted an admin, or changed the mail relay. `actor_id` in the webhook payload, and the security log, say who. |
