defmodule KilnCMSWeb.MoveToTrashTest do
  @moduledoc """
  "Move to trash" on the item itself (#2137): the content list's row menu and
  the content editor's Settings tab. Both soft-delete one document through
  `KilnCMSWeb.ContentTrash`; the soft delete itself is covered by
  `KilnCMS.CMS.ArchivalTest` and who may run it by
  `KilnCMS.CMS.ContentTypesTest`'s `can_destroy?/4` tests.

  A refused actor here is an editor: `/editor` admits only editors and admins,
  and the destroy policy is admin-only.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.EditorialSettings

  @password "password123456"

  defp authed_user(role) do
    email = "trashui-#{System.unique_integer([:positive])}@example.com"

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
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp slug, do: "trashui-#{System.unique_integer([:positive])}"

  defp page!(actor, title \\ "Trash candidate") do
    CMS.create_page!(%{title: title, slug: slug()}, actor: actor)
  end

  defp published_page!(admin, title) do
    CMS.publish_page!(page!(admin, title), %{}, actor: admin)
  end

  defp trashed?(page, admin),
    do: Enum.any?(CMS.list_trashed_pages!(actor: admin), &(&1.id == page.id))

  defp allow_editors! do
    {:ok, _} =
      EditorialSettings.save(%{editors_can_publish: true},
        actor: authed_user(:admin),
        tenant: Accounts.default_org_id()
      )
  end

  # Whether a destroy was ATTEMPTED as `actor`, not only whether one landed: a
  # refused forged event must be stopped by the handler's own check, before
  # the write, rather than reaching the destroy and relying on the policy to
  # refuse it there. Filtered to the actor, so concurrent tests can't trip it.
  # AshArchival runs the soft `:destroy` through Ash's update path, so its span
  # is `[:ash, :cms, :update, …]`; the destroy span is watched too in case that
  # ever changes.
  defp watch_destroys(actor) do
    id = "move-to-trash-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [[:ash, :cms, :update, :start], [:ash, :cms, :destroy, :start]],
        &__MODULE__.report_destroy/4,
        {self(), actor.id}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def report_destroy(_event, _measurements, %{action: :destroy, actor: %{id: id}}, {pid, id}),
    do: send(pid, :destroy_attempted)

  def report_destroy(_event, _measurements, _metadata, _config), do: :ok

  defp row_trash(kind, id), do: "#row-trash-#{kind}-#{id}"

  describe "the content list's row menu" do
    test "an admin moves a draft to the trash from the row", %{conn: conn} do
      admin = authed_user(:admin)
      page = page!(admin, "Old launch notes")
      watch_destroys(admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      item = element(lv, row_trash(:page, page.id))
      assert has_element?(lv, row_trash(:page, page.id) <> ~s([type="button"]))

      assert has_element?(
               lv,
               row_trash(:page, page.id) <>
                 ~s([data-confirm="Move “Old launch notes” to trash? Admins can restore it from Trash for 30 days."])
             )

      html = render_click(item)

      assert html =~ "Moved “Old launch notes” to trash."
      refute has_element?(lv, "#row-menu-page-#{page.id}")
      assert trashed?(page, admin)
      assert_received :destroy_attempted
    end

    test "a published row says it comes off the site, and it does", %{conn: conn} do
      admin = authed_user(:admin)
      page = published_page!(admin, "Live page")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      assert has_element?(
               lv,
               row_trash(:page, page.id) <>
                 ~s([data-confirm="Move “Live page” to trash? It comes off the live site now. Admins can restore it from Trash for 30 days, which puts it back on the site."])
             )

      lv |> element(row_trash(:page, page.id)) |> render_click()

      assert trashed?(page, admin)
      assert {:error, _} = CMS.get_published_page_by_slug(page.slug, page.locale)
    end

    test "a custom type's entry is trashed from its row", %{conn: conn} do
      admin = authed_user(:admin)

      type =
        CMS.create_type_definition!(
          %{name: "trash#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      entry = ContentTypes.create!(type.name, %{title: "Pancakes", slug: slug()}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      assert lv |> element(row_trash(type.name, entry.id)) |> render_click() =~
               "Moved “Pancakes” to trash."

      assert Enum.any?(
               ContentTypes.list_trashed!(type.name, actor: admin),
               &(&1.id == entry.id)
             )
    end

    test "trashing a selected row drops it from the selection only", %{conn: conn} do
      admin = authed_user(:admin)
      gone = page!(admin, "Goes")
      stays = page!(admin, "Stays")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      render_click(lv, "toggle_select", %{"key" => "page:#{gone.id}"})
      render_click(lv, "toggle_select", %{"key" => "page:#{stays.id}"})
      assert lv |> element("#content-selected-count") |> render() =~ "2 selected"

      lv |> element(row_trash(:page, gone.id)) |> render_click()

      assert lv |> element("#content-selected-count") |> render() =~ "1 selected"
    end

    test "an editor is not offered it, and a forged event is refused before the write",
         %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(editor)
      watch_destroys(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      assert has_element?(lv, "#row-menu-page-#{page.id}")
      refute has_element?(lv, row_trash(:page, page.id))

      assert render_click(lv, "move_to_trash", %{"kind" => "page", "id" => page.id}) =~
               "You don&#39;t have permission to do that."

      refute trashed?(page, admin)
      refute_received :destroy_attempted
    end

    test "an editor on a site that lets editors publish still may not trash", %{conn: conn} do
      allow_editors!()
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(editor)
      watch_destroys(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      # Publishing is theirs here; trashing still is not.
      assert has_element?(lv, ~s(button[phx-click="publish"][phx-value-id="#{page.id}"]))
      refute has_element?(lv, row_trash(:page, page.id))

      assert render_click(lv, "move_to_trash", %{"kind" => "page", "id" => page.id}) =~
               "You don&#39;t have permission to do that."

      refute trashed?(page, admin)
      refute_received :destroy_attempted
    end

    test "an unknown type, a missing id or a malformed one is a flash, not a crash",
         %{conn: conn} do
      admin = authed_user(:admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      for params <- [
            %{"kind" => "nosuchtype", "id" => Ecto.UUID.generate()},
            %{"kind" => "page", "id" => Ecto.UUID.generate()},
            %{"kind" => "page", "id" => "not-a-uuid"}
          ] do
        assert render_click(lv, "move_to_trash", params) =~
                 "Couldn&#39;t move that to trash. It may already be gone."
      end

      # A payload without the keys is dropped.
      render_click(lv, "move_to_trash", %{})
      assert Process.alive?(lv.pid)
    end

    test "another org's document is not found from this site", %{conn: conn} do
      admin = authed_user(:admin)
      elsewhere = KilnCMS.OrgFixtures.org("trashui-elsewhere")

      foreign =
        CMS.create_page!(%{title: "Foreign", slug: slug()}, actor: admin, tenant: elsewhere)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      assert render_click(lv, "move_to_trash", %{"kind" => "page", "id" => foreign.id}) =~
               "Couldn&#39;t move that to trash. It may already be gone."

      assert CMS.get_page!(foreign.id, actor: admin, tenant: elsewhere).id == foreign.id
    end
  end

  describe "the content editor's Settings tab" do
    test "an admin moves the document to the trash and lands on the list", %{conn: conn} do
      admin = authed_user(:admin)
      page = page!(admin, "Spring sale")
      conn = log_in(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, "#inspector-trash")

      assert has_element?(
               lv,
               ~s(#inspector-move-to-trash[type="button"][data-confirm="Move “Spring sale” to trash? Admins can restore it from Trash for 30 days."])
             )

      assert lv |> element("#inspector-trash") |> render() =~
               "Moving this to trash removes it from the content list."

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               result = lv |> element("#inspector-move-to-trash") |> render_click()

      {:ok, _list, html} = follow_redirect(result, conn)
      assert html =~ "Moved “Spring sale” to trash."
      assert trashed?(page, admin)
    end

    test "a published document says it comes off the site, and it does", %{conn: conn} do
      admin = authed_user(:admin)
      page = published_page!(admin, "Live doc")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      assert lv |> element("#inspector-trash") |> render() =~
               "Moving this to trash takes it off the live site and out of the content list."

      assert has_element?(
               lv,
               ~s(#inspector-move-to-trash[data-confirm="Move “Live doc” to trash? It comes off the live site now. Admins can restore it from Trash for 30 days, which puts it back on the site."])
             )

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               lv |> element("#inspector-move-to-trash") |> render_click()

      assert trashed?(page, admin)
      assert {:error, _} = CMS.get_published_page_by_slug(page.slug, page.locale)
    end

    # The trash is restorable, so it keeps what was on screen: text still
    # waiting for the autosave debounce is saved before the document goes.
    test "an edit waiting for autosave is saved before the trash", %{conn: conn} do
      admin = authed_user(:admin)
      page = page!(admin, "Before")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      lv |> form("#page-editor") |> render_change(%{"form" => %{"title" => "After"}})

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               lv |> element("#inspector-move-to-trash") |> render_click()

      trashed = Enum.find(CMS.list_trashed_pages!(actor: admin), &(&1.id == page.id))
      assert trashed.title == "After"
    end

    test "an edit that cannot be saved stops the trash", %{conn: conn} do
      admin = authed_user(:admin)
      page = page!(admin, "Keep me")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      lv |> form("#page-editor") |> render_change(%{"form" => %{"title" => ""}})

      html = lv |> element("#inspector-move-to-trash") |> render_click()

      assert html =~ "Couldn&#39;t save your latest changes"
      refute trashed?(page, admin)
      assert CMS.get_page!(page.id, actor: admin).title == "Keep me"
    end

    test "an editor is not offered it, and a forged event is refused before the write",
         %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(editor)
      watch_destroys(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      refute has_element?(lv, "#inspector-trash")
      refute has_element?(lv, ~s(button[phx-click="move_to_trash"]))

      assert render_click(lv, "move_to_trash", %{}) =~
               "You don&#39;t have permission to do that."

      refute trashed?(page, admin)
      refute_received :destroy_attempted
    end

    test "an editor on a site that lets editors publish still may not trash", %{conn: conn} do
      allow_editors!()
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(editor)
      watch_destroys(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      refute has_element?(lv, "#inspector-trash")

      assert render_click(lv, "move_to_trash", %{}) =~
               "You don&#39;t have permission to do that."

      refute trashed?(page, admin)
      refute_received :destroy_attempted
    end
  end
end
