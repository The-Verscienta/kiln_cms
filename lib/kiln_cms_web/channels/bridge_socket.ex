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

  ## The connect check runs again, periodically (#775)

  Same shape as `KilnCMSWeb.CollabChannel`, lower stakes: this streams reads
  rather than accepting writes, so there is no damage-done bound to enforce and
  no update count — just the timer. It re-runs `authorize_read/4` against a
  reloaded actor on the same interval the collab room uses, and stops the
  connection when it no longer passes.

  What it catches that `KilnCMS.Accounts.SessionEviction` cannot: an
  authorization change nobody wired an eviction into, and — the one that matters
  most here — a change to the *document*. A draft that is archived, locked or
  moved out of the watcher's audience under an open stream otherwise keeps being
  pushed to them, because the connect check is long past. That applies to
  **anonymous** connections too, which hold no grant to revoke and so were
  entirely outside eviction's reach: a document that stops being public keeps
  streaming to whoever was already watching.

  The plaintext API key is deliberately **not** kept in the socket state to be
  re-verified. Revocation is the one grant change on this surface that *is*
  wired to eviction (`KilnCMS.Accounts.ApiKey`'s `:revoke`), so re-checking it
  here buys little — and a crash report prints a transport's state, which would
  put a live credential in the logs. The credential *metadata* is carried across
  the reload instead, so the key's own scope (`using_api_key?` and the `ApiKey`
  record that `Checks.ApiKeyWithoutWriteAccess` reads) means the same thing on
  the re-check as it did at connect, rather than the reloaded struct quietly
  presenting as a session actor.
  """
  @behaviour Phoenix.Socket.Transport

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.PreviewLive
  alias KilnCMSWeb.SocketReauth

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params} = info) do
    with true <- KilnCMS.VisualEditing.enabled?(),
         {:ok, ct, id} <- fetch_target(params),
         {:ok, org} <- fetch_org(info),
         actor <- authenticate(params["api_key"]),
         :ok <- authorize_read(ct, id, actor, org) do
      # The actor rides along so `init/1` can subscribe to that user's eviction
      # topic. A raw transport has no `id/1` callback, so this socket cannot be
      # dropped the way a `Phoenix.Socket` is — it has to listen for itself
      # (#675). Anonymous connections carry `nil` and subscribe to nothing: they
      # hold no grant that can be revoked.
      #
      # The org rides along too, so the periodic re-check (#775) re-reads the
      # document under the tenant this connection was authorized against rather
      # than re-deriving one from a host it can no longer see.
      {:ok, %{type: to_string(ct.type), id: id, actor: actor, org: org}}
    else
      _ -> :error
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(state.type, state.id))
    subscribe_to_eviction(actor_id(state.actor))
    {:ok, schedule_reauth(state)}
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

  # The periodic re-check (#775). Stopping is the same answer eviction gives —
  # the connection closes, and `priv/static/bridge.js` reconnects and runs the
  # full authorization again, which is the point. A watcher who has genuinely
  # lost the grant is refused at that connect and simply stops receiving.
  def handle_info(:reauthorize, state) do
    case reauthorize(state) do
      {:ok, state} ->
        {:ok, schedule_reauth(state)}

      :error ->
        Logger.info(
          "Bridge re-authorization refused for #{state.type}:#{state.id}, closing (#775)"
        )

        {:stop, :normal, state}
    end
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
  # connection under `TENANT_STRICT_HOST` (#563). The refusal alerts (#678) —
  # from here, the decision point, not from `Tenant.fetch_org_from_connect_info/1`
  # itself.
  defp fetch_org(info) do
    # A raw transport nests connect_info one level deeper than a Phoenix.Socket.
    connect_info = info[:connect_info] || %{}

    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info) do
      {:ok, org} ->
        {:ok, org}

      :error ->
        KilnCMSWeb.TenantRefusalAlert.notify(
          :bridge,
          KilnCMSWeb.Tenant.connect_info_host(connect_info)
        )

        :error
    end
  end

  defp excerpt(value) when is_binary(value), do: value
  defp excerpt(_), do: nil

  # --- periodic re-authorization (#775) --------------------------------------

  defp schedule_reauth(state) do
    Process.send_after(self(), :reauthorize, SocketReauth.interval_ms())
    state
  end

  # Re-run `connect/1`'s authorization against a reloaded actor. The content type
  # is re-resolved too, so a type deleted or renamed under an open stream stops
  # it as surely as a document that moved out of reach.
  #
  # No timer ref is kept and none is cancelled: nothing else here triggers a
  # check, so unlike the collab room this timer never needs resetting.
  defp reauthorize(state) do
    with {:ok, actor} <- SocketReauth.reload_actor(state.actor),
         ct when not is_nil(ct) <- ContentTypes.get(state.type),
         :ok <- authorize_read(ct, state.id, actor, state.org) do
      {:ok, %{state | actor: actor}}
    else
      _refused -> :error
    end
  end
end
