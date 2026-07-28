defmodule KilnCMS.Seo.BodyStatsTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Seo.BodyStats

  defp para(text),
    do: %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}

  defp rich(blocks), do: %{"_type" => "rich_text", "body" => blocks}

  describe "compute/1 is total" do
    test "handles nil, an empty list, and unknown blocks without raising" do
      for input <- [nil, [], [%{"_type" => "who_knows", "wat" => 1}], "not a list"] do
        assert %BodyStats{} = BodyStats.compute(input)
      end
    end
  end

  describe "document order" do
    test "first_paragraph is the FIRST paragraph, not the last" do
      blocks = [
        rich([para("Alpha comes first."), para("Beta is second."), para("Gamma is last here.")])
      ]

      stats = BodyStats.compute(blocks)

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

      assert BodyStats.compute(blocks).headings == [
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

      stats = BodyStats.compute(blocks)

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

      stats = BodyStats.compute(blocks)

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

      assert BodyStats.compute(blocks).internal_link_paths == ["/guides/firing"]
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

      assert BodyStats.compute(blocks).internal_link_paths == ["/in/a/table"]
    end
  end

  describe "sentences and words" do
    test "splits on terminators and counts words" do
      assert BodyStats.sentences("One. Two! Three? Four") == ["One.", "Two!", "Three?", "Four"]
      assert BodyStats.count_words("  a  b \n c ") == 3
      assert BodyStats.count_words("") == 0
    end
  end
end
