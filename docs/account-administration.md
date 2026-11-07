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
| Can do | add an existing account to this site | create nothing — accounts arrive by sign-up, SSO or the first-run wizard |
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
