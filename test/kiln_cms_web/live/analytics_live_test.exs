defmodule KilnCMSWeb.AnalyticsLiveTest do
  @moduledoc """
  The analytics dashboard is editor/admin only and shows recorded view counts.
  Public delivery records a view per request.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Analytics
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "an-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  test "viewers are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:viewer)) |> live(~p"/editor/analytics")
  end

  test "editors see totals and the most-viewed content", %{conn: conn} do
    page =
      CMS.create_page!(
        %{title: "Tracked Page", slug: "ana-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Analytics.record_view!("page", page.id, authorize?: false)
    Analytics.record_view!("page", page.id, authorize?: false)

    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

    assert html =~ "Analytics"
    assert html =~ "Total views"
    assert html =~ "Tracked Page"
    assert html =~ "2"
  end

  test "visiting a published page records both a total and a daily bucket", %{conn: conn} do
    slug = "ana-#{System.unique_integer([:positive])}"

    page =
      Ash.Seed.seed!(CMS.Page, %{title: "Viewed", slug: slug, state: :published})

    # `config/test.exs` sets `:async_analytics, false`, so `track_view/3` takes
    # the *inline* branch and the delivery GET really does record on this test's
    # sandbox connection — no explicit record_view! is needed to make this pass.
    conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert Enum.any?(Analytics.list_views!(authorize?: false), &(&1.content_id == page.id))

    assert Enum.any?(
             Analytics.views_since!(Date.utc_today(), authorize?: false),
             &(&1.content_id == page.id and &1.views == 1)
           )
  end

  describe "trend range" do
    setup %{conn: conn} do
      page =
        CMS.create_page!(
          %{title: "Trend Page", slug: "ana-#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      Analytics.record_view_day!("page", page.id, authorize?: false)
      Analytics.record_view!("page", page.id, authorize?: false)

      %{conn: log_in(conn, authed_user(:editor)), page: page}
    end

    test "defaults to 30 days and marks that tab selected", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/analytics")

      assert html =~ "Views over time"
      assert html =~ ~s(aria-selected="true")
      assert html =~ "30 days"
    end

    test "?range=7 selects the 7-day window", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/analytics?range=7")

      # The sr-only data table is the accessible representation of the chart, so
      # its row count is the series length — 7 days, zero-filled.
      assert html =~ "Last 7 days"
      rows = html |> String.split("<th scope=\"row\">") |> length()
      assert rows == 8
    end

    test "an out-of-range or unparseable range falls back to the default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/analytics?range=99")
      assert html =~ "Last 30 days"

      {:ok, _lv, html} = live(conn, ~p"/editor/analytics?range=banana")
      assert html =~ "Last 30 days"
    end

    test "days with no views are zero-filled rather than dropped", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/analytics?range=7")

      # Only today has a view, so the other six days must still appear as rows.
      six_days_ago = Date.add(Date.utc_today(), -6)
      assert html =~ Date.to_iso8601(six_days_ago)
    end
  end

  # Deliberately outside the "trend range" describe: that setup records a view
  # today, which would put the window above zero and hide this state.
  test "shows an in-window empty state when every view predates the range", %{conn: conn} do
    page =
      CMS.create_page!(
        %{title: "Stale Page", slug: "ana-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    # An all-time total exists, but the only bucket is far outside the window.
    Analytics.record_view!("page", page.id, authorize?: false)

    Ash.Seed.seed!(KilnCMS.Analytics.ContentViewDay, %{
      content_type: "page",
      content_id: page.id,
      day: Date.add(Date.utc_today(), -60),
      views: 4
    })

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics?range=7")

    assert html =~ "No views in the last 7 days."
  end
end
