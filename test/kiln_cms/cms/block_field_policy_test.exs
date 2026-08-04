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

  describe "clear by omission (#566)" do
    setup do
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [quote_block(%{"featured" => true, "text" => "featured"})])

      %{page: page, admin: admin, editor: user(:editor)}
    end

    test "an editor cannot clear an admin-set field by dropping the id and omitting it",
         %{page: page, editor: editor} do
      # The hole. Block ids do not round-trip on the headless path — `blocks` is
      # not `public?`, so a client cannot read the tree it would be preserving —
      # and once the id is gone the block reads as new, where a restricted field
      # must equal its default. Omit the field and the cast supplies exactly
      # that default, so the write looked like a no-op and silently cleared it.
      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: editor
               )

      # And the message names the actual mistake. "cannot change `featured`" is
      # unactionable advice for a client that sent no `featured` at all.
      assert Exception.message(error) =~ "cannot omit `featured`"
    end

    test "an admin may still clear it", %{page: page, admin: admin} do
      assert {:ok, updated} =
               CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: admin
               )

      assert %Ash.Union{value: %{featured: false}} = hd(updated.blocks)
    end

    test "sending the block's id is the way through", %{page: page, editor: editor} do
      # The remedy the error names has to actually work, or the fix is a wall.
      # Note it is the *id*, not the value: resubmitting `featured: true` on an
      # id-less block is still refused by the older rule (a block with no id is
      # new, and a new block must carry the default), so the message must not
      # advise that.
      stored = stored_block(page)

      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => stored.id, "text" => "edited", "featured" => true})
                   ]
                 },
                 actor: editor
               )

      assert %Ash.Union{value: %{text: "edited", featured: true}} = hd(updated.blocks)
    end

    test "the message advises the remedy that works", %{page: page, editor: editor} do
      {:error, error} =
        CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]}, actor: editor)

      assert Exception.message(error) =~ "send each block's id"
    end

    test "a page with no admin-set value is untouched", %{editor: editor} do
      # The common case, and why this is narrower than requiring ids everywhere:
      # a headless client writing ordinary content never notices.
      {:ok, plain} = create_page(user(:admin), [quote_block(%{"text" => "plain"})])

      assert {:ok, updated} =
               CMS.update_page(plain, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: editor
               )

      assert %Ash.Union{value: %{text: "edited", featured: false}} = hd(updated.blocks)
    end

    test "the check only ever refuses; it grants nothing", %{page: page, editor: editor} do
      # The design constraint, pinned. An earlier attempt paired id-less blocks
      # with stored ones by POSITION and treated that as identity — which handed
      # the featured slot to whatever new content landed in that position. A
      # block with a fresh id is unambiguously new and must carry the default,
      # before and after.
      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{
                       "id" => Ecto.UUID.generate(),
                       "text" => "editor spam",
                       "featured" => true
                     })
                   ]
                 },
                 actor: editor
               )

      assert Exception.message(error) =~ "cannot change `featured`"
    end

    test "an editor may still insert a block above the featured one",
         %{page: page, editor: editor} do
      # The regression the positional pairing caused: the new block matched no
      # id, paired with the stored featured quote by position, and was refused
      # for not carrying a value it had no business carrying.
      stored = stored_block(page)

      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"text" => "new intro"}),
                     quote_block(%{
                       "id" => stored.id,
                       "text" => "featured",
                       "featured" => true
                     })
                   ]
                 },
                 actor: editor
               )

      assert [%Ash.Union{value: %{featured: false}}, %Ash.Union{value: %{featured: true}}] =
               updated.blocks
    end

    test "the editor form's own writes are unaffected", %{page: page, editor: editor} do
      # `ContentEditorLive` and the inline-editing bridge set `blocks` directly
      # rather than passing `block_tree`, so there is no raw input and nothing
      # can have been omitted. The editor form does not render `featured` at
      # all, so a rule that fired here would be unactionable.
      stored = stored_block(page)

      assert {:ok, _updated} =
               CMS.update_page(
                 page,
                 %{
                   blocks: [
                     %{
                       "_type" => "quote",
                       "id" => stored.id,
                       "text" => "edited",
                       "featured" => true
                     }
                   ]
                 },
                 actor: editor
               )
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
