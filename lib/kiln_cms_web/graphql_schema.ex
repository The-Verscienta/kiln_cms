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

  @desc """
  A resolved navigation item (#466): the label, the **live** URL its stored
  reference currently points at, and its children.
  """
  object :menu_node do
    field :id, non_null(:id)
    field :label, non_null(:string)

    @desc "nil for a heading (`link_type: NONE`) — everything else carries one."
    field :url, :string

    field :link_type, non_null(:string) do
      resolve fn node, _, _ -> {:ok, to_string(node.link_type)} end
    end

    field :open_in_new_tab, non_null(:boolean)
    field :children, non_null(list_of(non_null(:menu_node)))
  end

  @desc "A resolved navigation menu (#466)."
  object :menu do
    field :key, non_null(:string)
    field :name, non_null(:string)
    field :locale, non_null(:string)
    field :items, non_null(list_of(non_null(:menu_node)))
  end

  query do
    @desc "Lightweight GraphQL health probe"
    field :health, :string do
      resolve fn _, _, _ -> {:ok, "ok"} end
    end

    @desc """
    One navigation menu by its stable key, resolved (#466) — the GraphQL twin of
    `GET /api/menus/:key`.

    Every `:content` item's `url` is the target's *current* published path, and
    items pointing at unpublished content — or hidden by an editor — are omitted
    along with their children. The stored rows are deliberately **not** on the
    auto GraphQL surface: they carry references rather than URLs, and they carry
    exactly what those rules exist to withhold.

    `locale` defaults to the site's default locale; a locale the site does not
    run is an error, not the default menu. A menu with no variant in the
    requested locale follows the site's *configured* fallback chain only — never
    the implicit hop to the default locale, because English navigation on a
    French page is a worse answer than none unless the site said otherwise — and
    otherwise returns `null`. `fallback: false` and `fallbackLocale` narrow the
    chain as on every delivery surface. The result's `locale` is the variant
    served.
    """
    field :menu, :menu do
      arg :key, non_null(:string)
      arg :locale, :string
      arg :fallback, :boolean
      arg :fallback_locale, :string

      resolve fn args, resolution ->
        params =
          %{
            "locale" => args[:locale],
            "fallback" => if(is_boolean(args[:fallback]), do: to_string(args[:fallback])),
            "fallback_locale" => args[:fallback_locale]
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        case KilnCMSWeb.DeliveryLocale.parse(params) do
          {:ok, request} -> resolve_menu(args.key, request, graphql_org_id(resolution))
          {:error, _code, message} -> {:error, message}
        end
      end
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

  defp resolve_menu(key, %{locale: locale, mode: mode}, org_id) do
    case KilnCMS.CMS.Menus.resolve(key, locale, org_id, fallback: mode) do
      {:ok, menu, items} ->
        {:ok, %{key: menu.key, name: menu.name, locale: menu.locale, items: items}}

      :not_found ->
        {:ok, nil}
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
