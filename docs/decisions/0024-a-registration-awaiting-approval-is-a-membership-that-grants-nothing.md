# 0024. A registration awaiting approval is a membership that grants nothing

- **Status** — accepted (2026-11-09). Part one of three; parts two and three
  extend it.
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

## Not in this part

- Notifying admins of a new registration, and mailing the applicant the
  decision (part two).
- Erasing rejected accounts, queueing a site's own single sign-on, and
  accepting an invitation over a pending row (part three).
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
