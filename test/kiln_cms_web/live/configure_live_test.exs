defmodule KilnCMSWeb.ConfigureLiveTest do
  @moduledoc """
  The configuration hub (`/editor/configure`, #1319).

  The hub exists because a list of names is not a map: the thing being tested
  here is that each row says what the screen is *for*, that the filter matches
  those descriptions rather than only the names, and that the operator screens
  are named as belonging to the deployment. A hub that rendered the same bare
  link list as the sidebar would pass a "does it render" test and fix nothing.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp authed_user(role) do
    email = "configure-#{System.unique_integer([:positive])}@example.com"

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

  # The sidebar names every screen too, so a hub assertion has to look inside
  # the hub's own list or it passes on the nav.
  defp carded?(lv, group, path),
    do: has_element?(lv, ~s(section#configure-group-#{group} a[href="#{path}"]))

  test "editors and viewers cannot reach it", %{conn: conn} do
    for role <- [:viewer, :editor] do
      assert {:error, {:redirect, _}} =
               conn |> log_in(authed_user(role)) |> live(~p"/editor/configure")
    end
  end

  test "it lists every configuration screen with a line saying what it is for", %{conn: conn} do
    {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    # A screen from several sections, by link AND by the description the
    # sidebar cannot carry — the descriptions are the point of the page.
    assert carded?(lv, "delivery", ~p"/editor/branding")
    assert html =~ "Name, logo, colours and the public theme."
    assert carded?(lv, "content_model", ~p"/editor/feeds")
    assert html =~ "Which types syndicate, and whether in full."
    assert carded?(lv, "operations", ~p"/editor/backups")
    assert carded?(lv, "account", ~p"/editor/settings")
  end

  test "the operator band and the per-user section each say whose they are", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    assert html =~ "Running the deployment, not just this site."
    # The confusion #1319 opened with: the one screen called "Settings" was
    # never the site's.
    assert html =~ "Yours alone"
  end

  test "the filter matches descriptions and keywords, not just names", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    # "rss" appears in no screen NAME. Before #1319 an admin looking for feed
    # settings had nothing to type.
    html = lv |> form("#configure-filter", %{q: "rss"}) |> render_change()

    assert carded?(lv, "content_model", ~p"/editor/feeds")
    refute carded?(lv, "delivery", ~p"/editor/branding")

    # The section heading survives the filter, so a match keeps its context.
    assert html =~ "Content model"
  end

  test "a filter that matches nothing says so, and clearing it restores the map", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    html = lv |> form("#configure-filter", %{q: "zzzznothing"}) |> render_change()

    assert html =~ "Nothing here matches"
    refute carded?(lv, "delivery", ~p"/editor/branding")

    lv |> form("#configure-filter", %{q: ""}) |> render_change()
    assert carded?(lv, "delivery", ~p"/editor/branding")
  end

  test "the sidebar links to the hub and marks it current", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    assert has_element?(lv, ~s(aside a.side-link[href="/editor/configure"][aria-current="page"]))
  end
end
