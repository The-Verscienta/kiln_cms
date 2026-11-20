defmodule KilnCMSWeb.GraphqlSocketTest do
  # async: false — the join-budget test mutates the shared RateLimit config
  # (the Hammer ETS table is one per node).
  use KilnCMS.DataCase, async: false

  import KilnCMS.RateLimitHelpers,
    only: [client_address: 0, put_limit: 2, restore_limits_on_exit: 0]

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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    token = signed_in.__metadata__.token

    assert {:ok, socket} = GraphqlSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    assert socket.assigns.absinthe.opts[:context].actor.id == signed_in.id
  end

  # The scheme is case-insensitive over the socket too (#2632). Before, any
  # value without the exact `Bearer ` prefix was ignored, so a lower-case
  # valid JWT connected anonymously, and so did lower-case garbage.
  describe "connect/3 with an Authorization param in any case" do
    setup do
      user =
        Ash.Seed.seed!(User, %{
          email: "socket-case-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      {:ok, signed_in} =
        AshAuthentication.Strategy.action(
          AshAuthentication.Info.strategy!(User, :password),
          :sign_in,
          %{"email" => user.email, "password" => @password},
          []
        )

      %{user: user, token: signed_in.__metadata__.token}
    end

    test "a lower-case valid JWT connects as its user", %{user: user, token: token} do
      for value <- ["bearer " <> token, "BEARER " <> token] do
        assert {:ok, socket} =
                 GraphqlSocket.connect(%{"Authorization" => value}, %Phoenix.Socket{}, %{})

        assert socket.assigns.absinthe.opts[:context].actor.id == user.id
      end
    end

    test "lower-case garbage and a bare scheme are refused, not anonymous" do
      for value <- ["bearer garbage", "bearer", "Bearer", "BEARER  "] do
        assert :error =
                 GraphqlSocket.connect(%{"authorization" => value}, %Phoenix.Socket{}, %{}),
               "#{inspect(value)} connected"
      end
    end

    test "another scheme stays anonymous" do
      assert {:ok, socket} =
               GraphqlSocket.connect(%{"Authorization" => "Basic x"}, %Phoenix.Socket{}, %{})

      assert socket.assigns.absinthe.opts[:context].actor == nil
    end
  end

  test "connect/3 allows anonymous connections with a nil actor" do
    assert {:ok, socket} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert socket.assigns.absinthe.opts[:context].actor == nil
  end

  test "connect/3 charges the gql_join budget first, refusing an over-budget address before tenant/auth resolve" do
    # Restored, not deleted (#1614): a delete drops config/test.exs's raised
    # limits for every later module, and the next conn to spend 61 /gql
    # requests gets a 429 from the shipped 60/min.
    restore_limits_on_exit()
    put_limit(:gql_join, 1)

    address = client_address()
    connect_info = %{peer_data: %{address: address, port: 111, ssl_cert: nil}, x_headers: []}

    assert {:ok, _socket} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
    assert :error = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
  end
end
