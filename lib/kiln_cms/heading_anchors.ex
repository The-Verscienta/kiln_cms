defmodule KilnCMS.HeadingAnchors do
  @moduledoc """
  `id`s for headings on public pages, so a link to `…#some-section` lands on
  that section instead of the top of the page.

  The slug is GitHub's (github-slugger): lowercase, drop punctuation and
  symbols, turn each space into `-`, and number repeats `-1`, `-2`, … in
  document order. Matching it exactly is the point — Kiln's guides are written
  in Markdown on GitHub and link to each other's sections by those slugs, and
  so does Markdown imported from anywhere else GitHub-flavoured.

  ## Where ids are put on

  Only on public HTML delivery (`KilnCMSWeb.ContentController`), once per
  page, over the whole block tree — heading blocks, the headings inside
  rich-text prose, and both inside `columns` — so repeats are numbered across
  the page rather than per block.

  Not in the renderers (`PortableText.to_html/1`, `Heading.render/2`), and so
  not in fired `:web` artifacts or the editor previews: those render one block
  at a time, where two blocks sharing a heading would share an id, and the
  previews are LiveViews, where a duplicate id breaks DOM patching.

  Ids are derived, never stored. The rich-text scrubber
  (`KilnCMS.HTMLSanitizer.RichText`) still strips every attribute off a
  heading, so an author picks the words, not the id.
  """

  # Everything github-slugger keeps: letters, combining marks, digits,
  # connector punctuation (`_`), `-` and space. The id charset is therefore
  # closed — no quote, `<` or `&` can reach the attribute.
  @stripped ~r/[^\p{L}\p{M}\p{N}\p{Pc} -]/u

  @bare_heading ~r/<h([1-6])>(.*?)<\/h\1>/s

  @doc """
  The anchor slug for a heading's plain text, or `nil` when nothing survives
  (a heading of only punctuation or emoji gets no id).

      iex> KilnCMS.HeadingAnchors.slug("5. What shipped: the PWA")
      "5-what-shipped-the-pwa"
  """
  @spec slug(String.t() | nil) :: String.t() | nil
  def slug(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> String.replace(@stripped, "")
    |> String.replace(" ", "-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  def slug(_), do: nil

  @doc """
  Anchors a public page's rendered block tree (the maps
  `KilnCMSWeb.BlockComponents.render_block/1` takes): a `heading` block gets
  an `:anchor`, a `rich_text` block's bare `<h1>`–`<h6>` get an `id`, and
  `columns` children are walked in place. One numbering runs over the page.
  """
  @spec anchor_tree([map()]) :: [map()]
  def anchor_tree(blocks) when is_list(blocks) do
    {blocks, _seen} = anchor_blocks(blocks, %{})
    blocks
  end

  @doc """
  Adds an `id` to every bare `<h1>`–`<h6>` in `html`, numbering repeats.

  Expects renderer or scrubber output: headings with no attributes, text
  entity-escaped. A heading that already carries attributes is left alone.
  """
  @spec put_ids(String.t()) :: String.t()
  def put_ids(html) when is_binary(html), do: html |> put_ids(%{}) |> elem(0)

  defp anchor_blocks(blocks, seen), do: Enum.map_reduce(blocks, seen, &anchor_block/2)

  defp anchor_block(%{type: "heading", content: text} = block, seen) do
    case slug(text) do
      nil ->
        {block, seen}

      base ->
        {id, seen} = unique(base, seen)
        {Map.put(block, :anchor, id), seen}
    end
  end

  defp anchor_block(%{type: "rich_text", content: html} = block, seen) when is_binary(html) do
    {html, seen} = put_ids(html, seen)
    {%{block | content: html}, seen}
  end

  defp anchor_block(%{type: "columns", columns: cols} = block, seen) when is_list(cols) do
    {cols, seen} =
      Enum.map_reduce(cols, seen, fn col, seen ->
        {children, seen} = anchor_blocks(Map.get(col, :blocks, []), seen)
        {Map.put(col, :blocks, children), seen}
      end)

    {%{block | columns: cols}, seen}
  end

  defp anchor_block(block, seen), do: {block, seen}

  defp put_ids(html, seen) do
    if String.contains?(html, ["<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>"]) do
      {chunks, seen} =
        @bare_heading
        |> Regex.split(html, include_captures: true)
        |> Enum.map_reduce(seen, &put_id/2)

      {IO.iodata_to_binary(chunks), seen}
    else
      {html, seen}
    end
  end

  # `Regex.split/3` with `include_captures` hands back each whole match as
  # its own chunk, so a chunk is either a bare heading or the text between.
  defp put_id("<h" <> _ = chunk, seen) do
    case Regex.run(~r/\A<h([1-6])>(.*)<\/h[1-6]>\z/s, chunk) do
      [_, level, inner] ->
        case slug(text_of(inner)) do
          nil ->
            {chunk, seen}

          base ->
            {id, seen} = unique(base, seen)
            {[~s(<h#{level} id="#{id}">), inner, "</h#{level}>"], seen}
        end

      nil ->
        {chunk, seen}
    end
  end

  defp put_id(chunk, seen), do: {chunk, seen}

  # github-slugger's counter: the first `x` is `x`, then `x-1`, `x-2`; a
  # heading whose own text slugs to an already-issued `x-1` is bumped too.
  defp unique(base, seen), do: unique(base, base, seen)

  defp unique(candidate, base, seen) do
    if Map.has_key?(seen, candidate) do
      n = Map.get(seen, base, 0) + 1
      unique("#{base}-#{n}", base, Map.put(seen, base, n))
    else
      {candidate, Map.put(seen, candidate, 0)}
    end
  end

  # The heading's textContent. Named entities the renderers emit (`&amp;`,
  # `&lt;`, `&quot;`, `&nbsp;` …) all decode to characters the slug drops, so
  # they are dropped here; numeric references can spell letters and decode.
  defp text_of(inner) do
    inner
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/&#(x[0-9a-fA-F]+|[0-9]+);/, &decode_numeric/1)
    |> String.replace(~r/&[a-zA-Z][a-zA-Z0-9]*;/, "")
  end

  defp decode_numeric("&#" <> ref) do
    ref = String.trim_trailing(ref, ";")

    code =
      case ref do
        "x" <> hex -> String.to_integer(hex, 16)
        dec -> String.to_integer(dec)
      end

    if code <= 0x10FFFF and code not in 0xD800..0xDFFF, do: <<code::utf8>>, else: ""
  end
end
