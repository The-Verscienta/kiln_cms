defmodule KilnCMSWeb.GraphqlSocket do
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMSWeb.BearerAuth

  @impl true
  def connect(params, socket, _connect_info) do
    context =
      params
      |> BearerAuth.token_from_params()
      |> case do
        nil ->
          BearerAuth.graphql_context(nil)

        token ->
          case BearerAuth.user_from_token(token) do
            {:ok, user} -> BearerAuth.graphql_context(user)
            :error -> BearerAuth.graphql_context(nil)
          end
      end

    {:ok, Absinthe.Phoenix.Socket.put_options(socket, context: context)}
  end

  @impl true
  def id(_socket), do: nil
end
