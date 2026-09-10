defmodule KilnCMSWeb.ContentEditor.Session do
  @moduledoc """
  Autosave, advisory collaboration state, and presence plumbing for the
  content editor, attached as `on_mount` lifecycle hooks (#1311): the
  `handle_info` traffic for presence diffs, typing indicators, field cursors,
  peer saves and the autosave timer, plus the `handle_event` heads for field
  focus and block presence — all intercepted before
  `KilnCMSWeb.ContentEditorLive`'s own callbacks. Messages and events this
  module doesn't own pass through untouched (`{:cont, socket}`).

  The record lifecycle stays in the LiveView: actually persisting an autosave
  and adopting a peer's save re-enter it through
  `ContentEditorLive.do_autosave/1` and
  `ContentEditorLive.refresh_saved_record/1`.

  Function bodies are moved verbatim from `KilnCMSWeb.ContentEditorLive`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]
  import KilnCMSWeb.ContentEditor.Preview, only: [broadcast_preview: 1, refresh_preview: 1]
  import KilnCMSWeb.ContentEditor.Shared, only: [changeset_errors: 1, color_for: 1]

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMSWeb.ContentEditorLive
  alias KilnCMSWeb.Presence

  # Idle delay before a draft is autosaved after the last edit. Configurable so
  # tests can shorten it.
  @autosave_debounce_ms Application.compile_env(
                          :kiln_cms,
                          [:editor, :autosave_debounce_ms],
                          2_000
                        )

  # How long a "typing…" survives without another keystroke. Long enough to
  # bridge the gap between words, short enough that a closed tab stops typing
  # while the reader is still looking at the composer.
  @typing_ttl :timer.seconds(3)

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> attach_hook(:editor_session_info, :handle_info, &info/2)
     |> attach_hook(:editor_session_events, :handle_event, &event/3)}
  end

  # ── handle_info hooks ───────────────────────────────────────────────────────

  # A pop-out preview window opened or closed — flip the broadcast gate.
  defp info(
         %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "previewing:" <> _},
         socket
       ) do
    open? = Presence.previews_open?(socket.assigns.kind, socket.assigns.record.id)
    socket = assign(socket, :preview_open?, open?)
    # Catch the window up with the latest unsaved edits the moment it opens.
    if open?, do: broadcast_preview(socket)
    {:halt, socket}
  end

  defp info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    editors = Presence.editors(socket.assigns.kind, socket.assigns.record.id)
    # Drop cursors for anyone who has left, so stale focus badges disappear.
    present = MapSet.new(editors, & &1.id)
    cursors = Map.filter(socket.assigns.cursors, fn {id, _} -> MapSet.member?(present, id) end)
    socket = assign(socket, editors: editors, cursors: cursors)

    # If the departing persister left us in charge while we hold live-synced
    # edits, take over persistence by scheduling the autosave we suppressed.
    socket =
      if socket.assigns.save_state == :synced and persister?(socket),
        do: mark_dirty(socket),
        else: socket

    {:halt, socket}
  end

  # Someone is typing into a block's composer. Transient: no row, no Presence
  # entry, just an assign that expires on its own (see `note_typing/3`). Our
  # own echo is dropped — a composer that told you *you* were typing would be
  # both useless and permanently on.
  defp info({:typing, user_id, name, block_id}, socket) do
    if user_id == socket.assigns.actor.id do
      {:halt, socket}
    else
      {:halt, note_typing(socket, block_id, name)}
    end
  end

  # A typing indicator aged out. Keyed on `{block_id, name}` rather than a
  # blanket clear, so one peer falling silent doesn't erase another who is
  # still going.
  defp info({:typing_expired, block_id, name}, socket),
    do: {:halt, clear_typing(socket, block_id, name)}

  # Coarse block ops from `Collab.apply_op/4` ride the topic the editor
  # subscribes to for discussions. It applies block edits through the form and
  # the CRDT channel rather than this message, so there is nothing to do — but
  # the clause has to exist, because an unmatched `handle_info` takes the
  # editor down with a `FunctionClauseError`.
  defp info({:block_op, _op}, socket), do: {:halt, socket}

  # A collaborator focused (field set) or left (field nil) a field. Ignore our
  # own echo — we only render *other* people's cursors.
  defp info({:cursor, %{id: id} = cursor}, socket) do
    cursors =
      cond do
        id == socket.assigns.actor.id -> socket.assigns.cursors
        is_nil(cursor.field) -> Map.delete(socket.assigns.cursors, id)
        true -> Map.put(socket.assigns.cursors, id, put_color(cursor))
      end

    {:halt, assign(socket, :cursors, cursors)}
  end

  # Another editor of this item persisted a write (#694).
  #
  # In a collaborative session only the elected persister autosaves — everyone
  # else stands down, so their `assign_record/2` never runs again and their
  # `@record` and `@versions` stay at whatever they were on mount. The version
  # list silently stopped growing, and #467 turned that into a confidently wrong
  # statement: pick the creation version against **Current draft** and the modal
  # says "These two versions are identical" while the live document says
  # otherwise. That is exactly the wrong-document diff the compare path refuses
  # to show everywhere else.
  #
  # Only the read-only views derived from the SAVED record are refreshed —
  # `@record`, the title, and the version list (which drags an open comparison
  # along with it through `refresh_compare/2`). Not the form, the block children
  # or the rich-text bodies: those are this session's own in-flight edits, and in
  # a collab session the text among them lives in the shared Y.Doc rather than in
  # the record that was just written. Rebuilding the form here would throw away
  # whatever the person was typing, which is a worse bug than the one being
  # fixed.
  defp info({:record_saved, from}, socket) do
    if from == self() do
      # Our own echo; `assign_record/2` already ran. Keyed on the PID, not the
      # actor id: one person with the document open in two tabs is two sessions
      # with two stale views, and an actor-id guard silently excluded exactly
      # that case — the reported symptom reproduces for one person in two
      # windows.
      {:halt, socket}
    else
      {:halt, ContentEditorLive.refresh_saved_record(socket)}
    end
  end

  # Debounced draft autosave fired by the timer scheduled in `mark_dirty/1`.
  defp info(:autosave, socket), do: {:halt, perform_autosave(socket)}

  # This session's own `broadcast_preview/1` echoing back (or another
  # editor's) — `PreviewLive` is the intended audience, not us.
  defp info({:preview_update, _payload}, socket), do: {:halt, socket}

  # `PreviewLive`'s own "switch locale variant" broadcast (#1252 review), sent
  # on the same topic the editor subscribes to so it can pick up comments
  # written elsewhere (#946) — that pop-out's audience, not this LiveView's.
  # Left unhandled before this, a variant switch in the preview pane crashed
  # every open editor subscribed to the same content with a
  # `FunctionClauseError`; ignored here the same way `{:preview_update, _}`
  # already is.
  defp info({:preview_switch, _id}, socket), do: {:halt, socket}

  # Not ours — the LiveView's own `handle_info` heads (discussions, comment
  # reloads) take it from here.
  defp info(_message, socket), do: {:cont, socket}

  # ── handle_event hooks ──────────────────────────────────────────────────────

  defp event("field_focus", %{"field" => field}, socket) when is_binary(field) do
    broadcast_cursor(socket, field)
    {:halt, assign(socket, :self_field, field)}
  end

  defp event("field_blur", _params, socket) do
    broadcast_cursor(socket, nil)
    {:halt, assign(socket, :self_field, nil)}
  end

  # Block-scoped presence (advisory only — nothing here locks a block). The
  # browser sends the focused block on `focusin` and an explicit `nil` on
  # `focusout`, so both shapes are legitimate and each gets its own guarded
  # head rather than one that binds whatever arrives (#764). An empty string is
  # a blur too — a card rendered before its block had an id.
  defp event("presence_focus", %{"bid" => block_id}, socket)
       when is_binary(block_id) and block_id != "",
       do: {:halt, focus_block(socket, block_id)}

  defp event("presence_focus", %{"bid" => block_id}, socket)
       when is_binary(block_id) or is_nil(block_id),
       do: {:halt, focus_block(socket, nil)}

  defp event("presence_focus", _params, socket), do: {:halt, socket}

  defp event(_event, _params, socket), do: {:cont, socket}

  # ── dirty tracking + draft autosave ─────────────────────────────────────────

  # Every form-mutating event funnels through here. Drafts autosave;
  # published/in-review/archived content is changed deliberately via the
  # explicit Save button, so for those we only flip the dirty indicator
  # (and the UnsavedGuard hook warns before navigating away).
  #
  # Under active collaboration (CRDT prototype), only ONE editor persists:
  # concurrent autosaves would race the optimistic lock even though the
  # rich-text content has already converged. The persister's TipTap mirrors
  # remote CRDT edits into its own form, so its autosave covers everyone's
  # typing; the others show `:synced` instead of autosaving (their edits to
  # non-CRDT fields still save via the explicit Save button).
  def mark_dirty(socket) do
    socket = refresh_preview(socket)

    cond do
      not draft?(socket) ->
        assign(socket, :save_state, :unsaved)

      collab_active?(socket) and not persister?(socket) ->
        socket
        |> cancel_autosave_timer()
        |> assign(:save_state, :synced)

      true ->
        socket
        |> cancel_autosave_timer()
        |> assign(:autosave_timer, Process.send_after(self(), :autosave, @autosave_debounce_ms))
        # `:saving` from the moment of edit — the change is queued to autosave,
        # like a "Saving…" indicator (#136). Resolves to `:saved`/`:error` on
        # flush.
        |> assign(:save_state, :saving)
    end
  end

  # More than one editor present with the CRDT prototype on — text edits flow
  # through the shared Y.Doc rather than each session's form.
  defp collab_active?(socket),
    do: socket.assigns.collab_token != nil and length(socket.assigns.editors) > 1

  # The designated persisting editor: lowest user id among those present — the
  # same deterministic tie-break the advisory field locks use, so every
  # session elects the same one without coordination.
  defp persister?(%{assigns: %{editors: []}}), do: true

  defp persister?(socket) do
    socket.assigns.actor.id ==
      socket.assigns.editors |> Enum.map(& &1.id) |> Enum.min()
  end

  defp perform_autosave(%{assigns: %{save_state: :saving}} = socket) do
    cond do
      not draft?(socket) ->
        assign(socket, :autosave_timer, nil)

      # A lower-id editor joined between scheduling and firing — stand down;
      # they persist from here.
      collab_active?(socket) and not persister?(socket) ->
        socket |> assign(:autosave_timer, nil) |> assign(:save_state, :synced)

      true ->
        ContentEditorLive.do_autosave(socket)
    end
  end

  # Stale timer (already saved, or state moved on) — no-op.
  defp perform_autosave(socket), do: assign(socket, :autosave_timer, nil)

  # Stop autosaving and put the editor into a conflict state until the user
  # reloads. Surface a flash so a blocked Save gets immediate feedback (#137) —
  # the Save button is also disabled while `@conflict` is set.
  def flag_conflict(socket) do
    socket
    |> cancel_autosave_timer()
    |> assign(:conflict, true)
    |> assign(:save_state, :unsaved)
    |> put_flash(
      :error,
      gettext("This content changed elsewhere. Reload to get the latest before saving.")
    )
  end

  # True when a failed submit was rejected by the optimistic lock (the record
  # changed underneath us), as opposed to ordinary validation errors. The
  # `StaleRecord` error has no form-field representation, so unwrap the
  # Phoenix.HTML.Form → AshPhoenix.Form → Ash.Changeset to read its errors.
  def stale_conflict?(form), do: form |> changeset_errors() |> Enum.any?(&stale_error?/1)

  defp stale_error?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_error?/1)

  defp stale_error?(_other), do: false

  def cancel_autosave_timer(socket) do
    if ref = socket.assigns.autosave_timer, do: Process.cancel_timer(ref)
    assign(socket, :autosave_timer, nil)
  end

  defp draft?(socket), do: socket.assigns.record.state == :draft

  # ── presence helpers ────────────────────────────────────────────────────────

  defp note_typing(socket, block_id, name) do
    for_block = Map.get(socket.assigns.typing, block_id, %{})

    # One timer per {block, person}: a new keystroke replaces the old timer, so
    # the indicator rides continuous typing rather than blinking every 3s.
    case Map.get(for_block, name) do
      nil -> :noop
      old_ref -> Process.cancel_timer(old_ref)
    end

    ref = Process.send_after(self(), {:typing_expired, block_id, name}, @typing_ttl)

    assign(
      socket,
      :typing,
      Map.put(socket.assigns.typing, block_id, Map.put(for_block, name, ref))
    )
  end

  # `focus_block/5` fails harmlessly when this session isn't tracked yet (a
  # still-connecting mount, or a focus arriving after the entry went), which is
  # why its result is discarded rather than matched on: block focus is
  # advisory, and there is nothing useful to do about a miss.
  defp focus_block(socket, block_id) do
    Presence.focus_block(
      self(),
      socket.assigns.kind,
      socket.assigns.record.id,
      socket.assigns.actor.id,
      block_id
    )

    socket
  end

  # The peers focused on one block, never including ourselves — the pin is
  # there to say who *else* is looking, and an avatar of your own face beside
  # the block you are editing is noise.
  def block_viewers(editors, self_id, block_id) do
    Enum.filter(editors, &(&1.id != self_id and &1.block_id == block_id))
  end

  def typing_names(typing, block_id) do
    typing |> Map.get(block_id, %{}) |> Map.keys() |> Enum.sort()
  end

  defp clear_typing(socket, block_id, name) do
    for_block = socket.assigns.typing |> Map.get(block_id, %{}) |> Map.delete(name)

    typing =
      if for_block == %{},
        do: Map.delete(socket.assigns.typing, block_id),
        else: Map.put(socket.assigns.typing, block_id, for_block)

    assign(socket, :typing, typing)
  end

  defp put_color(%{} = cursor), do: Map.put(cursor, :color, color_for(cursor.id))

  # Tell other editors of this item which field we just focused (or left, when
  # `field` is nil). Reuses the Presence editing topic.
  defp broadcast_cursor(socket, field) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Presence.topic(socket.assigns.kind, socket.assigns.record.id),
      {:cursor,
       %{
         id: socket.assigns.actor.id,
         name: Presence.display_name(socket.assigns.actor),
         field: field
       }}
    )
  end

  # Tell the other editors of this item that the record on disk moved (#694).
  # Reuses the Presence editing topic every session already subscribes to, so
  # this costs no new subscription and no new fan-out.
  #
  # Carries the writing session's PID and nothing else. The payload is
  # deliberately not the record: a broadcast body would have to be authorized per
  # recipient, and each session re-reads through `fetch!/4` with its OWN actor
  # and tenant anyway — so a session that may no longer read the record simply
  # keeps what it has.
  def broadcast_saved(socket) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Presence.topic(socket.assigns.kind, socket.assigns.record.id),
      {:record_saved, self()}
    )

    socket
  end
end
