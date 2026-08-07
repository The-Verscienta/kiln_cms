defmodule KilnCMS.CMS.TaxonomyShapeTest do
  @moduledoc """
  What `KilnCMS.CMS.Taxonomy` guarantees every taxonomy resource has (#530).

  The three resources were near-verbatim copies of one shape, and the parts that
  mattered most — the policy stack, the tenancy strategy, the `writable?: false`
  `org_id` boundary — were exactly the parts a 3× edit could miss silently. The
  macro makes that structural; these assert the structure, so the guarantee
  survives the next option added to it.

  The drift the duplication had already produced is asserted too: `TagGroup` was
  the only one without a `:search` action, which is why tag groups were
  unfindable in `/search`, the command palette and the search API.
  """
  use KilnCMS.DataCase, async: true

  alias Ash.Resource.Info
  alias KilnCMS.CMS.Taxonomy

  @resources [KilnCMS.CMS.Category, KilnCMS.CMS.Tag, KilnCMS.CMS.TagGroup]

  describe "every taxonomy resource" do
    test "is partitioned by org_id, on the same axis as content" do
      for resource <- @resources do
        assert Info.multitenancy_strategy(resource) == :attribute, inspect(resource)
        assert Info.multitenancy_attribute(resource) == :org_id, inspect(resource)
      end
    end

    # The cross-site boundary: `org_id` is set from the tenant, never accepted
    # from input. A writable one on any admin path is a tenant escape.
    test "never accepts org_id from input" do
      for resource <- @resources do
        org_id = Info.attribute(resource, :org_id)

        refute org_id.writable?, inspect(resource)
        refute org_id.public?, inspect(resource)
        refute org_id.allow_nil?, inspect(resource)

        for action <- Info.actions(resource), action.type in [:create, :update] do
          refute :org_id in (action.accept || []), "#{inspect(resource)}.#{action.name}"
        end
      end
    end

    # Read-scoped API keys can never write taxonomy, and no key may hard-delete
    # it. Both checks must sit BEFORE the admin bypass, or a key on an admin
    # account skips them.
    test "gates API keys ahead of the admin bypass" do
      for resource <- @resources do
        policies = Ash.Policy.Info.policies(resource)

        bypass_at = Enum.find_index(policies, & &1.bypass?)
        assert bypass_at, "#{inspect(resource)}: no admin bypass"

        key_checks =
          for {policy, index} <- Enum.with_index(policies),
              check <- policy.policies,
              check.check_module in [
                KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess,
                AshAuthentication.Checks.UsingApiKey
              ],
              do: {check.check_module, index}

        assert length(key_checks) == 2, inspect(resource)

        for {module, index} <- key_checks do
          assert index < bypass_at, "#{inspect(resource)}: #{inspect(module)} after the bypass"
        end
      end
    end

    test "is world-readable" do
      for resource <- @resources do
        assert Ash.can?({resource, :read}, nil, tenant: nil), inspect(resource)
      end
    end

    test "is addressed by slug: a by_slug read, a search read, and a unique_slug identity" do
      for resource <- @resources do
        assert Info.action(resource, :by_slug), inspect(resource)
        assert Info.action(resource, :search), inspect(resource)
        assert Info.identity(resource, :unique_slug), inspect(resource)
        assert Info.calculation(resource, :name_similarity), inspect(resource)
      end
    end

    # The exact paths and type names, not just their shape: they are derived
    # from `plural` inside the macro, and a slip there renames a public URL —
    # `/api/json/tag-groups` is documented in docs/json-api.md and docs/api.md.
    test "exposes the same REST + GraphQL surface, at the documented paths" do
      expected = %{
        KilnCMS.CMS.Category =>
          {"category", ["/categories", "/categories/by-slug/:slug", "/categories/:id"]},
        KilnCMS.CMS.Tag => {"tag", ["/tags", "/tags/by-slug/:slug", "/tags/:id"]},
        KilnCMS.CMS.TagGroup =>
          {"tag_group", ["/tag-groups", "/tag-groups/by-slug/:slug", "/tag-groups/:id"]}
      }

      for {resource, {type, paths}} <- expected do
        routes = AshJsonApi.Resource.Info.routes(resource)

        assert AshJsonApi.Resource.Info.type(resource) == type
        # `/:id` LAST, so it can't shadow the static `/by-slug/:slug` above it —
        # declaration order is the routing order.
        assert Enum.map(routes, & &1.route) == paths
        assert Enum.map(routes, & &1.action) == [:read, :by_slug, :read]

        assert AshGraphql.Resource.Info.queries(resource)
               |> Enum.map(& &1.action)
               |> Enum.sort() == [:by_slug, :read]
      end
    end
  end

  describe "the search registry" do
    # `Search.global/2`'s taxonomy leg drove off a literal two-element list, so
    # adding TagGroup to the domain did not add it to search and nothing failed.
    # `searchable/0` now DISCOVERS them, so this literal is the expectation
    # rather than a second copy of the implementation: a fourth taxonomy
    # resource is meant to fail here, and be added deliberately.
    test "finds every taxonomy resource" do
      assert Enum.map(Taxonomy.searchable(), &elem(&1, 1)) |> Enum.sort() ==
               Enum.sort(@resources)
    end

    test "gives each one a distinct section key" do
      keys = Enum.map(Taxonomy.searchable(), &elem(&1, 0))
      assert keys == Enum.uniq(keys)
    end

    # `Search.global/2` collects its sections into one map, so a content type
    # whose plural collides with a reserved section silently overwrites it —
    # and because the fan-out is `ordered: false`, which one wins varies run to
    # run. A project registering a "tag group" content type would hit this.
    test "no section key collides with a content type's or a fixed section" do
      taxonomy = Enum.map(Taxonomy.searchable(), &elem(&1, 0))
      reserved = taxonomy ++ [:entries, :media]
      content = Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.section)

      assert reserved -- Enum.uniq(reserved) == []

      for section <- content do
        refute section in reserved,
               "content type section #{inspect(section)} shadows a reserved search section"
      end
    end
  end
end
