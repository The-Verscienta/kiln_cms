defmodule KilnCMS.Accounts.SignInCounterTest do
  @moduledoc """
  When the per-account sign-in counter is forgiven (#478, #742).

  #478 clears it on a successful password, which is right for an account whose
  password *is* the sign-in. For a 2FA account it was the hole: the password
  succeeds, so the counter reset on every attempt, and someone holding a stuffed
  password for an account they cannot pass could loop `POST /api/auth/sign_in`
  indefinitely. The only remaining bound was the per-IP `:auth` bucket — the
  axis #478 exists *because* attackers rotate it.

  Each of those calls also mints and stores a token row nobody will ever hold:
  `store_all_tokens?` writes the JWT before the controller learns the account
  owes a code, so the cost was unbounded `tokens` growth for a chosen account
  as well as unbounded guessing.

  So the counter is now held until `SecondFactor.check/2` sees the second factor
  land. These tests pin both halves — held for a 2FA account, still forgiven for
  everyone else — because getting the second wrong would lock out every account
  that has no second factor at all.

  `async: false`: node-wide ETS budgets, tightened app-wide via `put_env`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User

  @password "password123456"
  @budget 3

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        budget: @budget,
        # Widened, not tightened — a fixed-window rollover mid-test is the #697
        # flake shape.
        window: :timer.hours(1),
        second_factor_budget: 10,
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp seed(extra) do
    address = "counter-#{System.unique_integer([:positive])}@example.com"

    user =
      Ash.Seed.seed!(
        User,
        Map.merge(
          %{
            email: address,
            hashed_password: Bcrypt.hash_pwd_salt(@password),
            confirmed_at: DateTime.utc_now(),
            role: :editor
          },
          extra
        )
      )

    on_exit(fn ->
      AccountThrottle.reset(address)
      AccountThrottle.forgive_second_factor(user.id)
      AccountThrottle.forget_second_factor_alert(user.id)
    end)

    {user, address}
  end

  defp two_factor_user do
    secret = :crypto.strong_rand_bytes(20)
    {user, address} = seed(%{totp_secret: secret, totp_confirmed_at: DateTime.utc_now()})
    {user, address, secret}
  end

  defp password_sign_in(address) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => address,
      "password" => @password
    })
  end

  describe "an account with no second factor" do
    test "a correct password still clears the counter" do
      # The half that must not regress: for these accounts the password *is* the
      # sign-in, and holding the counter would lock out everyone who mistypes
      # a few times before getting it right.
      {_user, address} = seed(%{})

      Enum.each(1..@budget, fn _ -> AccountThrottle.consume(address) end)
      assert {:deny, _ms} = AccountThrottle.consume(address)

      AccountThrottle.reset(address)
      assert {:ok, _user} = password_sign_in(address)

      # Forgiven, so a full budget is available again.
      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
    end
  end

  describe "an account that owes a second factor" do
    test "a correct password does NOT clear the counter" do
      # The fix. Before #742 this returned to zero on every call, so the loop
      # below never ended.
      {_user, address, _secret} = two_factor_user()

      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)

      # Three first factors spent three units of a budget of three.
      assert {:deny, _ms} = AccountThrottle.consume(address)
    end

    test "looping the first factor is therefore bounded" do
      # The attack the issue describes, run end to end: a stuffed password for
      # an account the caller cannot pass. Each pass mints and stores a token
      # row nobody holds; the point is that it stops.
      {_user, address, _secret} = two_factor_user()

      results = Enum.map(1..(@budget + 2), fn _ -> password_sign_in(address) end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == @budget
      assert Enum.any?(results, &match?({:error, _}, &1))
    end

    test "completing the second factor clears it" do
      # And the release. A legitimate user who signs in and enters their code is
      # back to a full budget, exactly as a 1FA user is after their password.
      {user, address, secret} = two_factor_user()

      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)

      code = Totp.code_at(secret, System.system_time(:second))
      assert {:ok, _verified} = SecondFactor.check(user, code)

      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
    end

    test "a wrong code leaves the counter held" do
      # Only a *completed* sign-in releases it. Forgiving on a failed second
      # factor would hand the loop back to the attacker one level down.
      {user, address, _secret} = two_factor_user()

      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)

      assert :invalid = SecondFactor.check(user, "000000")
      assert {:deny, _ms} = AccountThrottle.consume(address)
    end

    test "a recovery code releases it too, though the record is a fresh one" do
      # The one path where the forgive key comes off a record the charge never
      # saw: `consume_totp_recovery_code` returns a *new* struct, and the
      # release reads `verified.email` from it. A `%Ash.NotLoaded{}` or a nil
      # there would forgive a bucket nobody charged, and the hold would be
      # permanent.
      codes = RecoveryCodes.generate()
      secret = :crypto.strong_rand_bytes(20)

      {user, address} =
        seed(%{
          totp_secret: secret,
          totp_confirmed_at: DateTime.utc_now(),
          totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)
        })

      assert {:ok, _user} = password_sign_in(address)
      assert {:ok, _user} = password_sign_in(address)

      assert {:ok, _verified} = SecondFactor.check(user, hd(codes))

      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
      assert :allow = AccountThrottle.consume(address)
    end

    test "a locked-out second factor spends the first factor's budget too" do
      # The composition, pinned because it is the cost of this fix rather than a
      # bug in it. While the tighter budget is refusing, `check/2` denies before
      # it can release anything — so the retries both controllers tell a user to
      # make each spend a unit that nothing will hand back until the window
      # rolls. The owner reaches it themselves by fumbling codes, since #727
      # shares that bucket with `/editor/settings`.
      #
      # If this is ever judged too harsh, the lever is `@budget` or refunding
      # the unit on a `{:deny, _, _}` — but the latter reopens #742's loop, so
      # it is not a free change.
      {user, address, _secret} = two_factor_user()

      Enum.each(1..10, fn _ -> SecondFactor.check(user, "000000") end)
      assert {:deny, _user, _ms} = SecondFactor.check(user, "000000")

      results = Enum.map(1..(@budget + 1), fn _ -> password_sign_in(address) end)
      assert Enum.any?(results, &match?({:error, _}, &1))
    end

    test "the address is normalized, so the two halves agree on the bucket" do
      # `ThrottleSignIn` charges the *submitted* identifier; `SecondFactor`
      # forgives `user.email`. `AccountThrottle.digest/1` trims and downcases
      # both, so a differently-cased submission must not leave the charge in one
      # bucket and the forgive in another.
      {user, address, secret} = two_factor_user()
      shouted = String.upcase(address)

      assert {:ok, _user} = password_sign_in(shouted)
      assert {:ok, _user} = password_sign_in(shouted)

      code = Totp.code_at(secret, System.system_time(:second))
      assert {:ok, _verified} = SecondFactor.check(user, code)

      assert :allow = AccountThrottle.consume(shouted)
      assert :allow = AccountThrottle.consume(shouted)
      assert :allow = AccountThrottle.consume(shouted)
    end
  end
end
