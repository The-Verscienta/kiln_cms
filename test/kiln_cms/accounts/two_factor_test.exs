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

  defp current_code(user), do: Totp.code_at(user.totp_secret, System.system_time(:second))

  test "setup then confirm enables 2FA; a wrong code is rejected" do
    user = user()
    refute Accounts.totp_enabled?(user)

    {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
    assert is_binary(user.totp_secret)
    # A generated-but-unconfirmed secret does not yet enforce 2FA.
    refute Accounts.totp_enabled?(user)

    assert {:error, _} = Accounts.confirm_totp(user, %{code: "000000"}, actor: user)

    {:ok, confirmed} = Accounts.confirm_totp(user, %{code: current_code(user)}, actor: user)
    assert Accounts.totp_enabled?(confirmed)
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
end
