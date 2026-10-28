defmodule KilnCMS.SchemaExport.SwiftTest do
  @moduledoc """
  The Swift emitter, one construct at a time.

  Hand-written documents, as in `KilnCMS.SchemaExport.TypeScriptTest`, so
  each case is unambiguous; `GoldenTest` covers the full export and
  `SwiftCompileTest` puts the output through `swiftc`.
  """
  use ExUnit.Case, async: true

  alias Kiln.Block.JsonSchema
  alias KilnCMS.SchemaExport.Swift

  defp document(defs), do: %{"x-kiln" => %{"artifact_format_version" => 3}, "$defs" => defs}

  defp emit(defs), do: Swift.emit(document(defs))

  defp object(properties, required \\ []),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp thing(properties, required \\ []),
    do: emit(%{"block_thing" => object(properties, required)})

  describe "properties" do
    test "a required, non-null key is plain; a nullable or optional one is an optional" do
      swift =
        thing(
          %{
            "a" => %{"type" => "string"},
            "b" => %{"type" => ["string", "null"]},
            "c" => %{"type" => "integer"}
          },
          ["a", "b"]
        )

      assert swift =~ "    public let a: String\n"
      assert swift =~ "    public let b: String?\n"
      assert swift =~ "    public let c: Int?\n"
      assert swift =~ "public init(a: String, b: String? = nil, c: Int? = nil) {"
    end

    test "JSON keys become lowerCamel names with CodingKeys pinning the wire name" do
      swift = thing(%{"read_time" => %{"type" => "number"}, "title" => %{"type" => "string"}})

      assert swift =~ "public let readTime: Double?"
      assert swift =~ ~s(case readTime = "read_time")
      assert swift =~ "        case title\n"
    end

    test "no CodingKeys when every key is already its Swift name" do
      refute thing(%{"title" => %{"type" => "string"}}) =~ "CodingKeys"
    end

    test "a keyword is back-ticked and a name Swift reserves even quoted is suffixed" do
      swift =
        thing(%{
          "default" => %{"type" => "string"},
          "self" => %{"type" => "string"},
          "hash_value" => %{"type" => "string"}
        })

      assert swift =~ "public let `default`: String?"
      assert swift =~ "        case `default`\n"
      assert swift =~ ~s(case self_ = "self")
      assert swift =~ ~s(case hashValue_ = "hash_value")
    end

    test "a key that is not an identifier is sanitized, its JSON spelling kept exactly" do
      swift = thing(%{"read time!" => %{"type" => "string"}, "2fa" => %{"type" => "boolean"}})

      assert swift =~ "public let readTime: String?"
      assert swift =~ ~s(case readTime = "read time!")
      assert swift =~ ~s(case _2fa = "2fa")
    end

    test "two keys that camel-case alike stay apart, the exact one keeping its name" do
      swift = thing(%{"_type" => %{"const" => "thing"}, "type" => %{"type" => "string"}})

      assert swift =~ "public let type: String?"
      assert swift =~ "public let _type: String?"
      # Both names are their keys, so there is nothing to map.
      refute swift =~ "CodingKeys"
    end

    test "a format, a bound and a const are dropped; the value's type stays" do
      swift =
        thing(%{
          "at" => %{"type" => "string", "format" => "date-time"},
          "level" => %{"type" => "integer", "minimum" => 1},
          "_type" => %{"const" => "thing"}
        })

      assert swift =~ "public let at: String?"
      assert swift =~ "public let level: Int?"
      assert swift =~ "public let type: String?"
      refute swift =~ "Date"
    end

    test "descriptions and reference targets become doc comments" do
      swift =
        thing(%{
          "parent" => %{
            "type" => ["object", "null"],
            "description" => "A snapshot.\nSecond line.",
            "x-kiln-target-types" => ["post", "page"]
          }
        })

      assert swift =~
               "    /// A snapshot.\n    /// Second line.\n    ///\n    /// Links to: `post`, `page`.\n" <>
                 "    public let parent: [String: JSONValue]?"
    end
  end

  describe "type mapping" do
    test "an object with no properties is an open map of JSONValue, which is bundled" do
      swift = thing(%{"meta" => %{"type" => "object"}})

      assert swift =~ "public let meta: [String: JSONValue]?"
      assert swift =~ "public indirect enum JSONValue: Codable, Hashable, Sendable {"
    end

    test "an inline object nests as a struct named for its key; array items take Item" do
      swift =
        thing(%{
          "seo" => object(%{"title" => %{"type" => "string"}}),
          "rows" => %{"type" => "array", "items" => object(%{"n" => %{"type" => "integer"}})}
        })

      assert swift =~ "public let seo: Seo?"
      assert swift =~ "    public struct Seo: Codable, Hashable, Sendable {\n"
      assert swift =~ "public let rows: [RowsItem]?"
      assert swift =~ "    public struct RowsItem: Codable, Hashable, Sendable {\n"
    end

    test "a nested type never shadows a top-level one" do
      swift =
        emit(%{
          "block" => %{"oneOf" => [%{"$ref" => "#/$defs/block_thing"}]},
          "block_thing" =>
            object(%{
              "_type" => %{"const" => "thing"},
              "block" =>
                object(%{
                  "blocks" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/block"}}
                })
            })
        })

      assert swift =~ "public let block: BlockValue?"
      assert swift =~ "public struct BlockValue: Codable, Hashable, Sendable {"
      assert swift =~ "public let blocks: [Block]?"
    end

    test "nullable array items stay optional inside the array" do
      swift = thing(%{"xs" => %{"type" => "array", "items" => %{"type" => ["number", "null"]}}})

      assert swift =~ "public let xs: [Double?]?"
    end

    test "a union Swift cannot name, or a $ref to nothing it declares, is JSONValue" do
      swift =
        emit(%{
          "other_union" => %{"oneOf" => [%{"$ref" => "#/$defs/a"}]},
          "block_thing" =>
            object(%{
              "either" => %{"type" => ["string", "integer"]},
              "dangling" => %{"$ref" => "#/$defs/nowhere"},
              "union" => %{"$ref" => "#/$defs/other_union"}
            })
        })

      assert swift =~ "public let either: JSONValue?"
      assert swift =~ "public let dangling: JSONValue?"
      assert swift =~ "public let union: JSONValue?"
      refute swift =~ "OtherUnion"
    end

    test "a single-member oneOf is its member, and a schema without properties is an alias" do
      swift =
        emit(%{
          "geo_point" => object(%{"lat" => %{"type" => "number"}}),
          "opaque_marker" => %{"const" => "fixed"},
          "block_thing" =>
            object(%{
              "at" => %{"oneOf" => [%{"$ref" => "#/$defs/geo_point"}]},
              "marker" => %{"$ref" => "#/$defs/opaque_marker"}
            })
        })

      assert swift =~ "public let at: GeoPoint?"
      assert swift =~ "public typealias OpaqueMarker = JSONValue"
      assert swift =~ "public let marker: OpaqueMarker?"
    end
  end

  describe "enums" do
    test "a string enum is an open, String-backed enum that decodes any value" do
      swift = thing(%{"style" => %{"enum" => ["primary", "ghost-outline"]}})

      assert swift =~ "public let style: Style?"
      assert swift =~ "public enum Style: RawRepresentable, Codable, Hashable, Sendable {"
      assert swift =~ "        case primary\n        case ghostOutline\n"
      assert swift =~ "        case unknown(String)\n"
      assert swift =~ ~s(case "ghost-outline": self = .ghostOutline)
      assert swift =~ "default: self = .unknown(rawValue)"

      assert swift =~
               "self.init(rawValue: try decoder.singleValueContainer().decode(String.self))"
    end

    test "a nullable enum keeps its null" do
      swift =
        thing(%{"tier" => %{"type" => ["string", "null"], "enum" => ["free", "pro"]}}, ["tier"])

      assert swift =~ "public let tier: Tier?"
    end

    test "a value spelled `unknown`, a keyword or a clash gets a case of its own" do
      swift = thing(%{"mode" => %{"enum" => ["unknown", "default", "a_b", "a-b"]}})

      assert swift =~ ~s(case "unknown": self = .unknown2)
      assert swift =~ ~s(case "default": self = .`default`)
      assert swift =~ ~s(case "a_b": self = .aB)
      assert swift =~ ~s(case "a-b": self = .a_b)
    end

    test "a quote, backslash or control character in a value is escaped" do
      swift = thing(%{"path" => %{"enum" => [~S(C:\x) <> ~s("y\n\u0001)]}})

      assert swift =~ ~S(case "C:\\x\"y\n\u{1}":)
    end

    test "an integer enum is an Int, not an enum" do
      assert thing(%{"level" => %{"enum" => [1, 2, 3]}}) =~ "public let level: Int?"
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

    test "the block union is an indirect enum switching on _type with an unknown fallback" do
      swift = emit(union_doc())

      assert swift =~ "public indirect enum Block: Codable, Hashable, Sendable {"
      assert swift =~ "    case richText(RichTextBlock)\n"
      assert swift =~ "    case unknown(type: String)\n"
      assert swift =~ ~s(case tag = "_type")
      assert swift =~ ~s(case "rich_text": self = .richText(try RichTextBlock(from: decoder\)\))
      assert swift =~ "default: self = .unknown(type: type)"
    end

    test "a block named `type` does not collide with the union's type accessor" do
      swift = emit(union_doc())

      assert swift =~ "    case type2(TypeBlock)\n"
      assert swift =~ "    public var type: String {"
    end

    test "content types get a Document union switching on type" do
      swift = emit(union_doc())

      assert swift =~ "public indirect enum Document: Codable, Hashable, Sendable {"
      assert swift =~ "    case landingPage(LandingPageDocument)\n    case post(PostDocument)\n"
      assert swift =~ ~s(case tag = "type")
    end

    test "with no content types there is no Document union" do
      refute emit(JsonSchema.defs(KilnCMS.Blocks.modules())) =~ "enum Document"
    end

    test "every registered block gets a struct and a case" do
      swift = emit(JsonSchema.defs(KilnCMS.Blocks.modules()))

      for module <- JsonSchema.block_modules(KilnCMS.Blocks.modules()) do
        name = JsonSchema.pascal(Kiln.Block.Info.name(module))
        assert swift =~ "public struct #{name}Block: Codable, Hashable, Sendable {"
        assert swift =~ "(#{name}Block)\n"
      end
    end

    test "a top-level name that would shadow a bundled type is suffixed" do
      swift =
        emit(%{
          "json_value" => object(%{}),
          "document" => object(%{}),
          "content_post" => object(%{"type" => %{"const" => "post"}}, ["type"])
        })

      assert swift =~ "public struct JsonValue: Codable"
      assert swift =~ "public struct Document2: Codable"
      assert swift =~ "public indirect enum Document: Codable"
    end
  end

  test "an object with no keys still declares a public init" do
    assert emit(%{"empty" => object(%{})}) =~
             "public struct Empty: Codable, Hashable, Sendable {\n    public init() {}\n}"
  end
end
