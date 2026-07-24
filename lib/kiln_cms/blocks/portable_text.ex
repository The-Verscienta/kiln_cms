defmodule KilnCMS.Blocks.PortableText do
  @moduledoc """
  Portable Text — the canonical rich-prose representation (Kiln v2 — decision D12).

  Prose is stored as a structured array of *block* maps, each holding *span*
  children whose formatting is carried as data (`marks`), not tags. This is plain
  Portable Text JSON (string keys: `_type`, `_key`, `style`, `children`,
  `markDefs`), so it serializes straight to/from jsonb.

  TipTap is an **interchange layer**: `from_tiptap/1` converts the editor's JSON to
  PT on save; `to_html/1` renders PT for the web surface; `to_plain_text/1` feeds
  search/embeddings.

  ## Coverage
  Block styles: paragraph (`normal`), `h1`–`h6`, `blockquote`, `code`
  (TipTap codeBlock). Lists: bullet/ordered, nested (PT `listItem` +
  `level`). Marks: bold→strong, italic→em, code, strike, underline, and link
  annotations (via `markDefs`). Hard breaks become `\n` inside a span;
  horizontal rules become a standalone `%{"_type" => "hr"}` item.
  **Follow-up:** embedded typed objects inside prose are not converted.
  """

  @typedoc "A Portable Text block map (string keys)."
  @type pt_block :: %{optional(String.t()) => term()}

  # ── TipTap → Portable Text ────────────────────────────────────────────────

  @doc "Convert TipTap JSON (string or decoded map) to a list of PT block maps."
  @spec from_tiptap(binary() | map() | list() | nil) :: [pt_block()]
  def from_tiptap(json) when is_binary(json), do: json |> Jason.decode!() |> from_tiptap()

  def from_tiptap(%{"content" => content}) when is_list(content) do
    {blocks, _next_key} =
      Enum.reduce(content, {[], 0}, fn node, {acc, key} ->
        {emitted, key} = blocks_from_node(node, key)
        {acc ++ emitted, key}
      end)

    blocks
  end

  # Already Portable Text (idempotent).
  def from_tiptap(list) when is_list(list), do: list
  def from_tiptap(_), do: []

  # One TipTap node can emit several PT blocks (each list item is its own PT
  # block), so nodes return {blocks, next_key}.
  defp blocks_from_node(%{"type" => "blockquote"} = node, key) do
    # Blockquotes wrap paragraphs in TipTap; flatten their inline content.
    inline = node["content"] |> List.wrap() |> Enum.flat_map(&(&1["content"] || []))
    {children, defs} = spans_and_defs(inline)
    {[pt_block("blockquote", key, children, defs)], key + 1}
  end

  defp blocks_from_node(%{"type" => list} = node, key) when list in ["bulletList", "orderedList"],
    do: list_items(node, list_kind(list), 1, key)

  defp blocks_from_node(%{"type" => "codeBlock"} = node, key) do
    {children, defs} = spans_and_defs(node["content"] || [])
    {[pt_block("code", key, children, defs)], key + 1}
  end

  defp blocks_from_node(%{"type" => "horizontalRule"}, key),
    do: {[%{"_type" => "hr", "_key" => "b#{key}"}], key + 1}

  defp blocks_from_node(%{"type" => type} = node, key) do
    {children, defs} = spans_and_defs(node["content"] || [])
    {[pt_block(style_for(type, node), key, children, defs)], key + 1}
  end

  defp blocks_from_node(_other, key), do: {[pt_block("normal", key, [], [])], key + 1}

  defp list_kind("orderedList"), do: "number"
  defp list_kind(_), do: "bullet"

  # TipTap: bulletList > listItem[] > (paragraph + optional nested list).
  # PT: one block per item with `listItem` + `level`; nesting via level.
  defp list_items(%{"content" => items}, kind, level, key) do
    Enum.reduce(List.wrap(items), {[], key}, fn item, {acc, key} ->
      inline =
        item["content"]
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "paragraph"))
        |> Enum.flat_map(&(&1["content"] || []))

      {children, defs} = spans_and_defs(inline)

      item_block =
        "normal"
        |> pt_block(key, children, defs)
        |> Map.merge(%{"listItem" => kind, "level" => level})

      {nested, key} =
        item["content"]
        |> List.wrap()
        |> Enum.filter(&(&1["type"] in ["bulletList", "orderedList"]))
        |> Enum.reduce({[], key + 1}, fn sub, {sub_acc, key} ->
          {emitted, key} = list_items(sub, list_kind(sub["type"]), level + 1, key)
          {sub_acc ++ emitted, key}
        end)

      {acc ++ [item_block | nested], key}
    end)
  end

  defp list_items(_node, _kind, _level, key), do: {[], key}

  defp pt_block(style, idx, children, defs) do
    %{
      "_type" => "block",
      "_key" => "b#{idx}",
      "style" => style,
      "children" => children,
      "markDefs" => defs
    }
  end

  defp style_for("heading", %{"attrs" => %{"level" => level}}) when level in 1..6,
    do: "h#{level}"

  defp style_for("heading", _), do: "h2"
  defp style_for(_other, _node), do: "normal"

  defp spans_and_defs(content) do
    {spans, defs, _next} =
      Enum.reduce(content, {[], [], 0}, fn node, {spans, defs, key_idx} ->
        {span, new_defs, key_idx} = span_from(node, key_idx)
        {[span | spans], defs ++ new_defs, key_idx}
      end)

    {Enum.reverse(spans), defs}
  end

  defp span_from(%{"type" => "text"} = node, key_idx) do
    {marks, defs, key_idx} =
      (node["marks"] || [])
      |> Enum.reduce({[], [], key_idx}, fn
        %{"type" => "link", "attrs" => %{"href" => href}}, {marks, defs, idx} ->
          key = "lk#{idx}"
          {[key | marks], [%{"_key" => key, "_type" => "link", "href" => href} | defs], idx + 1}

        %{"type" => type}, {marks, defs, idx} ->
          {[map_mark(type) | marks], defs, idx}

        _other, acc ->
          acc
      end)

    span = %{"_type" => "span", "text" => node["text"] || "", "marks" => Enum.reverse(marks)}
    {span, Enum.reverse(defs), key_idx}
  end

  defp span_from(%{"type" => "hardBreak"}, key_idx),
    do: {%{"_type" => "span", "text" => "\n", "marks" => []}, [], key_idx}

  defp span_from(_other, key_idx),
    do: {%{"_type" => "span", "text" => "", "marks" => []}, [], key_idx}

  defp map_mark("bold"), do: "strong"
  defp map_mark("italic"), do: "em"
  defp map_mark("code"), do: "code"
  defp map_mark("strike"), do: "strike"
  defp map_mark("underline"), do: "underline"
  defp map_mark(other), do: other

  # ── Sanitization (cast-time, defense-in-depth) ────────────────────────────

  @doc """
  Strip link `markDefs` whose `href` fails the URL allowlist, so malicious
  schemes (`javascript:`, `data:`, …) are never persisted in a `body`. The web
  renderer already drops them at output time; this keeps stored prose clean for
  any other consumer (typed renderers, exports).
  """
  @spec sanitize_body([pt_block()] | term()) :: [pt_block()] | term()
  def sanitize_body(blocks) when is_list(blocks), do: Enum.map(blocks, &sanitize_block/1)
  def sanitize_body(other), do: other

  defp sanitize_block(%{"markDefs" => defs} = block) when is_list(defs),
    do: Map.put(block, "markDefs", Enum.map(defs, &sanitize_def/1))

  defp sanitize_block(block), do: block

  defp sanitize_def(%{"_type" => "link", "href" => href} = def),
    do: Map.put(def, "href", KilnCMS.HTMLSanitizer.safe_href(href) || "")

  defp sanitize_def(def), do: def

  # ── Portable Text → HTML (web surface) ────────────────────────────────────

  @doc "Render PT blocks to an HTML string."
  @spec to_html([pt_block()] | nil) :: String.t()
  def to_html(blocks) when is_list(blocks) do
    blocks
    |> chunk_list_runs()
    |> Enum.map_join(fn
      [%{"listItem" => _} | _] = items -> list_to_html(items, 1)
      other -> Enum.map_join(other, &block_to_html/1)
    end)
  end

  def to_html(_), do: ""

  # Group consecutive list items into runs: first chunk on the list/non-list
  # boundary, then split each list chunk where a LEVEL-1 item changes kind (a
  # bullet list followed by a numbered list stays two lists). Deeper items
  # always follow their preceding level-1 item, whatever their kind.
  defp chunk_list_runs(blocks) do
    blocks
    |> Enum.chunk_by(&match?(%{"listItem" => _}, &1))
    |> Enum.flat_map(fn
      [%{"listItem" => _} | _] = items -> split_kind_runs(items)
      other -> [other]
    end)
  end

  defp split_kind_runs(items) do
    {runs, _kind} =
      Enum.reduce(items, {[], nil}, fn item, {runs, kind} ->
        level1? = (item["level"] || 1) == 1

        cond do
          runs == [] -> {[[item]], item["listItem"]}
          not level1? -> {prepend_to_head_run(runs, item), kind}
          item["listItem"] == kind -> {prepend_to_head_run(runs, item), kind}
          true -> {[[item] | runs], item["listItem"]}
        end
      end)

    runs |> Enum.map(&Enum.reverse/1) |> Enum.reverse()
  end

  defp prepend_to_head_run([run | rest], item), do: [[item | run] | rest]

  defp list_to_html([], _level), do: ""

  defp list_to_html([first | _] = items, level) do
    kind = first["listItem"]
    tag = if kind == "number", do: "ol", else: "ul"

    inner =
      items
      |> chunk_items(level)
      |> Enum.map_join(fn {item, nested} ->
        defs = item["markDefs"] || []
        text = Enum.map_join(item["children"] || [], &span_to_html(&1, defs))
        "<li>#{text}#{list_to_html(nested, level + 1)}</li>"
      end)

    "<#{tag}>#{inner}</#{tag}>"
  end

  # Pair each level-N item with the deeper items that follow it (its sublist).
  defp chunk_items(items, level) do
    items
    |> Enum.chunk_while(
      nil,
      fn item, acc ->
        if (item["level"] || 1) <= level do
          case acc do
            nil -> {:cont, {item, []}}
            {head, nested} -> {:cont, {head, Enum.reverse(nested)}, {item, []}}
          end
        else
          case acc do
            nil -> {:cont, {item, []}}
            {head, nested} -> {:cont, {head, [item | nested]}}
          end
        end
      end,
      fn
        nil -> {:cont, nil}
        {head, nested} -> {:cont, {head, Enum.reverse(nested)}, nil}
      end
    )
  end

  defp block_to_html(%{"_type" => "hr"}), do: "<hr/>"

  defp block_to_html(%{} = block) do
    defs = block["markDefs"] || []
    inner = Enum.map_join(block["children"] || [], &span_to_html(&1, defs))
    wrap(block["style"] || "normal", inner)
  end

  defp wrap("blockquote", inner), do: "<blockquote>#{inner}</blockquote>"

  defp wrap("code", inner), do: "<pre><code>#{inner}</code></pre>"

  defp wrap("h" <> level, inner) when level in ["1", "2", "3", "4", "5", "6"],
    do: "<h#{level}>#{inner}</h#{level}>"

  defp wrap(_normal, inner), do: "<p>#{inner}</p>"

  defp span_to_html(%{} = span, defs) do
    text = esc(span["text"] || "")
    Enum.reduce(span["marks"] || [], text, &apply_mark(&1, &2, defs))
  end

  defp apply_mark("strong", acc, _defs), do: "<strong>#{acc}</strong>"
  defp apply_mark("em", acc, _defs), do: "<em>#{acc}</em>"
  defp apply_mark("code", acc, _defs), do: "<code>#{acc}</code>"
  defp apply_mark("strike", acc, _defs), do: "<s>#{acc}</s>"
  defp apply_mark("underline", acc, _defs), do: "<u>#{acc}</u>"

  defp apply_mark(key, acc, defs) do
    case Enum.find(defs, &(&1["_key"] == key)) do
      %{"_type" => "link", "href" => href} ->
        # Allowlist the URL scheme so fired `:web` HTML (consumed via innerHTML by
        # headless clients) cannot carry `javascript:`/`data:` links. A rejected
        # href degrades to the plain text rather than a live anchor.
        case KilnCMS.HTMLSanitizer.safe_href(href) do
          nil -> acc
          safe -> ~s(<a href="#{esc(safe)}">#{acc}</a>)
        end

      _ ->
        acc
    end
  end

  # ── Portable Text → plain text (search / embeddings) ──────────────────────

  @doc "Flatten PT blocks to plain text."
  @spec to_plain_text([pt_block()] | nil) :: String.t()
  def to_plain_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def to_plain_text(_), do: ""

  defp block_text(%{} = block) do
    (block["children"] || [])
    |> Enum.map_join(&(&1["text"] || ""))
    |> String.trim()
  end

  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
