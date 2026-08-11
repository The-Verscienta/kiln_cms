defmodule KilnCMS.Accounts.TwoFactorTest do
  @moduledoc "TOTP 2FA enrolment actions (issue #331)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.TwoFactorFixtures

  defp user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "2fa-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # Pending during enrolment, live once confirmed — either way this is "the
  # code that should currently work".
  defp current_code(user),
    do: TwoFactorFixtures.current_code(user.totp_pending_secret || user.totp_secret)

  test "setup then confirm enables 2FA; a wrong code is rejected" do
    user = user()
    refute Accounts.totp_enabled?(user)

    {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
    assert is_binary(user.totp_pending_secret)
    # #754: setup stages a pending secret and touches nothing else — the live
    # secret and confirmation stay untouched until a code proves the pending one.
    assert is_nil(user.totp_secret)
    refute Accounts.totp_enabled?(user)

    assert {:error, _} = Accounts.confirm_totp(user, %{code: "000000"}, actor: user)

    {:ok, confirmed} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)
    assert Accounts.totp_enabled?(confirmed)
    assert is_nil(confirmed.totp_pending_secret)
  end

  test "disabling requires a valid current code" do
    user = user()
    {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
    {:ok, user} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)

    assert {:error, _} = Accounts.disable_totp(user, %{code: "000000"}, actor: user)
    assert Accounts.totp_enabled?(Accounts.get_user!(user.id, authorize?: false))

    {:ok, disabled} = Accounts.disable_totp(user, %{code: current_code(user)}, actor: user)
    refute Accounts.totp_enabled?(disabled)
    assert is_nil(disabled.totp_secret)
  end

  test "a user cannot set up 2FA on someone else's account" do
    actor = user()
    other = user()
    assert {:error, _} = Accounts.setup_totp(other, %{}, actor: actor)
  end

  # #754: `:setup_totp` used to write straight into `totp_secret` and null
  # `totp_confirmed_at` in the same call — any session on the account could
  # turn 2FA off with zero code guesses. Pins that a confirmed account's
  # `totp_confirmed_at` survives a re-enrolment attempt no matter how far it
  # gets, short of an actual `:confirm_totp`.
  describe "re-enrolling a confirmed account (#754)" do
    test "setup_totp alone cannot turn 2FA off" do
      user = user()
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      {:ok, enrolled} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)
      assert Accounts.totp_enabled?(enrolled)

      # A second `setup_totp` — e.g. from a stolen session, or the owner
      # starting to switch devices — stages a new pending secret but must not
      # touch the live one.
      {:ok, restarted} = Accounts.setup_totp(enrolled, %{}, actor: enrolled)

      assert Accounts.totp_enabled?(restarted)
      assert restarted.totp_secret == enrolled.totp_secret
      assert restarted.totp_confirmed_at == enrolled.totp_confirmed_at
      assert is_binary(restarted.totp_pending_secret)
      refute restarted.totp_pending_secret == enrolled.totp_secret

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert Accounts.totp_enabled?(reloaded)
    end

    test "confirm_totp without a pending secret is refused, even with the live code" do
      user = user()
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      {:ok, enrolled} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)

      live_code = TwoFactorFixtures.current_code(enrolled.totp_secret)

      assert {:error, _} = Accounts.confirm_totp(enrolled, %{code: live_code}, actor: enrolled)

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert Accounts.totp_enabled?(reloaded)
      assert reloaded.totp_secret == enrolled.totp_secret
    end
  end

  describe "replacing a confirmed secret needs proof of the outgoing one (#786)" do
    # Enrol, then stage a fresh pending secret over the live one.
    defp re_enrolling do
      user = user()
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      {:ok, enrolled} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)
      {:ok, restarted} = Accounts.setup_totp(enrolled, %{}, actor: enrolled)

      %{
        enrolled: enrolled,
        restarted: restarted,
        new_code: TwoFactorFixtures.current_code(restarted.totp_pending_secret),
        live_code: TwoFactorFixtures.current_code(restarted.totp_secret)
      }
    end

    test "the new secret's own code alone cannot promote it over the live one" do
      %{enrolled: enrolled, restarted: restarted, new_code: new_code} = re_enrolling()

      # The #786 attack: a session runs setup_totp + confirm_totp with the pending
      # secret's own code (trivially known) and would otherwise swap the factor.
      assert {:error, _} = Accounts.confirm_totp(restarted, %{code: new_code}, actor: restarted)

      reloaded = Accounts.get_user!(enrolled.id, authorize?: false)

      assert reloaded.totp_secret == enrolled.totp_secret,
             "the live secret must be untouched"
    end

    test "a code from the current authenticator promotes it" do
      %{enrolled: enrolled, restarted: restarted, new_code: new_code, live_code: live_code} =
        re_enrolling()

      assert {:ok, swapped} =
               Accounts.confirm_totp(restarted, %{code: new_code, current_code: live_code},
                 actor: restarted
               )

      assert swapped.totp_secret == restarted.totp_pending_secret
      refute swapped.totp_secret == enrolled.totp_secret
    end

    test "a wrong current code is refused" do
      %{restarted: restarted, new_code: new_code} = re_enrolling()

      assert {:error, _} =
               Accounts.confirm_totp(restarted, %{code: new_code, current_code: "000000"},
                 actor: restarted
               )
    end

    test "a recovery-code session may promote it without a current code" do
      %{enrolled: enrolled, restarted: restarted, new_code: new_code} = re_enrolling()

      # `recovery_login?` stands in for the outgoing factor: the owner who lost
      # their authenticator signed in with a recovery code and has no live code.
      assert {:ok, swapped} =
               Accounts.confirm_totp(restarted, %{code: new_code, recovery_login?: true},
                 actor: restarted
               )

      assert swapped.totp_secret == restarted.totp_pending_secret
      refute swapped.totp_secret == enrolled.totp_secret
    end

    test "an account confirmed but with a nil secret still can't be swapped without proof" do
      # `totp_confirmed_at` set while `totp_secret` is nil — no shipped action
      # produces it (a partial write / restore / future rotate would), but 2FA is
      # still enforced there via recovery codes, so the replacement check must not
      # be skippable. Keying on `totp_confirmed_at` alone covers it.
      base = user()
      {:ok, base} = Accounts.setup_totp(base, %{}, actor: base)
      {:ok, enrolled} = Accounts.confirm_totp(base, %{code: current_code(base)}, actor: base)

      # Force the pathological state (no shipped action does), then stage a fresh
      # secret over it.
      nil_secret = Ash.Seed.update!(enrolled, %{totp_secret: nil})
      {:ok, restarted} = Accounts.setup_totp(nil_secret, %{}, actor: nil_secret)
      new_code = TwoFactorFixtures.current_code(restarted.totp_pending_secret)

      # No current code is even possible (the secret is nil); without a recovery
      # session it must be refused rather than silently promoted.
      assert {:error, _} = Accounts.confirm_totp(restarted, %{code: new_code}, actor: restarted)

      # A recovery-code session is still the sanctioned way back in.
      assert {:ok, _} =
               Accounts.confirm_totp(restarted, %{code: new_code, recovery_login?: true},
                 actor: restarted
               )
    end
  end

  # #787: two settings tabs open on the same account are two LiveView processes,
  # each holding its own `current_user` assign. `:confirm_totp` used to read the
  # pending secret off the passed-in struct, so the tab that staged first could
  # confirm a secret the DB no longer holds and silently discard the tab that
  # staged second. `:confirm_totp` now re-reads the pending secret from the DB,
  # pinning "last `:setup_totp` wins; a stale confirm is rejected".
  describe "two tabs racing a re-enrolment (#787)" do
    test "a stale confirm is rejected once a second tab has staged a newer secret" do
      user = user()

      # Two "tabs", both derived from the same original record.
      {:ok, tab_a} = Accounts.setup_totp(user, %{}, actor: user)
      secret_a = tab_a.totp_pending_secret

      # Tab B stages a newer secret. The DB now holds B; tab A's struct is stale.
      {:ok, tab_b} = Accounts.setup_totp(user, %{}, actor: user)
      secret_b = tab_b.totp_pending_secret
      refute secret_a == secret_b

      # Tab A submits a valid code for its now-superseded secret A. Because the
      # action re-reads the staged secret (B), A's code no longer matches and the
      # confirm is rejected — A is NOT promoted.
      code_a = TwoFactorFixtures.current_code(secret_a)
      assert {:error, _} = Accounts.confirm_totp(tab_a, %{code: code_a}, actor: tab_a)

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      refute Accounts.totp_enabled?(reloaded)
      assert reloaded.totp_pending_secret == secret_b

      # Tab B can still finish its own enrolment.
      code_b = TwoFactorFixtures.current_code(secret_b)
      {:ok, confirmed} = Accounts.confirm_totp(tab_b, %{code: code_b}, actor: tab_b)
      assert Accounts.totp_enabled?(confirmed)
      assert confirmed.totp_secret == secret_b
      assert is_nil(confirmed.totp_pending_secret)
    end

    test "the sole active enrolment confirms normally (reload is a no-op)" do
      # No second tab: the DB read returns the same secret the struct carries, so
      # the happy path is unchanged.
      user = user()
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

      {:ok, confirmed} =
        Accounts.confirm_totp(staged, %{code: current_code(staged)}, actor: staged)

      assert Accounts.totp_enabled?(confirmed)
      assert confirmed.totp_secret == staged.totp_pending_secret
    end
  end
end
