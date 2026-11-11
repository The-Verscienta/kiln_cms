defmodule KilnCMSWeb.ContentEditorConflictTest do
  @moduledoc """
  When another editor saves a draft first, the optimistic lock rejects this
  editor's save and the content editor shows a conflict banner (saving paused)
  with a Reload that recovers the latest version.

  When someone moves the record to the trash (or purges it) while it is open,
  every write is refused (#2332) and the banner says so instead: no Reload,
  since there is nothing to reload, the typed text kept to copy, and a way
  back to the content list.
  """
  use KilnCMSWeb.ConnCase, async: true

  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Firing.FireWorker

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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

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

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

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

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

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

  # #2532: `:restore_version` carries the optimistic lock, so a restore
  # confirmed from a session whose record someone has since saved over is
  # refused. It must read as the same conflict as a stale save, not as a
  # failed restore, and leave the typed text alone.
  test "a restore confirmed after a concurrent save shows the conflict banner", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Original", slug: slug()}, actor: editor)
    page = CMS.update_page!(page, %{title: "Revised"}, actor: editor)

    [first | _] =
      CMS.list_page_versions!(actor: editor)
      |> Enum.filter(&(&1.version_source_id == page.id))
      |> Enum.sort_by(& &1.version_inserted_at, DateTime)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    lv
    |> form("#page-editor")
    |> render_change(%{
      "form" => %{"title" => "My unsaved words"},
      "_target" => ["form", "title"]
    })

    # Someone else saves first, bumping lock_version out from under this editor.
    {:ok, _} = CMS.update_page(page, %{title: "Changed elsewhere"}, actor: editor)

    render_click(lv, "restore", %{"version_id" => first.id})
    assert has_element?(lv, "#restore-preview-dialog")
    html = render_click(lv, "confirm_restore", %{"version_id" => first.id})

    assert html =~ "This content changed elsewhere"
    refute html =~ "Restored that version."
    assert has_element?(lv, ~s(#edit-conflict[role="alert"]), "Someone else saved changes")
    assert has_element?(lv, "#edit-conflict button", "Reload latest")
    assert has_element?(lv, ~s(button[type="submit"][disabled]))
    # The person's unsaved text is still in the form.
    assert has_element?(lv, ~s(#page-editor input[name="form[title]"][value="My unsaved words"]))
    # And the row keeps the other session's save.
    assert CMS.get_page!(page.id, actor: editor).title == "Changed elsewhere"
  end

  describe "the record is moved to the trash while open (#2332)" do
    @gone "This content was moved to the trash or deleted"

    defp admin, do: authed_user(:admin)

    defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

    # Raw, so the trash's read filter does not hide the row.
    defp row(page) do
      %{rows: [[title, working_title, lock_version, archived_at]]} =
        KilnCMS.Repo.query!(
          "SELECT title, working_title, lock_version, archived_at FROM pages WHERE id = $1",
          [Ecto.UUID.dump!(page.id)]
        )

      %{
        title: title,
        working_title: working_title,
        lock_version: lock_version,
        archived_at: archived_at
      }
    end

    defp trash!(page, actor), do: CMS.destroy_page!(reload(page), actor: actor)

    defp open(conn, user, page) do
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
      lv
    end

    defp type_title(lv, title) do
      lv
      |> form("#page-editor")
      |> render_change(%{"form" => %{"title" => title}, "_target" => ["form", "title"]})
    end

    defp assert_gone_banner(lv) do
      assert has_element?(lv, ~s(#edit-conflict[role="alert"]), @gone)
      assert has_element?(lv, ~s(#edit-conflict a[href="/editor"]), "Back to content")
      refute has_element?(lv, "#edit-conflict button", "Reload latest")
      assert has_element?(lv, ~s(button[type="submit"][disabled]))
      # Its tooltip says why, not "Reload" (nothing to reload).
      assert has_element?(lv, ~s(button[type="submit"][disabled][title*="moved to the trash"]))
    end

    # Before the fix the autosave wrote the typed title into the trashed row.
    test "an autosave is refused and the banner says the content is gone", %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Before trash", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      type_title(lv, "Typed after the trash")
      trash!(page, admin)
      before = row(page)

      send(lv.pid, :autosave)
      render(lv)

      assert_gone_banner(lv)
      refute render(lv) =~ "This content changed elsewhere"
      assert row(page) == before
      assert row(page).title == "Before trash"
      # The typed text is still in the form, to copy.
      assert has_element?(lv, ~s(input[name="form[title]"][value="Typed after the trash"]))

      # And no further autosave is scheduled for a row that is not there.
      type_title(lv, "Still typing")
      assert :sys.get_state(lv.pid).socket.assigns.autosave_timer == nil
      assert row(page) == before
    end

    # Before the fix Reload raised on the trashed record and killed the editor.
    test "Reload on a record trashed after a conflict keeps the editor and the text",
         %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Shared draft", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      {:ok, _} = CMS.update_page(page, %{title: "Changed elsewhere"}, actor: admin)
      type_title(lv, "Mine")
      lv |> form("#page-editor") |> render_submit()
      assert has_element?(lv, "#edit-conflict button", "Reload latest")

      trash!(page, admin)

      html = lv |> element("#edit-conflict button", "Reload latest") |> render_click()

      assert Process.alive?(lv.pid)
      assert_gone_banner(lv)
      refute html =~ "Reloaded the latest version."
      assert has_element?(lv, ~s(input[name="form[title]"][value="Mine"]))
    end

    # Before the fix the held struct published the working copy into the
    # trashed row and re-fired its artifacts.
    test "Publish changes on a trashed live page is refused and fires nothing",
         %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Live title", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      lv = open(conn, admin, page)

      type_title(lv, "Working copy title")
      send(lv.pid, :autosave)
      render(lv)
      assert row(page).working_title == "Working copy title"

      trash!(page, admin)
      KilnCMS.DataCase.drain_oban()
      before = row(page)

      render_click(lv, "workflow", %{"action" => "publish_changes"})

      assert_gone_banner(lv)
      assert row(page) == before
      assert row(page).title == "Live title"
      refute_enqueued(worker: FireWorker, args: %{"id" => page.id})
    end

    test "a workflow transition on a trashed draft shows the gone banner", %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "To publish", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      trash!(page, admin)
      before = row(page)

      render_click(lv, "workflow", %{"action" => "publish"})

      assert_gone_banner(lv)
      assert row(page) == before
    end

    test "Mark reviewed on a trashed record shows the gone banner", %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Review me", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      trash!(page, admin)
      before = row(page)

      render_click(lv, "mark_reviewed", %{})

      assert_gone_banner(lv)
      assert row(page) == before
    end

    test "restoring a version of a trashed record shows the gone banner", %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Original", slug: slug()}, actor: admin)
      page = CMS.update_page!(page, %{title: "Revised"}, actor: admin)

      [first | _] =
        CMS.list_page_versions!(actor: admin)
        |> Enum.filter(&(&1.version_source_id == page.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      lv = open(conn, admin, page)
      render_click(lv, "restore", %{"version_id" => first.id})
      assert has_element?(lv, "#restore-preview-dialog")

      trash!(page, admin)
      before = row(page)

      render_click(lv, "confirm_restore", %{"version_id" => first.id})

      assert_gone_banner(lv)
      assert row(page) == before
      assert row(page).title == "Revised"
    end

    # Before the fix the takeover's reload raised on the trashed record.
    test "a field lock handed over after the trash does not crash the editor",
         %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Locked", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      trash!(page, admin)
      send(lv.pid, {:lock_granted, "editing:page:#{page.id}", "title"})
      render(lv)

      assert Process.alive?(lv.pid)
      assert_gone_banner(lv)
    end

    # `:destroy` refuses a row already in the trash (#2332), so the Settings
    # tab's Move to trash on a record a peer trashed first gets `StaleRecord`.
    # What was asked for is done: say so and leave, not "someone else
    # changed this item's status first".
    test "Move to trash on a record someone already trashed", %{conn: conn} do
      admin = admin()
      page = CMS.create_page!(%{title: "Trash twice", slug: slug()}, actor: admin)
      lv = open(conn, admin, page)

      trash!(page, admin)
      before = row(page)

      lv |> element("#inspector-move-to-trash") |> render_click()

      assert {"/editor", flash} = assert_redirect(lv)
      assert flash["info"] == "Someone else already moved this to the trash or deleted it."
      assert row(page) == before
    end
  end
end
