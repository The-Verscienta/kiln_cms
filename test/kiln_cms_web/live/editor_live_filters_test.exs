defmodule KilnCMSWeb.EditorLiveFiltersTest do
  @moduledoc """
  The content list's custom-field conditions (`cf`) and field sort in
  `EditorLive.Filters` (#2293): the URL contract, validation against the one
  type in play, and the rules that keep stale state out of the URL.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.SavedView
  alias KilnCMSWeb.EditorLive.Filters

  @fields [
    %{name: "price", field_type: :integer},
    %{name: "note", field_type: :string},
    %{name: "born", field_type: :date},
    %{name: "color", field_type: :select, options: ["red", "blue"]},
    %{name: "author_ref", field_type: :reference},
    %{name: "seen", field_type: :datetime}
  ]

  defp ctx(opts \\ []) do
    types = Keyword.get(opts, :types, ["post", "page"])
    fields = Keyword.get(opts, :fields, %{"post" => @fields})

    %{
      types: types,
      locales: ["en"],
      fields: fn type -> Map.get(fields, type, []) end
    }
  end

  defp parse(params, opts \\ []), do: Filters.parse(params, ctx(opts))

  describe "cf" do
    test "round-trips through to_params, with encoded awkward values" do
      for value <- ["a;b", "a:b", "50%", "a+b c", "ünï cödé ✓", "x=y&z"] do
        filters = parse(%{"type" => "post", "cf" => cf("note", "eq", value)})
        assert [%{field: "note", op: "eq", value: ^value}] = Filters.conditions(filters)

        params = Filters.to_params(filters)
        assert parse(params) == filters
        # the value never appears raw in a `;`/`:` position
        assert length(String.split(params["cf"], ";")) == 1
        assert length(String.split(params["cf"], ":")) == 3
      end
    end

    test "equal filters give equal strings, whatever order they were written in" do
      a = parse(%{"type" => "post", "cf" => "price:gte:10;note:eq:x"})
      b = parse(%{"type" => "post", "cf" => "note:eq:x;price:gte:10"})
      assert a["cf"] == b["cf"]
      assert a["cf"] == "note:eq:x;price:gte:10"
    end

    test "a single-type site needs no type param" do
      filters = parse(%{"cf" => "price:gt:5"}, types: ["post"])
      assert [%{field: "price", op: "gt", value: "5"}] = Filters.conditions(filters)
    end

    test "mixed types (all, several) discard cf and a field sort" do
      for params <- [%{}, %{"type" => "all"}] do
        filters = parse(Map.merge(params, %{"cf" => "price:gt:5", "sort" => "field:price"}))
        assert filters["cf"] == nil
        assert filters["sort"] == "updated"
      end
    end

    test "a type with no readable definitions reads cf as absent" do
      filters = parse(%{"type" => "page", "cf" => "price:gt:5"})
      assert filters["cf"] == nil
    end

    test "unknown field, op not offered for the type, and a bad cast are dropped" do
      filters =
        parse(%{
          "type" => "post",
          "cf" =>
            Enum.join(
              [
                "ghost:eq:1",
                "price:contains:1",
                "price:eq:abc",
                "born:eq:2026-13-45",
                "color:eq:green",
                "author_ref:eq:not-a-uuid",
                "note:null:maybe",
                "price:gte:10"
              ],
              ";"
            )
        })

      assert filters["cf"] == "price:gte:10"
    end

    test "malformed segments and escapes are skipped, not raised" do
      filters =
        parse(%{"type" => "post", "cf" => ";;price;price:eq;note:eq:%ZZ;note:eq:%FF;price:eq:3"})

      # `%ZZ` is just text; `%FF` is not UTF-8 and is skipped.
      assert filters["cf"] == "note:eq:%25ZZ;price:eq:3"
    end

    test "a non-string cf is absent" do
      assert parse(%{"type" => "post", "cf" => ["price:eq:3"]})["cf"] == nil
      assert parse(%{"type" => "post", "cf" => %{"a" => "b"}})["cf"] == nil
    end

    test "at most four conditions, one per field and op" do
      cf =
        Enum.join(
          [
            "price:eq:1",
            "price:eq:2",
            "price:gte:1",
            "price:lte:9",
            "note:eq:a",
            "born:eq:2026-01-01"
          ],
          ";"
        )

      filters = parse(%{"type" => "post", "cf" => cf})
      assert length(Filters.conditions(filters)) == 4

      assert Filters.conditions(filters)
             |> Enum.map(&{&1.field, &1.op})
             |> Enum.uniq()
             |> length() == 4
    end

    test "the encoded string never exceeds what a saved view stores" do
      long = String.duplicate("é", 60)
      cf = Enum.map_join(~w(a b c d), ";", fn _ -> cf("note", "contains", long) end)
      filters = parse(%{"type" => "post", "cf" => cf})
      assert String.length(filters["cf"] || "") <= SavedView.max_cf_length()
    end

    test "datetime accepts a day, a select its options" do
      filters = parse(%{"type" => "post", "cf" => "seen:gte:2026-03-01;color:eq:red"})
      assert filters["cf"] == "color:eq:red;seen:gte:2026-03-01"
    end

    test "narrowing? and active? see cf" do
      filters = parse(%{"type" => "post", "cf" => "price:eq:1"})
      assert Filters.narrowing?(filters)
      assert Filters.active?(filters)
    end
  end

  describe "field sort" do
    test "is kept for a sortable field of the one type, in both directions" do
      assert Filters.field_sort(parse(%{"type" => "post", "sort" => "field:price"})) ==
               {"price", :asc}

      assert Filters.field_sort(parse(%{"type" => "post", "sort" => "-field:price"})) ==
               {"price", :desc}
    end

    test "unknown, unsortable and out-of-type fields fall back to updated" do
      for sort <- ["field:ghost", "field:author_ref", "field:", "-field:", "fieldprice"] do
        assert parse(%{"type" => "post", "sort" => sort})["sort"] == "updated", sort
      end

      assert parse(%{"type" => "page", "sort" => "field:price"})["sort"] == "updated"
    end

    test "is not an Ash sort, and cannot be merged across types" do
      filters = parse(%{"type" => "post", "sort" => "-field:price"})
      assert Filters.sort(filters) == []
      assert_raise ArgumentError, fn -> Filters.before?(filters, %{}, %{}) end
      assert Filters.sort(parse(%{})) == [updated_at: :desc, id: :desc]
    end

    test "the argument map names the field once, ordered as asked" do
      filters = parse(%{"type" => "post", "sort" => "-field:price", "cf" => "price:gte:3"})

      assert Filters.field_arguments(filters, @fields) == %{
               custom_filter: %{"price" => %{"gte" => "3"}},
               custom_sort: "-price"
             }

      assert Filters.field_arguments(parse(%{}), @fields) == %{}
    end
  end

  describe "changing the type" do
    test "clears cf and a field sort, but not other facets" do
      filters =
        parse(%{"type" => "post", "cf" => "price:eq:1", "sort" => "field:price", "q" => "hi"})

      merged = Filters.merge(filters, %{"type" => "page"})

      assert merged["cf"] == nil
      assert merged["sort"] == "updated"
      assert merged["q"] == "hi"

      assert Filters.to_params(parse(merged)) == %{"type" => "page", "q" => "hi"}
    end

    test "re-sending the same type keeps them" do
      filters = parse(%{"type" => "post", "cf" => "price:eq:1", "sort" => "field:price"})
      assert Filters.merge(filters, %{"type" => "post"}) == filters
    end

    test "other changes keep them" do
      filters = parse(%{"type" => "post", "cf" => "price:eq:1"})
      assert Filters.merge(filters, %{"status" => "draft"})["cf"] == "price:eq:1"
    end
  end

  describe "add_condition/5 and remove_condition/3" do
    test "adds in canonical order, replaces the same field and op" do
      filters = parse(%{"type" => "post"})
      {:ok, filters} = Filters.add_condition(filters, @fields, "price", "gte", "10")
      {:ok, filters} = Filters.add_condition(filters, @fields, "color", "eq", "red")
      {:ok, filters} = Filters.add_condition(filters, @fields, "price", "gte", "20")

      assert filters["cf"] == "color:eq:red;price:gte:20"
      assert Filters.remove_condition(filters, "price", "gte")["cf"] == "color:eq:red"

      assert Filters.remove_condition(
               Filters.remove_condition(filters, "price", "gte"),
               "color",
               "eq"
             )["cf"] == nil
    end

    test "refuses what is not a condition, and a fifth, loudly" do
      filters = parse(%{"type" => "post"})
      assert {:error, :invalid} = Filters.add_condition(filters, @fields, "ghost", "eq", "1")
      assert {:error, :invalid} = Filters.add_condition(filters, @fields, "price", "eq", "x")

      assert {:error, :invalid} =
               Filters.add_condition(filters, @fields, "price", "contains", "1")

      assert {:error, :invalid} = Filters.add_condition(filters, @fields, "price", "eq", ["1"])

      {:ok, filters} = Filters.add_condition(filters, @fields, "price", "gte", "1")
      {:ok, filters} = Filters.add_condition(filters, @fields, "price", "lte", "9")
      {:ok, filters} = Filters.add_condition(filters, @fields, "note", "eq", "a")
      {:ok, filters} = Filters.add_condition(filters, @fields, "color", "eq", "red")

      assert {:error, :limit} =
               Filters.add_condition(filters, @fields, "born", "eq", "2026-01-01")

      # replacing one of the four is not a fifth
      assert {:ok, _} = Filters.add_condition(filters, @fields, "note", "eq", "b")
    end

    test "refuses a value that would overflow the stored length" do
      filters = parse(%{"type" => "post"})
      long = String.duplicate("é", 100)

      assert {:error, :limit} = Filters.add_condition(filters, @fields, "note", "contains", long)
    end
  end

  describe "saved views" do
    test "cf is a stored key with its own, longer cap" do
      assert "cf" in SavedView.param_keys()
      long = String.duplicate("a", 500)
      assert %{"cf" => ^long} = SavedView.clean_params(%{"cf" => long, "q" => "ok"})
      assert SavedView.clean_params(%{"cf" => String.duplicate("a", 601)}) == %{}
      assert SavedView.clean_params(%{"q" => String.duplicate("a", 201)}) == %{}
    end

    test "dropped_conditions counts what a deleted or private field takes out" do
      params = %{"type" => "post", "cf" => "price:eq:1;ghost:eq:2"}
      assert Filters.dropped_conditions(params, ctx()) == 1
      assert Filters.dropped_conditions(%{"type" => "post", "cf" => "price:eq:1"}, ctx()) == 0
      assert Filters.dropped_conditions(%{"type" => "post"}, ctx()) == 0
    end

    test "dropped_conditions counts only distinct, well-formed conditions that were lost" do
      count = &Filters.dropped_conditions(%{"type" => "post", "cf" => &1}, ctx())

      # repeats, malformed segments and the fifth-and-later are not losses
      assert count.("price:eq:1;price:eq:1") == 0
      assert count.("price:eq:1;;junk;price:eq") == 0

      assert count.("price:eq:1;price:gt:1;price:gte:1;price:lt:1;price:lte:1;note:eq:a") == 0

      # an unknown field, or a value that no longer casts, is
      assert count.("price:eq:1;ghost:eq:1;ghost:eq:1") == 1
      assert count.("price:eq:abc") == 1
    end

    test "stale? also sees a field sort that was dropped" do
      stale? = &Filters.stale?(&1, ctx())
      assert stale?.(%{"type" => "post", "sort" => "field:ghost"})
      refute stale?.(%{"type" => "post", "sort" => "field:price"})
      refute stale?.(%{"type" => "post", "sort" => "title"})
      refute stale?.(%{"type" => "post"})
    end

    test "the lookup is asked only when cf or a field sort needs it" do
      ctx = %{types: ["post"], locales: ["en"], fields: fn _ -> flunk("read definitions") end}
      Filters.parse(%{"type" => "post", "q" => "x", "sort" => "title"}, ctx)
      assert Filters.needs_fields?(%{"cf" => "a:b:c"})
      assert Filters.needs_fields?(%{"sort" => "-field:a"})
      refute Filters.needs_fields?(%{"sort" => "title"})
    end

    test "a field the actor cannot read (absent from the lookup) is forged away" do
      readable = Enum.reject(@fields, &(&1.name == "secret"))
      forged = %{"type" => "post", "cf" => "secret:eq:x"}
      assert parse(forged, fields: %{"post" => readable})["cf"] == nil
    end

    test "a ctx without a lookup drops cf" do
      assert Filters.parse(%{"type" => "post", "cf" => "price:eq:1"}, %{
               types: ["post"],
               locales: ["en"]
             })[
               "cf"
             ] == nil
    end
  end

  defp cf(field, op, value),
    do: URI.encode_www_form(field) <> ":" <> op <> ":" <> URI.encode_www_form(value)
end
