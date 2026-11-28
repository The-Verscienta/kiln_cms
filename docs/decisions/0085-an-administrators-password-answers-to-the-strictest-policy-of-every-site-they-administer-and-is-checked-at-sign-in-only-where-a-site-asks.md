# 0085. An administrator's password answers to the strictest policy of every site they administer, and is checked at sign-in only where a site asks

- **Status** — accepted (2026-11-26). Amends
  [ADR 0031](0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md),
  which rejected checking at sign-in.
- **References** — [#2408](https://github.com/The-Verscienta/kiln_cms/issues/2408)
  (strictest policy across an account's admin sites) and
  [#2407](https://github.com/The-Verscienta/kiln_cms/issues/2407) (the check
  at sign-in), with follow-ups
  [#3436](https://github.com/The-Verscienta/kiln_cms/issues/3436) (the reset
  mail's branding),
  [#3437](https://github.com/The-Verscienta/kiln_cms/issues/3437) (the pause
  mail) and [#3438](https://github.com/The-Verscienta/kiln_cms/issues/3438)
  (auditing when the deciding sites can't be read),
  [#3435](https://github.com/The-Verscienta/kiln_cms/issues/3435) (the Warn
  verdict across the API's second factor) and
  [#3470](https://github.com/The-Verscienta/kiln_cms/issues/3470) (the
  breached-pause mail's own alert window); [ADR 0031](0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md)
  for the check itself and why it fails open;
  [ADR 0023](0023-an-unlock-link-lifts-only-the-account-pause-and-the-pause-stays-undisclosed.md)
  for the per-account sign-in pause a blocked sign-in still counts toward.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Breaking ([long form](../changelog/unreleased.md#breached-password-strictest-admin-sites))
  and Added ([long form](../changelog/unreleased.md#breached-password-sign-in-check)).

## The problem

The breached-password check (`KilnCMS.Accounts.Changes.CheckBreachedPassword`)
took its policy from the site the request came in on. Kiln serves many sites
from one account table, so one person can administer several. An admin of a
site that blocks breached passwords could change their password on another
site's host, where the policy is Warn or Off, and set a breached one. The
account is the same everywhere, so the blocking site's admin console was
then guarded by that password.

And the check ran only when a password was set. A breached password set
before 1.9.0, or set on a site that warned, was never looked at again.

Four questions had to be answered, and each outlives the release:

- Which sites' policies govern one account's password?
- Does a site's **Off** still mean "nothing about this password is sent"?
- Should signing in be checked, for whom, and who decides?
- What happens to a person whose correct password is refused?

## The decision

### Setting a password: the strictest of every administered site

`KilnCMS.Accounts.PasswordPolicy.resolve_for/3` answers

    strictest(request site's policy, downgraded for the target's tier there,
              strictest(policy of each site the target administers))

ordered Off, Warn, Block. "Administers" is
`KilnCMS.Accounts.Scoping.admin_org_ids/1`: every site for a platform admin;
otherwise the sites where an `:active` membership is effectively admin, live
temporary grants included; none for an erased account or one that does not
exist yet. An administered site with no saved row brings in the operator's
default, because that is the policy it has. Only administered sites escalate:
an editor of a blocking site is not refused for it, since Block has only ever
applied to administrators.

This is a password's property, not a request's. The account is one
credential across every site it can reach, so the site whose admin console is
most carefully guarded sets the bar.

So a site's **Off** no longer guarantees that nothing is sent for a password
set on it: it guarantees that this site asks for nothing. Someone who also
administers a site that checks is checked on every host. The Password policy
page says so under Off, and `BREACHED_PASSWORD_CHECK=false` remains the one
switch that stops every request. One site turning its check off must not
weaken another site's control over its own administrators.

The cross-site rows are read through two `multitenancy :bypass` actions on
`KilnCMS.CMS.SitePasswordPolicy`, `:for_orgs` and `:all_orgs`, which only the
`:accounts` system actor may call: the settings macro's read policy admits a
site's own admin, and through a tenant-less read that would be every site's
row. The read is a bounded number of queries whatever the number of sites,
and fails open to Warn for its part of the answer.

### Signing in: opt-in, administrators only, per site

`check_on_sign_in` on a site's policy row, off by default, asks for the
check at sign-in too. `PasswordPolicy.sign_in/1` decides:

- only an account that administers at least one site with the switch on is
  checked; an editor or a viewer never is;
- the outcome is the strictest policy among **those** sites alone. One site's
  switch never changes what another site's policy does at sign-in, and the
  site the request came in on plays no part, so every host and door decides
  alike;
- the deployment switch off, a policy of Off, or any failure to read the
  settings means no check.

Opt-in, unlike the set-password check, because it changes the cost of the
call ADR 0031 accepted: one prefix each time a password is set becomes one
prefix at every sign-in of every checked administrator, and a sign-in waits
on a third party. A site that wants that accepts it explicitly. Nothing is
cached in this release: a cached "clean" verdict would be a password
derivative stored on the server, and would delay noticing a password that
enters the corpus later. The same five-character prefix is therefore sent at
every checked sign-in.

The check is `KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignIn`,
an `after_action` hook on `:sign_in_with_password` ordered after the password
is verified and before the remember-me token is minted. So it makes one
lookup per sign-in, never for a wrong password, an unknown address, a
throttled or challenged attempt, or a keystroke, and holds no database
connection while it waits. Its deadline is `sign_in_deadline` (1.5 s), half
the 3 s a password being set may take, because a person is waiting on a
sign-in page. Every failure lets the sign-in through, for ADR 0031's reason.

It runs **before** the second factor. The plaintext exists only at the first
factor; checking after the code would mean carrying a verdict through the
pending sign-in on both verify doors. A refusal still comes before any
session, so the second factor is never skipped.

*Amended (#3435, #3470, 2026-11-28):* the lookup stays here, at the first
factor, but its Warn result now does ride the pending state to the step that
finishes the sign-in, on both doors. The browser door already did (a note in
`KilnCMS.Accounts.PasswordNotice` and the session, shown after the code). The
API door had nowhere to put it, so `POST /api/auth/sign_in/verify`'s `201`
never warned a two-factor administrator. The verdict now rides inside the
`:encrypted` pending blob (`KilnCMS.Accounts.PendingSignIn`), which is already
encrypted, authenticated and single-use, so the caller can neither read nor
forge it and it never travels in a URL. The key is written on every
`:encrypted` blob, `1` when warned and `0` when not: AES-GCM hides the content
but not the length, and the headless blob is printed in client logs and CI
transcripts, so a key present only when warned would name the administrators
who sign in with a breached password. Only `1` reads as warned, so a blob from
a release without the key reads as not warned. The `:session` blob carries no
key. Neither the salt nor the lifetime changed. The verify step does not
re-read the policy: a site that moves from Warn to Block between the two
steps still gets that sign-in issued, with the warning, since the lookup ran
under the policy of the step that had the password.

### A refused sign-in is sent to reset, not locked out

Under Block a breached password is refused with
`KilnCMS.Accounts.Errors.PasswordResetRequired`, not the
`AuthenticationFailed` a wrong password gets: that would tell someone who
typed the right password to retype it, and the throttle would count it as a
guess. The minted token is revoked, and a reset link is mailed through
`KilnCMS.Accounts.PasswordResetMail` with its own copy
(`KilnCMS.Accounts.User.Senders.SendBreachedPasswordReset`), since nobody
asked for it and the sign-in may not have been the owner's. The browser lands
on `/reset`; the API answers `403 password_reset_required`.

*Amended (#3436–#3438, 2026-11-26):* the mail is branded for a site whose policy refused
the sign-in, not the site the request came in on: the request's site when it
is one of them, else the one with the smallest id (stable across attempts,
and no extra read). The request's site had been used because it was at hand,
but under the strictest-policy rule it may be a site where the person is only
a viewer, or one they never think of, so a mail in its name reads like
phishing. A platform admin administers every site, so no deciding site is
more theirs than another; their mail keeps the request's site (the default
site's branding with none). No log or audit line gets a deciding site's name.

The mail is charged to the address's reset-mail budget like every other
reset mail. The person who typed the password may be an attacker holding it,
so the budget is never waived. For the same reason the per-account sign-in
counter is not forgiven: a blocked attempt counts like a failed one, and an
owner who keeps retrying is paused like anyone else.

*Amended (#3436–#3438, 2026-11-26):* the reasoning above assumed each block mails the
owner. It does not: the block's reset mail shares the address's five-an-hour
budget with the anonymous `/reset` form, so someone holding the password can
spend that budget first, and every block after it is `:over_budget` and sends
nothing. The pause mail is therefore the notice that budget cannot silence,
and it now says what filled the counter. Each block is noted in a tally
beside the counter, on the same window (`AccountThrottle.note_sign_in_block/1`,
a new bucket, no migration), and `KilnCMS.Accounts.SignInAlert.account_locked/2`
picks the wording from `AccountThrottle.sign_in_pause_cause/1`: the usual
"Unusual sign-in activity" mail when there were no blocks; "Sign-in paused on
your (site) account: choose a new password" when there were, saying that the
attempts (or some of them) used the current, breached password and that a new
password lifts the pause. It links `/reset` bare: an unlock link would send the
owner back to a password that is still refused, and a token would be minted
on an attacker's schedule. Withholding the mail when every attempt was a
block was considered, since those attempts are not guesses, and rejected: with
the reset budget spent it would leave the owner with no word that someone
holds their current password. So every cause mails, and spends the six-hour
alert window like the usual mail. The throttle itself is unchanged; the tally
admits and refuses no one. The tally and the counter are separate rows, so a
forgiveness or a window boundary between the two reads can only move the mail
between its wordings.

*Amended (#3435, #3470, 2026-11-28):* the breached wordings no longer spend
the usual mail's window. Sharing it let the weaker signal silence the
stronger in the order an attack produces them: wrong guesses fill the counter
and spend the window; the counter's window rolls; someone spends the
address's reset mails; the blocks then fill the counter again, and the mail
that says why found the window spent. They now spend their own six-hour
window (`AccountThrottle.breach_alert_allowed?/1`, bucket
`signin:breach-alert`, no migration), as the second-factor alert does. The
choice was between at most two pause mails per address per six hours (one of
each) and at most one (the breached mail also holding back a later usual
one); it is two, because the second can only be spent by someone holding the
correct password of an administrator whose site blocks it, and guessing that
starts after a breached pause is still news. Both windows are charged before
the mail is built, since the charge is one atomic increment-and-compare and
two simultaneous refusals must not both send; when the mail then fails to be
queued, the window is handed back (`AccountThrottle.forget_alert/1`, which the
usual window did not have before, and `forget_breach_alert/1`).

Under Warn the person signs in and is told: a flash on the browser doors, an
additive `password_breach` field on the API's one-step `201`.

*Amended (#3435, 2026-11-28):* and on the `201` of
`POST /api/auth/sign_in/verify` for a two-factor administrator, never on the
`200` pending step, since the caller has not yet proved the second factor.

### Audit

A refusal is `sign_in_failed` with reason `breached_password`, recorded
unsampled in the log of each site whose policy refused it, not the request
site's, and not charged to the failed-sign-ins alert. Only the right password
gets this far, so it is neither a guess nor something a flood can produce,
and an alert about guessing would mislead.

*Amended (#3436–#3438, 2026-11-26):* a refusal whose deciding sites cannot be read is
recorded once in the request's site. The rule above left such a refusal
unrecorded, on the reasoning that the request's site is not one that decided.
But only a platform admin's deciding sites are read at refusal time (a
member's come with the decision), and a platform admin's correct password
refused with no trace anywhere is worse than one row in a site that did not
decide. So the fallback applies only when the deciding read fails or comes
back empty, never alongside the deciding sites; it names no other site, and
the account is labelled only if it is a member of the request's site, so the
row shows a platform admin to that site's admins no more than a failed sign-in
by them already would. `PasswordResetRequired`'s `org_ids` stay the sites that
decided: `[]` means "not known", and the request's site is never put in it.
With no request site nothing is recorded, as for every sign-in event.

## Rejected

- **The request site's policy alone** (the old rule). It lets an
  administrator set a breached password by choosing the host.
- **Letting a site's Off win.** One site's choice would decide how another
  site's administrators are protected.
- **Every administered site's policy deciding at sign-in, switch or not.**
  One site ticking the box would change what an unticked site's Block meant
  for its admins at sign-in. The switch and the policy that decides come from
  the same site.
- **Checking every account at sign-in, or applying Block to editors.**
  Contrary to ADR 0031: the check is advisory, and only an administrator's
  password can be refused.
- **On by default.** Turns a call made when a password changes into a call
  made at every administrator sign-in, on every install, without anyone
  having asked.
- **Checking in the controller after sign-in** (`AuthController.success/4`).
  The sign-in form's door reaches it with a sign-in token, not the password,
  and the API door never reaches it.
- **A `before_action` hook or the preparation body.** Before the password is
  verified, and the body runs on every keystroke of the form.
- **An `after_transaction` hook.** The remember-me token is already minted.
- **Refusing without a way back, or locking the account.** The owner did
  nothing wrong by having a password that was later breached.
- **Sending the reset mail through `:request_password_reset_token`.** It
  charges the per-IP `:auth` bucket a second time for one request, and its
  copy says the person asked for it.
- **Caching a verdict per account.** A stored password derivative, and a
  delay in noticing a newly breached password.
- **Holding the verdict across the second factor.** See above. *Amended
  (#3435, 2026-11-28):* what stays rejected is running the lookup at the
  second factor, which has no password. The first factor's Warn result does
  ride the pending state, on both doors (above). Also rejected for carrying
  it: re-running the lookup at verify, putting it in the `200` pending
  response, a node-local cache, a URL, header or second token, a column on
  the token row (a migration), a new salt or blob version, and writing the
  key only when warned (its length would show).

## What it leaves open

These are recorded in the threat model's "Breached passwords" section:

- A `403 password_reset_required`, or the redirect to `/reset`, tells a
  credential stuffer that the pair is valid and that the account administers
  a site that checks at sign-in. It issues no token, which a successful
  sign-in would have.
- An attacker holding the breached password can spend the owner's five reset
  mails an hour, and pause the account through the sign-in throttle (which a
  wrong password could already do). *Amended (#3436–#3438, 2026-11-26):* the pause
  mail names the breach and is not withheld (above), so the owner hears
  even when the reset budget is spent. *Amended (#3470, 2026-11-28):* it has
  its own six-hour window, so a pause of wrong guesses no longer delays it.
  Still open: someone who spends the reset budget and then makes too few
  blocked attempts to fill the sign-in counter never pauses the account, so
  neither the reset mail nor the pause mail reaches the owner.
- ~~The Warn signal does not reach an API client of a two-factor administrator:
  `/api/auth/sign_in/verify` does not carry `password_breach`.~~ *Amended
  (#3435, 2026-11-28):* closed: it does, through the pending token.
- ~~The reset mail is branded for the site the request came in on, not the
  site whose policy refused the sign-in.~~ *Amended (#3436–#3438, 2026-11-26):* closed:
  it is branded for a deciding site (a platform admin's, the request's site).

## When to revisit

- A cache of recent clean verdicts is proposed: argue it against the stored
  derivative and the detection delay.
- Have I Been Pwned's terms or rate limits change for repeated prefixes from
  one address.
- The sign-in check is to cover editors or every account, or to become on by
  default: either reopens ADR 0031's trade-off.
