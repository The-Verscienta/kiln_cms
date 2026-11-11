defmodule KilnCMS.SchemaExport.GoldenTest do
  @moduledoc """
  Every emitter over the full-schema fixture, byte for byte.

  `full.schema.json` is a real export — every registered block, `post` and
  `page`, a `post` custom field of each kind, and an admin-defined type with a
  plugin field type (see `KilnCMS.SchemaExport.GoldenFixture`;
  `KilnCMS.SchemaExport.RegenerateGoldensTest` writes all of them, and
  `KilnCMS.SchemaExport.DriftTest` fails when the export has moved away from
  them). The `.d.ts` golden was written by the TypeScript emitter *before* it
  moved onto `KilnCMS.SchemaExport.Walk`, so this is also the proof that the
  move changed nothing it emits.

  A failure after a deliberate change: regenerate (the command is in
  `RegenerateGoldensTest`'s moduledoc) and review the diff.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.SchemaExport

  @dir Path.expand("../../support/fixtures/schema_export", __DIR__)

  setup_all do
    %{document: @dir |> Path.join("full.schema.json") |> File.read!() |> Jason.decode!()}
  end

  test "TypeScript reproduces full.d.ts", %{document: document} do
    assert SchemaExport.TypeScript.emit(document) == File.read!(Path.join(@dir, "full.d.ts"))
  end

  test "TypeScript with GraphQL fragments reproduces full.graphql.ts" do
    document =
      @dir |> Path.join("full.graphql.schema.json") |> File.read!() |> Jason.decode!()

    assert SchemaExport.TypeScript.emit_graphql(document) ==
             File.read!(Path.join(@dir, "full.graphql.ts"))
  end

  test "Swift with GraphQL fragments reproduces full.graphql.swift" do
    document =
      @dir |> Path.join("full.graphql.schema.json") |> File.read!() |> Jason.decode!()

    assert SchemaExport.Swift.emit_graphql(document) ==
             File.read!(Path.join(@dir, "full.graphql.swift"))
  end

  test "Kotlin with GraphQL fragments reproduces full.graphql.kt" do
    document =
      @dir |> Path.join("full.graphql.schema.json") |> File.read!() |> Jason.decode!()

    assert SchemaExport.Kotlin.emit_graphql(document) ==
             File.read!(Path.join(@dir, "full.graphql.kt"))
  end

  test "Swift reproduces full.swift", %{document: document} do
    assert SchemaExport.Swift.emit(document) == File.read!(Path.join(@dir, "full.swift"))
  end

  test "Kotlin reproduces full.kt", %{document: document} do
    assert SchemaExport.Kotlin.emit(document) == File.read!(Path.join(@dir, "full.kt"))
  end

  test "OpenAPI reproduces full.openapi.json", %{document: document} do
    assert Mix.Tasks.Kiln.Export.Schema.encode(document, :openapi, pretty: true) ==
             File.read!(Path.join(@dir, "full.openapi.json"))
  end

  # What the golden must hold, so a regenerate that loses it shows up as more
  # than a diff to wave through.
  test "full.openapi.json maps every block and document tag and has no JSON Schema pointers left" do
    golden = File.read!(Path.join(@dir, "full.openapi.json"))
    openapi = Jason.decode!(golden)
    schemas = openapi["components"]["schemas"]

    refute golden =~ "#/$defs/"
    refute Map.has_key?(openapi, "$schema")
    assert openapi["jsonSchemaDialect"] == "https://json-schema.org/draft/2020-12/schema"

    mapping = schemas["block"]["discriminator"]["mapping"]
    assert mapping["heading"] == "#/components/schemas/block_heading"
    assert mapping["dep_badge"] == "#/components/schemas/block_dep_badge"
    assert map_size(mapping) == length(schemas["block"]["oneOf"])

    assert "#/components/schemas/content_review" in Enum.map(
             schemas["document"]["oneOf"],
             & &1["$ref"]
           )

    document_mapping = schemas["document"]["discriminator"]["mapping"]
    assert schemas["document"]["discriminator"]["propertyName"] == "type"
    assert document_mapping["review"] == "#/components/schemas/content_review"
    assert document_mapping["post"] == "#/components/schemas/content_post"
    assert map_size(document_mapping) == length(schemas["document"]["oneOf"])
  end
end
