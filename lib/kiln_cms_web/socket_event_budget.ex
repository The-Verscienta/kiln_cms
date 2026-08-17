defmodule KilnCMSWeb.SocketEventBudget do
  @moduledoc """
  A per-**connection** budget on the frames a client sends over an
  established socket (#1305) — the residual `KilnCMSWeb.LiveJoinBudget` (#1183)
  and the `/ws/*` connect budgets left open in `docs/threat-model.md` item 10.

  Those two count *handshakes*: a `/live` root join, a `/ws/gql`, `/ws/bridge`
  or `/ws/collab` connect. Once a connection is up, nothing counted what a
  client sent over it — a `handle_in/3` on a long-lived socket cost nothing
  per call, so a caller who connected once (paying one unit of the connect
  budget) could push events for as long as the socket stayed open, and every
  one of them was served in full.

  ## Why per connection, and not per address

  The join budgets key on the client address, and share one bucket per socket
  family across every connection from that address. Events cannot be sized
  that way. Legitimate collaboration *is* a high-frequency event stream — one
  editor typing in `/ws/collab` produces two frames per keystroke (a Yjs update
  and an awareness update, see `assets/js/collab.js`), and a mouse-drag
  selection re-announces the caret at the browser's event rate — so an
  address-wide ceiling that clears twenty editors on one office NAT all
  typing at once would be too high to catch anything, and one that catches
  a flood would close every room on that NAT the moment a meeting's worth of
  people paste at the same time.

  A **connection** has a natural cost model: one connection is one tab, one
  human, and one human's frame rate is bounded. So the ceiling is per
  connection, keyed on the transport process (`socket.transport_pid`), which is
  the websocket itself — the same pid for every channel joined over it, and
  for every *re*join of a channel this budget closed. That last point is what
  keeps a refusal from being an amplifier: a client whose channel was stopped
  for flooding and that rejoins immediately is still over the same budget,
  and is refused at `join/3` before the join's own authorization queries run.
  To get a fresh budget the client has to open a fresh connection, and
  connections are what the address-keyed join budgets charge — the two
  compose, one bounding how many sockets an address gets and this one bounding
  what one socket may send.

  ## What it charges

  Everything a channel receives from its client — every `handle_in/3` frame,
  whatever its event name, plus the `join/3` that opened it — against one
  `KilnCMSWeb.RateLimit` bucket named by the caller. One bucket per socket
  family and not per event kind, deliberately: per connection the frames come
  from one human, and it is the *total* work one connection may cause that has
  to be bounded, not the shape of it. The expensive-to-serve amplifier on
  `/ws/collab` is that every N `"update"`s re-run the join's authorization
  (three database reads, `KilnCMSWeb.SocketReauth`); the cheap-to-flood one is
  `"awareness"`, relayed to every peer in the room. Both are frames, both
  count.

  ## What a refusal looks like

  This module only answers; the channel decides. A refused `handle_in/3` should
  **stop the channel** rather than reply with an error and drop the frame: a
  Yjs update dropped on the floor leaves that client's document diverged until
  the next full-state sync, and the only thing that produces one is a rejoin —
  which is what a stopped channel gives it. Phoenix pushes `phx_error` on the
  exit, `phoenix.js` retries the join on a backoff, and each successful rejoin
  re-applies the room's authoritative state, so an honest client that somehow
  tripped the ceiling loses nothing and is back within the window's reset. A
  scripted one gets a closed channel per attempt and a refused join for the
  rest of the window, which is the point.

  ## Sizing

  Not decided here — see the bucket's comment in `KilnCMSWeb.RateLimit`. The
  shape is a flood ceiling per connection per minute, well clear of the fastest
  human on one tab, so that a false positive costs a resync a real editor
  will never see and a flood is bounded to what one human could have done.

  ## What it does not cover

  Only `KilnCMSWeb.CollabChannel` charges it today — the surface whose events
  are cheapest to flood and most expensive to serve, per the issue's own
  scoping. `/live` events (`handle_event/3` on every LiveView; no single hook
  intercepts them before the handler body) and `/ws/gql` subscription
  documents are still uncounted, and remain in threat-model item 10.
  """

  alias KilnCMSWeb.RateLimit

  @doc """
  Charges one frame on `socket`'s connection to `bucket`.

  Keyed on `socket.transport_pid`, so every channel on one websocket — and
  every rejoin of a channel over it — spends the same budget. Returns
  `:ok`, or `{:deny, retry_after_ms}` when the connection is over it.
  """
  @spec charge(atom(), Phoenix.Socket.t()) :: :ok | {:deny, non_neg_integer()}
  def charge(bucket, %Phoenix.Socket{transport_pid: transport_pid})
      when is_atom(bucket) and is_pid(transport_pid) do
    case RateLimit.check(bucket, connection_key(transport_pid)) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  @doc """
  The bucket key for a connection: its transport pid, spelled the way
  `:erlang.pid_to_list/1` spells it (`<0.123.45>`, serial included, so a
  recycled process index inside one window is not the same key).
  """
  @spec connection_key(pid()) :: String.t()
  def connection_key(transport_pid) when is_pid(transport_pid) do
    "conn:" <> List.to_string(:erlang.pid_to_list(transport_pid))
  end
end
