defmodule KilnCMSWeb.GraphqlSocket do
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMSWeb.BearerAuth

  @impl true
  def connect(params, socket, connect_info) do
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
      # Resolve the tenant from the connecting host (epic #336) — a raw transport
      # bypasses the SetTenant plug, so without this the GraphQL context's
      # `tenant` stays nil and every subscription/query over the socket spans all
      # orgs. The `org_id` (not the struct) is what AshGraphql's subscription
      # topic-matching compares against a record's `org_id`. Mirrors
      # `KilnCMSWeb.Channels.BridgeSocket`.
      |> Map.put(:tenant, resolve_org_id(connect_info))

    {:ok, Absinthe.Phoenix.Socket.put_options(socket, context: context)}
  end

  # A missing host (e.g. `connect_info` absent in tests) resolves to the default
  # org, matching the SetTenant plug's fallback.
  defp resolve_org_id(connect_info) do
    connect_info
    |> get_in([:uri, Access.key(:host)])
    |> KilnCMSWeb.Tenant.resolve_org()
    |> Map.fetch!(:id)
  end

  @impl true
  def id(_socket), do: nil
end
