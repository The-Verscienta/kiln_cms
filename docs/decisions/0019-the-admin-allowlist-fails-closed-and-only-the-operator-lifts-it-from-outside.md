# 0019. The admin allowlist fails closed, and only the operator lifts it from outside

- **Status** — accepted (2026-11-08); amended 2026-11-10 by
  [#2493](https://github.com/The-Verscienta/kiln_cms/issues/2493) (a per-site
  "Also restrict sign-in" setting, see "Amendment").
- **References** — [#2248](https://github.com/The-Verscienta/kiln_cms/issues/2248),
  following [#2242](https://github.com/The-Verscienta/kiln_cms/issues/2242)
  (the block list) and
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

#2248 lets a site admin restrict the console and sign-in to listed networks
(`KilnCMS.CMS.SiteAdminAllowlist`, enforced by `KilnCMS.Security.AdminAllowlist`
and its HTTP and socket gates). It sits beside the block list of #2242 and
shares its matcher (`KilnCMS.Security.Cidr`), but the two answer opposite
questions, and almost every choice the block list made is wrong for this one:

- The block list **fails open**: an unreadable rule set lets requests through,
  so a database blip does not take a public site down.
- The block list applies to **every route**, by an endpoint plug.
- The block list asks "**block it anyway?**" when a rule would cover the admin.
- The block list's operator command can **remove** rules, which only ever
  widens access.

An allowlist that fails open turns itself off exactly when the database is
struggling, and one that silently drops a route is a hole nobody sees. A list
saved with no way back in is a site nobody can administer.

## Decision

- **It fails closed.** A list that cannot be read answers `503` on the gated
  routes and refuses gated socket joins, and the failure is not cached. The
  console and sign-in cannot work without the database anyway, so this costs
  nothing real; public delivery never reads the list.
- **Except where this node last saw "off".** A site the node last read as off
  stays off through a failed read, so a blip does not take down the console of
  every site that never turned the list on. That memory is per node, lasts a
  day and is **versioned** by the row's `updated_at`: every save sets it on
  every node to the saved list, and a read that began before a save cannot
  write the older list back after it. Last known "on", or nothing known, stays
  closed.
- **Gating is structural.** The HTTP gate is router pipelines, first in each
  gated `pipe_through`: `:admin_allowlist` and `:admin_allowlist_api` for the
  console's surface, `:sign_in_allowlist` and `:sign_in_allowlist_api` for
  sign-in's (since #2493); the socket gate acts for exactly the
  `live_session`s whose routes sit behind those pipelines, on the same
  surface, and is also declared on every LiveView
  module so a url-less join cannot skip it. Whether a route is gated is a fact
  on the route, and `admin_allowlist_routes_test.exs` pins the whole gated set,
  so a new console or sign-in route lands in or out deliberately. A path-prefix
  plug was rejected: `KilnCMSWeb.Surface` shows prefixes are ambiguous
  (`/api/auth/sign_in`, `/media`, `/:slug`).
- **The save refuses a list that excludes its author.** No "confirm anyway":
  the lock-out is immediate and total.
- **Break-glass can only widen or clear.** `KilnCMS.Release.admin_allowlist/1`
  runs `operator_override` as the `:operator` system actor. It adds one entry
  to a list that is **on**, or empties the list, and records
  `admin_allowlist_overridden` in the same transaction. Adding to a list that
  is off is refused, because it would turn the list on from a shell and lock
  out every admin on another network. An org admin is refused the action. For
  operators who cannot run `rpc`, `KILN_ADMIN_ALLOWLIST_DISABLED` stops a node
  enforcing any list; it is not a site setting and is not in any security log.
- **The site decides; there is no operator ceiling.** By ADR 0018's test, a
  looser allowlist costs only the site that chose it, so the operator's levers
  are ways back in, not a ceiling.
- **Members' sign-in is gated too, by default.** The sign-in routes are shared
  by admins and members, and refusing after the password check would tell an
  outsider both that the password was right and that the account is
  privileged. The headless `POST /api/auth/sign_in` is gated for the same
  reason: it exchanges a password for a token with the account's full role.
  Since #2493 a site may turn this off; see "Amendment".
- **Rolling back turns the control off.** An older release does not know the
  table. This is said in the upgrade notes rather than prevented: preventing it
  would mean a contract migration that refuses to run backwards, for a setting
  that is off on most sites.

## Amendment (2026-11-10, #2493): "Also restrict sign-in"

Gating members' sign-in was a default chosen without an owner decision, and it
locks every member, and every SPA or mobile app that signs members in, out of
unlisted networks. The owner chose a per-site setting:

- **`restrict_sign_in` on `SiteAdminAllowlist`, on by default.** The migration
  adds the column with `DEFAULT true`, so every existing list keeps gating
  sign-in after an upgrade, and a rollback restricts sign-in again.
- **Turned off, sign-in opens and the console does not.** The gates ask for a
  surface, `:console` or `:sign_in`; the cached and broadcast value carries the
  whole setting (`{:console_only, cidrs}` when sign-in is open), and
  `KilnCMS.Security.AdminAllowlist.for_surface/2` projects it per gate. A value
  that reaches `verdict/2` unprojected is judged as the console would judge
  it, so a mistake fails closed.
- **The headless door follows the same setting.** `POST /api/auth/sign_in*`
  sits behind `:sign_in_allowlist_api`. A separate setting for it was rejected:
  a site that lets members sign in on its pages but not through its own app
  is not a real need, and a second checkbox is one more way to leave a door
  open by mistake.
- **What it gives up, said where it is chosen.** With sign-in open, the
  password check is no longer behind the list: an outsider learns whether a
  password is right, and an admin's password yields a full-role token that
  JSON:API, GraphQL and MCP accept from anywhere (they were never gated). The
  console page says so and recommends two-factor sign-in; the console itself,
  `/setup`, `/ws/collab` and the security posture stay behind the list.
- **Only those who manage the list change it.** It is an attribute of the same
  resource, written by the same `:save`, under the same org-admin policy, and
  audited in the same `admin_allowlist_changed` event (`sign_in`: `restricted`
  or `open`).

Option 2 of #2493, gating sign-in only on the console host when
`KILN_CONSOLE_HOST` is set, was not chosen: it helps only deployments that
split the hosts, and decides by deployment shape what is a site's choice.

## Considered and rejected

- **Fail open, like the block list.** The control would vanish under load, the
  case #564 warns about.
- **Fail closed always, with no last-known value.** One failed read on a busy
  node would answer `503` on the console and sign-in of every site, including
  the many with no list.
- **A loopback or platform-admin exemption.** Behind an undeclared same-host
  proxy every request is `127.0.0.1`, so a loopback exemption admits the whole
  internet; and a platform-admin exemption makes a stolen platform credential
  the bypass. The gate runs before anyone is known in any case.
- **An `allow` kind on the block list's table.** Opposite failure modes,
  opposite scopes and a whole-list lock-out check would share one cache and one
  set of rows.
- **Checking only at sign-in, or only over HTTP.** A cookie carried to another
  network would keep the console, and the password form's socket would let an
  outsider test passwords.

## Follow-ups

- A per-API-key address allowlist, for keys that should only be used from a
  known server.
- Two-step activation: save the list, then confirm from inside it within a
  few minutes or it rolls back.
