defmodule KilnCMSWeb.SessionPolicyLiveTest do
  @moduledoc """
  `/editor/sessions` (#2246): the admin gate, saving an idle timeout for the
  request's org only (and the audit event it records), the refusal of an
  administrators' timeout longer than everyone's, and "Off" keeping the row
  that holds the "sign out everyone" watermark. Signing everyone out from this
  page is in `KilnCMSWeb.IdleTimeoutTest`, beside the browsers it affects.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Security

  @password "password1234!"

  setup do
    %{org: org("sessionpolicylive")}
  end

  test "turns away an editor and a viewer", %{conn: conn} do
    for role <- [:editor, :viewer] do
      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> log_in(authed_user(role)) |> live(~p"/editor/sessions")
    end
  end

  test "turns away a visitor who is not signed in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/sessions")
  end

  test "shows no timeout when nothing is set", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, "#session-policy-form select option[value=''][selected]")
    assert has_element?(lv, "#session-policy-current", "No idle timeout is set")
    assert has_element?(lv, "#sign-out-all")
  end

  test "an admin saves a timeout, only for this org, and it is logged", %{conn: conn, org: org} do
    other = org("sessionpolicyother")
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#session-policy-form",
        session_policy: %{"idle_timeout_minutes" => "60", "admin_idle_timeout_minutes" => "15"}
      )
      |> render_submit()

    assert html =~ "Session settings saved."
    assert has_element?(lv, "#session-policy-current", "signs idle browsers out")

    assert {:ok, [row]} = CMS.list_site_session_policy(tenant: org, authorize?: false)
    assert row.idle_timeout_minutes == 60
    assert row.admin_idle_timeout_minutes == 15
    assert {:ok, []} = CMS.list_site_session_policy(tenant: other, authorize?: false)

    events =
      Security.list_events!(actor: authed_user(:admin), tenant: org.id, page: [limit: 20])
      |> Map.get(:results)
      |> Enum.filter(&(&1.type == :org_setting_changed))

    assert [_event] = events
  end

  test "refuses an administrators' timeout longer than everyone's", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#session-policy-form",
        session_policy: %{"idle_timeout_minutes" => "15", "admin_idle_timeout_minutes" => "60"}
      )
      |> render_submit()

    assert html =~ "can&#39;t be longer than the time for everyone"
    assert {:ok, []} = CMS.list_site_session_policy(tenant: org, authorize?: false)
  end

  test "a value that is not a number saves nothing", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    render_submit(lv, "save", %{"session_policy" => %{"idle_timeout_minutes" => "soon"}})

    assert {:ok, []} = CMS.list_site_session_policy(tenant: org, authorize?: false)
  end

  test "turning it off keeps the row, and its sign-out-everyone watermark", %{
    conn: conn,
    org: org
  } do
    CMS.record_sessions_revoked!(%{at: DateTime.utc_now()}, authorize?: false, tenant: org.id)
    CMS.save_site_session_policy!(%{idle_timeout_minutes: 30}, authorize?: false, tenant: org.id)
    {:ok, lv, _html} = admin_live(conn, org)

    lv
    |> form("#session-policy-form",
      session_policy: %{"idle_timeout_minutes" => "", "admin_idle_timeout_minutes" => ""}
    )
    |> render_submit()

    assert {:ok, [row]} = CMS.list_site_session_policy(tenant: org, authorize?: false)
    assert row.idle_timeout_minutes == nil
    assert %DateTime{} = row.sessions_revoked_at
  end

  test "malformed payloads change nothing and do not crash the page", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    render_submit(lv, "save", %{"session_policy" => "not a map"})
    render_submit(lv, "save", %{"session_policy" => %{"idle_timeout_minutes" => ["30"]}})

    assert render(lv) =~ "Sign out when idle"
    assert {:ok, []} = CMS.list_site_session_policy(tenant: org, authorize?: false)

    # A keep flag of the wrong shape is not "keep me": the sign-out runs, and
    # this page — signed out with everyone — goes to sign-in rather than crashing.
    render_submit(lv, "sign_out_all", %{"sign_out_all" => "keep"})
    assert_redirect(lv, ~p"/sign-in", 1_000)
  end

  test "a saved time that is not a preset is still shown", %{conn: conn, org: org} do
    CMS.save_site_session_policy!(%{idle_timeout_minutes: 10}, authorize?: false, tenant: org.id)
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, "#session-policy-form select option[value='10'][selected]")
  end

  test "the console nav lists the page for an admin", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, ~s(nav a[href="/editor/sessions"]))
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/sessions")
  end

  defp authed_user(role) do
    email = "sessionpolicylive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
