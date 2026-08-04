defmodule KilnCMSWeb.Plugs.LiveSocketId do
  @moduledoc """
  Keys a signed-in session's LiveView socket to its user, so it can be dropped
  (#675).

  LiveView sockets are disconnected by broadcasting on the session's
  `live_socket_id`, so a session without one is a socket that cannot be
  evicted — a demoted or erased editor keeps every mounted view until they
  close the tab.

  `KilnCMSWeb.AuthController.complete_sign_in/3` sets it for the flows that pass
  through it, which is most of them. This plug is for the two that do not:

    * **remember-me.** `sign_in_with_remember_me` calls
      `AshAuthentication.Plug.Helpers.store_in_session/2` directly and never
      reaches the controller, so a thirty-day cookie restored an undroppable
      session on every visit.
    * **sessions established before this shipped.** They carry a `user_token`
      and no `live_socket_id`, and nothing would ever add one — the value would
      have arrived only at a sign-in that already happened.

  Written on every request rather than only at sign-in for exactly that reason:
  the property wanted is "a signed-in session has one", not "a sign-in sets
  one", and only the first survives contact with a session store that predates
  the deploy. `put_session/3` on an unchanged value is a no-op for the cookie,
  so the cost is a map read per request.
  """
  import Plug.Conn

  alias KilnCMS.Accounts.SessionEviction

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: id} when is_binary(id) -> ensure_id(conn, SessionEviction.topic(id))
      _anonymous -> conn
    end
  end

  defp ensure_id(conn, topic) do
    if get_session(conn, :live_socket_id) == topic,
      do: conn,
      else: put_session(conn, :live_socket_id, topic)
  end
end
