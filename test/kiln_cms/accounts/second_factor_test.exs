defmodule KilnCMS.Accounts.SecondFactorTest do
  @moduledoc """
  `SecondFactor.check/2` — the whole second-factor step for a sign-in gate
  (#714, #726, #728, #745).

  The ordering is the thing under test. Both gates used to write
  charge → verify → forgive out for themselves, with the correct order enforced
  by prose in two files; #745 made it a property of this module. Getting it
  backwards fails *silently* — still refusing wrong codes, just with an
  unbounded budget — so it needs a test that fails on the reversal rather than
  on the refusal.

  `KilnCMSWeb.TwoFactorBudgetTest` covers the same property end to end, over
  HTTP, with a real 429 and `retry-after`. This is the unit-level view: it is
  what fails first, and what a future third surface (a LiveView prompt) would
  be tested against before it has a route.

  `async: false`: node-wide ETS budgets, tightened app-wide via `put_env`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User

  @budget 2

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        second_factor_budget: @budget,
        # Widened, not tightened — a fixed-window rollover mid-test is the #697
        # flake shape.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp enabled_user(extra \\ %{}) do
    secret = :crypto.strong_rand_bytes(20)

    user =
      Ash.Seed.seed!(
        User,
        Map.merge(
          %{
            email: "sf-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: :editor,
            totp_secret: secret,
            totp_confirmed_at: DateTime.utc_now()
          },
          extra
        )
      )

    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)
    {user, secret}
  end

  defp current_code(secret), do: Totp.code_at(secret, System.system_time(:second))

  describe "the charge lands before the check" do
    test "a wrong code spends budget, so a spent budget refuses a correct one" do
      # The discriminating case. With the charge *after* the verify, a correct
      # code sails through a spent budget — and an attacker who guessed right on
      # attempt 5,000 still wins, while every wrong guess cost nothing.
      {user, secret} = enabled_user()

      assert :invalid = SecondFactor.check(user, "000000")
      assert :invalid = SecondFactor.check(user, "000000")

      assert {:deny, denied, ms} = SecondFactor.check(user, current_code(secret))
      assert denied.id == user.id
      assert is_integer(ms) and ms > 0
    end

    test "the refusal carries the user, which the gates need for retry-after" do
      {user, _secret} = enabled_user()

      Enum.each(1..@budget, fn _ -> SecondFactor.check(user, "000000") end)

      assert {:deny, denied, _ms} = SecondFactor.check(user, "000000")
      assert denied.id == user.id
    end
  end

  describe "a verified code clears the counter" do
    test "so the next sign-in starts from a full budget" do
      {user, secret} = enabled_user()

      assert :invalid = SecondFactor.check(user, "000000")
      assert {:ok, verified} = SecondFactor.check(user, current_code(secret))
      assert verified.id == user.id

      # Full budget back, rather than the earlier failure carried into it.
      assert :invalid = SecondFactor.check(user, "000000")
      assert :invalid = SecondFactor.check(user, "000000")
    end

    test "a recovery code counts as proof too, and is burned" do
      codes = RecoveryCodes.generate()

      {user, _secret} =
        enabled_user(%{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      code = hd(codes)

      assert {:ok, verified} = SecondFactor.check(user, code)
      # The updated record comes back, so the burn is not lost.
      assert length(verified.totp_recovery_hashes) == length(codes) - 1

      # Re-presenting it is now just a wrong code — checked against a record
      # read back from the database, because that is what a second request
      # holds. `check/2` verifies against the struct it is handed, so re-using
      # the stale one would only prove that a stale struct is stale.
      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert :invalid = SecondFactor.check(reloaded, code)
    end

    test "the first-factor token rides through a recovery-code burn" do
      # `consume_totp_recovery_code` returns a fresh record; losing the caller's
      # metadata here would leave the gate with nothing to store a session from.
      codes = RecoveryCodes.generate()

      {user, _secret} =
        enabled_user(%{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      user = %{user | __metadata__: Map.put(user.__metadata__, :token, "stub.jwt.token")}

      assert {:ok, verified} = SecondFactor.check(user, hd(codes))
      assert verified.__metadata__.token == "stub.jwt.token"
    end
  end

  describe "a missing secret does not take the recovery codes with it" do
    test "an account with totp_confirmed_at but no secret can still use one" do
      # Not reachable through a shipped action, but a partial write or a restore
      # produces it — and short-circuiting to :invalid would make such an account
      # unreachable through both gates with no self-service remedy.
      codes = RecoveryCodes.generate()

      {user, _secret} =
        enabled_user(%{
          totp_secret: nil,
          totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)
        })

      assert {:ok, _verified} = SecondFactor.check(user, hd(codes))
    end
  end
end
