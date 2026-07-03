defmodule KilnCMSWeb.CollabSocket do
  @moduledoc """
  Socket for the collaborative-editing CRDT prototype (`KilnCMS.Collab.Crdt`).

  Connections authenticate with a short-lived `Phoenix.Token` minted by the
  content editor's LiveView mount — which is itself editor/admin-gated — so
  only signed-in editors can ever hold a valid token. No token, no socket.
  """
  use Phoenix.Socket

  channel "collab:*", KilnCMSWeb.CollabChannel

  # Editor sessions are long-lived; tokens outlive a working day.
  @max_age 60 * 60 * 24

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, "collab", token, max_age: @max_age) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      _invalid -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "collab:user:#{socket.assigns.user_id}"
end
