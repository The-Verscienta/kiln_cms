defmodule KilnCMSWeb.GraphqlSchema do
  @moduledoc false
  use Absinthe.Schema

  use AshGraphql,
    domains: [KilnCMS.CMS]

  # Follow-up: when list queries are first exposed via GraphQL, add a query
  # complexity/depth limit (e.g. `Absinthe.Plug` `max_complexity:` plus
  # `Absinthe.Phase.Document.Complexity.Analysis`) so a deeply nested or
  # wide query can't force an unbounded resolve. Latent today — no list
  # queries are exposed, only the `:health` probe.

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
