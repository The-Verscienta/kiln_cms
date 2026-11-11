# The security log

The security log is a per-site record of security-sensitive events: who signed
in, who was locked out, who added a second factor or a passkey, who was given a
role, who made or revoked an API key, and who changed the site's sign-in or
other settings (#2241). Use it to answer "who did this, and from where?" after
the fact, and to hand an auditor a file.

Some of these events also raise a [security alert](security-alerts.md): a bell
notification and an email to the site's admins, or to the platform admins, as
it happens.

It is for administrators only, it belongs to one site (organization), and it
cannot be edited: no person, an admin included, can create, change or delete an
event. Events leave the log in exactly two ways, both automatic: the retention
prune and the erasure of a person's account.

## Read the log

You need the admin role on the site. Editors and viewers do not see the page
and are refused if they open its address.

1. Open **Security log** under **Organization** in the console sidebar, or go to
   `/editor/security-log`.
2. Read the table, newest first: **Time**, **Event**, **Who**, **Target**,
   **IP address** and **Browser**. Failed sign-ins, lockouts, refused unlock
   links and a rotated API key used again are marked with a warning badge. **Load more** fetches the next 50.
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
| `sign_in_failed` | Failed sign-in | A wrong password, a wrong second-factor code, or a password sign-in refused by [human verification](human-verification.md) (a token that did not pass, or the provider down past the point where sign-ins are let through). Sampled: see below | `method`, `reason` |
| `sign_in_locked` | Sign-in locked out | A throttle refused an attempt. First refusal per subject and scope each 15 minutes | `method`, `scope` |
| `second_factor_enrolled` | Second factor added | An authenticator app was confirmed | `kind` |
| `second_factor_removed` | Second factor removed | Two-factor sign-in was turned off, or removed when an invitation took over an unconfirmed account (see below) | `kind`, `via` |
| `recovery_code_used` | Recovery code used | A recovery code was spent at the code prompt | `remaining` |
| `passkey_added` | Passkey added | A passkey was registered | `name` |
| `passkey_removed` | Passkey removed | A passkey was deleted, by its owner or an admin, or when an invitation took over an unconfirmed account | `name`, `via` |
| `role_granted` | Role granted | A membership was created, or a role was raised | `role`, `previous_role`, `level`, `via` |
| `role_revoked` | Role revoked | A role was lowered, a membership removed, a temporary elevation ended early, or a live temporary admin grant replaced by a lower one | `role`, `level`, `change` |
| `member_invited` | Member invited | An admin invited an address to the site, or resent an invitation | `role`, `resent` |
| `invitation_revoked` | Invitation revoked | An admin revoked a pending invitation, or changed the tier or custom role of the person it names, or removed them, which retires it | `role` |
| `elevation_granted` | Temporary elevation granted | A time-boxed role was granted | `role`, `minutes`, `level`, `via` |
| `api_key_created` | API key created | A key was minted, or a draft-write key was rotated into a new one | `name`, `scope`, `via` |
| `api_key_revoked` | API key revoked | A key was revoked by an admin, or when an invitation took over its unconfirmed account (a repeat revoke records nothing) | `name` |
| `sso_config_changed` | Single sign-on changed | The site's identity provider or a verified SSO domain was saved, verified or removed | `provider`, `change` |
| `org_setting_changed` | Site setting changed | Any other site-level setting, or a blocked-address rule, was saved or removed | `setting` |
| `ip_auto_blocked` | Address blocked automatically | The [scanner guard](ip-blocking.md#block-scanners-automatically) temporarily blocked an address for racking up 404s or probing bait paths. The address is the event's IP; there is no acting person | `reason`, `count`, `window_minutes`, `block_minutes` |
| `session_idle_expired` | Signed out after inactivity | A browser session (with its remember-me cookie) was signed out by the site's [idle timeout](account-administration.md#sign-people-out-when-idle). The person is the account signed out | `timeout_minutes`, `tier`, `surface` |
| `all_sessions_revoked` | Everyone signed out | An admin used [Sign out everyone](account-administration.md#sign-everyone-out); the target is the site (target type `organization`) | `count`, `except_self` |
| `admin_access_refused` | Refused outside the admin allowlist | A request, page connection or collaboration connect from an address the site's [admin allowlist](admin-allowlist.md) does not list was refused. No person (the gate runs before anyone is known); the address is the event's IP. Sampled: see below | `surface` |
| `admin_allowlist_changed` | Admin allowlist changed | An admin saved the site's [admin allowlist](admin-allowlist.md), including turning it off. The target is the list (target type `site_admin_allowlist`) | `state`, `count`, `added`, `removed`, `sign_in` |
| `admin_allowlist_overridden` | Admin allowlist changed from the server | An operator widened or cleared the list with [`KilnCMS.Release.admin_allowlist/1`](admin-allowlist.md#recovering-from-a-lock-out). No person and no IP address; the target is the site (target type `organization`) | `change`, `count` |
| `sign_in_unlock_requested` | Sign-in unlock link sent | An [unlock link](account-administration.md#lift-a-sign-in-pause-by-email) was mailed to a paused account. Only once the mail is queued: a request that sends nothing records nothing. The person is the account mailed | `surface` |
| `sign_in_unlocked` | Sign-in pause lifted by email | An unlock link was redeemed and the account's sign-in pause cleared. The person is the account | `was_locked` |
| `sign_in_unlock_refused` | Sign-in unlock link refused | An unlock link was not redeemed. The person is named only when the link's signature verified and the account belongs to this site. Sampled: see below | `reason` |
| `registration_queued` | Registration awaiting approval | A password sign-up on a site that [requires approval](account-administration.md#approving-registrations) was queued, or a new account from the site's own single sign-on on a site that [holds those](account-administration.md#hold-new-single-sign-on-accounts-too). No acting person (the registration's own system write); the target is the new account | `method` |
| `registration_approved` | Registration approved | A waiting or rejected registration was approved: by a site admin on Registrations, by the applicant accepting an invitation to the site (no person), or by a platform admin adding the address on Team. The target is the applicant | `role`, `via` |
| `registration_rejected` | Registration rejected | A site admin rejected a waiting registration. The person is the admin; the target is the applicant, or none when the account was erased | `outcome` |
| `backup_canceled` | Backup canceled | A platform admin [canceled a running backup](backups.md#cancel-a-running-backup). Always in the default site's log. The person is the admin; the target is the backup run (target type `backup_run`) | `stamp`, `step` |
| `api_key_reuse_detected` | Rotated API key used again | A draft-write key that had been rotated away was presented to `POST /api/keys/rotate` more than 120 seconds after its rotation, so two parties held it, and the live key of its lineage was revoked ([self-rotation](headless-consumer-guide.md#keeping-the-key-alive-self-rotation)). No person; the target is the presented key (target type `api_key`), the IP the request's. Raises the platform's `api_key_abuse` [alert](security-alerts.md) | `name`, `revoked` |

`method` is `password`, `password_reset`, `magic_link`, `sso`, `passkey`,
`second_factor` or `other`. `reason` is `invalid_credentials`,
`invalid_code`, `challenge_failed` (the human-verification provider refused
the token) or `challenge_unavailable` (the provider could not be reached and
the attempt was refused anyway). A sign-in that was merely asked for a check,
with no token, records nothing: it is not a failed attempt. `scope` is `account`, `address`, `second_factor` or
`settings`. `change` is `created`, `updated` or `removed`; `provider` is
`site_oidc` or `site_sso_domain`. `setting` is the settings resource's short
name, for example `site_mail_relay`; it names the setting and never its value.

The role events carry what the [security alerts](security-alerts.md) need to
tell a new site admin from a new platform admin (#2245):

- `level` (on `role_granted`, `role_revoked` and `elevation_granted`) is
  `site` for a membership and `platform` for the account's own role.
- `change` (on `role_revoked`) is `removed` (the membership was deleted),
  `demoted` (the role was lowered) or `grant_revoked` (a temporary role ended
  early). For `removed`, `role` is the role the member effectively held, so
  removing a member whose admin power came from a live temporary grant
  records `admin`.
- `via` (on `role_granted` and `elevation_granted`) is `legacy_carry` when an
  account from before multi-site memberships got its first membership and its
  standing role or grant was copied onto it. It held that role already.
  Absent otherwise.

Replacing a member's live temporary **admin** grant with a lower temporary
role records two events: the `elevation_granted` of the new grant, and a
`role_revoked` (`role` `admin`, `change` `grant_revoked`) for the admin power
it ended.

For `api_key_created`, `via` is `rotate` when the key was minted by rotating
its predecessor (absent for a key an admin minted). For
`api_key_reuse_detected`, `name` is the presented key's name and `revoked` the
number of live keys of its lineage the detection revoked; a lineage that is
already dead records nothing.

For `session_idle_expired`, `timeout_minutes` is the timeout that applied,
`tier` is `admin` when it was the administrators' own timeout and `member` when
it was everyone's, and `surface` is where it was noticed: `http` (a request),
`live` (an open page) or `remember_me` (a remember-me cookie that sat unused too
long). For `all_sessions_revoked`, `count` is the number of browser sessions
signed out (remember-me cookies and two-factor holds are not counted) and
`except_self` is `true` when the admin kept their own browser. Saving the idle
timeout itself is `org_setting_changed` with `setting` `site_session_policy`.

For `admin_access_refused`, `surface` is where the refusal happened: `http`
(a console, `/setup` or sign-in page), `api` (`POST /api/auth/sign_in` or
`/api/auth/sign_in/verify`), `live` (a page's LiveView connection) or `collab`
(the collaborative-editing socket). A refusal because the list could not be read
is not an event; it is only counted (see
[admin-allowlist.md](admin-allowlist.md#when-the-list-cannot-be-read)).

For `admin_allowlist_changed`, `state` is `on` or `off` after the save, `count`
the number of entries after it, `added` and `removed` how many entries the
save added and removed, and `sign_in` whether the list also gates sign-in
after it (`restricted` or `open`, "Also restrict sign-in", #2493; absent on
events from before that setting). The entries themselves are never recorded: an allowlist
is often the admins' own home and office addresses, and the log keeps what it
records for its whole retention. The page shows the current entries. This
event replaces `org_setting_changed` for this setting, so a save is still
exactly one event. For `admin_allowlist_overridden`, `change` is `cleared` or
`added` and `count` the number of entries after the change.

For `sign_in_unlock_requested`, `surface` is always `browser`: the link can
only be asked for on `/sign-in/unlock`. For `sign_in_unlocked`, `was_locked`
is `true` when the account was still paused at the moment of the redeem and
`false` when the pause had already ended on its own. For
`sign_in_unlock_refused`, `reason` is `invalid` (made up, malformed, or not an
unlock link), `expired` (older than 15 minutes), `used` (already redeemed, or
revoked by a password change or reset), `wrong_site` (opened on another site's
host; the link is not spent and still works on its own site) or
`account_changed` (the account's address changed, or the account was erased).
The person sees one page for all of them. Opening a link without pressing the
button records nothing.

For `registration_queued`, `method` is `password` (a sign-up at `/register`)
or `site_sso` (a new account the site's own single sign-on provisioned; the
event carries the address the sign-in came from). For `registration_approved`,
`role` is the tier the membership now grants and `via` says how:

- `queue`: a site admin approved it on the Registrations page, always as
  `viewer`. The person is that admin;
- `invitation`: the applicant accepted an invitation to the site, which
  approves the registration with the invited tier
  ([Invitations and registrations](account-administration.md#invitations-and-registrations)).
  No person: the system honours the invitation (`SystemActor` `:invitations`);
- `added`: a platform admin entered the address in Team's **Add or invite**,
  approving it with the tier they picked. The person is that admin. This is
  also how a rejection is overridden from Team, so a `registration_approved`
  with `via` `added` after a `registration_rejected` for the same target is
  that override.

For `registration_rejected`, `outcome` is `kept` (the account and its row
stay) or `erased` (#2514: the site erases unconfirmed applicants it rejects,
and this account qualified, so it was
[erased](account-administration.md#erase-unconfirmed-applicants-you-reject) in
the same transaction; the row stays, `:rejected`). An `erased` event has **no
target**: it is recorded after the erasure, and a target would only point at
an account that no longer identifies anyone. The person is still the admin who
rejected, not the system actor that ran the erasure. Neither the queued row
nor any approval writes a `role_granted` as well. Changing any of the
Registrations settings (either approval switch, or what rejecting does to the
account) is `org_setting_changed` with `setting` `site_registration`.

For `ip_auto_blocked`, `reason` is `miss_threshold` or `bait_path`, `count` is
the threshold that was crossed, and `window_minutes` and `block_minutes` are the
settings in force. The requested path is attacker-controlled and is never
recorded. The rule the guard stores is created by a system actor, and
`org_setting_changed` is only written for a person's change, so an automatic
block produces `ip_auto_blocked` alone.

`resent` is `true` for a resend, and for inviting an address whose invitation
had expired. The two invitation events target the invitation (target type
`invitation`), never the invited address, which is not stored in the log. When
the invitee accepts, the membership that creates is recorded as `role_granted`
with no person, because nobody signed in did it; the target is the new or
existing account. An invitee who was already a member at a lower tier is
raised to the invited one (`OrgMembership` `:raise_role_by_invitation`,
#2452), also recorded as `role_granted` with no person, with `role` and
`previous_role`; one who already held the invited tier or a higher one is left
as they were, and nothing is recorded. When an admin changes a member's tier
or custom role, or removes them, the invitation still pending for that
person's address on that site is retired (`Invitation` `:retire`, #2452) and
recorded as `invitation_revoked`, with that admin as the person and the
invitation's tier as `role`, beside the `role_granted` or `role_revoked` of
the change itself.
When the invitee had a waiting or rejected registration on
the site, accepting approves that row instead, recorded as
`registration_approved` with `via` `invitation` and no `role_granted`.

When the invitee sets a password over an account someone registered for the
address but never confirmed, accepting takes that account over and removes
every credential the first registrant could have set up (#2453). Each removal
is recorded with no person, beside the membership's own event: `second_factor_removed`
(`kind` `totp`, `via` `invitation`) when the account had confirmed two-step
verification, `passkey_removed` (`name`, `via` `invitation`) for each passkey,
targeting the account, and `api_key_revoked` (`name`) for each key that was
still live, targeting the key. They go to the log of the site the invitation
page was opened on, or the invited site when the request names none. A
confirmed account accepting with one click loses nothing and records none of
these. `via` is absent on the events a person causes.

### Failed sign-ins, allowlist and unlock refusals are sampled, lockouts are not

A password-guessing flood must not fill the log, so at most **5 failed
sign-ins per IP address per 15 minutes** are written; the rest are dropped.
Anyone outside an admin allowlist can cause `admin_access_refused` just by
opening `/sign-in`, so it is capped the same way, at **5 per address per 15
minutes** on each site, with its own counter (a flood of one cannot use up the
other's budget). Anyone can post made-up unlock links, so
`sign_in_unlock_refused` is capped the same way again, at **5 per address per
15 minutes** on each site, with a counter of its own. An IPv6 address counts as
its `/64`, because one client can rotate through its whole prefix.
Each lockout is written once per subject and scope per 15 minutes (a locked
account refuses every attempt until its window rolls, and one event says so).
When a site has the `failed_sign_ins` [alert](security-alerts.md#failed-sign-ins-are-counted-per-site)
turned on, every failed sign-in is also counted on the site's alert tally
before sampling, and the one attempt that brings the site to 10 in a window is
written even when its address has used up its 5. Both counters live in the same database-backed store as the sign-in throttles
(`KilnCMS.Accounts.ThrottleStore`), so they hold across nodes and restarts.

### Which site's log

An event is written to the log of the site the request resolved to. A request
to an unknown host has no site and records nothing. A failed sign-in or lockout
labels the account only if it belongs to that site (a membership on it, or the
legacy no-membership account on the default site); an account of another site
appears as an unknown address. A role change is written to the log of the
membership's own site, whichever site the admin was viewing; a user's global
role is written to the site the request ran on. Invitation events likewise go to
the invited site's log. Registration events go to the log of the site the registration
waits on, which may be the default site for a sign-up on another site's host,
whichever host the deciding admin was on. A canceled backup belongs to the
whole installation, not to a site, so `backup_canceled` always goes to the
default site's log. A reused API key (`api_key_reuse_detected`) goes to the log
of the key owner's site when the owner has exactly one active membership, and
to the default site's otherwise; the host the request named never decides,
since whoever presents the key chooses it.

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
| `sign_in_failed` (human verification) | `audit_sign_in.ex`, when `ThrottleSignIn` refuses with `KilnCMS.Accounts.Errors.ChallengeRequired` (`KilnCMS.Challenge.Gate`) | sampled, after commit; `method: "password"`, `reason: "challenge_failed"` or `"challenge_unavailable"` |
| `sign_in_failed` (wrong code) | `lib/kiln_cms/accounts/second_factor.ex`: `check/3` (`audit_failure/3`), used by `TwoFactorController.verify` and `ApiAuthController.verify` | sampled; `method: "second_factor"`, `reason: "invalid_code"` |
| `sign_in_locked` (account, address) | `audit_sign_in.ex`, via `AuthEvents.password_locked/3`, when `ThrottleSignIn` refuses | after commit; `method: "password"`, `scope: "account"` or `"address"` |
| `sign_in_locked` (second factor at sign-in) | `lib/kiln_cms/accounts/second_factor.ex`: `check/3` on a denied budget | after commit; `scope: "second_factor"` |
| `sign_in_locked` (second factor in settings) | `lib/kiln_cms/accounts/changes/throttle_second_factor.ex`: on a denied budget (turning 2FA off, regenerating recovery codes) | after commit; `scope: "settings"` |
| `second_factor_enrolled` | `User` `:confirm_totp` (`lib/kiln_cms/accounts/user.ex`) | in txn; `kind: "totp"` |
| `second_factor_removed` | `User` `:disable_totp`, and `lib/kiln_cms/accounts/changes/forget_prior_credentials.ex` on `User` `:accept_invitation_with_password` (#2453) when the row it re-reads under lock had a confirmed factor | in txn; `kind: "totp"`; from the takeover, also `via: "invitation"` and no person |
| `recovery_code_used` | `User` `:consume_totp_recovery_code` | in txn; `remaining` is the count left |
| `passkey_added` | `Accounts.Passkey` `:register` (`lib/kiln_cms/accounts/passkey.ex`) | in txn; `name` |
| `passkey_removed` | `Accounts.Passkey` `:destroy`, and `:forget_on_takeover` (#2453, from `Changes.ForgetPriorCredentials`, as `SystemActor.new(:invitations)`) | in txn; `name`; target is the owner; from the takeover, also `via: "invitation"` and no person |
| `role_granted` / `role_revoked` | `lib/kiln_cms/security/changes/record_role_change.ex`, on `User` `:manage_access` and `OrgMembership` `:create`, `:update`, `:destroy`, `:raise_role_by_invitation` (`lib/kiln_cms/accounts/org_membership.ex`) | in txn; an edit that leaves the role alone (audiences, type scopes) writes nothing |
| `member_invited` | `Accounts.Invitation` `:invite` and `:resend` (`lib/kiln_cms/accounts/invitation.ex`), also reached through `:add_or_invite` | in txn; `role`, `resent`; tenant is the invitation's site |
| `invitation_revoked` | `Accounts.Invitation` `:revoke`, and `:retire` (#2452, from `Changes.RetirePendingInvitation` on `OrgMembership` `:update` and `:destroy`, as `SystemActor.new(:invitations)`) | in txn; `role` is the invitation's tier; for `:retire`, the person is the admin who made the membership change, or none when system code made it |
| `elevation_granted`, and `role_revoked` when cleared early or when a live admin grant is replaced by a lower one | `lib/kiln_cms/security/changes/record_elevation.ex`, on `User` and `OrgMembership` `:grant_temporary_role` | in txn; `minutes` until it lapses; `level`; `change: "grant_revoked"` on the `role_revoked` |
| `api_key_created` | `Accounts.ApiKey` `:create` and `:rotate` (`lib/kiln_cms/accounts/api_key.ex`) | in txn; `name`, `scope` (the key's `access`), and `via: "rotate"` from `:rotate`; never the key or its hash |
| `api_key_revoked` | `Accounts.ApiKey` `:revoke` and `:retire_rotated`; `:revoke` is also called by `Changes.ForgetPriorCredentials` (#2453) for each live key of an account an invitation takes over, with no person | in txn; only when the key was not already revoked; target is the key |
| `sso_config_changed` | `CMS.SiteSsoProvider` (every write, via the `audit: :sso_config` option of `use KilnCMS.CMS.OrgSettings`, `lib/kiln_cms/cms/site_sso_provider.ex`), and `CMS.SiteSsoDomain` `:add`, `:verify`, `:remove` (`lib/kiln_cms/cms/site_sso_domain.ex`) | in txn; never the issuer, client id, secret or domain |
| `org_setting_changed` | `lib/kiln_cms/cms/org_settings.ex`: the `use KilnCMS.CMS.OrgSettings` macro adds `Changes.RecordOrgSetting` to every write of every settings resource, and `CMS.IpBlockRule` `:create`, `:destroy` (`lib/kiln_cms/cms/ip_block_rule.ex`) | in txn; names the setting, never a value. The retention setting itself is one of them |
| `ip_auto_blocked` | `lib/kiln_cms/security/scanner_guard.ex`, after the guard's `CMS.IpBlockRule` `:create` succeeds, via `Recorder.record_after_commit/2` | outside the transaction, off the request path; skipped when the guard is off, the cap is reached or a recent sign-in from the address exists |
| `session_idle_expired` | `lib/kiln_cms/accounts/idle_timeout.ex`: `check/3`, once the expiring UPDATE matched the row (a racing tab that kept the session awake records nothing). Reached from `KilnCMSWeb.Plugs.IdleTimeout` (requests, remember-me) and `KilnCMSWeb.IdleSession` (open pages) | after commit; tenant is the site the request was on; target type `session`, no target id |
| `all_sessions_revoked` | `lib/kiln_cms/accounts/sign_out_all.ex`: `run/3`, the `:sign_out_all` action of `CMS.SiteSessionPolicy` | in txn, with the revocation and the watermark: if the event cannot be written nothing is signed out |
| `admin_access_refused` | `KilnCMSWeb.AdminAllowlist.record_refusal/4`, called from `lib/kiln_cms_web/plugs/admin_allowlist.ex` (`surface` `http` or `api`) and from `lib/kiln_cms_web/admin_allowlist.ex`: the LiveView `on_mount` (`live`) and `check_connect/2`, from the collab socket's `connect/3` in `lib/kiln_cms_web/channels/collab_socket.ex` (`collab`) | sampled, after commit; only for an address not on the list, never for a list that could not be read |
| `admin_allowlist_changed` | `lib/kiln_cms/cms/changes/record_admin_allowlist_change.ex`, on `CMS.SiteAdminAllowlist` `:save` and `:update` (the `audit: {:change, ...}` option of `use KilnCMS.CMS.OrgSettings`) | in txn; only when the actor is a user. The previous list is read in the same transaction; if it cannot be read the save fails |
| `admin_allowlist_overridden` | `lib/kiln_cms/cms/changes/operator_override_admin_allowlist.ex`, on `CMS.SiteAdminAllowlist` `:operator_override`, run by `KilnCMS.Release.admin_allowlist/1` | in txn: if the event cannot be written the list does not change |
| `sign_in_unlock_requested` | `lib/kiln_cms/accounts/sign_in_unlock.ex`: the request's background task, via `AuthEvents.sign_in_unlock_requested/2`, once `SendSignInUnlock` has queued the mail | after commit, off the request path; tenant is the site the request was made on; `surface: "browser"` |
| `sign_in_unlocked` | `sign_in_unlock.ex`: `redeem/2`, after the token's atomic revoke succeeded and the counter was cleared (`AuthEvents.sign_in_unlocked/3`) | after commit; `was_locked` |
| `sign_in_unlock_refused` | `sign_in_unlock.ex`: `redeem/2` on every refusal, including the loser of two concurrent redeems (`AuthEvents.sign_in_unlock_refused/3`) | sampled, after commit; `reason` |
| `registration_queued`, `registration_approved`, `registration_rejected` | `lib/kiln_cms/security/changes/record_registration.ex`, on `OrgMembership` `:queue_registration` (from `Changes.QueueRegistration` inside `User` `:register_with_password`, and from `SiteSso.Admission` for a new site single sign-on account), `:approve_registration`, `:approve_registration_by_invitation` (from `Invitations.grant_membership/4` when an invitation is accepted, and from `Invitations.AddOrInvite`) and `:reject_registration` (`lib/kiln_cms/accounts/org_membership.ex`) | in txn; tenant is the membership's site |
| `backup_canceled` | `KilnCMS.Security.Changes.Record` on `Backups.Run` `:cancel` (`lib/kiln_cms/backups/run.ex`), called from the Backups page | in txn, with the cancel: if the event cannot be written the backup is not canceled; tenant is the default site |
| `api_key_reuse_detected` | `lib/kiln_cms/accounts/api_key_reuse.ex`: `check/2`, called by `KilnCMSWeb.ApiKeyRotationController` with the request context, after the lineage's live keys are revoked | `Recorder.record/2` outside any transaction, with `alert_required: true`: if its `api_key_abuse` alert cannot be claimed the event is not written either, and when the event is not written the platform admins get the plain reuse email instead |

`org_setting_changed` covers every resource built with `use
KilnCMS.CMS.OrgSettings`, so a new settings resource cannot forget it:
`CMS.FeedSettings`, `FormSpamSettings`, `SiteAiProvider`, `SiteBotBudgets`, `SiteBranding`,
`SiteCodeInjection`, `SiteCompliance`, `SiteEditorialSettings`,
`SiteEmbedSettings`, `SiteLinkCheck`, `SiteLocaleSettings`, `SiteMailRelay`,
`SiteMeilisearch`, `SitePasswordPolicy`, `SiteRegistration`, `SiteSafetyFields`, `SiteSecurityAlerts`, `SiteSecurityLog`,
`SiteSecurityTxt`, `SiteSessionPolicy`, `SiteStorage`, `SiteVapidKey` and
`Federation.SiteFederation`. (`SiteSsoProvider` is the exception that records
`sso_config_changed` instead, and `SiteAdminAllowlist` the one that records
`admin_allowlist_changed`.)

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
| An invitation used up, or pruned | Not recorded | Accepting destroys the row through `Invitation` `:consume`; the `role_granted` of the membership it became or raised is the record. An accept by someone who already held the invited tier or higher changes nothing and records nothing. (An invitation retired by a membership change is recorded, as `invitation_revoked`.) The daily `:prune_expired` sweep removes rows long past expiry, which no one decided. |
| A session signed out by an earlier "sign out everyone" when it is next used | Not recorded | A session that recorded no site (signed in before #2246) is caught later, on its next use on the site. `all_sessions_revoked` already records the decision; the late catch is its consequence. |
| A session used on another site's host | Not recorded | The cookie was copied; it is served signed out there and nothing is written to it. |
| Identity-provider links and push devices removed when an invitation takes over an unconfirmed account | Not recorded | There is no event type for either, and none is recorded when one is made. The second factor, passkeys and API keys removed by the same takeover are recorded (#2453). |
| An unlock request that mails nothing, or opening an unlock link | Not recorded | A request for an unknown, unpaused or non-member address is answered like any other and leaves no trace, so the log names no address that was not mailed. Opening the link only shows a button; mail scanners do it too. |
| Unknown host | Not recorded | No site to attribute it to; the event is skipped. |
| A save of the admin allowlist refused because it would lock you out | Not recorded | Nothing changed. |
| The admin allowlist kill switch (`KILN_ADMIN_ALLOWLIST_DISABLED`) | Not recorded | It is an environment variable read at boot, with no site and no person. The boot log warns while it is set, and your platform's own record of environment changes is the trail. See [admin-allowlist.md](admin-allowlist.md#recovering-from-a-lock-out). |
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
| `[:kiln_cms, :security, :event_sampled_out]` | An event was dropped on purpose: a failed sign-in, an admin allowlist refusal or a refused unlock link over the per-address cap, or a repeat lockout in the same window. Metadata: `type`. A sustained rate of `sign_in_failed` is a guessing attack. |

Security alerts have a telemetry event of their own,
`[:kiln_cms, :security, :alert_failed]`; see
[Security alerts](security-alerts.md#for-operators).

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
- `type` is a `KilnCMS.Types.KnownAtom` column (#2509). A type this release
  does not know (one a newer release recorded, read during a rolling deploy or
  after a rollback) loads as `%KilnCMS.Types.UnknownAtom{value: "the_type"}`
  instead of failing the read. So code that reads `event.type` gets either one
  of `Event.types/0` or that struct: match the known atoms and let the struct
  fall through to a catch-all. `Event.metadata_keys/1` returns `[]` for it, and
  `KilnCMSWeb.SecurityLog.type_label/1` labels it "Unrecognized event (name)".
  Writes stay strict: `KilnCMS.Security.record/2` refuses a type outside
  `@types`, and an `UnknownAtom` too. Adding a type is safe for an older release only if
  that release already has this column as `KnownAtom`; see
  [New values in an atom column](releasing.md#new-values-in-an-atom-column).
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
| "Unrecognized event (some_name)" in a gray badge | A newer release recorded this event, and the release now running does not know the type: usually during a rolling deploy, or after rolling back. The row is kept and shown, the CSV carries the raw name in `type`, the erasure sweep scrubs it and the prune deletes it on schedule. The **Type** filter lists only the types this release knows, so filtering by one hides these rows. They read normally again once every node runs the newer release. |
| `413` on the CSV | More rows match than the export cap. Narrow the date range. |
| Old events are still there | The prune runs once a day, and `KILN_SECURITY_LOG_PRUNE_CRON=false` turns it off; or retention is 0. |
