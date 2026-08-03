defmodule KilnCMSWeb.TwoFactorControllerTest do
  @moduledoc "The second-factor sign-in gate (issue #331)."
  # Not `async: true`: the budget tests below tighten the app-wide
  # second-factor limit, which lives in one node-wide ETS table (#714).
  use KilnCMSWeb.ConnCase, async: false

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

  # `async: false` — these tighten the app-wide second-factor budget, which the
  # rest of the file (and every other suite that signs a 2FA user in) reads.
  # ExUnit runs sync modules after every async one, so the tightening cannot
  # reach another file.
  describe "the per-account budget (#714)" do
    alias KilnCMS.Accounts.AccountThrottle
    alias KilnCMS.Accounts.RecoveryCodes

    @budget 3

    setup do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])

      Application.put_env(
        :kiln_cms,
        AccountThrottle,
        Keyword.put(previous, :second_factor_budget, @budget)
      )

      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
      :ok
    end

    defp verify(user, code) do
      build_conn() |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})
    end

    defp exhaust(user), do: Enum.each(1..@budget, fn _ -> verify(user, "000000") end)

    test "a run of wrong codes bounds further guesses, the right code included" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      exhaust(user)

      # The point of budgeting the second factor: six digits and a skew window
      # are guessable, so the *correct* code has to be refused too, or an
      # attacker's final successful guess still lands.
      refused = verify(user, Totp.code_at(@secret, System.system_time(:second)))
      assert refused.status == 429
      assert refused.resp_body =~ "Too many attempts"
      assert [retry_after] = get_resp_header(refused, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "a fresh pending token buys no new attempts" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      exhaust(user)

      # The window this replaces. `@pending_2fa_max_age` is five minutes, but
      # re-running the password step mints a new pending token *and* forgives the
      # sign-in counter — so it costs an attacker who holds the password nothing
      # to renew. `with_pending/2` mints a brand-new token here, and the budget
      # keys on the account rather than on the token, so it does not care.
      assert verify(user, "000000").status == 429
    end

    test "recovery codes draw on the same budget, not one of their own" do
      user = enabled_user()
      codes = RecoveryCodes.generate()

      user =
        Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      exhaust(user)

      # An attacker who cannot guess the TOTP pivots to the recovery codes; two
      # budgets would simply be one budget twice as large.
      assert verify(user, hd(codes)).status == 429
    end

    test "a verified code clears the counter" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      # One short of the budget, then the real code.
      for _ <- 1..(@budget - 1), do: assert(verify(user, "000000").status == 401)
      code = Totp.code_at(@secret, System.system_time(:second))
      assert redirected_to(verify(user, code)) == ~p"/editor/overview"

      # If the counter had survived, this run would spend the budget and the
      # code below would be refused — an authenticator a minute out of sync
      # must not carry its failures into the next sign-in.
      for _ <- 1..(@budget - 1), do: assert(verify(user, "000000").status == 401)
      assert redirected_to(verify(user, code)) == ~p"/editor/overview"
    end

    test "the budget follows the account, not the browser" do
      user = enabled_user()
      other = enabled_user()
      on_exit(fn -> Enum.each([user, other], &AccountThrottle.forgive_second_factor(&1.id)) end)

      exhaust(user)

      # Every request above already came from a fresh `build_conn/0`, so a
      # per-session or per-IP counter would not have bound them at all.
      assert verify(user, "000000").status == 429
      assert verify(other, "000000").status == 401
    end
  end
end
