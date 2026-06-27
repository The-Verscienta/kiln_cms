defmodule KilnCMSWeb.SearchPaletteLiveTest do
  @moduledoc """
  Phase E (#10): the editor search palette (`/editor/search`) runs a global
  search and links to where results are edited, and records each query.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Analytics
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "palette-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "palette-#{System.unique_integer([:positive])}"

  test "viewers are redirected away", %{conn: conn} do
    conn = log_in(conn, authed_user(:viewer))
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/search")
  end

  test "searching surfaces content with an edit link and records the query", %{conn: conn} do
    editor = authed_user(:editor)
    term = "paletteterm#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "#{term} doc", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/search")

    html = lv |> form("#palette-search", %{q: term}) |> render_change()

    assert html =~ "#{term} doc"
    assert html =~ ~p"/editor/content/page/#{page.id}"

    # The search was recorded for analytics (normalized, lowercased).
    recorded = Analytics.top_searches!(authorize?: false) |> Enum.map(& &1.query)
    assert String.downcase(term) in recorded
  end

  test "highlights the matched term in the result snippet", %{conn: conn} do
    editor = authed_user(:editor)
    term = "lighthouse#{System.unique_integer([:positive])}"
    CMS.create_page!(%{title: "Coastal #{term} guide", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/search")

    html = lv |> form("#palette-search", %{q: term}) |> render_change()

    # The matching term is wrapped in a <mark> snippet, rendered safely.
    assert html =~ "<mark>"
    assert html =~ term
  end

  test "discloses that searches are logged and the retention window (#220)", %{conn: conn} do
    editor = authed_user(:editor)
    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/search")

    days = KilnCMS.Analytics.SearchQuery.retention_days()
    assert html =~ "logged anonymously"
    assert html =~ "purged after #{days} days"
  end

  test "shows an empty state for a non-matching query", %{conn: conn} do
    editor = authed_user(:editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/search")

    html =
      lv
      |> form("#palette-search", %{q: "zzznomatch#{System.unique_integer([:positive])}"})
      |> render_change()

    assert html =~ "No results"
  end

  # #176: the search field is named and result changes are announced.
  test "labels the search field and announces results in a live region", %{conn: conn} do
    editor = authed_user(:editor)
    term = "a11ysearch#{System.unique_integer([:positive])}"
    CMS.create_page!(%{title: "#{term} doc", slug: slug()}, actor: editor)

    {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/search")

    # The input is named and points at the live status region.
    assert html =~ ~s(aria-label="Search content")
    assert html =~ ~s(aria-describedby="search-status")
    assert html =~ ~s(id="search-status")
    assert html =~ ~s(aria-live="polite")

    # After a search, the status region announces the result count.
    searched = lv |> form("#palette-search", %{q: term}) |> render_change()
    assert searched =~ "results for"
  end
end
