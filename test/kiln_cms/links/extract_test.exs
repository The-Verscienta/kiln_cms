defmodule KilnCMS.Links.ExtractTest do
  @moduledoc """
  Pulling outbound URLs out of a block tree (#474).

  The mirror image of `Kiln.Advisory.Body`'s internal-link walk, and the two
  share `Body.node_hrefs/1` so a new place a link can hide is learned once.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Links.Extract

  defp rich(nodes), do: %{"_type" => "rich_text", "body" => nodes}

  defp linked(href) do
    %{
      "_type" => "block",
      "style" => "normal",
      "children" => [%{"text" => "See"}],
      "markDefs" => [%{"_type" => "link", "href" => href}]
    }
  end

  describe "what is collected" do
    test "absolute URLs from rich-text annotations, with their block index" do
      blocks = [
        %{"_type" => "divider"},
        rich([linked("https://example.test/a")])
      ]

      assert [%{url: "https://example.test/a", block_index: 1}] = Extract.from_blocks(blocks)
    end

    test "same-origin paths, mailto and anchors are not outbound links" do
      blocks = [
        rich([
          linked("/blog/internal"),
          linked("mailto:someone@example.test"),
          linked("#section"),
          linked("https://example.test/real")
        ])
      ]

      assert [%{url: "https://example.test/real"}] = Extract.from_blocks(blocks)
    end

    test "links inside a table's cells" do
      blocks = [
        rich([
          %{
            "_type" => "table",
            "rows" => [
              %{
                "cells" => [
                  %{
                    "children" => [%{"text" => "cell"}],
                    "markDefs" => [%{"_type" => "link", "href" => "https://example.test/table"}]
                  }
                ]
              }
            ]
          }
        ])
      ]

      assert [%{url: "https://example.test/table"}] = Extract.from_blocks(blocks)
    end

    test "an embed's URL — a taken-down video is exactly this feature's case" do
      blocks = [%{"_type" => "embed", "url" => "https://vimeo.test/123"}]

      assert [%{url: "https://vimeo.test/123", block_index: 0}] = Extract.from_blocks(blocks)
    end

    test "a claim's source URL — a citation whose source vanished" do
      blocks = [
        %{"_type" => "claim", "text" => "Kilns are hot", "source_url" => "https://src.test/paper"}
      ]

      assert [%{url: "https://src.test/paper"}] = Extract.from_blocks(blocks)
    end

    test "an image's URL is not collected — it points at our own storage" do
      blocks = [%{"_type" => "image", "url" => "https://cdn.test/photo.jpg", "alt" => "x"}]

      assert Extract.from_blocks(blocks) == []
    end
  end

  describe "nesting and repetition" do
    test "a link in a column reports against its top-level ancestor's index" do
      blocks = [
        %{"_type" => "divider"},
        %{
          "_type" => "columns",
          "columns" => [%{"blocks" => [rich([linked("https://example.test/nested")])]}]
        }
      ]

      # The top-level block is the one the editor can scroll to.
      assert [%{url: "https://example.test/nested", block_index: 1}] = Extract.from_blocks(blocks)
    end

    test "a URL repeated in one document collapses to its first occurrence" do
      blocks = [
        rich([linked("https://example.test/same")]),
        rich([linked("https://example.test/same")])
      ]

      # The stored grain is {document, url}, so the alternative is not more
      # detail — it is the same row written twice.
      assert [%{url: "https://example.test/same", block_index: 0}] = Extract.from_blocks(blocks)
    end
  end

  describe "totality" do
    test "malformed input contributes nothing rather than raising" do
      for input <- [nil, [], "not a list", [%{"_type" => "who_knows"}], [%{}]] do
        assert Extract.from_blocks(input) == []
      end
    end
  end
end
