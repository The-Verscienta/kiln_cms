defmodule KilnCMSWeb.SessionTracking do
  @moduledoc """
  Ties a signed-in LiveView to the one session it was mounted from (#1823).

  Attached by `KilnCMSWeb.LiveUserAuth` to every signed-in mount. It does
  three things:

    * assigns `:current_session_jti` — the jti of the token in this browser's
      session, which is how the settings page marks "This session" and keeps
      it out of "Sign out of all other sessions";
    * on a connected mount, notes that the session was used
      (`KilnCMS.Accounts.Sessions.record_use/2`, at most one write per
      interval), with the browser the socket was opened from;
    * on a connected mount, listens on the session's own topic
      (`KilnCMS.Accounts.SessionEviction.session_topic/1`) and, when that
      session is signed out from another device, sends this page to sign-in.

  The last is what makes "Sign out" on one session end it *now* rather than at
  its next full page load. The LiveView socket's `live_socket_id` is per user —
  `SessionEviction.evict/2` drops every session at once, which is right for a
  demotion and wrong here — so each LiveView subscribes to its own session
  instead. The redirect is a courtesy to the person in front of that page; the
  control is the revoked token, which the rejoin and every later request are
  refused on.
  """
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias Phoenix.LiveView

  @doc "Attach to a signed-in mount; `session` is the LiveView session."
  @spec attach(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def attach(socket, session) do
    jti = Token.peeked_jti(session["user_token"])
    socket = assign(socket, :current_session_jti, jti)

    if is_binary(jti) and LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.session_topic(jti))
      Sessions.record_use(jti, KilnCMSWeb.UserAgent.parse(user_agent(socket)))
      LiveView.attach_hook(socket, :session_eviction, :handle_info, &handle_info/2)
    else
      socket
    end
  end

  defp handle_info({:session_revoked, jti}, %{assigns: %{current_session_jti: jti}} = socket) do
    {:halt,
     socket
     |> LiveView.put_flash(:info, gettext("This session was signed out from another device."))
     |> LiveView.redirect(to: ~p"/sign-in")}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp user_agent(socket) do
    LiveView.get_connect_info(socket, :user_agent)
  rescue
    # Only readable during mount, and only when the endpoint declares it.
    _not_available -> nil
  end
end
