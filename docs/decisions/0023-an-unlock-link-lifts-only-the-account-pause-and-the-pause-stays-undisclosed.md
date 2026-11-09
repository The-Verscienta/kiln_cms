# 0023. An unlock link lifts only the account pause, and the pause stays undisclosed

- **Status** — accepted (2026-11-09).
- **References** — [#2250](https://github.com/The-Verscienta/kiln_cms/issues/2250),
  following #478 (`KilnCMS.Accounts.AccountThrottle`) and
  [ADR 0020](0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md)
  (the challenge before the pause).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

`AccountThrottle` pauses password sign-in for an address after 20 attempts in
a 15-minute window, and the pause answers exactly as a wrong password does,
so it is not an account-existence or "this account is under attack" oracle.
An owner who paused themselves had two ways out: wait for the window, or
reset a password they did not need to change. #2250 asks for an emailed link
that lifts the pause.

What it is worth is modest, and should be said plainly. It lifts a pause of up
to 15 minutes without a password change. A completed reset already lifts it.
Against an attacker still guessing, the account pauses again within seconds.
The link is for the owner who paused themselves and would rather not reset.
Its risks are the usual ones for an emailed credential (scanners, stale links,
a changed address, the wrong site) plus two of its own: becoming an oracle for
which accounts are paused, and becoming a stronger credential than the reset
the same mailbox can already ask for.

## Decision

- **It clears the `signin` counter and nothing else.** Not the free attempts
  before a challenge, the second-factor budget, the alert windows or any
  per-address bucket. It signs no one in, mints no session, confirms nothing
  and touches no other token. Whoever signs in next pays the challenge, the
  per-IP limit and the second factor as before.
- **The pause stays undisclosed.** The sign-in page always shows the same
  link ("Paused after too many attempts?"), whatever happened. The request
  page answers one sentence for every address. The request path never looks
  the address up: it hands off to a task under its own bounded supervisor, and
  the task decides, in order, that the account exists, is confirmed, is not
  erased or the demo's shared account, is paused, and belongs to the site the
  request was made on. Only then is the per-address unlock mail budget (3 an
  hour) charged, so an address that is never mailed writes no counter row.
- **Only a member of the requesting site is mailed.** A membership on that
  site, or the legacy no-membership account on the default site, the same
  rule that decides whether a security event names the account. The mail is
  in that site's branding and the link works only there, so a person is sent
  to their own site's sign-in page rather than mailed in the name of a site
  they do not belong to. A non-member gets no mail and no event; the response
  is the same either way.
- **The link is an AshAuthentication token, not a new mechanism.** Purpose
  and `act` `sign_in_unlock`, stored like every token, 15 minutes, single use
  through the token resource's atomic revocation, revoked by a password change
  or reset with every other token. It is refused as a bearer credential and by
  the reset, confirmation, magic-link and token sign-in routes.
- **It is bound to the site and the address.** An `org` claim names the site
  the request was made on; the mail is in that site's branding and the link
  opens on its host. On another site it is refused and not spent. An `ed`
  claim is a keyed HMAC of the address it was mailed to (the claims are also
  stored in `tokens.extra_data`, where a bare hash of an address would be a
  lookup away from it); an address change since refuses the link.
- **Opening it spends nothing.** The `GET` is the same page for any token.
  Only the button's `POST` redeems, so a mail scanner cannot use it up, and
  the refusal page allows for one that clicked through.
- **System-only actions.** `User.:request_sign_in_unlock` and
  `:redeem_sign_in_unlock` are `forbid_if always()`, and refuse an
  actor-carrying call themselves because the admin bypass would pass that.

## Considered and rejected

- **Saying "locked out" or answering 429 at sign-in.** Turns the pause into
  an oracle for which accounts are being guessed at.
- **Reusing `forgive/1`.** It also hands back the free attempts before a
  challenge, which a mailbox proves nothing about.
- **Clearing the per-IP buckets or the second-factor budget.** The link
  proves the mailbox, not the caller's address or the second factor.
- **A token in the "unusual sign-in activity" alert.** That mail goes out on
  a lockout anyone can cause; a token in it is minted on an attacker's
  schedule. The alert links to the request page instead.
- **Looking the address up on the request path, or charging the mail budget
  before the lookup.** The first is a timing oracle; the second writes a
  counter row for every address anyone names.
- **A JSON request endpoint.** There is no headless reset or magic-link
  request today, and redeeming is browser-only. A headless account-recovery
  request is a follow-up of its own.
- **A custom HMAC token, `Phoenix.Token` or a dedicated resource.** The token
  resource already gives storage, expiry, atomic single use and revocation on
  a password change.

## Residual risks

- A node that counted sign-in attempts in its own fallback table while the
  database was unreachable keeps those counts through an unlock made
  elsewhere, until its window rolls (`ThrottleStore`'s documented bound).
- A newer link does not revoke an older one. Each is short-lived and single
  use, and the mail budget bounds how many exist.
- A link revoked by a password change is recorded as `used` in the security
  log, not as revoked.
