defmodule KilnCMSWeb.SessionTracking do
  @moduledoc """
  Ties a signed-in LiveView to the one session it was mounted from (#1823).

  Attached by `KilnCMSWeb.LiveUserAuth` to every signed-in mount. It does
  two things:

    * assigns `:current_session_jti` — the jti of the token in this browser's
      session, which is how the settings page marks "This session" and keeps
      it out of "Sign out of all other sessions";
    * on a connected mount, listens on the session's own topic
      (`KilnCMS.Accounts.SessionEviction.session_topic/1`) and, when that
      session is signed out from another device, sends this page to sign-in.

  Noting that the session was used, with the browser the socket was opened
  from, is `KilnCMSWeb.IdleSession`'s, which runs just before this (#2246):
  on the first mount only, and on every event.

  The topic is what makes "Sign out" on one session end it *now* rather than at
  its next full page load. The LiveView socket's `live_socket_id` is per user —
  `SessionEviction.evict/2` drops every session at once, which is right for a
  demotion and wrong here — so each LiveView subscribes to its own session
  instead. The redirect is a courtesy to the person in front of that page; the
  control is the revoked token, which the rejoin and every later request are
  refused on. The flash says why, from the row's `revoked_reason`: signed out
  from another device, after inactivity, or by an admin's "sign out everyone"
  (#2246).
  """
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token
  alias Phoenix.LiveView

  @doc "Attach to a signed-in mount; `session` is the LiveView session."
  @spec attach(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def attach(socket, session) do
    jti = Token.peeked_jti(session["user_token"])
    socket = assign(socket, :current_session_jti, jti)

    if is_binary(jti) and LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.session_topic(jti))
      LiveView.attach_hook(socket, :session_eviction, :handle_info, &handle_info/2)
    else
      socket
    end
  end

  defp handle_info({:session_revoked, jti}, %{assigns: %{current_session_jti: jti}} = socket) do
    {:halt,
     socket
     |> LiveView.put_flash(:info, message(jti))
     |> LiveView.redirect(to: ~p"/sign-in")}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # Why the row was revoked; a row that cannot be read gets the message this
  # page always showed.
  defp message(jti) do
    reason =
      case IdleTimeout.read(jti, IdleTimeout.off()) do
        {:ok, row} -> IdleTimeout.revoked_reason(row)
        :error -> :revoked
      end

    KilnCMSWeb.IdleSession.reason_message(reason) ||
      gettext("This session was signed out from another device.")
  end
end
