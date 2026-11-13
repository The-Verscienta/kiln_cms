defmodule KilnCMS.SchemaExport.SwiftUIReaderDriftTest do
  @moduledoc """
  The SwiftUI reader example's checked-in models,
  `examples/swiftui-reader/Sources/KilnModels/Kiln.swift`, are what the export
  produces today (#2579).

  The example's own CI (`swift test`) proves the app builds against the file it
  has, not that the file is current: it drifted past artifact format version 4
  unnoticed. This builds the same state the regenerator does
  (`KilnCMS.SchemaExport.SwiftUIReaderFixture`) and compares byte for byte, so
  a change to the export, the Swift emitter or the artifact format fails here
  until the example is regenerated.

  Not async: the dynamic-type registry reads across the table.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.SchemaExport.SwiftUIReaderFixture

  setup do
    SwiftUIReaderFixture.setup!()
  end

  # Excluded under a project overlay, like the schema goldens: the example
  # describes the core registry.
  @tag :core_registry
  test "Kiln.swift matches the live export" do
    assert SwiftUIReaderFixture.swift() == File.read!(SwiftUIReaderFixture.models_path()), """
    examples/swiftui-reader/Sources/KilnModels/Kiln.swift no longer matches what
    the export produces.

    Regenerate it, review the diff, and run `swift test` in examples/swiftui-reader:

        #{SwiftUIReaderFixture.regenerate_command()}
    """
  end

  test "the generation covers the fields the app reads" do
    swift = SwiftUIReaderFixture.swift()

    assert swift =~ "Artifact format version: #{KilnCMS.Firing.Engine.format_version()}"

    # Inside `RecipeDocument.CustomFields`, not anywhere in the file: a block
    # struct with a property of the same name would otherwise satisfy it.
    [_, recipe] = String.split(swift, "public struct RecipeDocument: ", parts: 2)
    [recipe | _] = String.split(recipe, "\n}\n", parts: 2)
    [_, custom_fields] = String.split(recipe, "    public struct CustomFields: ", parts: 2)
    [custom_fields | _] = String.split(custom_fields, "\n    }\n", parts: 2)

    for name <- ~w(serves minutes hero method ingredients),
        do:
          assert(
            custom_fields =~ "public let #{name}: ",
            "no `#{name}` in RecipeDocument.CustomFields"
          )

    # Core blocks only: the test env's fixture plugins must not leak into the example.
    refute swift =~ "dep_badge"
  end
end
