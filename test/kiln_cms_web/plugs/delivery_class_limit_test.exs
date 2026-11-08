defmodule KilnCMSWeb.Plugs.DeliveryClassLimitTest do
  @moduledoc """
  The per-class ceilings inside the `:delivery` bucket (#2243), through the real
  router: exact counts per class, the one shared counter, the refusal (the same
  429 as before, naming no class), a site's lower value, the operator's value,
  the routes that are never classified, and the telemetry.

  `async: false`: every test lowers `:delivery` with `put_limit/3` and some set
  the operator's class values, both VM-global application env (restored by
  `restore_limits_on_exit/0`); the telemetry handler is node-wide too.

  The window is `BudgetWindow.fresh_window_ms/0` (~20 days, opened under a
  second ago), so no window boundary can fall inside a test and turn an exact
  count into a flake (#697). Each test's `conn` carries an address of its own
  (`ConnCase`, #936).
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  import KilnCMS.RateLimitHelpers,
    only: [put_limit: 3, restore_limits_on_exit: 0, spent: 2]

  alias KilnCMS.CMS
  alias KilnCMS.Test.BudgetWindow
  alias KilnCMSWeb.RateLimit

  @browser "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @gptbot "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot"
  @curl "curl/8.4.0"

  setup %{conn: conn} do
    restore_limits_on_exit()
    put_limit(:delivery, 10, BudgetWindow.fresh_window_ms())
    %{conn: conn, ip: RateLimit.client_key(conn.remote_ip)}
  end

  defp put_classes(classes) do
    current = Application.get_env(:kiln_cms, RateLimit, [])
    Application.put_env(:kiln_cms, RateLimit, Keyword.put(current, :delivery_classes, classes))
  end

  # One GET "/" from the test's address. `nil` sends no user-agent header at all.
  defp hit(conn, ua, path \\ "/") do
    conn = if ua, do: put_req_header(conn, "user-agent", ua), else: conn
    get(conn, path)
  end

  defp throttled?(conn), do: conn.status == 429

  # How many of `n` requests got through before the first 429, asserting that
  # everything after the first 429 is refused too.
  defp allowed_of(conn, ua, n) do
    statuses = for _ <- 1..n, do: conn |> hit(ua) |> throttled?()
    allowed = Enum.take_while(statuses, &(not &1))
    assert Enum.all?(Enum.drop(statuses, length(allowed))), "a refusal was followed by an allow"
    length(allowed)
  end

  describe "each class's ceiling, with :delivery at 10" do
    test "no user agent: 2", %{conn: conn} do
      assert allowed_of(conn, nil, 4) == 2
    end

    test "a blank user agent counts as none", %{conn: conn} do
      assert allowed_of(conn, "   ", 4) == 2
    end

    test "a declared bot: 5", %{conn: conn} do
      assert allowed_of(conn, @curl, 7) == 5
    end

    test "a browser: 10, exactly the delivery limit", %{conn: conn} do
      assert {10, _scale} = RateLimit.limits().delivery
      assert allowed_of(conn, @browser, 12) == 10
    end

    test "an AI crawler: 10", %{conn: conn} do
      assert allowed_of(conn, @gptbot, 12) == 10
    end

    test "a search engine: 10", %{conn: conn} do
      assert allowed_of(conn, @googlebot, 12) == 10
    end

    test "an unknown user agent is a browser", %{conn: conn} do
      assert allowed_of(conn, "okhttp/4.12.0", 12) == 10
    end
  end

  test "a class the operator raised gets its raised ceiling", %{conn: conn} do
    put_classes(%{search_engine: 400})
    assert allowed_of(conn, @googlebot, 42) == 40
  end

  test "the ceiling is never below 1", %{conn: conn} do
    put_limit(:delivery, 3, BudgetWindow.fresh_window_ms())
    # 20% of 3 is 0.6, floored to 1.
    assert allowed_of(conn, nil, 3) == 1
  end

  describe "what reads the site's row" do
    # A site's row is read as `OrgSettings.system(:bot_budgets)`; swapping in an
    # actor no grant names makes any read of it fail and log, so a quiet log
    # means no read happened. The plug runs in the test process, where the
    # override applies.
    setup %{conn: conn} do
      site = org("botclass-reads")
      on_exit(fn -> KilnCMS.Cache.bust_bot_budgets(site.id) end)
      %{site: site, site_conn: org_conn(conn, site)}
    end

    defp without_grant(fun) do
      ExUnit.CaptureLog.capture_log(fn ->
        KilnCMS.OrgSettings.with_actor(KilnCMS.SystemActor.new(:nobody), fun)
      end)
    end

    test "an allowed non-browser request looks it up", %{site_conn: site_conn} do
      assert without_grant(fn -> hit(site_conn, @curl) end) =~ "bot budgets lookup failed"
    end

    test "a browser never does", %{site_conn: site_conn} do
      refute without_grant(fn -> hit(site_conn, @browser) end) =~ "bot budgets"
    end

    test "a request the operator's ceiling refuses never does", ctx do
      %{site: site, site_conn: site_conn} = ctx
      # Spend the empty-UA ceiling (2) with the grant in place, then go past it
      # with nothing cached, so a lookup would have to read the row.
      for _ <- 1..2, do: hit(site_conn, nil)
      KilnCMS.Cache.bust_bot_budgets(site.id)

      log = without_grant(fn -> assert site_conn |> hit(nil) |> throttled?() end)
      refute log =~ "bot budgets"
    end
  end

  describe "one counter per address" do
    test "every class spends it, one request at a time", %{conn: conn, ip: ip} do
      for {ua, n} <- [{@browser, 1}, {nil, 2}, {@curl, 3}, {@googlebot, 4}] do
        hit(conn, ua)
        assert spent(:delivery, ip) == n
      end
    end

    test "switching user agents earns nothing", %{conn: conn} do
      # 1 browser request, then the empty-UA ceiling (2) is reached at count 2.
      refute conn |> hit(@browser) |> throttled?()
      refute conn |> hit(nil) |> throttled?()
      assert conn |> hit(nil) |> throttled?()

      # Browsers go on to the delivery limit on the same count (3 spent so far).
      assert allowed_of(conn, @browser, 9) == 7
    end
  end

  describe "the refusal" do
    test "is the ordinary 429, HTML for a browser navigation", %{conn: conn} do
      for _ <- 1..2, do: hit(conn, nil)

      refused = conn |> put_req_header("accept", "text/html") |> hit(nil)

      assert refused.status == 429
      assert [retry] = get_resp_header(refused, "retry-after")
      assert String.to_integer(retry) >= 1
      assert refused.resp_body =~ "Too many requests"
      refute refused.resp_body =~ ~r/bot|crawler|class|user.agent/i
    end

    test "is the JSON error otherwise", %{conn: conn} do
      for _ <- 1..5, do: hit(conn, @curl)

      refused = hit(conn, @curl)

      assert refused.status == 429
      assert [_retry] = get_resp_header(refused, "retry-after")
      assert %{"errors" => [%{"code" => "too_many_requests"}]} = json_response(refused, 429)
      refute refused.resp_body =~ ~r/bot|crawler|class|user.agent/i
    end
  end

  describe "a site's own value" do
    test "lowers its class for requests to that site", %{conn: conn} do
      site = org("botclass-site")
      CMS.save_site_bot_budgets!(%{declared_bot_percent: 20}, authorize?: false, tenant: site)

      site_conn = org_conn(conn, site)
      # 20% of 10.
      assert allowed_of(site_conn, @curl, 4) == 2

      # The refusal from a site's ceiling carries a retry-after as well.
      assert [retry] = site_conn |> hit(@curl) |> get_resp_header("retry-after")
      assert String.to_integer(retry) >= 1
    end

    test "does not reach another site", %{conn: conn} do
      site = org("botclass-lowered")
      other = org("botclass-other")
      CMS.save_site_bot_budgets!(%{declared_bot_percent: 20}, authorize?: false, tenant: site)

      assert conn |> org_conn(other) |> allowed_of(@curl, 7) == 5
    end

    test "the operator's value applies when the site sets none", %{conn: conn} do
      put_classes(%{declared_bot: 30})
      site = org("botclass-norow")

      assert conn |> org_conn(site) |> allowed_of(@curl, 5) == 3
    end
  end

  describe "routes outside :delivery are never classified" do
    @exempt ~w(/robots.txt /llms.txt /sitemap.xml /feed.xml /up /ready)

    test "none of them pipes through :delivery" do
      for path <- @exempt do
        assert %{pipe_through: pipes} =
                 Phoenix.Router.route_info(KilnCMSWeb.Router, "GET", path, "localhost"),
               path

        refute :delivery in pipes, "#{path} pipes through :delivery"
      end
    end

    test "an address out of empty-UA budget still reaches them", %{conn: conn} do
      for _ <- 1..2, do: hit(conn, nil)
      assert conn |> hit(nil) |> throttled?()

      for path <- ["/live" | @exempt] do
        refute conn |> hit(nil, path) |> throttled?(), path
      end
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      handler = "delivery-class-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :delivery, :client_class],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:client_class, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "every check reports its class and result, and nothing else", %{conn: conn} do
      for _ <- 1..3, do: hit(conn, nil)

      for result <- [:allowed, :allowed, :throttled] do
        assert_received {:client_class, %{count: 1}, metadata}
        assert metadata == %{class: :empty, result: result}
      end

      # Same count (4 of 10), a class with a higher ceiling: allowed.
      hit(conn, @gptbot)
      assert_received {:client_class, %{count: 1}, %{class: :ai_crawler, result: :allowed}}
    end

    test "a site-level refusal is reported as throttled", %{conn: conn} do
      site = org("botclass-telemetry")
      CMS.save_site_bot_budgets!(%{search_engine_percent: 10}, authorize?: false, tenant: site)
      site_conn = org_conn(conn, site)

      hit(site_conn, @googlebot)
      hit(site_conn, @googlebot)

      assert_received {:client_class, _, %{class: :search_engine, result: :allowed}}
      assert_received {:client_class, _, %{class: :search_engine, result: :throttled}}
    end

    test "the counter is tagged by class and result only" do
      assert [metric] =
               for(
                 m <- KilnCMSWeb.Telemetry.metrics(),
                 m.name == [:kiln_cms, :delivery, :client_class, :count],
                 do: m
               )

      assert metric.tags == [:class, :result]
    end
  end
end
