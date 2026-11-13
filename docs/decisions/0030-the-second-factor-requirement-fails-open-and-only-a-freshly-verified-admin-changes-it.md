# 0030. The second-factor requirement fails open, and only a freshly verified admin changes it

- **Status** — accepted (2026-11-13). The policy, its requirement logic and
  the save guard shipped first, with nothing enforced; the enforcement this
  record describes (the sign-in doors, the per-request JWT check) is the last
  part of #2247.
- **References** — [#2247](https://github.com/The-Verscienta/kiln_cms/issues/2247)
  and the owner's decisions on it of 2026-11-09;
  [ADR 0026](0026-the-ip-block-list-fails-open-and-covers-dynamic-routes-only.md)
  for the same failure direction on another control, and
  [ADR 0019](0019-the-admin-allowlist-fails-closed-and-only-the-operator-lifts-it-from-outside.md)
  for the opposite one.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A site can require a second factor (an authenticator app or a passkey) of its
administrators, of its editors and administrators, or of everyone, after a
grace period (`KilnCMS.CMS.SiteSecondFactorPolicy`). Four questions decide
whether that requirement protects accounts or becomes a way to lose them, and
each has an obvious answer that is wrong:

- **What happens when the site's requirement cannot be read?**
- **Which credentials does it reach?** A browser session is checked as it is
  used; a headless JWT is minted once and lives about 14 days; an API key is
  meant for unattended use.
- **Who may change it, and with what proof?** The setting that holds everyone
  to a second factor is also the setting an attacker with a password wants
  off.
- **How does a site get back in** when no administrator can pass it?

## Decision

- **An unreadable requirement is read as off.**
  `KilnCMS.Accounts.TwoFactorRequirement.policy/1` reads the row as the
  `:accounts` system actor with `authorize_with: :error`, so a refused read is
  an error and not "no row". On an error it logs, answers `off/0` and **does
  not cache the failure**: the next question reads again. `read_policy/1`
  tells the two apart (`:error`), for the posture check, which must not report
  a requirement it cannot see as one that is unset. This is the direction
  `KilnCMS.Accounts.IdleTimeout` takes.
- **Headless JWTs are checked on every request; API keys are exempt.** A JWT
  minted during the grace period stops working at the deadline instead of
  living out its lifetime (owner decision 3). API keys carry no second factor
  by design and are not held. The per-request check is part of the
  enforcement, not of the policy that shipped first.
- **Every save needs the saver's own second factor, proved now.**
  `KilnCMS.CMS.Changes.SaverVerifiedSecondFactor` runs on the person-facing
  `:save` and `:update`, strengthening included. It re-reads the actor, who
  must hold a second factor and either carry a verified mark no more than 15
  minutes old (the changeset context's `:second_factor_verified_at`) or give a
  current authenticator code, charged to the account's shared second-factor
  budget before the transaction so a wrong code's rollback cannot refund it.
  `:destroy` is refused to everyone: off is a save of `required_for: :off`, one
  path with one audit event (`second_factor_policy_changed`).
- **Only the operator turns it off from outside, and only off.**
  `KilnCMS.Release.second_factor_requirement_off/1` runs
  `:operator_override` as the `:operator` system actor: it sets
  `required_for` to `:off`, keeps the grace period, and records the change
  with `via: "console"` and no person. An org admin is refused the action.
- **A promotion does not restart the grace period.** The deadline runs from
  the latest of the account's creation, its membership's creation and the
  moment its tier became covered (`TwoFactorRequirement.deadline/3`), so a
  long-standing viewer promoted to admin on a site that requires admins is
  held at once, and the promoting admin is warned
  (`TwoFactorRequirement.promotion_warning/4`; owner decision 6).

## Rejected

- **Fail closed when the requirement cannot be read.** It would hold every
  covered account on every site during a database blip, at the sign-in doors
  and on every request, which is an outage. The exposure of failing open is
  bounded: an account that has no second factor signs in as it did before the
  requirement existed, for as long as the read fails, and the failure is in
  the log.
- **Let a JWT live out its lifetime.** It would make the deadline about two
  weeks late for every headless client minted in the grace period.
- **Hold API keys too.** The issue exempts them, and an integration has no one
  to set up a second factor.
- **Guard only weakening, or accept any session that ever verified a
  factor.** A password-only session on a passkey-only admin, or a session
  signed in before the admin enrolled, could switch the requirement off; so
  could a session that verified a factor days ago and was left open. Guarding
  every write is also simpler: an admin who has no factor cannot turn the
  requirement on and lock themselves out.
- **Let the operator's way in run `:save` as a system actor.** `:save` takes
  any value, so the way in would also be a way to turn the requirement on or
  change the grace from a shell. A dedicated action that can only set off
  keeps the console the only place the requirement is strengthened.
- **Restart the grace on a promotion.** Demoting an account and promoting it
  again before each deadline would then keep it out of the requirement
  indefinitely.

## Consequences

- While the requirement cannot be read, it is not enforced. The warning in the
  log is the signal, and `read_policy/1` lets the posture check report the
  setting as unreadable rather than as off.
- An admin whose session verified its second factor more than 15 minutes ago
  gives a code to save the setting, or signs in again; a passkey-only admin
  signs in again.
- A last administrator who loses their only factor is recovered from the
  server, not the console, and the recovery is in the site's security log.
- Rolling back past the enforcement drops it silently: the table stays, and an
  older release ignores it.
