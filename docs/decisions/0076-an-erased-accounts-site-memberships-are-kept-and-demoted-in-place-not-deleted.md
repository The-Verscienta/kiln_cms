# 0076. An erased account's site memberships are kept and demoted in place, not deleted

- **Status** — accepted (2026-11-19).
- **References** — [#3024](https://github.com/The-Verscienta/kiln_cms/issues/3024)
  (this record); [#2774](https://github.com/The-Verscienta/kiln_cms/issues/2774)
  (erasure left every membership as it was, fixed in
  [#3022](https://github.com/The-Verscienta/kiln_cms/pull/3022)), which
  builds on [#2514](https://github.com/The-Verscienta/kiln_cms/issues/2514)
  (erase on reject) and [#2251](https://github.com/The-Verscienta/kiln_cms/issues/2251)
  (registration approval, [ADR 0024](0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)).
  The guides are [data-flows.md](../data-flows.md) and
  [account-administration.md](../account-administration.md#removing-an-account).
- **Changelog** — v1.11.0, under Fixed
  ([long form](../changelog/v1.11.0.md#erasure-demotes-site-memberships)),
  with the backfill under Upgrade notes
  ([long form](../changelog/v1.11.0.md#erasure-backfill-memberships-upgrade)).

## The problem

Erasing an account (`KilnCMS.Accounts.Changes.AnonymizeUser`) keeps the
`users` row so authorship and history stay referentially intact. Before
#2774 it also left every `org_memberships` row exactly as it was. A
tombstone therefore kept its site tier, a live temporary tier and its
audiences: it stayed on the admin and assignee rosters and could read gated
content.

Something had to be done to those rows, and four things are tempting. The
rows are not only a grant. A membership row is also a record: of who
belonged to a site, and, since #2251, of a registration decision (`status`
and `decided_at`: `:pending`, `:active` or `:rejected`). #2514 then made
erasure part of a rejection: with the site's `rejected_accounts` setting, an
unconfirmed applicant is erased in the transaction that rejects them, and
the `:rejected` row is what is left to say so (the console shows it with an
**Account erased** badge). A fix has to stop the row granting without losing
what it records.

## The decision

**Erasure keeps every membership row of the account and demotes it in
place.** `OrgMembership.:erase` writes four columns and nothing else:
`role` to `:viewer`, `granted_role` and `granted_role_expires_at` to `nil`,
and `audiences` to `[]`. It does not touch:

- `status` and `decided_at`, so a pending, active or rejected row stays what
  it was, and a rejected applicant's row survives their erasure;
- the restrictions: `editable_types`, `readable_types`, `field_grants`,
  `field_read_grants` and the custom role (`role_id`). Each means "empty is
  unrestricted", so the row is a bare viewer whose scopes are whatever they
  were.

Everything that makes this safe is in the modules, not in the row:

- **Who may write it.** `:erase` is system-only. The policy on
  `OrgMembership` forbids it to every actor, a platform admin included
  (`forbid_if action(:erase)` ahead of the admin bypass), and
  `AnonymizeUser` and `KilnCMS.Accounts.ErasureBackfill` call it with
  `authorize?: false`, commented as such. It accepts no input, writes no
  role-change event (`RecordRoleChange` is not declared on it) and evicts no
  sessions (the erasure evicts the account's itself). The resource's
  validations are excluded for it (`where: [negate(action_is(:erase))]`), so
  a stored value an earlier release let through cannot fail an erasure, and
  the action runs as one atomic `UPDATE`.
- **What it selects.** `AnonymizeUser.granting/0` is the one expression for
  "still grants something": a tier above `:viewer`, a temporary tier, or any
  audience. Erasure demotes the rows that match it, and the backfill finds
  the same rows with the same expression, so the two cannot drift.
  Idempotent: a demoted row stops matching.
- **No one can give a tier back.** `OrgMembership.:update` and
  `:grant_temporary_role` take the account's row first through
  `Changes.LockAccount`, and refuse an erased one with
  `KilnCMS.Accounts.Errors.AccountErased`. The two approvals also take the
  lock but pass `refuse_erased?: false`, because `DecideRegistration` has an
  error of its own for it (`:erased`: approving an erased applicant is
  refused, there is nobody left to let in). Erasure takes the `users` row
  exclusively before demoting, so a write that locks the account first
  either commits before the erasure and is demoted by it, or waits and sees
  the tombstone (`KilnCMS.Accounts.AccountLock`).
- **The row decides nothing for an erased account anyway.**
  `KilnCMS.Accounts.Scoping` answers no tier and no audiences for an account
  with `anonymized_at` set, on every site, and leaves it off every roster.
  The demotion is for the rows that outlive that rule: a rollback to a
  release without it, a query that reads the table directly, an operator
  reading the row.
- **Accounts erased before the fix.** `ErasureBackfill` runs the same
  `:erase` over every membership of an already-erased account that matches
  `granting/0`, ten minutes after the first boot of the release. Rolling
  back is safe: the earlier release works with demoted rows.
- **The row can still be removed.** An admin's `remove_org_membership` still
  deletes it. This record is about what erasure does, not a ban on deleting.

## Rejected alternatives

**Delete the rows.** This is the obvious tidy answer, and it throws away what
the row records. A rejected registration is a decision with a time, and the
row is the only place it is kept; the site's registrations queue and the
rejected tab read it. The history of who belonged where goes with it. It also
turns erasure into a destructive write across every site, in the
erasure's transaction, where a demotion is one `UPDATE`. And it gains nothing the demotion does not: a row
that grants nothing is as harmless as no row.

**A new `:erased` membership status.** `status` is `one_of: [:active,
:pending, :rejected]`, and it records the registration decision. An `:erased`
value would overwrite the decision it should preserve (an erased applicant
who was rejected is no longer visibly rejected, and an active member who
was erased no longer shows they were active), and every place that reads
`status` (the registrations queue, `DecideRegistration`, `Scoping`'s "not
`:active` is no tier" rule, the console's badges) would need a branch for a
fourth state. The fact that the account was erased is already on the account
(`anonymized_at`), which every one of those places can read. This is a
judgment of cost against benefit, not something the code refutes.

**Reuse `:rejected`.** It already means "no grant, and kept", which looks
like the right answer. But it is the one status a person can undo:
approving accepts a `:rejected` row (`DecideRegistration`: "a rejection can
be reversed"), and an invitation sent after the rejection approves it. An
erased account relabeled `:rejected` would be a row that offers
**Approve** on a tombstone and be indistinguishable from a real rejection
in the queue and in the security log. The `:erased` refusal in
`DecideRegistration` would still stop the approval, but only by
contradicting the status the row was just given. Erasing must not make up a
decision nobody took.

**Clear the restrictions along with the grants.** Emptying `editable_types`,
`readable_types`, `field_grants`, `field_read_grants` or `role_id` looks
like the thorough option. They are restrictions, not grants: an empty value
means no restriction, so clearing them widens the row. A row that is bare
viewer with the scopes it had is narrower than one with the scopes gone, and
the first is what a later reader of the row (a tier change, a restore, a
support look) would not misread. The test that holds this line is "to a bare
viewer row, keeping its restrictions and its status" in
`test/kiln_cms/accounts/erasure_grants_test.exs`, which seeds a custom role
and every scope and asserts each survives. The same comment is on `:erase`
in `OrgMembership`.

## Consequences

- **Anything that adds a grant-bearing column to `org_memberships` adds it
  to `:erase` and to `granting/0` in the same change**, or an erased account
  keeps it. Anything that adds a restriction does not: leave it. Nothing
  enforces this mechanically; the erasure tests seed each existing column.
- A site's member list can contain an erased account as a bare viewer, as it
  could contain any viewer, if a query reads the table without `Scoping`.
  Every roster in the application goes through `Scoping`
  (`is_nil(anonymized_at)`), and a new one must.

## Not verified here

The claim that nothing else reads `org_memberships.role` without going
through `Scoping` is the author's reading of the roster code, not a test.
