defmodule KilnCMSWeb.PasswordRotationTest do
  @moduledoc """
  A password change or reset signs every other device out — through the real
  plugs, not just the token rows (#734, #1637).

  The #1536 review's probe, as a regression: sign in with a session and a
  remember-me cookie, rotate the password, and both kept authenticating —
  because `log_out_everywhere apply_on_password_change?` never fires on either
  password action (see `KilnCMS.Accounts.Changes.RevokeAllTokens`). Every
  "before" below is asserted too, so a test cannot pass by the credential never
  having worked.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.User
  alias KilnCMS.TwoFactorFixtures

  @password "password123456"
  @new_password "brand-new-password-789"

  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  defp account do
    Ash.Seed.seed!(User, %{
      email: "rotation-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # A browser signing in through the real controller: the session it is left
  # with, and the remember-me cookie when the box was ticked.
  defp sign_in(user, params \\ %{}) do
    build_conn()
    |> unique_ip()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => @password}, params)
    })
  end

  # The next request from that browser: its session cookie, nothing else.
  defp session_of(signed_in), do: signed_in |> recycle() |> unique_ip()

  # Whether a browser's session still gets it into the console. Mounting is
  # `LiveUserAuth` resolving the session token, which is also exactly what an
  # evicted socket's reconnect runs.
  defp console(conn), do: live(conn, ~p"/editor/settings")

  defp signed_out?(conn) do
    match?({:error, {:redirect, %{to: "/sign-in"}}}, console(conn))
  end

  # A request carrying only the remember-me cookie, on the pipeline that reads
  # it (`:browser_auth`) — the cookie is a complete sign-in on its own.
  defp remembered_as(token) do
    build_conn()
    |> unique_ip()
    |> Plug.Test.put_req_cookie(@cookie, token)
    |> get(~p"/sign-in")
    |> Map.get(:assigns)
    |> Map.get(:current_user)
  end

  defp reset_token(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
    token
  end

  # The form `/password-reset/:token` posts, through the real plug and
  # `AuthController.success/4`.
  defp reset(user) do
    build_conn()
    |> unique_ip()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/reset", %{
      "user" => %{
        "reset_token" => reset_token(user),
        "password" => @new_password,
        "password_confirmation" => @new_password
      }
    })
  end

  defp change_in_settings(conn) do
    {:ok, lv, _html} = console(conn)

    lv
    |> form("#password-form",
      user: %{
        "current_password" => @password,
        "password" => @new_password,
        "password_confirmation" => @new_password
      }
    )
    |> render_submit()
  end

  describe "changing the password in settings" do
    test "signs out every other session and the remember-me cookie" do
      user = account()
      elsewhere = sign_in(user)
      remembered = sign_in(user, %{"remember_me" => "true"})
      cookie = remembered.resp_cookies[@cookie].value

      refute signed_out?(session_of(elsewhere))
      assert remembered_as(cookie).id == user.id

      here = sign_in(user)
      change_in_settings(session_of(here))

      assert signed_out?(session_of(elsewhere))
      assert remembered_as(cookie) == nil
    end

    # The decision, pinned: the device making the change is signed out too.
    # A LiveView cannot write the cookie a re-issued token would need, and the
    # rotation is the moment the old password stops identifying whoever holds
    # a session. The page says so and sends them to sign in.
    test "signs out the device that made the change, and tells it why" do
      user = account()
      here = sign_in(user)
      {:ok, lv, _html} = console(session_of(here))

      lv
      |> form("#password-form",
        user: %{
          "current_password" => @password,
          "password" => @new_password,
          "password_confirmation" => @new_password
        }
      )
      |> render_submit()

      flash = assert_redirect(lv, ~p"/sign-in")
      assert flash["info"] =~ "Sign in again with your new password"
      assert signed_out?(session_of(here))

      # And the new password is what signs them back in.
      assert redirected_to(
               build_conn()
               |> unique_ip()
               |> Phoenix.ConnTest.init_test_session(%{})
               |> post(~p"/auth/user/password/sign_in", %{
                 "user" => %{"email" => to_string(user.email), "password" => @new_password}
               })
             ) != ~p"/sign-in"
    end
  end

  describe "resetting the password by email link" do
    test "signs out every earlier session and the remember-me cookie" do
      user = account()
      stolen = sign_in(user)
      remembered = sign_in(user, %{"remember_me" => "true"})
      cookie = remembered.resp_cookies[@cookie].value

      refute signed_out?(session_of(stolen))
      assert remembered_as(cookie).id == user.id

      reset(user)

      assert signed_out?(session_of(stolen))
      assert remembered_as(cookie) == nil
    end

    test "signs the resetting browser in on a session that works" do
      user = account()
      _earlier = sign_in(user)

      reset_conn = reset(user)

      assert redirected_to(reset_conn) != ~p"/sign-in"
      refute signed_out?(session_of(reset_conn))
    end

    # #1637: revoking the tokens stops new connections; the LiveViews already
    # mounted authorized once, at connect. The eviction broadcast on the
    # session's `live_socket_id` is what Phoenix closes them on.
    test "disconnects the LiveViews the account already has open" do
      user = account()
      stolen = sign_in(user)
      socket_id = get_session(stolen, :live_socket_id)
      assert socket_id == SessionEviction.topic(user.id)

      {:ok, _lv, _html} = console(session_of(stolen))
      KilnCMSWeb.Endpoint.subscribe(socket_id)

      reset(user)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}, 2_000

      # And the reconnect that follows finds nothing to mount on.
      assert signed_out?(session_of(stolen))
    end

    # A reset says the old password may be someone else's, so a sign-in
    # parked on it at the code prompt (#742) — possibly theirs — dies with the
    # rest rather than completing on the next valid code.
    test "kills a sign-in waiting at the two-factor prompt" do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      first = sign_in(user)
      assert redirected_to(first) == ~p"/sign-in/verify"
      pending = get_session(first, :pending_2fa)
      assert is_binary(pending)

      reset(user)

      verified =
        build_conn()
        |> unique_ip()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> Phoenix.ConnTest.init_test_session(%{pending_2fa: pending})
        |> post(~p"/sign-in/verify", %{"code" => TwoFactorFixtures.current_code(secret)})

      assert get_session(verified, :user_token) == nil
      assert signed_out?(session_of(verified))
    end
  end
end
