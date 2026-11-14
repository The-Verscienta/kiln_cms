# Security alerts

The [security log](security-events.md) records what happened. Security alerts
tell someone while it still matters: a new admin, a lockout, two-factor turned
off, a changed single sign-on provider, a stolen API key used again, a blocked
address knocking, an API key over a rate limit (#2245).
Each alert arrives as a bell notification and an email, and a site can also
send its alerts to a webhook.

Alerts are built on the security log. Nothing records an alert on its own: an
event is written to the log, and if it is one of the kinds below it raises an
alert in the same database transaction. An event that rolls back raises
nothing. Why alerts are built this way, who hears them and why turning them
down always sends a notice are argued in
[ADR 0027](decisions/0027-security-alerts-derive-from-the-audit-log-and-turning-a-sites-alerts-down-is-never-silent.md).

## What raises an alert

There are two channels. A **site** alert is about one site and goes to that
site's own admins, who can turn each kind off. A **platform** alert is about
the whole installation and goes to every platform admin. Nobody can mute a
platform alert, and only one platform kind, `api_key_rate_limited`, can be
turned off, by a platform admin
([Turn off rate-limit alerts for API keys](#turn-off-rate-limit-alerts-for-api-keys)).

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
| `blocked_ip` | Blocked addresses | A request or socket connect from an address on the site's [block list](ip-blocking.md) is refused (see [Blocked addresses](#blocked-addresses-raise-one-alert-per-window)) | Yes |

Platform alerts:

| Kind | Raised when | Can be turned off |
|---|---|---|
| `new_admin` | An account's own role is set or raised to admin (a platform admin), standing or by a temporary grant | No |
| `platform_role_changed` | A platform admin's admin role is taken away: lowered, or a temporary admin grant ended early or replaced by a lower one | No |
| `new_api_key` | An API key is minted. Rotating a key into its successor is not an alert | No |
| `api_key_abuse` | A rotated-away API key is presented to `POST /api/keys/rotate` again more than 120 seconds after its rotation: two parties held the key, and Kiln revoked the whole chain ([self-rotation](headless-consumer-guide.md#keeping-the-key-alive-self-rotation)) | No |
| `api_key_rate_limited` | A verified API key goes over a rate limit (see [API keys over a rate limit](#api-keys-over-a-rate-limit)) | Yes, by a platform admin. On by default |

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
- **An automatic address block being created.** The scanner guard adding a
  temporary rule is recorded as `ip_auto_blocked` and raises nothing. The
  requests that rule then refuses do raise `blocked_ip`, like any rule's.
- **Every other security event**: sign-ins, invitations, passkeys, recovery
  codes, API key revocations, the admin allowlist, other site settings. They
  stay in the log.

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
  preferred language, and one admin can hold sites in several
  ([ADR 0029](decisions/0029-security-alert-email-stays-english-until-accounts-store-a-locale.md)). They go through the
  installation's own mail relay, never a site's (see
  [For operators](#for-operators)).
- **Never a name or address of a person.** Neither the bell, the email nor the
  webhook carries an email address, a user agent, a secret or a webhook URL
  (a webhook URL is treated as a credential:
  [ADR 0028](decisions/0028-webhook-urls-are-credentials-masked-wherever-they-are-shown-exported-or-logged.md)).
  The client's IP address is shown only as its network unless the site opted
  in (see [IP addresses in alerts](#ip-addresses-in-alerts)).

### One alert per kind every 15 minutes

Alerts are grouped into 15-minute windows aligned to the database clock (on
the quarter hour, UTC). The first event of a kind in a window raises the
alert. Later events of the same kind in the same window raise nothing more on
their own; about a minute after the window closes, a **summary** says how many
there were ("A new administrator: 4 in this alert window"). The summary is sent
only when there was more than the alert already said: more than one event,
or for failed sign-ins more than the count the alert carried (see below).

Windows are per site for site alerts, and one for the whole installation for
platform alerts. Each kind has its own window, so an API key going over a rate
limit never uses up the window a stolen key's `api_key_abuse` alert is sent
in. Silencing notices are never grouped: each one is sent.

### Failed sign-ins are counted per site

When `failed_sign_ins` is on, every failed sign-in on the site is counted:
a wrong password, a wrong second-factor code, a sign-in refused by
[human verification](human-verification.md). The count is per site, not per
address or account, which an attacker chooses: 40 attempts from 40 addresses
count the same as 40 from one.

The failed sign-in that takes the window's count to 10 raises the alert,
which names that attempt's address. The window's total arrives in the
summary. Because the windows are fixed, 10 failures that straddle a quarter
hour can stay under the threshold in both windows.

The alert's count can be more than 10. The site's count is kept in several
rows, so that a burst of failed sign-ins does not queue on one database row,
and attempts that arrive together each add to their own row before any of
them reads the total. The first of them to see 10 or more raises the alert,
and the count it saw (11, say) is the one the alert carries. A summary
follows only when the window's total ends above that count. Still only one
alert is sent per window, however many servers see the threshold crossed.

If the database cannot be reached, each server counts failed sign-ins on
its own until it can, and raises the alert when its own count reaches 10.

A site with the kind off counts nothing. Turning it on takes effect at once on
every node.

The [security log samples failed sign-ins](security-events.md#failed-sign-ins-refusals-and-rate-limited-keys-are-sampled-lockouts-are-not)
(5 per address per 15 minutes). The attempt that crosses the threshold (on
each server, the first one there to see it) is written to the log even past
that cap, so the alert always has its event.

### Blocked addresses raise one alert per window

When `blocked_ip` is on (the default), a request refused by the site's
[block list](ip-blocking.md) raises an alert: an HTTP request (the empty
`403`), a page's LiveView connection, or a connect to `/ws/gql`,
`/ws/collab` or `/ws/bridge`. Rules the [scanner guard](ip-blocking.md#block-scanners-automatically)
adds for a while are rules like any other, so the requests they refuse
alert too.

A blocked address is a flood by nature, so it is thinned out in memory
before anything reaches the database:

- Each server lets through the first refusal of each client network per
  site per 15-minute window, and at most **20 networks per site per window**.
  A client network is an IPv4 address, or an IPv6 address's `/64`.
- What gets through is written to the security log as `ip_block_refused`,
  once per site and network per window across all servers. The event names
  the **rule that matched and the surface** (`http`, `live`, `gql`,
  `collab`, `bridge`), and has **no IP address and no user agent**: nothing
  records a blocked address.
- The first event of the window raises the alert: "A blocked address was
  refused (rule 203.0.113.0/24)". The rule is masked like an address (see
  [IP addresses in alerts](#ip-addresses-in-alerts)).
- The summary counts the client networks recorded in the window, at most 20
  per server ([Running more than one server](#running-more-than-one-server)),
  not the requests refused. For the number of refusals, see the
  `kiln_cms.ip_block.refused.count` counter
  ([Observability](observability.md#blocked-addresses)).

**How many to expect.** A blocked client that keeps trying raises one alert
every 15 minutes, 96 a day for each admin, by bell and by email. When more
than one network is refused in a window, a summary follows each alert, so the
most a site sends is one alert and one summary per window, 192 a day. To
stop them, untick **Blocked addresses** on the Security alerts page (the
[steps](#choose-which-alerts-your-site-sends) below). The refusals are still
written to the security log, sampled the same way, but no alert is sent.

Don't confuse the alert setting with the **Blocked addresses** page under
**Sign-in & access** (`/editor/ip-blocks`), where the rules themselves are.
Removing a rule there stops the alerts it raises.

### API keys over a rate limit

`api_key_rate_limited` is a platform alert: every platform admin gets it by
bell and email, with no mute, and no webhook carries it. It is raised when an
API key that this server has verified goes over one of these rate limits:

| Limit (`bucket`) | Covers |
|---|---|
| `api` | JSON:API and the REST routes under `/api`, the change feed (`/api/feed`), MCP (`/mcp`) and the ActivityPub inbox (`POST /actor/inbox`) |
| `gql` | `/gql`, including a batch over its operation budget |
| `media_upload` | Uploads and imports under `/api/media` |
| `media_transform` | Image transforms, `/media/:id/t/...` |
| `plugin_endpoint` | Plugin routes |

No other limit raises it: sign-in, forms, page delivery and the rest are
about addresses, not keys.

**"Verified" means used successfully on this server recently.**
A rate limit refuses a request before the key in it is checked, and checking
it there would cost a database read on every refused request. So each server
remembers, in memory, the keys that authenticated on it, as a SHA-256 of the
key and the key's id. An entry lasts 5 minutes from when it was written, and
a successful request rewrites it only once it is more than 2.5 minutes old (so
an authenticated request costs one hash and one memory read, not a write). A
key in steady use therefore stays remembered, and is forgotten between 2.5 and
5 minutes after its last successful request on that server. A refused
request whose key is not remembered (forged, unknown, revoked, expired, never used on this
server, or a JWT from the headless sign-in rather than a key) is counted on the
`kiln_cms.security.api_key_trip.count` counter and nothing else. Why the key
is not checked at the refusal, and why servers do not share what they
remember, is argued in [ADR 0053](decisions/0053-rate-limit-alerts-trust-a-node-local-verified-key-cache-never-a-check-on-the-refusal-path.md). That means:

- On image transforms and plugin routes, which never check a key, a refusal
  alerts only if the same key was used on an authenticated API on the same
  server recently enough to still be remembered (2.5 to 5 minutes, as
  above). Behind a load balancer, the earlier use and the refusal have to
  land on the same server (see
  [Running more than one server](#running-more-than-one-server)).
- `/ws/gql` cannot carry an API key (the socket accepts only a JWT), so a
  refusal there never alerts.
- A key revoked while it is still remembered records nothing: the key is
  reloaded before the event is written, and must still be valid.

**One per key and limit per window.** Each server notes a key once per limit
per 15-minute window. The security log gets one `api_key_rate_limited` event
per key and limit per window across servers, and the platform gets one
alert, then a summary counting the key-and-limit pairs. The window is the
kind's own, so it never delays a stolen-key `api_key_abuse` alert.

**Where it is logged.** In the security log of the key owner's site when the
owner has exactly one active membership, otherwise the default site's; the
host the request named never decides. The event has no person (whoever
presented the key is not known to be its owner); its target is the key, its
`metadata` the key's `name` and the `bucket`, and its IP address the
request's. The alert shows the address as its network only, like every
platform alert: "An API key hit a rate limit (from 203.0.113.0/24)".

**False positives.** The limits are per client address, not per key. A
legitimate key behind a NAT or proxy that someone else is flooding is refused
too, and alerts. If that is routine for your installation (clients that batch
heavily, shared egress), a platform admin can
[turn this alert off](#turn-off-rate-limit-alerts-for-api-keys).

## Choose which alerts your site sends

You need the admin role on the site (a platform admin has it on every site).
Editors and viewers do not see the page and are refused if they open its
address.

1. Open **Security alerts** under **Organization** in the console sidebar,
   or go to `/editor/security-alerts`. You see three parts: **Alerts**,
   **Delivery** and **Not set here**. A platform admin also sees **Platform
   alerts** (see
   [Turn off rate-limit alerts for API keys](#turn-off-rate-limit-alerts-for-api-keys)).
2. Under **Alerts**, tick the kinds you want and untick the ones you don't.
   Each has a line saying what raises it. **Failed sign-ins** reads "10 failed
   sign-ins in 15 minutes on this site. Off by default." **Blocked addresses**
   reads "A request from an address on this site's block list is refused.
   One alert every 15 minutes, then a summary."
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

Platform alerts are not site settings. The **Not set here** section lists them
and links to **Webhooks**, where an endpoint can subscribe to the site's
alerts (see [Send alerts to a webhook](#send-alerts-to-a-webhook)).

Saving the page is itself recorded in the security log, as
`org_setting_changed` with `setting` `site_security_alerts`.

## Turn off rate-limit alerts for API keys

`api_key_rate_limited` is the one platform alert that can be turned off. It
starts on. Only a platform admin can change it, and the change applies to
the whole installation, not one site.

1. Open **Security alerts** (`/editor/security-alerts`) on any site. Below
   the site's form you see **Platform alerts**, with the line "Shown to
   platform admins only. These go to every platform admin, for the whole
   installation. Turning one off is recorded in the instance security log."
   Site admins who are not platform admins don't see this part.
2. Untick **API keys over a rate limit**. The line under it reads "A verified
   API key goes over a rate limit. One alert every 15 minutes, then a
   summary, to every platform admin." The **?** at the end of that line
   ("About when a rate-limit alert is raised") opens **When an alert is
   raised**: "Some refusals raise no alert, especially when Kiln runs on more
   than one server: an alert is raised only by a server that recently
   verified the key." Its **Learn more** link opens
   [Running more than one server](#running-more-than-one-server).
3. Select **Save platform alerts**. You see "Platform alert settings saved.
   Turning an alert off is recorded in the instance security log." (Saving
   with nothing turned off says "Platform alert settings saved.")
4. Open **Security log**, then **Instance log**. The save is there as
   **Platform security alerts changed** (`platform_alerts_changed`), with
   `disabled_kinds` `api_key_rate_limited`, or `none` after turning it back
   on.

From the next delivery on, nothing is sent for the kind. The
`api_key_rate_limited` events are still written to the security log, and the
alert's window is still claimed and stamped delivered; only the bell and
email are skipped. Unlike a site setting, turning it off sends no
[silencing notice](#silencing-notices): notices go to one site's admins, and
this is the installation's. The instance log is the record.

What can go wrong:

- **"Only platform administrators can change the platform's security
  alerts."** Your platform admin role was lowered, or a temporary platform
  grant expired, while the page was open. Nothing changed.
- **"The platform alert settings could not be saved."** The save failed, for
  example because its instance log event could not be written (the two are
  saved together). Nothing changed; try again and check the application log.
- **The alerts keep coming after you turned the kind off.** The setting
  could not be read when an alert was delivered; delivery then treats the
  kind as on and logs "Security alerts: the platform alert settings could
  not be read (…); every platform kind is treated as on."

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
turned down without a word. The platform's own switch for
`api_key_rate_limited` is the one exception: it sends no notice and is
recorded in the instance security log instead
([ADR 0027](decisions/0027-security-alerts-derive-from-the-audit-log-and-turning-a-sites-alerts-down-is-never-silent.md)).

## IP addresses in alerts

The security log keeps every event's full address. An alert shows less:

- **By default**, an IPv4 address as its `/24` (`203.0.113.7` becomes
  `203.0.113.0/24`) and an IPv6 address as its `/48` (`2001:db8:1:2::7`
  becomes `2001:db8:1::/48`). An IPv4-mapped IPv6 address is shown as IPv4.
- **With Show the full IP address in alerts ticked**, the full address, in the
  bell, the email and the webhook payload of that site's alerts.
- **Platform alerts always show the network only.** No site chose to show
  the address.

A `blocked_ip` alert carries no address at all: its event records none. It
names the block rule that matched, masked by the same setting. By default a
rule narrower than a `/24` (IPv4) or a `/48` (IPv6) is shown as that network,
so a rule for one host does not name the host (`203.0.113.7/32` becomes
`203.0.113.0/24`, `2001:db8:1:2::/64` becomes `2001:db8:1::/48`); a broader
rule, such as `10.0.0.0/16`, is shown as it is. With **Show the full IP
address in alerts** ticked, the rule is shown as stored. The security log
keeps the rule in full.

## Send alerts to a webhook

A webhook endpoint of the site can receive the site's alerts and its silencing
notices, signed like every other delivery. Platform alerts are not sent to any
webhook in this release.

1. Open **Webhooks** (`/editor/webhooks`). You need the admin role on the site.
2. Create an endpoint, or edit one.
3. In the event list, find the **`security`** group and tick the events you
   want: `security.new_admin`, `security.role_elevation`,
   `security.failed_sign_ins`, `security.lockout`,
   `security.two_factor_disabled`, `security.sso_config_changed`,
   `security.blocked_ip` and `security.alerts_silenced`. **Select all** in
   the group ticks them all. None of them is in the defaults, so an existing
   endpoint receives nothing until you tick them, and an endpoint made before
   `security.blocked_ip` existed does not receive it until you tick it. The **Select all** above the whole list leaves them
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
`failed_sign_ins` the count that crossed the threshold: `10` or more, see
[Failed sign-ins](#failed-sign-ins-are-counted-per-site)) and `event`,
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
log's ([What is recorded](security-events.md#what-is-recorded)), except that a
block `rule` is masked like an address. `event` is absent when the event was
already removed by the log's retention before the alert was delivered.

A `security.blocked_ip` alert's `event` has `ip` `null` and names the rule and
the surface instead:

```jsonc
// data.event of a security.blocked_ip alert, the site showing networks only
{
  "id": "4c1e…",
  "type": "ip_block_refused",
  "actor_id": null,
  "target_type": null,
  "target_id": null,
  "ip": null,
  "metadata": { "rule": "203.0.113.0/24", "surface": "http" }
}
```

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
   A Slack endpoint added before `security.blocked_ip` existed does not have
   it ticked: edit the endpoint and tick it if the channel should get
   blocked-address alerts.
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
- **Rolling deploys and the failed-sign-in count.** From this release a
  site's failed sign-ins are counted over eight rows instead of one (#2639);
  no migration. A node on the new release adds the old single row into its
  total, so failed sign-ins counted by a node still on 1.9 are not lost.
  The other way does not hold: a 1.9 node reads only the single row. For
  the 15-minute window the deploy (or a rollback) falls in, a 1.9 node can
  therefore raise the failed-sign-in alert late, and when it is the node
  that sends the window's summary it reads too low a count: the summary
  shows fewer failed sign-ins than there were, or is skipped (with "the
  failed sign-in tally for its window is gone; no summary sent." in the log
  when the single row has none). Later windows are unaffected once every
  node runs the same release. Nothing needs doing.
- **Upgrade to blocked-address and rate-limit alerts.** One additive
  migration, a new table `platform_security_alerts` (one row, the platform
  kinds a platform admin turned off; empty until someone saves). From the
  deploy on:
  - every site with block rules alerts its admins when a blocked address is
    refused, by default (up to one alert and one summary per 15 minutes; see
    [Blocked addresses](#blocked-addresses-raise-one-alert-per-window));
  - existing webhook endpoints, Slack ones included, do not receive
    `security.blocked_ip` until an admin ticks it. On a site whose alerts go
    only by webhook (admin notifications off, or no admins), the
    **Security alerts reach someone** posture line turns **Review** ("Some
    security alerts on this site reach nobody…") until the event is ticked
    or **Blocked addresses** is turned off;
  - platform admins get `api_key_rate_limited`.

  During a rolling deploy, a `blocked_ip` or `api_key_rate_limited` alert
  that a node still on the previous release picks up is logged as "Security
  alert … names an unknown kind; not sent." and stamped, so it is lost.
  Older nodes don't remember verified keys, so a key going over a limit on
  one of them raises nothing. After a rollback, the new event rows read as
  "Unrecognized event (ip_block_refused)" and "Unrecognized event
  (api_key_rate_limited)", a site's stored opt-out of `blocked_ip` is kept
  and its page still saves, and the new table is left unused. **Editing a
  webhook endpoint on 1.9.x drops `security.blocked_ip` from it**: the 1.9
  form lists only the events it knows, so saving sends the list without it,
  and that counts as unticking a security event, which sends the site's
  admins a `webhook_changed` silencing notice. Tick it again after rolling
  forward.
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
- **Watch** `kiln_cms.security.api_key_trip.count`, tagged `result`
  (`unverified`, `debounced`, `noted`) and `bucket`: rate-limit refusals of
  requests that carried a credential. A high `unverified` rate is clients
  over a limit with keys this server has not seen authenticate (forged,
  revoked, or used only on other servers); `noted` is what alerted. See
  [Observability](observability.md#security-log-and-alerts).
- **A reused API key** is recorded as `api_key_reuse_detected` in the key
  owner's site when the owner has exactly one active membership, else in the
  default site; the request's host never chooses. A key over a rate limit
  (`api_key_rate_limited`) is recorded by the same rule. If the event cannot be
  recorded, the platform admins get the plain email this check sent before
  alerts existed, and the log says "API key reuse event for key … not
  recorded (…); mailing the platform admins directly."
- **Staging.** `mix kiln.staging.scrub` deletes every row of
  `security_alert_dispatches` (`security_alert_dispatches_purged`), so a clone
  never mails production's admins about production's events.
- **Data.** [data-flows.md](data-flows.md) lists what each part stores.

### Running more than one server

The gates in front of blocked-address and rate-limit alerts are kept in each
server's memory, so a cluster behaves differently from one server in three
ways.

- **Most request-rate limits are per server.** Every request-rate limit
  (`KilnCMSWeb.RateLimit`) except sign-in (`auth`), registration (`register`)
  and unlock (`unlock`) is counted in each server's memory, the five limits
  that raise `api_key_rate_limited` included. (The per-account budgets, such as
  sign-in lockout and invitations, are shared through the database and don't
  multiply.) Behind a load balancer an address can make up to N times the
  configured number of requests on N servers before it is refused, so a key goes over a limit, and
  alerts, less often than the numbers suggest.
- **A rate-limit alert needs the refusing server to know the key.** It is
  raised only when that server [verified the key](#api-keys-over-a-rate-limit)
  recently: it forgets a key between 2.5 and 5 minutes after the key's last
  successful request there. On `/api`, `/gql` and `/mcp` it normally has, with
  or without session affinity: the server that refuses an address is the one
  that let the address's earlier requests through, and it checked the key on
  each of them that carried it. No alert is raised when:
  - the refusal is on an image transform or a plugin route (neither checks a
    key) or the ActivityPub inbox (which counts against the `api` limit
    without checking a key), and the key's earlier API use landed on another
    server;
  - the address's limit was used up by requests that did not carry the key,
    such as other clients behind the same egress address;
  - the server's key cache restarted on its own while its rate-limit counts
    did not, or the server runs a release that does not remember keys (see
    the rolling-deploy note above).

  On a server running this release, these refusals show up as `unverified`
  on `kiln_cms.security.api_key_trip.count`. Why the servers do not share what
  they remember is argued in [ADR 0053](decisions/0053-rate-limit-alerts-trust-a-node-local-verified-key-cache-never-a-check-on-the-refusal-path.md).
- **A blocked-address summary can count more than 20.** Each server lets at
  most 20 client networks per site through per 15-minute window, and a
  network is recorded once per window across all servers. When the blocked
  clients are spread over the servers, the window's summary can count up to
  about 20 times the number of servers. It is "about" because each server
  starts its window by its own clock, and the summary's window starts by the
  database's.

## For developers

- `KilnCMS.Security.Alerts`: the kinds, `classify/2` (an event to the alerts
  it raises; pure), the recipients, the IP display rule and the failed sign-in
  tally. The tally is spread over `failed_sign_in_shards/0` rows by
  `KilnCMS.Accounts.ThrottleStore.count_sharded/5`, and read back with
  `failed_sign_in_total/2`. `KilnCMS.Security.AlertTrips` lets one crossing
  per node and window try to claim the alert; `KilnCMS.Security.AlertGate`
  keeps it to one across nodes.
- Whether a site's alerts reach anyone is a line on the
  [security posture](security-posture.md#security-alerts) page
  (`core.security_alerts_reach_someone`).
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
- `KilnCMS.Security.BlockedIpAlert.note/4`: called by every edge that refuses
  a blocked address (`KilnCMSWeb.Plugs.IpBlock`, `KilnCMSWeb.IpBlock`) with
  the rule `KilnCMS.Security.IpBlocklist.match/2` returned. `blocked?/2` has
  no side effect, so the scanner guard asking it raises nothing.
- `KilnCMS.Security.ApiKeyTrip`: the node-local cache of verified keys
  (`remember/2`, called by `KilnCMSWeb.Plugs.ApiKeyAuth` and, on `/mcp`, by
  `KilnCMSWeb.Plugs.RememberApiKey`) and `note/2`, called from the refusal
  branch of `KilnCMSWeb.Plugs.RateLimit` and
  `KilnCMSWeb.Plugs.GraphqlBatchLimit`. `buckets/0` lists the limits it
  covers. A new rate-limited API surface that should alert needs its bucket
  there and a key that reaches `remember/2`.
- `KilnCMS.Security.PlatformAlertSettings`: the platform's one settings row,
  through `KilnCMS.Security.list_platform_alert_settings/1` and
  `KilnCMS.Security.save_platform_alert_settings/2` (platform admins only).
  `:save` takes the whole `disabled_kinds` list; only
  `KilnCMS.Security.Alerts.platform_optional_kinds/0` may be added, and a
  save adding another kind is refused with "has alert kinds that cannot be
  turned off". `KilnCMS.Security.Alerts.platform_enabled?/1` is what
  delivery asks.
- `KilnCMS.Security.AlertText`: the kind and change labels and the
  one-line headline, gettext'd. The inbox renders it in the reader's locale
  from `Notification.details` (the values `AlertText.details/1` keeps: phase,
  kind, channel, change, kinds, count, display IP, display block rule, event
  type);
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
| No alerts at all on a site | **Notify this site's admins by bell and email** is off, or the kind is off. (A site with no member admins sends its alerts to the platform admins.) The **Security alerts reach someone** line on [Security posture](security-posture.md#security-alerts) says which. |
| A failed-sign-in alert says 11 or 12, not 10 | Several failed sign-ins arrived together and the first to see the threshold crossed saw more than 10. One alert is still sent. |
| An alert email is missing, the bell row is there | You muted the email in **Your settings**. Platform alerts and notices ignore the mute. |
| A platform alert is not in the bell | Platform alerts are listed in the default site's bell and inbox. In another site's console the bell shows only "N unread platform alerts": select it to open the default site's inbox. Alerts raised before this release are not counted there. |
| "Couldn't reveal that URL." on Webhooks | The endpoint was deleted after the page loaded, or you are no longer an admin of the site. Reload. |
| A Slack endpoint was auto-disabled after an upgrade or rollback | A node running 1.9 sent it the Kiln envelope and Slack refused it. Once every node runs this release, tick **Active** on the endpoint. |
| Several events, one alert | They fell in one 15-minute window. The summary follows about a minute after the window closes. |
| A blocked-address alert every 15 minutes | A blocked client keeps trying. Untick **Blocked addresses** on Security alerts to stop the alerts, or remove the rule on `/editor/ip-blocks` if it is no longer wanted. |
| A blocked-address summary counts far fewer than the refusals | The summary counts client networks (at most 20 per server per window), not requests. `kiln_cms.ip_block.refused.count` counts every refusal. |
| An API key went over a rate limit and no alert came | That server no longer remembered the key (it forgets one between 2.5 and 5 minutes after the key's last successful request there; see [API keys over a rate limit](#api-keys-over-a-rate-limit)), the route was `/ws/gql`, the limit is not one of the [five covered](#api-keys-over-a-rate-limit), the key was revoked in the meantime, or a platform admin turned the kind off. |
| An API key alert for a client that did nothing wrong | Limits are per address: someone else behind the same NAT or proxy used up the limit. |
| "Security alerts reach someone" says some alerts reach nobody after an upgrade | Alerts go only by webhook on this site, and no endpoint has `security.blocked_ip` ticked. Tick it, or untick **Blocked addresses**. |
| "You don't have permission to change this site's security alerts." | Your role on the site was lowered while the page was open. Reload. |
| "The security alert settings could not be saved." | The save failed, for example because its notice could not be written; nothing changed. Try again, and check the application log. |
| "can only be changed by the account holder" | Someone other than the account holder tried to change its security alert email setting. |
| A notice you did not expect | Someone turned a kind off, switched admin notifications off, changed a security webhook, removed or demoted an admin, or changed the mail relay. `actor_id` in the webhook payload, and the security log, say who. |
