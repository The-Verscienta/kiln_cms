defmodule KilnCMS.CMS.ContentTreeTest do
  @moduledoc """
  Where a document sits (#1597, decision D21 — `KilnCMS.CMS.ContentTree`).

  `parent_id` is a same-type self-reference and `position` orders siblings.
  Placement is guarded by `KilnCMS.CMS.Validations.ContentPlacement`: inside the
  writer's own organization, within `ContentTree.max_depth/0` *counting the
  subtree a move carries*, and never inside the document's own subtree.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTree

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tree-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp page(actor, attrs \\ %{}) do
    {placement, attrs} = Map.split(attrs, [:parent_id, :position])

    page =
      CMS.create_page!(
        Map.merge(
          %{
            title: "P#{System.unique_integer([:positive])}",
            slug: "t-#{System.unique_integer([:positive])}"
          },
          attrs
        ),
        actor: actor
      )

    # Placement is its own action — `parent_id`/`position` are deliberately not
    # in `default_accept`, so a create cannot set them.
    if placement == %{}, do: page, else: CMS.move_page!(page, placement, actor: actor)
  end

  # A chain `depth` deep, root first.
  defp chain(actor, depth) do
    Enum.reduce(1..depth, [], fn _i, acc ->
      parent = List.last(acc)
      acc ++ [page(actor, if(parent, do: %{parent_id: parent.id}, else: %{}))]
    end)
  end

  describe "the tree" do
    test "a document sits under a parent of its own type", %{} do
      admin = user(:admin)
      parent = page(admin)
      child = page(admin, %{parent_id: parent.id})

      assert child.parent_id == parent.id

      loaded = CMS.get_page!(parent.id, actor: admin, load: [:children])
      assert Enum.map(loaded.children, & &1.id) == [child.id]
    end

    test "children come back in position order, title breaking ties" do
      admin = user(:admin)
      parent = page(admin)

      _b = page(admin, %{parent_id: parent.id, title: "B", position: 1})
      _a = page(admin, %{parent_id: parent.id, title: "A", position: 1})
      first = page(admin, %{parent_id: parent.id, title: "Z", position: 0})

      loaded = CMS.get_page!(parent.id, actor: admin, load: [:children])

      assert Enum.map(loaded.children, & &1.title) == ["Z", "A", "B"]
      assert hd(loaded.children).id == first.id
    end

    test "position defaults to 0 rather than nil" do
      assert page(user(:admin)).position == 0
    end
  end

  describe "placement is refused when it would break the tree" do
    test "a document cannot be its own parent" do
      admin = user(:admin)
      doc = page(admin)

      assert {:error, error} = CMS.move_page(doc, %{parent_id: doc.id}, actor: admin)
      assert error_on(error, :parent_id) =~ "can't be the document itself"
    end

    test "a document cannot move under its own descendant" do
      admin = user(:admin)
      [root, _mid, leaf] = chain(admin, 3)

      assert {:error, error} = CMS.move_page(root, %{parent_id: leaf.id}, actor: admin)
      assert error_on(error, :parent_id) =~ "own children"
    end

    test "a parent in another organization is refused" do
      admin = user(:admin)

      other_org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      foreign =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Foreign",
          slug: "f-#{System.unique_integer([:positive])}",
          org_id: other_org.id
        })

      doc = page(admin)

      assert {:error, error} = CMS.move_page(doc, %{parent_id: foreign.id}, actor: admin)
      assert error_on(error, :parent_id) =~ "in this site"
    end

    test "a move is refused when the moved document's own subtree would nest too deep" do
      admin = user(:admin)
      max = ContentTree.max_depth()

      # A chain that fills the cap exactly, and a two-level subtree elsewhere.
      deepest = List.last(chain(admin, max))
      subtree_root = page(admin)
      _subtree_leaf = page(admin, %{parent_id: subtree_root.id})

      # Moving a 2-level subtree under a full-depth leaf must be refused for the
      # LEAF's sake, not just the moved node's: this is the check that counts
      # `ancestors + 1 + height`.
      assert {:error, error} =
               CMS.move_page(subtree_root, %{parent_id: deepest.id}, actor: admin)

      assert error_on(error, :parent_id) =~ "deeper than #{max} levels"
    end
  end

  describe "placement is validated on a move, not on every write" do
    test "a document at the depth cap can still be renamed and outdented" do
      admin = user(:admin)
      max = ContentTree.max_depth()
      deepest = List.last(chain(admin, max))

      # A rename does not mention `parent_id`, so placement must not re-judge it.
      assert {:ok, renamed} = CMS.update_page(deepest, %{title: "Renamed"}, actor: admin)
      assert renamed.title == "Renamed"

      # And outdenting to a root must be allowed — it is the repair path, and an
      # unconditional depth check would have made it impossible.
      assert {:ok, outdented} = CMS.move_page(renamed, %{parent_id: nil}, actor: admin)
      assert is_nil(outdented.parent_id)
    end

    test "a document at the depth cap can be reordered among its siblings" do
      admin = user(:admin)
      deepest = List.last(chain(admin, ContentTree.max_depth()))

      # `:move` that supplies only `position` is not a placement change, so the
      # depth check must not fire — otherwise the deepest row in a tree could
      # never be reordered, only outdented.
      assert {:ok, moved} = CMS.move_page(deepest, %{position: 3}, actor: admin)
      assert moved.position == 3
      assert moved.parent_id == deepest.parent_id
    end
  end

  describe "deleting a parent" do
    test "a purge leaves its children as roots rather than deleting them" do
      admin = user(:admin)
      parent = page(admin)
      child = page(admin, %{parent_id: parent.id})

      CMS.purge_page!(parent, actor: admin)

      reloaded = CMS.get_page!(child.id, actor: admin)
      assert reloaded.id == child.id
      assert is_nil(reloaded.parent_id)
    end
  end

  defp error_on(error, field) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.filter(&(Map.get(&1, :field) == field))
    |> Enum.map_join(" ", &Map.get(&1, :message, ""))
  end
end
