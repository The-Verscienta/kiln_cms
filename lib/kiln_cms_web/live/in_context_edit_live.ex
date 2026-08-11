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
  # Shared inline-editing engine (block working set + Ash write path), also used
  # by the Presentation console (#355).
  alias KilnCMSWeb.InlineEditing

  # Idle delay before a draft edit autosaves. Runtime-configurable so callers can
  # tune it; tests drive the autosave deterministically instead of waiting.
  @autosave_debounce_ms Application.compile_env(
                          :kiln_cms,
                          [:in_context_editor, :autosave_debounce_ms],
                          1_500
                        )

  @impl true
  def mount(%{"type" => type, "slug" => slug} = params, _session, socket) do
    actor = socket.assigns.current_user
    locale = locale_param(params)

    # Each failure has its own answer, so they are tagged rather than collapsed
    # into one "no such content": an unwritable record is not a missing one, and
    # the reader is sent somewhere useful.
    with ct when not is_nil(ct) <- ContentTypes.get(type),
         record when not is_nil(record) <-
           fetch_by_slug(ct.type, slug, locale, actor, socket.assigns.current_org),
         {true, _ct, _record} <-
           {may_write?(record, actor, socket.assigns.current_org), ct, record} do
      {:ok, socket |> assign(:may_write?, true) |> mount_editor(ct, record, actor, params)}
    else
      # Read-only visitors get the read-only surface, not an editor that accepts
      # a page of typing and refuses all of it on Save (#1159).
      {false, ct, record} ->
        {:ok,
         socket
         |> put_flash(:info, gettext("You can view this content but not edit it."))
         |> push_navigate(to: ~p"/editor/preview/#{ct.type}/#{record.id}")}

      nil ->
        {:ok, redirect_to_editor(socket, gettext("No such content to edit."))}
    end
  end

  # Whether the actor may WRITE this record, the concept this console never had
  # (#1159). `/editor/site/...` sits in the editor-tier live_session, and that
  # gate is coarser than it looks: `Checks.ReadableContentType` lets an editor
  # restricted to other types read this one exactly as a signed-in consumer
  # does, so they can open a published page they may not author. Everything on
  # this screen then works — the regions are `contenteditable`, drag-reorder
  # runs, Save is present — until the update is refused and a page of typing is
  # gone.
  #
  # Keyed on `:autosave`, the same action `ContentEditorLive.may_write?/3` asks
  # about, so the two consoles cannot disagree about who may edit a record.
  defp may_write?(record, actor, org), do: Ash.can?({record, :autosave}, actor, tenant: org)

  defp mount_editor(socket, ct, record, actor, params) do
    socket
    |> assign(:kind, ct.type)
    |> assign(:ct, ct)
    |> assign(:actor, actor)
    # Deep-link target from the visual-editing bridge (#355):
    # `?focus=<block_id>` scrolls to and focuses that block on load.
    |> assign(:focus_block_id, params["focus"])
    |> assign(:autosave_timer, nil)
    |> assign(:save_state, :saved)
    |> assign(:conflict, false)
    |> assign(:moved_announcement, nil)
    # Bumped on server-driven form replacement (save/restore/reload) so the
    # `phx-update="ignore"` editable regions remount and reload from the
    # fresh content rather than keeping the stale DOM they own.
    |> assign(:region_version, 0)
    |> assign_record(record)
  end

  # The editable record for a public slug: the live working copy — draft or
  # published — whose `blocks` the page renders and edits write to.
  #
  # NOT "editors may read any state". That was the comment here, and it is false
  # for a restricted editor (#1159): `Checks.ReadableContentType` grants the
  # see-everything read only for types in the actor's `readable_types` scope,
  # and an out-of-scope type falls through to the published/audience filters —
  # so this can return a *published* record to someone who may not author it,
  # which is exactly why `mount/3` now asks whether they may write it.
  defp fetch_by_slug(kind, slug, locale, actor, org) do
    # Scope to the current site's org (epic #336) so in-context editing on one
    # site's host only resolves that site's content.
    #
    # Locale is part of the identity (`[slug, locale]`). Absent `?locale=` falls
    # back to the default — an older bridge or a hand-typed URL (#1104). Shared
    # block ids across locale variants (#502) make loading the wrong variant a
    # silent cross-locale write.
    case ContentTypes.list!(kind,
           actor: actor,
           tenant: org,
           query: [
             filter: [slug: slug, locale: locale],
             select: [:id],
             limit: 1
           ]
         ) do
      [%{id: id} | _] ->
        ContentTypes.get_record!(kind, id,
          actor: actor,
          tenant: org,
          load: [:category, :featured_image, :tags]
        )

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp locale_param(params) do
    KilnCMSWeb.Params.string(params, "locale", KilnCMS.I18n.default_locale())
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
    |> assign(:block_inputs, InlineEditing.block_inputs(typed))
    |> assign(:blocks, InlineEditing.editable_blocks(typed))
  end

  # ── events ────────────────────────────────────────────────────────────────

  @impl true
  # An inline region reports its edited text/HTML. Update just that block's field
  # in the working set (every other block and its stable id untouched) and persist
  # as a draft autosave, or mark it for an explicit Save on non-draft content.
  #
  # `value` is a binary for a plain-text region and a TipTap document (a map)
  # for a rich one, so both shapes are the contract. A LIST is not, and is the
  # shape worth excluding: `PortableText.from_tiptap/1` returns a list
  # unchanged, so `"value" => [%{"_type" => "block", ...}]` would have written
  # a client-authored body straight into the block without normalisation.
  def handle_event("update_block", %{"id" => id, "value" => value}, socket)
      when is_binary(id) and (is_binary(value) or is_map(value)) do
    case block_target(socket, id) do
      {index, field} ->
        inputs = InlineEditing.put_block_field(socket.assigns.block_inputs, index, field, value)
        {:noreply, socket |> assign(:block_inputs, inputs) |> mark_dirty()}

      :error ->
        {:noreply, socket}
    end
  end

  # Drag-and-drop reorder (the `Sortable` hook pushes the new order of block ids).
  # Reordering is a structural edit, but a single-block move is cheap and stays on
  # the inline surface; add/remove of blocks remains in the full editor (#335).
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    case reordered(socket, order) do
      {:ok, socket} -> {:noreply, mark_dirty(socket)}
      :noop -> {:noreply, socket}
    end
  end

  # Keyboard-accessible reorder (the up/down buttons), so reordering isn't
  # drag-only (mirrors the block editor's #171 controls). Announces the move.
  def handle_event("move_block", %{"id" => id, "dir" => dir}, socket)
      when is_binary(id) and is_binary(dir) do
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
  # The mount decision, re-asserted at the write. `mount/3` refuses with
  # `push_navigate`, which ends the LiveView — so the guarantee holds only by
  # accident of how the refusal is spelled. Render a "read-only" panel instead,
  # an ordinary refactor, and every write below becomes reachable. This is the
  # one funnel they all pass through (#1159).
  #
  # The ASSIGN, not a fresh `Ash.can?`. Recomputing it here would rebuild the
  # whole `:autosave` changeset — a `field_definitions` read plus the policy
  # chain — on every debounce, which is the editor's hottest path, and would
  # answer from the same mount-time actor regardless. `ContentEditorLive`
  # computes it once per record load for the same reason.
  #
  # Be exact about what it therefore does NOT do: a scope narrowed mid-session
  # is invisible. Measured — the save still lands. Catching that needs the actor
  # re-read per write, which no console does; diverging from them would be worse
  # than the gap. This guards the refactor, not the revocation.
  defp persist(socket, action) do
    if socket.assigns.may_write? do
      do_persist(socket, action)
    else
      # Same shape as `do_persist/2`'s own error branch, so a refusal cannot
      # leave the toolbar stuck on "Saving…" with nothing said — which is what
      # `perform_autosave/1` would do with a bare `{:error, socket}`, since it
      # discards the tag.
      {:error, assign(socket, :save_state, :error)}
    end
  end

  defp do_persist(socket, action) do
    # `:update` shares the `:save` telemetry event with the structured editor.
    event = if action == :autosave, do: :autosave, else: :save

    result =
      EditorTelemetry.span(event, %{kind: socket.assigns.kind}, fn ->
        InlineEditing.write(
          socket.assigns.record,
          action,
          socket.assigns.block_inputs,
          socket.assigns.actor
        )
      end)

    case result do
      {:ok, record} ->
        {:ok,
         socket
         |> assign_record(reload(socket, record.id))
         |> reset_regions()
         |> assign(:save_state, :saved)}

      :conflict ->
        {:conflict, flag_conflict(socket)}

      {:error, _error} ->
        {:error, assign(socket, :save_state, :error)}
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
    do:
      ContentTypes.get_record!(socket.assigns.kind, id,
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org
      )

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

  defp redirect_to_editor(socket, message) do
    socket |> put_flash(:error, message) |> push_navigate(to: ~p"/editor")
  end

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public locale_links={[]} locale={@record.locale} current_org={@current_org}>
      <%!-- This page renders in the *public* layout so the editor sees the real
            page, which means it inherits none of the console chrome — including
            the environment strip. Typing straight into live content is the last
            place you want to be unsure which deployment you are on (#469). --%>
      <Layouts.environment_banner />
      <Layouts.flash_group flash={@flash} />
      <.edit_bar
        record={@record}
        kind={@kind}
        ct={@ct}
        save_state={@save_state}
        conflict={@conflict}
      />

      <article
        id="in-context-article"
        phx-hook="FocusBlock"
        data-kiln-focus={@focus_block_id}
        class="prose max-w-none"
      >
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
        id={InlineEditing.region_id(@block, @region_version)}
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
        id={InlineEditing.region_id(@block, @region_version)}
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
        id={InlineEditing.region_id(@block, @region_version)}
        phx-hook="InlineRichText"
        phx-update="ignore"
        data-kiln-block-id={@block.id}
        data-kiln-block-mode="html"
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
  # Everything goes through the shared thin-map builder, so a block that carries
  # data-side fields — a `columns` container's children (#335), the GEO blocks'
  # items/steps/citation (#357), a gallery's images or an accordion's panels
  # (#482) — shows them here without this module knowing which blocks those are.
  #
  # This used to be a hardcoded `when mod in [...]` list beside a hand-written
  # fallback, which meant every new data-carrying block rendered blank on this
  # surface until someone remembered to add it. The builder already has a total
  # fallback of its own, so there is nothing for the list to protect.
  defp read_only_block(struct) do
    [legacy] = TypedBlocks.to_legacy([struct])
    [thin] = BlockComponents.thin_blocks([legacy])
    thin
  end

  # Stable-id region element id, keyed by `region_version` so a save/restore
  # remounts the region and reloads its content.

  defp published_path(ct, record) do
    prefix = if record.locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{record.locale}"
    "#{prefix}#{ContentTypes.public_prefix(ct)}/#{record.slug}"
  end

  defp save_label(:saved), do: gettext("All changes saved")
  defp save_label(:saving), do: gettext("Saving…")
  defp save_label(:unsaved), do: gettext("Unsaved changes")
  defp save_label(:error), do: gettext("Save failed")
end
