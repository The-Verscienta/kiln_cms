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

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin, do: authed_user(:admin)
  defp authed_viewer, do: authed_user(:viewer)

  defp authed_user(role, extra \\ %{}) do
    email = "cal-#{System.unique_integer([:positive])}@example.com"

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

  # A fixture date that is always in the future and always mid-month: the 15th
  # of next month. Anchoring on `today + n` instead put the fixture in a
  # different month from the one the calendar rendered on any day within `n`
  # of month end. Callers mount at `calendar_at(soon())` so the rendered month
  # is the anchor's, whatever today is; `+1`/`+2` stay inside it.
  defp soon do
    Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: 1) |> Date.add(14)
  end

  defp calendar_at(%Date{} = at), do: ~p"/editor/calendar?at=#{Date.to_iso8601(at)}"

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

      {:ok, lv, _html} = conn |> log_in(admin) |> live(calendar_at(at))

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

    # A burst of writes elsewhere (a bulk import, a release going out, a
    # scheduler sweep) queues one `:calendar_changed` per write. Re-running the
    # window query once per message rather than once per burst is what turns a
    # busy org into a mailbox this LiveView can never catch up on: every later
    # `render`/`render_click` is just another message, handled strictly after
    # whatever backlog of stale, already-superseded re-queries arrived first.
    # `handle_info/2` drains the mailbox before it re-queries, so N messages
    # cost the one re-query they actually need — proven here by the
    # `[:kiln_cms, :calendar, :requery]` event `handle_info/2` emits once per
    # re-query, carrying how many messages that re-query answered. Not by
    # timing, which would be exactly the kind of load-sensitive assertion this
    # bug already hid behind — and, since #1336's follow-up, not by repo query
    # telemetry either: a repo event is one *physical* query, and one logical
    # re-query runs several (one per content type, plus the dynamic-type
    # registry, tasks and releases), so a raw event count measures the
    # projection's fan-out, not the coalescing.
    test "a burst of change notifications is coalesced into one re-query", %{conn: conn} do
      admin = authed_admin()

      # The calendar's broadcast topic is per-org, and most of this suite
      # writes to the shared default org — mounted there, every concurrent
      # async test's lifecycle write would land another `:calendar_changed`
      # in this LiveView's mailbox mid-measurement, each a *legitimate*,
      # uncoalescible extra re-query (the flake #1336's fix still left
      # behind). A freshly-seeded org has a topic nothing else publishes on,
      # so the only messages in play are the twenty sent below.
      org =
        Ash.Seed.seed!(Organization, %{
          name: "Calendar Burst",
          slug: "cal-burst-#{System.unique_integer([:positive])}",
          status: :active
        })

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(admin) |> live(~p"/editor/calendar")

      test_pid = self()
      handler_id = "calendar-coalesce-#{System.unique_integer([:positive])}"

      # `:telemetry.execute/3` runs each handler synchronously, IN THE PROCESS
      # THAT EMITTED THE EVENT — no message passing involved. So `self()`
      # inside this handler is whatever CalendarLive just re-queried, and this
      # attachment (a VM-wide hook, since `:telemetry` has no per-test scope)
      # only reports re-queries `lv.pid` itself ran, ignoring every other
      # concurrently-mounted calendar.
      :telemetry.attach(
        handler_id,
        [:kiln_cms, :calendar, :requery],
        fn _event, %{messages: messages}, _metadata, %{lv_pid: lv_pid, test_pid: test_pid} ->
          if self() == lv_pid, do: send(test_pid, {:calendar_requery, messages})
        end,
        %{lv_pid: lv.pid, test_pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # `:sys.suspend/1` pauses lv.pid's message loop without blocking `send/2`
      # (delivery to a mailbox is independent of whether the owner is running),
      # so every one of the 20 sends below is guaranteed to land before the
      # process handles the first of them — a real, atomic burst regardless of
      # scheduler contention. Without this, the burst's atomicity depended on
      # this loop finishing before lv.pid was next scheduled, which a busy
      # test suite cannot promise: kiln_cms#1336 caught CalendarLive draining
      # (and re-querying for) several partial bursts instead of one whole one
      # under load, which this suspend/resume closes off at the test level.
      :sys.suspend(lv.pid)

      for _ <- 1..20, do: send(lv.pid, {:calendar_changed, Ash.UUID.generate()})

      :sys.resume(lv.pid)

      # Forces the LiveView to actually process its mailbox before we assert:
      # `render/1` is itself a message, so it cannot return before every
      # `:calendar_changed` already queued ahead of it has been handled — by
      # which point the requery events those handlers emitted are already in
      # this test's mailbox. Hence `assert_received`, not `assert_receive`:
      # nothing here waits on timing.
      render(lv)

      assert_received {:calendar_requery, messages},
                      "expected the drained burst to still run its one re-query"

      assert messages == 20,
             "the burst's first re-query answered only #{messages} of 20 " <>
               ":calendar_changed messages — handle_info/2 is re-querying per " <>
               "partial drain instead of coalescing the whole burst"

      refute_received {:calendar_requery, _},
                      "20 :calendar_changed messages ran more than one re-query — " <>
                        "handle_info/2 is re-querying per message instead of " <>
                        "coalescing the burst"
    end
  end

  describe "reschedule" do
    defp scheduled_page(admin, at, attrs \\ %{}) do
      CMS.create_page!(
        Map.merge(
          %{
            title: "Movable #{System.unique_integer([:positive])}",
            slug: slug(),
            scheduled_at: at
          },
          attrs
        ),
        actor: admin
      )
    end

    # Mount the calendar on `at`'s month and prove the fixture is actually on
    # it: every reschedule below depends on that, and the "leaves the record
    # alone" assertions would pass vacuously otherwise.
    defp open_calendar_on(conn, user, %Date{} = at, %{title: title}) do
      {:ok, lv, html} = conn |> log_in(user) |> live(calendar_at(at))

      assert html =~ title
      {:ok, lv, html}
    end

    # A move that fails server-side — including a DB checkout dropped under
    # full-suite contention (#1348) — leaves the record unmoved, and the bare
    # `==` mismatch on the reloaded row says nothing about why. The hook's own
    # response carries the reason as an error flash, so fail with that first.
    defp assert_move_accepted(html) do
      case html |> Floki.parse_document!() |> Floki.find("#flash-error") do
        [] -> :ok
        nodes -> flunk("reschedule was refused: #{nodes |> Floki.text() |> String.trim()}")
      end
    end

    test "moves a scheduled publish to the dropped day, keeping its time", %{conn: conn} do
      admin = authed_admin()
      day = soon()
      at = DateTime.new!(day, ~T[09:30:00])
      page = scheduled_page(admin, at)

      {:ok, lv, _html} = open_calendar_on(conn, admin, day, page)

      target = Date.add(day, 1)

      render_hook(lv, "reschedule", %{
        "id" => page.id,
        "type" => "page",
        "kind" => "publish",
        "date" => Date.to_iso8601(target)
      })
      |> assert_move_accepted()

      reloaded = CMS.get_page!(page.id, actor: admin)
      assert DateTime.to_date(reloaded.scheduled_at) == target
      # The day moved; the time of day did not. Truncated because the column
      # is `utc_datetime_usec` and the fixture's literal carries no microseconds.
      assert reloaded.scheduled_at |> DateTime.to_time() |> Time.truncate(:second) ==
               ~T[09:30:00]
    end

    test "moves an embargo end, whatever its expiry action", %{conn: conn} do
      admin = authed_admin()
      day = soon()

      page =
        CMS.create_page!(
          %{
            title: "Embargo #{System.unique_integer([:positive])}",
            slug: slug(),
            expiry_action: :archive
          },
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)

      page =
        CMS.update_page!(page, %{unpublish_at: DateTime.new!(day, ~T[17:00:00])}, actor: admin)

      {:ok, lv, _html} = open_calendar_on(conn, admin, day, page)

      target = Date.add(day, 2)

      render_hook(lv, "reschedule", %{
        "id" => page.id,
        "type" => "page",
        "kind" => "archive",
        "date" => Date.to_iso8601(target)
      })
      |> assert_move_accepted()

      assert DateTime.to_date(CMS.get_page!(page.id, actor: admin).unpublish_at) == target
    end

    test "refuses a move into the past and leaves the record alone", %{conn: conn} do
      admin = authed_admin()
      # An overdue chip on last month's grid, dragged one day further back.
      # Anchoring on the real clock instead (a chip today, dropped onto
      # yesterday) had a month-boundary edge: on the 1st, "yesterday" is not
      # a cell of the mounted month at all (#1357). Here every day of the
      # mounted month is behind us on every real-clock day, and the arrow-key
      # reschedule path makes a backwards move off any cell a real input.
      day = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: -1) |> Date.add(14)
      at = DateTime.new!(day, ~T[23:59:59])
      page = scheduled_page(admin, at)

      {:ok, lv, _html} = open_calendar_on(conn, admin, day, page)

      html =
        render_hook(lv, "reschedule", %{
          "id" => page.id,
          "type" => "page",
          "kind" => "publish",
          "date" => Date.to_iso8601(Date.add(day, -1))
        })

      assert html =~ "Can&#39;t reschedule into the past" or
               html =~ "Can't reschedule into the past"

      assert DateTime.compare(CMS.get_page!(page.id, actor: admin).scheduled_at, at) == :eq
    end

    test "refuses a drop onto today once the chip's time of day has passed", %{conn: conn} do
      admin = authed_admin()
      # A drop keeps the chip's time of day, so "today" is only in the future
      # until that time comes round. Midnight is always behind us — and a
      # midnight chip on the 15th of *next* month is always itself in the
      # future, unlike the old end-of-current-month fixture, which was born
      # already-past on the last day of a month and proved the refusal for
      # the wrong reason (#1357). The target day is off the mounted month,
      # which the handler must tolerate anyway: arrow keys can walk a chip
      # onto any date.
      day = soon()
      at = DateTime.new!(day, ~T[00:00:00])
      page = scheduled_page(admin, at)

      {:ok, lv, _html} = open_calendar_on(conn, admin, day, page)

      html =
        render_hook(lv, "reschedule", %{
          "id" => page.id,
          "type" => "page",
          "kind" => "publish",
          "date" => Date.to_iso8601(Date.utc_today())
        })

      assert html =~ "Can&#39;t reschedule into the past" or
               html =~ "Can't reschedule into the past"

      assert DateTime.compare(CMS.get_page!(page.id, actor: admin).scheduled_at, at) == :eq
    end

    test "refuses to drag a lane that offers no handle, without crashing", %{conn: conn} do
      admin = authed_admin()
      # `published` is on the calendar but is history, not a plan — the chip
      # has no drag handle. The payload names its own kind, so a hand-pushed
      # event must be refused server-side rather than reach a `case` with no
      # clause for it.
      page = CMS.create_page!(%{title: "Live #{slug()}", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/calendar")
      assert html =~ page.title

      html =
        render_hook(lv, "reschedule", %{
          "id" => page.id,
          "type" => "page",
          "kind" => "published",
          "date" => Date.to_iso8601(soon())
        })

      assert html =~ "can&#39;t be moved by dragging" or html =~ "can't be moved by dragging"

      assert DateTime.compare(
               CMS.get_page!(page.id, actor: admin).published_at,
               page.published_at
             ) ==
               :eq
    end

    test "refuses an event that is not in the rendered window", %{conn: conn} do
      admin = authed_admin()
      day = soon()
      # Scheduled far outside the rendered month, so the calendar never loaded it.
      far = DateTime.new!(Date.shift(day, year: 2), ~T[09:00:00])
      page = scheduled_page(admin, far)

      {:ok, lv, html} = conn |> log_in(admin) |> live(calendar_at(day))
      refute html =~ page.title

      html =
        render_hook(lv, "reschedule", %{
          "id" => page.id,
          "type" => "page",
          "kind" => "publish",
          "date" => Date.to_iso8601(day)
        })

      assert html =~ "no longer on the calendar"
      # The window lookup is the authorization boundary, so nothing moved.
      assert DateTime.compare(CMS.get_page!(page.id, actor: admin).scheduled_at, far) == :eq
    end

    test "the month grid's padding days are part of the window", %{conn: conn} do
      admin = authed_admin()
      # The month view pads out to full weeks, and every padding cell is a drop
      # target. Anchor on a month whose grid runs past its own last day.
      day = month_with_trailing_padding()
      padding = day |> Date.end_of_month() |> Date.end_of_week()
      assert padding.month != day.month

      already_there = scheduled_page(admin, DateTime.new!(padding, ~T[09:00:00]))
      movable = scheduled_page(admin, DateTime.new!(day, ~T[09:00:00]))

      {:ok, lv, html} = conn |> log_in(admin) |> live(calendar_at(day))
      # Something scheduled on a padding day draws a chip like any other day.
      assert html =~ already_there.title

      moved =
        render_hook(lv, "reschedule", %{
          "id" => movable.id,
          "type" => "page",
          "kind" => "publish",
          "date" => Date.to_iso8601(padding)
        })

      assert DateTime.to_date(CMS.get_page!(movable.id, actor: admin).scheduled_at) == padding
      # And a chip dropped there does not vanish from the grid it was dropped on.
      assert moved =~ movable.title
    end

    # Some months fill their weeks exactly (February 2027 starts on a Monday
    # and ends on a Sunday); walk forward from the anchor until one does not.
    defp month_with_trailing_padding do
      Stream.iterate(soon(), &Date.shift(&1, month: 1))
      |> Enum.find(fn day -> Date.end_of_week(Date.end_of_month(day)).month != day.month end)
    end

    test "a viewer never reaches the calendar at all", %{conn: conn} do
      # The route lives in the `:editor_routes` live session, so the boundary
      # for a viewer is the mount, not the event handler — there is no forged
      # payload to test, because there is no socket to send one on. Mounted at
      # the bare URL every nav link uses: the hook halts before any param is read.
      assert {:error, {:redirect, _}} =
               conn |> log_in(authed_viewer()) |> live(~p"/editor/calendar")
    end

    test "an editor scoped to other types cannot move what they cannot edit", %{conn: conn} do
      admin = authed_admin()
      day = soon()
      at = DateTime.new!(day, ~T[09:00:00])
      page = scheduled_page(admin, at)

      # Granular RBAC (#332): this editor may author posts, not pages. The page
      # is still *readable*, so it is on their calendar and the window lookup
      # succeeds — the refusal has to come from the write's own policy.
      scoped =
        authed_user(:editor, %{editable_types: ["post"]})

      {:ok, lv, _html} = open_calendar_on(conn, scoped, day, page)

      render_hook(lv, "reschedule", %{
        "id" => page.id,
        "type" => "page",
        "kind" => "publish",
        "date" => Date.to_iso8601(Date.add(day, 1))
      })

      assert DateTime.compare(CMS.get_page!(page.id, actor: admin).scheduled_at, at) == :eq
    end

    test "announces the move for a screen reader", %{conn: conn} do
      admin = authed_admin()
      day = soon()
      page = scheduled_page(admin, DateTime.new!(day, ~T[09:00:00]))

      {:ok, lv, html} = open_calendar_on(conn, admin, day, page)
      # The live region exists before anything happens — one inserted later is
      # not reliably announced.
      assert html =~ ~s(aria-live="polite")

      moved =
        render_hook(lv, "reschedule", %{
          "id" => page.id,
          "type" => "page",
          "kind" => "publish",
          "date" => Date.to_iso8601(Date.add(day, 1))
        })

      assert_move_accepted(moved)
      assert moved =~ "Moved"
    end
  end

  describe "mark reviewed from the calendar" do
    test "an overdue chip attests, and the chip stops asking", %{conn: conn} do
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

      page
      |> Ash.Changeset.for_update(:backdate_published_at, %{
        published_at: DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)
      })
      |> Ash.update!(authorize?: false)

      # due_at is 15 days back, so anchor the list window there.
      at = Date.add(Date.utc_today(), -15)

      {:ok, lv, html} =
        conn |> log_in(admin) |> live(~p"/editor/calendar?view=list&at=#{Date.to_iso8601(at)}")

      assert html =~ "Mark reviewed"

      after_click =
        lv
        |> element("button[phx-value-id='#{page.id}'][phx-click='mark_reviewed']")
        |> render_click()

      assert CMS.get_page!(page.id, actor: admin).last_reviewed_at
      # The clock reset, so the review-due chip has moved out of this window
      # entirely — and with it the button.
      refute after_click =~ "Mark reviewed"
    end
  end
end
