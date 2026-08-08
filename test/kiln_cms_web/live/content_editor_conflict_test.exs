defmodule KilnCMSWeb.ContentEditorConflictTest do
  @moduledoc """
  When another editor saves a draft first, the optimistic lock rejects this
  editor's save and the content editor shows a conflict banner (saving paused)
  with a Reload that recovers the latest version.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

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

  # A publish landing while an editor has the draft open is the race
  # `:autosave`'s row-level `state == :draft` filter exists for (#1015). The
  # LiveView's own `draft?/1` guard reads the SOCKET's record, which is still
  # the stale draft, so it calls the action — and the action refuses at the row.
  #
  # This test is here because the refusal's user-visible half is the promise the
  # fix rests on: `StaleRecord` has to keep landing in `stale_conflict?/1`, so
  # the editor prompts a reload instead of retrying and failing on every
  # keystroke.
  test "a publish landing mid-edit surfaces the same conflict banner", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Draft in flight", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

    # Typing schedules the debounce and puts the editor in `:saving`.
    lv |> form("#page-editor") |> render_change(%{"form" => %{"title" => "Still typing"}})

    # Someone else publishes — an admin, since publishing is not an editor's to
    # do. The socket still holds a `:draft` struct.
    admin =
      Ash.Seed.seed!(User, %{
        email: "conflict-admin-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, _published} = CMS.publish_page(page, %{}, actor: admin)

    # Fire the debounce the way the timer would.
    send(lv.pid, :autosave)
    html = render(lv)

    assert html =~ "This content changed elsewhere"
    assert html =~ ~r/id="edit-conflict"[^>]*role="alert"/
    assert has_element?(lv, ~s(button[type="submit"][disabled]))

    # And the autosave wrote nothing to the now-published document.
    assert CMS.get_page!(page.id, actor: editor).title == "Draft in flight"
  end

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
