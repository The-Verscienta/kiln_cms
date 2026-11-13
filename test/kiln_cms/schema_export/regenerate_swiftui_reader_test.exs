defmodule KilnCMS.SchemaExport.RegenerateSwiftUIReaderTest do
  @moduledoc """
  Rewrites the SwiftUI reader example's checked-in models,
  `examples/swiftui-reader/Sources/KilnModels/Kiln.swift` (#2579) — **not a
  test**, and excluded from every run (`:regenerate_swiftui_models` in
  `test_helper.exs`).

  Generates the `recipe` type the demo seed creates
  (`KilnCMS.SchemaExport.SwiftUIReaderFixture`) in the test sandbox, so it needs
  no seeded database. `KilnCMS.SchemaExport.SwiftUIReaderDriftTest` fails when
  the file no longer matches. After a change to the export or the Swift
  emitter:

      mix test --only regenerate_swiftui_models test/kiln_cms/schema_export/regenerate_swiftui_reader_test.exs

  (or `examples/swiftui-reader/bin/regenerate`), review the diff, and run
  `swift test` in `examples/swiftui-reader`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.SchemaExport.SwiftUIReaderFixture

  @tag :regenerate_swiftui_models
  test "regenerate the SwiftUI reader's models" do
    SwiftUIReaderFixture.setup!()
    File.write!(SwiftUIReaderFixture.models_path(), SwiftUIReaderFixture.swift())
  end
end
