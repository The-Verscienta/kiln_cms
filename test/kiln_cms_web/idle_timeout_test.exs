defmodule KilnCMSWeb.IdleTimeoutTest do
  @moduledoc """
  The idle timeout and "sign out everyone" (#2246) through the real sign-in
  controller, the real plugs and real LiveViews, on a site's own host.

  What is asserted is the effect on a browser: its next request is served
  signed out, its open page goes to sign-in, its remember-me cookie stops
  signing it in. Every "before" is asserted too, so no test passes because the
  credential never worked.

  The test's transaction freezes the database's `now()` at its start, so a
  policy saved during a test is "just now" and its clamp would hide any idle
  time; `aged_policy!/2` moves the save a day back.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Repo

  @password "password123456"
  @firefox "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:126.0) Gecko/20100101 Firefox/126.0"

  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  defp uniq, do: System.unique_integer([:positive])

  # A platform admin by default: an admin on every site, so a refusal on a
  # second site's host is the session's, never the account's tier.
  defp account(role \\ :admin) do
    Ash.Seed.seed!(User, %{
      email: "idle-web-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, site, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp sign_in(user, site, params \\ %{}) do
    build_conn()
    |> org_conn(site)
    |> unique_ip()
    |> put_req_header("user-agent", @firefox)
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => @password}, params)
    })
  end

  # That browser's next request, on `site`'s host (its own by default).
  defp session_of(signed_in, site \\ nil) do
    conn = signed_in |> recycle() |> unique_ip() |> put_req_header("user-agent", @firefox)
    if site, do: org_conn(conn, site), else: conn
  end

  defp jti_of(signed_in), do: Token.peeked_jti(get_session(signed_in, :user_token))

  defp settings(conn), do: live(conn, ~p"/editor/settings")

  defp signed_out?(conn),
    do: match?({:error, {:redirect, %{to: "/sign-in"}}}, settings(conn))

  defp remembered_as(token, site) do
    build_conn()
    |> org_conn(site)
    |> unique_ip()
    |> Plug.Test.put_req_cookie(@cookie, token)
    |> get(~p"/sign-in")
  end

  defp row(jti), do: Repo.one!(from(t in Token, where: t.jti == ^jti))

  defp idle_for!(jti, seconds) do
    Repo.query!(
      "UPDATE tokens SET last_used_at = (now() AT TIME ZONE 'utc') - make_interval(secs => $1) WHERE jti = $2",
      [seconds * 1.0, jti]
    )
  end

  defp aged_policy!(site, attrs) do
    CMS.save_site_session_policy!(attrs, authorize?: false, tenant: site.id)

    Repo.query!(
      "UPDATE site_session_policy SET policy_changed_at = (now() AT TIME ZONE 'utc') - interval '1 day' WHERE org_id = $1",
      [Ecto.UUID.dump!(site.id)]
    )

    KilnCMS.Cache.bust_session_policy(site.id)
  end

  defp idle_state(lv) do
    %{socket: socket} = :sys.get_state(lv.pid)
    socket.private[:kiln_idle]
  end

  setup do
    %{site: org("idle-web")}
  end

  describe "a request" do
    test "past the timeout is served signed out, and sign-in says why", %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      refute signed_out?(session_of(browser))

      idle_for!(jti, 16 * 60)
      assert signed_out?(session_of(browser))
      assert %{purpose: "revocation", revoked_reason: "idle"} = row(jti)

      html = session_of(browser) |> get(~p"/sign-in") |> html_response(200)
      assert html =~ "signed out after a period of inactivity"
    end

    test "on a public page writes no cookie, signed in or expired", %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      # The first request after a sign-in consumes its flash and mints a CSRF
      # token, both session writes whatever this plug does; the claim is about
      # the requests after it, each carrying the cookie the last one left.
      warm = session_of(browser) |> get(~p"/search?q=x")

      active = session_of(warm) |> get(~p"/search?q=x")
      assert active.assigns.current_user
      assert get_resp_header(active, "set-cookie") == []

      idle_for!(jti, 16 * 60)
      expired = session_of(active) |> get(~p"/search?q=x")

      assert expired.assigns.current_user == nil
      assert row(jti).purpose == "revocation"
      assert get_resp_header(expired, "set-cookie") == []
    end

    test "within the timeout stays signed in and notes the use, at most once per interval",
         %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)

      idle_for!(jti, 120)
      aged = row(jti).last_used_at

      assert session_of(browser)
             |> get(~p"/search?q=x")
             |> Map.get(:assigns)
             |> Map.get(:current_user)

      touched = row(jti).last_used_at
      assert DateTime.compare(touched, aged) == :gt

      # Inside the 90-second interval of a 15-minute timeout: no write.
      idle_for!(jti, 30)
      thirty = row(jti).last_used_at
      session_of(browser) |> get(~p"/search?q=x")
      assert row(jti).last_used_at == thirty
    end

    test "with no policy, nothing ends a session for being idle", %{site: site} do
      browser = sign_in(account(), site)
      idle_for!(jti_of(browser), 3 * 86_400)

      refute signed_out?(session_of(browser))
    end

    test "an admin is held to the shorter administrators' timeout, an editor is not",
         %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 60, admin_idle_timeout_minutes: 15})
      admin = sign_in(account(:admin), site)
      editor = sign_in(account(:viewer) |> member!(site, :editor), site)

      idle_for!(jti_of(admin), 20 * 60)
      idle_for!(jti_of(editor), 20 * 60)

      assert signed_out?(session_of(admin))
      refute signed_out?(session_of(editor))
    end

    test "a session copied to another site's host is signed out there, and never touched",
         %{site: site} do
      other = org("idle-web-other")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      idle_for!(jti, 120)
      before = row(jti)

      assert signed_out?(session_of(browser, other))

      after_replay = row(jti)
      assert after_replay.purpose == "user"
      assert after_replay.last_used_at == before.last_used_at
      # Still good at home.
      refute signed_out?(session_of(browser, site))
    end
  end

  test "the settings page says when this site signs browsers out", %{site: site} do
    browser = sign_in(account(:viewer) |> member!(site, :editor), site)
    {:ok, lv, _html} = settings(session_of(browser))
    refute has_element?(lv, "#sessions-idle-timeout")

    aged_policy!(site, %{idle_timeout_minutes: 30})
    {:ok, lv, _html} = settings(session_of(browser))
    assert has_element?(lv, "#sessions-idle-timeout", "after 30 minutes without activity")
  end

  describe "a session bound to another site" do
    test "gets no signed-in render of a signed-in page on that host", %{site: site} do
      other = org("idle-web-dead")
      browser = sign_in(account(), site)

      conn = session_of(browser, other) |> get(~p"/editor/settings")
      assert redirected_to(conn) == ~p"/sign-in"

      assert session_of(browser, site) |> get(~p"/editor/settings") |> html_response(200)
    end

    test "is anonymous on an anonymous-tolerant page there, and not touched", %{site: site} do
      other = org("idle-web-optional")
      user = account()
      browser = sign_in(user, site)
      jti = jti_of(browser)
      idle_for!(jti, 600)
      before = row(jti).last_used_at

      {:ok, lv, _html} = live(session_of(browser, other), ~p"/membership")
      assert :sys.get_state(lv.pid).socket.assigns.current_user == nil
      assert row(jti).last_used_at == before

      {:ok, home, _html} = live(session_of(browser, site), ~p"/membership")
      assert :sys.get_state(home.pid).socket.assigns.current_user.id == user.id
    end
  end

  describe "remember-me" do
    test "signs in within the timeout; past it, does not, and the cookie is deleted",
         %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      user = account()
      browser = sign_in(user, site, %{"remember_me" => "true"})
      cookie = browser.resp_cookies[@cookie].value
      cookie_jti = Token.peeked_jti(cookie)

      assert row(cookie_jti).org_id == site.id
      assert remembered_as(cookie, site).assigns.current_user.id == user.id

      idle_for!(cookie_jti, 16 * 60)
      conn = remembered_as(cookie, site)

      assert conn.assigns.current_user == nil
      assert %{max_age: 0} = conn.resp_cookies[@cookie]
      assert html_response(conn, 200) =~ "signed out after a period of inactivity"
      assert %{purpose: "revocation", revoked_reason: "idle"} = row(cookie_jti)
    end

    test "a forged cookie naming someone else's row changes nothing", %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      victim = account()
      browser = sign_in(victim, site, %{"remember_me" => "true"})
      cookie = browser.resp_cookies[@cookie].value
      cookie_jti = Token.peeked_jti(cookie)
      idle_for!(cookie_jti, 3600)
      Repo.query!("UPDATE tokens SET org_id = NULL WHERE jti = $1", [cookie_jti])

      # Same claims, broken signature: a peek reads the victim's jti from it.
      [header, payload, _signature] = String.split(cookie, ".")
      forged = Enum.join([header, payload, "forged"], ".")
      assert Token.peeked_jti(forged) == cookie_jti

      # Neither the remember-me check nor a sign-in carrying it acts on the row.
      assert remembered_as(forged, site).assigns.current_user == nil

      attacker = account()

      build_conn()
      |> org_conn(site)
      |> unique_ip()
      |> Plug.Test.put_req_cookie(@cookie, forged)
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post(~p"/auth/user/password/sign_in", %{
        "user" => %{"email" => to_string(attacker.email), "password" => @password}
      })

      victim_row = row(cookie_jti)
      assert victim_row.purpose == "remember_me"
      assert victim_row.revoked_reason == nil
      assert victim_row.org_id == nil
    end

    test "a cookie copied to another site's host does not sign in there", %{site: site} do
      other = org("idle-web-rm-other")
      user = account()
      browser = sign_in(user, site, %{"remember_me" => "true"})
      cookie = browser.resp_cookies[@cookie].value

      assert remembered_as(cookie, other).assigns.current_user == nil
      assert row(Token.peeked_jti(cookie)).purpose == "remember_me"
      assert remembered_as(cookie, site).assigns.current_user.id == user.id
    end
  end

  describe "an open page" do
    test "goes to sign-in when its timer finds the session idle", %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      {:ok, lv, _html} = settings(session_of(browser))
      assert is_reference(idle_state(lv).timer)

      idle_for!(jti, 16 * 60)
      send(lv.pid, {:kiln_idle_check, jti})

      flash = assert_redirect(lv, ~p"/sign-in", 1_000)
      assert flash["info"] =~ "period of inactivity"
      assert row(jti).revoked_reason == "idle"
    end

    test "stays open when another tab kept the session awake", %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      {:ok, lv, _html} = settings(session_of(browser))

      idle_for!(jti, 10)
      send(lv.pid, {:kiln_idle_check, jti})

      assert render(lv) =~ "Active sessions"
      assert row(jti).purpose == "user"
      assert is_reference(idle_state(lv).timer)
    end

    test "an event counts as activity, the first one after a mount included",
         %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      # A mount that writes nothing — a rejoin, or a use inside the interval.
      {:ok, lv, _html} = live(session_of(browser), ~p"/editor/sessions")

      idle_for!(jti, 120)
      aged = row(jti).last_used_at

      render_submit(lv, "save", %{})
      assert DateTime.compare(row(jti).last_used_at, aged) == :gt
    end

    test "a patch counts as activity; the mount's own params do not write twice",
         %{site: site} do
      aged_policy!(site, %{idle_timeout_minutes: 15})
      browser = sign_in(account(), site)
      jti = jti_of(browser)
      {:ok, lv, _html} = live(session_of(browser), ~p"/editor/security-log")
      assert idle_state(lv).params_seen?

      idle_for!(jti, 120)
      aged = row(jti).last_used_at

      render_patch(lv, ~p"/editor/security-log?type=sign_in")
      assert DateTime.compare(row(jti).last_used_at, aged) == :gt
    end

    test "a reply a hook sends on its own is not activity" do
      refute KilnCMSWeb.IdleSession.activity_event?("body_flushed")
      refute KilnCMSWeb.IdleSession.activity_event?("push_state")
      refute KilnCMSWeb.IdleSession.activity_event?("push_unsupported")
      assert KilnCMSWeb.IdleSession.activity_event?("rich_text_body")
      assert KilnCMSWeb.IdleSession.activity_event?("save")
    end

    test "a timeout turned on after it opened applies to it, from then on", %{site: site} do
      user = account()
      browser = sign_in(user, site)
      jti = jti_of(browser)
      {:ok, lv, _html} = settings(session_of(browser))
      assert idle_state(lv).timer == nil

      # Two hours idle before the timeout exists.
      idle_for!(jti, 2 * 3600)

      {:ok, _} =
        CMS.save_site_session_policy(%{idle_timeout_minutes: 15}, actor: user, tenant: site.id)

      KilnCMS.Test.Eventually.eventually(fn -> is_reference(idle_state(lv).timer) end,
        timeout_ms: 5_000,
        message: fn -> "the page never armed its idle timer" end
      )

      assert render(lv) =~ "Active sessions"
      assert row(jti).purpose == "user"
    end
  end

  describe "sign out everyone" do
    test "sends another browser's open page to sign-in, saying an admin did it",
         %{site: site} do
      admin = account()
      victim = sign_in(account(:viewer) |> member!(site, :editor), site)
      {:ok, victim_lv, _html} = settings(session_of(victim))

      {:ok, 1} = CMS.sign_out_all_sessions(%{}, actor: admin, tenant: site.id)

      flash = assert_redirect(victim_lv, ~p"/sign-in", 1_000)
      assert flash["info"] =~ "An administrator signed everyone out"
      assert signed_out?(session_of(victim))
    end

    test "keeps the admin who asked, on this browser", %{site: site} do
      admin_browser = sign_in(account(), site)
      victim = sign_in(account(:viewer) |> member!(site, :editor), site)
      {:ok, victim_lv, _html} = settings(session_of(victim))
      {:ok, lv, _html} = live(session_of(admin_browser), ~p"/editor/sessions")

      html =
        lv
        |> form("#sign-out-all-form", sign_out_all: %{"keep_me" => "true"})
        |> render_submit()

      assert html =~ "Signed out 1 session on this site."
      assert_redirect(victim_lv, ~p"/sign-in", 1_000)
      refute signed_out?(session_of(admin_browser))
    end

    test "signs the admin out too when not asked to keep them", %{site: site} do
      admin_browser = sign_in(account(), site)
      {:ok, lv, _html} = live(session_of(admin_browser), ~p"/editor/sessions")

      lv
      |> form("#sign-out-all-form", sign_out_all: %{"keep_me" => "false"})
      |> render_submit()

      flash = assert_redirect(lv, ~p"/sign-in", 1_000)
      assert flash["info"] =~ "An administrator signed everyone out"
      assert signed_out?(session_of(admin_browser))
    end
  end
end
