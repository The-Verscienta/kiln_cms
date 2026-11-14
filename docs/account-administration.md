# Account administration

`/editor/accounts` is the instance-wide account register: who has signed up,
what they can do, and how to take it away. Platform-admin only
(`KilnCMS.Accounts.User.role == :admin`), because every resource behind it is
instance-wide rather than per-site.

## Where it sits next to `/editor/team`

The two pages answer adjacent questions and are deliberately separate surfaces,
because they are about different objects:

| | `/editor/team` | `/editor/accounts` |
|---|---|---|
| Lists | `OrgMembership` rows for **this site** | every `User` on the **instance** |
| Answers | who may author what *here* | who has registered at all |
| Sets | site tier, custom role, per-member scope axes | platform role, temporary role, audiences on this site |
| Can do | add an existing account to this site, or [invite an address by email](#invite-someone-to-a-site) | create nothing — accounts arrive by sign-up, SSO, an accepted invitation or the first-run wizard |
| Also | publishing policy for the site | password resets, session revocation, account removal |

Both offer **temporary tiers** — the team page for the site tier, this page for
the platform role. See [Granular RBAC](granular-rbac.md) for how the tier
interacts with the scope axes.

## The register

Search matches email or name; the filters narrow by **Standing role** and by
**Status** (*Email not confirmed*, *Temporary role*, *Erased*). The role filter
is the **standing** role, not the effective one: it is what an admin set, and
hiding someone because they happen to be an admin until Friday would hide them
from the page that ends the grant. So a standing viewer with a live admin grant
is listed under *Viewer*, even though their row's badge reads *Admin*.

Each row leads with **Platform:** and one badge, the platform role that applies
now (see [See which role applies now](#see-which-role-applies-now)). The
account's status (*Email not confirmed*, *erased*) is a separate line of badges
under it, because none of it changes what the role allows.

**Email not confirmed is not a sign-in block.** Password sign-in, magic links
and the instance's own SSO all work for an unconfirmed account. A magic-link
sign-in to one confirms the address and takes the account over, password
included ([Confirming an address](#confirming-an-address)). The one thing that
waits on confirmation is a site's **own** single sign-on: it refuses to sign
its provider's user into an existing account whose address was never
confirmed, because someone else may have registered that address in advance
(`KilnCMS.Accounts.SiteSso.Admission`, rule 4).

## See which role applies now

Every screen that shows a role leads with the tier that applies **now**, as one
badge after a label that says which scope it is:

- **Platform:** is the account's platform role (`User.role`, or a live grant on
  the user). It decides instance-wide administration, such as this page.
- **On this site:** is the tier on one site, decided the same way the
  policies decide it (`Scoping.effective_tier/2`). A platform admin is admin on
  every site whatever their membership holds; otherwise it's the membership's
  tier, or for an account with no memberships at all, its platform role on the
  default site.

When a live temporary grant is behind the badge, a line under it says until
when and what it returns to:

> Admin is temporary: until 2026-11-14 17:00 UTC (7 days left), then Viewer.

When two grants are live and the second outlasts the first (a temporary
platform admin who also holds a temporary site tier), the line names both
steps:

> Admin is temporary: until 2026-11-10 09:00 UTC (3 days left), then Editor until 2026-11-14 17:00 UTC, then Viewer.

No line means nothing is due to change. That includes a temporary platform
admin whose membership on the site is a standing admin: the grant expiring
changes nothing there, so it isn't mentioned. Times are UTC; the count in
brackets reads *under an hour left*, *N hours left* below two days, and
*N days left* after that.

### Check an account's role

You need the platform admin role.

1. Open **Accounts** (`/editor/accounts`). Each row shows **Platform:** and the
   platform role that applies now, with the grant line under it if a temporary
   role is live.
2. Click the account's email (or **Manage**). The header repeats **Platform:**
   and its badge; the status line under it adds *2FA on* and *this is you* where
   they apply, and explains *Email not confirmed* in a sentence.
3. Scroll to **Sites**. Each site the account is a member of shows
   **On this site:** and the tier there. For a platform admin the badge reads
   *Admin* and a note names the tier the membership holds, for example
   "Site tier Viewer, overridden by the platform admin role." A custom role is
   listed under the badge as **Custom role:**.

### Check a team member's role on this site

You need the platform admin role: **Team** is a platform-admin screen, and an
admin of one site is sent to the access-denied page.

1. Open **Team** (`/editor/team`). Each member row shows **On this site:** and
   the tier that applies now, with the grant line when a temporary tier is
   live.
2. A platform admin's row carries the *Site admin* badge and the
   "Site tier …, overridden by the platform admin role." note. Platform admins
   with no membership on the site are listed too, each with
   **On this site:** *Admin*.

### Check your own access

Anyone who can reach the console (editor or admin on the site) can do this.

1. Open **Your settings** (`/editor/settings`).
2. In **Profile**, the **Your access** box shows **On this site:** and your tier
   now, with *platform admin* beside it when that's why. A temporary tier has
   its grant line.
3. If your tier will drop to viewer or no access, which ends your use of the
   console, the box also says "Your access to this console ends at
   2026-11-14 17:00 UTC."

### When the badge looks wrong

- **The badge still shows a tier whose grant has expired.** The page worked it
  out when it loaded. Reload it. The policies stopped honouring the grant the
  moment it expired, whatever the page still says.
- **A standing viewer with an admin grant doesn't appear under the *Admin*
  filter.** The **Standing role** filter matches the stored role, not the
  badge. Use the *Temporary role* status filter to find live grants.
- **The accounts list says *Viewer*, but the person edits a site.** **Platform:**
  is the platform role. Their tier on a site is under **Sites** on the account
  page, or on that site's **Team** page.

### When someone is turned away from a console page

A console page someone lacks the role for sends them to `/access-denied`, a
page answered with `403`, rather than to the home page with a passing message.
It says which role the page needs, what their own role on this site is, and
whom to ask:

- The heading reads "This page needs editor access", "This page needs admin
  access" or "This page needs platform admin access". Platform admin pages are
  the ones backed by the whole installation (Team, Accounts, Billing, Mail,
  API keys, Backups, System): an admin of one site cannot open them either.
- "You are signed in as (role) on (site)." with a line on what that role can
  do. An account with no role on the site (a member of another site, or a
  registration still [waiting for approval](#approving-registrations)) reads
  "You are signed in, but your account has no role on (site)." and is offered
  **Sign out**, to sign in with another account.
- "To get access, ask an admin of (site) to change your role." (or "... to give
  your account a role.", or, for a platform admin page, "ask the person who
  administers this installation.").

To let them in, raise their tier on **Team** or their platform role on
**Accounts** ([See which role applies now](#see-which-role-applies-now)). They
reload the page they wanted; nothing else needs clearing.

`access-denied` is a reserved root slug. A page slugged `access-denied`, or a
path alias under `/access-denied`, made before the upgrade that added this
page is shadowed by it. Operators list such records with
`mix kiln.reserved_paths` (in a release,
`bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`) and give each a new
slug or alias. When a built-in page reserves its address and when it waits
behind your content instead:
[ADR 0059](decisions/0059-a-generated-page-is-served-only-as-the-last-fallback-of-the-404-funnel-not-as-a-route-or-a-reserved-segment.md).

Paging is `limit`/`offset` with one extra row read to decide whether "Next"
exists — the authentication resource's primary read carries no `pagination`, and
an account register is not worth teaching it to count.

## Temporary roles

A grant is "admin until Friday": a higher role that expires on its own.

```elixir
KilnCMS.Accounts.grant_user_temporary_role(
  user,
  %{granted_role: :admin, granted_role_expires_at: ~U[2026-09-19 17:00:00Z]},
  actor: admin
)
```

Two columns carry it, on `User` (the platform role) and `OrgMembership` (the
site tier) alike: `granted_role` and `granted_role_expires_at`. The rules live
in `KilnCMS.Accounts.RoleGrant`.

**The standing role is never overwritten.** The obvious modelling — write the
elevated role into `role`, remember what to put back — makes a background sweep
load-bearing for authorization: miss it and a 48-hour admin is an admin forever.
Here `role` keeps the standing value for the whole life of the grant and
`granted_role` shadows it, so expiry is a *comparison* rather than an event.
Nothing has to run on time.

**How it reaches the policies: at the decision.** A loaded `role` is always the
standing tier — nothing rewrites it on read. Every place that decides what
someone may do asks `RoleGrant.effective_role/1`, which compares
`granted_role_expires_at` with the clock *now*:
`KilnCMS.Accounts.Checks.PlatformAdmin` (on every platform resource, in place of
`actor_attribute_equals(:role, :admin)`), `Scoping.effective_tier/2` (every
org-scoped tier check and the console nav) and
`LiveUserAuth.platform_admin_user?/1`. Rosters ask the same rule in SQL,
`RoleGrant.expression/1`.

Deciding at the decision matters because an actor struct outlives its load: a
LiveView assigns `current_user` once at mount, and the GraphQL socket freezes it
at connect. A grant stops authorizing the second it expires, whether or not
anything re-reads the account.

An earlier version folded a live grant into `role` on every read instead. It
still needed the decision-time check for those long-lived actors, and the fold
made every *write* of `role` hazardous: Ash drops a submitted attribute equal to
`changeset.data`, so promoting a temporary admin from an ordinary read silently
wrote nothing. It also fails in the unsafe direction — code that trusts a folded
`role` keeps honouring an expired grant — where code that reads `role` directly
today merely ignores a live one.

**Reading a tier in new code.** `user.role` is the standing tier. To ask what
someone may do *now*, call `RoleGrant.effective_role(user)` (platform role) or
`Scoping.effective_tier(user, org)` (on a site).

**Showing a tier on a page.** A page that has to *explain* a tier, not only act
on it, uses `KilnCMS.Accounts.Scoping.tier_source/2`. It returns the same tier
with the branch that decided it and the row whose grant columns govern it:

```elixir
Scoping.tier_source(user, org)
#=> {:admin, :platform, %User{}}       # platform admin, standing or granted
#=> {:editor, :member, %OrgMembership{}}
#=> {:viewer, :legacy, %User{}}        # no memberships, on the default org
#=> {:none, :none, nil}
```

`effective_tier/2` is `elem(tier_source(actor, subject), 0)`, so the two can't
disagree. `Scoping.tier_changes/2` lists the changes ahead as live grants
expire, as `[{expires_at, tier_after}]`, and `[]` when nothing is due to
change. The `*_for_membership/3` twins take a membership the page has just
read (`nil` for none on that org), so a re-read after a write shows what the
write left rather than the policy checks' memo. They are for display only; no
policy calls them. `KilnCMSWeb.RoleDisplay` renders all of this (`role_summary/1`,
`role_label/1`, `platform_access/1`, `site_access/2`); use it rather than
re-deriving a tier in a template.

**A grantee cannot grant.** `Validations.StandingAdminOnly` refuses
`:manage_access` and `:grant_temporary_role` on `User`, and every create/update
on `OrgMembership`, from an actor who is an admin only temporarily. Otherwise a
grantee could write `role: :admin` onto their own account or renew their own grant
indefinitely, and the bound would be whatever they chose. Ordinary admin work —
password resets, signing someone out, removing an account — stays available to
them. It is a validation rather than a policy because both resources open with an
admin bypass that would short-circuit a `forbid_if`.

**Only elevations.** A grant must name a higher tier than the row's own. A
temporary *demotion* is a demotion: write it to `role`, where it holds until
someone decides to undo it, rather than expiring quietly back into access nobody
re-approved.

**Setting the window.** Both consoles offer five durations (6 hours through 30
days) plus an explicit "or until" datetime in UTC, which wins when it is filled.
The presets cover what this is usually for ("cover me while I'm on call"); the
field covers what they cannot ("until the contractor's last day"). A past or
unparseable value is refused with a message rather than becoming "no expiry",
which `RoleGrant` would read as no grant at all.

**The hourly sweep** (`AshOban` triggers `expire_role_grants` on both resources)
clears the two dead columns and evicts the holder's live sockets. Enforcement does
not depend on it — see above. Both resources grant
`AshOban.Checks.AshObanInteraction` as an **unconditional** bypass, like
`KilnCMS.Accounts.Token`: the scheduler *reads* the rows before any worker writes,
and a grant scoped to the write action leaves that read filtered to nothing.

## Audiences

The audience checkboxes set what gated content the account can read **on the
site the page is served from**, and they write that site's `OrgMembership` —
the value the read policy consults (see
[Reading gated content](memberships.md#reading-gated-content)). They never
write the global `User.audiences` column, which no access decision reads since
1.0 removed the no-membership fallback. To edit another site's audiences, open the page on
that site's host.

An account with no membership on the site gets one on the first save. Its role
is the tier the account already holds there, so the save changes what it can
read and never what it can author: a membership-less account on the default
site keeps its standing platform role (and a live temporary role, with its
expiry), and anyone else joins as a `:viewer`. The note under the heading says
which case applies before you save. The details, including the one extra write
for a membership-less account edited from another site, are in
[Paid memberships](memberships.md#editing-audiences-from-the-console).

An audience a billing tier has ever claimed is billing's to grant: a tick there
lasts until the next entitlement recompute. Comp a membership instead.

## Invite someone to a site

Bring a person onto one site with the tier they should have there, whether or
not they have an account yet. You need the platform admin role, and it must be
your **standing** role: a temporary admin can open Team but cannot invite or
resend, because an accepted invitation would outlast the grant.

Invitations work on an invite-only site (`:registration_enabled` false) too:
that is what they are for there.

Why an invitation is not an account until it is accepted: [ADR 0050](decisions/0050-a-site-invitation-is-its-own-row-not-an-account-written-up-front.md).

1. Open the console on the host of the site you are inviting them to, then
   **Team** under **Operations** in the sidebar (`/editor/team`). Team acts on
   the site the console is showing.
2. Under **Members**, enter the address in **Email**. Pick a **Site tier**
   (*Viewer* is the default) and, if the site has custom roles, a **Custom
   role**. The note under the fields ends in **Learn more**, which opens this
   section in a new tab.
3. Click **Add or invite**. You see one of these results:
   - "Invitation sent to (address)." The address now appears under **Pending
     invitations (n)** with its tier, its custom role, "Invited by (you)." and
     "Expires (date and time, UTC)". The line under that heading sums up the
     rules in [Resend or revoke an invitation](#resend-or-revoke-an-invitation):
     "Links work for 7 days. Resending mails a new link and restarts the
     clock; the old link stops working. Expired invitations stay listed for
     30 days, and inviting the address again resends it."
   - "Member added to this site." The address already had a confirmed account,
     so it is in the member list now. Its owner is mailed "You were added to
     (site)" with a sign-in link. There is nothing more to do.
   - "Their registration on this site is approved, and they are now a
     member." The address has a confirmed account whose registration was
     [waiting for approval](#approving-registrations) here. Adding it approves
     the registration with the tier you picked, and the owner is mailed as
     for an add.
   - "Their registration on this site had been rejected; it's now approved,
     and they are a member." The same, for a registration an admin had
     rejected: adding the address reverses that rejection
     ([Invitations and registrations](#invitations-and-registrations)).
4. The invitee receives "You've been invited to (site)". The mail names you,
   the site and the tier, and carries an **Accept the invitation** link that
   works once and expires in 7 days.
5. They open the link. The page reads "Join (site)" and "You've been invited to
   (site) as (tier), at (address)." What they do next depends on the address:
   - **No account:** they fill in **Display name (optional)**, **Password** and
     **Password (again)**, and click **Set up my account**. They get a confirmed
     account with the invited tier on this site.
   - **A confirmed account:** they click **Accept invitation**. Nothing else
     about the account changes. If they are already a member of the site at a
     lower tier, accepting raises them to the invited tier
     ([If the invitee is already a member](#if-the-invitee-is-already-a-member)).
   - **An account that was registered but never confirmed:** they see the
     password form, with a note that an unconfirmed account was already started
     with this address. Choosing a password takes the account over: the old
     password stops working, every session the account held is signed out, and
     a display name the first registrant chose is cleared unless they enter one.
     Anyone can register an unconfirmed account for any address, so its old
     password proves nothing about who holds the mailbox. For the same reason
     every other credential on the account goes too
     ([What taking over an account removes](#what-taking-over-an-account-removes)).
6. They are sent to the sign-in page with "Your account is ready — sign in to
   (site)." or "You've joined (site) — sign in to continue." Someone who was
   already a member sees "You're now (tier) on (site) — sign in to continue."
   when the invitation raised them, or "You're already a member of (site) as
   (tier); nothing changed." when it did not ("Your account is ready. You were
   already a member of (site) as (tier), and that is unchanged." if they set a
   password). When taking over an unconfirmed account removed two-step
   verification, a passkey or an API key, the message goes on: "Any two-step
   verification, passkeys or API keys set up on this address before were
   removed; set them up again." They sign in as usual; a second factor still
   applies (a confirmed account keeps its own). On
   **Team** they are in the member list, and their invitation is gone from
   **Pending invitations**.

The link opens on the invited site, whichever host you were on when you sent it.
A viewer's link uses the site's public host. An editor's or admin's link uses
the console host when `KILN_CONSOLE_HOST` is set, and the site's own host if it
is not ([Serving the console from its own host](multi-tenancy.md#serving-the-console-from-its-own-host)).
Opening the link changes nothing until a button is pressed, so a mail scanner
that follows it does no harm.

### What taking over an account removes

Accepting an invitation with a password over an account that was registered
but never confirmed (step 5) treats everything on that account as set up by a
stranger, because it may have been: whoever registered the address first could
sign in with their own password, and an admin may since have raised the
account's role or minted it a key. A password reset finished on such an
account, and a magic-link sign-in to one, do the same
([Confirming an address](#confirming-an-address)). In the same write as the
new password, the takeover:

- turns off **two-step verification**: the authenticator secret, its recovery
  codes, and any enrollment that was started but not confirmed;
- deletes every **passkey**;
- deletes every link to an **identity provider** (single sign-on);
- deletes every **push device**, so review notifications stop going to the
  stranger's browser;
- revokes every **API key** still live, including a draft-write key, which can
  then no longer sign in or rotate itself.

If any of these fails, nothing is accepted: the password, the invitation and
every credential stay as they were, the page shows an error, and the invitee
can submit again.

The invitee signs in with the new password alone. An editor or admin sets up
**Two-factor authentication** and **Passkeys** again under **Settings**
(`/editor/settings`). A viewer cannot reach that page, and sets up an
authenticator app or a passkey on `/account/two-factor` instead, where they
can also remove a passkey later
([Remove a passkey](passkeys.md#remove-a-passkey)). An
admin who minted an API key for the account mints a new one under **API keys**
if it is still wanted; the old key stays listed as revoked.

The security log of the site the page was opened on records *Second factor
removed* and *Passkey removed* (with `via` `invitation`, `password_reset` or
`magic_link`) and *API key revoked*, each with no person
([The security log](security-events.md)). Identity links and push devices are
removed without an entry.

A passkey, push device, two-step verification, new set of recovery codes or
new password the stranger was saving at that moment does not survive either:
it is either saved first and then removed or overwritten with the rest, or
refused once the account has changed hands. The stranger sees the page's
ordinary failure ("Couldn't verify that passkey — try again.", "Couldn't
register this device for notifications.", "That code isn't valid — try
again." for two-step verification and recovery codes, or "Couldn't change
your password. Check your current password and try again."), and their
sessions end as the accept commits.

A **confirmed** account accepting with one click keeps all of it, as does a
confirmed account resetting its password or signing in by magic link.

### Resend or revoke an invitation

Both buttons are on the invitation's row under **Pending invitations**.

- **Resend** mails a new link and restarts the 7 days. The previous link stops
  working. You see "Invitation sent again to (address)." A standing platform
  admin only, as for inviting.
- The **×** button ("Revoke the invitation to (address)") asks "Revoke this
  invitation? Its link will stop working." Confirm, and you see "Invitation
  revoked." The row is gone.

An expired invitation stays listed as *Expired* until it is 30 days past its
expiry, when a daily job deletes it. Entering the same address in **Add or
invite** while it is expired resends it with the tier and custom role you
picked this time.

### If the invitee is already a member

**Add or invite** refuses an address that is already on the site, but a
person can join between the invitation and the accept: through the site's own
single sign-on, or by registering and being approved. Accepting then compares
the invited tier with the one they hold:

- **Lower than the invited tier:** the membership is raised to it. If the
  invitation names a custom role, the membership takes that too; if not, it
  keeps its own. Everything else on the row stays: audiences, content type
  scopes, field grants. The member's sessions are signed out once the accept
  commits, so their next request runs with the new tier. The security log
  records *Role granted*, with the previous role and no person.
- **The invited tier or higher:** nothing changes, and the invitation is used
  up. An invitation never lowers anyone.

The comparison is with the member's **standing** tier. A
[temporary role](#temporary-roles) above it is not counted, because it
expires; if the raise reaches or passes the temporary role, the temporary
role is cleared as no longer needed.

The invitation is the decision you made when you sent it, so a later decision
replaces it. When an admin changes a member's tier or custom role on Team
(**Edit**, then **Save**), or removes them (the trash button, "Remove
(address)"), the invitation still pending for that person's address on that
site is deleted in the same write, expired or not, and drops off **Pending
invitations**. The security log records it as *Invitation revoked*, with you
as the person. Otherwise a member you
had just demoted could use the old link to raise themselves back, and one you
had just removed could rejoin with it. Editing only a member's audiences or
type scopes, or giving them a temporary role, leaves the invitation alone.

### Invite from code

The Team page calls `KilnCMS.Accounts.add_or_invite_member/2`, which adds an
address with a confirmed account and invites any other. From a release shell
(`bin/kiln_cms remote`), as a standing platform admin:

```elixir
alias KilnCMS.Accounts

admin = Accounts.get_user_by_email!("you@example.com", authorize?: false)

Accounts.add_or_invite_member(
  %{organization_id: Accounts.default_org_id(), email: "new.editor@example.com", role: :editor},
  actor: admin
)
#=> {:ok, %{outcome: :invited, invitation: %KilnCMS.Accounts.Invitation{role: :editor, ...}}}
```

`outcome` is `:added` (with `membership:`), `:approved` or
`:approved_over_rejection` (a confirmed account's waiting or rejected
registration on the site approved with the chosen tier, with `membership:`),
`:invited` or `:reinvited` (an expired invitation sent again, with
`invitation:`). A refusal is
`{:error, %Ash.Error.Invalid{}}` carrying a
`KilnCMS.Accounts.Errors.InvitationRefused`;
`InvitationRefused.reason/1` returns `:already_member`, `:already_invited`,
`:suppressed` or `:mail_budget`. Every read and write runs as `actor`, so an
editor, a viewer or no actor gets `Ash.Error.Forbidden` before the address is
looked up. `invite_to_org/2`, `resend_invitation/3`, `revoke_invitation/2` and
`list_invitations_for_org/2` are the single steps. The accept actions are
system-only; only the invitation page calls them.

### When an invitation does not go through

On the Team page:

- **"That person is already on this site."** The address belongs to a member.
  Change their tier from their row instead.
- **"That address is already invited — resend it from Pending invitations."**
  A live invitation exists. Use **Resend**, or revoke it and invite again with a
  different tier.
- **"That address is on the mail suppression list, so the invitation would not
  arrive. Clear it under Mail first."** The address hard-bounced before. Remove
  it from the suppression list on **Mail** (`/editor/mail`, instance-wide) or
  the site's outgoing mail page (`/editor/site-mail`), then invite again.
- **"That address has been sent too many invitations in the last hour. Try
  again later."** Each address has a mail budget (5 invitations per hour by
  default), so the form cannot be used to flood someone's inbox.
- **An error ending "must be a valid email address".** The address has no `@`,
  more than one, a space in the domain, or is over 254 characters.
- **An error saying the tier "can only be granted by a standing admin".** Your
  admin role is temporary. Ask a standing platform admin to send it.

On the invitation page:

- **"This invitation is no longer valid"** with "Ask a site admin to send you a
  new one." The link was made up, has expired, was revoked, was already used,
  or was replaced by a resend. An admin-tier invitation also shows this once
  the admin who sent it is no longer a standing platform admin, and so does
  an invitation to a site where the person's registration was rejected after
  the invitation was last sent
  ([Invitations and registrations](#invitations-and-registrations)). The page
  does not say which, on purpose. Send a new invitation.
- **"An account with this address already exists — accept the invitation with
  it."** An account was created for the address after the page opened, by
  sign-up or single sign-on. Nothing was set; the page now offers the branch
  that fits that account.
- **"Too many attempts from this address — try again shortly."** The same
  per-network budget as registration was spent.
- **"This password has appeared in a known data breach. Choose a different
  one."** The site's [breached-password policy](#breached-passwords) blocks it
  for the invited tier (blocking applies to administrators).
- **"You're already a member of (site) as (tier); nothing changed."** The
  invitee already held the invited tier or a higher one on the site, so the
  invitation was used up without changing anything
  ([If the invitee is already a member](#if-the-invitee-is-already-a-member)).
  To change their tier, edit their row on Team.

Accepting *through* single sign-on is not supported: the invitee accepts with a
password or with an account they already have.

## What happens when someone registers

Registering creates an account but does not sign anyone in. The answer is the
same for every address, so the sign-up page can't be used to find out who has
an account here.

1. On `/register`, the person enters their email address and a password twice,
   and submits the form.
2. Whatever address they used, they are sent to `/sign-in` with "Check your
   email - we have sent instructions for what to do next."
3. **A new address** gets its account and a confirmation email. The person
   signs in at `/sign-in` with their password (confirming first is not
   required to sign in), or waits for approval on a site that
   [holds sign-ups](#approving-registrations).
4. **An address that already has an account** gets no new account and no
   change to the existing one. Its owner is emailed "Someone tried to create a
   (site) account with your address", with links to sign in or reset their
   password.

A mistake in the form itself, such as a password shorter than 8 characters or
two passwords that don't match, is still shown on the page, the same way for
every address. If [human verification](human-verification.md) is on, the form
may ask for a check first.

## Approving registrations

While open registration is on (`:registration_enabled`, the default), anyone
can create an account with a password at `/register`. A site can make those
sign-ups wait for an administrator: the account is still created, but it gets
no access on the site until an admin approves it on the **Registrations** page.
Rejecting keeps the account and keeps it out, unless the site
[erases unconfirmed applicants it rejects](#erase-unconfirmed-applicants-you-reject).

The site's admins are told when someone who has confirmed their address is
waiting ([Get told when someone is waiting](#get-told-when-someone-is-waiting)),
and the applicant is emailed your decision
([What the applicant is told](#what-the-applicant-is-told)).

The reasoning is in
[ADR 0024](decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md).

### Turn approval on

You need the admin tier on the site: a site admin, or a platform admin.

1. Open the console on the site's host, then **Registrations** under
   **Sign-in & access** in the sidebar (`/editor/registrations`).
2. Scroll to **Settings** at the foot of the page and tick
   **New registrations wait for an administrator's approval**.
3. Click **Save**. You see "Registration settings saved."

The next password sign-up on this site waits for approval. Approval is off by
default, set per site, and has no environment variable. Saving the setting is
recorded in the [security log](security-events.md) as *Site setting changed*
(`setting` `site_registration`).

This setting holds password sign-ups at `/register` on this site's host.
New accounts from the site's own single sign-on have a switch of their own
([below](#hold-new-single-sign-on-accounts-too)). These are never queued:

- an accepted [invitation](#invite-someone-to-a-site), which an admin chose
  (accepting one approves a waiting registration instead:
  [Invitations and registrations](#invitations-and-registrations));
- a sign-in through the deployment's single sign-on (`OIDC_*`);
- an account that already exists, and the first admin created in `/setup`.

Turning approval off again approves nobody: everyone already waiting keeps
waiting until an admin decides. If the deployment has switched open
registration off, the page says "Open registration is switched off for this
deployment, so nobody can sign up and this setting has no effect. People join
through invitations."

### Hold new single sign-on accounts too

If the site has its own single sign-on provider
([Per-site providers](sso.md#per-site-providers)), the first sign-in through
it creates an account and, by default, makes it a *Viewer* on the site
straight away. A second switch makes those new accounts wait for approval
like a password sign-up. It is independent of the first: either can be on
without the other.

You need the admin tier on the site: a site admin, or a platform admin.

1. Open **Registrations** (`/editor/registrations`).
2. Under **Settings**, tick **New accounts from this site's single sign-on
   wait for approval too**.
3. Click **Save**. You see "Registration settings saved."

The next person who signs in through the site's provider for the first time
gets an account and a session, but no access on any site, and appears under
**Waiting for approval** on **Registrations**. The provider has already
verified their address, so they are approvable at once, and the site's
admins are told straight away
([Get told when someone is waiting](#get-told-when-someone-is-waiting)).
Approve or reject them as for any other registration. The security log
records *Registration awaiting approval* with `method` `site_sso`.

- **Only new accounts.** Someone who already has an account signs in through
  the provider as before, whatever this switch says.
- **Someone still waiting** who signs in through the provider again is
  signed in and is still waiting.
- **Open registration off** (`:registration_enabled` false): the provider
  creates no accounts, so this switch has nothing to act on.
- **The setting can't be read**: a first sign-in through the provider is
  refused with "Single sign-on isn't available on this site right now. Sign
  in another way." and no account is created. Sign-ins of existing accounts
  don't read the setting and are unaffected.

Operators: turn this on only once every node runs the release that has it.
An older node ignores the switch and makes new single sign-on accounts
*Viewers* straight away.

### What an applicant can do while they wait

The sign-up page looks and works as it always has, and does not say the
account is waiting. While their registration waits:

- **They can sign in.** **Your account** (`/account`) says "Waiting for
  approval on (site). You can sign in, but you can only read what's public
  here until an administrator approves your registration."
- **An applicant who hasn't confirmed their address is told to do that
  first.** An administrator can't approve them until they do
  ([Unconfirmed addresses cannot be approved](#unconfirmed-addresses-cannot-be-approved)),
  so under the waiting line **Your account** adds "Confirm your email address
  first: an administrator can't approve your registration until you do.",
  then a **Reset your password to confirm it.** link to the reset request page
  (`/reset`) and "Or use the link in the confirmation email we sent, if it's
  still valid." A password reset always works: every unconfirmed account
  signed up with a password, and finishing the reset confirms the address.
  The confirmation link lasts 3 days and can't be sent again, and asks for the
  password they signed up with. Signing in with a magic link confirms the
  address too, but replaces their password
  ([Confirming an address](#confirming-an-address)).
- **They read only what an anonymous visitor reads**, on every surface: pages,
  JSON:API, GraphQL, MCP and media. No members-only content and no drafts,
  whatever audiences the waiting row holds.
- **They have no access on any other site either**, the default site
  included. An account that registered on site A and waits there is not a
  viewer anywhere.
- **The console turns them away**, as it does any reader.
  `POST /api/auth/sign_in` succeeds and reports `"role": "none"`.
- **They cannot comment** where viewers may.
- **They cannot buy a paid membership on this site.** Checkout sends them back
  to `/account` with "Your registration on this site hasn't been approved, so
  you can't join yet." On a site that requires approval this applies to any
  account not let in there yet, not only applicants: paying is not a way past
  the queue ([Paying is not a way in](#paying-is-not-a-way-in)).
- **They are on no roster**: not in Team's member list, not offered as a
  mention, not counted in "who has this tier".

On `/editor/accounts/(id)`, their entry under **Sites** reads
**On this site:** *Pending approval* (or *Rejected*) rather than a tier.

### Approve or reject someone

You need the admin tier on the site whose registrations these are. An admin
of another site is refused, whichever host they ask from.

1. Open **Registrations** (`/editor/registrations`). The **Waiting** tab lists
   people who signed up here, oldest first, under
   **Waiting for approval (n)**: the address, the name if they gave one, and
   "Registered (date and time) UTC". With nobody waiting, you see "Nobody is
   waiting."
   Opening the page marks your registration notice for this site read.
2. To let someone in, click **Approve** on their row. You see "Approved
   (address). They can now read this site as a viewer. We'll email them."
   They leave the list, appear in Team's member list as a *Viewer* with no
   audiences, and any page they have open reconnects with the new access.
   They are emailed a sign-in link. Change their tier, custom role or
   audiences afterwards as for any member.
3. To turn someone away, click **Reject** and confirm "Reject (address)? The
   account is kept but gets no access to this site, and they can't register
   here again with this address. They'll be emailed that it wasn't
   approved." (For an applicant who hasn't confirmed their address, or whose
   account was erased, the last sentence is missing, because they get no
   email.) You see "Rejected (address)." and they move to the **Rejected**
   tab. If the site erases unconfirmed applicants it rejects, the dialog for
   an unconfirmed row says so instead
   ([Erase unconfirmed applicants you reject](#erase-unconfirmed-applicants-you-reject)).

A rejected account can still sign in, reads only what's public on every site,
and its account page says "Your registration on (site) wasn't approved." To
remove the account itself, a platform admin uses
[Removing an account](#removing-an-account), or the site
[erases unconfirmed applicants it rejects](#erase-unconfirmed-applicants-you-reject).

Approving gives exactly the *Viewer* tier on this site and nothing on other
sites. Without approval, a password sign-up is a viewer on the **default
site** only, whichever host it signed up on.

**Erased applicants.** If a platform admin erased an applicant's account
while it waited, its row shows an **Account erased** badge and has no
**Approve**: there is nobody left to let in. Reject it to clear it; no email
is sent.

### Erase unconfirmed applicants you reject

By default a rejected account is kept. On a site that gets waves of bot
sign-ups, that leaves a pile of accounts nobody ever proved they owned. A third
setting erases the account when you reject someone whose address was never
confirmed.

You need the admin tier on the site: a site admin, or a platform admin.

1. Open **Registrations** (`/editor/registrations`).
2. Under **Settings**, set **When you reject someone** to **Erase the account
   if the email address was never confirmed**. (The default is **Keep the
   account**.)
3. Click **Save**. You see "Registration settings saved."
4. Under **Email not confirmed yet**, click **Reject** on a row. The
   confirmation now reads "Reject (address) and erase the account? This
   address was never confirmed, so the account is erased, unless it's used for
   anything besides this registration. Erasing can't be undone, and the
   address can register again."
5. Confirm. You see one of:
   - "Rejected (address) and erased the account." The row moves to the
     **Rejected** tab with an **Account erased** badge.
   - "Rejected (address). The account was kept, because it's more than this
     registration or it can't be erased right now." The rejection stands and
     the account is kept, as with **Keep the account**.

No email goes out either way: an applicant who never confirmed their address
is never mailed. Rows under **Waiting for approval** have confirmed their
address, so their **Reject** dialog is the usual one and the account is kept.

**When an account is erased.** All of these must hold, checked when you
confirm; if any fails, the account is kept:

- the site's setting is **Erase the account if the email address was never
  confirmed**, and the dialog you confirmed said the account would be erased;
- you are a **standing** admin of the site, or a standing platform admin. A
  temporary admin sees the ordinary dialog and can reject, but the account is
  kept: an erasure would outlast the grant that allowed it;
- the address was never confirmed;
- this registration created the account (a password sign-up, or a new account
  from the site's own single sign-on), so it is not someone's existing account
  that applied;
- the account is nothing but this application: its account-wide role is
  *Viewer*, it holds no temporary role and no audiences, it has no other
  membership on any site (waiting, rejected or active), and nothing points
  at it: no paid membership, API key (revoked ones included), newsletter
  subscription, content, version, comment, task, media item, release,
  invitation it sent, recorded consent, logged editing event, or
  notification it caused in someone else's inbox.

Erasing is the same [anonymization](#removing-an-account) a platform admin
runs, done in the rejection's own transaction: if the erasure fails, the
rejection is undone too, the row stays waiting, and you see an error. The security log records
*Registration rejected* with `outcome` `erased` and no target, or `outcome`
`kept` naming the applicant.

**Keeping is what makes a rejection stick.** A kept account still holds the
address, so the same address can't register on this site again. An erased
account frees it: whoever owns it can sign up again and wait in the queue
like anyone new. That is why a confirmed rejection is always kept, whatever
the setting: someone who proved the address is theirs and was turned away
should not be able to come straight back. An unconfirmed sign-up proves
nothing, so erasing it loses little, and clearing it means the address's real
owner is not locked out by a stranger's sign-up.

**If a confirmation races your click.** If the applicant confirms their
address, starts a paid membership, or is given a membership on another site
at the moment you reject, one of the two waits for the other. Either the
erasure goes first and the other write is refused, or the other write goes
first and the account is kept.

Operators: turn this on only once every node runs the release that has it.
An older node doesn't take the account lock that keeps those writes from
racing an erasure.

### Get told when someone is waiting

You hear about a registration once the applicant has confirmed their address,
because that is when it can be approved. Registering alone tells nobody.

1. The applicant confirms their address: by the confirmation link, by
   resetting their password, or by accepting an invitation with a password.
   A magic-link sign-in does not confirm an address, so it does not count.
   A new account from the site's own single sign-on arrives confirmed, so on
   a site that [holds those](#hold-new-single-sign-on-accounts-too) the
   admins are told as soon as it is created.
2. Every site where they are waiting tells its admins. (Accepting an
   invitation approves the registration on the invitation's own site, so
   that site has nothing to be told.) Each admin gets a
   notice in the bell (and at `/editor/inbox`), "Registrations waiting for
   approval", titled with the site's name. Clicking it opens
   **Registrations**.
3. Each admin who gets a new notice is also emailed "Registrations are
   waiting for approval on (site)", with a **Review registrations** link to
   the queue on the site's own host and a link to switch these emails off.
4. Open **Registrations**. Your notice for this site is marked read.

**One notice per site, not per applicant.** While your notice is unread,
more applicants on that site add no notice and no email: a wave of fifty
sign-ups is one notice and one email. Once you have opened the queue, the
next applicant is news again and you get a fresh notice and email. Each
admin's notice is their own, so opening the queue reads only yours.

**No names.** Neither the notice nor the email names the applicant or gives
their address. The queue shows those, to the people allowed to see them.

**Who is told.** A standing platform admin, and anyone whose active
membership on the site is admin, including a temporary admin grant on that
membership. A temporary *platform* admin is not told, because it can't decide
registrations, and nor is an erased account.

**Turn the email off.** Open **Your settings** (`/editor/settings`), and under
**Email notifications** untick **New registrations — email me when someone is
waiting for approval on a site I administer**, then click
**Save preferences**. This mutes the email only: the bell notice still
appears, so you still see the queue is waiting next time you open the
console. The switch is one for your whole account, across every site you
administer, and it shows only if you would be told on at least one site (a
temporary platform admin grant does not count).

### What the applicant is told

The applicant is emailed after your decision is saved, through the site's
own mail relay if it has one:

- **Approved**: "Your registration on (site) was approved", with a
  **Sign in** link on the site's host. Also sent when you approve someone
  from the **Rejected** tab.
- **Rejected**: subject "About your registration on (site)", body "Your
  registration on (site) wasn't approved." There is no reason, no link and
  no name of who decided, and there is no way to add one.

No email goes to a rejected applicant who never confirmed their address,
since the address may belong to someone else, or to an erased account.

If the email can't be queued, the decision still stands; the failure is
logged. `/account` also shows the outcome on the applicant's next visit.

### Unconfirmed addresses cannot be approved

Below the waiting list, **Email not confirmed yet (n)** lists people who
haven't confirmed their address. Each row has **Reject** and no **Approve**:
"These can't be approved until they confirm their address, since anyone can
sign up with an address they don't own. You can reject them now."

Approving an address nobody has proved they own would give the site to
whoever typed it. Once the person confirms, they move up to
**Waiting for approval** the next time the page loads. The applicant's own
**Your account** page tells them how: reset their password, or follow the
confirmation link while it is still valid
([What an applicant can do while they wait](#what-an-applicant-can-do-while-they-wait)).
The two lists are paged
separately, so a wave of unconfirmed sign-ups never pushes the people you can
approve off the first page. Rejecting does not wait
for confirmation, so a wave of bot sign-ups can be cleared straight away.

### Undo a rejection

A rejection is not final.

1. On **Registrations**, click the **Rejected** tab
   (`/editor/registrations?status=rejected`). Each row adds
   "Rejected (date and time) UTC".
2. Click **Approve** on the row. It is offered only for a confirmed address
   whose account hasn't been erased. You see "Approved (address). They can now
   read this site as a viewer. We'll email them." The approval email goes out
   as for any other approval.

A rejected registration cannot be put back to waiting or rejected again; the
**Rejected** tab only offers **Approve**.

### Long queues

**Waiting for approval**, **Email not confirmed yet** and **Rejected** each
show 50 registrations at a time, oldest first, with their own **Load more**
for the next 50. The counts in the two waiting headings are the whole queue,
up to 100: from there they read "100+". Approving or rejecting removes only
that row, so the rest of what you have loaded stays where it was.

**Team** (`/editor/team`, platform admins) shows a link above the member list
while anyone is waiting: "1 registration is waiting for approval",
"(n) registrations are waiting for approval", or "100 or more registrations
are waiting for approval" once it reaches 100 (it stops counting there).

### Invitations and registrations

An invitation is never queued. Accepting one gives the invited tier on the
site, even on a site that requires approval. An invitation is an admin's
decision to let the person in, so it also decides a registration the person
has on the same site:

- **Accepting an invitation over a waiting registration approves it** with
  the invited tier and custom role, whether the invitee accepts with one
  click (a confirmed account) or by choosing a password (an unconfirmed one,
  which accepting confirms). The row leaves **Waiting for approval**, and the
  invitee gets no decision email: they just accepted.
- **Accepting over a rejected registration approves it only if the
  invitation is newer than the rejection**: sent, or last resent, after the
  registration was rejected. An older invitation was sent before an admin
  turned the person away, so it does not overrule that. The invitation page
  then says "This invitation is no longer valid", the registration stays
  rejected, and nothing about the account changes. To let them in after all,
  **Resend** the invitation (a resend counts as newer) or approve them from
  the **Rejected** tab.
- **Add or invite** on Team, for an address with a confirmed account and a
  registration here, approves the registration at once with the tier you
  picked. A rejected one is approved too, whenever it was rejected, because
  adding is a decision you make now; the message says the rejection was
  overridden. An address whose account is unconfirmed is invited instead,
  and accepting decides the registration as above. An erased account's
  address no longer matches it, so it is simply invited.

Each of these records *Registration approved* in the security log, with
`via` `invitation` (an accepted invitation; no person, since the system
honours it) or `added` (Add or invite; the person is the platform admin).
Neither writes a separate *Role granted*.

### Sign-ups on another site's host

Every site's setting applies to sign-ups on its own host, with one exception
for the **default site**. An account with no membership anywhere is a viewer on
the default site. So a sign-up on site B, where approval is off, would
otherwise be a default-site viewer that no one reviewed:

| Site signed up on requires approval | Default site requires approval | The registration |
|---|---|---|
| yes | either | waits on the site signed up on |
| no (a site other than the default) | yes | waits on the **default site**, in its admins' queue |
| no | no | is not queued: a viewer on the default site, as before |

While it waits on the default site, the account has no access on site B either
(it never had any there). `/account` lists every site where the account waits
or was rejected, on any host, so the applicant sees "Waiting for approval on
(default site name)" on B's host too.

### Paying is not a way in

A paid membership grants its audiences through a membership on the site, and
buying one used to create a *Viewer* membership on a site where the buyer had
none. On a site that requires approval that would let anyone pay past the
queue, so there:

- checkout is refused for an account that has not been let in: one with a
  waiting or rejected registration here, or with no access here at all. It
  sees "Your registration on this site hasn't been approved, so you can't join
  yet.";
- "let in" means any access on the site: a membership an admin approved or
  made, or, on the default site, the membership-less viewer every account was
  before approval existed. Turning approval on does not stop existing readers
  paying;
- a paid membership reached another way (an admin's comp, one that predates
  the setting) creates no membership for such an account. Once an admin
  approves or adds it, the next billing update puts its audiences on that
  membership.

On a site that does not require approval, nothing changes: an account waiting
on another site can pay here, and becomes a viewer member of this site only.

### When the setting cannot be read

If the site's setting (or the default site's, when it applies) cannot be read
from the database, the sign-up is refused rather than let in unreviewed, even
on a site with approval off, since it can't be known to be off. The person sees
"registration is unavailable for a moment — try again shortly" on the form, and
nothing is created, so trying again is safe.

### Errors you can hit

On **Registrations**:

- **"That registration has already been decided."** Another admin, or another
  tab of yours, decided it first. The list reloads with the current state.
- **"That person hasn't confirmed their email address yet, so it can't be
  approved."** The address was unconfirmed when you clicked. Reject it, or
  wait for them to confirm.
- **"That account was erased, so it can't be approved."** The account was
  erased after the page loaded. Reject it to clear it.
- **"You don't have permission to decide registrations on this site."** You
  are not an admin of this site, for example because your tier was lowered
  since the page loaded.
- **An error saying the tier "can only be granted by a standing admin".** Your
  platform admin role is temporary. You can see the queue but not decide it.
  Ask a standing platform admin or a site admin.
- **"You don't have permission to change this site's registration."** On
  **Save**: you are not an admin of this site.

On the public site, the applicant can hit "registration is unavailable for a
moment — try again shortly" (above), and at checkout "Your registration on
this site hasn't been approved, so you can't join yet." A first sign-in
through the site's own single sign-on can hit "Single sign-on isn't available
on this site right now. Sign in another way." when the setting can't be read
([Hold new single sign-on accounts too](#hold-new-single-sign-on-accounts-too)).

### Decide registrations from code

The page calls the `OrgMembership` actions through the `Accounts` code
interface, as the signed-in admin, so the same policies apply from a release
shell (`bin/kiln_cms remote`):

```elixir
alias KilnCMS.Accounts
alias KilnCMS.Accounts.Registrations

admin = Accounts.get_user_by_email!("you@example.com", authorize?: false)
site = Accounts.default_org_id()

# Turn approval on for the site.
{:ok, _row} = KilnCMS.CMS.save_site_registration(%{approval_required: true}, actor: admin, tenant: site)

# The first page of the queue: 50 rows, oldest first.
{:ok, %{entries: entries, more?: more?}} = Registrations.page(site, actor: admin)
#=> entries: [%{membership: %OrgMembership{status: :pending}, email: "new@example.com",
#              name: nil, confirmed?: true, erased?: false, registered_at: ~U[...]}, ...]

[entry | _] = entries
Accounts.approve_registration(entry.membership, %{}, actor: admin)
#=> {:ok, %KilnCMS.Accounts.OrgMembership{status: :active, role: :viewer, decided_at: ~U[...]}}
```

- `Registrations.page/2` takes `:status` (`:pending`, the default, or
  `:rejected`), `:confirmed` (`true` or `false` for only confirmed or only
  unconfirmed applicants; both when omitted), `:limit` (default 50) and
  `:after` (the last entry of the previous page). `Registrations.queue/2` returns the first page as a list,
  and `Registrations.pending_count/2` counts waiting rows up to 100 (it takes `:confirmed` too). A caller
  who is not an admin of the site gets `{:error, %Ash.Error.Forbidden{}}`
  from `page/2`, never an empty queue.
- `Accounts.reject_registration/3` takes the same arguments as
  `approve_registration/3`, plus `erase` (boolean, default `false`): ask to
  erase the account too
  ([Erase unconfirmed applicants you reject](#erase-unconfirmed-applicants-you-reject)).
  It is only a request; the site's setting, a standing admin actor and
  `KilnCMS.Accounts.Registrations.Erasure.check/1` decide. The returned
  membership says what happened in its metadata:

  ```elixir
  {:ok, row} = Accounts.reject_registration(entry.membership, %{erase: true}, actor: admin)
  row.status                              #=> :rejected
  row.__metadata__[:registration_outcome] #=> :erased (or :kept)
  ```

  A failed erasure returns its error and nothing is rejected.
- A refused decision is `{:error, %Ash.Error.Invalid{}}` carrying a
  `KilnCMS.Accounts.Errors.RegistrationRefused`. `RegistrationRefused.reason/1`
  returns `:not_pending` (already decided), `:unconfirmed` or `:erased`
  (approving an erased account), and `:rejected_after_invitation` from
  `approve_registration_by_invitation` (below). The same error
  carries `:settings_unavailable` on a refused sign-up and `:not_approved` on
  a refused paid-membership start.
- `save_site_registration/2` also takes `approval_for_site_sso`, the
  [single sign-on switch](#hold-new-single-sign-on-accounts-too), and
  `rejected_accounts` (`:keep`, the default, or `:erase_unconfirmed`).
  `KilnCMS.Accounts.RegistrationPolicy.settings/1` reads all three as
  the system, `{:ok, %{approval_required: boolean, approval_for_site_sso:
  boolean, rejected_accounts: :keep | :erase_unconfirmed}}` (`false`, `false`
  and `:keep` for a site with no row) or `{:error, :unavailable}`. Rejecting
  reads it too, and there an unreadable row means keep.
- A write that would attach something to an erased account (a membership, a
  paid membership `:start` or `:comp`, an API key, or one of the three
  updates that confirm an account) is refused with
  `KilnCMS.Accounts.Errors.AccountErased`, "belongs to an account that was
  erased". Each takes the account's row first
  (`KilnCMS.Accounts.AccountLock`), so it can't land on an account erased
  while it waited.
- `Accounts.queue_registration/2` is system-only: it is the sign-up's own
  write, and every person, a platform admin included, is refused it. Its
  `method` argument (`:password`, the default, or `:site_sso`) is recorded on
  the `registration_queued` event, and `new_account?` (default `false`) is
  stored on the row as `created_account`: whether this registration created
  the account. Rows written before the column existed read `false`.
- `Accounts.approve_registration_by_invitation/3` is how an invitation
  decides a registration ([Invitations and registrations](#invitations-and-registrations)).
  It takes `role` (default `:viewer`), `role_id` (a custom role of the row's
  own site), `invited_at` (required) and `via` (`:invitation`, the default,
  or `:added`). It refuses as `approve_registration` does, and refuses a
  rejected row whose `decided_at` is not earlier than `invited_at`. It admits
  the `:invitations` system actor (an accepted invitation) and a standing
  platform admin (Add or invite), nobody else. It sends no decision email.
- A decision from code mails the applicant exactly as the page does
  ([What the applicant is told](#what-the-applicant-is-told)), after the
  commit.
- The admin notice is written by `KilnCMS.Notifications.Registrations`, when
  any `User` update confirms an account that was unconfirmed. Code that queues
  an account that is already confirmed tells the site's admins itself with
  `KilnCMS.Notifications.Registrations.announce_org(org_id)` after its
  commit. `recipients/1` returns who that notifies. The notice is the
  `:registration_pending` notification event, with `content_type`
  `"registration_queue"` and `content_id` the site's id.

## Confirming an address

Anyone can register an account for any address, and the account stays
unconfirmed until someone proves they read that address's mail. Each way of
proving it treats the account differently, because each proves something
different (#2594):

- **The confirmation link** asks for the password chosen at sign-up as well:
  "Confirm your email address. Enter the password you chose when you signed
  up." Whoever both reads the mail and chose the password is the account's own
  registrant, so confirming keeps everything on the account: its password, its
  two-step verification, passkeys and API keys. A wrong password returns to the
  same page with "That isn't the password this account was signed up with. Try
  again, or reset the password instead.", and the link still works. Under the
  form, "Didn't sign up, or don't remember the password? Reset the password
  instead." links to the reset page.
- **A password reset** finished on an unconfirmed account confirms it and takes
  it over: the new password replaces the old one, every session is signed out,
  and every other credential on the account is removed
  ([What taking over an account removes](#what-taking-over-an-account-removes)).
  A reset on a **confirmed** account changes the password and signs out every
  session, and keeps two-step verification, passkeys and API keys, so a reset
  is never a way around a second factor.
- **A magic-link sign-in** to an unconfirmed account confirms it and takes it
  over the same way, and replaces the password with a random one nobody knows.
  The link proves the mailbox, not the password, so the password goes with
  everything else. The display name is cleared too. To sign in with a password
  afterwards, the owner resets it. A genuine registrant who signs in by magic
  link before confirming therefore loses the password they chose; the
  confirmation link is the way to confirm and keep it. A magic link to a
  **confirmed** account signs in and changes nothing.
- **Accepting an invitation** with a password over an unconfirmed account
  takes it over as well ([Invite someone to a site](#invite-someone-to-a-site)).

Every takeover is recorded in the security log, with `via` saying which of
these it was ([The security log](security-events.md)).

## Password resets

`KilnCMS.Accounts.send_user_password_reset/2` mails a reset link to a named
account and reports whether it went. The anonymous form
(`:request_password_reset_token`) cannot: it is built to be indistinguishable —
it takes an address rather than an account, answers `:ok` whether or not that
address exists, and its sender drops the mail silently when the per-address
budget is spent. All correct for a public endpoint that must not become an
account oracle, all wrong for a button in the console.

The admin path **still charges the per-address mail budget** — once, before a
token is minted — and a spent budget is refused *by name* ("too many reset links
in the last hour") instead of being dropped silently. The budget bounds mail to an
address whoever asks, a temporary admin included, and it is shared with the
owner's own requests rather than being a second, independent allowance. "Sent"
means the mail reached the queue; an enqueue failure is reported, not crashed on.
Erased accounts are refused: their password hash has no matching plaintext and
their address is a `@deleted.invalid` tombstone.

## Lift a sign-in pause by email

After 20 password attempts on one email address in 15 minutes, Kiln pauses
password sign-in for that address until the window ends. Anyone can cause
the pause by typing someone's address, so the person who is paused is often
the owner, after mistyping a password. They can wait, reset their password
(which lifts the pause too), or have a link emailed that lifts only the pause.
No admin is involved and there is nothing to turn on.

Anyone can follow these steps; they need access to the account's mailbox.

1. On the sign-in page (`/sign-in`), under the sign-in options, click **Email
   me an unlock link** (after "Paused after too many attempts?"). The page
   **Lift a sign-in pause** opens (`/sign-in/unlock`).
2. Enter the address you sign in with in **Email** and click **Email me an
   unlock link**. The page reads: "If an account with that address is paused
   after too many sign-in attempts, we've emailed it a link to lift the pause.
   The link works once, within 15 minutes."
3. Open the mail **Lift the sign-in pause on your (site) account** and click
   **Lift the pause**. The page **Lift the sign-in pause** opens, with a
   **Lift the pause** button. Opening the link has not used it yet.
4. Click **Lift the pause**. You are back on the sign-in page with: "The
   sign-in pause on your account is lifted. You may be asked to complete a
   check, or to wait a minute if your network is busy."
5. Sign in as usual, with your password and, if you have one, your second
   factor.

The "Unusual sign-in activity on your (site) account" mail that Kiln sends
the owner when the pause starts also links to the page in step 1. It never
carries an unlock link itself: that mail goes out on a pause anyone can
cause, so it would be a link minted whenever an attacker liked.

### Why the sign-in page never says an account is paused

A paused account answers exactly as a wrong password does: "Email or password
was incorrect". The unlock link on the sign-in page is shown to everyone,
paused or not, and the request page answers every address with the same
sentence. If any of these changed when an account was paused, a stranger could
type an address and learn that it has an account, and that someone is
guessing at it. The account owner is told by mail instead.

### It adds no new trust

The link goes only to the account's own address. Whoever can read that mailbox
can already ask for a password reset, which lifts the pause and changes the
password as well. The unlock link does less: it clears the pause and nothing
else. It does not sign anyone in.

### What it lifts and what it does not

It clears the account's sign-in counter, so the account gets its 20 attempts
back. It does not clear:

- the per-network limits: the sign-in pages allow 40 requests a minute from
  one IP address, and the human-verification check counts failed sign-ins per
  IP address too;
- the [human-verification](human-verification.md) budget: the free attempts
  before a check are not given back, so if the operator turned the check on,
  the next sign-in is likely to ask for one;
- the two-factor code budget (5 codes in 15 minutes). If the person also ran
  that out, their code is still refused until its window ends, or until they
  reset their password.

### Who gets a link

A link is mailed only when all of these are true:

- the address belongs to a confirmed account that has not been erased, and
  is not the demo's shared account;
- sign-in for that account is paused right now;
- the account is a member of the site the request was made on (or is a
  legacy account with no membership, on the default site). Ask on the site
  you sign in to: the mail is in that site's name and the link works only on
  that site's host;
- fewer than 3 unlock links have gone to that address this hour.

Otherwise nothing is sent, and the page says the same sentence anyway.

The link works once and for 15 minutes. It stops working when the account's
password is changed or reset, or its email address changes. A newer link does
not cancel an older one.

### Errors you can hit

- "Enter the email address you sign in with." The **Email** field was empty.
- No mail arrives. One of the conditions above was not met: the pause may
  already have ended, the request was made on another site, or 3 links were
  already sent this hour. Wait for the pause to end, or reset your password.
- "This link has already been used or is no longer valid. If you still can't
  sign in, request a new one." The link was used, is older than 15 minutes,
  was opened on another site's host, or was cancelled by a password or email
  change. Some mail security scanners click links as well as open them; if
  yours does, the scanner may have used it. Click **Request a new link**.
- "Too many requests" after submitting. Your IP address made more than 40
  requests to the sign-in pages in a minute. Wait for the time it shows.
- The sign-in still fails after the pause is lifted. Check the password. If
  attempts continue, someone else may be guessing it and has paused the
  account again: reset the password and turn on two-factor authentication or
  a passkey.

Admins see each link sent, used or refused in the site's
[security log](security-events.md#what-is-recorded).

For developers: the two actions behind these pages,
`KilnCMS.Accounts.request_sign_in_unlock/2` and
`KilnCMS.Accounts.redeem_sign_in_unlock/2`, are system-only. Only
`KilnCMSWeb.SignInUnlockController` calls them, with `authorize?: false` and
the request's site in `context:` (`KilnCMS.Security.AuthEvents.context/2`); a
call that carries an actor is refused, an admin's included. The link's
lifetime is `config :kiln_cms, KilnCMS.Accounts.SignInUnlock, ttl: {15,
:minutes}`, and the hourly mail budget is `config :kiln_cms,
KilnCMS.Accounts.AccountThrottle, unlock_mail_budget: 3`. The reasoning is in
[ADR 0023](decisions/0023-an-unlock-link-lifts-only-the-account-pause-and-the-pause-stays-undisclosed.md).

## Breached passwords

Whenever someone sets a password on your site (registers, changes it, resets
it, or you create the first admin in `/setup`) Kiln checks whether it appears in
a public data breach. The check sends only a short fragment of a hash of the
password to the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) range
API; the password never leaves your server. Signing in is not checked.

### Choose what happens

Requires the admin role.

1. Open **Password policy** under **Sign-in & access** in the console sidebar (or go to
   `/editor/password-policy`).
2. In **When a new password is in a known breach**, pick one of the three options:
   - **Off - don't warn.** Passwords set on this site are not checked, and
     nothing about them is sent to Have I Been Pwned. The description under
     the menu adds the two limits: if the saved policy can't be read, Warn
     applies instead, and only the operator's `BREACHED_PASSWORD_CHECK=false`
     stops the check for every site
     ([When the check does nothing](#when-the-check-does-nothing)).
   - **Warn - allow it, with a warning.** The default. The password is
     accepted; the person sees a notice asking them to consider another.
   - **Block - refuse it for administrators.** An administrator's new password
     that is in a breach is refused with "This password has appeared in a known
     data breach. Choose a different one." Editors and viewers are only warned.
3. Click **Save**. You see "Password policy saved." and the new choice applies to the next
   password set; nothing is re-checked retroactively.

**Use the default** (shown once the site has its own choice; it asks to confirm) removes the site's choice, so the
operator's default (`BREACHED_PASSWORD_POLICY`, `warn` if unset) applies again.

"Administrator" means the stricter of the account's role (a temporary role
counts) and its membership tier on this site.

### What people see

- **Blocked:** an error under the password field; they pick another.
- **After changing a password, or first-run setup:** the notice appears
  with the redirect to sign-in.
- **After registering or resetting:** the notice appears after their next
  password sign-in. It is a one-time, best-effort note kept for ten minutes, and
  it can be missed on a multi-node deployment.

### When the check does nothing

- The operator set `BREACHED_PASSWORD_CHECK=false` (the page says so).
- The site's policy is **Off**: nothing is sent. (If the saved policy can't
  be read, the site is treated as **Warn**; only the operator's
  `BREACHED_PASSWORD_CHECK=false` guarantees no request.)
- The lookup service is slow or unreachable: the password is accepted. Operators
  can watch for this in [observability](observability.md#breached-password-checks).
- Passwords an admin does not type: the admin-sent reset *mail* is checked when
  the owner uses the link, but magic links, SSO and passkeys set no password,
  and seeds and operator scripts are not checked.

See the [threat model](threat-model.md#breached-passwords) for the limits and
[environment variables](environment-variables.md#breached-password-check-2240)
for the two operator settings. Why the check is on by default and accepts the
password when the lookup fails is in
[ADR 0031](decisions/0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md).

## Signing an account out

"Sign out everywhere" does both halves:

- `Accounts.log_out_user_everywhere/2` (AshAuthentication's `log_out_everywhere`
  add-on) revokes every stored token, so each browser session fails on its next
  request;
- `KilnCMS.Accounts.SessionEviction.evict/2` drops the sockets that are
  connected right now, which no token revocation reaches.

Either alone leaves the account signed in somewhere.

That is one account, on every site. A site admin can also act on one site:
sign browsers out after a stretch of inactivity
([Sign people out when idle](#sign-people-out-when-idle)), or end every browser
session there at once ([Sign everyone out](#sign-everyone-out)).

## Sign people out when idle

Requires the admin role on the site (an org admin, or a platform admin). The
setting is per site and off by default: until you set it, a browser stays
signed in until it signs out, and "remember me" keeps it signed in for 30 days.

1. Open **Sessions** under **Configure → Sign-in & access** in the console sidebar
   (or go to `/editor/sessions`). Under **Sign out when idle**, the page reads
   "No idle timeout is set: browsers stay signed in until they sign out."
2. In **Everyone**, pick how long a browser may sit unused: from **15
   minutes** to **24 hours**. **Never** turns the timeout off.
3. Optionally, in **Administrators**, pick a shorter time for the site's
   admins. **Same as everyone** holds them to the time above. You can set only
   this one, which leaves editors and viewers without a timeout.
4. Click **Save**. You see "Session settings saved." and the line under the
   form reads "This site signs idle browsers out."

The clock starts at the save: turning the timeout on, or shortening it, signs
nobody out for time they spent idle before. Pages already open pick the change
up within a few seconds.

"Administrator" means the account's tier on this site, worked out again at
every check, so a temporary admin grant counts while it lasts. A person who is
an admin here and an editor on another site gets this site's admin time here
only. Each person can see the time that applies to them under **Active
sessions** on **Your settings**: "This site signs a browser out after 30
minutes without activity."

### What counts as activity

| Counts | Does not count |
|---|---|
| Loading any page of this site while signed in, public pages included | A tab left open with nobody using it |
| Clicking, typing or submitting on a console page | A page reconnecting after a network drop or a deploy |
| Moving within a console page (a LiveView patch, such as a tab or filter change) | Replies a page sends on its own (`body_flushed`, `push_state`, `push_unsupported`) |
| | Requests with an API key or a bearer token, and image transforms (`/media/:id/t/…`) |
| | Activity on another site |

Activity is written down at most once per tenth of the timeout, clamped to
between 30 seconds and 5 minutes, so a browser is signed out after between 90% and 100% of the timeout without
activity. An open page checks a few seconds after its deadline; a closed one is
checked at its next request.

The timeout wins over "remember me". A browser that goes idle loses its
remember-me cookie with its session, and a remember-me cookie that sat unused
longer than the timeout no longer signs the browser in: the cookie is deleted
and the person signs in again.

### What people see

- **An open console page** goes to `/sign-in` with "You were signed out after a
  period of inactivity."
- **The next click on a sign-in or console page** shows the same message on
  the sign-in page.
- **A public page** is served as to a signed-out visitor, with no message:
  public pages may be stored by a shared cache, so they never change cookies.
- **The site's security log** records **Signed out after inactivity**
  (`session_idle_expired`) for each one; see
  [Security events](security-events.md#what-is-recorded).

### When the timeout does nothing

- **The setting cannot be read** (a database fault): the timeout is off for
  that minute and a warning is logged. It fails open rather than signing every
  account out during an outage. There is no operator ceiling and no
  environment variable: the site decides.
- **API keys, bearer tokens and headless app tokens** are not browser sessions
  and never expire for idleness.
- **Clicks inside some components** (a LiveComponent handling its own events)
  do not count on their own. Every page that has them also sends page-level
  events, but a page driven only by such clicks can sign out the person using
  it.

### Errors you can hit

- "The time for administrators can't be longer than the time for everyone."
  The **Administrators** time must be the same or shorter.
- "Choose one of the listed times." The form sent a value that is not a number.
- "You don't have permission to change this site's session settings." Your
  admin role on the site ended after you opened the page.
- Editors and viewers who open `/editor/sessions` are sent to the access-denied
  page.

## Sign everyone out

For a suspected breach on one site. Requires the admin role on the site.

1. Open **Sessions** under **Configure → Sign-in & access** (`/editor/sessions`)
   and scroll to **Sign out everyone**.
2. Leave **Keep me signed in on this browser** ticked to stay signed in here,
   or untick it to sign yourself out too.
3. Click **Sign out everyone** and confirm "Sign out everyone on this site
   now?". You see "Signed out 12 sessions on this site."

What it ends, on this site only:

- every browser session, including platform admins' sessions on this site;
- every "remember me" cookie issued on this site;
- every sign-in waiting at the two-factor prompt. A person who enters the code
  afterwards is signed out again on their next page.

Every open page of those sessions goes to `/sign-in` with "An administrator
signed everyone out of this site. Sign in again to continue." Sessions on other
sites, including the same people's, are not affected. **Keep me signed in on
this browser** spares only the browser you clicked from (and its remember-me
cookie), not your sessions on other devices.

The count covers sessions known to belong to this site. Sessions signed in
before the upgrade that added this page record no site yet; they are not
counted, and each is signed out the first time it is used on this site again.

What it does **not** end:

- **API keys.** Revoke them on the **API keys** page.
- **Headless app tokens** (`POST /api/auth/sign_in`), including any minted
  with a stolen password. Reset the account's password, or have a platform
  admin use **Sign out everywhere** on the account in `/editor/accounts`
  ([Signing an account out](#signing-an-account-out)).
- **Already-connected collaborative-editing and GraphQL subscription sockets**
  (`/ws/collab`, `/ws/gql`). They are keyed per account rather than per
  browser, and close at their next reconnect or re-check.

The site's security log records **Everyone signed out**
(`all_sessions_revoked`) with the number of sessions and whether you kept your
own. If the log entry cannot be written, nothing is signed out and the page says
"Nobody was signed out. Try again."

### From code

`KilnCMS.CMS.sign_out_all_sessions/2` is the same action. It needs the site as
the tenant and an admin of that site as the actor, and returns the number of
browser sessions it ended:

```elixir
{:ok, count} =
  KilnCMS.CMS.sign_out_all_sessions(%{},
    actor: admin,
    tenant: org
  )
```

Pass `except_session_jti:` to keep one session. It must be one of the actor's
own sessions on this site; anything else is refused with "is not one of your
sessions on this site" and nothing is signed out. Without a tenant the call is
refused. The idle timeouts are saved with
`KilnCMS.CMS.save_site_session_policy/2`
(`%{idle_timeout_minutes: 60, admin_idle_timeout_minutes: 15}`, each `nil` or
10 to 1440); `KilnCMS.Accounts.IdleTimeout` enforces them.

## Restrict sign-in to your networks

A site admin can limit the console and every sign-in page on the site to a
list of IP addresses and ranges, such as an office or a VPN, at **Configure →
Sign-in & access → Admin allowlist** (`/editor/admin-allowlist`). Members and
apps that sign people in are restricted too while the list is on. The full
guide, including how an operator gets admins back in after a lock-out, is
[Restricting sign-in to your networks](admin-allowlist.md).

## Human verification at sign-in

The operator can have password sign-in and registration ask for a
human-verification check (Cloudflare Turnstile, Google reCAPTCHA v2 or a
plugin's provider) once an email address or an IP address has had too many
attempts. It is set for the whole installation with environment variables, not
per site, so there is no console page for it. Passkeys, sign-in links,
password reset, two-factor codes, single sign-on and invitations never ask for
one. See [Human verification](human-verification.md).

## Removing an account

`KilnCMS.Accounts.AccountRemoval.remove/3` is two decisions in one step: what
happens to the content, then the account itself.

### Content disposition

| Disposition | What it does | Reversible by |
|---|---|---|
| `:keep` | nothing — published work keeps its place in delivery, and its byline stops naming a person | n/a |
| `:archive` | the `:archive` workflow transition per document: torn out of delivery exactly as unpublishing would, artifacts purged, `unpublished` webhook fired | an editor, via `:unarchive` |
| `:trash` | soft-delete (AshArchival), the same `:destroy` the editor's delete button runs | an admin, from `/editor/trash` |

Nothing here hard-deletes content. `:purge` exists and is deliberately not
offered — "delete the account" must not be a way to silently destroy a site's
published archive.

The disposition spans **every content type on every site** the account authored
on, in cursor-paged batches, one document at a time (both writes carry
`after_action` hooks, so neither is a bulk atomic write). Failures are counted,
not raised: one document with a stale lock must not abandon the other four
hundred.

### Why deletion is erasure

There is no hard delete of a user row in Kiln. Seventeen tables reference
`users` as of this writing — content bylines, task assignees and creators,
comment authors, release creators, media uploaders — almost all with no
`ON DELETE` clause, so a row delete is a foreign-key error rather than a clean
removal, and the cascades that would make it succeed are exactly the audit trail
[retention](data-flows.md) keeps on purpose.

So removal is `User.:anonymize`, the GDPR Art. 17 path: the email becomes a
non-routable tombstone, the name is blanked, the password hash is destroyed,
the role drops to `:viewer`, audiences are cleared (even when a stale copy of
the account was loaded with none), passkeys and IdP links are deleted, every
token is revoked, paid memberships are canceled locally, and live sockets are
dropped. It also deletes what reaches only that person: their Web Push
subscriptions (the device endpoints review notifications go to), their private
saved views (shared views are the team's and stay), and the notifications
addressed to them. Nothing personal remains and nothing can sign in
again. What remains is a referenced id, and the console says so rather than
claiming a delete it did not do.

**Preflight, then content, then account.** Refusals that are knowable up front —
the last-admin guard, a policy the actor fails — are checked before any document
is touched, so a refused removal changes nothing. After that the content goes
first, so a failure part-way through leaves an account that is still an account,
with its content in a state the admin is told about.

A content type whose documents **could not be read** is reported by name — on the
confirmation screen ("could not be counted") and in the result — never folded into
a success count. Erasure also clears the account's temporary grant and any
per-site grants, and **revokes its API keys**: a surviving key would sign the
tombstone straight back in.

## The last admin

`KilnCMS.Accounts.Validations.NotLastAdmin` refuses the demotion or erasure that
would leave the instance with no platform admin. There is no recovery path for
that through the UI: `/setup` is gated on "no admin exists", and an account with
`role: :viewer` still exists, so the first-run wizard does not come back — the
fix is a release console.

A temporary admin does not count as the other one. A grant expires, so an
instance whose only admin holds one is the same lockout, merely deferred.

The guard applies to system calls too — `KilnCMS.Beta.Round` seats testers through
`:manage_access` with no actor, and demoting the sole admin there would also flip
`Bootstrap.bootstrapped?/0` and re-open the anonymous first-run wizard. The one
exemption is by name: `KilnCMS.Staging.Scrub`, which erases every account on a
clone of production on purpose, passes `context: NotLastAdmin.exempt()`.
