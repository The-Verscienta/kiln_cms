defmodule KilnCMSWeb.ContentEditorLive do
  @moduledoc """
  Block editor for a single content record of **any** content type. The type
  comes from the `:type` param on `/editor/content/:type/:id` (or the
  `live_action` on the legacy `/editor/pages|posts/:id` routes) and is resolved
  through `KilnCMS.CMS.ContentTypes`, so types generated with
  `mix kiln.gen.content` are editable here with no extra wiring.

  Edit title/slug (+ excerpt where the type has one) and the typed block tree —
  blocks are authored as native `Ash.Type.Union` member sub-forms (Kiln v2), with
  per-member fields generated from each block's `Kiln.Block` DSL (add/remove/reorder
  via the `Sortable` hook, **TipTap rich text** for `rich_text`). A **side-by-side
  live preview** renders through the same typed serializers as firing/delivery
  (preview parity). Plus SEO & scheduling, version history + restore, and the
  publishing workflow. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.EditorTelemetry
  alias KilnCMSWeb.Presence

  # Preferred display order for the block palette; any block type registered
  # beyond these is appended automatically (the palette is registry-driven, so
  # adding a `Kiln.Block` module needs no editor change).
  @type_order ~w(rich_text heading quote image embed divider custom)

  # Bound the media picker window loaded on mount (newest first) so a large
  # library can't grow each open editor's heap without limit.
  @max_media 500

  # Idle delay before a draft is autosaved after the last edit. Configurable so
  # tests can shorten it.
  @autosave_debounce_ms Application.compile_env(
                          :kiln_cms,
                          [:editor, :autosave_debounce_ms],
                          2_000
                        )

  # Stable per-collaborator colors for live focus cursors. Static class strings
  # so Tailwind keeps them.
  @cursor_colors ~w(
    bg-rose-500 bg-amber-500 bg-emerald-500 bg-sky-500 bg-violet-500 bg-pink-500
  )

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case content_kind(params, socket) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/editor")}

      kind ->
        actor = socket.assigns.current_user
        record = fetch!(kind, id, actor)

        if connected?(socket) do
          topic = Presence.track_editor(self(), kind, id, actor)
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
        end

        {:ok,
         socket
         |> assign(:kind, kind)
         |> assign(:has_excerpt, ContentTypes.get!(kind).excerpt?)
         |> assign(:actor, actor)
         |> assign(:block_types, block_types())
         |> assign(:editors, Presence.editors(kind, id))
         |> assign(:cursors, %{})
         |> assign(:self_field, nil)
         # Debounced draft autosave: pending timer ref + status indicator state.
         |> assign(:autosave_timer, nil)
         |> assign(:save_state, :saved)
         # Set when an optimistic-lock conflict blocks saving until reload.
         |> assign(:conflict, false)
         # Media picker (image blocks) + relationship pickers (taxonomy, siblings).
         # `picking` is nil (closed), a block index (fill that image block), or
         # `:new` (insert a new image block — opened from the editor chrome).
         |> assign(:picking, nil)
         |> assign(:media_query, "")
         |> assign(
           :media,
           CMS.list_media_items!(
             actor: actor,
             query: [sort: [inserted_at: :desc], limit: @max_media]
           )
         )
         |> assign(:categories, CMS.list_categories!(actor: actor))
         |> assign(:tags, CMS.list_tags!(actor: actor))
         |> assign(:siblings, siblings(kind, id, actor))
         |> assign_record(record)}
    end
  end

  # The content type being edited: from the `:type` param on the generic
  # `/editor/content/:type/:id` route, or the `live_action` on the legacy
  # `/editor/pages|posts/:id` routes. Returns nil for an unknown type.
  defp content_kind(%{"type" => type}, _socket) do
    case ContentTypes.get(type) do
      nil -> nil
      ct -> ct.type
    end
  end

  defp content_kind(_params, socket), do: socket.assigns.live_action

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    editors = Presence.editors(socket.assigns.kind, socket.assigns.record.id)
    # Drop cursors for anyone who has left, so stale focus badges disappear.
    present = MapSet.new(editors, & &1.id)
    cursors = Map.filter(socket.assigns.cursors, fn {id, _} -> MapSet.member?(present, id) end)
    {:noreply, assign(socket, editors: editors, cursors: cursors)}
  end

  # A collaborator focused (field set) or left (field nil) a field. Ignore our
  # own echo — we only render *other* people's cursors.
  def handle_info({:cursor, %{id: id} = cursor}, socket) do
    cursors =
      cond do
        id == socket.assigns.actor.id -> socket.assigns.cursors
        is_nil(cursor.field) -> Map.delete(socket.assigns.cursors, id)
        true -> Map.put(socket.assigns.cursors, id, put_color(cursor))
      end

    {:noreply, assign(socket, :cursors, cursors)}
  end

  # Debounced draft autosave fired by the timer scheduled in `validate`.
  def handle_info(:autosave, socket), do: {:noreply, autosave(socket)}

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> assign(:form, build_form(record, socket.assigns.actor))
    |> load_versions()
  end

  defp load_versions(socket) do
    opts = [
      actor: socket.assigns.actor,
      query: [
        filter: [version_source_id: socket.assigns.record.id],
        sort: [version_inserted_at: :desc],
        limit: 15
      ]
    ]

    assign(socket, :versions, list_versions(socket.assigns.kind, opts))
  end

  defp build_form(record, actor) do
    # Blocks are authored as native `Ash.Type.Union` member sub-forms (Kiln v2):
    # each block sub-form is a typed block resource (Heading/Image/…), so fields
    # bind straight to the typed attributes.
    record
    |> AshPhoenix.Form.for_update(:update, actor: actor, forms: [auto?: true])
    |> to_form()
  end

  # The typed block module backing a block sub-form (its union member resource).
  # `inputs_for` yields a Phoenix.HTML.Form wrapping an AshPhoenix.Form; the
  # preview path holds the AshPhoenix.Form directly.
  defp block_member(%Phoenix.HTML.Form{source: source}), do: block_member(source)
  defp block_member(%AshPhoenix.Form{resource: resource}), do: resource

  # --- generic dispatch to the per-kind code interfaces (via the registry) ---

  defp fetch!(kind, id, actor) do
    ContentTypes.get_record!(kind, id,
      actor: actor,
      load: [:category, :featured_image, :tags, related_name(kind)]
    )
  end

  # Other content of the same kind, for the "related content" picker. Bounded to
  # the same window as the media picker so a large library can't blow up the mount.
  defp siblings(kind, id, actor) do
    kind
    |> ContentTypes.list!(actor: actor, query: [sort: [updated_at: :desc], limit: @max_media])
    |> Enum.reject(&(&1.id == id))
  end

  # The self-referential m2m relationship/argument names follow the convention
  # `related_<type>s` / `related_<type>_ids`. `to_existing_atom` (rather than
  # interpolating a new atom) keeps this safe even though `kind` originates from
  # a route param — it's already registry-validated, and the atoms are defined
  # at compile time by `KilnCMS.CMS.Content`.
  defp related_name(kind), do: String.to_existing_atom("related_#{kind}s")
  defp related_field(kind), do: String.to_existing_atom("related_#{kind}_ids")
  defp related_current(kind, record), do: Map.get(record, related_name(kind))

  # Current ids for a (possibly unloaded) relationship list.
  defp current_ids(records) when is_list(records), do: Enum.map(records, & &1.id)
  defp current_ids(_), do: []

  # Selected values for a multi-select: the in-progress form value once the user
  # has touched it, otherwise the record's currently-linked ids. Without this
  # fallback an untouched submit would send an empty list and wipe the links.
  defp selected_ids(form, field, fallback) do
    case form[field].value do
      nil -> fallback
      list when is_list(list) -> list
      other -> [other]
    end
  end

  defp list_versions(kind, opts), do: ContentTypes.list_versions!(kind, opts)

  defp restore_version(kind, record, vid, actor),
    do: ContentTypes.restore_version(kind, record, vid, actor: actor)

  defp do_workflow(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor)

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    socket = assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
    broadcast_preview(socket)
    {:noreply, schedule_autosave(socket)}
  end

  def handle_event("field_focus", %{"field" => field}, socket) do
    broadcast_cursor(socket, field)
    {:noreply, assign(socket, :self_field, field)}
  end

  def handle_event("field_blur", _params, socket) do
    broadcast_cursor(socket, nil)
    {:noreply, assign(socket, :self_field, nil)}
  end

  # Open the media browser to fill a specific image block.
  def handle_event("open_picker", %{"index" => index}, socket),
    do: {:noreply, assign(socket, :picking, String.to_integer(index))}

  # Open the media browser from the editor chrome to insert a *new* image block.
  def handle_event("open_media_browser", _params, socket),
    do: {:noreply, assign(socket, :picking, :new)}

  def handle_event("close_picker", _params, socket),
    do: {:noreply, reset_picker(socket)}

  # Live-filter the browser grid as the user types.
  def handle_event("search_media", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :media_query, q)}

  # Insert a library image as a brand-new image block (browser opened from the
  # editor chrome): the URL becomes the block content and its id is stashed in
  # `data` so delivery can build srcset.
  def handle_event("pick_image", %{"index" => "new", "id" => media_id, "url" => url}, socket) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => "image", "url" => url, "media_id" => media_id}
      )

    socket = socket |> assign(:form, form) |> reset_picker()
    broadcast_preview(socket)
    {:noreply, socket}
  end

  # Insert a library image into the existing image block at `index`.
  def handle_event("pick_image", %{"index" => index, "id" => media_id, "url" => url}, socket) do
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> put_block(index, %{"url" => url, "media_id" => media_id})

    socket =
      socket
      |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
      |> reset_picker()

    broadcast_preview(socket)
    {:noreply, socket}
  end

  def handle_event("add_block", %{"type" => type}, socket) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => type}
      )

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("remove_block", %{"path" => path}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.remove_form(socket.assigns.form, path))}
  end

  def handle_event("reorder", %{"order" => order}, socket) do
    form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)
    {:noreply, assign(socket, :form, form)}
  end

  # Keyboard-accessible alternative to drag-and-drop reordering (#171): swap a
  # block with its neighbour and announce the new position to screen readers.
  def handle_event("move_block", %{"index" => index, "dir" => dir}, socket) do
    i = String.to_integer(index)
    count = blocks_count(socket.assigns.form)
    j = if dir == "up", do: i - 1, else: i + 1

    if j >= 0 and j < count do
      order =
        0..(count - 1)
        |> Enum.map(&to_string/1)
        |> swap_at(i, j)

      form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)

      {:noreply,
       socket
       |> assign(:form, form)
       |> assign(
         :moved_announcement,
         gettext("Moved block to position %{pos} of %{count}", pos: j + 1, count: count)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"form" => params}, socket) do
    socket = cancel_autosave_timer(socket)

    result =
      EditorTelemetry.span(:save, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(socket.assigns.form, params: params)
      end)

    case result do
      {:ok, record} ->
        # Re-fetch so the relationship pickers reflect the saved links (the
        # submit result doesn't carry loaded relationships).
        reloaded = fetch!(socket.assigns.kind, record.id, socket.assigns.actor)

        {:noreply,
         socket
         |> assign_record(reloaded)
         |> assign(:save_state, :saved)
         |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        if stale_conflict?(form) do
          {:noreply, flag_conflict(socket)}
        else
          {:noreply,
           socket
           |> assign(:form, form)
           |> put_flash(:error, gettext("Please fix the errors below."))}
        end
    end
  end

  # Discard local changes and reload the latest saved version, clearing the
  # conflict. (The simplest safe resolution — a merge UI is future work.)
  def handle_event("reload_conflict", _params, socket) do
    record = fetch!(socket.assigns.kind, socket.assigns.record.id, socket.assigns.actor)

    {:noreply,
     socket
     |> assign_record(record)
     |> assign(:conflict, false)
     |> assign(:save_state, :saved)
     |> put_flash(:info, gettext("Reloaded the latest version."))}
  end

  def handle_event("workflow", %{"action" => action}, socket) do
    {:noreply, run_workflow(socket, action)}
  end

  def handle_event("restore", %{"version_id" => version_id}, socket) do
    result =
      restore_version(
        socket.assigns.kind,
        socket.assigns.record,
        version_id,
        socket.assigns.actor
      )

    case result do
      {:ok, record} ->
        {:noreply,
         socket |> assign_record(record) |> put_flash(:info, gettext("Restored that version."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't restore that version."))}
    end
  end

  defp run_workflow(socket, action) when action in ~w(submit return publish unpublish archive) do
    # `publish` gets its own event; the rest share `:workflow` (tagged by action)
    # so the publish hot path is isolated in the metrics.
    {event, meta} =
      if action == "publish",
        do: {:publish, %{kind: socket.assigns.kind}},
        else: {:workflow, %{kind: socket.assigns.kind, action: action}}

    result =
      EditorTelemetry.span(event, meta, fn ->
        do_workflow(socket.assigns.kind, action, socket.assigns.record, socket.assigns.actor)
      end)

    case result do
      {:ok, record} ->
        socket
        |> cancel_autosave_timer()
        |> assign_record(record)
        |> assign(:save_state, :saved)
        |> put_flash(:info, gettext("Updated to %{state}.", state: record.state))

      _ ->
        put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  defp run_workflow(socket, _action), do: socket

  # --- draft autosave --------------------------------------------------------

  # Only drafts autosave; published/in-review/archived content is changed
  # deliberately via the explicit Save button. Each edit (re)starts the idle
  # timer, so we save once the editor pauses rather than on every keystroke.
  defp schedule_autosave(socket) do
    if draft?(socket) do
      socket
      |> cancel_autosave_timer()
      |> assign(:autosave_timer, Process.send_after(self(), :autosave, @autosave_debounce_ms))
      |> assign(:save_state, :unsaved)
    else
      socket
    end
  end

  defp autosave(%{assigns: %{save_state: :unsaved}} = socket) do
    if draft?(socket) do
      socket = assign(socket, :autosave_timer, nil)

      # Submit the current edits through the dedicated `:autosave` action (kept
      # distinct from the explicit Save's `:update` so its PaperTrail versions
      # are tagged and coalesced). A throwaway form mirrors the live one's
      # params, leaving `socket.assigns.form` intact for the Save button.
      autosave_form =
        AshPhoenix.Form.for_update(socket.assigns.record, :autosave,
          actor: socket.assigns.actor,
          forms: [auto?: true]
        )

      result =
        EditorTelemetry.span(:autosave, %{kind: socket.assigns.kind}, fn ->
          AshPhoenix.Form.submit(autosave_form,
            params: AshPhoenix.Form.params(socket.assigns.form)
          )
        end)

      case result do
        {:ok, record} ->
          reloaded = fetch!(socket.assigns.kind, record.id, socket.assigns.actor)
          socket |> assign_record(reloaded) |> assign(:save_state, :saved)

        {:error, form} ->
          handle_autosave_error(socket, form)
      end
    else
      assign(socket, :autosave_timer, nil)
    end
  end

  # Nothing pending (a stale timer, or already saved) — no-op.
  defp autosave(socket), do: assign(socket, :autosave_timer, nil)

  # Someone else saved first → stop autosaving and surface the conflict rather
  # than retrying (which would keep losing). Otherwise leave the inline
  # validation errors in place and keep the draft unsaved so the next edit
  # reschedules a retry.
  defp handle_autosave_error(socket, form) do
    if stale_conflict?(form),
      do: flag_conflict(socket),
      else: assign(socket, :save_state, :unsaved)
  end

  # Stop autosaving and put the editor into a conflict state until the user
  # reloads.
  defp flag_conflict(socket) do
    socket
    |> cancel_autosave_timer()
    |> assign(:conflict, true)
    |> assign(:save_state, :unsaved)
  end

  # True when a failed submit was rejected by the optimistic lock (the record
  # changed underneath us), as opposed to ordinary validation errors. The
  # `StaleRecord` error has no form-field representation, so unwrap the
  # Phoenix.HTML.Form → AshPhoenix.Form → Ash.Changeset to read its errors.
  defp stale_conflict?(form), do: form |> changeset_errors() |> Enum.any?(&stale_error?/1)

  defp changeset_errors(%Phoenix.HTML.Form{source: source}), do: changeset_errors(source)
  defp changeset_errors(%AshPhoenix.Form{source: source}), do: changeset_errors(source)
  defp changeset_errors(%Ash.Changeset{errors: errors}), do: errors
  defp changeset_errors(_other), do: []

  defp stale_error?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_error?/1)

  defp stale_error?(_other), do: false

  defp cancel_autosave_timer(socket) do
    if ref = socket.assigns.autosave_timer, do: Process.cancel_timer(ref)
    assign(socket, :autosave_timer, nil)
  end

  defp draft?(socket), do: socket.assigns.record.state == :draft

  # Number of block sub-forms currently in the form (#171 keyboard reorder).
  defp blocks_count(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # Swap the two list elements at positions `i` and `j`.
  defp swap_at(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  # Push the current title + blocks to any open decoupled preview windows.
  defp broadcast_preview(socket) do
    form = socket.assigns.form

    payload = %{
      title: AshPhoenix.Form.value(form, :title) || "",
      excerpt: socket.assigns.has_excerpt && AshPhoenix.Form.value(form, :excerpt),
      blocks: preview_blocks(form)
    }

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic(socket.assigns.kind, socket.assigns.record.id),
      {:preview_update, payload}
    )

    socket
  end

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

  defp put_color(%{} = cursor), do: Map.put(cursor, :color, color_for(cursor.id))

  # Merge `fields` into the block at `index`, tolerating params where blocks are
  # an indexed map (the usual LiveView shape) or a list.
  defp put_block(params, index, fields) do
    Map.update(params, "blocks", %{to_string(index) => fields}, fn
      blocks when is_map(blocks) ->
        Map.update(blocks, to_string(index), fields, &Map.merge(&1, fields))

      blocks when is_list(blocks) ->
        List.update_at(blocks, String.to_integer(index), &Map.merge(&1 || %{}, fields))
    end)
  end

  # The media id currently on an image block sub-form, if any.
  defp media_id_of(bf), do: bf[:media_id].value

  # Safe `src` for the image-block preview: a pasted URL is untrusted, so it must
  # clear the same scheme allowlist as delivery before we echo it back. Returns
  # nil (image hidden) for rejected schemes like `javascript:`/`data:`.
  defp safe_preview_src(url), do: KilnCMS.HTMLSanitizer.safe_image_src(url)

  defp reset_picker(socket), do: socket |> assign(:picking, nil) |> assign(:media_query, "")

  # Substring filter over filename/alt/caption — instant, no DB round-trip, and
  # matches partial input as the user types (the library's `:search` action is
  # whole-word tsquery, less forgiving for a live picker).
  defp filter_media(media, ""), do: media

  defp filter_media(media, query) do
    q = String.downcase(query)

    Enum.filter(media, fn item ->
      [item.filename, item.alt, item.caption]
      |> Enum.any?(fn v -> v && String.contains?(String.downcase(v), q) end)
    end)
  end

  # The `phx-value-index` for a pick button: "new" inserts a fresh image block
  # (browser opened from the chrome), an integer fills that existing block.
  defp pick_index(:new), do: "new"
  defp pick_index(index), do: index

  attr :block_types, :list, required: true

  # Notion-style slash-command block inserter (#29). The trigger button (or the
  # `/` shortcut, handled by the `BlockInserter` JS hook) opens a filterable,
  # keyboard-navigable menu listing every registered block type. Each option is a
  # real `add_block` button, so it works without JS and is directly testable;
  # the hook layers on filtering, arrow-key navigation, and ARIA wiring.
  defp block_inserter(assigns) do
    ~H"""
    <div id="block-inserter" phx-hook="BlockInserter" class="relative">
      <button
        type="button"
        data-inserter-trigger
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls="block-inserter-list"
        class="inline-flex items-center gap-1.5 rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add block")}
        <kbd class="ml-1 rounded border border-base-content/20 px-1.5 text-xs opacity-60">/</kbd>
      </button>

      <div
        data-inserter-menu
        hidden
        class="absolute left-0 z-20 mt-1 w-72 rounded-lg border border-base-content/15 bg-base-100 p-1 shadow-lg"
      >
        <div class="p-1">
          <input
            type="text"
            data-inserter-search
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="true"
            aria-controls="block-inserter-list"
            placeholder={gettext("Filter blocks…")}
            class="w-full rounded border border-base-content/20 bg-base-100 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-primary/40"
          />
        </div>

        <ul
          id="block-inserter-list"
          role="listbox"
          aria-label={gettext("Insert block")}
          class="max-h-72 overflow-y-auto"
        >
          <li :for={bt <- @block_types} role="presentation" data-inserter-option data-label={bt.label}>
            <button
              type="button"
              id={"block-inserter-item-#{bt.type}"}
              role="option"
              aria-selected="false"
              tabindex="-1"
              phx-click="add_block"
              phx-value-type={bt.type}
              data-inserter-item
              class="flex w-full items-start gap-2 rounded px-2 py-1.5 text-left text-sm hover:bg-base-200 aria-selected:bg-base-200"
            >
              <.icon name={bt.icon} class="mt-0.5 size-5 shrink-0 opacity-70" />
              <span class="min-w-0">
                <span class="block font-medium">{bt.label}</span>
                <span class="block truncate text-xs opacity-60">{bt.description}</span>
              </span>
            </button>
          </li>
        </ul>

        <p data-inserter-empty hidden class="px-3 py-2 text-sm opacity-60">
          {gettext("No blocks match.")}
        </p>
      </div>
    </div>
    """
  end

  attr :index, :any, required: true
  attr :media, :list, required: true
  attr :query, :string, required: true

  # Full media-library browser modal. Reachable from the editor chrome (to
  # insert a new image block, `index = :new`) and from each image block (to fill
  # that block, `index` = its integer index). Browse + search + insert.
  defp image_picker(assigns) do
    assigns = assign(assigns, :visible, filter_media(assigns.media, assigns.query))

    ~H"""
    <div class="fixed inset-0 z-50" phx-window-keydown="close_picker" phx-key="Escape">
      <div class="absolute inset-0 bg-black/40" phx-click="close_picker" aria-hidden="true"></div>
      <div
        id="image-picker-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="image-picker-title"
        tabindex="-1"
        class="absolute left-1/2 top-1/2 max-h-[80vh] w-full max-w-2xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg bg-base-100 p-5 shadow-xl"
      >
        <div class="mb-3 flex items-center justify-between gap-4">
          <h2 id="image-picker-title" class="text-lg font-medium">
            {if @index == :new,
              do: gettext("Insert image from library"),
              else: gettext("Choose an image")}
          </h2>
          <button
            type="button"
            phx-click="close_picker"
            aria-label={gettext("Close")}
            class="text-base-content/50 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <form :if={@media != []} id="media-browser-filter" phx-change="search_media" class="mb-3">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search by filename, alt or caption")}
            phx-debounce="150"
            autocomplete="off"
            class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
          />
        </form>

        <p :if={@media == []} class="text-sm text-base-content/60">
          No media yet — upload some in the <.link navigate={~p"/media"} class="underline">media library</.link>.
        </p>
        <p :if={@media != [] and @visible == []} class="text-sm text-base-content/60">
          {gettext("No media matches “%{query}”.", query: @query)}
        </p>

        <div :if={@visible != []} class="grid grid-cols-3 gap-3 sm:grid-cols-4">
          <button
            :for={item <- @visible}
            type="button"
            phx-click="pick_image"
            phx-value-index={pick_index(@index)}
            phx-value-id={item.id}
            phx-value-url={item.url}
            title={item.filename}
            class="group overflow-hidden rounded border border-base-content/10 hover:ring-2 hover:ring-primary"
          >
            <img
              src={item.url}
              alt={item.alt || item.filename}
              loading="lazy"
              class="aspect-square w-full object-cover"
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp color_for(id),
    do: Enum.at(@cursor_colors, rem(:erlang.phash2(id), length(@cursor_colors)))

  # Focus-tracking attributes for an input; `field` keys the cursor badge.
  # `phx-debounce` coalesces the per-keystroke `validate` events (and the
  # `broadcast_preview/1` they trigger) so fast typing with a pop-out preview
  # open doesn't flood PubSub / LiveView diffing.
  defp field_attrs(field) do
    %{
      "phx-focus" => "field_focus",
      "phx-blur" => "field_blur",
      "phx-value-field" => field,
      "phx-debounce" => "300"
    }
  end

  # The set of fields soft-locked *for us* right now. A field is contended when
  # one or more editors are focused on it; the editor with the lowest id owns it
  # (a deterministic tie-break, so two simultaneous focusers never lock each
  # other out). We hold the lock only on fields we don't own. The lock is
  # advisory — the input goes readonly but still submits — and releases the
  # moment the owner blurs or leaves.
  defp locked_fields(cursors, self_field, self_id) do
    cursors
    |> Enum.group_by(fn {_id, c} -> c.field end, fn {id, _c} -> id end)
    |> Enum.flat_map(fn {field, other_ids} ->
      # We own `field` only if we're focused there and outrank everyone else.
      owned? = field == self_field and Enum.all?(other_ids, &(self_id < &1))
      if owned?, do: [], else: [field]
    end)
    |> MapSet.new()
  end

  defp field_locked?(locked, field), do: MapSet.member?(locked, field)

  defp lock_ring(locked, field) do
    if field_locked?(locked, field), do: "rounded-md ring-2 ring-warning/50", else: ""
  end

  # Effective blocks (data + unsaved edits) from the form, for the live preview.
  # Thin `%{type, content}` maps — used by the decoupled (pop-out) preview window.
  # Thin `%{type, content}` block maps for the decoupled (pop-out) preview, which
  # renders them through the shared `BlockComponents`. Routed through the SAME
  # sanitized typed→legacy pipeline as the inline preview (`preview_block_maps`)
  # and `PreviewLive.content_blocks/1`, so rich-text edits surface as rendered
  # `legacy_html` rather than the empty Portable Text `body` field that a
  # primary-field lookup would pick (#134).
  defp preview_blocks(form) do
    form
    |> preview_block_maps()
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> Enum.map(&%{type: to_string(&1.type), content: &1.content})
  end

  # Inline preview rendered through the **same typed serializers that firing
  # uses** (Kiln v2) — what you preview is exactly what publishes/delivers. Full
  # block maps (incl. `data`/`children`) go through the legacy→typed bridge and
  # the per-block `render(:web)`. Rich-text HTML is sanitized first (mirroring the
  # save-time `SanitizeBlocks` change), so the rendered output is safe.
  # sobelow_skip ["XSS.Raw"]
  defp preview_html(form) do
    form
    |> preview_block_maps()
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(&KilnCMS.Blocks.render(&1, :web))
    |> Phoenix.HTML.raw()
  end

  defp preview_block_maps(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      forms when is_list(forms) -> Enum.map(forms, &block_full_map/1)
      _ -> []
    end
  end

  # A typed block map (string keys, `_type`) read from a union member sub-form,
  # for the inline typed preview. Rich-text HTML is sanitized (unsaved edits
  # aren't sanitized until save).
  defp block_full_map(%AshPhoenix.Form{} = subform) do
    mod = block_member(subform)

    mod
    |> Kiln.Block.Info.fields()
    |> Map.new(fn field ->
      {to_string(field.name), AshPhoenix.Form.value(subform, field.name)}
    end)
    |> Map.put("_type", to_string(Kiln.Block.Info.name(mod)))
    |> sanitize_preview_block()
  end

  defp sanitize_preview_block(%{"_type" => "rich_text"} = map),
    do: Map.update(map, "legacy_html", nil, &KilnCMS.HTMLSanitizer.sanitize_rich_text/1)

  defp sanitize_preview_block(map), do: map

  # ── Registry-driven palette + DSL-metadata-driven block fields (Kiln v2) ──

  # The block palette: registered block types in a friendly order, with any new
  # ones appended — so adding a `Kiln.Block` module surfaces here automatically.
  # Each entry carries display metadata for the slash-command inserter menu.
  defp block_types do
    available = KilnCMS.Blocks.registry() |> Map.keys() |> Enum.map(&to_string/1)
    ordered = Enum.filter(@type_order, &(&1 in available))

    (ordered ++ Enum.sort(available -- ordered))
    |> Enum.map(fn type ->
      %{
        type: type,
        label: dsl_label(type),
        icon: block_icon(type),
        description: block_description(type)
      }
    end)
  end

  # Heroicon for a block type in the inserter menu (generic fallback for any
  # registry-discovered type without a bespoke icon).
  defp block_icon("rich_text"), do: "hero-document-text"
  defp block_icon("heading"), do: "hero-hashtag"
  defp block_icon("quote"), do: "hero-chat-bubble-bottom-center-text"
  defp block_icon("image"), do: "hero-photo"
  defp block_icon("embed"), do: "hero-code-bracket"
  defp block_icon("divider"), do: "hero-minus"
  defp block_icon("portable_text"), do: "hero-bars-3"
  defp block_icon("custom"), do: "hero-puzzle-piece"
  defp block_icon(_), do: "hero-squares-2x2"

  # One-line description shown under the label in the inserter menu.
  defp block_description("rich_text"), do: gettext("Formatted text with bold, italic, and lists")
  defp block_description("heading"), do: gettext("Section title")
  defp block_description("quote"), do: gettext("Highlighted quotation")
  defp block_description("image"), do: gettext("Picture with alt text and caption")
  defp block_description("embed"), do: gettext("Embedded HTML or external content")
  defp block_description("divider"), do: gettext("Visual separator between sections")
  defp block_description("portable_text"), do: gettext("Portable Text rich content")
  defp block_description("custom"), do: gettext("Custom block payload")
  defp block_description(_), do: gettext("Insert a block")

  # The typed block name (string) for a sub-form's union member.
  defp block_type_string(bf), do: bf |> block_member() |> Kiln.Block.Info.name() |> to_string()

  # The first string/rich_text field — the block's primary text field.
  defp primary_field_name(nil), do: nil

  defp primary_field_name(module) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.find_value(fn f -> f.type in [:string, :rich_text] && f.name end)
  end

  # The scalar DSL fields a role may edit (field-level policy, Phase J), excluding
  # types with bespoke UIs (rich_text/map/reference/array).
  defp editable_scalar_fields(module, role) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.reject(&(&1.type in [:rich_text, :map, :reference] or match?({:array, _}, &1.type)))
    |> Enum.filter(&Kiln.Block.Policy.can_edit_field?(module, &1.name, role))
  end

  defp dsl_input_type(:integer), do: "number"
  defp dsl_input_type(:boolean), do: "checkbox"
  defp dsl_input_type(_type), do: "text"

  defp dsl_label(name), do: name |> to_string() |> Phoenix.Naming.humanize()

  # Per-block editor body for non-rich-text/non-image blocks: labeled inputs bound
  # directly to the union member's typed attributes (Kiln v2 native-union editor).
  # The primary text field is a textarea carrying the collab field-lock; the rest
  # render by their declared type. Role-filtered by field-level policy.
  attr :bf, :any, required: true
  attr :role, :atom, required: true
  attr :locked_fields, :any, required: true
  attr :cursors, :any, required: true

  defp dsl_block_fields(assigns) do
    module = block_member(assigns.bf)

    assigns =
      assigns
      |> assign(:primary, primary_field_name(module))
      |> assign(:fields, editable_scalar_fields(module, assigns.role))

    ~H"""
    <div class="space-y-2">
      <p :if={@fields == []} class="text-sm text-base-content/50">
        {gettext("Section break — no editable fields.")}
      </p>

      <div :for={field <- @fields}>
        <div
          :if={field.name == @primary}
          class={["relative", lock_ring(@locked_fields, @bf[field.name].name)]}
        >
          <.input
            field={@bf[field.name]}
            type="textarea"
            label={dsl_label(field.name)}
            readonly={field_locked?(@locked_fields, @bf[field.name].name)}
            {field_attrs(@bf[field.name].name)}
          />
          <.field_cursors field={@bf[field.name].name} cursors={@cursors} />
        </div>

        <.input
          :if={field.name != @primary}
          field={@bf[field.name]}
          type={dsl_input_type(field.type)}
          label={dsl_label(field.name)}
        />
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :locked_fields,
        locked_fields(assigns.cursors, assigns.self_field, assigns.actor.id)
      )
      |> assign(:related_field, related_field(assigns.kind))
      |> assign(:related_current, related_current(assigns.kind, assigns.record))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div
        :if={@conflict}
        id="edit-conflict"
        class="mb-4 flex flex-wrap items-center gap-3 rounded border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
        <span class="flex-1">
          {gettext(
            "Someone else saved changes to this content. Saving is paused so you don't overwrite their work."
          )}
        </span>
        <button
          type="button"
          phx-click="reload_conflict"
          data-confirm={gettext("Reload and discard your unsaved changes?")}
          class="rounded bg-warning px-3 py-1.5 text-xs font-medium text-warning-content hover:opacity-90"
        >
          {gettext("Reload latest")}
        </button>
      </div>
      <.form
        for={@form}
        phx-change="validate"
        phx-submit="save"
        id={"#{@kind}-editor"}
        class="space-y-6"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
          <div>
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All content")}
            </.link>
            <h1 class="mt-1 text-2xl font-semibold">{gettext("Edit %{kind}", kind: @kind)}</h1>
            <p class="text-sm text-base-content/60">
              {gettext("State:")} <span class="font-medium">{@record.state}</span>
            </p>
            <.presence_roster editors={@editors} current_id={@actor.id} />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="open_media_browser"
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              <.icon name="hero-photo" class="mr-1 size-4" />{gettext("Media library")}
            </button>
            <.link
              href={~p"/editor/preview/#{@kind}/#{@record.id}"}
              target="_blank"
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Preview")} &nearr;
            </.link>
            <.autosave_status :if={@record.state == :draft} state={@save_state} />
            <.workflow_buttons state={@record.state} actor={@actor} />
            <.button type="submit" variant="primary">{gettext("Save")}</.button>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="space-y-6">
            <div class="grid gap-4 sm:grid-cols-2">
              <div class={["relative", lock_ring(@locked_fields, "title")]}>
                <.input
                  field={@form[:title]}
                  label={gettext("Title")}
                  readonly={field_locked?(@locked_fields, "title")}
                  {field_attrs("title")}
                />
                <.field_cursors field="title" cursors={@cursors} />
              </div>
              <div class={["relative", lock_ring(@locked_fields, "slug")]}>
                <.input
                  field={@form[:slug]}
                  label={gettext("Slug")}
                  readonly={field_locked?(@locked_fields, "slug")}
                  {field_attrs("slug")}
                />
                <.field_cursors field="slug" cursors={@cursors} />
              </div>
            </div>

            <div :if={@has_excerpt} class={["relative", lock_ring(@locked_fields, "excerpt")]}>
              <.input
                field={@form[:excerpt]}
                type="textarea"
                label={gettext("Excerpt")}
                readonly={field_locked?(@locked_fields, "excerpt")}
                {field_attrs("excerpt")}
              />
              <.field_cursors field="excerpt" cursors={@cursors} />
            </div>

            <div class="space-y-3">
              <h2 class="text-lg font-medium">{gettext("Blocks")}</h2>

              <%!-- Announces keyboard reorder moves to screen readers (#171). --%>
              <p class="sr-only" role="status" aria-live="polite">{assigns[:moved_announcement]}</p>

              <div id="blocks-sortable" phx-hook="Sortable" class="space-y-3">
                <.inputs_for :let={bf} field={@form[:blocks]}>
                  <div
                    id={"block-#{bf.index}"}
                    data-sort-id={bf.index}
                    class="rounded border border-base-content/15 p-3"
                  >
                    <div class="mb-2 flex items-center justify-between gap-3">
                      <div class="flex items-center gap-2">
                        <span
                          data-drag-handle
                          aria-label={gettext("Drag to reorder")}
                          class="cursor-grab text-base-content/40 hover:text-base-content/70"
                        >
                          <.icon name="hero-bars-3" class="size-5" />
                        </span>
                        <%!-- Keyboard-accessible reorder, alongside the drag handle (#171). --%>
                        <div class="flex flex-col">
                          <button
                            type="button"
                            phx-click="move_block"
                            phx-value-index={bf.index}
                            phx-value-dir="up"
                            disabled={bf.index == 0}
                            aria-label={gettext("Move block up")}
                            class="text-base-content/40 hover:text-base-content/70 disabled:cursor-not-allowed disabled:opacity-30"
                          >
                            <.icon name="hero-chevron-up" class="size-4" />
                          </button>
                          <button
                            type="button"
                            phx-click="move_block"
                            phx-value-index={bf.index}
                            phx-value-dir="down"
                            disabled={bf.index == blocks_count(@form) - 1}
                            aria-label={gettext("Move block down")}
                            class="text-base-content/40 hover:text-base-content/70 disabled:cursor-not-allowed disabled:opacity-30"
                          >
                            <.icon name="hero-chevron-down" class="size-4" />
                          </button>
                        </div>
                        <span class="rounded bg-base-200 px-2 py-1 text-sm font-medium">
                          {dsl_label(block_type_string(bf))}
                        </span>
                      </div>
                      <button
                        type="button"
                        phx-click="remove_block"
                        phx-value-path={bf.name}
                        aria-label={gettext("Remove block")}
                        class="text-base-content/50 hover:text-error"
                      >
                        <.icon name="hero-trash" class="size-5" />
                      </button>
                    </div>
                    <div
                      :if={block_type_string(bf) == "rich_text"}
                      id={"rt-#{bf.index}"}
                      phx-hook="RichText"
                      phx-update="ignore"
                      data-content={bf[:legacy_html].value || ""}
                      data-editor-label={gettext("Rich text editor")}
                      role="group"
                      aria-label={gettext("Rich text block")}
                    >
                      <div
                        data-toolbar
                        role="toolbar"
                        aria-label={gettext("Text formatting")}
                        class="mb-1 flex flex-wrap gap-1"
                      >
                      </div>
                      <div data-editor></div>
                      <p class="mt-1 text-xs text-base-content/50">
                        {gettext("Type / for commands.")}
                      </p>
                      <input
                        type="hidden"
                        name={bf[:legacy_html].name}
                        value={bf[:legacy_html].value}
                        data-input
                      />
                    </div>
                    <div :if={block_type_string(bf) == "image"} class="space-y-2">
                      <img
                        :if={safe_preview_src(bf[:url].value)}
                        src={safe_preview_src(bf[:url].value)}
                        alt=""
                        class="max-h-40 rounded border border-base-content/10"
                      />
                      <input type="hidden" name={bf[:media_id].name} value={media_id_of(bf)} />
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          phx-click="open_picker"
                          phx-value-index={bf.index}
                          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                        >
                          <.icon name="hero-photo" class="mr-1 size-4" />{gettext(
                            "Choose from library"
                          )}
                        </button>
                      </div>
                      <.input
                        field={bf[:url]}
                        label={gettext("Image URL")}
                        placeholder={gettext("…or paste a URL")}
                      />
                      <.input field={bf[:alt]} label={gettext("Alt text")} />
                      <.input field={bf[:caption]} label={gettext("Caption")} />
                    </div>
                    <div :if={block_type_string(bf) not in ["rich_text", "image"]}>
                      <.dsl_block_fields
                        bf={bf}
                        role={@actor.role}
                        locked_fields={@locked_fields}
                        cursors={@cursors}
                      />
                    </div>
                  </div>
                </.inputs_for>
              </div>

              <.block_inserter block_types={@block_types} />
            </div>

            <details class="rounded border border-base-content/15 p-3" open>
              <summary class="cursor-pointer text-sm font-medium">
                {gettext("Organization & relationships")}
              </summary>
              <div class="mt-3 space-y-3">
                <.input
                  field={@form[:category_id]}
                  type="select"
                  label={gettext("Category")}
                  prompt="— None —"
                  options={Enum.map(@categories, &{&1.name, &1.id})}
                />

                <.input
                  field={@form[:tag_ids]}
                  type="select"
                  multiple
                  label={gettext("Tags")}
                  value={selected_ids(@form, :tag_ids, current_ids(@record.tags))}
                  options={Enum.map(@tags, &{&1.name, &1.id})}
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  {gettext("Hold ⌘/Ctrl to select multiple.")}
                </p>

                <.input
                  field={@form[:featured_image_id]}
                  type="select"
                  label={gettext("Featured image")}
                  prompt="— None —"
                  options={Enum.map(@media, &{&1.filename, &1.id})}
                />

                <.input
                  field={@form[@related_field]}
                  type="select"
                  multiple
                  label={gettext("Related %{kind}s", kind: @kind)}
                  value={selected_ids(@form, @related_field, current_ids(@related_current))}
                  options={Enum.map(@siblings, &{&1.title, &1.id})}
                />
              </div>
            </details>

            <details class="rounded border border-base-content/15 p-3">
              <summary class="cursor-pointer text-sm font-medium">
                {gettext("SEO & scheduling")}
              </summary>
              <div class="mt-3 space-y-3">
                <div class={["relative", lock_ring(@locked_fields, "seo_title")]}>
                  <.input
                    field={@form[:seo_title]}
                    label={gettext("SEO title")}
                    readonly={field_locked?(@locked_fields, "seo_title")}
                    {field_attrs("seo_title")}
                  />
                  <.field_cursors field="seo_title" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_description")]}>
                  <.input
                    field={@form[:seo_description]}
                    type="textarea"
                    label={gettext("SEO description")}
                    readonly={field_locked?(@locked_fields, "seo_description")}
                    {field_attrs("seo_description")}
                  />
                  <.field_cursors field="seo_description" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_image")]}>
                  <.input
                    field={@form[:seo_image]}
                    label={gettext("OG image URL")}
                    readonly={field_locked?(@locked_fields, "seo_image")}
                    {field_attrs("seo_image")}
                  />
                  <.field_cursors field="seo_image" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "canonical_url")]}>
                  <.input
                    field={@form[:canonical_url]}
                    label={gettext("Canonical URL")}
                    readonly={field_locked?(@locked_fields, "canonical_url")}
                    {field_attrs("canonical_url")}
                  />
                  <.field_cursors field="canonical_url" cursors={@cursors} />
                </div>
                <.input field={@form[:locale]} label={gettext("Locale")} />
                <.input
                  field={@form[:scheduled_at]}
                  type="datetime-local"
                  label={gettext("Scheduled publish at")}
                />
              </div>
            </details>

            <details class="rounded border border-base-content/15 p-3">
              <summary class="cursor-pointer text-sm font-medium">
                {gettext("Version history (%{count})", count: length(@versions))}
              </summary>
              <p :if={@versions == []} class="mt-3 text-sm text-base-content/60">
                {gettext("No saved versions yet.")}
              </p>
              <ul :if={@versions != []} class="mt-3 space-y-2">
                <li
                  :for={version <- @versions}
                  class="flex items-center justify-between gap-3 text-sm"
                >
                  <span class="text-base-content/70">
                    {version.version_action_name} · {Calendar.strftime(
                      version.version_inserted_at,
                      "%Y-%m-%d %H:%M"
                    )}
                    <span
                      :if={version.id == @record.published_version_id}
                      class="ml-1 rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"
                    >
                      {gettext("Live published")}
                    </span>
                  </span>
                  <button
                    type="button"
                    phx-click="restore"
                    phx-value-version_id={version.id}
                    data-confirm={gettext("Restore content to this version?")}
                    class="rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
                  >
                    {gettext("Restore")}
                  </button>
                </li>
              </ul>
            </details>
          </div>

          <div class="lg:sticky lg:top-4 lg:self-start">
            <h2 class="mb-2 text-lg font-medium">{gettext("Preview")}</h2>
            <article class="prose max-w-none space-y-3 rounded border border-base-content/15 p-5">
              <%!-- Visual preview of the published title — an h2 (not h1) so the
                    editor page keeps a single logical h1 (the "Edit %{kind}" header). #174 --%>
              <h2 class="text-2xl font-bold">{@form[:title].value}</h2>
              {preview_html(@form)}
            </article>
          </div>
        </div>
      </.form>

      <.image_picker :if={@picking != nil} index={@picking} media={@media} query={@media_query} />
    </Layouts.app>
    """
  end

  attr :editors, :list, required: true
  attr :current_id, :string, required: true

  # Live "who's editing" roster — overlapping colored avatar chips (one per
  # collaborator, in the same color as their cursor/lock badges) plus a count.
  # Hidden when you're the only one here. Self is sorted first and tagged
  # "(you)".
  defp presence_roster(assigns) do
    others = Enum.reject(assigns.editors, &(&1.id == assigns.current_id))
    roster = Enum.sort_by(assigns.editors, &{&1.id != assigns.current_id, &1.name})

    assigns =
      assign(assigns, others: others, roster: roster, count: length(assigns.editors))

    ~H"""
    <div :if={@others != []} class="mt-2 flex items-center gap-2">
      <div class="flex">
        <span
          :for={e <- @roster}
          title={e.name <> if(e.id == @current_id, do: gettext(" (you)"), else: "")}
          class={[
            "-ml-1.5 flex size-6 items-center justify-center rounded-full text-[10px] font-semibold text-white ring-2 ring-base-100 first:ml-0",
            color_for(e.id)
          ]}
        >
          {e.name |> String.first() |> Kernel.||("?") |> String.upcase()}
        </span>
      </div>
      <span class="text-xs text-base-content/60">{gettext("%{count} editing", count: @count)}</span>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :cursors, :map, required: true

  # Floating badges naming the collaborators currently focused on `field`.
  defp field_cursors(assigns) do
    others = for {_id, c} <- assigns.cursors, c.field == assigns.field, do: c
    assigns = assign(assigns, :others, others)

    ~H"""
    <div
      :if={@others != []}
      class="pointer-events-none absolute right-1 top-0 z-10 flex gap-1"
    >
      <span
        :for={c <- @others}
        title={gettext("%{name} is editing this field", name: c.name)}
        class={[
          "flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] font-medium text-white shadow",
          c.color
        ]}
      >
        <.icon name="hero-lock-closed-mini" class="size-3" />{c.name}
      </span>
    </div>
    """
  end

  attr :state, :atom, required: true

  # Draft autosave indicator shown next to the workflow/Save buttons.
  defp autosave_status(assigns) do
    ~H"""
    <span class="text-xs text-base-content/50" aria-live="polite">
      {if @state == :unsaved, do: gettext("Unsaved changes"), else: gettext("Saved")}
    </span>
    """
  end

  attr :state, :atom, required: true
  attr :actor, :map, required: true

  defp workflow_buttons(assigns) do
    ~H"""
    <button
      :if={@state == :draft and @actor.role == :editor}
      type="button"
      phx-click="workflow"
      phx-value-action="submit"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      {gettext("Submit for review")}
    </button>
    <button
      :if={@state in [:draft, :in_review] and @actor.role == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="publish"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      {if @state == :in_review, do: gettext("Approve & publish"), else: gettext("Publish")}
    </button>
    <button
      :if={@state == :in_review and @actor.role == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="return"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      {gettext("Request changes")}
    </button>
    <span
      :if={@state == :in_review and @actor.role == :editor}
      class="text-xs text-base-content/50"
    >
      {gettext("Awaiting admin approval")}
    </span>
    <button
      :if={@state == :published}
      type="button"
      phx-click="workflow"
      phx-value-action="unpublish"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      {gettext("Unpublish")}
    </button>
    """
  end
end
