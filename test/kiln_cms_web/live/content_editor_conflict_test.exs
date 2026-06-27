defmodule KilnCMSWeb.ContentEditorConflictTest do
  @moduledoc """
  When another editor saves a draft first, the optimistic lock rejects this
  editor's save and the content editor shows a conflict banner (saving paused)
  with a Reload that recovers the latest version.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "conflict-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "conflict-#{System.unique_integer([:positive])}"

  test "a concurrent save surfaces a conflict banner and Reload recovers", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Shared draft", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

    # Someone else saves first, bumping lock_version out from under this editor.
    {:ok, _} = CMS.update_page(page, %{title: "Changed elsewhere"}, actor: editor)

    # This editor's save is now stale → conflict banner, no clobber.
    html = lv |> form("#page-editor") |> render_submit()
    assert html =~ "Someone else saved changes"
    # #179: the banner is announced to screen readers.
    assert html =~ ~r/id="edit-conflict"[^>]*role="alert"/
    assert CMS.get_page!(page.id, actor: editor).title == "Changed elsewhere"

    # #137: the blocked save also flashes feedback and disables the Save button.
    assert html =~ "This content changed elsewhere"
    assert has_element?(lv, ~s(button[type="submit"][disabled]))

    # Reloading clears the banner, recovers the latest version, and re-enables Save.
    reloaded = lv |> element("#edit-conflict button", "Reload latest") |> render_click()
    refute reloaded =~ "Someone else saved changes"
    assert reloaded =~ "Changed elsewhere"
    refute has_element?(lv, ~s(button[type="submit"][disabled]))
  end
end
