defmodule KilnCMS.CMS.PluginListQueryTest do
  @moduledoc """
  `custom_filter`, `custom_where` and `custom_sort` on a list of a plugin field
  type (#2680): the list operators of `Preparations.CustomFieldQuery.Lists`,
  operands cast by the type's own `cast/2`; GraphQL's `customWhere` with the
  item kind `graphql_kind/1` gives, refused for a type with none; and the sort
  refused, as on any list. Also what `fields(names:)` serves for each.
  """
  # async: false — the GraphQL documents go through the shared schema and
  # sandbox, as in the other GraphQL custom-field tests.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  @where """
  query ($w: [CustomFieldCondition!], $f: JsonString) {
    publishedPosts(limit: 100, customWhere: $w, customFilter: $f) { results { id } }
  }
  """

  @fields """
  query ($slug: String!, $names: [String!]!) {
    postBySlug(slug: $slug, locale: "en") {
      fields(names: $names) {
        __typename
        name
        ... on ListValue { items { __typename } }
      }
    }
  }
  """

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "plq-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp run(query, vars), do: Absinthe.run(query, @schema, variables: vars, context: %{})

  defp gql_ids!(vars) do
    assert {:ok, result} = run(@where, vars)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data["publishedPosts"]["results"] |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp gql_error!(where) do
    assert {:ok, %{errors: [_ | _] = errors}} = run(@where, %{"w" => where})
    Enum.map_join(errors, "; ", & &1.message)
  end

  defp ids!(filter, admin) do
    %{custom_filter: filter} |> CMS.list_posts!(actor: admin) |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp error!(inputs, admin) do
    assert {:error, %Ash.Error.Invalid{} = error} = CMS.list_posts(inputs, actor: admin)
    Exception.message(error)
  end

  setup do
    admin = admin()
    scores = "scores#{System.unique_integer([:positive])}"
    tags = "tags#{System.unique_integer([:positive])}"

    for {name, type} <- [{scores, :stars}, {tags, :tag}] do
      CMS.create_field_definition!(
        %{content_type: :post, name: name, label: name, field_type: type, multiple: true},
        actor: admin
      )
    end

    post = fn fields ->
      %{
        title: "Post #{System.unique_integer([:positive])}",
        slug: "plq-#{System.unique_integer([:positive])}",
        custom_fields: fields
      }
      |> CMS.create_post!(actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
    end

    one = post.(%{scores => [3, 5, 3], tags => ["Red", "Blue"]})
    two = post.(%{scores => [4], tags => ["green"]})
    bare = post.(%{})

    %{admin: admin, scores: scores, tags: tags, one: one, two: two, bare: bare}
  end

  defp sorted(posts), do: posts |> Enum.map(& &1.id) |> Enum.sort()

  describe "custom_filter" do
    test "membership on a list of stars, operands cast by its cast/2", ctx do
      %{admin: admin, scores: scores, one: one, two: two, bare: bare} = ctx

      assert ids!(%{scores => "3"}, admin) == [one.id]
      assert ids!(%{scores => %{"eq" => 4}}, admin) == [two.id]
      assert ids!(%{scores => %{"in" => ["4", "5"]}}, admin) == sorted([one, two])
      assert ids!(%{scores => %{"has_all" => [3, 5]}}, admin) == [one.id]

      none_3 = ids!(%{scores => %{"has_none" => [3]}}, admin)
      assert two.id in none_3
      assert bare.id in none_3
      refute one.id in none_3

      assert ids!(%{scores => %{"not_eq" => 3}}, admin) == [two.id]
      assert ids!(%{scores => %{"count" => %{"gt" => 2}}}, admin) == [one.id]
    end

    test "an operand is cast as the item was stored: RED finds red", ctx do
      assert ids!(%{ctx.tags => "RED"}, ctx.admin) == [ctx.one.id]
      assert ids!(%{ctx.tags => %{"has" => [" Green "]}}, ctx.admin) == [ctx.two.id]
    end

    test "comparing items is not supported, as on any list", ctx do
      assert error!(%{custom_filter: %{ctx.scores => %{"gt" => 3}}}, ctx.admin) =~
               "gt is not supported on custom field #{inspect(ctx.scores)} (a list)"
    end

    test "a plugin list is not sortable", ctx do
      for name <- [ctx.scores, ctx.tags] do
        assert error!(%{custom_sort: name}, ctx.admin) =~
                 "custom field #{inspect(name)} (a list) is not sortable"
      end
    end
  end

  describe "GraphQL" do
    test "customWhere takes the string kind on a tag list", ctx do
      assert gql_ids!(%{"w" => [%{"name" => ctx.tags, "string" => %{"eq" => "Blue"}}]}) ==
               [ctx.one.id]

      assert gql_ids!(%{"w" => [%{"name" => ctx.tags, "string" => %{"notEq" => "red"}}]}) ==
               [ctx.two.id]
    end

    test "customWhere on a list of a type with no graphql_kind says to use customFilter", ctx do
      assert gql_error!([%{"name" => ctx.scores, "int" => %{"eq" => 3}}]) =~
               "customWhere does not support a list of json values; use customFilter"

      assert gql_ids!(%{"f" => Jason.encode!(%{ctx.scores => 3})}) == [ctx.one.id]
    end

    test "fields(names:) serves a tag list as strings and a stars list as JSON", ctx do
      assert {:ok, %{data: data} = result} =
               run(@fields, %{"slug" => ctx.one.slug, "names" => [ctx.tags, ctx.scores]})

      refute Map.has_key?(result, :errors), inspect(result[:errors])
      by_name = Map.new(data["postBySlug"]["fields"], &{&1["name"], &1})

      assert %{"__typename" => "ListValue", "items" => tag_items} = by_name[ctx.tags]
      assert Enum.map(tag_items, & &1["__typename"]) == ["StringValue", "StringValue"]

      assert %{"__typename" => "ListValue", "items" => star_items} = by_name[ctx.scores]
      assert Enum.uniq(Enum.map(star_items, & &1["__typename"])) == ["JsonValue"]
      assert length(star_items) == 3
    end
  end
end
