defmodule KilnCMS.CMS.BlockFieldPolicyTest do
  @moduledoc """
  Server-side enforcement of `Kiln.Block` `editable_by` field policies (#51).

  `KilnCMS.Blocks.Quote` declares `field :featured, editable_by: [:admin]`. The
  rule used to be enforced only by the content editor filtering the fields it
  renders, so these tests drive the *resource*, which is the boundary every
  non-form write path (write API `block_tree`, MCP, GraphQL) shares.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "block-policy-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "block-policy-#{System.unique_integer([:positive])}"

  defp quote_block(attrs), do: Map.merge(%{"_type" => "quote", "text" => "body"}, attrs)

  defp create_page(actor, blocks) do
    CMS.create_page(%{title: "Blocks", slug: slug(), block_tree: blocks}, actor: actor)
  end

  # The stored block with its id, so an update can address the same block.
  defp stored_block(page) do
    [%Ash.Union{value: block}] = page.blocks
    block
  end

  describe "create" do
    test "an editor cannot create a block with an admin-only field set" do
      assert {:error, error} =
               create_page(user(:editor), [quote_block(%{"featured" => true})])

      assert Exception.message(error) =~ "featured"
    end

    test "an editor can create a block that leaves the admin-only field at its default" do
      assert {:ok, page} = create_page(user(:editor), [quote_block(%{})])
      assert stored_block(page).featured == false
    end

    test "an admin can create a block with the admin-only field set" do
      assert {:ok, page} = create_page(user(:admin), [quote_block(%{"featured" => true})])
      assert stored_block(page).featured == true
    end
  end

  describe "update" do
    setup do
      admin = user(:admin)
      {:ok, page} = create_page(admin, [quote_block(%{"featured" => true})])
      %{admin: admin, page: page, block: stored_block(page)}
    end

    test "an editor cannot flip an admin-only field on an existing block", %{
      page: page,
      block: block
    } do
      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => block.id, "text" => "edited", "featured" => false})
                   ]
                 },
                 actor: user(:editor)
               )

      assert Exception.message(error) =~ "featured"
    end

    test "an editor may edit other fields while resubmitting the unchanged admin-only value",
         %{page: page, block: block} do
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => block.id, "text" => "edited", "featured" => true})
                   ]
                 },
                 actor: user(:editor)
               )

      assert stored_block(updated).text == "edited"
      assert stored_block(updated).featured == true
    end

    test "an admin may flip the admin-only field", %{page: page, block: block, admin: admin} do
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{block_tree: [quote_block(%{"id" => block.id, "featured" => false})]},
                 actor: admin
               )

      assert stored_block(updated).featured == false
    end

    test "a metadata-only update is untouched by the check", %{page: page} do
      assert {:ok, updated} = CMS.update_page(page, %{title: "Renamed"}, actor: user(:editor))
      assert updated.title == "Renamed"
      assert stored_block(updated).featured == true
    end
  end

  describe "nesting" do
    test "an editor cannot smuggle an admin-only field through a columns child" do
      nested = [
        %{
          "_type" => "columns",
          "columns" => [%{"blocks" => [quote_block(%{"featured" => true})]}]
        }
      ]

      assert {:error, error} = create_page(user(:editor), nested)
      assert Exception.message(error) =~ "featured"
    end

    test "an editor may nest a block that leaves the admin-only field alone" do
      nested = [
        %{
          "_type" => "columns",
          "columns" => [%{"blocks" => [quote_block(%{})]}]
        }
      ]

      assert {:ok, _page} = create_page(user(:editor), nested)
    end
  end

  describe "system writes" do
    test "an actor-less write is exempt" do
      assert {:ok, page} =
               CMS.create_page(
                 %{
                   title: "System",
                   slug: slug(),
                   block_tree: [quote_block(%{"featured" => true})]
                 },
                 authorize?: false
               )

      assert stored_block(page).featured == true
    end
  end
end
