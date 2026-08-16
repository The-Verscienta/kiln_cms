defmodule KilnCMS.CMS.NestedBlockValidationTest do
  @moduledoc """
  #935: a block nested inside a `columns` container now runs through the same
  Ash cast a top-level block already went through, so a missing `field ...,
  required: true` (`allow_nil?: false`) is refused at write time — the whole
  write fails, exactly like an invalid top-level block already did — instead
  of silently landing in storage (and delivery) as `nil`.

  `KilnCMS.CMS.TypedBlocks.sanitize_children/2` is the write-time hook (called
  from `to_union_input/1`, which every `KilnCMS.CMS.BlockUnion` cast entry
  point runs); `test/kiln/block/json_schema_test.exs` covers the read-side
  implication (the exported schema can now say a required nested field is
  non-nullable again).
  """
  use KilnCMS.DataCase, async: true

  alias Kiln.Block.Info
  alias KilnCMS.Blocks
  alias KilnCMS.CMS
  alias KilnCMS.CMS.BlockUnion

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "nested-block-validation-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "nested-block-validation-#{System.unique_integer([:positive])}"

  defp create_page(actor, blocks) do
    CMS.create_page(%{title: "Nested validation", slug: slug(), block_tree: blocks},
      actor: actor
    )
  end

  defp columns_with(child), do: %{"_type" => "columns", "columns" => [%{"blocks" => [child]}]}

  describe "BlockUnion cast (the write entry point)" do
    test "a nested heading missing its required text is refused" do
      assert {:error, _error} =
               Ash.Type.cast_input(BlockUnion, columns_with(%{"_type" => "heading"}))
    end

    test "a top-level heading missing text is refused the same way (parity check)" do
      assert {:error, _error} = Ash.Type.cast_input(BlockUnion, %{"_type" => "heading"})
    end

    test "a validly-filled nested heading is accepted" do
      nested = columns_with(%{"_type" => "heading", "text" => "hi"})

      assert {:ok, %Ash.Union{type: :columns, value: columns}} =
               Ash.Type.cast_input(BlockUnion, nested)

      assert [%{"blocks" => [%{"text" => "hi"}]}] = columns.columns
    end

    test "nesting two columns deep still catches a missing required field" do
      inner = columns_with(%{"_type" => "quote"})
      outer = columns_with(inner)

      assert {:error, _error} = Ash.Type.cast_input(BlockUnion, outer)
    end

    # The scope boundary: a type nothing registers has no embedded resource to
    # cast against, so it is left exactly as tolerant as it always was — it
    # becomes `KilnCMS.Blocks.Custom` lazily on read
    # (`TypedBlocks.struct_from_typed_map/1`), same as any other unknown
    # legacy block. That tolerance is unrelated to #935 (a required-field gap
    # on a *known* block) and this pins it deliberately, not by omission.
    test "an unregistered nested block type is left untouched" do
      nested = columns_with(%{"_type" => "not_a_real_block", "whatever" => 1})

      assert {:ok, %Ash.Union{type: :columns, value: columns}} =
               Ash.Type.cast_input(BlockUnion, nested)

      assert [%{"blocks" => [%{"_type" => "not_a_real_block"}]}] = columns.columns
    end

    # Genericity across the whole registry (#935 explicitly calls out "any
    # plugin block with a required field") — the fixture plugin's `callout`
    # block (`test/support/fixture_plugin.ex`) is registered for the test
    # suite, so it is exercised here alongside every core block. A required
    # field that ALSO declares a `default:` is excluded — omitting it casts
    # fine (the default fills in), so it is not expected to be refused;
    # `RestrictedRequiredDefaultBlock` (post-#1250 review finding #2's
    # fixture) is that case.
    test "every registered block type with an undefaulted required field is refused when nested bare" do
      for module <- Blocks.modules(),
          Enum.any?(Info.fields(module), &(&1.required and is_nil(&1.default))) do
        type = to_string(Info.name(module))
        nested = columns_with(%{"_type" => type})

        assert {:error, _error} = Ash.Type.cast_input(BlockUnion, nested),
               "#{type} (#{inspect(module)}): a bare nested child was NOT refused"
      end
    end
  end

  describe "CMS write actions (full stack)" do
    test "creating a page with an invalid nested child is refused" do
      assert {:error, error} =
               create_page(user(:admin), [columns_with(%{"_type" => "claim"})])

      # Post-#9-fix, the surfaced error is the original `Ash.Error.Changes.Required`
      # (preserved via `BlockUnion`'s rescue returning `e.errors` rather than a
      # formatted string), so it names the missing FIELD rather than the block
      # type — a client's per-field error handling now fires the same way it
      # would for an invalid top-level block.
      assert Exception.message(error) =~ "text is required"
    end

    test "creating a page with a valid nested child succeeds and stores the value" do
      assert {:ok, page} =
               create_page(user(:admin), [
                 columns_with(%{"_type" => "claim", "text" => "cited"})
               ])

      [%Ash.Union{value: columns}] = page.blocks
      assert [%{"blocks" => [%{"text" => "cited"}]}] = columns.columns
    end

    test "a plugin block with a required field is refused when nested bare" do
      assert {:error, error} =
               create_page(user(:admin), [columns_with(%{"_type" => "callout"})])

      assert Exception.message(error) =~ "text is required"
    end

    test "updating a page to introduce an invalid nested child is refused" do
      {:ok, page} =
        create_page(user(:admin), [columns_with(%{"_type" => "claim", "text" => "cited"})])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [columns_with(%{"_type" => "claim"})]},
                 actor: user(:admin)
               )

      assert Exception.message(error) =~ "text is required"
    end
  end

  describe "nested error shape (#9): the original per-field Ash error survives" do
    # `BlockUnion`'s rescue used to collapse a nested validation failure into a
    # bare formatted string, which Ash then wrapped as one generic
    # `Ash.Error.Changes.InvalidAttribute` scoped to `field: :blocks` — losing
    # which nested field, on which resource, actually failed. Returning the
    # original exception list instead lets Ash's own error-class machinery
    # preserve it, same as a top-level failure already gets.
    test "the underlying Ash.Error.Changes.Required is preserved, not a generic :blocks error" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               create_page(user(:admin), [columns_with(%{"_type" => "claim"})])

      assert [%Ash.Error.Changes.Required{field: :text, resource: KilnCMS.Blocks.Claim}] = errors
    end
  end

  describe "nested child type coercion (the cast result is kept, not discarded)" do
    # `KilnCMS.Blocks.Heading.level` is `:integer`; a string `"3"` is a value a
    # form post or a loose API client sends. A top-level block already coerces
    # it through `Ash.Type.Union.cast_input`; this pins the nested one to the
    # same behavior — `cast_child!` used to run the cast only to check it
    # succeeded and then return the original, un-coerced `attrs`, so a nested
    # heading kept the string forever (`columns.columns` is untyped
    # `{:array, :map}`, so nothing downstream ever re-cast it).
    test "a nested heading's string level is coerced to an integer, matching a top-level one" do
      {:ok, top} =
        create_page(user(:admin), [%{"_type" => "heading", "text" => "hi", "level" => "3"}])

      {:ok, nested} =
        create_page(user(:admin), [
          columns_with(%{"_type" => "heading", "text" => "hi", "level" => "3"})
        ])

      assert [%Ash.Union{value: %{level: 3}}] = top.blocks
      assert [%Ash.Union{value: columns}] = nested.blocks
      assert [%{"blocks" => [%{"level" => 3}]}] = columns.columns
    end
  end

  describe "BlockUnion rescue clause coverage (post-#1250 review finding #5)" do
    # `:blocks` is stored as `{:array, BlockUnion}`, so every real CMS write
    # (create/update) dispatches through `cast_input_array/2`/
    # `prepare_change_array/3` — already covered above (the "CMS write
    # actions"/"nested error shape" describes). `cast_input/2` and
    # `prepare_change/3` (the *singular*, non-array clauses) are `@impl Ash.Type`
    # callbacks the array attribute never reaches, so nothing in the "full
    # stack" tests exercises their rescue bodies at all — pinned directly here
    # instead, so a future refactor can't silently turn them back into the
    # old formatted-string rescue (or drop the rescue) with nothing to catch it.
    test "cast_input/2's rescue returns the original error list, not a formatted string" do
      assert {:error, [%Ash.Error.Changes.Required{field: :text}]} =
               Ash.Type.cast_input(BlockUnion, columns_with(%{"_type" => "claim"}))
    end

    test "prepare_change/3's list clause rescue returns the original error list" do
      assert {:error, [%Ash.Error.Changes.Required{field: :text}]} =
               Ash.Type.prepare_change(
                 BlockUnion,
                 nil,
                 [columns_with(%{"_type" => "claim"})],
                 []
               )
    end

    test "prepare_change/3's fallback (non-list) clause rescue returns the original error list" do
      assert {:error, [%Ash.Error.Changes.Required{field: :text}]} =
               Ash.Type.prepare_change(BlockUnion, nil, columns_with(%{"_type" => "claim"}), [])
    end
  end
end
