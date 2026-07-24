defmodule KilnCMS.CMS.TypedBlocksBodyCastTest do
  @moduledoc """
  The rich_text block cast accepts three `body` input shapes — the editor's
  hidden input (a JSON string of the live TipTap document), a decoded TipTap
  doc (inline editing's update_block push), and canonical Portable Text
  (imports / API) — and normalizes them all to PT. Once PT is present,
  legacy_html is cleared: body is the single source of truth.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.TypedBlocks

  @tiptap %{
    "type" => "doc",
    "content" => [
      %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "text" => "typed in TipTap"}]
      }
    ]
  }

  # Exercise the save path (to_union_input, the BlockUnion cast) and hand the
  # normalized tag map to to_typed the way the union cast would.
  defp cast_rich_text(body_input, extra \\ %{}) do
    input =
      %{"_type" => "rich_text", "body" => body_input}
      |> Map.merge(extra)
      |> TypedBlocks.to_union_input()

    [%KilnCMS.Blocks.RichText{} = block] = TypedBlocks.to_typed([input])
    block
  end

  test "a JSON string of a TipTap doc converts to Portable Text" do
    block = cast_rich_text(Jason.encode!(@tiptap))

    assert [%{"_type" => "block", "children" => [%{"text" => "typed in TipTap"}]}] = block.body
  end

  test "a decoded TipTap doc converts to Portable Text" do
    block = cast_rich_text(@tiptap)

    assert [%{"_type" => "block"}] = block.body
  end

  test "canonical Portable Text passes through" do
    pt = [
      %{
        "_type" => "block",
        "_key" => "b0",
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "text" => "already PT", "marks" => []}]
      }
    ]

    block = cast_rich_text(pt)
    assert block.body == pt
  end

  test "a non-empty body clears legacy_html (single source of truth)" do
    block = cast_rich_text(Jason.encode!(@tiptap), %{"legacy_html" => "<p>stale</p>"})

    assert [%{"_type" => "block"}] = block.body
    assert block.legacy_html in [nil, ""]
  end

  test "an empty body leaves legacy_html alone (un-migrated content)" do
    block = cast_rich_text("[]", %{"legacy_html" => "<p>legacy prose</p>"})

    assert block.body == []
    assert block.legacy_html =~ "legacy prose"
  end

  test "garbage strings degrade to an empty body" do
    assert cast_rich_text("not json").body == []
  end
end
