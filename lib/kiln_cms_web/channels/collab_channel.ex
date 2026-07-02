defmodule KilnCMSWeb.CollabChannel do
  @moduledoc """
  Relay for the collaborative-editing CRDT prototype (`KilnCMS.Collab.Crdt`).

  One topic per open document (`collab:<kind>:<id>`). Joining attaches to the
  authoritative `DocServer` and replies with the full doc state (base64 Yjs
  update) plus the peer count — `peers: 1` tells the first client to seed the
  doc from the stored HTML. Two inbound events:

    * `"update"` — a binary Yjs update (base64): applied to the authoritative
      doc, then relayed to every other client;
    * `"awareness"` — ephemeral presence/caret payloads: relayed verbatim,
      never stored.

  Joins are refused while the `:collab_prototype` flag is off, so the channel
  is inert in production. Socket-level token auth already limits connections
  to signed-in editors (`KilnCMSWeb.CollabSocket`).
  """
  use Phoenix.Channel

  alias KilnCMS.Collab.Crdt

  @impl true
  def join("collab:" <> _key = topic, _params, socket) do
    if Crdt.enabled?() do
      {:ok, server} = Crdt.ensure_server(topic)
      {state, peers} = Crdt.attach(server)

      {:ok, %{"state" => Base.encode64(state), "peers" => peers},
       assign(socket, :doc_server, server)}
    else
      {:error, %{reason: "collab disabled"}}
    end
  end

  @impl true
  def handle_in("update", %{"update" => encoded}, socket) do
    with {:ok, update} <- Base.decode64(encoded),
         :ok <- Crdt.apply_update(socket.assigns.doc_server, update) do
      broadcast_from!(socket, "update", %{"update" => encoded})
      {:reply, :ok, socket}
    else
      _invalid -> {:reply, {:error, %{reason: "bad update"}}, socket}
    end
  end

  # Cursor/selection/name presence — ephemeral by design: relayed to the other
  # clients and forgotten.
  def handle_in("awareness", payload, socket) do
    broadcast_from!(socket, "awareness", payload)
    {:noreply, socket}
  end
end
