defmodule KilnCMSWeb.ContentEditorTreeTest do
  @moduledoc """
  Setting a document's parent from the content editor (#1597, D21).

  The control is not a field on the editor's form — `parent_id` is not in
  `default_accept`, because a move is its own action — so choosing a parent
  writes straight away. The options offered are only ones the write accepts.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTree

  @password "password123456"

  defp authed_user(role) do
    email = "tree-ui-#{System.unique_integer([:positive])}@example.com"

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
      %{title: title, slug: "tui-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp open(conn, user, record),
    do: conn |> log_in(user) |> live(~p"/editor/content/page/#{record.id}")

  defp reload(record), do: CMS.get_page!(record.id, authorize?: false, tenant: record.org_id)

  test "choosing a parent moves the document immediately", %{conn: conn} do
    admin = authed_user(:admin)
    parent = page(admin, "Section")
    child = page(admin, "Leaf")

    {:ok, lv, html} = open(conn, admin, child)

    # The picker offers the other document, and says the choice writes at once.
    assert html =~ "Section"
    assert html =~ "Moving a document saves straight away"

    lv
    |> element("#parent-field select")
    |> render_change(%{"parent_id" => parent.id})

    assert reload(child).parent_id == parent.id
    assert render(lv) =~ "Moved."
  end

  test "choosing no parent returns the document to the top level", %{conn: conn} do
    admin = authed_user(:admin)
    parent = page(admin, "Section")
    child = page(admin, "Leaf")
    {:ok, child} = CMS.move_page(child, %{parent_id: parent.id}, actor: admin)

    {:ok, lv, _html} = open(conn, admin, child)

    lv
    |> element("#parent-field select")
    |> render_change(%{"parent_id" => ""})

    assert is_nil(reload(child).parent_id)
  end

  test "the document's own subtree is not offered as a parent", %{conn: conn} do
    admin = authed_user(:admin)
    root = page(admin, "Root")
    mid = page(admin, "Middle")
    {:ok, mid} = CMS.move_page(mid, %{parent_id: root.id}, actor: admin)

    {:ok, lv, _html} = open(conn, admin, root)

    # `Middle` is a descendant of the document being edited, so it must not be
    # selectable — the picker applies the same rule as the write.
    refute has_element?(lv, "#parent-field option[value='#{mid.id}']")
  end

  test "a refused move surfaces its reason rather than a generic failure", %{conn: conn} do
    admin = authed_user(:admin)
    deepest = List.last(chain(admin, ContentTree.max_depth()))
    mover = page(admin, "Mover")
    _carried = CMS.move_page!(page(admin, "Carried"), %{parent_id: mover.id}, actor: admin)

    {:ok, lv, _html} = open(conn, admin, mover)

    # Hand-sent: the picker would not offer this, which is the point — the
    # failure path has to say why rather than collapse to "couldn't move".
    html =
      lv
      |> element("#parent-field select")
      |> render_change(%{"parent_id" => deepest.id})

    assert html =~ "deeper than #{ContentTree.max_depth()} levels"
    assert is_nil(reload(mover).parent_id)
  end

  defp chain(actor, depth) do
    Enum.reduce(1..depth, [], fn i, acc ->
      record = page(actor, "C#{i}")

      case List.last(acc) do
        nil -> acc ++ [record]
        parent -> acc ++ [CMS.move_page!(record, %{parent_id: parent.id}, actor: actor)]
      end
    end)
  end
end
