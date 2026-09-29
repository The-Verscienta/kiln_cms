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
