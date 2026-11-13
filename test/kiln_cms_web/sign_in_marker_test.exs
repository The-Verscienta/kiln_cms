defmodule KilnCMSWeb.SignInMarkerTest do
  @moduledoc """
  The session's sign-in marker (#2247): how a session signed in and whether it
  passed a second factor, written by every path that establishes a session and
  read only while it describes the session's current token.

  The stale-marker cases are what the jti is for: an idle timeout drops the
  token and keeps the session, and whatever signs that session in next must
  not inherit what the earlier sign-in proved.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PasskeyFixtures

  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.Token
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.AuthController
  alias KilnCMSWeb.SignInMarker

  @moduletag :capture_log

  @password "password123456"

  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  defp marker(conn), do: SignInMarker.read(get_session(conn))

  defp password_sign_in(conn, user, params \\ %{}) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => @password}, params)
    })
  end

  # `AuthController.success/4` as a strategy's callback reaches it.
  defp succeed(activity, user) do
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)

    build_conn()
    |> unique_ip()
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
    |> AuthController.success(activity, user, token)
  end

  defp token_with(claims) do
    {:ok, token, _claims} =
      AshAuthentication.Jwt.token_for_user(passkey_user(), claims)

    token
  end

  describe "read/1" do
    test "answers for the session's own token, with signed_in_at from its iat" do
      token = token_with(%{})
      {:ok, %{"jti" => jti, "iat" => iat}} = AshAuthentication.Jwt.peek(token)

      session = %{
        "user_token" => token,
        "sign_in" => %{"jti" => jti, "method" => "password", "second_factor_at" => iat + 5}
      }

      assert %{method: "password", signed_in_at: signed_in_at, second_factor_at: verified_at} =
               SignInMarker.read(session)

      assert DateTime.to_unix(signed_in_at) == iat
      assert DateTime.to_unix(verified_at) == iat + 5
    end

    test "a marker written for another token reads as nothing" do
      session = %{
        "user_token" => token_with(%{}),
        "sign_in" => %{
          "jti" => "some-earlier-token",
          "method" => "passkey",
          "second_factor_at" => 1
        }
      }

      assert SignInMarker.read(session) == nil
    end

    test "no token, a malformed one, or no marker reads as nothing" do
      marker = %{"jti" => "x", "method" => "password"}

      assert SignInMarker.read(%{"sign_in" => marker}) == nil
      assert SignInMarker.read(%{"sign_in" => marker, "user_token" => "not.a.jwt"}) == nil
      assert SignInMarker.read(%{"user_token" => token_with(%{})}) == nil
      assert SignInMarker.read(nil) == nil
    end
  end

  describe "each sign-in marks its session" do
    test "a password sign-in: password, no second factor", %{conn: conn} do
      signed_in = password_sign_in(conn, passkey_user())

      assert %{method: "password", second_factor_at: nil, signed_in_at: %DateTime{}} =
               marker(signed_in)
    end

    test "a magic link: magic_link" do
      assert %{method: "magic_link", second_factor_at: nil} =
               marker(succeed({:magic_link, :sign_in}, passkey_user()))
    end

    test "single sign-on: sso" do
      assert %{method: "sso", second_factor_at: nil} =
               marker(succeed({:site_sso, :callback}, passkey_user()))
    end

    test "a password reset: password_reset" do
      assert %{method: "password_reset", second_factor_at: nil} =
               marker(succeed({:password, :reset}, passkey_user()))
    end

    test "a passkey sign-in: passkey, with its second factor", %{conn: conn} do
      user = passkey_user()
      {:ok, _} = enroll(user, "mark-#{user.id}")

      optioned = post(conn, ~p"/auth/passkey/options")

      signed_in =
        optioned
        |> recycle()
        |> Map.put(:remote_ip, optioned.remote_ip)
        |> post(~p"/auth/passkey/verify", assertion("mark-#{user.id}"))

      assert json_response(signed_in, 200)
      assert %{method: "passkey", second_factor_at: %DateTime{}} = marker(signed_in)
    end

    test "the code prompt: the first factor's method, with its second factor", %{conn: conn} do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {user, _token} = TwoFactorFixtures.with_first_factor_token(user)

      signed_in =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> init_test_session(%{
          pending_2fa: PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, user),
          sign_in_method: "password"
        })
        |> post(~p"/sign-in/verify", %{"code" => TwoFactorFixtures.current_code(secret)})

      assert redirected_to(signed_in)
      assert %{method: "password", second_factor_at: %DateTime{}} = marker(signed_in)
    end

    test "the remember-me cookie: remember_me, no second factor", %{conn: conn} do
      user = passkey_user()
      cookie = password_sign_in(conn, user, %{"remember_me" => "true"}).resp_cookies[@cookie]

      remembered =
        build_conn()
        |> unique_ip()
        |> Plug.Test.put_req_cookie(@cookie, cookie.value)
        |> get(~p"/sign-in")

      assert remembered.assigns.current_user.id == user.id
      assert %{method: "remember_me", second_factor_at: nil} = marker(remembered)
    end
  end

  describe "a stale marker is never inherited" do
    test "remember-me after a magic-link session does not read as a magic link", %{conn: conn} do
      user = passkey_user()
      cookie = password_sign_in(conn, user, %{"remember_me" => "true"}).resp_cookies[@cookie]

      # A magic-link session whose token has since gone (an idle timeout drops
      # the token and keeps the rest of the session).
      magic = succeed({:magic_link, :sign_in}, user)
      assert %{method: "magic_link"} = marker(magic)
      session = magic |> get_session() |> Map.delete("user_token")

      remembered =
        build_conn()
        |> unique_ip()
        |> Plug.Test.init_test_session(session)
        |> Plug.Test.put_req_cookie(@cookie, cookie.value)
        |> get(~p"/sign-in")

      assert remembered.assigns.current_user.id == user.id
      assert %{method: "remember_me", second_factor_at: nil} = marker(remembered)
    end

    test "after an idle timeout, a password sign-in has no verified second factor" do
      site = org("mark-idle")
      user = passkey_user(:admin)
      {:ok, _} = enroll(user, "idle-#{user.id}")

      CMS.save_site_session_policy!(%{idle_timeout_minutes: 15},
        authorize?: false,
        tenant: site.id
      )

      # The test's transaction freezes `now()`; move the save back so its clamp
      # does not hide the idle time (as in `KilnCMSWeb.IdleTimeoutTest`).
      Repo.query!(
        "UPDATE site_session_policy SET policy_changed_at = (now() AT TIME ZONE 'utc') - interval '1 day' WHERE org_id = $1",
        [Ecto.UUID.dump!(site.id)]
      )

      KilnCMS.Cache.bust_session_policy(site.id)

      browser = org_conn(build_conn(), site) |> unique_ip()
      optioned = post(browser, ~p"/auth/passkey/options")

      signed_in =
        optioned
        |> recycle()
        |> org_conn(site)
        |> Map.put(:remote_ip, optioned.remote_ip)
        |> post(~p"/auth/passkey/verify", assertion("idle-#{user.id}"))

      assert %{method: "passkey", second_factor_at: %DateTime{}} = marker(signed_in)
      jti = Token.peeked_jti(get_session(signed_in, :user_token))

      Repo.query!(
        "UPDATE tokens SET last_used_at = (now() AT TIME ZONE 'utc') - interval '16 minutes' WHERE jti = $1",
        [jti]
      )

      idled =
        signed_in
        |> recycle()
        |> org_conn(site)
        |> Map.put(:remote_ip, signed_in.remote_ip)
        |> get(~p"/sign-in")

      assert Repo.one!(from(t in Token, where: t.jti == ^jti, select: t.purpose)) == "revocation"
      assert get_session(idled, :user_token) == nil
      # The marker is still in the session, and reads as nothing.
      assert %{"jti" => ^jti} = get_session(idled, "sign_in")
      assert marker(idled) == nil

      again =
        idled
        |> recycle()
        |> org_conn(site)
        |> Map.put(:remote_ip, idled.remote_ip)
        |> post(~p"/auth/user/password/sign_in", %{
          "user" => %{"email" => to_string(user.email), "password" => @password}
        })

      assert get_session(again, :user_token)
      assert %{method: "password", second_factor_at: nil} = marker(again)
    end
  end
end
