defmodule KilnCMSWeb.GraphqlSchema do
  @moduledoc false
  use Absinthe.Schema

  # Domains come from `:content_domains` at compile time, so a downstream
  # project overlay (see projects/README.md) exposes its content domain on the
  # GraphQL surface purely via `config/project.exs` — no core edit. The default
  # keeps a clean core build referencing only domains that exist in this repo.
  use AshGraphql,
    domains: Application.compile_env(:kiln_cms, :content_domains, [KilnCMS.CMS])

  # Query cost is bounded at the transport: the `/gql` Absinthe.Plug forward sets
  # `analyze_complexity: true` + `max_complexity:` (see the router) so a deeply
  # nested or wide query can't force an unbounded resolve. Introspection is
  # disabled in production by KilnCMSWeb.Plugs.DisableGraphqlIntrospection.

  import_types Absinthe.Plug.Types

  @desc "An index entry of the historical collection view (#338)."
  object :point_in_time_entry do
    field :slug, non_null(:string)
    field :title, :string
    field :published_at, non_null(:datetime)
  end

  query do
    @desc "Lightweight GraphQL health probe"
    field :health, :string do
      resolve fn _, _, _ -> {:ok, "ok"} end
    end

    @desc """
    The collection as of a date (#338): every document of `type` that was
    published at that instant, reconstructed from version history — the
    GraphQL twin of `GET /api/content/:type?as_of=`.
    """
    field :content_as_of, list_of(non_null(:point_in_time_entry)) do
      arg :type, non_null(:string)
      arg :as_of, non_null(:datetime)
      arg :limit, :integer

      resolve fn %{type: type, as_of: as_of} = args, resolution ->
        # Compiled types only — a dynamic (D17) descriptor has resource: nil
        # (the documented later-phase boundary), so error cleanly, never crash.
        case KilnCMS.CMS.ContentTypes.get(type, graphql_org_id(resolution)) do
          %{resource: resource} when not is_nil(resource) ->
            {:ok,
             KilnCMS.Firing.PointInTime.index(
               graphql_org_id(resolution),
               resource,
               as_of,
               limit: min(args[:limit] || 100, 500)
             )}

          _ ->
            {:error, "unknown content type (historical collections cover compiled types)"}
        end
      end
    end
  end

  # The request's org from the Absinthe context (set by the SetTenant plug via
  # AshGraphql), falling back to the default org — same posture as delivery.
  defp graphql_org_id(%{context: context}) do
    case context[:tenant] do
      %{id: id} -> id
      id when is_binary(id) -> id
      _ -> KilnCMS.Accounts.default_org_id()
    end
  end

  mutation do
    # Custom Absinthe mutations can be placed here
  end

  subscription do
    # Custom Absinthe subscriptions can be placed here
  end
end
