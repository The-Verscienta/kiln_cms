defmodule KilnCMS.SchemaExport.FlexibleTest do
  @moduledoc """
  The typed export of a `:flexible` field (#2282, `docs/flexible-content-plan.md`
  section 6): the JSON Schema hoists each field's items into a `oneOf` union
  over closed item definitions under `flex_*`, `Walk` reads them as `:unions`
  and `:flex_items`, and every emitter names them without parsing a def name.
  `GoldenTest` covers the full export; this builds the shapes that need their
  own state: three levels of nesting, a def name that two paths want, and the
  GraphQL selection.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport
  alias KilnCMS.SchemaExport.{Kotlin, OpenApi, Swift, TypeScript, Walk}

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flex-export-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define(admin, attrs) do
    CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)
  end

  defp flexible(admin, name, extra \\ %{}),
    do: define(admin, Map.merge(%{content_type: :post, name: name, field_type: :flexible}, extra))

  defp item(admin, parent, name, extra \\ %{}),
    do: define(admin, Map.merge(%{name: name, field_type: :group, flex_of_id: parent.id}, extra))

  defp sub(admin, parent, name, type \\ :string, extra \\ %{}),
    do:
      define(
        admin,
        Map.merge(%{name: name, field_type: type, group_of_id: parent.id}, extra)
      )

  # sections (1) -> hero.cols (2) -> text.inner (3) -> leaf, plus a `hero_cols`
  # item type of `sections`: the def name the nested `cols` union is built from.
  defp three_levels!(admin) do
    sections = flexible(admin, "sections", %{max_items: 9})
    hero = item(admin, sections, "hero", %{position: 0, max_items: 2})
    hero_cols = item(admin, sections, "hero_cols", %{position: 1})

    sub(admin, hero, "headline")
    sub(admin, hero, "background", :select, %{options: ["light", "dark"], item_setting: true})
    cols = sub(admin, hero, "cols", :flexible)
    sub(admin, hero_cols, "count", :integer)

    text = item(admin, cols, "text")
    sub(admin, text, "body")
    inner = sub(admin, text, "inner", :flexible)

    leaf = item(admin, inner, "leaf")
    sub(admin, leaf, "note")
    :ok
  end

  defp post_schema(document),
    do: document["$defs"][SchemaExport.content_def_name(:post)]

  defp custom_field(document, name),
    do: post_schema(document)["properties"]["custom_fields"]["properties"][name]

  defp unions(document),
    do:
      for(
        {name, %{"oneOf" => _, "x-kiln-flexible" => annotation} = schema} <- document["$defs"],
        into: %{},
        do: {annotation["path"], {name, schema}}
      )

  defp resolve(document, %{"$ref" => "#/$defs/" <> name}), do: document["$defs"][name]

  describe "the JSON Schema" do
    test "three levels hoist into one union per field, each carrying its own path" do
      three_levels!(admin())
      document = SchemaExport.json_schema()

      paths = document |> unions() |> Map.keys() |> Enum.sort()

      assert paths == [
               ["sections"],
               ["sections", "hero", "cols"],
               ["sections", "hero", "cols", "text", "inner"]
             ]

      # The field holds a bare `$ref` to its union, and the union a bare `$ref`
      # per member: a sibling keyword beside a `$ref` is what older generators
      # drop.
      assert %{"items" => %{"$ref" => ref} = items} = custom_field(document, "sections")
      assert map_size(items) == 1
      assert {name, union} = unions(document)[["sections"]]
      assert ref == "#/$defs/" <> name

      assert %{"content_type" => "post", "field" => "sections"} = union["x-kiln-flexible"]
      assert union["discriminator"] == %{"propertyName" => "_type"}
      assert Enum.all?(union["oneOf"], &(Map.keys(&1) == ["$ref"]))
    end

    test "a member is closed, requires only its ids and keeps settings and bounds apart" do
      three_levels!(admin())
      document = SchemaExport.json_schema()

      {_, union} = unions(document)[["sections"]]
      [hero_ref, hero_cols_ref] = union["oneOf"]
      hero = resolve(document, hero_ref)

      assert hero["additionalProperties"] == false
      assert hero["required"] == ["_id", "_type"]
      assert hero["properties"]["_type"] == %{"const" => "hero"}
      assert hero["properties"]["_id"] == %{"type" => "string", "format" => "uuid"}

      # Settings sit under `_settings`, content beside the meta keys; the type's
      # own bound is an annotation on the member, never a sibling of a `$ref`.
      assert %{"additionalProperties" => false, "properties" => %{"background" => _} = settings} =
               hero["properties"]["_settings"]

      assert Map.keys(settings) == ["background"]
      assert Map.has_key?(hero["properties"], "headline")
      refute Map.has_key?(hero["properties"], "background")
      assert hero["x-kiln-max-items"] == 2

      # No `_settings` property at all when the type has no setting.
      hero_cols = resolve(document, hero_cols_ref)
      refute Map.has_key?(hero_cols["properties"], "_settings")
      refute Map.has_key?(hero_cols, "x-kiln-max-items")

      # The field's own bounds stay where they were.
      assert custom_field(document, "sections")["x-kiln-max-items"] == 9
    end

    test "a def name two paths want goes to the first, and the second gets a suffix" do
      three_levels!(admin())
      document = SchemaExport.json_schema()

      # `sections` > `hero` > `cols` and `sections` > `hero_cols` both spell
      # `flex_post_sections_hero_cols`.
      {nested, _} = unions(document)[["sections", "hero", "cols"]]
      assert nested == "flex_post_sections_hero_cols"

      {_, union} = unions(document)[["sections"]]
      refs = Enum.map(union["oneOf"], & &1["$ref"])
      assert "#/$defs/flex_post_sections_hero_cols_2" in refs
      refute "#/$defs/flex_post_sections_hero_cols" in refs

      assert document["$defs"]["flex_post_sections_hero_cols_2"]["properties"]["_type"] ==
               %{"const" => "hero_cols"}
    end

    test "two fields whose paths spell one name are told apart by their annotation" do
      admin = admin()
      a = flexible(admin, "a")
      a_b = flexible(admin, "a_b")
      sub(admin, item(admin, a, "b_c"), "x")
      sub(admin, item(admin, a_b, "c"), "y")

      document = SchemaExport.json_schema()

      # `a` > `b_c` and `a_b` > `c` are both `flex_post_a_b_c`.
      {_, first} = unions(document)[["a"]]
      {_, second} = unions(document)[["a_b"]]

      assert [%{"$ref" => "#/$defs/flex_post_a_b_c"}] = first["oneOf"]
      assert [%{"$ref" => "#/$defs/flex_post_a_b_c_2"}] = second["oneOf"]

      assert document["$defs"]["flex_post_a_b_c"]["properties"]["x"]
      assert document["$defs"]["flex_post_a_b_c_2"]["properties"]["y"]

      # Names are deterministic: a second export reads the same.
      assert SchemaExport.json_schema() == document
    end

    test "a flexible field with no item type stays a list of generic objects" do
      flexible(admin(), "empty_one")

      assert %{"items" => %{"type" => "object"}} =
               custom_field(SchemaExport.json_schema(), "empty_one")
    end

    test "a media and a reference sub-field keep their shared shapes inside an item" do
      admin = admin()
      f = flexible(admin, "cards")
      card = item(admin, f, "card")
      sub(admin, card, "photo", :media)
      sub(admin, card, "see_also", :reference, %{target_type: "post"})

      document = SchemaExport.json_schema()
      {_, union} = unions(document)[["cards"]]
      member = resolve(document, hd(union["oneOf"]))

      assert %{"anyOf" => [%{"$ref" => "#/$defs/media_snapshot"}, _]} =
               member["properties"]["photo"]

      assert member["properties"]["see_also"]["x-kiln-target-types"] == ["post"]
    end

    test "the graphql annotations name the item kind of a flexible field only" do
      admin = admin()
      three_levels!(admin)
      define(admin, %{content_type: :post, name: "synonyms", field_type: :string, multiple: true})
      document = SchemaExport.json_schema(graphql: true)

      sections = custom_field(document, "sections")
      assert sections["x-kiln-graphql-kind"] == "list"
      assert sections["x-kiln-graphql-item-kind"] == "flexible_item"

      synonyms = custom_field(document, "synonyms")
      assert synonyms["x-kiln-graphql-kind"] == "list"
      refute Map.has_key?(synonyms, "x-kiln-graphql-item-kind")
    end
  end

  describe "Walk" do
    test "reads each union and member without letting flex defs into shared" do
      three_levels!(admin())
      model = SchemaExport.json_schema() |> Walk.model()

      assert length(model.unions) == 3
      refute Enum.any?(model.shared, &String.starts_with?(&1.name, "flex_"))
      assert Enum.all?(model.flex_items, &String.starts_with?(&1.name, "flex_"))

      assert %{origin: :flexible, tag: "_type", flexible: %{"path" => ["sections"]}} =
               union = Enum.find(model.unions, &(&1.flexible["path"] == ["sections"]))

      assert Enum.map(union.members, & &1.tag) == ["hero", "hero_cols"]
      assert model.defs[union.name] == :union
      assert model.defs["flex_post_sections_hero"] == :object

      assert model.block_union.origin == :block
      assert model.document_union.origin == :document
    end
  end

  describe "the emitters" do
    setup do
      three_levels!(admin())
      %{document: SchemaExport.json_schema()}
    end

    test "TypeScript spells a union alias over its member interfaces", %{document: document} do
      ts = TypeScript.emit(document)

      assert ts =~
               "export type FlexPostSections =\n  | FlexPostSectionsHero\n  | FlexPostSectionsHeroCols2;"

      assert ts =~ "export type FlexPostSectionsHeroCols =\n  | FlexPostSectionsHeroColsText;"
      assert ts =~ "_type: \"hero\";"
      assert ts =~ "sections?: Array<FlexPostSections> | null"
      assert ts =~ "cols?: Array<FlexPostSectionsHeroCols> | null"
      # Closed members: no index signature.
      [interface] = Regex.run(~r/export interface FlexPostSectionsHero \{.*?\n\}/s, ts)
      refute interface =~ "[k: string]"
    end

    test "Swift and Kotlin name every union, and the clashing member keeps its own", %{
      document: document
    } do
      swift = Swift.emit(document)
      assert swift =~ "public indirect enum FlexPostSections: Codable, Hashable, Sendable {"
      assert swift =~ "case heroCols(FlexPostSectionsHeroCols2)"
      assert swift =~ "public indirect enum FlexPostSectionsHeroCols:"
      assert swift =~ "case unknown(type: String)"
      assert swift =~ "public let sections: [FlexPostSections]?"

      kotlin = Kotlin.emit(document)
      assert kotlin =~ "public sealed interface FlexPostSections {"
      assert kotlin =~ "public object FlexPostSectionsSerializer"
      assert kotlin =~ ") : FlexPostSections\n"
      assert kotlin =~ "public sealed interface FlexPostSectionsHeroCols {"
      assert kotlin =~ "public val sections: List<FlexPostSections>? = null"
    end

    test "OpenAPI maps each tag of a union to its component", %{document: document} do
      schemas = OpenApi.emit(document)["components"]["schemas"]

      assert %{"discriminator" => %{"propertyName" => "_type", "mapping" => mapping}} =
               schemas["flex_post_sections"]

      assert mapping == %{
               "hero" => "#/components/schemas/flex_post_sections_hero",
               "hero_cols" => "#/components/schemas/flex_post_sections_hero_cols_2"
             }

      assert get_in(schemas, ["flex_post_sections", "oneOf"]) == [
               %{"$ref" => "#/components/schemas/flex_post_sections_hero"},
               %{"$ref" => "#/components/schemas/flex_post_sections_hero_cols_2"}
             ]
    end

    test "a union whose serializer name is taken gets a suffixed name in Kotlin" do
      document = %{
        "x-kiln" => %{"artifact_format_version" => 3},
        "$defs" => %{
          "flex_post_a" => %{
            "oneOf" => [%{"$ref" => "#/$defs/flex_post_a_x"}],
            "discriminator" => %{"propertyName" => "_type"},
            "x-kiln-flexible" => %{"content_type" => "post", "field" => "a", "path" => ["a"]}
          },
          "flex_post_a_x" => %{
            "type" => "object",
            "properties" => %{"_type" => %{"const" => "x"}},
            "required" => ["_type"],
            "additionalProperties" => false
          },
          "flex_post_a_serializer" => %{
            "type" => "object",
            "properties" => %{"_type" => %{"const" => "s"}},
            "additionalProperties" => false
          }
        }
      }

      # The member def `flex_post_a_serializer` is a class named
      # `FlexPostASerializer`, which is what `flex_post_a`'s serializer would
      # be called, so the union is renamed (with its serializer).
      kotlin = Kotlin.emit(document)
      assert kotlin =~ "public data class FlexPostASerializer("
      assert kotlin =~ "public sealed interface FlexPostAItem {"
      assert kotlin =~ "public object FlexPostAItemSerializer : KSerializer<FlexPostAItem>"
    end
  end

  describe "the generated GraphQL selection" do
    test "a flexible field is selected one level deep and nothing else grows" do
      three_levels!(admin())
      document = SchemaExport.json_schema(graphql: true)

      for emit <- [&TypeScript.emit_graphql/1, &Swift.emit_graphql/1, &Kotlin.emit_graphql/1] do
        out = emit.(document)

        assert out =~
                 "... on FlexibleItemValue { id type settings { __typename name"

        assert out =~ ~s|fields(names: ["sections"])|
      end
    end

    test "a fragment without a flexible field is unchanged" do
      admin = admin()

      define(admin, %{content_type: :post, name: "tags_list", field_type: :string, multiple: true})

      out = TypeScript.emit_graphql(SchemaExport.json_schema(graphql: true))
      refute out =~ "... on FlexibleItemValue {"
    end
  end
end
