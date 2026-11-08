defmodule KilnCMS.CMS.ListFieldQueryTest do
  @moduledoc """
  The content list's field-condition facade (#2293): the argument names it
  speaks exist on every read action the list calls, `ContentTypes.list!/2` and
  `count!/2` carry them (and agree), and the values it spells are safe.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ListFieldQuery

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lfq-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  describe "the argument names" do
    test "every content type's read action carries custom_filter and custom_sort" do
      resources = [CMS.Entry | Enum.map(ContentTypes.all(), & &1.resource)]
      assert length(resources) > 1

      for resource <- resources do
        action = Ash.Resource.Info.action(resource, :read)
        names = Enum.map(action.arguments, & &1.name)

        for name <-
              Map.keys(
                ListFieldQuery.arguments([%{field: "f", op: "eq", value: "1"}], {"f", :asc}, [])
              ) do
          assert name in names, "#{inspect(resource)} :read has no #{name} argument"
        end
      end
    end
  end

  describe "arguments/3" do
    test "nothing in, nothing out" do
      assert ListFieldQuery.arguments([], nil, []) == %{}
    end

    test "ranges on one field merge; a sort names the field, - for descending" do
      conditions = [
        %{field: "price", op: "gte", value: "10"},
        %{field: "price", op: "lte", value: "20"}
      ]

      assert ListFieldQuery.arguments(conditions, {"price", :desc}, [
               %{name: "price", field_type: :integer}
             ]) ==
               %{
                 custom_filter: %{"price" => %{"gte" => "10", "lte" => "20"}},
                 custom_sort: "-price"
               }

      assert %{custom_sort: "price"} = ListFieldQuery.arguments([], {"price", :asc}, [])
    end

    test "contains escapes LIKE metacharacters" do
      args =
        ListFieldQuery.arguments(
          [%{field: "note", op: "contains", value: "50%_a\\b"}],
          nil,
          [%{name: "note", field_type: :string}]
        )

      assert args.custom_filter == %{"note" => %{"ilike" => "%50\\%\\_a\\\\b%"}}
    end

    test "a datetime asks by whole days, the last day inclusive" do
      args =
        ListFieldQuery.arguments(
          [
            %{field: "at", op: "gte", value: "2026-03-01"},
            %{field: "at", op: "lte", value: "2026-03-31"}
          ],
          nil,
          [%{name: "at", field_type: :datetime}]
        )

      assert args.custom_filter == %{
               "at" => %{"gte" => "2026-03-01T00:00:00", "lt" => "2026-04-01T00:00:00"}
             }
    end
  end

  describe "cast/3" do
    test "ops are per field type" do
      assert {:ok, "10"} = ListFieldQuery.cast(%{field_type: :integer}, "gte", " 10 ")
      assert :error = ListFieldQuery.cast(%{field_type: :integer}, "contains", "10")
      assert :error = ListFieldQuery.cast(%{field_type: :boolean}, "gt", "true")
      assert :error = ListFieldQuery.cast(%{field_type: :string}, "bogus", "x")
    end

    test "values are cast to the type, or refused" do
      assert :error = ListFieldQuery.cast(%{field_type: :integer}, "eq", "1.5")
      assert :error = ListFieldQuery.cast(%{field_type: :integer}, "eq", "abc")
      assert {:ok, "1.5"} = ListFieldQuery.cast(%{field_type: :float}, "eq", "1.5")
      assert :error = ListFieldQuery.cast(%{field_type: :date}, "eq", "2026-13-40")

      assert {:ok, "2026-03-01"} =
               ListFieldQuery.cast(%{field_type: :datetime}, "gte", "2026-03-01")

      assert :error = ListFieldQuery.cast(%{field_type: :reference}, "eq", "not-a-uuid")
      assert :error = ListFieldQuery.cast(%{field_type: :string}, "eq", "")

      assert :error =
               ListFieldQuery.cast(%{field_type: :string}, "eq", String.duplicate("x", 101))

      assert {:ok, "true"} = ListFieldQuery.cast(%{field_type: :string}, "null", "true")
      assert :error = ListFieldQuery.cast(%{field_type: :string}, "null", "maybe")
    end

    test "a select takes its options only, unless it allows custom terms" do
      select = %{field_type: :select, options: ["red", "blue"], allow_custom: false}
      assert {:ok, "red"} = ListFieldQuery.cast(select, "eq", "red")
      assert :error = ListFieldQuery.cast(select, "eq", "green")
      assert {:ok, "green"} = ListFieldQuery.cast(%{select | allow_custom: true}, "eq", "green")
    end
  end

  describe "the format field types (#2278)" do
    test "their ops, and which can be sorted" do
      assert ListFieldQuery.ops(:email) == ~w(eq contains null)
      assert ListFieldQuery.ops(:color) == ~w(eq null)
      assert ListFieldQuery.ops(:time) == ~w(eq gte lte null)
      assert ListFieldQuery.ops(:json) == []

      for type <- [:range, :key_value, :link] do
        assert ListFieldQuery.ops(type) == []
        refute ListFieldQuery.sortable?(%{field_type: type})
        assert :error = ListFieldQuery.cast(%{field_type: type}, "eq", "x")
      end

      for type <- [:email, :telephone, :color, :slug, :time],
          do: assert(ListFieldQuery.sortable?(%{field_type: type}))

      refute ListFieldQuery.sortable?(%{field_type: :json})
    end

    test "a value is cast to the type's stored spelling" do
      assert {:ok, "Ann@example.com"} =
               ListFieldQuery.cast(%{field_type: :email}, "eq", "Ann@EXAMPLE.com")

      assert {:ok, "#aabbcc"} = ListFieldQuery.cast(%{field_type: :color}, "eq", "#ABC")
      assert {:ok, "09:05"} = ListFieldQuery.cast(%{field_type: :time}, "gte", "9:05")

      assert {:ok, "+442079460958"} =
               ListFieldQuery.cast(%{field_type: :telephone}, "eq", "+44 20 7946 0958")

      assert :error = ListFieldQuery.cast(%{field_type: :color}, "eq", "red")
      assert :error = ListFieldQuery.cast(%{field_type: :color}, "contains", "ff")
      assert :error = ListFieldQuery.cast(%{field_type: :json}, "eq", "x")
    end

    test "contains takes the typed fragment as it is" do
      assert {:ok, "example"} = ListFieldQuery.cast(%{field_type: :email}, "contains", "example")
    end

    test "the list filters by an email column" do
      admin = user(:admin)
      name = "mail#{uniq()}"

      CMS.create_field_definition!(
        %{content_type: :page, label: "Mail", name: name, field_type: :email},
        actor: admin
      )

      keep =
        CMS.create_page!(
          %{title: "K", slug: "lfq-#{uniq()}", custom_fields: %{name => "keep@example.com"}},
          actor: admin
        )

      _other =
        CMS.create_page!(
          %{title: "O", slug: "lfq-#{uniq()}", custom_fields: %{name => "other@elsewhere.org"}},
          actor: admin
        )

      args =
        ListFieldQuery.arguments(
          [%{field: name, op: "contains", value: "example"}],
          nil,
          [%{name: name, field_type: :email}]
        )

      assert [%{id: id}] = CMS.list_pages!(args, actor: admin)
      assert id == keep.id
    end
  end

  describe "ContentTypes.list!/2 and count! with arguments" do
    setup do
      %{admin: user(:admin)}
    end

    test "a compiled type: list and count agree, LIKE metacharacters are literal", %{admin: admin} do
      name = "note#{uniq()}"

      CMS.create_field_definition!(
        %{content_type: :page, label: "Note", name: name, field_type: :string},
        actor: admin
      )

      title = "lfq #{uniq()}"

      mk = fn value ->
        CMS.create_page!(%{title: title, slug: "lfq-#{uniq()}", custom_fields: %{name => value}},
          actor: admin
        )
      end

      pct = mk.("save 50% today")
      under = mk.("a_b")
      _plain = mk.("save 500 today")
      _other = mk.("axb")

      opts = [actor: admin, query: [filter: [title: title]]]

      for {needle, expected} <- [{"50%", pct}, {"a_b", under}] do
        arguments =
          ListFieldQuery.arguments(
            [%{field: name, op: "contains", value: needle}],
            nil,
            [%{name: name, field_type: :string}]
          )

        assert [row] = ContentTypes.list!(:page, [{:arguments, arguments} | opts])
        assert row.id == expected.id
        assert ContentTypes.count!(:page, [{:arguments, arguments} | opts]) == 1
      end

      # A limit bounds the count, with or without the field condition: the
      # "N+" the list shows reads through this (Ash wraps the limit in a subquery).
      assert ContentTypes.count!(:page, [
               {:query, [filter: [title: title], limit: 3]},
               actor: admin
             ]) == 3

      assert ContentTypes.count!(:page,
               actor: admin,
               arguments: %{custom_filter: %{name => %{"null" => "false"}}},
               query: [filter: [title: title], limit: 3]
             ) == 3

      # Without arguments the call is the one it always was.
      assert length(ContentTypes.list!(:page, opts)) == 4
      assert ContentTypes.count!(:page, opts) == 4
    end

    test "a dynamic type with a private field: list and count agree, and the field is the editor's",
         %{admin: admin} do
      type = CMS.create_type_definition!(%{name: "lfqtype#{uniq()}", label: "Lfq"}, actor: admin)

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          label: "Secret",
          name: "secret",
          field_type: :integer,
          private: true
        },
        actor: admin
      )

      for n <- [1, 2, 3] do
        CMS.create_entry!(
          %{
            title: "E#{n}",
            slug: "lfq-#{uniq()}",
            type_definition_id: type.id,
            custom_fields: %{"secret" => n}
          },
          actor: admin
        )
      end

      defs = [%{name: "secret", field_type: :integer}]

      arguments =
        ListFieldQuery.arguments(
          [%{field: "secret", op: "gte", value: "2"}],
          {"secret", :desc},
          defs
        )

      opts = [actor: admin, arguments: arguments]
      rows = ContentTypes.list!(type.name, opts)
      assert Enum.map(rows, & &1.custom_fields["secret"]) == [3, 2]
      assert ContentTypes.count!(type.name, opts) == 2

      # A viewer is not an editor: the field is unknown to them, the read refuses.
      viewer = user(:viewer)

      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.list!(type.name, actor: viewer, arguments: arguments)
      end

      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.count!(type.name, actor: viewer, arguments: arguments)
      end
    end
  end
end
