defmodule KilnCMS.CMS.ContentCopyTest do
  @moduledoc """
  Code-review finding #7 on PR #1250 (following #935): a block field that is
  both `required: true` and `editable_by:`-restricted cannot be reset to a
  safe default when a restricted role duplicates or translates it — nulling a
  required field now fails `TypedBlocks.validate_child!` and used to hard-fail
  the *entire* copy. `KilnCMS.FixturePlugin.RestrictedRequiredBlock`
  (test-only fixture) is the first block to combine the two, so it is what
  exercises this path; no core block does yet.

  Also covers two findings from the review that followed *that* fix pass:

    * finding #1 — a pre-#935 legacy row can already hold `nil` in a nested
      `columns` child's now-`required: true` field. #935 makes the
      duplicate/translate re-cast reject it outright; `dump_blocks/2` now
      drops just that stale child instead of hard-failing the whole copy.
    * finding #2 — `unsafe_reset?/2` used to drop the whole block whenever a
      required + restricted field existed, even when that field also declares
      a `default:` it could safely reset to instead.
      `KilnCMS.FixturePlugin.RestrictedRequiredDefaultBlock` is the fixture
      that combines all three.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.Translations

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "content-copy-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "content-copy-#{System.unique_integer([:positive])}"

  defp locked_page!(actor) do
    CMS.create_page!(
      %{
        title: "Locked",
        slug: slug(),
        block_tree: [
          %{"_type" => "heading", "text" => "Intro"},
          %{"_type" => "restricted_required", "locked_text" => "admin secret"}
        ]
      },
      actor: actor
    )
  end

  defp block_types(page), do: Enum.map(page.blocks, fn %Ash.Union{type: type} -> type end)

  describe "duplication" do
    test "an editor duplicating drops the unsafe block instead of hard-failing" do
      admin = user(:admin)
      editor = user(:editor)
      page = locked_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: editor)

      # The rest of the page copied normally.
      assert :heading in block_types(copy)
      # The block whose required field could not be safely reset is gone,
      # rather than the whole write refusing.
      refute :restricted_required in block_types(copy)
      assert Enum.any?(withheld, &(&1 =~ "restricted_required"))
    end

    test "an admin's duplicate keeps the block intact" do
      admin = user(:admin)
      page = locked_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: admin)

      assert :restricted_required in block_types(copy)
      assert withheld == []
    end
  end

  describe "translation" do
    test "an editor translating drops the unsafe block instead of hard-failing" do
      admin = user(:admin)
      editor = user(:editor)
      page = locked_page!(admin)

      {translation, withheld} =
        Translations.create_translation_with_notes!(:page, page, "fr", actor: editor)

      assert :heading in block_types(translation)
      refute :restricted_required in block_types(translation)
      assert Enum.any?(withheld, &(&1 =~ "restricted_required"))
    end
  end

  describe "legacy nested required-field gap (post-#1250 review finding #1, following #935)" do
    # A pre-#935 `columns` child was never cast through Ash at all, so it could
    # (and, on a real row, can still) hold `nil` in a field this codebase now
    # declares `required: true`. `Ash.Seed.seed!` does NOT reach this shape —
    # `force_change_attribute` still runs `Ash.Type.cast_input/3` for the
    # `blocks` union, so it refuses the same as a normal create would. This
    # writes a valid row through the real create action and then nulls the
    # nested field directly at the storage layer (raw SQL against the jsonb
    # column), the same way a genuinely pre-#935 row got into this state —
    # by predating the validation, not by skipping a changeset.
    defp legacy_page_with_stale_required_child! do
      page =
        CMS.create_page!(
          %{
            title: "Legacy",
            slug: slug(),
            block_tree: [
              %{
                "_type" => "columns",
                "columns" => [
                  %{
                    "blocks" => [
                      %{"_type" => "claim", "text" => "will be nulled below"},
                      %{"_type" => "quote", "text" => "still here"}
                    ]
                  }
                ]
              }
            ]
          },
          authorize?: false
        )

      Repo.query!(
        "UPDATE pages SET blocks[1] = jsonb_set(blocks[1], '{value,columns,0,blocks,0,text}', 'null') WHERE id = $1",
        [Ecto.UUID.dump!(page.id)]
      )

      CMS.get_page!(page.id, authorize?: false)
    end

    defp nested_children(record) do
      assert [%Ash.Union{type: :columns, value: columns}] = record.blocks
      assert [%{"blocks" => children}] = columns.columns
      children
    end

    test "duplicating drops only the stale-invalid nested child, not the whole write" do
      admin = user(:admin)
      page = legacy_page_with_stale_required_child!()

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: admin)

      assert [%{"_type" => "quote", "text" => "still here"}] = nested_children(copy)
      assert Enum.any?(withheld, &(&1 =~ "claim"))
    end

    test "translating drops only the stale-invalid nested child, not the whole write" do
      admin = user(:admin)
      page = legacy_page_with_stale_required_child!()

      {translation, withheld} =
        Translations.create_translation_with_notes!(:page, page, "fr", actor: admin)

      assert [%{"_type" => "quote", "text" => "still here"}] = nested_children(translation)
      assert Enum.any?(withheld, &(&1 =~ "claim"))
    end
  end

  describe "restricted required field with a declared default (post-#1250 review finding #2)" do
    defp default_locked_page!(actor) do
      CMS.create_page!(
        %{
          title: "Locked default",
          slug: slug(),
          block_tree: [
            %{"_type" => "restricted_required_default", "locked_text" => "admin secret"}
          ]
        },
        actor: actor
      )
    end

    test "an editor duplicating resets the field to its default instead of dropping the block" do
      admin = user(:admin)
      editor = user(:editor)
      page = default_locked_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: editor)

      assert [%Ash.Union{type: :restricted_required_default, value: value}] = copy.blocks
      assert value.locked_text == "redacted"
      assert Enum.any?(withheld, &(&1 =~ "restricted_required_default"))
    end

    test "an admin's duplicate keeps the admin-set value" do
      admin = user(:admin)
      page = default_locked_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: admin)

      assert [%Ash.Union{type: :restricted_required_default, value: value}] = copy.blocks
      assert value.locked_text == "admin secret"
      assert withheld == []
    end
  end
end
