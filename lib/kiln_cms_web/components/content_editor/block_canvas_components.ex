defmodule KilnCMSWeb.ContentEditor.BlockCanvasComponents do
  @moduledoc """
  Per-block editor bodies for the content editor's block canvas (#1311): the
  slash-command block inserter, the DSL-metadata-driven generic field editor,
  the repeating-row editor (faq/how_to/accordion), and the video, audio,
  gallery and columns editors. Moved verbatim from
  `KilnCMSWeb.ContentEditorLive`; events stay untargeted, so they keep
  landing on the enclosing LiveView.
  """

  use KilnCMSWeb, :html

  import KilnCMSWeb.ContentEditor.BlockParams,
    only: [
      block_member: 1,
      block_type_string: 1,
      item_row_maps: 1,
      nested_fields_for: 1,
      to_int: 1
    ]

  import KilnCMSWeb.ContentEditor.Shared

  attr :block_types, :list, required: true
  attr :id, :string, default: "block-inserter"

  attr :anchor, :string,
    default: nil,
    doc: "insert anchor: a block id, \"start\", or nil (append)"

  attr :compact, :boolean, default: false, doc: "slim inline \"+\" trigger vs the full button"
  attr :global_key, :boolean, default: false, doc: "this instance owns the global \"/\" shortcut"

  # Notion-style slash-command block inserter (#29). The trigger button (or the
  # `/` shortcut, handled by the `BlockInserter` JS hook) opens a filterable,
  # keyboard-navigable menu listing every registered block type. Each option is a
  # real `add_block` button, so it works without JS and is directly testable;
  # the hook layers on filtering, arrow-key navigation, and ARIA wiring.
  #
  # Rendered once as the main "Add block" trigger (append) and again inline in
  # each block card as a compact "+" (B2 inline insertion). `after` rides along on
  # every option so the same menu can append or insert at a gap; only the main
  # instance owns the global "/" shortcut (`global_key`) so inline copies don't
  # all fire at once.
  def block_inserter(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="BlockInserter"
      data-inserter-global={@global_key && "true"}
      class="relative"
    >
      <button
        :if={!@compact}
        type="button"
        data-inserter-trigger
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        class="inline-flex items-center gap-1.5 rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add block")}
        <kbd class="ml-1 rounded border border-base-content/20 px-1.5 text-xs opacity-60">/</kbd>
      </button>
      <button
        :if={@compact}
        type="button"
        data-inserter-trigger
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        aria-label={gettext("Insert block here")}
        class="group/ins flex w-full items-center gap-2 py-1 text-base-content/30 hover:text-base-content/70"
      >
        <span class="h-px flex-1 bg-current opacity-30 transition group-hover/ins:opacity-60"></span>
        <span class="inline-flex items-center gap-1 text-xs">
          <.icon name="hero-plus-circle" class="size-4" />{gettext("Insert")}
        </span>
        <span class="h-px flex-1 bg-current opacity-30 transition group-hover/ins:opacity-60"></span>
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
            aria-controls={"#{@id}-list"}
            placeholder={gettext("Filter blocks…")}
            class="w-full rounded border border-base-content/20 bg-base-100 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-primary/40"
          />
        </div>

        <ul
          id={"#{@id}-list"}
          data-inserter-list
          role="listbox"
          aria-label={gettext("Insert block")}
          class="max-h-72 overflow-y-auto"
        >
          <li :for={bt <- @block_types} role="presentation" data-inserter-option data-label={bt.label}>
            <button
              type="button"
              id={"#{@id}-item-#{bt.type}"}
              role="option"
              aria-selected="false"
              tabindex="-1"
              phx-click="add_block"
              phx-value-type={bt.type}
              phx-value-after={@anchor}
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

  # The first string/rich_text field — the block's primary text field.
  defp primary_field_name(nil), do: nil

  defp primary_field_name(module) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.find_value(fn f -> f.type in [:string, :rich_text] && f.name end)
  end

  # The scalar DSL fields a role may edit (field-level policy, Phase J), excluding
  # types with bespoke UIs (rich_text/map/reference/array).
  # Fields resolved by the server, not typed by a person. They are ordinary
  # block scalars — so without this the generic editor offers each of them as a
  # free-text box, which is how `thumbnail_url` (an `<img src>` on the public
  # page) and `resolved_at` (a machine timestamp) became editable in the first
  # draft of #489. The write path filters them anyway; this stops the editor
  # inviting the attempt.
  @server_resolved_fields [
    :title,
    :author_name,
    :provider_name,
    :thumbnail_url,
    :resolved_url,
    :resolved_at
  ]

  defp editable_scalar_fields(module, role) do
    server_resolved = if module == KilnCMS.Blocks.Embed, do: @server_resolved_fields, else: []

    module
    |> Kiln.Block.Info.fields()
    |> Enum.reject(fn field ->
      field.type in [:rich_text, :map, :reference] or match?({:array, _}, field.type) or
        field.name in server_resolved
    end)
    |> Enum.filter(&Kiln.Block.Policy.can_edit_field?(module, &1.name, role))
  end

  defp dsl_input_type(:integer), do: "number"
  defp dsl_input_type(:boolean), do: "checkbox"
  defp dsl_input_type(_type), do: "text"

  # Per-block editor body for non-rich-text/non-image blocks: labeled inputs bound
  # directly to the union member's typed attributes (Kiln v2 native-union editor).
  # The primary text field is a textarea carrying the collab field-lock; the rest
  # render by their declared type. Role-filtered by field-level policy.
  attr :bf, :any, required: true
  attr :role, :atom, required: true
  attr :locked_fields, :any, required: true
  attr :cursors, :any, required: true

  def dsl_block_fields(assigns) do
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
          {takeover_attrs(@locked_fields, @bf[field.name].name)}
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

  # ── Repeating two-field row editor (faq / how_to / accordion) ───────────────

  # Repeatable two-field rows bound straight into the union member's
  # `{:array, :map}` param (`…[items][0][question]`); `normalize_block_items`
  # turns the indexed maps back into lists on validate/save. The hidden
  # sentinel keeps the param present when every row is removed, so deleting
  # the last row actually clears the stored list.
  #
  # Written for the GEO blocks (#357) and generalized when the accordion arrived
  # (#482) — three blocks, one shape: a label and a body per row. The `case`
  # below has no fallback on purpose: a block wired into `@row_editor_types`
  # without a spec here should fail loudly at render rather than draw an empty
  # box the editor cannot use.
  attr :bf, :any, required: true

  def item_rows_editor(assigns) do
    {field, key_a, key_b, label_a, label_b, add_label} =
      case block_type_string(assigns.bf) do
        "faq" ->
          {:items, "question", "answer", gettext("Question"), gettext("Answer"),
           gettext("Add question")}

        "how_to" ->
          {:steps, "name", "text", gettext("Step label (optional)"), gettext("Instruction"),
           gettext("Add step")}

        "accordion" ->
          {:panels, "title", "content", gettext("Panel title"), gettext("Panel content"),
           gettext("Add panel")}
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:name, assigns.bf[field].name)
      |> assign(:items, item_row_maps(assigns.bf[field].value))
      |> assign(:key_a, key_a)
      |> assign(:key_b, key_b)
      |> assign(:label_a, label_a)
      |> assign(:label_b, label_b)
      |> assign(:add_label, add_label)

    ~H"""
    <div class="mt-2 space-y-2">
      <input type="hidden" name={"#{@name}[_sentinel]"} value="" />

      <div
        :for={{item, i} <- Enum.with_index(@items)}
        class="flex items-start gap-2 rounded border border-base-content/10 p-2"
      >
        <div class="grow space-y-1">
          <input
            type="text"
            name={"#{@name}[#{i}][#{@key_a}]"}
            value={item[@key_a]}
            placeholder={@label_a}
            aria-label={@label_a}
            phx-debounce="300"
            class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
          />
          <textarea
            name={"#{@name}[#{i}][#{@key_b}]"}
            placeholder={@label_b}
            aria-label={@label_b}
            rows="2"
            phx-debounce="300"
            class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
          >{item[@key_b]}</textarea>
        </div>
        <button
          type="button"
          phx-click="item_row_remove"
          phx-value-index={@bf.index}
          phx-value-field={@field}
          phx-value-item={i}
          aria-label={gettext("Remove row")}
          class="mt-1 text-base-content/60 hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <button
        type="button"
        phx-click="item_row_add"
        phx-value-index={@bf.index}
        phx-value-field={@field}
        class="btn btn-sm btn-default"
      >
        <.icon name="hero-plus" class="mr-1 size-4" />{@add_label}
      </button>
    </div>
    """
  end

  # ── gallery editor (#482) ───────────────────────────────────────────────────

  # One row per image: thumbnail, alt, caption, reorder, remove. Rows bind into
  # the `images` `{:array, :map}` param exactly as the row editor above binds
  # `items`/`steps`/`panels`, so `normalize_item_rows/1` flattens them the same
  # way and there is no parallel socket state to keep in sync.
  #
  # Reordering is offered twice on purpose. Dragging is the fast path; the
  # up/down buttons are the one that works from a keyboard, on a touch screen,
  # and with a screen reader — the same pairing `move_block/2` gives the
  # top-level list, and the reason it is not a "nice to have" is that a gallery
  # is *only* an ordering: an editor who cannot reorder it cannot use it.
  # The video block's editor (#494). Three library picks (the media, a poster,
  # a caption track), each writing a hidden `media_id`-shaped field, plus the
  # display metadata and the two playback flags.
  #
  # Every picked id is carried in a hidden input rather than re-derived on
  # save: the block's params round-trip through `AshPhoenix.Form`, and a field
  # with no input in the DOM is a field the next `validate` drops.
  attr :bf, :any, required: true

  def video_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <input type="hidden" name={@bf[:media_id].name} value={@bf[:media_id].value} />
      <input type="hidden" name={@bf[:poster_media_id].name} value={@bf[:poster_media_id].value} />
      <input
        type="hidden"
        name={@bf[:captions_media_id].name}
        value={@bf[:captions_media_id].value}
      />
      <input
        type="hidden"
        name={@bf[:duration_seconds].name}
        value={@bf[:duration_seconds].value}
      />
      <%!-- `poster_url` (an externally-hosted poster, the counterpart of the
            `url` field below) has no visible input: the picker is the only way
            to set a poster from this screen, and a second URL box next to it
            would be one more thing to explain than it is worth. It still needs
            a hidden input, because a field with no input in the DOM is a field
            the next `validate` DROPS — without this, opening any page whose
            video block was written through the headless API would silently
            erase its poster. The two captions text fields below are visible
            only when a track is picked, and carry hidden twins for exactly the
            same reason when they aren't. --%>
      <input type="hidden" name={@bf[:poster_url].name} value={@bf[:poster_url].value} />
      <input
        :if={@bf[:captions_media_id].value in [nil, ""]}
        type="hidden"
        name={@bf[:captions_label].name}
        value={@bf[:captions_label].value}
      />
      <input
        :if={@bf[:captions_media_id].value in [nil, ""]}
        type="hidden"
        name={@bf[:captions_lang].name}
        value={@bf[:captions_lang].value}
      />

      <%!-- The real player, not a still: the point of picking a video in the
            editor is confirming you picked the right one, and a filename does
            not tell you that. Streams through the authorized route, so a gated
            item previews here exactly as it will on the page. --%>
      <video
        :if={@bf[:media_id].value not in [nil, ""]}
        id={"video-preview-#{@bf[:id].value}"}
        src={~p"/media/#{@bf[:media_id].value}/stream"}
        controls
        playsinline
        preload="metadata"
        class="max-h-48 w-full rounded bg-black"
      />

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="media"
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-film" class="mr-1 size-4" />{gettext("Choose video")}
        </button>
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="poster"
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-photo" class="mr-1 size-4" />{if @bf[:poster_media_id].value in [
                                                               nil,
                                                               ""
                                                             ],
                                                             do: gettext("Add poster"),
                                                             else: gettext("Change poster")}
        </button>
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="captions"
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-language" class="mr-1 size-4" />{if @bf[:captions_media_id].value in [
                                                                  nil,
                                                                  ""
                                                                ],
                                                                do: gettext("Add captions"),
                                                                else: gettext("Change captions")}
        </button>
      </div>

      <%!-- Not a validation error — a video with no captions still publishes.
            It is the one accessibility fact about this block an editor cannot
            see by looking at it, so it is stated where the decision is made
            rather than in a report nobody opens. --%>
      <p
        :if={@bf[:media_id].value not in [nil, ""] and @bf[:captions_media_id].value in [nil, ""]}
        class="flex items-start gap-1 text-xs text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
        <span>
          {gettext("No captions — this video isn't available to deaf and hard-of-hearing readers.")}
        </span>
      </p>

      <.input
        field={@bf[:url]}
        label={gettext("Video URL")}
        placeholder={gettext("…or paste a URL to a video hosted elsewhere")}
      />
      <.input field={@bf[:title]} label={gettext("Title")} />
      <.input field={@bf[:caption]} label={gettext("Caption")} />
      <div :if={@bf[:captions_media_id].value not in [nil, ""]} class="grid grid-cols-2 gap-2">
        <.input field={@bf[:captions_label]} label={gettext("Captions label")} />
        <.input
          field={@bf[:captions_lang]}
          label={gettext("Captions language")}
          placeholder="en"
        />
      </div>
      <div class="flex flex-wrap gap-4">
        <%!-- The label says "muted" because the rendered element always is:
              browsers refuse to autoplay a video with sound, so offering the
              two as separate choices would offer one that does nothing. --%>
        <.input
          field={@bf[:autoplay]}
          type="checkbox"
          label={gettext("Autoplay (muted)")}
        />
        <.input field={@bf[:loop]} type="checkbox" label={gettext("Loop")} />
      </div>
    </div>
    """
  end

  attr :bf, :any, required: true

  def audio_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <input type="hidden" name={@bf[:media_id].name} value={@bf[:media_id].value} />
      <input
        type="hidden"
        name={@bf[:duration_seconds].name}
        value={@bf[:duration_seconds].value}
      />

      <audio
        :if={@bf[:media_id].value not in [nil, ""]}
        id={"audio-preview-#{@bf[:id].value}"}
        src={~p"/media/#{@bf[:media_id].value}/stream"}
        controls
        preload="metadata"
        class="w-full"
      />

      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="media"
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-musical-note" class="mr-1 size-4" />{gettext("Choose audio")}
        </button>
      </div>

      <.input
        field={@bf[:url]}
        label={gettext("Audio URL")}
        placeholder={gettext("…or paste a URL to audio hosted elsewhere")}
      />
      <.input field={@bf[:title]} label={gettext("Title")} />
      <.input field={@bf[:caption]} label={gettext("Caption")} />
      <.input field={@bf[:loop]} type="checkbox" label={gettext("Loop")} />
    </div>
    """
  end

  attr :bf, :any, required: true

  def gallery_editor(assigns) do
    assigns =
      assigns
      |> assign(:name, assigns.bf[:images].name)
      |> assign(:images, item_row_maps(assigns.bf[:images].value))
      |> assign(:bid, assigns.bf[:id].value)

    ~H"""
    <div class="mt-2 space-y-2">
      <%!-- Keeps the param present when the last image is removed, so clearing a
            gallery actually clears the stored list rather than leaving the old
            one untouched. Same trick as the row editor. --%>
      <input type="hidden" name={"#{@name}[_sentinel]"} value="" />

      <%!-- The gallery draws its own fields, so it is excluded from
            `dsl_block_fields/1` — which means anything not rendered here is
            unreachable from the editor entirely. `title` is one of them. --%>
      <.input field={@bf[:title]} label={gettext("Heading (optional)")} />

      <.input
        field={@bf[:layout]}
        type="select"
        label={gettext("Layout")}
        options={gallery_layout_options()}
      />

      <div
        :if={@images != []}
        id={"gallery-#{@bid}"}
        phx-hook="GallerySortable"
        data-block-id={@bid}
        class="space-y-2"
      >
        <div
          :for={{image, i} <- Enum.with_index(@images)}
          data-image-row={i}
          class="flex items-start gap-2 rounded border border-base-content/10 p-2"
        >
          <button
            type="button"
            data-image-handle
            aria-hidden="true"
            tabindex="-1"
            class="mt-1 cursor-grab active:cursor-grabbing text-base-content/40"
          >
            <.icon name="hero-bars-2" class="size-4" />
          </button>

          <img
            :if={safe_preview_src(image["url"])}
            src={safe_preview_src(image["url"])}
            alt=""
            class="size-16 shrink-0 rounded border border-base-content/10 object-cover"
          />

          <div class="grow space-y-1">
            <input type="hidden" name={"#{@name}[#{i}][url]"} value={image["url"]} />
            <input type="hidden" name={"#{@name}[#{i}][media_id]"} value={image["media_id"]} />
            <input
              type="text"
              name={"#{@name}[#{i}][alt]"}
              value={image["alt"]}
              placeholder={gettext("Alt text — leave blank only if decorative")}
              aria-label={gettext("Alt text")}
              phx-debounce="300"
              class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
            />
            <input
              type="text"
              name={"#{@name}[#{i}][caption]"}
              value={image["caption"]}
              placeholder={gettext("Caption (optional)")}
              aria-label={gettext("Caption")}
              phx-debounce="300"
              class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
            />
          </div>

          <div class="flex flex-col">
            <button
              type="button"
              phx-click="gallery_move"
              phx-value-bid={@bid}
              phx-value-item={i}
              phx-value-dir="up"
              disabled={i == 0}
              aria-label={gettext("Move image up")}
              class="text-base-content/60 hover:text-base-content disabled:opacity-30"
            >
              <.icon name="hero-chevron-up" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="gallery_move"
              phx-value-bid={@bid}
              phx-value-item={i}
              phx-value-dir="down"
              disabled={i == length(@images) - 1}
              aria-label={gettext("Move image down")}
              class="text-base-content/60 hover:text-base-content disabled:opacity-30"
            >
              <.icon name="hero-chevron-down" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="gallery_remove"
              phx-value-bid={@bid}
              phx-value-item={i}
              aria-label={gettext("Remove image")}
              class="mt-1 text-base-content/60 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <p :if={@images == []} class="text-sm text-base-content/60">
        {gettext("No images yet.")}
      </p>

      <button
        type="button"
        phx-click="open_gallery_picker"
        phx-value-bid={@bid}
        class="btn btn-sm btn-default"
      >
        <.icon name="hero-photo" class="mr-1 size-4" />{gettext("Add images")}
      </button>
    </div>
    """
  end

  # A blank first option, because a fresh gallery has `layout: nil` and a select
  # with no empty entry silently selects whichever option sorts first — the
  # editor would read "Carousel" while the preview rendered the default grid,
  # and the first save would post a layout nobody chose. (The columns editor
  # below prepends "Equal width" for the same reason.) It is also the only way
  # back to the default once a layout has been picked.
  defp gallery_layout_options do
    [{gettext("Grid (default)"), ""}] ++
      for layout <- KilnCMS.Blocks.Gallery.layouts(),
          layout != "grid",
          do: {gallery_layout_label(layout), layout}
  end

  defp gallery_layout_label("grid"), do: gettext("Grid")
  defp gallery_layout_label("masonry"), do: gettext("Masonry")
  defp gallery_layout_label("carousel"), do: gettext("Carousel")
  defp gallery_layout_label(other), do: other

  # ── columns (nested-layout) editor (#335) ───────────────────────────────────

  # The socket-managed children of the columns block behind sub-form `bf`, keyed
  # by the block's stable id. Falls back to the default two empty columns for a
  # block whose id isn't seeded yet (a just-inserted one before its first sync).
  def col_state(block_children, bf) do
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

  def columns_editor(assigns) do
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
          class="btn btn-sm btn-default"
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
                  class="flex cursor-grab active:cursor-grabbing items-center gap-1 text-xs text-base-content/60"
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

  def nested_child_fields(%{child: %{"_type" => "divider"}} = assigns) do
    ~H"""
    <hr class="border-base-300" />
    """
  end

  def nested_child_fields(assigns) do
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
      <%!-- Named, unlike its nameless siblings above, and the name carries the
      identifiers (#893). A `<select>` inside a form routes its own `phx-change`
      through LiveView's `pushInput`, which serializes the form filtered to the
      changed input's `name` and scrapes `phx-value-*` off the FORM, not the
      element — so a nameless select sends neither its value nor its ids, and
      the handler head could not match. The text inputs beside it work because
      `phx-blur` is not a form binding and goes through `pushEvent`, which does
      carry `phx-value-*`; that asymmetry is what hid this.

      Named outside the `form[...]` namespace on purpose, so it stays out of the
      content changeset exactly as the nameless inputs do: `validate` matches
      `%{"form" => params}` and never sees this key, and the nested tree is
      re-injected from socket state by `inject_children/2` regardless. --%>
      <select
        :if={@child["_type"] == "heading"}
        name={"col_child[#{@block_id}][#{@child["id"]}][level]"}
        phx-change="col_update_child"
        class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
      >
        <%!-- Matched to what will actually publish. A child with no stored `level`
        (a legacy one, or an empty string) made `to_int/1` return 0, so no option
        was `selected` and the browser showed the first — H1 — while delivery
        renders `h2`, because `Blocks.Heading.clamp/1` falls back to its default.
        Harmless while the control was inert; a lie now that it works. --%>
        <option :for={n <- 1..6} value={n} selected={child_heading_level(@child) == n}>H{n}</option>
      </select>
    </div>
    """
  end

  # The level the select must show: what `KilnCMS.Blocks.Heading` will render,
  # not what happens to be stored. Anything outside 1..6 — including a missing
  # or unparseable value — resolves to the same default that block clamps to, so
  # the control and the published page cannot disagree.
  @heading_default_level 2

  defp child_heading_level(child) do
    case to_int(child["level"]) do
      n when n in 1..6 -> n
      _out_of_range -> @heading_default_level
    end
  end
end
