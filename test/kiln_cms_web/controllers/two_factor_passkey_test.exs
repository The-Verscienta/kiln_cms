defmodule KilnCMSWeb.TwoFactorPasskeyTest do
  @moduledoc """
  A passkey at the second-factor prompt (#2247): `/sign-in/verify` offers it to
  an account that has one, and `/sign-in/verify/passkey{/options,}` completes
  the sign-in the first factor started — the same claim, budget, event and
  remember-me cookie as a code, and none of the anonymous ceremony's nonces.

  The ceremony runs over `KilnCMS.StubWebAuthnVerifier`, which honours the
  challenge's allow-list as Wax does.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.PasskeyFixtures
  import Plug.Conn

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Security.Event
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.BearerAuth
  alias KilnCMSWeb.SignInMarker

  @moduletag :capture_log

  # The canonical host, where passkey ceremonies run. ConnCase's default host,
  # `www.example.com`, stands for any other — a tenant site host.
  @ceremony_host "localhost"

  @remember_me_cookie to_string(
                        KilnCMSWeb.SessionCookie.remember_me_key(
                          Application.compile_env(:kiln_cms, :secure_session_cookie, false)
                        )
                      )

  # An account with the authenticator app and a passkey: `{user, secret, cred}`.
  defp both_factors do
    {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
    cred = "tfp-#{user.id}"
    {:ok, _} = enroll(user, cred)
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)
    {user, secret, cred}
  end

  # A passkey-only account. Nothing diverts one to the prompt yet, so it only
  # gets here by removing its authenticator app mid-prompt.
  defp passkey_only do
    user = passkey_user(:editor)
    cred = "tfp-only-#{user.id}"
    {:ok, _} = enroll(user, cred)
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)
    {user, cred}
  end

  # The state `AuthController.success/4` leaves: a pending blob holding a real,
  # stored first-factor token, and how the first factor was passed.
  defp pending(conn, user, opts \\ []) do
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)

    blob =
      PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, user,
        remember_me?: Keyword.get(opts, :remember_me?, false)
      )

    conn =
      conn
      |> Map.put(:host, Keyword.get(opts, :host, @ceremony_host))
      |> put_private(:plug_skip_csrf_protection, true)
      |> init_test_session(%{})
      |> put_session(:pending_2fa, blob)
      |> put_session(:sign_in_method, Keyword.get(opts, :method, "password"))

    {conn, token}
  end

  # The next request of the same browser: the session and cookies carried over.
  # A conn not yet sent still holds its test session, which `recycle/1` would
  # drop, so it is the next request as it stands.
  defp next(%Plug.Conn{state: :unset} = conn), do: conn

  defp next(conn) do
    conn
    |> recycle()
    |> Map.put(:host, conn.host)
    |> Map.put(:remote_ip, conn.remote_ip)
    |> put_private(:plug_skip_csrf_protection, true)
  end

  defp options(conn), do: post(conn, ~p"/sign-in/verify/passkey/options")
  defp verify(conn, payload), do: conn |> next() |> post(~p"/sign-in/verify/passkey", payload)

  defp sign_in_events(user) do
    Event
    |> Ash.Query.filter(type == :sign_in and actor_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: Accounts.default_org_id())
  end

  defp failed_events(user) do
    Event
    |> Ash.Query.filter(type == :sign_in_failed and actor_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: Accounts.default_org_id())
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

  describe "the prompt page" do
    test "offers the passkey to an account with both factors, beside the code", %{conn: conn} do
      {user, _secret, _cred} = both_factors()
      {conn, _token} = pending(conn, user)

      html = conn |> get(~p"/sign-in/verify") |> html_response(200)

      assert count(html, "#two-factor-form") == 1
      assert count(html, "#two-factor-recovery") == 1
      # Shipped hidden for the script to reveal; no inline script for it.
      assert count(html, "#two-factor-passkey[data-passkey-step-up][hidden]") == 1
      assert count(html, "#two-factor-passkey button[data-role='passkey-step-up']") == 1
      refute Regex.match?(~r/<script(?![^>]*\ssrc=)(?![^>]*\snonce=)[^>]*>/, html)
    end

    test "offers no passkey to an account with only the authenticator app", %{conn: conn} do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {conn, _token} = pending(conn, user)

      html = conn |> get(~p"/sign-in/verify") |> html_response(200)

      assert count(html, "#two-factor-form") == 1
      assert count(html, "#two-factor-passkey") == 0
    end

    test "offers no passkey on a tenant site host, where the ceremony cannot run", %{
      conn: conn
    } do
      {user, _secret, _cred} = both_factors()
      {conn, _token} = pending(conn, user, host: "www.example.com")

      html = conn |> get(~p"/sign-in/verify") |> html_response(200)

      assert count(html, "#two-factor-form") == 1
      assert count(html, "#two-factor-passkey") == 0
    end

    test "shows a passkey-only account no code fields", %{conn: conn} do
      {user, _cred} = passkey_only()
      {conn, _token} = pending(conn, user)

      html = conn |> get(~p"/sign-in/verify") |> html_response(200)

      assert count(html, "#two-factor-form") == 0
      assert count(html, "#two-factor-recovery") == 0
      assert count(html, "#two-factor-passkey") == 1
    end
  end

  describe "the code form requires the authenticator app" do
    test "a passkey-only account cannot spend the budget on it", %{conn: conn} do
      {user, _cred} = passkey_only()
      {conn, _token} = pending(conn, user)

      for _ <- 1..6 do
        refused = conn |> next() |> post(~p"/sign-in/verify", %{"code" => "000000"})
        assert redirected_to(refused) == ~p"/sign-in"
      end

      # Nothing reached the check: no refusal was recorded against the account
      # (`SecondFactor.check/3` records every one it charges).
      assert failed_events(user) == []
    end
  end

  describe "completing the sign-in with a passkey" do
    test "an account with both factors signs in with its passkey", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user, method: "magic_link")

      optioned = options(conn)

      assert %{"publicKey" => %{"allowCredentials" => [%{"id" => listed}]}} =
               json_response(optioned, 200)

      assert listed == b64(cred)

      done = verify(optioned, assertion(cred))

      assert %{"redirect_to" => "/editor/overview"} = json_response(done, 200)
      assert is_binary(get_session(done, "user_token"))
      assert get_session(done, :pending_2fa) == nil
      assert get_session(done, :passkey_step_up_nonce) == nil

      # One sign-in, by the first factor's method, and the session says a
      # second factor was verified.
      assert [event] = sign_in_events(user)
      assert event.metadata == %{"method" => "magic_link"}

      assert %{method: "magic_link", second_factor_at: %DateTime{}} =
               SignInMarker.read(get_session(done))
    end

    test "the first-factor token is held until the passkey verifies", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, token} = pending(conn, user)

      optioned = options(conn)
      assert :error = BearerAuth.user_from_token(token)

      # A refused assertion leaves it held.
      refused = verify(optioned, assertion(cred, signature: "bad"))
      assert refused.status == 401
      assert :error = BearerAuth.user_from_token(token)

      done = refused |> options() |> verify(assertion(cred))
      assert json_response(done, 200)["redirect_to"]
      assert {:ok, authed} = BearerAuth.user_from_token(token)
      assert authed.id == user.id
    end

    test "the remember-me cookie is issued only once the passkey verifies", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user, remember_me?: true)

      optioned = options(conn)
      refute Map.has_key?(optioned.resp_cookies, @remember_me_cookie)

      refused = verify(optioned, assertion(cred, signature: "bad"))
      refute Map.has_key?(refused.resp_cookies, @remember_me_cookie)

      done = refused |> options() |> verify(assertion(cred))
      assert %{value: value} = done.resp_cookies[@remember_me_cookie]
      assert is_binary(value) and value != ""
    end

    test "without remember-me, no cookie", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      done = conn |> options() |> verify(assertion(cred))
      assert json_response(done, 200)["redirect_to"]
      refute Map.has_key?(done.resp_cookies, @remember_me_cookie)
    end

    test "a passkey-only account completes with its passkey", %{conn: conn} do
      {user, cred} = passkey_only()
      {conn, _token} = pending(conn, user)

      done = conn |> options() |> verify(assertion(cred))
      assert json_response(done, 200)["redirect_to"]
      assert [_event] = sign_in_events(user)
    end
  end

  describe "refusals" do
    test "another account's passkey is refused, recorded and charged", %{conn: conn} do
      {user, _secret, _cred} = both_factors()
      other = passkey_user(:editor)
      {:ok, _} = enroll(other, "tfp-other-#{other.id}")
      {conn, token} = pending(conn, user)

      refused = conn |> options() |> verify(assertion("tfp-other-#{other.id}"))

      assert %{"error" => _} = json_response(refused, 401)
      assert get_session(refused, "user_token") == nil
      assert :error = BearerAuth.user_from_token(token)
      assert sign_in_events(user) == []

      assert [event] = failed_events(user)
      assert event.metadata["method"] == "second_factor"
    end

    test "a challenge minted for one pending account does not complete another's", %{
      conn: conn
    } do
      {victim, _secret, victim_cred} = both_factors()
      {attacker, _secret, _cred} = both_factors()

      # The victim's pending sign-in mints a challenge; its nonce is carried
      # into a session pending for the attacker's account.
      {victim_conn, _token} = pending(conn, victim)
      nonce = victim_conn |> options() |> get_session(:passkey_step_up_nonce)
      assert is_binary(nonce)

      {attacker_conn, _token} = pending(build_conn(), attacker)

      refused =
        attacker_conn
        |> put_session(:passkey_step_up_nonce, nonce)
        |> post(~p"/sign-in/verify/passkey", assertion(victim_cred))

      assert json_response(refused, 401)
      assert get_session(refused, "user_token") == nil
      assert sign_in_events(attacker) == []
      assert sign_in_events(victim) == []
    end

    test "a captured verify request cannot be replayed (single-use challenge)", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      optioned = options(conn)
      assert json_response(verify(optioned, assertion(cred)), 200)

      # The same cookie and nonce again: the challenge was consumed.
      assert json_response(verify(optioned, assertion(cred)), 401)
      assert [_one] = sign_in_events(user)
    end

    test "a counter regression is refused", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      first = conn |> options() |> verify(assertion(cred, auth_data: "count:4"))
      assert json_response(first, 200)

      {again, _token} = pending(build_conn(), user)
      refused = again |> options() |> verify(assertion(cred, auth_data: "count:4"))
      assert json_response(refused, 401)
    end

    test "an assertion without user verification is refused", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      refused = conn |> options() |> verify(assertion(cred, auth_data: "nouv"))

      assert json_response(refused, 401)
      assert get_session(refused, "user_token") == nil
    end

    test "verify without a parked challenge is refused", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      assert json_response(verify(conn, assertion(cred)), 401)
    end

    test "nothing pending: both steps refuse", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, @ceremony_host)
        |> put_private(:plug_skip_csrf_protection, true)
        |> init_test_session(%{})

      assert json_response(options(conn), 401)
      assert json_response(post(conn, ~p"/sign-in/verify/passkey", assertion("x")), 401)
    end

    test "an app-only account gets no step-up challenge", %{conn: conn} do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {conn, _token} = pending(conn, user)

      refused = options(conn)
      assert json_response(refused, 401)
      assert get_session(refused, :passkey_step_up_nonce) == nil
    end

    test "no challenge on a host where the ceremony cannot run", %{conn: conn} do
      {user, _secret, _cred} = both_factors()
      {conn, _token} = pending(conn, user, host: "www.example.com")

      refused = options(conn)
      assert json_response(refused, 401)
      assert get_session(refused, :passkey_step_up_nonce) == nil
    end
  end

  describe "the two passkey ceremonies do not share nonces" do
    test "an anonymous sign-in nonce is no step-up challenge", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      anonymous = post(conn, ~p"/auth/passkey/options")
      anonymous_nonce = get_session(anonymous, :passkey_challenge_nonce)
      assert is_binary(anonymous_nonce)

      # Neither under its own key nor under the step-up's.
      assert json_response(verify(anonymous, assertion(cred)), 401)

      {again, _token} = pending(build_conn(), user)

      refused =
        again
        |> put_session(:passkey_step_up_nonce, anonymous_nonce)
        |> post(~p"/sign-in/verify/passkey", assertion(cred))

      assert json_response(refused, 401)
      assert sign_in_events(user) == []
    end

    test "a step-up nonce is no anonymous sign-in challenge", %{conn: conn} do
      {user, _secret, cred} = both_factors()
      {conn, _token} = pending(conn, user)

      step_up_nonce = conn |> options() |> get_session(:passkey_step_up_nonce)
      assert is_binary(step_up_nonce)

      refused =
        build_conn()
        |> Map.put(:host, @ceremony_host)
        |> put_private(:plug_skip_csrf_protection, true)
        |> init_test_session(%{passkey_challenge_nonce: step_up_nonce})
        |> post(~p"/auth/passkey/verify", assertion(cred))

      assert json_response(refused, 401)
      assert get_session(refused, "user_token") == nil
      assert sign_in_events(user) == []
    end
  end
end
