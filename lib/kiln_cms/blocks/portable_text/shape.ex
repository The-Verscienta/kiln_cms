defmodule KilnCMS.Blocks.PortableText.Shape do
  @moduledoc """
  Lenient shape repair for a stored Portable Text body (#2768), and the strict
  check a headless write goes through (`check_body/2`).

  The `:rich_text` type casts as `{:array, :map}`, so a body can reach the
  database with a span whose `marks` is a string, `children` that are not a
  list of maps, or a `markDefs` entry that is not a map. Every reader —
  `KilnCMS.Blocks.PortableText.to_html/1`, `to_plain_text/1`, the Markdown
  view, the `:json` artifact — runs the body through `repair_body/1` first, so
  a row stored in one of those shapes renders, fires and is indexed instead of
  raising on every read.

  The repair salvages prose wherever it can, drops only what has no text to
  keep, and touches only the keys the renderers read:

    * on every node — a text block (`_type` `"block"`, `"code"` or none), a
      table cell, or a custom `_type` node:
      * `children` — a binary becomes one span carrying that text, a map
        becomes a one-element list; inside a list a binary child becomes a
        span and any other non-map entry is dropped;
      * `markDefs` — a map becomes a one-element list; non-map entries are
        dropped; a number or boolean `_key` on an entry becomes its text, and
        nothing else on an entry is touched (annotations are open objects);
    * on a text block, also `style`, `listItem` and `_key` — numbers and
      booleans become their text, anything else that is not a string is
      deleted — and `level`: a numeric string or a whole-number float becomes
      an integer, anything else that is not an integer is deleted;
    * on a span (a child whose `_type` is `"span"` or absent): `text` — numbers
      and booleans become their text, a map or list becomes `""`; `marks` — a
      binary is wrapped in a list, numbers and booleans become their text, any
      other entry is dropped; `_key` as on a block;
    * on any other child, only `marks`.

  Top-level entries that are not maps are dropped, as are table rows and
  cells that are not maps (the cast already drops those on write, #475).

  A well-formed body is returned as it is — `well_formed?/1` checks it
  without building anything. No key is ever added and `nil` values are left
  alone, since every renderer already reads a missing or `nil` key as its
  default. The function is total and idempotent.
  """

  @block_types [nil, "block", "code"]
  @span_types [nil, "span"]
  @string_slots ["style", "listItem", "_key"]

  @doc """
  The strict check a headless `block_tree` write goes through (#2768,
  `KilnCMS.CMS.Changes.ApplyBlocksInput`).

  It refuses exactly what `repair_body/1` would have to repair by dropping or
  rewriting something, and accepts what the repair only coerces. So the
  repaired form of any body passes, and nothing passes that a reader would
  still change, except for lossless coercions:

    * Refused: a node or child that is not an object; `children`, `marks` or
      `markDefs` that is not a list; a `markDefs` entry that is not an
      object; a `marks` entry that is an object or a list; on a text block
      (`_type` absent, `"block"` or `"code"`), an object or list in `style`,
      `listItem` or `_key`, or a `level` that is not an integer, a
      whole-number float or a numeric string; on a span (a child whose
      `_type` is absent or `"span"`), an object or list in `text` or `_key`.
    * Coerced (the #2743 rule), as the repair coerces them: a number or
      boolean in one of those string slots, a `marks` entry or a `markDefs`
      entry's `_key` becomes its text; a numeric-string or whole-number
      `level` becomes an integer. A `nil` entry in `marks` is dropped.
    * Left alone, as the repair leaves them: a custom node's own fields, an
      inline object's fields other than `marks`, an annotation's fields other
      than a scalar `_key`, and a table's rows and cells that are not objects
      (#475: the cast drops those). The children and `markDefs` of a custom
      node and of a table cell are checked like a text block's.

  Returns `{:ok, repair_body(blocks)}`, the coerced body, or `{:error,
  errors}`: one `"<path> must … (got …)"` string per violation, in body
  order. The path is 0-based JSON under `path` (`body[0].children[1].marks`),
  and a reason names the JSON type it found, never the value.
  """
  @spec check_body(list(), String.t()) :: {:ok, list()} | {:error, [String.t()]}
  def check_body(blocks, path \\ "body") when is_list(blocks) do
    case each(blocks, path, &check_node/2) do
      [] -> {:ok, repair_body(blocks)}
      errors -> {:error, errors}
    end
  end

  @doc "Repair a Portable Text body for reading. See the moduledoc."
  @spec repair_body(term()) :: term()
  def repair_body(blocks) when is_list(blocks) do
    if well_formed?(blocks),
      do: blocks,
      else: for(block <- blocks, is_map(block), do: repair_node(block))
  end

  def repair_body(other), do: other

  @doc """
  Whether `repair_body/1` would return `blocks` unchanged. Walks the body
  without allocating.
  """
  @spec well_formed?(term()) :: boolean()
  def well_formed?(blocks) when is_list(blocks), do: Enum.all?(blocks, &node_ok?/1)
  def well_formed?(_other), do: true

  # ── checks ──────────────────────────────────────────────────────────────────

  defp node_ok?(%{"_type" => "table"} = node), do: rows_ok?(node["rows"])

  defp node_ok?(%{} = node) do
    container_ok?(node) and
      (node["_type"] not in @block_types or
         (Enum.all?(@string_slots, &string_ok?(node[&1])) and level_ok?(node["level"])))
  end

  defp node_ok?(_other), do: false

  defp rows_ok?(rows) when is_list(rows), do: Enum.all?(rows, &row_ok?/1)
  defp rows_ok?(_absent_or_other), do: true

  defp row_ok?(%{"cells" => cells}) when is_list(cells),
    do: Enum.all?(cells, &(is_map(&1) and container_ok?(&1)))

  defp row_ok?(row), do: is_map(row)

  defp container_ok?(node), do: children_ok?(node["children"]) and defs_ok?(node["markDefs"])

  defp children_ok?(nil), do: true
  defp children_ok?(children) when is_list(children), do: Enum.all?(children, &child_ok?/1)
  defp children_ok?(_other), do: false

  defp child_ok?(%{} = child) do
    marks_ok?(child["marks"]) and
      (child["_type"] not in @span_types or
         (string_ok?(child["text"]) and string_ok?(child["_key"])))
  end

  defp child_ok?(_other), do: false

  defp marks_ok?(nil), do: true
  defp marks_ok?(marks) when is_list(marks), do: Enum.all?(marks, &is_binary/1)
  defp marks_ok?(_other), do: false

  defp defs_ok?(nil), do: true
  defp defs_ok?(defs) when is_list(defs), do: Enum.all?(defs, &def_ok?/1)
  defp defs_ok?(_other), do: false

  defp def_ok?(%{"_key" => key}) when is_number(key) or is_boolean(key), do: false
  defp def_ok?(def), do: is_map(def)

  defp string_ok?(value), do: is_binary(value) or is_nil(value)

  defp level_ok?(level), do: is_integer(level) or is_nil(level)

  # ── strict check ──────────────────────────────────────────────────────────
  #
  # Mirrors the checks above, clause for clause, but reports a path for each
  # shape the repair would drop or rewrite, and lets through what it only
  # coerces. Each check returns its errors in body order.

  defp each(items, path, check) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check.(item, "#{path}[#{index}]") end)
  end

  defp check_node(%{"_type" => "table"} = node, path) do
    case node["rows"] do
      rows when is_list(rows) -> each(rows, "#{path}.rows", &check_row/2)
      _absent_or_other -> []
    end
  end

  defp check_node(%{} = node, path) do
    block_errors =
      if node["_type"] in @block_types,
        do:
          Enum.flat_map(@string_slots, &check_string(node, &1, path)) ++ check_level(node, path),
        else: []

    block_errors ++ check_container(node, path)
  end

  defp check_node(other, path), do: [must(path, "be an object", other)]

  defp check_row(%{"cells" => cells}, path) when is_list(cells),
    do: each(cells, "#{path}.cells", &check_cell/2)

  defp check_row(_row, _path), do: []

  defp check_cell(%{} = cell, path), do: check_container(cell, path)
  defp check_cell(_cell, _path), do: []

  defp check_container(node, path) do
    check_list(node, "children", path, &check_child/2) ++
      check_list(node, "markDefs", path, &check_def/2)
  end

  defp check_list(node, key, path, check) do
    case node do
      %{^key => items} when is_list(items) -> each(items, "#{path}.#{key}", check)
      %{^key => nil} -> []
      %{^key => other} -> [must("#{path}.#{key}", "be a list", other)]
      _absent -> []
    end
  end

  defp check_child(%{} = child, path) do
    span_errors =
      if child["_type"] in @span_types,
        do: check_string(child, "text", path) ++ check_string(child, "_key", path),
        else: []

    span_errors ++ check_marks(child, path)
  end

  defp check_child(other, path), do: [must(path, "be an object", other)]

  defp check_def(%{}, _path), do: []
  defp check_def(other, path), do: [must(path, "be an object", other)]

  defp check_marks(%{"marks" => marks}, path) when is_list(marks) do
    each(marks, "#{path}.marks", fn
      mark, _path when is_binary(mark) or is_number(mark) or is_boolean(mark) or is_nil(mark) ->
        []

      mark, mark_path ->
        [must(mark_path, "be a string", mark)]
    end)
  end

  defp check_marks(%{"marks" => nil}, _path), do: []

  defp check_marks(%{"marks" => other}, path),
    do: [must("#{path}.marks", "be a list of strings", other)]

  defp check_marks(_child, _path), do: []

  defp check_string(map, key, path) do
    case map do
      %{^key => value}
      when is_binary(value) or is_nil(value) or is_number(value) or is_boolean(value) ->
        []

      %{^key => other} ->
        [must("#{path}.#{key}", "be a string", other)]

      _absent ->
        []
    end
  end

  defp check_level(%{"level" => level}, _path) when is_integer(level) or is_nil(level), do: []

  defp check_level(%{"level" => level}, path) when is_float(level) do
    if level == trunc(level),
      do: [],
      else: ["#{path}.level must be an integer (got a fractional number)"]
  end

  defp check_level(%{"level" => level}, path) when is_binary(level) do
    case Integer.parse(level) do
      {_int, ""} -> []
      _other -> ["#{path}.level must be an integer (got a non-numeric string)"]
    end
  end

  defp check_level(%{"level" => level}, path), do: [must("#{path}.level", "be an integer", level)]
  defp check_level(_node, _path), do: []

  defp must(path, expectation, value), do: "#{path} must #{expectation} (got #{kind(value)})"

  defp kind(nil), do: "null"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(value) when is_number(value), do: "a number"
  defp kind(value) when is_binary(value), do: "a string"
  defp kind(value) when is_map(value), do: "an object"
  defp kind(value) when is_list(value), do: "a list"
  defp kind(_value), do: "an unsupported value"

  # ── repairs ─────────────────────────────────────────────────────────────────

  defp repair_node(%{"_type" => "table", "rows" => rows} = node) when is_list(rows),
    do: Map.put(node, "rows", for(row <- rows, is_map(row), do: repair_cells(row)))

  defp repair_node(%{"_type" => "table"} = node), do: node

  defp repair_node(node) do
    node = repair_container(node)

    if node["_type"] in @block_types,
      do: node |> repair_string_slots(@string_slots) |> repair_level(),
      else: node
  end

  defp repair_cells(%{"cells" => cells} = row) when is_list(cells),
    do: Map.put(row, "cells", for(cell <- cells, is_map(cell), do: repair_container(cell)))

  defp repair_cells(row), do: row

  defp repair_container(node), do: node |> repair_children() |> repair_mark_defs()

  defp repair_children(%{"children" => children} = node) when is_list(children),
    do: Map.put(node, "children", Enum.flat_map(children, &repair_child/1))

  defp repair_children(%{"children" => text} = node) when is_binary(text),
    do: Map.put(node, "children", [span(text)])

  defp repair_children(%{"children" => child} = node) when is_map(child),
    do: Map.put(node, "children", repair_child(child))

  defp repair_children(%{"children" => nil} = node), do: node
  defp repair_children(%{"children" => _other} = node), do: Map.put(node, "children", [])
  defp repair_children(node), do: node

  defp repair_child(%{} = child) do
    child = repair_marks(child)

    if child["_type"] in @span_types,
      do: [child |> repair_text() |> repair_string_slots(["_key"])],
      else: [child]
  end

  defp repair_child(text) when is_binary(text), do: [span(text)]
  defp repair_child(_other), do: []

  defp span(text), do: %{"_type" => "span", "text" => text, "marks" => []}

  defp repair_marks(%{"marks" => marks} = node) when is_list(marks),
    do: Map.put(node, "marks", Enum.flat_map(marks, &repair_mark/1))

  defp repair_marks(%{"marks" => nil} = node), do: node
  defp repair_marks(%{"marks" => mark} = node), do: Map.put(node, "marks", repair_mark(mark))
  defp repair_marks(node), do: node

  defp repair_mark(mark) when is_binary(mark), do: [mark]
  defp repair_mark(mark) when is_number(mark) or is_boolean(mark), do: [to_string(mark)]
  defp repair_mark(_other), do: []

  defp repair_mark_defs(%{"markDefs" => defs} = node) when is_list(defs),
    do: Map.put(node, "markDefs", for(def <- defs, is_map(def), do: repair_def(def)))

  defp repair_mark_defs(%{"markDefs" => nil} = node), do: node

  defp repair_mark_defs(%{"markDefs" => def} = node) when is_map(def),
    do: Map.put(node, "markDefs", [repair_def(def)])

  defp repair_mark_defs(%{"markDefs" => _other} = node), do: Map.put(node, "markDefs", [])
  defp repair_mark_defs(node), do: node

  # An annotation is an open object: only the key spans point at is coerced.
  defp repair_def(%{"_key" => key} = def) when is_number(key) or is_boolean(key),
    do: Map.put(def, "_key", to_string(key))

  defp repair_def(def), do: def

  defp repair_text(%{"text" => text} = node) when is_binary(text) or is_nil(text), do: node

  defp repair_text(%{"text" => text} = node) when is_number(text) or is_boolean(text),
    do: Map.put(node, "text", to_string(text))

  defp repair_text(%{"text" => _other} = node), do: Map.put(node, "text", "")
  defp repair_text(node), do: node

  defp repair_level(%{"level" => level} = node) when is_integer(level) or is_nil(level),
    do: node

  defp repair_level(%{"level" => level} = node) when is_float(level) and level == trunc(level),
    do: Map.put(node, "level", trunc(level))

  defp repair_level(%{"level" => level} = node) when is_binary(level) do
    case Integer.parse(level) do
      {int, ""} -> Map.put(node, "level", int)
      _ -> Map.delete(node, "level")
    end
  end

  defp repair_level(%{"level" => _other} = node), do: Map.delete(node, "level")
  defp repair_level(node), do: node

  defp repair_string_slots(node, keys) do
    Enum.reduce(keys, node, fn key, node ->
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
end
