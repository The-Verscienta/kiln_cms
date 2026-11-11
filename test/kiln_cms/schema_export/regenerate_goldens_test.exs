defmodule KilnCMS.SchemaExport.RegenerateGoldensTest do
  @moduledoc """
  Rewrites the full-schema fixture and the emitter goldens under
  `test/support/fixtures/schema_export/` — **not a test**, and excluded from
  every run (`:regenerate_schema_goldens` in `test_helper.exs`).

  The fixture is a real `KilnCMS.SchemaExport.json_schema/1` export of the
  state `KilnCMS.SchemaExport.GoldenFixture` builds: every registered block
  (plugin ones included), `post` with a custom field of each kind, `page`, and
  an admin-defined type with a plugin field type. Checked in rather than built
  per run, so the goldens change only when someone regenerates them and the
  diff shows what moved.

  The goldens are enforced: `KilnCMS.SchemaExport.DriftTest` fails when the
  live export no longer matches `full.schema.json` / `full.graphql.schema.json`,
  and `KilnCMS.SchemaExport.GoldenTest` fails when an emitter no longer
  reproduces its golden from them. After a deliberate change to the export or
  an emitter:

      mix test --only regenerate_schema_goldens test/kiln_cms/schema_export/regenerate_goldens_test.exs

  then review the diff of `full.schema.json`, `full.graphql.schema.json`,
  `full.openapi.json`, `full.graphql.ts`, `full.graphql.swift`,
  `full.graphql.kt`, `full.d.ts`, `full.swift` and `full.kt`.
  `clients/js/test/parity.test.ts` reads `full.d.ts` too. Run `npm test` in
  `clients/js` as well; if a change to the TypeScript emitter isn't mirrored
  in `kiln-types`, that run fails.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.SchemaExport
  alias KilnCMS.SchemaExport.GoldenFixture

  @tag :regenerate_schema_goldens
  test "regenerate the full-schema fixture and its goldens" do
    GoldenFixture.setup!()
    dir = GoldenFixture.dir()

    document = GoldenFixture.document()
    File.write!(Path.join(dir, "full.schema.json"), GoldenFixture.encode(document))

    File.write!(
      Path.join(dir, "full.openapi.json"),
      Mix.Tasks.Kiln.Export.Schema.encode(document, :openapi, pretty: true)
    )

    # The same definitions with the GraphQL annotations (#2290), for the
    # `*-graphql` goldens.
    graphql_document = GoldenFixture.document(graphql: true)

    File.write!(
      Path.join(dir, "full.graphql.schema.json"),
      GoldenFixture.encode(graphql_document)
    )

    File.write!(
      Path.join(dir, "full.graphql.ts"),
      SchemaExport.TypeScript.emit_graphql(graphql_document)
    )

    File.write!(
      Path.join(dir, "full.graphql.swift"),
      SchemaExport.Swift.emit_graphql(graphql_document)
    )

    File.write!(
      Path.join(dir, "full.graphql.kt"),
      SchemaExport.Kotlin.emit_graphql(graphql_document)
    )

    File.write!(Path.join(dir, "full.d.ts"), SchemaExport.TypeScript.emit(document))
    File.write!(Path.join(dir, "full.swift"), SchemaExport.Swift.emit(document))
    File.write!(Path.join(dir, "full.kt"), SchemaExport.Kotlin.emit(document))
  end
end
