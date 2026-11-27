defmodule KilnCMSWeb.SessionPolicyLiveTest do
  @moduledoc """
  `/editor/sessions` (#2246): the admin gate, saving an idle timeout for the
  request's org only (and the audit event it records), the refusal of an
  administrators' timeout longer than everyone's, and "Off" keeping the row
  that holds the "sign out everyone" watermark, and the platform admins'
  "Sign out everyone on every site" (#2491): who sees it, the phrase gate and
  the refusals. Signing everyone out from this page is in
  `KilnCMSWeb.IdleTimeoutTest`, beside the browsers it affects.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.SignOutEveryone
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

  test "says what sign-out-everyone also reaches", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(
             lv,
             "#sign-out-all-hint",
             "Sessions from before this was available are signed out the next time they're used here."
           )

    assert has_element?(lv, "#sign-out-all-hint", "Collaborative-editing rooms open")
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

  describe "sign out everyone on every site" do
    test "is hidden from a site admin who is not a platform admin", %{conn: conn, org: org} do
      site_admin = authed_user(:viewer)
      member!(site_admin, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(site_admin) |> live(~p"/editor/sessions")

      assert has_element?(lv, "#sign-out-all")
      refute has_element?(lv, "#session-sign-out-everyone")
      refute has_element?(lv, "#sign-out-everyone")
    end

    test "a platform admin sees it, with keep-this-session ticked", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      assert has_element?(lv, "#session-sign-out-everyone", SignOutEveryone.phrase())
      assert has_element?(lv, "#session-sign-out-everyone", "API keys keep working")

      assert has_element?(
               lv,
               "#sign-out-everyone-form input[type=checkbox][name='sign_out_everyone[keep_me]'][checked]"
             )
    end

    test "the button is disabled until the phrase matches", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      assert has_element?(lv, "#sign-out-everyone[disabled]")

      change(lv, "wrong.example.com")
      assert has_element?(lv, "#sign-out-everyone[disabled]")

      change(lv, " " <> String.upcase(SignOutEveryone.phrase()))
      assert has_element?(lv, "#sign-out-everyone")
      refute has_element?(lv, "#sign-out-everyone[disabled]")

      change(lv, "")
      assert has_element?(lv, "#sign-out-everyone[disabled]")
    end

    test "a wrong phrase submitted anyway signs nobody out", %{conn: conn, org: org} do
      victim = victim_session(org)
      {:ok, lv, _html} = admin_live(conn, org)

      html =
        render_submit(lv, "sign_out_everyone", %{
          "sign_out_everyone" => %{"confirmation" => "wrong.example.com", "keep_me" => "true"}
        })

      assert html =~ "type the server&#39;s host name exactly"
      assert live?(victim)
    end

    test "a hand-crafted event from a site admin is refused by the action", %{
      conn: conn,
      org: org
    } do
      victim = victim_session(org)
      site_admin = authed_user(:viewer)
      member!(site_admin, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(site_admin) |> live(~p"/editor/sessions")

      for event <- ["check_everyone_phrase", "sign_out_everyone"] do
        html =
          render_submit(lv, event, %{
            "sign_out_everyone" => %{
              "confirmation" => SignOutEveryone.phrase(),
              "keep_me" => "true"
            }
          })

        refute html =~ "Signed out"
      end

      assert render(lv) =~ "permission to sign everyone out on every site"
      refute has_element?(lv, "#session-sign-out-everyone")
      assert live?(victim)
    end

    test "malformed payloads sign nobody out and do not crash the page", %{conn: conn, org: org} do
      victim = victim_session(org)
      {:ok, lv, _html} = admin_live(conn, org)

      render_change(lv, "check_everyone_phrase", %{"sign_out_everyone" => "nope"})

      render_change(lv, "check_everyone_phrase", %{
        "sign_out_everyone" => %{"confirmation" => [1]}
      })

      render_submit(lv, "sign_out_everyone", %{"sign_out_everyone" => "nope"})
      render_submit(lv, "sign_out_everyone", %{"sign_out_everyone" => %{"confirmation" => [1]}})

      assert render(lv) =~ "Sign out everyone on every site"
      assert live?(victim)
    end
  end

  defp change(lv, typed) do
    lv
    |> form("#sign-out-everyone-form", sign_out_everyone: %{"confirmation" => typed})
    |> render_change()
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })
  end

  defp victim_session(org) do
    user = authed_user(:editor)

    Ash.Seed.seed!(KilnCMS.Accounts.Token, %{
      jti: "spl-victim-#{System.unique_integer([:positive])}",
      subject: "user?id=#{user.id}",
      purpose: "user",
      org_id: org.id,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }).jti
  end

  defp live?(jti) do
    KilnCMS.Repo.one!(from(t in KilnCMS.Accounts.Token, where: t.jti == ^jti, select: t.purpose)) !=
      "revocation"
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
