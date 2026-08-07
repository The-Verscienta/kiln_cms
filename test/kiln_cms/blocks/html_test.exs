defmodule KilnCMS.Blocks.HtmlTest do
  @moduledoc """
  Legacy HTML → structured content (#487).

  These are the shapes an importer actually meets, not synthetic ones: classic
  WordPress bodies with no `<p>` tags, Gutenberg comment delimiters, `[caption]`
  shortcodes, and `<pre>` blocks whose newlines are content.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.Html
  alias KilnCMS.Blocks.PortableText

  defp text(html), do: html |> Html.to_portable_text() |> PortableText.to_plain_text()

  defp blocks(html), do: Html.to_blocks(html)

  defp types(html), do: blocks(html) |> Enum.map(& &1["type"])

  defp first_body(html) do
    blocks(html) |> Enum.find(&(&1["type"] == "rich_text")) |> get_in(["value", "body"])
  end

  describe "wpautop" do
    test "blank-line-separated text becomes paragraphs" do
      body = first_body("First paragraph.\n\nSecond paragraph.")

      assert [%{"style" => "normal"} = one, %{"style" => "normal"} = two] = body
      assert PortableText.to_plain_text([one]) == "First paragraph."
      assert PortableText.to_plain_text([two]) == "Second paragraph."
    end

    test "a single newline inside a run is a line break, not a paragraph break" do
      assert [_single_block] = first_body("Line one.\nLine two.")
      assert text("Line one.\nLine two.") == "Line one.\nLine two."
    end

    test "content that already has block tags is left alone" do
      body = first_body("<p>Already wrapped.</p>\n\n<p>And again.</p>")
      assert length(body) == 2
    end

    test "newlines inside <pre> survive" do
      assert text("<pre><code>a\n\nb\nc</code></pre>") =~ "a\n\nb\nc"
    end

    test "two identical code blocks stay two blocks" do
      body = first_body("<pre><code>same</code></pre>\n\n<pre><code>same</code></pre>")
      assert Enum.count(body, &(&1["style"] == "code")) == 2
    end

    test "autop: false leaves blank lines alone" do
      # One <p>-less run, so with autop off the whole thing is one block.
      assert [_one] = Html.to_portable_text("a\n\nb", autop: false)
    end
  end

  describe "inline marks" do
    test "bold, italic, code, strike and underline map to PT marks" do
      [block] =
        Html.to_portable_text("<p><strong>b</strong><em>i</em><code>c</code><s>s</s><u>u</u></p>")

      marks = Enum.map(block["children"], & &1["marks"])
      assert marks == [["strong"], ["em"], ["code"], ["strike"], ["underline"]]
    end

    test "b/i/del/ins are treated as their semantic equivalents" do
      [block] = Html.to_portable_text("<p><b>b</b><i>i</i><del>d</del><ins>n</ins></p>")

      assert Enum.map(block["children"], & &1["marks"]) ==
               [["strong"], ["em"], ["strike"], ["underline"]]
    end

    test "nested marks accumulate on one span" do
      [block] = Html.to_portable_text("<p><strong><em>both</em></strong></p>")
      assert [%{"text" => "both", "marks" => marks}] = block["children"]
      assert Enum.sort(marks) == ["em", "strong"]
    end

    test "a link becomes a markDef, not an inline href" do
      [block] = Html.to_portable_text(~s(<p>see <a href="https://example.com">this</a></p>))

      assert [%{"_type" => "link", "href" => "https://example.com", "_key" => key}] =
               block["markDefs"]

      assert Enum.any?(block["children"], &(&1["marks"] == [key]))
    end

    test "adjacent identical runs merge into one span" do
      [block] = Html.to_portable_text("<p><b>a</b><b>b</b></p>")
      assert [%{"text" => "ab"}] = block["children"]
    end

    test "collapsible whitespace is collapsed" do
      assert text("<p>a     b\n   c</p>") == "a b c"
    end

    test "script and style contribute nothing" do
      assert text("<p>keep<script>alert(1)</script><style>a{}</style></p>") == "keep"
    end
  end

  describe "block structure" do
    test "headings carry their level" do
      body = first_body("<h1>One</h1><h3>Three</h3><h7>Bogus</h7>")
      assert Enum.map(Enum.take(body, 2), & &1["style"]) == ["h1", "h3"]
    end

    test "nested lists reach PT levels" do
      body = first_body("<ul><li>a<ul><li>b</li></ul></li></ul>")
      assert [%{"level" => 1, "listItem" => "bullet"}, %{"level" => 2}] = body
    end

    test "an ordered list is a number list" do
      assert [%{"listItem" => "number"}] = first_body("<ol><li>a</li></ol>")
    end

    test "a list item with loose inline children still gets its text" do
      assert text("<ul><li>loose text</li></ul>") =~ "loose text"
    end

    # `Highlight.normalize/1` validates the tag's FORMAT, not that a lexer is
    # registered — a tag with no lexer falls back to plain `<pre>` at render.
    # The importer stores exactly what the editor would, rather than
    # second-guessing which languages this deployment has lexers for.
    test "a code block keeps any well-formed language tag" do
      [block] = Html.to_portable_text(~s(<pre><code class="language-elixir">x</code></pre>))
      assert block["language"] == "elixir"
    end

    test "a malformed language tag is dropped rather than stored" do
      [plain] =
        Html.to_portable_text(
          ~s(<pre><code class="language-#{String.duplicate("x", 40)}">c</code></pre>)
        )

      refute Map.has_key?(plain, "language")
    end

    test "WordPress' brush: syntax is read as a language too" do
      [block] = Html.to_portable_text(~s(<pre><code class="brush: elixir">x</code></pre>))
      assert block["language"] == "elixir"
    end

    test "an hr becomes a standalone PT item" do
      assert Enum.any?(first_body("<p>a</p><hr/><p>b</p>"), &(&1["_type"] == "hr"))
    end

    test "a table keeps headers and colspan" do
      [table] =
        Html.to_portable_text(
          ~s(<table><tr><th>A</th></tr><tr><td colspan="2">B</td></tr></table>)
        )

      assert table["_type"] == "table"

      assert [%{"cells" => [%{"header" => true}]}, %{"cells" => [%{"colspan" => 2}]}] =
               table["rows"]
    end

    test "an unknown tag still contributes its text" do
      assert text("<marquee>still text</marquee>") =~ "still text"
    end

    test "unparseable input does not raise" do
      assert is_list(Html.to_portable_text("<p>unclosed <b>bold"))
    end
  end

  describe "to_blocks/2 splitting" do
    test "prose runs group into one rich_text block, not one per paragraph" do
      assert types("<p>a</p><p>b</p><p>c</p>") == ["rich_text"]
    end

    test "a standalone image becomes an image block between prose runs" do
      html = ~s(<p>before</p><p><img src="https://x/y.jpg" alt="Y"></p><p>after</p>)
      assert types(html) == ["rich_text", "image", "rich_text"]
    end

    test "a figure's figcaption becomes the image's caption, not stray prose" do
      html = ~s(<figure><img src="https://x/y.jpg" alt="Y"><figcaption>Cap</figcaption></figure>)
      assert [%{"type" => "image", "value" => value}] = blocks(html)
      assert value["caption"] == "Cap"
      assert value["alt"] == "Y"
    end

    test "a [caption] shortcode is read as a caption" do
      html = ~s([caption id="a" width="300"]<img src="https://x/y.jpg" /> The words[/caption])
      assert [%{"type" => "image", "value" => %{"caption" => "The words"}}] = blocks(html)
    end

    test "a linked image is still an image block" do
      html = ~s(<p><a href="https://x/full.jpg"><img src="https://x/thumb.jpg"></a></p>)
      assert [%{"type" => "image", "value" => %{"url" => "https://x/thumb.jpg"}}] = blocks(html)
    end

    test "a bare YouTube URL on its own line becomes an embed" do
      assert [%{"type" => "embed", "value" => %{"url" => url}}] =
               blocks("https://www.youtube.com/watch?v=abc")

      assert url == "https://www.youtube.com/watch?v=abc"
    end

    test "an [embed] shortcode becomes an embed" do
      assert [%{"type" => "embed"}] = blocks("[embed]https://vimeo.com/123[/embed]")
    end

    test "a link with real anchor text stays prose, not an embed" do
      html = ~s(<p><a href="https://www.youtube.com/watch?v=abc">watch our talk</a></p>)
      assert types(html) == ["rich_text"]
    end

    test "a non-embeddable bare URL stays prose" do
      assert types("https://example.com/article") == ["rich_text"]
    end

    test "an iframe becomes an embed" do
      assert [%{"type" => "embed", "value" => %{"url" => "https://player/1"}}] =
               blocks(~s(<iframe src="https://player/1"></iframe>))
    end

    test "whitespace between two images does not emit an empty rich_text block" do
      html = ~s(<p><img src="https://x/1.jpg"></p>\n\n<p><img src="https://x/2.jpg"></p>)
      assert types(html) == ["image", "image"]
    end

    test "a media_resolver re-points the image at an imported item" do
      resolver = fn "https://old/pic.jpg" ->
        %{media_id: "abc-123", url: "https://new/pic.jpg"}
      end

      assert [%{"type" => "image", "value" => value}] =
               Html.to_blocks(~s(<img src="https://old/pic.jpg">), media_resolver: resolver)

      assert value["url"] == "https://new/pic.jpg"
      assert value["media_id"] == "abc-123"
    end

    test "an unresolved image keeps its source URL rather than breaking" do
      assert [%{"type" => "image", "value" => %{"url" => "https://old/pic.jpg"}}] =
               Html.to_blocks(~s(<img src="https://old/pic.jpg">),
                 media_resolver: fn _ -> nil end
               )
    end
  end

  describe "Gutenberg and shortcodes" do
    test "wp: comment delimiters are stripped, their HTML kept" do
      html = "<!-- wp:paragraph --><p>Hello</p><!-- /wp:paragraph -->"
      assert text(html) == "Hello"
    end

    test "a shortcode with content keeps the content" do
      assert text("[su_note]important[/su_note]") =~ "important"
    end

    test "a self-closing shortcode leaves no literal bracket text" do
      body_text = text(~s(<p>before [gallery ids="1,2,3"] after</p>))
      refute body_text =~ "gallery"
      refute body_text =~ "["
    end
  end

  describe "regressions" do
    # `collect_descendants/1` is fully recursive, so the inner table's rows were
    # hoisted into the OUTER table and rendered again inside the cell.
    test "a table nested in a cell does not duplicate its rows" do
      html = "<table><tr><td><table><tr><td>inner</td></tr></table></td></tr></table>"
      [outer] = Html.to_portable_text(html)

      assert length(outer["rows"]) == 1
      assert html |> text() |> String.split("inner") |> length() == 2
    end

    test "tbody/thead wrappers still contribute their rows" do
      [table] =
        Html.to_portable_text(
          "<table><thead><tr><th>H</th></tr></thead><tbody><tr><td>B</td></tr></tbody></table>"
        )

      assert length(table["rows"]) == 2
    end

    # Gutenberg emits a gallery as a figure of figures; `Enum.find` kept the
    # first image and dropped the rest with no entry in any failure report.
    test "a Gutenberg gallery keeps every image" do
      html = """
      <figure class="wp-block-gallery">
        <figure class="wp-block-image"><img src="https://x/a.jpg"><figcaption>A</figcaption></figure>
        <figure class="wp-block-image"><img src="https://x/b.jpg"><figcaption>B</figcaption></figure>
      </figure>
      """

      images = blocks(html) |> Enum.filter(&(&1["type"] == "image"))

      assert Enum.map(images, & &1["value"]["url"]) == ["https://x/a.jpg", "https://x/b.jpg"]
      assert Enum.map(images, & &1["value"]["caption"]) == ["A", "B"]
    end

    # Restoring token 0 reintroduced token 1's literal text, and token 1's
    # global replace then hit it too — replacing a code block with a duplicate
    # of another one.
    test "a <pre> containing a placeholder token is not corrupted" do
      html = "<pre>A &lt;!--kiln-pre-1--&gt; B</pre>\n\n<pre>SECOND</pre>"
      out = text(html)

      assert out =~ "SECOND"
      assert out |> String.split("SECOND") |> length() == 2
    end

    # An unmatched `[opener]` made the backreferenced regex rescan to
    # end-of-input for every occurrence — quadratic, and hours on a real body.
    test "many unmatched shortcode openers stay fast" do
      html = String.duplicate(~s([gallery ids="1,2,3"] some text ), 4_000)

      {micros, result} = :timer.tc(fn -> Html.to_portable_text(html) end)

      assert is_list(result)
      assert micros < 5_000_000, "took #{div(micros, 1000)}ms"
    end

    test "a bounded paired shortcode still unwraps its content" do
      assert text("[su_note]kept[/su_note]") =~ "kept"
    end
  end

  describe "empty and nil input" do
    test "nil and empty produce nothing" do
      assert Html.to_portable_text(nil) == []
      assert Html.to_blocks(nil) == []
      assert Html.to_blocks("") == []
      assert Html.to_blocks("   \n\n  ") == []
    end
  end
end
