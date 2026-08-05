defmodule Kiln.Advisory.BodyTest do
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body

  defp para(text),
    do: %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}

  defp rich(blocks), do: %{"_type" => "rich_text", "body" => blocks}

  describe "compute/1 is total" do
    test "handles nil, an empty list, and unknown blocks without raising" do
      for input <- [nil, [], [%{"_type" => "who_knows", "wat" => 1}], "not a list"] do
        assert %Body{} = Body.compute(input)
      end
    end
  end

  describe "document order" do
    test "first_paragraph is the FIRST paragraph, not the last" do
      blocks = [
        rich([para("Alpha comes first."), para("Beta is second."), para("Gamma is last here.")])
      ]

      stats = Body.compute(blocks)

      assert stats.first_paragraph == "Alpha comes first."
      # Per-paragraph word counts stay in document order too — 3, 3, 4.
      assert stats.paragraph_word_counts == [3, 3, 4]
    end

    test "headings are returned in document order with their levels" do
      blocks = [
        %{"_type" => "heading", "text" => "Top", "level" => 1},
        rich([%{"_type" => "block", "style" => "h3", "children" => [%{"text" => "Nested"}]}]),
        %{"_type" => "heading", "text" => "Second", "level" => 2}
      ]

      assert Body.compute(blocks).headings == [
               %{level: 1, text: "Top"},
               %{level: 3, text: "Nested"},
               %{level: 2, text: "Second"}
             ]
    end
  end

  describe "images" do
    test "blank and whitespace-only alt both count as missing, by top-level index" do
      blocks = [
        para("ignored — not a rich_text wrapper"),
        %{"_type" => "image", "url" => "/a.jpg", "alt" => "Described"},
        %{"_type" => "image", "url" => "/b.jpg", "alt" => ""},
        %{"_type" => "image", "url" => "/c.jpg", "alt" => "   "}
      ]

      stats = Body.compute(blocks)

      assert stats.image_count == 3
      assert stats.images_missing_alt == [2, 3]
    end
  end

  describe "nested columns" do
    test "children contribute headings and images, attributed to the top-level index" do
      blocks = [
        para("filler"),
        %{
          "_type" => "columns",
          "layout" => "1-1",
          "columns" => [
            %{"blocks" => [%{"_type" => "heading", "text" => "In a column", "level" => 2}]},
            %{"blocks" => [%{"_type" => "image", "url" => "/n.jpg", "alt" => ""}]}
          ]
        }
      ]

      stats = Body.compute(blocks)

      assert stats.headings == [%{level: 2, text: "In a column"}]
      assert stats.image_count == 1
      # Attributed to the columns block's own slot, which is what the editor
      # can actually scroll to.
      assert stats.images_missing_alt == [1]
    end
  end

  describe "internal links" do
    test "collects same-origin hrefs from markDefs, deduped, ignoring external ones" do
      blocks = [
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [%{"text" => "See here"}],
            "markDefs" => [
              %{"_type" => "link", "href" => "/guides/firing"},
              %{"_type" => "link", "href" => "https://example.com/away"},
              %{"_type" => "link", "href" => "mailto:a@b.c"}
            ]
          },
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [%{"text" => "Again"}],
            "markDefs" => [%{"_type" => "link", "href" => "/guides/firing"}]
          }
        ])
      ]

      assert Body.compute(blocks).internal_link_paths == ["/guides/firing"]
    end

    test "finds links nested inside table cells" do
      blocks = [
        rich([
          %{
            "_type" => "table",
            "rows" => [
              %{
                "cells" => [
                  %{
                    "children" => [%{"text" => "cell"}],
                    "markDefs" => [%{"_type" => "link", "href" => "/in/a/table"}]
                  }
                ]
              }
            ]
          }
        ])
      ]

      assert Body.compute(blocks).internal_link_paths == ["/in/a/table"]
    end
  end

  describe "link text (#495)" do
    test "pairs each link with the text a reader actually sees" do
      blocks = [
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [
              %{"text" => "Read ", "marks" => []},
              %{"text" => "our refund policy", "marks" => ["k1"]},
              %{"text" => " or ", "marks" => []},
              %{"text" => "click here", "marks" => ["k2"]}
            ],
            "markDefs" => [
              %{"_type" => "link", "_key" => "k1", "href" => "/refunds"},
              %{"_type" => "link", "_key" => "k2", "href" => "/help"}
            ]
          }
        ])
      ]

      assert [
               %{text: "our refund policy", href: "/refunds", index: 0},
               %{text: "click here", href: "/help", index: 0}
             ] = Body.compute(blocks).links
    end

    test "joins spans that share one annotation, and ignores other marks" do
      blocks = [
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [
              %{"text" => "the ", "marks" => ["k1"]},
              %{"text" => "annual", "marks" => ["k1", "strong"]},
              %{"text" => " report", "marks" => ["k1"]},
              %{"text" => " (2024)", "marks" => ["em"]}
            ],
            "markDefs" => [%{"_type" => "link", "_key" => "k1", "href" => "/report"}]
          }
        ])
      ]

      assert [%{text: "the annual report"}] = Body.compute(blocks).links
    end

    test "an annotation with no matching span yields empty text, not a dropped link" do
      # An orphaned markDef is exactly the "empty link" defect worth
      # reporting, so losing it here would hide it.
      blocks = [
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [%{"text" => "nothing linked", "marks" => []}],
            "markDefs" => [%{"_type" => "link", "_key" => "orphan", "href" => "/x"}]
          }
        ])
      ]

      assert [%{text: "", href: "/x"}] = Body.compute(blocks).links
    end

    test "attributes a link to its TOP-LEVEL block index" do
      blocks = [
        para("first") |> then(&rich([&1])),
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [%{"text" => "go", "marks" => ["k"]}],
            "markDefs" => [%{"_type" => "link", "_key" => "k", "href" => "/x"}]
          }
        ])
      ]

      assert [%{index: 1}] = Body.compute(blocks).links
    end

    test "internal_link_paths is still derived from the same walk" do
      blocks = [
        rich([
          %{
            "_type" => "block",
            "style" => "normal",
            "children" => [%{"text" => "a", "marks" => ["k1"]}],
            "markDefs" => [
              %{"_type" => "link", "_key" => "k1", "href" => "/internal"},
              %{"_type" => "link", "_key" => "k2", "href" => "https://example.com"}
            ]
          }
        ])
      ]

      body = Body.compute(blocks)
      assert body.internal_link_paths == ["/internal"]
      assert length(body.links) == 2
    end
  end

  describe "empty headings (#495)" do
    test "a blank heading block is recorded rather than silently dropped" do
      blocks = [
        %{"_type" => "heading", "level" => 2, "text" => "Real heading"},
        %{"_type" => "heading", "level" => 2, "text" => "   "}
      ]

      body = Body.compute(blocks)

      assert body.empty_headings == [1]
      # It stays OUT of `headings`, so the level-order check isn't judging a
      # heading with no text.
      assert [%{text: "Real heading"}] = body.headings
    end

    test "a blank Portable Text heading counts too" do
      blocks = [
        rich([%{"_type" => "block", "style" => "h2", "children" => [%{"text" => ""}]}])
      ]

      assert Body.compute(blocks).empty_headings == [0]
    end

    test "no empty headings on a well-formed document" do
      blocks = [%{"_type" => "heading", "level" => 2, "text" => "Fine"}]

      assert Body.compute(blocks).empty_headings == []
    end
  end

  describe "syllable counting" do
    test "every word scores at least one syllable" do
      # An earlier whole-text version lost the per-word floor, scoring these
      # (whose only vowel is a silent trailing e) as ZERO — which inflated
      # Flesch ~17 points and silenced the readability warning entirely.
      for word <- ~w(the he she be we me) do
        assert Body.syllable_count(word) == 1, "#{word} should be 1 syllable"
      end
    end

    test "counts vowel groups and drops a silent trailing e" do
      assert Body.syllable_count("kiln") == 1
      assert Body.syllable_count("firing") == 2
      assert Body.syllable_count("make") == 1
      assert Body.syllable_count("pottery") == 3
    end
  end

  describe "tokenize/1" do
    test "splits on punctuation so firing. matches firing" do
      assert Body.tokenize(Body.fold("The kiln firing. Done!")) ==
               ~w(the kiln firing done)
    end
  end

  describe "sentences and words" do
    test "splits on terminators and counts words" do
      assert Body.sentences("One. Two! Three? Four") == ["One.", "Two!", "Three?", "Four"]
      assert Body.count_words("  a  b \n c ") == 3
      assert Body.count_words("") == 0
    end
  end
end
