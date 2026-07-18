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

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.EditorTelemetry
  alias KilnCMSWeb.Presence

  # Preferred display order for the block palette; any block type registered
  # beyond these is appended automatically (the palette is registry-driven, so
  # adding a `Kiln.Block` module needs no editor change).
  @type_order ~w(rich_text heading quote image embed divider columns custom)

  # Child block types offerable inside a `columns` container (#335). A curated
  # subset with simple field editors — nested blocks get functional inputs, not
  # the top-level TipTap/media-picker treatment. Columns-in-columns is supported
  # by the model/renderer but intentionally not offered here (one nesting level
  # keeps the nested editor legible).
  @nested_child_types ~w(heading rich_text quote image embed divider)

  # Bounds on the columns editor, so the nested UI (and any hostile client event)
  # can't create a pathological tree. The storage cast has its own depth guard.
  @max_columns 4
  @max_children_per_column 20

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
        field_definitions = field_definitions(kind, actor)

        if connected?(socket) do
          topic = Presence.track_editor(self(), kind, id, actor)
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
          # Preview-window joins/leaves, so broadcast_preview/1 can no-op
          # while no pop-out is watching.
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_topic(kind, id))
        end

        {:ok,
         socket
         |> assign(:kind, kind)
         |> assign(:has_excerpt, ContentTypes.get!(kind).excerpt?)
         |> assign(:actor, actor)
         |> assign(:block_types, block_types())
         |> assign(:nested_child_types, @nested_child_types)
         |> assign(:editors, Presence.editors(kind, id))
         |> assign(:preview_open?, Presence.previews_open?(kind, id))
         |> assign(:cursors, %{})
         |> assign(:self_field, nil)
         # Debounced draft autosave: pending timer ref + status indicator state.
         |> assign(:autosave_timer, nil)
         |> assign(:save_state, :saved)
         # Set when an optimistic-lock conflict blocks saving until reload.
         |> assign(:conflict, false)
         # Bumped on server-driven form replacement (conflict reload, version
         # restore) so rich-text blocks remount and reload TipTap from the new
         # content — `phx-update="ignore"` otherwise keeps the stale editor (#135).
         |> assign(:editor_version, 0)
         # Media picker (image blocks) + relationship pickers (taxonomy, siblings).
         # `picking` is nil (closed), a block index (fill that image block), or
         # `:new` (insert a new image block — opened from the editor chrome).
         |> assign(:picking, nil)
         |> assign(:media_query, "")
         # nil = not searching (browse the mounted window); a list = DB search
         # results, so the picker also finds items beyond that window.
         |> assign(:picker_media, nil)
         |> assign(
           :media,
           # The picker grid needs only these fields; a select keeps 500
           # variants/EXIF-bearing rows out of the editor's heap.
           CMS.list_media_items!(
             actor: actor,
             query: [
               select: [:id, :url, :alt, :caption, :filename],
               sort: [inserted_at: :desc],
               limit: @max_media
             ]
           )
         )
         |> assign(:categories, CMS.list_categories!(actor: actor))
         |> assign(:tags, CMS.list_tags!(actor: actor))
         |> assign(:audiences, audience_options())
         |> assign(:field_definitions, field_definitions)
         |> assign(:reference_options, reference_options(field_definitions, actor))
         # CRDT collab prototype: when enabled, rich-text blocks sync live
         # between editors over the collab channel (see KilnCMS.Collab.Crdt).
         |> assign(:collab_token, collab_token(actor))
         |> assign(:collab_topic, "collab:#{kind}:#{id}")
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

  # A pop-out preview window opened or closed — flip the broadcast gate.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "previewing:" <> _},
        socket
      ) do
    open? = Presence.previews_open?(socket.assigns.kind, socket.assigns.record.id)
    socket = assign(socket, :preview_open?, open?)
    # Catch the window up with the latest unsaved edits the moment it opens.
    if open?, do: broadcast_preview(socket)
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
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

    {:noreply, socket}
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
  def handle_info(:autosave, socket), do: {:noreply, perform_autosave(socket)}

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> assign(:page_title, record.title)
    |> assign(:form, build_form(record, socket.assigns.actor))
    |> seed_block_children(record)
    |> refresh_preview()
    |> load_versions()
    |> load_translations()
  end

  # Seed the socket-managed children of every stored `columns` block, keyed by the
  # block's stable id (#335). Children live in socket state (not bound form
  # inputs) because a `{:array, :map}` field isn't an AshPhoenix sub-form; they're
  # injected back into the form params on every validate/save so the form — and
  # thus the preview and the eventual write — stays in sync. See `inject_children/2`.
  defp seed_block_children(socket, record) do
    children =
      record.blocks
      |> KilnCMS.CMS.TypedBlocks.to_typed()
      |> Enum.filter(&match?(%KilnCMS.Blocks.Columns{}, &1))
      |> Map.new(fn %KilnCMS.Blocks.Columns{} = c -> {c.id, normalize_columns(c.columns)} end)

    assign(socket, :block_children, children)
  end

  # Per-locale coverage for the Translations panel (only rendered when the
  # install has more than one locale).
  defp load_translations(socket) do
    assign(
      socket,
      :translations,
      KilnCMS.CMS.Translations.coverage(socket.assigns.kind, socket.assigns.record,
        actor: socket.assigns.actor
      )
    )
  end

  # The inline preview HTML is computed once per *form change* and kept in an
  # assign — it's rendered twice (mobile + desktop copies), and recomputing the
  # full sanitize-and-render pipeline in the template ran it on every render,
  # including presence diffs and collaborator cursor events.
  defp refresh_preview(socket) do
    assign(socket, :preview_html, preview_html(socket.assigns.form))
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
  # Only id + title — these fill a <select>; without the select, 500 siblings
  # would each carry their full blocks JSONB tree in this editor's heap.
  defp siblings(kind, id, actor) do
    kind
    |> ContentTypes.list!(
      actor: actor,
      query: [select: [:id, :title], sort: [updated_at: :desc], limit: @max_media]
    )
    |> Enum.reject(&(&1.id == id))
  end

  # `<select>` options for the consumer-facing audience (KilnCMS.CMS.Audiences):
  # `{humanized label, atom value}`. The select is only rendered when more than
  # one audience is configured (see the template).
  defp audience_options do
    Enum.map(KilnCMS.CMS.Audiences.all(), &{Phoenix.Naming.humanize(&1), &1})
  end

  # The self-referential m2m relationship/argument names follow the convention
  # `related_<type>s` / `related_<type>_ids`. `to_existing_atom` (rather than
  # interpolating a new atom) keeps this safe even though `kind` originates from
  # a route param — it's already registry-validated, and the atoms are defined
  # at compile time by `KilnCMS.CMS.Content`. Dynamic kinds (string names) all
  # live on the generic entry tier, so they resolve to its `related_entrys`.
  defp related_name(kind), do: String.to_existing_atom("related_#{interface_kind(kind)}s")
  defp related_field(kind), do: String.to_existing_atom("related_#{interface_kind(kind)}_ids")
  defp related_current(kind, record), do: Map.get(record, related_name(kind))

  defp interface_kind(kind) do
    case ContentTypes.get!(kind) do
      %{source: :dynamic} -> :entry
      ct -> ct.type
    end
  end

  # The Yjs fragment key for one rich-text block: its **stable block id**
  # (blocks carry a writable uuid primary key precisely so identity survives
  # reorders, restores and round-trips), so two sessions always bind the same
  # text to the same fragment regardless of block positions. Pre-id legacy
  # blocks (stored before ids existed and not yet backfilled) fall back to the
  # index — the old, positional behavior — until their next save assigns one.
  defp collab_fragment(bf) do
    case bf[:id] && bf[:id].value do
      id when is_binary(id) and id != "" -> "block-#{id}"
      _missing -> "block-idx-#{bf.index}"
    end
  end

  # Socket token for the CRDT collab prototype; nil (and thus no data-collab
  # attributes, no channel) when the flag is off. Mount is editor/admin-gated,
  # so a token only ever reaches an authorized editor.
  defp collab_token(actor) do
    if KilnCMS.Collab.Crdt.enabled?() do
      Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", actor.id)
    end
  end

  # A dynamic kind's custom fields are scoped by its TypeDefinition, a compiled
  # kind's by its type atom (see FieldDefinition's two scopes).
  defp field_definitions(kind, actor) do
    case ContentTypes.get!(kind) do
      %{source: :dynamic, definition: definition} ->
        CMS.field_definitions_for_definition!(definition.id, actor: actor)

      ct ->
        CMS.field_definitions_for!(ct.type, actor: actor)
    end
  end

  # Pick-lists for `:reference` custom fields: per definition, the target
  # type's records as `{title, id}` options — narrow select and the same window
  # cap as the media picker, so a large library can't blow up the mount.
  defp reference_options(definitions, actor) do
    definitions
    |> Enum.filter(&(&1.field_type == :reference))
    |> Map.new(fn definition ->
      options =
        case ContentTypes.get(definition.target_type) do
          nil ->
            []

          ct ->
            ct
            |> ContentTypes.list!(
              actor: actor,
              query: [select: [:id, :title], sort: [title: :asc], limit: @max_media]
            )
            |> Enum.map(&{&1.title, &1.id})
        end

      {definition.name, options}
    end)
  end

  # Options for the pick-list custom fields; other field types need none.
  defp custom_field_options(%{field_type: :media}, media, _refs),
    do: Enum.map(media, &{&1.filename, &1.id})

  defp custom_field_options(%{field_type: :reference, name: name}, _media, refs),
    do: Map.get(refs, name, [])

  defp custom_field_options(_definition, _media, _refs), do: []

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
    # The columns children live in socket state (they aren't bound form inputs);
    # re-inject them so a keystroke's partial params can't wipe the nested tree.
    params = inject_children(params, socket.assigns.block_children)
    socket = assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
    broadcast_preview(socket)
    {:noreply, mark_dirty(socket)}
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

  # Open the (searchable) media browser to choose the featured image (#154),
  # replacing the load-everything <select>.
  def handle_event("open_featured_picker", _params, socket),
    do: {:noreply, assign(socket, :picking, :featured)}

  def handle_event("clear_featured", _params, socket) do
    params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("featured_image_id", nil)

    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> mark_dirty()}
  end

  def handle_event("close_picker", _params, socket),
    do: {:noreply, reset_picker(socket)}

  # Live-filter the browser grid as the user types.
  def handle_event("search_media", %{"q" => q}, socket) do
    results = if q == "", do: nil, else: search_media(q, socket.assigns.actor)
    {:noreply, socket |> assign(:media_query, q) |> assign(:picker_media, results)}
  end

  # Set the featured image from the library (#154).
  def handle_event("pick_image", %{"index" => "featured", "id" => media_id}, socket) do
    params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("featured_image_id", media_id)

    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> reset_picker()
     |> mark_dirty()}
  end

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
    {:noreply, mark_dirty(socket)}
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
    {:noreply, mark_dirty(socket)}
  end

  # A columns block carries a socket-managed child tree, so it's inserted with a
  # stable id (seeded into `block_children`) and a default two-column layout.
  def handle_event("add_block", %{"type" => "columns"}, socket) do
    id = Ash.UUID.generate()
    cols = [%{"blocks" => []}, %{"blocks" => []}]

    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => "columns", "id" => id, "columns" => cols}
      )

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:block_children, Map.put(socket.assigns.block_children, id, cols))
     |> refresh_preview()
     |> mark_dirty()}
  end

  def handle_event("add_block", %{"type" => type}, socket) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => type}
      )

    {:noreply, socket |> assign(:form, form) |> mark_dirty()}
  end

  def handle_event("remove_block", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.remove_form(socket.assigns.form, path))
     |> mark_dirty()}
  end

  def handle_event("reorder", %{"order" => order}, socket) do
    form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)
    {:noreply, socket |> assign(:form, form) |> mark_dirty()}
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
       |> mark_dirty()
       |> assign(
         :moved_announcement,
         gettext("Moved block to position %{pos} of %{count}", pos: j + 1, count: count)
       )}
    else
      {:noreply, socket}
    end
  end

  # ── columns container editing (#335) ────────────────────────────────────────
  # These mutate the socket-managed child tree of a `columns` block, then re-sync
  # it into the form (so the live preview + save reflect it). Blocks and columns
  # are addressed by their stable ids; nothing here relies on positional indices
  # surviving a concurrent reorder.

  def handle_event("col_add_child", %{"id" => id, "col" => col, "type" => type}, socket)
      when type in @nested_child_types do
    bc =
      update_column(socket.assigns.block_children, id, to_int(col), fn blocks ->
        if length(blocks) >= @max_children_per_column,
          do: blocks,
          else: blocks ++ [new_child(type)]
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("col_remove_child", %{"id" => id, "child" => child_id}, socket) do
    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.reject(blocks, &(&1["id"] == child_id))
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event(
        "col_update_child",
        %{"id" => id, "child" => child_id, "field" => field} = p,
        socket
      ) do
    value = Map.get(p, "value", "")

    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.map(blocks, &maybe_put_field(&1, child_id, field, value))
      end)

    {:noreply, apply_children(socket, bc)}
  end

  # Nested SortableJS drop: `cols` is the new child-id order of every column of
  # this block. Rebuild each column from the flat id→child map so a child can
  # move within or across the block's columns without losing its edits.
  def handle_event("col_reorder", %{"id" => id, "cols" => cols}, socket) when is_list(cols) do
    bc = Map.update(socket.assigns.block_children, id, [], &rebuild_columns(&1, cols))
    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("col_add_column", %{"id" => id}, socket) do
    bc =
      Map.update(socket.assigns.block_children, id, [%{"blocks" => []}], fn cols ->
        if length(cols) >= @max_columns, do: cols, else: cols ++ [%{"blocks" => []}]
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("col_remove_column", %{"id" => id, "col" => col}, socket) do
    bc =
      Map.update(socket.assigns.block_children, id, [], fn cols ->
        # Keep at least one column so the block stays a valid container.
        if length(cols) <= 1, do: cols, else: List.delete_at(cols, to_int(col))
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    socket = cancel_autosave_timer(socket)
    params = inject_children(params, socket.assigns.block_children)

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
     |> reset_editors()
     |> assign(:conflict, false)
     |> assign(:save_state, :saved)
     |> put_flash(:info, gettext("Reloaded the latest version."))}
  end

  def handle_event("workflow", %{"action" => action}, socket) do
    {:noreply, run_workflow(socket, action)}
  end

  # One-click translation: duplicate this record's content into a new draft in
  # the target locale and jump to its editor.
  def handle_event("create_translation", %{"locale" => locale}, socket) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    translation =
      KilnCMS.CMS.Translations.create_translation!(kind, record, locale, actor: actor)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Draft translation created (%{locale}).", locale: locale))
     |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
  rescue
    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
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
         socket
         |> assign_record(record)
         |> reset_editors()
         |> assign(:save_state, :saved)
         |> put_flash(:info, gettext("Restored that version."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't restore that version."))}
    end
  end

  # Force rich-text blocks to remount (new element id) so TipTap reloads from the
  # replaced form rather than keeping its `phx-update="ignore"` content (#135).
  defp reset_editors(socket), do: update(socket, :editor_version, &(&1 + 1))

  defp run_workflow(socket, action)
       when action in ~w(submit return publish unpublish archive unarchive) do
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
        |> put_flash(:info, gettext("Updated to %{state}.", state: state_label(record.state)))

      _ ->
        put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  defp run_workflow(socket, _action), do: socket

  # --- dirty tracking + draft autosave ----------------------------------------

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
  defp mark_dirty(socket) do
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
        do_autosave(socket)
    end
  end

  # Stale timer (already saved, or state moved on) — no-op.
  defp perform_autosave(socket), do: assign(socket, :autosave_timer, nil)

  defp do_autosave(socket) do
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
  end

  # Someone else saved first → stop autosaving and surface the conflict rather
  # than retrying (which would keep losing). Otherwise mark the draft as failing
  # validation (`:error`) so the indicator says so (#136); the next edit
  # reschedules a retry.
  defp handle_autosave_error(socket, form) do
    if stale_conflict?(form),
      do: flag_conflict(socket),
      else: assign(socket, :save_state, :error)
  end

  # Stop autosaving and put the editor into a conflict state until the user
  # reloads. Surface a flash so a blocked Save gets immediate feedback (#137) —
  # the Save button is also disabled while `@conflict` is set.
  defp flag_conflict(socket) do
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
  # Skipped entirely while no window is watching (audit P-M2) — otherwise every
  # editor paid the full typed→legacy block conversion per debounced keystroke
  # for a payload nobody received.
  defp broadcast_preview(%{assigns: %{preview_open?: false}} = socket), do: socket

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

  # ── columns children: socket state ⇄ form params ────────────────────────────

  # Re-sync the socket-managed children into the form (keeping the preview + a
  # future save current), then refresh the preview and mark the doc dirty. The
  # form's own params carry every other field, so injecting the children over
  # them is a lossless round-trip.
  defp apply_children(socket, block_children) do
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> inject_children(block_children)

    socket
    |> assign(:block_children, block_children)
    |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
    |> broadcast_preview_and_refresh()
    |> mark_dirty()
  end

  defp broadcast_preview_and_refresh(socket) do
    socket = refresh_preview(socket)
    broadcast_preview(socket)
    socket
  end

  # Set the `columns` param of every `columns` block to its socket-managed
  # children, matched by the block's stable id. Tolerates params where `blocks`
  # is the usual indexed map or a list.
  defp inject_children(params, block_children) when map_size(block_children) == 0, do: params

  defp inject_children(params, block_children) do
    Map.update(params, "blocks", params["blocks"], fn
      blocks when is_map(blocks) ->
        Map.new(blocks, fn {k, v} -> {k, inject_block(v, block_children)} end)

      blocks when is_list(blocks) ->
        Enum.map(blocks, &inject_block(&1, block_children))

      other ->
        other
    end)
  end

  defp inject_block(%{} = block, block_children) do
    case block["id"] && Map.get(block_children, block["id"]) do
      nil -> block
      cols -> Map.put(block, "columns", cols)
    end
  end

  defp inject_block(other, _block_children), do: other

  # Apply `fun` to the child-block list of one column (by index) of a block.
  defp update_column(block_children, block_id, col_index, fun) do
    Map.update(block_children, block_id, [], fn cols ->
      List.update_at(cols, col_index, &update_col_blocks(&1, fun))
    end)
  end

  # Apply `fun` to every column's child-block list of a block.
  defp update_columns(block_children, block_id, fun) do
    Map.update(block_children, block_id, [], fn cols ->
      Enum.map(cols, &update_col_blocks(&1, fun))
    end)
  end

  defp update_col_blocks(col, fun) do
    Map.update(col || %{"blocks" => []}, "blocks", [], fn blocks -> fun.(List.wrap(blocks)) end)
  end

  # Rebuild every column of a block from a per-column list of child ids (a nested
  # drag result), preserving each child's current attrs by id.
  defp rebuild_columns(current, cols) do
    by_id = current |> Enum.flat_map(& &1["blocks"]) |> Map.new(&{&1["id"], &1})
    Enum.map(cols, fn ids -> %{"blocks" => pick_children(by_id, ids)} end)
  end

  defp pick_children(by_id, ids),
    do: ids |> List.wrap() |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)

  # Set `field` on the child whose id matches; leave every other child untouched.
  defp maybe_put_field(%{"id" => id} = child, id, field, value),
    do: put_child_field(child, field, value)

  defp maybe_put_field(child, _id, _field, _value), do: child

  # Normalize a stored/def columns value to the editor shape: a non-empty list of
  # `%{"blocks" => [child maps]}`, every child carrying a stable id (backfilled if
  # a legacy child lacks one, so the nested Sortable can address it).
  defp normalize_columns(cols) do
    case List.wrap(cols) do
      [] ->
        [%{"blocks" => []}, %{"blocks" => []}]

      list ->
        Enum.map(list, fn col ->
          blocks =
            col
            |> child_blocks_of()
            |> Enum.map(&ensure_child_id/1)

          %{"blocks" => blocks}
        end)
    end
  end

  defp child_blocks_of(col) when is_map(col),
    do: (Map.get(col, "blocks") || Map.get(col, :blocks) || []) |> List.wrap()

  defp child_blocks_of(_), do: []

  defp ensure_child_id(child) do
    child = stringify_child(child)
    Map.put_new_lazy(child, "id", &Ash.UUID.generate/0)
  end

  defp stringify_child(%{} = child), do: Map.new(child, fn {k, v} -> {to_string(k), v} end)
  defp stringify_child(_), do: %{}

  # A fresh child block map (string keys) with its type-appropriate defaults.
  defp new_child(type) do
    base = %{"_type" => type, "id" => Ash.UUID.generate()}

    case type do
      "heading" -> Map.merge(base, %{"text" => "", "level" => 2})
      "rich_text" -> Map.merge(base, %{"legacy_html" => "", "body" => []})
      "quote" -> Map.merge(base, %{"text" => "", "citation" => ""})
      "image" -> Map.merge(base, %{"url" => "", "alt" => ""})
      "embed" -> Map.merge(base, %{"url" => ""})
      _ -> base
    end
  end

  # Coerce an editable child field, keeping `level` an integer (headings clamp on
  # render, so an out-of-range value is harmless, but a non-integer would fail the
  # embedded cast).
  defp put_child_field(child, "level", value), do: Map.put(child, "level", to_int(value))
  defp put_child_field(child, field, value), do: Map.put(child, field, value)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  # The media id currently on an image block sub-form, if any.
  defp media_id_of(bf), do: bf[:media_id].value

  # Safe `src` for the image-block preview: a pasted URL is untrusted, so it must
  # clear the same scheme allowlist as delivery before we echo it back. Returns
  # nil (image hidden) for rejected schemes like `javascript:`/`data:`.
  defp safe_preview_src(url), do: KilnCMS.HTMLSanitizer.safe_image_src(url)

  defp reset_picker(socket),
    do: socket |> assign(:picking, nil) |> assign(:media_query, "") |> assign(:picker_media, nil)

  # Accessible tag picker (#153): a labeled checkbox group replacing the native
  # <select multiple> (no ⌘/Ctrl needed). Each tag is its own labeled control;
  # the array submits under the same `tag_ids[]` name the relationship expects.
  attr :form, :any, required: true
  attr :tags, :list, required: true
  attr :record, :any, required: true

  defp tag_picker(assigns) do
    selected =
      assigns.form
      |> selected_ids(:tag_ids, current_ids(assigns.record.tags))
      |> Enum.map(&to_string/1)

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:name, assigns.form[:tag_ids].name <> "[]")

    ~H"""
    <fieldset>
      <legend class="mb-1 block text-sm font-medium text-base-content">{gettext("Tags")}</legend>
      <p :if={@tags == []} class="text-xs text-base-content/70">{gettext("No tags yet.")}</p>
      <div :if={@tags != []} class="flex flex-wrap gap-2">
        <label
          :for={tag <- @tags}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded border border-base-content/20 px-2 py-1 text-sm hover:bg-base-200"
        >
          <input
            type="checkbox"
            name={@name}
            value={tag.id}
            checked={to_string(tag.id) in @selected}
            class="size-4 rounded border border-base-content/30 accent-primary"
          />
          {tag.name}
        </label>
      </div>
    </fieldset>
    """
  end

  # Featured-image chooser (#154): a thumbnail of the current selection plus a
  # button that opens the searchable media picker, replacing a <select> that
  # loaded every asset. The id is carried in a hidden input so it still submits.
  # One input for an admin-defined custom field (KilnCMS.CMS.FieldDefinition).
  # Inputs are named into the content form's `custom_fields` map
  # (`form[custom_fields][<name>]`); the write change coerces/validates them.
  attr :definition, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :errors, :list, default: []
  attr :options, :list, default: []

  # Media / reference pick-lists: the select posts the target id; the stored
  # value is the write-time snapshot map (see ApplyCustomFields), so the
  # current selection is its "id".
  defp custom_field_input(%{definition: %{field_type: type}} = assigns)
       when type in [:media, :reference] do
    assigns = assign(assigns, :selected_id, snapshot_id(assigns.value))

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={{label, id} <- @options} value={id} selected={@selected_id == id}>
          {label}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :boolean}} = assigns) do
    assigns = assign(assigns, :checked, assigns.value in [true, "true", "1", "on"])

    ~H"""
    <div>
      <label class="flex items-center gap-2 text-sm">
        <%!-- hidden "false" first so an unchecked box still submits a value (last wins) --%>
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && cf_errors_id(@definition)}
        />
        <span class="font-medium">{@definition.label}</span>
        <span :if={@definition.help_text} class="text-base-content/60">— {@definition.help_text}</span>
      </label>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :select}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={opt <- @definition.options} value={opt} selected={to_string(@value) == opt}>
          {opt}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :text}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <textarea
        id={cf_id(@definition)}
        name={@name}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
      >{@value}</textarea>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # Everything else renders as a plain `<input>`. Plugin field types
  # (`Kiln.FieldType`) pick their HTML input kind + extra attributes
  # (min/max/step/…) via the registry; core types map below.
  defp custom_field_input(assigns) do
    definition = assigns.definition

    {input_type, extra} =
      case KilnCMS.CMS.FieldTypes.get(definition.field_type) do
        nil -> {custom_input_type(definition.field_type), %{}}
        module -> {module.input_type(), module.input_attrs(definition)}
      end

    extra =
      if input_type == "number" and definition.field_type == :float,
        do: Map.put_new(extra, :step, "any"),
        else: extra

    assigns = assigns |> assign(:input_type, input_type) |> assign(:extra, extra)

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <input
        id={cf_id(@definition)}
        type={@input_type}
        name={@name}
        value={@value}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
        {@extra}
      />
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  attr :definition, :map, required: true
  attr :errors, :list, required: true

  defp custom_field_errors_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={cf_errors_id(@definition)}>
      <p :for={message <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4" /> {message}
      </p>
    </div>
    """
  end

  defp cf_id(definition), do: "custom-field-#{definition.name}"
  defp cf_errors_id(definition), do: "custom-field-#{definition.name}-errors"

  # The current selection for a pick-list field: the stored snapshot's id, or
  # the raw id while a change is mid-validate.
  defp snapshot_id(%{"id" => id}), do: id
  defp snapshot_id(id) when is_binary(id) and id != "", do: id
  defp snapshot_id(_other), do: nil

  defp custom_input_type(:integer), do: "number"
  defp custom_input_type(:float), do: "number"
  defp custom_input_type(:date), do: "date"
  defp custom_input_type(:datetime), do: "datetime-local"
  defp custom_input_type(:url), do: "url"
  defp custom_input_type(_), do: "text"

  # Current value of one custom field, from the form's `custom_fields` map
  # (param value mid-edit, otherwise the record's stored value). Keys are always
  # strings (jsonb / form params).
  defp custom_field_value(form, name) do
    case AshPhoenix.Form.value(form, :custom_fields) do
      map when is_map(map) -> Map.get(map, name)
      _ -> nil
    end
  end

  # Validation messages `ApplyCustomFields` attached for one definition — the
  # errors land on the `:custom_fields` attribute with the field's name in
  # `value`, so they'd otherwise never render anywhere (audit U-H2).
  defp custom_field_errors(form, name) do
    form
    |> changeset_errors()
    |> Enum.filter(fn
      %Ash.Error.Changes.InvalidAttribute{field: :custom_fields, value: value} -> value == name
      _ -> false
    end)
    |> Enum.map(& &1.message)
  end

  defp any_custom_field_errors?(form, definitions),
    do: Enum.any?(definitions, &(custom_field_errors(form, &1.name) != []))

  attr :form, :any, required: true
  attr :media, :list, required: true

  defp featured_image_field(assigns) do
    id = AshPhoenix.Form.value(assigns.form, :featured_image_id)

    assigns =
      assigns
      |> assign(:field, assigns.form[:featured_image_id])
      |> assign(:selected, Enum.find(assigns.media, &(to_string(&1.id) == to_string(id))))

    ~H"""
    <div>
      <span class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Featured image")}
      </span>
      <input type="hidden" name={@field.name} value={@field.value} />
      <div class="mt-1 flex flex-wrap items-center gap-3">
        <img
          :if={@selected}
          src={@selected.url}
          alt=""
          class="h-16 w-16 rounded border border-base-content/10 object-cover"
        />
        <span class="text-sm text-base-content/70">
          {(@selected && @selected.filename) || gettext("None selected")}
        </span>
        <button
          type="button"
          phx-click="open_featured_picker"
          class="btn btn-sm btn-default"
        >
          {gettext("Choose from library")}
        </button>
        <button
          :if={@selected}
          type="button"
          phx-click="clear_featured"
          class="text-sm text-base-content/70 hover:text-error"
        >
          {gettext("Remove")}
        </button>
      </div>
    </div>
    """
  end

  # Server-side substring search over filename/alt/caption (audit U-M2): finds
  # items beyond the mounted picker window, and matches partial input as the
  # user types (the library's `:search` action is whole-word tsquery, less
  # forgiving for a live picker). %, _ and \ in the input match literally.
  defp search_media(q, actor) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"

    CMS.list_media_items!(
      actor: actor,
      query: [
        filter:
          expr(ilike(filename, ^pattern) or ilike(alt, ^pattern) or ilike(caption, ^pattern)),
        select: [:id, :url, :alt, :caption, :filename],
        sort: [inserted_at: :desc],
        limit: @max_media
      ]
    )
  end

  # The `phx-value-index` for a pick button: "new" inserts a fresh image block
  # (browser opened from the chrome), an integer fills that existing block.
  defp pick_index(:new), do: "new"
  defp pick_index(:featured), do: "featured"
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
  attr :results, :list, default: nil
  attr :query, :string, required: true

  # Full media-library browser modal. Reachable from the editor chrome (to
  # insert a new image block, `index = :new`) and from each image block (to fill
  # that block, `index` = its integer index). Browse + search + insert; while a
  # query is active, `results` (a DB search) replaces the browse window.
  defp image_picker(assigns) do
    assigns = assign(assigns, :visible, assigns.results || assigns.media)

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
            class="text-base-content/70 hover:text-base-content"
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
            aria-label={gettext("Search by filename, alt text or caption")}
            phx-debounce="150"
            autocomplete="off"
            class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
          />
        </form>

        <p :if={@media == []} class="text-sm text-base-content/60">
          {gettext("No media yet — upload some in the")} <.link
            navigate={~p"/media"}
            class="underline"
          >{gettext("media library")}</.link>.
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

  # Hex twins of @cursor_colors (same order), for the CRDT caret labels —
  # TipTap's CollaborationCursor needs CSS color values, not Tailwind classes.
  @cursor_colors_hex ~w(#f43f5e #f59e0b #10b981 #0ea5e9 #8b5cf6 #ec4899)

  defp color_hex_for(id),
    do: Enum.at(@cursor_colors_hex, rem(:erlang.phash2(id), length(@cursor_colors_hex)))

  # Up-to-two-letter initials from a display name ("Jane Doe" → "JD",
  # "editor" → "E"), for the roster chips and remote caret labels.
  defp initials(nil), do: "?"

  defp initials(name) do
    case name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) do
      [] -> "?"
      words -> Enum.map_join(words, &(&1 |> String.first() |> String.upcase()))
    end
  end

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
    |> KilnCMSWeb.BlockComponents.thin_blocks()
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
  defp block_icon("columns"), do: "hero-view-columns"
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
  defp block_description("columns"), do: gettext("Side-by-side columns holding nested blocks")
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
      <p :if={@fields == []} class="text-sm text-base-content/70">
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

  # ── columns (nested-layout) editor (#335) ───────────────────────────────────

  # The socket-managed children of the columns block behind sub-form `bf`, keyed
  # by the block's stable id. Falls back to the default two empty columns for a
  # block whose id isn't seeded yet (a just-inserted one before its first sync).
  defp col_state(block_children, bf) do
    Map.get(block_children, col_block_id(bf)) || [%{"blocks" => []}, %{"blocks" => []}]
  end

  defp col_block_id(bf), do: bf[:id].value || AshPhoenix.Form.value(bf, :id)

  # Layout <select> options: "Equal" plus each width-ratio preset (labelled "1 : 2").
  defp layout_options do
    presets =
      KilnCMS.Blocks.Columns.presets()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&{String.replace(&1, "-", " : "), &1})

    [{gettext("Equal width"), ""} | presets]
  end

  # The full nested editor for one columns block: a layout picker, then a
  # drag-reorderable list per column (nested SortableJS via the `NestedBlockSortable`
  # hook — children move within and across this block's columns), each with an
  # "add block" palette. Children are edited by socket-side events, not bound form
  # inputs; the hidden id input lets the server match this block on save/validate.
  attr :bf, :any, required: true
  attr :columns, :list, required: true
  attr :child_types, :list, required: true

  defp columns_editor(assigns) do
    assigns = assign(assigns, :block_id, col_block_id(assigns.bf))

    ~H"""
    <div class="space-y-3">
      <%!-- Carries the block id into save/validate params so its socket-managed
            children can be matched and re-injected (see inject_children/2). --%>
      <input type="hidden" name={@bf[:id].name} value={@block_id} />

      <div class="flex flex-wrap items-end gap-3">
        <.input
          field={@bf[:layout]}
          type="select"
          label={gettext("Layout")}
          options={layout_options()}
        />
        <button
          type="button"
          phx-click="col_add_column"
          phx-value-id={@block_id}
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-plus" class="mr-1 size-4" />{gettext("Add column")}
        </button>
      </div>

      <div
        id={"cols-#{@block_id}"}
        phx-hook="NestedBlockSortable"
        data-block-id={@block_id}
        class="grid gap-3"
        style={"grid-template-columns:repeat(#{max(length(@columns), 1)}, minmax(0, 1fr))"}
      >
        <div
          :for={{col, ci} <- Enum.with_index(@columns)}
          class="rounded border border-dashed border-base-content/25 p-2"
        >
          <div class="mb-2 flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60">
              {gettext("Column %{n}", n: ci + 1)}
            </span>
            <button
              :if={length(@columns) > 1}
              type="button"
              phx-click="col_remove_column"
              phx-value-id={@block_id}
              phx-value-col={ci}
              data-confirm={gettext("Remove this column and its blocks?")}
              aria-label={gettext("Remove column")}
              class="text-base-content/50 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div data-col-list data-col-index={ci} class="min-h-8 space-y-2">
            <div
              :for={child <- col["blocks"] || []}
              id={"child-#{child["id"]}"}
              data-child-id={child["id"]}
              class="rounded border border-base-content/15 bg-base-100 p-2"
            >
              <div class="mb-1 flex items-center justify-between gap-2">
                <span
                  data-child-handle
                  class="flex cursor-grab items-center gap-1 text-xs text-base-content/60"
                >
                  <.icon name="hero-bars-3" class="size-4" />
                  {dsl_label(child["_type"])}
                </span>
                <button
                  type="button"
                  phx-click="col_remove_child"
                  phx-value-id={@block_id}
                  phx-value-child={child["id"]}
                  aria-label={gettext("Remove block")}
                  class="text-base-content/50 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
              <.nested_child_fields block_id={@block_id} child={child} />
            </div>
          </div>

          <div class="mt-2 flex flex-wrap gap-1">
            <button
              :for={type <- @child_types}
              type="button"
              phx-click="col_add_child"
              phx-value-id={@block_id}
              phx-value-col={ci}
              phx-value-type={type}
              class="rounded bg-base-200 px-2 py-1 text-xs hover:bg-base-300"
            >
              + {dsl_label(type)}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Simple per-type field editors for a nested child block. Inputs are nameless
  # (they never enter the form's params) and commit to socket state via
  # `col_update_child` on blur/change — see the columns handlers.
  attr :block_id, :any, required: true
  attr :child, :map, required: true

  defp nested_child_fields(%{child: %{"_type" => "divider"}} = assigns) do
    ~H"""
    <hr class="border-base-300" />
    """
  end

  defp nested_child_fields(assigns) do
    ~H"""
    <div class="space-y-1">
      <input
        :for={{field, ph} <- nested_fields_for(@child["_type"])}
        type="text"
        value={@child[field] || ""}
        placeholder={ph}
        phx-blur="col_update_child"
        phx-value-id={@block_id}
        phx-value-child={@child["id"]}
        phx-value-field={field}
        class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
      />
      <select
        :if={@child["_type"] == "heading"}
        phx-change="col_update_child"
        phx-value-id={@block_id}
        phx-value-child={@child["id"]}
        phx-value-field="level"
        class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
      >
        <option :for={n <- 1..6} value={n} selected={to_int(@child["level"]) == n}>H{n}</option>
      </select>
    </div>
    """
  end

  # {field, placeholder} pairs for a nested child type's text inputs.
  defp nested_fields_for("heading"), do: [{"text", gettext("Heading text")}]
  defp nested_fields_for("rich_text"), do: [{"legacy_html", gettext("HTML / text")}]

  defp nested_fields_for("quote"),
    do: [{"text", gettext("Quote")}, {"citation", gettext("Citation")}]

  defp nested_fields_for("image"),
    do: [{"url", gettext("Image URL")}, {"alt", gettext("Alt text")}]

  defp nested_fields_for("embed"), do: [{"url", gettext("Embed URL")}]
  defp nested_fields_for(_), do: []

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
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:content}
    >
      <div
        :if={@conflict}
        id="edit-conflict"
        role="alert"
        aria-live="assertive"
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
          class="btn btn-sm border-transparent bg-warning text-warning-content hover:opacity-90"
        >
          {gettext("Reload latest")}
        </button>
      </div>
      <.form
        for={@form}
        phx-change="validate"
        phx-submit="save"
        id={"#{@kind}-editor"}
        phx-hook="UnsavedGuard"
        data-dirty={to_string(@save_state != :saved)}
        data-unsaved-message={gettext("You have unsaved changes. Leave without saving?")}
        class="space-y-6"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
          <div>
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All content")}
            </.link>
            <h1 class="mt-1 text-2xl font-semibold">{gettext("Edit %{kind}", kind: @kind)}</h1>
            <p class="text-sm text-base-content/60">
              {gettext("State:")} <span class="font-medium">{state_label(@record.state)}</span>
            </p>
            <%!-- After saving a schedule, nothing else says it exists (U-M4). --%>
            <p
              :if={@record.scheduled_at && @record.state in [:draft, :in_review]}
              class="mt-0.5 flex items-center gap-1 text-sm text-base-content/60"
            >
              <.icon name="hero-clock" class="size-4" />
              {gettext("Scheduled to publish")}
              <time
                id="scheduled-publish-badge"
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(@record.scheduled_at)}
              >{Calendar.strftime(@record.scheduled_at, "%Y-%m-%d %H:%M")} UTC</time>
            </p>
            <p
              :if={@record.unpublish_at && @record.state == :published}
              class="mt-0.5 flex items-center gap-1 text-sm text-base-content/60"
            >
              <.icon name="hero-clock" class="size-4" />
              {gettext("Scheduled to unpublish")}
              <time
                id="scheduled-unpublish-badge"
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(@record.unpublish_at)}
              >{Calendar.strftime(@record.unpublish_at, "%Y-%m-%d %H:%M")} UTC</time>
            </p>
            <.presence_roster editors={@editors} current_id={@actor.id} />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="open_media_browser"
              class="btn btn-sm btn-default"
            >
              <.icon name="hero-photo" class="mr-1 size-4" />{gettext("Media library")}
            </button>
            <.link
              href={~p"/editor/preview/#{@kind}/#{@record.id}"}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm btn-default"
            >
              {gettext("Preview")} &nearr;
              <span class="sr-only">{gettext("(opens in a new tab)")}</span>
            </.link>
            <%!-- In-context (front-end) editing on Kiln's own rendered page (#354). --%>
            <.link
              navigate={~p"/editor/site/#{@kind}/#{@record.slug}"}
              class="btn btn-sm btn-default"
            >
              <.icon name="hero-pencil-square" class="mr-1 size-4" />{gettext("Edit on page")}
            </.link>
            <.autosave_status
              :if={@record.state == :draft or @save_state != :saved}
              state={@save_state}
            />
            <.workflow_buttons state={@record.state} actor={@actor} />
            <.button
              type="submit"
              variant="primary"
              disabled={@conflict}
              phx-disable-with={gettext("Saving…")}
              title={@conflict && gettext("Reload to resolve the edit conflict before saving.")}
            >
              {gettext("Save")}
            </.button>
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
                          class="cursor-grab text-base-content/70 hover:text-base-content/70"
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
                            class="text-base-content/70 hover:text-base-content/70 disabled:cursor-not-allowed disabled:opacity-30"
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
                            class="text-base-content/70 hover:text-base-content/70 disabled:cursor-not-allowed disabled:opacity-30"
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
                        data-confirm={gettext("Delete this block? This can't be undone.")}
                        aria-label={gettext("Remove block")}
                        class="text-base-content/70 hover:text-error"
                      >
                        <.icon name="hero-trash" class="size-5" />
                      </button>
                    </div>
                    <%!-- The collab lock UI (ring + "who's editing" badge) lives on
                          this non-ignored wrapper so it can update, while the inner
                          editor stays phx-update="ignore" (#140). --%>
                    <div
                      :if={block_type_string(bf) == "rich_text"}
                      class={["relative", lock_ring(@locked_fields, bf[:legacy_html].name)]}
                    >
                      <.field_cursors field={bf[:legacy_html].name} cursors={@cursors} />
                      <div
                        id={"rt-#{bf.index}-v#{@editor_version}"}
                        phx-hook="RichText"
                        phx-update="ignore"
                        data-content={bf[:legacy_html].value || ""}
                        data-editor-label={gettext("Rich text editor")}
                        data-lock-field={bf[:legacy_html].name}
                        data-collab-token={@collab_token}
                        data-collab-topic={@collab_token && @collab_topic}
                        data-collab-fragment={@collab_token && collab_fragment(bf)}
                        data-collab-user={@collab_token && initials(Presence.display_name(@actor))}
                        data-collab-color={@collab_token && color_hex_for(@actor.id)}
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
                        <%!-- Distinguish this in-text slash menu from the block
                              inserter's "Add block /" so the two / systems are
                              clearly scoped (#150). --%>
                        <p class="mt-1 text-xs text-base-content/70">
                          {gettext("Type / for text formatting within this block.")}
                        </p>
                        <input
                          type="hidden"
                          name={bf[:legacy_html].name}
                          value={bf[:legacy_html].value}
                          data-input
                        />
                      </div>
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
                    <.columns_editor
                      :if={block_type_string(bf) == "columns"}
                      bf={bf}
                      columns={col_state(@block_children, bf)}
                      child_types={@nested_child_types}
                    />
                    <div :if={block_type_string(bf) not in ["rich_text", "image", "columns"]}>
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
                  :if={length(@audiences) > 1}
                  field={@form[:audience]}
                  type="select"
                  label={gettext("Audience")}
                  options={@audiences}
                />

                <.tag_picker form={@form} tags={@tags} record={@record} />

                <.featured_image_field form={@form} media={@media} />

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

            <details
              :if={@field_definitions != []}
              class="rounded border border-base-content/15 p-3"
              open={any_custom_field_errors?(@form, @field_definitions)}
            >
              <summary class="cursor-pointer text-sm font-medium">
                {gettext("Custom fields")}
              </summary>
              <div class="mt-3 space-y-3">
                <.custom_field_input
                  :for={definition <- @field_definitions}
                  definition={definition}
                  name={"#{@form.name}[custom_fields][#{definition.name}]"}
                  value={custom_field_value(@form, definition.name)}
                  errors={custom_field_errors(@form, definition.name)}
                  options={custom_field_options(definition, @media, @reference_options)}
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
                <%!-- The visible input edits local wall-clock time; the hidden
                      input carries the UTC instant (UtcDatetimeInput hook).
                      Keyed on editor_version so conflict reloads / restores
                      remount it from the fresh form (as rich text does). --%>
                <div
                  id={"scheduled-at-#{@editor_version}"}
                  phx-hook="UtcDatetimeInput"
                  phx-update="ignore"
                >
                  <label
                    for={"scheduled-at-local-#{@editor_version}"}
                    class="mb-1 block text-sm font-medium"
                  >
                    {gettext("Scheduled publish at")}
                  </label>
                  <input
                    type="datetime-local"
                    id={"scheduled-at-local-#{@editor_version}"}
                    data-local-input
                    class="field-input"
                  />
                  <input
                    type="hidden"
                    name={@form[:scheduled_at].name}
                    value={@form[:scheduled_at].value && to_string(@form[:scheduled_at].value)}
                    data-utc-input
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Shown in your local timezone; stored as UTC.")}
                  </p>
                </div>
                <%!-- The embargo end — same local/UTC input pair as above. --%>
                <div
                  id={"unpublish-at-#{@editor_version}"}
                  phx-hook="UtcDatetimeInput"
                  phx-update="ignore"
                >
                  <label
                    for={"unpublish-at-local-#{@editor_version}"}
                    class="mb-1 block text-sm font-medium"
                  >
                    {gettext("Scheduled unpublish at")}
                  </label>
                  <input
                    type="datetime-local"
                    id={"unpublish-at-local-#{@editor_version}"}
                    data-local-input
                    class="field-input"
                  />
                  <input
                    type="hidden"
                    name={@form[:unpublish_at].name}
                    value={@form[:unpublish_at].value && to_string(@form[:unpublish_at].value)}
                    data-utc-input
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Published content is taken back to draft at this time.")}
                  </p>
                </div>
              </div>
            </details>

            <details
              :if={length(@translations) > 1}
              class="rounded border border-base-content/15 p-3"
              open
            >
              <summary class="cursor-pointer text-sm font-medium">
                {gettext("Translations")}
              </summary>
              <ul class="mt-3 space-y-2">
                <li
                  :for={cov <- @translations}
                  class="flex items-center justify-between gap-3 text-sm"
                >
                  <span class="flex items-center gap-2">
                    <span class="font-mono text-xs font-semibold uppercase">{cov.locale}</span>
                    <span
                      :if={cov.record && cov.record.id == @record.id}
                      class="text-xs text-base-content/50"
                    >
                      {gettext("(this one)")}
                    </span>
                    <span
                      :if={cov.stale?}
                      class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"
                      title={gettext("The source locale was updated after this translation.")}
                    >
                      {gettext("Outdated")}
                    </span>
                  </span>
                  <span
                    :if={cov.record && cov.record.id == @record.id}
                    class="text-xs text-base-content/70"
                  >
                    {state_label(cov.status)}
                  </span>
                  <.link
                    :if={cov.record && cov.record.id != @record.id}
                    navigate={~p"/editor/content/#{@kind}/#{cov.record.id}"}
                    class="text-xs text-primary hover:underline"
                  >
                    {state_label(cov.status)} — {gettext("edit")}
                  </.link>
                  <button
                    :if={is_nil(cov.record)}
                    type="button"
                    phx-click="create_translation"
                    phx-value-locale={cov.locale}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Create translation")}
                  </button>
                </li>
              </ul>
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
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Restore")}
                  </button>
                </li>
              </ul>
            </details>
          </div>

          <div class="lg:sticky lg:top-4 lg:self-start">
            <%!-- Mobile (#138): a collapsed disclosure so the preview doesn't bury
                  the form's Save/SEO/version sections below a full-height panel. --%>
            <details class="rounded border border-base-content/15 p-3 lg:hidden">
              <summary class="cursor-pointer text-lg font-medium">{gettext("Preview")}</summary>
              <div class="mt-3">
                <.preview_article form={@form} html={@preview_html} />
              </div>
            </details>

            <%!-- Desktop: the preview sits inline as the sticky second column. --%>
            <div class="hidden lg:block">
              <h2 class="mb-2 text-lg font-medium">{gettext("Preview")}</h2>
              <.preview_article form={@form} html={@preview_html} />
            </div>
          </div>
        </div>
      </.form>

      <.image_picker
        :if={@picking != nil}
        index={@picking}
        media={@media}
        results={@picker_media}
        query={@media_query}
      />
    </Layouts.console>
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
          {initials(e.name)}
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

  # The live preview article (title + rendered blocks). Shared by the desktop
  # sticky column and the mobile collapsible disclosure (#138). The previewed
  # title is an h2 so the editor keeps a single logical h1 (#174).
  attr :form, :any, required: true
  attr :html, :any, required: true

  defp preview_article(assigns) do
    ~H"""
    <article class="prose max-w-none space-y-3 rounded border border-base-content/15 p-5">
      <h2 class="text-2xl font-bold">{@form[:title].value}</h2>
      {@html}
    </article>
    """
  end

  attr :state, :atom, required: true

  # Draft autosave indicator shown next to the workflow/Save buttons. Covers the
  # in-flight (:saving) and validation-failure (:error) states too (#136).
  defp autosave_status(assigns) do
    ~H"""
    <span
      class={["text-xs", (@state == :error && "text-error") || "text-base-content/70"]}
      aria-live="polite"
    >
      <%= case @state do %>
        <% :saving -> %>
          {gettext("Saving…")}
        <% :saved -> %>
          {gettext("Saved")}
        <% :synced -> %>
          <%!-- Collab: a co-editor persists; text edits are already in the
                shared doc. Fields outside the text still need Save. --%>
          {gettext("Synced live — co-editor saves")}
        <% :error -> %>
          {gettext("Couldn't autosave — check for errors")}
        <% _ -> %>
          {gettext("Unsaved changes")}
      <% end %>
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
      phx-disable-with={gettext("Submitting…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Submit for review")}
    </button>
    <button
      :if={@state in [:draft, :in_review] and @actor.role == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="publish"
      phx-disable-with={gettext("Publishing…")}
      class="btn btn-sm btn-default"
    >
      {if @state == :in_review, do: gettext("Approve & publish"), else: gettext("Publish")}
    </button>
    <button
      :if={@state == :in_review and @actor.role == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="return"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Request changes")}
    </button>
    <span
      :if={@state == :in_review and @actor.role == :editor}
      class="text-xs text-base-content/70"
    >
      {gettext("Awaiting admin approval")}
    </span>
    <button
      :if={@state == :published}
      type="button"
      phx-click="workflow"
      phx-value-action="unpublish"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unpublish")}
    </button>
    <button
      :if={@state == :archived}
      type="button"
      phx-click="workflow"
      phx-value-action="unarchive"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unarchive")}
    </button>
    """
  end
end
