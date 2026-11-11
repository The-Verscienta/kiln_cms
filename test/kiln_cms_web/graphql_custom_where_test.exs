defmodule KilnCMSWeb.GraphqlCustomWhereTest do
  @moduledoc """
  `customWhere` (#2290): typed conditions on admin-defined custom fields, on
  every list query that takes `customFilter`. The conditions are translated
  into `customFilter`'s own conditions by `CustomFieldQuery`, so the tests pin
  the operator matrix, the kind check, privacy, limits and, throughout, that the
  two arguments agree.
  """
  # async: false — the documents go through the shared endpoint and sandbox.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  @query """
  query ($w: [CustomFieldCondition!], $f: JsonString) {
    publishedPosts(limit: 100, customWhere: $w, customFilter: $f) { results { id } }
  }
  """

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gcw-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "gcw-#{System.unique_integer([:positive])}"

  defp run(vars, actor \\ nil, query \\ @query),
    do: Absinthe.run(query, @schema, variables: vars, context: %{actor: actor})

  defp ids!(where, actor \\ nil) do
    assert {:ok, result} = run(%{"w" => where}, actor)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data["publishedPosts"]["results"] |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp filter_ids!(filter, actor \\ nil) do
    assert {:ok, result} = run(%{"f" => Jason.encode!(filter)}, actor)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data["publishedPosts"]["results"] |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp error!(where, actor \\ nil) do
    assert {:ok, %{errors: [_ | _] = errors}} = run(%{"w" => where}, actor)
    errors |> Enum.map_join("; ", & &1.message)
  end

  defp sorted(posts), do: posts |> Enum.map(& &1.id) |> Enum.sort()

  setup do
    admin = user(:admin)

    for {name, type, extra} <- [
          {"title_text", :string, %{}},
          {"count", :integer, %{}},
          {"price", :float, %{}},
          {"featured", :boolean, %{}},
          {"on", :date, %{}},
          {"at", :datetime, %{}},
          {"tagged", :string, %{multiple: true}},
          {"secret", :string, %{private: true}}
        ] do
      CMS.create_field_definition!(
        Map.merge(%{content_type: :post, label: name, name: name, field_type: type}, extra),
        actor: admin
      )
    end

    post = fn fields ->
      %{title: "Post #{System.unique_integer([:positive])}", slug: slug(), custom_fields: fields}
      |> CMS.create_post!(actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
    end

    apple =
      post.(%{
        "title_text" => "Red Apple",
        "count" => 1,
        "price" => 5.5,
        "featured" => true,
        "on" => "2026-01-01",
        "at" => "2026-01-01T10:00:00Z",
        "tagged" => ["a", "b"],
        "secret" => "classified"
      })

    pear =
      post.(%{
        "title_text" => "green_pear 100%",
        "count" => 5,
        "price" => 10,
        "featured" => false,
        "on" => "2026-06-01",
        "at" => "2026-06-01T10:00:00Z",
        "tagged" => ["c"]
      })

    plum =
      post.(%{
        "title_text" => "Blue Plum",
        "count" => 10,
        "price" => 20.25,
        "on" => "2026-12-01",
        "at" => "2026-12-01T10:00:00Z"
      })

    bare = post.(%{})

    %{admin: admin, apple: apple, pear: pear, plum: plum, bare: bare}
  end

  describe "the operator matrix" do
    test "string", %{apple: a, pear: p, plum: l} do
      t = fn op -> [%{"name" => "title_text", "string" => op}] end

      assert ids!(t.(%{"eq" => "Red Apple"})) == sorted([a])
      assert ids!(t.(%{"notEq" => "Red Apple"})) == sorted([p, l])
      assert ids!(t.(%{"in" => ["Red Apple", "Blue Plum"]})) == sorted([a, l])
      assert ids!(t.(%{"contains" => "PLUM"})) == sorted([l])
      assert ids!(t.(%{"startsWith" => "red"})) == sorted([a])
      assert ids!(t.(%{"startsWith" => "apple"})) == []
      assert ids!(t.(%{"isNull" => false})) == sorted([a, p, l])
    end

    test "int", %{apple: a, pear: p, plum: l} do
      t = fn op -> [%{"name" => "count", "int" => op}] end

      assert ids!(t.(%{"eq" => 5})) == sorted([p])
      assert ids!(t.(%{"notEq" => 5})) == sorted([a, l])
      assert ids!(t.(%{"in" => [1, 10]})) == sorted([a, l])
      assert ids!(t.(%{"gt" => 5})) == sorted([l])
      assert ids!(t.(%{"gte" => 5})) == sorted([p, l])
      assert ids!(t.(%{"lt" => 5})) == sorted([a])
      assert ids!(t.(%{"lte" => 5})) == sorted([a, p])
      assert ids!(t.(%{"gte" => 2, "lt" => 10})) == sorted([p])
    end

    test "float compares numerically, not as text", %{apple: a, pear: p, plum: l} do
      t = fn op -> [%{"name" => "price", "float" => op}] end

      assert ids!(t.(%{"gt" => 9.5})) == sorted([p, l])
      assert ids!(t.(%{"eq" => 10.0})) == sorted([p])
      assert ids!(t.(%{"notEq" => 10})) == sorted([a, l])
      assert ids!(t.(%{"in" => [5.5, 20.25]})) == sorted([a, l])
      assert ids!(t.(%{"lte" => 5.5})) == sorted([a])
      assert ids!(t.(%{"lt" => 20.25, "gte" => 5.5})) == sorted([a, p])
    end

    test "boolean", %{apple: a, pear: p, bare: b} do
      t = fn op -> [%{"name" => "featured", "boolean" => op}] end

      assert ids!(t.(%{"eq" => true})) == sorted([a])
      assert ids!(t.(%{"eq" => false})) == sorted([p])
      assert b.id in ids!(t.(%{"isNull" => true}))
      assert ids!(t.(%{"isNull" => false})) == sorted([a, p])
    end

    test "date", %{apple: a, pear: p, plum: l} do
      t = fn op -> [%{"name" => "on", "date" => op}] end

      assert ids!(t.(%{"eq" => "2026-06-01"})) == sorted([p])
      assert ids!(t.(%{"notEq" => "2026-06-01"})) == sorted([a, l])
      assert ids!(t.(%{"in" => ["2026-01-01", "2026-12-01"]})) == sorted([a, l])
      assert ids!(t.(%{"gt" => "2026-01-01"})) == sorted([p, l])
      assert ids!(t.(%{"gte" => "2026-06-01", "lte" => "2026-06-30"})) == sorted([p])
      assert ids!(t.(%{"lt" => "2026-06-01"})) == sorted([a])
    end

    test "dateTime", %{apple: a, pear: p, plum: l} do
      t = fn op -> [%{"name" => "at", "dateTime" => op}] end

      assert ids!(t.(%{"eq" => "2026-06-01T10:00:00Z"})) == sorted([p])
      assert ids!(t.(%{"gt" => "2026-06-01T10:00:00Z"})) == sorted([l])
      assert ids!(t.(%{"lte" => "2026-06-01T10:00:00Z"})) == sorted([a, p])
      # An offset is an instant: 12:00+02:00 is 10:00Z.
      assert ids!(t.(%{"eq" => "2026-06-01T12:00:00+02:00"})) == sorted([p])

      assert ids!(t.(%{"in" => ["2026-01-01T10:00:00Z", "2026-12-01T10:00:00Z"]})) ==
               sorted([a, l])
    end

    test "conditions are ANDed, also on one field", %{pear: p, plum: l} do
      assert ids!([
               %{"name" => "count", "int" => %{"gt" => 1}},
               %{"name" => "price", "float" => %{"gt" => 15}}
             ]) == sorted([l])

      assert ids!([
               %{"name" => "count", "int" => %{"gt" => 1}},
               %{"name" => "count", "int" => %{"lt" => 10}}
             ]) == sorted([p])
    end

    test "a multiple string keeps eq and in as list contains", %{apple: a, pear: p} do
      t = fn op -> [%{"name" => "tagged", "string" => op}] end

      assert ids!(t.(%{"eq" => "a"})) == sorted([a])
      assert ids!(t.(%{"in" => ["b", "c"]})) == sorted([a, p])
    end

    test "an empty or missing customWhere changes nothing", %{apple: a, pear: p, plum: l, bare: b} do
      assert ids!([]) == sorted([a, p, l, b])
      assert {:ok, %{data: %{"publishedPosts" => _}}} = run(%{})
    end
  end

  describe "escaping" do
    test "contains and startsWith take %, _ and \\ literally", %{pear: p} do
      t = fn key, text -> [%{"name" => "title_text", "string" => %{key => text}}] end

      assert ids!(t.("contains", "100%")) == sorted([p])
      assert ids!(t.("contains", "n_p")) == sorted([p])
      # An unescaped `_` or `%` would match these.
      assert ids!(t.("contains", "g_e")) == []
      assert ids!(t.("contains", "%")) == sorted([p])
      assert ids!(t.("startsWith", "%")) == []
      assert ids!(t.("startsWith", "green_")) == sorted([p])
      assert ids!(t.("startsWith", "gre_n")) == []
      assert ids!(t.("contains", "\\")) == []
    end

    test "customFilter takes the same operators (additive)", %{apple: a, pear: p} do
      assert filter_ids!(%{"title_text" => %{"contains" => "APPLE"}}) == sorted([a])
      assert filter_ids!(%{"title_text" => %{"starts_with" => "green_"}}) == sorted([p])
      assert filter_ids!(%{"title_text" => %{"contains" => "n_p"}}) == sorted([p])
      assert filter_ids!(%{"title_text" => %{"contains" => "n__p"}}) == []
    end

    test "the new operators are refused on a non-text field through customFilter" do
      assert {:ok, %{errors: [%{message: message}]}} =
               run(%{"f" => Jason.encode!(%{"count" => %{"contains" => "1"}})})

      assert message =~ "text-like"
    end

    test "the new operators are refused on a multiple field through customFilter" do
      assert {:ok, %{errors: [%{message: message}]}} =
               run(%{"f" => Jason.encode!(%{"tagged" => %{"contains" => "["}})})

      assert message =~ "contains is not supported on custom field \"tagged\" (a list)"
    end
  end

  describe "customFilter regression" do
    test "customFilter still works alone, with ilike and bare equality", %{apple: a, plum: l} do
      assert filter_ids!(%{"count" => %{"gt" => 5}}) == sorted([l])
      assert filter_ids!(%{"title_text" => "Red Apple"}) == sorted([a])
      assert filter_ids!(%{"title_text" => %{"ilike" => "%apple"}}) == sorted([a])
    end

    test "customWhere and customFilter together are ANDed", %{pear: p, plum: l} do
      assert {:ok, %{data: data}} =
               run(%{
                 "w" => [%{"name" => "count", "int" => %{"gte" => 5}}],
                 "f" => Jason.encode!(%{"price" => %{"gt" => 15}})
               })

      assert Enum.map(data["publishedPosts"]["results"], & &1["id"]) == [l.id]
      refute p.id == l.id
    end

    test "customWhere returns the rows customFilter does", %{apple: a} do
      pairs = [
        {[%{"name" => "price", "float" => %{"gt" => 5, "lt" => 15}}],
         %{"price" => %{"gt" => 5, "lt" => 15}}},
        {[%{"name" => "title_text", "string" => %{"in" => ["Red Apple", "x"]}}],
         %{"title_text" => %{"in" => ["Red Apple", "x"]}}},
        {[%{"name" => "featured", "boolean" => %{"eq" => true}}], %{"featured" => true}},
        {[%{"name" => "on", "date" => %{"gte" => "2026-02-01"}}],
         %{"on" => %{"gte" => "2026-02-01"}}},
        {[%{"name" => "count", "int" => %{"isNull" => true}}], %{"count" => %{"null" => true}}}
      ]

      for {where, filter} <- pairs do
        assert ids!(where) == filter_ids!(filter), inspect(where)
      end

      assert a.id in ids!([%{"name" => "featured", "boolean" => %{"eq" => true}}])
    end
  end

  describe "the kind check" do
    test "a wrong kind names the field's actual kind" do
      message = error!([%{"name" => "title_text", "float" => %{"gt" => 1}}])
      assert message =~ ~s("title_text")
      assert message =~ "string field"
      assert message =~ "not float"

      assert error!([%{"name" => "count", "string" => %{"eq" => "1"}}]) =~ "int field"
      assert error!([%{"name" => "price", "int" => %{"eq" => 1}}]) =~ "float field"
      assert error!([%{"name" => "at", "date" => %{"eq" => "2026-01-01"}}]) =~ "dateTime field"
    end

    test "exactly one kind key, and at least one operator" do
      assert error!([%{"name" => "count"}]) =~ "exactly one of"
      assert error!([%{"name" => "count"}]) =~ "got none"

      both = [%{"name" => "count", "int" => %{"eq" => 1}, "float" => %{"eq" => 1}}]
      assert error!(both) =~ "got int, float"

      assert error!([%{"name" => "count", "int" => %{}}]) =~ "at least one operator"
    end

    test "a list of strings takes string eq, notEq, in and isNull" do
      assert error!([%{"name" => "tagged", "string" => %{"contains" => "a"}}]) =~
               "supports only eq, notEq, in and isNull"

      assert error!([%{"name" => "tagged", "int" => %{"eq" => 1}}]) =~
               "is a list of string values, not int"
    end

    test "a field customWhere does not type is pointed at customFilter", %{admin: admin} do
      CMS.create_field_definition!(
        %{content_type: :post, name: "where", label: "Where", field_type: :geolocation},
        actor: admin
      )

      assert error!([%{"name" => "where", "string" => %{"eq" => "x"}}]) =~ "customFilter"
    end

    test "a built-in relationship name is not a custom field" do
      assert error!([%{"name" => "tags", "string" => %{"eq" => "x"}}]) =~ "unknown custom field"
    end

    test "an unknown field is refused" do
      assert error!([%{"name" => "nope", "string" => %{"eq" => "x"}}]) =~
               ~s(unknown custom field "nope")
    end

    test "an operand of the wrong type is refused by GraphQL, not the database" do
      assert {:ok, %{errors: [_ | _]}} =
               run(%{"w" => [%{"name" => "price", "float" => %{"gt" => "abc"}}]})

      assert {:ok, %{errors: [_ | _]}} =
               run(%{"w" => [%{"name" => "on", "date" => %{"gt" => "not a date"}}]})
    end
  end

  describe "private fields" do
    @secret [%{"name" => "secret", "string" => %{"eq" => "classified"}}]

    test "unknown below editor, the same error as a missing field", %{apple: a} do
      missing = error!([%{"name" => "nope", "string" => %{"eq" => "classified"}}])
      assert missing =~ "unknown custom field"

      for actor <- [nil, user(:viewer)] do
        assert error!(@secret, actor) == String.replace(missing, "nope", "secret")
      end

      assert ids!(@secret, user(:editor)) == sorted([a])
      assert ids!(@secret, user(:admin)) == sorted([a])
    end

    test "customWhere and customFilter agree for every actor", %{apple: a} do
      for actor <- [nil, user(:viewer), user(:editor)] do
        where = run(%{"w" => @secret}, actor)
        filter = run(%{"f" => Jason.encode!(%{"secret" => "classified"})}, actor)

        case {where, filter} do
          {{:ok, %{errors: [w]}}, {:ok, %{errors: [f]}}} ->
            assert w.message == f.message

          {{:ok, %{data: w}}, {:ok, %{data: f}}} ->
            assert w == f
            assert Enum.map(w["publishedPosts"]["results"], & &1["id"]) == [a.id]
        end
      end
    end
  end

  describe "Entry scoping" do
    test "a dynamic type's field is typed per type", %{admin: admin} do
      mk = fn n ->
        type =
          CMS.create_type_definition!(
            %{name: "gcw_type_#{n}_#{System.unique_integer([:positive])}", label: "T#{n}"},
            actor: admin
          )

        CMS.create_field_definition!(
          %{type_definition_id: type.id, name: "rank", label: "Rank", field_type: :integer},
          actor: admin
        )

        entry =
          %{
            title: "E#{n}",
            slug: slug(),
            type_definition_id: type.id,
            custom_fields: %{"rank" => n}
          }
          |> CMS.create_entry!(actor: admin)
          |> CMS.publish_entry!(%{}, actor: admin)

        {type, entry}
      end

      {type1, e1} = mk.(1)
      {_type2, e2} = mk.(2)

      query = """
      query ($t: String, $w: [CustomFieldCondition!]) {
        publishedEntries(limit: 100, filter: {typeName: {eq: $t}}, customWhere: $w) { results { id } }
      }
      """

      where = [%{"name" => "rank", "int" => %{"gte" => 1}}]
      assert {:ok, %{data: data} = result} = run(%{"t" => type1.name, "w" => where}, nil, query)
      refute result[:errors]
      assert Enum.map(data["publishedEntries"]["results"], & &1["id"]) == [e1.id]
      refute e1.id == e2.id

      bad = [%{"name" => "rank", "string" => %{"eq" => "1"}}]

      assert {:ok, %{errors: [%{message: message}]}} =
               run(%{"t" => type1.name, "w" => bad}, nil, query)

      assert message =~ "int field"
    end
  end

  describe "limits" do
    test "more than the maximum conditions is refused" do
      max = KilnCMSWeb.GraphqlLimits.max_custom_conditions()
      one = %{"name" => "count", "int" => %{"gte" => 0}}

      assert is_list(ids!(List.duplicate(one, max)))
      assert error!(List.duplicate(one, max + 1)) =~ "at most #{max} conditions"
    end

    test "an in list over the maximum is refused" do
      max = KilnCMSWeb.GraphqlLimits.max_custom_in_values()

      assert is_list(ids!([%{"name" => "count", "int" => %{"in" => Enum.to_list(1..max)}}]))

      assert error!([%{"name" => "count", "int" => %{"in" => Enum.to_list(1..(max + 1))}}]) =~
               "at most #{max} values"
    end

    test "each condition adds to the query's price" do
      none = KilnCMSWeb.GraphqlLimits.custom_where_complexity(%{}, 3, nil)

      three =
        KilnCMSWeb.GraphqlLimits.custom_where_complexity(%{custom_where: [%{}, %{}, %{}]}, 3, nil)

      assert three > none
      assert three - none == 3 * 5
    end

    test "a document of maximum conditions stays under the complexity cap" do
      max = KilnCMSWeb.GraphqlLimits.max_custom_conditions()

      cost =
        KilnCMSWeb.GraphqlLimits.custom_where_complexity(
          %{limit: 10, custom_where: List.duplicate(%{}, max)},
          1,
          nil
        )

      assert cost <= KilnCMSWeb.GraphqlLimits.max_complexity()
    end
  end

  describe "the schema" do
    test "every query that takes customFilter takes customWhere" do
      {:ok, %{data: data}} =
        Absinthe.run(
          "{ __schema { queryType { fields { name args { name } } } } }",
          @schema
        )

      with_filter =
        for %{"name" => name, "args" => args} <- data["__schema"]["queryType"]["fields"],
            Enum.any?(args, &(&1["name"] == "customFilter")),
            do: {name, Enum.any?(args, &(&1["name"] == "customWhere"))}

      assert with_filter != []
      assert Enum.all?(with_filter, &elem(&1, 1)), inspect(with_filter)
    end
  end
end
