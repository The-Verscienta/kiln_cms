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
end
