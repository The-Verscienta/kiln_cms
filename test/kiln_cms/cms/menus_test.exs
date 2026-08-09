defmodule KilnCMS.CMS.MenusTest do
  @moduledoc """
  Editor-managed navigation (#466): the tree's write-time guards (destination,
  depth, cycles) and the delivery-time resolution that turns stored references
  into live URLs and drops what a reader may not see.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Menus

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "menu-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  defp menu(actor, attrs \\ %{}) do
    CMS.create_menu!(
      Map.merge(%{key: "main-#{uniq()}", name: "Main", locale: "en"}, attrs),
      actor: actor
    )
  end

  defp item(actor, menu, attrs) do
    CMS.create_menu_item!(Map.merge(%{menu_id: menu.id, label: "Item"}, attrs), actor: actor)
  end

  defp published_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.Page,
      Map.merge(%{title: "P", slug: "mp-#{uniq()}", state: :published}, attrs)
    )
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  describe "destinations" do
    test "a content item stores a reference and resolves to the target's live URL" do
      actor = user(:editor)
      page = published_page()
      menu = menu(actor)

      item(actor, menu, %{
        label: "About",
        link_type: :content,
        target_type: "page",
        target_id: page.id
      })

      assert {:ok, _menu, [node]} = Menus.resolve(menu.key, "en", org_id())
      assert node.label == "About"
      assert node.url == "/#{page.slug}"
    end

    test "renaming the target's slug moves the menu with it — no stale link" do
      actor = user(:editor)
      page = published_page()
      menu = menu(actor)

      item(actor, menu, %{
        label: "About",
        link_type: :content,
        target_type: "page",
        target_id: page.id
      })

      renamed = CMS.update_page!(page, %{slug: "mp-#{uniq()}"}, authorize?: false)

      assert {:ok, _menu, [node]} = Menus.resolve(menu.key, "en", org_id())
      assert node.url == "/#{renamed.slug}"
    end

    test "a URL item is sanitized on write, and a javascript: link is refused" do
      actor = user(:editor)
      menu = menu(actor)

      ok = item(actor, menu, %{label: "Docs", link_type: :url, url: "https://example.com/docs"})
      assert ok.url == "https://example.com/docs"

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_menu_item(
                 %{
                   menu_id: menu.id,
                   label: "Trap",
                   link_type: :url,
                   url: "javascript:alert(1)"
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "enter a link"
    end

    test "switching link_type clears the destination it no longer uses" do
      actor = user(:editor)
      page = published_page()
      menu = menu(actor)

      linked =
        item(actor, menu, %{
          label: "About",
          link_type: :content,
          target_type: "page",
          target_id: page.id
        })

      switched =
        CMS.update_menu_item!(linked, %{link_type: :url, url: "https://example.com"},
          actor: actor
        )

      assert switched.url == "https://example.com"
      assert is_nil(switched.target_id)
      assert is_nil(switched.target_type)
    end

    test "a content item needs a target, and a known content type" do
      actor = user(:editor)
      menu = menu(actor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_menu_item(%{menu_id: menu.id, label: "X", link_type: :content},
                 actor: actor
               )

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_menu_item(
                 %{
                   menu_id: menu.id,
                   label: "X",
                   link_type: :content,
                   target_type: "nope",
                   target_id: Ash.UUID.generate()
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "content type"
    end

    test "a label-only item carries no link at all" do
      actor = user(:editor)
      menu = menu(actor)
      item(actor, menu, %{label: "Section", link_type: :none})

      assert {:ok, _menu, [node]} = Menus.resolve(menu.key, "en", org_id())
      assert node.url == nil
    end
  end

  describe "visibility" do
    test "an item pointing at unpublished content is omitted for delivery" do
      actor = user(:editor)
      draft = Ash.Seed.seed!(KilnCMS.CMS.Page, %{title: "D", slug: "mp-#{uniq()}", state: :draft})
      menu = menu(actor)

      item(actor, menu, %{
        label: "Coming soon",
        link_type: :content,
        target_type: "page",
        target_id: draft.id
      })

      assert {:ok, _menu, []} = Menus.resolve(menu.key, "en", org_id())

      # …but the editor's own view still shows it, or it couldn't be edited.
      assert [%{label: "Coming soon"}] = Menus.tree(menu, org_id(), include_hidden?: true)
    end

    test "an editor-hidden item is omitted even when its target is published" do
      actor = user(:editor)
      page = published_page()
      menu = menu(actor)

      item(actor, menu, %{
        label: "Hidden",
        link_type: :content,
        target_type: "page",
        target_id: page.id,
        visible: false
      })

      assert {:ok, _menu, []} = Menus.resolve(menu.key, "en", org_id())
    end

    test "a dropped parent takes its children with it, rather than promoting them" do
      actor = user(:editor)
      draft = Ash.Seed.seed!(KilnCMS.CMS.Page, %{title: "D", slug: "mp-#{uniq()}", state: :draft})
      page = published_page()
      menu = menu(actor)

      parent =
        item(actor, menu, %{
          label: "Section",
          link_type: :content,
          target_type: "page",
          target_id: draft.id
        })

      item(actor, menu, %{
        label: "Child",
        parent_id: parent.id,
        link_type: :content,
        target_type: "page",
        target_id: page.id
      })

      assert {:ok, _menu, []} = Menus.resolve(menu.key, "en", org_id())
    end
  end

  describe "the tree" do
    test "children nest under their parent, in position order" do
      actor = user(:editor)
      menu = menu(actor)

      parent = item(actor, menu, %{label: "Parent", link_type: :none, position: 0})
      item(actor, menu, %{label: "Second", link_type: :none, parent_id: parent.id, position: 1})
      item(actor, menu, %{label: "First", link_type: :none, parent_id: parent.id, position: 0})

      assert {:ok, _menu, [node]} = Menus.resolve(menu.key, "en", org_id())
      assert Enum.map(node.children, & &1.label) == ["First", "Second"]
    end

    test "an item can't be its own parent, or its own descendant" do
      actor = user(:editor)
      menu = menu(actor)

      root = item(actor, menu, %{label: "Root", link_type: :none})
      child = item(actor, menu, %{label: "Child", link_type: :none, parent_id: root.id})

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_menu_item(root, %{parent_id: root.id}, actor: actor)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_menu_item(root, %{parent_id: child.id}, actor: actor)

      assert Exception.message(error) =~ "own children"
    end

    # Checking only the moved node's ancestor chain would accept this and land
    # the subtree's leaves below max_depth — where they then can't be moved back.
    test "re-parenting a subtree counts the levels it brings with it" do
      actor = user(:editor)
      m = menu(actor)

      root = item(actor, m, %{label: "Root", link_type: :none})
      mid = item(actor, m, %{label: "Mid", link_type: :none, parent_id: root.id})
      _leaf = item(actor, m, %{label: "Leaf", link_type: :none, parent_id: mid.id})

      sibling = item(actor, m, %{label: "Sibling", link_type: :none})

      # `root` is three levels tall; nesting it under a root sibling would put
      # `leaf` at depth four.
      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_menu_item(root, %{parent_id: sibling.id}, actor: actor)

      assert Exception.message(error) =~ "nest deeper"
    end

    # A depth check that fired on every write would freeze a too-deep row: the
    # editor couldn't rename it, and couldn't outdent it either.
    test "an edit that doesn't move the item is never a placement failure" do
      actor = user(:editor)
      m = menu(actor)

      root = item(actor, m, %{label: "Root", link_type: :none})
      mid = item(actor, m, %{label: "Mid", link_type: :none, parent_id: root.id})
      leaf = item(actor, m, %{label: "Leaf", link_type: :none, parent_id: mid.id})

      assert {:ok, renamed} = CMS.update_menu_item(leaf, %{label: "Renamed"}, actor: actor)
      assert renamed.label == "Renamed"

      # …and it can still be lifted back out.
      assert {:ok, lifted} = CMS.update_menu_item(renamed, %{parent_id: root.id}, actor: actor)
      assert lifted.parent_id == root.id
    end

    test "nesting stops at max_depth" do
      actor = user(:editor)
      menu = menu(actor)

      deepest =
        Enum.reduce(1..KilnCMS.CMS.MenuItem.max_depth(), nil, fn i, parent ->
          item(actor, menu, %{label: "L#{i}", link_type: :none, parent_id: parent && parent.id})
        end)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_menu_item(
                 %{menu_id: menu.id, label: "Too deep", link_type: :none, parent_id: deepest.id},
                 actor: actor
               )

      assert Exception.message(error) =~ "nest deeper"
    end

    test "an item can't be parented into a different menu" do
      actor = user(:editor)
      one = menu(actor)
      other = menu(actor, %{key: "other-#{uniq()}"})

      elsewhere = item(actor, other, %{label: "Elsewhere", link_type: :none})

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_menu_item(
                 %{menu_id: one.id, label: "X", link_type: :none, parent_id: elsewhere.id},
                 actor: actor
               )

      assert Exception.message(error) =~ "different menu"
    end
  end

  describe "localization" do
    test "variants share a key and differ by locale; a missing locale is a miss" do
      actor = user(:editor)
      key = "nav-#{uniq()}"

      en = menu(actor, %{key: key, locale: "en", name: "Main"})
      _fr = menu(actor, %{key: key, locale: "fr", name: "Principal"})

      item(actor, en, %{label: "Home", link_type: :none})

      assert {:ok, %{name: "Principal"}, []} = Menus.resolve(key, "fr", org_id())
      assert {:ok, %{name: "Main"}, [%{label: "Home"}]} = Menus.resolve(key, "en", org_id())

      # No fallback: an unbuilt locale returns nothing rather than the wrong nav.
      assert :not_found = Menus.resolve(key, "es", org_id())
    end

    test "one key + locale pair may only exist once" do
      actor = user(:editor)
      key = "nav-#{uniq()}"
      menu(actor, %{key: key, locale: "en"})

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_menu(%{key: key, name: "Dupe", locale: "en"}, actor: actor)
    end
  end

  describe "gated content" do
    # `Menus` reads with `authorize?: false`, so its filter is the whole security
    # boundary — the sitemap and the feeds both exclude gated content, and nav
    # has to agree.
    test "a members-only page is omitted from anonymous navigation" do
      actor = user(:editor)

      gated =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Members",
          slug: "mp-#{uniq()}",
          state: :published,
          audience: :member
        })

      m = menu(actor)

      item(actor, m, %{
        label: "Members area",
        link_type: :content,
        target_type: "page",
        target_id: gated.id
      })

      assert {:ok, _menu, []} = Menus.resolve(m.key, "en", org_id())

      # A caller that has established the reader holds the tier can widen it.
      assert {:ok, _menu, [%{label: "Members area"}]} =
               Menus.resolve(m.key, "en", org_id(), audiences: [:public, :member])
    end
  end

  describe "authorization" do
    test "a viewer can read menus but not write them" do
      admin = user(:admin)
      viewer = user(:viewer)
      menu = menu(admin)

      assert CMS.list_menus!(actor: viewer) != []

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_menu(%{key: "x-#{uniq()}", name: "X"}, actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_menu(menu, %{name: "Renamed"}, actor: viewer)
    end

    test "deleting a menu is admin-only, and takes its items with it" do
      admin = user(:admin)
      editor = user(:editor)
      menu = menu(admin)
      item(admin, menu, %{label: "Item", link_type: :none})

      assert {:error, %Ash.Error.Forbidden{}} = CMS.destroy_menu(menu, actor: editor)
      assert :ok = CMS.destroy_menu(menu, actor: admin)
      assert CMS.list_menu_items!(authorize?: false) == []
    end
  end

  # #900. `build/3` descends from the roots and emits each item under its single
  # parent, so an item in a parent cycle renders nowhere — it and its subtree
  # vanish from the served menu and from the editor's own tree, with no error and
  # no row deleted. `detached/2` is what makes that recoverable.
  #
  # The cycle is written with `Ash.Seed.update!`, which goes straight to the row:
  # `Validations.MenuItemPlacement` refuses this at the write, and the point of
  # the issue is that two concurrent writers can each pass that validation
  # against pre-commit state and commit one anyway.
  describe "detached items (#900)" do
    test "a parent cycle is reported, and its members are absent from the tree" do
      actor = user(:editor)
      menu = menu(actor)

      a = item(actor, menu, %{label: "A", link_type: :none})
      d = item(actor, menu, %{label: "D", link_type: :none, parent_id: a.id})
      kept = item(actor, menu, %{label: "Top", link_type: :none})

      # A.parent_id = D, completing A → D → A.
      Ash.Seed.update!(a, %{parent_id: d.id})

      detached = Menus.detached(menu, org_id())
      assert Enum.map(detached, & &1.label) |> Enum.sort() == ["A", "D"]

      # And they really are missing from the tree, which is the damage.
      assert [%{label: "Top"}] = Menus.tree(menu, org_id(), include_hidden?: true)
      refute Enum.find(detached, &(&1.id == kept.id))
    end

    test "a child of a cycle member is detached too" do
      actor = user(:editor)
      menu = menu(actor)

      a = item(actor, menu, %{label: "A", link_type: :none})
      d = item(actor, menu, %{label: "D", link_type: :none, parent_id: a.id})
      leaf = item(actor, menu, %{label: "Leaf", link_type: :none, parent_id: d.id})

      Ash.Seed.update!(a, %{parent_id: d.id})

      assert Menus.detached(menu, org_id()) |> Enum.map(& &1.label) |> Enum.sort() ==
               ["A", "D", "Leaf"]

      assert Menus.tree(menu, org_id(), include_hidden?: true) == []
      assert leaf.parent_id == d.id
    end

    test "a healthy menu reports nothing, hidden and unpublished items included" do
      actor = user(:editor)
      menu = menu(actor)

      top = item(actor, menu, %{label: "Top", link_type: :none})
      item(actor, menu, %{label: "Nested", link_type: :none, parent_id: top.id})
      # Hidden, and a :content item whose target is a draft: both are legitimately
      # absent from a rendered tree and neither is detached — `detached/2` asks a
      # structural question, not a visibility one.
      item(actor, menu, %{label: "Hidden", link_type: :none, visible: false})

      draft = Ash.Seed.seed!(KilnCMS.CMS.Page, %{title: "D", slug: "md-#{uniq()}", state: :draft})

      item(actor, menu, %{
        label: "Draft target",
        link_type: :content,
        target_type: "page",
        target_id: draft.id
      })

      assert Menus.detached(menu, org_id()) == []
    end

    # A `parent_id` pointing at a row that does not exist is impossible — the
    # foreign key refuses it, verified by `Ash.Seed.update!` raising "would leave
    # records behind". What the key does *not* require is that the parent share
    # this item's menu, and nothing renders through a parent in another tree.
    test "an item parented outside this menu is detached" do
      actor = user(:editor)
      menu = menu(actor)
      elsewhere = menu(actor, %{key: "other-#{uniq()}"})

      foreign_parent = item(actor, elsewhere, %{label: "Elsewhere", link_type: :none})
      orphan = item(actor, menu, %{label: "Orphan", link_type: :none})
      Ash.Seed.update!(orphan, %{parent_id: foreign_parent.id})

      assert [%{label: "Orphan"}] = Menus.detached(menu, org_id())
      # And the other menu is unaffected — this is not a global scan.
      assert Menus.detached(elsewhere, org_id()) == []
    end

    test "a long chain terminates rather than recursing forever" do
      actor = user(:editor)
      menu = menu(actor)

      # Three in a ring: the walk must stop on the revisit, not on a depth cap.
      a = item(actor, menu, %{label: "A", link_type: :none})
      b = item(actor, menu, %{label: "B", link_type: :none, parent_id: a.id})
      c = item(actor, menu, %{label: "C", link_type: :none, parent_id: b.id})
      Ash.Seed.update!(a, %{parent_id: c.id})

      assert Menus.detached(menu, org_id()) |> Enum.map(& &1.label) |> Enum.sort() ==
               ["A", "B", "C"]
    end
  end
end
