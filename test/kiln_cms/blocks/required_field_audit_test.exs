defmodule KilnCMS.Blocks.RequiredFieldAuditTest do
  @moduledoc """
  Code-review finding #2 on PR #1250: a row written before #935 can hold `nil`
  in a block field now declared `required: true`, and nothing on the read
  path flags it. `RequiredFieldAudit.scan_blocks/1` is the pure tree-walk this
  pins — no database needed, since it operates on whatever `cast_stored`
  already produced (a top-level `%Ash.Union{}` list with raw nested-child
  maps inside any `columns`, exactly the shape a real read hands back).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.RequiredFieldAudit

  describe "top-level blocks" do
    test "a top-level block with the required field nil is flagged" do
      blocks = [%Ash.Union{type: :claim, value: %Blocks.Claim{text: nil}}]

      assert [%{path: "blocks[0]", block_type: "claim", field: :text}] =
               RequiredFieldAudit.scan_blocks(blocks)
    end

    test "a top-level block with the required field set is not flagged" do
      blocks = [%Ash.Union{type: :claim, value: %Blocks.Claim{text: "cited"}}]

      assert [] = RequiredFieldAudit.scan_blocks(blocks)
    end
  end

  describe "nested children (the actual #935 legacy-gap shape)" do
    test "a nested child with a missing required field is flagged with its path" do
      columns_block = %Blocks.Columns{
        columns: [%{"blocks" => [%{"_type" => "claim"}]}]
      }

      blocks = [%Ash.Union{type: :columns, value: columns_block}]

      assert [%{path: path, block_type: "claim", field: :text}] =
               RequiredFieldAudit.scan_blocks(blocks)

      assert path == "blocks[0].columns[0].blocks[0]"
    end

    test "a nested child with the required field present is not flagged" do
      columns_block = %Blocks.Columns{
        columns: [%{"blocks" => [%{"_type" => "claim", "text" => "cited"}]}]
      }

      blocks = [%Ash.Union{type: :columns, value: columns_block}]

      assert [] = RequiredFieldAudit.scan_blocks(blocks)
    end

    test "the walk recurses through columns nested two deep" do
      inner = %{
        "_type" => "columns",
        "columns" => [%{"blocks" => [%{"_type" => "claim"}]}]
      }

      columns_block = %Blocks.Columns{columns: [%{"blocks" => [inner]}]}
      blocks = [%Ash.Union{type: :columns, value: columns_block}]

      assert [%{path: path, block_type: "claim", field: :text}] =
               RequiredFieldAudit.scan_blocks(blocks)

      assert path == "blocks[0].columns[0].blocks[0].columns[0].blocks[0]"
    end

    test "an unregistered nested block type is skipped, not flagged" do
      columns_block = %Blocks.Columns{
        columns: [%{"blocks" => [%{"_type" => "not_a_real_block"}]}]
      }

      blocks = [%Ash.Union{type: :columns, value: columns_block}]

      assert [] = RequiredFieldAudit.scan_blocks(blocks)
    end
  end

  test "an empty block list is not flagged" do
    assert [] = RequiredFieldAudit.scan_blocks([])
    assert [] = RequiredFieldAudit.scan_blocks(nil)
  end
end
