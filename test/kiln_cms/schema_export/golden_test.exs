defmodule KilnCMS.SchemaExport.GoldenTest do
  @moduledoc """
  Every emitter over the full-schema fixture, byte for byte.

  `full.schema.json` is a real export — every registered block, `post` and
  `page`, and a `post` custom field of each kind (see
  `KilnCMS.SchemaExport.RegenerateGoldensTest`, which writes all of
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

  test "Swift reproduces full.swift", %{document: document} do
    assert SchemaExport.Swift.emit(document) == File.read!(Path.join(@dir, "full.swift"))
  end

  test "Kotlin reproduces full.kt", %{document: document} do
    assert SchemaExport.Kotlin.emit(document) == File.read!(Path.join(@dir, "full.kt"))
  end
end
