defmodule KilnCMSWeb.GraphqlScalarListsTest do
  @moduledoc """
  A `multiple` scalar field over GraphQL (#2289): `fields(names:)` serves a
  `ListValue` of typed items (`IntValue`, `DateValue`), and `customWhere` takes
  the item kind with `eq` / `notEq` / `in` / `isNull` on the list, agreeing
  with `customFilter`.
  """
  # async: false — the documents go through the shared schema and sandbox,
  # as in the other GraphQL custom-field tests.
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
        ... on ListValue {
          items { __typename ... on IntValue { value } ... on DateValue { value } }
        }
      }
    }
  }
  """

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gsl-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp run(query, vars), do: Absinthe.run(query, @schema, variables: vars, context: %{})

  defp ids!(vars) do
    assert {:ok, result} = run(@where, vars)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data["publishedPosts"]["results"] |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp error!(where) do
    assert {:ok, %{errors: [_ | _] = errors}} = run(@where, %{"w" => where})
    Enum.map_join(errors, "; ", & &1.message)
  end

  setup do
    admin = user(:admin)

    for {name, type} <- [{"scores", :integer}, {"dates", :date}] do
      CMS.create_field_definition!(
        %{content_type: :post, name: name, label: name, field_type: type, multiple: true},
        actor: admin
      )
    end

    post = fn fields ->
      %{
        title: "Post #{System.unique_integer([:positive])}",
        slug: "gsl-#{System.unique_integer([:positive])}",
        custom_fields: fields
      }
      |> CMS.create_post!(actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
    end

    one = post.(%{"scores" => [3, 10], "dates" => ["2026-03-01", "2026-04-01"]})
    two = post.(%{"scores" => [7], "dates" => ["2026-05-01"]})
    bare = post.(%{})

    %{one: one, two: two, bare: bare}
  end

  test "fields(names:) serves a list of typed items", %{one: one} do
    assert {:ok, %{data: data} = result} =
             run(@fields, %{"slug" => one.slug, "names" => ["scores", "dates"]})

    refute Map.has_key?(result, :errors)
    by_name = Map.new(data["postBySlug"]["fields"], &{&1["name"], &1})

    assert %{
             "__typename" => "ListValue",
             "items" => [
               %{"__typename" => "IntValue", "value" => 3},
               %{"__typename" => "IntValue", "value" => 10}
             ]
           } = by_name["scores"]

    assert %{
             "__typename" => "ListValue",
             "items" => [
               %{"__typename" => "DateValue", "value" => "2026-03-01"},
               %{"__typename" => "DateValue", "value" => "2026-04-01"}
             ]
           } = by_name["dates"]
  end

  test "customWhere takes the item kind on a list, as customFilter reads it", ctx do
    %{one: one, two: two} = ctx

    assert ids!(%{"w" => [%{"name" => "scores", "int" => %{"eq" => 10}}]}) == [one.id]
    assert ids!(%{"f" => Jason.encode!(%{"scores" => 10})}) == [one.id]

    assert ids!(%{"w" => [%{"name" => "scores", "int" => %{"in" => [7, 3]}}]}) ==
             Enum.sort([one.id, two.id])

    assert ids!(%{"w" => [%{"name" => "scores", "int" => %{"notEq" => 3}}]}) == [two.id]
    assert ids!(%{"w" => [%{"name" => "dates", "date" => %{"eq" => "2026-05-01"}}]}) == [two.id]

    unset = ids!(%{"w" => [%{"name" => "scores", "int" => %{"isNull" => true}}]})
    assert ctx.bare.id in unset
    refute one.id in unset
  end

  test "customWhere refuses comparisons and the wrong kind on a list" do
    assert error!([%{"name" => "scores", "int" => %{"gt" => 3}}]) =~
             "supports only eq, notEq, in and isNull"

    assert error!([%{"name" => "scores", "string" => %{"eq" => "3"}}]) =~
             "is a list of int values, not string; use the int condition"
  end

  test "has and count are customFilter's, not customWhere's", %{one: one} do
    assert ids!(%{"f" => Jason.encode!(%{"scores" => %{"count" => 2}})}) == [one.id]
    assert ids!(%{"f" => Jason.encode!(%{"scores" => %{"has" => [10]}})}) == [one.id]

    # The input type has no `count`: GraphQL validation refuses it.
    assert error!([%{"name" => "scores", "int" => %{"count" => 2}}]) =~ "count"
  end
end
