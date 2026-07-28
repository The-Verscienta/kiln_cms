defmodule KilnCMS.Collab.Crdt.Materializer do
  @moduledoc """
  Renders a collab Y.Doc's rich-text fragment to **sanitized HTML on the
  BEAM** — the server-side half of checkpoint materialization (spike doc §8).

  A `y-prosemirror` fragment serializes ProseMirror *node* XML
  (`<paragraph>`, `<bulletList>`, …), not HTML, so this maps the closed
  TipTap StarterKit node/mark set — the same set the editor can produce and
  `KilnCMS.HTMLSanitizer.RichText` allowlists — to its HTML. The mapping is
  **total**: unknown elements render their children, unknown marks render as
  plain text, so a future block extension degrades instead of crashing. All
  text is HTML-escaped and the final result passes through the rich-text
  sanitizer, exactly like editor-submitted HTML.
  """

  alias KilnCMS.HTMLSanitizer

  @doc """
  The sanitized HTML for `fragment_name` of `doc`, or `nil` when the fragment
  is empty/absent (callers must not clobber stored HTML with emptiness — a
  block that was never collaboratively edited has no fragment).
  """
  @spec fragment_html(Yex.Doc.t(), String.t()) :: String.t() | nil
  def fragment_html(doc, fragment_name) do
    fragment = Yex.Doc.get_xml_fragment(doc, fragment_name)

    if Yex.XmlFragment.length(fragment) == 0 do
      nil
    else
      fragment
      |> children(&Yex.XmlFragment.fetch!/2, Yex.XmlFragment.length(fragment))
      |> Enum.map(&render_node/1)
      |> IO.iodata_to_binary()
      |> HTMLSanitizer.sanitize_rich_text()
    end
  end

  defp children(container, fetch, count) when count > 0,
    do: Enum.map(0..(count - 1), &fetch.(container, &1))

  defp children(_container, _fetch, _count), do: []

  # ── nodes ───────────────────────────────────────────────────────────────────

  defp render_node(%Yex.XmlElement{} = el),
    do: wrap(Yex.XmlElement.get_tag(el), el)

  defp render_node(%Yex.XmlText{} = text) do
    text
    |> Yex.XmlText.to_delta()
    |> Enum.map(&render_delta_op/1)
  end

  defp render_node(_other), do: []

  defp wrap("paragraph", el), do: ["<p>", element_children_html(el), "</p>"]
  defp wrap("heading", el), do: heading(el)
  defp wrap("bulletList", el), do: ["<ul>", element_children_html(el), "</ul>"]
  defp wrap("orderedList", el), do: ["<ol>", element_children_html(el), "</ol>"]
  defp wrap("listItem", el), do: ["<li>", element_children_html(el), "</li>"]
  defp wrap("blockquote", el), do: ["<blockquote>", element_children_html(el), "</blockquote>"]

  defp wrap("codeBlock", el),
    do: ["<pre><code", code_language_attr(el), ">", element_children_html(el), "</code></pre>"]

  defp wrap("horizontalRule", _el), do: ["<hr>"]
  defp wrap("hardBreak", _el), do: ["<br>"]
  # Tables (#475): keep the structural markup — the pre-table fallback
  # flattened collaboratively-authored tables to a run of bare paragraphs the
  # moment a crash-recovery checkpoint materialized them.
  defp wrap("table", el), do: ["<table>", element_children_html(el), "</table>"]
  defp wrap("tableRow", el), do: ["<tr>", element_children_html(el), "</tr>"]
  defp wrap("tableHeader", el), do: table_cell(el, "th")
  defp wrap("tableCell", el), do: table_cell(el, "td")
  # Total: unknown nodes contribute their children, not a crash.
  defp wrap(_unknown, el), do: element_children_html(el)

  defp table_cell(el, tag),
    do: ["<", tag, cell_span_attrs(el), ">", element_children_html(el), "</", tag, ">"]

  # The language tag the #503 dropdown stores on the codeBlock node; carried as
  # a `language-…` class so the checkpoint keeps what the editor chose.
  defp code_language_attr(el) do
    with %{"language" => language} <- Yex.XmlElement.get_attributes(el),
         tag when is_binary(tag) <- KilnCMS.Highlight.normalize(to_string(language)) do
      [~s( class="language-), tag, ~s(")]
    else
      _absent_or_implausible -> []
    end
  end

  defp cell_span_attrs(el) do
    attrs =
      case Yex.XmlElement.get_attributes(el) do
        %{} = map -> map
        _other -> %{}
      end

    Enum.flat_map(["colspan", "rowspan"], fn key ->
      case attrs[key] |> to_string() |> Integer.parse() do
        {n, _rest} when n > 1 -> [~s( #{key}="#{n}")]
        _default_or_invalid -> []
      end
    end)
  end

  defp element_children_html(el) do
    el
    |> children(&Yex.XmlElement.fetch!/2, Yex.XmlElement.length(el))
    |> Enum.map(&render_node/1)
  end

  defp heading(el) do
    level =
      case Yex.XmlElement.get_attributes(el) do
        %{"level" => l} -> l |> to_string() |> Integer.parse() |> clamp_level()
        _none -> 2
      end

    ["<h#{level}>", element_children_html(el), "</h#{level}>"]
  end

  defp clamp_level({n, _rest}) when n in 1..6, do: n
  defp clamp_level(_other), do: 2

  # ── text runs & marks ───────────────────────────────────────────────────────

  # Mark name → HTML tag, in a stable outer→inner nesting order (matching what
  # the sanitizer allows; unknown marks are dropped, keeping the text).
  @marks [{"bold", "strong"}, {"italic", "em"}, {"strike", "s"}, {"code", "code"}]

  defp render_delta_op(%{insert: text} = op) when is_binary(text) do
    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    apply_marks(escaped, Map.get(op, :attributes, %{}))
  end

  defp render_delta_op(_other), do: []

  defp apply_marks(iodata, attrs) do
    Enum.reduce(Enum.reverse(@marks), iodata, fn {mark, tag}, acc ->
      if Map.has_key?(attrs, mark), do: ["<#{tag}>", acc, "</#{tag}>"], else: acc
    end)
  end
end
