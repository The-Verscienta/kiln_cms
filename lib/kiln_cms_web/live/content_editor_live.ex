defmodule KilnCMSWeb.ContentEditorLive do
  @moduledoc """
  Block editor for a single content record of **any** content type. The type
  comes from the `:type` param on `/editor/content/:type/:id` (or the
  `live_action` on the legacy `/editor/pages|posts/:id` routes) and is resolved
  through `KilnCMS.CMS.ContentTypes`, so types generated with
  `mix kiln.gen.content` are editable here with no extra wiring.

  Edit title/slug (+ excerpt where the type has one) and the embedded block tree
  (add/remove/reorder via the `Sortable` hook), with **TipTap rich text** for
  `rich_text` blocks, a **side-by-side live preview** (`KilnCMSWeb.BlockComponents`),
  SEO & scheduling, version history + restore, and the publishing workflow.
  Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.Presence

  @block_types ~w(rich_text heading quote image embed divider)

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
         |> assign(:block_types, @block_types)
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
           CMS.list_media_items!(actor: actor, query: [sort: [inserted_at: :desc]])
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
    record
    |> AshPhoenix.Form.for_update(:update, actor: actor, forms: [auto?: true])
    |> to_form()
  end

  # --- generic dispatch to the per-kind code interfaces (via the registry) ---

  defp fetch!(kind, id, actor) do
    ContentTypes.get_record!(kind, id,
      actor: actor,
      load: [:category, :featured_image, :tags, related_name(kind)]
    )
  end

  # Other content of the same kind, for the "related content" picker.
  defp siblings(kind, id, actor),
    do: kind |> ContentTypes.list!(actor: actor) |> Enum.reject(&(&1.id == id))

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
        params: %{"type" => "image", "content" => url, "data" => %{"media_id" => media_id}}
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
      |> put_block(index, %{"content" => url, "data" => %{"media_id" => media_id}})

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
        params: %{"type" => type, "content" => ""}
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

  def handle_event("save", %{"form" => params}, socket) do
    socket = cancel_autosave_timer(socket)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
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
    result =
      do_workflow(socket.assigns.kind, action, socket.assigns.record, socket.assigns.actor)

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

      case AshPhoenix.Form.submit(socket.assigns.form,
             params: AshPhoenix.Form.params(socket.assigns.form)
           ) do
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

  # The media id currently stored on an image block's `data`, if any.
  defp media_id_of(bf) do
    case bf[:data].value do
      %{"media_id" => id} -> id
      %{media_id: id} -> id
      _ -> nil
    end
  end

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
      <div class="absolute left-1/2 top-1/2 max-h-[80vh] w-full max-w-2xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg bg-base-100 p-5 shadow-xl">
        <div class="mb-3 flex items-center justify-between gap-4">
          <h2 class="text-lg font-medium">
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
  defp field_attrs(field) do
    %{"phx-focus" => "field_focus", "phx-blur" => "field_blur", "phx-value-field" => field}
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
  defp preview_blocks(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      forms when is_list(forms) -> Enum.map(forms, &block_map/1)
      _ -> []
    end
  end

  defp block_map(%AshPhoenix.Form{} = subform) do
    %{
      type: to_string(AshPhoenix.Form.value(subform, :type) || "rich_text"),
      content: AshPhoenix.Form.value(subform, :content) || ""
    }
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
    <Layouts.app flash={@flash}>
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
                        <.input
                          field={bf[:type]}
                          type="select"
                          options={@block_types}
                          class="max-w-40"
                        />
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
                      :if={to_string(bf[:type].value) == "rich_text"}
                      id={"rt-#{bf.index}"}
                      phx-hook="RichText"
                      phx-update="ignore"
                      data-content={bf[:content].value || ""}
                    >
                      <div data-toolbar class="mb-1 flex flex-wrap gap-1"></div>
                      <div data-editor></div>
                      <p class="mt-1 text-xs text-base-content/50">
                        {gettext("Type / for commands.")}
                      </p>
                      <input
                        type="hidden"
                        name={bf[:content].name}
                        value={bf[:content].value}
                        data-input
                      />
                    </div>
                    <div :if={to_string(bf[:type].value) == "image"} class="space-y-2">
                      <img
                        :if={bf[:content].value not in [nil, ""]}
                        src={bf[:content].value}
                        alt=""
                        class="max-h-40 rounded border border-base-content/10"
                      />
                      <input
                        type="hidden"
                        name={"#{bf.name}[data][media_id]"}
                        value={media_id_of(bf)}
                      />
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
                        field={bf[:content]}
                        label={gettext("Image URL")}
                        placeholder={gettext("…or paste a URL")}
                      />
                    </div>
                    <div
                      :if={to_string(bf[:type].value) not in ["rich_text", "image"]}
                      class={["relative", lock_ring(@locked_fields, bf[:content].name)]}
                    >
                      <.input
                        field={bf[:content]}
                        type="textarea"
                        placeholder={gettext("Block content…")}
                        readonly={field_locked?(@locked_fields, bf[:content].name)}
                        {field_attrs(bf[:content].name)}
                      />
                      <.field_cursors field={bf[:content].name} cursors={@cursors} />
                    </div>
                  </div>
                </.inputs_for>
              </div>

              <div class="flex flex-wrap gap-2">
                <button
                  :for={type <- @block_types}
                  type="button"
                  phx-click="add_block"
                  phx-value-type={type}
                  class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                >
                  <.icon name="hero-plus" class="mr-1 size-4" />{type}
                </button>
              </div>
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
            <article class="space-y-3 rounded border border-base-content/15 p-5">
              <h1 class="text-2xl font-bold">{@form[:title].value}</h1>
              <BlockComponents.render_block :for={block <- preview_blocks(@form)} block={block} />
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
