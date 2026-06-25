defmodule KilnCMS.CMS.TypedBlocksTest do
  @moduledoc "Phase C — Ash.Type.Union typed storage (D11) + legacy↔typed bridge."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.{Block, BlockUnion, TypedBlocks}

  describe "BlockUnion (Ash.Type.Union)" do
    test "casts a tagged map to the matching typed block, wrapped in Ash.Union" do
      {:ok, %Ash.Union{type: :heading, value: %Blocks.Heading{} = heading}} =
        Ash.Type.cast_input(BlockUnion, %{"_type" => "heading", "text" => "Hi", "level" => 3})

      assert heading.text == "Hi"
      assert heading.level == 3
    end

    test "dispatches each member by its _type discriminator" do
      for {tag, mod} <- [
            {"image", Blocks.Image},
            {"rich_text", Blocks.RichText},
            {"quote", Blocks.Quote},
            {"embed", Blocks.Embed},
            {"custom", Blocks.Custom}
          ] do
        input = Map.merge(%{"_type" => tag}, required_for(tag))
        assert {:ok, %Ash.Union{value: %^mod{}}} = Ash.Type.cast_input(BlockUnion, input)
      end
    end
  end

  describe "from_legacy/1 bridge" do
    test "maps every legacy block type to a typed block (total)" do
      legacy = [
        %Block{type: :heading, content: "Title", data: %{"level" => 1}, order: 0},
        %Block{type: :rich_text, content: "<p>hi</p>", order: 1},
        %Block{type: :image, content: "/x.png", data: %{"alt" => "x"}, order: 2},
        %Block{type: :quote, content: "q", data: %{"citation" => "me"}, order: 3},
        %Block{type: :embed, content: "https://x", order: 4},
        %Block{type: :divider, order: 5},
        %Block{type: :columns, data: %{"cols" => 2}, order: 6}
      ]

      typed = TypedBlocks.from_legacy(legacy)

      assert [
               %Blocks.Heading{text: "Title", level: 1},
               %Blocks.RichText{legacy_html: "<p>hi</p>"},
               %Blocks.Image{url: "/x.png", alt: "x"},
               %Blocks.Quote{text: "q", citation: "me"},
               %Blocks.Embed{url: "https://x"},
               %Blocks.Divider{},
               %Blocks.Custom{legacy_type: "columns"}
             ] = typed
    end

    test "preserves block ids and renders via the typed serializers" do
      [heading] = TypedBlocks.from_legacy([%Block{id: "abc", type: :heading, content: "T"}])
      assert heading.id == "abc"
      assert heading |> Blocks.render(:web) |> IO.iodata_to_binary() == "<h2>T</h2>"
    end

    test "tolerates nested string-keyed maps from jsonb" do
      typed =
        TypedBlocks.from_legacy([
          %{"type" => "heading", "content" => "Hi", "data" => %{"level" => 4}}
        ])

      assert [%Blocks.Heading{text: "Hi", level: 4}] = typed
    end

    test "a divider maps to the Divider block and renders as <hr/>" do
      assert [%Blocks.Divider{} = divider] = TypedBlocks.from_legacy([%Block{type: :divider}])
      assert Blocks.render(divider, :web) |> IO.iodata_to_binary() == "<hr/>"
    end
  end

  describe "to_legacy/1 round-trip" do
    test "typed → legacy preserves the discriminator and payload" do
      typed = [%Blocks.Heading{text: "T", level: 2}, %Blocks.Quote{text: "q", citation: "c"}]

      assert [
               %{type: :heading, content: "T", data: %{"level" => 2}},
               %{type: :quote, content: "q", data: %{"citation" => "c"}}
             ] = TypedBlocks.to_legacy(typed)
    end
  end

  defp required_for("image"), do: %{"url" => "/x.png"}
  defp required_for("rich_text"), do: %{"body" => []}
  defp required_for("quote"), do: %{"text" => "q"}
  defp required_for("embed"), do: %{"url" => "https://x"}
  defp required_for(_), do: %{}
end
