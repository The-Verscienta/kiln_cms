defmodule KilnCMSWeb.MenuLiveTest do
  @moduledoc """
  The navigation tree builder at `/editor/menus` (#466): creating menus, adding
  items by content reference, reordering a level, and changing depth.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "menulive-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp menu, do: CMS.create_menu!(%{key: "ml-#{uniq()}", name: "Main"}, authorize?: false)

  defp item(menu, attrs) do
    CMS.create_menu_item!(Map.merge(%{menu_id: menu.id, label: "Item"}, attrs),
      authorize?: false
    )
  end

  defp items(menu) do
    CMS.list_menu_items!(authorize?: false, query: [filter: [menu_id: menu.id]])
  end

  test "viewers are denied", %{conn: conn} do
    conn = log_in(conn, authed_user(:viewer))

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/menus")
  end

  test "an editor creates a menu and lands in its builder", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus")

    key = "ml-#{uniq()}"

    assert {:error, {:live_redirect, %{to: to}}} =
             lv
             |> form("#new-menu-form", menu: %{name: "Footer", key: key, locale: "en"})
             |> render_submit()

    [created] = CMS.list_menus!(authorize?: false, query: [filter: [key: key]])
    assert to == "/editor/menus/#{created.id}"
  end

  test "adding an item resolves the picked slug to a stable reference", %{conn: conn} do
    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "About",
        slug: "ml-#{uniq()}",
        state: :published
      })

    m = menu()
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    lv
    |> form("#new-item-form",
      item: %{label: "About", link_type: "content", target_type: "page", target_slug: page.slug}
    )
    |> render_submit()

    assert [stored] = items(m)
    assert stored.label == "About"
    assert stored.target_id == page.id
    assert stored.target_type == "page"
  end

  test "an unknown slug is refused rather than stored as a dangling item", %{conn: conn} do
    m = menu()
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    html =
      lv
      |> form("#new-item-form",
        item: %{label: "X", link_type: "content", target_type: "page", target_slug: "no-such"}
      )
      |> render_submit()

    assert html =~ "pick the content"
    assert items(m) == []
  end

  test "dragging renumbers the whole level", %{conn: conn} do
    m = menu()
    first = item(m, %{label: "First", link_type: :none, position: 0})
    second = item(m, %{label: "Second", link_type: :none, position: 1})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    render_hook(lv, "reorder_items", %{"parent_id" => "", "order" => [second.id, first.id]})

    by_id = Map.new(items(m), &{&1.id, &1.position})
    assert by_id[second.id] == 0
    assert by_id[first.id] == 1
  end

  test "indent nests under the sibling above; outdent lifts back out", %{conn: conn} do
    m = menu()
    above = item(m, %{label: "Above", link_type: :none, position: 0})
    below = item(m, %{label: "Below", link_type: :none, position: 1})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    render_click(lv, "indent_item", %{"id" => below.id})
    assert Enum.find(items(m), &(&1.id == below.id)).parent_id == above.id

    render_click(lv, "outdent_item", %{"id" => below.id})
    assert Enum.find(items(m), &(&1.id == below.id)).parent_id == nil
  end

  test "outdenting lands right after the former parent, not at the end of the level (#921)",
       %{conn: conn} do
    # Root A(0), B(1), C(2); X under A. Outdenting X must yield A, X, B, C —
    # the doc comment's own promise ("become the next sibling of the current
    # parent"). Two root items alone can't catch this: append-to-the-end and
    # insert-after-parent coincide when there's nothing after the parent.
    m = menu()
    a = item(m, %{label: "A", link_type: :none, position: 0})
    _b = item(m, %{label: "B", link_type: :none, position: 1})
    _c = item(m, %{label: "C", link_type: :none, position: 2})
    x = item(m, %{label: "X", link_type: :none, parent_id: a.id, position: 0})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    render_click(lv, "outdent_item", %{"id" => x.id})

    ordered =
      m
      |> items()
      |> Enum.filter(&is_nil(&1.parent_id))
      |> Enum.sort_by(& &1.position)
      |> Enum.map(& &1.label)

    assert ordered == ["A", "X", "B", "C"]
  end

  test "the first item in a level can't be indented — there is nothing above it", %{conn: conn} do
    m = menu()
    only = item(m, %{label: "Only", link_type: :none, position: 0})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    render_click(lv, "indent_item", %{"id" => only.id})

    assert Enum.find(items(m), &(&1.id == only.id)).parent_id == nil
  end

  # `render_level/1` builds a plain map, so the item form must not treat it as a
  # LiveView assigns map — `assign/3` raises on one, taking the whole page down.
  test "Edit opens the item form instead of crashing the page", %{conn: conn} do
    m = menu()
    only = item(m, %{label: "Section", link_type: :none})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    html = render_click(lv, "edit_item", %{"id" => only.id})

    assert html =~ "edit-item-#{only.id}"
    assert html =~ ~s(value="Section")
  end

  # A slug is unique per locale, not globally, so an unscoped lookup raises
  # `MultipleResults` the moment a page is translated.
  test "a translated slug resolves to the menu's own locale", %{conn: conn} do
    slug = "ml-#{uniq()}"

    en =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "About",
        slug: slug,
        locale: "en",
        state: :published
      })

    _fr =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "À propos",
        slug: slug,
        locale: "fr",
        state: :published
      })

    m = menu()
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    lv
    |> form("#new-item-form",
      item: %{label: "About", link_type: "content", target_type: "page", target_slug: slug}
    )
    |> render_submit()

    assert [stored] = items(m)
    assert stored.target_id == en.id
  end

  test "the delete-menu button is only offered to admins", %{conn: conn} do
    menu()

    {:ok, _lv, editor_html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus")
    refute editor_html =~ ~s(phx-click="delete_menu")

    {:ok, _lv, admin_html} =
      build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor/menus")

    assert admin_html =~ ~s(phx-click="delete_menu")
  end

  test "deleting an item takes its subtree", %{conn: conn} do
    m = menu()
    parent = item(m, %{label: "Parent", link_type: :none})
    item(m, %{label: "Child", link_type: :none, parent_id: parent.id})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

    render_click(lv, "delete_item", %{"id" => parent.id})

    assert items(m) == []
  end

  # #900. A parent cycle makes `build/3` skip the items entirely, so they vanish
  # from the served menu AND from the builder's tree — the editor sees a section
  # disappear with nothing to click, because the items aren't rendered and so
  # can't be selected, edited or outdented back.
  describe "detached items (#900)" do
    # `Ash.Seed.update!` writes the row directly: the placement validation
    # refuses this, and the issue is that two concurrent writers can each pass
    # it against pre-commit state and commit a cycle anyway.
    defp cycle(m) do
      a = item(m, %{label: "Products", link_type: :none})
      d = item(m, %{label: "Widgets", link_type: :none, parent_id: a.id})
      Ash.Seed.update!(a, %{parent_id: d.id})
      {a, d}
    end

    test "the builder surfaces them instead of showing nothing", %{conn: conn} do
      m = menu()
      item(m, %{label: "Home", link_type: :none})
      cycle(m)

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      assert html =~ "Detached items"
      assert html =~ "Products"
      assert html =~ "Widgets"
      # The healthy item still renders in the tree above.
      assert html =~ "Home"
    end

    test "a healthy menu shows no such section", %{conn: conn} do
      m = menu()
      top = item(m, %{label: "Home", link_type: :none})
      item(m, %{label: "Nested", link_type: :none, parent_id: top.id})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      refute html =~ "Detached items"
    end

    test "reattaching one brings it and its subtree back into the tree", %{conn: conn} do
      m = menu()

      # The subtree is built BEFORE the cycle is closed: once it exists, the
      # depth validation bounds its ancestor walk rather than following the
      # cycle round, so every new child under one is refused as "is nested too
      # deeply". That is itself the shape of the damage — the section is not
      # just invisible, it is unusable.
      a = item(m, %{label: "Products", link_type: :none})
      d = item(m, %{label: "Widgets", link_type: :none, parent_id: a.id})
      leaf = item(m, %{label: "Blue widget", link_type: :none, parent_id: d.id})
      Ash.Seed.update!(a, %{parent_id: d.id})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      html =
        lv
        |> element(~s(button[phx-click="reattach_item"][phx-value-id="#{a.id}"]))
        |> render_click()

      # The cycle is broken, so nothing is detached any more and the whole
      # subtree is reachable again.
      refute html =~ "Detached items"

      assert %{parent_id: nil} = CMS.get_menu_item!(a.id, authorize?: false)
      # Only the one item moved — its children keep their parents.
      assert %{parent_id: parent} = CMS.get_menu_item!(d.id, authorize?: false)
      assert parent == a.id
      assert %{parent_id: leaf_parent} = CMS.get_menu_item!(leaf.id, authorize?: false)
      assert leaf_parent == d.id

      assert KilnCMS.CMS.Menus.detached(m, KilnCMS.Accounts.default_org_id()) == []
    end

    # The `position:` half. Labels chosen so the assertion can actually fail:
    # without repositioning, the reattached item keeps position 0, ties with the
    # existing root, and the label tiebreak sorts "Alpha" ahead of "Zebra".
    test "a reattached item lands at the end of the top level", %{conn: conn} do
      m = menu()
      item(m, %{label: "Zebra", link_type: :none, position: 0})

      a = item(m, %{label: "Alpha", link_type: :none, position: 0})
      d = item(m, %{label: "Nested", link_type: :none, parent_id: a.id})
      Ash.Seed.update!(a, %{parent_id: d.id})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      lv
      |> element(~s(button[phx-click="reattach_item"][phx-value-id="#{a.id}"]))
      |> render_click()

      roots =
        items(m)
        |> Enum.filter(&is_nil(&1.parent_id))
        |> Enum.sort_by(&{&1.position, &1.label})
        |> Enum.map(& &1.label)

      assert roots == ["Zebra", "Alpha"]
    end

    # A `:url` item with a blank url, or a `:content` item whose type is gone,
    # is exactly what a restore or a direct UPDATE leaves behind — the causes
    # this section claims to cover. Running the general update's destination
    # validation on the repair would refuse it to the items that most need it,
    # with a message about links that has nothing to do with being stranded.
    test "an item whose destination no longer validates can still be rescued",
         %{conn: conn} do
      m = menu()
      a = item(m, %{label: "Products", link_type: :none})

      d =
        item(m, %{label: "Widgets", link_type: :url, url: "https://example.com", parent_id: a.id})

      Ash.Seed.update!(a, %{parent_id: d.id})
      # Blank the url behind the validation's back.
      Ash.Seed.update!(d, %{url: ""})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      lv
      |> element(~s(button[phx-click="reattach_item"][phx-value-id="#{d.id}"]))
      |> render_click()

      assert %{parent_id: nil} = CMS.get_menu_item!(d.id, authorize?: false)
    end

    # This page has no PubSub subscription, so `@detached` is only as fresh as
    # this session's own last event. A peer who repairs the cycle leaves a
    # button here that would otherwise re-root an item now sitting happily under
    # a parent — causing the damage the section exists to repair.
    test "a button left stale by a peer's repair does not re-root the item",
         %{conn: conn} do
      m = menu()
      home = item(m, %{label: "Home", link_type: :none})
      a = item(m, %{label: "Products", link_type: :none})
      d = item(m, %{label: "Widgets", link_type: :none, parent_id: a.id})
      Ash.Seed.update!(a, %{parent_id: d.id})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      assert has_element?(lv, ~s(button[phx-click="reattach_item"][phx-value-id="#{a.id}"]))

      # Out of band: a peer breaks the cycle and parks Products under Home.
      Ash.Seed.update!(a, %{parent_id: home.id})

      render_click(lv, "reattach_item", %{"id" => a.id})

      assert %{parent_id: parent} = CMS.get_menu_item!(a.id, authorize?: false)
      assert parent == home.id
    end

    # The event is client-sent and the index view assigns neither `:menu` nor
    # `:detached`, so an unguarded handler would take the LiveView down.
    test "the event is inert on the menu index", %{conn: conn} do
      m = menu()
      only = item(m, %{label: "Home", link_type: :none})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus")

      render_click(lv, "reattach_item", %{"id" => only.id})

      assert render(lv) =~ "Menus"
      assert %{parent_id: nil} = CMS.get_menu_item!(only.id, authorize?: false)
    end

    # The button only ever names a detached item, but the event is client-sent.
    # Re-parenting an attached item on request would be a way to *cause* the
    # damage this section exists to repair.
    test "an id that is not detached is refused", %{conn: conn} do
      m = menu()
      cycle(m)
      top = item(m, %{label: "Home", link_type: :none})
      nested = item(m, %{label: "Nested", link_type: :none, parent_id: top.id})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/menus/#{m.id}")

      render_click(lv, "reattach_item", %{"id" => nested.id})

      assert %{parent_id: still} = CMS.get_menu_item!(nested.id, authorize?: false)
      assert still == top.id
    end
  end
end
