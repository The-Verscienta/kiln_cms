defmodule KilnCMSWeb.ContentEditorMarkdownModeTest do
  @moduledoc """
  The Markdown view's conversion (`KilnCMSWeb.ContentEditor.MarkdownMode`):
  blocks to Markdown with placeholders, and edited Markdown back to blocks.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ContentEditor.MarkdownMode

  @gallery %{"_union_type" => "gallery", "id" => "7a1c0b9e-0000-4000-8000-000000000001"}

  defp placeholder(block), do: "<!-- kiln:block #{block["_union_type"]} #{block["id"]} -->"

  test "headings, dividers and plain images are Markdown; a library image is kept" do
    library = %{
      "_union_type" => "image",
      "id" => "7a1c0b9e-0000-4000-8000-000000000002",
      "url" => "https://cdn.example.com/a.png",
      "media_id" => "m1"
    }

    {source, kept} =
      MarkdownMode.to_source([
        %{"_union_type" => "heading", "id" => "h", "text" => "Intro", "level" => 3},
        %{"_union_type" => "divider", "id" => "d"},
        %{
          "_union_type" => "image",
          "id" => "i",
          "url" => "https://x.com/a b.png",
          "alt" => "A [b]"
        },
        library
      ])

    assert source ==
             "### Intro\n\n---\n\n![A \\[b\\]](<https://x.com/a b.png>)\n\n#{placeholder(library)}\n"

    assert Map.keys(kept) == [library["id"]]
  end

  test "a placeholder brings its block back once; an unknown or repeated one is dropped" do
    kept = %{@gallery["id"] => @gallery}
    unknown = placeholder(%{"_union_type" => "gallery", "id" => "nope"})

    blocks =
      MarkdownMode.from_source(
        "Before.\n\n#{placeholder(@gallery)}\n\n#{unknown}\n\nAfter.\n\n#{placeholder(@gallery)}",
        kept
      )

    assert [%{"_union_type" => "rich_text"}, @gallery, %{"_union_type" => "rich_text"}] = blocks
  end

  test "a placeholder inside a fenced code block is code" do
    blocks =
      MarkdownMode.from_source(
        "```html\n#{placeholder(@gallery)}\n```",
        %{@gallery["id"] => @gallery}
      )

    assert [%{"_union_type" => "rich_text", "body" => [%{"style" => "code"} = code]}] = blocks
    assert hd(code["children"])["text"] =~ "kiln:block gallery"
  end

  test "an image whose URL the importer wouldn't keep is kept whole" do
    for url <- ["abc123", "uploads/a.png"] do
      image = %{"_union_type" => "image", "id" => "img-#{url}", "url" => url, "alt" => "A"}
      assert {"<!-- kiln:block image img-" <> _, %{}} = MarkdownMode.to_source([image])
    end
  end

  test "prose that Markdown can't hold is kept whole" do
    merged = %{
      "_union_type" => "rich_text",
      "id" => "t",
      "body" => [
        %{
          "_type" => "table",
          "rows" => [
            %{"cells" => [%{"header" => true, "colspan" => 2, "children" => [%{"text" => "A"}]}]},
            %{
              "cells" => [
                %{"children" => [%{"text" => "1"}]},
                %{"children" => [%{"text" => "2"}]}
              ]
            }
          ]
        }
      ]
    }

    assert {"<!-- kiln:block rich_text t -->\n", %{"t" => ^merged}} =
             MarkdownMode.to_source([merged])
  end

  describe "a pasted document (#1800)" do
    @specimen File.read!("test/support/fixtures/markdown/beta_1800_specimen.md")

    defp shape(blocks) do
      Enum.map(blocks, fn
        %{"_union_type" => "heading", "level" => level, "text" => text} -> {:h, level, text}
        %{"_union_type" => type} -> String.to_atom(type)
      end)
    end

    test "the beta tester's specimen becomes headings, dividers and a prose block per section" do
      blocks = MarkdownMode.from_source(@specimen, %{})

      assert shape(blocks) == [
               {:h, 1, "Lorem Ipsum: A Comprehensive Markdown Specimen"},
               {:h, 2, "Preface"},
               :rich_text,
               :divider,
               {:h, 2, "Chapter I: Foundations of Placeholder Text"},
               {:h, 3, "Origins and Usage"},
               :rich_text,
               {:h, 4, "Nested Heading Example (H4)"},
               :rich_text,
               {:h, 5, "Even Deeper (H5)"},
               :rich_text,
               {:h, 6, "The Smallest Heading (H6)"},
               :rich_text,
               {:h, 3, "Unordered Lists"},
               :rich_text,
               {:h, 3, "Ordered Lists"},
               :rich_text,
               {:h, 3, "Task Lists"},
               :rich_text,
               :divider,
               {:h, 2, "Chapter II: Quotations, Code, and Data"},
               :rich_text,
               {:h, 3, "Comparison Table"},
               :rich_text,
               :divider,
               {:h, 2, "Chapter III: Media, Links, and Cross References"},
               :rich_text,
               # The standalone image. Before #1800 it was the only thing that
               # split the document: prose, this image, prose.
               :image,
               :rich_text,
               {:h, 3, "Definition-Style Notes"},
               :rich_text,
               :divider,
               {:h, 2, "Chapter IV: Extended Body Copy"},
               :rich_text,
               {:h, 3, "Closing Remarks"},
               :rich_text,
               :divider,
               :rich_text
             ]

      # Lists stay in their section's prose: there is no list block.
      lists = Enum.at(blocks, 14)["body"]
      assert Enum.count(lists, &(&1["listItem"] == "bullet" and &1["level"] == 2)) == 5
    end

    test "Blocks → Markdown → Blocks gives back the same blocks, ids included" do
      blocks = MarkdownMode.from_source(@specimen, %{})
      {source, kept} = MarkdownMode.to_source(blocks)

      assert kept == %{}
      ids = for %{"_union_type" => type, "id" => id} <- blocks, do: {type, id}
      assert MarkdownMode.from_source(source, kept, ids) == blocks
    end
  end

  test "heading blocks read back as heading blocks, whatever their text" do
    for text <- [
          "A *b* <a href=x>y</a> [l](u)",
          "See https://example.com/x",
          "A & B < C",
          "1. Not a list"
        ] do
      heading = %{"_union_type" => "heading", "id" => "h", "text" => text, "level" => 5}
      {source, %{}} = MarkdownMode.to_source([heading])

      assert MarkdownMode.from_source(source, %{}, [{"heading", "h"}]) == [heading]
    end
  end

  test "parsed blocks take the previous ids by position and type" do
    blocks =
      MarkdownMode.from_source(
        "First.\n\n#{placeholder(@gallery)}\n\nSecond.\n\nThird.",
        %{@gallery["id"] => @gallery},
        [{"rich_text", "p1"}, {"image", "img"}]
      )

    assert [%{"id" => "p1"}, @gallery, %{"id" => fresh}] = blocks
    refute fresh in ["p1", "img"]
  end
end
