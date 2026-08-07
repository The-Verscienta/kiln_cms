defmodule KilnCMSWeb.AnalyticsLiveTest do
  @moduledoc """
  The analytics dashboard is editor/admin only and shows recorded view counts.
  Public delivery records a view per request.
  """
  # async: false — the "referrer breakdown" describe block below mutates the
  # global :analytics_referrers Application env, which an async: true sibling
  # test (e.g. KilnCMS.AnalyticsTest's "off by default" assertion) could
  # observe mid-mutation. See #620 review.
  use KilnCMSWeb.ConnCase, async: false

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

  describe "referrer breakdown (#620)" do
    setup do
      original = Application.get_env(:kiln_cms, :analytics_referrers, [])
      on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, original) end)
      :ok
    end

    defp enable_referrers(threshold \\ 5) do
      Application.put_env(:kiln_cms, :analytics_referrers,
        enabled: true,
        low_count_threshold: threshold
      )
    end

    # The breakdown only renders once @window_total > 0 (no separate empty
    # state — see analytics_live.ex), and the "Most viewed" table only shows
    # content with a ContentView row — so every test below records all three
    # counters, mirroring what `ViewTracking.record/4` does in one call.
    defp record_referrers(page, source, count) do
      Analytics.record_view!("page", page.id, authorize?: false)
      Analytics.record_view_day!("page", page.id, authorize?: false)

      for _ <- 1..count,
          do: Analytics.record_referrer!("page", page.id, source, authorize?: false)
    end

    defp new_page(title) do
      CMS.create_page!(
        %{title: title, slug: "ana-#{System.unique_integer([:positive])}"},
        authorize?: false
      )
    end

    test "hidden entirely when the phase-2 gate is off", %{conn: conn} do
      Application.put_env(:kiln_cms, :analytics_referrers, enabled: false)
      page = new_page("No Referrers")
      record_referrers(page, :search, 1)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      refute html =~ "Where readers came from"
      refute html =~ "Referrers</th>"
    end

    test "shows the site-wide breakdown and honestly labels :direct", %{conn: conn} do
      enable_referrers()
      page = new_page("Referred Page")
      record_referrers(page, :search, 6)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      assert html =~ "Where readers came from"
      assert html =~ "referring site chose not to send"
      # Non-suppressed (>= threshold), and no complementary suppression is
      # needed here — nothing else is nonzero, so the SVG <title> renders the
      # exact count.
      assert html =~ "<title>Search: 6</title>"
    end

    test "suppresses a count below the threshold as \"< n\", not the exact number", %{
      conn: conn
    } do
      enable_referrers(5)
      page = new_page("Quiet Page")
      record_referrers(page, :social, 2)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      assert html =~ "<title>Social: &lt; 5</title>"
      refute html =~ "Social: 2"
    end

    # The vulnerability the #620 review found: publishing exactly one
    # suppressed category next to four EXACT zeros (which sum, with the
    # suppressed one, to the row's own exact view total) makes that one
    # category's true count recoverable by subtraction. Closing it means a
    # second category must also stop reading as an exact "0".
    test "a lone suppressed category forces a second category into complementary suppression",
         %{conn: conn} do
      enable_referrers(5)
      page = new_page("Complementary")
      record_referrers(page, :social, 2)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      # social stays "< 5" (it was already below threshold); some other
      # category — direct, first in source order — no longer reads as an
      # honest exact "0", which would have given social away by subtraction.
      assert html =~ "<title>Social: &lt; 5</title>"
      assert html =~ "<title>Direct: hidden</title>"
      refute html =~ "<title>Direct: 0</title>"
    end

    test "two or more naturally-suppressed categories need no complementary help", %{conn: conn} do
      enable_referrers(5)
      page = new_page("Two Low")
      Analytics.record_view_day!("page", page.id, authorize?: false)
      Analytics.record_referrer!("page", page.id, :search, authorize?: false)
      Analytics.record_referrer!("page", page.id, :social, authorize?: false)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      # Two unknowns, one equation: internal/other genuinely have nothing to
      # hide and read as exact zeros; direct does too (it's not adjacent to
      # the lone-suppressed case above).
      assert html =~ "<title>Search: &lt; 5</title>"
      assert html =~ "<title>Social: &lt; 5</title>"
      assert html =~ "<title>Direct: 0</title>"
      assert html =~ "<title>Internal: 0</title>"
      assert html =~ "<title>Other: 0</title>"
    end

    test "suppressed and complementarily-suppressed bars render at the same size, unlike an exact one",
         %{conn: conn} do
      enable_referrers(5)
      page = new_page("Bar Sizes")
      record_referrers(page, :social, 2)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      # Both the naturally-suppressed and the complementarily-suppressed
      # segment must be identically sized — a regression that clamped only
      # one of them (or clamped to the raw hit count) would produce two
      # different `width:` percentages here instead of one repeated value.
      widths = Regex.scan(~r/width: ([\d.]+)%/, html) |> Enum.map(&List.last/1)
      assert length(Enum.uniq(widths)) == 1
    end

    test "the per-row table gains a Referrers column with each row's breakdown", %{conn: conn} do
      enable_referrers()
      page = new_page("Row Breakdown")
      record_referrers(page, :internal, 7)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      assert html =~ "Referrers</th>"
      # The `title="..."` attribute form is unique to the per-row bar
      # (`referrer_bar/1`) — the site-wide chart's own "Internal: 7" lives in
      # an SVG <title> *element*, a different string, so this can't pass
      # merely because the site-wide chart (which, with only one page
      # recorded, shows the same total) rendered correctly.
      assert html =~ ~s(title="Internal: 7")
    end

    test "a bucket outside the selected range is excluded from the breakdown", %{conn: conn} do
      enable_referrers()
      page = new_page("Old Referrer")

      Analytics.record_view_day!("page", page.id, authorize?: false)

      Ash.Seed.seed!(KilnCMS.Analytics.ReferrerDay, %{
        content_type: "page",
        content_id: page.id,
        source: :search,
        day: Date.add(Date.utc_today(), -10),
        hits: 9
      })

      {:ok, _lv, html_7} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics?range=7")

      refute html_7 =~ "<title>Search: 9</title>"

      {:ok, _lv, html_30} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics?range=30")

      assert html_30 =~ "<title>Search: 9</title>"
    end

    test "the range toggle keeps working with referrers on", %{conn: conn} do
      enable_referrers()
      page = new_page("Range Toggle")
      record_referrers(page, :direct, 1)

      conn = log_in(conn, authed_user(:editor))

      {:ok, _lv, html_30} = live(conn, ~p"/editor/analytics?range=30")
      assert html_30 =~ "Last 30 days"
      assert html_30 =~ "Where readers came from"

      {:ok, _lv, html_7} = live(conn, ~p"/editor/analytics?range=7")
      assert html_7 =~ "Last 7 days"
      assert html_7 =~ "Where readers came from"
    end

    test "the range toggle keeps working with referrers off", %{conn: conn} do
      Application.put_env(:kiln_cms, :analytics_referrers, enabled: false)
      conn = log_in(conn, authed_user(:editor))

      {:ok, _lv, html_30} = live(conn, ~p"/editor/analytics?range=30")
      assert html_30 =~ "Last 30 days"
      refute html_30 =~ "Where readers came from"

      {:ok, _lv, html_7} = live(conn, ~p"/editor/analytics?range=7")
      assert html_7 =~ "Last 7 days"
      refute html_7 =~ "Where readers came from"
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

  describe "funnels (#622)" do
    defp bucket!(content_type, content_id, views) do
      Ash.Seed.seed!(KilnCMS.Analytics.ContentViewDay, %{
        content_type: content_type,
        content_id: content_id,
        day: Date.utc_today(),
        views: views
      })
    end

    defp funnel_with_steps!(admin, steps) do
      funnel =
        Analytics.create_funnel!(
          %{name: "Signup", slug: "ana-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      for {content_type, content_id, position} <- steps do
        Analytics.create_funnel_step!(
          %{
            funnel_id: funnel.id,
            content_type: content_type,
            content_id: content_id,
            position: position
          },
          actor: admin
        )
      end

      funnel
    end

    test "shows no funnels section when the org has none", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      refute html =~ "Funnels</h2>"
    end

    test "an active funnel reports each step's window views and ratio", %{conn: conn} do
      admin = authed_user(:admin)

      landing =
        CMS.create_page!(
          %{title: "Landing", slug: "ana-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      pricing =
        CMS.create_page!(
          %{title: "Pricing", slug: "ana-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      bucket!("page", landing.id, 20)
      bucket!("page", pricing.id, 5)

      funnel_with_steps!(admin, [{"page", landing.id, 0}, {"page", pricing.id, 1}])

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/analytics")

      assert html =~ "Signup"
      assert html =~ "Landing"
      assert html =~ "Pricing"
      assert html =~ "25.0%"
      assert html =~ "not a per-visitor conversion rate"
    end

    test "an inactive funnel is excluded from the report", %{conn: conn} do
      admin = authed_user(:admin)

      funnel =
        Analytics.create_funnel!(
          %{name: "Hidden", slug: "ana-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      Analytics.update_funnel!(funnel, %{active: false}, actor: admin)

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/analytics")

      refute html =~ "Hidden"
    end

    test "a step whose content was deleted still shows a row, titled as deleted", %{conn: conn} do
      admin = authed_user(:admin)
      gone_id = Ash.UUID.generate()
      bucket!("page", gone_id, 3)

      funnel_with_steps!(admin, [{"page", gone_id, 0}])

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/analytics")

      assert html =~ "(deleted)"
    end
  end

  describe "content gaps (#339)" do
    defp searched!(query, result_count, times) do
      for _ <- 1..times do
        Analytics.record_search!(
          %{query: query, locale: "en", result_count: result_count},
          authorize?: false
        )
      end
    end

    test "zero-result searches are listed, most-searched first", %{conn: conn} do
      searched!("moxibustion", 0, 2)
      searched!("cupping therapy", 0, 5)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      assert html =~ "Content gaps"
      assert html =~ "moxibustion"
      assert html =~ "cupping therapy"

      # Ordering is the point of the section: the gap searched most is the one
      # worth writing about first.
      assert :binary.match(html, "cupping therapy") < :binary.match(html, "moxibustion")
    end

    test "a search that DID find something is not a gap", %{conn: conn} do
      searched!("acupuncture", 7, 3)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      refute html =~ "acupuncture"
    end

    test "the section is absent entirely when nothing came back empty", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      refute html =~ "Content gaps"
    end

    test "a query containing markup is escaped, not rendered", %{conn: conn} do
      # A recorded query is visitor input echoed into an editor's page.
      searched!("<script>alert(1)</script>", 0, 1)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/analytics")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
