defmodule KilnCMSWeb.TwoFactorControllerTest do
  @moduledoc "The second-factor sign-in gate (issue #331)."
  use KilnCMSWeb.ConnCase, async: true

  import Plug.Conn

  alias KilnCMS.Accounts.Totp

  # A fixed secret so the test can compute the matching code.
  @secret :crypto.strong_rand_bytes(20)

  defp enabled_user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gate-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin,
      totp_secret: @secret,
      totp_confirmed_at: DateTime.utc_now()
    })
  end

  # Simulate the post-first-factor state AuthController.success/4 sets: a signed
  # pending token in the session (and skip CSRF for the direct POST).
  defp with_pending(conn, user) do
    # Mirrors AuthController.sign_pending/3: the payload carries the user id + the
    # first-factor token (a stand-in here — store_in_session doesn't validate it).
    payload = %{"user_id" => user.id, "token" => "stub.jwt.token"}
    token = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "two-factor pending", payload)

    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> init_test_session(%{})
    |> put_session(:pending_2fa, token)
  end

  test "GET /sign-in/verify without a pending token redirects to sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/sign-in/verify")) == ~p"/sign-in"
  end

  test "a valid code completes sign-in and clears the pending state", %{conn: conn} do
    user = enabled_user()
    code = Totp.code_at(@secret, System.system_time(:second))

    conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})

    assert redirected_to(conn) == ~p"/editor/overview"
    assert is_nil(get_session(conn, :pending_2fa))
  end

  test "an invalid code is rejected and keeps the user on the prompt", %{conn: conn} do
    user = enabled_user()

    conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => "000000"})

    assert conn.status == 401
    assert conn.resp_body =~ "isn&#39;t valid" or conn.resp_body =~ "isn't valid"
    refute is_nil(get_session(conn, :pending_2fa))
  end

  describe "recovery codes (#331 phase 2)" do
    alias KilnCMS.Accounts.RecoveryCodes

    defp with_recovery_codes(user) do
      codes = RecoveryCodes.generate()

      user =
        Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      {user, codes}
    end

    test "a recovery code completes sign-in and is burned on use", %{conn: conn} do
      {user, [code | _]} = with_recovery_codes(enabled_user())

      conn2 = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})
      assert redirected_to(conn2) == ~p"/editor/overview"

      # One fewer unused code, and the same code never works again.
      reloaded = KilnCMS.Accounts.get_user!(user.id, authorize?: false)
      assert length(reloaded.totp_recovery_hashes) == RecoveryCodes.count() - 1

      retry = build_conn() |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})
      assert retry.status == 401
    end

    test "a recovery code is accepted case- and format-insensitively", %{conn: conn} do
      {user, [code | _]} = with_recovery_codes(enabled_user())
      variant = code |> String.downcase() |> String.replace("-", " ")

      conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => variant})
      assert redirected_to(conn) == ~p"/editor/overview"
    end

    test "an unknown recovery code is rejected", %{conn: conn} do
      {user, _codes} = with_recovery_codes(enabled_user())

      conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => "AAAA-AAAA"})
      assert conn.status == 401
    end
  end
end
