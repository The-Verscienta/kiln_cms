defmodule KilnCMS.CMS.PluginNumericFieldQueryTest do
  @moduledoc """
  `custom_filter`, `custom_where` and `custom_sort` on a plugin field type
  whose `graphql_kind/1` is numeric (#2855): the fixture plugin's `:score`
  (`:int`). Its operands are cast as a core `:integer` field's are, so `9`
  compares below `10` and an operand that is not a number is a 400, where
  they used to be compared as text and never matched a stored JSON number.

  Field names are unique per test, so predicates on them only ever match
  records seeded here (shared-sandbox safety).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pnq-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, label: "Score"}, attrs),
      actor: actor
    )
  end

  defp page!(fields, actor) do
    CMS.create_page!(
      %{title: "P", slug: "pnq-#{System.unique_integer([:positive])}", custom_fields: fields},
      actor: actor
    )
  end

  defp ids!(inputs, actor), do: inputs |> CMS.list_pages!(actor: actor) |> Enum.map(& &1.id)

  defp sorted_ids!(inputs, actor), do: inputs |> ids!(actor) |> Enum.sort()

  defp error!(inputs, actor) do
    assert {:error, %Ash.Error.Invalid{} = error} = CMS.list_pages(inputs, actor: actor)
    Exception.message(error)
  end

  setup do
    admin = admin()
    name = "score#{System.unique_integer([:positive])}"
    define!(%{name: name, field_type: :score}, admin)

    nine = page!(%{name => 9}, admin)
    ten = page!(%{name => "10"}, admin)

    %{admin: admin, name: name, nine: nine, ten: ten}
  end

  test "the fixture type stores a JSON number", %{admin: admin, name: name, ten: ten} do
    assert CMS.get_page!(ten.id, actor: admin).custom_fields[name] == 10
  end

  describe "custom_filter" do
    test "range operators compare numerically, not as text", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx

      # As text "9" > "10"; as numbers it is not.
      for operand <- ["9", 9] do
        assert ids!(%{custom_filter: %{name => %{"gt" => operand}}}, admin) == [ten.id]
      end

      for operand <- ["10", 10] do
        assert ids!(%{custom_filter: %{name => %{"lt" => operand}}}, admin) == [nine.id]
      end

      assert sorted_ids!(%{custom_filter: %{name => %{"gte" => "9"}}}, admin) ==
               Enum.sort([nine.id, ten.id])
    end

    test "equality matches the stored number", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx

      assert ids!(%{custom_filter: %{name => "10"}}, admin) == [ten.id]
      assert ids!(%{custom_filter: %{name => %{"eq" => 9}}}, admin) == [nine.id]
      assert ids!(%{custom_filter: %{name => %{"not_eq" => "9"}}}, admin) == [ten.id]

      assert sorted_ids!(%{custom_filter: %{name => %{"in" => ["9", 10]}}}, admin) ==
               Enum.sort([nine.id, ten.id])
    end

    test "an operand that is not a number is refused, as on a core integer", ctx do
      assert error!(%{custom_filter: %{ctx.name => %{"gt" => "ten"}}}, ctx.admin) =~
               "invalid integer value"

      assert error!(%{custom_filter: %{ctx.name => "ten"}}, ctx.admin) =~
               "invalid integer value"

      assert error!(%{custom_filter: %{ctx.name => %{"ilike" => "%1%"}}}, ctx.admin) =~
               "only supported on text-like custom fields"
    end
  end

  test "custom_where's int condition compares numerically", ctx do
    %{admin: admin, name: name, nine: nine, ten: ten} = ctx

    assert ids!(%{custom_where: [%{name: name, int: %{gt: 9}}]}, admin) == [ten.id]
    assert ids!(%{custom_where: [%{name: name, int: %{lt: 10}}]}, admin) == [nine.id]
    assert ids!(%{custom_where: [%{name: name, int: %{eq: 10}}]}, admin) == [ten.id]
  end

  test "custom_sort orders numerically", ctx do
    %{admin: admin, name: name, nine: nine, ten: ten} = ctx
    only_these = %{name => %{"null" => "false"}}

    assert ids!(%{custom_filter: only_these, custom_sort: name}, admin) == [nine.id, ten.id]

    assert ids!(%{custom_filter: only_these, custom_sort: "-" <> name}, admin) == [
             ten.id,
             nine.id
           ]
  end

  # A value stored before the field was retyped stays where jsonb's order puts
  # it, exactly as on a core `:integer` field: never a crash, and the numbers
  # still compare as numbers among themselves.
  test "a stored value that is not a number neither crashes nor reorders the numbers" do
    admin = admin()

    [core, plugin] =
      for type <- [:integer, :score] do
        name = "retyped#{System.unique_integer([:positive])}"
        definition = define!(%{name: name, field_type: :string}, admin)
        word = page!(%{name => "lots"}, admin)
        CMS.update_field_definition!(definition, %{field_type: type}, actor: admin)
        nine = page!(%{name => 9}, admin)
        ten = page!(%{name => 10}, admin)

        assert CMS.get_page!(word.id, actor: admin).custom_fields[name] == "lots"

        label = %{word.id => :word, nine.id => 9, ten.id => 10}
        read = fn inputs -> inputs |> ids!(admin) |> Enum.map(&Map.fetch!(label, &1)) end
        present = %{name => %{"null" => "false"}}

        gt = read.(%{custom_filter: %{name => %{"gt" => "9"}}})
        lt = read.(%{custom_filter: %{name => %{"lt" => 10}}})
        asc = read.(%{custom_filter: present, custom_sort: name})
        desc = read.(%{custom_filter: present, custom_sort: "-" <> name})

        assert 10 in gt and 9 not in gt
        assert 9 in lt and 10 not in lt
        assert read.(%{custom_filter: %{name => "10"}}) == [10]
        assert Enum.filter(asc, &is_integer/1) == [9, 10]
        assert Enum.filter(desc, &is_integer/1) == [10, 9]
        assert Enum.sort(asc) == Enum.sort([:word, 9, 10])

        {Enum.sort(gt), Enum.sort(lt), asc, desc}
      end

    assert plugin == core
  end
end
