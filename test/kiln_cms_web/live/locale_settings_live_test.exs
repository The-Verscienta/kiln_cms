defmodule KilnCMSWeb.LocaleSettingsLiveTest do
  @moduledoc """
  `/editor/locales`: the admin gate, and that the three answers a locale row
  can give — the default locale, an explicit chain, never — land in the saved
  map as three different things.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = org("localeslive")
    on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(org.id) end)
    %{org: org}
  end

  test "turns away a non-admin", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/locales")
  end

  test "shows the site on the deployment defaults, with each locale's walk", %{
    conn: conn,
    org: org
  } do
    {:ok, _lv, html} = admin_live(conn, org)

    assert html =~ "using the deployment defaults"
    # No chains configured: every locale falls back to the default.
    assert html =~ "es → en"
  end

  test "saves the three answers as three different things", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#locale-settings-form",
        fallbacks: %{
          "es" => %{"mode" => "chain", "chain" => "fr, en"},
          "fr" => %{"mode" => "none", "chain" => ""},
          "en" => %{"mode" => "default", "chain" => ""}
        }
      )
      |> render_submit()

    assert html =~ "Locale fallbacks saved."
    assert html =~ "es → fr → en"

    assert {:ok, [row]} = CMS.list_site_locale_settings(tenant: org, authorize?: false)
    assert row.fallbacks == %{"es" => ["fr", "en"], "fr" => []}
  end

  test "an unknown locale is refused with the reason, and nothing is saved", %{
    conn: conn,
    org: org
  } do
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#locale-settings-form",
        fallbacks: %{"es" => %{"mode" => "chain", "chain" => "fr_CA"}}
      )
      |> render_submit()

    assert html =~ "not a locale this site runs"
    assert {:ok, []} = CMS.list_site_locale_settings(tenant: org, authorize?: false)
  end

  test "reset drops the row and goes back to the deployment defaults", %{conn: conn, org: org} do
    CMS.save_site_locale_settings!(%{fallbacks: %{"es" => []}}, authorize?: false, tenant: org.id)

    {:ok, lv, _html} = admin_live(conn, org)
    html = lv |> element("button", "Use the operator defaults") |> render_click()

    assert html =~ "reset to the operator defaults"
    assert {:ok, []} = CMS.list_site_locale_settings(tenant: org, authorize?: false)
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/locales")
  end

  defp authed_user(role) do
    email = "localeslive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
