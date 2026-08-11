defmodule KilnCMS.TwoFactorFixturesTest do
  @moduledoc """
  The shared TOTP fixture's own behaviour (#746).

  A fixture used by nine files is production code for the suite, and this one has
  two decisions that nothing else pins: which secret `current_code/1` prefers,
  and what `enabled_user/1` returns. Both survived mutation before this file
  existed — inverting the secret preference left 132 tests green — and the
  failure they cause is the worst kind: a test asserting a *refusal* keeps
  passing, for the wrong reason.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Totp
  alias KilnCMS.TwoFactorFixtures

  describe "enabled_user/1" do
    test "returns the secret it actually seeded" do
      {user, secret} = TwoFactorFixtures.enabled_user()

      assert user.totp_secret == secret
      assert Totp.valid?(secret, TwoFactorFixtures.current_code(secret))
    end

    test "a pinned secret is the one seeded and the one returned" do
      pinned = :crypto.strong_rand_bytes(20)
      {user, secret} = TwoFactorFixtures.enabled_user(secret: pinned)

      assert secret == pinned
      assert user.totp_secret == pinned
    end

    # The footgun: every helper this fixture replaced spelled the attribute
    # name, so `totp_secret:` is the natural thing to reach for — and it would
    # seed one secret while returning another, making `current_code/1` produce a
    # code that can never verify. A test asserting a refusal would then pass for
    # entirely the wrong reason.
    test "a non-nil totp_secret: is refused rather than silently ignored" do
      assert_raise ArgumentError, ~r/Pass `secret:` instead/, fn ->
        TwoFactorFixtures.enabled_user(totp_secret: :crypto.strong_rand_bytes(20))
      end
    end

    # …but an account with recovery codes and no TOTP factor is a real thing to
    # want, and there the returned secret is meaningless anyway.
    test "totp_secret: nil is allowed" do
      {user, _secret} = TwoFactorFixtures.enabled_user(totp_secret: nil)

      assert is_nil(user.totp_secret)
    end

    test "defaults to an admin, and takes any other attribute" do
      {admin, _} = TwoFactorFixtures.enabled_user()
      assert admin.role == :admin

      {editor, _} = TwoFactorFixtures.enabled_user(role: :editor)
      assert editor.role == :editor
    end

    test "the seeded password is the one the module publishes" do
      {user, _secret} = TwoFactorFixtures.enabled_user()

      assert Bcrypt.verify_pass(TwoFactorFixtures.password(), user.hashed_password)
    end
  end

  describe "current_code/1" do
    test "from a secret, is the code that secret accepts now" do
      secret = :crypto.strong_rand_bytes(20)

      assert Totp.valid?(secret, TwoFactorFixtures.current_code(secret))
    end

    # The preference that had no test. A mid-enrolment user holds the secret
    # being *confirmed* in `totp_pending_secret`; reaching for `totp_secret`
    # there mints a code for the factor being replaced — which the enrolment
    # step then rejects, and the test reads that as the feature working.
    test "from a user, prefers the pending secret over the live one" do
      live = :crypto.strong_rand_bytes(20)
      pending = :crypto.strong_rand_bytes(20)
      {user, _} = TwoFactorFixtures.enabled_user(secret: live)
      user = Ash.Seed.update!(user, %{totp_pending_secret: pending})

      code = TwoFactorFixtures.current_code(user)

      assert Totp.valid?(pending, code)
      refute Totp.valid?(live, code)
    end

    test "from a user with no enrolment in flight, uses the live secret" do
      {user, secret} = TwoFactorFixtures.enabled_user()

      assert Totp.valid?(secret, TwoFactorFixtures.current_code(user))
    end
  end

  describe "with_recovery_codes/1" do
    test "returns codes that verify against the stored hashes" do
      {user, _secret} = TwoFactorFixtures.enabled_user()
      {user, codes} = TwoFactorFixtures.with_recovery_codes(user)

      assert length(user.totp_recovery_hashes) == length(codes)
      assert {:ok, _verified} = KilnCMS.Accounts.SecondFactor.check(user, hd(codes))
    end
  end
end
