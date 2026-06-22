defmodule KilnCMSWeb.BearerAuthTest do
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.BearerAuth

  @password "password123456"

  defp sign_in_user(role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    {signed_in, signed_in.__metadata__.token}
  end

  test "user_from_token/1 returns the user for a valid bearer token" do
    {user, token} = sign_in_user(:editor)
    assert {:ok, authed} = BearerAuth.user_from_token(token)
    assert authed.id == user.id
    assert authed.role == :editor
  end

  test "user_from_token/1 rejects invalid tokens" do
    assert :error = BearerAuth.user_from_token("not-a-jwt")
  end

  test "graphql_context/1 matches AshGraphql.Plug shape" do
    {user, _} = sign_in_user(:editor)
    assert %{actor: ^user, tenant: nil, context: %{}} = BearerAuth.graphql_context(user)
    assert %{actor: nil, tenant: nil, context: %{}} = BearerAuth.graphql_context(nil)
  end
end
