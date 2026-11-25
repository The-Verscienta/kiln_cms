defmodule KilnCMS.Blocks.PortableTextShapeTest do
  @moduledoc """
  A malformed Portable Text body that is already stored renders instead of
  raising (#2768): `repair_body/1` salvages what it can before every reader,
  and the renderers skip what is left.

  Every shape here raised in at least one of `to_html/1`, `to_plain_text/1`
  and `to_markdown/1`, or rendered without the text it carried, before the
  repair.
  """
  use ExUnit.Case, async: true

  import KilnCMS.TipTapFixtures

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.LegacyBlockCorpus

  import KilnCMS.MalformedPortableText, only: [block: 1, block: 2, span: 2]

  @neighbor KilnCMS.MalformedPortableText.neighbor()
  # {name, malformed node, text the repair must keep (nil: nothing to keep)}
  @shapes KilnCMS.MalformedPortableText.shapes()

  describe "renderers on a stored malformed body (#2768)" do
    for {name, poison, kept} <- @shapes do
      @poison poison
      @kept kept

      # Fails on the code before #2768 for every shape but the numeric-string
      # level, which the old HTML renderer already nested correctly.
      test "to_html/1: #{name}" do
        html = PortableText.to_html([@neighbor, @poison])

        assert html =~ "Neighbor stays"
        assert_kept(html, @kept)
      end

      # Fails on the code before #2768 for a binary child, string children, a
      # map text, the custom node, the code block's string children and the
      # top-level binary node.
      test "to_plain_text/1: #{name}" do
        text = PortableText.to_plain_text([@neighbor, @poison])

        assert text =~ "Neighbor stays"
        assert_kept(text, @kept)
      end

      # Fails on the code before #2768 for a binary child, string children, a
      # map text, the custom node, the code block's string children (their
      # text was dropped) and the numeric-string level (which raised).
      test "to_markdown/1: #{name}" do
        markdown = PortableText.to_markdown([@neighbor, @poison])

        assert markdown =~ "Neighbor stays"
        assert_kept(markdown, @kept)
      end
    end

    # Fails on the code before #2768, as does every `repair_body/1` test below.
    test "a salvaged mark still applies" do
      assert PortableText.to_html([block([span("Bold", "strong")])]) ==
               "<p><strong>Bold</strong></p>"
    end

    # Fails on the code before #2768 in Markdown, which raised; the old HTML
    # already nested the item.
    test "a numeric-string level nests the item as that level would" do
      items = [
        block([span("one", [])], %{"listItem" => "bullet", "level" => 1}),
        block([span("two", [])], %{"_key" => "b1", "listItem" => "bullet", "level" => "2"})
      ]

      assert PortableText.to_html(items) == "<ul><li>one<ul><li>two</li></ul></li></ul>"
      assert PortableText.to_markdown(items) == "- one\n    - two"
    end
  end

  describe "from_tiptap/1 on hostile editor JSON" do
    # Fails on the code before #2768: `marks` went straight into Enum.reduce.
    test "a text node whose marks is not a list converts as unmarked text" do
      for marks <- ["bold", %{"type" => "bold"}, 1] do
        assert [%{"children" => [%{"text" => "hi", "marks" => []}]}] =
                 PortableText.from_tiptap(doc(para([text("hi", marks)])))
      end
    end

    # Fails on the code before #2768: `content` went straight into Enum.reduce.
    test "a node whose content is not a list converts as an empty block" do
      for content <- ["abc", %{"type" => "text", "text" => "x"}, 1] do
        for type <- ["paragraph", "heading", "codeBlock"] do
          assert [%{"_type" => "block", "children" => [], "markDefs" => []}] =
                   PortableText.from_tiptap(doc([%{"type" => type, "content" => content}]))
        end
      end
    end
  end

  defp assert_kept(_output, nil), do: :ok
  defp assert_kept(output, kept), do: assert(output =~ kept)

  describe "repair_body/1" do
    test "salvages binaries into spans and wraps binary marks" do
      assert PortableText.repair_body([block("abc"), block(["x", nil, 3])]) == [
               block([span("abc", [])]),
               block([span("x", [])])
             ]

      assert [%{"children" => [%{"marks" => ["strong"]}]}] =
               PortableText.repair_body([block([span("a", "strong")])])
    end

    test "drops non-string marks and non-map markDefs entries" do
      [repaired] =
        PortableText.repair_body([
          block([span("a", ["em", nil, %{}, ["x"], "lk"])], %{
            "markDefs" => ["x", nil, %{"_key" => "lk", "_type" => "link", "href" => "/a"}]
          })
        ])

      assert [%{"marks" => ["em", "lk"]}] = repaired["children"]
      assert repaired["markDefs"] == [%{"_key" => "lk", "_type" => "link", "href" => "/a"}]
    end

    test "coerces numbers and booleans in string slots" do
      [repaired] =
        PortableText.repair_body([
          %{
            "_type" => "block",
            "_key" => 3,
            "style" => true,
            "listItem" => 1.5,
            "children" => [%{"_type" => "span", "text" => 42, "marks" => [1, false]}]
          }
        ])

      assert repaired["_key"] == "3"
      assert repaired["style"] == "true"
      assert repaired["listItem"] == "1.5"
      assert [%{"text" => "42", "marks" => ["1", "false"]}] = repaired["children"]
    end

    test "a map or list text becomes empty; other bad string slots are removed" do
      [repaired] =
        PortableText.repair_body([
          %{
            "_type" => "block",
            "_key" => ["k"],
            "style" => %{},
            "children" => [%{"text" => %{}}, %{"text" => ["a"]}]
          }
        ])

      refute Map.has_key?(repaired, "_key")
      refute Map.has_key?(repaired, "style")
      assert repaired["children"] == [%{"text" => ""}, %{"text" => ""}]
    end

    test "a numeric-string level or whole-number float becomes an integer; any other non-integer level is removed" do
      levels =
        for level <- ["2", 2.0, "two", "2.5", 2.5, %{}, true] do
          [repaired] = PortableText.repair_body([%{"listItem" => "bullet", "level" => level}])
          Map.fetch(repaired, "level")
        end

      assert levels == [{:ok, 2}, {:ok, 2}, :error, :error, :error, :error, :error]
    end

    test "repairs what the renderers read on custom nodes, markDefs entries and table cells" do
      [custom, table] =
        PortableText.repair_body([
          %{"_type" => "callout", "children" => "abc", "markDefs" => %{"_key" => 1}},
          %{
            "_type" => "table",
            "rows" => [
              "junk",
              %{"cells" => [%{"children" => ["cell", %{"text" => 7, "marks" => "em"}]}, nil]}
            ]
          }
        ])

      assert custom["children"] == [span("abc", [])]
      assert custom["markDefs"] == [%{"_key" => "1"}]

      assert table["rows"] == [
               %{
                 "cells" => [
                   %{"children" => [span("cell", []), %{"text" => "7", "marks" => ["em"]}]}
                 ]
               }
             ]
    end

    test "leaves a custom node's own fields and an annotation's fields alone" do
      custom = %{
        "_type" => "callout",
        "_key" => %{"not" => "a string"},
        "style" => ["warning"],
        "level" => %{"severity" => 3},
        "text" => %{"title" => "Heads up"},
        "marks" => "anything",
        "tone" => 4.5,
        "children" => [
          %{"_type" => "span", "text" => "Inside", "marks" => ["note"]},
          %{"_type" => "mention", "text" => %{"id" => 1}, "user" => [1, 2], "marks" => []}
        ],
        "markDefs" => [
          %{
            "_key" => "note",
            "_type" => "footnote",
            "level" => %{"depth" => 1},
            "style" => %{"italic" => true},
            "text" => %{"body" => "A note"}
          }
        ]
      }

      assert PortableText.repair_body([custom]) == [custom]
      assert PortableText.to_html([custom]) == "<p>Inside</p>"
      assert PortableText.to_plain_text([custom]) == "Inside"
      assert PortableText.to_markdown([custom]) == "Inside"
      assert PortableText.to_markdown([Map.put(custom, "listItem", "bullet")]) == "- Inside"
    end

    test "returns a well-formed body itself, without rebuilding it" do
      body = [@neighbor, block([span("b", ["strong"])], %{"listItem" => "bullet", "level" => 2})]

      assert PortableText.Shape.well_formed?(body)
      assert :erts_debug.same(PortableText.repair_body(body), body)
      refute PortableText.Shape.well_formed?([block("abc")])
    end

    test "never adds a missing key and leaves nil values alone" do
      sparse = [
        %{"_type" => "block"},
        %{"_type" => "block", "children" => [%{"text" => "no marks"}]},
        %{"_type" => "block", "children" => nil, "markDefs" => nil, "level" => nil},
        %{"_type" => "block", "children" => [%{"text" => nil, "marks" => nil}]}
      ]

      assert PortableText.repair_body(sparse) == sparse
    end

    test "drops top-level nodes that are not maps and leaves a non-list alone" do
      assert PortableText.repair_body(["x", nil, 1, @neighbor]) == [@neighbor]
      assert PortableText.repair_body(nil) == nil
      assert PortableText.repair_body("x") == "x"
    end

    test "is idempotent on every malformed shape" do
      for {_name, poison, _kept} <- @shapes do
        once = PortableText.repair_body([@neighbor, poison])
        assert PortableText.repair_body(once) == once
      end
    end

    test "is the identity on bodies the editor and the importers write" do
      for body <- valid_bodies() do
        assert PortableText.repair_body(body) == body
      end
    end
  end

  # The strict check a headless `block_tree` write goes through. Every test
  # here fails on the code before #2768, which had no check.
  describe "check_body/2 (#2768 write check)" do
    alias KilnCMS.Blocks.PortableText.Shape

    test "names each violation by its 0-based path and the type it found, never the value" do
      body = [
        @neighbor,
        block([span("a", "strong"), "loose", span(%{"secret" => 1}, [%{}, nil, ["x"]])], %{
          "markDefs" => [nil],
          "style" => ["h2"],
          "level" => 2.5
        }),
        %{"_type" => "table", "rows" => [%{"cells" => [%{"children" => "cell"}]}]},
        :not_json
      ]

      assert Shape.check_body(body) ==
               {:error,
                [
                  "body[1].style must be a string (got a list)",
                  "body[1].level must be an integer (got a fractional number)",
                  "body[1].children[0].marks must be a list of strings (got a string)",
                  "body[1].children[1] must be an object (got a string)",
                  "body[1].children[2].text must be a string (got an object)",
                  "body[1].children[2].marks[0] must be a string (got an object)",
                  "body[1].children[2].marks[2] must be a string (got a list)",
                  "body[1].markDefs[0] must be an object (got null)",
                  "body[2].rows[0].cells[0].children must be a list (got a string)",
                  "body[3] must be an object (got an unsupported value)"
                ]}
    end

    test "takes the path prefix it is given" do
      assert {:error, ["block_tree[0].summary[0] must be an object (got a number)"]} =
               Shape.check_body([1], "block_tree[0].summary")
    end

    test "refuses a level that is not an integer, a whole number or a numeric string" do
      for {level, got} <- [
            {"two", "a non-numeric string"},
            {"2.5", "a non-numeric string"},
            {2.5, "a fractional number"},
            {true, "a boolean"},
            {%{}, "an object"},
            {[2], "a list"}
          ] do
        assert {:error, ["body[0].level must be an integer (got #{got})"]} ==
                 Shape.check_body([%{"_type" => "block", "level" => level}])
      end
    end

    test "coerces scalars and drops null marks" do
      body = [
        %{
          "_type" => "block",
          "_key" => 3,
          "style" => true,
          "level" => "2",
          "children" => [%{"_type" => "span", "text" => 42, "marks" => [nil, 1, "em"]}],
          "markDefs" => [%{"_key" => 7, "_type" => "link", "href" => 1}]
        },
        %{"_type" => "block", "listItem" => "bullet", "level" => 3.0}
      ]

      assert {:ok, [coerced, whole]} = Shape.check_body(body)

      assert coerced == %{
               "_type" => "block",
               "_key" => "3",
               "style" => "true",
               "level" => 2,
               "children" => [%{"_type" => "span", "text" => "42", "marks" => ["1", "em"]}],
               "markDefs" => [%{"_key" => "7", "_type" => "link", "href" => "1"}]
             }

      assert whole["level"] == 3
    end

    test "holds a custom node's standard keys to the schema and leaves its own alone" do
      own = %{"_type" => "callout", "tone" => %{"any" => ["shape"]}, "children" => []}
      assert Shape.check_body([own]) == {:ok, [own]}

      assert {:error,
              [
                "body[0]._key must be a string (got an object)",
                "body[0].children[0].text must be a string (got an object)"
              ]} =
               Shape.check_body([
                 %{
                   "_type" => "callout",
                   "_key" => %{},
                   "children" => [%{"_type" => "mention", "text" => %{"id" => 1}}]
                 }
               ])
    end

    test "keeps table rows and cells lenient (#475)" do
      table = %{"_type" => "table", "rows" => ["junk", %{"cells" => [nil, %{"children" => []}]}]}
      assert Shape.check_body([table]) == {:ok, [table]}
    end

    test "accepts what the repair returns for every malformed shape" do
      for {_name, poison, _kept} <- @shapes do
        repaired = PortableText.repair_body([@neighbor, poison])
        assert Shape.check_body(repaired) == {:ok, repaired}
      end
    end

    test "is the identity on bodies the editor and the importers write" do
      for body <- valid_bodies() ++ importer_bodies() do
        assert Shape.check_body(body) == {:ok, body}
      end
    end
  end

  # What `KilnCMS.Markdown` (the API's `body_markdown`, the editor's paste)
  # and `KilnCMS.Blocks.Html` (the WordPress and Ghost importers) produce.
  defp importer_bodies do
    markdown =
      Path.expand("../../support/fixtures/markdown/beta_1800_specimen.md", __DIR__)
      |> File.read!()

    html = """
    <h2>Title</h2><p>Some <strong>bold</strong> and <a href="https://x.test">a link</a>.</p>
    <ul><li>one<ul><li>nested</li></ul></li></ul><ol><li>first</li></ol>
    <blockquote><p>Quoted</p></blockquote><pre><code class="language-elixir">IO.puts(1)</code></pre>
    <table><tr><th colspan="2">H</th></tr><tr><td>C</td><td><em>D</em></td></tr></table>
    """

    blocks =
      KilnCMS.Markdown.to_blocks(markdown) ++
        KilnCMS.Blocks.Html.to_blocks(html) ++
        KilnCMS.Blocks.Html.to_blocks(html, autop: false, shortcodes: false)

    bodies = for %{"type" => "rich_text", "value" => %{"body" => body}} <- blocks, do: body
    assert length(bodies) >= 3
    bodies
  end

  # Bodies from every producer that writes Portable Text: the TipTap
  # conversion on the fixtures, the HTML conversion across the legacy corpus,
  # and the bodies the corpus stores as they are.
  defp valid_bodies do
    tiptap = [
      doc([para("Plain"), para([text("Bold", [%{"type" => "bold"}])])]),
      doc([
        bullet_list([list_item([para("one"), bullet_list([list_item(para("nested"))])])]),
        ordered_list([list_item(para("first"))])
      ]),
      doc([
        para([text("link", [%{"type" => "link", "attrs" => %{"href" => "https://x.test"}}])]),
        tt_node("codeBlock", [text("IO.puts(1)")]) |> Map.put("attrs", %{"language" => "elixir"}),
        tt_node("horizontalRule"),
        tt_node("table", [
          tt_node("tableRow", [
            tt_node("tableHeader", [para("H")]) |> Map.put("attrs", %{"colspan" => 2})
          ]),
          tt_node("tableRow", [tt_node("tableCell", [para("C")])])
        ])
      ])
    ]

    from_tiptap = Enum.map(tiptap, &PortableText.from_tiptap/1)

    from_corpus =
      for {_name, _expectation, stored} <- LegacyBlockCorpus.entries(),
          value <- deep_values(stored),
          body <- corpus_body(value),
          do: body

    bodies = from_tiptap ++ from_corpus
    assert Enum.any?(bodies, &(&1 != []))
    bodies
  end

  defp corpus_body(%{"body" => body}) when is_list(body), do: [body]

  defp corpus_body(%{"legacy_html" => html}) when is_binary(html),
    do: [PortableText.from_html(html)]

  defp corpus_body(%{"content" => html}) when is_binary(html),
    do: [PortableText.from_html(html)]

  defp corpus_body(_value), do: []

  defp deep_values(value) when is_map(value),
    do: [value | value |> Map.values() |> Enum.flat_map(&deep_values/1)]

  defp deep_values(value) when is_list(value), do: Enum.flat_map(value, &deep_values/1)
  defp deep_values(_value), do: []
end
