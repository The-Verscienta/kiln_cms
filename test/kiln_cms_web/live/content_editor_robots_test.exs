defmodule KilnCMSWeb.ContentEditorRobotsTest do
  @moduledoc """
  The "Hide from search engines" / "Do not follow links" toggles in the editor
  (#2256): they save through the form, they are refused to an editor whose field
  grant leaves them out, and the advisory shows in the SEO panel for a
  published, menu-linked page.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "robots-ui-#{System.unique_integer([:positive])}@example.com"

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

  defp page(attrs \\ %{}) do
    admin = authed_user(:admin)

    CMS.create_page!(
      Map.merge(%{title: "A page", slug: "rb-#{System.unique_integer([:positive])}"}, attrs),
      actor: admin
    )
  end

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  test "the toggles render and save", %{conn: conn} do
    page = page()
    {lv, html} = open_editor(conn, authed_user(:editor), page)

    assert html =~ "Hide from search engines"
    assert html =~ "Do not follow links"

    lv
    |> form("#page-editor", form: %{noindex: "true", nofollow: "true"})
    |> render_submit()

    saved = CMS.get_page!(page.id, authorize?: false)
    assert saved.noindex and saved.nofollow

    lv
    |> form("#page-editor", form: %{noindex: "false"})
    |> render_submit()

    saved = CMS.get_page!(page.id, authorize?: false)
    refute saved.noindex
    assert saved.nofollow
  end

  test "an editor whose grant leaves the flags out cannot change them", %{conn: conn} do
    page = page()
    granted = authed_user(:editor, %{field_grants: %{"page" => ["title"]}})
    {lv, _html} = open_editor(conn, granted, page)

    html =
      lv
      |> form("#page-editor", form: %{noindex: "true"})
      |> render_submit()

    refute CMS.get_page!(page.id, authorize?: false).noindex

    # The refusal is shown under the checkbox, not swallowed: the field is
    # marked invalid and its error container is rendered.
    assert has_element?(lv, "#form_noindex[aria-invalid=true]")
    assert has_element?(lv, "#form_noindex-error")
    refute has_element?(lv, "#form_nofollow-error")
  end

  test "the advisory shows for a published, menu-linked, noindex page", %{conn: conn} do
    admin = authed_user(:admin)
    page = page(%{noindex: true})
    page = CMS.publish_page!(page, actor: admin)

    menu =
      CMS.create_menu!(
        %{key: "m#{System.unique_integer([:positive])}", locale: "en", name: "Main"},
        actor: admin
      )

    CMS.create_menu_item!(
      %{
        menu_id: menu.id,
        label: "L",
        link_type: :content,
        target_type: "page",
        target_id: page.id
      },
      actor: admin
    )

    {_lv, html} = open_editor(conn, admin, page)
    assert html =~ "hidden from search engines but a menu links to it"
  end

  test "no advisory when the page is not linked from a menu", %{conn: conn} do
    admin = authed_user(:admin)
    page = CMS.publish_page!(page(%{noindex: true}), actor: admin)

    {_lv, html} = open_editor(conn, admin, page)
    refute html =~ "hidden from search engines but a menu links to it"
  end
end
