defmodule KilnCMSWeb.CalendarLiveTest do
  @moduledoc """
  The editorial calendar (`/editor/calendar`): plots scheduled publishes,
  embargo ends, go-lives, review-due dates, task due dates and release
  go-lives, each chip linking to its record; the navigation moves the window,
  the view switch changes how it is drawn, and the filters narrow it.

  The projection itself is tested in `KilnCMS.CMS.CalendarTest` — these are the
  assertions that only hold once it is rendered.
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

  test "a task's due date shows a chip linking to its content (#501)", %{conn: conn} do
    admin = authed_admin()
    this_month_middle = Date.beginning_of_month(Date.utc_today()) |> Date.add(14)

    page =
      CMS.create_page!(
        %{title: "Task-due page #{System.unique_integer([:positive])}", slug: slug()},
        actor: admin
      )

    CMS.assign_task!(
      %{
        content_type: "page",
        content_id: page.id,
        assignee_id: admin.id,
        due_on: this_month_middle
      },
      actor: admin
    )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")

    assert html =~ page.title
    assert html =~ ~p"/editor/content/page/#{page.id}"
    assert html =~ "Task due"
  end

  describe "views" do
    test "the view switch renders week and list, and keeps the anchor", %{conn: conn} do
      admin = authed_admin()
      # Anchor mid-month so a week window around it stays inside the month.
      at = Date.beginning_of_month(Date.utc_today()) |> Date.add(14)

      page =
        CMS.create_page!(
          %{
            title: "Anchored #{System.unique_integer([:positive])}",
            slug: slug(),
            scheduled_at: DateTime.new!(at, ~T[09:00:00])
          },
          actor: admin
        )

      {:ok, lv, _html} =
        conn |> log_in(admin) |> live(~p"/editor/calendar?at=#{Date.to_iso8601(at)}")

      week = lv |> element("a", "Week") |> render_click()
      assert week =~ page.title
      # The week view shows times; the month grid does not.
      assert week =~ "09:00"

      list = lv |> element("a", "List") |> render_click()
      assert list =~ page.title
    end

    test "the week navigation steps seven days, not a month", %{conn: conn} do
      admin = authed_admin()
      at = Date.beginning_of_month(Date.utc_today()) |> Date.add(7)

      page =
        CMS.create_page!(
          %{
            title: "Thisweek #{System.unique_integer([:positive])}",
            slug: slug(),
            scheduled_at: DateTime.new!(at, ~T[09:00:00])
          },
          actor: admin
        )

      {:ok, lv, html} =
        conn |> log_in(admin) |> live(~p"/editor/calendar?view=week&at=#{Date.to_iso8601(at)}")

      assert html =~ page.title

      # The control announces itself as a week step, and moving one week forward
      # leaves this week's chip behind.
      moved = lv |> element("a[aria-label='Next week']") |> render_click()
      refute moved =~ page.title
    end

    test "an empty window renders the empty state, not a blank grid", %{conn: conn} do
      admin = authed_admin()
      # Far enough out that no other test's fixture can land in the window.
      far = Date.utc_today() |> Date.shift(year: 3)

      {:ok, _lv, html} =
        conn
        |> log_in(admin)
        |> live(~p"/editor/calendar?view=list&at=#{Date.to_iso8601(far)}")

      assert html =~ "Nothing scheduled in this window"
    end
  end

  describe "lifecycle lanes" do
    test "an overdue record plots a review-due chip carrying its health", %{conn: conn} do
      admin = authed_admin()

      page =
        CMS.create_page!(
          %{
            title: "Stale #{System.unique_integer([:positive])}",
            slug: slug(),
            review_after_days: 5
          },
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)

      # Published 20 days ago on a 5-day cadence: due 15 days ago, so overdue.
      page
      |> Ash.Changeset.for_update(:backdate_published_at, %{
        published_at: DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)
      })
      |> Ash.update!(authorize?: false)

      at = DateTime.utc_now() |> DateTime.add(-15 * 86_400, :second) |> DateTime.to_date()

      {:ok, _lv, html} =
        conn
        |> log_in(admin)
        |> live(~p"/editor/calendar?view=list&at=#{Date.to_iso8601(at)}")

      assert html =~ page.title
      assert html =~ "Overdue"
    end

    test "a flagged expiry reads as expired rather than as an unpublish", %{conn: conn} do
      admin = authed_admin()
      yesterday = DateTime.add(DateTime.utc_now(), -86_400, :second)

      page =
        CMS.create_page!(
          %{
            title: "Notice #{System.unique_integer([:positive])}",
            slug: slug(),
            expiry_action: :flag
          },
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)
      page = CMS.update_page!(page, %{unpublish_at: yesterday}, actor: admin)

      at = DateTime.to_date(yesterday)

      {:ok, _lv, html} =
        conn
        |> log_in(admin)
        |> live(~p"/editor/calendar?view=list&at=#{Date.to_iso8601(at)}")

      assert html =~ page.title
      assert html =~ "Expired"
    end
  end

  describe "filters" do
    test "the health filter narrows the grid and survives in the URL", %{conn: conn} do
      admin = authed_admin()

      this_month =
        DateTime.new!(Date.beginning_of_month(Date.utc_today()) |> Date.add(3), ~T[09:00:00])

      plain =
        CMS.create_page!(
          %{
            title: "Plain #{System.unique_integer([:positive])}",
            slug: slug(),
            scheduled_at: this_month
          },
          actor: admin
        )

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")
      assert html =~ plain.title

      filtered =
        lv
        |> form("form[phx-change='filter']", %{"health" => "overdue"})
        |> render_change()

      refute filtered =~ plain.title

      # Query order is the router's, not the caller's — assert the pairs.
      assert_patched(
        lv,
        ~p"/editor/calendar?at=#{Date.to_iso8601(Date.utc_today())}&health=overdue&view=month"
      )
    end

    test "an unknown filter value shows everything rather than nothing", %{conn: conn} do
      admin = authed_admin()

      this_month =
        DateTime.new!(Date.beginning_of_month(Date.utc_today()) |> Date.add(3), ~T[09:00:00])

      page =
        CMS.create_page!(
          %{
            title: "Unfiltered #{System.unique_integer([:positive])}",
            slug: slug(),
            scheduled_at: this_month
          },
          actor: admin
        )

      {:ok, _lv, html} =
        conn |> log_in(admin) |> live(~p"/editor/calendar?kind=not_a_lane")

      assert html =~ page.title
    end
  end

  describe "live updates" do
    test "a lifecycle write elsewhere refreshes an open calendar", %{conn: conn} do
      admin = authed_admin()
      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")

      title = "Latecomer #{System.unique_integer([:positive])}"
      refute html =~ title

      # A write that happens outside this LiveView entirely — the broadcast is
      # attached to the action, not to the editor's event handlers.
      CMS.create_page!(
        %{
          title: title,
          slug: slug(),
          scheduled_at:
            DateTime.new!(Date.beginning_of_month(Date.utc_today()) |> Date.add(3), ~T[09:00:00])
        },
        actor: admin
      )

      assert render(lv) =~ title
    end
  end
end
