defmodule KilnCMS.Accounts.TwoFactorTest do
  @moduledoc "TOTP 2FA enrolment actions (issue #331)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp

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
    do: Totp.code_at(user.totp_pending_secret || user.totp_secret, System.system_time(:second))

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

      live_code = Totp.code_at(enrolled.totp_secret, System.system_time(:second))

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
        new_code: Totp.code_at(restarted.totp_pending_secret, System.system_time(:second)),
        live_code: Totp.code_at(restarted.totp_secret, System.system_time(:second))
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
  end
end
