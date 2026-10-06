defmodule KilnCMSWeb.EditorLiveDashboardTest do
  @moduledoc """
  The content list's dashboard chrome: the overview strip (a count per
  workflow stage, each a link to the list it counts), the bulk bar that only
  appears once something is selected, and the row — its byline, type label,
  one visible next step and the "⋯" menu holding the rest.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  @password "password123456"

  defp authed_user(role) do
    email = "dash-#{System.unique_integer([:positive])}@example.com"

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

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "dash-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(%{title: "A post", slug: "dash-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  # The number on one overview card.
  defp stat(lv, key) do
    html = lv |> element("#overview-#{key} .stat-value") |> render()
    [_, n] = Regex.run(~r/>\s*(\d+)\s*</, html)
    String.to_integer(n)
  end

  describe "overview strip" do
    test "counts each stage across types and links to the list it counts", %{conn: conn} do
      page(%{state: :draft})
      post(%{state: :draft})
      page(%{state: :in_review})
      post(%{state: :published})
      page(%{state: :draft, scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day)})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert stat(lv, "draft") == 3
      assert stat(lv, "in_review") == 1
      assert stat(lv, "scheduled") == 1
      assert stat(lv, "published") == 1

      # A card is a link to its filter, and is marked current once followed.
      lv |> element("#overview-in_review") |> render_click()
      assert_patch(lv, ~p"/editor?status=in_review")
      assert has_element?(lv, ~s(#overview-in_review[aria-current="page"]))
      refute has_element?(lv, ~s(#overview-draft[aria-current="page"]))
    end

    test "moves when a row's verb changes a record's stage", %{conn: conn} do
      draft = page(%{state: :draft, title: "Moves along"})
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      drafts = stat(lv, "draft")
      published = stat(lv, "published")

      lv
      |> element("button[phx-click='publish'][phx-value-id='#{draft.id}']")
      |> render_click()

      assert stat(lv, "draft") == drafts - 1
      assert stat(lv, "published") == published + 1
    end

    test "is not drawn on a site with no content", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert has_element?(lv, "p", "No content yet")
      refute has_element?(lv, "#content-overview")
    end
  end

  describe "bulk bar" do
    test "appears only once something is selected", %{conn: conn} do
      record = page(%{state: :draft, title: "Select me"})
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      refute has_element?(lv, "#bulk-actions")
      refute has_element?(lv, "#content-selected-count")

      lv |> element(~s(input[phx-value-key="page:#{record.id}"])) |> render_click()

      assert has_element?(lv, "#content-selected-count", "1 selected")
      assert has_element?(lv, ~s(#bulk-actions button[phx-value-action="publish"]))

      lv |> element(~s(input[phx-value-key="page:#{record.id}"])) |> render_click()
      refute has_element?(lv, "#bulk-actions")
    end
  end

  describe "rows" do
    test "carry the type's label, the author and when it was last updated", %{conn: conn} do
      admin = authed_user(:admin)
      record = page(%{state: :draft, title: "Bylined", author_id: admin.id})

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")
      row = "#page-#{record.id}"

      assert has_element?(lv, row, "Page")
      assert has_element?(lv, row, to_string(admin.email))
      assert has_element?(lv, "#{row} time", "Updated")
    end

    test "show one next step and keep the rest in the row menu", %{conn: conn} do
      record = post(%{state: :published, title: "Live one"})
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      menu = "#row-menu-post-#{record.id}"

      assert has_element?(
               lv,
               ~s(#row-menu-button-post-#{record.id}[popovertarget="row-menu-post-#{record.id}"])
             )

      assert has_element?(lv, ~s(#{menu}[popover]))
      assert has_element?(lv, ~s(#{menu} button[phx-click="unpublish"]))
      assert has_element?(lv, ~s(#{menu} button[phx-click="duplicate"]))
      assert has_element?(lv, ~s(#{menu} a[href$="?assign=1"]))

      # A menu action still runs, and closes the menu on the way.
      assert has_element?(
               lv,
               ~s(#{menu} button[phx-click="unpublish"][popovertargetaction="hide"])
             )

      lv |> element(~s(#{menu} button[phx-click="unpublish"])) |> render_click()
      assert CMS.get_post!(record.id, authorize?: false).state == :draft
    end

    test "an editor without publish rights gets Submit as the visible step", %{conn: conn} do
      record = page(%{state: :draft, title: "Editor's draft"})
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      refute has_element?(lv, "#row-menu-page-#{record.id} button[phx-click='submit']")
      assert has_element?(lv, "#page-#{record.id} button[phx-click='submit']")
      refute has_element?(lv, "#page-#{record.id} button[phx-click='publish']")
    end
  end

  test "a filter that matches nothing says so, with a way back", %{conn: conn} do
    {:ok, lv, _html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?q=no-such-title-anywhere")

    assert has_element?(lv, "#content-no-match", "Nothing matches the current filter.")
    lv |> element("#content-no-match button", "Clear filters") |> render_click()
    assert_patch(lv, ~p"/editor")
  end
end
