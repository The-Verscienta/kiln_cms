defmodule KilnCMSWeb.GraphqlSocketTest do
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.GraphqlSocket

  @password "password123456"

  test "connect/3 sets actor in absinthe context when a valid token is provided" do
    email = "socket-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    token = signed_in.__metadata__.token

    assert {:ok, socket} = GraphqlSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    assert socket.assigns.absinthe.opts[:context].actor.id == signed_in.id
  end

  test "connect/3 allows anonymous connections with a nil actor" do
    assert {:ok, socket} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert socket.assigns.absinthe.opts[:context].actor == nil
  end
end
