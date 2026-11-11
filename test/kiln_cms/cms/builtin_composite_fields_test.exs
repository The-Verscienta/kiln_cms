defmodule KilnCMS.CMS.BuiltinCompositeFieldsTest do
  @moduledoc """
  The built-in composite field types (#2278): `:range`, `:key_value` and
  `:link`. Each registers through `Kiln.FieldType`, casts totally (an error
  tuple, never a raise), and round-trips through `ApplyCustomFields`, search
  indexing, conditions and the filter surface.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.{FieldKind, FieldTypes, SearchableFields}
  alias KilnCMS.CMS.FieldTypes.{KeyValue, Link, Range}
  alias KilnCMS.JsonSchemaValidator

  @types [:range, :key_value, :link]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cmp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define(actor, type, attrs) do
    CMS.create_field_definition(
      Map.merge(
        %{
          content_type: :page,
          name: "#{type}_#{System.unique_integer([:positive])}",
          label: "A #{type}",
          field_type: type
        },
        attrs
      ),
      actor: actor
    )
  end

  defp define!(actor, type, attrs \\ %{}) do
    {:ok, definition} = define(actor, type, attrs)
    definition
  end

  defp page(actor, fields),
    do:
      CMS.create_page(
        %{title: "Cmp", slug: "cmp-#{System.unique_integer([:positive])}", custom_fields: fields},
        actor: actor
      )

  defp message({:error, error}), do: Exception.message(error)

  describe "registration" do
    test "every type is built in, reserved, described and served as generic JSON" do
      for type <- @types do
        assert module = FieldTypes.get(type)
        assert module in FieldTypes.builtin()
        assert type in FieldTypes.reserved()
        assert is_binary(module.description())
        assert module.name() == type
        assert FieldKind.kind_for(%{field_type: type}) == :json
        assert is_map(module.json_schema(%{}))
      end
    end

    test "constraints (min_length, pattern, min) are refused on all three" do
      actor = admin()

      for type <- @types,
          validation <- [%{"min_length" => 1}, %{"pattern" => "a"}, %{"min" => 1}] do
        assert {:error, error} = define(actor, type, %{validation: validation})
        assert Exception.message(error) =~ "validation"
      end

      for type <- @types, do: assert({:ok, _} = define(actor, type, %{validation: %{}}))
    end

    test "multiple is cleared, not honoured" do
      actor = admin()

      for type <- @types do
        assert define!(actor, type, %{multiple: true}).multiple == false
      end
    end
  end

  describe "range" do
    test "numbers keep their kind; numeric strings become numbers" do
      assert Range.cast(%{"min" => 1, "max" => 2.5}, nil) == {:ok, %{"min" => 1, "max" => 2.5}}

      assert Range.cast(%{"min" => " 5 ", "max" => "7.5"}, nil) ==
               {:ok, %{"min" => 5, "max" => 7.5}}

      assert Range.cast(%{min: -3, max: 0}, nil) == {:ok, %{"min" => -3, "max" => 0}}
    end

    test "dates are ISO strings; a half-open range is a value" do
      assert Range.cast(%{"min" => "2026-01-31", "max" => "2026-12-31"}, nil) ==
               {:ok, %{"min" => "2026-01-31", "max" => "2026-12-31"}}

      assert Range.cast(%{"min" => ~D[2026-02-01], "max" => ""}, nil) ==
               {:ok, %{"min" => "2026-02-01"}}

      assert Range.cast(%{"min" => "", "max" => 9}, nil) == {:ok, %{"max" => 9}}
    end

    test "refuses what is not a range" do
      for bad <- [
            %{},
            %{"min" => "", "max" => nil},
            %{"min" => 5, "max" => 1},
            %{"min" => "2026-02-01", "max" => "2026-01-01"},
            %{"min" => 1, "max" => "2026-01-01"},
            %{"min" => "2026-01-01T10:00:00Z"},
            %{"min" => "2026-02-30"},
            %{"min" => "NaN"},
            %{"min" => "Infinity"},
            %{"min" => "1e999"},
            %{"min" => "1_000"},
            %{"min" => "5abc"},
            %{"min" => 9_007_199_254_740_993},
            %{"min" => true},
            %{"min" => [1]},
            %{"min" => %{}},
            %{"min" => 1, "other" => 2},
            %{"min" => String.duplicate("1", 100)},
            "1..5",
            [1, 2],
            5,
            nil,
            ~D[2026-01-01]
          ] do
        assert {:error, _} = Range.cast(bad, nil), inspect(bad)
      end
    end

    # The merged object is what Swift, Kotlin and older generators read, so it
    # stays exactly as it was; the `anyOf` beside it narrows it (#2548).
    test "the merged schema still allows null, numbers or dates" do
      assert %{
               "type" => ["object", "null"],
               "properties" => %{"min" => %{"type" => ["number", "string"]}, "max" => max},
               "additionalProperties" => false
             } = Range.json_schema(nil)

      assert max["type"] == ["number", "string"]
    end

    test "the schema accepts what cast/2 delivers: two numbers, two dates, a half range, null" do
      schema = Range.json_schema(nil)

      for value <- [
            %{"min" => 1, "max" => 2.5},
            %{"min" => -3, "max" => 0},
            %{"max" => 9},
            %{"min" => "2026-01-31", "max" => "2026-12-31"},
            %{"min" => "2026-02-01"},
            nil
          ] do
        assert JsonSchemaValidator.validate(value, schema) == :ok, inspect(value)
      end
    end

    # A number with a date and an empty range are both refused by cast/2, and
    # now by the schema too; the merged object alone accepted them.
    test "the schema refuses a mixed range, an empty one, and an undeclared key" do
      schema = Range.json_schema(nil)

      for value <- [
            %{"min" => 1, "max" => "2026-01-01"},
            %{"min" => "2026-01-01", "max" => 5},
            %{},
            %{"min" => 1, "other" => 2},
            %{"min" => true},
            "1..5"
          ] do
        assert {:error, _} = JsonSchemaValidator.validate(value, schema), inspect(value)
      end

      assert {:error, [message | _]} = JsonSchemaValidator.validate(%{}, schema)
      assert message =~ "anyOf"
    end

    test "what cast/2 accepts, the schema accepts" do
      schema = Range.json_schema(nil)

      for raw <- [
            %{"min" => " 5 ", "max" => "7.5"},
            %{"min" => ~D[2026-02-01], "max" => ""},
            %{"min" => "", "max" => 9}
          ] do
        assert {:ok, value} = Range.cast(raw, nil)
        assert JsonSchemaValidator.validate(value, schema) == :ok, inspect(value)
      end
    end
  end

  describe "key_value" do
    test "textarea lines split at the first =, trimmed, blanks skipped" do
      assert KeyValue.cast("Weight = 2 kg\r\n\n  Formula=a=b  \n", nil) ==
               {:ok,
                [
                  %{"key" => "Weight", "value" => "2 kg"},
                  %{"key" => "Formula", "value" => "a=b"}
                ]}
    end

    test "a list keeps its order; a map is sorted by key" do
      list = [%{"key" => "b", "value" => "1"}, %{key: "a", value: "2"}]

      assert KeyValue.cast(list, nil) ==
               {:ok, [%{"key" => "b", "value" => "1"}, %{"key" => "a", "value" => "2"}]}

      assert KeyValue.cast(%{"b" => "1", a: "2"}, nil) ==
               {:ok, [%{"key" => "a", "value" => "2"}, %{"key" => "b", "value" => "1"}]}
    end

    test "an empty value is allowed; a pair with neither key nor value is dropped" do
      assert KeyValue.cast("flag=\n=\n", nil) == {:ok, [%{"key" => "flag", "value" => ""}]}
    end

    test "refuses hostile and malformed input" do
      long_value = String.duplicate("v", 1001)

      for bad <- [
            "no equals sign",
            "=orphan value",
            "a=1\na=2",
            "a=1\n" <> "a = 3",
            "a\u0000b=1",
            "a=b\u0000",
            "a=\u0001",
            <<0xFF, ?=, ?a>>,
            String.duplicate("k", 101) <> "=1",
            "k=" <> long_value,
            Enum.map_join(1..101, "\n", &"k#{&1}=v"),
            String.duplicate("a=b\n", 40_000),
            [%{"key" => "a=b", "value" => "1"}],
            [%{"key" => "a", "value" => "line\nbreak"}],
            [%{"key" => "a", "value" => 1}],
            [%{"key" => 1, "value" => "x"}],
            [%{"key" => "a", "value" => "b", "extra" => "c"}],
            [%{"key" => "", "value" => "orphan"}],
            ["a=b"],
            [[:a, :b]],
            %{"a" => %{"nested" => "x"}},
            %{1 => "x"},
            5,
            nil,
            {:a, :b}
          ] do
        assert {:error, _} = KeyValue.cast(bad, nil), inspect(bad, limit: 5)
      end
    end

    test "the encoded size is capped" do
      pairs = for i <- 1..100, do: %{"key" => "k#{i}", "value" => String.duplicate("é", 700)}
      assert {:error, message} = KeyValue.cast(pairs, nil)
      assert message =~ "KB"
    end

    test "a deeply nested value is refused, not recursed into" do
      deep = Enum.reduce(1..5_000, "x", fn _, acc -> %{"k" => acc} end)
      assert {:error, _} = KeyValue.cast(deep, nil)
    end
  end

  describe "link" do
    test "stores the trimmed url, and only the parts that are set" do
      assert Link.cast(%{"url" => "  https://example.com/a?b=1 "}, nil) ==
               {:ok, %{"url" => "https://example.com/a?b=1"}}

      assert Link.cast(%{url: "/about", label: " About us ", target: "_self", rel: ""}, nil) ==
               {:ok, %{"url" => "/about", "label" => "About us", "target" => "_self"}}

      for url <- ["mailto:a@example.com", "#section", "/path#x"],
          do: assert({:ok, %{"url" => ^url}} = Link.cast(%{"url" => url}, nil))
    end

    test "rel is allowlisted, lowercased, canonically ordered; _blank forces noopener noreferrer" do
      assert {:ok, %{"rel" => "nofollow sponsored"}} =
               Link.cast(%{"url" => "/a", "rel" => "Sponsored  nofollow"}, nil)

      assert {:ok, %{"rel" => "noopener noreferrer", "target" => "_blank"}} =
               Link.cast(%{"url" => "/a", "target" => "_blank"}, nil)

      assert {:ok, %{"rel" => "noopener noreferrer ugc"}} =
               Link.cast(
                 %{"url" => "/a", "target" => "_blank", "rel" => ["ugc", "noopener"]},
                 nil
               )
    end

    test "hostile and malformed urls are refused, never rewritten" do
      for bad <- [
            "javascript:alert(1)",
            "JaVa\tscript:alert(1)",
            " jav\nascript:x",
            "data:text/html,<script>1</script>",
            "//evil.example.com",
            "tel:+15551234567",
            "ftp://example.com",
            "vbscript:x",
            "https://exa\u0000mple.com",
            <<0xFF, ?a>>,
            "https://example.com/" <> String.duplicate("a", 10_000),
            "",
            "   "
          ] do
        assert {:error, _} = Link.cast(%{"url" => bad}, nil), inspect(bad, limit: 40)
      end
    end

    test "refuses bad parts and shapes" do
      for bad <- [
            %{},
            %{"label" => "x"},
            %{"url" => 5},
            %{"url" => ["/a"]},
            %{"url" => "/a", "label" => 5},
            %{"url" => "/a", "label" => String.duplicate("l", 201)},
            %{"url" => "/a", "label" => "two\nlines"},
            %{"url" => "/a", "label" => "nul\u0000"},
            %{"url" => "/a", "target" => "_top"},
            %{"url" => "/a", "rel" => "bogus"},
            %{"url" => "/a", "rel" => "nofollow bogus"},
            %{"url" => "/a", "rel" => 5},
            %{"url" => "/a", "extra" => "x"},
            "https://example.com",
            [],
            5,
            nil
          ] do
        assert {:error, message} = Link.cast(bad, nil), inspect(bad, limit: 5)
        refute message =~ "link field"
      end
    end
  end

  describe "through ApplyCustomFields" do
    test "values are stored normalised and are JSON" do
      actor = admin()
      range = define!(actor, :range)
      kv = define!(actor, :key_value)
      link = define!(actor, :link)

      assert {:ok, page} =
               page(actor, %{
                 range.name => %{"min" => "10", "max" => "20.5"},
                 kv.name => "Weight=2 kg\nColour = red",
                 link.name => %{"url" => " https://example.com ", "target" => "_blank"}
               })

      fields = page.custom_fields
      assert fields[range.name] == %{"min" => 10, "max" => 20.5}
      assert [%{"key" => "Weight"}, %{"key" => "Colour", "value" => "red"}] = fields[kv.name]

      assert fields[link.name] == %{
               "url" => "https://example.com",
               "target" => "_blank",
               "rel" => "noopener noreferrer"
             }

      assert {:ok, _} = Jason.encode(fields)
    end

    test "an invalid value fails the write, naming the field" do
      actor = admin()
      link = define!(actor, :link)
      assert message(page(actor, %{link.name => %{"url" => "javascript:alert(1)"}})) =~ "address"
      assert message(page(actor, %{link.name => "javascript:alert(1)"})) =~ "link with an address"
    end

    test "an untouched widget (blank parts) is empty: optional is skipped, required is refused" do
      actor = admin()
      range = define!(actor, :range)
      link = define!(actor, :link)
      kv = define!(actor, :key_value)

      blank = %{
        range.name => %{"min" => "", "max" => ""},
        link.name => %{"url" => "", "label" => "", "target" => "", "rel" => ""},
        kv.name => ""
      }

      assert {:ok, page} = page(actor, blank)
      for name <- Map.keys(blank), do: refute(Map.has_key?(page.custom_fields, name))

      required = for t <- @types, into: %{}, do: {t, define!(actor, t, %{required: true})}

      for {type, inputs} <- [
            range: [%{"min" => "", "max" => ""}, %{min: nil, max: nil}],
            link: [%{"url" => "", "label" => "", "target" => "", "rel" => ""}],
            key_value: ["", "  ", %{}, [], [%{"key" => "", "value" => ""}]]
          ],
          input <- inputs do
        assert message(page(actor, %{required[type].name => input})) =~ "required",
               inspect({type, input})
      end
    end

    test "clearing a stored value removes the key, and never stores []" do
      actor = admin()
      kv = define!(actor, :key_value)
      {:ok, page} = page(actor, %{kv.name => "a=1"})
      assert page.custom_fields[kv.name] == [%{"key" => "a", "value" => "1"}]

      updated = CMS.update_page!(page, %{custom_fields: %{kv.name => []}}, actor: actor)
      refute Map.has_key?(updated.custom_fields, kv.name)
    end

    test "a hidden target is not required, and none can be a condition source (#2277)" do
      actor = admin()
      kind = define!(actor, :select, %{options: ["a", "b"]})
      rule = %{"field" => kind.name, "op" => "eq", "value" => "a"}

      # A hidden field is only not required: a value is still cast.
      for {type, bad, blank} <- [
            {:range, %{"min" => "NaN"}, %{"min" => "", "max" => ""}},
            {:link, %{"url" => "javascript:x"}, %{"url" => "", "target" => ""}},
            {:key_value, "no equals sign", ""}
          ] do
        target = define!(actor, type, %{visible_when: rule, required: true})
        assert {:ok, page} = page(actor, %{kind.name => "b", target.name => blank})
        refute Map.has_key?(page.custom_fields, target.name)
        assert message(page(actor, %{kind.name => "a", target.name => blank})) =~ "required"
        assert {:error, _} = page(actor, %{kind.name => "b", target.name => bad})
      end

      for type <- @types do
        source = define!(actor, type)

        assert {:error, error} =
                 define(actor, :string, %{
                   visible_when: %{"field" => source.name, "op" => "not_empty"}
                 })

        assert Exception.message(error) =~ "no simple value to test"
      end
    end
  end

  describe "searchable" do
    defp texts(type, value) do
      definition = %{
        name: "f",
        field_type: type,
        searchable: true,
        position: 0,
        names_record: false
      }

      SearchableFields.texts(%{"f" => value}, [definition])
    end

    test "a link indexes its label only" do
      value = %{
        "url" => "https://secret.example/zorp",
        "label" => "Read more",
        "rel" => "nofollow"
      }

      assert texts(:link, value) == ["Read more"]
      assert texts(:link, %{"url" => "/a"}) == []
    end

    test "a range indexes nothing" do
      assert texts(:range, %{"min" => 5, "max" => 9}) == []
      assert texts(:range, %{"min" => "2026-01-01"}) == []
    end

    test "a key/value list indexes its values, not its keys" do
      value = [%{"key" => "Zorp", "value" => "Alpha"}, %{"key" => "Quux", "value" => "Beta"}]
      assert texts(:key_value, value) == ["Alpha", "Beta"]
    end

    test "end to end: the label is findable, the url is not" do
      actor = admin()
      link = define!(actor, :link, %{searchable: true})

      {:ok, page} =
        page(actor, %{
          link.name => %{"url" => "https://urlonlytoken.example", "label" => "Labeltoken"}
        })

      assert page.search_text =~ "Labeltoken"
      refute page.search_text =~ "urlonlytoken"
    end
  end

  describe "filter and sort" do
    test "all three answer null only, and cannot be sorted" do
      actor = admin()

      values = %{
        range: %{"min" => 1},
        key_value: "a=1",
        link: %{"url" => "/a"}
      }

      for type <- @types do
        definition = define!(actor, type)
        {:ok, with_value} = page(actor, %{definition.name => values[type]})

        assert [%{id: id}] =
                 CMS.list_pages!(%{custom_filter: %{definition.name => %{"null" => false}}},
                   actor: actor
                 )

        assert id == with_value.id

        for filter <- [
              %{"eq" => "x"},
              %{"contains" => "a"},
              %{"gt" => "1"},
              %{"in" => "a,b"},
              %{"ilike" => "%a%"},
              "x"
            ] do
          assert {:error, error} =
                   CMS.list_pages(%{custom_filter: %{definition.name => filter}}, actor: actor)

          assert Exception.message(error) =~ "only supports null", inspect({type, filter})
        end

        assert {:error, error} = CMS.list_pages(%{custom_sort: definition.name}, actor: actor)
        assert Exception.message(error) =~ "not sortable"
      end
    end
  end
end
