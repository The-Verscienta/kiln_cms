defmodule KilnCMS.CMS.CustomFieldContainmentTest do
  @moduledoc """
  `custom_filter` equality is matched as jsonb containment (`custom_fields @>
  {name: value}`, #2291) so a GIN index can serve it. These tests hold the
  rewrite to the old predicate, `(custom_fields -> name) = value::jsonb`, on a
  corpus whose stored values are deliberately off-type for the field: both the
  predicates themselves (raw SQL) and the real `custom_filter` path must pick
  the same rows. `not_eq` is not rewritten (an absent key must stay excluded)
  and is asserted against the old form too.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  # Every shape a value can be stored in, for one field name.
  @stored [
    {:int, 5},
    {:float_whole, 5.0},
    {:float, 5.5},
    {:string_five, "5"},
    {:string_red, "red"},
    {:bool, true},
    {:list_int, [5]},
    {:list_red, ["red", "blue"]},
    {:object, %{"x" => 5}},
    {:snapshot, %{"id" => "abc", "filename" => "a.png"}},
    {:snapshots, [%{"id" => "abc"}, %{"id" => "def"}]},
    {:json_null, nil},
    {:absent, :absent}
  ]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfc-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp field_name(base), do: "#{base}#{System.unique_integer([:positive])}"

  # Seeds one page per stored shape and returns `%{key => id}`.
  defp seed!(name) do
    Map.new(@stored, fn {key, value} ->
      fields = if value == :absent, do: %{"other" => 1}, else: %{name => value}

      page =
        Ash.Seed.seed!(CMS.Page, %{
          title: "cfc #{key}",
          slug: "cfc-#{key}-#{System.unique_integer([:positive])}",
          custom_fields: fields
        })

      {key, page.id}
    end)
  end

  defp ids_by_sql(sql, params, seeded) do
    ids = Map.values(seeded) |> Enum.map(&Ecto.UUID.dump!/1)

    %{rows: rows} =
      Repo.query!("SELECT id FROM pages WHERE id = ANY($1) AND " <> sql, [ids | params])

    rows |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end) |> Enum.sort()
  end

  defp old(name, value, seeded),
    do: ids_by_sql("(custom_fields -> $2::text) = $3::jsonb", [name, value], seeded)

  defp new(name, value, seeded),
    do:
      ids_by_sql(
        "custom_fields @> jsonb_build_object($2::text, $3::jsonb)",
        [name, value],
        seeded
      )

  describe "the predicates" do
    test "containment selects the same rows as the old equality, whatever is stored" do
      name = field_name("eq")
      seeded = seed!(name)

      for probe <- [5, 5.0, 5.5, "5", "red", true, false, "abc"] do
        assert new(name, probe, seeded) == old(name, probe, seeded),
               "differs for probe #{inspect(probe)}"
      end
    end

    test "a number matches 5 and 5.0 alike, never the string" do
      name = field_name("num")
      seeded = seed!(name)

      assert new(name, 5, seeded) ==
               Enum.sort([seeded.int, seeded.float_whole])

      assert new(name, 5.0, seeded) == new(name, 5, seeded)
      assert new(name, "5", seeded) == [seeded.string_five]
    end

    test "a list holding the scalar does not match the scalar" do
      # Containment's `[5] @> 5` shortcut is top-level only.
      name = field_name("nest")
      seeded = seed!(name)

      refute seeded.list_int in new(name, 5, seeded)
      refute seeded.list_red in new(name, "red", seeded)
      refute seeded.snapshots in new(name, %{"id" => "abc"}, seeded)
    end

    test "absent and JSON null match nothing" do
      name = field_name("nul")
      seeded = seed!(name)

      for probe <- [5, "5", "red", true] do
        refute seeded.absent in new(name, probe, seeded)
        refute seeded.json_null in new(name, probe, seeded)
      end
    end

    test "containment is wider than equality for a non-scalar probe, so the helper is scalar-only" do
      # `cast_value/3` only ever yields a string, number or boolean, so
      # `custom_filter` never reaches this; it is pinned so nobody feeds
      # `contains/3` a list or object expecting equality.
      name = field_name("lst")
      seeded = seed!(name)

      assert old(name, ["red"], seeded) == []
      assert new(name, ["red"], seeded) == [seeded.list_red]
    end

    test "a snapshot's id matches the way the old text comparison did" do
      name = field_name("snap")
      seeded = seed!(name)

      matched =
        ids_by_sql(
          "custom_fields @> jsonb_build_object($2::text, jsonb_build_object('id', $3::text))",
          [name, "abc"],
          seeded
        )

      assert matched == [seeded.snapshot]

      assert ids_by_sql("(custom_fields #>> ARRAY[$2::text, 'id']) = $3", [name, "abc"], seeded) ==
               matched
    end
  end

  describe "through custom_filter" do
    setup do
      %{admin: admin()}
    end

    defp filter_ids(name, condition, seeded, admin) do
      %{custom_filter: %{name => condition}}
      |> CMS.list_pages!(actor: admin)
      |> Enum.map(& &1.id)
      |> Enum.filter(&(&1 in Map.values(seeded)))
      |> Enum.sort()
    end

    test "integer eq and in match the old predicate on a re-typed definition", %{admin: admin} do
      name = field_name("price")

      CMS.create_field_definition!(
        %{content_type: :page, label: "P", name: name, field_type: :integer},
        actor: admin
      )

      seeded = seed!(name)

      assert filter_ids(name, "5", seeded, admin) == old(name, 5, seeded)
      assert filter_ids(name, %{"eq" => "5"}, seeded, admin) == old(name, 5, seeded)

      in_ids = (old(name, 5, seeded) ++ old(name, 6, seeded)) |> Enum.sort()
      assert filter_ids(name, %{"in" => ["5", "6"]}, seeded, admin) == in_ids
      assert filter_ids(name, %{"in" => []}, seeded, admin) == []
    end

    test "string eq and in match the old predicate", %{admin: admin} do
      name = field_name("color")

      CMS.create_field_definition!(
        %{content_type: :page, label: "C", name: name, field_type: :string},
        actor: admin
      )

      seeded = seed!(name)

      assert filter_ids(name, "red", seeded, admin) == old(name, "red", seeded)

      assert filter_ids(name, %{"in" => ["red", "5"]}, seeded, admin) ==
               Enum.sort(old(name, "red", seeded) ++ old(name, "5", seeded))
    end

    test "boolean eq matches the old predicate", %{admin: admin} do
      name = field_name("flag")

      CMS.create_field_definition!(
        %{content_type: :page, label: "F", name: name, field_type: :boolean},
        actor: admin
      )

      seeded = seed!(name)

      assert filter_ids(name, "true", seeded, admin) == old(name, true, seeded)
    end

    test "not_eq keeps excluding rows that lack the key", %{admin: admin} do
      name = field_name("neq")

      CMS.create_field_definition!(
        %{content_type: :page, label: "N", name: name, field_type: :integer},
        actor: admin
      )

      seeded = seed!(name)

      expected =
        ids_by_sql("(custom_fields -> $2::text) != $3::jsonb", [name, 5], seeded)

      got = filter_ids(name, %{"not_eq" => "5"}, seeded, admin)

      assert got == expected
      refute seeded.absent in got
    end

    test "a multiple select matches by containment and not_eq still drops absent rows", %{
      admin: admin
    } do
      name = field_name("tags")

      CMS.create_field_definition!(
        %{
          content_type: :page,
          label: "T",
          name: name,
          field_type: :select,
          multiple: true,
          options: ["red", "blue"]
        },
        actor: admin
      )

      seeded = seed!(name)

      # A bare "red" stored before the field was a list reads as a one-item
      # list (#2289), so it matches too; no other shape does.
      red = Enum.sort([seeded.list_red, seeded.string_red])

      assert filter_ids(name, "red", seeded, admin) == red
      assert filter_ids(name, %{"in" => ["red", "blue"]}, seeded, admin) == red

      not_red = filter_ids(name, %{"not_eq" => "red"}, seeded, admin)
      refute seeded.list_red in not_red
      refute seeded.string_red in not_red
      refute seeded.absent in not_red
      refute seeded.json_null in not_red
    end

    test "a single media field matches the snapshot id", %{admin: admin} do
      name = field_name("hero")

      CMS.create_field_definition!(
        %{content_type: :page, label: "H", name: name, field_type: :media},
        actor: admin
      )

      seeded = seed!(name)

      assert filter_ids(name, "abc", seeded, admin) == [seeded.snapshot]
      assert filter_ids(name, %{"in" => ["abc", "zzz"]}, seeded, admin) == [seeded.snapshot]

      not_abc = filter_ids(name, %{"not_eq" => "abc"}, seeded, admin)
      refute seeded.snapshot in not_abc
      refute seeded.absent in not_abc
    end
  end
end
