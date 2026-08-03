defmodule KilnCMS.Accounts.SecondFactorSettingsBudgetTest do
  @moduledoc """
  The per-account budget on the TOTP actions reachable from a signed-in session
  (#727): `:disable_totp` and `:regenerate_totp_recovery_codes`.

  #714 budgeted `/sign-in/verify`. These two verify the same six digits and were
  charged nothing — and being LiveView events, they passed no router pipeline,
  so they did not get the per-IP `:auth` bucket either. A stolen session could
  grind them at socket speed, and `:disable_totp`'s prize is the second factor
  itself.

  `async: false` for the same reason as `KilnCMSWeb.TwoFactorBudgetTest`:
  `Application.put_env` is a process-wide write.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.SecondFactorThrottled
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User

  @secret :crypto.strong_rand_bytes(20)
  @budget 3

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        second_factor_budget: @budget,
        # Widened, not tightened — a fixed-window rollover between spending the
        # budget and asserting the refusal is the #697 flake shape.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp enabled_user do
    Ash.Seed.seed!(User, %{
      email: "sfsettings-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin,
      totp_secret: @secret,
      totp_confirmed_at: DateTime.utc_now(),
      totp_recovery_hashes: Enum.map(RecoveryCodes.generate(), &RecoveryCodes.hash/1)
    })
  end

  defp valid_code, do: Totp.code_at(@secret, System.system_time(:second))

  defp throttled?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%SecondFactorThrottled{}, &1))

  defp throttled?(_), do: false

  defp exhaust(user, action) do
    Enum.each(1..@budget, fn _ ->
      apply(Accounts, action, [user, %{code: "000000"}, [actor: user]])
    end)
  end

  for action <- [:disable_totp, :regenerate_totp_recovery_codes, :confirm_totp] do
    describe "#{action}" do
      @action action

      test "a wrong code is refused, and spends budget" do
        user = enabled_user()

        assert {:error, error} =
                 apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]])

        refute throttled?({:error, error}), "the first attempt must not be the throttled one"

        exhaust(user, @action)

        assert throttled?(apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]]))
      end

      test "a spent budget refuses a *correct* code too" do
        # The property that matters. If the charge ran after the check, a
        # correct code would sail through a spent budget — and an attacker who
        # guessed right on attempt 5,000 would still win.
        user = enabled_user()
        exhaust(user, @action)

        assert throttled?(apply(Accounts, @action, [user, %{code: valid_code()}, [actor: user]]))
      end

      test "a correct code clears the counter" do
        user = enabled_user()

        # One wrong, then right: the next run must get a full budget back,
        # rather than carrying the failure into it.
        apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]])

        assert {:ok, user} =
                 apply(Accounts, @action, [user, %{code: valid_code()}, [actor: user]])

        AccountThrottle.forgive_second_factor(user.id)
        refute throttled?(apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]]))
      end

      test "the refusal carries how long to wait" do
        user = enabled_user()
        exhaust(user, @action)

        assert {:error, %{errors: errors}} =
                 apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]])

        assert %SecondFactorThrottled{retry_after_seconds: seconds} =
                 Enum.find(errors, &match?(%SecondFactorThrottled{}, &1))

        assert is_integer(seconds) and seconds > 0
      end
    end
  end

  describe "the budget is shared with the sign-in prompt" do
    test "spending it at disable_totp refuses regenerate_totp_recovery_codes too" do
      # Two budgets would be one budget twice as large: an attacker who
      # exhausted one action would simply pivot to its neighbour.
      user = enabled_user()
      exhaust(user, :disable_totp)

      assert throttled?(
               Accounts.regenerate_totp_recovery_codes(user, %{code: "000000"}, actor: user)
             )
    end

    test "spending it here refuses the sign-in gate's own bucket" do
      user = enabled_user()
      exhaust(user, :disable_totp)

      assert {:deny, _ms} = AccountThrottle.consume_second_factor(user.id)
    end
  end

  describe "confirm_totp on an already-enrolled account" do
    # The reason enrolment looked exempt, and why it isn't. `:confirm_totp` is
    # not scoped to an enrolment in progress, so on an enrolled account it
    # checks the *live* secret and mints a fresh recovery-code set — the same
    # prize as `:regenerate_totp_recovery_codes`, from a differently-named door.
    # Budgeting one and not the other would have bolted the front and left the
    # side open.
    test "grinds the live secret, so it is charged like its twin" do
      user = enabled_user()
      exhaust(user, :confirm_totp)

      assert throttled?(Accounts.confirm_totp(user, %{code: "000000"}, actor: user))
    end

    test "a correct code hands back a working recovery set without touching the secret" do
      # Pins the mechanism, so that if a future change scopes `:confirm_totp` to
      # enrolment this test fails and the budget can be reconsidered on purpose.
      user = enabled_user()

      assert {:ok, updated} =
               Accounts.confirm_totp(user, %{code: valid_code()}, actor: user)

      assert length(Ash.Resource.get_metadata(updated, :recovery_codes)) == 10
      assert updated.totp_secret == @secret
    end

    test "spending it there refuses disable_totp too" do
      user = enabled_user()
      exhaust(user, :confirm_totp)

      assert throttled?(Accounts.disable_totp(user, %{code: "000000"}, actor: user))
    end
  end
end
