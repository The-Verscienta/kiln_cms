defmodule KilnCMS.Blocks.PortableText.Markdown do
  @moduledoc """
  Portable Text → Markdown: the reverse of `KilnCMS.Markdown.to_blocks/2` for
  prose. It exists for the content editor's Markdown view, where an author
  flips a document to Markdown, edits it as text, and flips back. What it
  writes must therefore parse back (through `KilnCMS.Markdown`) into the same
  Portable Text wherever Markdown can say it:

    * styles — paragraphs, `#`–`######` headings, `>` quotes, fenced code
      (with its language);
    * lists — bullet and numbered, nested by indentation;
    * marks — `**strong**`, `*em*`, `` `code` ``, `~~strike~~`, links, and
      underline as `<u>` (Markdown has no syntax for it; the importer keeps
      the tag);
    * hard breaks, horizontal rules, and GFM tables.

  What Markdown cannot say is dropped, not approximated: a table cell's
  colspan/rowspan, and a header row anywhere but first (GFM tables always
  have one, so a table without one gets its first row promoted).

  Text is escaped, so a literal `*` or `[` in prose stays literal on the way
  back.
  """

  # Outermost first: a link wraps its formatting, and inline code — whose
  # content is never escaped — is always innermost.
  @mark_order %{"strong" => 1, "em" => 2, "strike" => 3, "underline" => 4, "code" => 5}

  @doc "Render Portable Text blocks as Markdown. Blocks are separated by a blank line."
  @spec to_markdown([map()] | nil) :: String.t()
  def to_markdown(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&is_map/1)
    |> Enum.chunk_by(&list_item?/1)
    |> Enum.flat_map(fn
      [first | _] = items ->
        if list_item?(first), do: [list(items)], else: Enum.map(items, &block/1)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def to_markdown(_), do: ""

  defp list_item?(block), do: is_map_key(block, "listItem")

  # ── Blocks ────────────────────────────────────────────────────────────────

  defp block(%{"_type" => "hr"}), do: "---"
  defp block(%{"_type" => "table"} = table), do: table(table)
  defp block(%{"style" => "code"} = block), do: code(block)

  defp block(%{"style" => "h" <> n} = block) when n in ~w(1 2 3 4 5 6) do
    case inline(block) do
      "" ->
        ""

      # A heading is one line: a hard break inside it would end the heading.
      text ->
        String.duplicate("#", String.to_integer(n)) <> " " <> String.replace(text, "  \n", " ")
    end
  end

  defp block(%{"style" => "blockquote"} = block) do
    case inline(block) do
      "" -> ""
      text -> text |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))
    end
  end

  defp block(block), do: inline(block)

  defp code(block) do
    code = block |> children() |> Enum.map_join(&(&1["text"] || ""))
    fence = fence_for(code)
    language = if is_binary(block["language"]), do: block["language"], else: ""
    fence <> language <> "\n" <> code <> "\n" <> fence
  end

  # A fence one backtick longer than the longest run inside the code.
  defp fence_for(code) do
    longest =
      ~r/`+/
      |> Regex.scan(code)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  # Consecutive items: numbered items count up per level, and a new
  # level-1 run of the other kind starts a separate list (a blank line apart,
  # or Markdown would continue the first one).
  defp list(items) do
    {lines, _counters, _kind} =
      Enum.reduce(items, {[], %{}, nil}, fn item, {lines, counters, kind} ->
        level = max(item["level"] || 1, 1)
        item_kind = item["listItem"]

        separator? = level == 1 and kind != nil and item_kind != kind

        {n, counters} = count(counters, level, separator?)

        marker = if item_kind == "number", do: "#{n}.", else: "-"
        indent = String.duplicate("    ", level - 1)
        text = item |> inline() |> String.replace("\n", "\n" <> indent <> "    ")
        line = indent <> marker <> " " <> text

        lines = if separator?, do: [line, "" | lines], else: [line | lines]
        {lines, counters, if(level == 1, do: item_kind, else: kind)}
      end)

    lines |> Enum.reverse() |> Enum.join("\n")
  end

  # The item's number at `level`. Deeper counters restart whenever a shallower
  # item appears, and every counter with a new list.
  defp count(_counters, level, true = _new_list?), do: {1, %{level => 1}}

  defp count(counters, level, false = _new_list?) do
    n = Map.get(counters, level, 0) + 1
    {n, counters |> Map.reject(fn {l, _} -> l > level end) |> Map.put(level, n)}
  end

  defp table(table) do
    rows =
      table["rows"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        row["cells"] |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.map(&cell/1)
      end)
      |> Enum.reject(&(&1 == []))

    case rows do
      [] ->
        ""

      [head | body] ->
        width = rows |> Enum.map(&length/1) |> Enum.max()
        pad = fn row -> row ++ List.duplicate("", width - length(row)) end

        [pad.(head), List.duplicate("---", width) | Enum.map(body, pad)]
        |> Enum.map_join("\n", fn cells -> "| " <> Enum.join(cells, " | ") <> " |" end)
    end
  end

  # A cell is one line: a hard break becomes `<br>`, and a pipe would end the cell.
  defp cell(cell) do
    cell |> inline() |> String.replace("  \n", "<br>") |> String.replace("|", "\\|")
  end

  # ── Inline ────────────────────────────────────────────────────────────────

  # A block's spans, with marks opened and closed as a stack so a run shared by
  # neighbouring spans is written once (`**a *b***`, not `**a****b**`), and the
  # whitespace at a span's edge moved outside its delimiters (`** a**` is not
  # emphasis).
  defp inline(block) do
    defs = List.wrap(block["markDefs"])

    {out, stack} =
      block
      |> children()
      |> merge_runs(defs)
      |> Enum.reduce({"", []}, fn {text, marks}, {out, stack} ->
        keep = common_prefix(stack, marks)
        {out, stack} = close(out, stack, length(stack) - keep)
        opening = Enum.drop(marks, keep)
        {lead, text} = split_leading_space(text, opening)
        out = out <> lead <> Enum.map_join(opening, &open/1)
        {out <> text_for(text, marks), stack ++ opening}
      end)

    {out, _} = close(out, stack, length(stack))
    String.trim(out)
  end

  defp children(block), do: block["children"] |> List.wrap() |> Enum.filter(&is_map/1)

  # Each span as `{text, marks}` with its marks resolved (a link key becomes
  # `{:link, href}`, an unknown key is dropped) and ordered; neighbours with the
  # same marks are joined, and empty spans vanish.
  defp merge_runs(spans, defs) do
    spans
    |> Enum.map(fn span -> {span["text"] || "", resolve_marks(span["marks"], defs)} end)
    |> Enum.reject(fn {text, _} -> text == "" end)
    |> Enum.chunk_by(fn {_, marks} -> marks end)
    |> Enum.map(fn [{_, marks} | _] = run -> {Enum.map_join(run, &elem(&1, 0)), marks} end)
  end

  defp resolve_marks(marks, defs) do
    marks
    |> List.wrap()
    |> Enum.flat_map(fn
      mark when is_map_key(@mark_order, mark) ->
        [mark]

      key ->
        case Enum.find(defs, &(is_map(&1) and &1["_key"] == key)) do
          %{"_type" => "link", "href" => href} when is_binary(href) and href != "" ->
            [{:link, href}]

          _ ->
            []
        end
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn
      {:link, _} -> 0
      mark -> @mark_order[mark]
    end)
  end

  defp common_prefix([a | as], [a | bs]), do: 1 + common_prefix(as, bs)
  defp common_prefix(_, _), do: 0

  defp close(out, stack, 0), do: {out, stack}

  defp close(out, stack, count) do
    {keep, closing} = Enum.split(stack, length(stack) - count)
    trimmed = String.trim_trailing(out)
    trailing = binary_part(out, byte_size(trimmed), byte_size(out) - byte_size(trimmed))
    {trimmed <> (closing |> Enum.reverse() |> Enum.map_join(&close_mark/1)) <> trailing, keep}
  end

  defp split_leading_space(text, []), do: {"", text}

  defp split_leading_space(text, _opening) do
    trimmed = String.trim_leading(text)
    {binary_part(text, 0, byte_size(text) - byte_size(trimmed)), trimmed}
  end

  defp open({:link, _href}), do: "["
  defp open("strong"), do: "**"
  defp open("em"), do: "*"
  defp open("strike"), do: "~~"
  defp open("underline"), do: "<u>"
  defp open("code"), do: "`"

  defp close_mark({:link, href}), do: "](" <> link_target(href) <> ")"
  defp close_mark("underline"), do: "</u>"
  defp close_mark(mark), do: open(mark)

  # Spaces and parentheses would end the destination early; `<…>` holds them.
  defp link_target(href) do
    if String.match?(href, ~r/[\s()<>]/),
      do: "<" <> String.replace(href, ">", "%3E") <> ">",
      else: href
  end

  # Inline code is written raw — it has no escapes — and a hard break inside
  # prose becomes Markdown's two-space line break.
  defp text_for(text, marks) do
    if "code" in marks do
      String.replace(text, "\n", " ")
    else
      text |> escape() |> String.replace("\n", "  \n")
    end
  end

  # Characters that would otherwise start Markdown syntax. Line-start markers
  # (`#`, `>`, `-`, `+`, `1.`) are escaped only where they would take effect.
  defp escape(text) do
    text
    |> String.replace(~r/([\\`*\[\]<~])/, "\\\\\\1")
    # An underscore inside a word (`snake_case`) is never emphasis.
    |> String.replace(~r/(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])/u, "\\\\_")
    |> String.split("\n")
    |> Enum.map_join("\n", &escape_line_start/1)
  end

  defp escape_line_start(line) do
    cond do
      String.match?(line, ~r/^\s*(#+(\s|$)|>|[-+](\s|$))/) ->
        String.replace(line, ~r/^(\s*)(.)/, "\\1\\\\\\2")

      String.match?(line, ~r/^\s*\d+[.)](\s|$)/) ->
        String.replace(line, ~r/^(\s*\d+)([.)])/, "\\1\\\\\\2")

      true ->
        line
    end
  end
end
