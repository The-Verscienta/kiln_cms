defmodule KilnCMSWeb.GraphqlSchema do
  @moduledoc false
  use Absinthe.Schema

  use AshGraphql,
    domains: [KilnCMS.CMS]

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
