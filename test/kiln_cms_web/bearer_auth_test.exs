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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

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

  doctest BearerAuth, only: [parse: 1]

  describe "parse/1 (#2632)" do
    test "the scheme is case-insensitive and whitespace-tolerant" do
      for value <- ["Bearer abc", "bearer abc", "BEARER abc", "bEaReR abc", "  bearer\tabc  "] do
        assert BearerAuth.parse(value) == {:bearer, "abc"}, inspect(value)
      end
    end

    test "a bare scheme has no token; another scheme or a non-string is :other" do
      for value <- ["Bearer", "bearer", "Bearer   ", "  BEARER"] do
        assert BearerAuth.parse(value) == {:bearer, nil}, inspect(value)
      end

      for value <- ["Basic dXNlcjpwYXNz", "Bearerabc", "", "kiln_x", nil, 42, %{}] do
        assert BearerAuth.parse(value) == :other, inspect(value)
      end
    end

    test "normalize/1 rewrites only a bearer with a token" do
      assert BearerAuth.normalize(" bearer  abc ") == "Bearer abc"
      assert BearerAuth.normalize("bearer") == "bearer"
      assert BearerAuth.normalize("Basic x") == "Basic x"
    end
  end

  describe "token_from_params/1" do
    test "reads the Authorization param under any case of the scheme" do
      assert BearerAuth.token_from_params(%{"Authorization" => "bearer abc"}) == "abc"
      assert BearerAuth.token_from_params(%{"authorization" => "BEARER abc"}) == "abc"

      assert BearerAuth.token_from_params(%{"token" => "t", "authorization" => "Bearer abc"}) ==
               "t"
    end

    test "a bare Bearer is an empty token, which never verifies; no bearer is nil" do
      assert BearerAuth.token_from_params(%{"Authorization" => "bearer"}) == ""
      assert :error = BearerAuth.user_from_token("")
      assert BearerAuth.token_from_params(%{"Authorization" => "Basic x"}) == nil
      assert BearerAuth.token_from_params(%{}) == nil
    end
  end

  test "graphql_context/1 matches AshGraphql.Plug shape" do
    {user, _} = sign_in_user(:editor)
    assert %{actor: ^user, tenant: nil, context: %{}} = BearerAuth.graphql_context(user)
    assert %{actor: nil, tenant: nil, context: %{}} = BearerAuth.graphql_context(nil)
  end
end
