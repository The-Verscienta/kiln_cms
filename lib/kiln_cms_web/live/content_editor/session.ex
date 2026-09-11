defmodule KilnCMSWeb.ContentEditor.Session do
  @moduledoc """
  Autosave, advisory collaboration state, and presence plumbing for the
  content editor, attached as `on_mount` lifecycle hooks (#1311): the
  `handle_info` traffic for presence diffs, typing indicators, field locks,
  peer saves and the autosave timer, plus the `handle_event` heads for field
  focus, the lock takeover and block presence — all intercepted before
  `KilnCMSWeb.ContentEditorLive`'s own callbacks. Messages and events this
  module doesn't own pass through untouched (`{:cont, socket}`).

  ## Field locks

  Focusing an input acquires an advisory lock on that field from
  `KilnCMS.Collab.FieldLock`, the per-record process that orders every
  session's focus events; blurring releases it. The lock map it announces is
  what `@field_locks` (and the derived `@cursors` badges) render from, so a
  field held by another session is readonly here until they blur, leave, go
  idle, or are taken over.

  The takeover runs in three messages. The taker's `confirm_takeover` asks the
  lock process, which sends the holder `{:lock_flush, _, field}`; the holder
  pushes `flush_body` to its client so the rich-text hook sends whatever still
  sits in its debounce (`rich_text_body`, then `body_flushed`), persists a
  pending draft autosave (the version snapshot), and answers `flushed/2` — or
  the `:flush_fallback` timer answers for a client that does not. Then the
  lock transfers: the holder gets `{:lock_taken, _, field, by}` and a note,
  the taker gets `{:lock_granted, _, field}`, and a taker with nothing of its
  own in flight reloads the record so the flushed text is what it edits.

  The record lifecycle stays in the LiveView: actually persisting an autosave
  and adopting a peer's save re-enter it through
  `ContentEditorLive.do_autosave/1` and
  `ContentEditorLive.refresh_saved_record/1`.

  Function bodies are moved verbatim from `KilnCMSWeb.ContentEditorLive`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, put_flash: 3]
  import KilnCMSWeb.ContentEditor.Preview, only: [broadcast_preview: 1, refresh_preview: 1]

  import KilnCMSWeb.ContentEditor.Shared,
    only: [changeset_errors: 1, cursors_from_locks: 2, field_label: 1]

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Collab.FieldLock
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

  # How long a holder asked to flush waits for its client's `body_flushed`
  # before answering the lock anyway. Longer than the 300 ms `phx-debounce` /
  # rich-text push debounce, so a keystroke already typed reaches the server
  # first; well inside the lock's own 3 s flush timeout, so the lock never has
  # to give up on a healthy session.
  @flush_fallback_ms Application.compile_env(:kiln_cms, [:editor, :flush_fallback_ms], 700)

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
    # The focus badges are NOT pruned here: a lock outlives its holder's
    # presence entry by the grace period, and the badge should say so.
    socket = assign(socket, :editors, editors)

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

  # The record's lock map changed — somebody focused, blurred, left, idled
  # out, or was taken over. The full map arrives every time, so nothing here
  # has to be reconciled.
  defp info({:field_locks, topic, locks}, socket) do
    if topic == lock_topic(socket),
      do: {:halt, assign_locks(socket, locks)},
      else: {:halt, socket}
  end

  # The lock asks this holder to flush before a takeover: first the client
  # hands over what still sits in its debounce (`flush_body` → the rich-text
  # hook answers `rich_text_body` then `body_flushed`), then the pending
  # autosave persists it, only then the transfer. A client that does not
  # answer within the fallback window is not waited for.
  defp info({:lock_flush, _topic, field}, socket) do
    Process.send_after(self(), :flush_fallback, @flush_fallback_ms)

    {:halt,
     socket
     |> assign(:flushing, [field | socket.assigns.flushing])
     |> push_event("flush_body", %{field: field})}
  end

  defp info(:flush_fallback, socket) do
    if socket.assigns.flushing == [],
      do: {:halt, socket},
      else: {:halt, finish_flush(socket)}
  end

  # Somebody took a field from this session. The lock map broadcast has
  # already made it readonly; this is the note saying who, and where the text
  # this session had typed now stands. Only `:saved` earns "saved": a collab
  # non-persister's `:synced` covers the shared prose, not a title it typed.
  defp info({:lock_taken, _topic, field, by}, socket) do
    label = field_label(field)

    note =
      if socket.assigns.save_state == :saved,
        do:
          gettext("%{name} took over “%{field}”. Your changes are saved.",
            name: by.name,
            field: label
          ),
        else:
          gettext(
            "%{name} took over “%{field}”. Your unsaved changes are still in this form.",
            name: by.name,
            field: label
          )

    {:halt, put_flash(socket, :info, note)}
  end

  # The takeover this session asked for went through. The displaced holder's
  # flush persisted whatever it had (a draft autosaves), so a session with
  # nothing of its own in flight reloads the record and edits the flushed
  # text. A session with unsaved edits keeps its form — reloading would throw
  # them away — and its next save meets the optimistic lock as any stale
  # writer does. Either way the client is told to put the caret in the field.
  defp info({:lock_granted, _topic, field}, socket) do
    socket =
      if draft?(socket) and socket.assigns.save_state == :saved,
        do: ContentEditorLive.reload_latest(socket),
        else: socket

    {:halt, push_event(socket, "lock_granted", %{field: field})}
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
    {:halt, focus_field(socket, field)}
  end

  defp event("field_blur", _params, socket) do
    {:halt, blur_field(socket)}
  end

  # A click on a locked field (or its badge): open the takeover dialog for it,
  # with the holder as it stands. Nothing to ask about a field nobody else
  # holds — a stale click after the holder blurred is just a click.
  defp event("ask_takeover", %{"field" => field}, socket) when is_binary(field) do
    case Map.get(socket.assigns.field_locks, field) do
      %{pid: pid} = holder when pid != self() ->
        {:halt, assign(socket, :takeover, %{field: field, holder: holder})}

      _free_or_mine ->
        {:halt, socket}
    end
  end

  defp event("ask_takeover", _params, socket), do: {:halt, socket}

  defp event("cancel_takeover", _params, socket), do: {:halt, assign(socket, :takeover, nil)}

  # The dialog closes at once either way: `:ok` means the field was free (or
  # its holder gone) and the lock map broadcast already made it ours;
  # `:pending` means the holder is flushing and `{:lock_granted, _, _}` follows.
  defp event("confirm_takeover", _params, socket) do
    case socket.assigns.takeover do
      nil ->
        {:halt, socket}

      %{field: field} ->
        FieldLock.takeover(lock_topic(socket), field, lock_user(socket), self())
        {:halt, assign(socket, :takeover, nil)}
    end
  end

  # The rich-text hook's answer to `flush_body`: its `rich_text_body` (if it
  # had one pending) is already in, so the flush can settle now rather than
  # on the fallback timer.
  defp event("body_flushed", %{"field" => field}, socket) when is_binary(field) do
    if field in socket.assigns.flushing,
      do: {:halt, finish_flush(socket)},
      else: {:halt, socket}
  end

  # A keystroke: activity for the idle rule and the takeover dialog's
  # "is typing right now" — then on to the LiveView's own handler.
  defp event(event, _params, socket) when event in ["validate", "rich_text_body"] do
    {:cont, touch_lock(socket)}
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

  # Every form-mutating event funnels through here. Drafts autosave. A LIVE
  # document autosaves its text too — into the working copy, never the
  # published columns (docs/working-copy.md) — while its settings are changed
  # deliberately via the explicit Save button and go live at once; `scope`
  # says which kind of edit this was (`:text` is the title or the body,
  # `:settings` everything else). In-review/archived content only flips the
  # dirty indicator (and the UnsavedGuard hook warns before navigating away).
  #
  # Under active collaboration (CRDT prototype), only ONE editor persists:
  # concurrent autosaves would race the optimistic lock even though the
  # rich-text content has already converged. The persister's TipTap mirrors
  # remote CRDT edits into its own form, so its autosave covers everyone's
  # typing; the others show `:synced` instead of autosaving (their edits to
  # non-CRDT fields still save via the explicit Save button).
  def mark_dirty(socket, scope \\ :text) do
    socket = refresh_preview(socket)

    cond do
      published?(socket) and scope == :settings ->
        assign(socket, :settings_dirty?, true)

      not autosaves?(socket) ->
        assign(socket, :save_state, :unsaved)

      collab_active?(socket) and not persister?(socket) ->
        socket
        |> cancel_autosave_timer()
        |> assign(:save_state, :synced)

      true ->
        socket
        |> cancel_autosave_timer()
        |> assign(:autosave_timer, Process.send_after(self(), :autosave, @autosave_debounce_ms))
        # `:pending` from the moment of edit: the change is queued behind the
        # debounce, and the indicator keeps showing the last save's stamp
        # rather than a "Saving…" that no request is behind yet. Resolves to
        # `:saved`/`:error` when the flush lands.
        |> assign(:save_state, :pending)
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

  defp perform_autosave(%{assigns: %{save_state: :pending}} = socket) do
    cond do
      not autosaves?(socket) ->
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
  defp published?(socket), do: socket.assigns.record.state == :published

  # The two states whose text autosaves: a draft into its own row, a live
  # document into its working copy (`ContentEditorLive.do_autosave/1` picks).
  defp autosaves?(socket), do: draft?(socket) or published?(socket)

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

  # ── field locks ─────────────────────────────────────────────────────────────

  # The lock map, and the badges derived from it, in one move — so the two
  # can never disagree about who holds what.
  def assign_locks(socket, locks) do
    socket
    |> assign(:field_locks, locks)
    |> assign(:cursors, cursors_from_locks(locks, self()))
  end

  def lock_topic(socket), do: Presence.topic(socket.assigns.kind, socket.assigns.record.id)

  defp lock_user(socket),
    do: %{id: socket.assigns.actor.id, name: Presence.display_name(socket.assigns.actor)}

  # Focus: ask for the field. A `{:held, _}` answer changes nothing here — the
  # input is readonly through the lock map already, and the dialog is opened
  # by a click, not by focus, so tabbing through a locked field stays quiet.
  # A focus that arrives without the blur before it (a browser quirk, a
  # dropped event) still lets go of the previous field first.
  defp focus_field(socket, field) do
    socket = if socket.assigns.self_field in [nil, field], do: socket, else: blur_field(socket)
    FieldLock.acquire(lock_topic(socket), field, lock_user(socket), self())
    assign(socket, :self_field, field)
  end

  defp blur_field(%{assigns: %{self_field: nil}} = socket), do: socket

  defp blur_field(socket) do
    FieldLock.release(lock_topic(socket), socket.assigns.self_field, self())
    assign(socket, :self_field, nil)
  end

  # A keystroke in the focused field. Holding it: a ping, so the idle clock
  # restarts and the takeover dialog says "typing right now". Not holding it
  # and nobody else does either (the idle rule let it go while the tab sat
  # there, and the person is back): take it again. Held by somebody else: the
  # input is readonly and this keystroke is a stale event — nothing to do.
  defp touch_lock(%{assigns: %{self_field: nil}} = socket), do: socket

  defp touch_lock(socket) do
    field = socket.assigns.self_field

    case Map.get(socket.assigns.field_locks, field) do
      %{pid: pid} when pid == self() -> FieldLock.ping(lock_topic(socket), self())
      nil -> FieldLock.acquire(lock_topic(socket), field, lock_user(socket), self())
      _held_by_other -> :ok
    end

    socket
  end

  # Settle every flush in flight: persist a pending draft autosave (the
  # version snapshot a takeover promises), then tell the lock. Only a draft
  # with an autosave queued (`:pending`) has anything to persist — published
  # content saves by hand, and a collab non-persister's text lives in the
  # shared document — so for those the flush is the client push alone.
  defp finish_flush(socket) do
    fields = socket.assigns.flushing
    socket = assign(socket, :flushing, [])

    socket =
      if draft?(socket) and socket.assigns.save_state == :pending,
        do: socket |> cancel_autosave_timer() |> ContentEditorLive.do_autosave(),
        else: socket

    Enum.each(fields, &FieldLock.flushed(lock_topic(socket), &1))
    socket
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
