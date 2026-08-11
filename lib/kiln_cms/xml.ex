defmodule KilnCMS.Xml do
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  @moduledoc """
  XML text escaping, in one place.

  Three serializers hand-rolled this: the Atom/RSS feeds, the sitemap, and the
  XLIFF exporter (#502). They had already drifted — the sitemap's copy escaped
  three characters where the feed's escaped five and stripped control bytes —
  which is the failure mode a duplicated escaper always has: the copy nobody
  looked at is the one that emits a document no parser will open.

  Two functions, because the two contexts are genuinely different:

    * `escape/1` — element text. `&`, `<`, `>`, `"` and `'` become entities;
      characters XML 1.0 cannot represent at all are dropped, because one stray
      control byte makes the whole document unparseable and losing the byte is
      the smaller failure. A carriage return becomes `&#13;`: XML 1.0 §2.11
      normalizes a literal CR to LF *before* the parser sees it, so a serializer
      that writes one raw does not round-trip.

    * `escape_attribute/1` — attribute values, which get a second normalization
      pass (§3.3.3) that turns every literal tab, newline and carriage return
      into a space. Those three travel as character references instead.
  """

  # Characters XML 1.0 cannot represent. `\\t`, `\\n` and `\\r` are deliberately
  # not in the class — they are legal, and are escaped rather than dropped.
  @illegal ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{FFFE}\x{FFFF}]/u

  # Atom-table budget for XML uploads (#1105). `:xmerl_scan` interns every
  # distinct element and attribute name with `list_to_atom/1`; atoms are never
  # reclaimed and exhausting the table aborts the whole BEAM. A crafted document
  # of 50,000 distinct tags raised the atom count by exactly 50,000 — ~8.8 bytes
  # of input per permanent atom — against a default limit of 1,048,576.
  #
  # Legitimate documents use a fixed vocabulary of a few dozen names, so a few
  # hundred is generous. The check is done with an offset-advancing
  # `:binary.match/3` loop rather than `Regex.scan/2` so a 64 MB input does not
  # materialize a match list.
  @xliff_limit 200
  @wxr_limit 500

  @doc "Distinct-name limit for XLIFF 2.0 documents."
  def xliff_limit, do: @xliff_limit

  @doc "Distinct-name limit for WXR documents."
  def wxr_limit, do: @wxr_limit

  @doc """
  Checks that the number of distinct element and attribute names in `xml` does
  not exceed `limit`.

  Returns `:ok` or `{:error, {:too_many_distinct_names, count, limit}}`.
  The scan keeps names as binaries — no atoms are interned — and uses an
  offset-advancing `:binary.match/3` loop so a 64 MB input is not expanded into
  a match list.
  """
  @spec check_distinct_names(binary(), pos_integer()) ::
          :ok | {:error, {:too_many_distinct_names, non_neg_integer(), pos_integer()}}
  def check_distinct_names(xml, limit) when is_binary(xml) and is_integer(limit) and limit > 0 do
    do_check(xml, 0, MapSet.new(), limit)
  end

  defp do_check(xml, offset, seen, limit) do
    size = byte_size(xml)

    if offset >= size do
      :ok
    else
      case :binary.match(xml, "<", scope: {offset, size - offset}) do
        :nomatch ->
          :ok

        {pos, 1} ->
          # Look ahead to decide what kind of markup this is
          cond do
            # CDATA — skip to `]]>`
            pos + 9 <= size and :binary.part(xml, pos, 9) == "<![CDATA[" ->
              case :binary.match(xml, "]]>", scope: {pos + 9, size - (pos + 9)}) do
                :nomatch -> :ok
                {end_pos, 3} -> do_check(xml, end_pos + 3, seen, limit)
              end

            # Comment — skip to `-->`
            pos + 4 <= size and :binary.part(xml, pos, 4) == "<!--" ->
              case :binary.match(xml, "-->", scope: {pos + 4, size - (pos + 4)}) do
                :nomatch -> :ok
                {end_pos, 3} -> do_check(xml, end_pos + 3, seen, limit)
              end

            # Processing instruction — skip to `?>`
            pos + 2 <= size and :binary.part(xml, pos, 2) == "<?" ->
              case :binary.match(xml, "?>", scope: {pos + 2, size - (pos + 2)}) do
                :nomatch -> :ok
                {end_pos, 2} -> do_check(xml, end_pos + 2, seen, limit)
              end

            # Declaration / DOCTYPE like `<!DOCTYPE` or `<!ENTITY` — skip to `>`
            pos + 2 <= size and :binary.part(xml, pos, 2) == "<!" ->
              case :binary.match(xml, ">", scope: {pos + 2, size - (pos + 2)}) do
                :nomatch -> :ok
                {end_pos, 1} -> do_check(xml, end_pos + 1, seen, limit)
              end

            true ->
              # Regular element tag — find its closing `>`
              case :binary.match(xml, ">", scope: {pos + 1, size - (pos + 1)}) do
                :nomatch ->
                  :ok

                {end_pos, 1} ->
                  tag_content = :binary.part(xml, pos + 1, end_pos - pos - 1)
                  seen = add_tag_names(tag_content, seen, limit)

                  case seen do
                    {:error, _} = error -> error
                    seen -> do_check(xml, end_pos + 1, seen, limit)
                  end
              end
          end
      end
    end
  end

  defp add_tag_names(tag_content, seen, limit) do
    # Tag content is between `<` and `>`, e.g. `wp:post_type="post" domain="x"`
    # Trim and handle closing tags and self-closing markers.
    trimmed = String.trim_leading(tag_content)

    # Leading `/` for closing tags — strip it for name extraction but the name
    # is still counted (a distinct closing name is still a distinct element).
    trimmed =
      case trimmed do
        <<"/", rest::binary>> -> String.trim_leading(rest)
        _ -> trimmed
      end

    # Empty or just `/` (self-closing `</>` is not XML but be tolerant)
    if trimmed == "" or trimmed == "/" do
      seen
    else
      # Element name is up to first whitespace, `/`, or `?` (for `?>` leftover)
      element_name = extract_element_name(trimmed)

      seen =
        if element_name != "" do
          maybe_add(seen, element_name, limit)
        else
          seen
        end

      case seen do
        {:error, _} = error ->
          error

        seen ->
          # Attribute names are `name=` patterns within the tag
          extract_attribute_names(tag_content, seen, limit)
      end
    end
  end

  defp extract_element_name(content) do
    # Read until whitespace, `/`, `>`, `?`, `=`, or `!` — any terminator that
    # cannot be part of a name. Names may contain `:`, `-`, `.`, `_`, digits.
    content
    |> String.split(~r/[\s\/>=\?]+/, parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      name -> String.trim_trailing(name, "/")
    end
  end

  defp extract_attribute_names(tag_content, seen, limit) do
    extract_attribute_names(tag_content, 0, seen, limit)
  end

  defp extract_attribute_names(tag_content, offset, seen, limit) do
    size = byte_size(tag_content)

    if offset >= size do
      seen
    else
      case :binary.match(tag_content, "=", scope: {offset, size - offset}) do
        :nomatch ->
          seen

        {eq_pos, 1} ->
          # Walk backwards from `eq_pos` to find attribute name start
          name = extract_name_before(tag_content, eq_pos)

          seen =
            case name do
              "" -> seen
              name -> maybe_add(seen, name, limit)
            end

          case seen do
            {:error, _} = error -> error
            seen -> extract_attribute_names(tag_content, eq_pos + 1, seen, limit)
          end
      end
    end
  end

  defp extract_name_before(content, eq_pos) do
    # Scan backwards from `eq_pos - 1`, skipping whitespace, then collecting
    # name characters `[A-Za-z0-9_:.-]`. Stop at first non-name char.
    pos = skip_whitespace_backwards(content, eq_pos - 1)
    end_pos = pos

    start_pos = find_name_start(content, pos)

    if start_pos > end_pos or start_pos < 0 do
      ""
    else
      len = end_pos - start_pos + 1
      candidate = :binary.part(content, start_pos, len) |> String.trim()

      # Must look like an XML name: start with letter, `_`, or `:`
      if candidate =~ ~r/^[A-Za-z_:][\w:.\-]*$/ do
        candidate
      else
        ""
      end
    end
  end

  defp skip_whitespace_backwards(_content, pos) when pos < 0, do: -1

  defp skip_whitespace_backwards(content, pos) do
    char = :binary.part(content, pos, 1)

    if char in [" ", "\t", "\n", "\r"] do
      skip_whitespace_backwards(content, pos - 1)
    else
      pos
    end
  end

  defp find_name_start(_content, pos) when pos < 0, do: 0

  defp find_name_start(content, pos) do
    char = :binary.part(content, pos, 1)

    if char =~ ~r/[A-Za-z0-9_:.\-]/ do
      if pos == 0 do
        0
      else
        find_name_start(content, pos - 1)
      end
    else
      pos + 1
    end
  end

  defp maybe_add(seen, name, limit) do
    # Keep names as binaries — never intern as atoms.
    if MapSet.member?(seen, name) do
      seen
    else
      new_seen = MapSet.put(seen, name)

      if MapSet.size(new_seen) > limit do
        {:error, {:too_many_distinct_names, MapSet.size(new_seen), limit}}
      else
        new_seen
      end
    end
  end

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
end
