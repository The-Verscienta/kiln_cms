defmodule KilnCMS.CMS.FragmentReferenceValidationTest do
  @moduledoc """
  Write-time validation of a `KilnCMS.Blocks.Fragment`'s `ref` (#911, follow-up
  to #479): a dangling target is refused rather than saved silently, and the
  target is resolved under the ACTING actor's own read policy rather than
  `authorize?: false` — so an editor cannot reference a document their
  `readable_types` scope hides from them.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "fragref-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "fragref-#{System.unique_integer([:positive])}"

  defp fragment_ref(type, id),
    do: %{"_type" => "fragment", "ref" => %{"type" => type, "id" => id}}

  defp columns_wrapping(child),
    do: %{"_type" => "columns", "columns" => [%{"blocks" => [child]}]}

  test "a fragment referencing an existing, readable target saves cleanly" do
    admin = user(:admin)
    target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)

    assert {:ok, _page} =
             CMS.create_page(
               %{title: "Host", slug: slug(), block_tree: [fragment_ref("page", target.id)]},
               actor: admin
             )
  end

  test "a fragment referencing a nonexistent id is refused, not saved silently" do
    admin = user(:admin)
    ghost_id = Ash.UUID.generate()

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.create_page(
               %{title: "Host", slug: slug(), block_tree: [fragment_ref("page", ghost_id)]},
               actor: admin
             )

    assert Exception.message(error) =~ "does not exist or is not readable"
  end

  test "a fragment referencing a malformed id is refused, not a 500" do
    admin = user(:admin)

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.create_page(
               %{
                 title: "Host",
                 slug: slug(),
                 block_tree: [fragment_ref("page", "not-a-uuid")]
               },
               actor: admin
             )
  end

  test "a nested fragment (inside columns) is checked too" do
    admin = user(:admin)
    ghost_id = Ash.UUID.generate()

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.create_page(
               %{
                 title: "Host",
                 slug: slug(),
                 block_tree: [columns_wrapping(fragment_ref("page", ghost_id))]
               },
               actor: admin
             )

    assert Exception.message(error) =~ "does not exist or is not readable"
  end

  describe "readable_types scoping" do
    test "an editor cannot reference a DRAFT of an out-of-scope type" do
      admin = user(:admin)

      definition =
        CMS.create_type_definition!(
          %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      draft_entry =
        KilnCMS.CMS.ContentTypes.create!(
          definition.name,
          %{title: "Draft recipe", slug: slug(), blocks: []},
          actor: admin
        )

      editor = user(:editor, %{readable_types: ["post"]})

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_page(
                 %{
                   title: "Host",
                   slug: slug(),
                   block_tree: [fragment_ref(definition.name, draft_entry.id)]
                 },
                 actor: editor
               )

      assert Exception.message(error) =~ "does not exist or is not readable"
    end

    test "an editor CAN reference a PUBLISHED document of an out-of-scope type" do
      admin = user(:admin)
      target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)
      target = CMS.publish_page!(target, actor: admin)

      # readable_types never narrows PUBLISHED visibility (docs/granular-rbac.md).
      editor = user(:editor, %{readable_types: ["post"]})

      assert {:ok, _page} =
               CMS.create_page(
                 %{title: "Host", slug: slug(), block_tree: [fragment_ref("page", target.id)]},
                 actor: editor
               )
    end

    test "an admin can reference anything that exists, regardless of scope" do
      admin = user(:admin)
      target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)

      assert {:ok, _page} =
               CMS.create_page(
                 %{title: "Host", slug: slug(), block_tree: [fragment_ref("page", target.id)]},
                 actor: admin
               )
    end
  end

  test "an update introducing a dangling reference is refused too" do
    admin = user(:admin)
    ghost_id = Ash.UUID.generate()

    page = CMS.create_page!(%{title: "Host", slug: slug()}, actor: admin)

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.update_page(page, %{block_tree: [fragment_ref("page", ghost_id)]}, actor: admin)

    assert Exception.message(error) =~ "does not exist or is not readable"
  end

  test "a system write with no actor is trusted (exempt, matching EnforceBlockFieldPolicy)" do
    ghost_id = Ash.UUID.generate()

    assert {:ok, _page} =
             CMS.create_page(
               %{title: "Host", slug: slug(), block_tree: [fragment_ref("page", ghost_id)]},
               authorize?: false
             )
  end
end
