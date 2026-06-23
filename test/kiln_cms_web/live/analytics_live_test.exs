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

  test "visiting a published page records a view", %{conn: conn} do
    slug = "ana-#{System.unique_integer([:positive])}"

    page =
      Ash.Seed.seed!(CMS.Page, %{title: "Viewed", slug: slug, state: :published})

    conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert [%{content_type: "page", content_id: id, views: 1}] =
             Analytics.list_views!(authorize?: false)

    assert id == page.id
  end
end
