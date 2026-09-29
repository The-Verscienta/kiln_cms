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
      # A trailing `#` would read as the optional closing sequence (the parser
      # ignores a `\#` there, so it is written as an entity).
      text ->
        text = text |> String.replace("  \n", " ") |> String.replace(~r/#(\s*)$/, "&#35;\\1")
        String.duplicate("#", String.to_integer(n)) <> " " <> text
    end
  end

  defp block(%{"style" => "blockquote"} = block) do
    case inline(block) do
      "" ->
        ""

      # Each line keeps its trailing two-space hard break.
      text ->
        text
        |> String.split("\n")
        |> Enum.map_join("\n", fn
          "" -> ">"
          line -> "> " <> line
        end)
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
  defp fence_for(code), do: String.duplicate("`", max(3, longest_backtick_run(code) + 1))

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
  # emphasis). Inline code is not on the stack: each run writes its own code
  # span (see `text_for/2`), since nothing inside one is Markdown.
  defp inline(block) do
    defs = List.wrap(block["markDefs"])

    {out, stack} =
      block
      |> children()
      |> merge_runs(defs)
      |> Enum.reduce({"", []}, &emit_run/2)

    {out, _} = close(out, stack, length(stack))
    String.trim(out)
  end

  # A whitespace-only run opens nothing: `** **` is not emphasis, and its
  # delimiters would be left as literal asterisks.
  defp emit_run({text, marks}, {out, stack}) do
    if String.trim(text) == "" and "code" not in marks do
      {out <> text_for(text, []), stack}
    else
      # Keep the open marks this run still carries, in the order they were
      # opened; close the rest and open what is new. Reordering them would
      # close and reopen a mark mid-word (`*a****b***`).
      keep = stack |> Enum.take_while(fn {mark, _} -> mark in marks end) |> length()
      {out, stack} = close(out, stack, length(stack) - keep)
      opening = (marks -- ["code"]) -- Enum.map(stack, &elem(&1, 0))
      {lead, text} = split_leading_space(text, opening)
      {out, opened} = open_marks(out <> lead, opening)
      {out <> text_for(text, marks), stack ++ opened}
    end
  end

  defp open_marks(out, marks) do
    Enum.reduce(marks, {out, []}, fn mark, {out, opened} ->
      style = style_for(mark, out)
      {open(out, mark, style), opened ++ [{mark, style}]}
    end)
  end

  # A `*` delimiter straight after another (`**a***b*`) runs into it, and the
  # parser reads the pair as one run. The HTML element says the same thing
  # unambiguously, and the importer keeps it.
  defp style_for(mark, out) when mark in ["strong", "em"],
    do: if(String.ends_with?(out, "*"), do: :html, else: :markdown)

  defp style_for(_mark, _out), do: :markdown
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

  # A `!` right before a link's `[` would make it an image.
  defp open(out, {:link, _href}, _style) do
    if String.ends_with?(out, "!"),
      do: binary_part(out, 0, byte_size(out) - 1) <> "\\![",
      else: out <> "["
  end

  defp open(out, mark, :html), do: out <> "<" <> html_tag(mark) <> ">"
  defp open(out, "strong", :markdown), do: out <> "**"
  defp open(out, "em", :markdown), do: out <> "*"
  defp open(out, "strike", :markdown), do: out <> "~~"
  defp open(out, "underline", :markdown), do: out <> "<u>"

  defp close_mark({{:link, href}, _style}), do: "](" <> link_target(href) <> ")"
  defp close_mark({mark, :html}), do: "</" <> html_tag(mark) <> ">"
  defp close_mark({"strong", :markdown}), do: "**"
  defp close_mark({"em", :markdown}), do: "*"
  defp close_mark({"strike", :markdown}), do: "~~"
  defp close_mark({"underline", :markdown}), do: "</u>"

  defp html_tag("strong"), do: "strong"
  defp html_tag("em"), do: "em"

  # Spaces and parentheses would end the destination early, and the parser
  # takes no `<…>` destination, so they are percent-encoded — the same URL.
  defp link_target(href),
    do: Regex.replace(~r/[\s()<>]/, href, fn char -> "%" <> Base.encode16(char) end)

  # Inline code is written raw — it has no escapes — between backtick runs
  # longer than any inside it (padded when it starts or ends with one), and a
  # hard break inside prose becomes Markdown's two-space line break.
  defp text_for(text, marks) do
    if "code" in marks do
      code = String.replace(text, "\n", " ")
      ticks = String.duplicate("`", longest_backtick_run(code) + 1)
      pad = if String.starts_with?(code, "`") or String.ends_with?(code, "`"), do: " ", else: ""
      ticks <> pad <> code <> pad <> ticks
    else
      text |> escape() |> String.replace("\n", "  \n")
    end
  end

  defp longest_backtick_run(code) do
    ~r/`+/
    |> Regex.scan(code)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  # Characters that would otherwise start Markdown syntax. Line-start markers
  # (`#`, `>`, `-`, `+`, `1.`, a `---`/`===` rule or underline) are escaped only
  # where they would take effect. `&` and `<` become entities: the parser
  # treats `\<` as the start of raw HTML all the same, and a bare `&copy;`
  # as the character it names.
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(~r/([\\`*\[\]~])/, "\\\\\\1")
    # An underscore inside a word (`snake_case`) is never emphasis.
    |> String.replace(~r/(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])/u, "\\\\_")
    |> String.split("\n")
    |> Enum.map_join("\n", &escape_line_start/1)
  end

  defp escape_line_start(line) do
    cond do
      # The parser ignores `\=`, so an underline is broken with an entity.
      String.match?(line, ~r/^\s*=+\s*$/) ->
        String.replace(line, "=", "&#61;", global: false)

      String.match?(line, ~r/^\s*(#+(\s|$)|>|[-+](\s|$)|-+\s*$)/) ->
        String.replace(line, ~r/^(\s*)(.)/, "\\1\\\\\\2")

      String.match?(line, ~r/^\s*\d+[.)](\s|$)/) ->
        String.replace(line, ~r/^(\s*\d+)([.)])/, "\\1\\\\\\2")

      true ->
        line
    end
  end
end
