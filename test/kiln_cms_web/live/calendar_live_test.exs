defmodule KilnCMSWeb.CalendarLiveTest do
  @moduledoc """
  The editorial calendar (`/editor/calendar`): plots scheduled publishes,
  scheduled unpublishes (embargo ends), and go-live dates for the current
  month across content types, each chip linking to the record's editor; the
  month navigation moves the window.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "cal-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  defp slug, do: "cal-#{System.unique_integer([:positive])}"

  test "plots publish, unpublish, and went-live events with editor links", %{conn: conn} do
    admin = authed_admin()
    # Keep every fixture inside the *current* month regardless of today's date.
    middle_of_month = DateTime.new!(Date.beginning_of_month(Date.utc_today()), ~T[12:00:00])

    scheduled =
      CMS.create_page!(
        %{
          title: "Launch post #{System.unique_integer([:positive])}",
          slug: slug(),
          scheduled_at: middle_of_month
        },
        actor: admin
      )

    live_page =
      CMS.create_page!(%{title: "Live page #{System.unique_integer([:positive])}", slug: slug()},
        actor: admin
      )

    live_page = CMS.publish_page!(live_page, %{}, actor: admin)

    embargoed =
      CMS.update_page!(live_page, %{unpublish_at: middle_of_month}, actor: admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")

    assert html =~ scheduled.title
    assert html =~ embargoed.title
    # The published page contributes both a went-live and an unpublish chip.
    assert html =~ ~p"/editor/content/page/#{scheduled.id}"
    assert html =~ ~p"/editor/content/page/#{embargoed.id}"
    assert html =~ "Scheduled unpublish"
  end

  test "month navigation moves the window", %{conn: conn} do
    admin = authed_admin()
    this_month = DateTime.new!(Date.beginning_of_month(Date.utc_today()), ~T[12:00:00])

    page =
      CMS.create_page!(
        %{
          title: "Windowed #{System.unique_integer([:positive])}",
          slug: slug(),
          scheduled_at: this_month
        },
        actor: admin
      )

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")
    assert html =~ page.title

    next = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: 1)

    html =
      lv
      |> element("a[aria-label='Next month']")
      |> render_click()

    assert html =~ Calendar.strftime(next, "%B %Y")
    refute html =~ page.title
  end

  test "dynamic entries appear on the calendar", %{conn: conn} do
    admin = authed_admin()
    this_month = DateTime.new!(Date.beginning_of_month(Date.utc_today()), ~T[12:00:00])

    definition =
      CMS.create_type_definition!(
        %{name: "cal#{System.unique_integer([:positive])}", label: "Cal"},
        actor: admin
      )

    entry =
      KilnCMS.CMS.ContentTypes.create!(
        definition.name,
        %{
          title: "Dyn event #{System.unique_integer([:positive])}",
          slug: slug(),
          scheduled_at: this_month
        },
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")

    assert html =~ entry.title
    assert html =~ ~p"/editor/content/#{definition.name}/#{entry.id}"
  end
end
