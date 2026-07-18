defmodule KilnCMSWeb.BridgeSocket do
  @moduledoc """
  Live-preview push for the visual-editing bridge (#355).

  A raw `Phoenix.Socket.Transport` WebSocket (not a `Phoenix.Channel`) so the
  dependency-free `priv/static/bridge.js` can consume it with a plain
  `new WebSocket(...)` and JSON frames — no Phoenix JS client required. One
  connection watches one document:

      wss://<host>/ws/bridge?type=post&id=<uuid>&api_key=kiln_…

  On connect it authenticates the `api_key` to its owning user (or stays
  anonymous), authorizes that the actor may **read** that document (so a draft is
  never pushed to someone who couldn't fetch it), and subscribes to the same
  `content_preview:<type>:<id>` PubSub topic the structured editor broadcasts on
  (`ContentEditorLive.broadcast_preview/1`). Each `{:preview_update, payload}` is
  forwarded as a `{"event":"update", …}` JSON frame; the bridge fires its
  `onUpdate` callback so the external front end re-fetches the annotated preview
  and re-renders. Origin is gated by the shared `CORS_ORIGINS` allowlist
  (`check_origin` in the endpoint); the whole surface is off when
  `VISUAL_EDITING_ENABLED=false`.

  Compiled content types (page/post) are supported; live push for the dynamic
  entry tier is a follow-on (its editor broadcasts on a different topic kind).
  """
  @behaviour Phoenix.Socket.Transport

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.PreviewLive

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params}) do
    with true <- KilnCMS.VisualEditing.enabled?(),
         {:ok, ct, id} <- fetch_target(params),
         actor <- authenticate(params["api_key"]),
         :ok <- authorize_read(ct, id, actor) do
      {:ok, %{type: to_string(ct.type), id: id}}
    else
      _ -> :error
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(state.type, state.id))
    {:ok, state}
  end

  # The client never sends anything meaningful; ignore inbound frames.
  @impl true
  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:preview_update, payload}, state) do
    frame = %{
      "event" => "update",
      "type" => state.type,
      "id" => state.id,
      "title" => Map.get(payload, :title),
      "excerpt" => excerpt(Map.get(payload, :excerpt))
    }

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- helpers --------------------------------------------------------------

  defp fetch_target(%{"type" => type, "id" => id}) when is_binary(type) and is_binary(id) do
    case ContentTypes.get(type) do
      nil -> :error
      ct -> {:ok, ct, id}
    end
  end

  defp fetch_target(_), do: :error

  # `nil` actor = anonymous (published-only visibility); a `kiln_…` key resolves
  # to its owning user. An invalid key falls back to anonymous rather than
  # erroring — authorize_read then decides based on visibility.
  defp authenticate("kiln_" <> _ = key) do
    case Accounts.actor_from_api_key(key) do
      {:ok, actor} -> actor
      :error -> nil
    end
  end

  defp authenticate(_), do: nil

  # The actor must be able to read the document, or we refuse the socket (so a
  # draft is never streamed to someone who couldn't fetch it over HTTP).
  defp authorize_read(ct, id, actor) do
    ContentTypes.get_record!(ct.type, id, actor: actor)
    :ok
  rescue
    _ -> :error
  end

  defp excerpt(value) when is_binary(value), do: value
  defp excerpt(_), do: nil
end
