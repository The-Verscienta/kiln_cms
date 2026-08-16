defmodule KilnCMS.Blocks.RequiredFieldAuditTest do
  @moduledoc """
  Code-review finding #2 on PR #1250: a row written before #935 can hold `nil`
  in a block field now declared `required: true`, and nothing on the read
  path flags it. `RequiredFieldAudit.scan_blocks/1` is the pure tree-walk this
  pins — no database needed, since it operates on whatever `cast_stored`
  already produced (a top-level `%Ash.Union{}` list with raw nested-child
  maps inside any `columns`, exactly the shape a real read hands back).

  The "database-backed" describe block below covers a follow-up finding (#3
  on the review of PR #1250 itself): `run/1`'s `stream_records/2` query path —
  tenant scoping, the `:blocks` select — had no coverage at all, only the pure
  `scan_blocks/1` walk above. A wiring bug there (wrong tenant, a resource not
  loading `:blocks`) would make the tool report false-clean and nothing would
  catch it.
  """
  use KilnCMS.DataCase, async: true

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

  describe "run/1 (database-backed, finding #3 on the review of PR #1250 itself)" do
    defp org_id, do: KilnCMS.Accounts.default_org_id()

    defp slug, do: "required-field-audit-#{System.unique_integer([:positive])}"

    test "finds a legacy nested required-field gap through the real query path" do
      # `Ash.Seed.seed!` does not reach this shape (`force_change_attribute`
      # still casts the `blocks` union, so it refuses a bare nested `claim`
      # exactly as a normal create would) — write a valid row through the real
      # create action and null the nested field directly at the storage layer,
      # the same way a genuinely pre-#935 row got into this state.
      page =
        KilnCMS.CMS.create_page!(
          %{
            title: "Legacy audit target",
            slug: slug(),
            block_tree: [
              %{
                "_type" => "columns",
                "columns" => [%{"blocks" => [%{"_type" => "claim", "text" => "will be nulled"}]}]
              }
            ]
          },
          authorize?: false,
          tenant: org_id()
        )

      Repo.query!(
        "UPDATE pages SET blocks[1] = jsonb_set(blocks[1], '{value,columns,0,blocks,0,text}', 'null') WHERE id = $1",
        [Ecto.UUID.dump!(page.id)]
      )

      violations = RequiredFieldAudit.run(org_id: org_id())
      assert [violation] = Enum.filter(violations, &(&1.record_id == page.id))

      assert violation.org_id == org_id()
      assert violation.type == :page
      assert violation.block_type == "claim"
      assert violation.field == :text
      assert violation.path == "blocks[0].columns[0].blocks[0]"
    end

    test "a page with no violations is not flagged" do
      {:ok, page} =
        KilnCMS.CMS.create_page(
          %{title: "Clean", slug: slug(), block_tree: [%{"_type" => "heading", "text" => "hi"}]},
          authorize?: false,
          tenant: org_id()
        )

      violations = RequiredFieldAudit.run(org_id: org_id())
      assert Enum.filter(violations, &(&1.record_id == page.id)) == []
    end
  end
end
