defmodule KilnCMS.CMS.TypedBlocksTest do
  @moduledoc "Phase C — Ash.Type.Union typed storage (D11), and reading the legacy shape."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.{BlockUnion, TypedBlocks}

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

  describe "reading a stored legacy block (to_typed/1 — the read-only fallback kept at 1.0)" do
    test "maps every legacy block type to a typed block (total)" do
      legacy = [
        %{type: :heading, content: "Title", data: %{"level" => 1}, order: 0},
        %{type: :rich_text, content: "<p>hi</p>", order: 1},
        %{type: :image, content: "/x.png", data: %{"alt" => "x"}, order: 2},
        %{type: :quote, content: "q", data: %{"citation" => "me"}, order: 3},
        %{type: :embed, content: "https://x", order: 4},
        %{type: :divider, order: 5},
        %{type: :columns, data: %{"cols" => 2}, order: 6}
      ]

      typed = TypedBlocks.to_typed(legacy)

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
               TypedBlocks.to_typed([
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
               TypedBlocks.to_typed([%{"type" => "never_an_atom_pricing_table_1537"}])
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
      [heading] =
        TypedBlocks.to_typed([%{id: "abc", type: :heading, content: "T"}])

      assert heading.id == "abc"
      assert heading |> Blocks.render(:web) |> IO.iodata_to_binary() == "<h2>T</h2>"
    end

    test "tolerates nested string-keyed maps from jsonb" do
      typed =
        TypedBlocks.to_typed([
          %{"type" => "heading", "content" => "Hi", "data" => %{"level" => 4}}
        ])

      assert [%Blocks.Heading{text: "Hi", level: 4}] = typed
    end

    test "a divider maps to the Divider block and renders as <hr/>" do
      assert [%Blocks.Divider{} = divider] =
               TypedBlocks.to_typed([%{type: :divider}])

      assert Blocks.render(divider, :web) |> IO.iodata_to_binary() == "<hr/>"
    end
  end

  # 0.12 deprecated the legacy shape as write input; 1.0 refuses it (#1543).
  # Stored rows in it — a row the backfill refused, a version in history —
  # still load.
  describe "the legacy write shape, at 1.0" do
    test "is refused on write, with an error that says what to send instead" do
      for legacy <- [
            %{type: :heading, content: "T", data: %{"level" => 2}},
            %{"type" => "rich_text", "content" => "<p>x</p>"}
          ] do
        assert {:error, [message: message]} = Ash.Type.cast_input(BlockUnion, legacy)
        assert message =~ "legacy `type`/`content`/`data` shape"
        assert message =~ "`_type`"

        assert {:error, _} = Ash.Type.cast_input({:array, BlockUnion}, [legacy])
      end
    end

    # Reading a stored legacy row through the real load path — and every row
    # the backfill refuses — is `KilnCMSWeb.LegacyBlockDeliveryTest`.
    test "a stored legacy row still converts to the stored union envelope" do
      assert %{
               "type" => "heading",
               "value" => %{"_type" => "heading", "text" => "T", "level" => 2}
             } =
               TypedBlocks.to_union_stored(%{
                 "type" => "heading",
                 "content" => "T",
                 "data" => %{"level" => 2}
               })
    end

    test "an unknown type or a non-block parks as custom on read, payload whole" do
      assert %{
               "type" => "custom",
               "value" => %{"legacy_type" => "retired_widget", "data" => %{"size" => 3}}
             } =
               TypedBlocks.to_union_stored(%{
                 "type" => "retired_widget",
                 "value" => %{"_type" => "retired_widget", "size" => 3}
               })

      assert %{"type" => "custom", "value" => %{"data" => %{"nothing" => "here"}}} =
               TypedBlocks.to_union_stored(%{"nothing" => "here"})
    end

    test "a stored union envelope is not mistaken for the legacy shape" do
      assert {:ok, %Ash.Union{value: %Blocks.Heading{text: "T"}}} =
               Ash.Type.cast_input(BlockUnion, %{
                 "type" => "heading",
                 "value" => %{"_type" => "heading", "text" => "T"}
               })
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
