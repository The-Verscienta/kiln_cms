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
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.TwoFactorFixtures

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
        # 401 — the shape of flake #697 (closed by exactly this hour-wide-window
        # convention). A long window makes that vanishingly unlikely; nothing
        # here waits for one to roll.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  # The module-wide `@secret` is passed in so every account here shares it and
  # `valid_code/0` can stay argument-free — the budget tests care about how many
  # attempts an account gets, not about which secret they came from.
  defp enabled_user do
    {user, _secret} = TwoFactorFixtures.enabled_user(secret: @secret)
    user
  end

  # The state a browser is in after the first factor and before the second.
  # A real, stored first-factor JWT rather than a stub (#1171): `mint_and_hold/4`
  # holds the stored row, and a stub has none — the "nothing to hold" branch is
  # silent, so a stub here would exercise a path no sign-in ever takes.
  defp with_pending(conn, user) do
    {user, _token} = TwoFactorFixtures.with_first_factor_token(user)
    token = PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, user)

    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> init_test_session(%{})
    |> put_session(:pending_2fa, token)
  end

  defp verify(user, code), do: submit(with_pending(unique_ip(build_conn()), user), code)

  defp verify_from(conn, user, code), do: submit(with_pending(conn, user), code)

  defp submit(conn, code), do: post(conn, ~p"/sign-in/verify", %{"code" => code})

  defp valid_code, do: TwoFactorFixtures.current_code(@secret)

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

    # `>= 1`: a refusal landing in the last second of a fixed window has under a
    # second left, which truncating division rounded to zero — a retry hint that
    # says "now". `AccountThrottle.retry_after_seconds/1` rounds up and floors at
    # one, so a wait is always a wait.
    assert [retry_after] = get_resp_header(refused, "retry-after")
    assert String.to_integer(retry_after) >= 1
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
    # is the only thing that varies. `PendingSignIn.max_age/0` is five minutes and
    # this window is longer, so a token-keyed budget would be no bound at all:
    # re-running the password step mints a new one. (Until #742 that step also
    # forgave the sign-in counter, making the refresh entirely free; it now
    # costs a unit of that budget, which is a looser second ceiling on the same
    # attack rather than a replacement for this one.)
    conn = with_pending(unique_ip(build_conn()), user)

    Enum.reduce(1..@budget, conn, fn _, conn ->
      assert submit(conn, "000000").status == 401
      conn
    end)

    assert verify(user, "000000").status == 429
  end

  test "recovery codes draw on the same budget, not one of their own" do
    {user, codes} = TwoFactorFixtures.with_recovery_codes(enabled_user())
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

    # Shared loopback on purpose: ConnCase's default conn is unique per test
    # (#936), so proving "not per-IP" requires opting back into the one address
    # every bare `build_conn/0` used to share.
    shared = loopback_conn()

    exhaust_from = fn account ->
      Enum.each(1..@budget, fn _ -> verify_from(shared, account, "000000") end)
    end

    exhaust_from.(user)

    # This pair is what distinguishes per-account from per-IP: both requests
    # come from the same address, so a per-address counter would refuse the
    # first line — and would also refuse the second, which is the one that
    # rules it out.
    assert verify_from(shared, user, "000000").status == 429
    assert verify_from(shared, other, "000000").status == 401
  end

  describe "the headless second factor draws on the same bucket (#726)" do
    # Minted through the real module rather than hand-rolled, so a change to the
    # payload shape or the salt breaks this loudly instead of leaving it asserting
    # against a blob the controller can no longer read.
    defp api_verify(user, code) do
      {user, _token} = TwoFactorFixtures.with_first_factor_token(user)
      pending = PendingSignIn.mint_and_hold(:encrypted, KilnCMSWeb.Endpoint, user)

      unique_ip(build_conn())
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/sign_in/verify", %{"pending_token" => pending, "code" => code})
    end

    test "a browser run of wrong codes bounds the API endpoint too" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      exhaust(user)

      # The bound the whole of #726 rests on. Two surfaces verify the same six
      # digits; per-surface budgets would let an attacker double their guesses
      # by alternating endpoints, which is not a budget, it is a speed bump.
      refused = api_verify(user, valid_code())
      assert refused.status == 429

      # Pinned as a bound, not just as present. `div(ms, 1000)` truncates, so a
      # refusal in the last second of a window used to emit `Retry-After: 0` —
      # which tells a conforming client to retry immediately into the next
      # refusal. Browsers ignore the header; scripts do not.
      assert [retry_after] = get_resp_header(refused, "retry-after")
      seconds = String.to_integer(retry_after)
      assert seconds >= 1
      assert seconds <= div(:timer.hours(1), 1000)
    end

    test "an API run of wrong codes bounds the browser prompt too" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      Enum.each(1..@budget, fn _ -> assert api_verify(user, "000000").status == 401 end)

      # ...and the same in the other direction, or the bound holds only for
      # whichever surface an attacker chose not to use.
      assert verify(user, valid_code()).status == 429
    end

    test "a verified API code clears the counter for both" do
      user = enabled_user()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      for _ <- 1..(@budget - 1), do: assert(api_verify(user, "000000").status == 401)
      assert api_verify(user, valid_code()).status == 201

      # A forgiveness that only cleared the surface it happened on would leave a
      # user who fumbled their code in a script locked out of the browser.
      assert redirected_to(verify(user, valid_code())) == ~p"/editor/overview"
    end
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
