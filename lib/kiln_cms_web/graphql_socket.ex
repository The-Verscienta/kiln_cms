defmodule KilnCMSWeb.GraphqlSocket do
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMSWeb.BearerAuth

  @impl true
  def connect(params, socket, connect_info) do
    # Resolve the tenant from the connecting host (epic #336) — a raw transport
    # bypasses the SetTenant plug, so without this the GraphQL context's
    # `tenant` stays nil and every subscription/query over the socket spans all
    # orgs. The `org_id` (not the struct) is what AshGraphql's subscription
    # topic-matching compares against a record's `org_id`. Mirrors
    # `KilnCMSWeb.Channels.BridgeSocket`.
    #
    # Under strict host mode the connection is REFUSED rather than falling back
    # to the default org (#563): a socket is opened directly, so it is the one
    # surface where an attacker-chosen host never passes the plug that would
    # otherwise 404 it.
    case KilnCMSWeb.Tenant.fetch_org(get_in(connect_info, [:uri, Access.key(:host)])) do
      {:ok, org} ->
        context = params |> auth_context() |> Map.put(:tenant, org.id)
        {:ok, Absinthe.Phoenix.Socket.put_options(socket, context: context)}

      :error ->
        :error
    end
  end

  defp auth_context(params) do
    case BearerAuth.token_from_params(params) do
      nil -> BearerAuth.graphql_context(nil)
      token -> token |> BearerAuth.user_from_token() |> user_context()
    end
  end

  defp user_context({:ok, user}), do: BearerAuth.graphql_context(user)
  defp user_context(:error), do: BearerAuth.graphql_context(nil)

  @impl true
  def id(_socket), do: nil
end
