defmodule KilnCMSWeb.InContextEditLive do
  @moduledoc """
  In-context (front-end) editing on Kiln's own rendered site (#354).

  Unlike a headless CMS — where the front end is decoupled and a fragile DOM→field
  bridge is needed — Kiln renders its own pages, so it already knows which typed
  block produced each region. This LiveView re-renders a content record's page
  **from the live draft** (never the fired/published artifacts, which stay
  read-only) and lets an editor edit text regions *in place*: headings, quotes,
  and rich-text blocks become `contenteditable`, and edits write straight through
  the same Ash `:update`/`:autosave` actions the structured editor uses — so
  policies (#332) and PaperTrail versioning are native, with no separate write path.

  Scope is inline text editing of existing blocks plus drag-and-drop (and
  keyboard) reordering. Structural add / delete of blocks belongs to the block
  editor and page-building (#335) and stays out of scope — the "Open full editor"
  link covers it.

  Editor/admin only (mounted in the `:editor_routes` live session). The per-type
  authoring scope is enforced by the resource policies at save time, exactly as in
  `KilnCMSWeb.ContentEditorLive`.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.EditorTelemetry

  # Block types that support inline editing, mapped to the single form field the
  # editable region writes. `:html` fields carry sanitized rich-text HTML (the
  # `BlockUnion` cast re-sanitizes on write); `:text` fields are plain strings.
  @inline_fields %{
    "heading" => {"text", :text},
    "quote" => {"text", :text},
    "rich_text" => {"legacy_html", :html}
  }

  # Idle delay before a draft edit autosaves. Runtime-configurable so callers can
  # tune it; tests drive the autosave deterministically instead of waiting.
  @autosave_debounce_ms Application.compile_env(
                          :kiln_cms,
                          [:in_context_editor, :autosave_debounce_ms],
                          1_500
                        )

  @impl true
  def mount(%{"type" => type, "slug" => slug}, _session, socket) do
    actor = socket.assigns.current_user

    case ContentTypes.get(type) do
      nil ->
        {:ok, redirect_to_editor(socket, gettext("Unknown content type."))}

      ct ->
        case fetch_by_slug(ct.type, slug, actor) do
          nil ->
            {:ok, redirect_to_editor(socket, gettext("No such content to edit."))}

          record ->
            {:ok,
             socket
             |> assign(:kind, ct.type)
             |> assign(:ct, ct)
             |> assign(:actor, actor)
             |> assign(:autosave_timer, nil)
             |> assign(:save_state, :saved)
             |> assign(:conflict, false)
             |> assign(:moved_announcement, nil)
             # Bumped on server-driven form replacement (save/restore/reload) so the
             # `phx-update="ignore"` editable regions remount and reload from the
             # fresh content rather than keeping the stale DOM they own.
             |> assign(:region_version, 0)
             |> assign_record(record)}
        end
    end
  end

  # The editable record for a public slug. Editors may read any state (see the
  # content read policy), so this returns the live working copy — draft or
  # published — whose `blocks` the page renders and edits write to.
  defp fetch_by_slug(kind, slug, actor) do
    case ContentTypes.list!(kind,
           actor: actor,
           query: [filter: [slug: slug], select: [:id], limit: 1]
         ) do
      [%{id: id} | _] ->
        ContentTypes.get_record!(kind, id,
          actor: actor,
          load: [:category, :featured_image, :tags]
        )

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp assign_record(socket, record) do
    typed = TypedBlocks.to_typed(record.blocks)

    socket
    |> assign(:record, record)
    |> assign(:page_title, record.title)
    # The working set edits mutate: the full block list as `BlockUnion` input
    # maps (each carrying its stable id + `_type`), so a save rewrites every
    # block — the edited one changed, the rest byte-for-byte — with identity
    # intact. Kept alongside the display descriptors so one edit can't drop a
    # sibling block the way a partial form-params merge would.
    |> assign(:block_inputs, Enum.map(typed, &TypedBlocks.input_map/1))
    |> assign(:blocks, editable_blocks(typed))
  end

  # The record's typed blocks as flat render descriptors, keeping each block's
  # absolute position (`index`) in the `blocks` array. `field`/`mode` are set for
  # the inline editable types and nil for read-only ones (image/divider/embed/…).
  defp editable_blocks(typed) do
    typed
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      type = to_string(block._type)
      {field, mode} = Map.get(@inline_fields, type, {nil, nil})

      %{
        id: block.id,
        index: index,
        type: type,
        field: field,
        mode: mode,
        value: inline_value(block, field),
        struct: block
      }
    end)
  end

  # The current text/HTML for an inline field; empty string when unset so the
  # contenteditable region mounts with a stable (non-nil) value.
  defp inline_value(_block, nil), do: nil
  defp inline_value(block, field), do: Map.get(block, String.to_existing_atom(field)) || ""

  # ── events ────────────────────────────────────────────────────────────────

  @impl true
  # An inline region reports its edited text/HTML. Update just that block's field
  # in the working set (every other block and its stable id untouched) and persist
  # as a draft autosave, or mark it for an explicit Save on non-draft content.
  def handle_event("update_block", %{"id" => id, "value" => value}, socket) do
    case block_target(socket, id) do
      {index, field} ->
        inputs = List.update_at(socket.assigns.block_inputs, index, &Map.put(&1, field, value))
        {:noreply, socket |> assign(:block_inputs, inputs) |> mark_dirty()}

      :error ->
        {:noreply, socket}
    end
  end

  # Drag-and-drop reorder (the `Sortable` hook pushes the new order of block ids).
  # Reordering is a structural edit, but a single-block move is cheap and stays on
  # the inline surface; add/remove of blocks remains in the full editor (#335).
  def handle_event("reorder", %{"order" => order}, socket) do
    case reordered(socket, order) do
      {:ok, socket} -> {:noreply, mark_dirty(socket)}
      :noop -> {:noreply, socket}
    end
  end

  # Keyboard-accessible reorder (the up/down buttons), so reordering isn't
  # drag-only (mirrors the block editor's #171 controls). Announces the move.
  def handle_event("move_block", %{"id" => id, "dir" => dir}, socket) do
    ids = Enum.map(socket.assigns.blocks, &to_string(&1.id))

    with {order, pos} <- neighbor_swap(ids, id, dir),
         {:ok, socket} <- reordered(socket, order) do
      {:noreply,
       socket
       |> mark_dirty()
       |> assign(
         :moved_announcement,
         gettext("Moved block to position %{pos} of %{count}", pos: pos + 1, count: length(ids))
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  # Explicit save (the toolbar Save button, and the only save path for non-draft
  # content). Optimistic-lock conflicts pause with a banner rather than clobbering
  # a concurrent edit.
  def handle_event("save", _params, socket) do
    socket = cancel_autosave_timer(socket)

    case persist(socket, :update) do
      {:ok, socket} -> {:noreply, put_flash(socket, :info, gettext("Saved."))}
      {:conflict, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, put_flash(socket, :error, gettext("Couldn't save."))}
    end
  end

  # Discard local edits and reload the latest saved version, clearing a conflict.
  def handle_event("reload", _params, socket) do
    {:noreply,
     socket
     |> cancel_autosave_timer()
     |> assign_record(reload(socket, socket.assigns.record.id))
     |> reset_regions()
     |> assign(:conflict, false)
     |> assign(:save_state, :saved)
     |> put_flash(:info, gettext("Reloaded the latest version."))}
  end

  @impl true
  def handle_info(:autosave, socket), do: {:noreply, perform_autosave(socket)}

  # ── save-state machine (mirrors ContentEditorLive) ──────────────────────────

  defp mark_dirty(socket) do
    if draft?(socket) do
      socket
      |> cancel_autosave_timer()
      |> assign(:autosave_timer, Process.send_after(self(), :autosave, @autosave_debounce_ms))
      |> assign(:save_state, :saving)
    else
      assign(socket, :save_state, :unsaved)
    end
  end

  defp perform_autosave(%{assigns: %{save_state: :saving}} = socket) do
    socket = assign(socket, :autosave_timer, nil)

    if draft?(socket) do
      {_, socket} = persist(socket, :autosave)
      socket
    else
      socket
    end
  end

  # Stale timer (already saved, or an intervening explicit save) — no-op.
  defp perform_autosave(socket), do: assign(socket, :autosave_timer, nil)

  # Write the current working block set through Ash. `:update` (explicit Save) and
  # `:autosave` (debounced draft) share this — the `:autosave` action tags and
  # coalesces its PaperTrail versions so an edit-per-pause doesn't flood history.
  # Returns `{:ok | :conflict | :error, socket}` with the save state applied.
  defp persist(socket, action) do
    # `:update` shares the `:save` telemetry event with the structured editor.
    event = if action == :autosave, do: :autosave, else: :save

    result =
      EditorTelemetry.span(event, %{kind: socket.assigns.kind}, fn ->
        socket.assigns.record
        |> Ash.Changeset.for_update(action, %{blocks: socket.assigns.block_inputs},
          actor: socket.assigns.actor
        )
        |> Ash.update()
      end)

    case result do
      {:ok, record} ->
        {:ok,
         socket
         |> assign_record(reload(socket, record.id))
         |> reset_regions()
         |> assign(:save_state, :saved)}

      {:error, error} ->
        if stale_conflict?(error),
          do: {:conflict, flag_conflict(socket)},
          else: {:error, assign(socket, :save_state, :error)}
    end
  end

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

  defp cancel_autosave_timer(socket) do
    if ref = socket.assigns.autosave_timer, do: Process.cancel_timer(ref)
    assign(socket, :autosave_timer, nil)
  end

  # Bump the region key so every editable region remounts and reloads its content
  # from the freshly-saved form (the regions are otherwise browser-owned).
  defp reset_regions(socket), do: update(socket, :region_version, &(&1 + 1))

  defp reload(socket, id),
    do: ContentTypes.get_record!(socket.assigns.kind, id, actor: socket.assigns.actor)

  defp draft?(socket), do: socket.assigns.record.state == :draft

  # {block index, field name} for the edited block id, or :error if it isn't an
  # inline-editable block on this record.
  defp block_target(socket, id) do
    case Enum.find(socket.assigns.blocks, &(&1.id == id and &1.field != nil)) do
      %{index: index, field: field} -> {index, field}
      _ -> :error
    end
  end

  # The id order that swaps block `id` with its neighbour in `dir` (`"up"`/down),
  # plus the target position, or nil if there's no neighbour that way.
  defp neighbor_swap(ids, id, dir) do
    i = Enum.find_index(ids, &(&1 == id))
    j = if dir == "up", do: i && i - 1, else: i && i + 1

    if (i && j && j >= 0) and j < length(ids) do
      {ids |> List.replace_at(i, Enum.at(ids, j)) |> List.replace_at(j, id), j}
    end
  end

  # Reorder the working set (both the save inputs and the render descriptors) to
  # match `order`, a list of block-id strings. Returns `:noop` — never a partial
  # order — unless `order` is exactly a permutation of the current block ids, so a
  # stray/missing id (e.g. a not-yet-backfilled null-id block whose sort key is "")
  # can never silently drop a block on the next save.
  defp reordered(socket, order) do
    inputs_by_id = Map.new(socket.assigns.block_inputs, &{to_string(&1["id"]), &1})
    blocks_by_id = Map.new(socket.assigns.blocks, &{to_string(&1.id), &1})
    current = MapSet.new(Map.keys(blocks_by_id))

    if length(order) == map_size(blocks_by_id) and MapSet.equal?(MapSet.new(order), current) do
      inputs = Enum.map(order, &Map.fetch!(inputs_by_id, &1))

      blocks =
        order
        |> Enum.map(&Map.fetch!(blocks_by_id, &1))
        |> Enum.with_index()
        |> Enum.map(fn {block, index} -> %{block | index: index} end)

      {:ok, socket |> assign(:block_inputs, inputs) |> assign(:blocks, blocks)}
    else
      :noop
    end
  end

  # True when a failed update was rejected by the optimistic lock (the row moved
  # underneath us) rather than by ordinary validation.
  defp stale_conflict?(error), do: stale_error?(error)

  defp stale_error?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_error?/1)

  defp stale_error?(_other), do: false

  defp redirect_to_editor(socket, message) do
    socket |> put_flash(:error, message) |> push_navigate(to: ~p"/editor")
  end

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public locale_links={[]} locale={@record.locale}>
      <Layouts.flash_group flash={@flash} />
      <.edit_bar
        record={@record}
        kind={@kind}
        ct={@ct}
        save_state={@save_state}
        conflict={@conflict}
      />

      <article class="prose max-w-none">
        <h1 class="text-3xl font-bold tracking-tight">{@record.title}</h1>

        <p :if={@blocks == []} class="mt-6 text-base-content/70">
          {gettext("This page has no text blocks to edit inline yet.")}
          <.link navigate={~p"/editor/content/#{@kind}/#{@record.id}"} class="underline">
            {gettext("Open the full editor")}
          </.link>
          {gettext("to add blocks.")}
        </p>

        <%!-- Announces keyboard reorder moves to screen readers (mirrors #171). --%>
        <p class="sr-only" role="status" aria-live="polite">{@moved_announcement}</p>

        <div id="in-context-blocks" phx-hook="Sortable" class="mt-6 space-y-4">
          <div
            :for={block <- @blocks}
            id={"block-wrap-#{block.id}"}
            data-sort-id={block.id}
            class="group relative"
          >
            <div class="absolute -left-9 top-0 hidden items-center gap-0.5 pr-1 group-hover:flex group-focus-within:flex">
              <span
                data-drag-handle
                aria-label={gettext("Drag to reorder")}
                class="cursor-grab text-base-content/40 hover:text-base-content/70"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </span>
              <div class="flex flex-col">
                <button
                  type="button"
                  phx-click="move_block"
                  phx-value-id={block.id}
                  phx-value-dir="up"
                  disabled={block.index == 0}
                  aria-label={gettext("Move block up")}
                  class="text-base-content/40 hover:text-base-content/70 disabled:opacity-30"
                >
                  <.icon name="hero-chevron-up" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="move_block"
                  phx-value-id={block.id}
                  phx-value-dir="down"
                  disabled={block.index == length(@blocks) - 1}
                  aria-label={gettext("Move block down")}
                  class="text-base-content/40 hover:text-base-content/70 disabled:opacity-30"
                >
                  <.icon name="hero-chevron-down" class="size-4" />
                </button>
              </div>
            </div>
            <.block block={block} region_version={@region_version} />
          </div>
        </div>
      </article>
    </Layouts.public>
    """
  end

  # A fixed toolbar naming what's being edited, its save state, and the escape
  # hatches to the structured editor / published page.
  attr :record, :any, required: true
  attr :kind, :any, required: true
  attr :ct, :map, required: true
  attr :save_state, :atom, required: true
  attr :conflict, :boolean, required: true

  defp edit_bar(assigns) do
    ~H"""
    <div
      id="in-context-edit-bar"
      class="sticky top-0 z-40 -mx-4 mb-6 flex flex-wrap items-center justify-between gap-3 border-b border-base-content/10 bg-base-100/95 px-4 py-3 backdrop-blur sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8"
    >
      <div class="flex items-center gap-2 text-sm">
        <span class="inline-flex items-center gap-1.5 rounded bg-primary/10 px-2 py-1 font-medium text-primary">
          <.icon name="hero-pencil-square" class="size-4" />
          {gettext("Editing in place")}
        </span>
        <span class="text-base-content/70">
          {gettext("State:")} <span class="font-medium">{@record.state}</span>
        </span>
        <span
          id="in-context-save-state"
          data-state={@save_state}
          class="text-xs text-base-content/60"
        >
          {save_label(@save_state)}
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="save"
          disabled={@conflict}
          class="btn btn-sm btn-primary disabled:opacity-50"
        >
          {gettext("Save")}
        </button>
        <.link
          navigate={~p"/editor/content/#{@kind}/#{@record.id}"}
          class="btn btn-sm btn-default"
        >
          {gettext("Open full editor")}
        </.link>
        <.link
          :if={@record.state == :published}
          href={published_path(@ct, @record)}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-sm btn-default"
        >
          {gettext("View published")} &nearr;
          <span class="sr-only">{gettext("(opens in a new tab)")}</span>
        </.link>
      </div>

      <div
        :if={@conflict}
        id="in-context-conflict"
        role="alert"
        class="w-full rounded border border-warning/50 bg-warning/10 px-3 py-2 text-sm"
      >
        {gettext("Someone else saved changes to this content.")}
        <button type="button" phx-click="reload" class="ml-2 font-medium underline">
          {gettext("Reload latest")}
        </button>
      </div>
    </div>
    """
  end

  attr :block, :map, required: true
  attr :region_version, :integer, required: true

  # Inline heading — a `contenteditable` <h2> matching the public block styling.
  defp block(%{block: %{type: "heading"}} = assigns) do
    ~H"""
    <div class="kiln-block">
      <h2
        id={region_id(@block, @region_version)}
        phx-hook="InlineText"
        phx-update="ignore"
        contenteditable="true"
        role="textbox"
        aria-label={gettext("Edit heading")}
        data-kiln-block-id={@block.id}
        class="text-xl font-bold outline-none focus:ring-2 focus:ring-primary/40 focus:ring-offset-2"
      >{@block.value}</h2>
    </div>
    """
  end

  defp block(%{block: %{type: "quote"}} = assigns) do
    ~H"""
    <div class="kiln-block">
      <blockquote
        id={region_id(@block, @region_version)}
        phx-hook="InlineText"
        phx-update="ignore"
        contenteditable="true"
        role="textbox"
        aria-label={gettext("Edit quote")}
        data-kiln-block-id={@block.id}
        class="border-l-4 border-base-300 pl-3 italic outline-none focus:ring-2 focus:ring-primary/40"
      >{@block.value}</blockquote>
    </div>
    """
  end

  # Inline rich text — a TipTap editor is mounted into this region (seeded from
  # `data-content`); a floating toolbar appears on focus. `phx-update="ignore"`
  # hands the DOM to TipTap; the seed HTML keeps the region readable without JS.
  # The value is rich-text HTML the `BlockUnion` cast sanitized on write (same
  # allowlist as public delivery), so raw rendering is safe here.
  # sobelow_skip ["XSS.Raw"]
  defp block(%{block: %{type: "rich_text"}} = assigns) do
    ~H"""
    <div class="kiln-block">
      <div
        id={region_id(@block, @region_version)}
        phx-hook="InlineRichText"
        phx-update="ignore"
        data-kiln-block-id={@block.id}
        data-content={@block.value}
        data-editor-label={gettext("Edit rich text")}
        class="rounded outline-none focus-within:ring-2 focus-within:ring-primary/40"
      >
        {Phoenix.HTML.raw(@block.value)}
      </div>
    </div>
    """
  end

  # Read-only blocks (image, divider, embed, form, custom): rendered through the
  # shared public component, un-editable in Phase 1.
  defp block(assigns) do
    assigns = assign(assigns, :legacy, read_only_block(assigns.block.struct))

    ~H"""
    <div class="kiln-block relative" title={gettext("Edit this block in the full editor")}>
      <BlockComponents.render_block block={@legacy} />
    </div>
    """
  end

  # A minimal legacy-shaped map for the public renderer. Media enrichment
  # (srcset/focal) is a delivery concern; the edit surface renders the plain
  # source, which is enough to keep the page's shape recognizable.
  #
  # A `columns` container (#335) is rendered through the shared thin-map builder
  # so its nested children show in place (read-only here — structural nested
  # edits live in the full editor, like the other non-text blocks on this surface).
  defp read_only_block(%KilnCMS.Blocks.Columns{} = struct) do
    [legacy] = TypedBlocks.to_legacy([struct])
    [thin] = BlockComponents.thin_blocks([legacy])
    thin
  end

  defp read_only_block(struct) do
    [legacy] = TypedBlocks.to_legacy([struct])
    base = %{type: to_string(legacy.type), content: legacy.content}

    case to_string(legacy.type) do
      "image" -> Map.put(base, :alt, Map.get(legacy.data, "alt") || "")
      _ -> base
    end
  end

  # Stable-id region element id, keyed by `region_version` so a save/restore
  # remounts the region and reloads its content.
  defp region_id(block, version), do: "region-#{block.id}-v#{version}"

  defp published_path(ct, record) do
    prefix = if record.locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{record.locale}"
    "#{prefix}#{ContentTypes.public_prefix(ct)}/#{record.slug}"
  end

  defp save_label(:saved), do: gettext("All changes saved")
  defp save_label(:saving), do: gettext("Saving…")
  defp save_label(:unsaved), do: gettext("Unsaved changes")
  defp save_label(:error), do: gettext("Save failed")
end
