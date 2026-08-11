defmodule KilnCMS.SchemaExport.TypeScriptTest do
  @moduledoc """
  The `.d.ts` emitter (#430).

  It reads the JSON Schema document rather than the block registry, so these
  tests feed it hand-written documents where the interesting cases (a nullable
  union, a recursive `$ref`, an admin-named property that is not a valid
  identifier) are unambiguous — plus one pass over the real block export to
  prove the naming holds for every registered block.
  """
  use ExUnit.Case, async: true

  alias Kiln.Block.JsonSchema
  alias KilnCMS.SchemaExport.TypeScript

  defp document(defs), do: %{"x-kiln" => %{"artifact_format_version" => 2}, "$defs" => defs}

  defp emit(defs), do: TypeScript.emit(document(defs))

  describe "type mapping" do
    test "a const becomes a string literal and a nullable type becomes a union" do
      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{
              "_type" => %{"const" => "thing"},
              "caption" => %{"type" => ["string", "null"]}
            },
            "required" => ["_type"],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~s(_type: "thing";)
      assert ts =~ "caption?: string | null;"
    end

    test "required properties are not optional; the rest are" do
      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}},
            "required" => ["a"],
            "additionalProperties" => false
          }
        })

      assert ts =~ "a: string;"
      assert ts =~ "b?: string;"
    end

    test "an open object keeps an index signature; a closed one does not" do
      open =
        emit(%{
          "loose" => %{"type" => "object", "properties" => %{}, "additionalProperties" => true}
        })

      closed =
        emit(%{
          "tight" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
        })

      assert open =~ "[k: string]: unknown;"
      refute closed =~ "[k: string]: unknown;"
    end

    test "an enum becomes a literal union" do
      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{"layout" => %{"enum" => ["grid", "masonry"]}},
            "required" => [],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~s(layout?: "grid" | "masonry";)
    end

    test "a property name that is not an identifier is quoted" do
      ts =
        emit(%{
          "content_post" => %{
            "type" => "object",
            "properties" => %{
              "custom_fields" => %{
                "type" => "object",
                "properties" => %{"read time" => %{"type" => "string"}},
                "required" => [],
                "additionalProperties" => false
              }
            },
            "required" => ["custom_fields"],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~s("read time"?: string)
    end

    test "an integer is a number and a format is dropped rather than approximated" do
      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{
              "level" => %{"type" => "integer", "minimum" => 1},
              "url" => %{"type" => "string", "format" => "uri"}
            },
            "required" => [],
            "additionalProperties" => false
          }
        })

      assert ts =~ "level?: number;"
      assert ts =~ "url?: string;"
    end
  end

  describe "naming and unions" do
    test "the block union becomes KilnBlock, documents become KilnDocument" do
      ts =
        emit(%{
          "block" => %{"oneOf" => [%{"$ref" => "#/$defs/block_rich_text"}]},
          "block_rich_text" => %{
            "type" => "object",
            "properties" => %{"_type" => %{"const" => "rich_text"}},
            "required" => ["_type"],
            "additionalProperties" => false
          },
          "content_post" => %{
            "type" => "object",
            "properties" => %{"type" => %{"const" => "post"}},
            "required" => ["type"],
            "additionalProperties" => false
          }
        })

      assert ts =~ "export interface RichTextBlock {"
      assert ts =~ "export interface PostDocument {"
      assert ts =~ "export type KilnBlock =\n  | RichTextBlock;"
      assert ts =~ "export type KilnDocument =\n  | PostDocument;"
    end

    test "a recursive $ref emits a self-referencing type rather than expanding" do
      ts = emit(JsonSchema.defs(KilnCMS.Blocks.modules()))

      assert ts =~ "columns?: Array<{ blocks: Array<KilnBlock> }>;"
    end
  end

  test "every registered block gets exactly one exported interface" do
    ts = emit(JsonSchema.defs(KilnCMS.Blocks.modules()))

    for module <- KilnCMS.Blocks.modules() do
      name =
        module
        |> Kiln.Block.Info.name()
        |> to_string()
        |> String.split("_")
        |> Enum.map_join("", &String.capitalize/1)

      assert ts =~ "export interface #{name}Block {",
             "no interface emitted for #{inspect(module)}"
    end
  end

  describe "escaping" do
    # Custom-field names and select options are admin input with no charset
    # validation, so an unescaped backslash silently changes the emitted type
    # and an unescaped newline breaks the consumer's build outright.
    test "a backslash, quote or newline in a literal is escaped" do
      # A literal backslash, a double quote, and a real newline — the three that
      # respectively corrupt the value, terminate the string early, and break
      # the file outright.
      value = ~S(C:\reports) <> ~s("x\n)

      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{"path" => %{"const" => value}},
            "required" => [],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~S(path?: "C:\\reports\"x\n";)
      # The emitted declaration stays on one line.
      refute ts =~ ~s(path?: "C:\\reports\"x\n)
    end

    test "a property name that needs quoting is escaped too" do
      name = ~S(od\d) <> ~s( "x")

      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{name => %{"type" => "string"}},
            "required" => [],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~S("od\\d \"x\""?: string;)
    end

    test "a nullable const keeps its null" do
      # The clause-ordering trap: matching `const` before the type list would
      # drop `| null` and tell a consumer the `?.` is redundant.
      ts =
        emit(%{
          "block_thing" => %{
            "type" => "object",
            "properties" => %{"tone" => %{"type" => ["string", "null"], "const" => "warn"}},
            "required" => [],
            "additionalProperties" => false
          }
        })

      assert ts =~ ~s(tone?: "warn" | null;)
    end
  end

  test "a document with no content types still emits the block half" do
    ts = emit(JsonSchema.defs(KilnCMS.Blocks.modules()))

    assert ts =~ "export type KilnBlock ="
    refute ts =~ "export type KilnDocument ="
  end
end
