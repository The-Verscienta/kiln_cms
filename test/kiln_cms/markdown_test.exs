defmodule KilnCMS.MarkdownTest do
  @moduledoc """
  Markdown → structured content. One converter for editor paste, `.md` import
  and the `body_markdown` API argument, so these are the shapes all three rely
  on — plus the ways Markdown can smuggle HTML or a URL past the sanitizer.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Markdown

  defp body(markdown) do
    markdown
    |> Markdown.to_blocks()
    |> Enum.find(&(&1["type"] == "rich_text"))
    |> get_in(["value", "body"])
  end

  defp text(markdown), do: markdown |> body() |> PortableText.to_plain_text()

  defp styles(markdown), do: markdown |> body() |> Enum.map(&(&1["style"] || &1["_type"]))

  describe "structure" do
    test "ATX and setext headings keep their level" do
      assert styles("# One\n\n### Three\n\nTwo\n---\n\nbody") == ["h1", "h3", "h2", "normal"]
    end

    test "inline marks become Portable Text marks" do
      assert [%{"children" => children}] = body("**b** *i* `c` ~~s~~")

      assert Enum.map(children, &{&1["text"], &1["marks"]}) == [
               {"b", ["strong"]},
               {" ", []},
               {"i", ["em"]},
               {" ", []},
               {"c", ["code"]},
               {" ", []},
               {"s", ["strike"]}
             ]
    end

    test "nested bullet and numbered lists keep their kind and depth" do
      shape =
        "- a\n  - b\n- c\n\n1. one\n2. two"
        |> body()
        |> Enum.map(&{PortableText.to_plain_text([&1]), &1["listItem"], &1["level"]})

      assert shape == [
               {"a", "bullet", 1},
               {"b", "bullet", 2},
               {"c", "bullet", 1},
               {"one", "number", 1},
               {"two", "number", 1}
             ]
    end

    test "a GFM table becomes a table with its header row" do
      assert [%{"_type" => "table", "rows" => [header, row]}] =
               body("| A | B |\n|:--|--:|\n| 1 | *2* |")

      assert Enum.map(header["cells"], &{&1["header"], PortableText.to_plain_text([&1])}) == [
               {true, "A"},
               {true, "B"}
             ]

      assert Enum.map(row["cells"], & &1["header"]) == [false, false]
    end

    test "a fenced code block keeps its language and its text verbatim" do
      source = ~s|IO.puts("<b>&amp;</b>")\nlist[idx] = [x=1]|

      assert [%{"style" => "code", "language" => "elixir"} = code] =
               body("```elixir\n#{source}\n```")

      assert PortableText.to_plain_text([code]) == source
    end

    test "a blockquote and a thematic break survive" do
      assert styles("> quoted\n\n***\n\nafter") == ["blockquote", "hr", "normal"]
    end

    test "bracketed prose is not mistaken for a WordPress shortcode" do
      assert text("Set [x=1] and [embed] here.") == "Set [x=1] and [embed] here."
    end

    test "character references decode to the characters they name" do
      assert text("AT&T &copy; &#169; &#x2014; &bogus; &amp;lt;") == "AT&T © © — &bogus; &lt;"
    end

    test "an escaped tag in prose stays literal text" do
      assert text("Write &lt;b&gt; for bold.") == "Write <b> for bold."
    end
  end

  describe "media" do
    test "a standalone image becomes an image block with alt and caption" do
      assert Markdown.to_blocks(~s|![A "view"](https://img.example.com/a.png "At dusk")|) == [
               %{
                 "type" => "image",
                 "value" => %{
                   "url" => "https://img.example.com/a.png",
                   "alt" => ~s(A "view"),
                   "caption" => "At dusk"
                 }
               }
             ]
    end

    test "a bare YouTube link on its own line becomes an embed" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      assert Markdown.to_blocks(url) == [%{"type" => "embed", "value" => %{"url" => url}}]
    end

    test "prose, image, prose splits into three blocks in order" do
      types =
        "Before.\n\n![x](https://img.example.com/x.png)\n\nAfter."
        |> Markdown.to_blocks()
        |> Enum.map(& &1["type"])

      assert types == ["rich_text", "image", "rich_text"]
    end

    test ":media_resolver points the image at a library item" do
      resolver = fn "https://img.example.com/x.png" -> %{media_id: "m-1", url: "/media/x.png"} end

      assert [%{"value" => %{"media_id" => "m-1", "url" => "/media/x.png"}}] =
               Markdown.to_blocks("![x](https://img.example.com/x.png)", media_resolver: resolver)
    end
  end

  describe "untrusted input" do
    test "a raw <script> block is dropped — tag and text" do
      html = Markdown.to_html("before\n\n<script>alert(1)</script>\n\nafter")

      assert html == "<p>before</p><p>after</p>"
    end

    test "event-handler attributes on raw HTML are stripped" do
      html =
        Markdown.to_html(
          ~s|<div onclick="x()">block</div>\n\nInline <span onmouseover="y()">s</span>.|
        )

      refute html =~ "onclick"
      refute html =~ "onmouseover"
      assert text(~s|<div onclick="x()">block</div>|) == "block"
    end

    test "inline raw HTML goes through the rich-text allowlist" do
      assert Markdown.to_html("a <b>b</b> <img src=x onerror=alert(1)> c") ==
               "<p>a <b>b</b>  c</p>"
    end

    test "a javascript: link loses its href but keeps its words" do
      assert Markdown.to_html("[click](javascript:alert(1)) me") == "<p>click me</p>"
    end

    test "a link href cannot break out of its attribute" do
      assert Markdown.to_html(~s|[q](https://a.example/?a="><script>x</script>)|) =~
               ~s(href="https://a.example/?a=&quot;&gt;&lt;script&gt;x&lt;/script&gt;")
    end

    test "an image with an unsafe src keeps only its alt text" do
      assert Markdown.to_blocks("![the alt](javascript:alert(1))") ==
               [
                 %{
                   "type" => "rich_text",
                   "value" => %{
                     "body" => [
                       %{
                         "_key" => "b0",
                         "_type" => "block",
                         "children" => [%{"_type" => "span", "marks" => [], "text" => "the alt"}],
                         "markDefs" => [],
                         "style" => "normal"
                       }
                     ]
                   }
                 }
               ]
    end
  end

  describe "to_tiptap/1" do
    test "prose only: an image arrives as a link to the picture" do
      assert Markdown.to_tiptap("See ![the map](https://img.example.com/m.png).") == %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "paragraph",
                   "content" => [
                     %{"type" => "text", "text" => "See "},
                     %{
                       "type" => "text",
                       "text" => "the map",
                       "marks" => [
                         %{
                           "type" => "link",
                           "attrs" => %{"href" => "https://img.example.com/m.png"}
                         }
                       ]
                     },
                     %{"type" => "text", "text" => "."}
                   ]
                 }
               ]
             }
    end

    test "nil is an empty document" do
      assert Markdown.to_tiptap(nil) == %{"type" => "doc", "content" => []}
    end
  end

  describe "parse_document/2" do
    test "front matter supplies title, slug and excerpt; a repeated H1 is dropped" do
      doc =
        Markdown.parse_document("""
        ---
        title: "Getting started"
        slug: getting-started
        description: >
          Install it,
          then run it.
        ---
        # Getting started

        First paragraph.
        """)

      assert doc.title == "Getting started"
      assert doc.slug == "getting-started"
      assert doc.excerpt == "Install it, then run it."
      assert doc.front_matter["description"] == "Install it, then run it."
      assert [%{"type" => "rich_text", "value" => %{"body" => body}}] = doc.blocks
      assert PortableText.to_plain_text(body) == "First paragraph."
    end

    test "without front matter a leading H1 is the title and leaves the body" do
      doc = Markdown.parse_document("# The *Title*\n\nBody.")

      assert doc.title == "The Title"
      assert {doc.slug, doc.excerpt, doc.front_matter} == {nil, nil, %{}}
      assert [%{"value" => %{"body" => body}}] = doc.blocks
      assert PortableText.to_plain_text(body) == "Body."
    end

    test "a comment above the leading H1 does not cost it the title" do
      doc = Markdown.parse_document("<!-- license header -->\n\n# The Title\n\nBody.")

      assert doc.title == "The Title"
      assert [%{"value" => %{"body" => body}}] = doc.blocks
      assert Enum.map(body, & &1["style"]) == ["normal"]
      assert PortableText.to_plain_text(body) == "Body."
    end

    test "several comments, one of them multi-line, still leave a leading H1" do
      doc =
        Markdown.parse_document("""
        <!-- Copyright the authors.
             Licensed under the same terms as the rest of the manual. -->
        <!-- Editors: keep the title in sync with the nav entry. -->

        # The Title

        Body.
        """)

      assert doc.title == "The Title"
      assert [%{"value" => %{"body" => body}}] = doc.blocks
      assert Enum.map(body, & &1["style"]) == ["normal"]
      assert PortableText.to_plain_text(body) == "Body."
    end

    test "a comment above an H1 that repeats the front-matter title drops both" do
      doc =
        Markdown.parse_document("""
        ---
        title: Declared
        ---
        <!-- note -->

        # Declared

        Body.
        """)

      assert doc.title == "Declared"
      assert [%{"value" => %{"body" => body}}] = doc.blocks
      assert Enum.map(body, & &1["style"]) == ["normal"]
      assert PortableText.to_plain_text(body) == "Body."
    end

    test "an H1 that differs from the front-matter title stays in the body" do
      doc = Markdown.parse_document("---\ntitle: Declared\n---\n# Heading\n\nBody.")

      assert doc.title == "Declared"

      assert [%{"value" => %{"body" => [%{"style" => "h1"}, %{"style" => "normal"}]}}] =
               doc.blocks
    end

    test "an H1 further down is a section, not the title" do
      doc = Markdown.parse_document("Intro.\n\n# Later")

      assert doc.title == nil

      assert [%{"value" => %{"body" => [%{"style" => "normal"}, %{"style" => "h1"}]}}] =
               doc.blocks
    end
  end

  describe "split_front_matter/1" do
    test "front matter is never rendered as prose" do
      assert Markdown.to_html("---\ntitle: T\n---\nBody") == "<p>Body</p>"
    end

    test "a rule followed by a setext heading is not front matter" do
      source = "---\nSome text\n---\nbody"
      assert Markdown.split_front_matter(source) == {%{}, source}
    end

    test "empty front matter is removed" do
      assert Markdown.split_front_matter("---\n---\nBody") == {%{}, "Body"}
    end
  end

  test "nil converts to nothing" do
    assert {Markdown.to_html(nil), Markdown.to_blocks(nil)} == {"", []}
    assert Markdown.parse_document(nil).blocks == []
  end
end
