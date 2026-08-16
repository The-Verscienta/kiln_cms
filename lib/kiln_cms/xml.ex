defmodule KilnCMS.Xml do
  @moduledoc """
  XML text escaping, and the shared pre-parse guards that every `xmerl` caller
  must run.

  Three serializers hand-rolled escaping: the Atom/RSS feeds, the sitemap, and
  the XLIFF exporter (#502). They had already drifted — the sitemap's copy
  escaped three characters where the feed's escaped five and stripped control
  bytes — which is the failure mode a duplicated escaper always has: the copy
  nobody looked at is the one that emits a document no parser will open.

  Two escape functions, because the two contexts are genuinely different:

    * `escape/1` — element text. `&`, `<`, `>`, `"` and `'` become entities;
      characters XML 1.0 cannot represent at all are dropped, because one stray
      control byte makes the whole document unparseable and losing the byte is
      the smaller failure. A carriage return becomes `&#13;`: XML 1.0 §2.11
      normalizes a literal CR to LF *before* the parser sees it, so a serializer
      that writes one raw does not round-trip.

    * `escape_attribute/1` — attribute values, which get a second normalization
      pass (§3.3.3) that turns every literal tab, newline and carriage return
      into a space. Those three travel as character references instead.

  ## Name budget (#1105)

  `:xmerl_scan` interns every distinct element and attribute name with
  `list_to_atom/1`. Atoms are never reclaimed, and exhausting the table aborts
  the whole BEAM — not an exception this process can catch. A byte cap only
  changes how many uploads it takes. `check_name_budget/2` counts distinct
  names with an offset-advancing binary scan (no match list over a 64 MB
  input) and refuses past a threshold before SweetXml/xmerl ever see the
  bytes.
  """

  # Characters XML 1.0 cannot represent. `\\t`, `\\n` and `\\r` are deliberately
  # not in the class — they are legal, and are escaped rather than dropped.
  @illegal ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{FFFE}\x{FFFF}]/u

  # Legitimate XLIFF (~20) and WXR (~40) vocabularies are tiny; headroom covers
  # vendor / plugin extensions without letting a crafted document mint tens of
  # thousands of permanent atoms.
  @default_max_names 512

  @doc "Default distinct-name ceiling for `check_name_budget/2`."
  @spec max_names() :: pos_integer()
  def max_names, do: @default_max_names

  @doc "Escape a value for XML element text."
  @spec escape(term()) :: String.t()
  def escape(value), do: value |> entities() |> String.replace("\r", "&#13;")

  @doc "Escape a value for an XML attribute value (adds tab/newline/CR refs)."
  @spec escape_attribute(term()) :: String.t()
  def escape_attribute(value) do
    value
    |> entities()
    |> String.replace("\r", "&#13;")
    |> String.replace("\n", "&#10;")
    |> String.replace("\t", "&#9;")
  end

  @doc """
  Refuse XML that would intern more than `max` distinct element/attribute
  names under xmerl (#1105).

  Returns `:ok`, or `{:error, {:too_many_names, observed, max}}`. Must run
  **before** `SweetXml.parse` / `:xmerl_scan`.
  """
  @spec check_name_budget(binary(), pos_integer()) ::
          :ok | {:error, {:too_many_names, pos_integer(), pos_integer()}}
  def check_name_budget(xml, max \\ @default_max_names)
      when is_binary(xml) and is_integer(max) and max > 0 do
    case scan_names(xml, 0, %{}, max) do
      {:ok, _names} -> :ok
      {:error, count} -> {:error, {:too_many_names, count, max}}
    end
  end

  # `"` and `'` are escaped alongside the three that matter in element text so
  # that one function is safe in both contexts — a serializer must not depend on
  # a validation elsewhere staying shaped as it is.
  defp entities(value) do
    value
    |> to_string()
    |> String.replace(@illegal, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp scan_names(xml, offset, names, _max) when byte_size(xml) <= offset, do: {:ok, names}

  defp scan_names(xml, offset, names, max) do
    size = byte_size(xml)

    case :binary.match(xml, "<", scope: {offset, size - offset}) do
      :nomatch -> {:ok, names}
      {lt, 1} -> continue_after_lt(xml, lt + 1, names, max, size)
    end
  end

  defp continue_after_lt(_xml, rest_off, names, _max, size) when rest_off >= size,
    do: {:ok, names}

  defp continue_after_lt(xml, rest_off, names, max, _size) do
    case :binary.at(xml, rest_off) do
      ?! -> scan_names(xml, skip_declaration(xml, rest_off + 1), names, max)
      ?? -> scan_names(xml, skip_pi(xml, rest_off + 1), names, max)
      _ -> after_tag(xml, rest_off, names, max)
    end
  end

  defp after_tag(xml, rest_off, names, max) do
    case read_tag(xml, rest_off, names, max) do
      {:ok, names, next} -> scan_names(xml, next, names, max)
      {:error, _} = err -> err
    end
  end

  # Comments `<!-- … -->`, CDATA `<![CDATA[ … ]]>`, and DOCTYPE / other `<!…>`.
  defp skip_declaration(xml, offset) do
    size = byte_size(xml)

    cond do
      comment_start?(xml, offset, size) -> match_or_eof(xml, "-->", offset + 2, size)
      cdata_start?(xml, offset, size) -> match_or_eof(xml, "]]>", offset + 7, size)
      true -> match_or_eof(xml, ">", offset, size)
    end
  end

  defp comment_start?(xml, offset, size),
    do: offset + 2 <= size and binary_part(xml, offset, 2) == "--"

  defp cdata_start?(xml, offset, size),
    do: offset + 7 <= size and binary_part(xml, offset, 7) == "[CDATA["

  defp match_or_eof(xml, needle, from, size) do
    case :binary.match(xml, needle, scope: {from, size - from}) do
      {at, len} -> at + len
      :nomatch -> size
    end
  end

  defp skip_pi(xml, offset) do
    size = byte_size(xml)
    match_or_eof(xml, "?>", offset, size)
  end

  defp read_tag(xml, offset, names, max) do
    size = byte_size(xml)
    # Closing tags share the same name table as opening ones.
    name_off = if offset < size and :binary.at(xml, offset) == ?/, do: offset + 1, else: offset

    case read_name(xml, name_off) do
      {nil, next} ->
        {:ok, names, next}

      {name, after_name} ->
        with {:ok, names} <- put_name(names, name, max) do
          read_attributes(xml, after_name, names, max)
        end
    end
  end

  defp read_attributes(xml, offset, names, max) do
    size = byte_size(xml)
    offset = skip_ws(xml, offset)

    cond do
      offset >= size ->
        {:ok, names, offset}

      :binary.at(xml, offset) in [?>, ?/] ->
        {:ok, names, match_or_eof(xml, ">", offset, size)}

      true ->
        read_next_attribute(xml, offset, names, max)
    end
  end

  defp read_next_attribute(xml, offset, names, max) do
    case read_name(xml, offset) do
      {nil, next} when next == offset ->
        # Not a name and not a tag end — skip one byte so a malformed tag
        # cannot spin the scanner.
        read_attributes(xml, offset + 1, names, max)

      {nil, next} ->
        {:ok, names, next}

      {attr, after_attr} ->
        with {:ok, names} <- put_name(names, attr, max) do
          after_value = skip_attribute_value(xml, skip_ws(xml, after_attr))
          read_attributes(xml, after_value, names, max)
        end
    end
  end

  defp skip_attribute_value(xml, offset) do
    size = byte_size(xml)

    cond do
      offset >= size -> offset
      :binary.at(xml, offset) != ?= -> offset
      true -> skip_value_after_equals(xml, skip_ws(xml, offset + 1), size)
    end
  end

  defp skip_value_after_equals(xml, offset, size) do
    if offset < size and :binary.at(xml, offset) in [?", ?'] do
      quote = :binary.at(xml, offset)
      match_or_eof(xml, <<quote>>, offset + 1, size)
    else
      # Unquoted value — advance to whitespace or tag end.
      skip_unquoted(xml, offset)
    end
  end

  defp skip_unquoted(xml, offset) do
    size = byte_size(xml)

    Enum.reduce_while(offset..(size - 1)//1, offset, fn i, _acc ->
      case :binary.at(xml, i) do
        c when c in [?\s, ?\t, ?\n, ?\r, ?>, ?/] -> {:halt, i}
        _ -> {:cont, i + 1}
      end
    end)
  end

  defp skip_ws(xml, offset) do
    size = byte_size(xml)

    Enum.reduce_while(offset..(size - 1)//1, offset, fn i, _acc ->
      case :binary.at(xml, i) do
        c when c in [?\s, ?\t, ?\n, ?\r] -> {:cont, i + 1}
        _ -> {:halt, i}
      end
    end)
  end

  # XML Name: start with letter / `_` / `:`, continue with those plus digits / `-` / `.`.
  # Kept deliberately loose — the budget, not the grammar, is the defence.
  defp read_name(xml, offset) do
    size = byte_size(xml)

    if offset >= size do
      {nil, offset}
    else
      case :binary.at(xml, offset) do
        c when c in [?_, ?:] or (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z) ->
          stop = name_end(xml, offset + 1, size)
          {binary_part(xml, offset, stop - offset), stop}

        _ ->
          {nil, offset}
      end
    end
  end

  defp name_end(_xml, i, size) when i >= size, do: size

  defp name_end(xml, i, size) do
    case :binary.at(xml, i) do
      c
      when c in [?_, ?:, ?-, ?.] or (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z) or
             (c >= ?0 and c <= ?9) ->
        name_end(xml, i + 1, size)

      _ ->
        i
    end
  end

  # The distinct-name set is a plain map, not a `MapSet`, and that is a dialyzer
  # constraint rather than a style choice (#599 family). On Elixir 1.20+ a
  # MapSet's internal is the opaque `:sets.set/1`; opacity survives a *contract*
  # but not a success typing, so the untyped `put_name/3` here infers the
  # unrolled `{:set, …} | %{_ => []}` union for its return. Feeding that back
  # into the `scan_names/4` accumulator on the next iteration then trips
  # `call_without_opaque` under OTP 29 (invisible on CI's OTP 27). The
  # build-once-at-the-end shape used elsewhere cannot apply: the budget has to
  # be enforced *during* the scan, before a crafted document is fully read.
  # `map_size/1` is O(1) like `MapSet.size/1`, and `:sets` v2 stores exactly
  # this shape underneath, so behaviour and cost are unchanged.
  defp put_name(names, name, max) do
    names = Map.put(names, name, [])
    count = map_size(names)

    if count > max do
      {:error, count}
    else
      {:ok, names}
    end
  end
end
