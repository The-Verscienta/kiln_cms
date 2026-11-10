defmodule KilnCMSWeb.BotBudgetsLiveTest do
  @moduledoc """
  `/editor/bot-budgets` (#2243): the admin gate (and the re-check on every
  event), saving and resetting for the request's org only, what each class
  comes to in requests, the server's value a site cannot exceed, a clamped
  stored value, and the audit event.

  `async: false`: tests lower `:delivery` and set the operator's class values,
  `KilnCMSWeb.RateLimit` application env, which is VM-global; both are put back
  by `restore_limits_on_exit/0`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.RateLimitHelpers, only: [put_limit: 2, restore_limits_on_exit: 0]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    restore_limits_on_exit()
    put_limit(:delivery, 300)
    org = org("botbudgetslive")
    on_exit(fn -> KilnCMS.Cache.bust_bot_budgets(org.id) end)
    %{org: org}
  end

  defp put_classes(classes) do
    current = Application.get_env(:kiln_cms, KilnCMSWeb.RateLimit, [])

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.RateLimit,
      Keyword.put(current, :delivery_classes, classes)
    )
  end

  describe "access" do
    test "turns away a visitor who is not signed in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/bot-budgets")
    end

    for role <- [:editor, :viewer] do
      test "turns away a #{role} of this very site", %{conn: conn, org: org} do
        user = authed_user(unquote(role))
        grant_tier(user, org, unquote(role))

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/bot-budgets")
      end
    end

    test "the console nav lists the page for an admin", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)
      assert has_element?(lv, ~s(nav a[href="/editor/bot-budgets"]))
    end
  end

  test "shows each class's default, in requests, and the server's ceiling", %{
    conn: conn,
    org: org
  } do
    {:ok, lv, html} = admin_live(conn, org)

    assert has_element?(lv, "#bot-budgets-browser", "300 requests a minute")
    assert has_element?(lv, "#bot-budget-empty-effective", "20%")
    assert has_element?(lv, "#bot-budget-empty-effective", "60 requests a minute")
    assert has_element?(lv, "#bot-budget-empty-effective", "Default")
    assert has_element?(lv, "#bot-budget-declared_bot-ceiling", "at most 50% here")
    assert has_element?(lv, "#bot-budget-search_engine-ceiling", "at most 100% here")
    assert has_element?(lv, ~s(#bot-budget-declared_bot input[max="50"]))
    refute has_element?(lv, "#bot-budgets-search-warning")
    refute has_element?(lv, "button", "Use the server's values")
    assert html =~ "It is not access control"
  end

  test "the server's own values are shown as such", %{conn: conn, org: org} do
    put_classes(%{search_engine: 400})
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, "#bot-budget-search_engine-effective", "1200 requests a minute")
    assert has_element?(lv, "#bot-budget-search_engine-effective", "Server setting")
    assert has_element?(lv, "#bot-budget-search_engine-ceiling", "at most 400% here")
  end

  test "an admin saves a value for this site only, and it is audited", %{conn: conn, org: org} do
    other = org("botbudgetslive-other")
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#bot-budgets-form", bot_budgets: %{"empty_percent" => "10"})
      |> render_submit()

    assert html =~ "Bot budgets saved."
    assert has_element?(lv, "#bot-budget-empty-effective", "30 requests a minute")
    assert has_element?(lv, "#bot-budget-empty-effective", "Set for this site")

    assert {:ok, [row]} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    assert row.empty_percent == 10
    assert row.declared_bot_percent == nil
    assert {:ok, []} = CMS.list_site_bot_budgets(tenant: other, authorize?: false)

    assert [event] =
             KilnCMS.Security.list_events!(authorize?: false, tenant: org, page: [limit: 50])
             |> Map.get(:results)
             |> Enum.filter(&(&1.type == :org_setting_changed))

    assert event.metadata == %{"setting" => "site_bot_budgets"}
  end

  describe "search-engine verification (#2254)" do
    test "the hints say a claim is checked and a false one counts as no user agent",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      assert has_element?(lv, "#bot-budget-search_engine", "checks out as theirs")
      assert has_element?(lv, "#bot-budget-search_engine", "A claim proven false counts as")
      assert has_element?(lv, "#bot-budget-empty", "proven not to be them")
      refute has_element?(lv, "#bot-budget-search_engine-unchecked")
    end

    test "with verification off, the page says claims are not checked", %{conn: conn, org: org} do
      previous = Application.get_env(:kiln_cms, KilnCMS.CrawlerVerification)

      # VM-global application env; this module is async: false.
      Application.put_env(
        :kiln_cms,
        KilnCMS.CrawlerVerification,
        Keyword.put(previous || [], :enabled, false)
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.CrawlerVerification, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.CrawlerVerification)
      end)

      {:ok, lv, _html} = admin_live(conn, org)

      assert has_element?(
               lv,
               "#bot-budget-search_engine-unchecked",
               "does not check search-engine claims"
             )
    end
  end

  test "a lowered search engine budget is warned about", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    lv
    |> form("#bot-budgets-form", bot_budgets: %{"search_engine_percent" => "50"})
    |> render_submit()

    assert has_element?(lv, "#bot-budgets-search-warning", "refused sooner than browsers")
  end

  describe "invalid input" do
    test "a value above the server's is refused with the ceiling", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      html =
        lv
        |> form("#bot-budgets-form", bot_budgets: %{"declared_bot_percent" => "60"})
        |> render_submit()

      assert html =~ "At most 50%: this server&#39;s operator caps it there."
      assert {:ok, []} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    end

    test "something that is not a whole number in range is refused", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      for value <- ["abc", "0", "1001", "2.5"] do
        html =
          lv
          |> form("#bot-budgets-form", bot_budgets: %{"empty_percent" => value})
          |> render_submit()

        assert html =~ "Enter a whole number from 1 to 1000", value
      end

      assert {:ok, []} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    end
  end

  test "a stored value above a lowered server value is shown as clamped, and the rest can still be saved",
       %{conn: conn, org: org} do
    CMS.save_site_bot_budgets!(%{declared_bot_percent: 40}, authorize?: false, tenant: org)
    put_classes(%{declared_bot: 25})

    {:ok, lv, _html} = admin_live(conn, org)
    assert has_element?(lv, "#bot-budget-declared_bot-effective", "25%")

    assert has_element?(
             lv,
             "#bot-budget-declared_bot-effective",
             "above what the server now allows"
           )

    # The input must admit the stored 40, or a real browser's constraint check
    # blocks submitting the whole form (LiveViewTest does not run it).
    assert has_element?(
             lv,
             ~s(#bot-budget-declared_bot input[name="bot_budgets[declared_bot_percent]"][max="40"])
           )

    # The form still carries the stored 40; saving another field is allowed.
    html =
      lv
      |> form("#bot-budgets-form", bot_budgets: %{"empty_percent" => "10"})
      |> render_submit()

    assert html =~ "Bot budgets saved."
    assert {:ok, [row]} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    assert row.empty_percent == 10
    assert row.declared_bot_percent == 40
  end

  test "using the server's values drops the row", %{conn: conn, org: org} do
    CMS.save_site_bot_budgets!(%{empty_percent: 5}, authorize?: false, tenant: org)
    {:ok, lv, _html} = admin_live(conn, org)

    html = lv |> element("button", "Use the server's values") |> render_click()

    assert html =~ "reset to the server&#39;s values"
    assert {:ok, []} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    assert has_element?(lv, "#bot-budget-empty-effective", "Default")
  end

  test "an admin demoted after mounting can neither save nor reset", %{conn: conn, org: org} do
    CMS.save_site_bot_budgets!(%{empty_percent: 5}, authorize?: false, tenant: org)
    user = authed_user(:editor)
    membership = grant_tier(user, org, :admin)

    {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/bot-budgets")

    Ash.Seed.update!(membership, %{role: :editor})

    html =
      lv
      |> form("#bot-budgets-form", bot_budgets: %{"empty_percent" => "7"})
      |> render_submit()

    assert html =~ "don&#39;t have permission"

    html = lv |> element("button", "Use the server's values") |> render_click()
    assert html =~ "don&#39;t have permission"

    assert {:ok, [row]} = CMS.list_site_bot_budgets(tenant: org, authorize?: false)
    assert row.empty_percent == 5
  end

  defp admin_live(conn, org) do
    user = authed_user(:editor)
    grant_tier(user, org, :admin)
    conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/bot-budgets")
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "botbudgetslive-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
