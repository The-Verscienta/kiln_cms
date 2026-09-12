defmodule KilnCMSWeb.ConfigureLiveTest do
  @moduledoc """
  The configuration hub (`/editor/configure`, #1319).

  The hub exists because a list of names is not a map: the thing being tested
  here is that each row says what the screen is *for*, that the filter matches
  those descriptions rather than only the names, and that the operator screens
  are marked as belonging to the deployment rather than to the site. A hub that
  rendered the same bare link list as the sidebar would pass a "does it render"
  test and fix nothing.
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

  test "editors and viewers cannot reach it", %{conn: conn} do
    for role <- [:viewer, :editor] do
      assert {:error, {:redirect, _}} =
               conn |> log_in(authed_user(role)) |> live(~p"/editor/configure")
    end
  end

  test "it lists every configuration screen with a line saying what it is for", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    # A screen from each group, by name AND by the description the sidebar
    # cannot carry — the descriptions are the point of the page.
    assert html =~ "Branding"
    assert html =~ "Name, logo, colours and the public theme."
    assert html =~ "Content types"
    assert html =~ "Feeds"
    assert html =~ "Which types syndicate, and whether in full."
    assert html =~ "Backups"
    assert html =~ ~p"/editor/branding"
    assert html =~ ~p"/editor/system"
  end

  test "operator screens are named as belonging to the deployment", %{conn: conn} do
    {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    assert html =~ "Operations"
    assert html =~ "Running the deployment, rather than authoring this site."

    # The badge is per screen, because the section is not uniform: Backups is
    # deployment-wide, Governance — sitting right beside it — is this site's own
    # audit record. A heading-level badge would have lied about one of them.
    badged? = &has_element?(lv, "#configure-card-#{&1} span", "This deployment")
    assert badged?.(:backups)
    refute badged?.(:governance)

    # And the per-user group says whose it is, which is the confusion #1319
    # opened with: the one screen called "Settings" was never the site's.
    assert html =~ "Yours alone"
  end

  # The sidebar names every screen too, so a filter assertion has to look inside
  # the hub's own list or it passes on the nav.
  defp carded?(lv, group, path),
    do: has_element?(lv, ~s(section#configure-group-#{group} a[href="#{path}"]))

  test "the filter matches descriptions and keywords, not just names", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    # "rss" appears in no screen NAME. Before #1319 an admin looking for feed
    # settings had nothing to type.
    html = lv |> form("#configure-filter", %{q: "rss"}) |> render_change()

    assert carded?(lv, "model", ~p"/editor/feeds")
    refute carded?(lv, "site", ~p"/editor/branding")

    # The group heading survives the filter, so a match keeps its context.
    assert html =~ "Content model"
  end

  test "a filter that matches nothing says so", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    html = lv |> form("#configure-filter", %{q: "zzzznothing"}) |> render_change()

    assert html =~ "Nothing here matches"
    refute carded?(lv, "site", ~p"/editor/branding")

    # Clearing it brings everything back.
    lv |> form("#configure-filter", %{q: ""}) |> render_change()
    assert carded?(lv, "site", ~p"/editor/branding")
  end

  test "the sidebar links to the hub, and its groups are collapsible", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

    assert has_element?(lv, ~s(aside a.side-link[href="/editor/configure"]))

    # Each Configure section head is a real button wired to the group it owns
    # (app.js keys the collapse off `data-nav-toggle`).
    assert has_element?(
             lv,
             ~s(aside button.side-section[data-nav-toggle="model"][aria-controls="side-group-model"])
           )

    # The operator group is drawn apart from the site-level ones.
    assert has_element?(lv, ~s(aside .side-group-instance[data-nav-group="operations"]))
    refute has_element?(lv, ~s(aside .side-group-instance[data-nav-group="site"]))
  end
end
