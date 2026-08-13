defmodule KilnCMS.CMS.ContentCopyTest do
  @moduledoc """
  Code-review finding #7 on PR #1250 (following #935): a block field that is
  both `required: true` and `editable_by:`-restricted cannot be reset to a
  safe default when a restricted role duplicates or translates it — nulling a
  required field now fails `TypedBlocks.validate_child!` and used to hard-fail
  the *entire* copy. `KilnCMS.FixturePlugin.RestrictedRequiredBlock`
  (test-only fixture) is the first block to combine the two, so it is what
  exercises this path; no core block does yet.
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
end
