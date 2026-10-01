defmodule KilnCMSWeb.SettingsSessionsTest do
  @moduledoc """
  The active-sessions list on `/editor/settings` (#1823), through the real
  sign-in controller and the real plugs.

  What is asserted is the EFFECT on a browser — its next request is signed out,
  its open page is closed, its remember-me cookie stops working — never only
  that a row changed. Every "before" is asserted too, so no test can pass
  because the credential never worked in the first place.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Ecto.Query

  require Ash.Query
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @password "password123456"
  @new_password "brand-new-password-789"

  @firefox_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:126.0) Gecko/20100101 Firefox/126.0"
  @chrome_windows "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
  @safari_iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  defp account(email_prefix \\ "sessions") do
    Ash.Seed.seed!(User, %{
      email: "#{email_prefix}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # A browser signing in through the real controller, as `user_agent`.
  defp sign_in(user, user_agent, params \\ %{}, password \\ @password) do
    build_conn()
    |> unique_ip()
    |> put_req_header("user-agent", user_agent)
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => password}, params)
    })
  end

  # That browser's next request: its session cookie, nothing else.
  defp session_of(signed_in), do: signed_in |> recycle() |> unique_ip()

  defp jti_of(signed_in), do: Token.peeked_jti(get_session(signed_in, :user_token))

  defp settings(conn), do: live(conn, ~p"/editor/settings")

  defp signed_out?(conn),
    do: match?({:error, {:redirect, %{to: "/sign-in"}}}, settings(conn))

  # A request carrying only the remember-me cookie, on the pipeline that reads it.
  defp remembered_as(token) do
    build_conn()
    |> unique_ip()
    |> Plug.Test.put_req_cookie(@cookie, token)
    |> get(~p"/sign-in")
    |> Map.get(:assigns)
    |> Map.get(:current_user)
  end

  defp row(jti), do: Repo.one!(from t in Token, where: t.jti == ^jti)

  describe "recording a session" do
    test "the sign-in notes the browser, coarsely, and the remember-me cookie it issued" do
      user = account()
      browser = sign_in(user, @firefox_mac, %{"remember_me" => "true"})
      cookie = browser.resp_cookies[@cookie].value

      session = row(jti_of(browser))
      assert session.browser == "Firefox"
      assert session.platform == "macOS"
      assert %DateTime{} = session.last_used_at
      assert session.remember_me_jti == Token.peeked_jti(cookie)
    end

    test "no user agent string and no address is kept" do
      user = account()
      browser = sign_in(user, @firefox_mac)

      stored = row(jti_of(browser)) |> Map.from_struct() |> inspect()
      refute stored =~ "Gecko"
      refute stored =~ "127.0.0"
    end

    test "a page load notes the session was used, at most once per interval" do
      user = account()
      browser = sign_in(user, @firefox_mac)
      jti = jti_of(browser)

      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      Repo.update_all(from(t in "tokens", where: t.jti == ^jti), set: [last_used_at: long_ago])

      {:ok, _lv, _html} = settings(session_of(browser))
      bumped = row(jti).last_used_at
      assert DateTime.compare(bumped, long_ago) == :gt

      # A second page load inside the interval writes nothing.
      {:ok, _lv, _html} = settings(session_of(browser))
      assert row(jti).last_used_at == bumped
    end
  end

  describe "the list" do
    test "shows each browser, marks this one, and offers sign-out only for the others" do
      user = account()
      here = sign_in(user, @firefox_mac)
      elsewhere = sign_in(user, @chrome_windows)

      {:ok, lv, _html} = settings(session_of(here))

      assert has_element?(lv, "#settings-sessions", "Active sessions")
      assert has_element?(lv, "#session-list li", "Firefox on macOS")
      assert has_element?(lv, "#session-list li", "Chrome on Windows")
      assert has_element?(lv, "#session-list li:first-child", "This session")
      assert has_element?(lv, "#session-list li:first-child", "Active now")

      refute has_element?(lv, ~s(button[phx-value-id="#{jti_of(here)}"]))
      assert has_element?(lv, ~s(button[phx-value-id="#{jti_of(elsewhere)}"]), "Sign out")
      assert has_element?(lv, "#sign-out-other-sessions")
    end

    test "lists only this account's sessions" do
      user = account()
      other = account("someone-else")
      here = sign_in(user, @firefox_mac)
      theirs = sign_in(other, @chrome_windows)

      {:ok, lv, _html} = settings(session_of(here))

      refute has_element?(lv, "#session-list li", "Chrome on Windows")
      refute has_element?(lv, ~s(button[phx-value-id="#{jti_of(theirs)}"]))
      assert has_element?(lv, "#sessions-only-this")
      refute has_element?(lv, "#sign-out-other-sessions")
    end
  end

  describe "signing out one session" do
    test "signs that browser out on its next request, and its remember-me cookie with it" do
      user = account()
      here = sign_in(user, @firefox_mac)
      phone = sign_in(user, @safari_iphone, %{"remember_me" => "true"})
      phone_cookie = phone.resp_cookies[@cookie].value

      refute signed_out?(session_of(phone))
      assert remembered_as(phone_cookie).id == user.id

      {:ok, lv, _html} = settings(session_of(here))
      lv |> element(~s(button[phx-value-id="#{jti_of(phone)}"])) |> render_click()

      assert render(lv) =~ "Signed out of that session."
      refute has_element?(lv, "#session-list li", "Safari on iOS")

      assert signed_out?(session_of(phone))
      assert remembered_as(phone_cookie) == nil
      # And this browser is untouched.
      refute signed_out?(session_of(here))
    end

    test "closes the page that session has open, right away" do
      user = account()
      here = sign_in(user, @firefox_mac)
      elsewhere = sign_in(user, @chrome_windows)

      {:ok, their_lv, _html} = settings(session_of(elsewhere))
      {:ok, lv, _html} = settings(session_of(here))

      lv |> element(~s(button[phx-value-id="#{jti_of(elsewhere)}"])) |> render_click()

      flash = assert_redirect(their_lv, ~p"/sign-in", 1_000)
      assert flash["info"] =~ "signed out from another device"
      # And it cannot come back: the rejoin (or any request) finds the token gone.
      assert signed_out?(session_of(elsewhere))

      # The page that did it stays open.
      assert render(lv) =~ "Signed out of that session."
    end

    test "cannot sign out another account's session" do
      user = account()
      other = account("victim")
      here = sign_in(user, @firefox_mac)
      theirs = sign_in(other, @chrome_windows)
      {:ok, their_lv, _html} = settings(session_of(theirs))

      {:ok, lv, _html} = settings(session_of(here))
      html = render_click(lv, "sign_out_session", %{"id" => jti_of(theirs)})

      assert html =~ "That session has already ended."
      refute signed_out?(session_of(theirs))
      assert Process.alive?(their_lv.pid)
      assert row(jti_of(theirs)).purpose == "user"

      # And at the action, not just the page: the policy narrows to own rows.
      their_jti = jti_of(theirs)
      query = Ash.Query.filter(Token, jti == ^their_jti)

      assert %Ash.BulkResult{records: []} =
               Accounts.revoke_own_sessions(query, %{},
                 actor: user,
                 bulk_options: [
                   strategy: :atomic,
                   read_action: :own_tokens,
                   return_records?: true,
                   return_errors?: true
                 ]
               )

      assert row(jti_of(theirs)).purpose == "user"
      assert {:error, :not_found} = Sessions.revoke(user, jti_of(theirs))
      refute Enum.any?(Sessions.list(user), &(&1.jti == jti_of(theirs)))
    end

    test "an admin cannot read or revoke someone else's sessions either" do
      admin =
        Ash.Seed.seed!(User, %{
          email: "admin-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      other = account("member")
      theirs = sign_in(other, @chrome_windows)

      assert {:ok, []} = Accounts.list_own_sessions(actor: admin)
      assert {:error, :not_found} = Sessions.revoke(admin, jti_of(theirs))
      refute signed_out?(session_of(theirs))
    end
  end

  describe "signing out of all other sessions" do
    test "keeps this browser and its remember-me cookie, and signs out everything else" do
      user = account()
      here = sign_in(user, @firefox_mac, %{"remember_me" => "true"})
      here_cookie = here.resp_cookies[@cookie].value
      laptop = sign_in(user, @chrome_windows)
      phone = sign_in(user, @safari_iphone, %{"remember_me" => "true"})
      phone_cookie = phone.resp_cookies[@cookie].value

      {:ok, laptop_lv, _html} = settings(session_of(laptop))
      refute signed_out?(session_of(phone))
      assert remembered_as(phone_cookie).id == user.id

      {:ok, lv, _html} = settings(session_of(here))
      lv |> element("#sign-out-other-sessions") |> render_click()

      # Three: the laptop, the phone, and the session the phone's cookie
      # signed in on its own just above — a remember-me cookie is a sign-in.
      assert render(lv) =~ "Signed out of 3 other sessions."
      assert has_element?(lv, "#sessions-only-this")

      assert signed_out?(session_of(laptop))
      assert signed_out?(session_of(phone))
      assert remembered_as(phone_cookie) == nil
      assert_redirect(laptop_lv, ~p"/sign-in", 1_000)

      # This one keeps working, and so does its own remember-me cookie.
      refute signed_out?(session_of(here))
      assert remembered_as(here_cookie).id == user.id
    end

    test "with nothing else signed in, says so" do
      user = account()
      here = sign_in(user, @firefox_mac)

      {:ok, lv, _html} = settings(session_of(here))
      assert render_click(lv, "sign_out_other_sessions", %{}) =~ "anywhere else"
      refute signed_out?(session_of(here))
    end
  end

  describe "a password change" do
    test "still ends every other session, and the list shows it" do
      user = account()
      here = sign_in(user, @firefox_mac)
      elsewhere = sign_in(user, @chrome_windows)

      {:ok, lv, _html} = settings(session_of(here))

      lv
      |> form("#password-form",
        user: %{
          "current_password" => @password,
          "password" => @new_password,
          "password_confirmation" => @new_password
        }
      )
      |> render_submit()

      assert signed_out?(session_of(elsewhere))
      assert Sessions.list(user) == []

      again = sign_in(user, @safari_iphone, %{}, @new_password)
      {:ok, lv, _html} = settings(session_of(again))

      assert has_element?(lv, "#session-list li", "Safari on iOS")
      refute has_element?(lv, "#session-list li", "Chrome on Windows")
      assert has_element?(lv, "#sessions-only-this")
    end
  end
end
