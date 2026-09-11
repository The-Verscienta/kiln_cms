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

  defp authed_user(role) do
    email = "pub-live-#{role}-#{System.unique_integer([:positive])}@example.com"

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
      |> element(~s(button[phx-click="workflow"][phx-value-action="publish"]), "Publish")
      |> render_click()

      assert CMS.get_page!(page.id, actor: editor).state == :published
    end
  end

  describe "the content list" do
    test "bulk Publish follows the switch for editors", %{conn: conn} do
      editor = authed_user(:editor)
      page!(editor)
      bulk_publish = ~s(button[phx-click="bulk"][phx-value-action="publish"])

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")
      refute has_element?(lv, bulk_publish)

      allow_editors!(true)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")
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
