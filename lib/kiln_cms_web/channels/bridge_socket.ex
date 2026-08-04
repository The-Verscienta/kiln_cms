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

  Works for every content type — compiled (page/post) and the dynamic entry
  tier alike — since the topic is keyed by the public type name (`ct.type`), the
  same value the editor broadcasts with.
  """
  @behaviour Phoenix.Socket.Transport

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.PreviewLive

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params} = info) do
    with true <- KilnCMS.VisualEditing.enabled?(),
         {:ok, ct, id} <- fetch_target(params),
         {:ok, org} <- fetch_org(info),
         actor <- authenticate(params["api_key"]),
         :ok <- authorize_read(ct, id, actor, org) do
      # The actor id rides along so `init/1` can subscribe to that user's
      # eviction topic. A raw transport has no `id/1` callback, so this socket
      # cannot be dropped the way a `Phoenix.Socket` is — it has to listen for
      # itself (#675). Anonymous connections carry `nil` and subscribe to
      # nothing: they hold no grant that can be revoked.
      {:ok, %{type: to_string(ct.type), id: id, actor_id: actor_id(actor)}}
    else
      _ -> :error
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(state.type, state.id))
    subscribe_to_eviction(state.actor_id)
    {:ok, state}
  end

  defp subscribe_to_eviction(actor_id) when is_binary(actor_id),
    do: Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.topic(actor_id))

  defp subscribe_to_eviction(_anonymous), do: :ok

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

  # The eviction broadcast. `Endpoint.broadcast/3` delivers a
  # `%Phoenix.Socket.Broadcast{}`, which is what a `Phoenix.Socket` acts on for
  # its own sockets — here it has to be acted on by hand, because this is a raw
  # transport (#675). Stopping the process closes the connection; the client
  # reconnects and runs the full authorization again, which is the point.
  def handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"}, state),
    do: {:stop, :normal, state}

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

  defp actor_id(%{id: id}), do: id
  defp actor_id(_anonymous), do: nil

  # The actor must be able to read the document, or we refuse the socket (so a
  # draft is never streamed to someone who couldn't fetch it over HTTP). Scoped
  # to the connecting host's org (epic #336) so a socket on one site's host
  # can't watch another site's document.
  defp authorize_read(ct, id, actor, org) do
    ContentTypes.get_record!(ct.type, id, actor: actor, tenant: org)
    :ok
  rescue
    _ -> :error
  end

  # Raw transports bypass the plug pipeline, so resolve the tenant from the
  # connect URI's host (the same source `SetTenant` uses). A missing host —
  # `connect_info` absent in tests — resolves to the default org, or refuses the
  # connection under `TENANT_STRICT_HOST` (#563).
  defp fetch_org(info) do
    # A raw transport nests connect_info one level deeper than a Phoenix.Socket.
    KilnCMSWeb.Tenant.fetch_org_from_connect_info(info[:connect_info] || %{})
  end

  defp excerpt(value) when is_binary(value), do: value
  defp excerpt(_), do: nil
end
