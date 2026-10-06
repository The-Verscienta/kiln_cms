defmodule KilnCMSWeb.StructureLiveTest do
  @moduledoc """
  The content tree for one type (#1597, D21) at `/editor/structure/:type`.

  Drag reorders a level; indent/outdent change depth. Every change writes
  through `:move`, so the placement rules are the action's, not the page's.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTree

  @password "password123456"

  defp authed_user(role) do
    email = "struct-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  defp page(actor, title) do
    CMS.create_page!(
      %{title: title, slug: "st-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp reload(record), do: CMS.get_page!(record.id, authorize?: false, tenant: record.org_id)

  defp open(conn, user), do: conn |> log_in(user) |> live(~p"/editor/structure/page")

  test "lists the tree and links each document to its editor", %{conn: conn} do
    admin = authed_user(:admin)
    parent = page(admin, "Section")
    child = CMS.move_page!(page(admin, "Leaf"), %{parent_id: parent.id}, actor: admin)

    {:ok, lv, html} = open(conn, admin)

    assert html =~ "Section"
    assert html =~ "Leaf"
    # One sortable list per level, which is what lets the hook report a parent.
    assert has_element?(lv, "#structure-level-root")
    assert has_element?(lv, "#structure-level-#{parent.id}")
    assert has_element?(lv, ~s(a[href="/editor/content/page/#{child.id}"]))
  end

  test "dragging renumbers the level it was dropped in", %{conn: conn} do
    admin = authed_user(:admin)
    a = page(admin, "A")
    b = page(admin, "B")

    {:ok, lv, _html} = open(conn, admin)

    lv
    |> element("#structure-level-root")
    |> render_hook("reorder_items", %{"parent_id" => "", "order" => [b.id, a.id]})

    assert reload(b).position == 0
    assert reload(a).position == 1
  end

  test "an id from another level is ignored rather than trusted", %{conn: conn} do
    admin = authed_user(:admin)
    parent = page(admin, "Section")
    child = CMS.move_page!(page(admin, "Leaf"), %{parent_id: parent.id}, actor: admin)
    root = page(admin, "Root")

    {:ok, lv, _html} = open(conn, admin)

    # `child` belongs to another level. A client that sends it must not get its
    # position rewritten against the root level.
    before = reload(child).position

    lv
    |> element("#structure-level-root")
    |> render_hook("reorder_items", %{"parent_id" => "", "order" => [child.id, root.id]})

    assert reload(child).position == before
    assert reload(child).parent_id == parent.id
  end

  test "indent makes a document the child of the sibling above it", %{conn: conn} do
    admin = authed_user(:admin)
    above = page(admin, "Above")
    below = page(admin, "Below")

    {:ok, lv, _html} = open(conn, admin)

    lv |> element(~s(button[phx-click="indent"][phx-value-id="#{below.id}"])) |> render_click()

    assert reload(below).parent_id == above.id
  end

  test "the first sibling cannot be indented — there is nothing above it", %{conn: conn} do
    admin = authed_user(:admin)
    first = page(admin, "First")
    _second = page(admin, "Second")

    {:ok, lv, _html} = open(conn, admin)

    assert has_element?(
             lv,
             ~s(button[phx-click="indent"][phx-value-id="#{first.id}"][disabled])
           )
  end

  test "outdent makes a document the next sibling of its parent", %{conn: conn} do
    admin = authed_user(:admin)
    top = page(admin, "Top")
    mid = CMS.move_page!(page(admin, "Mid"), %{parent_id: top.id}, actor: admin)
    leaf = CMS.move_page!(page(admin, "Leaf"), %{parent_id: mid.id}, actor: admin)

    {:ok, lv, _html} = open(conn, admin)

    lv |> element(~s(button[phx-click="outdent"][phx-value-id="#{leaf.id}"])) |> render_click()

    # Up one level: a sibling of `mid`, so a child of `top`.
    assert reload(leaf).parent_id == top.id
  end

  test "a root document offers no outdent", %{conn: conn} do
    admin = authed_user(:admin)
    root = page(admin, "Root")

    {:ok, lv, _html} = open(conn, admin)

    refute has_element?(lv, ~s(button[phx-click="outdent"][phx-value-id="#{root.id}"]))
  end

  test "indent is refused at the depth cap, with the reason", %{conn: conn} do
    admin = authed_user(:admin)
    max = ContentTree.max_depth()

    # A full-depth chain, plus a sibling of the deepest that could be indented
    # into it if the cap were not enforced.
    chain =
      Enum.reduce(1..max, [], fn i, acc ->
        record = page(admin, "C#{i}")

        case List.last(acc) do
          nil -> acc ++ [record]
          parent -> acc ++ [CMS.move_page!(record, %{parent_id: parent.id}, actor: admin)]
        end
      end)

    deepest = List.last(chain)
    sibling = CMS.move_page!(page(admin, "Sib"), %{parent_id: deepest.parent_id}, actor: admin)

    {:ok, lv, _html} = open(conn, admin)

    # The button is disabled at the cap, so this is the hand-sent path — and it
    # must be refused by the action with its reason, not merely by the UI.
    html =
      lv
      |> render_hook("indent", %{"id" => sibling.id})

    assert html =~ "deeper than #{max} levels"
    assert reload(sibling).parent_id == deepest.parent_id
  end

  describe "orphan detection (#1597)" do
    defp menu_linking(actor, record) do
      menu =
        CMS.create_menu!(
          %{key: "sm#{System.unique_integer([:positive])}", locale: "en", name: "Main"},
          actor: actor
        )

      CMS.create_menu_item!(
        %{
          menu_id: menu.id,
          label: "L",
          link_type: :content,
          target_type: "page",
          target_id: record.id
        },
        actor: actor
      )
    end

    test "a published document in no menu is badged and counted", %{conn: conn} do
      admin = authed_user(:admin)
      orphan = CMS.publish_page!(page(admin, "Orphan"), %{}, actor: admin)

      {:ok, lv, html} = open(conn, admin)

      assert html =~ "Not in any menu"
      assert html =~ "1 published document is in no menu."
      assert has_element?(lv, ~s([data-sort-id="#{orphan.id}"]), "Not in any menu")
    end

    test "a published document a menu links to is not badged", %{conn: conn} do
      admin = authed_user(:admin)
      linked = CMS.publish_page!(page(admin, "Linked"), %{}, actor: admin)
      menu_linking(admin, linked)

      {:ok, _lv, html} = open(conn, admin)

      refute html =~ "Not in any menu"
    end

    test "a draft in no menu is not badged — that is a draft's normal state", %{conn: conn} do
      admin = authed_user(:admin)
      _draft = page(admin, "Draft")

      {:ok, _lv, html} = open(conn, admin)

      refute html =~ "Not in any menu"
    end
  end

  test "an unknown type goes back to the list rather than crashing", %{conn: conn} do
    admin = authed_user(:admin)

    assert {:error, {:live_redirect, %{to: "/editor"}}} =
             conn |> log_in(admin) |> live(~p"/editor/structure/nope")
  end
end
