defmodule KilnCMS.SchemaExport.GraphQLEmittersTest do
  @moduledoc """
  The GraphQL custom-field sections of the TypeScript, Swift and Kotlin emitters
  (#2290), over the same hand-written documents: the selection (aliases, the
  collision rules, the `fields(names:)` kinds) must be identical in all three,
  because `KilnCMS.SchemaExport.GraphQL` owns it. `GoldenTest` covers the full
  export, and the `:swiftc`/`:kotlinc` compile tests run the output.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.SchemaExport.{Kotlin, Swift, TypeScript}

  defp document(defs), do: %{"x-kiln" => %{"artifact_format_version" => 3}, "$defs" => defs}

  defp content(type, graphql, custom) do
    %{
      "type" => "object",
      "x-kiln-graphql" => graphql,
      "properties" => %{
        "type" => %{"const" => type},
        "custom_fields" => %{
          "type" => "object",
          "properties" => custom,
          "additionalProperties" => true
        }
      }
    }
  end

  defp field(kind, type \\ ["string", "null"]),
    do: %{"type" => type, "x-kiln-graphql-kind" => kind}

  defp post(custom),
    do: document(%{"content_post" => content("post", %{"type" => "Post"}, custom)})

  defp emitters do
    [
      swift: &Swift.emit_graphql/1,
      kotlin: &Kotlin.emit_graphql/1,
      typescript: &TypeScript.emit_graphql/1
    ]
  end

  defp for_each(doc, fun) do
    for {name, emit} <- emitters(), do: fun.(name, emit.(doc))
  end

  test "every emitter reads scalar kinds through the same aliased accessors" do
    doc =
      post(%{
        "price" => field("float", ["number", "null"]),
        "seats" => field("int", ["integer", "null"]),
        "title_tag" => field("string"),
        "on_sale" => field("boolean", ["boolean", "null"]),
        "opens" => field("date"),
        "starts_at" => field("datetime")
      })

    for_each(doc, fn name, out ->
      for line <- [
            ~s|price: customFloat(name: "price")|,
            ~s|seats: customInt(name: "seats")|,
            ~s|titleTag: customString(name: "title_tag")|,
            ~s|onSale: customBoolean(name: "on_sale")|,
            ~s|opens: customDate(name: "opens")|,
            ~s|startsAt: customDateTime(name: "starts_at")|,
            "fragment PostCustomFields on Post {"
          ] do
        assert out =~ line, "#{name} lacks #{line}"
      end

      refute out =~ ~s|fields(names: ["|, "#{name} selects fields(names:) with no such kind"
    end)

    swift = Swift.emit_graphql(doc)
    assert swift =~ "public let price: Double?"
    assert swift =~ "public let seats: Int?"
    assert swift =~ "public let onSale: Bool?"
    assert swift =~ "public let startsAt: String?"
    assert swift =~ ~s|public static let fragment = """|
    refute swift =~ "public let fields:"

    kotlin = Kotlin.emit_graphql(doc)
    assert kotlin =~ "public val price: Double? = null,"
    assert kotlin =~ "public val seats: Long? = null,"
    assert kotlin =~ "public val onSale: Boolean? = null,"
    assert kotlin =~ "public data class PostCustomFields("
    refute kotlin =~ "public val fields: List<KilnCustomFieldValue> = emptyList()"
  end

  test "kinds without a scalar accessor go through fields(names:), geolocation included" do
    doc =
      post(%{
        "gallery" => field("list", ["array", "null"]),
        "seo" => field("group", ["object", "null"]),
        "venue" => field("geolocation", ["object", "null"]),
        "price" => field("float", ["number", "null"])
      })

    for_each(doc, fn name, out ->
      assert out =~ ~s|fields(names: ["gallery", "seo", "venue"]) {|, "#{name}"
      assert out =~ "... on GeolocationValue { lat lng label zoom }", "#{name}"
      assert out =~ "... on ListValue {", "#{name}"
      assert out =~ ~s|price: customFloat(name: "price")|, "#{name}"
    end)

    swift = Swift.emit_graphql(doc)
    assert swift =~ "public let fields: [KilnCustomFieldValue]"
    assert swift =~ "case geolocation(name: String, value: KilnGeolocationValue)"
    assert swift =~ "case unknown(typename: String, name: String)"

    kotlin = Kotlin.emit_graphql(doc)
    assert kotlin =~ "public val fields: List<KilnCustomFieldValue> = emptyList(),"
    assert kotlin =~ "public data class GeolocationValue("
    assert kotlin =~ "public data class Unknown("
    assert kotlin =~ "import kotlinx.serialization.KSerializer"
  end

  test "a dynamic type is an Entry fragment that names its typeName" do
    doc =
      document(%{
        "content_recipe" =>
          content("recipe", %{"type" => "Entry", "type_name" => "recipe"}, %{
            "serves" => field("int", ["integer", "null"])
          })
      })

    for_each(doc, fn name, out ->
      assert out =~ "fragment RecipeCustomFields on Entry {", "#{name}"
      assert out =~ ~s(`typeName: "recipe"`), "#{name}"
    end)
  end

  test "an alias that shadows a document field is prefixed, and collisions stay unique" do
    doc =
      post(%{
        "title" => field("string"),
        "state" => field("string"),
        "foo_bar" => field("string"),
        "foo__bar" => field("string")
      })

    for_each(doc, fn name, out ->
      assert out =~ ~s|customTitle: customString(name: "title")|, "#{name}"
      assert out =~ ~s|customState: customString(name: "state")|, "#{name}"
      assert out =~ ~s|fooBar: customString(name: "foo__bar")|, "#{name}"
      assert out =~ ~s|fooBar2: customString(name: "foo_bar")|, "#{name}"
    end)

    assert Swift.emit_graphql(doc) =~ "public let fooBar2: String?"
    assert Kotlin.emit_graphql(doc) =~ "public val fooBar2: String? = null,"
  end

  test "names Swift and Kotlin cannot take as a property are rescued" do
    doc = post(%{"self" => field("string"), "class" => field("string"), "in" => field("string")})

    swift = Swift.emit_graphql(doc)
    assert swift =~ "public let self_: String?"
    assert swift =~ "case self_ = \"self\""
    assert swift =~ "public let `class`: String?"

    kotlin = Kotlin.emit_graphql(doc)
    assert kotlin =~ "public val `class`: String? = null,"
    assert kotlin =~ "public val `in`: String? = null,"
  end

  test "a type with no custom fields gets no section" do
    doc = document(%{"content_post" => content("post", %{"type" => "Post"}, %{})})

    for_each(doc, fn name, out ->
      refute out =~ "fragment PostCustomFields", "#{name}"
      refute out =~ "KilnCustomFieldValue", "#{name}"
    end)
  end

  test "a document without the annotations is the plain emit" do
    doc = document(%{"content_post" => content("post", nil, %{"a" => %{"type" => "string"}})})

    assert Swift.emit_graphql(doc) == Swift.emit(doc)
    assert Kotlin.emit_graphql(doc) == Kotlin.emit(doc)
    assert TypeScript.emit_graphql(doc) == TypeScript.emit(doc)
  end

  test "Kotlin's GraphQL section honours the package option" do
    out = Kotlin.emit_graphql(post(%{"a" => field("string")}), package: "com.example.cms")
    assert out =~ "package com.example.cms"
  end
end
