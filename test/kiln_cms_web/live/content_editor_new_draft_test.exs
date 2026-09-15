defmodule KilnCMSWeb.ContentEditorNewDraftTest do
  @moduledoc """
  "New page" opens the editor on an unsaved document at
  `/editor/content/:type/new`. Nothing is written until the writer commits —
  a non-blank title or Save — and then exactly one row is created, through the
  same create action and authorization as before, and the same LiveView
  carries on at `/editor/content/:type/:id` (a patch, not a remount).
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.ContentTypes

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "new-draft-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
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

  defp pages(actor), do: ContentTypes.list!("page", actor: actor)

  defp type_title(lv, title) do
    render_change(lv, "validate", %{"form" => %{"title" => title}, "_target" => ["form", "title"]})
  end

  setup %{conn: conn} do
    editor = authed_user(:editor)
    %{conn: log_in(conn, editor), editor: editor}
  end

  test "New on the content list opens the unsaved editor without writing a row",
       %{conn: conn, editor: editor} do
    {:ok, index, _html} = live(conn, ~p"/editor")

    assert {:error, {:live_redirect, %{to: "/editor/content/page/new"}}} =
             index
             |> element(~s{button[phx-click="new"][phx-value-kind="page"]})
             |> render_click()

    assert pages(editor) == []
  end

  test "visiting /new creates nothing, and says when it will", %{conn: conn, editor: editor} do
    {:ok, lv, html} = live(conn, ~p"/editor/content/page/new")

    assert html =~ "New page"
    assert has_element?(lv, ~s{form#page-editor input[name="form[title]"]})
    assert has_element?(lv, "#new-draft-status")
    # No id-bound features on a document that does not exist yet.
    refute has_element?(lv, ~s{button[phx-click="duplicate"]})
    refute has_element?(lv, ~s{[role="tablist"]})

    # Leaving (browser back, closing the tab) is just the process ending.
    assert pages(editor) == []
  end

  test "a blank title is not a commit", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "   ")

    assert pages(editor) == []
    assert has_element?(lv, "#new-draft-status")
  end

  test "the first title keystroke creates exactly one row and patches to its edit route",
       %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "Hello kiln")

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")

    # The same LiveView carried on into the full editor with the typed title,
    # and the scaffold slug re-derived from it.
    assert has_element?(lv, ~s{input[name="form[title]"][value="Hello kiln"]})
    assert has_element?(lv, ~s{input[name="form[slug]"][value="hello-kiln"]})
    assert has_element?(lv, ~s{[role="tablist"]})
    refute has_element?(lv, "#new-draft-status")
    assert has_element?(lv, ~s{form#page-editor[data-dirty="true"]})
  end

  test "rapid changes after the first create no second row", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "H")
    type_title(lv, "He")
    type_title(lv, "Hel")

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    assert has_element?(lv, ~s{input[name="form[title]"][value="Hel"]})
  end

  test "Save on a blank new document creates the untitled draft", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    html = lv |> form("#page-editor", %{"form" => %{"title" => ""}}) |> render_submit()

    assert [page] = pages(editor)
    assert page.title == "Untitled page"
    assert page.slug =~ ~r/^untitled-/
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    assert html =~ "Saved."
  end

  test "Save with a title creates the row and saves the title", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    lv |> form("#page-editor", %{"form" => %{"title" => "Saved at once"}}) |> render_submit()

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    saved = ContentTypes.get_record!("page", page.id, actor: editor)
    assert saved.title == "Saved at once"
    # Derived from the saved title, stop words stripped — the slug a writer
    # typing the same title would have got.
    assert saved.slug == "saved-once"
  end

  test "an editor who may not author the type is refused at the door, and nothing is written",
       %{conn: conn} do
    # Scoped to author posts only: pages are not offered on the content list,
    # and the create policy (`Checks.EditableContentType`) refuses them.
    post_only = authed_user(:editor, %{editable_types: ["post"]})
    conn = log_in(conn, post_only)

    {:ok, index, html} = live(conn, ~p"/editor")
    refute html =~ ~s{phx-value-kind="page"}
    _ = index

    assert {:error, {:live_redirect, %{to: "/editor", flash: flash}}} =
             live(conn, ~p"/editor/content/page/new")

    assert flash["error"] =~ "can't create"
    assert pages(authed_user(:admin)) == []
  end

  test "an unknown type goes back to the content list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/editor"}}} =
             live(conn, ~p"/editor/content/no-such-type/new")
  end
end
