# 0024. A registration awaiting approval is a membership that grants nothing

- **Status** — accepted (2026-11-09). Part one of three, extended by part two
  (who is told, below) and part three (invitations, a site's own single
  sign-on, and erasing unconfirmed rejected accounts).
- **References** — [#2251](https://github.com/The-Verscienta/kiln_cms/issues/2251),
  building on #336 (memberships), #419 (per-site tiers) and
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  (per-site settings).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

Open registration lets anyone create an account, and since 1.0 a fresh
self-registered account is a viewer on the default site: it can read members'
pages it pays for, start a checkout, comment where viewers may and call the
APIs as itself. #2251 asks for a site to be able to hold new sign-ups until an
administrator has looked at them, without turning registration off.

The question is where "waiting" lives. Every surface — the console, JSON:API,
GraphQL, MCP, the sockets, media, billing — authorizes through
`KilnCMS.Accounts.Scoping`, which resolves an account's tier, audiences and
scopes from its `OrgMembership` on the request's site. A flag anywhere else
would need a check on each surface, and the one that was forgotten would be
the hole.

## Decision

- **Waiting is a status on the membership.** `OrgMembership.status` is
  `:active`, `:pending` or `:rejected`, `:active` by default and for every row
  that existed before. A self-registration on a site with
  `SiteRegistration.approval_required` on creates the account and a `:pending`
  viewer row on that site in one transaction.
- **`Scoping` grants nothing through a row that is not active.** No tier
  (`:none`), no audiences, a denied type scope, empty field grants; the tier
  rosters and the mention roster leave it out, and the `for_org` read lists
  active rows only. The row still makes the account *affiliated*, so it is
  `:none` on every other site too, the default site included — narrower than a
  membership-less account, which is a viewer there. So every surface refuses
  a pending account through the check it already makes, and none needed its
  own.
- **A pending account may sign in.** It reaches `/account`, which says it is
  waiting, and reads what is public. Refusing sign-in would need its own
  wording at every door and would tell a stranger which addresses are waiting.
- **The site's admins decide, on that site's rows only.** The queue read and
  the two decisions admit an admin of the org the **row** names (the
  argument, for the read), never the request's host, and a standing platform
  admin. A temporary platform admin is refused by `StandingAdminOnly`, as on
  every membership write. The policies name their actions, so the blanket
  membership-write refusal and the self-only read do not reach them.
- **Decisions lock the row.** Approve and reject re-read the row
  `FOR UPDATE` and refuse one that is no longer pending, so two admins (or a
  stale tab) cannot both decide. Approving needs a confirmed address: anyone
  can register an address they do not own. Rejecting does not, so a wave of
  unconfirmed sign-ups can be cleared.
- **Rejected is kept, and can be reversed.** The account and the row stay; the
  row grants nothing and the address cannot register on that site again. An
  admin may still approve a rejected row (same lock, same confirmed-address
  rule), so a mistaken rejection is not final. Erasing a rejected account is
  part three.
- **The setting fails closed.** It is read before the transaction, as a
  system actor admitted to `read` only. A row that cannot be read refuses the
  registration with a retryable error and creates nothing: "no approval
  needed" is the direction that lets an unreviewed account in. The site
  decides; there is no operator default.
- **The applicant's address is shown to that site's admins.** The queue
  carries each applicant's email, name and whether it is confirmed, read as
  the system for the queue's own rows only. It is the first place a site admin
  who is not a platform admin sees an account they do not administer, and only
  someone who asked to join their site.
- **Invitations are never queued.** An invited person was chosen by an admin.
  Adding or inviting an address that has a pending or rejected registration on
  the site is refused, pointing at the queue.

## Who is told (part two)

- **A site's admins hear when someone can be approved.** The update that
  confirms an applicant's address (the confirmation link, a password reset,
  accepting an invitation with a password) announces every site where the
  applicant waits: `Changes.AnnouncePendingRegistration`, declared on every
  `User` update and attached only when the row was unconfirmed, so no action
  can be forgotten from a list. Registering alone tells nobody: an unconfirmed
  applicant cannot be approved yet. Creates are not hooked, since no create
  that confirms leaves a pending row; a later path that queues a confirmed
  account calls `Notifications.Registrations.announce_org/1` after its commit.
