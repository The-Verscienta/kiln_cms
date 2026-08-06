defmodule KilnCMS.Collab.Crdt.Materializer do
  @moduledoc """
  Renders a collab Y.Doc's rich-text fragment to **Portable Text on the BEAM** —
  the server-side half of checkpoint materialization (spike doc §8).

  A `y-prosemirror` fragment serializes ProseMirror *node* XML (`<paragraph>`,
  `<bulletList>`, …). Those tag names are already TipTap's node names, so this
  reassembles the fragment into the TipTap JSON document the browser would have
  pushed and hands it to `KilnCMS.Blocks.PortableText.from_tiptap/1` — the same
  converter every client save goes through.

  Going via TipTap JSON rather than rendering HTML directly is the whole point:

    * **The checkpoint writes what a save writes.** Portable Text is
      authoritative, so `TypedBlocks` nulls `legacy_html` whenever `body` is
      present. A checkpoint that materialized to HTML wrote into `legacy_html`
      and had it discarded on the way in — the crash-recovery net was inert for
      every block the editor had ever saved, while still burning a write and a
      version.
    * **Marks stay in one place.** A second renderer means a second list of
      marks to keep in step, and it silently fell behind: it knew bold, italic,
      strike and code, so the links #823 made authorable were dropped from every
      collaborative checkpoint. `from_tiptap/1` already turns link marks into
      `markDefs`, and `sanitize_def/1` already gates their hrefs through
      `KilnCMS.HTMLSanitizer.safe_href/1`.

  The mapping is **total**: unknown elements contribute their children and
  unknown marks their plain text, so a future block extension degrades instead
  of crashing.
  """

  alias KilnCMS.Blocks.PortableText

  # Marks that are a bare flag in the y-prosemirror delta, in the order
  # `from_tiptap/1` will fold them. `link` is not here — it carries an `href`
  # attribute and is built separately below.
  @flag_marks ~w(bold italic strike code underline)

  @doc """
  The Portable Text for `fragment_name` of `doc`, or `nil` when the fragment is
  empty/absent.

  `nil` is not the same as `[]`: callers must not clobber stored prose with
  emptiness, because a block that was never collaboratively edited has no
  fragment at all.

  The result is run through `PortableText.sanitize_body/1` here rather than
  left to the block cast, so a caller can compare it against what is already
  stored — both sides are then canonical, and an unchanged document compares
  equal instead of forcing a pointless write.
  """
  @spec fragment_body(Yex.Doc.t(), String.t()) :: [PortableText.pt_block()] | nil
  def fragment_body(doc, fragment_name) do
    case fragment_doc(doc, fragment_name) do
      nil -> nil
      tiptap -> tiptap |> PortableText.from_tiptap() |> PortableText.sanitize_body()
    end
  end

  @doc """
  The TipTap JSON document for `fragment_name`, or `nil` when the fragment is
  empty/absent — the interchange step `fragment_body/2` converts.
  """
  @spec fragment_doc(Yex.Doc.t(), String.t()) :: map() | nil
  def fragment_doc(doc, fragment_name) do
    fragment = Yex.Doc.get_xml_fragment(doc, fragment_name)

    if Yex.XmlFragment.length(fragment) == 0 do
      nil
    else
      content =
        fragment
        |> children(&Yex.XmlFragment.fetch!/2, Yex.XmlFragment.length(fragment))
        |> Enum.flat_map(&node_json/1)
        |> wrap_inline()

      %{"type" => "doc", "content" => content}
    end
  end

  defp children(container, fetch, count) when count > 0,
    do: Enum.map(0..(count - 1), &fetch.(container, &1))

  defp children(_container, _fetch, _count), do: []

  # ── nodes ───────────────────────────────────────────────────────────────────

  # A node can contribute several TipTap nodes (an unknown element contributes
  # its children in its place), so every clause returns a list.
  defp node_json(%Yex.XmlElement{} = el), do: element_json(Yex.XmlElement.get_tag(el), el)

  defp node_json(%Yex.XmlText{} = text) do
    text
    |> Yex.XmlText.to_delta()
    |> Enum.flat_map(&delta_json/1)
  end

  defp node_json(_other), do: []

  # Childless nodes.
  defp element_json(tag, _el) when tag in ~w(horizontalRule hardBreak),
    do: [%{"type" => tag}]

  defp element_json("heading", el),
    do: [%{"type" => "heading", "attrs" => %{"level" => level(el)}, "content" => content(el)}]

  defp element_json("codeBlock", el) do
    attrs =
      case Yex.XmlElement.get_attributes(el) do
        %{"language" => language} -> %{"language" => to_string(language)}
        _absent -> %{}
      end

    [%{"type" => "codeBlock", "attrs" => attrs, "content" => content(el)}]
  end

  defp element_json(tag, el) when tag in ~w(tableHeader tableCell),
    do: [%{"type" => tag, "attrs" => cell_attrs(el), "content" => block_content(el)}]

  # Containers whose children are blocks. Their content is wrapped, because an
  # unknown element inside one hands back inline children that `from_tiptap/1`
  # would otherwise walk as if they were blocks and flatten to an empty
  # paragraph — losing the very text the "unknown degrades" contract promises
  # to keep.
  defp element_json(tag, el)
       when tag in ~w(bulletList orderedList listItem blockquote table tableRow),
       do: [%{"type" => tag, "content" => block_content(el)}]

  # Containers whose children are inline.
  defp element_json("paragraph", el),
    do: [%{"type" => "paragraph", "content" => content(el)}]

  # Total: an unknown element contributes its children, not a crash. The
  # wrapping above is what keeps those children from being dropped.
  defp element_json(_unknown, el), do: content(el)

  defp content(el) do
    el
    |> children(&Yex.XmlElement.fetch!/2, Yex.XmlElement.length(el))
    |> Enum.flat_map(&node_json/1)
  end

  defp block_content(el), do: el |> content() |> wrap_inline()

  @inline ~w(text hardBreak)

  # Gather each run of inline nodes into a paragraph, leaving blocks alone.
  defp wrap_inline(nodes) do
    nodes
    |> Enum.chunk_by(&(&1["type"] in @inline))
    |> Enum.flat_map(fn
      [%{"type" => type} | _] = run when type in @inline ->
        [%{"type" => "paragraph", "content" => run}]

      blocks ->
        blocks
    end)
  end

  defp level(el) do
    case Yex.XmlElement.get_attributes(el) do
      %{"level" => l} -> l |> to_string() |> Integer.parse() |> clamp_level()
      _none -> 2
    end
  end

  defp clamp_level({n, _rest}) when n in 1..6, do: n
  defp clamp_level(_other), do: 2

  # Y attributes come back as strings; `from_tiptap/1` stores a span only for an
  # INTEGER greater than 1, so parse here or every colspan is silently dropped.
  defp cell_attrs(el) do
    attrs = Yex.XmlElement.get_attributes(el)

    Map.new(["colspan", "rowspan"], fn key ->
      case attrs[key] |> to_string() |> Integer.parse() do
        {n, _rest} when n > 1 -> {key, n}
        _default_or_invalid -> {key, 1}
      end
    end)
  end

  # ── text runs & marks ───────────────────────────────────────────────────────

  defp delta_json(%{insert: text} = op) when is_binary(text) and text != "",
    do: [%{"type" => "text", "text" => text, "marks" => marks(Map.get(op, :attributes, %{}))}]

  defp delta_json(_other), do: []

  defp marks(attrs) when is_map(attrs) do
    flags = Enum.filter(@flag_marks, &Map.has_key?(attrs, &1))

    Enum.map(flags, &%{"type" => &1}) ++ link_mark(attrs)
  end

  defp marks(_other), do: []

  # The href is carried through as authored; `PortableText.sanitize_def/1` is
  # what decides whether it survives, so this path can't disagree with the
  # editor's or the API's.
  defp link_mark(%{"link" => %{"href" => href}}) when is_binary(href),
    do: [%{"type" => "link", "attrs" => %{"href" => href}}]

  defp link_mark(_absent), do: []
end
