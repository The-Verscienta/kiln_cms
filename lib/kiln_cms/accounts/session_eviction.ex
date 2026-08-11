defmodule KilnCMS.Accounts.SessionEviction do
  @moduledoc """
  Drops a user's live socket connections when their authorization changes (#675).

  Every socket here authorized **once**, at connect and — for channels — at
  join, and never again. `BridgeSocket` authorized the read once and then
  streamed; `GraphqlSocket` puts the actor and tenant into the Absinthe context
  at connect and still does. (`CollabChannel` and `BridgeSocket` have since
  gained a periodic re-check of their own — see below.)

  So an account that was deleted, demoted to `:viewer`, removed from an
  organization, or had its `editable_types` / `readable_types` / audiences
  narrowed kept everything its live sockets were already granted — on every
  joined channel, for as long as the tab stayed open. The token's `max_age`
  bounds only the minting of *new* connections. Every HTTP surface refuses such
  an account immediately; the sockets did not.

  That was tolerable while the collab socket was inert. #655 made the join the
  security boundary, which made "evaluated once, never again" load-bearing —
  and offboarding an editor mid-session is exactly the case an operator assumes
  is covered.

  ## Evicting is not re-authorizing

  This drops the connection; it does not decide what the connection may do. A
  dropped client reconnects immediately, and that reconnect runs the full
  authorization it always did — so the effect of eviction is precisely "make
  them prove it again", which is the cheapest correct answer to "their grant
  changed" and needs no per-message check on a CRDT hot path.

  It is a **prompt** mechanism, not a complete one: it fires on the events wired
  to it, so an authorization change nobody remembered to wire in — and a change
  to the *document* rather than to the user — reaches a live socket only when
  something else looks. `KilnCMSWeb.SocketReauth` is that something else (#775):
  `CollabChannel` and `BridgeSocket` re-run their own check on a 30-second
  timer, so the two mechanisms answer different questions and neither replaces
  the other. This one bounds the window for the changes an operator makes
  deliberately, to seconds; that one bounds every other change, to the interval.

  Wiring a new grant-narrowing action to this module therefore remains the right
  thing to do — the backstop is a floor under forgetting, not a licence to.

  ## Four sockets, three mechanisms

  `Phoenix.Socket`-based sockets are dropped by broadcasting `"disconnect"` on
  their `id/1` topic, which Phoenix handles for us. That covers `CollabSocket`
  and `GraphqlSocket` — the latter had to *gain* an `id/1`, having returned
  `nil`, which is Phoenix's way of saying "this socket can never be
  disconnected".

  `BridgeSocket` is a raw `Phoenix.Socket.Transport` with no `id/1` callback at
  all, so it subscribes to the same topic itself and stops on the message.

  LiveView sockets are keyed by `live_socket_id` in the session, which nothing
  was setting — so `/live` was undroppable too.
  `KilnCMSWeb.AuthController.put_live_socket_id/2` writes it at sign-in, and
  `KilnCMSWeb.Plugs.LiveSocketId` covers the paths that never reach the
  controller (remember-me) and the sessions that predate this.

  All four derive their topic from `topic/1` here, so the broadcaster and the
  listeners cannot drift onto different strings — which would fail silently, in
  the direction of not evicting.
  """
  require Logger

  @doc """
  The PubSub topic a user's sockets listen on.

  One function so a socket's `id/1` and this module's broadcast are the same
  string by construction. Two spellings would leave the sockets connected and
  the caller believing they were dropped.
  """
  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: "user_sockets:#{user_id}"

  @doc """
  Drop every live socket belonging to `user_id`.

  Always returns `:ok`. Failures are swallowed and logged: this runs inside the
  action that changed the authorization — a deletion, a demotion — and an
  eviction that could roll that back would leave the *grant* changed and the
  socket connected, which is the worst of both.

  `reason` names the change, for the operator log only. Nothing is sent to the
  client beyond the disconnect itself.
  """
  @spec evict(String.t(), atom()) :: :ok
  def evict(user_id, reason) when is_binary(user_id) do
    Logger.info("Evicting live sockets for user #{user_id}: #{reason}")

    KilnCMSWeb.Endpoint.broadcast(topic(user_id), "disconnect", %{})
    :ok
  rescue
    error ->
      Logger.warning("Socket eviction failed for user #{user_id}: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("Socket eviction exited for user #{user_id}: #{inspect(reason)}")
      :ok
  end

  # A caller that could not name a user is the failure this module is least able
  # to survive quietly: `EvictSessions` reads the id out of a record by field
  # name, so a wrong `user_id:` option, a typo, or an attribute the action did
  # not select all arrive here as `nil` — every action succeeds, and no socket
  # ever drops. Logged at `:warning` for exactly that reason.
  def evict(user_id, reason) do
    Logger.warning(
      "Socket eviction skipped: no user id to evict (#{inspect(user_id)}, #{inspect(reason)}). " <>
        "A change wired with the wrong `user_id:` field fails exactly this way."
    )

    :ok
  end
end
