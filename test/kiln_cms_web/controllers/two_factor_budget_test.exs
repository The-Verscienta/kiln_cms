defmodule KilnCMSWeb.TwoFactorBudgetTest do
  @moduledoc """
  The per-account budget on the second factor (#714).

  Its own file rather than a `describe` in `KilnCMSWeb.TwoFactorControllerTest`,
  because what forces `async: false` here is `Application.put_env` — a
  process-wide write — and folding these in would drag that file's ten gate
  tests out of the async pool for a reason that does not apply to them. (The ETS
  table is *not* the reason: these buckets key on a per-test unique user id and
  cannot collide, which is exactly what `config/test.exs` says about them.)
  """
  use KilnCMSWeb.ConnCase, async: false

  import Plug.Conn

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.Totp

  @secret :crypto.strong_rand_bytes(20)
  @budget 3

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        second_factor_budget: @budget,
        # Widened, not tightened. These are fixed windows, so a rollover between
        # spending the budget and asserting the refusal would turn a 429 into a
        # 401 — the shape of the already-open flake #697. A long window makes
        # that vanishingly unlikely; nothing here waits for one to roll.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp enabled_user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "budget-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin,
      totp_secret: @secret,
      totp_confirmed_at: DateTime.utc_now()
    })
  end

  defp with_recovery_codes(user) do
    codes = RecoveryCodes.generate()
    user = Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})
    {user, codes}
  end

  # Mirrors `AuthController.sign_pending/3`: the state a browser is in after the
  # first factor and before the second.
  defp with_pending(conn, user) do
    payload = %{"user_id" => user.id, "token" => "stub.jwt.token"}
    token = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "two-factor pending", payload)

    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> init_test_session(%{})
    |> put_session(:pending_2fa, token)
  end

  defp verify(user, code), do: submit(with_pending(build_conn(), user), code)

  defp submit(conn, code), do: post(conn, ~p"/sign-in/verify", %{"code" => code})

  defp valid_code, do: Totp.code_at(@secret, System.system_time(:second))

  defp exhaust(user), do: Enum.each(1..@budget, fn _ -> verify(user, "000000") end)

  test "a run of wrong codes bounds further guesses, the right code included" do
    user = enabled_user()
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    exhaust(user)

    # The point of budgeting the second factor: six digits and a skew window are
    # guessable, so the *correct* code has to be refused too, or an attacker's
    # final successful guess still lands.
    refused = verify(user, valid_code())
    assert refused.status == 429
    assert refused.resp_body =~ "Too many attempts"

    # `>= 0`, not `> 0`: these are fixed windows, so a refusal landing in the
    # last second of one legitimately has under a second left and rounds down to
    # zero. Asserting a positive number would go red for correct behaviour.
    assert [retry_after] = get_resp_header(refused, "retry-after")
    assert String.to_integer(retry_after) >= 0
  end

  test "the refusal keeps the pending token, so it is not also a sign-out" do
    user = enabled_user()
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    exhaust(user)
    refused = verify(user, "000000")

    # The caller has not failed authentication — bouncing them to `/sign-in`
    # would be the wrong answer to "you have tried too often".
    assert refused.status == 429
    refute is_nil(get_session(refused, :pending_2fa))
  end

  test "one pending token spends the budget, and a fresh one does not refill it" do
    user = enabled_user()
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    # The whole budget spent through a SINGLE pending token, so the next request
    # is the only thing that varies. `@pending_2fa_max_age` is five minutes and
    # this window is longer, so a token-keyed budget would be no bound at all:
    # re-running the password step mints a new token and — because that step
    # succeeds — also forgives the sign-in counter, making the refresh free.
    conn = with_pending(build_conn(), user)

    Enum.reduce(1..@budget, conn, fn _, conn ->
      assert submit(conn, "000000").status == 401
      conn
    end)

    assert verify(user, "000000").status == 429
  end

  test "recovery codes draw on the same budget, not one of their own" do
    {user, codes} = with_recovery_codes(enabled_user())
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    exhaust(user)

    # An attacker who cannot guess the TOTP pivots to the recovery codes; two
    # budgets would simply be one budget twice as large.
    assert verify(user, hd(codes)).status == 429
  end

  test "a verified code clears the counter" do
    user = enabled_user()
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    for _ <- 1..(@budget - 1), do: assert(verify(user, "000000").status == 401)
    assert redirected_to(verify(user, valid_code())) == ~p"/editor/overview"

    # If the counter had survived, this run would spend the budget and the code
    # below would be refused — an authenticator a minute out of sync must not
    # carry its failures into the next sign-in.
    for _ <- 1..(@budget - 1), do: assert(verify(user, "000000").status == 401)
    assert redirected_to(verify(user, valid_code())) == ~p"/editor/overview"
  end

  test "the budget follows the account, not the caller" do
    user = enabled_user()
    other = enabled_user()
    on_exit(fn -> Enum.each([user, other], &AccountThrottle.forgive_second_factor(&1.id)) end)

    exhaust(user)

    # This pair is what distinguishes per-account from per-IP: every request in
    # this file comes from `build_conn/0`, i.e. 127.0.0.1, so a per-address
    # counter would refuse the first line — and would also refuse the second,
    # which is the one that rules it out.
    assert verify(user, "000000").status == 429
    assert verify(other, "000000").status == 401
  end

  test "whitespace in a pasted code does not cost an attempt" do
    user = enabled_user()
    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    # Authenticators display `123 456`, and both a paste and Safari's
    # `autocomplete="one-time-code"` fill carry the space through. Before the
    # budget that cost a retry; with it, a few pastes would lock a user out
    # having never entered a wrong code.
    spaced =
      valid_code()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(" ", &Enum.join/1)

    assert redirected_to(verify(user, spaced)) == ~p"/editor/overview"
  end
end
