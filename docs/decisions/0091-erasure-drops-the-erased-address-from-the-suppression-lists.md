# 0091. Erasure drops the erased address from the suppression lists

- **Status** — accepted (2026-11-26).
- **References** — [#3036](https://github.com/The-Verscienta/kiln_cms/issues/3036)
  (what erasure leaves on the mail suppression lists; the owner chose "drop"
  on the issue, 2026-11-26);
  [#1562](https://github.com/The-Verscienta/kiln_cms/issues/1562) (per-site
  suppression lists);
  [ADR 0076](0076-an-erased-accounts-site-memberships-are-kept-and-demoted-in-place-not-deleted.md)
  (another erasure step that keeps a row on purpose, for contrast).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Fixed ([long form](../changelog/unreleased.md#erasure-drops-suppressions)).

## The problem

When a relay hard-bounces an address, the mail pipeline records it on a
suppression list, and mail that checks the lists is not sent to it again.
There are two lists: `KilnCMS.Mail.SuppressedRecipient`, the instance list,
for rejects from the operator's relay, and
`KilnCMS.Mail.SiteSuppressedRecipient`, one list per site, for rejects from a
site's own relay. Each row holds the address in clear, the bounce reason with
addresses redacted, and when it last failed. Rows have no retention: one stays
until an admin removes it on `/editor/mail` or `/editor/site-mail`.

Erasure (`User.:anonymize`, `KilnCMS.Accounts.Changes.AnonymizeUser`) replaces
the account's address with a tombstone and removes or scrubs everything
linked to the account. The suppression lists are not linked to an account;
they are keyed by address. So after an erasure the person's real address
stayed on those lists, readable by platform and site admins, with no end
date. That contradicts what erasure promises, and the only fix was an admin
who happened to know to look.

Something had to be decided for those rows: keep them, transform them, or
delete them.

## The decision

**Erasure deletes the rows for the erased account's address from the
instance list and from every site's list.**

- **Where.** `KilnCMS.Mail.forget_suppressions/2`, called from
  `AnonymizeUser` right after the mail step that strips the address from
  finished mail jobs, with the address read from the row before the tombstone
  replaces it. It runs in the erasure's transaction for every way an erasure
  happens: a platform admin removing an account, a registration rejected with
  erasure, and the staging scrub's anonymization.
- **Matching.** Both `email` columns are `ci_string`, so the delete matches
  the address whatever its case, the same way a lookup does.
- **Through a destroy of its own.** Each resource has a `:forget_erased`
  destroy that requires the address as its `email` argument and filters on it
  in the action, so a caller whose query forgot its own filter still deletes
  only that address's rows. Its policy is `forbid_if actor_present()` then
  `authorize_if always()`: it runs only with no actor, and every actor is
  refused, the platform admin, the site's admin and `KilnCMS.Mail.system/0`
  included. An admin clears one row with `:destroy`, as before. The existing
  policies were narrowed from `always()` and `action_type([:read, :destroy])`
  to named actions so that `:forget_erased` answers to its own policy alone;
  what they allow is unchanged.
- **Failure rolls the erasure back.** A delete that fails is logged with the
  list it happened in (the instance list or the org id) and the error's
  module, never the address or the error's message, which can quote the
  filter. It is then re-raised, so the whole erasure rolls back and can be
  run again. A half-done erasure that left the address listed would look
  finished.

## Why it is safe to drop them

A suppression row protects the deployment's sending reputation, not the
person: it says that this address bounced, not that its owner asked not to be
contacted. Consent and opt-out live elsewhere (a newsletter row keeps its
unsubscribed status, for example). Once the account is erased nothing of the
account's can be mailed: it is on no roster and gets no workflow, task or
account mail. What is left is mail to the bare address that is not the
account's. If the address is mailed again by anything that checks the lists,
a relay that still rejects it bounces it at most once more, and that bounce
suppresses it again.

## Rejected

- **Keep the rows, and document that erasure does not reach them.** This was
  the behavior until #3036. It leaves the address readable indefinitely by
  every admin of every list it is on, which is exactly what erasure is meant
  to end, and it leaves the cleanup to an admin who has to know to do it.
- **Store a keyed hash (HMAC) instead of the address, for every row.** The
  lists would keep working without holding addresses, but at a cost far out
  of proportion: a schema change that has to go through expand and contract
  across releases; a backfill that has to run in Elixir, because it needs the
  application's key, not in a migration; admin pages that can no longer show
  which address bounced, which is what an admin needs to decide whether to
  clear it; matching that silently stops when `SECRET_KEY_BASE` is rotated;
  and a hash of an email address is still pseudonymous personal data, not
  anonymous data, so erasure would still have to deal with it.
- **Replace the address with a hash only at erasure.** It avoids the
  backfill, but every lookup would have to compute an extra HMAC to match the
  hashed rows, the hash is still pseudonymous data kept about an erased
  person, and a key rotation would silently turn it into the drop chosen
  here, only later and without anyone noticing.

## Consequences

- **At most one more bounce.** If the address is mailed again by anything
  that checks the lists, it is no longer stopped before sending: a relay that
  still rejects it bounces it at most once more, and that bounce puts it back
  on that relay's list. The cost is one rejected message per relay,
  not continued mail to a dead address.
- **Erasures before this release are not reached.** An account erased by an
  earlier release already holds a tombstone, so nothing ties its rows to it
  and there is no backfill. An admin removes such a row by hand on
  `/editor/mail` or the site's `/editor/site-mail`.
- **A rolling deploy.** An erasure that runs on a node still on the previous
  release keeps the rows, as before.
- **The staging scrub** already purges both lists outright, after it has
  anonymized every account. Its anonymization now deletes the rows that
  match an account's address first, so the scrub leaves the same empty lists,
  and its `suppressed_recipients_purged` and
  `site_suppressed_recipients_purged` counts no longer include those rows.

## When to revisit

If a suppression list ever records a person's own request not to be
contacted, a row would then protect the person rather than the sender, and
deleting it on erasure would resume mail they asked to stop. That row would
need to survive erasure in a form that holds no address, and the hashing
options above would have to be weighed again.