- **One notice per admin and site, naming no one.** An in-app
  `:registration_pending` notification whose title is the site's name and
  whose link is `/editor/registrations`, and an email to the same effect. It
  collapses like the document-level events: while it is unread a further
  applicant adds no row and no mail. Opening the queue reads it; it is marked
  before the queue is listed, so an applicant arriving in between leaves a
  fresh notice. Neither the row nor the mail carries the applicant's address
  or name: the queue shows those, to the people it checks.
- **Recipients are standing admins.** A standing platform admin, or a member
  whose active membership on the site is admin, and not an erased account. A
  temporary platform admin is left out: it may not decide registrations.
- **`User.notify_on_registration` mutes the email only.** The bell row is
  always written. The flag is one per account, across every site the account
  administers, so the settings page shows it to anyone who would be told on
  some site (a standing platform admin, or an admin through an active
  membership, including a live grant on it), whichever site it is opened on,
  and the notice email links to it.
- **The applicant hears the decision, by email.** After the commit:
  approving (including reversing a rejection) mails a sign-in link on the
  site's host; rejecting mails one sentence, "Your registration on (site)
  wasn't approved.", with no reason, no link and no name. An unconfirmed
  applicant is not mailed a rejection (the address was never proven theirs),
  and an erased account is mailed nothing. Approving an erased account is
  refused (`:erased`).
- **Best effort.** Notices and mails run after the commit through
  `KilnCMS.AfterCommit`; a failure is logged and never undoes the
  confirmation or the decision.

## Considered and rejected

- **A flag on the user.** One account spans sites; a flag would hold it on
  every site, and every surface would need to read it.
- **A check per surface.** The forgotten one is the hole.
- **Refusing sign-in.** See above.
- **A `nil` role, or reusing `:update`/`:destroy`.** A nil tier is a crash
  waiting in every `case`; the general write is platform-admin only and
  carries the wrong audit event.
- **Approval on by default, or an unreadable setting read as off.** The first
  changes every existing site on upgrade; the second fails open.

## Mode semantics

Approval is per site and applies to self-registration on that site's host —
with one exception, for the **default site**. A membership-less account is a
viewer there, so a registration on site B (approval off) would otherwise be a
default-site viewer that nobody reviewed. When B does not require approval and
the default site does, the pending row is queued on the **default site**: the
account is affiliated and holds nothing anywhere (it already held nothing on
B) until a default-site admin approves it. When B requires approval the row is
on B whatever the default site says; when neither does, nothing is queued and
the account is the legacy viewer it always was. Both settings are read before
the transaction, the default site's only when it can matter, and an unreadable
one that matters refuses the registration.

Otherwise approval does not follow an account between sites: a person
registered on B is not queued on another site A.

**Paying is not a way in.** A paid membership grants through a membership,
and the entitlement recompute gives a paying reader a viewer membership on a
site where it has none. So on a site that requires approval, billing `:start`
is refused for an account that has not been let in there: no active
membership and no tier by any other route (`Scoping.effective_tier/2` is
`:none`). A pending or rejected row is always refused. The setting is read
failing closed. The recompute likewise creates no membership on such a site
for an account with no access there (an entitlement reached another way, such
as an admin's comp); an admin approves or adds the account, and the next
recompute syncs the audiences onto that row.

"Let in" includes the membership-less account that predates approval: it is a
viewer on the default site already, so turning approval on there neither
stops it paying nor stops its entitlement creating the viewer row it always
did. On a site that does not require approval, an account pending elsewhere
may pay there as before, and becomes a viewer member of that site only.

## Part three (c1): invitations and a site's own single sign-on

- **An invitation decides the registration.** Accepting an invitation to a
  site where the address waits, or was rejected, approves that row with the
  invitation's tier (`OrgMembership.:approve_registration_by_invitation`, as
  `SystemActor.new(:invitations)`), recorded as `registration_approved` with
  `via: invitation`. A rejected row is approved only when the invitation was
  sent after the rejection; an older one is refused as no longer valid, so it
  cannot overrule the later decision. A platform admin adding a confirmed
  address on the Team page approves it the same way (`via: added`); an
  unconfirmed address is invited, as before. No decision mail: the person
  accepted, or is told they were added.
- **A site's own single sign-on may queue new accounts.**
  `site_registration.approval_for_site_sso` (off by default, independent of
  `approval_required`) makes an account the site's provider provisions wait
  as a pending row (`method: site_sso`); the admins are told after the
  commit. An unreadable setting refuses the sign-in and creates nothing. An
  existing account is admitted as before.
- **Provenance.** `org_memberships.created_account` records that a queued
  registration created the account (a password sign-up, or a provisioned
  single sign-on account), for the erasure that follows.

