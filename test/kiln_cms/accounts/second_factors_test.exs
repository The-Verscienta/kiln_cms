defmodule KilnCMS.Accounts.SecondFactorsTest do
  @moduledoc """
  Which second factors an account holds (#2247): `Accounts.second_factors/1`
  and `Accounts.has_second_factor?/1`, for every combination of the
  authenticator app and passkeys.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.PasskeyFixtures

  alias KilnCMS.Accounts

  defp with_app(user), do: Ash.Seed.update!(user, %{totp_confirmed_at: DateTime.utc_now()})

  test "none" do
    user = passkey_user()

    assert Accounts.second_factors(user) == %{totp?: false, passkeys: 0}
    refute Accounts.has_second_factor?(user)
  end

  test "the authenticator app only" do
    user = with_app(passkey_user())

    assert Accounts.second_factors(user) == %{totp?: true, passkeys: 0}
    assert Accounts.has_second_factor?(user)
  end

  test "a passkey only" do
    user = passkey_user()
    {:ok, _} = enroll(user, "sfs-only-#{user.id}")

    assert Accounts.second_factors(user) == %{totp?: false, passkeys: 1}
    assert Accounts.has_second_factor?(user)
  end

  test "both, with every passkey counted" do
    user = with_app(passkey_user())
    {:ok, _} = enroll(user, "sfs-a-#{user.id}")
    {:ok, _} = enroll(user, "sfs-b-#{user.id}")

    assert Accounts.second_factors(user) == %{totp?: true, passkeys: 2}
    assert Accounts.has_second_factor?(user)
  end

  test "another account's passkeys are not counted" do
    user = passkey_user()
    other = passkey_user()
    {:ok, _} = enroll(other, "sfs-other-#{other.id}")

    assert Accounts.second_factors(user) == %{totp?: false, passkeys: 0}
  end

  test "the map answers without a read" do
    assert Accounts.has_second_factor?(%{totp?: false, passkeys: 1})
    assert Accounts.has_second_factor?(%{totp?: true, passkeys: 0})
    refute Accounts.has_second_factor?(%{totp?: false, passkeys: 0})
  end
end
