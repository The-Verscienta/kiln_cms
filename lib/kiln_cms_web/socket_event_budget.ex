defmodule KilnCMSWeb.SocketEventBudget do
  @moduledoc """
  A per-**account** budget on the frames a client sends over an established
  socket (#1305) — the residual `KilnCMSWeb.LiveJoinBudget` (#1183) and
  `KilnCMSWeb.SocketJoinBudget` (the `/ws/*` connects) left open in
  `docs/threat-model.md` item 10.

  Those count *handshakes*: a `/live` root join, a `/ws/gql`, `/ws/bridge` or
  `/ws/collab` connect. Once a connection is up, nothing counted what a client
  sent over it — a `handle_in/3` on a long-lived socket cost nothing per call,
  so a caller who connected once could push events for as long as the socket
  stayed open, and every one of them was served in full.

  ## The key: the account, not the address and not the connection

  The join budgets key on the client address, and share one bucket per socket
  family across every connection from that address. Events cannot be sized
  that way. Legitimate collaboration *is* a high-frequency event stream — one
  editor typing in `/ws/collab` produces a Yjs update per keystroke and an
  awareness frame per caret move (`assets/js/collab.js`) — so an address-wide
  ceiling that clears twenty editors on one office NAT all typing at once is
  too high to catch anything, and one that catches a flood closes every room
  on that NAT the moment a meeting's worth of people paste at the same time.

  A **connection** was the first candidate: one connection is one tab, one
  human, and a human's frame rate is bounded. But a connection is also the
  cheapest thing a flooder has — a fresh websocket is a fresh key, so a
  per-connection ceiling bounds nothing a script cannot reset by reconnecting,
  and the honest recovery from a refusal *is* a reconnect (below), which would
  hand the flooder the reset for free.

  So the key is the **actor** — the account the socket authenticated as
  (`socket.assigns.actor.id`, which every `/ws/collab` connection carries;
  `KilnCMSWeb.CollabSocket` refuses a connect without one). One human's frame
  rate is bounded the same whether they hold one tab or three, so the ceiling
  is sized the same as it would be per connection; what changes is that a
  reconnect, a second tab or a second room does not mint a fresh budget, and a
  flooder is bounded per credential rather than per socket. It is the same
  axis the sign-in throttle already uses beside its per-address bucket
  (`KilnCMS.Accounts.AccountThrottle`): the address bounds volume, the account
  bounds what one identity may do. Nothing about it collides across an office
  NAT. Its one cost is a *shared* login — several humans on one account share
  one budget — which this deployment's per-user accounts, roles and eviction
  already assume is not how it is used. A socket that carries no actor (none
  does today) falls back to its transport pid, so a future anonymous channel
  is bounded per connection rather than exempt.

  ## What it charges

  Everything a channel receives from its client — every `handle_in/3` frame,
  whatever its event name, plus the `join/3` that opened it — against one
  `KilnCMSWeb.RateLimit` bucket named by the caller. One bucket per socket
  family and not per event kind, deliberately: it is the *total* work one
  account may cause that has to be bounded, not the shape of it. The
  expensive-to-serve amplifier on `/ws/collab` is that every N `"update"`s
  re-run the join's authorization (three database reads,
  `KilnCMSWeb.SocketReauth`); the cheap-to-flood one is `"awareness"`, relayed
  to every peer in the room. Both are frames, both count. A frame that makes
  *other* clients send frames is a different problem — one connection could
  spend every peer's budget through it — and `KilnCMSWeb.CollabChannel`
  bounds the one such frame it has (`"awareness_request"`) on its own.

  ## What a refusal looks like

  This module answers; the channel decides. But the channel's choice is
  narrower than it looks, and this is where the first version of this budget
  was wrong: **stopping the channel does not make the client rejoin.** A
  `{:stop, {:shutdown, _}, socket}` from `handle_in/3` is a *graceful* close —
  the channel server tells the transport, which pushes `phx_close`, and
  `phoenix.js` treats `phx_close` as a completed leave: the channel goes to
  `closed`, is removed from the socket, and is never rejoined. Only a channel
  in `errored` state is rejoined, and only `phx_error` (a crash) or a socket
  close puts it there. A crash is not an option (a client-triggerable error
  report per refusal), so the refusal **closes the connection** instead:
  `close_connection/1` sends the transport the same `"disconnect"` broadcast
  `KilnCMS.Accounts.SessionEviction` uses (#675), the transport closes with
  code 1001, `phoenix.js` reconnects on its backoff and rejoins every channel
  it had, and each rejoin runs `join/3` — where the account, still over
  budget, is refused before its authorization reads until the window turns.
  Then the joins succeed, the room's full state is re-applied, and the client
  pushes back whatever local ops the room is missing (`collab.js` diffs its
  doc against the state it was handed, so the frame that tripped the budget
  and the ones in flight behind it are not lost). An honest editor who trips
  the ceiling therefore sees collaboration pause for the rest of the window
  and resume on its own, with nothing dropped; a script sees a closed socket
  per attempt and refused joins on its account, which is the point.

  Refusing a *join* does not close the connection: `phoenix.js` already
  retries a refused join on a backoff while the socket stays up, and closing
  it would only make the retry more expensive.

  ## Sizing

  Not decided here — see the bucket's comment in `KilnCMSWeb.RateLimit`. The
  shape is a flood ceiling per account per minute, well clear of the fastest
  human, sized against the client's own frame rate (which it bounds: awareness
  pushes are coalesced client-side so a mouse drag cannot emit at the
  browser's event rate).

  ## What it does not cover

  Only `KilnCMSWeb.CollabChannel` charges it today — the surface whose events
  are cheapest to flood and most expensive to serve, per the issue's own
  scoping. `/live` events (`handle_event/3` on every LiveView; no single hook
  intercepts them before the handler body) and `/ws/gql` subscription
  documents are still uncounted, and remain in threat-model item 10.
  """

  alias KilnCMSWeb.RateLimit

  require Logger

  @doc """
  Charges one frame from `socket`'s account to `bucket`.

  Keyed on the actor the socket authenticated as, so every connection, tab,
  room and rejoin of one account spends the same budget; a socket with no
  actor is keyed on its transport pid. Returns `RateLimit.check/2`'s answer
  unchanged — `:allow`, or `{:deny, retry_after_ms}` — and logs the refusal
  at `:debug` (client-triggerable, so a line per refusal is an unbounded
  write; the caller's refusal is the signal that matters).
  """
  @spec charge(atom(), Phoenix.Socket.t()) :: :allow | {:deny, non_neg_integer()}
  def charge(bucket, %Phoenix.Socket{} = socket) when is_atom(bucket) do
    case RateLimit.check(bucket, key(socket)) do
      :allow ->
        :allow

      {:deny, retry_after_ms} = deny ->
        Logger.debug(fn ->
          "SocketEventBudget: #{key(socket)} over its #{bucket} budget on " <>
            "#{inspect(socket.topic)} (retry in #{retry_after_ms}ms)"
        end)

        deny
    end
  end

  @doc """
  The bucket key for a socket: `"actor:<id>"` for an authenticated one, or
  `"conn:<pid>"` (`:erlang.pid_to_list/1`, serial included) for one that
  carries no actor.
  """
  @spec key(Phoenix.Socket.t()) :: String.t()
  def key(%Phoenix.Socket{assigns: %{actor: %{id: id}}}) when is_binary(id), do: "actor:" <> id

  def key(%Phoenix.Socket{transport_pid: transport_pid}) when is_pid(transport_pid) do
    "conn:" <> List.to_string(:erlang.pid_to_list(transport_pid))
  end

  @doc """
  Closes the connection this socket rides, so the client reconnects and
  rejoins — the only refusal `phoenix.js` recovers from (see the moduledoc).

  The transport process handles a `"disconnect"` broadcast by closing with
  code 1001, exactly as it does when `KilnCMS.Accounts.SessionEviction`
  broadcasts one on the socket's id topic; this delivers the same message
  to this one transport directly rather than to every socket of the account.
  """
  @spec close_connection(Phoenix.Socket.t()) :: :ok
  def close_connection(%Phoenix.Socket{transport_pid: transport_pid})
      when is_pid(transport_pid) do
    send(transport_pid, %Phoenix.Socket.Broadcast{
      topic: "socket_event_budget",
      event: "disconnect",
      payload: %{}
    })

    :ok
  end
end
