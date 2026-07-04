defmodule KilnCMS.CMS.CustomFieldQueryTest do
  @moduledoc """
  Filtering and sorting by admin-defined custom fields
  (`Preparations.CustomFieldQuery`): the `custom_filter`/`custom_sort` read
  arguments over the `custom_fields` JSONB map, typed per the FieldDefinition
  registry.

  Field names are unique per test, so predicates on them only ever match
  records seeded here (shared-sandbox safety) — except `null: true`, which
  matches records *lacking* the key and is asserted via membership only.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfq-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, label: "Field"}, attrs),
      actor: actor
    )
  end

  defp field_name(base), do: "#{base}#{System.unique_integer([:positive])}"

  defp slug, do: "cfq-#{System.unique_integer([:positive])}"

  defp page!(fields, actor) do
    CMS.create_page!(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)
  end

  defp list_ids!(inputs, actor) do
    inputs |> CMS.list_pages!(actor: actor) |> Enum.map(& &1.id)
  end

  defp assert_invalid(inputs, actor, expected_message) do
    assert {:error, %Ash.Error.Invalid{} = error} = CMS.list_pages(inputs, actor: actor)
    assert Exception.message(error) =~ expected_message
  end

  describe "custom_filter on compiled types" do
    test "integer comparisons are numeric, not lexical" do
      admin = admin()
      price = field_name("price")
      define!(%{name: price, field_type: :integer}, admin)

      # Lexically "9" > "10"; numerically it isn't — the cast is the test.
      _nine = page!(%{price => 9}, admin)
      _ten = page!(%{price => 10}, admin)
      thirty = page!(%{price => 30}, admin)

      assert list_ids!(%{custom_filter: %{price => %{"gt" => "10"}}}, admin) == [thirty.id]
    end

    test "a bare value means equality; in matches any of a list" do
      admin = admin()
      color = field_name("color")
      define!(%{name: color, field_type: :string}, admin)

      red = page!(%{color => "red"}, admin)
      blue = page!(%{color => "blue"}, admin)
      _green = page!(%{color => "green"}, admin)

      assert list_ids!(%{custom_filter: %{color => "red"}}, admin) == [red.id]

      assert %{custom_filter: %{color => %{"in" => ["red", "blue"]}}}
             |> list_ids!(admin)
             |> Enum.sort() == Enum.sort([red.id, blue.id])
    end

    test "ilike matches text fields case-insensitively" do
      admin = admin()
      subtitle = field_name("subtitle")
      define!(%{name: subtitle, field_type: :string}, admin)

      match = page!(%{subtitle => "Sweet Herb Guide"}, admin)
      _other = page!(%{subtitle => "Bitter Root"}, admin)

      assert list_ids!(%{custom_filter: %{subtitle => %{"ilike" => "%herb%"}}}, admin) ==
               [match.id]
    end

    test "boolean and date values cast to their declared types" do
      admin = admin()
      organic = field_name("organic")
      harvested = field_name("harvested")
      define!(%{name: organic, field_type: :boolean}, admin)
      define!(%{name: harvested, field_type: :date}, admin)

      yes = page!(%{organic => true, harvested => "2026-05-01"}, admin)
      _no = page!(%{organic => false, harvested => "2026-03-01"}, admin)

      assert list_ids!(%{custom_filter: %{organic => "true"}}, admin) == [yes.id]

      assert list_ids!(%{custom_filter: %{harvested => %{"gte" => "2026-04-01"}}}, admin) ==
               [yes.id]
    end

    test "null tests key presence" do
      admin = admin()
      rare = field_name("rare")
      define!(%{name: rare, field_type: :string}, admin)

      set = page!(%{rare => "yes"}, admin)
      unset = page!(%{}, admin)

      with_value = list_ids!(%{custom_filter: %{rare => %{"null" => "false"}}}, admin)
      assert with_value == [set.id]

      # Every record without the key matches null: true, including ones from
      # concurrent tests — membership only.
      without_value = list_ids!(%{custom_filter: %{rare => %{"null" => "true"}}}, admin)
      assert unset.id in without_value
      refute set.id in without_value
    end

    test "media/reference fields match on the snapshot id, equality-shaped only" do
      admin = admin()
      related = field_name("related")
      define!(%{name: related, field_type: :reference, target_type: "page"}, admin)

      target = page!(%{}, admin)
      linked = page!(%{related => target.id}, admin)
      _unlinked = page!(%{}, admin)

      assert list_ids!(%{custom_filter: %{related => target.id}}, admin) == [linked.id]

      assert_invalid(
        %{custom_filter: %{related => %{"gt" => target.id}}},
        admin,
        "only supports eq/not_eq/in/null"
      )
    end
  end

  describe "custom_sort on compiled types" do
    test "sorts numerically by a typed field, ascending and descending" do
      admin = admin()
      price = field_name("price")
      define!(%{name: price, field_type: :integer}, admin)

      nine = page!(%{price => 9}, admin)
      ten = page!(%{price => 10}, admin)
      thirty = page!(%{price => 30}, admin)

      # The null: false predicate scopes the list to this test's rows.
      scope = %{custom_filter: %{price => %{"null" => "false"}}}

      assert list_ids!(Map.put(scope, :custom_sort, price), admin) ==
               [nine.id, ten.id, thirty.id]

      assert list_ids!(Map.put(scope, :custom_sort, "-#{price}"), admin) ==
               [thirty.id, ten.id, nine.id]
    end

    test "media/reference fields are not sortable" do
      admin = admin()
      related = field_name("related")
      define!(%{name: related, field_type: :reference, target_type: "page"}, admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.list_pages(%{custom_sort: related}, actor: admin)

      assert Exception.message(error) =~ "is not sortable"
    end
  end

  describe "validation errors" do
    test "rejects unknown field names, unknown operators and uncastable values" do
      admin = admin()
      price = field_name("price")
      define!(%{name: price, field_type: :integer}, admin)

      assert_invalid(
        %{custom_filter: %{field_name("ghost") => "x"}},
        admin,
        "unknown custom field"
      )

      assert_invalid(
        %{custom_filter: %{price => %{"between" => "1"}}},
        admin,
        "unknown operator"
      )

      assert_invalid(
        %{custom_filter: %{price => %{"gt" => "not-a-number"}}},
        admin,
        "invalid integer value"
      )

      assert_invalid(
        %{custom_filter: %{price => %{"ilike" => "%x%"}}},
        admin,
        "only supported on text-like custom fields"
      )
    end
  end

  describe "the entry tier (dynamic types)" do
    defp define_type!(actor) do
      CMS.create_type_definition!(
        %{name: "cfqdyn#{System.unique_integer([:positive])}", label: "Dyn"},
        actor: actor
      )
    end

    defp entry_field!(type, attrs, actor) do
      CMS.create_field_definition!(
        Map.merge(%{type_definition_id: type.id, label: "Field"}, attrs),
        actor: actor
      )
    end

    defp entry!(type, fields, actor) do
      KilnCMS.CMS.ContentTypes.create!(
        type.name,
        %{title: "E", slug: slug(), custom_fields: fields},
        actor: actor
      )
    end

    test "resolves definitions through the query's type scope" do
      admin = admin()
      rating = field_name("rating")

      recipes = define_type!(admin)
      guides = define_type!(admin)
      entry_field!(recipes, %{name: rating, field_type: :integer}, admin)
      entry_field!(guides, %{name: rating, field_type: :string}, admin)

      _low = entry!(recipes, %{rating => 2}, admin)
      high = entry!(recipes, %{rating => 5}, admin)
      _guide = entry!(guides, %{rating => "excellent"}, admin)

      by_name =
        CMS.list_entries!(
          %{custom_filter: %{rating => %{"gt" => "3"}}},
          query: [filter: [type_name: recipes.name]],
          actor: admin
        )

      assert Enum.map(by_name, & &1.id) == [high.id]

      by_id =
        CMS.list_entries!(
          %{custom_filter: %{rating => %{"gt" => "3"}}},
          query: [filter: [type_definition_id: recipes.id]],
          actor: admin
        )

      assert Enum.map(by_id, & &1.id) == [high.id]
    end

    test "unscoped queries work when owners agree on the type, else reject" do
      admin = admin()
      featured = field_name("featured")
      rating = field_name("rating")

      recipes = define_type!(admin)
      guides = define_type!(admin)
      entry_field!(recipes, %{name: featured, field_type: :boolean}, admin)
      entry_field!(guides, %{name: featured, field_type: :boolean}, admin)
      entry_field!(recipes, %{name: rating, field_type: :integer}, admin)
      entry_field!(guides, %{name: rating, field_type: :string}, admin)

      starred_recipe = entry!(recipes, %{featured => true, rating => 4}, admin)
      starred_guide = entry!(guides, %{featured => true, rating => "good"}, admin)
      _plain = entry!(recipes, %{featured => false, rating => 1}, admin)

      # Same type under every owner: the unscoped filter spans dynamic types.
      featured_ids =
        CMS.list_entries!(%{custom_filter: %{featured => "true"}}, actor: admin)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert featured_ids == Enum.sort([starred_recipe.id, starred_guide.id])

      # Divergent types: refuse to guess which cast applies.
      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.list_entries(%{custom_filter: %{rating => %{"gt" => "3"}}}, actor: admin)

      assert Exception.message(error) =~ "different type per content type"
    end
  end
end
