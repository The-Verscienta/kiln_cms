defmodule KilnCMS.Accounts.UserAuthTest do
  @moduledoc """
  Guards that the User resource's policies and field policies don't break
  AshAuthentication, and that the `role` field policy behaves.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp confirmed_user(role) do
    Ash.Seed.seed!(User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # Sign in through the AshAuthentication strategy entry point (what the app
  # uses) — it sets the interaction context that the resource/field policy
  # bypasses key off.
  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => email,
      "password" => password
    })
  end

  test "sign-in succeeds with policies + field policies in place (auth bypass works)" do
    user = confirmed_user(:editor)
    assert {:ok, signed_in} = sign_in(to_string(user.email), @password)
    assert signed_in.id == user.id
  end

  test "sign-in rejects a wrong password" do
    user = confirmed_user(:editor)
    assert {:error, _} = sign_in(to_string(user.email), "wrong-password")
  end

  test "a user can read their own role" do
    user = confirmed_user(:editor)

    assert {:ok, read} = Ash.get(User, user.id, actor: user)
    assert read.role == :editor
  end
end
