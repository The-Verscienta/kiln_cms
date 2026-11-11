defmodule KilnCMSWeb.EditorsCanPublishLiveTest do
  @moduledoc """
  The console surfaces of the "editors can publish" switch: which workflow
  controls an editor is offered in the content editor and the content list,
  the schedule field, and the Team page toggle. The policy itself is pinned in
  `KilnCMS.CMS.EditorsCanPublishTest`.

  These run on the default org, where a membership-less `role: :editor`
  account resolves to `:editor`.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.EditorialSettings

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "pub-live-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(actor) do
    CMS.create_page!(
      %{title: "Pub live", slug: "pub-live-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp allow_editors!(value) do
    {:ok, _} =
      EditorialSettings.save(%{editors_can_publish: value},
        actor: authed_user(:admin),
        tenant: Accounts.default_org_id()
      )
  end

  describe "the content editor" do
    test "while publishing needs an admin, an editor gets Submit for review and a locked date",
         %{conn: conn} do
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, ~s(button[phx-click="workflow"][phx-value-action="submit"]))
      refute has_element?(lv, ~s(button[phx-click="workflow"][phx-value-action="publish"]))
      assert has_element?(lv, ~s(input[id^="scheduled-at-local-"][disabled]))
    end

    test "where editors may publish, an editor publishes — and can still ask for review",
         %{conn: conn} do
      allow_editors!(true)
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, ~s(button[phx-click="workflow"][phx-value-action="submit"]))
      refute has_element?(lv, ~s(input[id^="scheduled-at-local-"][disabled]))

      lv
      |> element(~s(button[phx-click="workflow"][phx-value-action="publish"]), "Publish now")
      |> render_click()

      assert CMS.get_page!(page.id, actor: editor).state == :published
    end
  end

  # Taking content down is the same approval step as putting it up (#2134).
  describe "taking a live page down in the content editor" do
    defp published_page! do
      admin = authed_user(:admin)
      page!(admin) |> CMS.publish_page!(%{}, actor: admin)
    end

    @unpublish ~s(button[phx-click="workflow"][phx-value-action="unpublish"])

    test "while publishing needs an admin, an editor is offered no Unpublish and a locked unpublish date",
         %{conn: conn} do
      editor = authed_user(:editor)
      page = published_page!()

      {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      refute has_element?(lv, @unpublish)
      assert has_element?(lv, ~s(input[id^="unpublish-at-local-"][disabled]))

      assert html =~
               "Unpublishing needs an admin on this site, so an admin sets the unpublish date of a live or scheduled page."
    end

    test "with pending changes, the live-draft menu holds no Unpublish for that editor",
         %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)

      page =
        published_page!()
        |> CMS.save_page_working_copy!(%{working_title: "Held title"}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, "#publish-changes")
      assert has_element?(lv, ~s(#live-draft-menu button[phx-value-action="discard_changes"]))
      refute has_element?(lv, @unpublish)
    end

    test "a forged unpublish or archive is refused in words, and the page stays up",
         %{conn: conn} do
      editor = authed_user(:editor)
      page = published_page!()

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert render_hook(lv, "workflow", %{"action" => "unpublish"}) =~
               "Only an admin can unpublish content on this site."

      assert render_hook(lv, "workflow", %{"action" => "archive"}) =~
               "Only an admin can archive content on this site."

      assert CMS.get_page!(page.id, actor: editor).state == :published
    end

    test "the unpublish date stays open on a draft", %{conn: conn} do
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, ~s(input[id^="unpublish-at-local-"]))
      refute has_element?(lv, ~s(input[id^="unpublish-at-local-"][disabled]))
    end

    test "where editors may publish, an editor unpublishes", %{conn: conn} do
      allow_editors!(true)
      editor = authed_user(:editor)
      page = published_page!()

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      refute has_element?(lv, ~s(input[id^="unpublish-at-local-"][disabled]))
      lv |> element(@unpublish) |> render_click()

      assert CMS.get_page!(page.id, actor: editor).state == :draft
    end

    test "an admin unpublishes", %{conn: conn} do
      admin = authed_user(:admin)
      page = published_page!()

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      lv |> element(@unpublish) |> render_click()

      assert CMS.get_page!(page.id, actor: admin).state == :draft
    end
  end

  describe "the content list" do
    test "bulk Publish follows the switch for editors", %{conn: conn} do
      editor = authed_user(:editor)
      page!(editor)
      bulk_publish = ~s(button[phx-click="bulk"][phx-value-action="publish"])

      # The bulk bar only appears once something is selected.
      select_all = "input[phx-click='toggle_select_all']"

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")
      lv |> element(select_all) |> render_click()
      refute has_element?(lv, bulk_publish)

      allow_editors!(true)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")
      lv |> element(select_all) |> render_click()
      assert has_element?(lv, bulk_publish)
    end

    test "an editor allowed to publish can actually run bulk Publish", %{conn: conn} do
      allow_editors!(true)
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

      confirm =
        lv |> element("button[phx-click='bulk'][phx-value-action='publish']") |> render_click()

      assert confirm =~ "go live on the site immediately"

      lv |> element("button[phx-click='confirm_bulk']") |> render_click()

      assert CMS.get_page!(page.id, actor: editor).state == :published
    end
  end

  describe "taking content down from the content list (#2134)" do
    @select_all "input[phx-click='toggle_select_all']"
    defp bulk(verb), do: ~s(button[phx-click="bulk"][phx-value-action="#{verb}"])
    defp row_unpublish(page), do: ~s(button[phx-click="unpublish"][phx-value-id="#{page.id}"])

    test "while publishing needs an admin, an editor gets no Unpublish or Archive, and forged ones are refused",
         %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(admin) |> CMS.publish_page!(%{}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      refute has_element?(lv, row_unpublish(page))

      lv |> element(@select_all) |> render_click()
      refute has_element?(lv, bulk("unpublish"))
      refute has_element?(lv, bulk("archive"))
      assert has_element?(lv, bulk("unarchive"))

      assert render_hook(lv, "bulk", %{"action" => "unpublish"}) =~
               "Only an admin can unpublish content on this site."

      assert render_hook(lv, "bulk", %{"action" => "archive"}) =~
               "Only an admin can archive content on this site."

      refute has_element?(lv, "button[phx-click='confirm_bulk']")

      assert render_hook(lv, "unpublish", %{"kind" => "page", "id" => page.id}) =~
               "Only an admin can unpublish content on this site."

      assert CMS.get_page!(page.id, actor: admin).state == :published
    end

    test "where editors may publish, an editor gets Unpublish and Archive", %{conn: conn} do
      allow_editors!(true)
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      page = page!(admin) |> CMS.publish_page!(%{}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      assert has_element?(lv, row_unpublish(page))

      lv |> element(@select_all) |> render_click()
      assert has_element?(lv, bulk("unpublish"))
      assert has_element?(lv, bulk("archive"))

      lv |> element(row_unpublish(page)) |> render_click()
      assert CMS.get_page!(page.id, actor: admin).state == :draft
    end
  end

  # "Only an admin…" is said only where it is the reason (#2473): to an editor
  # on a site where publishing needs an admin. An editor scoped away from the
  # type, or a viewer, was told something false or no help.
  describe "refusal wording" do
    @scoped %{editable_types: ["post"]}

    test "an editor scoped away from the type is told so in the content editor, not that an admin publishes",
         %{conn: conn} do
      allow_editors!(true)
      editor = authed_user(:editor, @scoped)
      page = published_page!()

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      for action <- ~w(unpublish archive) do
        html = render_hook(lv, "workflow", %{"action" => action})
        assert html =~ "You can&#39;t edit this content type."
        refute html =~ "Only an admin"
      end

      assert CMS.get_page!(page.id, actor: editor).state == :published
    end

    test "the scope is the reason even while publishing needs an admin", %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor, @scoped)
      page = page!(admin)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      html = render_hook(lv, "workflow", %{"action" => "publish"})
      assert html =~ "You can&#39;t edit this content type."
      refute html =~ "Only an admin"
    end

    test "Return stays an admin's step for an editor where editors may publish", %{conn: conn} do
      allow_editors!(true)
      editor = authed_user(:editor)
      page = editor |> page!() |> CMS.submit_page_for_review!(%{}, actor: editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      assert render_hook(lv, "workflow", %{"action" => "return"}) =~
               "Only an admin can return content to draft."

      assert CMS.get_page!(page.id, actor: editor).state == :in_review
    end

    test "an editor scoped away from the type is told so in the content list", %{conn: conn} do
      allow_editors!(true)
      admin = authed_user(:admin)
      editor = authed_user(:editor, @scoped)
      page = page!(admin) |> CMS.publish_page!(%{}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      html = render_hook(lv, "unpublish", %{"kind" => "page", "id" => page.id})
      assert html =~ "You can&#39;t edit this content type."
      refute html =~ "Only an admin"

      assert CMS.get_page!(page.id, actor: admin).state == :published
    end
  end

  describe "the Team page" do
    test "an admin turns editor publishing on and off", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/team")

      assert has_element?(lv, "#team-toggle-publishing", "Let editors publish")

      html = lv |> element("#team-toggle-publishing") |> render_click()
      assert html =~ "Editors can now publish their own work."
      assert EditorialSettings.editors_can_publish?(Accounts.default_org_id())

      lv |> element("#team-toggle-publishing", "Require admin approval") |> render_click()
      refute EditorialSettings.editors_can_publish?(Accounts.default_org_id())
    end
  end
end
