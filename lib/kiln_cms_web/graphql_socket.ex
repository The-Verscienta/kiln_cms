defmodule KilnCMSWeb.GraphqlSocket do
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMSWeb.BearerAuth

  @impl true
  def connect(params, socket, connect_info) do
    # Charged first, ahead of tenant resolution (threat-model item 10's
    # `/ws/*` gap — see `KilnCMSWeb.SocketJoinBudget`): a connect this
    # deployment is about to refuse anyway still cost a handshake, so it still
    # has to count.
    with :ok <- KilnCMSWeb.SocketJoinBudget.charge(:gql_join, connect_info) do
      do_connect(params, socket, connect_info)
    end
  end

  defp do_connect(params, socket, connect_info) do
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
    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info) do
      {:ok, org} ->
        context = params |> actor_context() |> Map.put(:tenant, org.id)

        socket =
          socket
          # Kept as an assign as well as in the Absinthe context, because `id/1`
          # is given the Phoenix socket and cannot see the Absinthe options
          # (#675).
          |> Phoenix.Socket.assign(:kiln_actor_id, actor_id(context))
          |> Absinthe.Phoenix.Socket.put_options(context: context)

        {:ok, socket}

      :error ->
        # The decision point, not `Tenant.fetch_org_from_connect_info/1` itself
        # (#678) — this is where the connection is actually refused.
        KilnCMSWeb.TenantRefusalAlert.notify(
          :gql,
          KilnCMSWeb.Tenant.connect_info_host(connect_info)
        )

        :error

      # The lookup failed rather than found nothing. A socket has no 503 to
      # send, so the connect is refused either way and the client retries — but
      # it is not alerted, because the refusal alert counts hosts this
      # deployment does not serve and this may be one it does.
      :unavailable ->
        :error
    end
  end

  defp actor_id(%{actor: %{id: id}}), do: id
  defp actor_id(_context), do: nil

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

  # `nil` is Phoenix's way of saying a socket can never be disconnected, which
  # is what left a demoted or deleted user's subscriptions running until they
  # closed the tab (#675). An authenticated socket is now keyed on its user so
  # `KilnCMS.Accounts.SessionEviction` can drop it; an anonymous one keeps `nil`,
  # since it holds no grant that can be revoked.
  @impl true
  def id(socket) do
    case socket.assigns[:kiln_actor_id] do
      user_id when is_binary(user_id) -> KilnCMS.Accounts.SessionEviction.topic(user_id)
      _anonymous -> nil
    end
  end
end
