defmodule KilnCMS.ScrollableTables do
  @moduledoc """
  Makes the tables in rendered rich text reachable from the keyboard (#2464),
  the way `KilnCMS.CodeBlocks` does for code blocks.

  A content table scrolls sideways inside its `.kiln-table-wrap` when it is
  wider than the column (`.kiln-block .kiln-table-wrap { overflow-x: auto }`),
  and a scroll container that holds no focusable element cannot be scrolled
  without a mouse or touch. Every wrapper that holds a table therefore gets
  `tabindex="0"`, so Tab reaches it and the arrow keys scroll it, and an
  accessible name, so a screen reader announces what took focus. Whether a
  table overflows depends on the reader's viewport, which the server cannot
  know, so all of them are made focusable rather than only the wide ones.

  ## The markup

      <div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Scrollable table">
        <table>…</table>
      </div>

  `role="group"` because ARIA prohibits `aria-label` on a generic `div`. Not
  `region`: that is a landmark, and a page of tables would bury its real
  landmarks under a row of same-named ones. The table inside keeps its native
  display, and so its own table semantics.

  ## The two shapes it handles

    * `<div class="kiln-table-wrap"><table>` — what
      `KilnCMS.Blocks.PortableText.to_html/1` writes for a table, and what the
      rich-text scrubber lets through from `legacy_html`. Only a wrapper whose
      first child is a table is matched: an author's `legacy_html` can put the
      class on any `div`, and a wrapper with nothing to scroll needs no focus.
    * A bare top-level `<table>` from `legacy_html` (TipTap's shape), which
      had no scroll wrapper at all and overflowed the column. It is wrapped
      first, then named like the other. A table nested inside another table's
      cell scrolls with its parent and is left alone.

  Both are matched on the exact text the scrubber emits (a lowercase
  `<table>` with no attributes, balanced end tags, `<` escaped in text and
  attribute values), which is all that reaches `RichText.render(:web)`.
  Unbalanced input is left unwrapped rather than guessed at.

  ## Where it runs

  Beside `KilnCMS.CodeBlocks.focusable/2`, at the end of
  `KilnCMS.Blocks.RichText.render(block, :web)`, after the scrubber, so the
  attributes are always the renderer's: the scrubber strips any `tabindex`,
  `role` or `aria-label` an author puts on the wrapper. Not in
  `PortableText.to_html/1`, whose output seeds the editors, and not on the
  `:json` artifact, which carries the stored prose as data. The label is
  translated in the calling process's Gettext locale, which delivery and
  firing set to the content's (`KilnCMS.CodeBlocks.with_content_locale/2`).
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  # A wrapper start tag with nothing but the class, directly (bar whitespace)
  # holding a table. One that already carries `tabindex` does not match, so a
  # second pass changes nothing.
  @wrap ~r/<div class="kiln-table-wrap">(?=\s*<table>)/

  # Any wrapper start tag, ours or already named, at the end of the text
  # before a top-level `<table>`: that table is already wrapped.
  @wrapped ~r/<div class="kiln-table-wrap"[^>]*>\s*\z/

  @doc """
  Wraps every bare top-level `<table>` in a `.kiln-table-wrap`, then adds
  `tabindex="0"`, `role="group"` and an `aria-label` to every wrapper that
  holds a table.

  HTML with no `<table>` comes back unchanged. The label is HTML-escaped.

      iex> KilnCMS.ScrollableTables.focusable("<table><tr><td>x</td></tr></table>", "Table")
      ~s(<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Table"><table><tr><td>x</td></tr></table></div>)
  """
  @spec focusable(String.t(), String.t()) :: String.t()
  def focusable(html, label \\ gettext("Scrollable table"))

  def focusable(html, label) when is_binary(html) and is_binary(label) do
    if String.contains?(html, "<table>") do
      named =
        ~s(<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="#{escape(label)}">)

      # A function, not a string: a replacement string reads `\0` in the label
      # as a back-reference.
      Regex.replace(@wrap, wrap_bare_tables(html), fn _tag -> named end)
    else
      html
    end
  end

  # Walks the table start and end tags, tracking nesting depth; a top-level
  # table not already in a wrapper gets one around its whole extent.
  defp wrap_bare_tables(html) do
    parts = Regex.split(~r{</?table>}, html, include_captures: true)

    case wrap(parts, 0, false, []) do
      {:ok, iodata} -> IO.iodata_to_binary(iodata)
      :unbalanced -> html
    end
  end

  defp wrap([], 0, _wrapping?, acc), do: {:ok, Enum.reverse(acc)}
  defp wrap([], _depth, _wrapping?, _acc), do: :unbalanced

  defp wrap(["<table>" | rest], 0, _wrapping?, acc) do
    if before_wrapped?(acc) do
      wrap(rest, 1, false, ["<table>" | acc])
    else
      wrap(rest, 1, true, [~s(<div class="kiln-table-wrap"><table>) | acc])
    end
  end

  defp wrap(["<table>" | rest], depth, wrapping?, acc),
    do: wrap(rest, depth + 1, wrapping?, ["<table>" | acc])

  defp wrap(["</table>" | _rest], 0, _wrapping?, _acc), do: :unbalanced

  defp wrap(["</table>" | rest], 1, true, acc),
    do: wrap(rest, 0, false, ["</table></div>" | acc])

  defp wrap(["</table>" | rest], depth, wrapping?, acc),
    do: wrap(rest, depth - 1, wrapping?, ["</table>" | acc])

  defp wrap([text | rest], depth, wrapping?, acc), do: wrap(rest, depth, wrapping?, [text | acc])

  # The text just before this table: the split alternates text and tags, so
  # it is the head of the accumulator.
  defp before_wrapped?([text | _]) when is_binary(text), do: Regex.match?(@wrapped, text)
  defp before_wrapped?(_acc), do: false

  defp escape(label), do: label |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
