defmodule KilnCMS.Blocks.PortableText.Shape do
  @moduledoc """
  Lenient shape repair for a stored Portable Text body (#2768).

  The `:rich_text` type casts as `{:array, :map}`, so a body can reach the
  database with a span whose `marks` is a string, `children` that are not a
  list of maps, or a `markDefs` entry that is not a map. Every reader —
  `KilnCMS.Blocks.PortableText.to_html/1`, `to_plain_text/1`, the Markdown
  view, the `:json` artifact — runs the body through `repair_body/1` first, so
  a row stored in one of those shapes renders, fires and is indexed instead of
  raising on every read.

  The repair salvages prose wherever it can and drops only what has no text
  to keep. It checks the standard keys on **every** map node — blocks, spans,
  `markDefs` entries, custom `_type` nodes and table cells alike:

    * `children` — a binary becomes one span carrying that text, a map becomes
      a one-element list; inside a list a binary child becomes a span and any
      other non-map entry is dropped;
    * `marks` — a binary is wrapped in a list; numbers and booleans become
      their text; any other entry is dropped;
    * `markDefs` — a map becomes a one-element list; non-map entries are dropped;
    * `text`, `style`, `listItem`, `_key` — numbers and booleans become their
      text; a map or list in `text` becomes `""`, in the others the key is
      deleted;
    * `level` — a numeric string becomes an integer; anything else that is
      not an integer is deleted.

  Top-level entries that are not maps are dropped, as are table rows and
  cells that are not maps (the cast already drops those on write, #475).

  A body that is already valid comes back unchanged: no key is ever added and
  `nil` values are left alone, since every renderer already reads a missing
  or `nil` key as its default. The function is total and idempotent.
  """

  @string_slots ["style", "listItem", "_key"]

  @doc "Repair a Portable Text body for reading. See the moduledoc."
  @spec repair_body(term()) :: term()
  def repair_body(blocks) when is_list(blocks) do
    for block <- blocks, is_map(block), do: repair_node(block)
  end

  def repair_body(other), do: other

  defp repair_node(node) do
    node
    |> repair_children()
    |> repair_marks()
    |> repair_mark_defs()
    |> repair_text()
    |> repair_level()
    |> repair_string_slots()
    |> repair_rows()
  end

  defp repair_children(%{"children" => children} = node) when is_list(children),
    do: Map.put(node, "children", Enum.flat_map(children, &repair_child/1))

  defp repair_children(%{"children" => text} = node) when is_binary(text),
    do: Map.put(node, "children", [span(text)])

  defp repair_children(%{"children" => child} = node) when is_map(child),
    do: Map.put(node, "children", [repair_node(child)])

  defp repair_children(%{"children" => nil} = node), do: node
  defp repair_children(%{"children" => _other} = node), do: Map.put(node, "children", [])
  defp repair_children(node), do: node

  defp repair_child(child) when is_map(child), do: [repair_node(child)]
  defp repair_child(text) when is_binary(text), do: [span(text)]
  defp repair_child(_other), do: []

  defp span(text), do: %{"_type" => "span", "text" => text, "marks" => []}

  defp repair_marks(%{"marks" => marks} = node) when is_list(marks),
    do: Map.put(node, "marks", Enum.flat_map(marks, &repair_mark/1))

  defp repair_marks(%{"marks" => nil} = node), do: node

  defp repair_marks(%{"marks" => mark} = node),
    do: Map.put(node, "marks", repair_mark(mark))

  defp repair_marks(node), do: node

  defp repair_mark(mark) when is_binary(mark), do: [mark]
  defp repair_mark(mark) when is_number(mark) or is_boolean(mark), do: [to_string(mark)]
  defp repair_mark(_other), do: []

  defp repair_mark_defs(%{"markDefs" => defs} = node) when is_list(defs),
    do: Map.put(node, "markDefs", for(def <- defs, is_map(def), do: repair_node(def)))

  defp repair_mark_defs(%{"markDefs" => nil} = node), do: node

  defp repair_mark_defs(%{"markDefs" => def} = node) when is_map(def),
    do: Map.put(node, "markDefs", [repair_node(def)])

  defp repair_mark_defs(%{"markDefs" => _other} = node), do: Map.put(node, "markDefs", [])
  defp repair_mark_defs(node), do: node

  defp repair_text(%{"text" => text} = node) when is_binary(text) or is_nil(text), do: node

  defp repair_text(%{"text" => text} = node) when is_number(text) or is_boolean(text),
    do: Map.put(node, "text", to_string(text))

  defp repair_text(%{"text" => _other} = node), do: Map.put(node, "text", "")
  defp repair_text(node), do: node

  defp repair_level(%{"level" => level} = node) when is_integer(level) or is_nil(level),
    do: node

  defp repair_level(%{"level" => level} = node) when is_binary(level) do
    case Integer.parse(level) do
      {int, ""} -> Map.put(node, "level", int)
      _ -> Map.delete(node, "level")
    end
  end

  defp repair_level(%{"level" => _other} = node), do: Map.delete(node, "level")
  defp repair_level(node), do: node

  defp repair_string_slots(node) do
    Enum.reduce(@string_slots, node, fn key, node ->
      case node do
        %{^key => value} when is_binary(value) or is_nil(value) ->
          node

        %{^key => value} when is_number(value) or is_boolean(value) ->
          Map.put(node, key, to_string(value))

        %{^key => _other} ->
          Map.delete(node, key)

        _absent ->
          node
      end
    end)
  end

  # Table items (#475) keep their spans one level down, in cells.
  defp repair_rows(%{"_type" => "table", "rows" => rows} = node) when is_list(rows),
    do: Map.put(node, "rows", for(row <- rows, is_map(row), do: repair_cells(row)))

  defp repair_rows(node), do: node

  defp repair_cells(%{"cells" => cells} = row) when is_list(cells),
    do: Map.put(row, "cells", for(cell <- cells, is_map(cell), do: repair_node(cell)))

  defp repair_cells(row), do: row
end
