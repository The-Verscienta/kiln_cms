# Two-factor authentication (TOTP)

Kiln supports time-based one-time password (TOTP) two-factor authentication —
the "richer auth" Phase 1 ([issue #331](https://github.com/The-Verscienta/kiln_cms/issues/331)).
Any account can add a second factor from a standard authenticator app (Google
Authenticator, 1Password, Authy, …); once enabled, a valid code is required at
every sign-in, after the first factor.

To see who on a site has no authenticator app yet, a site admin opens
**Configure → Organization → Security posture**: the "Two-step sign-in"
lines fail for any administrator without one and warn for editors, and a
platform admin also sees the platform administrators
([Security posture](security-posture.md#two-step-sign-in)). A passkey is not
counted there. It is another way to sign in, and on its own it does not
protect the account's password sign-in: someone who has the password signs in
with the password and, without TOTP, needs nothing else. The exception is a
site that [requires two-step sign-in](#requiring-two-step-sign-in-on-a-site):
past the deadline, a passkey-only account's password stops at the passkey
prompt there.

Turning a second factor on or off is recorded in the site's
[security log](security-events.md) (`second_factor_enrolled`,
`second_factor_removed`), and removing one alerts the site's admins by bell and
email unless they turned off "Two-factor authentication turned off"
([Security alerts](security-alerts.md#what-raises-an-alert)). A factor removed
because an invitee took the account over is logged but raises no alert.

## How it works

- **Self-service enrolment** at `/editor/settings` → "Two-factor authentication"
  (editors and admins), or at `/account/two-factor` (any signed-in account,
  readers included; see
  [Set up two-step sign-in when your site asks](#set-up-two-step-sign-in-when-your-site-asks)):
  1. *Enable* generates a fresh secret (`setup_totp`) into a **pending** slot
     (`totp_pending_secret`) and shows a setup key + an `otpauth://`
     provisioning URI. The live secret and enforcement state are untouched by
     this step, so starting (or restarting) enrolment can never by itself
     weaken an already-confirmed account (#754).
  2. The user adds it to their authenticator app and enters a current code to
     confirm (`confirm_totp`), which is checked against the *pending* secret.
     Only on success is it promoted to the live secret and 2FA enforced —
     `setup_totp` alone never flips that switch. `confirm_totp` re-reads the
     pending secret from the database, so if a second settings tab started a
     newer enrolment in the meantime, **the last `setup_totp` wins**: a code
     from the older tab's now-superseded secret is rejected as invalid rather
     than silently promoting a secret the database no longer holds (#787).
     The write itself then checks again, under the account's row lock
     (`Changes.GuardAccountTakeover`, #2453): if a second tab's `setup_totp`
     replaced the staged secret, or an invitation took the account over and
     cleared it, between the confirmation being built and being written, it is
     refused with `KilnCMS.Accounts.Errors.AccountTakenOver` ("belongs to an
     account that changed since this request began"). The settings page shows
     its usual "That code isn't valid — try again."; start enrollment again.
  3. *Disable* (`disable_totp`) requires a current *live* code, so a walk-up
     attacker on an open session still can't remove the factor — and clears any
     abandoned pending secret along with it.

  Re-enrolling on an account that already has a confirmed factor works the same
  way, which is also what makes it self-service for someone who lost their
  device: a recovery-code sign-in gets them a session but no live code to
  prove, and re-enrolment asks for none — only a code from the *new* device.
- **Sign-in gate (browser):** `KilnCMSWeb.AuthController.success/4` diverts a
  2FA-enabled account to `/sign-in/verify` instead of establishing a session. A
  short-lived (5-minute), signed pending token carries the user id + the
  already-minted first-factor token across the redirect — the user is **not**
  signed in until a valid code is entered. The blob only needs signing because
  it lives in the (encrypted) session, where the client never sees it.
- **Sign-in gate (headless):** `POST /api/auth/sign_in` answers a 2FA account
  with `200 {"two_factor_required": true, "pending_token": …}` rather than the
  `201` + JWT a single-factor account gets, and `POST /api/auth/sign_in/verify`
  redeems that plus a code
  ([#726](https://github.com/The-Verscienta/kiln_cms/issues/726)). Same five
  minutes and the same budget as the browser prompt. This blob *is* handed to
  the client, so it is **encrypted** rather than signed and is single-use; see
  `KilnCMS.Accounts.PendingSignIn` and `docs/api.md`.

  Until #726 this endpoint asked for no second factor at all, which is why the
  sentence at the top of this page — "a valid code is required at every sign-in"
  — is only now true. API keys remain the recommended credential for unattended
  server-to-server use, and carry no second factor by design.
- **The first-factor token is held for the length of the step**
  ([#742](https://github.com/The-Verscienta/kiln_cms/issues/742)). `User` sets
  `store_all_tokens?`, so the first-factor JWT is minted *and inserted into
  `tokens`* before either gate has looked at `totp_enabled?`. Withholding the
  caller's access to it is not the same as withholding the token: an exchange
  abandoned at the prompt used to leave a live, usable row that nobody held, for
  the JWT's full lifetime.

  `PendingSignIn.mint_and_hold/4` therefore moves that row to the `pending_second_factor`
  purpose and shortens its expiry to the length of this step, and
  `PendingSignIn.claim/1` puts it back once a code verifies. AshAuthentication
  requires a row under the `user` purpose to authenticate a JWT
  (`require_token_presence_for_authentication?`), so in between the token
  authenticates nothing, wherever it is. Both gates, one code path — which is
  why the browser prompt calls `claim/1` at all, when the single use a session
  blob needs is the deleted session key.

  That dependency on AshAuthentication is pinned rather than assumed
  ([#1172](https://github.com/The-Verscienta/kiln_cms/issues/1172)).
  `KilnCMS.Accounts.SecondFactorHoldExtension` fails the compile if `User`
  ever turns off `require_token_presence_for_authentication?` or
  `store_all_tokens?`, or points `token_resource` away from
  `KilnCMS.Accounts.Token` — any of which would leave the hold a silent no-op
  with every test green. And
  `test/kiln_cms/accounts/second_factor_hold_contract_test.exs` drives a held
  token through the dep's *own* bearer and session round trips, so a future
  AshAuthentication that quietly widened its purpose filter would go red on
  the `mix.lock` bump rather than re-opening #742 unnoticed.

  Held rather than revoked, because the exchange may still complete — and the
  release is filtered on the hold purpose **in the UPDATE's own WHERE**, so a
  token revoked mid-window is not resurrected by a late redemption even if the
  revocation lands after the release has read the row. The revokers are a
  password change or reset (`KilnCMS.Accounts.Changes.RevokeAllTokens`, #734)
  and account erasure, which sweep
  every row a subject owns, held ones included. Sign-out revokes too, but only
  the token in *that* session — a browser sitting at the code prompt is not
  signed in and carries none, so signing out elsewhere does not reach a held
  row.
- **Where the code is checked:** `KilnCMS.Accounts.SecondFactor.check/3`, for
  both gates, so neither can drift on what counts as a valid submission. A
  passkey at the browser prompt goes through its twin,
  `KilnCMS.Accounts.SecondFactor.check_passkey/3`, which charges the same
  budget in the same order (see
  [Using a passkey at the code prompt](#using-a-passkey-at-the-code-prompt)).
  Whitespace normalization sits one level lower still, in
  `KilnCMS.Accounts.Totp.valid?/3`, because the enrolment and disable forms
  check a code too and used to reject the `123 456` an authenticator app copies.

## Using a passkey at the code prompt

An account that has both an authenticator app and a passkey can finish the
second step with the passkey instead of typing a code (#2247). An account
with an authenticator app is always sent to the prompt; a passkey-only
account is sent there only on a site that
[requires two-step sign-in](#passkey-only-accounts) of it, past its deadline,
and is then offered the passkey alone. A passkey sign-in from the sign-in page
is still a complete sign-in on its own (see [Passkeys](passkeys.md)).

You need an account with an authenticator app and at least one passkey, both
added at `/editor/settings`, and a browser that supports passkeys. Then:

1. Sign in at `/sign-in` with your password (a sign-in link by email or
   single sign-on works the same). The **Two-factor authentication** page
   opens at `/sign-in/verify`, asking for "the 6-digit code from your
   authenticator app", with **Use a passkey** below **Use a recovery code
   instead**.
2. Click **Use a passkey**. The browser offers this account's passkeys, and
   only those, and asks for the device's screen lock (PIN, fingerprint or
   face).
3. Confirm on the device. You are signed in, with "You are now signed in",
   and land where the sign-in was taking you, exactly as after a code.

If you ticked **Remember me** on the sign-in page, the 30-day cookie is set
at step 3 and not before, for the reason in
["Remember me" and the second factor](#remember-me-and-the-second-factor).

The button is shown only where the passkey can be checked: on the main host
(`PHX_HOST`) or a console host under it (`KILN_CONSOLE_HOST`), and never on a
site's own host, because a passkey belongs to the main host and a browser
refuses it anywhere else. On a site's own host the page shows the code form
only. It is also hidden in a browser without passkey support.

### What counts, and what is recorded

A passkey at the prompt is the other way past the same step, so it is held to
the same rules as a code:

- A refused passkey costs one attempt from the account's second-factor budget,
  the one codes and recovery codes share (five per fifteen minutes; see
  [Why a wrong code can say "too many attempts"](#why-a-wrong-code-can-say-too-many-attempts)).
  At the limit the prompt refuses the passkey too, the lockout is recorded,
  and the owner gets the same lockout email.
- A verified passkey clears that budget and the sign-in budget, as a verified
  code does.
- A refused passkey is recorded in the [security log](security-events.md) as
  `sign_in_failed` with `method` `second_factor` and `reason` `invalid_code`,
  the same as a wrong code. The completed sign-in is one `sign_in` event whose
  `method` is the first factor's (`password`, `magic_link`, `sso`, …).
- Only a passkey registered to the account waiting at the prompt is accepted,
  it must have checked the screen lock, and its signature counter must not go
  backwards (the clone check every passkey sign-in makes).

### If it does not work

- **No Use a passkey button.** The account has no passkey, you are on a site's
  own host rather than the main or console host, or the browser has no passkey
  support. The code and recovery-code forms still work.
- **"That passkey couldn't be verified. Try again or use another method."**
  The device prompt was canceled or timed out, or the passkey was refused (it
  belongs to another account, did not check the screen lock, or failed the
  clone check). The sign-in is still waiting: try again, or type a code. A
  refusal the server saw used one attempt; a canceled prompt did not.
- **"Too many attempts. Wait a few minutes and try again."** The account's
  second-factor budget is spent, by codes, passkeys, or the settings forms
  that share it. The answer carries `Retry-After`.
- **You are sent back to `/sign-in`.** The pending sign-in lasts five minutes,
  and it had run out, or it was already completed in another tab. Sign in
  again.
- **"Sign-in could not be completed right now. Try again in a moment."** The
  passkey verified but the sign-in could not be finished on the server (a
  503). Try again; the passkey was not the problem.
- **The page says "This sign-in can't be finished here. Start again." and
  offers nothing.** The account no longer has a factor this page can check
  here: for example, its authenticator app was removed while the prompt was
  open and the page is on a site's own host, where a passkey cannot run. Go
  back to sign in, on the main host if the account has a passkey.

For developers: the button drives a two-step JSON exchange,
`POST /sign-in/verify/passkey/options` then `POST /sign-in/verify/passkey`
(`KilnCMSWeb.TwoFactorController`, `initPasskeyStepUp` in
`assets/js/passkeys.js`), on the same pipeline as `/sign-in/verify`: CSRF
protection, the per-address `:auth` rate limit, and the
[admin allowlist](admin-allowlist.md)'s **Also restrict sign-in**. The
first answers `{"publicKey": …}`, a challenge limited to the waiting account's
credentials (`KilnCMS.Accounts.WebAuthn.step_up_challenge/1`), parked
server-side and bound to that account. The second verifies the assertion
(`KilnCMS.Accounts.WebAuthn.verify_step_up/3`, which mints no token: it
releases the first-factor token held since the first step) and answers
`{"redirect_to": …}`. A refusal is a 401 with `{"error": …}`, plus
`"redirect_to": "/sign-in"` when the pending sign-in is over; 429 and 503 as
above. The two passkey ceremonies keep separate session keys and challenge
entries, so a nonce from `/auth/passkey/*` is never accepted here, nor the
reverse. Who is sent to the prompt at all is
`KilnCMSWeb.SecondFactorStepUp.decide/3`, shared by the browser and headless
doors (the sign-in budget follows the same
`KilnCMS.Accounts.TwoFactorRequirement.step_up/3`): `:prompt` when the
authenticator app is on, or for a passkey-only account past a site's deadline
on a host where the passkey can run;
`{:refuse, :passkey_host}` for that account on a site's own host, and
`{:refuse, :headless_passkey}` at the headless door.

Every completed browser sign-in now also records, in the session, how it
signed in and whether a second factor was verified (`KilnCMSWeb.SignInMarker`,
session key `"sign_in"`). It is keyed to the session token, so a marker from
an earlier token reads as nothing. The policy page reads it to decide whether
a save needs a code, the email step reads how the session signed in, and the
gates read it to tell a passkey-only account's password session from one that
passed the passkey.

## We email you when a second factor is added

Whenever a second factor is added to an account, its owner gets an email
(#2247):

- an authenticator app is set up on `/editor/settings` or
  `/account/two-factor` (the first one, or a new one that replaces the old);
- a passkey is added.

One email per factor, every time. Regenerating recovery codes adds no factor
and sends nothing; nor does a wrong code or a refused passkey.

Why: adding a factor needs only a signed-in session. Someone who got hold of
a session could add a passkey of their own and use it to sign in again after
the owner's session ends. No sign-in fails, and the new factor sits in a
settings list the owner has no reason to open, so the email is how they find
out.

The email is titled "A second factor was added to your (name) account", with
the instance's name. It says:

- what was added: "An authenticator app was set up…", "A new authenticator app
  replaced the one your account used… Codes from the old one no longer work."
  or "A passkey was added… A passkey signs in on its own, without your
  password.";
- **When**, in UTC;
- **Browser**, as a browser and platform family, for example "Firefox on
  macOS", never the raw browser string;
- **Site**, the site it was added from, when known.

It never contains the secret, a recovery code, the passkey's credential id or
its name. The name was typed by whoever added it, and text chosen by an
intruder has no place in a mail sent from your own address.

### If it wasn't you

The email gives two steps, in this order:

1. **Reset your password** (the link goes to `/reset`). That signs out every
   session, including the intruder's.
2. **Ask an administrator of your site** to check your account's sign-in
   methods. The factor just added may now be the only second factor the
   account has, so you may not be able to get past it to remove it yourself.

### For operators

The email goes through the instance mail relay (`KilnCMS.Mailer`), never a
site's own, in English, like the other account email, and it cannot be
muted. An erased account gets none. It is queued only after the factor is
saved: a mail that cannot be queued is logged as "Second-factor notice for
user (id) not sent" and does not undo the new factor.

Because every passkey added sends an email, an account can hold at most 20
passkeys and add at most 5 an hour (see [Limits on adding passkeys](passkeys.md#limits-on-adding-passkeys)).

## "Remember me" and the second factor

Ticking "Remember me" on the sign-in page issues a 30-day cookie that signs the
browser in on its own. For a 2FA account that cookie is only issued **after a
code verifies** ([#699](https://github.com/The-Verscienta/kiln_cms/issues/699)):
AshAuthentication writes it at the first factor by default, which would let
someone tick the box, close the code prompt, and keep a credential that never
asks for a code again. `KilnCMSWeb.AuthController` withholds it there and
`KilnCMSWeb.TwoFactorController` issues it on success instead.

Once issued it *does* skip the code prompt on later visits, deliberately — it
represents a device that completed every factor. Signing out deletes it. Changing
or resetting the password revokes it too, along with every other stored token
the account holds — every session, and any sign-in waiting at this prompt
([#734](https://github.com/The-Verscienta/kiln_cms/issues/734)) — so a password
change is how to withdraw a device you no longer have. Before 1.0 it did not:
the flag that was meant to do it never fired.

## Why a wrong code can say "too many attempts"

Six digits and a ±1-step tolerance are guessable in a way a password is not, and
whoever is at that prompt has already got past the first factor. So beyond the
per-IP `:auth` limit — which an attacker escapes by rotating addresses — every
submitted code is charged a **per-account** budget: five per fifteen minutes,
keyed on the account the pending token names, cleared the moment a valid code is
accepted ([#714](https://github.com/The-Verscienta/kiln_cms/issues/714)).

What an operator should know when a user reports it:

- **It is per account, not per browser or per address.** Signing in from another
  device or network does not reset it, and neither does re-entering the password
  — a fresh pending token does not refill the budget, which is the point.
- **It is per account, not per *surface*.** The browser prompt and the headless
  `POST /api/auth/sign_in/verify` charge the same bucket (#726), so a user whose
  correct code is refused in the browser may have spent it in a script — a CI
  job or a mobile client retrying a stale code will do it silently. Check for a
  headless client before concluding the browser attempts don't add up.
- **All three settings forms share it too.** *Enabling*, *disabling* and
  *regenerating recovery codes* on `/editor/settings` each charge the same
  bucket ([#727](https://github.com/The-Verscienta/kiln_cms/issues/727)) — they
  verify the same six digits, and a separate budget would just be this one
  twice as large. So a user who mistyped at a settings prompt can find the
  sign-in prompt refusing them, and the reverse. Those forms say "too many
  attempts — try again in N seconds" rather than "that code isn't valid", for
  the same reason the sign-in prompt does.

  Enrolment is on that list, which is not obvious. `confirm_totp` is not
  scoped to an enrolment in progress: run against an account that is *already*
  enrolled it checks the live secret and mints a fresh recovery-code set, which
  is `regenerate_totp_recovery_codes`' prize through a different door. The cost
  is that a user enrolling with a skewed device clock can spend the budget that
  gates their next sign-in — a correct code clears it.
- **TOTP codes and recovery codes share it.** Someone who has spent the budget
  guessing codes cannot fall back to recovery codes until the window rolls.
- **A completed password reset clears it.** That is the remedy to offer: it is
  also what stops an attacker minting the pending tokens they were spending the
  budget with.
- **A lockout at the *sign-in* prompt mails the owner**
  ([#728](https://github.com/The-Verscienta/kiln_cms/issues/728)). Reaching that
  prompt needs a pending token, and a pending token is only minted once a **first
  factor has already succeeded** — so a lockout there means someone got in far
  enough to be asked for a code, which is a much stronger signal than the
  password alert's "someone is guessing".

  Two things the mail deliberately does *not* say, both of which the obvious
  wording would get wrong:

  - **It does not say "someone has your password".** `AuthController.success/4`
    is the callback for every strategy, so a magic link and an SSO assertion
    reach the code prompt exactly as a password does. For those users the
    compromised thing is their mailbox or their identity provider, and telling
    them to change their Kiln password would leave the actual hole open. The
    mail lists all three.
  - **It does not assume an attacker.** The budget is shared with the settings
    forms (#727), so an owner who fumbles five codes regenerating their recovery
    set and then signs in normally trips it with nobody attacking them — the
    likeliest trigger in practice. "If that was you" comes second in the mail,
    before the intrusion paragraph, not buried at the end.

  Separate copy and a separate once-per-six-hours budget from the password
  alert, so the weaker signal cannot suppress the stronger one. The refusal is
  logged when the mail goes and when it is suppressed; if delivery then fails,
  the window is handed back so the next refusal can try again.

  Note the password alert (#478) used to be structurally unable to fire in this
  scenario: to keep grinding codes an attacker must keep re-running the first
  factor, and that step succeeds, which forgave the sign-in counter every time.
  Before #728, the one case where a primary credential was provably in someone
  else's hands produced no notification at all. #742 closed that reset, so both
  alerts can now fire on the same attack — this one first, because the
  second-factor budget is the tighter of the two.

  A lockout that happens *entirely* at `/editor/settings` — with no sign-in
  attempt afterwards — sends its **own** mail (#757), not this one. The person
  there holds a live session rather than a first factor, so the news is
  different and so is the advice: "someone signed in with your password" is not
  what happened, and changing the password matters here because it signs every
  other session out, not because the password itself is suspect. It carries a
  third alert budget for the same reason the second-factor one is separate from
  the sign-in one — the three signals are strictly ordered, and the weaker must
  never suppress the stronger.

  It is also the lockout with no other symptom: a stolen session produces no
  failed sign-ins for the owner to notice.
- **Whitespace is not a wasted attempt.** `123 456` pasted from an authenticator
  is normalized before it is checked; recovery codes are already case- and
  separator-insensitive.
- **It answers 429 with `Retry-After`,** rather than the generic "that code
  isn't valid" a wrong code gets. Unlike the rest of the auth flow there is
  nothing to hide here — whoever is asking already holds a signed token naming
  the account — and telling a user their correct code was wrong is worse.

## Requiring two-step sign-in on a site

A site administrator can require a second factor (an authenticator app or a
passkey) of the site's administrators, of its editors and administrators, or
of everyone, with a grace period of 0 to 90 days for each account to set one
up (#2247). During the grace period people are reminded; after it, an account
with no second factor is **held**: every page of the site sends it to set one
up first, and its headless tokens stop working. A site that never saved the
setting requires nothing, and nobody is held.

Who counts is decided by each person's role on the site the request is for.
"Administrators" covers the admin role; "Editors and administrators" covers
editors and admins; "Everyone" covers every signed-in account, readers
included. An account that belongs to two sites is held only on the one that
requires a factor of it, but the factor it adds counts on both.

The grace period is counted per account, from the latest of: when the account
was created, when it joined the site, and when its role became covered by the
setting. A promotion does not restart it, so a reader of long standing
promoted to admin on a site that requires admins is held at once. Lengthening
the grace moves every deadline later; shortening it, or setting it to none,
can hold people the moment you save.

### Require two-step sign-in on your site

You need to be an administrator of the site, and to hold a second factor
yourself (an authenticator app or a passkey). If you don't, set one up first
at `/account/two-factor`.

1. Open `/editor/two-factor` on the site's console. (The page has no entry in
   the console menu yet; go to it by its address.) You see **Two-step sign-in**
   with three parts: **Who it covers now**, **Requirement** and **If nobody can
   get in**. If you hold no second factor, a notice at the top says "Set up
   two-step sign-in on your own account first." with a **Set up two-step
   sign-in** button.
2. Under **Require two-step sign-in for**, choose **Administrators**,
   **Editors and administrators** or **Everyone**. (**Off** turns the
   requirement off.)
3. Choose a **Grace period**: **None: right away**, **7 days**, **14 days**,
   **30 days** or **90 days**. As soon as you change either field, a line
   under the form says how many people would be asked to set it up, and how
   many of them right away: for example "4 people will be asked to set it up;
   1 of them right away." Nothing is saved yet.
4. If the page shows **Code from your authenticator app**, type a current code
   from your app. It is shown when your sign-in did not verify a second factor
   in the last 15 minutes. If your only factor is a passkey, sign out and sign
   in again with it instead, then come back within 15 minutes.
5. Click **Save**. The page says "Two-step sign-in settings saved.", and the
   **Who it covers now** table shows, for each covered role, how many
   **People** it has, how many have **Set up** a factor, how many are **Still
   in grace** (with the first deadline) and how many are **Held until set
   up**. Below the table, "Last changed (date) by (you)." The table shows
   counts only, never names.

The change reaches every open page of the site at once: anyone it holds is
sent to the setup page, and their open GraphQL and collaboration connections
are dropped. It is recorded in the site's security log as "Two-step sign-in
requirement changed".

Every save needs that fresh second factor, turning the requirement off
included, so a session left open or a stolen password cannot switch it off.
The policy page itself is not exempt from the requirement: an administrator
the site holds sets up their own factor before they can reach it. Why:
[ADR 0030](decisions/0030-the-second-factor-requirement-fails-open-and-only-a-freshly-verified-admin-changes-it.md).

What can go wrong when saving:

- **"Set up two-step sign-in on your own account first."** You hold no second
  factor. Click **Set up two-step sign-in**, add one, then save again.
- **"Confirm with a code from your authenticator app, or sign in again with
  your passkey."** Your sign-in did not verify a second factor in the last 15
  minutes and no code was given. Type a code, or sign in again with your
  passkey. A page left open for more than 15 minutes after signing in asks for
  a code too.
- **"That code isn't valid. Check your authenticator app."** The code was
  wrong or too old. It used one of your account's five attempts per 15
  minutes, shared with the sign-in code prompt.
- **"Too many attempts — try again in N seconds."** Those five attempts are
  spent, here, at the sign-in prompt or on `/editor/settings`. Wait the
  seconds it names.
- **"You don't have permission to change this site's two-step sign-in."** You
  are not an administrator of this site.

### What people see during the grace period

- **A banner** at the top of every console page and of `/account`: "This site
  requires two-step sign-in. N days left to set it up." with a **Set it up
  now** link to `/account/two-factor`. The count is whole days rounded up, so
  the last day reads "1 day left".
- **A reminder after signing in.** Instead of landing where they were going,
  they land on the setup page, which says "(site) requires two-step sign-in
  for your role from (date)." and offers **Not now**, which continues to where
  they were going.
- **Headless sign-ins** get a `second_factor` field in the token response
  (see [Headless clients, tokens and API keys](#headless-clients-tokens-and-api-keys)).

People who already hold a factor, and roles the setting does not cover, see
none of this.

### Set up two-step sign-in when your site asks

Anyone signed in can do this, readers included. You start on `/account/two-factor`:
the site sends you there when it holds you, the banner and the post-sign-in
reminder link to it, and you can open it yourself.

1. Read the line under **Set up two-step sign-in**. Past your deadline it says
   "This site requires two-step sign-in for your role. Set it up to continue."
2. If the page shows **First, confirm it's you**, click **Email me a code**.
   The page says "We sent a code to (your address)." Type the code from the
   email under **Code from the email** and click **Confirm**. The page says
   "Thanks — your email address is confirmed." (When this step is asked for,
   and when it is not, is below.)
3. Under **Authenticator app**, click **Set up an authenticator app**. Scan
   the QR code with your app (or type the **Setup key**), type the current
   **6-digit code** and click **Confirm**. The page says "Two-factor
   authentication is now on." and shows ten recovery codes once: save them,
   then click **I've saved them**.

   Or, on the main or console host, add a passkey under **Passkey**: name it
   if you like, click **Add a passkey** and confirm on your device. The page
   says "Passkey added — you can sign in with it now." A passkey has no
   recovery codes, so the page suggests adding an authenticator app as well.
4. Click **Continue**. You go on to where you were going (only a path on the
   same site is followed), or to the console overview for an editor or admin
   and `/account` for a reader.

The owner of the account is emailed for every factor added, as always
([We email you when a second factor is added](#we-email-you-when-a-second-factor-is-added)).
The page also has **Sign out**. A reader held on a site that requires
everyone also sees **Your membership and data**, with **Manage billing** (when
they have a paid membership to manage) and **Export my data**.

### When the emailed code is asked for

Once a site holds an account, the setup page is the one page it can reach, and
someone who has only the password reaches it too. Without a further check
they could add their own authenticator app and take the account. So a session
that signed in with **only a password** proves it can read the account's
email before it adds a factor.

The code is asked for when all of these are true:

- a site the account belongs to holds it now (past its deadline, no factor).
  Any of its sites counts, not only the one the page is on, because the
  factor added counts on all of them;
- the session signed in with a password, or was restored by a "Remember me"
  cookie, or it is not known how it signed in;
- it signed in at or after the earliest of those deadlines.

It is **not** asked for when:

- the session signed in with a magic link, a password reset or by confirming
  a new account (each already proved the mailbox), with single sign-on (the
  site's own or the operator's OIDC), or with a passkey;
- no site holds the account (it is in its grace period everywhere, or not
  covered);
- the session signed in with a password before the deadline: the grace
  period let it add a factor then, and it still may;
- the site has **no working mail relay**: no outgoing mail server is
  configured for the deployment and the site has none of its own, or the
  site's relay password can no longer be decrypted. The step is skipped and
  the enrollment is recorded with `proof: "email_skipped_no_relay"`.

A relay that fails this time (a refused connection, a site relay whose
settings could not be read just now) does **not** skip the step: the page says
"We couldn't send the code. Try again." Otherwise anyone who could cause a
passing failure would get past it.

The code is six digits, goes through the site's relay, works for 10 minutes,
and works only in the browser session that asked for it. At most three are
sent to an address an hour. Each attempt to confirm one uses one of the
account's five second-factor attempts per 15 minutes, the same budget as the
sign-in code prompt, before the code is compared. The code is never stored
(the page keeps only a keyed hash), logged or shown. Its email says what to do
if you did not ask for it: reset your password, which signs out every session.

The check is made again by the enrollment itself (`User` `:confirm_totp`,
`Passkey` `:register`), not only by the page, so a page that skipped the step
cannot add a factor. `/editor/settings` has no email step: an account that
owes one is refused there with "Confirm your email address before adding a
second factor." and sets up on `/account/two-factor` instead.

What can go wrong on the setup page:

- **"Confirm your email address before adding a second factor."** The email
  step is still owed. Do step 2 first.
- **"That code isn't valid — try again."** Wrong code, or a code sent to
  another browser. It used one attempt.
- **"That code has expired. Send a new one."** More than 10 minutes passed.
  Click **Send a new code**.
- **"We've sent several codes already. Wait a while, then try again."** Three
  codes went to the address in the last hour.
- **"We couldn't send the code. Try again."** The mail relay failed this time.
- **"Too many attempts — try again in N seconds."** The account's five
  second-factor attempts are spent, here or at the sign-in prompt.

### What a held account can still reach

A held account is sent to `/account/two-factor` before anything else, by every
door: the sign-in itself, every page of the site (public pages included), the
console's LiveViews (also a page left open when the deadline passes or the
policy changes), `/membership` and plugin pages. The redirect is a `302`
marked `private, no-store` that writes no session and no cookie, so a shared
cache can never store it for other visitors.

It can still reach:

- `/account/two-factor`, and **Sign out**;
- the sign-in pages, `/sign-in/verify`, `/auth/*`, invitations and unlock
  links;
- `POST /billing/portal` and `GET /editor/account/export.json` (managing a paid
  membership, and the export of the account's own data);
- `/locale/:locale`, `/access-denied`, `/developers` and `/api`;
- `/preview/...` and `/newsletter/...` links, which their own tokens authorize,
  and `/setup`;
- images (`/media/:id/t/...`), which are served as to a visitor who is not
  signed in, because an image cannot follow a redirect;
- anything an API key reaches.

To read the public site while held, sign out. The demo mode's shared account
is never held.

### Passkey-only accounts

An account whose only factor is a passkey satisfies the requirement, but its
password alone must not sign it in once the deadline has passed:

- **On the main or console host**, a password (or a magic link, or single
  sign-on) stops at `/sign-in/verify`, which says "Confirm it's you with your
  passkey." and offers **Use a passkey**.
- **On a site's own host**, where a passkey cannot run, the password is
  refused: the sign-in page says "Your account's second factor is a passkey,
  which works at (main host). Sign in there, or add an authenticator app."
- **A session that signed in with the password before the deadline**, or that
  a "Remember me" cookie restores, is sent through the same passkey prompt
  (or signed out, on a site's own host). A session that signed in with the
  passkey, or passed it at the prompt, carries on.
- **Headless:** a passkey cannot be used outside a browser, so the account's
  tokens and its headless sign-in are refused (below).

Before the deadline, and on a site that requires nothing, its password signs
it in as before.

### Headless clients, tokens and API keys

**API keys are not affected.** They carry no second factor by design and are
never held, on any surface (JSON:API, GraphQL, MCP, `/ws/bridge`, key
rotation).

A user's JWT is checked **on every request**, so a token issued during the
grace period stops working at the deadline:

- `POST /api/auth/sign_in` answers a held account `403`
  `second_factor_required` and issues no token (the one the password minted is
  revoked). `meta.setup_url` is the setup page, `meta.deadline` when the grace
  ended, and `meta.reason` is `"passkey_only"` for a passkey-only account.
  During the grace period the `201` carries
  `"second_factor": {"required": true, "deadline": "…"}`. An account with an
  authenticator app still gets the `200 two_factor_required` step.
- `/api/*` (JSON:API, media, the content and posture routes), `/gql` and
  `/api/feed` answer a held account's JWT `403` `second_factor_required`, on
  public reads too: the token is no longer good, and the answer says so
  rather than serving the request as anonymous. Drop the header to read
  public content.
- `/ws/gql` refuses the connect (the handshake answers `403`), closes a
  socket opened during the grace period at the deadline, and refuses every
  document sent on an open socket afterwards with `extensions.code`
  `"second_factor_required"`.
- `/ws/collab` refuses the connect and closes an open room within 30 seconds
  of the deadline.

Request and response shapes: [API § Accounts a site requires two-step sign-in of](api.md#accounts-a-site-requires-two-step-sign-in-of).
Each refused request emits `[:kiln_cms, :api, :second_factor_required]`
([Observability](observability.md#refused-api-credentials)); it writes no
security event.

### Your last second factor stays while a site requires one

While any site an account belongs to requires a second factor (in the grace
period too), the owner cannot remove the account's last one. On
`/editor/settings`, the authenticator app's **Disable** form, or the last
passkey's remove (trash) button, is replaced by "A site you use requires
two-step sign-in, so you can't remove your last second factor. Add another one
first." The same refusal comes from
the action itself, before any code is checked, so it costs no attempt.

Replacing the authenticator app still works (also after signing in with a
recovery code), and so does removing the app while a passkey remains, or a
passkey while another factor remains. A platform admin removing someone's
passkey, and an invitation taking over an unconfirmed account, are not
affected: those are how a lost or stolen factor is cleared.

### For operators

- **Upgrading changes nothing by itself.** No site requires anything until an
  administrator saves the setting. The migration (`site_second_factor_policy`,
  `users.inserted_at`) is expand-only; existing accounts get the time it ran
  as their creation time, so none starts out overdue.
- **Headless clients of a held account get `403`.** A script or app that signs
  in as a person on a site that holds that person stops working at the
  deadline. Give it an API key instead.
- **Mail.** The email step goes through the site's relay. A deployment with no
  outgoing mail server skips it, which leaves the enrollment protected only by
  the "a second factor was added" email to the owner (which also needs a
  relay). The three-codes-an-hour cap per address is code config:
  `config :kiln_cms, KilnCMS.Accounts.AccountThrottle, enrolment_proof_mail_budget: 3`.
- **Rolling back** to a release before this one drops the enforcement without
  a warning: the table stays and an older release ignores it. Nobody is held,
  and headless tokens work again.
- **The way back in** when no administrator can pass the requirement is the
  server command below.
- **Recorded:** "Held for two-step sign-in setup" (`second_factor_required`)
  once per sign-in that a requirement held or refused, and `proof` on every
  enrollment ([What is recorded](security-events.md#what-is-recorded)).

If the setting cannot be read (a database error), the site is treated as
requiring nothing until it can be, rather than holding every account; see
[ADR 0030](decisions/0030-the-second-factor-requirement-fails-open-and-only-a-freshly-verified-admin-changes-it.md).

### Turn the requirement off from the server

If no administrator of a site can pass its requirement, for example the last
administrator lost their only passkey, an operator with a shell on the
running release turns it off. You need `bin/kiln_cms` on a node of the
running cluster, and the site's slug if it is not the default site.

1. Run the command with `rpc`, not `eval` (the change has to reach the running
   application and clear every node's cached copy):

   ```sh
   bin/kiln_cms rpc 'KilnCMS.Release.second_factor_requirement_off()'
   bin/kiln_cms rpc 'KilnCMS.Release.second_factor_requirement_off(org: "acme")'
   ```

   The first acts on the default site; `org: "<slug>"` acts on another one.

2. Read what it printed. A site that required a second factor:

   ```text
   Turned off the two-step sign-in requirement (it was: admins).
   The change reaches every node now, and is in the site's security log.
   ```

   A site that requires nothing (every site, in this release) is left as it
   is:

   ```text
   This site does not require two-step sign-in; nothing to turn off.
   ```

3. As an admin of that site, open **Security log** under **Organization** in
   the console sidebar. The change is at the top as "Two-step sign-in
   requirement changed", with no one under **Who** and no IP address. (Its
   metadata, `via: "console"` among it, is stored but not shown on the page.)

The command sets the requirement to off and nothing else: the grace period is
kept, and nobody's second factor is touched. It runs as the server's own
`:operator` actor; an administrator cannot run the same action from the
console. Once an administrator has set up a second factor, they can turn the
requirement back on at `/editor/two-factor`.

`rpc` exits 0 whatever the command returns, which is `{:ok, :off}` or
`{:error, message}`. A script that must fail on an error matches the result:

```sh
bin/kiln_cms rpc '{:ok, :off} = KilnCMS.Release.second_factor_requirement_off()'
```

What can go wrong:

- **"This needs the running application … Run it against the live node with
  `bin/kiln_cms rpc '...'`, not `bin/kiln_cms eval`."** You used `eval`. Run
  the same call with `rpc`.
- **"No organization with slug acme"**: no site has that slug. Leave `org:`
  out for the default site.
- **"Could not read the two-step sign-in requirement: …"**: the setting could
  not be read, usually a database problem; the rest of the line says what.
  Nothing changed.
- **"Could not turn off the two-step sign-in requirement: …"**: the write
  failed, and nothing changed, its security log event included. Fix the cause
  the line names and run the command again.

## The TOTP implementation

`KilnCMS.Accounts.Totp` implements RFC 6238 on Erlang's `:crypto` (HMAC-SHA1)
with **no external dependency**. Correctness is pinned to the RFC 6238 published
test vectors (`KilnCMS.Accounts.TotpTest`). Defaults: 6 digits, 30-second period,
±1 step of clock-drift tolerance, constant-time code comparison.

The raw secret is stored as `users.totp_secret` (`bytea`, `sensitive?`,
`public? false`); it is never exposed on any API surface and is read only by the
sign-in gate and the owner's enrolment UI. 2FA is "enabled" iff
`totp_confirmed_at` is set. `users.totp_pending_secret` holds an in-progress,
not-yet-proven enrolment in the same shape — `setup_totp` writes only this
one, `confirm_totp` is the only action that ever copies it into `totp_secret`,
and it is what a code is checked against while an enrolment is in progress
(#754).

## Recovery codes & QR (Phase 2, shipped)

- **Recovery codes.** Confirming enrolment mints 10 one-time codes
  (`XXXX-XXXX`), shown exactly once — only SHA-256 hashes are stored
  (`totp_recovery_hashes`; the codes are 40-bit uniform random, so a fast hash
  is appropriate, matched in constant time). At the sign-in gate a recovery
  code works in place of the 6-digit TOTP and is **burned in the same update**
  (`:consume_totp_recovery_code`), so it can never sign in twice.
  `/editor/settings` shows the unused count and can regenerate the set (needs a
  current authenticator code; regeneration invalidates unused codes). Disabling
  2FA clears the set. Regeneration checks the code against the account as the
  request loaded it, so it also re-checks the account's row under lock
  (`Changes.GuardAccountTakeover`, #2453): a regeneration from a session that
  predates an invitation's takeover of the account is refused with
  `KilnCMS.Accounts.Errors.AccountTakenOver` rather than writing codes the
  stranger knows onto the invitee's account. The page shows "That code isn't
  valid — try again."
- **Invitation takeover.** Accepting a site invitation with a password over an
  unconfirmed account clears the live secret, the recovery codes and any
  pending enrollment, with no code asked for (#2453): whoever registered the
  address first may have enrolled them, and the invitee proved the mailbox
  instead. A password reset finished on an unconfirmed account, and a
  magic-link sign-in to one, clear them the same way (#2594), recorded with
  `via` `password_reset` or `magic_link`. A reset or magic link on a
  **confirmed** account never touches the factor. Recorded as
  `second_factor_removed` with `via` `invitation` when a confirmed factor was
  removed by an invitation. See
  [What taking over an account removes](account-administration.md#what-taking-over-an-account-removes).
- **QR-code image.** Enrolment renders the `otpauth://` URI as an inline SVG QR
  (`eqrcode`, pure Elixir) alongside the setup key.

## Scope & later phases

Shipped since, and no longer out of scope:

- **Passkeys/WebAuthn** — `KilnCMS.Accounts.WebAuthn`,
  `KilnCMSWeb.PasskeyController`, `/auth/passkey/*`. A verified passkey
  completes sign-in **without** a TOTP prompt, on purpose: every Kiln passkey is
  registered *and* asserted with user verification required, so the ceremony
  already proves possession + PIN/biometric. That is policy, and
  `docs/threat-model.md` records it as such. An account with both can also use
  its passkey *at* the TOTP prompt instead of a code
  ([Using a passkey at the code prompt](#using-a-passkey-at-the-code-prompt)).
  Passkeys are browser-only — there is no headless ceremony, so the headless
  `POST /api/auth/sign_in/verify` still takes a code.
- **SSO (OAuth2/OIDC)** — built on `assent` (bundled with
  `ash_authentication`), compile-gated off by default: set
  `config :kiln_cms, :sso_oidc, enabled: true` plus the `OIDC_*` env and
  recompile. An SSO sign-in completes through `AuthController.success/4` like
  any other, so a 2FA account is diverted to the code prompt from there too.

Still out of scope (the other half of #331):

- **SAML.**
