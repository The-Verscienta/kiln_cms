defmodule KilnCMS.Blocks.ColumnsTest do
  @moduledoc "Nested-layout container block (#335): serializers, cast, refs."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.Columns
  alias KilnCMS.CMS.{BlockUnion, TypedBlocks}
  alias KilnCMS.Firing.References

  # A two-column layout: heading + image in one, a quote in the other.
  defp sample do
    %Columns{
      layout: "1-1",
      gap: "md",
      columns: [
        %{
          "blocks" => [
            %{"_type" => "heading", "text" => "Left", "level" => 3},
            %{"_type" => "image", "url" => "/a.png", "alt" => "A"}
          ]
        },
        %{"blocks" => [%{"_type" => "quote", "text" => "Right", "citation" => "me"}]}
      ]
    }
  end

  describe ":web serializer" do
    test "renders a grid container with a div per column and nested child HTML" do
      html = sample() |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ ~s(class="kiln-columns")
      assert html =~ "display:grid"
      assert html =~ "grid-template-columns:1fr 1fr"
      assert html =~ "gap:1rem"
      # Two column wrappers.
      assert length(String.split(html, ~s(class="kiln-column"))) == 3
      # Children render through their own typed serializers, in order.
      assert html =~ "<h3>Left</h3>"
      assert html =~ ~s(<img src="/a.png" alt="A"/>)
      assert html =~ "Right"
    end

    test "falls back to equal widths when the preset count mismatches the columns" do
      block = %Columns{layout: "1-1-1", columns: [%{"blocks" => []}, %{"blocks" => []}]}
      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()
      assert html =~ "grid-template-columns:repeat(2, minmax(0, 1fr))"
    end

    test "always renders to a binary, even with empty/garbage columns" do
      for cols <- [[], [%{}], [%{"blocks" => nil}], nil] do
        block = %Columns{columns: cols}
        assert is_binary(IO.iodata_to_binary(Blocks.render(block, :web)))
      end
    end
  end

  describe ":json serializer" do
    test "nests each column's children as their own json" do
      json = Blocks.render(sample(), :json)

      assert %{"_type" => "columns", "layout" => "1-1", "gap" => "md", "columns" => cols} = json
      assert [%{"blocks" => left}, %{"blocks" => right}] = cols
      assert [%{"_type" => "heading", "text" => "Left"}, %{"_type" => "image"}] = left
      assert [%{"_type" => "quote", "text" => "Right"}] = right
    end
  end

  describe ":json_ld serializer" do
    test "flattens children's schema.org nodes (image contributes, heading/quote do not)" do
      nodes = Blocks.render(sample(), :json_ld)
      assert [%{"@type" => "ImageObject", "url" => "/a.png"}] = nodes
    end
  end

  describe "search_text" do
    test "concatenates the search text of every nested child" do
      text = Blocks.search_text(sample())
      assert text =~ "Left"
      assert text =~ "A"
      assert text =~ "Right"
    end
  end

  describe "BlockUnion cast" do
    test "casts a nested columns map to a Columns struct, children preserved as maps" do
      input = %{
        "_type" => "columns",
        "layout" => "2-1",
        "columns" => [
          %{"blocks" => [%{"_type" => "heading", "text" => "Hi", "level" => 2}]},
          %{"blocks" => []}
        ]
      }

      {:ok, %Ash.Union{type: :columns, value: %Columns{} = block}} =
        Ash.Type.cast_input(BlockUnion, input)

      assert block.layout == "2-1"
      assert [%{"blocks" => [child]}, %{"blocks" => []}] = block.columns
      assert child["_type"] == "heading"
      assert child["text"] == "Hi"
    end

    test "sanitizes a nested rich_text child's dangerous link href on cast" do
      body = [
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [%{"_type" => "span", "text" => "x", "marks" => ["l"]}],
          "markDefs" => [%{"_key" => "l", "_type" => "link", "href" => "javascript:alert(1)"}]
        }
      ]

      input = %{
        "_type" => "columns",
        "columns" => [%{"blocks" => [%{"_type" => "rich_text", "body" => body}]}]
      }

      {:ok, %Ash.Union{value: %Columns{columns: [%{"blocks" => [child]}]}}} =
        Ash.Type.cast_input(BlockUnion, input)

      assert [%{"markDefs" => [%{"href" => ""}]}] = child["body"]
    end
  end

  describe "TypedBlocks round-trip" do
    test "to_legacy carries the layout + child tree in data, keyed :columns" do
      assert [legacy] = TypedBlocks.to_legacy([sample()])
      assert legacy.type == :columns
      assert legacy.content == nil
      assert legacy.data["layout"] == "1-1"
      assert [%{"blocks" => _}, %{"blocks" => _}] = legacy.data["columns"]
    end

    test "to_typed re-materializes a stored typed columns map" do
      stored = %{
        "_type" => "columns",
        "layout" => "1-1",
        "columns" => [%{"blocks" => [%{"_type" => "divider"}]}]
      }

      assert [%Columns{layout: "1-1"} = block] = TypedBlocks.to_typed([stored])
      assert [%KilnCMS.Blocks.Divider{}] = Columns.child_blocks_flat(block)
    end
  end

  describe "reference extraction recurses into children" do
    test "a reference-bearing custom child inside columns is tracked" do
      block = %Columns{
        columns: [
          %{
            "blocks" => [
              %{"_type" => "custom", "data" => %{"ref" => %{"type" => "page", "id" => "p-1"}}}
            ]
          }
        ]
      }

      assert [{:page, "p-1"}] = References.extract([block])
    end
  end
end
