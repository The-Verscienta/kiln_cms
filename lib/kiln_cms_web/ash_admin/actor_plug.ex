defmodule KilnCMSWeb.AshAdmin.ActorPlug do
  @moduledoc """
  Dev-only AshAdmin actor wiring (issue #24).

  Out of the box AshAdmin makes you pick an actor by hand from its toolbar.
  In development we instead default the actor to the signed-in user (loaded by
  `load_from_session` in the `:browser_dev_tools` pipeline) so policy-driven
  admin actions reflect real RBAC while inspecting data.

  Three pieces wire this together (all dev-only, see `config/dev.exs` and the
  router's `ash_admin` block):

    * `config :ash_admin, :actor_plug, KilnCMSWeb.AshAdmin.ActorPlug` swaps in
      this module so AshAdmin asks us for the actor.
    * `set_actor_session/1` runs in the request pipeline (dead views).
    * `actor_assigns/2` runs in AshAdmin's LiveView mount — this is the one that
      matters, since AshAdmin is a LiveView app. It needs the AshAuthentication
      session entries, which the `:session` option on the `ash_admin` route
      copies in via `admin_session/1`.

  An explicit actor chosen from the AshAdmin toolbar (stored in cookies) always
  wins, so devs can still impersonate other records. We only supply a default
  when no actor has been chosen and someone is signed in. When nobody is signed
  in we defer entirely to AshAdmin's default cookie-based behaviour.
  """

  @behaviour AshAdmin.ActorPlug

  alias AshAdmin.ActorPlug.Plug, as: Default
  alias AshAuthentication.Plug.Helpers

  @otp_app :kiln_cms

  # AshAuthentication stores the signed-in user under these session keys (the
  # subject name and, because tokens require presence, the token key). Copying
  # them into AshAdmin's LiveView session lets `actor_assigns/2` reload the user.
  @session_keys ["user", "user_token", "tenant"]

  @doc """
  Extra session forwarded into AshAdmin's `live_session` (wired via the
  `session:` option on the `ash_admin` route). Carries the AshAuthentication
  session entries so the LiveView can reload the signed-in user.
  """
  @spec admin_session(Plug.Conn.t()) :: map()
  def admin_session(conn) do
    conn
    |> Plug.Conn.get_session()
    |> Map.take(@session_keys)
  end

  @impl true
  def set_actor_session(conn) do
    conn = Default.set_actor_session(conn)

    cond do
      # An actor explicitly selected in the AshAdmin toolbar wins.
      conn.assigns[:actor] -> conn
      actor = conn.assigns[:current_user] -> assign_actor(conn, actor)
      true -> conn
    end
  end

  @impl true
  def actor_assigns(socket, session) do
    base = Default.actor_assigns(socket, session)

    case base[:actor] || load_user(session) do
      nil ->
        base

      actor ->
        Keyword.merge(base, actor: actor, authorizing: true, actor_paused: false)
    end
  end

  defp assign_actor(conn, actor) do
    conn
    |> Plug.Conn.assign(:actor, actor)
    |> Plug.Conn.assign(:authorizing, true)
    |> Plug.Conn.assign(:actor_paused, false)
  end

  defp load_user(session) do
    @otp_app
    |> AshAuthentication.authenticated_resources()
    |> Enum.find_value(fn resource ->
      case Helpers.authenticate_resource_from_session(resource, session, @otp_app, []) do
        {:ok, user} -> user
        _ -> nil
      end
    end)
  end
end
