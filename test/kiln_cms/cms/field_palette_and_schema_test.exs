defmodule KilnCMS.CMS.FieldPaletteAndSchemaTest do
  @moduledoc """
  A color field's palette and a JSON field's JSON Schema (#2434): both live in
  the field definition's `validation` map, are checked when the definition is
  saved and on every content write, appear in the exported schema, and survive
  a field-definition export and import.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.{FieldSchema, FieldSync}
  alias KilnCMS.CMS.FieldTypes.{Color, Json}

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pal-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define(actor, type, validation, attrs \\ %{}) do
    CMS.create_field_definition(
      Map.merge(
        %{
          content_type: :page,
          name: "#{type}_#{System.unique_integer([:positive])}",
          label: "A #{type}",
          field_type: type,
          validation: validation
        },
        attrs
      ),
      actor: actor
    )
  end

  defp page(actor, fields),
    do:
      CMS.create_page(
        %{title: "P", slug: "p-#{System.unique_integer([:positive])}", custom_fields: fields},
        actor: actor
      )

  @schema %{
    "type" => "object",
    "required" => ["id"],
    "properties" => %{"id" => %{"type" => "integer", "minimum" => 3}}
  }

  describe "palette" do
    test "cast stays structural; the palette is a write constraint" do
      def = %{validation: %{"palette" => ["#FF8800", "#00f"]}}
      assert Color.cast("#F80", def) == {:ok, "#ff8800"}
      assert Color.cast("#123456", def) == {:ok, "#123456"}
      assert {:error, _} = Color.cast("nope", def)

      assert Color.palette(def) == ["#ff8800", "#0000ff"]
      assert Color.palette(%{validation: %{palette: ["#000"]}}) == ["#000000"]
      assert Color.palette(nil) == []
    end

    test "a definition's palette is validated when it is saved" do
      actor = admin()
      assert {:ok, _} = define(actor, :color, %{"palette" => ["#fff", "#000000"]})

      for bad <- [[], ["red"], "#fff", Enum.map(1..65, &"#0000#{rem(&1, 10)}0"), [1]] do
        assert {:error, error} = define(actor, :color, %{"palette" => bad})
        assert Exception.message(error) =~ "palette"
      end
    end

    test "palette is refused on other types, and the default must be in it" do
      actor = admin()
      assert {:error, error} = define(actor, :string, %{"palette" => ["#fff"]})
      assert Exception.message(error) =~ "can't be set"

      assert {:error, error} =
               define(actor, :color, %{"palette" => ["#fff"]}, %{default: "#123456"})

      assert Exception.message(error) =~ "palette"

      assert {:ok, _} = define(actor, :color, %{"palette" => ["#fff"]}, %{default: "#FFF"})
    end

    test "every write surface refuses a color outside it" do
      actor = admin()
      {:ok, definition} = define(actor, :color, %{"palette" => ["#2563eb", "#f59e0b"]})

      assert {:ok, page} = page(actor, %{definition.name => "#F59E0B"})
      assert page.custom_fields[definition.name] == "#f59e0b"

      assert {:error, error} = page(actor, %{definition.name => "#000000"})
      assert Exception.message(error) =~ "palette"
    end

    test "a multiple color field checks each item" do
      actor = admin()
      {:ok, definition} = define(actor, :color, %{"palette" => ["#2563eb"]}, %{multiple: true})
      assert {:ok, _} = page(actor, %{definition.name => ["#2563eb"]})
      assert {:error, _} = page(actor, %{definition.name => ["#2563eb", "#000000"]})
    end
  end

  describe "FieldSchema" do
    test "validates against draft 2020-12 with readable messages" do
      assert FieldSchema.validate(%{"id" => 5}, @schema) == :ok

      assert {:error, [message]} = FieldSchema.validate(%{"id" => 1}, @schema)
      assert message =~ "/id"
      assert message =~ "minimum"

      assert {:error, [message]} = FieldSchema.validate(%{}, @schema)
      assert message =~ "required"
    end

    test "reports at most five problems" do
      schema = %{"type" => "object", "additionalProperties" => false}
      value = Map.new(1..20, &{"k#{&1}", 1})
      assert {:error, messages} = FieldSchema.validate(value, schema)
      assert length(messages) <= 5
    end

    test "remote and unsupported references are refused, never fetched" do
      for ref <- [
            "http://169.254.169.254/latest",
            "https://example.com/s.json",
            "file:///etc/passwd",
            "other.json"
          ] do
        schema = %{"properties" => %{"a" => %{"$ref" => ref}}}
        assert {:error, message} = FieldSchema.check_schema(schema)
        assert message =~ "reference itself" or message =~ "may only"
      end

      assert :ok =
               FieldSchema.check_schema(%{
                 "$defs" => %{"n" => %{"type" => "integer"}},
                 "properties" => %{"a" => %{"$ref" => "#/$defs/n"}}
               })

      for key <- ["$id", "$dynamicRef", "$recursiveRef"],
          do: assert({:error, _} = FieldSchema.check_schema(%{key => "http://x.test/"}))

      assert {:error, _} =
               FieldSchema.check_schema(%{"$schema" => "http://json-schema.org/draft-04/schema#"})
    end

    test "size, depth and breadth are capped" do
      big = %{"description" => String.duplicate("x", FieldSchema.max_bytes())}
      assert {:error, message} = FieldSchema.check_schema(big)
      assert message =~ "too large"

      deep = Enum.reduce(1..30, %{"type" => "string"}, &%{"properties" => %{"k#{&1}" => &2}})
      assert {:error, message} = FieldSchema.check_schema(deep)
      assert message =~ "levels"

      wide = %{"enum" => Enum.to_list(1..1_500)}
      assert {:error, message} = FieldSchema.check_schema(wide)
      assert message =~ "values"
    end

    test "an invalid schema is refused" do
      assert {:error, _} = FieldSchema.check_schema(%{"type" => "nonsense"})
      assert {:error, _} = FieldSchema.check_schema("string")
    end

    test "an expensive check fails with a message instead of hanging" do
      schema = %{"type" => "string", "pattern" => "^(a+)+$"}
      value = String.duplicate("a", 40) <> "!"
      started = System.monotonic_time(:millisecond)
      assert {:error, [_ | _]} = FieldSchema.validate(%{"v" => value} |> Map.fetch!("v"), schema)
      assert System.monotonic_time(:millisecond) - started < 4_000
    end

    # #3063: a cold or busy node can take longer than the deadline to build a
    # schema. The deadline is for the value check, so a slow build must not
    # refuse a valid value. The stand-in builder sleeps four times the
    # deadline, so a build inside the deadline could not pass.
    test "a slow schema build does not count against the deadline" do
      slow_build = fn schema ->
        Process.sleep(200)
        JSV.build(schema, default_meta: FieldSchema.draft())
      end

      assert FieldSchema.validate(%{"id" => 5}, @schema, build: slow_build, deadline_ms: 50) ==
               :ok

      assert {:error, [message]} =
               FieldSchema.validate(%{"id" => 1}, @schema, build: slow_build, deadline_ms: 50)

      assert message =~ "minimum"
    end

    test "a value check past the deadline is refused" do
      # Checking 200,000 items for uniqueness takes far longer than 1 ms.
      value = Enum.to_list(1..200_000)

      assert FieldSchema.validate(value, %{"uniqueItems" => true}, deadline_ms: 1) ==
               {:error, ["took too long to check against the schema"]}
    end
  end

  describe "json_schema on a field" do
    test "cast stays structural; the schema is a write constraint" do
      def = %{validation: %{"json_schema" => @schema}}
      assert {:ok, %{"id" => 1}} = Json.cast(~s({"id": 1}), def)
    end

    test "a stored value outside a later schema or palette does not block other saves" do
      actor = admin()
      {:ok, json} = define(actor, :json, %{})
      {:ok, color} = define(actor, :color, %{})
      {:ok, other} = define(actor, :string, %{})

      assert {:ok, page} = page(actor, %{json.name => %{"x" => 1}, color.name => "#123456"})

      CMS.update_field_definition!(json, %{validation: %{"json_schema" => @schema}}, actor: actor)

      CMS.update_field_definition!(color, %{validation: %{"palette" => ["#ffffff"]}},
        actor: actor
      )

      # Resubmitting the stored values while changing something else saves.
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   custom_fields: %{
                     json.name => ~s({"x": 1}),
                     color.name => "#123456",
                     other.name => "hi"
                   }
                 },
                 actor: actor
               )

      assert updated.custom_fields[other.name] == "hi"

      # Changing them is judged.
      assert {:error, _} =
               CMS.update_page(
                 updated,
                 %{
                   custom_fields: %{
                     json.name => ~s({"x": 2}),
                     color.name => "#123456",
                     other.name => "hi"
                   }
                 },
                 actor: actor
               )

      assert {:error, _} =
               CMS.update_page(
                 updated,
                 %{
                   custom_fields: %{
                     json.name => ~s({"x": 1}),
                     color.name => "#abcdef",
                     other.name => "hi"
                   }
                 },
                 actor: actor
               )
    end

    test "a schema the default breaks is refused at save" do
      actor = admin()

      assert {:error, error} =
               define(actor, :json, %{"json_schema" => @schema}, %{default: "{}"})

      assert Exception.message(error) =~ "default value"
    end

    test "a property or example may be named $ref" do
      assert :ok =
               FieldSchema.check_schema(%{
                 "properties" => %{"$ref" => %{"type" => "string"}},
                 "examples" => [%{"$ref" => "x"}]
               })
    end

    test "a definition's schema is validated when it is saved" do
      actor = admin()
      assert {:ok, _} = define(actor, :json, %{"json_schema" => @schema})

      assert {:error, error} =
               define(actor, :json, %{
                 "json_schema" => %{
                   "properties" => %{"a" => %{"$ref" => "http://169.254.169.254/"}}
                 }
               })

      assert Exception.message(error) =~ "json_schema"

      assert {:error, error} = define(actor, :json, %{"json_schema" => "not an object"})
      assert Exception.message(error) =~ "json_schema"

      assert {:error, _} = define(actor, :string, %{"json_schema" => @schema})
    end

    test "writes are checked, with a readable error naming the field" do
      actor = admin()
      {:ok, definition} = define(actor, :json, %{"json_schema" => @schema})

      assert {:ok, page} = page(actor, %{definition.name => ~s({"id": 9})})
      assert page.custom_fields[definition.name] == %{"id" => 9}

      assert {:error, error} = page(actor, %{definition.name => %{"id" => 1}})
      message = Exception.message(error)
      assert message =~ "A json"
      assert message =~ "/id"
    end
  end

  describe "exports" do
    test "the schema export annotates palette and schema" do
      actor = admin()
      {:ok, color} = define(actor, :color, %{"palette" => ["#FFF", "#2563eb"]})
      {:ok, json} = define(actor, :json, %{"json_schema" => @schema})

      page =
        KilnCMS.SchemaExport.json_schema(org_id: color.org_id)["$defs"]["content_page"]

      custom = get_in(page, ["properties", "custom_fields", "properties"])
      assert custom[color.name]["x-kiln-palette"] == ["#ffffff", "#2563eb"]
      assert custom[json.name]["x-kiln-json-schema"] == @schema
    end

    test "field-definition export and import round-trip both options" do
      actor = admin()
      {:ok, color} = define(actor, :color, %{"palette" => ["#fff", "#2563eb"]})
      {:ok, json} = define(actor, :json, %{"json_schema" => @schema})

      {:ok, doc} = FieldSync.export(actor: actor)
      fields = for o <- doc["owners"], f <- o["fields"], do: f

      assert Enum.find(fields, &(&1["name"] == color.name))["validation"] == %{
               "palette" => ["#fff", "#2563eb"]
             }

      assert Enum.find(fields, &(&1["name"] == json.name))["validation"] == %{
               "json_schema" => @schema
             }

      CMS.destroy_field_definition!(color, actor: actor)
      CMS.destroy_field_definition!(json, actor: actor)

      assert {:ok, _} = FieldSync.import_doc(doc, actor: actor, apply?: true)

      restored = CMS.list_field_definitions!(actor: actor)

      assert Enum.find(restored, &(&1.name == color.name)).validation == %{
               "palette" => ["#fff", "#2563eb"]
             }

      assert Enum.find(restored, &(&1.name == json.name)).validation == %{
               "json_schema" => @schema
             }
    end
  end
end
