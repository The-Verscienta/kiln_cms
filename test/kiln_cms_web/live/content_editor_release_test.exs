defmodule KilnCMSWeb.ContentEditorReleaseTest do
  @moduledoc """
  The content editor's Release panel (#836): queue the record you are editing
  into a content release, see which release it is in, and take it back out —
  the editor-side half of "add to release", which until now existed only as a
  bulk action on the content list.

  These tests drive the panel through real clicks rather than asserting on
  markup, deliberately: the panel renders inside the page's own
  `id="page-editor"` form, and a nested `<form>` there is silently dropped by
  the HTML parser — its inputs survive, so a markup assertion passes while the
  button does nothing. Clicking is the only check that catches it.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "editrel-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

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

  defp n, do: System.unique_integer([:positive])

  defp page!(actor),
    do: CMS.create_page!(%{title: "Editable #{n()}", slug: "editrel-#{n()}"}, actor: actor)

  defp open(conn, user, page),
    do: conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")

  test "with no releases the panel points at where to make one", %{conn: conn} do
    editor = authed_user(:editor)
    page = page!(editor)

    {:ok, _lv, html} = open(conn, editor, page)

    assert html =~ "No open releases"
    assert html =~ ~s{href="/editor/releases"}
  end

  test "adding the record to a release from the editor", %{conn: conn} do
    editor = authed_user(:editor)
    rel = CMS.create_release!(%{name: "Autumn launch"}, actor: editor)
    page = page!(editor)

    {:ok, lv, html} = open(conn, editor, page)
    assert html =~ "Autumn launch"

    html = render_click(lv, "release_add")

    assert [%{content_id: content_id, action: :publish}] =
             CMS.list_release_items_for!(rel.id, authorize?: false)

    assert content_id == page.id

    # The panel now reports membership rather than offering the picker again.
    assert html =~ "Autumn launch"
    assert html =~ "Will be published when the release goes live"
    assert html =~ "Remove from release"
  end

  test "the action select is honoured", %{conn: conn} do
    editor = authed_user(:editor)
    rel = CMS.create_release!(%{name: "Takedown"}, actor: editor)
    page = page!(editor)

    {:ok, lv, _html} = open(conn, editor, page)

    render_change(lv, "release_draft_change", %{"release_action" => "unpublish"})
    html = render_click(lv, "release_add")

    assert [%{action: :unpublish}] = CMS.list_release_items_for!(rel.id, authorize?: false)
    assert html =~ "Will be unpublished when the release goes live"
  end

  test "picking a specific release when several are open", %{conn: conn} do
    editor = authed_user(:editor)
    _first = CMS.create_release!(%{name: "First"}, actor: editor)
    second = CMS.create_release!(%{name: "Second"}, actor: editor)
    page = page!(editor)

    {:ok, lv, _html} = open(conn, editor, page)

    render_change(lv, "release_draft_change", %{"release_target" => second.id})
    render_click(lv, "release_add")

    assert [%{content_id: content_id}] =
             CMS.list_release_items_for!(second.id, authorize?: false)

    assert content_id == page.id
  end

  test "removing the record from its release frees it again", %{conn: conn} do
    editor = authed_user(:editor)
    rel = CMS.create_release!(%{name: "Reversible"}, actor: editor)
    page = page!(editor)

    {:ok, lv, _html} = open(conn, editor, page)
    render_click(lv, "release_add")
    assert [_] = CMS.list_release_items_with_status!(rel.id, :pending, authorize?: false)

    html = render_click(lv, "release_remove")

    assert [] = CMS.list_release_items_with_status!(rel.id, :pending, authorize?: false)
    assert html =~ "Add to release"
  end

  test "an existing membership is shown when the editor opens the record", %{conn: conn} do
    editor = authed_user(:editor)
    rel = CMS.create_release!(%{name: "Already queued"}, actor: editor)
    page = page!(editor)

    {:ok, _item} =
      CMS.add_release_item(
        %{release_id: rel.id, content_type: "page", content_id: page.id},
        actor: editor
      )

    {:ok, _lv, html} = open(conn, editor, page)

    assert html =~ "Already queued"
    assert html =~ "Remove from release"
    assert html =~ ~s{/editor/releases/#{rel.id}}
  end

  test "a refused add surfaces the reason, not a generic failure", %{conn: conn} do
    admin = authed_user(:admin)
    editor = authed_user(:editor)

    # The page is already spoken for by another open release.
    other = CMS.create_release!(%{name: "Holds it"}, actor: admin)
    page = page!(admin)

    {:ok, _} =
      CMS.add_release_item(
        %{release_id: other.id, content_type: "page", content_id: page.id},
        actor: admin
      )

    mine = CMS.create_release!(%{name: "Wants it"}, actor: editor)
    {:ok, lv, _html} = open(conn, editor, page)

    render_change(lv, "release_draft_change", %{"release_target" => mine.id})
    html = render_click(lv, "release_add")

    assert html =~ "already in another open release"
    assert [] = CMS.list_release_items_for!(mine.id, authorize?: false)
  end

  test "a type-scoped editor never reaches the panel for out-of-scope content", %{conn: conn} do
    # Containment is one level earlier than the panel: granular RBAC (#332)
    # already hides the record from this editor's read, so the editor route
    # itself refuses. The panel's own scope check (`EditableReleaseContent`) is
    # the backstop for the API path, covered in `KilnCMS.CMS.ReleasesTest`.
    admin = authed_user(:admin)
    scoped = authed_user(:editor, %{editable_types: ["post"], readable_types: ["post"]})
    page = page!(admin)

    assert_raise Ash.Error.Invalid, fn -> open(conn, scoped, page) end
  end
end
