defmodule KilnCMS.SchemaExport.DriftTest do
  @moduledoc """
  The checked-in `full.schema.json` and `full.graphql.schema.json` are what the
  export produces today (#2274).

  `KilnCMS.SchemaExport.GoldenTest` proves the emitters agree with those two
  documents; this proves the documents agree with the export, so a change to
  `KilnCMS.SchemaExport` (or to a block, a field type or the fixture plugins
  it reads) cannot leave every typed-client golden quietly describing an old
  shape. It builds the same state the regenerator does
  (`KilnCMS.SchemaExport.GoldenFixture`) and compares byte for byte.

  Not async: the dynamic-type registry reads across the table.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.SchemaExport.GoldenFixture

  setup do
    GoldenFixture.setup!()
  end

  for {name, opts} <- [{"full.schema.json", []}, {"full.graphql.schema.json", [graphql: true]}] do
    test "#{name} matches the live export" do
      golden = File.read!(Path.join(GoldenFixture.dir(), unquote(name)))
      live = GoldenFixture.encode(GoldenFixture.document(unquote(opts)))

      assert live == golden, """
      #{unquote(name)} no longer matches what the export produces.

      If the change is deliberate, regenerate the goldens and review the diff:

          #{GoldenFixture.regenerate_command()}
      """
    end
  end

  # Without these, the fixture plugin dropping out of `config/test.exs` would
  # regenerate into a smaller golden that still "matches".
  test "the fixture covers a plugin block, a plugin field type and a dynamic type" do
    document = GoldenFixture.document()
    dynamic = GoldenFixture.dynamic_type()

    assert "dep_badge" in document["x-kiln"]["blocks"]
    assert dynamic in document["x-kiln"]["content_types"]

    content = document["$defs"]["content_#{dynamic}"]
    assert content["x-kiln-content-type-source"] == "dynamic"

    # The dependency plugin's own `json_schema/1`, not widget inference (which
    # would say `number` with no bounds).
    assert content["properties"]["custom_fields"]["properties"]["score"] ==
             %{"type" => ["integer", "null"], "minimum" => 1, "maximum" => 5}
  end
end
