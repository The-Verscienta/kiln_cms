defmodule KilnCMSWeb.ReleaseLiveTest do
  @moduledoc """
  The release console (`/editor/releases`, #500): composing a release, the
  editor/admin split on the controls that actually ship content, "Add to
  release" from the content list, and the shared preview link.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "releaselive-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "releaselive-#{System.unique_integer([:positive])}"

  defp release(actor, name \\ "Spring campaign") do
    CMS.create_release!(%{name: name}, actor: actor)
  end

  test "an editor creates a release and lands on it", %{conn: conn} do
    editor = authed_user(:editor)
    {:ok, view, _html} = conn |> log_in(editor) |> live(~p"/editor/releases")

    view
    |> form("#new-release-form",
      release: %{name: "Autumn launch", description: "Homepage + posts"}
    )
    |> render_submit()

    assert_redirect(view)
    assert [%{name: "Autumn launch"}] = CMS.list_releases!(actor: editor)
  end

  test "the show page lists items with their content resolved", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin)
    page = CMS.create_page!(%{title: "Landing page", slug: slug()}, actor: admin)

    {:ok, _item} =
      CMS.add_release_item(
        %{release_id: rel.id, content_type: "page", content_id: page.id},
        actor: admin
      )

    {:ok, _view, html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")

    assert html =~ "Landing page"
    assert html =~ "Publish now"
  end

  test "an editor sees no shipping controls on a release", %{conn: conn} do
    editor = authed_user(:editor)
    rel = release(editor)

    {:ok, _view, html} = conn |> log_in(editor) |> live(~p"/editor/releases/#{rel.id}")

    refute html =~ "Publish now"
    assert html =~ "need admin access"
  end

  test "an admin publishes a release from the console", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin)
    page = CMS.create_page!(%{title: "Ship me", slug: slug()}, actor: admin)

    {:ok, _} =
      CMS.add_release_item(
        %{release_id: rel.id, content_type: "page", content_id: page.id},
        actor: admin
      )

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")
    render_click(view, "publish_now", %{})
    KilnCMS.DataCase.drain_oban()

    assert CMS.get_release!(rel.id, authorize?: false).state == :published
    assert CMS.get_page!(page.id, authorize?: false).state == :published
  end

  test "the readiness panel flags an item that cannot publish", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin)
    page = CMS.create_page!(%{title: "Archived thing", slug: slug()}, actor: admin)
    {:ok, archived} = CMS.archive_page(page, %{}, actor: admin)

    {:ok, _} =
      CMS.add_release_item(
        %{release_id: rel.id, content_type: "page", content_id: archived.id},
        actor: admin
      )

    {:ok, _view, html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")

    assert html =~ "cannot be published from archived"
  end

  test "the preview link is minted on request and opens the release preview", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin, "Preview me")
    page = CMS.create_page!(%{title: "Previewed page", slug: slug()}, actor: admin)

    {:ok, _} =
      CMS.add_release_item(
        %{release_id: rel.id, content_type: "page", content_id: page.id},
        actor: admin
      )

    {:ok, view, html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")
    refute html =~ "/preview/release/"

    html = render_click(view, "share_preview", %{})
    assert [_, token] = Regex.run(~r{/preview/release/([A-Za-z0-9_.\-]+)}, html)

    {:ok, _preview, preview_html} = live(build_conn(), ~p"/preview/release/#{token}")
    assert preview_html =~ "Preview me"
    assert preview_html =~ "Previewed page"
  end

  test "an expired or forged release preview token shows a dead link, never content" do
    assert {:ok, _view, html} = live(build_conn(), ~p"/preview/release/not-a-real-token")
    assert html =~ "expired"
  end

  test "add to release from the content list", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin, "Bulk target")
    page = CMS.create_page!(%{title: "Bulk added", slug: slug()}, actor: admin)

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/editor")

    render_click(view, "toggle_select", %{"key" => "page:#{page.id}"})
    render_click(view, "open_release_panel", %{})

    html =
      view
      |> form("#add-to-release", %{"release_id" => rel.id, "release_action" => "publish"})
      |> render_submit()

    assert html =~ "Added 1 item"

    assert [%{content_id: content_id, action: :publish}] =
             CMS.list_release_items_for!(rel.id, authorize?: false)

    assert content_id == page.id
  end

  test "a scheduled release shows up on the editorial calendar", %{conn: conn} do
    admin = authed_user(:admin)
    rel = release(admin, "Calendar release")
    at = DateTime.add(DateTime.utc_now(), 60 * 60)
    {:ok, _} = CMS.schedule_release(rel, %{scheduled_at: at}, actor: admin)

    month = Calendar.strftime(at, "%Y-%m")
    {:ok, _view, html} = conn |> log_in(admin) |> live(~p"/editor/calendar?month=#{month}")

    assert html =~ "Calendar release"
    assert html =~ "Release go-live"
  end
end
