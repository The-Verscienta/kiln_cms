# 0020. Human verification is deployment-wide, and fails open only within the sign-in budget

- **Status** — accepted (2026-11-08). Partly superseded by
  [ADR 0022](0022-a-challenge-provider-is-a-plugin-contract-and-the-core-enforces-its-claims.md):
  the provider is now a plugin contract, and reCAPTCHA v2 is built in.
- **References** — [#2249](https://github.com/The-Verscienta/kiln_cms/issues/2249)
  (the first of three parts), following
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  and #478 (`KilnCMS.Accounts.AccountThrottle`).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

#2249 asks for a CAPTCHA on password sign-in and registration. The
`AccountThrottle` budget (20 attempts per address per 15 minutes) already
bounds guessing against one account, but it is a lockout: an attacker who
spends it locks the owner out for the window. A challenge is the softer step
before that, for the attempts that look like a run. Four questions decide
whether it helps or becomes a new way to hurt people:

- **Who sets it.** Most of Kiln's sign-in settings are a site's (#2246, #2248).
  An account is not: one `User` signs in on every site it belongs to.
- **What a refusal costs.** If a refused attempt spends the account budget, an
  attacker who never solves a challenge still locks the owner out, and the
  challenge has become the lockout it was meant to soften.
- **What happens when the provider is down.** Failing closed hands a third
  party's outage the power to stop everyone signing in. Failing open hands an
  attacker a way past the control: make the provider look down.
- **What it tells an attacker.** A challenge asked for on known accounts and
  not on unknown ones is an account-existence oracle.

## Decision

- **Operator-only and deployment-wide.** The provider, its keys and the modes
  (`sign_in` `:off | :adaptive`, `registration` `:off | :adaptive | :always`)
  are the operator's (`KilnCMS.Challenge`, `CHALLENGE_*`). There is no per-site
  setting. By ADR 0018's test, a site's looser setting must cost only that
  site; a site that switched sign-in challenges off would be the door every
  other site's accounts are guessed through, because the account is the same.
  Whether a challenge is needed is decided from the account's and the caller's
  counters, never from the host that was dialled.
- **Enforced on the actions.** `ThrottleSignIn` (on `:sign_in_with_password`)
  and `RequireRegistrationChallenge` (on `:register_with_password`) call
  `KilnCMS.Challenge.Gate`, so the LiveView, the no-JavaScript form POST and
  the headless endpoint pass one check. The headless endpoint is opted in
  separately (`api_sign_in`, off by default), because turning it on changes a
  published contract for every app that signs people in.
- **Two axes, each with free attempts spent atomically.** The account axis is
  a bucket keyed on the *submitted* address, so an address with no account is
  asked exactly when one with an account would be. The client-address axis is
  reserved before the password is checked and refunded when it was right, so
  in effect it counts failures. Each spend is one increment-and-compare
  (`ThrottleStore.hit/5`), so a burst at the start of a window cannot all read
  "under the threshold" and skip the challenge together. A read-only
  `ThrottleStore.peek/3` serves the pages that decide whether to draw the
  widget before the first submit, and the fail-closed point; it never admits.
- **A refusal costs nothing.** The gate runs after the per-IP `:auth` charge
  and before `AccountThrottle.consume/1`. An attempt refused for want of a
  challenge never reaches the budget and pays no bcrypt. The budget stays the
  only thing that admits. No simulated hash is needed for timing: whether a
  challenge is required never depends on whether the account exists.
- **Fail rules.** A refusal the provider gave never passes. Only "could not be
  asked" (timeout, transport error, `5xx`, `429`, a malformed answer, an
  unreadable or rejected secret, a crash) may admit, and only within bounds:
  for sign-in, the account's own budget, which applies anyway, and a separate
  closed point of `ip_closed_after` failed sign-ins per client address (20 by
  default); for registration, the existing per-address `:register` rate
  limit. Any other 4xx from the provider is a refusal.
- **A missing token fails open only during an observed outage.** When the
  widget's script cannot load, a real visitor has nothing to submit. Refusing
  them while admitting an attacker who sends junk (which reaches the provider
  and comes back unavailable) would be backwards. So for `outage_window` (60
  s) after a node sees an unavailable answer, a missing token on that node
  gets the same bounded treatment. The memory is node-local and lapses on its
  own.
- **Hostnames come from the deployment, not the request.** A token is accepted
  when the provider reports a host this deployment serves (the canonical host,
  the console host, any site's host) or one the operator listed in
  `CHALLENGE_HOSTNAMES`. The request's own `Host` header, or a LiveView join
  URL, is the caller's to choose, so it never vouches for where a token was
  solved.
- **Turnstile only, and the provider behaviour stays internal.** Turnstile adds
  one origin, `https://challenges.cloudflare.com`, which serves nothing but the
  widget. reCAPTCHA needs `www.google.com` in `script-src`, an origin with
  JSONP endpoints that is a known way round a strict policy. The
  `KilnCMS.Challenge.Provider` behaviour is not in the plugin SDK: an SDK
  callback is a promise for all of 1.x, and this shape should be proven by a
  second provider first.
- **The page policy widens only while a challenge can be shown.** Only the
  `:browser_auth` pipeline, and only with a usable provider and a mode that is
  not `:off`; byte-identical otherwise.
- **Never on the accessible ways in.** Passkeys, magic links, password reset,
  the second factor, single sign-on and invitations are never challenged, and
  the fallback copy names only the ones the site offers.

## Considered and rejected

- **A per-site mode now.** The bypass described above. Per-site keys (each
  site its own widget and secret) do not have that problem and are planned;
  a per-site sign-in mode is not.
- **Charging the budget before deciding.** Turns every unsolved challenge into
  a unit of the owner's lockout.
- **Deciding by reading the counters (check, then act).** A burst all reads
  the same count; the free attempts are spent atomically instead.
- **Failing closed on any provider error.** A Cloudflare outage would stop all
  password sign-in on every deployment that turned this on.
- **Failing open without a bound.** Blocking or slowing the provider's endpoint
  from the attacker's side, or sending tokens that time out, would switch the
  control off.
- **Trusting the request's host for the hostname check.** A POST can name any
  host; a token solved on another page that uses the same site key would pass.
- **Challenging magic links, reset, passkeys, 2FA or SSO.** Each is either a
  proof the attacker does not hold or the accessible way out for someone who
  cannot complete a check.
- **reCAPTCHA v3 (score only).** No user-visible step, a score with no clear
  threshold, and the same `script-src` problem.
- **Caching a verified token or a "passed" session flag.** A token is good for
  one verification; a flag would be a replayable pass.

## Follow-ups

The work is split so each part ships on its own:

1. This part: password sign-in and registration, Turnstile, operator config.
2. Public forms: a forms mode, what a form without a token does, the delivery
   and embed page policies. Shipped as a per-form setting under an operator
   ceiling, with unverified submissions held for review: see
   [ADR 0021](0021-a-form-opts-in-to-human-verification-and-an-unverified-submission-is-held-not-refused.md).
3. reCAPTCHA v2 and a plugin SDK callback for providers: shipped, see
   [ADR 0022](0022-a-challenge-provider-is-a-plugin-contract-and-the-core-enforces-its-claims.md).
   Per-site keys and a settings page (sign-in stays deployment-wide) moved to
   [#2505](https://github.com/The-Verscienta/kiln_cms/issues/2505), and a
   self-hosted proof-of-work provider to
   [#2506](https://github.com/The-Verscienta/kiln_cms/issues/2506).

Also: a deployment-wide trigger on the overall sign-in failure rate, for
credential stuffing spread thinly across many accounts and addresses.
