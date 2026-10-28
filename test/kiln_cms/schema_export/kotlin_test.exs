defmodule KilnCMS.SchemaExport.KotlinTest do
  @moduledoc """
  The Kotlin emitter, one construct at a time.

  Hand-written documents, as in `KilnCMS.SchemaExport.SwiftTest`, so each
  case is unambiguous; `GoldenTest` covers the full export and
  `KotlinCompileTest` puts the output through `kotlinc`.
  """
  use ExUnit.Case, async: true

  alias Kiln.Block.JsonSchema
  alias KilnCMS.SchemaExport.Kotlin

  defp document(defs), do: %{"x-kiln" => %{"artifact_format_version" => 3}, "$defs" => defs}

  defp emit(defs, opts \\ []), do: Kotlin.emit(document(defs), opts)

  defp object(properties, required \\ []),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp thing(properties, required \\ []),
    do: emit(%{"block_thing" => object(properties, required)})

  describe "file" do
    test "the package defaults to kiln and follows :package" do
      assert emit(%{}) =~ "\npackage kiln\n"
      assert emit(%{}, package: "com.example.kiln") =~ "\npackage com.example.kiln\n"
    end

    test "a package Kotlin cannot parse is refused" do
      for bad <- ["", "com..kiln", "com.example-app", "com.class", "1kiln", "kiln._"] do
        refute Kotlin.valid_package?(bad), bad
        assert_raise ArgumentError, fn -> emit(%{}, package: bad) end
      end

      assert Kotlin.valid_package?("com.example.kiln_app")
    end

    test "KilnJson ignores unknown keys; the union imports only come with a union" do
      kotlin = emit(%{"geo" => object(%{"lat" => %{"type" => "number"}})})

      assert kotlin =~ "public val KilnJson: Json = Json { ignoreUnknownKeys = true }"
      refute kotlin =~ "import kotlinx.serialization.KSerializer"
      refute kotlin =~ "tagged("
    end
  end

  describe "properties" do
    test "a required, non-null key is plain; a nullable or optional one defaults to null" do
      kotlin =
        thing(
          %{
            "a" => %{"type" => "string"},
            "b" => %{"type" => ["string", "null"]},
            "c" => %{"type" => "integer"}
          },
          ["a", "b"]
        )

      assert kotlin =~ "@Serializable\npublic data class ThingBlock(\n"
      assert kotlin =~ "    public val a: String,\n"
      assert kotlin =~ "    public val b: String? = null,\n"
      assert kotlin =~ "    public val c: Long? = null,\n"
    end

    test "JSON keys become lowerCamel names with @SerialName pinning the wire name" do
      kotlin = thing(%{"read_time" => %{"type" => "number"}, "title" => %{"type" => "string"}})

      assert kotlin =~ ~s(    @SerialName("read_time"\) public val readTime: Double? = null,\n)
      assert kotlin =~ "    public val title: String? = null,\n"
    end

    test "a hard keyword is back-ticked; a soft one is left alone" do
      kotlin = thing(%{"class" => %{"type" => "string"}, "where" => %{"type" => "string"}})

      assert kotlin =~ "public val `class`: String? = null,"
      assert kotlin =~ "public val where: String? = null,"
    end

    test "a key that is not an identifier is sanitized, its JSON spelling kept exactly" do
      kotlin =
        thing(%{
          "read time!" => %{"type" => "string"},
          "2fa" => %{"type" => "boolean"},
          "___" => %{"type" => "string"}
        })

      assert kotlin =~ ~s(@SerialName("read time!"\) public val readTime: String?)
      assert kotlin =~ ~s(@SerialName("2fa"\) public val _2fa: Boolean?)
      # An all-underscore name is reserved in Kotlin.
      assert kotlin =~ ~s(@SerialName("___"\) public val empty: String?)
    end

    test "two keys that camel-case alike stay apart, the exact one keeping its name" do
      kotlin = thing(%{"_type" => %{"const" => "thing"}, "type" => %{"type" => "string"}})

      assert kotlin =~ "    public val type: String? = null,\n"
      # Both names are their keys, so there is nothing to pin.
      assert kotlin =~ "    public val _type: String? = null,\n"
      refute kotlin =~ "@SerialName"
    end

    test "a format, a bound and a const are dropped; the value's type stays" do
      kotlin =
        thing(%{
          "at" => %{"type" => "string", "format" => "date-time"},
          "level" => %{"type" => "integer", "minimum" => 1},
          "_type" => %{"const" => "thing"}
        })

      assert kotlin =~ "public val at: String? = null,"
      assert kotlin =~ "public val level: Long? = null,"
      assert kotlin =~ ~s(@SerialName("_type"\) public val type: String? = null,)
      refute kotlin =~ "Instant"
    end

    test "descriptions and reference targets become KDoc, comment markers defused" do
      kotlin =
        thing(%{
          "parent" => %{
            "type" => ["object", "null"],
            "description" => "A snapshot.\nSee /* and */ here.",
            "x-kiln-target-types" => ["post", "page"]
          },
          "short" => %{"type" => "string", "description" => "One line."}
        })

      assert kotlin =~
               "    /**\n     * A snapshot.\n     * See / * and * / here.\n     *\n" <>
                 "     * Links to: `post`, `page`.\n     */\n" <>
                 "    public val parent: JsonObject? = null,\n"

      assert kotlin =~ "    /** One line. */\n    public val short: String? = null,\n"
    end
  end

  describe "type mapping" do
    test "an object with no properties is a JsonObject" do
      assert thing(%{"meta" => %{"type" => "object"}}) =~ "public val meta: JsonObject? = null,"
    end

    test "an inline object nests as a data class named for its key; list items take Item" do
      kotlin =
        thing(%{
          "seo" => object(%{"title" => %{"type" => "string"}}),
          "rows" => %{"type" => "array", "items" => object(%{"n" => %{"type" => "integer"}})}
        })

      assert kotlin =~ "public val seo: Seo? = null,"
      assert kotlin =~ ") {\n    @Serializable\n    public data class RowsItem(\n"
      assert kotlin =~ "public val rows: List<RowsItem>? = null,"

      assert kotlin =~
               "    public data class Seo(\n        public val title: String? = null,\n    )"
    end

    test "an object with no keys is a data object" do
      assert emit(%{"empty" => object(%{})}) =~ "@Serializable\npublic data object Empty\n"
    end

    test "a nested type never shadows a top-level or a Kotlin type, even by case" do
      kotlin =
        emit(%{
          "block" => %{"oneOf" => [%{"$ref" => "#/$defs/block_thing"}]},
          "block_thing" =>
            object(%{
              "_type" => %{"const" => "thing"},
              "block" =>
                object(%{
                  "blocks" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/block"}}
                }),
              "string" => object(%{"n" => %{"type" => "integer"}}),
              "seo" => object(%{"a" => %{"type" => "string"}}),
              "SEO" => object(%{"b" => %{"type" => "string"}})
            })
        })

      assert kotlin =~ "public val block: BlockValue? = null,"
      assert kotlin =~ "public val blocks: List<Block>? = null,"
      assert kotlin =~ "public val string: StringValue? = null,"
      # `Seo` and `SEO` would be one `.class` file on a case-insensitive disk;
      # keys sort `SEO` first, so it keeps its spelling.
      assert kotlin =~ ~s(@SerialName("SEO"\) public val sEO: SEO? = null,)
      assert kotlin =~ "public val seo: SeoValue? = null,"
    end

    test "nullable list items stay nullable inside the list" do
      kotlin = thing(%{"xs" => %{"type" => "array", "items" => %{"type" => ["number", "null"]}}})

      assert kotlin =~ "public val xs: List<Double?>? = null,"
    end

    test "a union Kotlin cannot name, or a $ref to nothing it declares, is JsonElement" do
      kotlin =
        emit(%{
          "other_union" => %{"oneOf" => [%{"$ref" => "#/$defs/a"}]},
          "block_thing" =>
            object(%{
              "either" => %{"type" => ["string", "integer"]},
              "dangling" => %{"$ref" => "#/$defs/nowhere"},
              "union" => %{"$ref" => "#/$defs/other_union"}
            })
        })

      assert kotlin =~ "public val either: JsonElement? = null,"
      assert kotlin =~ "public val dangling: JsonElement? = null,"
      assert kotlin =~ "public val union: JsonElement? = null,"
      refute kotlin =~ "OtherUnion"
    end

    test "a single-member oneOf is its member, and a schema without properties is an alias" do
      kotlin =
        emit(%{
          "geo_point" => object(%{"lat" => %{"type" => "number"}}),
          "opaque_marker" => %{"const" => "fixed"},
          "block_thing" =>
            object(%{
              "at" => %{"oneOf" => [%{"$ref" => "#/$defs/geo_point"}]},
              "marker" => %{"$ref" => "#/$defs/opaque_marker"}
            })
        })

      assert kotlin =~ "public val at: GeoPoint? = null,"
      assert kotlin =~ "public typealias OpaqueMarker = JsonElement"
      assert kotlin =~ "public val marker: OpaqueMarker? = null,"
    end
  end

  describe "enums" do
    test "a string enum is an open value class with a constant per listed value" do
      kotlin = thing(%{"style" => %{"enum" => ["primary", "ghost-outline"]}})

      assert kotlin =~ "public val style: Style? = null,"

      assert kotlin =~
               "    @Serializable\n    @JvmInline\n" <>
                 "    public value class Style(public val value: String) {\n"

      assert kotlin =~ ~s(public val Primary: Style = Style("primary"\)\n)
      assert kotlin =~ ~s(public val GhostOutline: Style = Style("ghost-outline"\)\n)
      assert kotlin =~ "public val entries: List<Style> = listOf(Primary, GhostOutline)"
      assert kotlin =~ "public val isKnown: Boolean get() = this in entries"
    end

    test "a nullable enum keeps its null" do
      kotlin =
        thing(%{"tier" => %{"type" => ["string", "null"], "enum" => ["free", "pro"]}}, ["tier"])

      assert kotlin =~ "public val tier: Tier? = null,"
    end

    test "a value spelled Companion, an empty value or a clash gets a constant of its own" do
      kotlin = thing(%{"mode" => %{"enum" => ["Companion", "", "a_b", "a-b"]}})

      assert kotlin =~ ~s(public val Companion2: Mode = Mode("Companion"\))
      assert kotlin =~ ~s(public val Empty: Mode = Mode(""\))
      assert kotlin =~ ~s(public val AB: Mode = Mode("a_b"\))
      assert kotlin =~ ~s(public val a_b: Mode = Mode("a-b"\))
    end

    test "a quote, backslash, dollar or control character in a value is escaped" do
      kotlin = thing(%{"path" => %{"enum" => [~S(C:\x) <> ~s("y\n\u0001$z)]}})

      assert kotlin =~ ~S{Path("C:\\x\"y\n\u0001\$z")}
    end

    test "an integer enum is a Long, not a value class" do
      assert thing(%{"level" => %{"enum" => [1, 2, 3]}}) =~ "public val level: Long? = null,"
    end
  end

  describe "unions" do
    defp union_doc do
      %{
        "block" => %{
          "oneOf" => [%{"$ref" => "#/$defs/block_rich_text"}, %{"$ref" => "#/$defs/block_type"}],
          "discriminator" => %{"propertyName" => "_type"}
        },
        "block_rich_text" => object(%{"_type" => %{"const" => "rich_text"}}, ["_type"]),
        "block_type" => object(%{"_type" => %{"const" => "type"}}, ["_type"]),
        "content_post" => object(%{"type" => %{"const" => "post"}}, ["type"]),
        "content_landing_page" => object(%{"type" => %{"const" => "landing_page"}}, ["type"])
      }
    end

    test "the block union is a sealed interface its members implement, with Unknown" do
      kotlin = emit(union_doc())

      assert kotlin =~
               "@Serializable(with = BlockSerializer::class)\npublic sealed interface Block {\n"

      assert kotlin =~
               "    public data class Unknown(public val type: String, public val raw: JsonObject) : Block\n"

      assert kotlin =~ ") : Block\n"
      assert kotlin =~ "public data class RichTextBlock(\n"
    end

    test "the serializer switches on _type, falls back to Unknown and re-stamps the tag" do
      kotlin = emit(union_doc())

      assert kotlin =~ "public object BlockSerializer : KSerializer<Block> {"
      assert kotlin =~ ~s{(raw["_type"] as? JsonPrimitive)?.contentOrNull}

      assert kotlin =~
               ~s{"rich_text" -> input.json.decodeFromJsonElement(RichTextBlock.serializer(), raw)}

      assert kotlin =~ "else -> Block.Unknown(type.orEmpty(), raw)"

      assert kotlin =~
               ~s{is RichTextBlock -> output.json.encodeToJsonElement(RichTextBlock.serializer(), value).tagged("_type", "rich_text")}

      assert kotlin =~ "is Block.Unknown -> value.raw"
      assert kotlin =~ "private fun JsonElement.tagged(key: String, tag: String): JsonObject ="
    end

    test "content types get a Document union switching on type" do
      kotlin = emit(union_doc())

      assert kotlin =~ "public sealed interface Document {"
      assert kotlin =~ ") : Document\n"
      assert kotlin =~ ~s{(raw["type"] as? JsonPrimitive)?.contentOrNull}

      assert kotlin =~
               ~s{"landing_page" -> input.json.decodeFromJsonElement(LandingPageDocument.serializer(), raw)\n} <>
                 ~s{            "post" -> }
    end

    test "with no content types there is no Document union" do
      refute emit(JsonSchema.defs(KilnCMS.Blocks.modules())) =~ "interface Document"
    end

    test "every registered block gets a class and a branch" do
      kotlin = emit(JsonSchema.defs(KilnCMS.Blocks.modules()))

      for module <- JsonSchema.block_modules(KilnCMS.Blocks.modules()) do
        name = JsonSchema.pascal(Kiln.Block.Info.name(module))
        assert kotlin =~ "public data class #{name}Block("
        assert kotlin =~ "is #{name}Block -> "
      end
    end

    test "a top-level name that would shadow a bundled one is suffixed" do
      kotlin =
        emit(%{
          "kiln_json" => object(%{"a" => %{"type" => "string"}}),
          "document" => object(%{"a" => %{"type" => "string"}}),
          "document_serializer" => object(%{"a" => %{"type" => "string"}}),
          "content_post" => object(%{"type" => %{"const" => "post"}}, ["type"])
        })

      assert kotlin =~ "public data class KilnJson2("
      assert kotlin =~ "public data class Document2("
      assert kotlin =~ "public data class DocumentSerializer2("
      assert kotlin =~ "public sealed interface Document {"
    end
  end
end
