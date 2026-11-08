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
and the instance's own SSO all work for an unconfirmed account, and a magic
link sign-in confirms the address on the way. The one thing that
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

You need the admin tier on the site.

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

1. Open the console on the host of the site you are inviting them to, then
   **Team** under **Operations** in the sidebar (`/editor/team`). Team acts on
   the site the console is showing.
2. Under **Members**, enter the address in **Email**. Pick a **Site tier**
   (*Viewer* is the default) and, if the site has custom roles, a **Custom
   role**.
3. Click **Add or invite**. You see one of two results:
   - "Invitation sent to (address)." The address now appears under **Pending
     invitations (n)** with its tier, its custom role, "Invited by (you)." and
     "Expires (date and time, UTC)".
   - "Member added to this site." The address already had a confirmed account,
     so it is in the member list now. Its owner is mailed "You were added to
     (site)" with a sign-in link. There is nothing more to do.
4. The invitee receives "You've been invited to (site)". The mail names you,
   the site and the tier, and carries an **Accept the invitation** link that
   works once and expires in 7 days.
5. They open the link. The page reads "Join (site)" and "You've been invited to
   (site) as (tier), at (address)." What they do next depends on the address:
   - **No account:** they fill in **Display name (optional)**, **Password** and
     **Password (again)**, and click **Set up my account**. They get a confirmed
     account with the invited tier on this site.
   - **A confirmed account:** they click **Accept invitation**. Nothing else
     about the account changes.
   - **An account that was registered but never confirmed:** they see the
     password form, with a note that an unconfirmed account was already started
     with this address. Choosing a password takes the account over: the old
     password stops working, every session the account held is signed out, and
     a display name the first registrant chose is cleared unless they enter one.
     Anyone can register an unconfirmed account for any address, so its old
     password proves nothing about who holds the mailbox.
6. They are sent to the sign-in page with "Your account is ready — sign in to
   (site)." or "You've joined (site) — sign in to continue." They sign in as
   usual; a second factor still applies. On **Team** they are in the member
   list, and their invitation is gone from **Pending invitations**.

The link opens on the invited site, whichever host you were on when you sent it.
A viewer's link uses the site's public host. An editor's or admin's link uses
the console host when `KILN_CONSOLE_HOST` is set, and the site's own host if it
is not ([Serving the console from its own host](multi-tenancy.md#serving-the-console-from-its-own-host)).
Opening the link changes nothing until a button is pressed, so a mail scanner
that follows it does no harm.

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

`outcome` is `:added` (with `membership:`), `:invited` or `:reinvited` (an
expired invitation sent again, with `invitation:`). A refusal is
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
  the admin who sent it is no longer a standing platform admin. The page does
  not say which, on purpose. Send a new invitation.
- **"An account with this address already exists — accept the invitation with
  it."** An account was created for the address after the page opened, by
  sign-up or single sign-on. Nothing was set; the page now offers the branch
  that fits that account.
- **"Too many attempts from this address — try again shortly."** The same
  per-network budget as registration was spent.
- **"This password has appeared in a known data breach. Choose a different
  one."** The site's [breached-password policy](#breached-passwords) blocks it
  for the invited tier (blocking applies to administrators).
- **The invitee joined, but with a lower tier than you invited them at.** They
  were already a member of the site when they accepted (for example, they
  signed in through the site's own single sign-on first). Accepting leaves an
  existing membership as it is. Change their tier on their row.

Accepting *through* single sign-on is not supported: the invitee accepts with a
password or with an account they already have.

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

## Breached passwords

Whenever someone sets a password on your site (registers, changes it, resets
it, or you create the first admin in `/setup`) Kiln checks whether it appears in
a public data breach. The check sends only a short fragment of a hash of the
password to the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) range
API; the password never leaves your server. Signing in is not checked.

### Choose what happens

Requires the admin role.

1. Open **Password policy** under **Organization** in the console sidebar (or go to
   `/editor/password-policy`).
2. In **When a new password is in a known breach**, pick one of the three options:
   - **Off - don't warn.** The check result is ignored.
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
- The lookup service is slow or unreachable: the password is accepted. Operators
  can watch for this in [observability](observability.md#breached-password-checks).
- Passwords an admin does not type: the admin-sent reset *mail* is checked when
  the owner uses the link, but magic links, SSO and passkeys set no password,
  and seeds and operator scripts are not checked.

See the [threat model](threat-model.md#breached-passwords) for the limits and
[environment variables](environment-variables.md#breached-password-check-2240)
for the two operator settings.

## Signing an account out

"Sign out everywhere" does both halves:

- `Accounts.log_out_user_everywhere/2` (AshAuthentication's `log_out_everywhere`
  add-on) revokes every stored token, so each browser session fails on its next
  request;
- `KilnCMS.Accounts.SessionEviction.evict/2` drops the sockets that are
  connected right now, which no token revocation reaches.

Either alone leaves the account signed in somewhere.

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
the role drops to `:viewer`, audiences are cleared, passkeys and IdP links are
deleted, every token is revoked, paid memberships are cancelled locally, and
live sockets are dropped. Nothing personal remains and nothing can sign in
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
