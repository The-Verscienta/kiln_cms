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

    test "strips javascript: link hrefs from Portable Text body on cast" do
      body = [
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [%{"_type" => "span", "text" => "click", "marks" => ["lk0"]}],
          "markDefs" => [%{"_key" => "lk0", "_type" => "link", "href" => "javascript:alert(1)"}]
        }
      ]

      {:ok, %Ash.Union{value: %Blocks.RichText{body: [block]}}} =
        Ash.Type.cast_input(BlockUnion, %{"_type" => "rich_text", "body" => body})

      assert [%{"href" => ""}] = block["markDefs"]
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
               %Blocks.Columns{columns: []}
             ] = typed
    end

    # #1537: a legacy `columns` block became an opaque `Custom` on every typed
    # read, rendering as columns only because delivery converted it straight
    # back. It is a typed `Columns` now, children and all.
    test "a legacy columns block keeps its layout and child tree" do
      child = %{"type" => "heading", "content" => "Left", "data" => %{"level" => 3}}

      assert [%Blocks.Columns{layout: "1-2", gap: "lg", columns: [%{"blocks" => [^child]}]}] =
               TypedBlocks.from_legacy([
                 %{
                   "type" => "columns",
                   "data" => %{
                     "layout" => "1-2",
                     "gap" => "lg",
                     "columns" => [%{"blocks" => [child]}]
                   }
                 }
               ])
    end

    # #1537: an unmapped legacy type kept only `"custom"` as its name when the
    # stored string was never an atom in this build.
    test "an unmapped legacy type keeps the name it was stored under" do
      assert [%Blocks.Custom{legacy_type: "never_an_atom_pricing_table_1537"}] =
               TypedBlocks.from_legacy([%{"type" => "never_an_atom_pricing_table_1537"}])
    end

    test "legacy_loss/1: nothing, for a block the typed mapping holds whole" do
      assert TypedBlocks.legacy_loss(%{
               "id" => "x",
               "type" => "heading",
               "content" => "T",
               "data" => %{"level" => "3"},
               "order" => 4
             }) == []
    end

    test "legacy_loss/1: names every key the typed block has nowhere to keep" do
      assert TypedBlocks.legacy_loss(%{
               "type" => "image",
               "content" => "https://old/pic.jpg",
               "data" => %{"url" => "https://new/pic.jpg", "width" => 640},
               "children" => [%{"type" => "heading"}],
               "style" => "wide"
             }) == ["content", "data.width", "children", "style"]
    end

    test "legacy_loss/1: a divider has nowhere to put content; custom keeps any data" do
      assert TypedBlocks.legacy_loss(%{"type" => "divider", "content" => "text"}) == ["content"]

      assert TypedBlocks.legacy_loss(%{
               "type" => "custom",
               "content" => "c",
               "data" => %{"a" => %{"b" => [1, 2]}}
             }) == []
    end

    test "legacy_loss/1: a legacy columns block loses only what is not its layout or tree" do
      assert TypedBlocks.legacy_loss(%{"type" => "columns", "data" => %{"cols" => 2}}) ==
               ["data.cols"]
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

  describe "InvalidChildBlockError.message/1 (#5/#6): readable errors, not struct dumps" do
    alias KilnCMS.CMS.TypedBlocks.InvalidChildBlockError

    test "a bare Ash/Splode exception is formatted via Exception.message/1, not inspect/1" do
      # `Ash.Type.cast_input` on an embedded resource returns Splode exception
      # structs (`Ash.Error.Changes.Required` for a missing required field), not
      # keyword lists — the old `is_list(kw)` clause never matched them, so this
      # fell through to `inspect(other)` and leaked the raw struct.
      error = Ash.Error.Changes.Required.exception(field: :text, type: :attribute)

      message =
        Exception.message(%InvalidChildBlockError{block_type: "claim", errors: [error]})

      assert message =~ "text"
      assert message =~ "required"
      refute message =~ "%Ash.Error"
      refute message =~ "splode:"
    end

    test "a Splode exception's :vars are substituted into its message template" do
      # `Exception.message/1` on a Splode exception substitutes `:vars` into the
      # message — the hand-rolled keyword-list branch never did this, so a
      # constraint violation showed the literal `%{min}` placeholder.
      error =
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :text,
          message: "must be at least %{min} characters",
          vars: [min: 3]
        )

      message =
        Exception.message(%InvalidChildBlockError{block_type: "quote", errors: [error]})

      assert message =~ "must be at least 3 characters"
      refute message =~ "%{min}"
    end
  end

  defp required_for("image"), do: %{"url" => "/x.png"}
  defp required_for("rich_text"), do: %{"body" => []}
  defp required_for("quote"), do: %{"text" => "q"}
  defp required_for("embed"), do: %{"url" => "https://x"}
  defp required_for(_), do: %{}
end
