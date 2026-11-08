# The security log

The security log is a per-site record of security-sensitive events: who signed
in, who was locked out, who added a second factor or a passkey, who was given a
role, who made or revoked an API key, and who changed the site's sign-in or
other settings (#2241). Use it to answer "who did this, and from where?" after
the fact, and to hand an auditor a file.

It is for administrators only, it belongs to one site (organization), and it
cannot be edited: no person, an admin included, can create, change or delete an
event. Events leave the log in exactly two ways, both automatic: the retention
prune and the erasure of a person's account.

## Read the log

You need the admin role on the site. Editors and viewers do not see the page
and are refused if they open its address.

1. Open **Security log** in the console sidebar (it sits with the other
   security screens, next to **Blocked addresses**), or go to
   `/editor/security-log`.
2. Read the table, newest first: **Time**, **Event**, **Who**, **Target**,
   **IP address** and **Browser**. Failed sign-ins and lockouts are marked with
   a warning badge. **Load more** fetches the next 50.
3. To narrow it, use the filters above the table and select **Apply**:
   - **Event**: one event type (the list below), or **All events**.
   - **Who (email)**: the address of the person who acted. It matches only
     addresses already in this site's log (see "What the page will not tell
     you"). If none matches you see "No member of this site has that email
     address." and an empty list.
   - **From (UTC)** and **To (UTC)**: whole days, both included.

   **Clear** removes the filters. The filters are in the page address, so you
   can bookmark or share a filtered view with another admin.

The extra detail an event stores (the `metadata` in the table below, such as a
sign-in method or an API key's name) is kept in the database but is not shown
on the page or put in the CSV.

### What the page will not tell you

The **Who** filter looks only in this site's own log, as you. It never searches
the accounts table or another site, so it cannot be used to find out whether an
address has an account. A person who has no event yet cannot be filtered on,
and neither can one whose account was erased (their label is gone).

A failed sign-in for an address that has no account records no email at all:
the row shows an empty **Who**. The log would otherwise confirm which addresses
exist.

## Download the log as CSV

1. On **Security log**, set the filters you want.
2. Select **Download CSV**. The file is `security-log-<date>.csv`.

The file holds what the page shows for the same filters, with these columns:
`time` (ISO 8601, UTC), `type`, `actor` (the email), `target_type`,
`target_id`, `ip`, `user_agent`. It opens in a spreadsheet with a byte-order
mark so non-ASCII characters survive.

The export is bounded like the content-list export: at most the same number of
rows (10,000 by default; `config :kiln_cms, :content_export, max_rows:`), and a
rate limit per person. A log with more matching rows is not silently cut short;
the request is refused with `413 Payload Too Large` and
`{"error": "too_many_rows", ...}`. Narrow it with **From** and **To** and try
again. Cells starting with `=`, `+`, `-`, `@`, a tab or a carriage return are
prefixed with `'`, so a hostile user agent or display name cannot run as a
spreadsheet formula.

Responses other than the file:

| Status | Meaning |
|---|---|
| `403` `{"error": "admin_required"}` | You are not an admin on this site, or not signed in. |
| `413` `{"error": "too_many_rows"}` | More rows match than the cap. Narrow the date range. |
| `429` | You used up the export rate limit. Wait for `retry-after`. |

## Set how long events are kept

On the same page, under **Retention**:

1. Type a whole number in **Keep events for (days)**. `0` keeps events forever.
   The maximum is 36500.
2. Select **Save**. You see "Retention saved." and the sentence above the form
   reads "Events are deleted N days after they happen."

The default is **365 days**, and a site that never saved a value gets it.
An invalid value shows "Enter a whole number of days from 0 to 36500."

**Retention 0 keeps raw IP addresses and browser details of everyone who signs
in indefinitely.** The page says so in a warning while the value is 0. Keep 0
only if you have a documented reason; the raw address is personal data (see
"Privacy" below).

A daily job deletes events older than the window, in batches. It runs at
`20 3 * * *` (03:20 UTC) unless you change it with `KILN_SECURITY_LOG_PRUNE_CRON`
([environment-variables.md](environment-variables.md), under the schedules table).
Shortening the window deletes the older events at the next run, and that cannot
be undone. If the retention setting cannot be read at that moment the site is
skipped, so a fault never deletes on a window nobody confirmed.

## What is recorded

Every event has a time, a type, the person who acted (an email snapshot and
their id, only for a known account), an optional target (a user, an API key, a
setting), the IP address and the user agent of the request, and a short
allowlisted `metadata` map. No metadata ever holds a password, a key, a token,
a setting's value or an email address. Values are capped at 200 characters and
a type may carry only the keys below; anything else is dropped.

| Type (CSV `type`) | Label on the page | Written when | `metadata` keys |
|---|---|---|---|
| `sign_in` | Sign-in | A sign-in completed, every factor passed | `method` |
| `sign_in_failed` | Failed sign-in | A wrong password, or a wrong second-factor code. Sampled: see below | `method`, `reason` |
| `sign_in_locked` | Sign-in locked out | A throttle refused an attempt. First refusal per subject and scope each 15 minutes | `method`, `scope` |
| `second_factor_enrolled` | Second factor added | An authenticator app was confirmed | `kind` |
| `second_factor_removed` | Second factor removed | Two-factor sign-in was turned off | `kind` |
| `recovery_code_used` | Recovery code used | A recovery code was spent at the code prompt | `remaining` |
| `passkey_added` | Passkey added | A passkey was registered | `name` |
| `passkey_removed` | Passkey removed | A passkey was deleted | `name` |
| `role_granted` | Role granted | A membership was created, or a role was raised | `role`, `previous_role` |
| `role_revoked` | Role revoked | A role was lowered, a membership removed, or a temporary elevation ended early | `role` |
| `elevation_granted` | Temporary elevation granted | A time-boxed role was granted | `role`, `minutes` |
| `api_key_created` | API key created | A key was minted, or a draft-write key was rotated into a new one | `name`, `scope` |
| `api_key_revoked` | API key revoked | A key was revoked (a repeat revoke records nothing) | `name` |
| `sso_config_changed` | Single sign-on changed | The site's identity provider or a verified SSO domain was saved, verified or removed | `provider`, `change` |
| `org_setting_changed` | Site setting changed | Any other site-level setting, or a blocked-address rule, was saved or removed | `setting` |

`method` is `password`, `password_reset`, `magic_link`, `sso`, `passkey`,
`second_factor` or `other`. `reason` is `invalid_credentials` or
`invalid_code`. `scope` is `account`, `address`, `second_factor` or
`settings`. `change` is `created`, `updated` or `removed`; `provider` is
`site_oidc` or `site_sso_domain`. `setting` is the settings resource's short
name, for example `site_mail_relay`; it names the setting and never its value.

### Failed sign-ins are sampled, lockouts are not

A password-guessing flood must not fill the log, so at most **5 failed
sign-ins per IP address per 15 minutes** are written; the rest are dropped.
Each lockout is written once per subject and scope per 15 minutes (a locked
account refuses every attempt until its window rolls, and one event says so).
Both counters live in the same database-backed store as the sign-in throttles
(`KilnCMS.Accounts.ThrottleStore`), so they hold across nodes and restarts.

### Which site's log

An event is written to the log of the site the request resolved to. A request
to an unknown host has no site and records nothing. A failed sign-in or lockout
labels the account only if it belongs to that site (a membership on it, or the
legacy no-membership account on the default site); an account of another site
appears as an unknown address. A role change is written to the log of the
membership's own site, whichever site the admin was viewing; a user's global
role is written to the site the request ran on.

## Event matrix: where each event comes from

This is the list a reviewer checks. "In txn" means the event is written inside
the same database transaction as the change, so it commits or rolls back with
it; "after commit" means best-effort once the change is committed, and a failure
never fails the sign-in or action it reports on (it is logged and counted, see
"Watching for failures").

All sites write through `KilnCMS.Security.Recorder` (`record/2` in txn,
`record_after_commit/2`, `record_sampled/2`), either via the Ash change
`KilnCMS.Security.Changes.Record` or the sign-in helpers in
`KilnCMS.Security.AuthEvents`.

| Event | Emit site (file: function or action) | Method |
|---|---|---|
| `sign_in` | `lib/kiln_cms_web/controllers/auth_controller.ex`: `complete_sign_in/4`. Every password, magic-link, SSO and post-second-factor browser sign-in ends here; `TwoFactorController` reaches it through `complete_sign_in/3` | after commit; `method` from the strategy (`AuthEvents.method/1`) |
| `sign_in` | `lib/kiln_cms_web/controllers/passkey_controller.ex`: `verify/2` | after commit; `method: "passkey"` |
| `sign_in` | `lib/kiln_cms_web/controllers/api_auth_controller.ex`: `issue_token/2` (the headless token API, `sign_in/2` and `verify/2`) | after commit; `method: "password"` |
| `sign_in_failed` (wrong password) | `lib/kiln_cms/security/preparations/audit_sign_in.ex`, on `User` `:sign_in_with_password` (`lib/kiln_cms/accounts/user.ex`) | sampled, after commit; `method: "password"`, `reason: "invalid_credentials"` |
| `sign_in_failed` (wrong code) | `lib/kiln_cms/accounts/second_factor.ex`: `check/3` (`audit_failure/3`), used by `TwoFactorController.verify` and `ApiAuthController.verify` | sampled; `method: "second_factor"`, `reason: "invalid_code"` |
| `sign_in_locked` (account, address) | `audit_sign_in.ex`, via `AuthEvents.password_locked/3`, when `ThrottleSignIn` refuses | after commit; `method: "password"`, `scope: "account"` or `"address"` |
| `sign_in_locked` (second factor at sign-in) | `lib/kiln_cms/accounts/second_factor.ex`: `check/3` on a denied budget | after commit; `scope: "second_factor"` |
| `sign_in_locked` (second factor in settings) | `lib/kiln_cms/accounts/changes/throttle_second_factor.ex`: on a denied budget (turning 2FA off, regenerating recovery codes) | after commit; `scope: "settings"` |
| `second_factor_enrolled` | `User` `:confirm_totp` (`lib/kiln_cms/accounts/user.ex`) | in txn; `kind: "totp"` |
| `second_factor_removed` | `User` `:disable_totp` | in txn; `kind: "totp"` |
| `recovery_code_used` | `User` `:consume_totp_recovery_code` | in txn; `remaining` is the count left |
| `passkey_added` | `Accounts.Passkey` `:register` (`lib/kiln_cms/accounts/passkey.ex`) | in txn; `name` |
| `passkey_removed` | `Accounts.Passkey` `:destroy` | in txn; `name`; target is the owner |
| `role_granted` / `role_revoked` | `lib/kiln_cms/security/changes/record_role_change.ex`, on `User` `:manage_access` and `OrgMembership` `:create`, `:update`, `:destroy` (`lib/kiln_cms/accounts/org_membership.ex`) | in txn; an edit that leaves the role alone (audiences, type scopes) writes nothing |
| `elevation_granted`, and `role_revoked` when cleared early | `lib/kiln_cms/security/changes/record_elevation.ex`, on `User` and `OrgMembership` `:grant_temporary_role` | in txn; `minutes` until it lapses |
| `api_key_created` | `Accounts.ApiKey` `:create` and `:rotate` (`lib/kiln_cms/accounts/api_key.ex`) | in txn; `name`, `scope` (the key's `access`); never the key or its hash |
| `api_key_revoked` | `Accounts.ApiKey` `:revoke` and `:retire_rotated` | in txn; only when the key was not already revoked |
| `sso_config_changed` | `CMS.SiteSsoProvider` (every write, via the `audit: :sso_config` option of `use KilnCMS.CMS.OrgSettings`, `lib/kiln_cms/cms/site_sso_provider.ex`), and `CMS.SiteSsoDomain` `:add`, `:verify`, `:remove` (`lib/kiln_cms/cms/site_sso_domain.ex`) | in txn; never the issuer, client id, secret or domain |
| `org_setting_changed` | `lib/kiln_cms/cms/org_settings.ex`: the `use KilnCMS.CMS.OrgSettings` macro adds `Changes.RecordOrgSetting` to every write of every settings resource, and `CMS.IpBlockRule` `:create`, `:destroy` (`lib/kiln_cms/cms/ip_block_rule.ex`) | in txn; names the setting, never a value. The retention setting itself is one of them |

`org_setting_changed` covers every resource built with `use
KilnCMS.CMS.OrgSettings`, so a new settings resource cannot forget it:
`CMS.FeedSettings`, `FormSpamSettings`, `SiteAiProvider`, `SiteBranding`,
`SiteCodeInjection`, `SiteCompliance`, `SiteEditorialSettings`,
`SiteEmbedSettings`, `SiteLinkCheck`, `SiteLocaleSettings`, `SiteMailRelay`,
`SiteMeilisearch`, `SitePasswordPolicy`, `SiteSafetyFields`, `SiteSecurityLog`,
`SiteSecurityTxt`, `SiteStorage`, `SiteVapidKey` and
`Federation.SiteFederation`. (`SiteSsoProvider` is the exception that records
`sso_config_changed` instead.)

Only a person's write is an event. `RecordOrgSetting` skips a write with no
user as its actor (the VAPID key generated on first use, a federation sync, a
seed), because no one took that decision. The org-setting events are only
complete for writes whose caller passed the request context: the console pages
do. A write from a script or `iex` carries no IP address or user agent; it is
recorded as long as it names a user actor and a tenant.

### Not recorded, and why

| Thing | Status | Reason |
|---|---|---|
| Plugin install or enable | Not applicable | Plugins are compiled into the release; there is no runtime path that installs or enables one, so there is nothing to hook. A change shows up as a deploy. |
| Remember-me sign-in | Not recorded | A valid remember-me cookie is turned into a session by the read plug (`store_in_session/2`), which never passes through `AuthController.complete_sign_in/4`. The original sign-in that issued the cookie is recorded. |
| Failed magic-link, SSO and passkey sign-ins | Not recorded | Only the password action (`:sign_in_with_password`) and the second-factor prompt have an audit hook. The other strategies do not have a point where a refusal is observed. The successful ones are recorded (`sign_in` with `method`). |
| Sign-in with a token (`:sign_in_with_token`) | Not recorded | Not audited: no hook. |
| Temporary elevation lapsing | Not recorded | `OrgMembership` `:expire_role_grant` and `User` `:expire_role_grant` clear a dead column. Expiry is a comparison, not an act; `elevation_granted` already carried the end time (`minutes`). |
| Erasing a user | Not recorded as an event | `User` `:anonymize` forces the role through a different action and writes no event, and the recorder refuses any event whose acting user is the one being erased. The erasure scrubs the log instead (below). |
| Changing a member's audiences or type scopes | Not recorded | Only a changed role is. `SiteAudiences.set/4` and an `OrgMembership` `:update` that leaves `role` alone write nothing. |
| Unknown host | Not recorded | No site to attribute it to; the event is skipped. |
| Anything that is not a person's write to a settings resource | Not recorded | See above. |

## Privacy: IP addresses, erasure and staging

The log stores the raw IP address and the user agent of each event, and an
email snapshot for known accounts. It does not truncate or hash the address.
They stay until the retention prune or an erasure removes them, so set a window
you can defend (default 365 days), and list the table in your records of
processing. [data-flows.md](data-flows.md) has the full inventory.

**Erasure.** When an admin erases a user
(see *Erasure (GDPR Art. 17)* in [data-flows.md](data-flows.md)), the same
transaction runs `KilnCMS.Security.anonymize_actor/1` across every site. For
each event the user acted in, `actor_id`, `actor_label`, `ip` and `user_agent`
are cleared; for each event that names them as its target, `target_id` is
cleared; and `metadata` is emptied on every event touched, because a passkey's
or API key's name can be the person's own words. The event itself, its type and
its time remain, so the log still shows that something happened. It is
idempotent, and it **fails closed**: a failure in any site is logged, the
sweep continues, and the erasure then raises so it can be retried, rather than
reporting a partial erasure as done.

**Staging.** `KilnCMS.Staging.Scrub` (`mix kiln.staging.scrub`, see
[deploy-staging.md](deploy-staging.md)) deletes every row of `security_events`
from a clone of production and reports `security_events_purged`.

**Not an API.** The log is not on JSON:API, GraphQL or MCP, so there is no
token that can read it. The only reads are the console page and the CSV above,
both admin-gated and scoped to the site you are on. The `kiln_reporting_v1`
SQL views do not include it and are unaffected.

## Watching for failures

An audit write must never break the sign-in or action it reports on, so a
failed write is not shown to the user. It is visible only in the application
log (`security event <type> not recorded: ...`, at `error`) and on two
telemetry events:

| Telemetry event | Meaning |
|---|---|
| `[:kiln_cms, :security, :event_failed]` | An event could not be written. Metadata: `type`. Wire an alert to this one. |
| `[:kiln_cms, :security, :event_sampled_out]` | An event was dropped on purpose: a failed sign-in over the per-IP cap, or a repeat lockout in the same window. Metadata: `type`. A sustained rate is a guessing attack. |

Events written inside a transaction (credentials, roles, API keys, settings)
are different: if the event cannot be written, the change rolls back and the
person sees the usual error, so a credential change is never unrecorded.

## For developers

- Domain: `KilnCMS.Security` (an Ash domain; an overlay that restates
  `:ash_domains` must add it, see [overlay-contract.md](overlay-contract.md)).
  Resource: `KilnCMS.Security.Event`. Settings: `KilnCMS.CMS.SiteSecurityLog`.
- Add an emit site to an Ash action with one line:
  `change {KilnCMS.Security.Changes.Record, type: :passkey_added, target: fn record, _cs -> {"user", record.user_id} end, metadata: fn record, _cs -> %{"name" => record.name} end}`.
  Options (`:mode`, `:user`, `:target`, `:metadata`, `:when`, `:tenant`) are in
  the module's docs. Pass the request context into the action with
  `context: socket.assigns.security_context` (LiveView) or
  `KilnCMS.Security.AuthEvents.context(conn)` (controllers). Without it the event
  is still written but has no IP address or user agent.
- A new event type needs an entry in `KilnCMS.Security.Event` (`@types`, and its
  `metadata` keys), a label in `KilnCMSWeb.SecurityLog.type_label/1`, and a row
  in the matrix above.
- Authorization: reads are org-admin only. The recorder, the erasure sweep and
  the prune run as `KilnCMS.Security.system/0`. See
  *Security audit log* in [policy-matrix.md](policy-matrix.md).

## Troubleshooting

| You see | Meaning |
|---|---|
| The **Security log** entry is missing from the sidebar | You are not an admin on this site. |
| "You don't have permission to view or change this site's security log." | Your role was lowered while the page was open. Reload. |
| "The log could not be loaded." | The read failed; try again, and check the application log. |
| "No member of this site has that email address." | The **Who** filter matched no actor label in this site's log. Check the spelling, or that the person has an event on this site. |
| An expected event is missing | Check the "Not recorded" table; then the sampling cap for failed sign-ins; then `[:kiln_cms, :security, :event_failed]` and the log. |
| `413` on the CSV | More rows match than the export cap. Narrow the date range. |
| Old events are still there | The prune runs once a day, and `KILN_SECURITY_LOG_PRUNE_CRON=false` turns it off; or retention is 0. |
