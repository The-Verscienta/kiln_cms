defmodule KilnCMSWeb.GraphqlSchema do
  @moduledoc false
  use Absinthe.Schema

  use AshGraphql,
    domains: [KilnCMS.CMS]

  # Query cost is bounded at the transport: the `/gql` Absinthe.Plug forward sets
  # `analyze_complexity: true` + `max_complexity:` (see the router) so a deeply
  # nested or wide query can't force an unbounded resolve. Introspection is
  # disabled in production by KilnCMSWeb.Plugs.DisableGraphqlIntrospection.

  import_types Absinthe.Plug.Types

  query do
    @desc "Lightweight GraphQL health probe"
    field :health, :string do
      resolve fn _, _, _ -> {:ok, "ok"} end
    end
  end

  mutation do
    # Custom Absinthe mutations can be placed here
  end

  subscription do
    # Custom Absinthe subscriptions can be placed here
  end
end
