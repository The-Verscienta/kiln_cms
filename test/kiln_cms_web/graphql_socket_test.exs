defmodule KilnCMSWeb.GraphqlSocketTest do
  # async: false — the join-budget test mutates the shared RateLimit config
  # (the Hammer ETS table is one per node).
  use KilnCMS.DataCase, async: false

  import KilnCMS.RateLimitHelpers, only: [client_address: 0]

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.GraphqlSocket
  alias KilnCMSWeb.RateLimit

  @password "password123456"

  defp put_gql_join_limit(limit) do
    current = Application.get_env(:kiln_cms, RateLimit, [])

    limits =
      current |> Keyword.get(:limits, %{}) |> Map.put(:gql_join, {limit, :timer.minutes(1)})

    Application.put_env(:kiln_cms, RateLimit, Keyword.put(current, :limits, limits))
  end

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

  test "connect/3 charges the gql_join budget first, refusing an over-budget address before tenant/auth resolve" do
    on_exit(fn -> Application.delete_env(:kiln_cms, RateLimit) end)
    put_gql_join_limit(1)

    address = client_address()
    connect_info = %{peer_data: %{address: address, port: 111, ssl_cert: nil}, x_headers: []}

    assert {:ok, _socket} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
    assert :error = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
  end
end
