# 0050. A site invitation is its own row, not an account written up front

- **Status** — accepted (2026-11-13), recording the design #2448 shipped
  (merged 2026-11-08). It is written after the fact, so it argues against the
  code as it is now. That code includes #2594 (fixed by #2704), which came
  after #2448: since then the confirmation link needs the sign-up password,
  and a reset or a magic link over an unconfirmed account forgets the earlier
  registrant's credentials.
- **References** — [#2135](https://github.com/The-Verscienta/kiln_cms/issues/2135)
  and [#2448](https://github.com/The-Verscienta/kiln_cms/pull/2448), which
  built it; [#2454](https://github.com/The-Verscienta/kiln_cms/issues/2454),
  which asked for this record;
  [#2594](https://github.com/The-Verscienta/kiln_cms/issues/2594) and #2453
  for the pre-hijack paths; #2255 for `RefuseExistingAddress`;
  [ADR 0024](0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)
  for the membership that grants nothing.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#team-invitations) (Added),
  with its [upgrade note](../changelog/v1.9.0.md#team-invitations-upgrade).

## The problem

A platform admin wants to bring someone onto a site who has no account yet.
The obvious way is to create the account when the admin presses **Add or
invite**: a `User` with the address, no password, unconfirmed, with a
membership at the chosen tier, and a mail asking the person to set a
password. Everything else in the system already understands users and
memberships, so nothing new would be needed.

That account would exist, under the invitee's address, before the invitee
had done anything. Every part of sign-in that looks an address up would find
it, and each one treats an existing, unconfirmed account as something to
protect against, because anyone can register an unconfirmed account for any
address.

## Decision

An invitation is a row of its own, `KilnCMS.Accounts.Invitation`: an
address, a site, a tier (and optional custom role), the inviter, an expiry,
and the SHA-256 of the mailed token. No `User` and no `OrgMembership` exist
for the address until the invitee clicks the link and accepts:

- with no account, `User.:register_with_invitation` creates a confirmed one;
- over an unconfirmed account, `User.:accept_invitation_with_password` sets a
  new password, confirms it, revokes every token and forgets the earlier
  registrant's credentials (`KilnCMS.Accounts.Changes.ForgetPriorCredentials`);
- a confirmed account accepts with one click.

`KilnCMS.Accounts.Changes.AcceptInvitation` adds the membership
(`KilnCMS.Accounts.Invitations.grant_membership/4`) and consumes the row in
the same transaction as the account write. The rules are in the
`KilnCMS.Accounts.Invitations` moduledoc.

## Why not an account up front

Each of these holds in today's code:

- **Single sign-on would refuse the invitee.** The operator's provider
  registers through `User.:register_with_sso`, an upsert on `:unique_email`.
  The confirmation add-on's `prevent_hijacking?` (on by default) makes
  `AshAuthentication.AddOn.Confirmation.ConfirmationHookChange` add a filter
  to that upsert that fails with `CannotConfirmUnconfirmedUser` when the
  existing row is unconfirmed; `KilnCMSWeb.AuthController` turns it into
  "confirm your account or reset your password". A site's own provider
  refuses the same row: `KilnCMS.Accounts.SiteSso.Admission` answers
  `{:error, :unconfirmed_account}` for any existing account without
  `confirmed_at`. The invitee could not sign in the way their site expects.
- **Self-registration would refuse the invitee.**
  `KilnCMS.Accounts.Changes.RefuseExistingAddress` on
  `User.:register_with_password` creates no row for an address that already
  has an account. It answers "check your email" and mails the owner a
  notice instead. The invitee who tried to sign up would get a mail saying
  they already have an account they never made.
- **The account would be mailed a confirmation it cannot complete.**
  `confirm_on_create?` is on for `:confirm_new_user`, so any create not in
  `auto_confirm_actions` sends "confirm your email". Since #2594,
  `User.:confirm_new_user` asks for the password chosen at sign-up as well as
  the token, and an account written up front has none the invitee knows. The
  only way in would be a password reset.
- **The tier would be held before anyone accepted it.** A membership written
  at the chosen tier grants it at once. An invitation that is never accepted, sent to
  a mistyped address, or revoked would have been a live role on the site
  until someone removed it. As a row of its own, an invitation grants
  nothing: `AcceptInvitation` writes the membership only once the token is
  presented, and re-checks that an `:admin` invitation's sender is still a
  standing platform admin (`Invitations.inviter_still_admin?/1`).

## Rejected

- **An account up front, auto-confirmed.** Adding the create to
  `auto_confirm_actions` would silence the mail and pass the SSO checks, but
  only by vouching for an address nobody had proved. `confirmed_at` is what
  the hijack filter, `SiteSso.Admission` and
  `KilnCMS.Accounts.Invitations.AddOrInvite` each read as "the mailbox owner
  did this": a mistyped address would leave a confirmed account, holding a
  tier, for a stranger's mailbox, and the next site to add the address would
  add it directly instead of inviting it. It would also leave
  self-registration refused.
- **An account up front with a pending membership** (the shape
  [ADR 0024](0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)
  uses for registrations awaiting approval). It fixes the tier held early,
  but not the other three: those are about the account row, not the
  membership.

## Consequences

- An invitation is new personal data: an address held for at most the 7-day
  life plus 30 days until the daily `:prune_expired` sweep. The staging scrub
  deletes the table.
- A pending invitation admits nobody through single sign-on, on the
  operator's provider or a site's own: the invitee accepts with a password
  first ([sso.md](../sso.md)). After that the account is confirmed, and SSO
  signs it in as an existing account.
- Inviting an address that has an unconfirmed account invites it rather than
  adding it, and accepting takes that account over.

See [Invite someone to a site](../account-administration.md#invite-someone-to-a-site).