## Part three (c2): erasing unconfirmed rejected accounts

- **Unconfirmed only.** `site_registration.rejected_accounts` is `keep` (the
  default) or `erase_unconfirmed`. With the second, rejecting an applicant
  whose address was **never confirmed** erases the account
  (`User.:anonymize`) in the rejection's transaction. A confirmed rejection is
  always kept: it is what stops the same person registering on the site
  again, and erasing it would free the address. Nobody is mailed, since an
  unconfirmed applicant never is.
- **Only an account that is nothing but the application**
  (`Accounts.Registrations.Erasure`): the registration created it
  (`created_account`), it is not erased, its standing role is viewer, it holds
  no live grant and no audiences, it has no other membership of any status,
  and nothing references it — no paid membership, API key, content, version,
  comment, task, media item, release, invitation sent, consent or logged
  event. The tables are a static list; a test classifies every foreign key to
  `users` against it. Anything else, an unreadable setting included, keeps
  the account.
- **Asked for, by a standing admin.** The action erases only with
  `erase: true`, which the console sends only when its confirmation said the
  account would be erased. A temporary admin may reject, and the account is
  kept.
- **A user-row lock, not a check alone.** Under READ COMMITTED the check
  cannot see a membership another transaction is creating. The rejection
  takes the account's `users` row `FOR UPDATE` (only when it will try to
  erase) before it locks the membership; every membership create,
  `Billing.Membership` `:start`/`:comp`, `ApiKey` `:create`, the entitlement
  recompute and the three updates that confirm an account take it
  `FOR KEY SHARE` first (`Accounts.AccountLock`). Whichever locks first goes
  first: an erasure that waited sees what the other committed (a confirmation
  included) and keeps; a writer that waited sees the tombstone and is
  refused. Lock order everywhere: the account, then the membership.
- **The system actor, guarded.** The rejecting admin may be a site admin, who
  may not erase accounts, so the erasure runs as
  `SystemActor.new(:registrations)`, newly admitted to `:anonymize`.
  `Changes.GuardRegistrationErasure` holds that actor to the one erasure: the
  context must name a membership of the account that is `:rejected` with the
  `decided_at` this rejection wrote, and the check must pass under the lock.
- **One transaction.** A failed erasure rolls the rejection back. The event
  is recorded after the erasure: `registration_rejected` with
  `outcome: erased` and no target, or `outcome: kept` naming the applicant.
- **Erasure deletes more** (every erasure, not only these): the account's Web
  Push subscriptions, its private saved views and the notifications
  addressed to it. Shared saved views stay, like authored content.

## Not in this part

- Queueing an existing account the first time a site's own single sign-on
  admits it.
- Recording a membership for every registration whatever the setting, and
  expiring old pending rows (follow-up issues).

## Upgrade notes

- The migration adds `org_memberships.status` (`NOT NULL DEFAULT 'active'`),
  `decided_at` and an index, and the `site_registration` table. Every existing
  row is active.
- A node still on the previous release reads a pending row as an active
  viewer membership, which is about what anonymous gets. Turn approval on
  only once every node runs this release.
- New atoms a rollback must tolerate: the membership statuses `:pending` and
  `:rejected`, and the security event types `registration_queued`,
  `registration_approved` and `registration_rejected`.
- Part two adds `users.notify_on_registration` (`NOT NULL DEFAULT true`) and
  the notification event `registration_pending`. A node on an older release
  cannot load a row with that event, so during a rolling deploy, and after a
  rollback, an affected admin's bell on such a node shows the count but an
  empty list, and "mark all read" fails there. Finish the roll forward, or
  before rolling back run
  `DELETE FROM notifications WHERE event = 'registration_pending'`.
- Part three (c1) adds `org_memberships.created_account` and
  `site_registration.approval_for_site_sso` (both `NOT NULL DEFAULT false`).
  Turn `approval_for_site_sso` on only once every node runs this release: an
  older node provisions single sign-on accounts as active viewers. New values
  an older node may read: the `registration_queued` method `site_sso` and the
  `registration_approved` vias `invitation` and `added`, all strings in event
  metadata.
- Part three (c2) adds `site_registration.rejected_accounts`
  (`NOT NULL DEFAULT 'keep'`). Turn `erase_unconfirmed` on only once every
  node runs this release: an older node neither erases nor takes the account
  lock on its membership and billing writes. New value an older node may
  read: the `registration_rejected` outcome `erased`, a string in event
  metadata.
