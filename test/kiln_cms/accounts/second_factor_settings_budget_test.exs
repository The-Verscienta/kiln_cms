defmodule KilnCMS.Accounts.SecondFactorSettingsBudgetTest do
  @moduledoc """
  The per-account budget on the TOTP actions reachable from a signed-in session
  (#727): `:disable_totp`, `:regenerate_totp_recovery_codes` and
  `:confirm_totp`. Once it is spent, every attempt gets one identical refusal
  and no code is compared (GHSA-4854-24jg-q7j5).

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
  alias KilnCMS.Accounts.User
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
        # Widened, not tightened — a fixed-window rollover between spending the
        # budget and asserting the refusal is the #697 flake shape.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  # Recovery hashes are seeded straight in rather than through
  # `with_recovery_codes/1`: these tests spend the budget against codes they
  # never need to know, so the plaintext would be dead weight.
  defp enabled_user do
    {user, _secret} =
      TwoFactorFixtures.enabled_user(
        secret: @secret,
        totp_recovery_hashes: Enum.map(RecoveryCodes.generate(), &RecoveryCodes.hash/1)
      )

    user
  end

  defp valid_code, do: TwoFactorFixtures.current_code(@secret)

  defp with_pending(user) do
    pending = :crypto.strong_rand_bytes(20)
    Ash.Seed.update!(user, %{totp_pending_secret: pending})
  end

  defp pending_code(user), do: TwoFactorFixtures.current_code(user.totp_pending_secret)

  defp throttled?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%SecondFactorThrottled{}, &1))

  defp throttled?(_), do: false

  defp exhaust(user, action) do
    Enum.each(1..@budget, fn _ ->
      apply(Accounts, action, [user, %{code: "000000"}, [actor: user]])
    end)
  end

  # `:confirm_totp` (#754) has no "correct code" against `enabled_user`'s live
  # secret — it checks `totp_pending_secret`, which is only ever set by staging
  # a re-enrolment. Give it one so the generic tests below still exercise "the
  # code that would otherwise succeed", the same property they check for the
  # other two actions against the live secret.
  # Returns the whole params map, not just a code: since #786 a `:confirm_totp`
  # that replaces an already-CONFIRMED secret must also carry `current_code`, so
  # "the attempt that would otherwise succeed" is no longer a bare `%{code: _}`.
  defp fresh_valid_attempt(:confirm_totp, user) do
    pending = :crypto.strong_rand_bytes(20)
    updated = Ash.Seed.update!(user, %{totp_pending_secret: pending})

    {updated, %{code: TwoFactorFixtures.current_code(pending), current_code: valid_code()}}
  end

  defp fresh_valid_attempt(_action, user), do: {user, %{code: valid_code()}}

  # The attempt that would fail every code check the action makes — for
  # `:confirm_totp` the outgoing factor's `current_code` too, so a refusal that
  # still compared either code would carry an error the right attempt does not.
  defp wrong_attempt(:confirm_totp), do: %{code: "000000", current_code: "000000"}
  defp wrong_attempt(_action), do: %{code: "000000"}

  # What an error list tells the caller: each error's kind and field. Not the
  # retry-after seconds, which tick between two calls without saying anything
  # about the code.
  defp error_shape({:error, %{errors: errors}}),
    do: Enum.map(errors, &{&1.__struct__, Map.get(&1, :field)})

  defp error_shape(other), do: other

  # The columns each action writes on success: unchanged means not accepted.
  defp factor_state(user) do
    reloaded = Ash.get!(User, user.id, authorize?: false)

    {reloaded.totp_secret, reloaded.totp_confirmed_at, reloaded.totp_pending_secret,
     reloaded.totp_recovery_hashes}
  end

  defp with_demo_mode(fun) do
    saved = Application.get_env(:kiln_cms, KilnCMS.Demo)
    Application.put_env(:kiln_cms, KilnCMS.Demo, enabled: true)

    try do
      fun.()
    after
      if saved,
        do: Application.put_env(:kiln_cms, KilnCMS.Demo, saved),
        else: Application.delete_env(:kiln_cms, KilnCMS.Demo)
    end
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
        {user, params} = fresh_valid_attempt(@action, user)
        exhaust(user, @action)

        assert throttled?(apply(Accounts, @action, [user, params, [actor: user]]))
      end

      test "a correct code clears the counter" do
        user = enabled_user()
        {user, params} = fresh_valid_attempt(@action, user)

        # One wrong, then right: the next run must get a full budget back,
        # rather than carrying the failure into it.
        apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]])

        assert {:ok, user} =
                 apply(Accounts, @action, [user, params, [actor: user]])

        AccountThrottle.forgive_second_factor(user.id)
        refute throttled?(apply(Accounts, @action, [user, %{code: "000000"}, [actor: user]]))
      end

      test "a spent budget gives a right and a wrong code one identical refusal, comparing neither (GHSA-4854-24jg-q7j5)" do
        # Past the throttle the code checks used to run anyway: a wrong code
        # added its own error and a right one did not, so the error list was a
        # code oracle with no budget at all.
        user = enabled_user()
        {user, right} = fresh_valid_attempt(@action, user)
        exhaust(user, @action)
        before = factor_state(user)

        right_result = apply(Accounts, @action, [user, right, [actor: user]])
        wrong_result = apply(Accounts, @action, [user, wrong_attempt(@action), [actor: user]])

        assert {:error, %{errors: [%SecondFactorThrottled{}]}} = right_result
        assert {:error, %{errors: [%SecondFactorThrottled{}]}} = wrong_result
        assert error_shape(right_result) == error_shape(wrong_result)

        # And the right one changed nothing.
        assert factor_state(user) == before
      end

      test "with budget left, a wrong code is still told it is wrong" do
        user = enabled_user()
        {user, _right} = fresh_valid_attempt(@action, user)

        result = apply(Accounts, @action, [user, wrong_attempt(@action), [actor: user]])

        refute throttled?(result)
        assert {:error, %{errors: [_ | _] = errors}} = result
        assert Enum.all?(errors, &(Map.get(&1, :field) in [:code, :current_code]))
      end

      test "a refusal before the throttle spends no attempt" do
        # Demo mode refuses a non-admin's credential change up front; that
        # refusal must leave the budget whole, and compare no code either.
        user = enabled_user()
        editor = Ash.Seed.update!(user, %{role: :editor})

        with_demo_mode(fn ->
          for _ <- 1..(@budget + 1) do
            assert {:error, %{errors: errors}} =
                     apply(Accounts, @action, [editor, wrong_attempt(@action), [actor: editor]])

            assert [%KilnCMS.Accounts.Errors.DemoAccountLocked{}] = errors
          end
        end)

        # The whole budget is still there: as many wrong guesses as it allows,
        # none of them throttled.
        for _ <- 1..@budget do
          refute throttled?(
                   apply(Accounts, @action, [editor, wrong_attempt(@action), [actor: editor]])
                 )
        end
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
    # #754: `:confirm_totp` now checks `totp_pending_secret`, not the live
    # secret — an enrolled account with no re-enrolment in progress has no
    # pending secret at all, so nothing here can be guessed *or* proven, the
    # live code included.
    test "without a pending secret, no code is accepted — not even the live one" do
      user = enabled_user()

      assert {:error, _} = Accounts.confirm_totp(user, %{code: valid_code()}, actor: user)

      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert reloaded.totp_secret == @secret
      assert reloaded.totp_confirmed_at == user.totp_confirmed_at
    end

    test "still charges the budget on a guess, even though nothing can match" do
      user = enabled_user()
      exhaust(user, :confirm_totp)

      assert throttled?(Accounts.confirm_totp(user, %{code: "000000"}, actor: user))
    end

    test "spending it there refuses disable_totp too" do
      user = enabled_user()
      exhaust(user, :confirm_totp)

      assert throttled?(Accounts.disable_totp(user, %{code: "000000"}, actor: user))
    end
  end

  describe "confirming a re-enrolment (pending secret) on an already-enrolled account (#754)" do
    # The scenario the budget still guards on this action: the owner starts
    # switching devices (`:setup_totp` stages a pending secret) and a second,
    # attacker-held session on the same account tries to confirm it first.
    test "a correct code for the pending secret promotes it, replacing the live one" do
      user = enabled_user() |> with_pending()

      # `current_code` is required since #786 — replacing a CONFIRMED secret takes
      # proof of the outgoing one. Without it this test asserted the swap #786
      # exists to refuse.
      assert {:ok, updated} =
               Accounts.confirm_totp(
                 user,
                 %{code: pending_code(user), current_code: valid_code()},
                 actor: user
               )

      assert updated.totp_secret == user.totp_pending_secret
      refute updated.totp_secret == @secret
      assert is_nil(updated.totp_pending_secret)
      assert length(Ash.Resource.get_metadata(updated, :recovery_codes)) == 10
    end

    test "grinding the pending secret is charged and eventually throttled" do
      user = enabled_user() |> with_pending()
      exhaust(user, :confirm_totp)

      assert throttled?(Accounts.confirm_totp(user, %{code: "000000"}, actor: user))
    end
  end
end
