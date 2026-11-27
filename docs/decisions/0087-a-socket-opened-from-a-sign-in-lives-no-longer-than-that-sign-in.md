# 0087. A socket opened from a sign-in lives no longer than that sign-in

- **Status** — accepted (2026-11-26).
- **References** — [#2490](https://github.com/The-Verscienta/kiln_cms/issues/2490)
  (collab and GraphQL sockets survived a per-session sign-out);
  [#2489](https://github.com/The-Verscienta/kiln_cms/issues/2489) and
  [#2246](https://github.com/The-Verscienta/kiln_cms/issues/2246) (per-site
  idle timeout and "sign out everyone", which end sessions one at a time);
  [#1823](https://github.com/The-Verscienta/kiln_cms/issues/1823) (an
  account's own *Active sessions*); [#775](https://github.com/The-Verscienta/kiln_cms/issues/775)
  (the collab channel's periodic re-check).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Upgrade notes ([long form](../changelog/unreleased.md#session-bound-sockets-upgrade))
  and Security ([long form](../changelog/unreleased.md#session-bound-sockets)).

## The problem

Kiln ends sign-ins in two sizes. Per account: *Sign out everywhere*, a
password change or reset, an erasure, a demotion. Those revoke every token
and broadcast on the user's topic, which every socket's `id/1` names, so every
socket closed. Per session: one row from *Active sessions*, "all other
sessions", the site's idle timeout, the site's *Sign out everyone*, the
browser's own **Sign out**. Those revoke one token row and must leave the
account's other sessions alone (#2489: a site's sign-out must not reach the
same person on another site).

`SessionEviction.evict_session/2` reached a session's LiveViews, which listen
on a per-session topic. It reached nothing else. `/ws/collab` authenticated
with a 24-hour `Phoenix.Token` that named only the user, and `/ws/gql` with a
bearer JWT it never looked at again after the connect. Both sockets were
known to the server only by user. So the Sessions page said a browser was
"signed out now" while its collaborative-editing room went on writing to the
document for up to a day, and a GraphQL socket opened with the revoked token
went on answering queries. The collab channel's 30-second re-check (#775)
reloaded the user, not the session, and could not see it.

## The decision

**Every socket opened from a sign-in names that sign-in, and is closed with
it.**

- **The credential carries the session.** The collab token gains `"j"`, the
  jti of the browser session whose editor minted it
  (`KilnCMSWeb.CollabSocket.token/3`). A page that cannot name its session
  gets no token and edits on its own: there is no way to mint a collab token
  that a per-session sign-out cannot reach. A `/ws/gql` socket takes the jti
  from the bearer JWT it verified (`KilnCMSWeb.BearerAuth.verify_token/1`).
- **One broadcast reaches all of a session's sockets.** Every per-session
  sign-out broadcasts a `%Phoenix.Socket.Broadcast{event: "disconnect"}` on
  `SessionEviction.session_socket_topic/1`, which both sockets subscribe to at
  connect, after their last refusal. The two broadcasts in
  `evict_session/2` (pages and sockets) are guarded separately, so a failure
  in one does not skip the other. The browser's own Sign out sends only the
  socket half (`disconnect_sockets/2`): its pages are on their way to the
  sign-out redirect, and telling the other tabs at once would show them
  "signed out from another device".
- **A backstop reads the row.** A broadcast can be lost between nodes, sent by
  a node on an older release, or never sent by a path that revokes without
  one. The collab connect and its 30-second re-check read the session's row
  and refuse anything but a live, unexpired `"user"` sign-in of this account
  that the site's `IdleTimeout` would let a page through on
  (`CollabSocket.session_refused?/3`). Every `/ws/gql` document reads the
  bearer's row and is refused with `extensions.code: "unauthenticated"` once
  it is revoked, expired or gone (`GraphqlLimits.SocketSession`).
- **The site's rules follow the credential, not the socket.** A collab token
  is always minted from a browser session on the site, so the connect applies
  the site's idle, binding and watermark rules, and the re-check can expire an
  idle session whose pages are all closed. `/ws/gql` applies none of them,
  because `/gql` applies none to a bearer and a headless token from
  `POST /api/auth/sign_in` is bound to no site: running `IdleTimeout` on it
  would revoke it as "older than the watermark" (#2489 decided that a site's
  sign-out does not reach headless tokens).
- **Per-account eviction is unchanged.** `id/1` stays per user on both
  sockets, so everything that signs an account out everywhere still closes
  every socket it has.

## Rejected

- **A per-session `id/1`.** Phoenix allows one id per socket. Making it the
  session would lose per-account eviction, the more important of the two.
- **Sending the disconnect on the LiveViews' own topic.** `Phoenix.Socket`
  closes only on a `%Broadcast{event: "disconnect"}`; a LiveView on
  `user_session:<jti>` without a catch-all `handle_info/2` would crash on it.
  Hence a second topic.
- **Per-account eviction for per-session triggers.** Simple, and wrong: a
  site's idle timeout would close the same person's rooms on other sites and
  devices.
- **Relying on the re-check alone, or a shorter token lifetime.** It leaves a
  30-second (or token-lifetime) window where the session is signed out on
  every page but still editing, which is the gap the issue was filed about.
- **Applying site rules to every `/ws/gql` bearer.** See above: it revokes
  headless tokens.
- **Encrypting the collab token so the jti is not readable in the page.** A
  node on the previous release must be able to verify a new token during a
  rolling deploy, and a jti authenticates nothing on its own: every use
  checks the row's subject against the account presenting it.
- **Accepting a token without `"j"` indefinitely.** It would leave a way to
  hold a room that no per-session sign-out reaches. Legacy tokens are
  accepted for the one release that has to tolerate old nodes, and removed in
  the next.

## What it leaves open

- A collab token minted before the upgrade names no session; it is accepted,
  per account, until it expires (24 hours after the last old node stops).
- A `/ws/gql` socket that only holds subscriptions sends no documents, so
  after a revocation whose broadcast never arrived it keeps receiving pushes
  until it sends one or reconnects.
- During a rolling deploy, a node on the older release revokes sessions
  without the socket broadcast.
- A token row that cannot be read fails open on both sockets, as on every
  other door.
- The collab check costs one primary-key read and a cached policy lookup per
  re-check (every 30 seconds and every 200th update).

## When to revisit

When a new kind of socket or long-lived connection is opened from a sign-in:
it must subscribe to `session_socket_topic/1` and check its session's row, or
this record is wrong. And when the legacy collab clauses are removed, the
first residual above goes with them.
