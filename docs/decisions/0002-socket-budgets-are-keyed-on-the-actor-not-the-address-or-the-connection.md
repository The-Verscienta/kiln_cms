# 0002. Socket budgets are keyed on the actor, not the address or the connection

- **Status** — accepted, shipped in
  [0.8.0](../changelog/v0.8.0.md) (Security).
- **References** — [#1305](https://github.com/The-Verscienta/kiln_cms/issues/1305), [#1183](https://github.com/The-Verscienta/kiln_cms/issues/1183).
- **Changelog** — [0.8.0 → Security](../../CHANGELOG.md#080---2026-09-11).

## Decision

**Frames on an established `/ws/collab` connection are budgeted per
account** (#1305). #1183 charged `/live` root joins, but once a socket was
up nothing counted what a client sent over it: an authenticated editor
holding one connection could push Yjs updates and awareness frames without
bound, each costing a `DocServer` apply and a room fan-out, and every N of
them a full re-authorization (three database reads). New
`KilnCMSWeb.SocketEventBudget` charges every `handle_in/3` on
`KilnCMSWeb.CollabChannel` — and the `join/3` that opened it, ahead of the
join's own authorization — to a new `:collab_event` bucket in
`KilnCMSWeb.RateLimit` (6,000/minute by default), keyed on the **actor** the
socket authenticated as: not the address (legitimate collaboration is itself
a high-frequency stream and one office NAT holds many editors) and not the
connection (a fresh websocket is a flooder's cheapest move, and the honest
recovery from a refusal is itself a reconnect). Over it, the *connection* is
closed — a channel stop alone is a `phx_close` the JS client treats as a
finished leave and never rejoins — so the client reconnects on a backoff,
its rejoins are refused until the window turns, and on the join that
succeeds it pushes back whatever local ops the room is missing, so nothing
typed meanwhile is lost. `assets/js/collab.js` now coalesces awareness
pushes to ~10/s (a mouse-drag selection used to emit at the browser's event
rate), resyncs its doc against the room's state on every successful join,
and treats an `"over budget"` join refusal as transient rather than seeding
the document as the first peer; the channel relays `awareness_request` at
most once per ten seconds per channel, since each relay makes every peer
send a frame of their own. Override like any bucket via
`config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{collab_event: …}`.
Events on `/live` and subscription documents on `/ws/gql` remain uncounted
(threat model item 10).
