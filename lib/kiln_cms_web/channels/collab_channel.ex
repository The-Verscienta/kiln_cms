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
  is inert in production.

  ## Every join is authorized to WRITE the document (#655)

  The socket token names a user and nothing else, so "holds a valid token" is
  not an answer to "may join `collab:page:<uuid>`". Each join resolves the topic
  to a real document, loads it as the connecting user under the connection's
  org, and then asks whether that user may **autosave** it. Without any of this,
  an editor token was a key to every document in every organization: read the
  CRDT state, and push updates that land in the real collaborators' live
  editors.

  **The gate is the write, not the read.** They are separate scopes here —
  `ReadableContentType` against `EditableContentType` (#332) — and the read is
  strictly the wider of the two, since it also admits any published, public
  document to anybody at all. A room is bidirectional, and its terminal action
  is `KilnCMS.Collab.Crdt.Checkpoint`, which persists through `:autosave` with
  `authorize?: false`. So authorizing the *read* would have let a reader author:
  an editor scoped to `editable_types: ["post"]` could join a page's room, push
  Yjs updates, disconnect, and have the checkpoint write them under no policy at
  all. Asking `Ash.can?/3` about the very action the checkpoint performs is what
  stops the channel drifting from the policies. `KilnCMSWeb.BridgeSocket`
  authorizes the read, correctly — it is push-only.

  The doc key is rebuilt from the **resolved record**, never taken from the
  client's topic string. Ash casts uuids leniently (trimmed, case-insensitive),
  so `collab:page:0F2E…` and `collab:page:0f2e…` name one document but are two
  different keys — which would mean two authoritative docs over one record,
  each invisible to the other's editors and each overwriting the other at
  checkpoint, plus an unbounded supply of `DocServer`s for anyone who cared to
  cycle the casing.
  """
  use Phoenix.Channel

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Collab.Crdt

  # Must match SCHEMA_VSN in assets/js/collab.js. A peer whose bundle predates
  # the current ProseMirror node set is refused: y-prosemirror deletes nodes
  # its schema doesn't know from the shared doc, so one stale tab (e.g. open
  # across a deploy) would silently destroy newer content — tables, at v2 —
  # for every peer. Refused clients degrade to solo editing with autosave.
  @schema_vsn 2

  @impl true
  def join("collab:" <> key, params, socket) do
    cond do
      not Crdt.enabled?() ->
        {:error, %{reason: "collab disabled"}}

      params["vsn"] != @schema_vsn ->
        {:error, %{reason: "stale bundle"}}

      true ->
        join_authorized(key, socket)
    end
  end

  defp join_authorized(key, socket) do
    %{actor: actor, org: org} = socket.assigns

    case authorize(key, actor, org) do
      {:ok, doc_key, org_id} -> attach(doc_key, org_id, socket)
      # One reason for "no such document", "not your organization", "not yours
      # to edit" and "not a content type at all": the refusal must not answer
      # questions the caller could not already answer over HTTP.
      :error -> {:error, %{reason: "not found"}}
    end
  end

  # The topic's `<kind>:<id>` has to name a document this actor may AUTOSAVE on
  # this org — see the module docs on why the write and not the read.
  #
  # Returns the canonical doc key built from the resolved record, and the
  # record's OWN org, so the checkpoint's tenant is right by construction rather
  # than by an argument about the connection's org matching it.
  defp authorize(key, actor, org) do
    with [kind, id] <- String.split(key, ":", parts: 2),
         ct when not is_nil(ct) <- ContentTypes.get(kind, org.id),
         # `get_record!/3` raises on a miss, a forbidden read and a bad uuid
         # alike; the struct match is belt and braces, since a content domain
         # that declared `not_found_error?: false` would hand back a plain nil.
         %{} = record <- ContentTypes.get_record!(ct.type, id, actor: actor, tenant: org),
         true <- Ash.can?({record, :autosave}, actor, tenant: org) do
      {:ok, "collab:#{ct.type}:#{record.id}", record.org_id}
    else
      _refused -> :error
    end
  rescue
    # Fail closed, but say which kind of closed: a forbidden read is the control
    # working, while a pool timeout is an incident that otherwise shows up only
    # as every editor quietly dropping to solo mode (the client treats a refused
    # join as "you are alone" — see assets/js/collab.js).
    error ->
      unless ash_refusal?(error) do
        Logger.warning("Collab join check failed, refusing: #{inspect(error)}")
      end

      :error
  end

  defp ash_refusal?(%Ash.Error.Forbidden{}), do: true
  defp ash_refusal?(%Ash.Error.Invalid{}), do: true
  defp ash_refusal?(%Ash.Error.Query.NotFound{}), do: true
  defp ash_refusal?(_other), do: false

  # `ensure_server/2` can hand back a server that hits its idle shutdown before
  # `attach/1` reaches it, and a supervisor can refuse to start one at all.
  # Neither is the caller's fault and neither should crash the join.
  defp attach(doc_key, org_id, socket) do
    # `:unavailable` is the deployment's open-document ceiling (#676), already
    # logged where it is decided. It is a capacity answer, not an authorization
    # one, so it says so rather than joining the uniform "not found".
    case Crdt.ensure_server(doc_key, org_id) do
      {:ok, server} ->
        {state, peers} = Crdt.attach(server)

        {:ok, %{"state" => Base.encode64(state), "peers" => peers},
         assign(socket, :doc_server, server)}

      {:error, :unavailable} ->
        {:error, %{reason: "unavailable"}}
    end
  rescue
    error ->
      Logger.warning("Collab doc server unavailable: #{inspect(error)}")
      {:error, %{reason: "unavailable"}}
  catch
    :exit, reason ->
      Logger.warning("Collab doc server exited during attach: #{inspect(reason)}")
      {:error, %{reason: "unavailable"}}
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

  # A newcomer asking the room to re-announce its awareness states (so remote
  # carets appear immediately instead of on the next periodic refresh).
  def handle_in("awareness_request", _payload, socket) do
    broadcast_from!(socket, "awareness_request", %{})
    {:noreply, socket}
  end
end
