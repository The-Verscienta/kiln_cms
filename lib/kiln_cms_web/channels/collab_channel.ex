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

  ## The join check runs again, periodically (#775)

  `KilnCMS.Accounts.SessionEviction` (#675) drops a user's sockets from the
  actions that narrow a grant, which covers deliberate offboarding promptly.
  It cannot cover two things, and both of them fail silently:

    * **the change nobody wired an eviction into** — a new action that narrows a
      grant, a role-resource edit, a direct `Ash.update` in a migration or a mix
      task. The socket simply stays connected doing what it was allowed to do
      before, and nothing anywhere reports it;
    * **a change to the document rather than to the user** — the join that
      authorized this room is long past, so a document that was archived,
      locked, moved out of the actor's audience or unpublished under an open
      room keeps accepting updates.

  So the room re-runs `authorize/3` — the *same* function `join/3` uses, never a
  second spelling of it — on a timer, and additionally every N inbound updates.
  Both bounds live in `KilnCMSWeb.SocketReauth`, with the measurement behind the
  interval; `docs/threat-model.md` states the window an operator can rely on.
  Both are needed, and they bound different things:

    * the **timer** bounds the exposure window in wall-clock terms, which is
      what an operator reasons about ("within a minute of offboarding") and the
      only thing that covers a room that is connected but idle;
    * the **update count** is a floor under that: at typing speed a room emits
      several updates a second, so a timer alone would admit thousands of writes
      to a revoked editor before it fired. The count bounds damage done, which
      is what matters on a channel that writes.

  Only `"update"` is counted. `"awareness"` fires per caret movement and is
  relayed rather than stored, so counting it would multiply the DB work for a
  message that changes no document; the timer covers it.

  **The actor is reloaded first, and that is the whole mechanism.**
  `socket.assigns.actor` is the `User` struct resolved at *connect*, so
  re-running the policies against it would re-derive the same answer from the
  same stale role, scopes and audiences for as long as the tab stayed open —
  an inert check that looks like a working one. Everything else here is
  plumbing around that reload.

  What this catches is exactly what a *fresh join* would refuse — no more, by
  design, so the room's rule cannot drift from the join's. In particular a
  publish under an open room does not close it: `Ash.can?` on `:autosave` does
  not consult the row-level `state == :draft` filter that action carries. That
  loses collaborative prose at checkpoint and is worth fixing, on the publish
  path rather than here (#1061).

  A refusal **closes the channel** rather than pushing an error, which is what
  eviction does and what the client already handles: Phoenix sends `phx_error`
  on the channel process exiting, and `phoenix.js` retries the join on a
  backoff. Those rejoins run the full `join/3` and are refused in turn, so no
  update flows — and if the grant comes back, the room resumes on its own.
  """
  use Phoenix.Channel

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Collab.Crdt
  alias KilnCMSWeb.SocketReauth

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
      {:ok, doc_key, org_id} -> attach(key, doc_key, org_id, socket)
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
  defp attach(key, doc_key, org_id, socket) do
    # `:unavailable` is the deployment's open-document ceiling (#676), already
    # logged where it is decided. It is a capacity answer, not an authorization
    # one, so it says so rather than joining the uniform "not found".
    case Crdt.ensure_server(doc_key, org_id) do
      {:ok, server} ->
        {state, peers} = Crdt.attach(server)

        # `key` is the client's topic string, kept so the periodic check can run
        # the same `authorize/3` this join just ran; `doc_key` is the canonical
        # one derived from the resolved record, kept so that check can assert it
        # still resolves to the document this room is attached to.
        socket =
          socket
          |> assign(:doc_server, server)
          |> assign(:topic_key, key)
          |> assign(:doc_key, doc_key)
          |> schedule_reauth()

        {:ok, %{"state" => Base.encode64(state), "peers" => peers}, socket}

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
  # `is_binary(encoded)` is load-bearing, not decoration (#764). The payload is
  # client-chosen JSON, so `%{"update" => encoded}` constrains the key and never
  # the value — and `Base.decode64/2` has no clause for a list or a map.
  #
  # The blast radius is the offending client only, not the room: Phoenix gives
  # each client its own channel process per topic, and `Collab.DocServer` only
  # MONITORS its attached channels rather than linking them, so a crash just
  # drops that pid from `clients`. What the sender gets is its editor dropping
  # to a rejoin mid-edit, which is bad enough for a frame it could have ignored.
  #
  # A non-binary falls through to the catch-all below, NOT to the `else` here —
  # so an undecodable *binary* gets an error reply and a wrong-shaped payload
  # gets no reply at all. That asymmetry is deliberate but harmless either way:
  # `assets/js/collab.js` pushes updates without a `.receive`, so nothing is
  # waiting on a reply.
  def handle_in("update", %{"update" => encoded}, socket) when is_binary(encoded) do
    # The count floor (#775) runs BEFORE the update is applied, so the update
    # that trips it is refused rather than being the last one through.
    case count_update(socket) do
      {:ok, socket} ->
        with {:ok, update} <- Base.decode64(encoded),
             :ok <- Crdt.apply_update(socket.assigns.doc_server, update) do
          broadcast_from!(socket, "update", %{"update" => encoded})
          {:reply, :ok, socket}
        else
          _invalid -> {:reply, {:error, %{reason: "bad update"}}, socket}
        end

      :error ->
        {:stop, {:shutdown, :unauthorized}, socket}
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

  # Anything else is ignored rather than crashing the room (#764).
  #
  # `handle_in/3` had no catch-all, so an unknown event name — or a known one
  # whose payload arrived in a shape its clause head does not match — was a
  # `FunctionClauseError`, which terminates that client's channel process and
  # drops it to a rejoin mid-edit. (Only that client's: see the `"update"`
  # clause above on why the room survives.)
  #
  # Logged at debug rather than warn, and not replied to. A real client never
  # gets here, so the only traffic is a stale build or someone poking the
  # socket; neither is worth an error-tracker event, and an error reply would
  # tell a prober which event names exist.
  def handle_in(event, _payload, socket) do
    Logger.debug("CollabChannel ignoring unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # --- periodic re-authorization (#775) ---------------------------------------

  @impl true
  def handle_info(:reauthorize, socket) do
    case reauthorize(socket) do
      {:ok, socket} -> {:noreply, schedule_reauth(socket)}
      :error -> {:stop, {:shutdown, :unauthorized}, socket}
    end
  end

  # `use Phoenix.Channel` supplies no default `handle_info/2` — the channel
  # server only calls one if the module exports it — so defining the clause
  # above makes every other message a `FunctionClauseError` that drops this
  # client mid-edit. Same reason as the `handle_in/3` catch-all (#764).
  #
  # Nothing sends here: `Collab.DocServer` monitors its channels rather than
  # talking to them. Logged at debug because exporting `handle_info/2` at all
  # silences the "unexpected message" warning Phoenix emits for a channel that
  # exports none, and losing that signal entirely is worse than a debug line.
  def handle_info(message, socket) do
    Logger.debug("CollabChannel ignoring unexpected message #{inspect(message)}")
    {:noreply, socket}
  end

  # The timer. Cancelling first keeps a check triggered by the update floor from
  # leaving the old timer to fire moments later; a message that raced the cancel
  # and is already in the mailbox only costs one extra check.
  defp schedule_reauth(socket) do
    case socket.assigns[:reauth_timer] do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end

    socket
    |> assign(
      :reauth_timer,
      Process.send_after(self(), :reauthorize, SocketReauth.interval_ms())
    )
    |> assign(:updates_since_reauth, 0)
  end

  # The floor. Returns the socket with the counter advanced, or runs the check
  # when the count is reached — which also resets the timer, so a busy room does
  # not then check again a moment later for having also run out the clock.
  defp count_update(socket) do
    count = socket.assigns.updates_since_reauth + 1

    if count < SocketReauth.update_floor() do
      {:ok, assign(socket, :updates_since_reauth, count)}
    else
      case reauthorize(socket) do
        {:ok, socket} -> {:ok, schedule_reauth(socket)}
        :error -> :error
      end
    end
  end

  # Re-run the join's authorization against a RELOADED actor — see
  # `SocketReauth.reload_actor/1` for why the reload is the mechanism and not a
  # detail of it.
  #
  # `authorize/3` then re-reads the *document* under that actor, which is what
  # catches a change to the document rather than to the user: archived, locked,
  # unpublished or moved out of the reader's audience all come back as a refused
  # read. It is the same function `join/3` calls, so the room's rule at minute
  # ten cannot drift from its rule at minute zero — and it already fails closed,
  # logging the difference between a refusal and an outage.
  #
  # `^doc_key` pins the answer to the document this room is attached to: a topic
  # that now resolves elsewhere is refused rather than silently re-pointed,
  # since the `DocServer` it holds is keyed on the old one.
  defp reauthorize(socket) do
    %{actor: actor, org: org, topic_key: key, doc_key: doc_key} = socket.assigns

    with {:ok, %{} = actor} <- SocketReauth.reload_actor(actor),
         {:ok, ^doc_key, _org_id} <- authorize(key, actor, org) do
      {:ok, assign(socket, :actor, actor)}
    else
      _refused ->
        # One line per closed room, not per rejoin: the client's refused rejoins
        # go through `join/3`, which stays silent.
        Logger.info("Collab re-authorization refused for #{doc_key}, closing the channel (#775)")

        :error
    end
  end
end
