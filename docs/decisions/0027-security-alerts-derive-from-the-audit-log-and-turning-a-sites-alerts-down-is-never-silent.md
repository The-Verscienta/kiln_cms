# 0027. Security alerts derive from the audit log, and turning a site's alerts down is never silent

- **Status** — accepted (2026-11-12).
- **References** — [#2245](https://github.com/The-Verscienta/kiln_cms/issues/2245)
  (owner decisions D1–D7 of 2026-11-08, the 2026-11-09 answers, OC-1 to OC-3
  of 2026-11-10 and the two 2026-11-12 decisions, all in its comments; PRs
  #2638, #2650, #2793, #2806, #2808), [#2642](https://github.com/The-Verscienta/kiln_cms/issues/2642),
  [#2643](https://github.com/The-Verscienta/kiln_cms/issues/2643);
  [ADR 0011](0011-each-organization-gets-its-own-console-origin-under-the-console-host.md)
  and threat-model residual risk 16 for why platform alerts stay in one
  console; [ADR 0026](0026-the-ip-block-list-fails-open-and-covers-dynamic-routes-only.md)
  for why a blocked-address event records no address.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#security-alerts) (Added:
  #2638, #2650), and the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md) (#2793, which closed #2642; #2806;
  #2808).

## The problem

Kiln already wrote a security log (`KilnCMS.Security.Event`). Security alerts
tell an admin about some of those events while they still matter: a new admin,
a lockout, a removed second factor, a changed identity provider, a stolen API
key used again, a blocked address, an API key over a rate limit. Four choices
decide whether the alerts can be trusted, and each has a cheaper answer that
a later reader will be tempted by:

- **Where an alert comes from.** Each emit site could raise its own alert
  next to its own log line.
- **What happens when someone turns the alerts down.** An intruder holding an
  admin's session turns the alerts off before doing anything else.
- **Who hears.** A platform admin is admin on every site, so "every admin of
  the site" means every platform admin hears every site's lockouts.
- **What an alert costs the action it reports on, and the request path.**
  Alerts are about floods (failed sign-ins, blocked addresses, keys over a
  limit) and about writes that must not fail (a role grant, a key rotation).

## Decision

### Alerts are derived from the audit log, never emitted beside it

`KilnCMS.Security.Changes.RaiseAlert` is the last change on
`KilnCMS.Security.Event`'s `:record`. It asks the pure
`KilnCMS.Security.Alerts.classify/2` which alerts and notices the event
raises, and claims them in the event's own transaction. There is no second
emitter: a rolled-back event raises nothing, an event that was never written
claims nothing, and a summary re-classifies a closed window's events with the
same function, so the alert and its count cannot disagree about what counts.

The two kinds that need a new trigger got one as a security event first:
`ip_block_refused` (`KilnCMS.Security.BlockedIpAlert`) and
`api_key_rate_limited` (`KilnCMS.Security.ApiKeyTrip`), alongside
`api_key_reuse_detected` (`KilnCMS.Accounts.ApiKeyReuse`). Each is in the log
whether or not its alert is turned on; a kind turned off is dropped at
delivery, not at recording.

### A claim never fails the action it reports on, unless it must

`KilnCMS.Security.AlertGate.claim/6` is one `INSERT … ON CONFLICT (scope,
kind, window_index) DO NOTHING` in the caller's transaction:

- **Windows are fixed, 15 minutes, on the database clock**
  (`floor(epoch_ms / window_ms)`, `KilnCMS.Security.Alerts.window_ms/0`), so
  two nodes with skewed clocks claim the same row. The first event of a kind
  in a window gets the dispatch row; every later one finds it taken and is
  left for the window's summary. Each kind has its own window, per site for
  site kinds and one for the installation for platform kinds.
- **Best effort by default.** The insert runs under a savepoint with a
  two-second `lock_timeout`. A failure rolls back to the savepoint, is logged,
  emits `[:kiln_cms, :security, :alert_failed]`, and the emitter's write
  commits: losing one alert is better than losing the role grant that raised
  it.
- **Required for a stolen key's reuse.** `KilnCMS.Accounts.ApiKeyReuse`
  records with `alert_required: true`: the claim raises, the event is not
  written, and the module falls back to the plain email it sent before alerts
  existed. A reuse is never left unannounced.
- **No Oban insert in the emitter's transaction.** The dispatch row is the
  queue. `KilnCMS.Security.AlertDispatch`'s AshOban triggers find it within a
  minute and deliver it through `KilnCMS.Security.Changes.DeliverAlert`, up to
  10 attempts, then stamp it failed and emit `alert_failed` again.
- **Delivery reads fail loudly.** `DeliverAlert` makes every read with
  `authorize_with: :error`, so a lost grant raises and the job retries rather
  than reading as "nobody to tell". A summary whose failed-sign-in tally is
  gone is logged and skipped, never sent as zero.

### Floods are thinned before they reach the database

- **Failed sign-ins** are counted per site, never per address or account,
  which the attacker chooses. The tally is spread over 8 shard rows
  (`KilnCMS.Accounts.ThrottleStore.count_sharded/5`, #2806) in two
  autocommitted statements: an upsert on a random shard, then a separate sum.
  Because each attempt sums after its own increment committed, the one that
  commits last sees every increment, so at least one attempt reaches the
  threshold; a single CTE would not, since its snapshot predates its own
  write. `KilnCMS.Security.AlertTrips` lets one crossing per node and window
  through, and the claim keeps it to one across nodes. The threshold is 10 in
  a window (`Alerts.failed_sign_in_threshold/0`).
- **Blocked addresses** pass node-local gates first
  (`KilnCMS.Security.BlockedIpAlert`): a site cap of 20 client networks per
  window, read before it is charged, then one per network. What passes is
  recorded off the request path and sampled once per network per window
  across the cluster.
- **API keys over a rate limit** are noted only for a key this node has
  verified (`KilnCMS.Security.ApiKeyTrip`): a cache of SHA-256 hashes of keys
  that authenticated here in the last five minutes, written only after the
  plaintext checked out. The gate is keyed on the verified key's id, never on
  the presented string, so an attacker sending a fresh forged key per request
  costs one hash and one ETS read, and cannot use up the real key's alert.

### Who hears

- **Site alerts** go to `KilnCMS.Security.Alerts.site_recipients/1`: the
  site's member admins, or the platform admins when it has none (OC-1,
  #2650). A platform admin is not a member admin, so on a site that has
  member admins the platform admins never hear its site alerts. The literal
  reading of decision 2 ("member admins only") left the most common
  deployment, one site run by a platform admin with no membership, with
  nobody to tell.
- **Platform alerts** (`new_admin` at platform level,
  `platform_role_changed`, `new_api_key`, `api_key_abuse`,
  `api_key_rate_limited`) go to every platform admin by bell and email and
  never by webhook (OC-3): the only endpoints that could carry them are the
  default site's, whose admins need not be platform admins. Their bell rows
  live in the default site. Another site's console shows only a content-free
  count (`KilnCMS.Notifications.unread_platform_alert_count/2`), because that
  console is an origin where the site's own admin may run script when no
  console host is set (residual risk 16, ADR 0011).
- **Keys are attributed to the owner, never the Host.** Reuse and rate-limit
  events are recorded in the key owner's site when the owner has exactly one
  active membership, otherwise in the default site
  (`KilnCMS.Security.ApiKeyTrip.owner_org_id/1`). `new_api_key` is a platform
  kind because keys are global and only platform admins mint them.
- **Mutes.** A site alert's email respects the recipient's
  `notify_on_security_alert`; the bell row is still written. Platform alerts
  and notices ignore the mute. A site's `notify_admins` off silences its site
  alerts' bell and email (webhooks still go) and raises a notice.

### Turning a site's alerts down is never silent

Each change in `KilnCMS.Security.Alerts.notice_changes/0` raises an
`alerts_silenced` notice: a kind turned off, admin notifications turned off,
a `security.*`-subscribed webhook changed, removed, re-keyed or auto-disabled,
another person removing, demoting or ending the admin grant of a site admin,
and a person changing the site mail relay. A notice:

- **fails closed**: `AlertGate.insert_notice!/2` raises, so the change that
  would have gone unannounced rolls back with it
  (`KilnCMS.Security.Changes.NoticeAlertSettings`,
  `KilnCMS.Security.Changes.NoticeWebhookSilenced`, and the derived notices in
  `RaiseAlert`, all in the change's transaction);
- **cannot be muted or turned off**, and is never grouped into a window;
- **goes to the site-alert recipients** (OC-2), including the OC-1 fallback,
  and to the site's webhooks subscribed to `security.alerts_silenced`.

Alert mail goes through the **instance** relay (`KilnCMS.Security.AlertMail`),
so a site admin cannot reroute it by changing the site's relay; changing that
relay is itself a notice.

**The one exception is the platform toggle.** `api_key_rate_limited` is the
only optional platform kind (`Alerts.platform_optional_kinds/0`, stored in
`KilnCMS.Security.PlatformAlertSettings`). Turning it off raises no notice:
a notice goes to one site's admins, and this is the installation's setting,
which only platform admins can read or write. It is recorded instead in the
instance security log as `platform_alerts_changed`, which only platform
admins read. It is optional at all because a key over a per-address limit can
be routine for clients that batch or share an egress address.

### Defaults and fail directions

- **Every kind starts on except `failed_sign_ins`**, whose 10-in-15-minutes
  threshold ordinary typos reach on a busy site. Settings store opt-outs
  (`disabled_kinds`), so a kind a later release adds starts on, as
  `blocked_ip` did (owner decision 2026-11-12).
- **Addresses are masked by default**: an IPv4 address to its `/24`, IPv6 to
  its `/48` (`Alerts.display_ip/2`), and a block rule widened the same way
  (`Alerts.display_rule/2`), unless the site opts into `include_full_ip`.
  Platform alerts always mask. A blocked-address event records no address at
  all, only the rule and the surface (owner decision 2026-11-12), so ADR
  0026's "nothing logs the address" still holds.
- **A setting that cannot be read errs toward alerting.** Unreadable site
  settings are `Alerts.unreadable_settings/0`: every kind on,
  `failed_sign_ins` included, addresses masked. An unreadable platform
  setting treats `api_key_rate_limited` as on.

## Rejected

- **An alert emitter per feature.** Every emit site would need its own
  debounce, recipients and fail rule, and the next feature would forget one.
  Deriving from the log also means the log is the proof of what an alert
  said.
- **Oban `unique` for the debounce.** It takes a try lock that can raise
  inside `Event :record`, failing the very action being reported. A
  dedicated table with `ON CONFLICT DO NOTHING` cannot.
- **Enqueuing the delivery job in the emitter's transaction.** One more write
  that can fail a role grant. The cost of polling is up to a minute of delay.
- **Site alerts to every admin, platform admins included.** On an installation
  with many sites, each platform admin would hear every site's lockouts and
  learn to ignore them.
- **Platform alerts by webhook.** Not without a platform-admin-only
  subscription; the default site's endpoints would show its admins every
  site's admin changes and key names.
- **Merging platform alerts into each site's bell.** See ADR 0011: the rows
  would render in an origin a site admin may control.
- **A silencing notice that can be muted, or that is best effort.** The person
  turning alerts down is the one an intruder would be; a notice they can
  suppress, or one that is lost when its write fails, tells nobody.
- **Gating API-key trips on the presented key.** Each forged string would get
  its own gate (unbounded writes), or forged strings would share one and
  silence the real key.
- **Folding rate-limit trips into `api_key_abuse`.** A routine trip would
  claim the window and push a stolen key's reuse alert into a summary up to
  15 minutes later.

## Consequences

- An alert arrives within about a minute, not at once. A best-effort claim
  that fails loses that alert, and only that alert; `alert_failed` and the
  error log are the signal.
- Fixed windows mean 10 failed sign-ins that straddle a quarter hour can stay
  under the threshold in both windows.
- The node-local gates are per node: on N nodes a flood can record up to N
  times the per-node cap, and a key is "verified" only on the node it
  authenticated on.
- A site with no member admins sends its alerts to every platform admin, in
  that site's bell. Platform admins cannot opt out of platform alerts other
  than `api_key_rate_limited`.
- Turning `api_key_rate_limited` off notifies no other platform admin; the
  instance log is the only record.
- Whether a site's alerts reach anyone is checked by the security posture
  line `core.security_alerts_reach_someone`
  (`KilnCMS.Security.Posture.Checks.SecurityAlerts`).
