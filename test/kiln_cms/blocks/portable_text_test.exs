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
      import KilnCMS.TipTapFixtures

      tiptap =
        doc([
          bullet_list([
            list_item([para("one"), bullet_list([list_item(para("one-a"))])]),
            list_item(para("two"))
          ]),
          ordered_list([list_item(para("first"))])
        ])

      pt = PortableText.from_tiptap(tiptap)

      assert [
               %{"listItem" => "bullet", "level" => 1},
               %{"listItem" => "bullet", "level" => 2},
               %{"listItem" => "bullet", "level" => 1},
               %{"listItem" => "number", "level" => 1}
             ] =
               Enum.map(pt, &Map.take(&1, ["listItem", "level"]))

      assert PortableText.to_html(pt) ==
               "<ul><li>one<ul><li>one-a</li></ul></li><li>two</li></ul><ol><li>first</li></ol>"
    end

    test "a nested list of a different kind stays inside its parent item" do
      pt = [
        %{
          "_type" => "block",
          "_key" => "a",
          "style" => "normal",
          "listItem" => "bullet",
          "level" => 1,
          "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "b1", "marks" => []}]
        },
        %{
          "_type" => "block",
          "_key" => "b",
          "style" => "normal",
          "listItem" => "number",
          "level" => 2,
          "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "n1", "marks" => []}]
        },
        %{
          "_type" => "block",
          "_key" => "c",
          "style" => "normal",
          "listItem" => "bullet",
          "level" => 1,
          "markDefs" => [],
          "children" => [%{"_type" => "span", "text" => "b2", "marks" => []}]
        }
      ]

      assert PortableText.to_html(pt) == "<ul><li>b1<ol><li>n1</li></ol></li><li>b2</li></ul>"
    end

    test "code blocks, horizontal rules and hard breaks convert" do
      import KilnCMS.TipTapFixtures

      tiptap =
        doc([
          tt_node("codeBlock", [text("IO.puts(1)")]),
          tt_node("horizontalRule"),
          para([text("a"), tt_node("hardBreak"), text("b")])
        ])

      pt = PortableText.from_tiptap(tiptap)
      html = PortableText.to_html(pt)

      assert html =~ "<pre><code>IO.puts(1)</code></pre>"
      assert html =~ "<hr/>"
      assert html =~ "<p>a\nb</p>"
    end

    test "code block language rides the PT block and highlights at render (#503)" do
      import KilnCMS.TipTapFixtures

      tiptap =
        doc([
          Map.put(tt_node("codeBlock", [text("IO.puts(1)")]), "attrs", %{"language" => "Elixir"})
        ])

      assert [block] = PortableText.from_tiptap(tiptap)
      # Normalized at capture, so the :json surface carries the canonical tag.
      assert block["language"] == "elixir"

      html = PortableText.to_html([block])
      assert html =~ ~s(<pre class="highlight"><code class="language-elixir">)
      assert html =~ ~s(<span class="nc">IO</span>)
    end

    test "unknown language keeps the escaped plain <pre> but carries the tag (#503)" do
      import KilnCMS.TipTapFixtures

      tiptap =
        doc([
          Map.put(tt_node("codeBlock", [text("print('<hi>')")]), "attrs", %{
            "language" => "python"
          })
        ])

      assert [block] = PortableText.from_tiptap(tiptap)
      assert block["language"] == "python"

      html = PortableText.to_html([block])

      assert html ==
               "<pre><code class=\"language-python\">print(&#39;&lt;hi&gt;&#39;)</code></pre>"
    end

    test "implausible language attrs are dropped, not stored (#503)" do
      import KilnCMS.TipTapFixtures

      tiptap =
        doc([
          Map.put(tt_node("codeBlock", [text("x")]), "attrs", %{
            "language" => ~s(js" onmouseover=")
          })
        ])

      assert [block] = PortableText.from_tiptap(tiptap)
      refute Map.has_key?(block, "language")
      assert PortableText.to_html([block]) == "<pre><code>x</code></pre>"
    end

    test "sanitize_body normalizes API-written language tags (from_tiptap isn't the only writer)" do
      hostile = %{
        "_type" => "block",
        "style" => "code",
        "language" => ~s(js" onload="),
        "children" => [],
        "markDefs" => []
      }

      cased = %{
        "_type" => "block",
        "style" => "code",
        "language" => " Elixir ",
        "children" => [],
        "markDefs" => []
      }

      assert [clean, normalized] = PortableText.sanitize_body([hostile, cased])
      refute Map.has_key?(clean, "language")
      assert normalized["language"] == "elixir"
    end

    test "marked spans in code blocks keep their marks and links in the fallback render" do
      block = %{
        "_type" => "block",
        "style" => "code",
        "children" => [
          %{"_type" => "span", "text" => "see docs", "marks" => ["strong", "lk0"]}
        ],
        "markDefs" => [%{"_key" => "lk0", "_type" => "link", "href" => "https://x.test"}]
      }

      html = PortableText.to_html([block])

      assert html =~
               ~s(<pre><code><a href="https://x.test"><strong>see docs</strong></a></code></pre>)

      # A language tag can't be highlighted over marked spans — the marked
      # fallback still carries the class for client-side highlighters.
      tagged = Map.put(block, "language", "elixir")
      assert PortableText.to_html([tagged]) =~ ~s(<code class="language-elixir"><a href=)
    end
  end

  describe "tables (#475)" do
    import KilnCMS.TipTapFixtures

    defp tt_cell(type, content, attrs \\ nil) do
      cell = tt_node(type, [para(content)])
      if attrs, do: Map.put(cell, "attrs", attrs), else: cell
    end

    test "a table with a header row round-trips and renders accessible markup" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [tt_cell("tableHeader", "Name"), tt_cell("tableHeader", "Dose")]),
            tt_node("tableRow", [tt_cell("tableCell", "Ginger"), tt_cell("tableCell", "3g")])
          ])
        ])

      assert [item] = PortableText.from_tiptap(tiptap)
      assert item["_type"] == "table"

      assert [
               %{"cells" => [%{"header" => true}, %{"header" => true}]},
               %{"cells" => [%{"header" => false}, %{"header" => false}]}
             ] = item["rows"]

      assert PortableText.to_html([item]) ==
               ~s(<div class="kiln-table-wrap"><table><thead><tr>) <>
                 ~s(<th scope="col">Name</th><th scope="col">Dose</th>) <>
                 "</tr></thead><tbody><tr><td>Ginger</td><td>3g</td></tr></tbody></table></div>"
    end

    test "row-header cells outside the first row get scope=row; no thead without one" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [tt_cell("tableHeader", "Yin"), tt_cell("tableCell", "cool")]),
            tt_node("tableRow", [tt_cell("tableHeader", "Yang"), tt_cell("tableCell", "warm")])
          ])
        ])

      html = tiptap |> PortableText.from_tiptap() |> PortableText.to_html()

      refute html =~ "<thead>"
      assert html =~ ~s(<th scope="row">Yin</th><td>cool</td>)
      assert html =~ ~s(<th scope="row">Yang</th><td>warm</td>)
    end

    test "colspan/rowspan survive when >1 and cell text is escaped" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [
              tt_cell("tableCell", "a < b", %{"colspan" => 2, "rowspan" => 1})
            ])
          ])
        ])

      assert [item] = PortableText.from_tiptap(tiptap)
      assert [%{"cells" => [cell]}] = item["rows"]
      assert cell["colspan"] == 2
      refute Map.has_key?(cell, "rowspan")

      assert PortableText.to_html([item]) ==
               ~s(<div class="kiln-table-wrap"><table><tbody>) <>
                 ~s(<tr><td colspan="2">a &lt; b</td></tr></tbody></table></div>)
    end

    test "cell marks and links render; unsafe link hrefs are dropped at both layers" do
      link = %{"type" => "link", "attrs" => %{"href" => "https://x.test"}}
      bad = %{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}

      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [
              tt_node("tableCell", [para([text("ok", [link])])]),
              tt_node("tableCell", [para([text("bad", [bad])])])
            ])
          ])
        ])

      pt = PortableText.from_tiptap(tiptap)
      html = PortableText.to_html(pt)

      assert html =~ ~s(<a href="https://x.test">ok</a>)
      refute html =~ "javascript:"
      assert html =~ "bad"

      # Cast-time defense-in-depth reaches cell markDefs too.
      [%{"rows" => [%{"cells" => [_ok, bad_cell]}]}] = PortableText.sanitize_body(pt)
      assert [%{"_type" => "link", "href" => ""}] = bad_cell["markDefs"]
    end

    test "multi-paragraph cells keep a break between paragraphs" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [tt_node("tableCell", [para("one"), para("two")])])
          ])
        ])

      assert [item] = PortableText.from_tiptap(tiptap)
      assert [%{"cells" => [%{"children" => children}]}] = item["rows"]
      assert Enum.map(children, & &1["text"]) == ["one", "\n", "two"]

      # The break renders as <br/> — a literal newline would collapse to a
      # space in HTML and merge the lines on the next editor hydration.
      assert PortableText.to_html([item]) =~ "<td>one<br/>two</td>"
    end

    test "non-paragraph cell content flattens to lines instead of being dropped" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [
              tt_node("tableCell", [
                para("intro"),
                tt_node("bulletList", [
                  tt_node("listItem", [para("first")]),
                  tt_node("listItem", [para("second")])
                ])
              ])
            ])
          ])
        ])

      assert [item] = PortableText.from_tiptap(tiptap)
      assert [%{"cells" => [%{"children" => children}]}] = item["rows"]
      assert Enum.map_join(children, & &1["text"]) == "intro\nfirst\nsecond"
    end

    test "sanitize_body canonicalizes malformed table shapes instead of crashing" do
      # Every shape here 500'd the cast or persisted render-crashing poison
      # before canonicalization: nil/binary rows, nil/binary cells lists,
      # non-map cells.
      body = [
        %{
          "_type" => "table",
          "rows" => [
            nil,
            "junk",
            %{"cells" => nil},
            %{"cells" => "junk"},
            %{"cells" => [%{"header" => false, "children" => [], "markDefs" => []}, "junk"]}
          ]
        }
      ]

      assert [%{"rows" => rows}] = PortableText.sanitize_body(body)
      assert [%{"cells" => []}, %{"cells" => []}, %{"cells" => [_only_map]}] = rows

      # A non-list rows value is normalized away, and rendering stays total
      # even for pre-fix stored poison.
      assert [%{"rows" => []}] =
               PortableText.sanitize_body([%{"_type" => "table", "rows" => "x"}])

      assert PortableText.to_html([%{"_type" => "table", "rows" => "x"}]) =~ "<table>"
      assert PortableText.to_plain_text([%{"_type" => "table", "rows" => "x"}]) == ""
    end

    test "sanitize_body scrubs table-level markDefs and coerces string col/rowspans" do
      body = [
        %{
          "_type" => "table",
          "markDefs" => [%{"_key" => "a", "_type" => "link", "href" => "javascript:alert(1)"}],
          "rows" => [
            %{
              "cells" => [
                %{
                  "header" => false,
                  "children" => [],
                  "markDefs" => [],
                  "colspan" => "2",
                  "rowspan" => true
                }
              ]
            }
          ]
        }
      ]

      assert [%{"markDefs" => [%{"href" => ""}], "rows" => [%{"cells" => [cell]}]}] =
               PortableText.sanitize_body(body)

      # Numeric strings become canonical integers (so :web and :json agree);
      # anything else is dropped rather than silently diverging per surface.
      assert cell["colspan"] == 2
      refute Map.has_key?(cell, "rowspan")
    end

    test "to_plain_text flattens table cells for search" do
      tiptap =
        doc([
          tt_node("table", [
            tt_node("tableRow", [tt_cell("tableHeader", "Herb"), tt_cell("tableHeader", "Use")]),
            tt_node("tableRow", [tt_cell("tableCell", "Ginger"), tt_cell("tableCell", "warmth")])
          ])
        ])

      assert tiptap |> PortableText.from_tiptap() |> PortableText.to_plain_text() ==
               "Herb Use\nGinger warmth"
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
