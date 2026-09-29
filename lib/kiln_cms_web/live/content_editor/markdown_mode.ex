defmodule KilnCMSWeb.ContentEditor.MarkdownMode do
  @moduledoc """
  The content editor's **Markdown view**: a Blocks | Markdown switch over the
  same document. It is a second way to edit the blocks, not a separate draft:

    * **Entering** writes the current blocks out as Markdown
      (`to_source/1`). Prose, headings, rules and plain images become
      Markdown; every block Markdown can't say (a gallery, a form, columns, an
      image tied to the media library, …) becomes a one-line placeholder
      comment, `<!-- kiln:block gallery 1f0c… -->`, that stands for the block
      as it is. Placeholders can be moved or deleted like any line.
    * **Typing** (debounced) re-parses the text through `KilnCMS.Markdown` —
      the converter the paste, `.md` import and API share — and puts the
      resulting blocks in the form (`from_source/2`), so the preview, autosave
      and Save all see what the text says. A placeholder brings its block back
      unchanged, with its id.
    * **Leaving** just closes the view: the blocks are already there. After
      an edit, the rich-text editors remount (`@markdown_generation` is part
      of their element id), since they keep the content they mounted with.

  Prose keeps its block ids across edits: the blocks a parse produces take
  the ids of the previous parse's, by position and type, so a discussion on a
  paragraph survives a typo fixed two sections away. Rich text is written as
  Markdown only when it reads back the same (tables with merged cells, custom
  objects and the like become placeholders), and so is an image only when its
  URL is one the Markdown importer keeps.

  While another editor holds a lock on a block, the view does not rewrite the
  blocks: entering is refused, and so is applying an edit.

  Text that matches what entering wrote restores the blocks exactly as they
  were (ids, block types, everything): an author who looks at the Markdown and
  switches back without editing loses nothing. An edit is a re-parse, and
  Markdown's shape wins — prose between placeholders becomes one rich-text
  block, and a heading block comes back as a heading inside that prose.

  Every event is gated on `@may_write?`, the editor's own write gate; the
  record's policies re-check the eventual save.
  """
  use KilnCMSWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  import KilnCMSWeb.ContentEditor.BlockParams,
    only: [
      add_blocks: 2,
      full_blocks_input: 1,
      html_block_params: 2,
      inject_children: 2,
      inject_rich_bodies: 2,
      remove_all_blocks: 1,
      to_int: 1,
      writable?: 1
    ]

  import KilnCMSWeb.ContentEditor.BlockOps, only: [revalidate: 2]
  import KilnCMSWeb.ContentEditor.Preview, only: [broadcast_preview: 1]
  import KilnCMSWeb.ContentEditor.Session, only: [mark_dirty: 1]
  import KilnCMSWeb.ContentEditor.Shared, only: [locked_fields: 1]

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.Markdown

  @placeholder ~r/^\s*<!--\s*kiln:block\s+([a-z0-9_]+)\s+([0-9A-Za-z-]+)\s*-->\s*$/

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:markdown_mode, nil)
     |> assign(:markdown_generation, 0)
     |> attach_hook(:editor_markdown_mode, :handle_event, &on_event/3)}
  end

  # ── Events ────────────────────────────────────────────────────────────────

  defp on_event(_event, _params, %{assigns: %{record: nil}} = socket), do: {:cont, socket}

  defp on_event("markdown_mode_enter", _params, socket) do
    cond do
      not writable?(socket) or socket.assigns.markdown_mode != nil -> {:halt, socket}
      blocks_locked?(socket) -> {:halt, locked(socket)}
      true -> {:halt, enter(socket)}
    end
  end

  defp on_event("markdown_mode_exit", _params, socket) do
    socket =
      case socket.assigns.markdown_mode do
        %{touched?: true} -> update(socket, :markdown_generation, &(&1 + 1))
        _ -> socket
      end

    {:halt, assign(socket, :markdown_mode, nil)}
  end

  defp on_event("markdown_mode_change", %{"markdown_source" => text}, socket)
       when is_binary(text) do
    cond do
      is_nil(socket.assigns.markdown_mode) or not writable?(socket) ->
        {:halt, socket}

      byte_size(text) > Markdown.max_bytes() ->
        {:halt,
         put_flash(
           socket,
           :error,
           gettext("That's more Markdown than one document can hold (the limit is %{size} MB).",
             size: div(Markdown.max_bytes(), 1_000_000)
           )
         )}

      blocks_locked?(socket) ->
        {:halt, locked(socket)}

      true ->
        {:halt, change(socket, text)}
    end
  end

  defp on_event("markdown_mode_change", _params, socket), do: {:halt, socket}

  defp on_event(_event, _params, socket), do: {:cont, socket}

  # A peer's lock on any block field (`form[blocks][N][…]`). Rewriting the
  # blocks would overwrite what they are typing, and move their lock onto
  # whichever block lands at that position.
  defp blocks_locked?(socket) do
    prefix = socket.assigns.form.name <> "[blocks]"
    socket |> locked_fields() |> Enum.any?(&String.starts_with?(&1, prefix))
  end

  defp locked(socket) do
    put_flash(
      socket,
      :error,
      gettext(
        "Someone is editing a block right now. Try the Markdown view again once they're done."
      )
    )
  end

  # ── Entering / changing ───────────────────────────────────────────────────

  defp enter(socket) do
    %{form: form, block_children: children, rich_bodies: rich_bodies} = socket.assigns

    # The blocks as a save would write them: children and pending rich-text
    # bodies are socket-held, not in the sub-forms.
    blocks =
      %{"blocks" => full_blocks_input(form)}
      |> inject_children(children)
      |> inject_rich_bodies(rich_bodies)
      |> Map.fetch!("blocks")
      |> Enum.map(&ensure_id/1)

    {source, kept} = to_source(blocks)

    assign(socket, :markdown_mode, %{
      source: source,
      original: source,
      snapshot: %{blocks: blocks, block_children: children, rich_bodies: rich_bodies},
      kept: kept,
      prose_ids: prose_ids(blocks, kept),
      applied: :original,
      touched?: false
    })
  end

  defp change(socket, text) do
    mode = socket.assigns.markdown_mode

    cond do
      # Unchanged since entering: the original blocks, exactly.
      same_text?(text, mode.original) ->
        if mode.applied == :original,
          do: assign(socket, :markdown_mode, %{mode | source: text}),
          else: apply_blocks(socket, mode.snapshot, %{mode | source: text, applied: :original})

      same_text?(text, mode.source) ->
        socket

      true ->
        blocks = from_source(text, mode.kept, mode.prose_ids)

        kept_ids =
          for %{"id" => id} <- blocks, Map.has_key?(mode.kept, id), into: MapSet.new(), do: id

        state = %{
          blocks: blocks,
          block_children:
            Map.filter(mode.snapshot.block_children, fn {id, _} -> id in kept_ids end),
          rich_bodies:
            for(
              %{"_union_type" => "rich_text", "id" => id, "body" => [_ | _] = body} <- blocks,
              into: %{},
              do: {id, body}
            )
        }

        mode = %{mode | source: text, applied: :parsed, prose_ids: prose_ids(blocks, mode.kept)}
        apply_blocks(socket, state, mode)
    end
  end

  defp same_text?(a, b), do: String.trim(a) == String.trim(b)

  # The ids of the blocks written as Markdown, in order — what the next parse
  # hands out again.
  defp prose_ids(blocks, kept) do
    for %{"id" => id, "_union_type" => type} <- blocks, not Map.has_key?(kept, id), do: {type, id}
  end

  # Replace every block sub-form with `state.blocks`, the way the `.md` import
  # does (sub-forms added one by one — see `MarkdownImport.apply_import/2` for
  # why a longer params list is not enough), then re-validate so the form, the
  # preview and the next save agree.
  defp apply_blocks(socket, state, mode) do
    form = socket.assigns.form |> remove_all_blocks() |> add_blocks(state.blocks)

    socket =
      socket
      |> assign(:form, form)
      |> assign(:block_children, state.block_children)
      |> assign(:rich_bodies, state.rich_bodies)
      |> assign(:markdown_mode, %{mode | touched?: true})

    params =
      form
      |> AshPhoenix.Form.params()
      |> Map.put("blocks", full_blocks_input(form))
      |> inject_rich_bodies(state.rich_bodies)

    socket = revalidate(socket, params)
    broadcast_preview(socket)
    # `mark_dirty/1` refreshes the inline preview itself.
    mark_dirty(socket)
  end

  defp ensure_id(%{"id" => id} = block) when is_binary(id) and id != "", do: block
  defp ensure_id(block), do: Map.put(block, "id", Ash.UUID.generate())

  # ── Blocks ⇄ Markdown ─────────────────────────────────────────────────────

  @doc """
  The editor's blocks (union input maps: `_union_type`, `id`, fields) as
  Markdown, and the blocks it wrote as placeholders, by id.
  """
  @spec to_source([map()]) :: {String.t(), %{String.t() => map()}}
  def to_source(blocks) do
    {parts, kept} =
      Enum.reduce(blocks, {[], %{}}, fn block, {parts, kept} ->
        case block_markdown(block) do
          {:markdown, ""} -> {parts, kept}
          {:markdown, md} -> {[md | parts], kept}
          :keep -> {[placeholder(block) | parts], Map.put(kept, block["id"], block)}
        end
      end)

    source =
      case parts do
        [] -> ""
        parts -> (parts |> Enum.reverse() |> Enum.join("\n\n")) <> "\n"
      end

    {source, kept}
  end

  @doc """
  Markdown (as written by `to_source/1`, then edited) back into union input
  maps. A placeholder line whose id is in `kept` brings that block back as it
  was — once; a copy, or an id it doesn't know, is dropped. Every run of
  Markdown between them goes through `KilnCMS.Markdown.to_blocks/2`.

  The blocks the Markdown parses to take their ids from `prose_ids`
  (`{type, id}` in order, from the previous parse) by position, where the
  type matches; the rest get fresh ones.
  """
  @spec from_source(String.t(), %{String.t() => map()}, [{String.t(), String.t()}]) :: [map()]
  def from_source(text, kept, prose_ids \\ []) do
    {blocks, _used} =
      text
      |> String.split(~r/\r?\n/)
      |> segments()
      |> Enum.flat_map_reduce(MapSet.new(), &segment_blocks(&1, &2, kept))

    {blocks, _left} = Enum.map_reduce(blocks, prose_ids, &assign_id/2)
    blocks
  end

  # A kept block has its id; a parsed one (id `nil`) takes the next one.
  defp assign_id(%{"id" => id} = block, queue) when is_binary(id), do: {block, queue}

  defp assign_id(%{"_union_type" => type} = block, [{type, id} | rest]),
    do: {Map.put(block, "id", id), rest}

  defp assign_id(block, [_other | rest]), do: {Map.put(block, "id", Ash.UUID.generate()), rest}
  defp assign_id(block, []), do: {Map.put(block, "id", Ash.UUID.generate()), []}

  defp segment_blocks({:keep, id}, used, kept) do
    cond do
      id in used -> {[], used}
      Map.has_key?(kept, id) -> {[kept[id]], MapSet.put(used, id)}
      true -> {[], used}
    end
  end

  defp segment_blocks({:markdown, lines}, used, _kept),
    do:
      {lines |> Enum.join("\n") |> Markdown.to_blocks() |> Enum.map(&html_block_params(&1, nil)),
       used}

  # Lines → `{:markdown, lines}` runs and `{:keep, id}` placeholders. A
  # placeholder-shaped line inside a fenced code block is code, not a block.
  defp segments(lines) do
    {segments, run, _fence} =
      Enum.reduce(lines, {[], [], nil}, &segment_line/2)

    Enum.reverse(flush(run, segments))
  end

  defp segment_line(line, {segments, run, fence}) when fence != nil,
    do: {segments, [line | run], if(closes_fence?(line, fence), do: nil, else: fence)}

  defp segment_line(line, {segments, run, nil}) do
    cond do
      fence = opening_fence(line) ->
        {segments, [line | run], fence}

      match = Regex.run(@placeholder, line) ->
        [_, _type, id] = match
        {[{:keep, id} | flush(run, segments)], [], nil}

      true ->
        {segments, [line | run], nil}
    end
  end

  defp flush([], segments), do: segments
  defp flush(run, segments), do: [{:markdown, Enum.reverse(run)} | segments]

  defp opening_fence(line) do
    case Regex.run(~r/^\s{0,3}(`{3,}|~{3,})/, line) do
      [_, fence] -> fence
      nil -> nil
    end
  end

  defp closes_fence?(line, fence) do
    String.match?(line, ~r/^\s{0,3}#{Regex.escape(fence)}+\s*$/) and
      String.first(String.trim(line)) == String.first(fence)
  end

  defp block_markdown(%{"_union_type" => "rich_text"} = block) do
    case block["body"] do
      [_ | _] = body -> prose_markdown(body)
      # Prose Portable Text can't hold (a list in a quote, marks in code) is
      # kept as its stored HTML — rewriting it through Markdown would lose it.
      _ -> if blank?(block["legacy_html"]), do: {:markdown, ""}, else: :keep
    end
  end

  defp block_markdown(%{"_union_type" => "heading"} = block) do
    case trimmed(block["text"]) do
      "" -> {:markdown, ""}
      text -> {:markdown, heading(block["level"], text)}
    end
  end

  defp block_markdown(%{"_union_type" => "divider"}), do: {:markdown, "---"}

  # A picture from the media library is tied to it by `media_id`, which
  # Markdown can't carry: keep the block.
  defp block_markdown(%{"_union_type" => "image"} = block) do
    url = trimmed(block["url"])

    # The importer keeps only a URL `safe_image_src/1` accepts as it is; any
    # other (a bare media id, a relative path) would vanish on the next edit.
    if url == "" or not blank?(block["media_id"]) or HTMLSanitizer.safe_image_src(url) != url do
      :keep
    else
      {:markdown, image(url, trimmed(block["alt"]), trimmed(block["caption"]))}
    end
  end

  defp block_markdown(_block), do: :keep

  # Prose becomes Markdown only when that Markdown reads back as the same
  # prose; anything it can't hold (merged table cells, a headerless table, a
  # custom object) keeps the block whole, as a placeholder.
  defp prose_markdown(body) do
    markdown = PortableText.to_markdown(body)
    html = PortableText.to_html(body)

    cond do
      html == "" -> {:markdown, ""}
      reads_back?(markdown, html) -> {:markdown, markdown}
      true -> :keep
    end
  end

  defp reads_back?(markdown, html) do
    case Markdown.to_blocks(markdown) do
      [%{"type" => "rich_text", "value" => %{"body" => body}}] ->
        PortableText.to_html(body) == html

      _ ->
        false
    end
  end

  defp heading(level, text) do
    # An unset level is the heading block's own default, h2.
    level =
      case to_int(level) do
        0 -> 2
        n -> n |> max(1) |> min(6)
      end

    body = [%{"style" => "h#{level}", "children" => [%{"text" => text}]}]
    PortableText.to_markdown(body)
  end

  defp image(url, alt, caption) do
    alt = String.replace(alt, ~r/([\\\[\]])/, "\\\\\\1")
    target = if String.match?(url, ~r/[\s()<>]/), do: "<#{url}>", else: url
    title = if caption == "", do: "", else: ~s( "#{String.replace(caption, "\"", "\\\"")}")
    "![#{alt}](#{target}#{title})"
  end

  defp placeholder(block), do: "<!-- kiln:block #{block["_union_type"]} #{block["id"]} -->"

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp blank?(value), do: trimmed(value) == ""

  # ── Components ────────────────────────────────────────────────────────────

  attr :mode, :map, default: nil

  @doc "The Blocks | Markdown switch above the canvas."
  def mode_switch(assigns) do
    ~H"""
    <div
      id="editor-mode-switch"
      role="group"
      aria-label={gettext("Edit as")}
      class="inline-flex rounded-lg border border-base-content/15 bg-base-200/60 p-0.5 text-sm"
    >
      <button
        type="button"
        id="editor-mode-blocks"
        phx-click="markdown_mode_exit"
        aria-pressed={to_string(is_nil(@mode))}
        class={[
          "inline-flex cursor-pointer items-center gap-1 rounded-md px-2.5 py-1 transition-colors duration-150",
          is_nil(@mode) && "bg-base-100 font-medium shadow-sm",
          @mode && "text-base-content/70 hover:text-base-content"
        ]}
      >
        <.icon name="hero-squares-2x2" class="size-4" />{gettext("Blocks")}
      </button>
      <%!-- `data-flush-body`: a rich-text block sends its debounced text on
            this button's mousedown, so words typed just before switching are
            in the Markdown the switch writes. --%>
      <button
        type="button"
        id="editor-mode-markdown"
        phx-click="markdown_mode_enter"
        data-flush-body
        aria-pressed={to_string(not is_nil(@mode))}
        title={gettext("Edit this document's blocks as Markdown")}
        class={[
          "inline-flex cursor-pointer items-center gap-1 rounded-md px-2.5 py-1 transition-colors duration-150",
          @mode && "bg-base-100 font-medium shadow-sm",
          is_nil(@mode) && "text-base-content/70 hover:text-base-content"
        ]}
      >
        <.icon name="hero-hashtag" class="size-4" />{gettext("Markdown")}
      </button>
    </div>
    """
  end

  attr :mode, :map, required: true

  @doc """
  The Markdown editor. Its own `phx-change` (not the editor form's): the text
  is converted server-side on every debounced change, and a blur flushes the
  debounce, so clicking "Blocks" never loses the last keystrokes.
  """
  def source_editor(assigns) do
    ~H"""
    <div id="markdown-mode" class="space-y-2">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Paste or write Markdown. It becomes blocks as you type — switch back to Blocks to see them."
        )}
        <span :if={@mode.kept != %{}}>
          {gettext(
            "Lines like <!-- kiln:block gallery … --> stand for blocks Markdown can't express; move or delete them like any line."
          )}
        </span>
      </p>
      <.input
        type="textarea"
        id="markdown-mode-source"
        name="markdown_source"
        value={@mode.source}
        phx-change="markdown_mode_change"
        phx-debounce="400"
        rows="24"
        spellcheck="true"
        aria-label={gettext("Document body as Markdown")}
        class="block min-h-[24rem] w-full resize-y rounded-lg border border-base-content/15 bg-base-100 p-4 font-mono text-sm leading-relaxed shadow-sm transition-colors duration-150 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
      />
    </div>
    """
  end
end
