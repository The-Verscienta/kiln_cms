defmodule KilnCMS.BotBudgetsTest do
  @moduledoc """
  `KilnCMS.BotBudgets` (#2243): the defaults, the operator's values over them,
  a site's values under the operator's (refused above at write, clamped at
  read), an unreadable row, the cache bust, and the ceiling formula.

  `async: false`: the operator's values are `KilnCMSWeb.RateLimit` application
  env, which is VM-global; every change is put back by
  `restore_limits_on_exit/0`.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.RateLimitHelpers, only: [put_limit: 2, restore_limits_on_exit: 0]

  alias KilnCMS.BotBudgets
  alias KilnCMS.CMS

  setup do
    restore_limits_on_exit()
    put_limit(:delivery, 300)
    %{org: org("botbudgets")}
  end

  defp put_classes(classes) do
    current = Application.get_env(:kiln_cms, KilnCMSWeb.RateLimit, [])

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.RateLimit,
      Keyword.put(current, :delivery_classes, classes)
    )
  end

  defp save!(org, attrs), do: CMS.save_site_bot_budgets!(attrs, authorize?: false, tenant: org)

  defp save(org, attrs), do: CMS.save_site_bot_budgets(attrs, authorize?: false, tenant: org)

  test "with nothing set, the built-in defaults apply", %{org: org} do
    assert BotBudgets.percent(org, :browser) == 100
    assert BotBudgets.percent(org, :search_engine) == 200
    assert BotBudgets.percent(org, :ai_crawler) == 100
    assert BotBudgets.percent(org, :declared_bot) == 50
    assert BotBudgets.percent(org, :empty) == 20

    assert BotBudgets.limit(org, :browser) == 300
    assert BotBudgets.limit(org, :declared_bot) == 150
    assert BotBudgets.limit(org, :empty) == 60

    assert %{source: :default, operator_source: :default, percent: 20, limit: 60} =
             BotBudgets.effective(org).empty
  end

  test "the operator's value replaces a default", %{org: org} do
    put_classes(%{search_engine: 400, empty: 10})

    assert BotBudgets.percent(org, :search_engine) == 400
    assert BotBudgets.limit(org, :search_engine) == 1_200
    assert BotBudgets.percent(org, :empty) == 10
    # The others keep their defaults.
    assert BotBudgets.percent(org, :declared_bot) == 50
    assert %{source: :operator, operator_percent: 400} = BotBudgets.effective(org).search_engine
  end

  test "an operator value out of range is ignored, not trusted", %{org: org} do
    put_classes(%{search_engine: 0, ai_crawler: 5_000, declared_bot: "abc"})

    assert BotBudgets.percent(org, :search_engine) == 200
    assert BotBudgets.percent(org, :ai_crawler) == 100
    assert BotBudgets.percent(org, :declared_bot) == 50
  end

  test "with no org, the operator's values apply" do
    put_classes(%{empty: 5})
    assert BotBudgets.percent(nil, :empty) == 5
    assert BotBudgets.percent(nil, :declared_bot) == 50
  end

  test "a site lowers one class and inherits the rest", %{org: org} do
    other = org("botbudgets-other")
    save!(org, %{empty_percent: 5})

    assert BotBudgets.percent(org, :empty) == 5
    assert BotBudgets.limit(org, :empty) == 15
    assert BotBudgets.percent(org, :declared_bot) == 50
    assert BotBudgets.percent(org, :search_engine) == 200
    assert %{source: :site, site_percent: 5} = BotBudgets.effective(org).empty
    assert %{source: :default, site_percent: nil} = BotBudgets.effective(org).declared_bot

    # Another site is not affected.
    assert BotBudgets.percent(other, :empty) == 20
  end

  describe "a site may only tighten" do
    test "a value above the operator's is refused at save, naming the ceiling", %{org: org} do
      put_classes(%{search_engine: 150})

      assert {:error, error} = save(org, %{search_engine_percent: 151})
      assert Exception.message(error) =~ "may not be more than 150%"
      assert {:ok, []} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)

      # The default is the ceiling when the operator set nothing.
      assert {:error, error} = save(org, %{declared_bot_percent: 51})
      assert Exception.message(error) =~ "may not be more than 50%"

      # At the ceiling is fine.
      assert {:ok, _row} = save(org, %{search_engine_percent: 150, declared_bot_percent: 50})
    end

    test "a stored value above a later-lowered operator value is clamped at read", %{org: org} do
      save!(org, %{declared_bot_percent: 40})
      assert BotBudgets.percent(org, :declared_bot) == 40

      put_classes(%{declared_bot: 25})

      assert BotBudgets.percent(org, :declared_bot) == 25
      assert BotBudgets.limit(org, :declared_bot) == 75

      assert %{source: :operator, clamped?: true, site_percent: 40, percent: 25} =
               BotBudgets.effective(org).declared_bot
    end

    test "an update that leaves a clamped column alone still saves the others", %{org: org} do
      row = save!(org, %{declared_bot_percent: 40})
      put_classes(%{declared_bot: 25})

      # Re-sending the stored 40 is not a change, so it is not judged.
      assert {:ok, row} =
               CMS.update_site_bot_budgets(row, %{declared_bot_percent: 40, empty_percent: 10},
                 authorize?: false,
                 tenant: org
               )

      assert row.empty_percent == 10

      # Changing it is judged.
      assert {:error, error} =
               CMS.update_site_bot_budgets(row, %{declared_bot_percent: 30},
                 authorize?: false,
                 tenant: org
               )

      assert Exception.message(error) =~ "may not be more than 25%"
    end
  end

  test "values outside 1-1000 are refused", %{org: org} do
    put_classes(%{search_engine: 1000})

    for value <- [0, -5, 1001] do
      assert {:error, _} = save(org, %{search_engine_percent: value}), inspect(value)
    end

    assert {:ok, _} = save(org, %{search_engine_percent: 1000})
  end

  describe "an unreadable row" do
    # A system actor no grant names: every read of the row is refused, which
    # is an error, and is logged. A quiet log means no read happened.
    defp without_grant(fun) do
      capture_log(fn ->
        KilnCMS.OrgSettings.with_actor(KilnCMS.SystemActor.new(:nobody), fun)
      end)
    end

    test "is answered with the operator's value", %{org: org} do
      save!(org, %{empty_percent: 5})
      KilnCMS.Cache.bust_bot_budgets(org.id)

      log = without_grant(fn -> assert BotBudgets.percent(org, :empty) == 20 end)
      assert log =~ "bot budgets lookup failed"
    end

    test "is not read again inside the interval", %{org: org} do
      save!(org, %{empty_percent: 5})
      KilnCMS.Cache.bust_bot_budgets(org.id)

      assert without_grant(fn -> BotBudgets.percent(org, :empty) end) =~ "lookup failed"

      # Inside the interval: the remembered failure answers, with no read.
      log =
        without_grant(fn ->
          assert BotBudgets.percent(org, :empty) == 20
          assert BotBudgets.percent(org, :declared_bot) == 50
        end)

      refute log =~ "bot budgets"
      # Even with the grant back, until the interval ends or a write busts it.
      assert BotBudgets.percent(org, :empty) == 20
    end

    test "is forgotten on the next write's bust, and the row is read", %{org: org} do
      save!(org, %{empty_percent: 5})
      KilnCMS.Cache.bust_bot_budgets(org.id)
      without_grant(fn -> BotBudgets.percent(org, :empty) end)

      KilnCMS.Cache.bust_bot_budgets(org.id)
      assert BotBudgets.percent(org, :empty) == 5
    end
  end

  test "a save is visible on the next read, not after the TTL", %{org: org} do
    assert BotBudgets.percent(org, :empty) == 20
    row = save!(org, %{empty_percent: 7})
    assert BotBudgets.percent(org, :empty) == 7

    CMS.reset_site_bot_budgets!(row, authorize?: false, tenant: org)
    assert BotBudgets.percent(org, :empty) == 20
  end

  test "the ceiling is a percentage of the delivery limit, at least 1" do
    assert BotBudgets.ceiling(300, 20) == 60
    assert BotBudgets.ceiling(300, 100) == 300
    assert BotBudgets.ceiling(300, 1000) == 3_000
    assert BotBudgets.ceiling(10, 5) == 1
    assert BotBudgets.ceiling(1, 1) == 1
    assert BotBudgets.ceiling(10, 25) == 2
  end

  test "the ceiling follows the delivery limit", %{org: org} do
    put_limit(:delivery, 10)
    assert BotBudgets.limit(org, :empty) == 2
    assert BotBudgets.limit(org, :declared_bot) == 5
    assert BotBudgets.limit(org, :browser) == 10
    assert BotBudgets.operator_limit(:empty) == 2
  end

  describe "the search-engine default (#2587)" do
    test "is 200%, twice the browser limit, with verification on", %{org: org} do
      assert BotBudgets.defaults().search_engine == 200
      assert BotBudgets.operator_percent(:search_engine) == 200
      assert BotBudgets.operator_limit(:search_engine) == 600
      assert BotBudgets.limit(org, :search_engine) == 600

      assert %{percent: 200, limit: 600, source: :default, operator_source: :default} =
               BotBudgets.effective(org).search_engine

      # An unproven claim is still held to what a browser gets.
      assert BotBudgets.unverified_search_limit() == 300
    end

    test "is 100% with verification off, so no claim gets more than a browser", %{org: org} do
      put_verification(false)

      assert BotBudgets.operator_percent(:search_engine) == 100
      assert BotBudgets.operator_limit(:search_engine) == 300
      assert BotBudgets.limit(org, :search_engine) == 300

      assert %{percent: 100, operator_percent: 100, source: :default} =
               BotBudgets.effective(org).search_engine

      # The other defaults do not depend on verification.
      assert BotBudgets.percent(org, :ai_crawler) == 100
      assert BotBudgets.percent(org, :empty) == 20
    end

    test "with verification off, an operator value is still used as given", %{org: org} do
      put_verification(false)
      put_classes(%{search_engine: 200})

      assert BotBudgets.operator_limit(:search_engine) == 600
      assert BotBudgets.percent(org, :search_engine) == 200
    end

    test "with verification off, a site may not save more than 100%", %{org: org} do
      put_verification(false)

      assert {:error, _} = save(org, %{search_engine_percent: 101})
      assert {:ok, _} = save(org, %{search_engine_percent: 100})
    end
  end

  defp put_verification(enabled?) do
    previous = Application.get_env(:kiln_cms, KilnCMS.CrawlerVerification)

    Application.put_env(
      :kiln_cms,
      KilnCMS.CrawlerVerification,
      Keyword.put(previous || [], :enabled, enabled?)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMS.CrawlerVerification, previous),
        else: Application.delete_env(:kiln_cms, KilnCMS.CrawlerVerification)
    end)
  end

  describe "unverified_search_limit/0 (#2254)" do
    test "is the search-engine ceiling held to the delivery limit" do
      assert BotBudgets.unverified_search_limit() == 300

      put_classes(%{search_engine: 400})
      assert BotBudgets.operator_limit(:search_engine) == 1_200
      assert BotBudgets.unverified_search_limit() == 300
    end

    test "is the search-engine ceiling itself when that is lower" do
      put_classes(%{search_engine: 40})
      assert BotBudgets.unverified_search_limit() == 120
    end
  end
end
