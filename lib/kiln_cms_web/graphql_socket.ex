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
    # `KilnCMSWeb.BridgeSocket`.
    #
    # A missing host (e.g. `connect_info` absent in tests) counts as
    # unresolvable: normally the default org, and under `TENANT_STRICT_HOST` a
    # refused connection rather than a socket silently scoped to the wrong site
    # (#563).
    case KilnCMSWeb.Tenant.fetch_org(get_in(connect_info, [:uri, Access.key(:host)])) do
      {:ok, org} ->
        context = params |> actor_context() |> Map.put(:tenant, org.id)
        {:ok, Absinthe.Phoenix.Socket.put_options(socket, context: context)}

      :error ->
        :error
    end
  end

  # An unusable or absent bearer token connects anonymously rather than being
  # refused — the public read surface is reachable without one, and the
  # resource policies are what gate everything past it.
  defp actor_context(params) do
    case BearerAuth.token_from_params(params) do
      nil ->
        BearerAuth.graphql_context(nil)

      token ->
        case BearerAuth.user_from_token(token) do
          {:ok, user} -> BearerAuth.graphql_context(user)
          :error -> BearerAuth.graphql_context(nil)
        end
    end
  end

  @impl true
  def id(_socket), do: nil
end
