defmodule KilnCMSWeb.BlockViewTest do
  @moduledoc """
  `KilnCMSWeb.BlockComponents.view_blocks/1` — the render maps every block
  surface (delivery, the previews, the in-context editor) is built from, taken
  straight from the typed blocks now that the legacy bridge is deprecated
  (#1537) — and the deprecation markers themselves.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMSWeb.BlockComponents

  test "rich text renders through the block's own serializer, Portable Text first" do
    body = Blocks.PortableText.from_html("<p>Fresh <strong>prose</strong></p>")

    assert [%{type: "rich_text", content: html, id: "r1"}] =
             BlockComponents.view_blocks([
               %Blocks.RichText{id: "r1", body: body, legacy_html: "<p>stale copy</p>"}
             ])

    assert html == "<p>Fresh <strong>prose</strong></p>"
  end

  test "unconverted legacy_html still renders, sanitized" do
    assert [%{content: html}] =
             BlockComponents.view_blocks([
               %Blocks.RichText{
                 body: [],
                 legacy_html: ~s|<p onclick="x()">old</p><script>1</script>|
               }
             ])

    assert html =~ "<p>old</p>"
    refute html =~ "onclick"
    refute html =~ "<script"
  end

  test "stored maps of any shape are typed first — a legacy columns tree included" do
    stored = [
      %{
        "type" => "columns",
        "data" => %{
          "layout" => "1-1",
          "columns" => [
            %{"blocks" => [%{"type" => "heading", "content" => "Left"}]},
            %{"blocks" => [%{"_type" => "image", "url" => "https://x.test/a.png", "alt" => "A"}]}
          ]
        }
      }
    ]

    assert [%{type: "columns", columns: [left, right], style: style}] =
             BlockComponents.view_blocks(stored)

    assert [%{type: "heading", content: "Left"}] = left.blocks
    assert [%{type: "image", content: "https://x.test/a.png", alt: "A"}] = right.blocks
    assert style =~ "grid-template-columns"
  end

  test "a block with no view of its own renders as an empty custom block" do
    assert [%{type: "custom", content: nil, id: "v1"}] =
             BlockComponents.view_blocks([%Blocks.Video{id: "v1", url: "https://x.test/v.mp4"}])
  end

  describe "the legacy block bridge, at 1.0 (#1543)" do
    test "to_legacy/1, from_legacy/1 and KilnCMS.CMS.Block are gone" do
      exports = KilnCMS.CMS.TypedBlocks.__info__(:functions)

      refute {:to_legacy, 1} in exports
      refute {:from_legacy, 1} in exports
      refute Code.ensure_loaded?(Module.concat([KilnCMS, CMS, Block]))
    end

    test "legacy_html is a read-only, deprecated fallback in the exported block schema" do
      schema = Kiln.Block.JsonSchema.for_module(Blocks.RichText)

      assert %{"deprecated" => true, "readOnly" => true} = schema["properties"]["legacy_html"]
      refute Map.has_key?(schema["properties"]["body"], "deprecated")
    end
  end
end
