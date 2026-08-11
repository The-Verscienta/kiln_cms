defmodule Mix.Tasks.Kiln.Export.SchemaTest do
  @moduledoc """
  `mix kiln.export.schema` (#430) — the build-step half of the delivery schema
  export.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Kiln.Export.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln-schema-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "writes JSON to stdout by default, and nothing else" do
    output = capture_io(fn -> Schema.run(["--blocks-only"]) end)

    assert {:ok, document} = Jason.decode(output)
    assert Map.has_key?(document["$defs"], "block")
  end

  test "the summary goes to stderr, so stdout stays pipeable" do
    stderr = capture_io(:stderr, fn -> capture_io(fn -> Schema.run(["--blocks-only"]) end) end)
    assert stderr =~ "block type(s)"
  end

  test "--pretty is still valid JSON, just indented" do
    output = capture_io(fn -> Schema.run(["--blocks-only", "--pretty"]) end)

    assert {:ok, _} = Jason.decode(output)
    assert output =~ "\n  \"$defs\": {"
  end

  # Erlang map order is only sorted up to 32 keys, and `$defs` passes that on any
  # real site — so an unsorted encode would reshuffle the whole file whenever a
  # block or content type is added. A schema written to disk gets committed and
  # diffed, so byte-stability is the point.
  test "JSON keys are sorted, so a committed artifact diffs cleanly" do
    output = capture_io(fn -> Schema.run(["--blocks-only", "--pretty"]) end)

    keys = output |> Jason.decode!() |> Map.get("$defs") |> Map.keys()

    emitted =
      Regex.scan(~r/^    "([^"]+)": \{$/m, output) |> Enum.map(fn [_, key] -> key end)

    assert Enum.sort(keys) == Enum.sort(emitted)
    assert emitted == Enum.sort(emitted)
  end

  test "--out writes a file and creates its directory", %{dir: dir} do
    path = Path.join([dir, "nested", "schema.json"])

    capture_io(fn -> Schema.run(["--blocks-only", "--out", path]) end)

    assert {:ok, document} = path |> File.read!() |> Jason.decode()
    assert Map.has_key?(document["$defs"], "block_heading")
  end

  test "--format ts emits declarations rather than JSON", %{dir: dir} do
    path = Path.join(dir, "kiln.d.ts")

    capture_io(fn -> Schema.run(["--blocks-only", "--format", "ts", "--out", path]) end)

    ts = File.read!(path)
    assert ts =~ "export interface HeadingBlock {"
    assert ts =~ "export type KilnBlock ="
  end

  test "--base-url becomes the document $id" do
    output =
      capture_io(fn ->
        Schema.run(["--blocks-only", "--base-url", "https://cdn.example.com"])
      end)

    assert Jason.decode!(output)["$id"] == "https://cdn.example.com/api/schema"
  end

  test "--all-orgs writes one document per site", %{dir: dir} do
    capture_io(fn -> Schema.run(["--all-orgs", "--blocks-only", "--out", dir]) end)

    written = dir |> File.ls!() |> Enum.sort()
    org_ids = KilnCMS.Accounts.list_org_ids() |> Enum.map(&"#{&1}.json") |> Enum.sort()

    assert written == org_ids
  end

  test "--all-orgs without --out fails loudly rather than writing one file per site" do
    assert_raise Mix.Error, ~r/--out/, fn -> Schema.run(["--all-orgs", "--blocks-only"]) end
  end

  test "an unknown format is rejected" do
    assert_raise Mix.Error, ~r/expected json\|ts/, fn -> Schema.run(["--format", "yaml"]) end
  end

  # `--all_orgs` looks right and parses as *unknown*; under `OptionParser.parse/2`
  # it would be dropped and the task would quietly export one site instead.
  test "an underscored switch is rejected rather than silently ignored" do
    assert_raise OptionParser.ParseError, ~r/all_orgs/, fn ->
      Schema.run(["--all_orgs", "--blocks-only"])
    end
  end
end
