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
| Sets | site tier, custom role, per-member scope axes | platform role, audiences, temporary role |
| Can do | add an existing account to this site | create nothing — accounts arrive by sign-up, SSO or the first-run wizard |
| Also | publishing policy for the site | password resets, session revocation, account removal |

Both offer **temporary tiers** — the team page for the site tier, this page for
the platform role. See [Granular RBAC](granular-rbac.md) for how the tier
interacts with the scope axes.

## The register

Search matches email or name; the filters narrow by platform role and by status
(*unconfirmed*, *temporary role*, *erased*). The role filter is the **standing**
role, not the effective one: it is what an admin set, and hiding someone because
they happen to be an admin until Friday would hide them from the page that ends
the grant.

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

**How it reaches the policies.** `role` on an actor struct is what a dozen
`actor_attribute_equals(:role, :admin)` policies, `Scoping.effective_tier/2` and
`LiveUserAuth.platform_admin?/1` read.
`KilnCMS.Accounts.Preparations.FoldRoleGrant` — declared on both resources'
top-level `preparations`, so it runs for *every* read action — presents a live
grant as `role` on every record those reads return. Every actor in the system is
loaded through a read, so a grant one millisecond past its expiry already
authorizes as the standing role.

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
clears the two dead columns and evicts the holder's live sockets. It is hygiene
and session teardown, not enforcement — a missed run cannot leave anyone
elevated.

### Reading a row you are about to write

Ash discards a submitted attribute that equals `changeset.data`, and it does so
when params are *cast* — before any change or validation could put the row back.
So a write of `role` built on a folded record silently loses the one edit that
matters most: promoting a temporary admin to a permanent one submits
`role: :admin`, matches the folded `:admin` on the struct, is dropped as a no-op,
and reports success while the column stays `:editor`.

A caller about to write a role therefore reads with `RoleGrant.unfolded/0`:

```elixir
user = Accounts.get_user!(id, [actor: admin] ++ RoleGrant.unfolded())
Accounts.manage_user_access!(user, %{role: :admin}, actor: admin)
```

Forgetting is not silent: `KilnCMS.Accounts.Validations.UnfoldedRecord` refuses a
changeset built on a folded record, naming the fix.

## Password resets

`KilnCMS.Accounts.send_user_password_reset/2` mails a reset link to a named
account and reports whether it went. The anonymous form
(`:request_password_reset_token`) cannot: it is built to be indistinguishable —
it takes an address rather than an account, answers `:ok` whether or not that
address exists, and its sender drops the mail silently when the per-address
budget is spent. All correct for a public endpoint that must not become an
account oracle, all wrong for a button in the console.

The admin path therefore **bypasses the per-address mail budget** and logs that
it did. Nobody reaches it without an admin session, and on a spent budget the
button would otherwise report success and send nothing. Erased accounts are
refused: their password hash has no matching plaintext and their address is a
`@deleted.invalid` tombstone.

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

**Content first, account second.** A failure part-way through then leaves an
account that is still an account — recoverable, with its content in a mixed
state an admin can see and finish. The other order would leave a tombstone whose
content was never dealt with and whose author is no longer nameable.

## The last admin

`KilnCMS.Accounts.Validations.NotLastAdmin` refuses the demotion or erasure that
would leave the instance with no platform admin. There is no recovery path for
that through the UI: `/setup` is gated on "no admin exists", and an account with
`role: :viewer` still exists, so the first-run wizard does not come back — the
fix is a release console.

A temporary admin does not count as the other one. A grant expires, so an
instance whose only admin holds one is the same lockout, merely deferred.
