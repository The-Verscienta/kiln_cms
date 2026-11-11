defmodule KilnCMS.ScrollableTablesTest do
  @moduledoc """
  Table scroll wrappers take keyboard focus and carry a name (#2464):
  `focusable/2` on its own, and its one call site, the rich-text `:web`
  renderer — over Portable Text tables and over `legacy_html`, wrapped or
  bare — while the `:json` artifact and `PortableText.to_html/1` (which seeds
  the editors) stay plain.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.RichText
  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.ScrollableTables

  doctest KilnCMS.ScrollableTables

  @attrs ~s(tabindex="0" role="group" aria-label="Scrollable table")
  @open ~s(<div class="kiln-table-wrap" #{@attrs}>)
  @table "<table><tbody><tr><td>a</td></tr></tbody></table>"

  describe "focusable/2" do
    test "a wrapper holding a table takes focus and a name" do
      assert ScrollableTables.focusable(~s(<div class="kiln-table-wrap">#{@table}</div>)) ==
               "#{@open}#{@table}</div>"
    end

    test "whitespace between the wrapper and its table still matches" do
      html = ~s(<div class="kiln-table-wrap">\n  #{@table}</div>)
      assert ScrollableTables.focusable(html) == "#{@open}\n  #{@table}</div>"
    end

    test "a wrapper with no table in it is left alone" do
      html = ~s(<div class="kiln-table-wrap"><p>x</p></div>)
      assert ScrollableTables.focusable(html) == html

      # A table further in is wrapped on its own rather than naming the outer div.
      html = ~s(<div class="kiln-table-wrap"><p>x</p>#{@table}</div>)

      assert ScrollableTables.focusable(html) ==
               ~s(<div class="kiln-table-wrap"><p>x</p>#{@open}#{@table}</div></div>)
    end

    test "a bare top-level table is wrapped" do
      assert ScrollableTables.focusable("<p>a</p>#{@table}<p>b</p>") ==
               "<p>a</p>#{@open}#{@table}</div><p>b</p>"
    end

    test "a table nested in a cell scrolls with its parent and is not wrapped" do
      inner = "<table><tr><td>n</td></tr></table>"
      html = "<table><tr><td>a#{inner}</td></tr></table>"

      assert ScrollableTables.focusable(html) == "#{@open}#{html}</div>"
    end

    test "every table, wrapped or bare, not only the first" do
      html = ~s(<div class="kiln-table-wrap">#{@table}</div><p>x</p>#{@table})
      out = ScrollableTables.focusable(html)

      assert length(Regex.scan(~r/tabindex="0"/, out)) == 2
      assert out == "#{@open}#{@table}</div><p>x</p>#{@open}#{@table}</div>"
    end

    test "is idempotent" do
      once =
        ScrollableTables.focusable(
          ~s(<div class="kiln-table-wrap">#{@table}</div>#{@table}<table><tr><td><table></table></td></tr></table>)
        )

      assert ScrollableTables.focusable(once) == once
    end

    test "unbalanced table tags are not wrapped by guess" do
      assert ScrollableTables.focusable("<table><tr><td>x") == "<table><tr><td>x"
      assert ScrollableTables.focusable("x</table>") == "x</table>"
    end

    test "leaves escaped markup alone" do
      html = ~s(<p>Write &lt;table&gt; or &lt;div class="kiln-table-wrap"&gt;.</p>)
      assert ScrollableTables.focusable(html) == html
    end

    test "returns html without a table unchanged" do
      html = "<p>No table here.</p>"
      assert ScrollableTables.focusable(html) == html
      assert ScrollableTables.focusable("") == ""
    end

    test "escapes the label" do
      out = ScrollableTables.focusable(@table, ~s(a "b" <c> & d))

      assert out ==
               ~s(<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="a &quot;b&quot; &lt;c&gt; &amp; d">#{@table}</div>)
    end
  end

  test "a backslash in the label is written literally, not as a back-reference" do
    out = ScrollableTables.focusable(~s(<div class="kiln-table-wrap">#{@table}</div>), ~S(a\0b))
    assert out =~ ~S(aria-label="a\0b")
  end

  describe "the scrubber, then focusable/2" do
    # The renderer adds these after the scrubber; an author never sets them,
    # so a stored `tabindex="-1"` can't take a table out of reach.
    test "an author's focus and labelling attributes on the wrapper are replaced with ours" do
      html =
        ~s(<div class="kiln-table-wrap" tabindex="-1" role="presentation" aria-label="x">) <>
          @table <> "</div>"

      assert html |> HTMLSanitizer.sanitize_rich_text() |> ScrollableTables.focusable() ==
               "#{@open}#{@table}</div>"
    end

    test "a bare table with attributes comes out wrapped, its attributes stripped" do
      html = ~s(<TABLE border="1" class="x" tabindex="-1"><tr><td>a</td></tr></TABLE>)

      assert html |> HTMLSanitizer.sanitize_rich_text() |> ScrollableTables.focusable() ==
               "#{@open}<table><tr><td>a</td></tr></table></div>"
    end

    test "an attribute value holding <table> stays escaped and unmatched" do
      html = ~s(<p><a href="/x?<table>">l</a></p>)
      sanitized = HTMLSanitizer.sanitize_rich_text(html)

      assert ScrollableTables.focusable(sanitized) == sanitized
    end
  end

  defp table_block do
    cell = fn text, header ->
      %{"header" => header, "children" => [%{"_type" => "span", "text" => text, "marks" => []}]}
    end

    %{
      "_type" => "table",
      "rows" => [
        %{"cells" => [cell.("Name", true), cell.("Amount", true)]},
        %{"cells" => [cell.("Flour", false), cell.("250g", false)]}
      ]
    }
  end

  defp web(block), do: block |> RichText.render(:web) |> IO.iodata_to_binary()

  describe "RichText.render(:web)" do
    test "a Portable Text table" do
      assert web(%RichText{body: [table_block()]}) =~ "#{@open}<table><thead>"
    end

    test "a wrapped legacy_html table, after the scrubber" do
      legacy = ~s(<div class="kiln-table-wrap" tabindex="-1">#{@table}</div>)
      assert web(%RichText{body: [], legacy_html: legacy}) == "#{@open}#{@table}</div>"
    end

    test "a bare legacy_html table" do
      legacy = "<p>Before</p><table><tr><th>h</th></tr></table>"

      assert web(%RichText{body: [], legacy_html: legacy}) ==
               "<p>Before</p>#{@open}<table><tr><th>h</th></tr></table></div>"
    end

    test "translates the label in the caller's locale" do
      html =
        KilnCMS.CodeBlocks.with_content_locale("fr", fn ->
          web(%RichText{body: [table_block()]})
        end)

      assert html =~ ~s(aria-label="Tableau défilant")
    end

    test "the :json artifact and PortableText.to_html/1 stay plain" do
      body = [table_block()]

      refute PortableText.to_html(body) =~ "tabindex"
      refute inspect(RichText.render(%RichText{body: body}, :json)) =~ "tabindex"

      assert %{"legacy_html" => @table} =
               RichText.render(%RichText{body: [], legacy_html: @table}, :json)
    end
  end
end
