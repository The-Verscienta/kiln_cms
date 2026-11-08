defmodule KilnCMS.CMS.ListFieldsTest do
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.ListFields

  @org "6f1c0e5e-0000-4000-8000-000000000001"

  defp def_(name, type, attrs \\ %{}),
    do: Map.merge(%{name: name, field_type: type, private: false}, attrs)

  defp actor(role), do: %{id: Ecto.UUID.generate(), role: role, memberships: []}

  setup do
    defs = [
      def_("price", :integer),
      def_("cost", :float, %{private: true}),
      def_("shape", :group),
      def_("where", :geolocation),
      def_("tags", :select, %{multiple: true}),
      def_("owner", :user, %{private: true})
    ]

    %{defs: defs}
  end

  test "an admin keeps private fields only when asked", %{defs: defs} do
    admin = actor(:admin)

    assert ["price", "cost", "owner"] ==
             admin |> ListFields.readable_fields(@org, defs, true) |> Enum.map(& &1.name)

    assert ["price"] ==
             admin |> ListFields.readable_fields(@org, defs, false) |> Enum.map(& &1.name)
  end

  test "an editor sees private fields only when asked", %{defs: defs} do
    editor = actor(:editor)
    org = KilnCMS.Accounts.default_org_id()

    assert ["price", "cost", "owner"] ==
             editor |> ListFields.readable_fields(org, defs, true) |> Enum.map(& &1.name)

    assert ["price"] ==
             editor |> ListFields.readable_fields(org, defs, false) |> Enum.map(& &1.name)
  end

  test "a viewer and no actor never get private fields, even when asked", %{defs: defs} do
    for who <- [actor(:viewer), nil] do
      assert ["price"] ==
               who |> ListFields.readable_fields(@org, defs, true) |> Enum.map(& &1.name)
    end
  end

  test "the format types are pickable, json is not (#2278)" do
    for type <- [:email, :telephone, :color, :slug, :time],
        do: assert(ListFields.pickable?(def_("x", type)))

    refute ListFields.pickable?(def_("x", :json))

    for type <- [:range, :key_value, :link],
        do: refute(ListFields.pickable?(def_("x", type)))
  end

  test "types the picker does not offer, and multiple-valued fields, are dropped", %{defs: defs} do
    names = actor(:admin) |> ListFields.readable_fields(@org, defs, true) |> Enum.map(& &1.name)
    refute "shape" in names
    refute "where" in names
    refute "tags" in names
  end

  test "picker_types covers the v1 set and the format types" do
    assert Enum.sort(ListFields.picker_types()) ==
             Enum.sort(
               ~w(string text integer float boolean date datetime url select reference user media email telephone color slug time)a
             )
  end

  describe "stored_columns/3" do
    test "reads the org-keyed map" do
      user = %{content_list_columns: %{@org => %{"post" => ["a", "b", "a"]}}}
      assert ["a", "b"] == ListFields.stored_columns(user, @org, "post")
    end

    test "nil, missing org, missing type, NotLoaded and junk read as []" do
      assert [] == ListFields.stored_columns(%{content_list_columns: nil}, @org, "post")
      assert [] == ListFields.stored_columns(%{content_list_columns: %{}}, @org, "post")

      assert [] ==
               ListFields.stored_columns(%{content_list_columns: %{@org => %{}}}, @org, "post")

      assert [] ==
               ListFields.stored_columns(
                 %{content_list_columns: %Ash.NotLoaded{}},
                 @org,
                 "post"
               )

      assert [] == ListFields.stored_columns(%{}, @org, "post")
      assert [] == ListFields.stored_columns(nil, @org, "post")

      assert [] ==
               ListFields.stored_columns(
                 %{content_list_columns: %{@org => %{"post" => "x"}}},
                 @org,
                 "post"
               )
    end

    test "non-string names are dropped and the list is capped" do
      names = Enum.map(1..9, &"f#{&1}")
      user = %{content_list_columns: %{@org => %{"post" => [1, nil | names]}}}
      assert Enum.take(names, 6) == ListFields.stored_columns(user, @org, "post")
    end
  end

  test "resolve_columns drops unknown names and caps at four", %{defs: defs} do
    assert ["price"] ==
             ["gone", "price"] |> ListFields.resolve_columns(defs) |> Enum.map(& &1.name)

    many = for n <- 1..6, do: def_("f#{n}", :string)

    assert 4 == many |> Enum.map(& &1.name) |> ListFields.resolve_columns(many) |> length()
  end
end
