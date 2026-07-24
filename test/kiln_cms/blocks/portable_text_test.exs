defmodule KilnCMS.Blocks.PortableTextTest do
  @moduledoc "TipTap ↔ Portable Text ↔ HTML interchange (decision D12)."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText

  defp tiptap(content), do: %{"type" => "doc", "content" => content}

  describe "from_tiptap/1 → to_html/1" do
    test "headings, paragraphs and inline marks" do
      doc =
        tiptap([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 2},
            "content" => [%{"type" => "text", "text" => "Title"}]
          },
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Hello "},
              %{"type" => "text", "text" => "world", "marks" => [%{"type" => "bold"}]}
            ]
          }
        ])

      html = doc |> PortableText.from_tiptap() |> PortableText.to_html()

      assert html =~ "<h2>Title</h2>"
      assert html =~ "<p>Hello <strong>world</strong></p>"
    end

    test "blockquote flattens its wrapped paragraph" do
      doc =
        tiptap([
          %{
            "type" => "blockquote",
            "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "quoted"}]}
            ]
          }
        ])

      html = doc |> PortableText.from_tiptap() |> PortableText.to_html()
      assert html =~ "<blockquote>quoted</blockquote>"
    end

    test "link marks become markDefs and render as anchors" do
      doc =
        tiptap([
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" => "click",
                "marks" => [%{"type" => "link", "attrs" => %{"href" => "https://x.test"}}]
              }
            ]
          }
        ])

      pt = PortableText.from_tiptap(doc)
      assert [%{"markDefs" => [%{"_type" => "link", "href" => "https://x.test"}]}] = pt
      assert PortableText.to_html(pt) =~ ~s(<a href="https://x.test">click</a>)
    end

    test "rejects javascript: and data: link hrefs, keeping the text" do
      for scheme <- [
            "javascript:alert(document.domain)",
            "data:text/html,<script>1</script>",
            "vbscript:msgbox(1)",
            "  JavaScript:alert(1)"
          ] do
        doc =
          tiptap([
            %{
              "type" => "paragraph",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "click",
                  "marks" => [%{"type" => "link", "attrs" => %{"href" => scheme}}]
                }
              ]
            }
          ])

        html = doc |> PortableText.from_tiptap() |> PortableText.to_html()
        refute html =~ "<a"
        refute html =~ "javascript:"
        refute html =~ "data:"
        assert html =~ "click"
      end
    end

    test "allows mailto: and relative link hrefs" do
      for href <- ["mailto:hi@x.test", "/editor/foo"] do
        doc =
          tiptap([
            %{
              "type" => "paragraph",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "click",
                  "marks" => [%{"type" => "link", "attrs" => %{"href" => href}}]
                }
              ]
            }
          ])

        html = doc |> PortableText.from_tiptap() |> PortableText.to_html()
        assert html =~ ~s(<a href="#{href}">click</a>)
      end
    end

    test "text is HTML-escaped" do
      doc =
        tiptap([
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "a < b & c"}]}
        ])

      assert doc |> PortableText.from_tiptap() |> PortableText.to_html() =~ "a &lt; b &amp; c"
    end
  end

  describe "lists, code blocks and rules" do
    test "bullet and ordered lists round-trip, including nesting" do
      tiptap = %{
        "type" => "doc",
        "content" => [
          %{"type" => "bulletList", "content" => [
            %{"type" => "listItem", "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "one"}]},
              %{"type" => "bulletList", "content" => [
                %{"type" => "listItem", "content" => [
                  %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "one-a"}]}
                ]}
              ]}
            ]},
            %{"type" => "listItem", "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "two"}]}
            ]}
          ]},
          %{"type" => "orderedList", "content" => [
            %{"type" => "listItem", "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "first"}]}
            ]}
          ]}
        ]
      }

      pt = PortableText.from_tiptap(tiptap)

      assert [%{"listItem" => "bullet", "level" => 1},
              %{"listItem" => "bullet", "level" => 2},
              %{"listItem" => "bullet", "level" => 1},
              %{"listItem" => "number", "level" => 1}] =
               Enum.map(pt, &Map.take(&1, ["listItem", "level"]))

      assert PortableText.to_html(pt) ==
               "<ul><li>one<ul><li>one-a</li></ul></li><li>two</li></ul><ol><li>first</li></ol>"
    end

    test "a nested list of a different kind stays inside its parent item" do
      pt = [
        %{"_type" => "block", "_key" => "a", "style" => "normal", "listItem" => "bullet",
          "level" => 1, "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "b1", "marks" => []}]},
        %{"_type" => "block", "_key" => "b", "style" => "normal", "listItem" => "number",
          "level" => 2, "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "n1", "marks" => []}]},
        %{"_type" => "block", "_key" => "c", "style" => "normal", "listItem" => "bullet",
          "level" => 1, "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "b2", "marks" => []}]}
      ]

      assert PortableText.to_html(pt) == "<ul><li>b1<ol><li>n1</li></ol></li><li>b2</li></ul>"
    end

    test "code blocks, horizontal rules and hard breaks convert" do
      tiptap = %{
        "type" => "doc",
        "content" => [
          %{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => "IO.puts(1)"}]},
          %{"type" => "horizontalRule"},
          %{"type" => "paragraph", "content" => [
            %{"type" => "text", "text" => "a"},
            %{"type" => "hardBreak"},
            %{"type" => "text", "text" => "b"}
          ]}
        ]
      }

      pt = PortableText.from_tiptap(tiptap)
      html = PortableText.to_html(pt)

      assert html =~ "<pre><code>IO.puts(1)</code></pre>"
      assert html =~ "<hr/>"
      assert html =~ "<p>a\nb</p>"
    end
  end

  describe "to_plain_text/1" do
    test "flattens prose for search/embeddings" do
      doc =
        tiptap([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 1},
            "content" => [%{"type" => "text", "text" => "Title"}]
          },
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Body text"}]}
        ])

      text = doc |> PortableText.from_tiptap() |> PortableText.to_plain_text()
      assert text =~ "Title"
      assert text =~ "Body text"
      refute text =~ "<"
    end
  end

  describe "edge cases" do
    test "from_tiptap is idempotent on PT input and tolerant of junk" do
      pt = [%{"_type" => "block", "style" => "normal", "children" => []}]
      assert PortableText.from_tiptap(pt) == pt
      assert PortableText.from_tiptap(nil) == []
      assert PortableText.to_html(nil) == ""
      assert PortableText.to_plain_text(nil) == ""
    end

    test "accepts a JSON string" do
      json =
        Jason.encode!(
          tiptap([%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}])
        )

      assert json |> PortableText.from_tiptap() |> PortableText.to_html() == "<p>hi</p>"
    end
  end
end
